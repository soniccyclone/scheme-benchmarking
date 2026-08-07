;;; Surface to core.
;;;
;;; Two halves, and the second one is the acceptance criterion.
;;;
;;; UNIT. The decisions this pass makes, each isolated: primcall against call,
;;; arity, controls starting fully checked, the shape of `top`, and the four
;;; things it refuses. Refusals get as much room as acceptances, because the
;;; failure mode of a permissive parser is a wrong-code bug four stages later
;;; rather than an error here.
;;;
;;; ACCEPTANCE. `bench/nbody/config-sonic.sps` goes read -> expand -> parse and
;;; comes out as a valid Lcore program. "Valid" is not an assertion this file
;;; makes: nanopass checks every constructed term against the grammar, so a
;;; program that builds IS well formed, and what is checked here is that the
;;; result says what the source said -- three kernels with their arrays declared
;;; distinct, every flonum operation a primcall, nothing derived surviving.
;;;
;;; And the same file is RUN, under Chez, against SPEC.md's energies. A parser
;;; that accepts a program which computes the wrong numbers has proved nothing,
;;; so the benchmark's correctness is checked here rather than assumed.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/parse-test.ss
;;;      (from sonic/)

(import (chezscheme) (nanopass)
        (sonic lang) (sonic read) (sonic expand) (sonic parse))

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

(define (core x) (unparse-Lcore (parse-expression x)))

