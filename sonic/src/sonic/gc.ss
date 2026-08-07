;;; Precise generational copying collector.
;;;
;;; E7, bead 6cm.5. Two generations, bump allocation in the nursery, Cheney scan
;;; on collection, and roots taken from `gcmeta.ss`'s stack maps rather than
;;; guessed from the stack's contents.
;;;
;;; Written in Scheme, and that is not a modelling convenience. Per D25 the
;;; runtime IS Scheme: there is no libc anywhere in the running system and
;;; nothing here calls out to one. This library stands to the emitted collector
;;; exactly as `numeric.ss` stands to the emitted arithmetic and `alloc.ss` to
;;; the emitted fast path. A later bead lowers it; what it lowers is these
;;; steps, in this order, over this object layout.
;;;
;;; ## Not Boehm, and the number is in the record
;;;
;;; `docs/RESEARCH.md` section 3 is where Stalin loses 5x to 16x to C on
;;; allocation-heavy code, and the cause is its conservative Boehm collector,
;;; not its analysis. Stalin has the most aggressive whole-program analysis
;;; anyone has shipped for Scheme and it still loses there, which is the whole
;;; argument: you cannot analyse your way out of a collector that has to assume
;;; every machine word might be a pointer. A conservative collector cannot move
;;; an object, because it cannot tell a pointer it must update from an integer
;;; it must not; not moving means no bump allocation, no compaction, and a free
;;; list on the hot path.
;;;
;;; Precision is what buys all three back, and D21 is what makes precision
;;; affordable: PC-total metadata for the stack, a static register partition for
;;; the registers, and therefore no shadow stack. We own the frame layout, so
;;; there is nothing to shadow.
;;;
;;; ## What precise means here, operationally
;;;
;;; At any PC, three questions have exact answers:
;;;
;;;   - Which stack slots hold tagged values? `gcmeta.ss`'s frame bitvector at
;;;     the last entry at or before the PC. The metadata is TOTAL over the PC,
;;;     so there is no such thing as being stopped somewhere with no answer.
;;;   - Which registers hold tagged values? The VALUE class, always, plus
;;;     whichever scratch registers the `scratch-live` flag names. `regs.ss`
;;;     enforces that a tagged value can never be allocated outside the value
;;;     class, so this needs no per-PC bitmap at all.
;;;   - Which old-space slots point into the nursery? The remembered set, after
;;;     the collector filters it. See the barrier below.
;;;
;;; Everything else is NOT a root. A raw register holding an integer that
;;; happens to have a pointer's bit pattern is not scanned, not traced and not
;;; updated, and the object it appears to name is collected. That sentence is
;;; the entire content of "precise", and `gc-test.ss` asserts it directly by
;;; building a state a conservative scan demonstrably retains and showing this
;;; collector reclaims it.
;;;
;;; ## The write barrier, and what is deliberately absent from it
;;;
;;; From `docs/phases/07-compiler/EXECUTION.md` E7, copied rather than invented:
;;; store the value, test ONE tag field on the value, and push the slot address
;;; if it is not a fixnum. That is all. The mutator does NOT check which
;;; generation the object is in, does NOT read a segment table, and does NOT
;;; look at the stored pointer's target. Every one of those filters is deferred
;;; to collection time, where it runs once over a batch instead of once per
;;; store.
;;;
;;; The cost is about ten instructions per pointer store and `barrier-path`
;;; below is exactly ten, of which the last six ARE `alloc.ss`'s
;;; `rs-push-path`, spliced in rather than restated. That splice is the second
;;; copied mechanism: the allocation check IS the remembered-set overflow check,
;;; because the allocation pointer grows up from the nursery base and the
;;; remembered-set pointer grows down from the top of the same region. One
;;; comparison, two consumers, and the barrier gets its bound check for free.
;;; `alloc.ss` already implements it, so this file wires into it and adds no
;;; second limit anywhere.
;;;
;;; One honest note on "test one tag bit". `numeric.ss` fixes a THREE-bit
;;; primary tag with fixnum = 000, so the test is against a 3-bit mask rather
;;; than a single bit. It is still one instruction on both targets (`test r, 7`
;;; / `andi t, r, 7`), and the expensive thing the design avoids is the
;;; generation check, not the second bit of the mask.
;;;
;;; ## Two orderings inside the barrier that are not arbitrary
;;;
;;; The store comes FIRST, before the filter. The push can overflow the buffer,
;;; the overflow drives a collection through `alloc.ss`'s slow path, and the
;;; collector must see the new value already in the slot or it will trace the
;;; old one.
;;;
;;; And a slot address recorded before a collection may name a nursery object
;;; that has since moved. That is safe, not lucky: the collector honours a
;;; remembered entry only when the SLOT is in old space, and old objects do not
;;; move in a minor collection. A stale nursery slot address is dropped by the
;;; same filter that drops nursery-to-nursery stores, which is one more reason
;;; the filtering belongs at collection time.
;;;
;;; ## Reserving the collection worst case up front
;;;
;;; The third copied mechanism. Two reserves, for two different failures.
;;;
;;; TO-SPACE is reserved by refusing to start. A minor collection promotes
;;; survivors into old space and in the limit everything survives, so the worst
;;; case is the whole mutator-usable nursery. `gc-reserve-ok?` asks whether old
;;; space can absorb that BEFORE a single object is copied, so the collector
;;; either runs to completion or does not begin. There is no state in which it
;;; has half-copied the heap and run out.
;;;
;;; THE CONDITION OBJECT is reserved inside the nursery, and this is what
;;; `alloc.ss`'s `reserve` is for. Heap exhaustion has to surface as a Scheme
;;; condition a program can catch, per the bundle's finding that this is the
;;; only thing that separates the systems that survive it from Linux, Chez and
;;; Mirage, which all die. A condition is a heap object. Allocating one at the
;;; moment the heap is full is exactly the circularity that turns a recoverable
;;; error into an abort, so the words come from the reserve, which the mutator's
;;; comparison can never reach. Note that Cheney itself needs no auxiliary
;;; storage at all -- the to-space IS the work queue -- so the condition is the
;;; only thing the reserve is ever asked for.
;;;
;;; ## The object layout
;;;
;;; Word-addressed, matching `alloc.ss`. An object is a header word followed by
;;; its fields. The header states how many fields there are and which of them
;;; are TAGGED, which is what lets an flvector's payload be raw f64 bits that
;;; the collector never looks at -- the same fact `fixtures.ss` records when it
;;; notes nbody's inner loop carries no GC metadata at all.
;;;
;;; A copied object's header slot is overwritten with a forwarding record. The
;;; collector never parses the nursery linearly, which is what makes the
;;; abandoned headerless block from `alloc.ss`'s restart region free rather than
;;; fatal: an unreferenced block is simply never reached.

