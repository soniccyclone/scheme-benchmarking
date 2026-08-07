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

;; --- the gaps the expander agent found -------------------------------------

(ok! "declare-distinct expresses restrict-style non-aliasing"
     (lambda () (with-output-language (Lcore Expr)
                  `(declare-distinct (a b c) (primcall flvector-ref
                                               ([type-check proved] [bounds-check proved])
                                               a i)))))

(ok! "void is a distinct value, not (quote ())"
     (lambda () (with-output-language (Lcore Expr) `(if (void) (void) (void)))))

(ok! "set! exists, so the expander has somewhere to put assignment"
     (lambda () (with-output-language (Lcore Expr) `(set! x (quote 1)))))

(ok! "letrec* is distinct from letrec, so sequential init survives"
     (lambda () (with-output-language (Lcore Expr)
                  `(letrec* ([a (quote 1)] [b (quote 2)]) b))))

(ok! "there is a top-level Program production, with an extern list"
     (lambda () (with-output-language (Lcore Program)
                  `(top ([f (lambda (x) x)]) (write-string sqrt) (call f (quote 1))))))

(ok! "an empty extern list means the unit is closed"
     (lambda () (with-output-language (Lcore Program)
                  `(top ([f (lambda (x) x)]) () (call f (quote 1))))))

;; --- the downstream IR contracts -------------------------------------------
;; The contract is that a pass author can CONSTRUCT valid input for their own
;; stage with no upstream pass in existence. That is what converts the pipeline
;; from a depth-13 chain into a wide DAG, so it is tested rather than assumed.

(printf "\nDownstream IRs (constructible with no upstream pass):\n")

(ok! "Lssa: phi carries per-predecessor operands"
     (lambda () (with-output-language (Lssa Expr)
                  `(phi ([i2 (entry i0) (back i1)]) i2))))

(ok! "Lssa: sigma names the branch fact ABCD needs"
     (lambda () (with-output-language (Lssa Expr)
                  `(sigma i2 i fx< n #f (phi ([s (entry (quote 0))]) s)))))

;; The false edge of the same test. Sigma carries the comparison AS WRITTEN plus
;; a negation flag rather than an opposite primitive, because for flonums there
;; is no opposite: NaN makes (not (fl< a b)) true where (fl>= a b) is false.
;; lang.ss states it at the production; this pins that the production can hold
;; it.
(ok! "Lssa: sigma can carry a NEGATED comparison"
     (lambda () (with-output-language (Lssa Expr)
                  `(sigma a2 a fl< b #t (phi ([s (entry (quote 0))]) s)))))

(ok! "Lrepr: a binding carries its storage class"
     (lambda () (with-output-language (Lrepr Expr)
                  `(let ([t raw-f64 (primcall fl+ ([fp-contract unchecked]) a b)]) t))))

(ok! "Lmach: a whole program, blocks and transfers"
     (lambda () (with-output-language (Lmach Prog)
                  `(program ([entry (block ((const v0 raw-word 0)
                                            (chk bounds-check checked 0 v0 v1)
                                            (load v2 raw-f64 v1 v0))
                                           (ret v2))])
                     entry))))

(reject! "Lmach refuses an op that is not machine-independent"
  '(with-output-language (Lmach Instr) `(vfmadd231pd v0 raw-f64 v1 v2)))

(reject! "Lrepr refuses a storage class that is not in the partition"
  '(with-output-language (Lrepr Expr) `(let ([t xmm-hi (quote 1)]) t)))

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
