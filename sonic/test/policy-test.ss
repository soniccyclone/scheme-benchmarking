;;; Declaration forms and the scoped named check policy.
;;;
;;; This is the language surface for the thing the whole project argued for, so
;;; the tests are organised around the claims rather than around the code.
;;;
;;;   D5, ratified on measurement: named per-check suppression, Ada-style.
;;;     `ada-8-named` and `ada-8-all` measure 801.00 instr/step each, identical,
;;;     so granularity is free and there is no efficiency case for CL's bundled
;;;     0-3 dial. What is tested: a policy names ONE check and leaves the others
;;;     alone, which is exactly what a single tri-state per call site could not
;;;     express.
;;;
;;;   LEXICAL, not global. Chez's optimize-level being a global dial is wall 3 of
;;;   the four that made it unable to host this experiment. What is tested: the
;;;   suppression stops at the closing paren, an inner policy overrides an outer
;;;   one and leaving the inner scope restores the outer one, and a procedure
;;;   DEFINED outside a policy is unaffected by being CALLED inside it, which is
;;;   the difference between a lexical form and a dynamic parameter.
;;;
;;;   D24: `fp-contract` is a named permission in the same mechanism, default
;;;   off. What is tested: an untouched flonum operation carries the obligation,
;;;   and the same form that suppresses a check is what lifts it.
;;;
;;;   AND IT REACHES THE MACHINE. The acceptance criterion says "verified in
;;;   emitted code", so the last section runs (sonic lower) and counts `chk`
;;;   instructions in Lmach, which is what a back end actually emits.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/policy-test.ss
;;;      (from sonic/)

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse)
        (sonic policy) (sonic anf) (sonic lower))

(define failures 0)
(define checks 0)

(define (check! name ok)
  (set! checks (+ checks 1))
  (unless ok
    (set! failures (+ failures 1))
    (printf "FAIL: ~a\n" name)))

(define (check-equal! name got want)
  (set! checks (+ checks 1))
  (unless (equal? got want)
    (set! failures (+ failures 1))
    (printf "FAIL: ~a\n  got:  ~s\n  want: ~s\n" name got want)))

