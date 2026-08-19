;;; Tests for cse.ss -- common subexpression elimination over Lmach.
;;;
;;; The pass exists because lowering translates the same source expression once
;;; per occurrence: nbody's position update computed `i+1` three times in one
;;; loop body, nine instructions for two distinct values out of a body of
;;; fifty-three. Nothing upstream is at fault; ANF names every intermediate
;;; separately and lowering translates each name.
;;;
;;; IT REWRITES USES RATHER THAN INSERTING MOVES, program-wide, and lets dce.ss
;;; collect the definition that is left with no readers. That is why it runs
;;; immediately before DCE. A `(move dst sc prev)` would not do: `prev` is still
;;; live -- having other readers is what made it common -- so its register is
;;; neither free nor dying and the coalescer correctly declines.
;;;
;;; THREE STORAGE CLASSES, AND KEEPING THEM APART IS THE WHOLE CORRECTNESS
;;; ARGUMENT. Arithmetic over single-assignment vregs is always reusable. A heap
;;; READ is reusable only between heap writes -- nbody's loop reads p[i], writes
;;; p[i], reads p[i+1], so folding a reload onto a value an intervening store
;;; replaced would stop the energies being bit-exact. A GLOBAL read is a
;;; different area again: a global and a heap object cannot alias, so a store
;;; into a vector says nothing about a global's value, and conflating them had
;;; nbody reloading `dt` three times per position update.
;;;
;;; Input is an Lmach datum: (program ([lbl (block (i ...) transfer)] ...) entry).

(import (chezscheme) (sonic cse) (sonic driver) (sonic pipeline))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

(define (run prog) (let-values (((out st) (cse-program prog))) (values out st)))

(define (instrs-of out lbl)
  (let find ((bs (cadr out)))
    (cond ((null? bs) #f)
          ((eq? (car (car bs)) lbl) (cadr (cadr (car bs))))
          (else (find (cdr bs))))))

;; What the LAST instruction's operands ended up naming. Every fixture below
;; ends in a consumer whose operands say whether the fold happened.
(define (last-operands out lbl)
  (let ((is (instrs-of out lbl))) (and (pair? is) (cdddr (car (reverse is))))))

;; EVERY OPERAND MUST BE DEFINED, exactly once, or nothing folds. `single?`
;; requires a definition count of 1, so a vreg the fixture never defines has
;; count 0 and every expression naming it is treated as denoting more than one
;; value. A global read is the one exemption -- its operand is a cell NAME, a
;; label rather than a value, with no definition to count.
;;
;; Writing the fixture without the preamble made all five folding assertions
;; fail while every refusal passed, which reads exactly like a pass that folds
;; nothing and is really a fixture the pass was right to decline.
(define preamble
  '((const i raw-word 0)
    (const one raw-word 1)
    (const two raw-word 2)
    (const p raw-word 4096)
    (const k raw-word 8)
    (const v raw-f64 0.0)
    (const f raw-word 512)))

