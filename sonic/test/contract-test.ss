;;; Tests for contract.ss -- D24 contraction, fusing a permitted multiply-add.
;;;
;;; THE PERMISSION WAS TESTED AND THE PASS THAT OBEYS IT WAS NOT. policy-test.ss
;;; asserts `fp-contract is off by default, per D24`, which covers the resolver.
;;; Nothing asserted that the transform actually declines when it is off and
;;; fuses when it is on. If it fused regardless, differential-test.ss would
;;; catch it loudly -- contraction rounds once where two instructions round
;;; twice, so bit-exactness against the other ten implementations would break.
;;; The quiet direction is the dangerous one: silently declining when GRANTED
;;; costs the 15 cycles D24 measured and looks like nothing at all.
;;;
;;; THE PERMISSION ARRIVES AS A MARKED OPCODE. `mul-c`, `add-c`, `sub-c` are the
;;; contraction-permitted spellings; plain `mul`/`add`/`sub` are not permitted
;;; and must never fuse. A marked op that does NOT fuse is emitted unmarked,
;;; because nothing downstream should have to know the mark existed.
;;;
;;; Three rows, one per width: scalar, p2 (a 128-bit pair) and p4. A packed
;;; product must not fuse into a scalar sum.
;;;
;;; Input is an Lmach datum: (program ([lbl (block (i ...) transfer)] ...) entry).

(import (chezscheme) (sonic contract))

(define checks 0)
(define failures 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok
      (begin (display "  ok   ") (display name) (newline))
      (begin (display "  FAIL ") (display name) (newline)
             (set! failures (+ failures 1)))))

(define (block instrs) `(program ([entry (block ,instrs (ret r))]) entry))

;; The opcodes the block came out with, in order.
(define (ops-of prog)
  (let-values (((out st) (contract-program prog)))
    (values (map car (cadr (cadr (car (cadr out))))) st)))

(define (has? ops o) (and (memq o ops) #t))

(display "\n-- fusing, where the program permitted it --\n")

;; a*b + c, the shape D34 says is the whole remaining gap to C: nbody runs 420
;; FP operations per step against gcc's 297, "and the difference is almost
;; entirely fused multiply-add".
;; THE ORDERING IS A COALESCING DECISION, not a spelling. 132/213/231 select
;; which operand is the addend and are semantically identical, so the pass picks
;; by what the register allocator can then coalesce. A FACTOR usually dies at
;; the multiply -- `dx` in `dx*mag` is read once -- and a value that dies at the
;; copy is exactly what `move-hints` needs. The ADDEND is typically a
;; loop-carried accumulator, live across the back edge, whose interval never
;; ends at the copy: choosing it measured 48 fusions and 65 SURVIVING moves, a
;; net of one instruction saved.
;;
;; So a single-use factor goes in the destination and the ordering is `132`.
(let-values (((ops st) (ops-of (block '((mul-c t raw-f64 a b)
                                        (add-c r raw-f64 t c))))))
  (ck! "a permitted multiply feeding an add fuses, with a single-use factor in the destination"
       (has? ops 'fma132))
  (ck! "the multiply is gone, not left beside the fused form"
       (not (or (has? ops 'mul-c) (has? ops 'mul))))
  (ck! "and it is counted" (= (contract-stats-fused st) 1))
  ;; vfmadd231sd computes d = a*b + d, so the destination IS the addend. The
  ;; copy is emitted HERE as an Lmach `move` rather than in the selector,
  ;; because only here can the allocator coalesce it -- emitting it after
  ;; allocation measured 48 fused multiply-adds and 113 MORE instructions per
  ;; step, 26 cycles worse than not fusing at all.
  (ck! "with a move putting the addend where the fused form needs it"
       (has? ops 'move)))

;; Addition commutes, so the product may be either operand.
(let-values (((ops st) (ops-of (block '((mul-c t raw-f64 a b)
                                        (add-c r raw-f64 c t))))))
  (ck! "the product may be either operand of the add, addition commuting"
       (has? ops 'fma132)))

;; AND THE FALLBACK. When NEITHER factor dies at the multiply, there is no
;; coalescing win to be had from a factor, so the addend goes in the destination
;; and the ordering is `231`.
(let-values (((ops st) (ops-of (block '((mul-c t raw-f64 a b)
                                        (add-c r raw-f64 t c)
                                        (add s raw-f64 a b))))))
  (ck! "when neither factor dies at the multiply, it falls back to the 231 form"
       (has? ops 'fma)))

;; c - a*b negates the PRODUCT, which is what fnma computes.
(let-values (((ops st) (ops-of (block '((mul-c t raw-f64 a b)
                                        (sub-c r raw-f64 c t))))))
  (ck! "c - a*b fuses to a negated-product form" (has? ops 'fnma132)))

(display "\n-- and where it did not --\n")

;; a*b - c negates the ADDEND instead, which is a different instruction.
(let-values (((ops st) (ops-of (block '((mul-c t raw-f64 a b)
                                        (sub-c r raw-f64 t c))))))
  (ck! "a*b - c does NOT fuse, negating the addend being a different operation"
       (not (exists (lambda (o) (memq o '(fma fnma fma132 fnma132))) ops)))
  (ck! "and nothing was counted" (= (contract-stats-fused st) 0)))

;; THE PERMISSION. Identical shape, unmarked opcodes.
(let-values (((ops st) (ops-of (block '((mul t raw-f64 a b)
                                        (add r raw-f64 t c))))))
  (ck! "the same shape WITHOUT the permission does not fuse"
       (and (not (exists (lambda (o) (memq o '(fma fma132))) ops))
            (= (contract-stats-fused st) 0)))
  (ck! "and is left exactly as it was" (equal? ops '(mul add))))

;; A MARKED OP THAT DID NOT FUSE IS UNMARKED. Nothing downstream should have to
;; know the mark existed, and a `mul-c` reaching the selector would be an opcode
;; it has no rule for.
(let-values (((ops st) (ops-of (block '((mul-c t raw-f64 a b)
                                        (sub-c r raw-f64 t c))))))
  (ck! "a permitted op that did not fuse is emitted unmarked"
       (and (has? ops 'mul) (has? ops 'sub)
            (not (has? ops 'mul-c)) (not (has? ops 'sub-c)))))

;; A SECOND READER. Fusing consumes the product, so a use elsewhere would be
;; left naming a vreg nothing defines.
(let-values (((ops st) (ops-of (block '((mul-c t raw-f64 a b)
                                        (add-c r raw-f64 t c)
                                        (add-c s raw-f64 t c))))))
  (ck! "a product with another reader does not fuse"
       (= (contract-stats-fused st) 0)))

(display "\n-- width, which the row is what says --\n")

;; A packed product does not fuse into a scalar sum.
(let-values (((ops st) (ops-of (block '((p2mul-c t raw-f64 a b)
                                        (add-c r raw-f64 t c))))))
  (ck! "a packed product does not fuse into a scalar add"
       (= (contract-stats-fused st) 0)))

;; But a pair fuses exactly as a scalar does: vfmadd231pd is two independent
;; fused multiply-adds, lane by lane, each rounding once where the two packed
;; instructions it replaces round twice.
(let-values (((ops st) (ops-of (block '((p2mul-c t raw-f64 a b)
                                        (p2add-c r raw-f64 t c))))))
  (ck! "a packed pair fuses to the packed form" (has? ops 'p2fma132)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
