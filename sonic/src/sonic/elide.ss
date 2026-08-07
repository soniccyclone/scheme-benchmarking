;;; SonicScheme: check elision. Lssa -> Lssa.
;;;
;;; Stage 07. Rewrites `checked` to `proved` on the primcalls whose obligation
;;; the analysis discharged, and touches nothing else.
;;;
;;; THE ONE RULE THAT IS NOT NEGOTIABLE: NEVER WRITE `unchecked`.
;;;
;;; `unchecked` means a POLICY suppressed the check. `proved` means the
;;; ANALYSIS discharged it. lower.ss emits the same code for both and counts
;;; them apart, because "how many checks did we prove away" is the number this
;;; project exists to produce and "how many did the programmer switch off" is
;;; not it. A pass that wrote `unchecked` here would launder a permission into
;;; a proof and the headline result would be a lie. This pass only ever moves
;;; `checked` to `proved`; an `unchecked` control it finds is passed through
;;; and counted as what it is.
;;;
;;; SOUNDNESS DIRECTION. Leaving a check that could have gone costs
;;; instructions. Removing one that was needed corrupts memory. So every
;;; discharge rule below has to be a proof, `unknown` is the default at every
;;; join, and anything this pass does not understand keeps its check.
;;;
;;; WHY TWO ANALYSES AND NOT ONE.
;;;
;;; (sonic interval) is a forward domain: it knows that `i*7 + k` with i in
;;; [0,4] and k in [0,6] lands in [0,34], which is the whole of nbody's index
;;; and is not expressible as a difference constraint. (sonic abcd) is a
;;; backward demand search over difference constraints: it knows that an index
;;; guarded by `i < a.length` is in range no matter how many times the loop
;;; went round, which no interval domain gets without a widening operator and a
;;; fixpoint. Neither subsumes the other. A check is discharged if EITHER
;;; proves it, which is sound because both are sound, and it is why nbody and
;;; the ABCD paper's own example both come out.
;;;
;;; A THIRD SOURCE, AND IT IS FREE: A CHECK THAT ALREADY RAN.
;;;
;;; If `a[i]` was checked and execution reached the next instruction, then i is
;;; in range for a, and every later access to a[i] that this one dominates is
;;; redundant. In Lssa dominance is lexical -- the continuation of a `let` is
;;; exactly what the binding dominates -- so the fact is threaded down the
;;; tree and never leaks sideways out of an `if` arm. Note it is established by
;;; a check that was EMITTED as much as by one that was proved, and NOT by one
;;; a policy suppressed: an `unchecked` access that runs off the end has already
;;; entered undefined behaviour and is no evidence of anything.
;;;
;;; WHAT THE ELISION IS FOR. Bodik, Gupta and Sarkar removed 45% of bounds
;;; checks for about 10% speedup, because Jalapeno had no global code motion to
;;; consume the freedom. So the deliverable here is not a count, it is a LIST:
;;; `elide-report` says which check on which operands went, so stage 10 can be
;;; asked whether it used the freedom. See docs/phases/07-compiler/CUJ.md,
;;; milestone 2.

