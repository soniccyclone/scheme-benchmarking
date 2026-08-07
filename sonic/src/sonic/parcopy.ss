;;; Parallel copy resolution, after register allocation.
;;;
;;; Bead 6gk.23. `callseq.ss` emits argument moves in sequence and says why it
;;; cannot do better: breaking a cycle needs to know which physical registers
;;; the sources ended up in, and selection runs before allocation. So this pass
;;; runs after.
;;;
;;; ## The bug being fixed
;;;
;;; A call's argument moves are a PARALLEL copy: every source is read from the
;;; state before the call, not from the state part-way through the moves. Emit
;;; them in sequence and the second move can read a register the first already
;;; overwrote.
;;;
;;;     mov a0, a1        ; a0 := old a1
;;;     mov a1, a0        ; wanted old a0, reads the a1 just written
;;;
;;; Both arguments end up holding the same value. It is silent, it is
;;; wrong-code, and it only fires when the allocator happens to place two
;;; arguments in each other's target registers — so it survives every test whose
;;; allocation happens to be acyclic.
;;;
;;; ## The algorithm
;;;
;;; Standard, and it is worth stating why it terminates. Repeatedly emit any
;;; move whose destination is not the source of a still-pending move: that
;;; destination is dead, so writing it clobbers nothing anyone still needs. When
;;; no such move exists, every remaining move is part of a cycle. Break exactly
;;; one edge by copying its source to the scratch register, then continue; the
;;; cycle is now a chain.
;;;
;;; Each pass either emits a move or breaks a cycle, and both strictly reduce
;;; the pending set, so it terminates in at most 2n steps.
;;;
;;; `regs.ss` reserves the scratch registers (`t0`/`t1`/`ft11` on RV64, `rax`
;;; and `xmm15` on x86-64) outside every allocatable pool, which is precisely
;;; what makes them usable here: no live range can be occupying one.

(library (sonic parcopy)
  (export resolve-parallel-copy resolve-moves-in-block
          make-parcopy-stats parcopy-stats? parcopy-stats-cycles-broken)
  (import (chezscheme) (sonic regs))

  (define-record-type (parcopy-stats make-parcopy-stats parcopy-stats?)
    (fields (mutable cycles-broken)))

  ;; moves : ((dst . src) ...) all read from the pre-copy state.
  ;; scratch-for : a procedure from a register to a scratch of the same class.
  ;; Returns a list of (dst . src) pairs to be emitted IN ORDER.
  ;; The termination argument in the header is CONDITIONAL, and the condition
  ;; was neither stated nor checked. It cost 31GB and a VM.
  ;;
  ;; Breaking a cycle rewrites `(dst . src)` into `(dst . tmp)`. If `dst` is
  ;; ALREADY the scratch for its class, that is `(tmp . tmp)` -- a self-move.
  ;; Self-moves are filtered once, at entry, so this one is never removed: its
  ;; destination is its own source, so it is never `ready`; the cycle branch
  ;; fires again; `scratch-for` returns the same register; the state is
  ;; identical. One cons per iteration, forever. The Linux OOM killer caught it
  ;; at 31,204,756 kB resident.
  ;;
  ;; Two guards, and both are needed. The filter now runs every round, so a
  ;; self-move created here is removed rather than spun on. And the iteration
  ;; count is bounded, because a pass that cannot make progress must FAIL, not
  ;; allocate -- a compiler that hangs is a compiler you debug by rebooting.
  (define (resolve-parallel-copy moves scratch-for stats)
    (define (no-self ms) (filter (lambda (m) (not (eq? (car m) (cdr m)))) ms))
    ;; Each round either emits a move or breaks a cycle, and both strictly
    ;; reduce the pending set, so 2n is a real ceiling rather than a guess.
    (let ((limit (* 2 (+ 1 (length moves)))))
      (let loop ((pending (no-self moves)) (out '()) (n 0))
        (when (> n limit)
          (error 'resolve-parallel-copy
                 "parallel copy made no progress; this is a bug in the pass, not in the program"
                 moves pending))
        (if (null? pending)
            (reverse out)
            (let* ((srcs (map cdr pending))
                   (ready (filter (lambda (m) (not (memq (car m) srcs))) pending)))
              (if (pair? ready)
                  ;; This destination is nobody's source, so writing it is safe.
                  (let ((m (car ready)))
                    (loop (drop-move m pending) (cons m out) (+ n 1)))
                  ;; Everything left is in a cycle. Break one edge through the
                  ;; scratch register for that class, and the cycle becomes a
                  ;; chain the ready rule can then unwind.
                  (let* ((m (car pending))
                         (tmp (scratch-for (cdr m))))
                    (when (eq? (car m) tmp)
                      (error 'resolve-parallel-copy
                             "a move's destination is the scratch register that would break its cycle; the scratch must be free, so this move never belonged in a parallel copy"
                             m))
                    (parcopy-stats-cycles-broken-set!
                     stats (+ 1 (parcopy-stats-cycles-broken stats)))
                    (loop (no-self (cons (cons (car m) tmp) (drop-move m pending)))
                          (cons (cons tmp (cdr m)) out)
                          (+ n 1)))))))))

  ;; Chez already binds `remq`, so this is named for what it does here.
  (define (drop-move x xs) (filter (lambda (y) (not (eq? x y))) xs))

  ;; Rewrite a run of `mov` instructions in an allocated block. A maximal run of
  ;; moves is a parallel copy; anything else ends the run.
  ;;
  ;; `mov-of` recognises a target's move spelling and yields (dst . src);
  ;; `emit-mov` builds one back.
  (define (resolve-moves-in-block arch instrs mov-of emit-mov)
    (let ((stats (make-parcopy-stats 0)))
      (define (scratch-for r)
        (let* ((cls (reg-class arch r))
               (sc (filter (lambda (s) (eq? (reg-class arch s) 'scratch))
                           (arch-scratch arch))))
          ;; Pick a scratch whose file matches: an integer cycle cannot be
          ;; broken through a float register and vice versa.
          ;; `float-register?` rather than membership in `arch-float`: the
          ;; float SCRATCH registers are deliberately outside the allocatable
          ;; pool, so asking the pool concludes there is no float scratch on a
          ;; target that reserves one precisely for this.
          (let ((same (filter (lambda (s)
                                (eq? (float-register? arch s)
                                     (float-register? arch r)))
                              (arch-scratch arch))))
            (if (pair? same)
                (car same)
                (error 'resolve-moves-in-block
                       "no scratch register of the right file to break a cycle" r)))))
      (let loop ((is instrs) (run '()) (out '()))
        (define (flush)
          (if (null? run)
              out
              (append (reverse (map (lambda (m) (emit-mov (car m) (cdr m)))
                                    (resolve-parallel-copy (reverse run)
                                                           scratch-for stats)))
                      out)))
        (cond
         ((null? is) (values (reverse (flush)) stats))
         ((mov-of (car is))
          => (lambda (m) (loop (cdr is) (cons m run) out)))
         (else (loop (cdr is) '() (cons (car is) (flush))))))))
  )
