;;; SonicScheme: assignment conversion. Lanf -> Lanf.
;;;
;;; Stage 04c, after inlining and before e-SSA. A mutated variable is rewritten
;;; into an immutable variable holding a ONE-SLOT CELL; `set!` becomes a store
;;; into that cell and every read becomes a load out of it. After this pass no
;;; local variable is ever assigned, which is what `(sonic essa)` and
;;; `(sonic interval)` already assume -- e-SSA hangs one interval on each name,
;;; and a name that can change under it has no single interval to hang.
;;;
;;; --- THE COST, WHICH IS THE WHOLE DIFFICULTY -------------------------------
;;;
;;; A cell is a heap object, so the CELL is `tagged` and lives in the value
;;; register class (D21, sonic/doc/register-partition.md). A conversion that
;;; boxes indiscriminately therefore takes every mutated flonum local out of the
;;; float registers and puts it behind a tagged pointer, which is precisely the
;;; effect this project exists to measure the absence of. Two rules keep that
;;; from happening, and they are the design:
;;;
;;; 1. ONLY ASSIGNED VARIABLES ARE BOXED. A variable that is never the target of
;;;    a `set!` is not touched at all -- not renamed, not wrapped, not reloaded.
;;;    Almost every local in the benchmark set is in this category, because
;;;    Scheme's loops are tail calls and its accumulators are parameters.
;;;
;;; 2. A PROVABLY-FLONUM CELL IS AN `flvector`, NOT A `vector`. `flvector-ref`
;;;    yields a `raw-f64`, so the VALUE stays unboxed and stays in a float
;;;    register even though the cell it lives in is tagged. With a general
;;;    vector the slot is tagged, and reading it hands representation selection
;;;    a tagged value it must unbox. The difference is a float register versus a
;;;    value register plus an unbox, on the one datum this compiler is measured
;;;    on. A variable qualifies when its initializer AND every one of its
;;;    assigned values is provably a flonum; anything less falls back to a
;;;    general cell, because `flvector-set!` of a non-flonum is a type error.
;;;
;;; WHAT IS STILL LOST, AND WHO GETS IT BACK. Even an `flvector` cell costs a
;;; heap allocation and turns each read and write into a load and a store. That
;;; is real and this pass cannot remove it: the cell has to exist because a
;;; closure might capture it. ESCAPE ANALYSIS (bead cqs.9) is what proves the
;;; cell does not outlive its frame, and a cell that does not escape can be a
;;; stack slot or a register outright, at which point the load and store go away
;;; and a mutated flonum local is exactly as cheap as an unmutated one. That
;;; pass is NOT implemented here, and this one does not pretend to it. What it
;;; does instead is REPORT: `assign-convert/report` returns every variable it
;;; boxed and which kind of cell it got, so the cost is a number somebody can
;;; look at rather than a silent regression. `assign-report-flonum-boxed` is the
;;; list cqs.9 would empty.
;;;
;;; ONE MORE PRECISION LOSS, RECORDED BECAUSE IT IS NOT OBVIOUS. `(sonic alias)`
;;; treats the fill argument of `make-vector` as escaping, since it lands in a
;;; heap object. So boxing a variable makes its value escape, and a boxed array
;;; can no longer be proved distinct from anything by allocation-site reasoning.
;;; That is why `declare` and `declare-distinct` over an assigned variable are
;;; REFUSED below rather than rewritten: the premise names a variable, and after
;;; boxing that variable is a cell rather than the array the programmer meant.
;;;
;;; --- WHAT THIS PASS REQUIRES OF ITS INPUT ----------------------------------
;;;
;;; The ANF invariant, and it holds it on the way out. Every cell read is bound
;;; by its own `let` before the operand position that needed it, and the two
;;; constants a cell access needs (size 1, index 0) are BOUND TO NAMES rather
;;; than written inline, because `Lanf`'s `primcall` takes variables and not
;;; expressions. That produces two extra bindings per boxed variable, which
;;; constant folding removes and which this pass will not do, because doing it
;;; here would give this pass two jobs.
;;;
;;; The right-hand side of a `set!` must already be an atom. A-normalization
;;; emits `(let ([t ...]) (set! x t))`, never `(set! x (call f))`, and there is
;;; no way to name an arbitrary `Expr`'s result in ANF, so a non-atomic
;;; right-hand side is refused rather than worked around.
;;;
;;; GLOBALS ARE NOT LOCALS. A top-level binding is already a mutable location:
;;; `(sonic gcell)` makes a global reference an indirect load from a cell and
;;; redefinition a store into it. So `assign-convert-program` leaves `set!` on a
;;; top-level name alone; boxing it would put a cell inside a cell.
;;;
;;; Run the tests: scheme -q --libdirs src:vendor/nanopass --script test/assign-test.ss