(library (sonic elide)
  (export elide elide-program elide-facts?
          elide-stats? elide-stats-sites
          elide-proved elide-kept elide-unchecked
          elide-proved-by elide-report
          elide-site? elide-site-prim elide-site-check
          elide-site-verdict elide-site-why elide-site-args)
  (import (chezscheme) (nanopass)
          (sonic lang) (sonic interval) (sonic abcd) (sonic gc))

  ;; --- what a decision looks like from outside ------------------------------

  ;; verdict is one of
  ;;   proved      this pass discharged it, control rewritten to `proved`
  ;;   kept        not discharged, control still `checked`
  ;;   unchecked   a policy had already suppressed it; passed through untouched
  ;;   prior       already `proved` on entry, by an earlier pass
  ;; why is the rule that discharged it, or #f.
  (define-record-type (elide-site make-elide-site elide-site?)
    (fields prim check verdict why args))

  (define-record-type (elide-stats make-elide-stats elide-stats?)
    (fields (mutable sites)))

  (define (count-verdict st v)
    (length (filter (lambda (s) (eq? (elide-site-verdict s) v)) (elide-stats-sites st))))

  (define (elide-proved st) (count-verdict st 'proved))
  (define (elide-kept st) (count-verdict st 'kept))
  (define (elide-unchecked st) (count-verdict st 'unchecked))

  ;; Proved sites for one named check, so a caller can ask the question that
  ;; matters -- WHICH bounds checks went -- rather than only how many.
  (define (elide-proved-by st check)
    (filter (lambda (s) (and (eq? (elide-site-verdict s) 'proved)
                             (eq? (elide-site-check s) check)))
            (elide-stats-sites st)))

  (define (elide-report st)
    (printf "  proved ~a, kept ~a, policy-suppressed ~a\n"
            (elide-proved st) (elide-kept st) (elide-unchecked st))
    (for-each
      (lambda (s)
        (printf "    ~a ~a ~a ~a~a\n"
                (case (elide-site-verdict s)
                  [(proved) "[+] proved   "]
                  [(kept) "[-] kept     "]
                  [(unchecked) "[x] suppressed"]
                  [else "[.] prior    "])
                (elide-site-check s)
                (elide-site-prim s)
                (elide-site-args s)
                (if (elide-site-why s)
                    (string-append "  by " (symbol->string (elide-site-why s)))
                    "")))
      (elide-stats-sites st)))

  (define (record! stats pr check verdict why args)
    (elide-stats-sites-set!
      stats (cons (make-elide-site pr check verdict why args) (elide-stats-sites stats))))

  ;; --- the fixnum range -----------------------------------------------------
  ;; An overflow check is discharged when the result provably fits a tagged
  ;; fixnum. The width is NOT a constant of this file: it is the word minus the
  ;; tag minus the sign, and the tag width lives in (sonic gc), which is the one
  ;; place that gets to decide it.
  (define fixnum-bits (- 64 gc-tag-bits 1))
  (define fixnum-hi (- (expt 2 fixnum-bits) 1))
  (define fixnum-lo (- (expt 2 fixnum-bits)))

  (define (exact-int? d) (and (integer? d) (exact? d)))

  (define (fits-fixnum? a)
    (let ([lo (interval-lo a)] [hi (interval-hi a)])
      (and (exact-int? lo) (exact-int? hi) (<= lo hi)
           (>= lo fixnum-lo) (<= hi fixnum-hi))))

  (define (nonneg-fixnum? a)
    (and (fits-fixnum? a) (>= (interval-lo a) 0)))

  (define (excludes-zero? a)
    (let ([lo (interval-lo a)] [hi (interval-hi a)])
      (or (and (exact-int? lo) (> lo 0))
          (and (exact-int? hi) (< hi 0)))))

  ;; --- the environment ------------------------------------------------------
  ;;
  ;; Immutable and rebuilt at each binding, so an `if` arm cannot leak a fact
  ;; to its sibling by construction rather than by remembering to undo one.

  (define-record-type (eenv make-eenv eenv?)
    (fields ivs      ; name -> interval
            kinds    ; name -> flvector | vector | pair
            lens     ; name -> exact length
            proved   ; obligations discharged by a dominating check
            nonnan   ; names premised not to be NaN
            graph))  ; the ABCD inequality graph, built once over the whole term

  (define (iv-of env x) (let ([p (assq x (eenv-ivs env))]) (if p (cdr p) iv-top)))
  (define (kind-of env x) (let ([p (assq x (eenv-kinds env))]) (and p (cdr p))))
  (define (len-of env x) (let ([p (assq x (eenv-lens env))]) (and p (cdr p))))
  (define (nonnan-of env x) (and (memq x (eenv-nonnan env)) #t))
  (define (holds? env ob) (and (member ob (eenv-proved env)) #t))

  (define (with-iv env x v)
    (make-eenv (cons (cons x v) (eenv-ivs env)) (eenv-kinds env) (eenv-lens env)
               (eenv-proved env) (eenv-nonnan env) (eenv-graph env)))
  (define (with-kind env x k)
    (if (not k) env
        (make-eenv (eenv-ivs env) (cons (cons x k) (eenv-kinds env)) (eenv-lens env)
                   (eenv-proved env) (eenv-nonnan env) (eenv-graph env))))
  (define (with-len env x n)
    (if (not n) env
        (make-eenv (eenv-ivs env) (eenv-kinds env) (cons (cons x n) (eenv-lens env))
                   (eenv-proved env) (eenv-nonnan env) (eenv-graph env))))
  (define (with-nonnan env x)
    (make-eenv (eenv-ivs env) (eenv-kinds env) (eenv-lens env)
               (eenv-proved env) (cons x (eenv-nonnan env)) (eenv-graph env)))
  (define (with-obligations env obs)
    (if (null? obs) env
        (make-eenv (eenv-ivs env) (eenv-kinds env) (eenv-lens env)
                   (append obs (eenv-proved env)) (eenv-nonnan env) (eenv-graph env))))

  ;; x0 is the same value as x1, so everything known about x1 is known about
  ;; x0, obligations included. This is what makes a check that dominates a
  ;; sigma still discharge the accesses below it, where the index has a new
  ;; name and the same value.
  (define (alias-facts env x0 x1)
    (let* ([e1 (with-kind env x0 (kind-of env x1))]
           [e2 (with-len e1 x0 (len-of env x1))]
           [e3 (if (nonnan-of env x1) (with-nonnan e2 x0) e2)]
           [obs (map (lambda (ob) (map (lambda (t) (if (eq? t x1) x0 t)) ob))
                     (filter (lambda (ob) (memq x1 ob)) (eenv-proved env)))])
      (with-obligations e3 obs)))

  ;; --- facts the caller supplies --------------------------------------------
  ;;
  ;; A real pipeline gets these from the enclosing scope. A fixture has no
  ;; enclosing scope, so they are stated:
  ;;
  ;;   (b flvector 35)     b is an flvector of 35 elements
  ;;   (v vector)          v is a vector, length unknown
  ;;   (i interval 0 4)    bounds may be exact integers, neginf or posinf
  ;;   (x non-nan)         x is not NaN, which is what unlocks the false edge
  ;;                       of a flonum comparison

  (define (elide-facts? fs)
    (and (list? fs)
         (for-all (lambda (f) (and (pair? f) (symbol? (car f)) (pair? (cdr f)))) fs)))

  (define (fact-lengths facts)
    (let loop ([fs facts] [acc '()])
      (cond [(null? fs) (reverse acc)]
            [(and (memq (cadr (car fs)) '(flvector vector)) (pair? (cddr (car fs))))
             (loop (cdr fs) (cons (cons (car (car fs)) (caddr (car fs))) acc))]
            [else (loop (cdr fs) acc)])))

  (define (facts->env facts g)
    (fold-left
      (lambda (env f)
        (let ([x (car f)] [tag (cadr f)] [rest (cddr f)])
          (case tag
            [(flvector vector)
             (with-len (with-kind env x tag) x (and (pair? rest) (car rest)))]
            [(pair) (with-kind env x 'pair)]
            [(interval) (with-iv env x (make-interval (car rest) (cadr rest)))]
            [(non-nan) (with-nonnan env x)]
            [else env])))
      (make-eenv '() '() '() '() '() g)
      facts))

  ;; --- the discharge rules --------------------------------------------------
  ;;
  ;; Each returns (values discharged? why). `why` names the rule, so the report
  ;; can say not just that a check went but what removed it, which is the
  ;; difference between a result and an anecdote.

  (define (want-kind pr)
    (case pr
      [(flvector-ref flvector-set! flvector-length) 'flvector]
      [(vector-ref vector-set! vector-length) 'vector]
      [(car cdr) 'pair]
      [else #f]))

  (define (bounds-ok? pr args env)
    (if (< (length args) 2)
        (values #f #f)
        (let* ([v (car args)] [i (cadr args)] [n (len-of env v)])
          (cond
            [(holds? env (list 'bounds v i)) (values #t 'dominating-check)]
            [(and n (iv-within? (iv-of env i) (iv-const n))) (values #t 'interval)]
            [(abcd-in-bounds? (eenv-graph env) i (or n (abcd-length-vertex v)))
             (values #t 'abcd)]
            [else (values #f #f)]))))

  (define (type-ok? pr args env)
    (let ([k (want-kind pr)])
      (cond
        [(and k (pair? args))
         (let ([v (car args)])
           (cond [(eq? (kind-of env v) k) (values #t 'premise)]
                 [(holds? env (list 'type v k)) (values #t 'dominating-check)]
                 [else (values #f #f)]))]
        ;; make-flvector's obligation is on the LENGTH argument, not on a
        ;; container it does not yet have.
        [(and (memq pr '(make-flvector make-vector)) (pair? args))
         (if (nonneg-fixnum? (iv-of env (car args)))
             (values #t 'interval)
             (values #f #f))]
        [else (values #f #f)])))

  (define (overflow-ok? pr args env)
    (let* ([n (length args)]
           [a (lambda (k) (iv-of env (list-ref args k)))]
           [r (case pr
                [(fx+) (and (= n 2) (iv-add (a 0) (a 1)))]
                [(fx-) (and (= n 2) (iv-sub (a 0) (a 1)))]
                [(fx*) (and (= n 2) (iv-mul (a 0) (a 1)))]
                [(fxneg) (and (= n 1) (iv-neg (a 0)))]
                ;; fl->fx's obligation is about a flonum whose range this
                ;; domain does not model, and fxquotient overflows only at
                ;; minfix/-1, which is a special case not worth a rule until
                ;; something asks for it.
                [else #f])])
      (if (and r (fits-fixnum? r)) (values #t 'interval) (values #f #f))))

  (define (div-ok? pr args env)
    (if (and (= (length args) 2) (excludes-zero? (iv-of env (cadr args))))
        (values #t 'interval)
        (values #f #f)))

  (define (discharge? pr check args env)
    (case check
      [(bounds-check) (bounds-ok? pr args env)]
      [(type-check) (type-ok? pr args env)]
      [(overflow-check) (overflow-ok? pr args env)]
      [(div-check) (div-ok? pr args env)]
      ;; fp-contract is a PERMISSION to rewrite, not an obligation to
      ;; discharge. There is nothing here to prove and proving it would mean
      ;; granting ourselves a licence the programmer withheld.
      [else (values #f #f)]))

  (define (decide-one pr check ctl args env stats)
    (cond
      [(eq? ctl 'unchecked) (record! stats pr check 'unchecked #f args) ctl]
      [(eq? ctl 'proved) (record! stats pr check 'prior #f args) ctl]
      [else
       (let-values ([(ok why) (discharge? pr check args env)])
         (cond [ok (record! stats pr check 'proved why args) 'proved]
               [else (record! stats pr check 'kept #f args) ctl]))]))

  ;; What the continuation may assume, given this call returned. Only from a
  ;; check that ran or was proved; see the header on why `unchecked` gives
  ;; nothing.
  (define (established pr checks ctls args)
    (let loop ([cs checks] [ls ctls] [acc '()])
      (cond
        [(null? cs) acc]
        [(not (memq (car ls) '(checked proved))) (loop (cdr cs) (cdr ls) acc)]
        [(and (eq? (car cs) 'bounds-check) (>= (length args) 2))
         (loop (cdr cs) (cdr ls) (cons (list 'bounds (car args) (cadr args)) acc))]
        [(and (eq? (car cs) 'type-check) (want-kind pr) (pair? args))
         (loop (cdr cs) (cdr ls) (cons (list 'type (car args) (want-kind pr)) acc))]
        [else (loop (cdr cs) (cdr ls) acc)])))

  ;; --- abstract value of a simple expression --------------------------------

  (define (se-interval se env)
    (nanopass-case (Lssa SimpleExpr) se
      [,x (iv-of env x)]
      [(quote ,d) (if (exact-int? d) (iv-const d) iv-top)]
      [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
       (let ([n (length x*)]
             [a (lambda (k) (iv-of env (list-ref x* k)))])
         (case pr
           [(fx+) (if (= n 2) (iv-add (a 0) (a 1)) iv-top)]
           [(fx-) (if (= n 2) (iv-sub (a 0) (a 1)) iv-top)]
           [(fx*) (if (= n 2) (iv-mul (a 0) (a 1)) iv-top)]
           [(fxneg) (if (= n 1) (iv-neg (a 0)) iv-top)]
           [(flvector-length vector-length)
            (let ([l (and (= n 1) (len-of env (car x*)))])
              ;; A length is never negative even when it is not known.
              (if l (iv-const l) (iv-range 0 'posinf)))]
           [else iv-top]))]
      [else iv-top]))

  ;; A `let` of a bare variable or of a vector-typed value carries the type and
  ;; length facts across; nothing else does.
  (define (se-alias se)
    (nanopass-case (Lssa SimpleExpr) se [,x x] [else #f]))

  (define (expr-interval e env)
    (nanopass-case (Lssa Expr) e
      [,x (iv-of env x)]
      [(quote ,d) (if (exact-int? d) (iv-const d) iv-top)]
      [else iv-top]))

  ;; --- the walk -------------------------------------------------------------
  ;;
  ;; Returns (values rewritten env'), where env' is env plus what this
  ;; expression established for whatever follows it. Only `let` and `seq`
  ;; propagate: those are the two forms with a continuation in the same scope.
  ;; Everything else returns env unchanged, which is how a fact discovered
  ;; inside one arm of an `if` is prevented from escaping to the other.

  (define (bind-params env x*)
    (fold-left (lambda (en p) (with-iv en p iv-top)) env x*))

  (define (rw-se se env stats)
    (with-output-language (Lssa SimpleExpr)
      (nanopass-case (Lssa SimpleExpr) se
        [,x (values `,x '())]
        [(quote ,d) (values `(quote ,d) '())]
        [(lambda (,x* ...) ,body)
         (let-values ([(b^ _) (rw body (bind-params env x*) stats)])
           (values `(lambda (,x* ...) ,b^) '()))]
        [(call ,x1 ,x* ...) (values `(call ,x1 ,x* ...) '())]
        [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
         (let ([c^* (map (lambda (pn c) (decide-one pr pn c x* env stats)) pn* c*)])
           (values `(primcall ,pr ([,pn* ,c^*] ...) ,x* ...)
                   (established pr pn* c^* x*)))]
        [else (values se '())])))

  (define (rw e env stats)
    (with-output-language (Lssa Expr)
      (nanopass-case (Lssa Expr) e
        [,x (values `,x env)]
        [(quote ,d) (values `(quote ,d) env)]
        [(void) (values `(void) env)]

        [(let ([,x ,se]) ,body)
         (let*-values ([(se^ obs) (rw-se se env stats)])
           (let* ([v (se-interval se env)]
                  [ali (se-alias se)]
                  [env1 (with-iv env x v)]
                  [env2 (if ali (alias-facts env1 x ali) env1)]
                  [env3 (with-obligations env2 obs)])
             (let-values ([(b^ envb) (rw body env3 stats)])
               (values `(let ([,x ,se^]) ,b^) envb))))]

        ;; Both arms are analysed under the incoming environment and neither
        ;; arm's facts survive the join. Refinement on the edges is sigma's
        ;; job and it has already been done by stage 06.
        [(if ,x ,e0 ,e1)
         (let-values ([(a^ _a) (rw e0 env stats)]
                      [(b^ _b) (rw e1 env stats)])
           (values `(if ,x ,a^ ,b^) env))]

        ;; The e-SSA edge fact. What may be concluded from it is iv-refine's
        ;; decision and not this file's: a negated flonum comparison refines
        ;; nothing unless a non-nan premise is in scope for both operands, and
        ;; that rule lives in (sonic interval) alone.
        [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body)
         (let*-values ([(nn) (and (nonnan-of env x1) (nonnan-of env x2))]
                       [(v0 v2) (if (iv-comparison? pr)
                                    (iv-refine pr b (iv-of env x1) (iv-of env x2) nn)
                                    (values (iv-of env x1) (iv-of env x2)))])
           (let* ([env1 (with-iv env x0 v0)]
                  [env2 (if (eq? x1 x2) env1 (with-iv env1 x2 v2))]
                  [env3 (alias-facts env2 x0 x1)])
             (let-values ([(b^ _) (rw body env3 stats)])
               (values `(sigma ,x0 ,x1 ,pr ,x2 ,b ,b^) env))))]

        [(phi ([,x* (,lbl** ,e**) ...] ...) ,body)
         (let* ([e2** (map (lambda (es)
                             (map (lambda (o)
                                    (let-values ([(o^ _) (rw o env stats)]) o^))
                                  es))
                           e**)]
                [vs (map (lambda (es)
                           (if (null? es)
                               iv-top
                               (fold-left (lambda (acc o) (iv-join acc (expr-interval o env)))
                                          iv-bot es)))
                         e**)]
                [env1 (fold-left (lambda (en p) (with-iv en (car p) (cdr p)))
                                 env (map cons x* vs))])
           (let-values ([(b^ _) (rw body env1 stats)])
             (values `(phi ([,x* (,lbl** ,e2**) ...] ...) ,b^) env)))]

        [(letrec ([,x* ,e*] ...) ,body)
         (let* ([r* (map (lambda (r) (let-values ([(r^ _) (rw r env stats)]) r^)) e*)])
           (let-values ([(b^ _) (rw body env stats)])
             (values `(letrec ([,x* ,r*] ...) ,b^) env)))]

        [(lambda (,x* ...) ,body)
         (let-values ([(b^ _) (rw body (bind-params env x*) stats)])
           (values `(lambda (,x* ...) ,b^) env))]

        [(tailcall ,x ,x* ...) (values `(tailcall ,x ,x* ...) env)]

        ;; The first arm dominates the second, so its facts DO propagate. This
        ;; is the only form other than `let` where they do.
        [(seq ,e0 ,e1)
         (let*-values ([(a^ env1) (rw e0 env stats)]
                       [(b^ env2) (rw e1 env1 stats)])
           (values `(seq ,a^ ,b^) env2))]

        [(policy ([,pn* ,b*] ...) ,body)
         (let-values ([(b^ _) (rw body env stats)])
           (values `(policy ([,pn* ,b*] ...) ,b^) env))]

        [(declare ([,x* ,prem*] ...) ,body)
         (let ([env1 (fold-left (lambda (en p) (apply-premise en (car p) (cdr p)))
                                env (map cons x* prem*))])
           (let-values ([(b^ _) (rw body env1 stats)])
             (values `(declare ([,x* ,prem*] ...) ,b^) env)))]

        [(declare-distinct (,x* ...) ,body)
         (let-values ([(b^ _) (rw body env stats)])
           (values `(declare-distinct (,x* ...) ,b^) env))]

        ;; Lssa should have no set! left. If one survives the name is not
        ;; single-valued, so every interval held for it is stale and the safe
        ;; move is to forget it.
        [(set! ,x ,e)
         (let-values ([(e^ _) (rw e env stats)])
           (values `(set! ,x ,e^) (with-iv env x iv-top)))]

        [else (values e env)])))

  ;; `declare` states a premise about a variable already in scope. Only the
  ;; type premises and non-nan are consumed here; a check name used as a
  ;; premise is a policy question and belongs to whatever set the control.
  (define (apply-premise env x prem)
    (case prem
      [(flvector) (with-kind env x 'flvector)]
      [(vector) (with-kind env x 'vector)]
      [(non-nan) (with-nonnan env x)]
      [else env]))

  ;; --- entry point ----------------------------------------------------------

  (define elide
    (case-lambda
      [(e) (elide e '())]
      [(e facts)
       (let* ([g (build-inequality-graph e (fact-lengths facts))]
              [env (facts->env facts g)]
              [stats (make-elide-stats '())])
         (let-values ([(e^ _) (rw e env stats)])
           (elide-stats-sites-set! stats (reverse (elide-stats-sites stats)))
           (values e^ stats)))]))
  
  ;; Program-level entry.
  ;;
  ;; Without it, `elide` on a Program fell through `rw`'s Expr dispatch, walked
  ;; nothing, and reported "proved 0, kept 0" -- which reads exactly like a
  ;; program with no checks rather than like a pass that never ran. Silently
  ;; correct-looking is the worst failure mode available to a pass whose whole
  ;; output is a count, so this exists and `elide` itself now refuses a Program.
  ;;
  ;; Each top-level binding is elided independently and the stats accumulate
  ;; across all of them, so the report covers the whole program rather than
  ;; whichever definition happened to be last.
  (define elide-program
    (case-lambda
      [(p) (elide-program p '())]
      [(p facts)
       (nanopass-case (Lssa Program) p
         [(top ([,x* ,e*] ...) (,x2* ...) ,body)
          (let ([all (make-elide-stats '())])
            (define (one e)
              (let-values ([(e^ st) (elide e facts)])
                (elide-stats-sites-set!
                 all (append (elide-stats-sites all) (elide-stats-sites st)))
                e^))
            (with-output-language (Lssa Program)
              (let* ([v* (map one e*)]
                     [b (one body)])
                (values `(top ([,x* ,v*] ...) (,x2* ...) ,b) all))))])]))
)
