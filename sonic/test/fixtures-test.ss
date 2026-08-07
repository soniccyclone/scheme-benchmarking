;;; The fixtures must actually construct, or every downstream bead that leans on
;;; them fails for a reason that has nothing to do with the pass under test.
(import (chezscheme) (nanopass) (sonic lang) (sonic fixtures))

(define (flatten-syms x)
  (cond [(pair? x) (append (flatten-syms (car x)) (flatten-syms (cdr x)))]
        [(symbol? x) (list x)]
        [else '()]))

(define failures 0) (define checks 0)
(define (t! name thunk)
  (set! checks (+ checks 1))
  (guard (e (#t (set! failures (+ failures 1)) (printf "  FAIL ~a\n" name)))
    (let ([v (thunk)]) (printf "  ok   ~a\n" name) v)))

(t! "straight-line-anf" straight-line-anf)
(t! "diamond-anf"       diamond-anf)
(t! "loop-anf"          loop-anf)
(t! "nbody-inner-anf"   nbody-inner-anf)
(t! "nbody-inner-ssa"   nbody-inner-ssa)
(t! "nbody-inner-repr"  nbody-inner-repr)
(t! "nbody-inner-mach"  nbody-inner-mach)
(t! "store-mach: pins the unused-destination shape" store-mach)
(t! "flcmp-mach: pins f64 comparison as its own op"  flcmp-mach)

;; The lowered fixture is E2-LIR's acceptance criterion: BOTH target selectors
;; consume this same value, so its shape is a contract.
(set! checks (+ checks 1))
(let ([m (unparse-Lmach (nbody-inner-mach))])
  (if (and (eq? (car m) 'program)
           ;; no check survived to codegen: the analysis discharged them
           (not (memq 'chk (flatten-syms m))))
      (printf "  ok   lowered nbody has NO surviving check instruction\n")
      (begin (set! failures (+ failures 1))
             (printf "  FAIL a check survived to Lmach: ~s\n" m))))

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
