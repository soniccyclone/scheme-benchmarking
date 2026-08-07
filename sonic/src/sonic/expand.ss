;;; SonicScheme: the syntax-rules expander.
;;;
;;; Stage 02. Datum in, datum out. The reader's output goes in; what comes out
;;; is the same s-expression language with every macro use and every derived
;;; form gone, leaving only the shapes stage 03 has to recognise:
;;;
;;;   (quote d)   (if e0 e1 e2)   (lambda (x ...) e)   (let ([x e] ...) e)
;;;   (letrec ([x e] ...) e)      (begin e e ...)      (set! x e)
;;;   (declare ([x pn] ...) e)    (policy ([pn b] ...) e)
;;;   (declare-distinct (x ...) e)
;;;   (define x e)                                  -- top level only
;;;   (e0 e1 ...)                                   -- an application
;;;
;;; Applications stay bare rather than becoming `call` or `primcall`. Choosing
;;; between those two needs the primitive table, and that is a decision about
;;; what a name MEANS, not about what shape it has, so it belongs to stage 03.
;;; Everything here is shape.
;;;
;;; `syntax-rules` only, per docs/phases/07-compiler/PLAN.md. No syntax-case, no
;;; procedural transformers, no identifier macros.
;;;
;;; --- HYGIENE ---------------------------------------------------------------
;;;
;;; Two renamings, and every hygiene property falls out of them.
;;;
;;; 1. BINDERS ARE ALPHA-RENAMED. Every `lambda`, `let`, `letrec`, named `let`,
;;;    internal `define` and expander-introduced temporary binds a FRESH symbol,
;;;    and the environment maps the source identifier to it. Two distinct
;;;    bindings therefore never share an output name, whoever wrote them.
;;;
;;; 2. TEMPLATE IDENTIFIERS ARE ALIASED. When a macro fires, every symbol in the
;;;    template that is not a pattern variable is replaced by a fresh symbol,
;;;    once per expansion, and `aliases` records `fresh -> (original . def-env)`
;;;    where def-env is the environment where the macro was DEFINED. Identifier
;;;    resolution consults the lexical frames, then the globals, then follows the
;;;    alias into its definition environment.
;;;
;;; The two capture directions die separately, which is the point:
;;;
;;;   * a macro-introduced BINDER cannot capture a user variable, because (1)
;;;     gives it a fresh output name and the user's reference resolves through
;;;     the use-site environment to a different one;
;;;   * a user BINDER cannot capture a macro-introduced reference, because (2)
;;;     makes that reference resolve in the macro's definition environment, which
;;;     the use site cannot reach into.
;;;
;;; Keywords go through the same door. `if`, `lambda` and friends are ordinary
;;; entries in the global environment rather than symbols compared with `eq?`,
;;; so a user who binds a variable named `if` shadows the special form exactly
;;; the way the standard says, and a macro whose template says `if` still gets
;;; the special form because its alias resolves in the definition environment.
;;;
;;; `literals` are compared by DENOTATION, not by name: an input identifier
;;; matches a literal when both resolve to the same binding, or when both are
;;; unbound and spell the same name. That is R7RS 4.3.2 and it is the reason
;;; `else` in a macro-generated `cond` keeps working after a user binds `else`.
;;;
;;; Fresh names are `base%N`. The counter skips any symbol that occurs anywhere
;;; in the source program, which is collected once up front, so a generated name
;;; can never collide with one the programmer wrote.
;;;
;;; --- WHAT Lcore DOES NOT HAVE ----------------------------------------------
;;;
;;; Recorded here rather than worked around silently:
;;;
;;;   * No unspecified value. `(when #f 1)`, a one-armed `if` and a body with no
;;;     value all need one. This file spells it `(quote ())`, defined once as
;;;     `unspecified-expr`, and that is a lie with a known shape rather than a
;;;     scattered one.
;;;   * No `set!`. The hygiene torture cases are written around `swap!`, which is
;;;     assignment, and any real program mutates. `set!` is emitted; stage 03 has
;;;     nothing in Lcore to put it in.
;;;   * No `define`. Top-level definitions are emitted as `define` forms;
;;;     INTERNAL ones are reduced to `letrec` here, since Lcore has letrec.
;;;   * No rest parameters. Lcore's lambda is `(lambda (x* ...) body)`, so
;;;     `(lambda args ...)` and `(lambda (a . rest) ...)` are refused loudly.
;;;   * `letrec*` is emitted as `letrec`. Lcore has only the unordered one, and
;;;     the sequential guarantee is lost at that point.
;;;
;;; Run the tests: scheme -q --libdirs src:vendor/nanopass --script test/expand-test.ss

