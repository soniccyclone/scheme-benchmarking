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
  (define (resolve-parallel-copy moves scratch-for stats)
    ;; Self-moves are no-ops and would otherwise look like one-element cycles.
    (let loop ((pending (filter (lambda (m) (not (eq? (car m) (cdr m)))) moves))
               (out '()))
      (if (null? pending)
          (reverse out)
          (let* ((srcs (map cdr pending))
                 (ready (filter (lambda (m) (not (memq (car m) srcs))) pending)))
            (if (pair? ready)
                ;; This destination is nobody's source, so writing it is safe.
                (let ((m (car ready)))
                  (loop (drop-move m pending) (cons m out)))
                ;; Everything left is in a cycle. Break one edge through the
                ;; scratch register for that class, and the cycle becomes a
                ;; chain the ready rule can then unwind.
                (let* ((m (car pending))
                       (tmp (scratch-for (cdr m))))
                  (parcopy-stats-cycles-broken-set!
                   stats (+ 1 (parcopy-stats-cycles-broken stats)))
                  (loop (cons (cons (car m) tmp) (drop-move m pending))
                        (cons (cons tmp (cdr m)) out))))))))

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
          (let ((same (filter (lambda (s)
                                (if (memq r (arch-float arch))
                                    (memq s (arch-float arch))
                                    (not (memq s (arch-float arch)))))
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
