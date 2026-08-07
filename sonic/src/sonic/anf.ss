;;; SonicScheme: A-normalization. Lcore -> Lanf.
;;;
;;; Stage 04a. Every intermediate value gets a name.
;;;
;;; THIS IS A PRECONDITION, NOT TIDINESS. The interval domain hangs one abstract
;;; value on each variable, so a subexpression with no name has nowhere to put
;;; its interval and the transfer functions cannot compose.
;;; sonic/src/sonic/analyze.ss already assumes it, and says so at the top of the
;;; file; sonic/src/sonic/assign.ss states the same requirement from the other
;;; side ("the right-hand side of a set! must already be an atom").
;;;
;;; --- THE THREE THINGS THAT ARE EASY TO GET WRONG ---------------------------
;;;
;;; 1. EVALUATION ORDER IS OBSERVABLE, so naming intermediates fixes an order and
;;;    that order must be the source's. For flonums the association order of a
;;;    sum changes the low bits (see the worked example at the top of
;;;    sonic/src/sonic/numeric.ss: 1.734723475976807e-18 against
;;;    9.020562075079397e-19, a factor of nearly two), bench/nbody/SPEC.md says
;;;    expression order is load-bearing, and the oracle compares bit-exactly. So
;;;    operands are atomized STRICTLY LEFT TO RIGHT and every construction below
;;;    binds its parts with `let*` in source order rather than letting the
;;;    quasiquote's argument order decide.
;;;
;;;    The fresh-name counter is the instrument that proves it: because names are
;;;    handed out in the order the bindings are emitted, the numbering of the
;;;    output IS the evaluation order, and test/anf-test.ss asserts on it.
;;;    `map/lr` exists for the same reason it exists in essa.ss -- Chez does not
;;;    promise `map`'s application order and the counter is stateful.
;;;
;;; 2. TAIL POSITION. `Lanf` has `tailcall` for tail position and `call` as a
;;;    SimpleExpr for everything else. Emitting `call` where `tailcall` belongs
;;;    turns a Scheme loop into a stack leak, and R5RS's proper tail recursion is
;;;    the one performance guarantee the standard made that ANSI CL never did.
;;;    So the conversion is context-directed: `tail` is the only context that
;;;    produces `tailcall`, and it is never inherited by an operand.
;;;
;;; 3. `Lanf`'s `if` TAKES AN ATOM. A compound test is converted under a binding
;;;    context first, so `(if (fx< i n) a b)` becomes
;;;    `(let ([t (primcall fx< () i n)]) (if t a b))`. That binding is also what
;;;    (sonic essa) reads to decide whether the branch gets a sigma, so a test
;;;    left unnamed would silently cost every bounds-check elision downstream.
;;;
;;; --- FOUR CONTEXTS ---------------------------------------------------------
;;;
;;;   tail          the value is the enclosing lambda's result; calls are tail
;;;   value         the value is produced but the frame stays; calls are not tail
;;;   (bind pref k) the value must be an ATOM; k receives its name
;;;   (effect th)   the value is discarded; `th` yields what comes after
;;;
;;; `value` and `tail` differ in exactly one production, `call`. `bind` carries a
;;; PREFERRED name so that `(let ([x e]) body)` binds `x` directly instead of
;;; binding a temporary and copying it; that is a readability choice with no
;;; semantic content, and it is only taken for a one-binding `let`, because a
;;; multi-binding `let` evaluates all its inits before any of its binders exist.
;;;
;;; --- WHAT NEEDS A JOIN, AND WHY --------------------------------------------
;;;
;;; `if`, `declare`, `declare-distinct` and `policy` are Exprs and NOT
;;; SimpleExprs, so none of them can sit on the right of a `let`. In value
;;; position their result therefore has nowhere to be named. Two ways out:
;;; duplicate the continuation into each arm, which doubles code and breaks
;;; unique naming (essa.ss reports having tried it), or name the continuation.
;;; This pass names it: a nullary-shaped `letrec` binding whose lambda takes the
;;; merged value.
;;;
;;;   (let ([n (if c 1 2)]) body)
;;;     ==> (letrec ([join.1 (lambda (n) body')])
;;;           (if c (let ([t (quote 1)]) (tailcall join.1 t))
;;;                 (let ([t (quote 2)]) (tailcall join.1 t))))
;;;
;;; For `declare` and `policy` the join is not a size argument, it is a
;;; CORRECTNESS one: threading the continuation into the body would extend a
;;; premise's or a policy's lexical scope past where the programmer wrote it, and
;;; D5's whole claim is that the scope is exactly what the source says. `let`,
;;; `letrec` and `begin` need no join, because their continuation appears once
;;; and a binding's scope growing over it changes nothing.
;;;
;;; --- WHAT THIS PASS REFUSES ------------------------------------------------
;;;
;;;   * `(void)` OR `set!` IN VALUE POSITION. Neither is a SimpleExpr and neither
;;;     has a value worth naming; `(f (set! x 1))` is refused rather than given
;;;     an invented atom. Spelling it `(quote ())` is the wart parse.ss already
;;;     records, and repeating it here would make it two.
;;;   * `letrec*` WITH A NON-LAMBDA RIGHT-HAND SIDE. Lanf removed `letrec*` and
;;;     put nothing back, so the sequential guarantee has no representation. When
;;;     every right-hand side is a lambda the two forms are the same thing and
;;;     the mapping is exact; otherwise this refuses rather than silently
;;;     dropping the ordering, which is the failure lang.ss calls out at the
;;;     `letrec*` production.
;;;
;;; Run the tests: scheme -q --libdirs src:vendor/nanopass --script test/anf-test.ss

(library (sonic anf)
  (export anf anf-program)
  (import (chezscheme) (nanopass) (sonic lang))

  (define (anf-error msg . irritants)
    (apply error 'anf msg irritants))

  ;; --- fresh names ----------------------------------------------------------
  ;; `t.7`, in the style essa.ss established: readable beats gensym'd when
  ;; fixtures are written by hand, and the counter is reset at pass entry so the
  ;; output is reproducible and a test can assert on the numbering.
  ;;
  ;; THE NUMBERING IS THE ORDER PROOF. A binding gets its number when it is
  ;; emitted, so t.1 is evaluated before t.2 by construction.

  (define counter 0)
  (define (reset-names!) (set! counter 0))

  (define (fresh base)
    (set! counter (+ counter 1))
    (string->symbol
     (string-append (symbol->string base) "." (number->string counter))))

  ;; LEFT-TO-RIGHT map, for the same reason essa.ss has one: Chez does not
  ;; promise `map`'s application order and `fresh` mutates a counter.
  (define (map/lr f xs)
    (let loop ([xs xs] [acc '()])
      (if (null? xs)
          (reverse acc)
          (let ([v (f (car xs))])           ; forced before the recursive call
            (loop (cdr xs) (cons v acc))))))

  ;; --- contexts -------------------------------------------------------------

  (define (make-bind pref k) (vector 'bind pref k))
  (define (make-effect thunk) (vector 'effect thunk))

  (define (ctx-kind ctx) (if (symbol? ctx) ctx (vector-ref ctx 0)))
  (define (bind-pref ctx) (vector-ref ctx 1))
  (define (bind-k ctx) (vector-ref ctx 2))
  (define (effect-thunk ctx) (vector-ref ctx 1))

  ;; --- delivering a converted form to its context ---------------------------

  (define (atom-expr x) (with-output-language (Lanf Expr) `,x))
  (define (atom-se x) (with-output-language (Lanf SimpleExpr) `,x))

  ;; The form is already an atom.
  (define (ret-atom x ctx)
    (case (ctx-kind ctx)
      [(tail value) (atom-expr x)]
      [(effect) ((effect-thunk ctx))]
      [else
       (let ([pref (bind-pref ctx)])
         (if pref
             ;; A one-binding `let` whose init is a variable: keep the binder the
             ;; programmer wrote rather than aliasing it to a temporary.
             (let* ([se (atom-se x)]
                    [body ((bind-k ctx) pref)])
               (with-output-language (Lanf Expr) `(let ([,pref ,se]) ,body)))
             ((bind-k ctx) x)))]))

  ;; `se` is the form as a SimpleExpr. `ex` is the SAME form as an Expr when it
  ;; has one (a variable, a quote or a lambda are both), or #f when it does not
  ;; (a call or a primcall), in which case value position still needs a binding.
  (define (ret-simple se ex ctx)
    (case (ctx-kind ctx)
      [(tail value)
       (or ex
           (let* ([t (fresh 't)]
                  [body (atom-expr t)])
             (with-output-language (Lanf Expr) `(let ([,t ,se]) ,body))))]
      [(effect)
       ;; Bound rather than dropped: a primcall in statement position can still
       ;; signal, and `seq` will not take a SimpleExpr.
       (let* ([t (fresh 't)]
              [rest ((effect-thunk ctx))])
         (with-output-language (Lanf Expr) `(let ([,t ,se]) ,rest)))]
      [else
       (let* ([t (or (bind-pref ctx) (fresh 't))]
              [body ((bind-k ctx) t)])
         (with-output-language (Lanf Expr) `(let ([,t ,se]) ,body)))]))

  ;; An Lanf Expr whose value cannot be named: `(void)` and `set!`.
  (define (ret-expr ex ctx)
    (case (ctx-kind ctx)
      [(tail value) ex]
      [(effect)
       (let ([rest ((effect-thunk ctx))])
         (with-output-language (Lanf Expr) `(seq ,ex ,rest)))]
      [else
       (anf-error "this form has no value to name in Lanf; it cannot be an operand"
                  (unparse-Lanf ex))]))

  ;; A form that PRODUCES a value but has no SimpleExpr spelling: `if`,
  ;; `declare`, `declare-distinct`, `policy`. `build` takes the context its body
  ;; (or its arms) must be converted under and returns the whole form.
  ;;
  ;; In binding position this is where the join continuation is introduced. See
  ;; the header: for `declare` and `policy` that is a scope-correctness measure,
  ;; not a code-size one.
  (define (deliver-compound ctx build)
    (case (ctx-kind ctx)
      [(tail) (build 'tail)]
      [(value) (build 'value)]
      [(effect)
       (let* ([inner (build 'value)]
              [rest ((effect-thunk ctx))])
         (with-output-language (Lanf Expr) `(seq ,inner ,rest)))]
      [else
       (let* ([j (fresh 'join)]
              ;; The arms are built BEFORE the continuation, so the numbering
              ;; still follows source order.
              [inner (build (make-bind #f
                              (lambda (a)
                                (let ([a* (list a)])
                                  (with-output-language (Lanf Expr)
                                    `(tailcall ,j ,a* ...))))))]
              [r (or (bind-pref ctx) (fresh 'r))]
              [kb ((bind-k ctx) r)]
              [r* (list r)]
              [lam (with-output-language (Lanf Expr) `(lambda (,r* ...) ,kb))]
              [j* (list j)]
              [lam* (list lam)])
         (with-output-language (Lanf Expr)
           `(letrec ([,j* ,lam*] ...) ,inner)))]))

  ;; --- the conversion -------------------------------------------------------

  (define (lambda-form? e)
    (nanopass-case (Lcore Expr) e
      [(lambda (,x* ...) ,body) #t]
      [else #f]))

  ;; Atomize a list of operands STRICTLY LEFT TO RIGHT and hand the names to `k`.
  ;; Each operand's bindings are emitted, and its name allocated, before the next
  ;; operand is even looked at, so the output order is the source order.
  (define (atomize* es k)
    (let loop ([es es] [acc '()])
      (if (null? es)
          (k (reverse acc))
          (Conv (car es)
                (make-bind #f (lambda (a) (loop (cdr es) (cons a acc))))))))

  (define (Conv e ctx)
    (nanopass-case (Lcore Expr) e

      [,x (ret-atom x ctx)]

      [(quote ,d)
       (ret-simple (with-output-language (Lanf SimpleExpr) `(quote ,d))
                   (with-output-language (Lanf Expr) `(quote ,d))
                   ctx)]

      [(lambda (,x* ...) ,body)
       ;; A lambda's body is a new frame, so it is converted in TAIL context
       ;; whatever the lambda itself sits in.
       (let ([b (Conv body 'tail)])
         (ret-simple (with-output-language (Lanf SimpleExpr) `(lambda (,x* ...) ,b))
                     (with-output-language (Lanf Expr) `(lambda (,x* ...) ,b))
                     ctx))]

      [(void) (ret-expr (with-output-language (Lanf Expr) `(void)) ctx)]

      [(set! ,x ,e0)
       ;; assign.ss requires the right-hand side to be an atom already, and says
       ;; so: "A-normalization emits (let ([t ...]) (set! x t))".
       (Conv e0 (make-bind #f
                  (lambda (a)
                    (let ([v (atom-expr a)])
                      (ret-expr (with-output-language (Lanf Expr) `(set! ,x ,v))
                                ctx)))))]

      [(call ,e0 ,e* ...)
       (atomize* (cons e0 e*)
         (lambda (as)
           (let ([f (car as)] [a* (cdr as)])
             (if (eq? (ctx-kind ctx) 'tail)
                 ;; THE ONE PLACE `tailcall` IS PRODUCED.
                 (with-output-language (Lanf Expr) `(tailcall ,f ,a* ...))
                 (ret-simple (with-output-language (Lanf SimpleExpr)
                               `(call ,f ,a* ...))
                             #f ctx)))))]

      [(primcall ,pr ([,pn* ,c*] ...) ,e* ...)
       ;; The controls ride through untouched. Weakening them is (sonic policy)'s
       ;; job by permission and the analysis's by proof; it is not this pass's.
       (atomize* e*
         (lambda (as)
           (ret-simple (with-output-language (Lanf SimpleExpr)
                         `(primcall ,pr ([,pn* ,c*] ...) ,as ...))
                       #f ctx)))]

      [(if ,e0 ,e1 ,e2)
       ;; Lanf's `if` takes an atom, so the test is bound first. (sonic essa)
       ;; reads that binding to decide whether the branch carries a sigma.
       (Conv e0
         (make-bind #f
           (lambda (t)
             (deliver-compound ctx
               (lambda (c)
                 (let* ([a (Conv e1 c)]         ; consequent first: source order
                        [b (Conv e2 c)])
                   (with-output-language (Lanf Expr) `(if ,t ,a ,b))))))))]

      [(let ([,x* ,e*] ...) ,body)
       (cond
        [(null? x*) (Conv body ctx)]
        ;; One binding: name the value `x` outright.
        [(null? (cdr x*))
         (Conv (car e*) (make-bind (car x*) (lambda (bound) (Conv body ctx))))]
        ;; More than one: Lcore's `let` evaluates every init OUTSIDE the new
        ;; scope, so each init is named first and the binders are attached
        ;; afterwards. Binding them as we go would let a later init see an
        ;; earlier binder, which is `let*` and not `let`.
        [else
         (atomize* e*
           (lambda (as)
             (let ([b (Conv body ctx)])
               (fold-right
                (lambda (x a acc)
                  (let ([se (atom-se a)])
                    (with-output-language (Lanf Expr) `(let ([,x ,se]) ,acc))))
                b x* as))))])]

      [(letrec ([,x* ,e*] ...) ,body)
       ;; Lanf keeps `letrec` with Expr right-hand sides, and a lambda IS an Expr
       ;; there, so it stays a bare lambda rather than being wrapped in a `let`.
       ;; That matters: (sonic essa) matches the right-hand side against `lambda`
       ;; to place a loop header's phi, and a wrapper would lose every header.
       (let* ([r* (map/lr (lambda (rhs) (Conv rhs 'value)) e*)]
              [b (Conv body ctx)])
         (with-output-language (Lanf Expr) `(letrec ([,x* ,r*] ...) ,b)))]

      [(letrec* ([,x* ,e*] ...) ,body)
       ;; Lanf has no sequential recursive binder. When every right-hand side is
       ;; a lambda the two forms agree exactly, because no initializer can
       ;; observe another; otherwise refuse rather than drop the ordering.
       (unless (for-all lambda-form? e*)
         (anf-error "letrec* with a non-lambda right-hand side has no Lanf form; its sequential initialization cannot be expressed"
                    (unparse-Lcore e)))
       (let* ([r* (map/lr (lambda (rhs) (Conv rhs 'value)) e*)]
              [b (Conv body ctx)])
         (with-output-language (Lanf Expr) `(letrec ([,x* ,r*] ...) ,b)))]

      [(declare ([,x* ,prem*] ...) ,body)
       (deliver-compound ctx
         (lambda (c)
           (let ([b (Conv body c)])
             (with-output-language (Lanf Expr)
               `(declare ([,x* ,prem*] ...) ,b)))))]

      [(declare-distinct (,x* ...) ,body)
       (deliver-compound ctx
         (lambda (c)
           (let ([b (Conv body c)])
             (with-output-language (Lanf Expr) `(declare-distinct (,x* ...) ,b)))))]

      [(policy ([,pn* ,b*] ...) ,body)
       (deliver-compound ctx
         (lambda (c)
           (let ([b (Conv body c)])
             (with-output-language (Lanf Expr) `(policy ([,pn* ,b*] ...) ,b)))))]

      [(begin ,e* ... ,e0)
       ;; Left to right, each element converted under an `effect` context whose
       ;; thunk is what follows. The thunk is forced AFTER the current element's
       ;; names are allocated, which is what keeps the numbering in source order;
       ;; building the tail first would number it backwards.
       (let loop ([es (append e* (list e0))])
         (if (null? (cdr es))
             (Conv (car es) ctx)
             (Conv (car es) (make-effect (lambda () (loop (cdr es)))))))]

      [else (anf-error "unhandled Lcore form" (unparse-Lcore e))]))

  ;; --- entry points ---------------------------------------------------------

  ;; One expression. Its value is the result, so it starts in tail context.
  (define (anf e)
    (reset-names!)
    (Conv e 'tail))

  ;; A whole program. Each top-level value is produced without a frame to return
  ;; from, so `value`; the body is the program's tail.
  (define (anf-program prog)
    (reset-names!)
    (nanopass-case (Lcore Program) prog
      [(top ([,x* ,e*] ...) (,x2* ...) ,body)
       (let* ([v* (map/lr (lambda (e) (Conv e 'value)) e*)]
              [b (Conv body 'tail)])
         (with-output-language (Lanf Program)
           `(top ([,x* ,v*] ...) (,x2* ...) ,b)))]))
  )
