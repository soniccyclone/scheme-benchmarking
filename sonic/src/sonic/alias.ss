;;; SonicScheme: alias analysis over Lanf.
;;;
;;; Stage 09. Answers exactly one question: can these two references touch the
;;; same storage? The answer is `must-not` or `may`, never a guess.
;;;
;;; WHY THIS EXISTS. Stage 10 rewrites
;;;
;;;   for i in [0,n):  a[i] = a[i] + s * b[i]
;;;
;;; into eight lanes at a time. That reorders the reads of `b` against the
;;; writes of `a`. If `a` and `b` are the same flvector the rewrite changes the
;;; answer, so vectorization is illegal unless the two are provably distinct.
;;; This file is what supplies the proof.
;;;
;;; SOUNDNESS DIRECTION, AND IT IS THE OPPOSITE OF THE INTERVAL DOMAIN'S.
;;;
;;; `interval.ss` over-approximates: a wider interval is always safe, because a
;;; check is only elided when the narrow fact is proven. Here the safe answer is
;;; `may`. Saying `may` when the two are in fact distinct costs a vectorization
;;; opportunity. Saying `must-not` when they might alias is a MISCOMPILE: the
;;; vectorizer will happily reorder the accesses and the program computes the
;;; wrong numbers with no diagnostic anywhere.
;;;
;;; So every default in this file is `may`, every unhandled form falls through
;;; to `may`, and an unknown variable is `may`. `must-not` is only ever returned
;;; from a positive proof. If you add a form to Lanf and forget to teach this
;;; file about it, the analysis gets less precise and stays correct.
;;;
;;; WHAT IT PROVES. Deliberately small, per CUJ stage 9: two values from
;;; distinct `make-flvector` (or `make-vector`) calls that have not escaped are
;;; distinct objects. That is decidable locally and it covers the numeric kernel
;;; shapes the benchmarks are made of. Anything else is assumed to alias.
;;;
;;; ON ESCAPE. Strictly, two distinct allocation sites denote distinct objects
;;; forever, escaped or not, so `escaped => may` gives up precision we are not
;;; obliged to give up. We give it up anyway, because the question stage 10 asks
;;; is not only "are these two arrays distinct" but "can anything else touch
;;; this storage while the loop runs". Once a reference is reachable from code
;;; we cannot see, we can no longer enumerate the reads and writes to it, and
;;; distinctness of the pair stops being sufficient. Folding that into the same
;;; verdict keeps the consumer from having to remember to ask twice. The two
;;; facts are still separately visible: `alias-escaped?` reports the escape.
;;;
;;; PRECISION CEILING, STATED. A procedure parameter gets the join of the
;;; actuals at every call site, but only when the procedure is KNOWN: bound to a
;;; lambda by `let` or `letrec`, bound exactly once, and never used anywhere
;;; except as the operator of a `call` or `tailcall`. Anything reached through a
;;; procedure we cannot enumerate the callers of is `may`. This is the
;;; un-inlined ceiling CUJ names in the wave-2 ordering corrections: run
;;; `(sonic inline)` first and the helpers the arrays flow through disappear,
;;; which is precisely why inlining is upstream of this stage.
;;;
;;; NAME UNIQUENESS IS ASSUMED. Binders are taken to be globally unique, which
;;; is what the expander guarantees. Two binders sharing a name are treated as
;;; one variable; for points-to that is a join and therefore sound, and the
;;; known-procedure test above refuses any name bound more than once, so the
;;; interprocedural step cannot be fooled by it.

