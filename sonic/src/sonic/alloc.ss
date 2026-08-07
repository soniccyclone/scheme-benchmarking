;;; Bump allocator: claim-then-fill, with the restart region that covers it.
;;;
;;; E7, bead 6cm.2. Written in Scheme because per D25 the runtime IS Scheme;
;;; there is no libc anywhere in the running system and nothing here calls out
;;; to one. This library is the model of the fast path and the executable form
;;; of its restart region, in the same sense that gcell.ss is the model of a
;;; global reference: the emitted code is these steps, in this order, with these
;;; PC boundaries.
;;;
;;; ## The fast path is a pointer bump and nothing else
;;;
;;; Load the allocation pointer, add the size, compare against the limit,
;;; branch out if it fails, store the new pointer, write the header. Six
;;; instructions, one comparison, no call, no poll.
;;;
;;; ## Two mechanisms copied rather than invented
;;;
;;; Both from the OS bundle by way of docs/phases/07-compiler/EXECUTION.md E7.
;;;
;;; **The allocation check IS the remembered-set overflow check.** The
;;; allocation pointer grows UP from the nursery base and the remembered-set
;;; pointer grows DOWN from the top of the same region. They approach each
;;; other, so running out of nursery and running out of store buffer are the
;;; same event, detected by the same comparison of the same two values on the
;;; same path. `nursery-overflow?` below is that one comparison, and both the
;;; allocation path and the barrier's push path call it. The store buffer gets
;;; its limit and its bound check for free, which is the entire point: the write
;;; barrier is already about ten instructions per pointer store and a second
;;; independent bound check would be a visible fraction of that.
;;;
;;; Our version loads the limit from the thread block rather than keeping it in
;;; a dedicated register, because the register partition has no register to
;;; spare for it on x86-64 and inventing one would mean editing regs.ss. On
;;; x86-64 that load is GS-relative, on RV64 tp-relative; either way it is ONE
;;; load serving both consumers instead of two.
;;;
;;; **Reserve the collection worst case up front.** The remembered-set pointer
;;; does not start at the top of the region. It starts `reserve` words below it,
;;; and the words above it belong to the collector. So when the mutator's
;;; comparison finally trips, the collector still has its guaranteed room and
;;; can run; and if it cannot free enough, the failure surfaces as a Scheme
;;; condition (`&heap-exhausted`) that a program can catch, not an abort. The
;;; bundle's finding is that the only systems that survive heap exhaustion do
;;; this, and that Linux, Chez and Mirage all die instead.
;;;
;;; ## The restart region
;;;
;;; Per D21 and sonic/src/sonic/preempt.ss there is no poll anywhere. A thread
;;; is stopped wherever it happens to be. Between the store that commits the new
;;; allocation pointer and the store that writes the object header, the memory
;;; the pointer now covers is not a valid object, and that window is the one
;;; place the no-poll invariant genuinely cannot hold on its own.
;;;
;;; The answer is not a poll. The window is a restart region, and a thread
;;; stopped inside it has its saved PC rewound to the region's START, which is
;;; the LOAD of the allocation pointer, not the bump. That matters: the redo has
;;; to re-read the pointer, because if the commit already happened the pointer
;;; has moved.
;;;
;;; What the redo costs, in the worst case, is one abandoned block: the
;;; interrupt landed after the commit but before the header, so the first claim
;;; is never filled and never referenced. That is free rather than a leak,
;;; because the collector is a precise TRACING copying collector (D21, bead
;;; 6cm.5). It never parses the nursery linearly, so an unreferenced headerless
;;; block is not something it can trip over; it is simply not copied, and it
;;; costs one block of nursery space until the next collection. One block per
;;; preemption event is not a quantity anything can measure.
;;;
;;; The obligation preempt.ss states for a region author is idempotence on
;;; rewind. Discharged: steps 0-3 are register-only, step 4 is a single word
;;; store that is either done or not, and re-running from step 0 re-reads
;;; whatever step 4 left. Nothing in the window is a read-modify-write of shared
;;; state whose second execution differs from its first.

