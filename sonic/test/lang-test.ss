;;; Tests for the core languages.
;;;
;;; The valuable half is the REJECTION tests. A grammar that accepts everything
;;; contracts nothing, and the entire parallelism argument in EXECUTION.md
;;; section 1 rests on these contracts being enforced rather than documented.

(import (chezscheme) (nanopass) (sonic lang))

(define failures 0)
(define checks 0)

(define (ok! name thunk)
  (set! checks (+ checks 1))
  (guard (e (#t (set! failures (+ failures 1))
                (printf "  FAIL ~a: rejected but should parse\n" name)))
    (thunk)
    (printf "  ok   ~a\n" name)))

;; A form the grammar must REFUSE.
;;
;; nanopass rejects these at EXPANSION time, which is the property we want and is
;; stronger than a runtime check: a pass emitting an undeclared form fails to
;; COMPILE rather than producing wrong code three stages later. It also means a
;; runtime `guard` cannot see it, since the error fires before the guard exists.
;; So these go through `eval`, which defers expansion to run time and makes the
;; compile-time refusal observable to a test.
(define env (environment '(chezscheme) '(nanopass) '(sonic lang)))
(define (reject! name form)
  (set! checks (+ checks 1))
  (let ([caught #f])
    (guard (e (#t (set! caught #t)))
      (eval form env))
    (if caught
        (printf "  ok   ~a (correctly refused)\n" name)
        (begin (set! failures (+ failures 1))
               (printf "  FAIL ~a: accepted but should be refused\n" name)))))

(printf "Lcore:\n")

(ok! "primcall carries a control input"
     (lambda () (with-output-language (Lcore Expr)
                  `(primcall flvector-ref ([type-check checked] [bounds-check proved]) v (quote 0)))))

(ok! "policy scopes a named check"
     (lambda () (with-output-language (Lcore Expr)
                  `(policy ([bounds-check #f]) (quote 1)))))

(ok! "policy carries fp-contract, per D24"
     (lambda () (with-output-language (Lcore Expr)
                  `(policy ([fp-contract #t]) (quote 1)))))

(ok! "declare states a premise"
     (lambda () (with-output-language (Lcore Expr)
                  `(declare ([v bounds-check]) (quote 1)))))

(ok! "nested let and letrec"
     (lambda () (with-output-language (Lcore Expr)
                  `(let ([a (quote 1)]) (letrec ([f (lambda (y) y)]) (call f a))))))

;; --- the rejections that make the contract real ---------------------------

(reject! "a primitive that is not in the table"
  '(with-output-language (Lcore Expr) `(primcall not-a-primitive ([type-check checked]) (quote 1))))

(reject! "a control input that is not checked/unchecked/proved"
  '(with-output-language (Lcore Expr) `(primcall fl+ ([fp-contract maybe]) (quote 1) (quote 2))))

(reject! "a policy naming a check that does not exist"
  '(with-output-language (Lcore Expr) `(policy ([no-such-check #f]) (quote 1))))

(reject! "primcall with a malformed control list"
  '(with-output-language (Lcore Expr) `(primcall fl+ ([fp-contract]) (quote 1) (quote 2))))

(ok! "per-check granularity: bounds elided, type still checked"
     (lambda () (with-output-language (Lcore Expr)
                  `(primcall flvector-ref ([type-check checked] [bounds-check proved]) v i))))

(ok! "flneg exists and is not (fl- 0.0 x)"
     (lambda () (with-output-language (Lcore Expr) `(primcall flneg () x))))

(ok! "type predicates exist, so config-2c is expressible"
     (lambda () (with-output-language (Lcore Expr)
                  `(if (primcall flvector? () b) (quote 1) (primcall error () (quote 2))))))

(printf "\nLanf:\n")

(ok! "let binds a simple expression"
     (lambda () (with-output-language (Lanf Expr)
                  `(let ([t (primcall fl+ ([fp-contract unchecked]) a b)]) t))))

(ok! "if tests an atom, not an expression"
     (lambda () (with-output-language (Lanf Expr)
                  `(if t (quote 1) (quote 2)))))

(reject! "if testing a non-atom is refused in ANF"
  '(with-output-language (Lanf Expr) `(if (primcall fl< checked a b) (quote 1) (quote 2))))

(reject! "primcall with non-atomic operands is refused in ANF"
  '(with-output-language (Lanf Expr) `(primcall fl+ ([fp-contract unchecked]) (primcall fl* ([fp-contract unchecked]) a b) c)))

;; --- the check vocabulary --------------------------------------------------

(set! checks (+ checks 1))
(let ([names (all-check-names)])
  (if (and (memq 'bounds-check names) (memq 'fp-contract names)
           (memq 'type-check names) (memq 'overflow-check names))
      (printf "\n  ok   check vocabulary complete: ~a\n" names)
      (begin (set! failures (+ failures 1))
             (printf "\n  FAIL check vocabulary incomplete: ~a\n" names))))

(set! checks (+ checks 1))
(if (and (equal? (prim-checks 'flvector-ref) '(type-check bounds-check))
         (null? (prim-checks 'fl/))
         (memq 'div-check (prim-checks 'fxquotient))
         (= (prim-arity 'flvector-set!) 3)
         (equal? (default-controls 'fx+) '((overflow-check checked))))
    (printf "  ok   prim table: checks, arity and defaults\n")
    (begin (set! failures (+ failures 1))
           (printf "  FAIL prim table wrong: ~a ~a\n"
                   (prim-checks 'flvector-ref) (prim-arity 'flvector-set!))))

(set! checks (+ checks 1))
(if (and (primitive? 'flneg) (primitive? 'fl>) (primitive? 'flvector?)
         (primitive? 'error) (primitive? 'fxquotient))
    (printf "  ok   flneg, fl>, predicates, error and integer division present\n")
    (begin (set! failures (+ failures 1))
           (printf "  FAIL table still missing primitives\n")))

(set! checks (+ checks 1))
(if (and (control? 'proved) (control? 'unchecked) (not (control? 'elided)))
    (printf "  ok   proved and unchecked are distinct controls\n")
    (begin (set! failures (+ failures 1))
           (printf "  FAIL control vocabulary wrong\n")))

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