(library (sonic alias)
  (export alias-analyze
          alias-table?
          alias-query may-alias? must-not-alias?
          alias-points-to alias-escaped? alias-sites)
  (import (chezscheme) (nanopass) (sonic lang))

  ;; --- the table -----------------------------------------------------------
  ;; pt      : symbol -> 'unknown | (site-id ...)      points-to
  ;; escaped : site-id -> #t
  ;; names   : site-id -> symbol                       the binder, for reports
  (define-record-type alias-table
    (fields pt escaped names))

  (define (pt-ref tbl x)
    (let ([h (alias-table-pt tbl)])
      (if (hashtable-contains? h x) (hashtable-ref h x #f) 'unknown)))

  ;; Join on the points-to lattice. 'unknown is top; the empty set is bottom and
  ;; means "holds no reference at all", which is a real and useful fact: a
  ;; flonum cannot touch any storage.
  (define (pts-join a b)
    (cond [(eq? a 'unknown) 'unknown]
          [(eq? b 'unknown) 'unknown]
          [else (let loop ([b b] [acc a])
                  (cond [(null? b) acc]
                        [(memv (car b) acc) (loop (cdr b) acc)]
                        [else (loop (cdr b) (cons (car b) acc))]))]))

  (define (pts-disjoint? a b)
    (not (exists (lambda (s) (memv s b)) a)))

  ;; --- which primitives can even yield a reference -------------------------
  ;; Stated as a table rather than left to a default, because the default here
  ;; decides between precision and a miscompile. Allocators produce a fresh
  ;; object; the readers produce something we cannot name; everything else in
  ;; the prim table produces a fixnum, a flonum or a boolean, none of which is a
  ;; reference to storage.
  (define (allocator? pr) (memq pr '(make-flvector make-vector)))
  (define (reference-reader? pr) (memq pr '(car cdr vector-ref)))
  ;; Primitives that store their operand into a heap object, making it
  ;; reachable by a path we no longer track. The stored VALUE escapes; the
  ;; container does not escape by being written.
  (define (stores-into-heap pr)
    (case pr
      [(vector-set!) '(2)]                 ; (vector-set! v i x)
      [(flvector-set!) '(2)]
      [(cons) '(0 1)]
      [(make-vector) '(1)]                 ; the fill lands in the new vector
      [else '()]))

  ;; --- pre-pass: which names are known procedures --------------------------
  ;; A name is known when it is bound exactly once, bound to a lambda, and never
  ;; appears except as a call operator. The last condition is what lets us
  ;; enumerate the call sites; without it a parameter could be reached from a
  ;; caller we never see.

  (define (scan-procs e)
    (let ([binds (make-eq-hashtable)]     ; name -> number of binding occurrences
          [lam (make-eq-hashtable)]       ; name -> (params ...)
          [nonop (make-eq-hashtable)])    ; name -> #t, used other than as operator
      (define (bind! x) (hashtable-update! binds x (lambda (n) (+ n 1)) 0))
      (define (use! x) (hashtable-set! nonop x #t))
      (define (use*! x*) (for-each use! x*))
      (define (Expr e)
        (nanopass-case (Lanf Expr) e
          [,x (use! x)]
          [(quote ,d) (void)]
          [(if ,x ,e0 ,e1) (use! x) (Expr e0) (Expr e1)]
          [(seq ,e0 ,e1) (Expr e0) (Expr e1)]
          [(let ([,x ,se]) ,body)
           (bind! x)
           (nanopass-case (Lanf SimpleExpr) se
             [(lambda (,x1* ...) ,body1)
              (hashtable-set! lam x x1*) (for-each bind! x1*) (Expr body1)]
             [else (SimpleExpr se)])
           (Expr body)]
          [(tailcall ,x ,x* ...) (use*! x*)]
          [(lambda (,x* ...) ,body) (for-each bind! x*) (Expr body)]
          [(letrec ([,x* ,e*] ...) ,body)
           (for-each bind! x*)
           (for-each (lambda (nm rhs)
                       (nanopass-case (Lanf Expr) rhs
                         [(lambda (,x1* ...) ,body1)
                          (hashtable-set! lam nm x1*) (for-each bind! x1*) (Expr body1)]
                         [else (Expr rhs)]))
                     x* e*)
           (Expr body)]
          [(declare ([,x* ,pn*] ...) ,body) (use*! x*) (Expr body)]
          [(policy ([,pn* ,b*] ...) ,body) (Expr body)]
          [else (void)]))
      (define (SimpleExpr se)
        (nanopass-case (Lanf SimpleExpr) se
          [,x (use! x)]
          [(quote ,d) (void)]
          [(lambda (,x* ...) ,body) (for-each bind! x*) (Expr body)]
          [(call ,x ,x* ...) (use*! x*)]
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (use*! x*)]
          [else (void)]))
      (Expr e)
      ;; known : name -> (params ...)
      (let ([known (make-eq-hashtable)])
        (vector-for-each
         (lambda (nm)
           (when (and (= 1 (hashtable-ref binds nm 0))
                      (not (hashtable-ref nonop nm #f)))
             (hashtable-set! known nm (hashtable-ref lam nm '()))))
         (hashtable-keys lam))
        known)))

  ;; --- the analysis --------------------------------------------------------
  ;;
  ;; Flow-insensitive: one points-to set per variable for the whole program,
  ;; not one per program point. That is the right trade here. Lanf is already
  ;; single-assignment in practice (there is no `set!` in the language), so a
  ;; variable's value does not change over its lifetime and flow sensitivity
  ;; would buy nothing on the shapes we care about.
  ;;
  ;; Run to a fixpoint because a parameter's points-to set depends on call sites
  ;; that may be walked after the body. Both maps only grow and both are bounded
  ;; by (variables x sites), so this terminates; the iteration cap below is a
  ;; guard against a bug in that argument, and it DEGRADES rather than errors.

  (define fixpoint-cap 40)

  (define (alias-analyze e)
    (let* ([known (scan-procs e)]
           [pt (make-eq-hashtable)]
           [escaped (make-eqv-hashtable)]
           [names (make-eqv-hashtable)])

      (define (get x) (if (hashtable-contains? pt x) (hashtable-ref pt x #f) 'unknown))
      (define (put! x v) (hashtable-set! pt x (pts-join (get-or-bottom x) v)))
      ;; A variable we have never bound is 'unknown (top). A variable we HAVE
      ;; bound starts from its recorded set. The distinction matters: joining a
      ;; fresh site into 'unknown must stay 'unknown.
      (define (get-or-bottom x) (if (hashtable-contains? pt x) (hashtable-ref pt x #f) '()))

      (define (escape-pts! v)
        (unless (eq? v 'unknown)
          (for-each (lambda (s) (hashtable-set! escaped s #t)) v)))
      (define (escape-var! x)
        (let ([v (get x)])
          (if (eq? v 'unknown)
              (void)                       ; already top; nothing more to lose
              (escape-pts! v))))

      ;; Every variable occurrence goes through here. `escaping?` is on inside a
      ;; lambda whose closure we cannot account for, and there we simply escape
      ;; everything the body mentions. Blunt, sound, and it needs no free
      ;; variable computation.
      (define (ref! x escaping?) (when escaping? (escape-var! x)))

      (define counter 0)
      (define (fresh-site! binder)
        (set! counter (+ counter 1))
        (hashtable-set! names counter binder)
        counter)

      (define (call! f a* escaping?)
        (ref! f escaping?)
        (for-each (lambda (a) (ref! a escaping?)) a*)
        (let ([params (hashtable-ref known f #f)])
          (if (and params (= (length params) (length a*)))
              ;; Known callee with matching arity: the actuals flow into the
              ;; formals and nothing escapes. The callee body is walked in
              ;; place, so anything it does with them is already accounted for.
              (for-each (lambda (p a) (put! p (get a))) params a*)
              ;; Unknown callee, or an arity we cannot match. Everything handed
              ;; over is now reachable from code we cannot see.
              (for-each escape-var! a*))))

      (define (walk e escaping?)
        (nanopass-case (Lanf Expr) e
          [,x (ref! x escaping?)]
          [(quote ,d) (void)]
          [(if ,x ,e0 ,e1) (ref! x escaping?) (walk e0 escaping?) (walk e1 escaping?)]
          [(seq ,e0 ,e1) (walk e0 escaping?) (walk e1 escaping?)]
          [(let ([,x ,se]) ,body)
           (put! x (walk-se se x escaping?))
           (walk body escaping?)]
          [(tailcall ,x ,x* ...) (call! x x* escaping?)]
          ;; A lambda sitting in Expr position has no name we can key call sites
          ;; on, so its parameters stay top and its body is walked as escaping.
          [(lambda (,x* ...) ,body) (walk body #t)]
          [(letrec ([,x* ,e*] ...) ,body)
           (for-each (lambda (nm rhs)
                       (nanopass-case (Lanf Expr) rhs
                         [(lambda (,x1* ...) ,body1)
                          (walk body1 (or escaping?
                                          (not (hashtable-contains? known nm))))]
                         [else (walk rhs escaping?)]))
                     x* e*)
           (walk body escaping?)]
          [(declare ([,x* ,pn*] ...) ,body)
           (for-each (lambda (x) (ref! x escaping?)) x*)
           (walk body escaping?)]
          [(policy ([,pn* ,b*] ...) ,body) (walk body escaping?)]
          [else (void)]))

      ;; Returns the points-to set for the variable this SimpleExpr is bound to.
      (define (walk-se se binder escaping?)
        (nanopass-case (Lanf SimpleExpr) se
          [,x (ref! x escaping?) (get x)]
          ;; `datum?` admits strings, which are the one mutable datum, and two
          ;; references to one literal are the same object. No primitive in the
          ;; table touches a string, but the default here has to be right rather
          ;; than merely unreachable.
          [(quote ,d) (if (string? d) 'unknown '())]
          [(lambda (,x* ...) ,body)
           (walk body (or escaping? (not (hashtable-contains? known binder))))
           ;; A closure is storage too. We never need to prove two closures
           ;; distinct, so this costs nothing and keeps the default at `may`.
           'unknown]
          [(call ,x ,x* ...) (call! x x* escaping?) 'unknown]
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
           (for-each (lambda (a) (ref! a escaping?)) x*)
           (let ([stored (stores-into-heap pr)])
             (let loop ([i 0] [a* x*])
               (unless (null? a*)
                 (when (memv i stored) (escape-var! (car a*)))
                 (loop (+ i 1) (cdr a*)))))
           (cond [(allocator? pr) (list (fresh-site! binder))]
                 [(reference-reader? pr) 'unknown]
                 [else '()])]
          [else 'unknown]))

      ;; Monotone signature: strictly increases until the fixpoint.
      (define (signature)
        (let ([n 0])
          (vector-for-each
           (lambda (x)
             (let ([v (hashtable-ref pt x #f)])
               (set! n (+ n 1 (if (eq? v 'unknown) 1000000 (length v))))))
           (hashtable-keys pt))
          (+ n (* 7 (hashtable-size escaped)))))

      (let loop ([i 0] [prev -1])
        (cond
         [(> i fixpoint-cap)
          ;; The termination argument above says we cannot get here. If we do,
          ;; the argument is wrong, and the only safe response is to forget
          ;; everything: an all-top table answers `may` to every query.
          (make-alias-table (make-eq-hashtable) (make-eqv-hashtable) names)]
         [else
          (set! counter 0)
          (walk e #f)
          (let ([s (signature)])
            (if (= s prev)
                (make-alias-table pt escaped names)
                (loop (+ i 1) s)))]))))

  ;; --- the query -----------------------------------------------------------

  (define (alias-points-to tbl x) (pt-ref tbl x))

  (define (alias-escaped? tbl x)
    (let ([v (pt-ref tbl x)])
      (or (eq? v 'unknown)
          (exists (lambda (s) (hashtable-ref (alias-table-escaped tbl) s #f)) v))))

  ;; Every allocation site the table knows about, as (id . binder).
  (define (alias-sites tbl)
    (let ([h (alias-table-names tbl)])
      (map (lambda (k) (cons k (hashtable-ref h k #f)))
           (vector->list (hashtable-keys h)))))

  ;; 'must-not or 'may. Read the cond top to bottom: every branch but the last
  ;; two answers `may`, and the one branch that answers `must-not` is guarded by
  ;; a positive proof that the two point-to sets are known, unescaped and
  ;; disjoint.
  (define (alias-query tbl x y)
    (let ([px (pt-ref tbl x)] [py (pt-ref tbl y)])
      (cond
       ;; Nothing known about one of them.
       [(or (eq? px 'unknown) (eq? py 'unknown)) 'may]
       ;; Reachable from code we cannot see, so we cannot enumerate the
       ;; accesses to it. See the header note on escape.
       [(or (alias-escaped? tbl x) (alias-escaped? tbl y)) 'may]
       ;; Disjoint allocation sites. Two executions of `make-flvector` return
       ;; different objects, so this is the proof. Note that a site is NOT
       ;; disjoint from itself: one syntactic site inside a loop produces a
       ;; different object per iteration, but two references carrying that same
       ;; site may well be the same object, which is exactly the case a
       ;; self-comparison has to answer `may` on.
       [(pts-disjoint? px py) 'must-not]
       [else 'may])))

  (define (may-alias? tbl x y) (eq? 'may (alias-query tbl x y)))
  (define (must-not-alias? tbl x y) (eq? 'must-not (alias-query tbl x y)))
  )