(define (find head form)
  (cond [(and (pair? form) (eq? (car form) head)) form]
        [(pair? form) (or (find head (car form)) (find head (cdr form)))]
        [else #f]))

(define (count head form)
  (cond [(and (pair? form) (eq? (car form) head))
         (+ 1 (apply + (map (lambda (f) (count head f)) (cdr form))))]
        [(pair? form) (+ (count head (car form)) (count head (cdr form)))]
        [else 0]))

(printf "surface to core:\n")

;; ===========================================================================
;; 1. the one decision: primcall or call
;; ===========================================================================

(check-equal! "a primitive head becomes a primcall, fully checked"
              (core '(flvector-ref a i))
              '(primcall flvector-ref ((type-check checked) (bounds-check checked)) a i))

(check-equal! "a primitive with no applicable check gets an empty control list"
              (core '(fx< a b))
              '(primcall fx< () a b))

(check-equal! "a non-primitive head is an ordinary call"
              (core '(helper a b))
              '(call helper a b))

(check-equal! "the operator of a call is itself an expression"
              (core '((chooser) a))
              '(call (call chooser) a))

;; A LOCAL named like a primitive shadows it. The expander renames binders, so
;; this cannot arise from real source; it can arise from hand-written core, and
;; the rule has to be the same one either way.
(check-equal! "a binding shadows the primitive of the same name"
              (core '(let ([fl+ helper]) (fl+ a b)))
              '(let ((fl+ helper)) (call fl+ a b)))

(must-fail "a primitive at the wrong arity is an error, not a silent call"
           (lambda () (parse-expression '(fl+ a b c))))

(must-fail "and at too few arguments too"
           (lambda () (parse-expression '(fl+ a))))

;; ===========================================================================
;; 2. the rest of the shape vocabulary
;; ===========================================================================

(check-equal! "quote" (core '(quote 1.5)) '(quote 1.5))
(check-equal! "the empty list is a datum" (core '(quote ())) '(quote ()))
(check-equal! "if" (core '(if a b c)) '(if a b c))
(check-equal! "lambda" (core '(lambda (x) x)) '(lambda (x) x))
(check-equal! "let" (core '(let ([x a]) x)) '(let ((x a)) x))
(check-equal! "letrec" (core '(letrec ([f a]) f)) '(letrec ((f a)) f))
(check-equal! "letrec*" (core '(letrec* ([f a]) f)) '(letrec* ((f a)) f))
(check-equal! "set!" (core '(set! x a)) '(set! x a))
(check-equal! "void" (core '(void)) '(void))
(check-equal! "a one-form begin collapses" (core '(begin a)) 'a)
(check-equal! "a longer begin does not" (core '(begin a b c)) '(begin a b c))
(check-equal! "policy" (core '(policy ([bounds-check #f]) a))
              '(policy ((bounds-check #f)) a))
(check-equal! "declare-distinct" (core '(declare-distinct (a b) a))
              '(declare-distinct (a b) a))

(check-equal! "declare carries a premise name"
              (car (find 'declare (core (list 'declare
                                              (list (list 'a (car (all-premise-names))))
                                              'a))))
              'declare)

;; --- refusals --------------------------------------------------------------

(must-fail "a quoted pair has no core form"
           (lambda () (parse-expression '(quote (1 2)))))
(must-fail "a quoted vector has no core form"
           (lambda () (parse-expression '(quote #(1 2)))))
(must-fail "an empty begin has no value"
           (lambda () (parse-expression '(begin))))
(must-fail "a two-armed if never reaches here"
           (lambda () (parse-expression '(if a b))))
(must-fail "a rest parameter is refused"
           (lambda () (parse-expression '(lambda x x))))
(must-fail "a policy setting must be a boolean"
           (lambda () (parse-expression '(policy ([bounds-check maybe]) a))))
(must-fail "a policy name must be a check name"
           (lambda () (parse-expression '(policy ([nonsense #f]) a))))
(must-fail "an improper application is refused"
           (lambda () (parse-expression '(f . a))))

;; ===========================================================================
;; 3. programs
;; ===========================================================================

(check-equal! "definitions become the binding group of `top`"
              (unparse-Lcore (parse-program '((define a (quote 1))
                                              (define b (quote 2))
                                              (fl+ a b))))
              '(top ((a (quote 1)) (b (quote 2)))
                    ()
                    (primcall fl+ ((fp-contract checked)) a b)))

(check-equal! "a program of definitions alone still has a body"
              (unparse-Lcore (parse-program '((define a (quote 1)))))
              '(top ((a (quote 1))) () (void)))

(check-equal! "an import header is not an expression"
              (unparse-Lcore (parse-program '((import (rnrs base)) (define a (quote 1)))))
              '(top ((a (quote 1))) () (void)))

(check-equal! "several trailing expressions become one begin"
              (unparse-Lcore (parse-program '((define a (quote 1)) a a)))
              '(top ((a (quote 1))) () (begin a a)))

;; Externs are declared, and that is what makes an unbound variable a bug again.
(check-equal! "a declared extern may be referenced"
              (unparse-Lcore (parse-program '((define a (display (quote 1)))) '(display)))
              '(top ((a (call display (quote 1)))) (display) (void)))

(must-fail "an undeclared free variable is an error"
           (lambda () (parse-program '((define a (display (quote 1)))))))

(must-fail "a definition after an expression cannot be expressed by `top`"
           (lambda () (parse-program '((define a (quote 1)) a (define b (quote 2))))))

(must-fail "a name defined twice is ambiguous in `top`"
           (lambda () (parse-program '((define a (quote 1)) (define a (quote 2))))))

(must-fail "a name cannot be both defined here and declared extern"
           (lambda () (parse-program '((define a (quote 1))) '(a))))

;; A top-level definition shadows a primitive for the whole program, because
;; top-level names are not renamed.
(check-equal! "a top-level define shadows a primitive"
              (unparse-Lcore (parse-program '((define car (lambda (x) x))
                                              (car (quote 1)))))
              '(top ((car (lambda (x) x))) () (call car (quote 1))))

;; ===========================================================================
;; 4. the acceptance criterion: bench/nbody/config-sonic.sps
;; ===========================================================================

(define (find-bench-dir)
  (let loop ([cands '("../bench/nbody/" "bench/nbody/" "./bench/nbody/")])
    (cond [(null? cands) #f]
          [(file-exists? (string-append (car cands) "config-sonic.sps")) (car cands)]
          [else (loop (cdr cands))])))

(define bench-dir (find-bench-dir))

;; What the program uses that this compilation unit does not define. Naming them
;; is the point of Lcore's extern list: anything not here and not defined is a
;; typo, and `parse-program` says so.
(define nbody-externs '(command-line length cadr string->number display newline))

;; Nothing derived may survive expansion, and nothing surface-only may survive
;; parsing.
(define banned
  '(define-syntax syntax-rules let-syntax letrec-syntax
    let* when unless cond else => and or define import))

(define (survivors form)
  (let scan ([d form] [acc '()])
    (cond [(and (pair? d) (eq? (car d) 'quote)) acc]
          [(pair? d) (scan (cdr d) (scan (car d) acc))]
          [(and (symbol? d) (memq d banned) (not (memq d acc))) (cons d acc)]
          [else acc])))

(newline)
(if (not bench-dir)
    (begin (printf "FAIL: cannot find bench/nbody; run this from sonic/\n")
           (set! failures (+ failures 1)))
    (let* ([source (read-all-from-file (string-append bench-dir "config-sonic.sps"))]
           [expanded (expand-program source)]
           [prog (parse-program expanded nbody-externs)]
           [out (unparse-Lcore prog)])
      (printf "bench/nbody/config-sonic.sps -> Lcore:\n")

      (check-equal! "it is a `top`" (car out) 'top)
      (check-equal! "with the declared externs" (caddr out) nbody-externs)
      (check-equal! "nothing derived or surface-only survives" (survivors out) '())

      (check-equal! "the three kernels' distinctness premises are in the core form"
                    (count 'declare-distinct out) 3)

      ;; Every flonum and fixnum operation is a primcall with its checks on.
      ;; If any of them had fallen through to `call`, the program would still
      ;; parse and the analysis would have nothing to discharge.
      (check! "the flonum work is primcalls, not calls"
              (> (count 'primcall out) 100))
      (check! "every flvector access carries type-check and bounds-check"
              (let scan ([d out] [ok #t])
                (cond [(not ok) #f]
                      [(and (pair? d) (eq? (car d) 'primcall)
                            (memq (cadr d) '(flvector-ref flvector-set!)))
                       (and (equal? (map car (caddr d)) '(type-check bounds-check))
                            (for-all (lambda (c) (eq? (cadr c) 'checked)) (caddr d))
                            (scan (cdddr d) #t))]
                      [(pair? d) (scan (cdr d) (scan (car d) #t))]
                      [else ok])))

      ;; Named let is the only loop this program has, and it becomes a letrec of
      ;; a lambda, so a surviving `let` with a symbol where the bindings go would
      ;; mean the expander leaked one through.
      (check-equal! "no named let survives"
                    (let scan ([d out] [n 0])
                      (cond [(and (pair? d) (eq? (car d) 'quote)) n]
                            [(and (pair? d) (eq? (car d) 'let)
                                  (pair? (cdr d)) (symbol? (cadr d)))
                             (+ n 1)]
                            [(pair? d) (scan (cdr d) (scan (car d) n))]
                            [else n]))
                    0)

      ;; NOTHING IS MUTATED. Worth stating as a measurement rather than as a
      ;; remark: nbody written this way assigns no local at all, so assignment
      ;; conversion boxes nothing and not one flonum local leaves a float
      ;; register. Every update goes through `flvector-set!`, and every loop
      ;; carries its state in parameters of a tail call.
      (check-equal! "no local is assigned, so nothing needs boxing"
                    (count 'set! out) 0)

      (printf "  ~a top-level definitions, ~a primcalls, ~a set! forms\n"
              (length (cadr out)) (count 'primcall out) (count 'set! out))

      ;; --- and it computes the right numbers --------------------------------
      ;;
      ;; Under Chez, with the four declaration forms supplied as no-ops by
      ;; bench/nbody/sonic-compat.sls. Dropping a premise is always sound; that
      ;; is what makes the same file both a SonicScheme benchmark and a Chez
      ;; program whose energy can be checked against SPEC.md.
      (library-directories (cons bench-dir (library-directories)))
      (let* ([host (environment '(chezscheme) '(sonic-compat))]
             [defs (filter (lambda (f)
                             (and (pair? f) (memq (car f) '(define define-syntax))))
                           source)]
             [run (lambda (probe) (eval (cons 'let (cons '() (append defs probe))) host))]
             ;; SPEC.md states the energies to nine decimal places, so compare
             ;; at that precision and no further: `ref.c` prints %.9f.
             [nine (lambda (x) (exact (round (* x 1e9))))])
        (check-equal! "energy at step 0 matches SPEC.md"
                      (nine (run '((init!)
                                   (offset-momentum! vel mass)
                                   (energy pos vel mass))))
                      -169075164)
        (check-equal! "energy after 1000 steps matches SPEC.md"
                      (nine (run '((init!)
                                   (offset-momentum! vel mass)
                                   (let loop ((i 0))
                                     (when (fx< i 1000)
                                       (advance! pos vel mass)
                                       (loop (fx+ i 1))))
                                   (energy pos vel mass))))
                      -169087605))))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