(library (sonic gc)
  (export ;; word encoding
          gc-tag-bits gc-tag-mask gc-fixnum-tag gc-pointer-tag
          word-fixnum word-pointer fixnum-word? pointer-word? word->addr

          ;; objects
          make-hdr hdr? hdr-kind hdr-fields hdr-traced
          tagged-hdr raw-hdr
          forward? forward-addr

          ;; the heap
          make-gc-heap gc-heap? gc-heap-nursery
          gc-heap-old-base gc-heap-old-limit gc-heap-old-free
          gc-nursery-addr? gc-old-addr?
          gc-ref gc-set! gc-alloc! gc-header gc-field-ref gc-field-set!
          gc-old-used gc-nursery-used

          ;; the barrier
          gc-store! barrier-path barrier-mnemonics
          barrier-generation-check-free? barrier-tests-only-the-value?

          ;; machine state and precise roots
          make-regfile regfile? regfile-value regfile-raw regfile-float
          regfile-scratch fresh-regfile
          make-frame frame? frame-entries frame-base frame-slots
          frame-pc frame-pc-set!
          make-thread-state thread-state? thread-state-target
          thread-state-stack thread-state-regs thread-state-frames
          thread-state-regions
          make-slot slot? slot-name slot-ref slot-set!
          precise-roots scratch-live-indices gc-rewind!

          ;; the collector
          gc-collect! gc-install! gc-forward!
          gc-worst-case gc-reserve-ok? gc-condition-words
          remembered-entries
          gc-stats? gc-stats-copied gc-stats-words
          gc-stats-remembered gc-stats-honoured gc-stats-dropped)
  (import (chezscheme)
          (sonic alloc)
          (sonic gcmeta)
          (sonic preempt))

  ;; --- word encoding --------------------------------------------------------
  ;;
  ;; `numeric.ss` fixes the tag: 64-bit word, 3-bit primary tag, fixnum = 000.
  ;; Heap objects are 8-byte aligned so the low three bits of a pointer are free
  ;; whether we use them or not. We give pointers tag 001.
  ;;
  ;; Addresses here are WORD indices, as in `alloc.ss`, and a pointer word is
  ;; the address shifted left by the tag width with the tag or'ed in. That is
  ;; the same shape a byte-addressed image has and it matters for the tests: a
  ;; pointer is an ordinary integer, indistinguishable at the bit level from a
  ;; raw integer of the same value, which is precisely the ambiguity a
  ;; conservative collector cannot resolve and a precise one never faces.

  (define gc-tag-bits 3)
  (define gc-tag-mask 7)
  (define gc-fixnum-tag 0)
  (define gc-pointer-tag 1)

  (define (word-fixnum v) (bitwise-arithmetic-shift-left v gc-tag-bits))
  (define (word-pointer a)
    (bitwise-ior (bitwise-arithmetic-shift-left a gc-tag-bits) gc-pointer-tag))
  (define (word->addr w) (bitwise-arithmetic-shift-right w gc-tag-bits))

  ;; THE test the barrier performs, and the only one it performs.
  (define (fixnum-word? w)
    (and (integer? w) (exact? w) (= gc-fixnum-tag (bitwise-and w gc-tag-mask))))

  (define (pointer-word? w)
    (and (integer? w) (exact? w) (= gc-pointer-tag (bitwise-and w gc-tag-mask))))

  ;; --- objects --------------------------------------------------------------
  ;;
  ;; `traced` is a per-field list of booleans rather than a single flag because
  ;; the two cases that matter differ: a vector's fields are all tagged and an
  ;; flvector's are all raw f64 bits. A collector that traced an flvector's
  ;; payload would scavenge doubles as pointers, which is the corruption
  ;; `regs.ss` refuses in the register file, one level down in memory.

  (define-record-type (hdr make-hdr hdr?)
    (fields kind fields traced))

  (define (tagged-hdr kind n) (make-hdr kind n (make-list n #t)))
  (define (raw-hdr kind n) (make-hdr kind n (make-list n #f)))

  ;; A copied object's header is replaced by this. It is a distinct record type
  ;; and not an encoded word, so mistaking one for a header is impossible rather
  ;; than merely unlikely.
  (define-record-type (forward make-forward forward?)
    (fields addr))

  ;; --- the heap -------------------------------------------------------------
  ;;
  ;;   [ nursery: generation 0, bump allocated ][ old: generation 1, to-space ]
  ;;   0                        nursery-top     old-base            old-limit
  ;;
  ;; One address space with two ranges, which is how a real image tells them
  ;; apart and why `gc-nursery-addr?` is a range test rather than a table
  ;; lookup. The nursery is `alloc.ss`'s, unmodified: this file installs itself
  ;; as its collector rather than reimplementing its pointers.

  (define-record-type (gc-heap mk-gc-heap gc-heap?)
    (fields nursery old-mem old-base old-limit (mutable old-free)))

  (define (make-gc-heap nursery-words reserve old-words)
    (let ((n (make-nursery nursery-words reserve)))
      (mk-gc-heap n (make-vector old-words 0)
                  nursery-words (+ nursery-words old-words) nursery-words)))

  (define (gc-nursery-addr? h a)
    (and (>= a (nursery-base (gc-heap-nursery h)))
         (< a (nursery-top (gc-heap-nursery h)))))

  (define (gc-old-addr? h a)
    (and (>= a (gc-heap-old-base h)) (< a (gc-heap-old-limit h))))

  (define (gc-ref h a)
    (if (gc-nursery-addr? h a)
        (heap-ref (gc-heap-nursery h) a)
        (vector-ref (gc-heap-old-mem h) (- a (gc-heap-old-base h)))))

  (define (gc-set! h a v)
    (if (gc-nursery-addr? h a)
        (heap-set! (gc-heap-nursery h) a v)
        (vector-set! (gc-heap-old-mem h) (- a (gc-heap-old-base h)) v)))

  (define (gc-old-used h) (- (gc-heap-old-free h) (gc-heap-old-base h)))
  (define (gc-nursery-used h)
    (let ((n (gc-heap-nursery h))) (- (nursery-alloc-ptr n) (nursery-base n))))

  ;; Allocate in the nursery through `alloc.ss`'s fast path and return a TAGGED
  ;; word. The mutator deals in words; addresses appear only inside this file.
  (define (gc-alloc! h header inits)
    (let* ((n (gc-heap-nursery h))
           (nf (hdr-fields header))
           (a (nursery-alloc! n (+ 1 nf) header)))
      (let loop ((i 0) (v inits))
        (when (< i nf)
          (heap-set! n (+ a 1 i) (if (pair? v) (car v) (word-fixnum 0)))
          (loop (+ i 1) (if (pair? v) (cdr v) '()))))
      (word-pointer a)))

  (define (gc-header h w) (gc-ref h (word->addr w)))
  (define (gc-field-ref h w i) (gc-ref h (+ (word->addr w) 1 i)))
  ;; The RAW store, with no barrier. The collector uses it, and so does any test
  ;; that wants to show what happens without one.
  (define (gc-field-set! h w i v) (gc-set! h (+ (word->addr w) 1 i) v))

  ;; --- the write barrier ----------------------------------------------------

  ;; Ten instructions. The first four are the barrier proper; the last six are
  ;; `alloc.ss`'s remembered-set push, SPLICED rather than restated, so the
  ;; aliased comparison cannot drift apart from the one the allocator uses.
  (define (barrier-path)
    (append
     '((store (mem obj off) val)      ; commit the store FIRST
       (and   t   val tag-mask)       ; ONE test, on the VALUE's primary tag
       (beq   t   zero done)          ; a fixnum records nothing
       (add   sl  obj off))           ; the SLOT address, which is what we push
     (rs-push-path)))

  (define (barrier-mnemonics) (map car (barrier-path)))

  ;; The absence that makes the barrier cheap, as a predicate. Every load in the
  ;; barrier reads the thread block; there is no segment-table load, no
  ;; generation word, and nothing derived from the OBJECT's address. If a load
  ;; from anywhere else ever appears here, the batched-filtering design is gone
  ;; and the barrier's cost has moved.
  (define (barrier-generation-check-free? path)
    (for-all (lambda (i)
               (or (not (eq? (car i) 'load))
                   (let ((src (caddr i))) (and (pair? src) (eq? (car src) 'thread)))))
             path))

  ;; And the one test it does perform is on the stored VALUE, never on the
  ;; object being stored into. Testing the object is how a generation check
  ;; sneaks back in wearing a tag test's clothes.
  (define (barrier-tests-only-the-value? path)
    (let loop ((is path))
      (cond ((null? is) #t)
            ((eq? (car (car is)) 'and)
             (and (eq? 'val (caddr (car is))) (loop (cdr is))))
            (else (loop (cdr is))))))

  ;; The barrier, executed. Store, test, push. Nothing else.
  (define (gc-store! h w i v)
    (let ((slot (+ (word->addr w) 1 i)))
      (gc-set! h slot v)
      (unless (fixnum-word? v)
        (nursery-rs-push! (gc-heap-nursery h) slot))))

  ;; --- machine state --------------------------------------------------------
  ;;
  ;; What the collector reads out of a thread it stopped. No shadow stack and no
  ;; handle table: we own the frame layout, so the stack IS the root map once
  ;; the metadata says which slots to believe.

  (define-record-type (regfile make-regfile regfile?)
    (fields value raw float scratch))

  (define (fresh-regfile nv nr nf ns)
    (make-regfile (make-vector nv (word-fixnum 0))
                  (make-vector nr (word-fixnum 0))
                  (make-vector nf (word-fixnum 0))
                  (make-vector ns (word-fixnum 0))))

  (define-record-type (frame make-frame frame?)
    (fields entries base slots (mutable pc)))

  (define-record-type (thread-state make-thread-state thread-state?)
    ;; `frames` is innermost first. `regions` is a preempt.ss region table.
    (fields target stack regs frames regions))

  ;; A root is a LOCATION, not a value: the collector has to write the forwarded
  ;; pointer back or the mutator resumes pointing at from-space.
  (define-record-type (slot make-slot slot?)
    (fields name get set))

  (define (slot-ref s) ((slot-get s)))
  (define (slot-set! s v) ((slot-set s) v))

  (define (vector-slot name v i)
    (make-slot name (lambda () (vector-ref v i)) (lambda (x) (vector-set! v i x))))

  ;; `scratch-live` means a RAW register is transiently holding a TAGGED value
  ;; during a calling sequence, per gc-metadata.md. Its ENCODING differs by
  ;; target and there is no shared enum, which is the whole reason `gcmeta.ss`
  ;; keys flag names off the target: x86-64 spends 2 bits on a strict nesting
  ;; COUNT, RV64 spends 3 on a BITMAP. Reading one as the other silently
  ;; scavenges the wrong registers, so the two are decoded separately here and
  ;; an unknown target is an error rather than a default.
  (define (scratch-live-indices target v)
    (case (target-name target)
      ((x86-64) (let loop ((i 0) (acc '())) (if (>= i v) (reverse acc) (loop (+ i 1) (cons i acc)))))
      ((rv64) (let loop ((i 0) (acc '()))
                (if (>= (bitwise-arithmetic-shift-right v i) 1)
                    (loop (+ i 1)
                          (if (odd? (bitwise-arithmetic-shift-right v i)) (cons i acc) acc))
                    (reverse acc))))
      (else (error 'scratch-live-indices "no scratch-live encoding for target"
                   (target-name target)))))

  (define (flag entry name)
    (let ((p (assq name (entry-flags entry)))) (if p (cdr p) 0)))

  ;; The thread was stopped wherever it happened to be, which per D21 may be
  ;; inside the allocator's claim-then-fill window. Rewinding is the COLLECTOR's
  ;; job -- the mutator never polls, cooperates or knows -- and it happens before
  ;; the metadata is read, because the metadata at the rewound PC is the one
  ;; describing the state the thread will resume in.
  ;;
  ;; Only the innermost frame can be inside a region. Every frame below it is
  ;; stopped at a call, and a call is not inside an allocation sequence.
  (define (gc-rewind! st)
    (let ((fs (thread-state-frames st)))
      (unless (null? fs)
        (let ((f (car fs)))
          (frame-pc-set! f (rewind-pc (thread-state-regions st) (frame-pc f)))))))

  ;; THE root set. Read the three sources and what is missing from them.
  (define (precise-roots st)
    (let ((regs (thread-state-regs st))
          (stack (thread-state-stack st))
          (frames (thread-state-frames st)))
      (append
       ;; 1. The value class, unconditionally, consulting NO metadata. This is
       ;;    the half of D21 that the static register partition buys: because
       ;;    `regs.ss` refuses to place a tagged value anywhere else, there is
       ;;    no register bitmap in the metadata at all.
       (let loop ((i 0) (acc '()))
         (if (>= i (vector-length (regfile-value regs)))
             (reverse acc)
             (loop (+ i 1) (cons (vector-slot (cons 'value i) (regfile-value regs) i) acc))))
       ;; 2. The scratch registers the innermost frame's flag names, and only
       ;;    those. Registers are global state, so only the interrupted PC
       ;;    describes them; an outer frame's flags describe a moment that has
       ;;    already passed.
       (if (null? frames)
           '()
           (let* ((f (car frames))
                  (e (lookup! f))
                  (v (flag e 'scratch-live)))
             (map (lambda (i) (vector-slot (cons 'scratch i) (regfile-scratch regs) i))
                  (scratch-live-indices (thread-state-target st) v))))
       ;; 3. The stack slots each frame's bitvector marks. NOT every slot: that
       ;;    is the difference this file exists to make.
       (let frames-loop ((fs frames) (acc '()))
         (if (null? fs)
             (reverse acc)
             (let* ((f (car fs))
                    (e (lookup! f))
                    (bits (entry-frame-bits e)))
               (frames-loop
                (cdr fs)
                (let bit-loop ((bs bits) (i 0) (acc acc))
                  (cond ((null? bs) acc)
                        ((car bs)
                         (bit-loop (cdr bs) (+ i 1)
                                   (cons (vector-slot (cons 'stack (+ (frame-base f) i))
                                                      stack (+ (frame-base f) i))
                                         acc)))
                        (else (bit-loop (cdr bs) (+ i 1) acc))))))))
       ;; And nothing else. The raw and float register files are not here, and
       ;; no stack slot outside a set bit is here.
       '())))

  ;; The metadata is TOTAL over the PC: every offset in every function has an
  ;; answer, obtained by taking the last entry at or before it. A PC with no
  ;; answer means the function's metadata does not cover its own code, which is
  ;; a compiler bug and not something to paper over with a conservative scan of
  ;; the frame. Fail loudly.
  (define (lookup! f)
    (let ((e (metadata-lookup (frame-entries f) (frame-pc f))))
      (unless e
        (error 'precise-roots
               "no GC metadata at this PC; the metadata is supposed to be total"
               (frame-pc f)))
      e))

  ;; --- the remembered set ---------------------------------------------------
  ;;
  ;; The buffer occupies [rs-ptr, reserve-base), grown downward by the barrier.
  ;; Its contents are slot ADDRESSES and it is deliberately unfiltered: the
  ;; mutator pushed every non-fixnum store it made, including nursery-to-nursery
  ;; ones, duplicates, and slots in objects that have since moved.
  (define (remembered-entries h)
    (let ((n (gc-heap-nursery h)))
      (let loop ((p (nursery-rs-ptr n)) (acc '()))
        (if (>= p (reserve-base n))
            (reverse acc)
            (loop (+ p 1) (cons (heap-ref n p) acc))))))

  ;; --- statistics -----------------------------------------------------------
  ;; Enough to assert on. `honoured` and `dropped` are what make the deferred
  ;; filter visible: the mutator's ten instructions push everything, and these
  ;; two numbers are where the sorting actually happened.
  (define-record-type (gc-stats mk-stats gc-stats?)
    (fields copied words remembered honoured dropped))

  ;; --- the collector --------------------------------------------------------

  ;; The worst case a minor collection can need in to-space: everything the
  ;; mutator could have allocated survives. Reserving against this rather than
  ;; against an estimate is what makes the collection all-or-nothing.
  (define (gc-worst-case h)
    (let ((n (gc-heap-nursery h))) (- (reserve-base n) (nursery-base n))))

  (define (gc-reserve-ok? h)
    (<= (+ (gc-heap-old-free h) (gc-worst-case h)) (gc-heap-old-limit h)))

  ;; Header plus two fields. Small, fixed, and claimed from `alloc.ss`'s reserve
  ;; rather than from anywhere the mutator's comparison can reach.
  (define gc-condition-words 3)

  (define (old-claim! h words)
    (let ((p (gc-heap-old-free h)))
      (if (> (+ p words) (gc-heap-old-limit h))
          ;; Unreachable: gc-reserve-ok? already proved the room exists. If the
          ;; argument is wrong, say so here rather than scribbling past the end.
          (error 'gc-collect! "to-space overflowed after the reserve check passed"
                 p words (gc-heap-old-limit h))
          (begin (gc-heap-old-free-set! h (+ p words)) p))))

  (define (raise-exhausted! h)
    (let* ((n (gc-heap-nursery h))
           (p (reserve-claim! n gc-condition-words)))
      ;; Build the condition object in the reserve. Allocating it from the space
      ;; we just failed to find would be the circularity that turns a
      ;; recoverable error into an abort.
      (when p
        (heap-set! n p (raw-hdr 'heap-exhausted 2))
        (heap-set! n (+ p 1) (word-fixnum (gc-worst-case h)))
        (heap-set! n (+ p 2) (word-fixnum (gc-old-used h))))
      (raise (make-heap-exhausted n (gc-worst-case h)))))

  ;; Copy one word's referent into to-space if it is a nursery object, and
  ;; return the word the referrer should now hold. Idempotent through the
  ;; forwarding record, which is what makes shared structure stay shared and
  ;; cycles terminate.
  (define (gc-forward! h w)
    (cond
     ;; Not a pointer: a fixnum, or raw f64 bits, or anything else. Returned
     ;; unchanged and never dereferenced. This one line is why a raw word with a
     ;; pointer's bit pattern is harmless -- the collector is never handed it.
     ((not (pointer-word? w)) w)
     (else
      (let ((a (word->addr w)))
        (cond
         ;; Already in old space. A minor collection does not move old objects,
         ;; so the word is already right.
         ((not (gc-nursery-addr? h a)) w)
         (else
          (let ((head (gc-ref h a)))
            (cond
             ((forward? head) (word-pointer (forward-addr head)))
             ((not (hdr? head))
              ;; Reached an address with no header. Under precise roots this
              ;; cannot happen from a real reference; it is what a conservative
              ;; scan hits when it follows an integer, and what an interior
              ;; pointer hits. Refuse rather than invent a size.
              (error 'gc-forward! "no object header at this address" a head))
             (else
              (let* ((nf (hdr-fields head))
                     (dst (old-claim! h (+ 1 nf))))
                (gc-set! h dst head)
                (let loop ((i 0))
                  (when (< i nf)
                    (gc-set! h (+ dst 1 i) (gc-ref h (+ a 1 i)))
                    (loop (+ i 1))))
                ;; From-space header becomes the forwarding record. Anything
                ;; else pointing here finds it and shares the copy.
                (gc-set! h a (make-forward dst))
                (word-pointer dst)))))))))))

  (define (gc-collect! h st)
    (let ((n (gc-heap-nursery h)))
      ;; The thread was stopped wherever it was. Rewind first, then believe the
      ;; metadata at the PC it will resume from.
      (gc-rewind! st)
      ;; RESERVE THE WORST CASE UP FRONT. Either the collection can finish or it
      ;; never starts; there is no half-copied state to recover from.
      (unless (gc-reserve-ok? h) (raise-exhausted! h))
      (let ((copy-start (gc-heap-old-free h))
            (honoured 0)
            (dropped 0)
            (remembered (remembered-entries h))
            (copied 0))
        ;; 1. Precise roots.
        (for-each (lambda (s) (slot-set! s (gc-forward! h (slot-ref s))))
                  (precise-roots st))
        ;; 2. The remembered set, filtered HERE. The mutator pushed everything;
        ;;    this is where the generation check it never made gets made, once,
        ;;    over a batch.
        (for-each
         (lambda (slot-addr)
           (if (and (integer? slot-addr)
                    (gc-old-addr? h slot-addr)
                    (pointer-word? (gc-ref h slot-addr))
                    (gc-nursery-addr? h (word->addr (gc-ref h slot-addr))))
               (begin (set! honoured (+ honoured 1))
                      (gc-set! h slot-addr (gc-forward! h (gc-ref h slot-addr))))
               (set! dropped (+ dropped 1))))
         remembered)
        ;; 3. Cheney. The to-space region between where copying started and
        ;;    where it has reached IS the work queue, so there is no auxiliary
        ;;    stack and no recursion depth to bound.
        (let loop ((scan copy-start))
          (when (< scan (gc-heap-old-free h))
            (let ((head (gc-ref h scan)))
              (unless (hdr? head)
                (error 'gc-collect! "to-space is not parseable at" scan head))
              (set! copied (+ copied 1))
              (let field-loop ((i 0) (ts (hdr-traced head)))
                (unless (null? ts)
                  (when (car ts)
                    (gc-set! h (+ scan 1 i) (gc-forward! h (gc-ref h (+ scan 1 i)))))
                  (field-loop (+ i 1) (cdr ts))))
              (loop (+ scan 1 (hdr-fields head))))))
        ;; 4. The nursery is now empty, and so is the store buffer. Everything
        ;;    that was not copied is reclaimed by this one assignment, which is
        ;;    the whole economics of a copying collector: the cost is
        ;;    proportional to what SURVIVED, not to what died.
        (nursery-alloc-ptr-set! n (nursery-base n))
        (nursery-rs-ptr-set! n (reserve-base n))
        (mk-stats copied (- (gc-heap-old-free h) copy-start)
                  (length remembered) honoured dropped))))

  ;; Wire into `alloc.ss`'s slow path. `get-state` is a thunk because the
  ;; collector reads whatever the thread's registers and frames hold at the
  ;; moment it was stopped, which is not known when the collector is installed.
  (define (gc-install! h get-state)
    (nursery-collector-set! (gc-heap-nursery h)
                            (lambda (n) (gc-collect! h (get-state)))))
  )