(library (sonic expand)
  (export expand-program expand-expression)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs hashtables))

  ;; --- errors ---------------------------------------------------------------

  (define (ex-error msg . irritants)
    (apply error 'expand msg irritants))

  ;; --- the value Lcore does not have ----------------------------------------
  ;; One spelling, one place to change it when Lcore grows a void.

  (define unspecified-expr '(quote ()))

  ;; --- expander state -------------------------------------------------------
  ;;
  ;; Reset at the top of every entry point. Whole-program state rather than a
  ;; threaded context record: the counter and the alias table are consulted from
  ;; every corner of the walk, and threading them would put a parameter on every
  ;; helper for no gain in clarity.

  (define counter 0)
  (define used-symbols (make-eq-hashtable))
  (define aliases (make-eq-hashtable))
  (define globals (make-eq-hashtable))

  (define (reset-state!)
    (set! counter 0)
    (set! used-symbols (make-eq-hashtable))
    (set! aliases (make-eq-hashtable))
    (set! globals (make-eq-hashtable))
    (for-each (lambda (name) (hashtable-set! globals name (make-special name)))
              special-forms))

  ;; Every symbol the programmer wrote, so `fresh` can avoid all of them.
  (define (note-symbols! d)
    (cond ((symbol? d) (hashtable-set! used-symbols d #t))
          ((pair? d) (note-symbols! (car d)) (note-symbols! (cdr d)))
          ((vector? d)
           (let loop ((i 0))
             (when (< i (vector-length d))
               (note-symbols! (vector-ref d i))
               (loop (+ i 1)))))
          (else 'nothing)))

  (define (fresh base)
    (let loop ()
      (set! counter (+ counter 1))
      (let ((s (string->symbol
                (string-append (symbol->string base) "%"
                               (number->string counter)))))
        (if (hashtable-ref used-symbols s #f)
            (loop)
            (begin (hashtable-set! used-symbols s #t) s)))))

  ;; --- identifiers ----------------------------------------------------------
  ;;
  ;; An identifier is a symbol. Some symbols are aliases created by template
  ;; instantiation; `id-name` walks back to whatever the programmer typed, which
  ;; is what gets emitted for a free reference and what appears inside `quote`.

  (define (id-name id)
    (let ((a (hashtable-ref aliases id #f)))
      (if a (id-name (car a)) id)))

  ;; Aliases are an expander artefact. Nothing downstream, and nothing inside a
  ;; quoted datum, may ever see one.
  (define (strip d)
    (cond ((symbol? d) (id-name d))
          ((pair? d) (cons (strip (car d)) (strip (cdr d))))
          ((vector? d)
           (let* ((n (vector-length d)) (v (make-vector n #f)))
             (let loop ((i 0))
               (if (= i n)
                   v
                   (begin (vector-set! v i (strip (vector-ref d i)))
                          (loop (+ i 1)))))))
          (else d)))

  ;; --- denotations ----------------------------------------------------------

  ;; Vectors rather than pairs so that `letrec-syntax` can tie its own knot: the
  ;; keywords have to be in scope while their own transformers are parsed, so the
  ;; denotation is created empty and filled in.
  (define (make-variable name) (vector 'variable name))
  (define (make-macro tx) (vector 'macro tx))
  (define (make-special name) (vector 'special name))

  (define (denotation? d) (and (vector? d) (= (vector-length d) 2)))
  (define (den-kind d) (vector-ref d 0))
  (define (den-value d) (vector-ref d 1))
  (define (set-den-value! d v) (vector-set! d 1 v))

  (define (variable? d) (and (denotation? d) (eq? (den-kind d) 'variable)))
  (define (macro? d) (and (denotation? d) (eq? (den-kind d) 'macro)))
  (define (special? d) (and (denotation? d) (eq? (den-kind d) 'special)))

  (define (special-is? d name) (and (special? d) (eq? (den-value d) name)))

  ;; --- environments ---------------------------------------------------------
  ;;
  ;; An environment is an alist of lexical frames. The global environment is a
  ;; hashtable, because the top level is mutable and sequential: a `define` seen
  ;; now must be visible to a reference expanded later.

  (define empty-env '())

  (define (extend env id den) (cons (cons id den) env))

  (define (extend* env ids dens)
    (if (null? ids)
        env
        (extend* (extend env (car ids) (car dens)) (cdr ids) (cdr dens))))

  ;; Lexical frames, then the top level, then the alias's own definition
  ;; environment. The order matters: an alias that a template BOUND (or that a
  ;; top-level define claimed) must be found as itself before the chain is
  ;; followed back to the identifier it was made from.
  (define (lookup id env)
    (cond ((assq id env) => cdr)
          ((hashtable-ref globals id #f))
          ((hashtable-ref aliases id #f)
           => (lambda (a) (lookup (car a) (cdr a))))
          (else #f)))

  ;; R7RS 4.3.2's identifier equivalence, used for the literals list.
  (define (id=? id1 env1 id2 env2)
    (let ((d1 (lookup id1 env1)) (d2 (lookup id2 env2)))
      (if (or d1 d2)
          (eq? d1 d2)
          (eq? (id-name id1) (id-name id2)))))

  ;; --- special forms --------------------------------------------------------

  (define special-forms
    '(quote if lambda let let* letrec letrec* begin set!
      define define-syntax let-syntax letrec-syntax
      syntax-rules when unless cond and or else =>
      declare declare-distinct policy import))

  ;; --- syntax-rules transformers --------------------------------------------
  ;;
  ;; A transformer is parsed once, at `define-syntax` time, and the templates are
  ;; validated then. A depth error is a property of the macro, not of any
  ;; particular use, so reporting it at the definition is both earlier and more
  ;; useful than reporting it at the first call.

  (define (make-transformer ellipsis literals rules def-env)
    (vector 'sr ellipsis literals rules def-env))
  (define (tx-ellipsis tx) (vector-ref tx 1))
  (define (tx-literals tx) (vector-ref tx 2))
  (define (tx-rules tx) (vector-ref tx 3))     ; ((pat-tail depths template) ...)
  (define (tx-def-env tx) (vector-ref tx 4))

  (define (ellipsis-id? id ellipsis)
    (and (symbol? id) (eq? (id-name id) ellipsis)))

  (define (underscore? id) (and (symbol? id) (eq? (id-name id) '_)))

  (define (parse-transformer spec env)
    (unless (and (pair? spec)
                 (symbol? (car spec))
                 (special-is? (lookup (car spec) env) 'syntax-rules))
      (ex-error "only syntax-rules transformers are supported" (strip spec)))
    (let* ((rest (cdr spec))
           (custom (and (pair? rest) (symbol? (car rest))))
           (ellipsis (if custom (id-name (car rest)) '...))
           (rest (if custom (cdr rest) rest)))
      (unless (and (pair? rest) (list? (car rest)) (for-all symbol? (car rest)))
        (ex-error "syntax-rules needs a list of literals" (strip spec)))
      (let ((literals (car rest))
            (clauses (cdr rest)))
        (unless (list? clauses) (ex-error "malformed syntax-rules" (strip spec)))
        (make-transformer
         ellipsis literals
         (map (lambda (clause)
                (unless (and (pair? clause) (pair? (cdr clause)) (null? (cddr clause)))
                  (ex-error "a syntax-rules clause is (pattern template)"
                            (strip clause)))
                (let ((pat (car clause)) (tmpl (cadr clause)))
                  (unless (pair? pat)
                    (ex-error "a syntax-rules pattern must be a list" (strip pat)))
                  ;; The keyword position of the pattern is ignored, per R7RS.
                  (let ((tail (cdr pat)))
                    (let ((depths (pattern-vars tail ellipsis literals)))
                      (validate-template tmpl depths ellipsis)
                      (list tail depths tmpl)))))
              clauses)
         env))))

  ;; --- patterns -------------------------------------------------------------

  ;; alist of (var . depth). Raises on a repeated variable, which is always a
  ;; mistake and is otherwise silently resolved in favour of one of them.
  (define (pattern-vars pat ellipsis literals)
    (let walk ((p pat) (d 0) (acc '()))
      (cond
        ((symbol? p)
         (cond ((ellipsis-id? p ellipsis) acc)
               ((underscore? p) acc)
               ((memq p literals) acc)
               ((assq p acc)
                (ex-error "pattern variable appears twice in one pattern" (id-name p)))
               (else (cons (cons p d) acc))))
        ((pair? p)
         (if (and (pair? (cdr p)) (ellipsis-id? (cadr p) ellipsis))
             (let count ((r (cdr p)) (n 0))
               (if (and (pair? r) (ellipsis-id? (car r) ellipsis))
                   (count (cdr r) (+ n 1))
                   (walk r d (walk (car p) (+ d n) acc))))
             (walk (cdr p) d (walk (car p) d acc))))
        ((vector? p) (walk (vector->list p) d acc))
        (else acc))))

  ;; Does any pattern variable occurring in `t` sit deeper than `d`? This is what
  ;; makes an ellipsis template well formed: something has to drive the loop.
  (define (has-deeper-var? t depths d)
    (let walk ((t t))
      (cond ((symbol? t)
             (let ((p (assq t depths))) (and p (> (cdr p) d))))
            ((pair? t) (or (walk (car t)) (walk (cdr t))))
            ((vector? t) (walk (vector->list t)))
            (else #f))))

  (define (validate-template tmpl depths ellipsis)
    (let walk ((t tmpl) (d 0))
      (cond
        ((symbol? t)
         (let ((p (assq t depths)))
           (when (and p (> (cdr p) d))
             (ex-error "pattern variable needs more ellipses in the template"
                       (id-name t) (cdr p) d))))
        ((pair? t)
         (cond
           ;; (... template): the escape. Nothing inside is checked, because
           ;; nothing inside is interpreted.
           ((and (ellipsis-id? (car t) ellipsis)
                 (pair? (cdr t)) (null? (cddr t)))
            'ok)
           ((and (pair? (cdr t)) (ellipsis-id? (cadr t) ellipsis))
            (let count ((r (cdr t)) (n 0))
              (if (and (pair? r) (ellipsis-id? (car r) ellipsis))
                  (count (cdr r) (+ n 1))
                  (begin
                    (unless (has-deeper-var? (car t) depths d)
                      (ex-error "ellipsis template has no pattern variable to iterate over"
                                (strip (car t))))
                    (walk (car t) (+ d n))
                    (walk r d)))))
           (else (walk (car t) d) (walk (cdr t) d))))
        ((vector? t) (walk (vector->list t) d))
        (else 'ok))))

  ;; --- matching -------------------------------------------------------------
  ;; Returns an alist (var . value) or #f. Values nest one list per ellipsis
  ;; level; the depths are already known statically from the pattern.

  (define (proper-length l)
    (let loop ((l l) (n 0)) (if (pair? l) (loop (cdr l) (+ n 1)) n)))

  (define (sr-match pat form use-env tx)
    (let ((ellipsis (tx-ellipsis tx))
          (literals (tx-literals tx))
          (def-env (tx-def-env tx)))
      (let match ((p pat) (f form))
        (cond
          ((symbol? p)
           (cond
             ((underscore? p) '())
             ((memq p literals)
              (and (symbol? f) (id=? p def-env f use-env) '()))
             (else (list (cons p f)))))
          ((pair? p)
           (if (and (pair? (cdr p)) (ellipsis-id? (cadr p) ellipsis))
               (let* ((sub (car p))
                      (vars (map car (pattern-vars sub ellipsis literals))))
                 (let count ((r (cdr p)))
                   (if (and (pair? r) (ellipsis-id? (car r) ellipsis))
                       (count (cdr r))
                       ;; r is what follows the ellipsis; it fixes how many of
                       ;; the input's elements the ellipsis may not eat.
                       (let* ((keep (proper-length r))
                              (have (proper-length f))
                              (take (- have keep)))
                         (and (>= take 0)
                              (let loop ((f f) (i 0) (subs '()))
                                (if (= i take)
                                    (let ((tail (match r f)))
                                      (and tail
                                           (append (transpose vars (reverse subs))
                                                   tail)))
                                    (let ((m (match sub (car f))))
                                      (and m (loop (cdr f) (+ i 1) (cons m subs)))))))))))
               (and (pair? f)
                    (let ((a (match (car p) (car f))))
                      (and a (let ((d (match (cdr p) (cdr f))))
                               (and d (append a d))))))))
          ((null? p) (and (null? f) '()))
          ((vector? p)
           (and (vector? f) (match (vector->list p) (vector->list f))))
          (else (and (equal? p f) '()))))))

  ;; One binding per variable holding the list of its per-iteration values. The
  ;; zero-iteration case is why `vars` comes from the pattern rather than from
  ;; the matches: an empty ellipsis still has to bind its variables to '().
  (define (transpose vars subs)
    (map (lambda (v)
           (cons v (map (lambda (m) (cdr (assq v m))) subs)))
         vars))

  ;; --- template instantiation -----------------------------------------------

  (define (instantiate tmpl matched depths tx)
    (let ((ellipsis (tx-ellipsis tx))
          (def-env (tx-def-env tx))
          (renames (make-eq-hashtable)))

      ;; One fresh alias per template identifier per expansion, so every
      ;; occurrence of `tmp` in one firing is the same variable and no two
      ;; firings share one.
      (define (rename id)
        (or (hashtable-ref renames id #f)
            (let ((new (fresh (id-name id))))
              (hashtable-set! aliases new (cons id def-env))
              (hashtable-set! renames id new)
              new)))

      ;; binds: alist (var depth . value)
      (define (occurs? v t)
        (cond ((symbol? t) (eq? v t))
              ((pair? t) (or (occurs? v (car t)) (occurs? v (cdr t))))
              ((vector? t) (occurs? v (vector->list t)))
              (else #f)))

      (define (inst t binds)
        (cond
          ((symbol? t)
           (let ((b (assq t binds)))
             (cond ((not b) (rename t))
                   ((> (cadr b) 0)
                    (ex-error "pattern variable used at too shallow a depth"
                              (id-name t)))
                   (else (cddr b)))))
          ((pair? t)
           (cond
             ((and (ellipsis-id? (car t) ellipsis)
                   (pair? (cdr t)) (null? (cddr t)))
              (inst-literal (cadr t) binds))
             ((and (pair? (cdr t)) (ellipsis-id? (cadr t) ellipsis))
              (let count ((r (cdr t)) (n 0))
                (if (and (pair? r) (ellipsis-id? (car r) ellipsis))
                    (count (cdr r) (+ n 1))
                    ;; n ellipses means n levels of iteration and n-1 levels of
                    ;; flattening: `x ... ...` walks the variable to depth two
                    ;; and then splices the outer level away.
                    (append (splice (iterate (car t) n binds) (- n 1))
                            (inst r binds)))))
             (else (cons (inst (car t) binds) (inst (cdr t) binds)))))
          ((vector? t) (list->vector (inst (vector->list t) binds)))
          (else t)))

      ;; (... template): substitute depth-0 variables, rename the rest, and treat
      ;; every ellipsis inside as an ordinary symbol.
      (define (inst-literal t binds)
        (cond
          ((symbol? t)
           (let ((b (assq t binds)))
             (if (and b (= (cadr b) 0)) (cddr b) (rename t))))
          ((pair? t) (cons (inst-literal (car t) binds) (inst-literal (cdr t) binds)))
          ((vector? t) (list->vector (inst-literal (vector->list t) binds)))
          (else t)))

      ;; `levels` levels of iteration, producing a list nested that deep. Each
      ;; level picks its own drivers: the variables occurring in `sub` that still
      ;; have depth left to spend.
      (define (iterate sub levels binds)
        (if (= levels 0)
            (inst sub binds)
            (let ((drivers (filter (lambda (b) (and (> (cadr b) 0) (occurs? (car b) sub)))
                                   binds)))
              (when (null? drivers)
                (ex-error "ellipsis template has no pattern variable to iterate over"
                          (strip sub)))
              (let ((n (length (cddr (car drivers)))))
                (for-each (lambda (b)
                            (unless (= (length (cddr b)) n)
                              (ex-error "ellipsis length mismatch between pattern variables"
                                        (id-name (car (car drivers))) (id-name (car b)))))
                          drivers)
                (let loop ((i 0) (acc '()))
                  (if (= i n)
                      (reverse acc)
                      (loop (+ i 1)
                            (cons (iterate sub (- levels 1)
                                           (map (lambda (b)
                                                  (if (memq b drivers)
                                                      (cons (car b)
                                                            (cons (- (cadr b) 1)
                                                                  (list-ref (cddr b) i)))
                                                      b))
                                                binds))
                                  acc))))))))

      ;; `x ... ...` flattens one level per extra ellipsis.
      (define (splice items extra)
        (if (= extra 0)
            items
            (splice (let loop ((xs items))
                      (cond ((null? xs) '())
                            ((list? (car xs)) (append (car xs) (loop (cdr xs))))
                            (else (ex-error "extra ellipsis over a non-list"))))
                    (- extra 1))))

      (inst tmpl
            (map (lambda (p)
                   (let ((v (assq (car p) matched)))
                     (cons (car p) (cons (cdr p) (and v (cdr v))))))
                 depths))))

  (define (apply-transformer tx form use-env)
    (let loop ((rules (tx-rules tx)))
      (if (null? rules)
          (ex-error "no matching syntax-rules clause" (strip form))
          (let* ((rule (car rules))
                 (m (sr-match (car rule) (cdr form) use-env tx)))
            (if m
                (instantiate (caddr rule) m (cadr rule) tx)
                (loop (cdr rules)))))))

  ;; --- the expander ---------------------------------------------------------

  (define (self-evaluating? d)
    (or (number? d) (boolean? d) (char? d) (string? d)))

  (define (expand form env)
    (cond
      ((symbol? form) (expand-reference form env))
      ((pair? form) (expand-pair form env))
      ((self-evaluating? form) (list 'quote form))
      ((vector? form) (list 'quote (strip form)))
      ((null? form) (ex-error "() is not an expression"))
      (else (ex-error "not an expression" (strip form)))))

  (define (expand-reference id env)
    (let ((d (lookup id env)))
      (cond ((not d) (id-name id))            ; free: a global or a primitive
            ((variable? d) (den-value d))
            ((macro? d) (ex-error "macro used as a variable" (id-name id)))
            (else (ex-error "syntactic keyword used as a variable" (id-name id))))))

  (define (expand-pair form env)
    (let* ((h (car form))
           (d (and (symbol? h) (lookup h env))))
      (cond
        ((macro? d) (expand (apply-transformer (den-value d) form env) env))
        ((special? d) (expand-special (den-value d) form env))
        (else (expand-application form env)))))

  (define (expand-application form env)
    (unless (list? form) (ex-error "an application must be a proper list" (strip form)))
    (map (lambda (e) (expand e env)) form))

  ;; --- sequences and bodies -------------------------------------------------

  (define (expand-sequence forms env)
    (cond ((null? forms) unspecified-expr)
          ((null? (cdr forms)) (expand (car forms) env))
          (else (cons 'begin (map (lambda (e) (expand e env)) forms)))))

  ;; A body is a run of definitions followed by a run of expressions. The
  ;; definitions have to be found BEFORE anything is expanded, and a macro may
  ;; produce one, so the scan expands macro uses and splices `begin` as it goes.
  ;; The result is a `letrec`, which is the reduction Lcore can hold.
  (define (expand-body forms env)
    (when (null? forms) (ex-error "empty body"))
    (let scan ((fs forms) (env env) (defs '()))
      (let ((f (and (pair? fs) (car fs))))
        (cond
          ((null? fs) (finish-body env (reverse defs) '()))
          ((and (pair? f) (symbol? (car f)))
           (let ((d (lookup (car f) env)))
             (cond
               ((macro? d)
                (scan (cons (apply-transformer (den-value d) f env) (cdr fs)) env defs))
               ((and (special-is? d 'begin) (list? (cdr f)))
                (scan (append (cdr f) (cdr fs)) env defs))
               ((special-is? d 'define)
                (let* ((parts (parse-define f))
                       (name (car parts))
                       (new (fresh (id-name name))))
                  (scan (cdr fs)
                        (extend env name (make-variable new))
                        (cons (cons new (cdr parts)) defs))))
               ((special-is? d 'define-syntax)
                (let ((parsed (parse-define-syntax f)))
                  (scan (cdr fs)
                        (extend env (car parsed)
                                (make-macro (parse-transformer (cdr parsed) env)))
                        defs)))
               (else (finish-body env (reverse defs) fs)))))
          (else (finish-body env (reverse defs) fs))))))

  (define (finish-body env defs exprs)
    (when (null? exprs)
      (ex-error "a body needs at least one expression after its definitions"))
    (let ((seq (expand-sequence exprs env)))
      (if (null? defs)
          seq
          (list 'letrec
                (map (lambda (d) (list (car d) (expand-define-value (cdr d) env)))
                     defs)
                seq))))

  ;; `(define x e)` and `(define (f a ...) body ...)` reduced to a name and the
  ;; ingredients of its value. `(lambda ...)` is NOT built as source and re-fed to
  ;; the expander: that would look the keyword `lambda` up at the use site, and a
  ;; program that rebinds `lambda` would then get a different meaning for its own
  ;; procedure definitions.
  (define (parse-define form)
    (unless (and (list? form) (>= (length form) 2))
      (ex-error "malformed define" (strip form)))
    (let ((target (cadr form)))
      (cond
        ((symbol? target)
         (cond ((null? (cddr form)) (list target 'expr #f))
               ((null? (cdddr form)) (list target 'expr (caddr form)))
               (else (ex-error "define takes one value expression" (strip form)))))
        ((and (pair? target) (symbol? (car target)))
         (list (car target) 'proc (cdr target) (cddr form)))
        (else (ex-error "malformed define" (strip form))))))

  (define (expand-define-value parts env)
    (if (eq? (car parts) 'expr)
        (if (cadr parts) (expand (cadr parts) env) unspecified-expr)
        (expand-lambda (car (cdr parts)) (cadr (cdr parts)) env)))

  (define (parse-define-syntax form)
    (unless (and (list? form) (= (length form) 3) (symbol? (cadr form)))
      (ex-error "malformed define-syntax" (strip form)))
    (cons (cadr form) (caddr form)))

  ;; --- lambda ---------------------------------------------------------------

  (define (expand-lambda formals body-forms env)
    (unless (and (list? formals) (for-all symbol? formals))
      (ex-error "Lcore's lambda has no rest parameter; formals must be a proper list of identifiers"
                (strip formals)))
    (let loop ((f formals) (seen '()))
      (cond ((null? f) 'ok)
            ((memq (car f) seen) (ex-error "duplicate parameter" (id-name (car f))))
            (else (loop (cdr f) (cons (car f) seen)))))
    (let* ((new (map (lambda (x) (fresh (id-name x))) formals))
           (env2 (extend* env formals (map make-variable new))))
      (list 'lambda new (expand-body body-forms env2))))

  ;; --- test position --------------------------------------------------------
  ;;
  ;; `and` and `or` in the TEST of a conditional lower to nested `if`s, one per
  ;; operand. In value position they keep the lowering that preserves the value.
  ;;
  ;; THIS IS A FRONT-END CONTRACT THE ANALYSIS DEPENDS ON, not a tidiness
  ;; preference. Lanf's `if` takes a single ATOM, so whatever the test evaluates
  ;; to gets let-bound, and (sonic essa) attaches a sigma only when the tested
  ;; variable was bound by a COMPARISON primcall. Lower
  ;;
  ;;   (if (and (fx<= 0 i) (fx< i n)) body else)
  ;;
  ;; the value-position way and the test becomes `(if (fx<= 0 i) (fx< i n) #f)`,
  ;; a boolean computed by an `if`. There is no comparison for a fact to hang
  ;; off, the branch gets NO sigma, and the analysis is blind at every
  ;; bounds-guarded loop -- which is the shape of config-2c and of every guard
  ;; the benchmark set contains.
  ;;
  ;; Nested, each comparison keeps its own branch and its own sigma pair, and
  ;; the inner one is converted under the outer edge's already-refined
  ;; environment, so the two facts COMPOSE into the interval the bounds check
  ;; needs. That composition is the entire mechanism.
  ;;
  ;; ON DUPLICATION. Distributing a conditional over an n-operand `and` copies
  ;; the ALTERNATIVE n times (`or` copies the consequent). An arm that is a
  ;; variable or a literal is copied outright; anything else is bound once to a
  ;; nullary join procedure and called from each site, so a nested test cannot
  ;; blow up code size. The arm reached exactly once is always emitted INLINE,
  ;; and for the guarded-loop shape that arm is the loop body: putting it behind
  ;; a call would move it out of the scope of the very refinements this lowering
  ;; exists to create.

  ;; A thunk that runs at most once. The skeleton builder calls each edge where
  ;; source order says that edge's code appears, and an `and` chain reaches the
  ;; same edge from several leaves; without memoization those leaves would each
  ;; expand it afresh, renaming its binders differently every time.
  (define (once thunk)
    (let ((forced #f) (value #f))
      (lambda ()
        (unless forced (set! value (thunk)) (set! forced #t))
        value)))

  ;; The arms are stood in for by these while the skeleton is built, so the
  ;; builder never has to know what an arm is, and so we can COUNT how many
  ;; times each one is reached before deciding whether to copy it. Fresh vectors
  ;; rather than symbols: identity is by eq?, and nothing in expander output can
  ;; be eq? to a vector allocated here, not even a quoted vector literal.
  (define (make-mark) (vector 'arm))

  (define (tree-count m t)
    (cond ((eq? m t) 1)
          ((pair? t) (+ (tree-count m (car t)) (tree-count m (cdr t))))
          (else 0)))

  (define (tree-subst m v t)
    (cond ((eq? m t) v)
          ((pair? t) (cons (tree-subst m v (car t)) (tree-subst m v (cdr t))))
          (else t)))

  ;; Cheap enough that copying it beats naming it.
  (define (duplicable-arm? e)
    (or (symbol? e) (and (pair? e) (eq? (car e) 'quote))))

  ;; Build the nested-if skeleton for `form` used as a test. `c` and `a` are
  ;; thunks yielding the trees for the true and false edges.
  ;;
  ;; A macro in test position is expanded HERE rather than left to `expand`, so
  ;; that a guard written as a macro over `and` gets the same lowering a guard
  ;; written as `and` does. Both keywords are recognised by DENOTATION, so a
  ;; program that rebinds `and` as a variable or a macro is unaffected.
  (define (build-test form c a env)
    (let ((d (and (pair? form) (symbol? (car form)) (lookup (car form) env))))
      (cond
        ((macro? d)
         (build-test (apply-transformer (den-value d) form env) c a env))
        ((and (special-is? d 'and) (list? form))
         (let loop ((es (cdr form)))
           (cond ((null? es) (c))                  ; (and) is true
                 ((null? (cdr es)) (build-test (car es) c a env))
                 (else (build-test (car es) (once (lambda () (loop (cdr es)))) a env)))))
        ((and (special-is? d 'or) (list? form))
         (let loop ((es (cdr form)))
           (cond ((null? es) (a))                  ; (or) is false
                 ((null? (cdr es)) (build-test (car es) c a env))
                 (else (build-test (car es) c (once (lambda () (loop (cdr es)))) env)))))
        ;; The leaf. Expanding the test BEFORE forcing either edge is what keeps
        ;; fresh names and error reports in source order.
        (else (let ((t (expand form env))) (list 'if t (c) (a)))))))

  ;; The entry point every conditional goes through. `then-thunk` and
  ;; `else-thunk` produce the already-expanded arms; they are called after the
  ;; skeleton so that a test's own bindings are numbered before the arms', which
  ;; is the order the source is written in.
  ;;
  ;; A test that is not an `and` or an `or` produces exactly `(if t C A)`, the
  ;; same tree the direct construction gave, so nothing but conjunctive and
  ;; disjunctive tests changes shape.
  (define (expand-test test then-thunk else-thunk env)
    (let* ((c-mark (make-mark))
           (a-mark (make-mark))
           (skeleton (build-test test (lambda () c-mark) (lambda () a-mark) env))
           (then-arm (then-thunk))
           (else-arm (else-thunk)))
      (let place ((arms (list (cons c-mark then-arm) (cons a-mark else-arm)))
                  (body skeleton)
                  (joins '()))
        (if (null? arms)
            (if (null? joins) body (list 'let joins body))
            (let* ((m (caar arms))
                   (arm (cdar arms))
                   (n (tree-count m body)))
              (if (or (<= n 1) (duplicable-arm? arm))
                  (place (cdr arms) (tree-subst m arm body) joins)
                  (let ((k (fresh 'join)))
                    (place (cdr arms)
                           (tree-subst m (list k) body)
                           (cons (list k (list 'lambda '() arm)) joins)))))))))

  ;; --- special forms --------------------------------------------------------

  (define (check-length! form n what)
    (unless (and (list? form) (= (length form) n))
      (ex-error what (strip form))))

  (define (bindings-of form what)
    (let ((bs (cadr form)))
      (unless (list? bs) (ex-error what (strip form)))
      (for-each (lambda (b)
                  (unless (and (list? b) (= (length b) 2) (symbol? (car b)))
                    (ex-error what (strip form))))
                bs)
      bs))

  (define (expand-special which form env)
    (case which
      ((quote)
       (check-length! form 2 "malformed quote")
       (list 'quote (strip (cadr form))))

      ((if)
       (unless (and (list? form) (memv (length form) '(3 4)))
         (ex-error "malformed if" (strip form)))
       (expand-test (cadr form)
                    (lambda () (expand (caddr form) env))
                    (lambda () (if (null? (cdddr form))
                                   unspecified-expr
                                   (expand (cadddr form) env)))
                    env))

      ((lambda)
       (unless (and (list? form) (>= (length form) 3))
         (ex-error "malformed lambda" (strip form)))
       (expand-lambda (cadr form) (cddr form) env))

      ((set!)
       (check-length! form 3 "malformed set!")
       (let ((target (cadr form)))
         (unless (symbol? target) (ex-error "set! needs an identifier" (strip form)))
         (let ((d (lookup target env)))
           (when (or (macro? d) (special? d))
             (ex-error "set! on a syntactic keyword" (id-name target)))
           (list 'set!
                 (if (variable? d) (den-value d) (id-name target))
                 (expand (caddr form) env)))))

      ((begin)
       (unless (list? form) (ex-error "malformed begin" (strip form)))
       (expand-sequence (cdr form) env))

      ((let) (expand-let form env))

      ((let*)
       (unless (and (list? form) (>= (length form) 3))
         (ex-error "malformed let*" (strip form)))
       (let loop ((bs (bindings-of form "malformed let*")) (env env))
         (if (null? bs)
             (expand-body (cddr form) env)
             (let* ((b (car bs))
                    (init (expand (cadr b) env))
                    (new (fresh (id-name (car b))))
                    (env2 (extend env (car b) (make-variable new))))
               (list 'let (list (list new init)) (loop (cdr bs) env2))))))

      ((letrec letrec*)
       (unless (and (list? form) (>= (length form) 3))
         (ex-error "malformed letrec" (strip form)))
       (let* ((bs (bindings-of form "malformed letrec"))
              (names (map car bs))
              (new (map (lambda (x) (fresh (id-name x))) names))
              (env2 (extend* env names (map make-variable new))))
         (list 'letrec
               (map (lambda (n b) (list n (expand (cadr b) env2))) new bs)
               (expand-body (cddr form) env2))))

      ((when unless)
       (unless (and (list? form) (>= (length form) 3))
         (ex-error "malformed when/unless" (strip form)))
       ;; Same test position as `if`, so the same lowering: `(when (and ...) ...)`
       ;; is how half the guards in the benchmark set are actually written.
       (let ((body (lambda () (expand-sequence (cddr form) env)))
             (nothing (lambda () unspecified-expr)))
         (if (eq? which 'when)
             (expand-test (cadr form) body nothing env)
             (expand-test (cadr form) nothing body env))))

      ((and)
       (unless (list? form) (ex-error "malformed and" (strip form)))
       (let loop ((es (cdr form)))
         (cond ((null? es) '(quote #t))
               ((null? (cdr es)) (expand (car es) env))
               (else (list 'if (expand (car es) env) (loop (cdr es)) '(quote #f))))))

      ((or)
       (unless (list? form) (ex-error "malformed or" (strip form)))
       ;; The temporary is generated, not written, so the classic capture in
       ;; `(or a t)` cannot arise here at all.
       (let loop ((es (cdr form)))
         (cond ((null? es) '(quote #f))
               ((null? (cdr es)) (expand (car es) env))
               (else
                (let ((t (fresh 'or-tmp)))
                  (list 'let (list (list t (expand (car es) env)))
                        (list 'if t t (loop (cdr es)))))))))

      ((cond) (expand-cond form env))

      ((declare) (expand-declare form env))
      ((declare-distinct) (expand-declare-distinct form env))
      ((policy) (expand-policy form env))

      ((let-syntax letrec-syntax)
       (unless (and (list? form) (>= (length form) 3))
         (ex-error "malformed let-syntax" (strip form)))
       ;; The only difference between the two: letrec-syntax's transformers see
       ;; the keywords being bound, let-syntax's do not. The denotations are
       ;; created empty and filled after parsing, which is how the recursive one
       ;; ties its knot without a second pass.
       (let* ((bs (bindings-of form "malformed let-syntax"))
              (names (map car bs))
              (dens (map (lambda (b) (make-macro #f)) bs))
              (inner (extend* env names dens))
              (parse-env (if (eq? which 'letrec-syntax) inner env)))
         (for-each (lambda (den b)
                     (set-den-value! den (parse-transformer (cadr b) parse-env)))
                   dens bs)
         (expand-body (cddr form) inner)))

      ((define define-syntax)
       (ex-error "definition in an expression position" (strip form)))

      ((syntax-rules)
       (ex-error "syntax-rules outside a transformer position" (strip form)))

      ((else =>)
       (ex-error "else and => are only meaningful inside cond" (strip form)))

      ((import)
       (ex-error "import is only valid at the top of a program" (strip form)))

      (else (ex-error "unhandled special form" which))))

  (define (expand-let form env)
    (unless (and (list? form) (>= (length form) 3))
      (ex-error "malformed let" (strip form)))
    (if (symbol? (cadr form))
        ;; Named let. The loop name is a binding like any other, so it is
        ;; renamed, and a macro-introduced name cannot be reached by the body.
        (let* ((name (cadr form))
               (rest (cddr form)))
          (unless (>= (length rest) 2) (ex-error "malformed named let" (strip form)))
          (let* ((bs (let ((bs (car rest)))
                       (unless (list? bs) (ex-error "malformed named let" (strip form)))
                       (for-each (lambda (b)
                                   (unless (and (list? b) (= (length b) 2) (symbol? (car b)))
                                     (ex-error "malformed named let" (strip form))))
                                 bs)
                       bs))
                 (inits (map (lambda (b) (expand (cadr b) env)) bs))
                 (loop-name (fresh (id-name name)))
                 (env2 (extend env name (make-variable loop-name))))
            (list 'letrec
                  (list (list loop-name
                              (expand-lambda (map car bs) (cdr rest) env2)))
                  (cons loop-name inits))))
        (let* ((bs (bindings-of form "malformed let"))
               (names (map car bs))
               (inits (map (lambda (b) (expand (cadr b) env)) bs))
               (new (map (lambda (x) (fresh (id-name x))) names))
               (env2 (extend* env names (map make-variable new))))
          (list 'let (map list new inits) (expand-body (cddr form) env2)))))

  (define (expand-cond form env)
    (unless (and (list? form) (>= (length form) 2))
      (ex-error "malformed cond" (strip form)))
    (let loop ((clauses (cdr form)))
      (if (null? clauses)
          unspecified-expr
          (let ((c (car clauses)))
            (unless (and (list? c) (>= (length c) 1))
              (ex-error "malformed cond clause" (strip c)))
            (cond
              ;; `else` by denotation, so a user binding named else does not
              ;; accidentally become the catch-all.
              ((and (symbol? (car c))
                    (special-is? (lookup (car c) env) 'else))
               (unless (null? (cdr clauses)) (ex-error "else is not the last cond clause"))
               (when (null? (cdr c)) (ex-error "empty else clause"))
               (expand-sequence (cdr c) env))
              ;; (test => receiver)
              ((and (= (length c) 3)
                    (symbol? (cadr c))
                    (special-is? (lookup (cadr c) env) '=>))
               (let ((t (fresh 'cond-tmp)))
                 (list 'let (list (list t (expand (car c) env)))
                       (list 'if t
                             (list (expand (caddr c) env) t)
                             (loop (cdr clauses))))))
              ;; (test) yields the test's own value
              ((null? (cdr c))
               (let ((t (fresh 'cond-tmp)))
                 (list 'let (list (list t (expand (car c) env)))
                       (list 'if t t (loop (cdr clauses))))))
              ;; An ordinary clause is a test position too. The remaining
              ;; clauses are the false edge, and they are exactly the arm the
              ;; join point exists for: an `and` test would otherwise copy the
              ;; whole rest of the `cond` once per operand.
              (else
               (expand-test (car c)
                            (lambda () (expand-sequence (cdr c) env))
                            (lambda () (loop (cdr clauses)))
                            env)))))))

  ;; (declare ([x pn] ...) body ...) and (policy ([pn on?] ...) body ...).
  ;; Both are Lcore forms already; the expander's only jobs are to rename the
  ;; variables `declare` talks about and to strip aliases off the check names, so
  ;; a macro that generates a policy block names the same checks lang.ss does.
  (define (expand-declare form env)
    (unless (and (list? form) (>= (length form) 3))
      (ex-error "malformed declare" (strip form)))
    (let ((prems (cadr form)))
      (unless (list? prems) (ex-error "malformed declare" (strip form)))
      (list 'declare
            (map (lambda (p)
                   (unless (and (list? p) (= (length p) 2)
                                (symbol? (car p)) (symbol? (cadr p)))
                     (ex-error "a premise is (variable check-name)" (strip p)))
                   (list (expand-reference (car p) env) (id-name (cadr p))))
                 prems)
            (expand-body (cddr form) env))))

  ;; (declare-distinct (a b ...) body ...)
  ;;
  ;; THE SPELLING, and why it is this one. C99 writes `restrict` as a qualifier
  ;; on a pointer DECLARATOR, which Scheme has nowhere to hang: there is no
  ;; declarator, and a formal parameter list is a list of bare identifiers.
  ;; Ada writes it as a pragma, which is the same shape as this. So the premise
  ;; goes where every other premise in this language goes, in a `declare`-family
  ;; form over a body, and it keeps the name the core language already uses.
  ;;
  ;; NOT `assert-distinct`, and the difference is not cosmetic: `assert` in
  ;; every Scheme that has one names something CHECKED at run time, and this is
  ;; never checked anywhere. It is asserted by the programmer and believed by
  ;; the compiler, and if it is false the program computes wrong numbers with no
  ;; diagnostic. `declare` is the R7RS-adjacent word for a premise the compiler
  ;; takes on faith, and (sonic alias) documents the undefined behaviour.
  ;;
  ;; A GROUP OF ONE IS REFUSED, and so is a repeated name. `alias-query` will
  ;; not answer `must-not` for a name against itself, so a one-name group asserts
  ;; nothing and is a typo every time; a repeated name is a premise the
  ;; programmer has already violated in the act of writing it. This is the one
  ;; place either mistake can be caught cheaply, so it is caught here.
  (define (expand-declare-distinct form env)
    (unless (and (list? form) (>= (length form) 3))
      (ex-error "malformed declare-distinct" (strip form)))
    (let ((names (cadr form)))
      (unless (and (list? names) (for-all symbol? names))
        (ex-error "declare-distinct takes a list of identifiers" (strip form)))
      (unless (>= (length names) 2)
        (ex-error "declare-distinct needs at least two names to be about"
                  (strip form)))
      (let ((out (map (lambda (n) (expand-reference n env)) names)))
        (let loop ((ns out) (seen '()))
          (cond ((null? ns) 'ok)
                ((memq (car ns) seen)
                 (ex-error "declare-distinct names one variable twice; nothing is distinct from itself"
                           (id-name (car ns))))
                (else (loop (cdr ns) (cons (car ns) seen)))))
        (list 'declare-distinct out (expand-body (cddr form) env)))))

  (define (expand-policy form env)
    (unless (and (list? form) (>= (length form) 3))
      (ex-error "malformed policy" (strip form)))
    (let ((settings (cadr form)))
      (unless (list? settings) (ex-error "malformed policy" (strip form)))
      (list 'policy
            (map (lambda (s)
                   (unless (and (list? s) (= (length s) 2)
                                (symbol? (car s)) (boolean? (cadr s)))
                     (ex-error "a policy setting is (check-name boolean)" (strip s)))
                   (list (id-name (car s)) (cadr s)))
                 settings)
            (expand-body (cddr form) env))))

  ;; --- the top level --------------------------------------------------------
  ;;
  ;; Sequential, left to right, because that is what the top level is: a
  ;; `define-syntax` is in force for what follows it and not for what precedes
  ;; it, and a reference to a not-yet-defined global is simply free.

  (define (expand-program forms)
    (unless (list? forms) (ex-error "expand-program takes a list of top-level forms"))
    (reset-state!)
    (note-symbols! forms)
    (let loop ((fs forms) (out '()))
      (if (null? fs)
          (reverse out)
          (let* ((f (car fs))
                 (d (and (pair? f) (symbol? (car f)) (lookup (car f) empty-env))))
            (cond
              ((macro? d)
               (loop (cons (apply-transformer (den-value d) f empty-env) (cdr fs)) out))
              ((and (special-is? d 'begin) (list? (cdr f)))
               (loop (append (cdr f) (cdr fs)) out))
              ((special-is? d 'import)
               ;; A program header, not an expression. Passed through untouched
               ;; for whoever resolves libraries; expanding it would turn
               ;; `(rnrs base)` into an application of `rnrs`.
               (loop (cdr fs) (cons (strip f) out)))
              ((special-is? d 'define-syntax)
               (let ((parsed (parse-define-syntax f)))
                 (hashtable-set! globals (car parsed)
                                 (make-macro (parse-transformer (cdr parsed) empty-env)))
                 (loop (cdr fs) out)))
              ((special-is? d 'define)
               (let* ((parts (parse-define f))
                      (name (car parts)))
                 ;; Registered BEFORE the value is expanded, so a recursive
                 ;; procedure sees itself. Top-level names are not renamed: the
                 ;; top level is one flat scope and its names are the interface.
                 (hashtable-set! globals name (make-variable name))
                 (let ((value (expand-define-value (cdr parts) empty-env)))
                   (loop (cdr fs) (cons (list 'define name value) out)))))
              (else
               (loop (cdr fs) (cons (expand f empty-env) out))))))))

  ;; One expression, expanded in an otherwise empty program. For tests and for
  ;; anything that wants to look at a single form.
  (define (expand-expression form)
    (reset-state!)
    (note-symbols! form)
    (expand form empty-env))
  )
