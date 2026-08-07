;;; SonicScheme: surface to core. Expander output in, Lcore out.
;;;
;;; Stage 03. `(sonic expand)` hands over an s-expression in a fixed, tiny shape
;;; vocabulary and this file turns it into a typed Lcore term. From here on
;;; nanopass checks every pass against a declared grammar; before here, nothing
;;; does.
;;;
;;; THE ONE DECISION THIS PASS MAKES, and it is the reason the expander refused
;;; to make it: whether `(fl+ a b)` is a `primcall` or an ordinary `call`. That
;;; is a question about what a NAME MEANS, and the expander deals only in shape.
;;; The answer here is: the head is a `primcall` when it is a symbol in
;;; `prim-table` that nothing has bound. Lexical bindings rarely interfere,
;;; because the expander alpha-renames every binder to `name%N`, so a user's
;;; local named `fl+` never reaches this file spelled `fl+`; top-level names are
;;; NOT renamed, so a program that defines its own `car` shadows the primitive.
;;; Either way the rule is the same one: bound wins over primitive.
;;;
;;; ARITY IS CHECKED HERE and a mismatch is an error rather than a fallback to
;;; `call`. lang.ss states an arity for every primitive precisely so that no
;;; variadic flonum op can exist (association order is observable in the result
;;; bits), and silently demoting `(fl+ a b c)` to a call to an undefined global
;;; would hide the mistake until link time.
;;;
;;; CONTROLS START FULLY CHECKED. Every `primcall` is built with
;;; `default-controls`, which is `checked` for each check the primitive can
;;; carry. `policy` weakens them by permission and the analysis discharges them
;;; by proof; nothing else may, and neither of those is this pass.
;;;
;;; EXTERNS ARE DECLARED, NOT INFERRED. `Lcore`'s `top` carries a second list
;;; naming what lives outside the compilation unit, and this pass enforces it:
;;; a variable that is neither bound nor named there is an error. Inferring the
;;; list from the free variables instead would make it unfalsifiable, which is
;;; the state lang.ss added the list to get out of -- a typo and a deliberate
;;; external reference would again be the same thing.
;;;
;;; --- WHAT THIS PASS REFUSES ------------------------------------------------
;;;
;;;   * A QUOTED NON-ATOM. `datum?` in lang.ss admits numbers, booleans, chars,
;;;     strings, the empty list and symbols. It does not admit pairs or vectors,
;;;     so `(quote (1 2))` has no Lcore representation. Refused loudly rather
;;;     than flattened into a `cons` chain, which would silently allocate on
;;;     every evaluation of what the programmer wrote as a constant.
;;;   * A TOP-LEVEL DEFINITION AFTER A TOP-LEVEL EXPRESSION. Lcore's Program is
;;;     `(top ([x e] ...) (ext ...) body)`: one binding group, then one body. A
;;;     file that interleaves them has an evaluation order that shape cannot
;;;     express, and hoisting the definitions would move side effects past each
;;;     other.
;;;   * A REDEFINED TOP-LEVEL NAME. Two bindings for one name in `top` is
;;;     ambiguous. Redefinition at the top level is a runtime store into a
;;;     global cell (see `(sonic gcell)`), not a second binding form.
;;;
;;; --- ONE KNOWN WART, RECORDED RATHER THAN WORKED AROUND --------------------
;;;
;;; The expander spells the unspecified value `(quote ())`, which is what it had
;;; before Lcore grew `(void)`. So a one-armed `if` that does not fire arrives
;;; here as the empty list, which is TRUTHY, and this pass cannot tell it from a
;;; `'()` the programmer wrote. `(void)` is parsed when it appears, so the fix
;;; is one line in `expand.ss` (`unspecified-expr`), not here; changing it here
;;; would break every real `'()` in the benchmark set.
;;;
;;; Run the tests: scheme -q --libdirs src:vendor/nanopass --script test/parse-test.ss

