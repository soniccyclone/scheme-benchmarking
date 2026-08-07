;;; SonicScheme: ABCD. Bodik, Gupta and Sarkar, PLDI 2000.
;;;
;;; Stage 07, over Lssa. Builds the INEQUALITY GRAPH from e-SSA and answers
;;; bounds queries by demand-driven backward search over it, memoised with the
;;; paper's three-colour lattice.
;;;
;;; WHY THIS AND NOT ANOTHER FIXPOINT.
;;;
;;; The interval domain (sonic interval) is a forward abstract interpretation:
;;; it computes a value for every variable whether or not anyone asked. ABCD
;;; computes nothing until a check asks a question, and then it walks backwards
;;; from the index to the length. That is the right shape for a check-elision
;;; client, and it is the only shape that handles a loop-carried index without
;;; a widening operator: the cycle is not iterated to a fixpoint, it is
;;; DETECTED, and its sign is the answer.
;;;
;;; THE CONSTRAINT LANGUAGE, AND WHAT IT CANNOT SAY.
;;;
;;; Difference constraints only: `x <= y + c` for an exact integer c. That is
;;; enough for indices built by addition, for guards, and for phis, which is
;;; every loop-carried index. It is NOT enough for `off = i * 7`, because a
;;; product of a variable and a constant is not a difference constraint and no
;;; amount of graph is going to make it one. This is a real limit of the
;;; algorithm and not an omission here: nbody's index is proved by the interval
;;; domain, and (sonic elide) runs both and takes whichever answers. Saying so
;;; out loud is cheaper than a reader discovering it from a failing test.
;;;
;;; TWO GRAPHS, NOT ONE.
;;;
;;; A phi is a MEET vertex: `x = phi(a, b)` gives `x <= max(a,b)` and
;;; `x >= min(a,b)`, and neither is a single constraint -- each is the
;;; conjunction over the operands, which is why the search takes the meet over
;;; a phi's edges and the join over everything else. The two halves do not live
;;; in one graph, because `x <= a` and `x >= a` are different edges with
;;; different traversal arithmetic. So there are two edge sets, `up` and `lo`,
;;; and the search carries a direction. The paper calls this proving the upper
;;; bound on the inequality graph and the lower bound on its inverse; the sign
;;; parameter here is the same thing with one copy of the code.
;;;
;;; SIGMA IS WHERE THE SOUNDNESS ARGUMENT LIVES, AND IT IS DIRECTIONAL.
;;;
;;; For `i2 = sigma(i)` on the true edge of `i < n` we add `i2 <= i` and
;;; `i2 <= n - 1`. We do NOT add `i <= i2`. The values are equal -- i2 IS i --
;;; but i is live on the OTHER edge too, where nothing bounds it by n, and a
;;; constraint in this graph is read at every vertex that can reach it. Adding
;;; the reverse edge would let a query about i pick up i2's bound and conclude
;;; `i <= n - 1` on the edge where the test failed. That is the wrong-code
;;; direction. e-SSA exists precisely so the fact and the name have the same
;;; scope; throwing that away in the graph builder would waste stage 06.
;;;
;;; The same reasoning says a FLONUM comparison contributes no edge at all.
;;; `iv-edge-cmp` will happily report `<` for the true edge of `fl<`, and it is
;;; right, but `a < b` over the reals does not give `a <= b - 1`. The minus one
;;; is an integrality argument and only fixnums have it.
;;;
;;; THE FREE LUNCH, per docs/phases/07-compiler/CUJ.md.
;;;
;;; An AMPLIFYING CYCLE -- one whose total weight round the loop is nonzero --
;;; is exactly an induction variable, and the weight is exactly its step. The
;;; search already has to detect these to terminate, so induction-variable
;;; discrimination falls out with no extra machinery. `abcd-ivs` exposes it.
;;; What does NOT fall out is a trip count, so (sonic loops) does not go away;
;;; see the cross-check in test/abcd-test.ss, which compares the two and
;;; reports a disagreement rather than picking a winner.

