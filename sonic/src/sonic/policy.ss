;;; SonicScheme: the lexical check policy. Lcore -> Lcore.
;;;
;;; Stage 03b. This is the pass that makes `(policy ([pn on?] ...) body)` MEAN
;;; something. Without it the form parses, survives every later stage, and
;;; changes not one emitted instruction.
;;;
;;; --- WHY THIS IS THE POINT OF THE PROJECT ----------------------------------
;;;
;;; D5, ratified on measurement 2026-08-06: Ada names each check and allows
;;; scoped re-enable, and `ada-8-named` and `ada-8-all` measure 801.00 instr/step
;;; EACH, identical. Granularity costs nothing, so there is no efficiency
;;; argument for Common Lisp's bundled 0-3 safety dial and no argument for
;;; Chez's `optimize-level` either.
;;;
;;; And `optimize-level` is not merely coarse, it is GLOBAL, which is wall 3 of
;;; the four that made Chez unable to host this experiment: you cannot ask for
;;; "unchecked in this loop, checked everywhere else" because there is no `this
;;; loop` to name. The form here is LEXICAL. It nests, an inner scope overrides
;;; an outer one, and leaving the scope restores what was outside it, because the
;;; environment is a walk of the syntax tree and nothing survives the walk out.
;;;
;;; D24 puts `fp-contract` in the same mechanism: a named permission, lexically
;;; scoped, default off. It is not a check being suppressed, it is a rewrite
;;; being permitted, and it is carried by the same form because it is the same
;;; KIND of thing.
;;;
;;; --- THE POLARITY, STATED ONCE ---------------------------------------------
;;;
;;; `b` is `on?`, which is how lang.ss, the surface form and
;;; bench/nbody/sonic-compat.sls all spell it. On means the CONSERVATIVE
;;; obligation is in force:
;;;
;;;   (policy ([bounds-check #f]) body)   the bounds check may be omitted
;;;   (policy ([fp-contract  #f]) body)   the back end may fuse a multiply-add
;;;
;;; and #t puts either obligation back. Every name defaults to #t, which is D5's
;;; fully-checked start and, for `fp-contract`, is exactly D24's "default off":
;;; contraction does not happen unless something says it may. One default, one
;;; polarity, no per-name special case.
;;;
;;; The mapping onto `Lcore`'s control input is the same in both directions:
;;; `checked` is the obligation in force, `unchecked` is the permission taken.
;;; `proved` never appears here -- that is the analysis discharging a check by
;;; proof, and keeping the two distinct is what lets the report say how many
;;; checks went away by proof and how many by permission, which is the number
;;; phase 3 says matters.
;;;
;;; --- THIS PASS ONLY EVER WEAKENS -------------------------------------------
;;;
;;; A control is rewritten only from `checked` to `unchecked`, and only when the
;;; policy in scope says the check is off. `unchecked` and `proved` are left
;;; alone. That is not timidity, it is what makes the pass idempotent and makes
;;; a re-enabling inner policy correct: parse.ss starts EVERY primcall fully
;;; checked (`default-controls`), so "restore" is not a stored stack of previous
;;; values, it is simply the outer environment being the one still in hand when
;;; the inner scope's walk returns.
;;;
;;; --- WHAT IT REFUSES -------------------------------------------------------
;;;
;;;   * AN UNKNOWN CHECK NAME. Refused before this pass ever runs: `policy-name?`
;;;     is a terminal predicate in lang.ss, so nanopass will not build the term,
;;;     and parse.ss raises "not a check name" on the way in. A policy naming a
;;;     check that does not exist is a typo whose whole effect would otherwise be
;;;     silence, which is the failure mode this project exists to argue against.
;;;   * ONE NAME TWICE IN ONE FORM. `(policy ([bounds-check #t] [bounds-check
;;;     #f]) ...)` states two things at once and picking one is a coin toss.
;;;
;;; Run the tests: scheme -q --libdirs src:vendor/nanopass --script test/policy-test.ss

(library (sonic policy)
  (export resolve-policy resolve-policy-program
          policy-default policy-extend policy-in-force?)
  (import (chezscheme) (nanopass) (sonic lang))

  (define (pol-error msg . irritants)
    (apply error 'policy msg irritants))

  ;; --- the environment ------------------------------------------------------
  ;;
  ;; An alist, newest first, so entering a scope is a cons and LEAVING ONE IS
  ;; FREE: the outer list is still the one the caller holds. That is the whole
  ;; implementation of "inner scopes override and leaving restores", and it is
  ;; why the form is lexical rather than a global dial with a save/restore
  ;; protocol somebody has to get right.

  (define (policy-default)
    (map (lambda (n) (cons n #t)) (all-check-names)))

  (define (policy-in-force? env pn)
    (let ([p (assq pn env)])
      (if p (cdr p) #t)))                  ; unmentioned means fully checked

  (define (policy-extend env pn* b*)
    (let dup ([ns pn*] [seen '()])
      (cond [(null? ns) 'ok]
            [(memq (car ns) seen)
             (pol-error "one policy form names the same check twice" (car ns))]
            [else (dup (cdr ns) (cons (car ns) seen))]))
    (append (map cons pn* b*) env))

  ;; --- the rewrite ----------------------------------------------------------

  ;; `checked` -> `unchecked` when the policy says the check is off. Nothing
  ;; else moves: see the header on why this pass only weakens.
  (define (resolve-control env pn c)
    (if (and (eq? c 'checked) (not (policy-in-force? env pn)))
        'unchecked
        c))

  (define (Expr e env)
    (with-output-language (Lcore Expr)
      (nanopass-case (Lcore Expr) e

        [(policy ([,pn* ,b*] ...) ,body)
         ;; The node stays. It is a record of what the programmer permitted,
         ;; which the check report wants and which costs nothing to carry; the
         ;; controls below it already say what it did.
         (let ([inner (policy-extend env pn* b*)])
           `(policy ([,pn* ,b*] ...) ,(Expr body inner)))]

        [(primcall ,pr ([,pn* ,c*] ...) ,e* ...)
         (let ([c1* (map (lambda (pn c) (resolve-control env pn c)) pn* c*)]
               [a* (map (lambda (a) (Expr a env)) e*)])
           `(primcall ,pr ([,pn* ,c1*] ...) ,a* ...))]

        [,x e]
        [(quote ,d) e]
        [(void) e]
        [(if ,e0 ,e1 ,e2)
         `(if ,(Expr e0 env) ,(Expr e1 env) ,(Expr e2 env))]
        [(let ([,x* ,e*] ...) ,body)
         `(let ([,x* ,(map (lambda (a) (Expr a env)) e*)] ...) ,(Expr body env))]
        [(letrec ([,x* ,e*] ...) ,body)
         `(letrec ([,x* ,(map (lambda (a) (Expr a env)) e*)] ...) ,(Expr body env))]
        [(letrec* ([,x* ,e*] ...) ,body)
         `(letrec* ([,x* ,(map (lambda (a) (Expr a env)) e*)] ...) ,(Expr body env))]
        [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Expr body env))]
        [(call ,e0 ,e* ...)
         `(call ,(Expr e0 env) ,(map (lambda (a) (Expr a env)) e*) ...)]
        [(set! ,x ,e0) `(set! ,x ,(Expr e0 env))]
        [(declare ([,x* ,prem*] ...) ,body)
         `(declare ([,x* ,prem*] ...) ,(Expr body env))]
        [(declare-distinct (,x* ...) ,body)
         `(declare-distinct (,x* ...) ,(Expr body env))]
        [(begin ,e* ... ,e0)
         `(begin ,(map (lambda (a) (Expr a env)) e*) ... ,(Expr e0 env))]

        ;; No `else`. A production added to Lcore later must be handled here
        ;; deliberately, because the failure of a silent fallthrough would be a
        ;; whole subtree whose policy never applied.
        )))

  ;; --- entry points ---------------------------------------------------------

  ;; (resolve-policy e)      the default policy: every check in force
  ;; (resolve-policy e env)  an outer policy supplied by the caller
  (define resolve-policy
    (case-lambda
      [(e) (Expr e (policy-default))]
      [(e env) (Expr e env)]))

  (define resolve-policy-program
    (case-lambda
      [(prog) (resolve-policy-program prog (policy-default))]
      [(prog env)
       (nanopass-case (Lcore Program) prog
         [(top ([,x* ,e*] ...) (,x2* ...) ,body)
          (let ([v* (map (lambda (e) (Expr e env)) e*)]
                [b (Expr body env)])
            (with-output-language (Lcore Program)
              `(top ([,x* ,v*] ...) (,x2* ...) ,b)))])]))
  )