(library (sonic parse)
  (export parse-program parse-expression
          parse-top-level-names)
  (import (chezscheme) (nanopass) (sonic lang))

  (define (ps-error msg . irritants)
    (apply error 'parse msg irritants))

  ;; --- context -------------------------------------------------------------
  ;;
  ;; `externs` is the declared outside world. `check?` is off for
  ;; `parse-expression`, which has no program around it and therefore no list to
  ;; check against; a bare expression's free variables are its interface.
  (define-record-type pctx (fields externs check?))

  (define (known? ctx bound x)
    (or (memq x bound)
        (not (pctx-check? ctx))
        (memq x (pctx-externs ctx))))

  (define (reference! ctx bound x)
    (unless (known? ctx bound x)
      (ps-error "unbound variable; if it is outside this compilation unit, name it in the extern list"
                x))
    x)

  ;; --- shapes the expander emits -------------------------------------------
  ;;
  ;; Recognised by NAME. A binding of one of these names wins, which is the same
  ;; rule the expander applies and the same rule primitives get below.
  (define core-forms
    '(quote if lambda let letrec letrec* begin set! declare declare-distinct
      policy void))

  (define (head-form? h bound)
    (and (symbol? h) (memq h core-forms) (not (memq h bound)) h))

  (define (prim-head? h bound)
    (and (symbol? h) (primitive? h) (not (memq h bound))))

  ;; --- expressions ---------------------------------------------------------

  (define (Expr form ctx bound)
    (with-output-language (Lcore Expr)
      (cond
       [(symbol? form) (reference! ctx bound form) `,form]
       [(not (pair? form))
        (ps-error "not an expression; the expander emits only symbols and lists"
                  form)]
       [(head-form? (car form) bound)
        => (lambda (w) (Special w form ctx bound))]
       [else (Application form ctx bound)])))

  (define (Expr* forms ctx bound)
    (map (lambda (f) (Expr f ctx bound)) forms))

  (define (fixed-length! form n what)
    (unless (and (list? form) (= (length form) n)) (ps-error what form)))

  ;; `([a b] ...)`, with each half validated.
  (define (pairs-of form what ok-car? ok-cadr?)
    (let ([bs (cadr form)])
      (unless (list? bs) (ps-error what form))
      (for-each (lambda (b)
                  (unless (and (list? b) (= (length b) 2)
                               (ok-car? (car b)) (ok-cadr? (cadr b)))
                    (ps-error what form)))
                bs)
      bs))

  (define (anything x) #t)

  (define (Special which form ctx bound)
    (with-output-language (Lcore Expr)
      (case which
        [(quote)
         (fixed-length! form 2 "malformed quote")
         (let ([d (cadr form)])
           (unless (datum? d)
             (ps-error "Lcore's quote holds one atom; a quoted pair or vector has no core form"
                       d))
           `(quote ,d))]

        [(if)
         ;; Always three-armed. The expander fills the missing alternative in
         ;; with its unspecified value, so a two-armed `if` never gets here.
         (fixed-length! form 4 "malformed if; the expander emits both arms")
         `(if ,(Expr (cadr form) ctx bound)
              ,(Expr (caddr form) ctx bound)
              ,(Expr (cadddr form) ctx bound))]

        [(lambda)
         (fixed-length! form 3 "malformed lambda")
         (let ([x* (cadr form)])
           (unless (and (list? x*) (for-all symbol? x*))
             (ps-error "Lcore's lambda has no rest parameter" form))
           `(lambda (,x* ...) ,(Expr (caddr form) ctx (append x* bound))))]

        [(let letrec letrec*)
         (let* ([what (string-append "malformed " (symbol->string which))]
                [_ (fixed-length! form 3 what)]
                [bs (pairs-of form what symbol? anything)]
                [x* (map car bs)]
                ;; `let` evaluates its inits OUTSIDE the new scope; the two
                ;; letrecs evaluate them inside it.
                [inner (append x* bound)]
                [init-scope (if (eq? which 'let) bound inner)]
                [e* (map (lambda (b) (Expr (cadr b) ctx init-scope)) bs)]
                [body (Expr (caddr form) ctx inner)])
           (case which
             [(let)     `(let ([,x* ,e*] ...) ,body)]
             [(letrec)  `(letrec ([,x* ,e*] ...) ,body)]
             [else      `(letrec* ([,x* ,e*] ...) ,body)]))]

        [(begin)
         (unless (and (list? form) (>= (length form) 2))
           (ps-error "an empty begin has no value" form))
         (Seq (Expr* (cdr form) ctx bound))]

        [(set!)
         (fixed-length! form 3 "malformed set!")
         (unless (symbol? (cadr form)) (ps-error "set! needs an identifier" form))
         (reference! ctx bound (cadr form))
         `(set! ,(cadr form) ,(Expr (caddr form) ctx bound))]

        [(declare)
         (fixed-length! form 3 "malformed declare")
         (let* ([ps (pairs-of form "malformed declare" symbol? symbol?)]
                [x* (map (lambda (p) (reference! ctx bound (car p))) ps)]
                [prem* (map cadr ps)])
           (for-each (lambda (prem)
                       (unless (premise-name? prem)
                         (ps-error "not a premise name" prem)))
                     prem*)
           `(declare ([,x* ,prem*] ...) ,(Expr (caddr form) ctx bound)))]

        [(declare-distinct)
         (fixed-length! form 3 "malformed declare-distinct")
         (let ([x* (cadr form)])
           (unless (and (list? x*) (for-all symbol? x*) (>= (length x*) 2))
             (ps-error "declare-distinct takes two or more identifiers" form))
           (for-each (lambda (x) (reference! ctx bound x)) x*)
           `(declare-distinct (,x* ...) ,(Expr (caddr form) ctx bound)))]

        [(policy)
         (fixed-length! form 3 "malformed policy")
         (let* ([ss (pairs-of form "malformed policy" symbol? boolean?)]
                [pn* (map car ss)]
                [b* (map cadr ss)])
           (for-each (lambda (pn)
                       (unless (policy-name? pn) (ps-error "not a check name" pn)))
                     pn*)
           `(policy ([,pn* ,b*] ...) ,(Expr (caddr form) ctx bound)))]

        [(void)
         (fixed-length! form 1 "void takes no arguments")
         `(void)]

        [else (ps-error "unhandled core form" which)])))

  ;; `(begin e* ... e)` from a non-empty list of already-parsed expressions.
  (define (Seq e*)
    (with-output-language (Lcore Expr)
      (if (null? (cdr e*))
          (car e*)
          (let* ([n (length e*)]
                 [front (list-head e* (- n 1))]
                 [last (list-ref e* (- n 1))])
            `(begin ,front ... ,last)))))

  ;; The primitive-or-call decision, and nothing else happens here.
  (define (Application form ctx bound)
    (unless (list? form)
      (ps-error "an application must be a proper list" form))
    (let ([h (car form)] [args (cdr form)])
      (with-output-language (Lcore Expr)
        (if (prim-head? h bound)
            (let ([want (prim-arity h)])
              (unless (= want (length args))
                (ps-error "primitive applied at the wrong arity" h want (length args)))
              (let* ([e* (Expr* args ctx bound)]
                     [ctl (default-controls h)]
                     [pn* (map car ctl)]
                     [c* (map cadr ctl)])
                `(primcall ,h ([,pn* ,c*] ...) ,e* ...)))
            `(call ,(Expr h ctx bound) ,(Expr* args ctx bound) ...)))))

  ;; --- programs ------------------------------------------------------------

  (define (definition? f)
    (and (pair? f) (eq? (car f) 'define) (list? f) (= (length f) 3)
         (symbol? (cadr f))))

  (define (import-header? f) (and (pair? f) (eq? (car f) 'import)))

  ;; The top-level names a program claims, in source order. Exported because the
  ;; shadowing rule above is a fact other stages may want to ask about.
  (define (parse-top-level-names forms)
    (let loop ([fs forms] [acc '()])
      (cond [(null? fs) (reverse acc)]
            [(definition? (car fs)) (loop (cdr fs) (cons (cadr (car fs)) acc))]
            [else (loop (cdr fs) acc)])))

  ;; (parse-program forms)          externs are empty, so every free variable
  ;;                                is an error
  ;; (parse-program forms externs)  the declared outside world
  (define parse-program
    (case-lambda
      [(forms) (parse-program forms '())]
      [(forms externs)
       (unless (list? forms)
         (ps-error "parse-program takes a list of top-level forms"))
       (unless (and (list? externs) (for-all symbol? externs))
         (ps-error "the extern list is a list of identifiers" externs))
       (let* ([names (parse-top-level-names forms)]
              [ctx (make-pctx externs #t)])
         (let dup ([ns names] [seen '()])
           (cond [(null? ns) 'ok]
                 [(memq (car ns) seen)
                  (ps-error "top-level name defined twice; redefinition is a store into a global cell, not a second binding"
                            (car ns))]
                 [else (dup (cdr ns) (cons (car ns) seen))]))
         (for-each (lambda (n)
                     (when (memq n externs)
                       (ps-error "a name is both defined here and declared extern" n)))
                   names)
         (let loop ([fs forms] [x* '()] [e* '()] [body '()])
           (cond
            [(null? fs)
             ;; Top-level bindings are mutually recursive, so every definition's
             ;; value is parsed with every top-level name in scope.
             (let ([n* (reverse x*)]
                   [v* (map (lambda (f) (Expr f ctx names)) (reverse e*))]
                   [b (Body (reverse body) ctx names)]
                   [ext externs])
               (with-output-language (Lcore Program)
                 `(top ([,n* ,v*] ...) (,ext ...) ,b)))]
            [(import-header? (car fs))
             ;; A library header, not an expression. Whoever resolves libraries
             ;; wants it; Lcore has nothing to hold it and nothing to do with it.
             (loop (cdr fs) x* e* body)]
            [(definition? (car fs))
             (unless (null? body)
               (ps-error "a top-level definition after a top-level expression; Lcore's `top` is one binding group then one body"
                         (cadr (car fs))))
             (loop (cdr fs) (cons (cadr (car fs)) x*)
                   (cons (caddr (car fs)) e*) body)]
            [(and (pair? (car fs)) (eq? (car (car fs)) 'define))
             (ps-error "malformed top-level define" (car fs))]
            [else (loop (cdr fs) x* e* (cons (car fs) body))])))]))

  (define (Body forms ctx bound)
    (with-output-language (Lcore Expr)
      ;; A program that is definitions and nothing else still has to have a
      ;; body, and the unspecified value is the honest one to give it.
      (if (null? forms)
          `(void)
          (Seq (Expr* forms ctx bound)))))

  ;; One expression, with no program around it. For tests and for anything that
  ;; wants to look at a single form; free variables are its interface rather
  ;; than an error, because there is no extern list to check them against.
  (define (parse-expression form)
    (Expr form (make-pctx '() #f) '()))
  )