(define (must-fail name thunk)
  (set! checks (+ checks 1))
  (let ([ok (guard (e (#t #t)) (thunk) #f)])
    (unless ok
      (set! failures (+ failures 1))
      (printf "FAIL: ~a  (expected an error, got none)\n" name))))

;; surface -> Lcore with the policy resolved onto the controls.
(define (P form)
  (unparse-Lcore (resolve-policy (parse-expression (expand-expression form)))))

;; Every primcall in the tree, in source order, as (prim (check control) ...).
(define (controls form)
  (reverse
   (let scan ([f form] [acc '()])
     (cond [(and (pair? f) (eq? (car f) 'quote)) acc]
           [(and (pair? f) (eq? (car f) 'primcall))
            (scan (cdddr f) (cons (cons (cadr f) (caddr f)) acc))]
           [(pair? f) (scan (cdr f) (scan (car f) acc))]
           [else acc]))))

;; The control on one named check of the first primcall for `pr`.
(define (control-of form pr pn)
  (let loop ([cs (controls form)])
    (cond [(null? cs) 'no-such-primcall]
          [(eq? (car (car cs)) pr)
           (let ([p (assq pn (cdr (car cs)))])
             (if p (cadr p) 'no-such-check))]
          [else (loop (cdr cs))])))

(printf "lexical check policy:\n")

;; ===========================================================================
;; 1. it suppresses inside its scope, and NOT outside it
;; ===========================================================================

(check-equal! "the default is fully checked"
              (control-of (P '(flvector-ref p i)) 'flvector-ref 'bounds-check)
              'checked)

(check-equal! "a policy suppresses the check it names"
              (control-of (P '(policy ((bounds-check #f)) (flvector-ref p i)))
                          'flvector-ref 'bounds-check)
              'unchecked)

;; D5's granularity, which is the whole reason the control input is one per
;; check rather than one per call: `flvector-ref` carries a type check AND a
;; bounds check, and "bounds off, type still on" is precisely the state that a
;; single tri-state could not express.
(check-equal! "and only the check it names"
              (cdr (car (controls (P '(policy ((bounds-check #f))
                                        (flvector-ref p i))))))
              '((type-check checked) (bounds-check unchecked)))

;; THE CLOSING PAREN IS THE EDGE. Two identical accesses, one inside and one
;; outside; if the mechanism were a dial rather than a scope they would agree.
(check-equal! "the suppression stops at the end of the scope"
              (map (lambda (c) (cadr (assq 'bounds-check (cdr c))))
                   (controls (P '(begin (policy ((bounds-check #f))
                                          (flvector-ref p i))
                                        (flvector-ref p i)))))
              '(unchecked checked))

;; And the other way round: outside first, inside second, so a test that passed
;; by accident on ordering fails here.
(check-equal! "and it does not reach backwards either"
              (map (lambda (c) (cadr (assq 'bounds-check (cdr c))))
                   (controls (P '(begin (flvector-ref p i)
                                        (policy ((bounds-check #f))
                                          (flvector-ref p i))))))
              '(checked unchecked))

;; ===========================================================================
;; 2. nesting: inner overrides outer, and leaving restores
;; ===========================================================================

(check-equal! "an inner policy re-enables a check the outer one suppressed"
              (control-of (P '(policy ((bounds-check #f))
                                (policy ((bounds-check #t))
                                  (flvector-ref p i))))
                          'flvector-ref 'bounds-check)
              'checked)

;; Three accesses at three depths: outer off, inner on, then BACK OUT to the
;; outer scope. The third is what "restore" means, and it is free here because
;; the environment is a walk of the tree: the outer alist is still the one in
;; hand when the inner scope's walk returns.
(check-equal! "leaving the inner scope restores the outer policy"
              (map (lambda (c) (cadr (assq 'bounds-check (cdr c))))
                   (controls (P '(policy ((bounds-check #f))
                                   (begin (flvector-ref p i)
                                          (policy ((bounds-check #t))
                                            (flvector-ref p i))
                                          (flvector-ref p i))))))
              '(unchecked checked unchecked))

;; Independent names nest independently: an inner policy about one check must
;; not disturb an outer policy about another.
(check-equal! "nesting different names composes rather than replaces"
              (cdr (car (controls
                         (P '(policy ((type-check #f))
                               (policy ((bounds-check #f))
                                 (flvector-ref p i)))))))
              '((type-check unchecked) (bounds-check unchecked)))

;; ===========================================================================
;; 3. LEXICAL, not dynamic
;; ===========================================================================
;;
;; The sharpest statement of the difference. `f` is written outside the policy
;; and called inside it. Under a global dial or a dynamic parameter the access
;; in `f` would be suppressed; under a lexical form it is not, because the
;; policy is a property of the TEXT and `f`'s text is elsewhere.

(check-equal! "a procedure defined outside a policy is not affected by being called inside it"
              (control-of (P '(let ((f (lambda (i) (flvector-ref p i))))
                                (policy ((bounds-check #f)) (f 1))))
                          'flvector-ref 'bounds-check)
              'checked)

(check-equal! "a policy around a lambda does reach its body"
              (control-of (P '(policy ((bounds-check #f))
                                (lambda (i) (flvector-ref p i))))
                          'flvector-ref 'bounds-check)
              'unchecked)

;; ===========================================================================
;; 4. D24: fp-contract is a named permission in the same mechanism
;; ===========================================================================
;;
;; DEFAULT OFF, and that default is not a special case: every name in the policy
;; vocabulary starts with its conservative obligation in force, and for
;; fp-contract that obligation is "round twice, do not fuse". Off by default is
;; what keeps oracle check 2, the eleven-way bit-exact cross-agreement, which is
;; the strongest correctness evidence the project has. It was found by the
;; RISC-V smoke gate: RV64 gcc contracts to fmadd.d by default and baseline
;; x86-64 has no FMA to contract into.

(check-equal! "fp-contract is off by default, per D24"
              (control-of (P '(fl+ a b)) 'fl+ 'fp-contract)
              'checked)

(check-equal! "the same form that suppresses a check grants the permission"
              (control-of (P '(policy ((fp-contract #f)) (fl+ a b)))
                          'fl+ 'fp-contract)
              'unchecked)

(check-equal! "and it is lexically scoped like every other name"
              (map (lambda (c) (cadr (assq 'fp-contract (cdr c))))
                   (controls (P '(begin (policy ((fp-contract #f)) (fl+ a b))
                                        (fl+ a b)))))
              '(unchecked checked))

;; `fl/` has no fp-contract entry at all, so a policy naming it cannot invent
;; one. There is nothing to fuse in a divide.
(check-equal! "a policy cannot add a check the primitive does not carry"
              (cdr (car (controls (P '(policy ((fp-contract #f)) (fl/ a b))))))
              '())

;; ===========================================================================
;; 5. what it refuses
;; ===========================================================================

;; A policy naming a check that does not exist is a typo whose entire effect
;; would otherwise be silence. `policy-name?` is a terminal predicate in
;; lang.ss, so the term cannot even be built, and parse.ss says so by name.
(must-fail "an unknown check name is an error, not a no-op"
           (lambda () (P '(policy ((no-such-check #f)) (flvector-ref p i)))))

(must-fail "a plausible misspelling is refused too"
           (lambda () (P '(policy ((bounds-checks #f)) (flvector-ref p i)))))

;; A premise name is not a check name; `non-nan` is a fact about a value and
;; there is no `non-nan` check to suppress.
(must-fail "a premise name is not a policy name"
           (lambda () (P '(policy ((non-nan #f)) (fl< a b)))))

(must-fail "a policy setting must be a boolean, not a control word"
           (lambda () (P '(policy ((bounds-check unchecked)) (flvector-ref p i)))))

;; Two settings for one name in one form state two things at once, and picking
;; one of them is a coin toss.
(must-fail "one policy form naming the same check twice is refused"
           (lambda () (P '(policy ((bounds-check #f) (bounds-check #t))
                            (flvector-ref p i)))))

;; ===========================================================================
;; 6. the pass only ever weakens
;; ===========================================================================
;;
;; `proved` and `unchecked` emit the same code and mean very different things:
;; one is the analysis discharging an obligation, the other is the programmer
;; taking a permission. Keeping them distinct is what lets the report say how
;; many checks went away by proof and how many by permission. So a `proved`
;; control is never rewritten, in either direction.

(let* ([e (with-output-language (Lcore Expr)
            `(policy ([bounds-check #f])
               (primcall flvector-ref ([type-check proved] [bounds-check proved]) p i)))]
       [out (unparse-Lcore (resolve-policy e))])
  (check-equal! "a proved control is left alone by a suppressing policy"
                (cdr (car (controls out)))
                '((type-check proved) (bounds-check proved))))

(let* ([e (with-output-language (Lcore Expr)
            `(policy ([bounds-check #t])
               (primcall flvector-ref ([type-check checked] [bounds-check unchecked]) p i)))]
       [out (unparse-Lcore (resolve-policy e))])
  (check-equal! "an already-suppressed control is not put back by a re-enabling policy"
                (cdr (car (controls out)))
                '((type-check checked) (bounds-check unchecked))))

;; Idempotent, which follows from only-weakening and is worth pinning: running
;; the resolver twice must not drift.
(let ([once (resolve-policy (parse-expression
                             (expand-expression
                              '(policy ((bounds-check #f)) (flvector-ref p i)))))])
  (check-equal! "resolving twice is resolving once"
                (unparse-Lcore (resolve-policy once))
                (unparse-Lcore once)))

;; ===========================================================================
;; 7. the other declaration forms are reachable from source
;; ===========================================================================
;;
;; `declare` and `declare-distinct` are premises rather than permissions: the
;; programmer asserts a fact and the compiler believes it. Nothing checks them,
;; which is why an unknown premise name has to be refused here.

(check-equal! "declare-distinct reaches the core form"
              (P '(declare-distinct (p v) (flvector-ref p i)))
              '(declare-distinct (p v)
                 (primcall flvector-ref
                           ((type-check checked) (bounds-check checked)) p i)))

(check-equal! "declare reaches the core form"
              (P '(declare ((x fixnum)) x))
              '(declare ((x fixnum)) x))

(check! "a premise about NaN is expressible; it is what makes a false float edge usable"
        (equal? (P '(declare ((a non-nan)) a)) '(declare ((a non-nan)) a)))

(must-fail "an unknown premise name is an error"
           (lambda () (P '(declare ((x no-such-premise)) x))))

(must-fail "declare-distinct about one name asserts nothing and is refused"
           (lambda () (P '(declare-distinct (p) (flvector-ref p i)))))

;; ===========================================================================
;; 8. verified in EMITTED CODE
;; ===========================================================================
;;
;; The acceptance criterion, taken literally. (sonic lower) turns a surviving
;; check into a `chk` instruction in Lmach and DROPS the ones it does not have
;; to emit, counting `proved` and `unchecked` separately. So the question "did
;; the policy do anything" has an answer in instructions.
;;
;; `lower-expr` is straight-line only and consumes an Lrepr-shaped datum, so the
;; adapter below hangs a storage class on each binding and strips the
;; declaration wrappers, which carry no code. Nothing else is invented.

(define (to-repr f)
  (cond [(and (pair? f) (memq (car f) '(policy declare declare-distinct)))
         (to-repr (caddr f))]
        [(and (pair? f) (eq? (car f) 'let))
         (let ([b (car (cadr f))])
           `(let ((,(car b) raw-word ,(cadr b))) ,(to-repr (caddr f))))]
        [else f]))

;; surface -> Lmach instructions, through the whole front end.
(define (emit form)
  (let* ([core (resolve-policy (parse-expression (expand-expression form)))]
         [repr (to-repr (unparse-Lanf (anf core)))]
         [stats (make-lower-stats 0 0 0)])
    (let-values ([(is v) (lower-expr repr stats)])
      (values (filter (lambda (i) (eq? (car i) 'chk)) is) stats))))

(let-values ([(chks stats) (emit '(flvector-ref p i))])
  (check-equal! "unpoliced, both checks are emitted as instructions"
                (map cadr chks) '(type-check bounds-check))
  (check-equal! "and none is reported as suppressed"
                (lower-stats-unchecked stats) 0))

(let-values ([(chks stats) (emit '(policy ((bounds-check #f)) (flvector-ref p i)))])
  (check-equal! "the suppressed check emits NO instruction"
                (map cadr chks) '(type-check))
  (check-equal! "and is counted as suppressed by permission, not by proof"
                (list (lower-stats-unchecked stats) (lower-stats-proved stats))
                '(1 0))
  (check-equal! "one check still emitted"
                (lower-stats-emitted stats) 1))

(let-values ([(chks stats) (emit '(policy ((bounds-check #f) (type-check #f))
                                   (flvector-ref p i)))])
  (check-equal! "suppressing both leaves no check instruction at all"
                chks '())
  (check-equal! "both counted as permission"
                (lower-stats-unchecked stats) 2))

;; ===========================================================================
;; 9. a whole program, and it composes with A-normalization
;; ===========================================================================

(define (find-bench-dir)
  (let loop ([cands '("../bench/nbody/" "bench/nbody/" "./bench/nbody/")])
    (cond [(null? cands) #f]
          [(file-exists? (string-append (car cands) "config-sonic.sps")) (car cands)]
          [else (loop (cdr cands))])))

(define bench-dir (find-bench-dir))
(define nbody-externs '(command-line length cadr string->number display newline))

(newline)
(if (not bench-dir)
    (begin (printf "FAIL: cannot find bench/nbody; run this from sonic/\n")
           (set! failures (+ failures 1)))
    (let* ([source (read-all-from-file (string-append bench-dir "config-sonic.sps"))]
           [core (parse-program (expand-program source) nbody-externs)]
           [out (unparse-Lcore (resolve-policy-program core))]
           [cs (controls out)])
      (printf "bench/nbody/config-sonic.sps -> Lcore, policy resolved:\n")

      ;; This program writes no `policy`, so every check must still be on. A
      ;; resolver that weakened anything here would be weakening by default,
      ;; which is the opposite of D5.
      (check! "a program with no policy form keeps every check"
              (for-all (lambda (c)
                         (for-all (lambda (p) (eq? (cadr p) 'checked)) (cdr c)))
                       cs))

      (check! "including fp-contract on every flonum operation, per D24"
              (for-all (lambda (c)
                         (let ([p (assq 'fp-contract (cdr c))])
                           (or (not p) (eq? (cadr p) 'checked))))
                       cs))

      (check! "and it still A-normalizes"
              (guard (e (#t #f))
                (begin (anf-program (resolve-policy-program core)) #t)))

      (printf "  ~a primcalls, ~a named checks, all in force\n"
              (length cs)
              (apply + (map (lambda (c) (length (cdr c))) cs)))))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