(define (block instrs)
  `(program ([entry (block ,(append preamble instrs) (jump entry))]) entry))

(display "\n-- arithmetic, which is always reusable --\n")

;; b and c compute the same thing from the same single-assignment vregs. The
;; consumer must end up naming ONE of them twice rather than one of each.
(let-values (((out st) (run (block '((add b raw-word i one)
                                     (add c raw-word i one)
                                     (add use raw-word b c))))))
  (ck! "a repeated pure computation is folded onto the earlier vreg"
       (equal? (last-operands out 'entry) '(b b)))
  (ck! "and it is counted" (>= (cse-stats-folded st) 1)))

;; Different operands are a different expression.
(let-values (((out st) (run (block '((add b raw-word i one)
                                     (add c raw-word i two)
                                     (add use raw-word b c))))))
  (ck! "a computation over different operands is NOT folded"
       (equal? (last-operands out 'entry) '(b c))))

(display "\n-- heap reads, reusable only between heap writes --\n")

(let-values (((out st) (run (block '((load a raw-f64 p k)
                                     (load b raw-f64 p k)
                                     (add use raw-f64 a b))))))
  (ck! "two loads of the same place, nothing between, fold"
       (equal? (last-operands out 'entry) '(a a))))

;; THE ONE THAT KEEPS THE ENERGIES BIT-EXACT. The store may have replaced the
;; value, so the reload is a different value and must survive as its own vreg.
(let-values (((out st) (run (block '((load a raw-f64 p k)
                                     (store v raw-f64 p k)
                                     (load b raw-f64 p k)
                                     (add use raw-f64 a b))))))
  (ck! "a reload across an intervening STORE is not folded"
       (equal? (last-operands out 'entry) '(a b)))
  (ck! "and the invalidation is counted" (>= (cse-stats-invalidations st) 1)))

(let-values (((out st) (run (block '((load a raw-f64 p k)
                                     (call r raw-word f)
                                     (load b raw-f64 p k)
                                     (add use raw-f64 a b))))))
  (ck! "nor across a call, which may write anything"
       (equal? (last-operands out 'entry) '(a b))))

;; Arithmetic is unaffected by a heap write: its operands are vregs, not
;; storage. If a store cleared the value table too, the win on index arithmetic
;; would vanish on nearly every line.
(let-values (((out st) (run (block '((add b raw-word i one)
                                     (store v raw-f64 p k)
                                     (add c raw-word i one)
                                     (add use raw-word b c))))))
  (ck! "a store does NOT invalidate arithmetic"
       (equal? (last-operands out 'entry) '(b b))))

(display "\n-- global reads are a separate area --\n")

;; A global and a heap object cannot alias. Clearing one table on the other's
;; writes is what had nbody reloading `dt` three times per position update --
;; and cost a vector instruction too, since two loads of one global are two
;; vregs and SLP assembled them with vunpcklpd instead of splatting one.
(let-values (((out st) (run (block '((gref d raw-f64 dt-cell)
                                     (store v raw-f64 p k)
                                     (gref e raw-f64 dt-cell)
                                     (add use raw-f64 d e))))))
  (ck! "a heap store does NOT invalidate a global read"
       (equal? (last-operands out 'entry) '(d d))))

;; But a write to a global must.
(let-values (((out st) (run (block '((gref d raw-f64 dt-cell)
                                     (gset v raw-f64 dt-cell)
                                     (gref e raw-f64 dt-cell)
                                     (add use raw-f64 d e))))))
  (ck! "a gset DOES invalidate a global read"
       (equal? (last-operands out 'entry) '(d e))))

;; And symmetrically: a global write says nothing about the heap.
(let-values (((out st) (run (block '((load a raw-f64 p k)
                                     (gset v raw-f64 dt-cell)
                                     (load b raw-f64 p k)
                                     (add use raw-f64 a b))))))
  (ck! "a gset does NOT invalidate a heap read"
       (equal? (last-operands out 'entry) '(a a))))

;; --- THE PASS IS NOT INERT ON A REAL PROGRAM --------------------------------
;;
;; A fixture cannot catch inertness: it tests the shape it was written for, which
;; the pass by construction handles. cse's effect is also not readable from the
;; emitted code -- selection and the allocator rewrite what it leaves -- so it is
;; asserted where it runs, via the driver's stage hook (D136, D137).
(define captured #f)
(parameterize ((compile-stage-hook
                (lambda (stage prog)
                  (when (eq? stage 'lmach/pre-cse) (set! captured prog)))))
  (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))

(ck! "the stage hook delivered nbody's pre-cse program" (and captured #t))
(let-values (((out st) (cse-program captured)))
  (ck! "cse folds something in nbody: the pass is not inert"
       (> (cse-stats-folded st) 0))
  (unless (> (cse-stats-folded st) 0)
    (display "       folded=") (display (cse-stats-folded st)) (newline)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