(library (sonic alloc)
  (export make-nursery nursery? nursery-base nursery-top nursery-reserve
          nursery-alloc-ptr nursery-rs-ptr nursery-heap
          nursery-alloc-ptr-set! nursery-rs-ptr-set!
          nursery-collector nursery-collector-set!
          nursery-free nursery-overflow? nursery-would-overflow?
          heap-ref heap-set!

          alloc-fast-path alloc-fast-path-mnemonics
          rs-push-path rs-push-path-mnemonics
          alloc-region rs-region alloc-region-table

          run-alloc run-rs-push
          nursery-alloc! nursery-rs-push!

          reserve-base reserve-ptr reserve-intact? reserve-claim!
          &heap-exhausted make-heap-exhausted heap-exhausted?
          heap-exhausted-nursery heap-exhausted-request)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs records syntactic)
          (rnrs conditions)
          (rnrs exceptions)
          (sonic preempt))

  ;; --- heap exhaustion is a condition, not an abort -------------------------
  (define-condition-type &heap-exhausted &error
    make-heap-exhausted heap-exhausted?
    (nursery heap-exhausted-nursery)
    (request heap-exhausted-request))

  ;; --- the nursery ----------------------------------------------------------
  ;;
  ;; Word-addressed for legibility. A real image uses byte addresses and the
  ;; sizes below are byte counts; nothing about the mechanism changes.
  ;;
  ;;   base                 alloc ->        <- rs      reserve-base      top
  ;;   |======= objects =======|   free   |== buffer ==|== collector ==|
  ;;
  ;; `alloc` grows up, `rs` grows down, and they meet. `reserve-base` is where
  ;; rs STARTS, so the words from there to `top` are the collector's and the
  ;; mutator's comparison never sees them.
  (define-record-type (nursery mk-nursery nursery?)
    (fields heap base top reserve reserve-base
            (mutable alloc-ptr) (mutable rs-ptr) (mutable reserve-ptr)
            (mutable collector)))

  (define (make-nursery words reserve)
    (when (or (negative? reserve) (> reserve words))
      (error 'make-nursery "reserve must fit inside the nursery" words reserve))
    (let ((rbase (- words reserve)))
      (mk-nursery (make-vector words 0) 0 words reserve rbase
                  0 rbase rbase #f)))

  (define (heap-ref n i) (vector-ref (nursery-heap n) i))
  (define (heap-set! n i v) (vector-set! (nursery-heap n) i v))

  (define (nursery-free n) (- (nursery-rs-ptr n) (nursery-alloc-ptr n)))

  ;; THE comparison. One function, two callers: the allocation fast path and the
  ;; write barrier's remembered-set push. `lo` is always the allocation side and
  ;; `hi` the remembered-set side; overflow is the moment they cross.
  (define (nursery-overflow? lo hi) (> lo hi))

  ;; The same question asked ahead of time, for `need` words on either side.
  (define (nursery-would-overflow? n need)
    (nursery-overflow? (+ (nursery-alloc-ptr n) need) (nursery-rs-ptr n)))

  ;; --- the collector's reserve ---------------------------------------------
  (define (reserve-base n) (nursery-reserve-base n))
  (define (reserve-ptr n) (nursery-reserve-ptr n))
  (define (reserve-intact? n) (= (nursery-reserve-ptr n) (nursery-reserve-base n)))

  ;; What the collector allocates from. Separate pointer, separate region,
  ;; unreachable from the mutator's comparison, which is the whole reason it can
  ;; be relied on at the moment the mutator has run out.
  (define (reserve-claim! n words)
    (let ((p (nursery-reserve-ptr n)))
      (if (> (+ p words) (nursery-top n))
          #f
          (begin (nursery-reserve-ptr-set! n (+ p words)) p))))

  ;; --- the fast path, as steps ---------------------------------------------
  ;;
  ;; One step per emitted instruction, executed by an interpreter that can be
  ;; interrupted between any two of them. This is not a mock of the fast path
  ;; sitting next to a real one: `nursery-alloc!` runs THESE steps, so the
  ;; restart test and the allocation test exercise the same code.

  (define-record-type (fpm make-fpm fpm?)
    (fields (mutable p) (mutable p1) (mutable lim) (mutable dst) (mutable slow)))

  (define (fresh-fpm) (make-fpm 0 0 0 #f #f))

  ;; PC layout. Byte offsets in a real image; indices here. The two sequences
  ;; are separate code at separate addresses, which is why the second is based
  ;; well past the first.
  (define alloc-base 0)
  (define rs-base 16)

  ;; step 0  p   <- [thread.alloc-ptr]      region starts HERE, at the load
  ;; step 1  p1  <- p + size
  ;; step 2  lim <- [thread.rs-ptr]         the aliased limit
  ;; step 3  if overflow -> slow            THE comparison
  ;; step 4  [thread.alloc-ptr] <- p1       commit: the block is claimed
  ;; step 5  [p] <- header                  fill: the block becomes an object
  ;; step 6  dst <- p                       outside the region
  (define (alloc-steps)
    (vector
     (lambda (n m size hdr) (fpm-p-set! m (nursery-alloc-ptr n)))
     (lambda (n m size hdr) (fpm-p1-set! m (+ (fpm-p m) size)))
     (lambda (n m size hdr) (fpm-lim-set! m (nursery-rs-ptr n)))
     (lambda (n m size hdr)
       (when (nursery-overflow? (fpm-p1 m) (fpm-lim m)) (fpm-slow-set! m #t)))
     (lambda (n m size hdr) (nursery-alloc-ptr-set! n (fpm-p1 m)))
     (lambda (n m size hdr) (heap-set! n (fpm-p m) hdr))
     (lambda (n m size hdr) (fpm-dst-set! m (fpm-p m)))))

  ;; step 16 r  <- [thread.rs-ptr]
  ;; step 17 r1 <- r - 1
  ;; step 18 a  <- [thread.alloc-ptr]
  ;; step 19 if overflow -> slow            THE SAME comparison
  ;; step 20 [thread.rs-ptr] <- r1          commit
  ;; step 21 [r1] <- slot                   fill
  (define (rs-steps)
    (vector
     (lambda (n m slot ignored) (fpm-p-set! m (nursery-rs-ptr n)))
     (lambda (n m slot ignored) (fpm-p1-set! m (- (fpm-p m) 1)))
     (lambda (n m slot ignored) (fpm-lim-set! m (nursery-alloc-ptr n)))
     (lambda (n m slot ignored)
       (when (nursery-overflow? (fpm-lim m) (fpm-p1 m)) (fpm-slow-set! m #t)))
     (lambda (n m slot ignored) (nursery-rs-ptr-set! n (fpm-p1 m)))
     (lambda (n m slot ignored)
       (heap-set! n (fpm-p1 m) slot)
       (fpm-dst-set! m (fpm-p1 m)))))

  ;; The regions. Half-open, and both END one step before the sequence does,
  ;; because the last step of each is a register write with nothing to redo and
  ;; the object is already valid by then.
  (define alloc-region (make-region 'alloc-claim-then-fill alloc-base (+ alloc-base 6)))
  (define rs-region (make-region 'remembered-set-push rs-base (+ rs-base 6)))

  ;; preempt.ss refuses overlap, so building the table is itself the check that
  ;; these two windows are distinct code.
  (define alloc-region-table
    (region-table-add! (region-table-add! (make-region-table) alloc-region)
                       rs-region))

  ;; The emitted shape, for anyone who wants to assert on it (poll-freedom, for
  ;; instance) without running it.
  (define (alloc-fast-path)
    '((load  p    (thread alloc-ptr))
      (add   p1   p size)
      (load  lim  (thread rs-ptr))
      (bgt   p1   lim slow)
      (store (thread alloc-ptr) p1)
      (store (mem p 0) header)
      (move  dst  p)))

  (define (rs-push-path)
    '((load  r    (thread rs-ptr))
      (sub   r1   r 1)
      (load  a    (thread alloc-ptr))
      (bgt   a    r1 slow)
      (store (thread rs-ptr) r1)
      (store (mem r1 0) slot)))

  (define (alloc-fast-path-mnemonics) (map car (alloc-fast-path)))
  (define (rs-push-path-mnemonics) (map car (rs-push-path)))

  ;; --- the interpreter ------------------------------------------------------
  ;;
  ;; `interrupt-at`, when it is a PC, is the collector stopping this thread
  ;; there exactly once. What happens next is not negotiated with the thread:
  ;; the saved PC goes through `rewind-pc` and execution resumes at whatever
  ;; comes back. Outside a region that is the same PC and nothing happened.

  (define (run-steps steps base n m a b interrupt-at)
    (let ((count (vector-length steps)))
      (let loop ((pc base) (fired #f))
        (cond
         ((fpm-slow m) #f)
         ((= pc (+ base count)) (fpm-dst m))
         ((and interrupt-at (not fired) (= pc interrupt-at))
          (loop (rewind-pc alloc-region-table pc) #t))
         (else
          ((vector-ref steps (- pc base)) n m a b)
          (loop (+ pc 1) fired))))))

  ;; Returns the address of the new object, or #f meaning take the slow path.
  (define (run-alloc n size hdr interrupt-at)
    (run-steps (alloc-steps) alloc-base n (fresh-fpm) size hdr interrupt-at))

  (define (run-rs-push n slot interrupt-at)
    (run-steps (rs-steps) rs-base n (fresh-fpm) slot #f interrupt-at))

  ;; --- the slow path --------------------------------------------------------
  ;;
  ;; Not inlined, not on the hot path, and the only place that can fail. The
  ;; collector runs with its reserve intact by construction, so if it still
  ;; cannot satisfy the request the program gets a condition it can handle.
  (define (nursery-alloc! n size hdr)
    (or (run-alloc n size hdr #f)
        (let ((c (nursery-collector n)))
          (when c (c n))
          (or (and c (run-alloc n size hdr #f))
              (raise (make-heap-exhausted n size))))))

  (define (nursery-rs-push! n slot)
    (or (run-rs-push n slot #f)
        (let ((c (nursery-collector n)))
          (when c (c n))
          (or (and c (run-rs-push n slot #f))
              (raise (make-heap-exhausted n 1))))))
  )
