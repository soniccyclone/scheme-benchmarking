;;; Linear-scan register allocation, enforcing the partition.
;;;
;;; E2-RA. Poletto and Sarkar's linear scan, with one addition that is the whole
;;; reason this bead is P0: **every assignment is checked against the register
;;; partition** (sonic/src/sonic/regs.ss).
;;;
;;; A tagged value reaching a raw register is a root the collector will never
;;; find, because under D21 the collector scavenges the value class
;;; unconditionally and consults no metadata. That is silent memory corruption,
;;; not a slow program, so the allocator raises rather than warning.
;;;
;;; Linear scan rather than graph colouring on purpose. Chaitin-style colouring
;;; buys maybe a few percent on straight-line numeric code and costs a
;;; build-coalesce-spill loop whose spill heuristic Chaitin's own prose and SETL
;;; appendix disagree about. The partition already fragments the register file,
;;; which is the thing colouring is best at exploiting, so the return is smaller
;;; here than usual.

(library (sonic regalloc)
  (export allocate live-intervals live-intervals/arch physical? label-operand?
          allocate-program allocate-functions live-intervals/cfg
          partition-into-functions call-positions
          instr-def instr-uses transfer-uses transfer-targets
          make-alloc-result alloc-result? alloc-result-map
          alloc-result-spills alloc-result-arch)
  (import (chezscheme)
          (sonic regs))

  (define-record-type (alloc-result make-alloc-result alloc-result?)
    (fields arch map spills))

  ;; --- live intervals -------------------------------------------------------
  ;; A linear pass over a flat instruction list. Each vreg gets [first-def,
  ;; last-use]. Straight-line only, which is what a basic block is; extending to
  ;; a whole CFG is a later bead and needs the loop structure from E4-LOOP so a
  ;; vreg live across a back edge stays live to the end of the loop.

  (define (for-each-indexed f xs)
    (let loop ([xs xs] [k 0])
      (unless (null? xs) (f (car xs) k) (loop (cdr xs) (+ k 1)))))

  (define (live-intervals instrs) (live-intervals/arch instrs #f))

  (define (live-intervals/arch instrs arch)
    ;; instrs: list of (op dst sc src ...) with dst possibly #f
    (let ([tbl (make-eq-hashtable)])
      (let loop ([is instrs] [i 0])
        (unless (null? is)
          (let* ([ins (car is)]
                 [dst (cadr ins)]
                 [srcs (cdddr ins)])
            (when (and (symbol? dst) (not (and arch (physical? arch dst))))
              (let ([e (hashtable-ref tbl dst #f)])
                (if e
                    (set-cdr! e (max (cdr e) i))
                    (hashtable-set! tbl dst (cons i i)))))
            (for-each-indexed
             (lambda (s k)
               (when (and (symbol? s)
                          (not (and arch (physical? arch s)))
                          (not (label-operand? ins k)))
                 (let ([e (hashtable-ref tbl s #f)])
                   (if e
                       (set-cdr! e (max (cdr e) i))
                       ;; A use with no prior def: live in from before this
                       ;; block. Start it at -1 so it sorts first and is never
                       ;; mistaken for a local temporary.
                       (hashtable-set! tbl s (cons -1 i))))))
             srcs))
          (loop (cdr is) (+ i 1))))
      ;; -> ((vreg start . end) ...) sorted by start
      (sort (lambda (a b) (< (cadr a) (cadr b)))
            (map (lambda (k)
                   (let ([e (hashtable-ref tbl k #f)])
                     (list k (car e) (cdr e))))
                 (vector->list (hashtable-keys tbl))))))

  ;; --- CFG-wide liveness ----------------------------------------------------
  ;;
  ;; The pass above is straight-line, and straight-line is WRONG for a loop.
  ;;
  ;; Take a vreg defined near the bottom of a loop body and used near the top on
  ;; the next iteration. Over a linear ordering of the blocks its last use comes
  ;; BEFORE its definition, so [first-def, last-use] is an empty or backwards
  ;; interval, the allocator expires it immediately, and the register is handed
  ;; to something else while the value is still needed on the back edge. That is
  ;; wrong code, it is silent, and it fires on every loop-carried value -- which
  ;; on nbody is every accumulator and every index.
  ;;
  ;; So liveness is computed over the CFG, by the standard backward dataflow:
  ;;
  ;;   live-out(B) = U live-in(S) for each successor S of B
  ;;   live-in(B)  = use(B) U (live-out(B) - def(B))
  ;;
  ;; where use(B) is the UPWARD-EXPOSED uses only: a use that a def earlier in
  ;; the same block already satisfies is not live in.
  ;;
  ;; Intervals then come from the linear order, taking for each vreg the extent
  ;; of every position at which it is live -- including the whole span of any
  ;; block it is merely live THROUGH. That is what pulls a loop-carried value's
  ;; interval across the back edge: it is live-out of the latch, live-in at the
  ;; header, and therefore live at every block of the body, so its interval
  ;; covers the loop.
  ;;
  ;; The result over-approximates: a vreg live in two separate regions gets one
  ;; interval spanning the gap. That costs registers and never correctness,
  ;; which is the right direction for a partition where the wrong answer is
  ;; memory corruption.

  ;; What each Lmach shape defines and uses. Lmach has three instruction
  ;; productions and three transfers, and only the first has a destination in
  ;; the slot a naive reader would assume:
  ;;
  ;;   (op v sc v* ...)     defines v, uses v*
  ;;   (const v sc d)       defines v, uses nothing -- d is a DATUM
  ;;   (chk pn c d v* ...)  defines NOTHING; pn is a check name and c a control
  ;;
  ;; Reading `chk`'s first slot as a destination is what made the allocator die
  ;; on "vreg has no storage class: bounds-check".
  (define (instr-def instr)
    (case (car instr)
      ((chk) #f)
      (else (and (symbol? (cadr instr)) (cadr instr)))))

  (define (instr-uses instr)
    (case (car instr)
      ((const) '())                       ; the datum is not an operand
      ((chk)   (filter symbol? (cdddr instr)))   ; skips the tag
      (else
       (let loop ((xs (cdddr instr)) (k 0) (acc '()))
         (if (null? xs)
             (reverse acc)
             (loop (cdr xs) (+ k 1)
                   (if (and (symbol? (car xs)) (not (label-operand? instr k)))
                       (cons (car xs) acc)
                       acc)))))))

  (define (transfer-uses t)
    (case (car t)
      ((branch-if) (if (symbol? (cadr t)) (list (cadr t)) '()))
      ((ret)       (if (and (pair? (cdr t)) (symbol? (cadr t))) (list (cadr t)) '()))
      (else '())))

  (define (transfer-targets t)
    (case (car t)
      ((jump)      (list (cadr t)))
      ((branch-if) (list (caddr t) (cadddr t)))
      (else '())))

  ;; blocks: ((lbl (block (i ...) t)) ...) in layout order.
  ;; Returns intervals in the same shape live-intervals/arch produces.
  (define (live-intervals/cfg blocks arch)
    (define (physical-or-label? x) (and arch (physical? arch x)))
    (define (keep xs) (filter (lambda (x) (not (physical-or-label? x))) xs))
    (define (block-of b) (cadr b))
    (define (block-instrs b) (cadr (block-of b)))
    (define (block-transfer b) (caddr (block-of b)))

    ;; local use/def, upward-exposed
    (define n (length blocks))
    (define use* (make-vector n '()))
    (define def* (make-vector n '()))
    (define in*  (make-vector n '()))
    (define out* (make-vector n '()))
    (define index-of (make-eq-hashtable))

    (for-each-indexed (lambda (b k) (hashtable-set! index-of (car b) k)) blocks)

    (for-each-indexed
     (lambda (b k)
       (let loop ((is (append (block-instrs b)
                              (list (cons 'transfer (block-transfer b)))))
                  (u '()) (d '()))
         (if (null? is)
             (begin (vector-set! use* k (reverse u)) (vector-set! def* k d))
             (let* ((i (car is))
                    (uses (if (eq? (car i) 'transfer)
                              (transfer-uses (cdr i))
                              (keep (instr-uses i))))
                    (dv (and (not (eq? (car i) 'transfer)) (instr-def i)))
                    (dv (and dv (not (physical-or-label? dv)) dv)))
               (loop (cdr is)
                     ;; upward-exposed: a use already satisfied by an earlier
                     ;; def in this block is not live in
                     (append u (filter (lambda (x) (and (not (memq x d))
                                                        (not (memq x u))))
                                       (keep uses)))
                     (if (and dv (not (memq dv d))) (cons dv d) d))))))
     blocks)

    ;; iterate to a fixpoint
    (let fix ()
      (let ((changed #f))
        (let loop ((k (- n 1)))
          (when (>= k 0)
            (let* ((b (list-ref blocks k))
                   (succs (filter values
                                  (map (lambda (l) (hashtable-ref index-of l #f))
                                       (transfer-targets (block-transfer b)))))
                   (out (fold-left (lambda (acc s)
                                     (union acc (vector-ref in* s)))
                                   '() succs))
                   (in (union (vector-ref use* k)
                              (difference out (vector-ref def* k)))))
              (unless (and (= (length out) (length (vector-ref out* k)))
                           (= (length in) (length (vector-ref in* k))))
                (set! changed #t))
              (vector-set! out* k out)
              (vector-set! in* k in))
            (loop (- k 1))))
        (when changed (fix))))

    ;; linearize and take, for each vreg, the extent of everywhere it is live
    (let ((tbl (make-eq-hashtable))
          (pos 0))
      (define (touch! v i)
        (let ((e (hashtable-ref tbl v #f)))
          (if e
              (begin (set-car! e (min (car e) i)) (set-cdr! e (max (cdr e) i)))
              (hashtable-set! tbl v (cons i i)))))
      (for-each-indexed
       (lambda (b k)
         (let ((start pos))
           ;; live-in covers the block from its first instruction
           (for-each (lambda (v) (touch! v start)) (vector-ref in* k))
           (for-each (lambda (i)
                       (let ((d (instr-def i)))
                         (when (and d (not (physical-or-label? d))) (touch! d pos)))
                       (for-each (lambda (v) (touch! v pos)) (keep (instr-uses i)))
                       (set! pos (+ pos 1)))
                     (block-instrs b))
           (for-each (lambda (v) (touch! v pos))
                     (keep (transfer-uses (block-transfer b))))
           ;; anything live OUT is live to the end of the block, even if this
           ;; block neither defined nor used it -- the loop case
           (for-each (lambda (v) (touch! v pos)) (vector-ref out* k))
           (set! pos (+ pos 1))))
       blocks)
      (sort (lambda (a b) (< (cadr a) (cadr b)))
            (map (lambda (k)
                   (let ((e (hashtable-ref tbl k #f)))
                     (list k (car e) (cdr e))))
                 (vector->list (hashtable-keys tbl))))))

  (define (union a b)
    (fold-left (lambda (acc x) (if (memq x acc) acc (cons x acc))) a b))
  (define (difference a b)
    (filter (lambda (x) (not (memq x b))) a))

  ;; --- function boundaries --------------------------------------------------
  ;;
  ;; Registers are a per-function resource. Running one linear scan over the
  ;; whole program makes every value in every procedure interfere with every
  ;; other, so a 41-block nbody spills a third of its virtuals for no reason:
  ;; two procedures that never run at the same time are told they cannot share
  ;; a register.
  ;;
  ;; Lmach's `(program ([lbl blk] ...) lbl)` is a flat block list and records no
  ;; function boundaries, but they are derivable and do not need a new IR slot.
  ;; A block is a function ENTRY exactly when something CALLS it -- as opposed
  ;; to jumping or branching to it, which are intraprocedural edges -- plus the
  ;; program's own entry. A function is then the blocks reachable from its entry
  ;; over jump and branch edges only.
  ;;
  ;; Blocks reachable from no entry are unreachable code and are returned as
  ;; their own group rather than dropped: dropping them here would hide a
  ;; lowering bug behind a smaller program.
  (define (call-targets blocks)
    (let ((acc '()))
      (for-each
       (lambda (b)
         (let walk ((x (cadr b)))
           (when (pair? x)
             (when (and (eq? (car x) 'call) (>= (length x) 4))
               ;; (call dst sc callee arg ...)
               (let ((callee (list-ref x 3)))
                 (when (and (symbol? callee) (not (memq callee acc)))
                   (set! acc (cons callee acc)))))
             (for-each walk x))))
       blocks)
      acc))

  ;; -> ((entry-label (lbl blk) ...) ...)
  (define (partition-into-functions blocks entry)
    (let* ((by-label (make-eq-hashtable))
           (labels (map car blocks))
           (entries (let ((cs (filter (lambda (l) (memq l labels))
                                      (call-targets blocks))))
                      (if (memq entry cs) cs (cons entry cs)))))
      (for-each (lambda (b) (hashtable-set! by-label (car b) b)) blocks)
      (let ((claimed (make-eq-hashtable))
            (out '()))
        (for-each
         (lambda (e)
           (let ((group '()))
             (let visit ((l e))
               (when (and (hashtable-ref by-label l #f)
                          (not (hashtable-ref claimed l #f)))
                 (hashtable-set! claimed l #t)
                 (let ((b (hashtable-ref by-label l #f)))
                   (set! group (cons b group))
                   (for-each visit (transfer-targets (caddr (cadr b)))))))
             (unless (null? group)
               (set! out (cons (cons e (reverse group)) out)))))
         entries)
        ;; Anything no entry reached.
        (let ((orphans (filter (lambda (b) (not (hashtable-ref claimed (car b) #f)))
                               blocks)))
          (reverse (if (null? orphans) out (cons (cons '<unreachable> orphans) out)))))))

  ;; Allocate each function independently. Returns
  ;;   ((entry-label . alloc-result) ...)
  ;; because two functions legitimately give the same vreg name different
  ;; registers, and one flat map could not express that.
  (define (allocate-functions arch blocks entry classes)
    (map (lambda (fn)
           (cons (car fn) (allocate-program arch (cdr fn) classes)))
         (partition-into-functions blocks entry)))

  ;; --- the scan -------------------------------------------------------------

  (define (pool-for arch sc)
    (case sc
      ((tagged)   (arch-value arch))
      ((raw-word) (arch-raw arch))
      ((raw-f64)  (arch-float arch))
      (else (error 'pool-for "unknown storage class" sc))))

  ;; A PHYSICAL register name in an operand slot is not a vreg, and the
  ;; allocator has to know the difference.
  ;;
  ;; The two-address fixup puts a scratch register (xmm15, t0) directly into an
  ;; operand, because the allocator runs over Lmach and never sees selected
  ;; output, so there is no vreg to request. Without this check `live-intervals`
  ;; treats that symbol as a virtual register and `allocate` either dies on
  ;; "vreg has no storage class" or -- far worse -- renames the scratch to an
  ;; allocatable register and silently emits wrong code for exactly the case the
  ;; fixup exists to handle.
  ;;
  ;; So: a name in ANY register class is skipped, not allocated. That subsumes
  ;; the adapter twoaddr.ss had to carry.
  (define (physical? arch r)
    (and (symbol? r) (reg-class arch r) #t))

  ;; A CALL's callee is a block label, not a virtual register.
  ;;
  ;; `physical?` skips register names and nothing skipped labels, so a call's
  ;; target was given a live interval and then allocated -- the allocator would
  ;; rewrite a branch target into a register name, which is a wrong-code bug and
  ;; not a slow one. Labels have no storage class either, so the more likely
  ;; symptom was `allocate` dying on "vreg has no storage class" and hiding the
  ;; real defect behind a confusing message.
  ;;
  ;; A call's first source is its callee. Everything after is an argument and is
  ;; an ordinary vreg.
  (define (label-operand? instr i)
    (and (pair? instr)
         (memq (car instr) '(call jump branch-if))
         (case (car instr)
           ((call) (= i 0))               ; (call dst sc callee arg ...)
           ((jump) (= i 0))               ; (jump lbl)
           ((branch-if) (>= i 1))         ; (branch-if v then else)
           (else #f))))

  ;; `classes` maps vreg -> storage class, which is what Lrepr carries.
  (define (allocate arch instrs classes)
    (allocate/intervals arch (live-intervals/arch instrs arch) classes))

  ;; Allocate over a whole CFG. This is what a real program goes through;
  ;; `allocate` remains for single-block fixtures.
  (define (allocate-program arch blocks classes)
    (allocate/intervals* arch (live-intervals/cfg blocks arch) classes
                         (call-positions blocks)))

  ;; The instruction positions at which a call happens, in the same numbering
  ;; `live-intervals/cfg` uses.
  ;;
  ;; A TAIL call is not one of these. It is a jump: control never comes back, so
  ;; nothing is live across it.
  (define (call-positions blocks)
    (let ((acc '()) (pos 0))
      (for-each
       (lambda (b)
         (let* ((blk (cadr b)) (instrs (cadr blk)) (t (caddr blk))
                (tail (and (pair? instrs)
                           (eq? (car t) 'ret)
                           (let ((last (car (reverse instrs))))
                             (and (eq? (car last) 'call)
                                  (eq? (cadr last) (cadr t))
                                  last)))))
           (for-each (lambda (i)
                       (when (and (eq? (car i) 'call) (not (eq? i tail)))
                         (set! acc (cons pos acc)))
                       (set! pos (+ pos 1)))
                     instrs)
           (set! pos (+ pos 1))))       ; the transfer occupies a position
       blocks)
      (reverse acc)))

  (define (allocate/intervals arch ivals classes)
    (allocate/intervals* arch ivals classes '()))

  ;; `calls` are positions where every allocatable register is destroyed.
  ;;
  ;; Our own convention saves nothing: a called function uses the whole pool.
  ;; So a value live ACROSS a call cannot stay in a register, and an allocator
  ;; that does not know this hands out a register that the callee overwrites --
  ;; which is not a slow program, it is a wrong one. nbody's `pos`, `vel` and
  ;; `mass` are exactly this: defined in the entry block, live across the calls
  ;; to `init!` and `offset-momentum!`, and clobbered by them. The first thing
  ;; downstream to notice was a type check, since what came back was no longer
  ;; a tagged pointer.
  ;;
  ;; Spilling them is the blunt answer and it is the right one here: designating
  ;; some registers callee-saved would need the prologue to know which the
  ;; function uses, and it would buy nothing in the loops, which contain no
  ;; calls -- every loop back edge is a TAIL call, which is a jump.
  (define (allocate/intervals* arch ivals classes calls)
    (let ((crosses-call?
           (lambda (iv)
             (exists (lambda (c) (and (< (cadr iv) c) (>= (caddr iv) c))) calls))))
      (allocate/scan arch ivals classes crosses-call?)))

  (define (allocate/scan arch ivals classes crosses-call?)
    (let* ([ivals ivals]
           [assign (make-eq-hashtable)]
           [spills '()]
           ;; free pools, one per storage class, kept disjoint by construction
           [free (make-eq-hashtable)])
      (for-each (lambda (sc) (hashtable-set! free sc (pool-for arch sc)))
                '(tagged raw-word raw-f64))
      (let scan ([is ivals] [active '()])
        (if (null? is)
            (make-alloc-result arch assign (reverse spills))
            (let* ([iv (car is)]
                   [v (car iv)] [start (cadr iv)]
                   [sc (let ([p (hashtable-ref classes v #f)])
                         (or p (error 'allocate "vreg has no storage class" v)))])
              ;; expire intervals that ended before this one starts
              (let ([still-active
                     (let expire ([as active] [keep '()])
                       (cond
                        [(null? as) (reverse keep)]
                        [(< (caddr (car as)) start)
                         (let* ([done (car as)]
                                [dv (car done)]
                                [dsc (hashtable-ref classes dv #f)]
                                [dr (hashtable-ref assign dv #f)])
                           (when dr
                             (hashtable-set! free dsc (cons dr (hashtable-ref free dsc '()))))
                           (expire (cdr as) keep))]
                        [else (expire (cdr as) (cons (car as) keep))]))])
                (if (crosses-call? iv)
                    ;; No register at all: a call destroys the whole pool, so
                    ;; this value has to live in the frame across it. Not the
                    ;; eviction path -- evicting someone else would still leave
                    ;; this one in a register the callee overwrites.
                    (begin
                      (set! spills (cons v spills))
                      (scan (cdr is) still-active))
                (let ([pool (hashtable-ref free sc '())])
                  (if (null? pool)
                      ;; SPILL. Poletto & Sarkar spill the active interval with
                      ;; the FURTHEST endpoint, which may be this one or one
                      ;; already holding a register.
                      ;;
                      ;; This used to always spill the current interval and
                      ;; never evict, and the difference is not marginal: one
                      ;; long-lived value hogging a register makes every short
                      ;; interval that begins while it is live spill, so nbody's
                      ;; inner loop spilled 30 values for a peak pressure of 8
                      ;; against 4 registers. Evicting the long one instead
                      ;; costs one spill and serves all of them.
                      ;;
                      ;; Only intervals of the SAME storage class are candidates.
                      ;; The partition is not a preference: taking a raw
                      ;; register from a tagged value would hide a GC root
                      ;; (regs.ss), so a class with no registers left cannot
                      ;; borrow from a class that has some.
                      (let* ([same (filter (lambda (a)
                                             (eq? (hashtable-ref classes (car a) #f) sc))
                                           still-active)]
                             [furthest (and (pair? same)
                                            (fold-left (lambda (best a)
                                                         (if (> (caddr a) (caddr best)) a best))
                                                       (car same) (cdr same)))])
                        (if (and furthest (> (caddr furthest) (caddr iv)))
                            ;; Evict it and give its register to this interval.
                            (let ([r (hashtable-ref assign (car furthest) #f)])
                              (hashtable-delete! assign (car furthest))
                              (set! spills (cons (car furthest) spills))
                              (check-assignment! arch sc r)
                              (hashtable-set! assign v r)
                              (scan (cdr is)
                                    (cons iv (remq furthest still-active))))
                            (begin
                              (set! spills (cons v spills))
                              (scan (cdr is) still-active))))
                      (let ([r (car pool)])
                        ;; THE assertion. Not a warning.
                        (check-assignment! arch sc r)
                        (hashtable-set! assign v r)
                        (hashtable-set! free sc (cdr pool))
                        (scan (cdr is) (cons iv still-active))))))))))))
  )