(library (sonic assign)
  (export assign-convert assign-convert/report
          assign-convert-program assign-convert-program/report
          assigned-variables
          assign-report? assign-report-boxed assign-report-stores
          assign-report-flonum-boxed assign-report-tagged-boxed)
  (import (chezscheme) (nanopass) (sonic lang))

  (define (ac-error msg . irritants)
    (apply error 'assign-convert msg irritants))

  ;; --- the report ----------------------------------------------------------
  ;; `boxed` is ((name . kind) ...) in binder order, kind being `flvector` or
  ;; `vector`. `stores` counts the `set!` forms that became stores.
  (define-record-type assign-report (fields boxed stores))

  (define (assign-report-flonum-boxed r)
    (map car (filter (lambda (p) (eq? (cdr p) 'flvector)) (assign-report-boxed r))))
  (define (assign-report-tagged-boxed r)
    (map car (filter (lambda (p) (eq? (cdr p) 'vector)) (assign-report-boxed r))))

  ;; --- which primitives yield a flonum, whatever their operands ------------
  ;; Stated as a table because the fallback decides between a float register and
  ;; a tagged slot. Note `fl->fx` is NOT here and `fx->fl` is.
  (define (flonum-prim? pr)
    (and (memq pr '(fl+ fl- fl* fl/ flneg flabs flsqrt flvector-ref fx->fl)) #t))

  ;; --- the pre-pass --------------------------------------------------------
  ;;
  ;; Four facts, collected in one walk, all of them about NAMES rather than
  ;; program points, which is sound because the expander makes binders globally
  ;; unique.
  ;;
  ;;   assigned : x -> #t          the target of some set!
  ;;   binders  : x -> #t          bound somewhere we can reach
  ;;   init     : x -> se | 'opaque   what the binding was initialized from
  ;;   rhs      : x -> (e ...)     every value assigned to it
  ;;   flo      : x -> #t          provably holds a flonum
  ;;
  ;; `flo` needs no fixpoint: a primcall's result type does not depend on its
  ;; operands, and the only case that consults another variable is a copy, whose
  ;; source is always bound earlier in a lexically scoped pre-order walk.

  (define (scan e prog-binders)
    (let ([assigned (make-eq-hashtable)]
          [binders (make-eq-hashtable)]
          [init (make-eq-hashtable)]
          [rhs (make-eq-hashtable)]
          [flo (make-eq-hashtable)])

      (define (bind! x) (hashtable-set! binders x #t))
      (define (mark-flonum! x) (hashtable-set! flo x #t))
      (define (flonum-var? x) (hashtable-ref flo x #f))

      (define (flonum-se? se)
        (nanopass-case (Lanf SimpleExpr) se
          [,x (flonum-var? x)]
          [(quote ,d) (flonum? d)]
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (flonum-prim? pr)]
          [else #f]))

      (define (flonum-expr? e)
        (nanopass-case (Lanf Expr) e
          [,x (flonum-var? x)]
          [(quote ,d) (flonum? d)]
          [else #f]))

      (define (Expr e)
        (nanopass-case (Lanf Expr) e
          [,x (void)]
          [(quote ,d) (void)]
          [(if ,x ,e0 ,e1) (Expr e0) (Expr e1)]
          [(seq ,e0 ,e1) (Expr e0) (Expr e1)]
          [(let ([,x ,se]) ,body)
           (bind! x)
           (hashtable-set! init x se)
           (when (flonum-se? se) (mark-flonum! x))
           (SimpleExpr se)
           (Expr body)]
          [(tailcall ,x ,x* ...) (void)]
          [(lambda (,x* ...) ,body)
           ;; A parameter's value comes from callers, so nothing is provable
           ;; about it here. `opaque` is what makes such a parameter fall back to
           ;; a general cell rather than an flvector.
           (for-each (lambda (x) (bind! x) (hashtable-set! init x 'opaque)) x*)
           (Expr body)]
          [(letrec ([,x* ,e*] ...) ,body)
           (for-each (lambda (x) (bind! x) (hashtable-set! init x 'opaque)) x*)
           (for-each Expr e*)
           (Expr body)]
          [(set! ,x ,e)
           (hashtable-set! assigned x #t)
           (hashtable-update! rhs x (lambda (l) (cons e l)) '())
           (Expr e)]
          [(declare ([,x* ,pn*] ...) ,body) (Expr body)]
          [(declare-distinct (,x* ...) ,body) (Expr body)]
          [(policy ([,pn* ,b*] ...) ,body) (Expr body)]
          [else (void)]))

      (define (SimpleExpr se)
        (nanopass-case (Lanf SimpleExpr) se
          [(lambda (,x* ...) ,body)
           (for-each (lambda (x) (bind! x) (hashtable-set! init x 'opaque)) x*)
           (Expr body)]
          [else (void)]))

      ;; A variable gets an flvector cell only if everything that can ever be in
      ;; it is provably a flonum.
      (define (provably-flonum? x)
        (and (let ([i (hashtable-ref init x 'opaque)])
               (and (not (eq? i 'opaque)) (flonum-se? i)))
             (for-all flonum-expr? (hashtable-ref rhs x '()))))

      (for-each bind! prog-binders)
      (for-each (lambda (x) (hashtable-set! init x 'opaque)) prog-binders)
      (Expr e)
      (values assigned binders provably-flonum?)))

  ;; Every variable some `set!` targets. Exported because "is this variable
  ;; mutated" is a question other passes ask and should not re-derive.
  (define (assigned-variables e)
    (let-values ([(assigned binders flonum?) (scan e '())])
      (vector->list (hashtable-keys assigned))))

  ;; --- the conversion ------------------------------------------------------

  (define (convert e prog-binders)
    (let*-values ([(assigned binders provably-flonum?) (scan e prog-binders)])
      (let ([cells (make-eq-hashtable)]     ; x -> #(cell n1 i0 kind)
            [report '()]
            [stores 0]
            [counter 0])

        (define (fresh x tag)
          (set! counter (+ counter 1))
          (string->symbol
           (string-append (symbol->string x) "." tag "." (number->string counter))))

        ;; Boxable, not merely assigned: a `set!` on a name we never see bound
        ;; is a store to a global, and `prog-binders` names the globals we were
        ;; told to leave alone.
        (define (boxable? x)
          (and (hashtable-ref assigned x #f)
               (hashtable-ref binders x #f)
               (not (memq x prog-binders))))

        (define (boxed? x) (hashtable-contains? cells x))
        (define (cell-of x) (hashtable-ref cells x #f))

        (define (register-cell! x)
          (let ([kind (if (provably-flonum? x) 'flvector 'vector)])
            (hashtable-set! cells x
              (vector (fresh x "cell") (fresh x "n1") (fresh x "i0") kind))
            (set! report (cons (cons x kind) report))))

        (define (kind-of x) (vector-ref (cell-of x) 3))
        (define (make-prim x) (if (eq? (kind-of x) 'flvector) 'make-flvector 'make-vector))
        (define (ref-prim x)  (if (eq? (kind-of x) 'flvector) 'flvector-ref 'vector-ref))
        (define (set-prim x)  (if (eq? (kind-of x) 'flvector) 'flvector-set! 'vector-set!))

        (define (prim-se pr x*)
          (let* ([ctl (default-controls pr)]
                 [pn* (map car ctl)]
                 [c* (map cadr ctl)])
            (with-output-language (Lanf SimpleExpr)
              `(primcall ,pr ([,pn* ,c*] ...) ,x* ...))))

        (define (cell-read x)
          (let ([c (cell-of x)])
            (prim-se (ref-prim x) (list (vector-ref c 0) (vector-ref c 2)))))

        ;; The cell, its size and its index, bound around `body`. `x` is still
        ;; the binder the program wrote; it holds the initial value and the cell
        ;; is filled from it, so nothing has to be renamed and an unassigned
        ;; sibling in the same binding form is untouched.
        (define (box-binder x body)
          (let* ([c (cell-of x)]
                 [cell (vector-ref c 0)] [n1 (vector-ref c 1)] [i0 (vector-ref c 2)])
            (with-output-language (Lanf Expr)
              `(let ([,n1 (quote 1)])
                 (let ([,cell ,(prim-se (make-prim x) (list n1 x))])
                   (let ([,i0 (quote 0)])
                     ,body))))))

        ;; Reload every boxed operand into a fresh name, then hand the rewritten
        ;; operand list to `k`. This is where the ANF invariant is kept: a cell
        ;; read is a primcall and an operand position takes only a variable.
        (define (with-unboxed x* k)
          (let loop ([xs x*] [acc '()])
            (cond
             [(null? xs) (k (reverse acc))]
             [(boxed? (car xs))
              (let ([t (fresh (car xs) "v")]
                    [rd (cell-read (car xs))])
                (with-output-language (Lanf Expr)
                  `(let ([,t ,rd]) ,(loop (cdr xs) (cons t acc)))))]
             [else (loop (cdr xs) (cons (car xs) acc))])))

        ;; A `set!` becomes a store and evaluates to the unspecified value,
        ;; which is what it evaluated to before.
        (define (emit-store x v)
          (let* ([c (cell-of x)]
                 [t (fresh x "st")]
                 [st (prim-se (set-prim x) (list (vector-ref c 0) (vector-ref c 2) v))])
            (with-output-language (Lanf Expr)
              `(let ([,t ,st]) (void)))))

        (define (store-into x e)
          (nanopass-case (Lanf Expr) e
            [,y (with-unboxed (list y) (lambda (v*) (emit-store x (car v*))))]
            [(quote ,d)
             (let ([t (fresh x "c")]
                   [q (with-output-language (Lanf SimpleExpr) `(quote ,d))])
               (with-output-language (Lanf Expr)
                 `(let ([,t ,q]) ,(emit-store x t))))]
            [else
             (ac-error "the right-hand side of a set! must already be named; A-normalize first"
                       x)]))

        (define (no-premise-on-boxed! x* what)
          (for-each
           (lambda (x)
             (when (boxable? x)
               (ac-error (string-append what " names an assigned variable; after boxing that name is the cell, not the value the premise is about")
                         x)))
           x*))

        ;; Register cells for the assigned members of a binding group BEFORE
        ;; anything in its scope is converted, so a reference cannot be walked
        ;; while its cell is still unknown.
        (define (register-group! x*)
          (for-each (lambda (x) (when (boxable? x) (register-cell! x))) x*))

        (define (box-group x* body)
          (fold-right (lambda (x acc) (if (boxed? x) (box-binder x acc) acc))
                      body x*))

        (define (Expr e)
          (with-output-language (Lanf Expr)
            (nanopass-case (Lanf Expr) e
              [,x (if (boxed? x)
                      (with-unboxed (list x)
                        (lambda (y*) (let ([y (car y*)])
                                       (with-output-language (Lanf Expr) `,y))))
                      e)]
              [(quote ,d) e]
              [(if ,x ,e0 ,e1)
               (with-unboxed (list x)
                 (lambda (y*)
                   (let ([y (car y*)] [a (Expr e0)] [b (Expr e1)])
                     (with-output-language (Lanf Expr) `(if ,y ,a ,b)))))]
              [(seq ,e0 ,e1) `(seq ,(Expr e0) ,(Expr e1))]
              [(let ([,x ,se]) ,body)
               (SimpleExpr se
                 (lambda (se1)
                   (register-group! (list x))
                   (let ([body1 (box-group (list x) (Expr body))])
                     (with-output-language (Lanf Expr) `(let ([,x ,se1]) ,body1)))))]
              [(tailcall ,x ,x* ...)
               (with-unboxed (cons x x*)
                 (lambda (y*)
                   (let ([f (car y*)] [a* (cdr y*)])
                     (with-output-language (Lanf Expr) `(tailcall ,f ,a* ...)))))]
              [(lambda (,x* ...) ,body) `(lambda (,x* ...) ,(Body x* body))]
              [(letrec ([,x* ,e*] ...) ,body) (Letrec x* e* body)]
              [(set! ,x ,e)
               (set! stores (+ stores 1))
               (if (boxed? x)
                   (store-into x e)
                   ;; A global. `(sonic gcell)` owns this one: a top-level
                   ;; binding is already a cell and boxing it would nest two.
                   `(set! ,x ,(Expr e)))]
              [(declare ([,x* ,pn*] ...) ,body)
               (no-premise-on-boxed! x* "declare")
               `(declare ([,x* ,pn*] ...) ,(Expr body))]
              [(declare-distinct (,x* ...) ,body)
               (no-premise-on-boxed! x* "declare-distinct")
               `(declare-distinct (,x* ...) ,(Expr body))]
              [(policy ([,pn* ,b*] ...) ,body)
               `(policy ([,pn* ,b*] ...) ,(Expr body))]
              [else e])))

        ;; A lambda body: the assigned parameters get their cells filled from the
        ;; parameters themselves, on entry.
        (define (Body x* body)
          (register-group! x*)
          (box-group x* (Expr body)))

        ;; `letrec` with an assigned binding cannot keep that binding: the cell
        ;; has to exist before the right-hand sides run, because a recursive
        ;; reference reads it, and the binding's own value is what fills it. So
        ;; the assigned members leave the `letrec` and become a cell plus a fill.
        ;;
        ;; The fill needs the value as an ATOM, and `letrec`'s right-hand side is
        ;; an `Expr` with no way to name its result in ANF, so only a right-hand
        ;; side that is already simple can be handled. In practice every one of
        ;; them is: an assigned `letrec` binding comes from an internal `define`,
        ;; whose value is a lambda or a literal.
        (define (Letrec x* e* body)
          (register-group! x*)
          (let* ([pairs (map cons x* e*)]
                 [keep (remp (lambda (p) (boxed? (car p))) pairs)]
                 [fill (filter (lambda (p) (boxed? (car p))) pairs)]
                 [kx* (map car keep)]
                 [ke* (map (lambda (p) (Expr (cdr p))) keep)]
                 ;; Each assigned binding's value is stored into its cell in the
                 ;; letrec's body, where every sibling is in scope.
                 [body1 (fold-right
                         (lambda (p acc)
                           (let ([st (fill-cell (car p) (cdr p))])
                             (with-output-language (Lanf Expr) `(seq ,st ,acc))))
                         (Expr body) fill)]
                 [lr (if (null? kx*)
                         body1
                         (with-output-language (Lanf Expr)
                           `(letrec ([,kx* ,ke*] ...) ,body1)))])
            ;; Cells outermost, so a recursive reference inside any right-hand
            ;; side can read one.
            (fold-right (lambda (x acc) (if (boxed? x) (box-cell-only x acc) acc))
                        lr x*)))

        ;; An empty cell, allocated before the right-hand sides so a recursive
        ;; reference can read it. The placeholder is a fixnum (or a flonum for an
        ;; flvector cell) rather than nothing at all: an unfilled slot is a wild
        ;; pointer under a scanning collector, which is why lang.ss makes the
        ;; fill mandatory in the first place.
        (define (box-cell-only x body)
          (let* ([c (cell-of x)]
                 [cell (vector-ref c 0)] [n1 (vector-ref c 1)] [i0 (vector-ref c 2)]
                 [ph (fresh x "ph")]
                 [zero (if (eq? (kind-of x) 'flvector) 0.0 0)])
            (with-output-language (Lanf Expr)
              `(let ([,n1 (quote 1)])
                 (let ([,ph (quote ,zero)])
                   (let ([,cell ,(prim-se (make-prim x) (list n1 ph))])
                     (let ([,i0 (quote 0)])
                       ,body)))))))

        (define (fill-cell x e)
          (nanopass-case (Lanf Expr) e
            [,y (with-unboxed (list y) (lambda (v*) (emit-store x (car v*))))]
            [(quote ,d)
             (let ([t (fresh x "c")]
                   [q (with-output-language (Lanf SimpleExpr) `(quote ,d))])
               (with-output-language (Lanf Expr)
                 `(let ([,t ,q]) ,(emit-store x t))))]
            [(lambda (,x* ...) ,body)
             (let* ([t (fresh x "f")]
                    [l (with-output-language (Lanf SimpleExpr)
                         `(lambda (,x* ...) ,(Body x* body)))])
               (with-output-language (Lanf Expr)
                 `(let ([,t ,l]) ,(emit-store x t))))]
            [else
             (ac-error "an assigned letrec binding needs a simple right-hand side; A-normalize first"
                       x)]))

        (define (SimpleExpr se k)
          (nanopass-case (Lanf SimpleExpr) se
            [,x (if (boxed? x) (k (cell-read x)) (k se))]
            [(quote ,d) (k se)]
            [(lambda (,x* ...) ,body)
             (k (with-output-language (Lanf SimpleExpr)
                  `(lambda (,x* ...) ,(Body x* body))))]
            [(call ,x ,x* ...)
             (with-unboxed (cons x x*)
               (lambda (y*)
                 (k (with-output-language (Lanf SimpleExpr)
                      `(call ,(car y*) ,(cdr y*) ...)))))]
            [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
             (with-unboxed x*
               (lambda (y*)
                 (k (with-output-language (Lanf SimpleExpr)
                      `(primcall ,pr ([,pn* ,c*] ...) ,y* ...)))))]
            [else (k se)]))

        (let ([out (Expr e)])
          (values out (make-assign-report (reverse report) stores))))))

  ;; --- entry points --------------------------------------------------------

  (define (assign-convert/report e) (convert e '()))

  (define (assign-convert e)
    (let-values ([(out r) (convert e '())]) out))

  (define (assign-convert-program/report prog)
    (nanopass-case (Lanf Program) prog
      [(top ([,x* ,e*] ...) (,x2* ...) ,body)
       ;; Each top-level value and the body are converted independently. They
       ;; share no locals, and the top-level names themselves are globals, which
       ;; `(sonic gcell)` already represents as cells.
       (let loop ([es e*] [out '()] [boxed '()] [stores 0])
         (if (null? es)
             (let-values ([(b r) (convert body (append x* x2*))])
               (values
                (with-output-language (Lanf Program)
                  (let ([v* (reverse out)])
                    `(top ([,x* ,v*] ...) (,x2* ...) ,b)))
                (make-assign-report (append (reverse boxed) (assign-report-boxed r))
                                    (+ stores (assign-report-stores r)))))
             (let-values ([(e1 r) (convert (car es) (append x* x2*))])
               (loop (cdr es) (cons e1 out)
                     (append (reverse (assign-report-boxed r)) boxed)
                     (+ stores (assign-report-stores r))))))]))

  (define (assign-convert-program prog)
    (let-values ([(out r) (assign-convert-program/report prog)]) out))
  )