(library (sonic abcd)
  (export build-inequality-graph
          abcd-graph? abcd-vertices abcd-edges abcd-phi-vertex?
          abcd-zero abcd-opaque abcd-length-vertex
          abcd-prove abcd-prove-upper abcd-prove-lower
          abcd-in-bounds?
          abcd-ivs abcd-iv? abcd-iv-name abcd-iv-step abcd-iv-weights
          abcd-iv-ref)
  (import (chezscheme) (nanopass) (sonic lang) (sonic interval))

  ;; --- vertices --------------------------------------------------------------
  ;; Program variables are their own vertices. Three kinds are synthetic.

  ;; The origin. Every constant is expressed as an offset from it, so a query
  ;; against a literal bound is a query against this vertex.
  (define abcd-zero (string->symbol "#zero"))

  ;; A vertex with no incoming edges, so every proof through it fails. Used
  ;; where the graph must record "and something we cannot see" -- an unknown
  ;; phi operand, a parameter of a function whose call sites we do not have.
  ;; Spelling it as a vertex rather than as a missing edge keeps the meet at a
  ;; phi honest: a phi with one known and one unknown operand must fail, and it
  ;; would silently succeed if the unknown operand contributed no edge.
  (define abcd-opaque (string->symbol "#opaque"))

  ;; The length of a vector, which is a value the program may never name. Where
  ;; it does name it, via flvector-length, the two are wired together as an
  ;; equality.
  (define (abcd-length-vertex v)
    (string->symbol (string-append "#len." (symbol->string v))))

  ;; --- the graph -------------------------------------------------------------

  (define-record-type (abcd-graph make-abcd-graph abcd-graph?)
    (fields up            ; v -> ((u . w) ...)   meaning  v <= u + w
            lo            ; v -> ((u . w) ...)   meaning  v >= u + w
            phis          ; v -> #t              meet vertex
            (mutable names)
            memo          ; (dir a v) -> (true-c . false-c)
            (mutable cycle-hits)))

  (define (abcd-vertices g) (abcd-graph-names g))

  (define (abcd-edges g dir v)
    (hashtable-ref (if (eq? dir 'up) (abcd-graph-up g) (abcd-graph-lo g)) v '()))

  (define (abcd-phi-vertex? g v) (hashtable-ref (abcd-graph-phis g) v #f))

  ;; --- construction ----------------------------------------------------------

  (define (exact-int? d) (and (integer? d) (exact? d)))

  ;; Comparisons that license an integer difference constraint. The flonum
  ;; spellings are deliberately absent; see the header.
  (define (integer-cmp? pr)
    (and (memq pr '(< <= = >= > fx< fx<= fx= fx>= fx>)) #t))

  (define build-inequality-graph
    (case-lambda
      [(e) (build-inequality-graph e '())]
      [(e lengths) (build-graph e lengths)]))

  ;; `lengths` is an alist of vector name . exact length, for the lengths the
  ;; caller knows and the program does not compute. Everything else comes out
  ;; of the term.
  (define (build-graph top lengths)
    (define up (make-eq-hashtable))
    (define lo (make-eq-hashtable))
    (define phis (make-eq-hashtable))
    (define seen (make-eq-hashtable))
    (define names '())

    ;; name -> exact integer, for constants and copies of them. Operands in
    ;; Lssa are atoms, so `i + 1` is spelled `(fx+ i one)` with `one` let-bound
    ;; to `(quote 1)`; without this table every increment would look like a sum
    ;; of two unknowns and no induction variable would have a step.
    (define consts (make-eq-hashtable))

    ;; Function structure, resolved after the walk because a call site may
    ;; precede the lambda it calls.
    (define fn-params (make-eq-hashtable))   ; f -> (p ...)
    (define fn-sites (make-eq-hashtable))    ; f -> ((arg ...) ...)
    (define value-use (make-eq-hashtable))   ; name used other than as callee

    (define (vertex! v)
      (unless (hashtable-ref seen v #f)
        (hashtable-set! seen v #t)
        (set! names (cons v names))))

    (define (add! tab v u w)
      (vertex! v) (vertex! u)
      (hashtable-set! tab v (cons (cons u w) (hashtable-ref tab v '()))))

    (define (both! v u w) (add! up v u w) (add! lo v u w))

    (define (mark-phi! v) (vertex! v) (hashtable-set! phis v #t))

    (define (use! x) (hashtable-set! value-use x #t))

    (define (const-of x) (hashtable-ref consts x #f))

    (define (var-of e) (nanopass-case (Lssa Expr) e [,x x] [else #f]))

    ;; x is exactly y: both bounds transfer, and so does constancy.
    (define (copy! x y)
      (both! x y 0)
      (let ([k (const-of y)]) (when k (hashtable-set! consts x k))))

    (define (prim-edges! x pr args)
      (let ([n (length args)])
        (cond
          [(and (eq? pr 'fx+) (= n 2))
           (let* ([a (car args)] [b (cadr args)] [ka (const-of a)] [kb (const-of b)])
             (cond [kb (both! x a kb) (when ka (hashtable-set! consts x (+ ka kb)))]
                   [ka (both! x b ka)]
                   [else (void)]))]
          [(and (eq? pr 'fx-) (= n 2))
           ;; Only a constant SUBTRAHEND. `k - b` is a negation, and negation
           ;; is not a difference constraint.
           (let* ([a (car args)] [b (cadr args)] [ka (const-of a)] [kb (const-of b)])
             (when kb
               (both! x a (- kb))
               (when ka (hashtable-set! consts x (- ka kb)))))]
          [(and (memq pr '(flvector-length vector-length)) (= n 1))
           (let ([lv (abcd-length-vertex (car args))])
             ;; An equality, so both directions, and the synthetic vertex is
             ;; the one that benefits: facts stated about the length reach the
             ;; program's name for it and vice versa.
             (both! x lv 0)
             (both! lv x 0)
             ;; A length is never negative. Cheap, and it is what discharges
             ;; the lower half of a check against a symbolic length.
             (add! lo lv abcd-zero 0))]
          [else (void)])))

    (define (walk-se se x)
      (nanopass-case (Lssa SimpleExpr) se
        [,x1 (use! x1) (copy! x x1)]
        [(quote ,d)
         (when (exact-int? d)
           (hashtable-set! consts x d)
           (both! x abcd-zero d))]
        [(lambda (,x* ...) ,body) (enter-fn! x x* body)]
        [(call ,x1 ,x* ...)
         (hashtable-set! fn-sites x1 (cons x* (hashtable-ref fn-sites x1 '())))
         (for-each use! x*)]
        [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
         (for-each use! x*)
         (prim-edges! x pr x*)]
        [else (void)]))

    (define (enter-fn! f p* body)
      (hashtable-set! fn-params f p*)
      (for-each vertex! p*)
      (walk body))

    (define (walk e)
      (nanopass-case (Lssa Expr) e
        [,x (use! x) (vertex! x)]
        [(quote ,d) (void)]

        [(let ([,x ,se]) ,body) (vertex! x) (walk-se se x) (walk body)]

        [(if ,x ,e0 ,e1) (use! x) (walk e0) (walk e1)]

        ;; The e-SSA fact. One copy edge and, for an integer comparison, one
        ;; refinement edge in whichever direction the edge licenses. Nothing
        ;; flows back to the unrefined name; see the header.
        [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body)
         (use! x1) (use! x2) (vertex! x0)
         (copy! x0 x1)
         (when (integer-cmp? pr)
           (case (iv-edge-cmp pr b)
             [(<)  (add! up x0 x2 -1)]
             [(<=) (add! up x0 x2 0)]
             [(>)  (add! lo x0 x2 1)]
             [(>=) (add! lo x0 x2 0)]
             [(=)  (add! up x0 x2 0) (add! lo x0 x2 0)]
             [else (void)]))
         (walk body)]

        ;; A meet vertex. An operand that is not a bare variable -- the `join`
        ;; edge of a value-position diamond carries a whole `if` -- becomes an
        ;; edge to #opaque, so the meet fails rather than quietly ignoring it.
        [(phi ([,x* (,lbl** ,e**) ...] ...) ,body)
         (for-each
           (lambda (x es)
             (mark-phi! x)
             (if (null? es)
                 (both! x abcd-opaque 0)
                 (for-each
                   (lambda (o)
                     (let ([v (var-of o)])
                       (if v
                           (begin (use! v) (both! x v 0))
                           (begin (walk o) (both! x abcd-opaque 0)))))
                   es)))
           x* e**)
         (walk body)]

        [(tailcall ,x ,x* ...)
         (hashtable-set! fn-sites x (cons x* (hashtable-ref fn-sites x '())))
         (for-each use! x*)]

        [(letrec ([,x* ,e*] ...) ,body)
         (for-each
           (lambda (nm rhs)
             (nanopass-case (Lssa Expr) rhs
               [(lambda (,x1* ...) ,body1) (enter-fn! nm x1* body1)]
               [else (walk rhs)]))
           x* e*)
         (walk body)]

        ;; No name to key call sites on, so its parameters can never be wired.
        ;; Walked anyway, for the definitions inside it.
        [(lambda (,x* ...) ,body)
         (enter-fn! (gensym "anon") x* body)]

        [(seq ,e0 ,e1) (walk e0) (walk e1)]
        [(policy ([,pn* ,b*] ...) ,body) (walk body)]
        [(declare ([,x* ,prem*] ...) ,body) (for-each use! x*) (walk body)]
        [(declare-distinct (,x* ...) ,body) (for-each use! x*) (walk body)]
        ;; Lssa should be free of set! after assignment conversion. If one
        ;; survives the name is not single-valued, so every constraint about it
        ;; is void and the vertex is cut loose.
        [(set! ,x ,e)
         (hashtable-set! up x (list (cons abcd-opaque 0)))
         (hashtable-set! lo x (list (cons abcd-opaque 0)))
         (walk e)]
        [else (void)]))

    ;; --- wire parameters -----------------------------------------------------
    ;; A parameter is a meet over its call sites, exactly like a phi. It is only
    ;; that if we have ALL the call sites: a function name used anywhere other
    ;; than in operator position may be called from somewhere we cannot see, and
    ;; then every parameter is opaque.

    (define (wire-params!)
      (vector-for-each
        (lambda (f)
          (let* ([p* (hashtable-ref fn-params f '())]
                 [n (length p*)]
                 [sites (hashtable-ref fn-sites f '())]
                 [ok (filter (lambda (a) (= (length a) n)) sites)]
                 [escapes? (or (hashtable-ref value-use f #f)
                               (null? sites)
                               (not (= (length ok) (length sites))))])
            (let loop ([ps p*] [k 0])
              (unless (null? ps)
                (mark-phi! (car ps))
                (if escapes?
                    (both! (car ps) abcd-opaque 0)
                    (for-each (lambda (args) (both! (car ps) (list-ref args k) 0)) ok))
                (loop (cdr ps) (+ k 1))))))
        (hashtable-keys fn-params)))

    (walk top)
    (wire-params!)
    ;; Lengths the caller knows. `b has 35 elements` is a fact about the
    ;; synthetic length vertex, so it composes with everything the program said
    ;; about its own flvector-length.
    (for-each (lambda (p)
                (let ([lv (abcd-length-vertex (car p))])
                  (both! lv abcd-zero (cdr p))))
              lengths)
    (vertex! abcd-zero)
    (vertex! abcd-opaque)
    (make-abcd-graph up lo phis names (make-hashtable equal-hash equal?) 0))

  ;; --- the three-colour lattice ---------------------------------------------
  ;;
  ;;   true     the inequality holds
  ;;   reduced  it holds, but the proof went round a cycle that made the
  ;;            constraint STRICTLY EASIER each time. A reducing cycle can only
  ;;            help, so the caller reads this as true; it is kept distinct
  ;;            because it must not be memoised as an unconditional fact.
  ;;   false    not proved

  (define (rank r) (case r [(false) 0] [(reduced) 1] [else 2]))
  (define (meet a b) (if (< (rank a) (rank b)) a b))
  (define (join a b) (if (> (rank a) (rank b)) a b))

  ;; --- the query -------------------------------------------------------------
  ;;
  ;; (abcd-prove g dir a v c) decides
  ;;     dir = up   ->   v <= a + c
  ;;     dir = lo   ->   v >= a + c
  ;;
  ;; The two differ only by the sign of every comparison on c, so one procedure
  ;; carries both with `sgn`. Traversal is identical: an edge (u . w) at v means
  ;; `v REL u + w`, so the subgoal at u is the same relation with c - w.

  (define (abcd-prove g dir a v c)
    (let ([active (make-eq-hashtable)])
      (prove g dir a v c active (make-counter))))

  ;; How many meet vertices are on the current search path. A cycle is only
  ;; readable as a loop iteration if it passes through one, and that is the
  ;; whole basis for treating a cycle coinductively: the argument is "if it
  ;; held on the previous iteration it holds on this one", and without a merge
  ;; point there are no iterations to induct over.
  ;;
  ;; Getting this wrong is not a lost optimization. `len` and `#len.b` are wired
  ;; as an equality, which is a zero-weight two-cycle with no phi in it; reading
  ;; that as a neutral cycle and returning `true` proves EVERY inequality about
  ;; a length, including the false ones.
  (define (make-counter) (list 0))
  (define (counter-value k) (car k))
  (define (counter-bump! k n) (set-car! k (+ (car k) n)))

  (define (abcd-prove-upper g a v c) (proved? (abcd-prove g 'up a v c)))
  (define (abcd-prove-lower g a v c) (proved? (abcd-prove g 'lo a v c)))

  ;; `reduced` reads as proved at the top level: a reducing cycle only ever
  ;; makes the constraint easier. It stays a separate value inside the search
  ;; so that it is never memoised as an unconditional fact.
  (define (proved? r) (and (memq r '(true reduced)) #t))

  (define (memo-key dir a v) (list dir a v))

  (define (prove g dir a v c active phis-seen)
    (let* ([sgn (if (eq? dir 'up) 1 -1)]
           [sc (* sgn c)]
           [key (memo-key dir a v)]
           [m (hashtable-ref (abcd-graph-memo g) key #f)])
      (cond
        ;; The source. `v <= v + c` is decided by the sign of c and nothing
        ;; else, in either direction.
        [(eq? v a) (if (>= sc 0) 'true 'false)]
        ;; Memoisation is monotone in c: a proof of a tighter bound proves
        ;; every looser one, and a failure at a looser bound fails every
        ;; tighter one.
        [(and m (car m) (>= sc (* sgn (car m)))) 'true]
        [(and m (cdr m) (<= sc (* sgn (cdr m)))) 'false]
        [(hashtable-ref active v #f)
         => (lambda (entry)
              (abcd-graph-cycle-hits-set! g (+ 1 (abcd-graph-cycle-hits g)))
              (let ([sc0 (* sgn (car entry))])
                (cond
                  ;; A cycle with no merge point on it is an algebraic identity
                  ;; going round in circles, not a loop. Nothing follows from it.
                  [(= (counter-value phis-seen) (cdr entry)) 'false]
                  ;; The cycle made the constraint strictly harder. That is an
                  ;; amplifying cycle, i.e. an induction variable running away
                  ;; from the bound, and the fact does not hold.
                  [(< sc sc0) 'false]
                  ;; Strictly easier: a reducing cycle, which can only help.
                  [(> sc sc0) 'reduced]
                  ;; Neither: the cycle is neutral in this variable, so the
                  ;; question reduces to the other operands of the meet.
                  [else 'true])))]
        [else
         (let ([es (abcd-edges g dir v)])
           (if (null? es)
               'false
               (let ([before (abcd-graph-cycle-hits g)]
                     [phi? (abcd-phi-vertex? g v)]
                     [seen0 (counter-value phis-seen)])
                 (hashtable-set! active v (cons c seen0))
                 (when phi? (counter-bump! phis-seen 1))
                 (let ([r (fold-left
                             (lambda (acc e)
                               (let ([sub (prove g dir a (car e) (- c (cdr e))
                                                 active phis-seen)])
                                 (if phi? (meet acc sub) (join acc sub))))
                             (if phi? 'true 'false)
                             es)])
                   (when phi? (counter-bump! phis-seen -1))
                   (hashtable-delete! active v)
                   ;; Only an answer that consulted no cycle assumption is an
                   ;; unconditional fact. Anything that leaned on an active
                   ;; vertex is true only relative to the goal being proved,
                   ;; and memoising it would export a hypothesis.
                   (when (= before (abcd-graph-cycle-hits g))
                     (let ([old (hashtable-ref (abcd-graph-memo g) key '(#f . #f))])
                       (case r
                         ;; Keep the TIGHTEST bound proved and the LOOSEST one
                         ;; refuted; those are the two that subsume the most
                         ;; future queries.
                         [(true)
                          (hashtable-set! (abcd-graph-memo g) key
                            (cons (if (and (car old) (<= (* sgn (car old)) sc))
                                      (car old) c)
                                  (cdr old)))]
                         [(false)
                          (hashtable-set! (abcd-graph-memo g) key
                            (cons (car old)
                                  (if (and (cdr old) (>= (* sgn (cdr old)) sc))
                                      (cdr old) c)))]
                         [else (void)])))
                   r))))])))

  ;; --- the question a bounds check asks -------------------------------------
  ;;
  ;; `len` is either an exact integer, when the length is known outright, or a
  ;; vertex name, when it is only known symbolically -- the usual case inside a
  ;; loop guarded by `i < a.length`.
  ;;
  ;; BOTH halves must be proved. Upper alone is the mistake that turns a
  ;; negative index into a wild read.

  (define (abcd-in-bounds? g idx len)
    (and (if (exact-int? len)
             (abcd-prove-upper g abcd-zero idx (- len 1))
             (abcd-prove-upper g len idx -1))
         (abcd-prove-lower g abcd-zero idx 0)))

  ;; --- the free lunch: induction variables from amplifying cycles -----------
  ;;
  ;; A cycle in the up-graph through a meet vertex accumulates the variable's
  ;; per-iteration change: `i <= i_next + 0` (phi), `i_next <= i_g + 1` (the
  ;; step), `i_g <= i + 0` (sigma) sums to +1, and +1 is the step. Zero-weight
  ;; cycles are loop-invariant phis. Several distinct nonzero weights means the
  ;; variable steps by different amounts on different back edges, which is an
  ;; induction variable with no single step, reported as `unknown` rather than
  ;; as one of the two.
  ;;
  ;; This does NOT produce a trip count, so (sonic loops) is still needed. It
  ;; produces the discrimination, which is the part that was going to be
  ;; written twice.

  (define-record-type (abcd-iv make-abcd-iv abcd-iv?)
    (fields name step weights))

  (define (abcd-iv-ref ivs name)
    (let scan ([vs ivs])
      (cond [(null? vs) #f]
            [(eq? (abcd-iv-name (car vs)) name) (car vs)]
            [else (scan (cdr vs))])))

  (define (cycle-weights g v limit)
    (let go ([u v] [w 0] [path (list v)] [acc '()])
      (fold-left
        (lambda (acc e)
          (let ([n (car e)] [k (cdr e)])
            (cond [(eq? n v) (let ([t (+ w k)]) (if (member t acc) acc (cons t acc)))]
                  [(memq n path) acc]
                  [(> (length path) limit) acc]
                  [else (go n (+ w k) (cons n path) acc)])))
        acc
        (abcd-edges g 'up u))))

  (define (abcd-ivs g)
    (let loop ([vs (abcd-vertices g)] [acc '()])
      (cond
        [(null? vs) acc]
        [(not (abcd-phi-vertex? g (car vs))) (loop (cdr vs) acc)]
        [else
         (let* ([ws (cycle-weights g (car vs) 64)]
                [nz (filter (lambda (w) (not (= w 0))) ws)])
           (if (null? ws)
               (loop (cdr vs) acc)
               (loop (cdr vs)
                     (cons (make-abcd-iv
                             (car vs)
                             (cond [(null? nz) 0]
                                   [(null? (cdr nz)) (car nz)]
                                   [else 'unknown])
                             (list-sort < ws))
                           acc))))])))
  )
