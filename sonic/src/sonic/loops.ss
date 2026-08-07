;;; SonicScheme: loop recognition, induction variables and trip counts.
;;;
;;; Stage 07, over Lssa. Answers three questions and refuses to guess at any of
;;; them: which letrec-bound lambdas are loops, which of their phis are
;;; induction variables, and how many times each loop runs.
;;;
;;; WHY THE TRIP COUNT IS THE DELIVERABLE AND NOT A BONUS.
;;;
;;; Larsen's measurements on `applu` are the whole argument: 22.56% of the
;;; kernel is vectorizable at 256 bits and 0.01% at 1024, and the collapse is
;;; what happens when the vectorizer picks an unroll factor from a trip count it
;;; guessed. A wrong trip count is worse than no trip count, because a wrong one
;;; is acted on. So `unknown` is a first-class answer here, it is the DEFAULT,
;;; and every path that cannot prove a count returns it with a reason attached
;;; rather than falling back on a plausible number.
;;;
;;; WHY THIS FILE IS SMALLER THAN ITS POSITION IN THE PIPELINE SUGGESTS.
;;;
;;; Clousot validates 88.9% of array accesses with no loop pass at all. The
;;; interval domain plus e-SSA's sigma already discharges the checks; what a
;;; loop pass buys is HOISTING (prove it once at the header instead of once per
;;; iteration) and stage 10's unroll factor. It does not buy provability. So
;;; there is no strength reduction here, no LICM rewrite, no loop rotation: this
;;; is an ANALYSIS that produces facts, and the clients that consume them are
;;; separate beads.
;;;
;;; WHAT A LOOP IS IN THIS IR.
;;;
;;; essa.ss's header says it: Lanf has no CFG, and a loop is a letrec-bound
;;; lambda that can reach itself. Its PARAMETERS are the phis, named explicitly
;;; by the header phi that essa wraps the body in:
;;;
;;;   (letrec ([loop (lambda (i.2 n.3)
;;;                    (phi ([i.4 i.2] [n.5 n.3])
;;;                      ... (tailcall loop i2.11 n.5))))]) ...)
;;;
;;; So "natural loop detection" is an SCC computation over the call graph of
;;; letrec-bound lambdas, not a dominator computation over basic blocks. This is
;;; not a shortcut: the two agree, because a lambda's body is single-entry by
;;; construction and reducibility is exactly the question of whether the cycle
;;; has one entry. Mutual recursion is the irreducible case, and it is reported
;;; as a multi-member SCC with `irreducible?` set rather than being silently
;;; forced into a header/back-edge shape it does not have.
;;;
;;; THE HEADER PHI IS OPTIONAL ON INPUT. essa only emits it for a recursive
;;; group, and hand-written Lssa fixtures may omit it. Where it is absent the
;;; parameters serve as their own phis, so `loop-phis` is always the list of
;;; names the loop body actually refers to.
;;;
;;; SIGMA IS WHERE THE GUARD COMES FROM. e-SSA already names the branch fact on
;;; each edge, which is the entire reason stage 06 exists, so the trip count
;;; reads (sigma i.7 i.4 fx< n.5 #f ...) directly rather than re-deriving the
;;; fact from the let-bound comparison and the polarity of the `if`. Both are
;;; read, because a fixture may carry one and not the other, and duplicate facts
;;; are normalized and deduplicated rather than counted twice.
;;;
;;; What sigma's fifth field means is NOT decided here. `negated?` says which
;;; edge this is, and (sonic interval)'s iv-edge-cmp says what may be concluded
;;; from it: `>=` for a failed fx<, and NOTHING for a failed fl<, because NaN
;;; makes both spellings false. Re-deriving that rule in this file would put the
;;; NaN case in two places and eventually in disagreement, so the fact is
;;; converted once, on the way in, and this file never sees a primitive name
;;; again.
;;;
;;; ON INPUT VALIDITY. Every table here is keyed by variable name, so SSA's
;;; uniqueness property is a precondition and a repeated binder is an error
;;; rather than a silently wrong answer. Note that essa.ss does not currently
;;; hold up its end: it has no `tailcall` clause, so nanopass's generated one
;;; copies the back edge's operands through unrenamed. Its loop output names
;;; variables that do not exist, and the fixtures for this stage are therefore
;;; written by hand in the shape stage 06 is specified to produce.
;;;
;;; SOUNDNESS DIRECTION. Same as interval.ss and the opposite of alias.ss: every
;;; count returned is an over-approximation of the true count, `unknown` is the
;;; top of the lattice, and a form this file does not understand makes the
;;; answer wider rather than wrong. The arithmetic is interval.ss's, including
;;; the division by the step, so an off-by-one in the ceiling is a bug in one
;;; place instead of four.

(library (sonic loops)
  (export analyze-loops loops-ref loop-iv-ref
          loop? loop-name loop-params loop-phis loop-members loop-irreducible?
          loop-parent loop-depth loop-ivs loop-trip
          loop-back-edges loop-entries
          iv? iv-name iv-kind iv-base iv-coeff iv-offset iv-step iv-init iv-span
          trip? trip-kind trip-count trip-interval trip-why
          trip-exact? trip-bound? trip-unknown?)
  (import (chezscheme) (nanopass) (sonic lang) (sonic interval))

  ;; Guard facts are held in interval.ss's spelling of a comparison, one of
  ;; < <= > >= =, because `iv-edge-cmp` is the one place that knows what an edge
  ;; licenses: it maps (fx< . negated) to >= and (fl< . negated) to NOTHING, and
  ;; that NaN rule must not be re-implemented here. So this file never sees a
  ;; primitive name after the fact is read, and the only comparison algebra it
  ;; needs of its own is the swap.
  (define (cmp-flip c)
    (case c [(<) '>] [(<=) '>=] [(>) '<] [(>=) '<=] [(=) '=] [else #f]))

  ;; --- what the query interface hands back ----------------------------------

  ;; A loop. `members` is its SCC, which is a singleton for every reducible
  ;; loop; `phis` is parallel to `params`; `back-edges` and `entries` are the
  ;; argument lists of the calls that close the cycle and of the calls that
  ;; enter it, each parallel to `params` as well.
  (define-record-type (loop make-loop loop?)
    (fields name params phis members irreducible?
            parent depth ivs trip back-edges entries))

  ;; An induction variable.
  ;;
  ;;   kind    basic or derived
  ;;   base    the basic IV this one is expressed over (itself, when basic)
  ;;   coeff   the multiplier on the base
  ;;   offset  an exact integer, an invariant variable's name, or 'unknown
  ;;   step    the per-iteration increment, or #f when the increment is a
  ;;           loop-invariant whose VALUE we do not know. #f is not zero.
  ;;   init    interval of the value on entry
  ;;   span    interval of every value it takes inside the body
  (define-record-type (iv make-iv iv?)
    (fields name kind base coeff offset step init span))

  ;; A trip count.
  ;;
  ;;   kind   exact | bound | unknown
  ;;   count  the exact iteration count, or #f
  ;;   interval  the possible counts. Top when unknown; a finite upper bound is
  ;;             what stage 10 needs even when the exact count is unavailable.
  ;;   why    the reason for the kind, so a client can report WHY it declined
  ;;          to unroll rather than reporting nothing.
  (define-record-type (trip make-trip trip?)
    (fields kind count interval why))

  (define (trip-exact? t) (eq? (trip-kind t) 'exact))
  (define (trip-bound? t) (eq? (trip-kind t) 'bound))
  (define (trip-unknown? t) (eq? (trip-kind t) 'unknown))

  (define (loops-ref loops name)
    (let scan ([ls loops])
      (cond [(null? ls) #f]
            [(eq? (loop-name (car ls)) name) (car ls)]
            [else (scan (cdr ls))])))

  (define (loop-iv-ref l name)
    (let scan ([vs (loop-ivs l)])
      (cond [(null? vs) #f]
            [(eq? (iv-name (car vs)) name) (car vs)]
            [else (scan (cdr vs))])))

  ;; --- interval arithmetic this domain needs and interval.ss does not have --
  ;; Division by the step, and a max against zero. Both are kept here rather
  ;; than added to interval.ss because both are specific to counting iterations:
  ;; the division is by a known nonzero constant, which is the only case that
  ;; arises, and the general interval quotient has a zero-divisor case that
  ;; would have to be answered and never is.

  (define (b-div x c mode)              ; c > 0, so the map is monotone
    (cond [(eq? x 'neginf) 'neginf]
          [(eq? x 'posinf) 'posinf]
          [(eq? mode 'ceil) (ceiling (/ x c))]
          [else (floor (/ x c))]))

  (define (iv-div a c mode)
    (if (iv-bot? a)
        iv-bot
        (make-interval (b-div (interval-lo a) c mode)
                       (b-div (interval-hi a) c mode))))

  ;; max(0, a), elementwise. NOT (iv-meet a [0,+inf]): a wholly negative
  ;; interval means "the guard was false on entry", which is zero iterations,
  ;; and meeting would call that bottom, i.e. unreachable, which is a different
  ;; and false claim.
  (define (iv-max0 a)
    (define (b0 x) (cond [(eq? x 'neginf) 0] [(eq? x 'posinf) 'posinf] [else (max x 0)]))
    (if (iv-bot? a) (iv-const 0) (make-interval (b0 (interval-lo a)) (b0 (interval-hi a)))))

  (define (b-min x y)
    (cond [(eq? x 'neginf) 'neginf] [(eq? y 'neginf) 'neginf]
          [(eq? x 'posinf) y] [(eq? y 'posinf) x]
          [else (min x y)]))

  ;; Elementwise min of two counts. Two conjunctive guards both bound the
  ;; iteration count from above and the loop stops at whichever comes first.
  (define (iv-min a b)
    (make-interval (b-min (interval-lo a) (interval-lo b))
                   (b-min (interval-hi a) (interval-hi b))))

  (define (iv-point a)
    (let ([lo (interval-lo a)] [hi (interval-hi a)])
      (and (integer? lo) (integer? hi) (= lo hi) lo)))

  (define (iv-finite-hi a)
    (let ([hi (interval-hi a)]) (and (integer? hi) hi)))

  ;; --- the analysis ---------------------------------------------------------

  (define (analyze-loops top)

    ;; x -> how it was defined. One of
    ;;   (const d) (copy y) (prim pr (a ...)) (phi f k) (join) (param f k)
    ;;   (fn f) (opaque)
    (define def (make-eq-hashtable))
    ;; x -> the innermost enclosing lambda's name, or #f for top level
    (define home (make-eq-hashtable))
    (define mutated (make-eq-hashtable))
    (define order '())                  ; every name, definition order reversed

    (define fn-parent (make-eq-hashtable))
    (define fn-params (make-eq-hashtable))
    (define fn-phis (make-eq-hashtable))
    (define fn-known (make-eq-hashtable))   ; the set of lambda-bound names
    (define callees (make-eq-hashtable))    ; f -> names f's body calls
    (define sites (make-eq-hashtable))      ; g -> call sites of g

    ;; Filled in as loops are processed, outermost first.
    (define inv-phi (make-eq-hashtable))    ; phi names that never change
    (define lf (make-eq-hashtable))         ; x -> (base coeff offset)
    (define span-table (make-eq-hashtable)) ; x -> interval over the whole loop

    (define (href h k d) (hashtable-ref h k d))
    (define (hset! h k v) (hashtable-set! h k v))
    (define (hpush! h k v) (hset! h k (cons v (href h k '()))))

    ;; SSA's uniqueness property is a PRECONDITION here, not a nicety: every
    ;; table in this file is keyed by name, so a name defined twice silently
    ;; redirects one definition's uses to the other's linear form and the trip
    ;; count that comes out is confidently wrong. That is the one failure mode
    ;; this stage must not have, so a repeated binder is an error at the point
    ;; it is seen rather than a wrong number three stages later.
    (define (record-def! x d fn)
      (when (hashtable-contains? def x)
        (error 'analyze-loops "input is not in SSA form: ~s is defined twice" x))
      (hset! def x d)
      (hset! home x fn)
      (set! order (cons x order)))

    ;; --- pass 1: one walk, everything structural -----------------------------
    ;;
    ;; guards is the list of facts known to hold at this point, each
    ;;   #(cmp a b fn)
    ;; with fn the function whose body established it, so a guard from outside a
    ;; loop is not mistaken for one the loop re-evaluates. facts maps a
    ;; let-bound boolean to the comparison it computed, exactly as essa.ss does,
    ;; so that an `if` on it can be read as a guard even where sigma is absent.

    (define (var-of e)
      (nanopass-case (Lssa Expr) e [,x x] [else #f]))

    (define (fact-of se)
      (nanopass-case (Lssa SimpleExpr) se
        [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
         (and (iv-comparison? pr) (= (length x*) 2) (list pr (car x*) (cadr x*)))]
        [else #f]))

    ;; A guard in effect at some point: #(cmp a b fn), cmp in interval.ss's
    ;; spelling, fn the function whose body established it.
    (define (edge-guard pr negated? a b fn)
      (let ([c (iv-edge-cmp pr negated?)])
        (and c (vector c a b fn))))

    (define (enter-fn! f p* body outer)
      (hset! fn-known f #t)
      (hset! fn-parent f outer)
      (hset! fn-params f p*)
      (let loop ([ps p*] [k 0])
        (unless (null? ps)
          (record-def! (car ps) (list 'param f k) f)
          (loop (cdr ps) (+ k 1))))
      ;; A header phi is a phi whose operands are exactly this lambda's
      ;; parameters, in order. Anything else is a diamond's join.
      (let ([hdr (nanopass-case (Lssa Expr) body
                   ;; phi now carries per-predecessor operands: each binding is
                   ;; (x (pred val) ...). A HEADER phi is one whose sole `entry`
                   ;; operand is this lambda's corresponding parameter.
                   [(phi ([,x* (,lbl** ,e**) ...] ...) ,body2)
                    (and (= (length x*) (length p*))
                         (let same ([ess e**] [ps p*])
                           (cond [(null? ess) #t]
                                 [(and (pair? (car ess))
                                       (eq? (var-of (caar ess)) (car ps)))
                                  (same (cdr ess) (cdr ps))]
                                 [else #f]))
                         (list x* body2))]
                   [else #f])])
        (cond
          [hdr
           (hset! fn-phis f (car hdr))
           (let loop ([hs (car hdr)] [k 0])
             (unless (null? hs)
               (record-def! (car hs) (list 'phi f k) f)
               (loop (cdr hs) (+ k 1))))
           (walk (cadr hdr) f '() '())]
          [else
           (hset! fn-phis f p*)
           (walk body f '() '())])))

    (define (site! callee args fn guards tail?)
      (hpush! sites callee (vector callee args fn guards tail?))
      (hpush! callees fn callee))

    (define (walk-se se x fn guards facts)
      (nanopass-case (Lssa SimpleExpr) se
        [,x1 (record-def! x (list 'copy x1) fn)]
        [(quote ,d) (record-def! x (list 'const d) fn)]
        [(lambda (,x* ...) ,body)
         (record-def! x (list 'fn x) fn)
         (enter-fn! x x* body fn)]
        [(call ,x1 ,x* ...)
         (record-def! x '(opaque) fn)
         (site! x1 x* fn guards #f)]
        [(primcall ,pr ([,pn* ,c*] ...) ,x* ...)
         (record-def! x (list 'prim pr x*) fn)]
        [else (record-def! x '(opaque) fn)]))

    (define (walk e fn guards facts)
      (nanopass-case (Lssa Expr) e
        [,x (void)]
        [(quote ,d) (void)]

        [(let ([,x ,se]) ,body)
         (walk-se se x fn guards facts)
         (let* ([f (fact-of se)]
                [facts1 (if f (cons (cons x f) facts) facts)])
           (walk body fn guards facts1))]

        ;; The guard, when the comparison was let-bound and tested here. The
        ;; false edge of a comparison whose negation licenses nothing (fx=,
        ;; every flonum test) contributes no guard, which is correct and is why
        ;; the trip count of such a loop comes back unknown rather than wrong.
        [(if ,x ,e0 ,e1)
         (let* ([p (assq x facts)]
                [f (and p (cdr p))]
                [gt (and f (edge-guard (car f) #f (cadr f) (caddr f) fn))]
                [gf (and f (edge-guard (car f) #t (cadr f) (caddr f) fn))])
           (walk e0 fn (if gt (cons gt guards) guards) facts)
           (walk e1 fn (if gf (cons gf guards) guards) facts))]

        ;; e-SSA's whole point: the fact is already named on this edge, with the
        ;; polarity that names which edge it is.
        [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body)
         (record-def! x0 (list 'copy x1) fn)
         (let ([g (edge-guard pr b x0 x2 fn)])
           (walk body fn (if g (cons g guards) guards) facts))]

        ;; phi bindings are now (x (pred val) ...), so the operand lists are
        ;; nested one level deeper than before.
        [(phi ([,x* (,lbl** ,e**) ...] ...) ,body)
         (for-each (lambda (x) (record-def! x '(join) fn)) x*)
         (for-each (lambda (es) (for-each (lambda (e) (walk e fn guards facts)) es)) e**)
         (walk body fn guards facts)]

        [(tailcall ,x ,x* ...) (site! x x* fn guards #t)]

        [(letrec ([,x* ,e*] ...) ,body)
         (for-each
           (lambda (nm rhs)
             (record-def! nm (list 'fn nm) fn)
             (nanopass-case (Lssa Expr) rhs
               [(lambda (,x1* ...) ,body1) (enter-fn! nm x1* body1 fn)]
               [else (walk rhs fn guards facts)]))
           x* e*)
         (walk body fn guards facts)]

        ;; A lambda with no name to key call sites on. Walked so that loops
        ;; nested inside it are still found; it can never be a loop itself,
        ;; because nothing can name it in order to call it.
        [(lambda (,x* ...) ,body)
         (let ([anon (gensym "anon")]) (enter-fn! anon x* body fn))]

        [(seq ,e0 ,e1) (walk e0 fn guards facts) (walk e1 fn guards facts)]
        [(policy ([,pn* ,b*] ...) ,body) (walk body fn guards facts)]
        [(declare ([,x* ,pn*] ...) ,body) (walk body fn guards facts)]
        [(declare-distinct (,x* ...) ,body) (walk body fn guards facts)]
        ;; Lssa should be free of set! by assignment conversion, but if one
        ;; survives the assigned name is not single-valued and must never be
        ;; taken for an invariant.
        [(set! ,x ,e) (hset! mutated x #t) (walk e fn guards facts)]
        [else (void)]))

    ;; --- name resolution -----------------------------------------------------

    (define (root x)
      (let go ([x x] [fuel 200])
        (let ([d (href def x #f)])
          (if (and (pair? d) (eq? (car d) 'copy) (> fuel 0))
              (go (cadr d) (- fuel 1))
              x))))

    (define (const-of x)
      (let ([d (href def (root x) #f)])
        (and (pair? d) (eq? (car d) 'const)
             (let ([v (cadr d)]) (and (integer? v) (exact? v) v)))))

    (define (fn-inside? f l)
      (let go ([f f]) (cond [(not f) #f] [(eq? f l) #t] [else (go (href fn-parent f #f))])))

    (define (defined-inside? x l) (fn-inside? (href home (root x) #f) l))

    ;; Primitives whose result depends only on their operands. Deliberately
    ;; excludes every memory read: flvector-ref is not invariant merely because
    ;; its operands are, since the body may store through the same vector, and
    ;; deciding otherwise is alias.ss's job and not this file's. `cons` and the
    ;; makers are excluded for the other reason: they return a FRESH object each
    ;; iteration, so the operands being invariant says nothing about the result.
    (define pure-prims
      '(fx+ fx- fx* fxneg fxquotient fxremainder fxmodulo
        fx< fx<= fx= fx>= fx>
        fl+ fl- fl* fl/ flneg flabs flsqrt fl< fl<= fl= fl>= fl>
        fl->fx fx->fl eq?
        flvector-length vector-length
        null? pair? fixnum? flonum? vector? flvector?))

    ;; Loop invariance, in the sense LICM means it: a value computed INSIDE the
    ;; body is still invariant when everything it is computed from is. Without
    ;; the recursive case, nbody's `off = i*7` would be classified as varying
    ;; with the inner loop merely because it is written inside it, and the inner
    ;; loop's index expression would lose its base.
    (define (invariant? x l) (invariant-rec? x l 100))

    (define (invariant-rec? x l fuel)
      (let ([r (root x)])
        (cond
          [(href mutated r #f) #f]
          [(not (defined-inside? r l)) #t]
          [(<= fuel 0) #f]
          [else
           (let ([d (href def r #f)])
             (cond
               [(not (pair? d)) #f]
               [(eq? (car d) 'const) #t]
               [(eq? (car d) 'phi) (and (eq? (cadr d) l) (href inv-phi r #f) #t)]
               [(eq? (car d) 'prim)
                (and (memq (cadr d) pure-prims)
                     (for-all (lambda (a) (invariant-rec? a l (- fuel 1))) (caddr d)))]
               [else #f]))])))

    ;; --- abstract value of a name, in intervals ------------------------------
    ;; Constants, induction variables of an already-processed enclosing loop,
    ;; and affine functions of one. Everything else is top.

    (define (base-span b) (or (href span-table b #f) iv-top))

    (define (offset-interval o)
      (cond [(eq? o 'unknown) iv-top]
            [(integer? o) (iv-const o)]
            [(symbol? o) (value-interval o)]
            [else iv-top]))

    (define (value-interval x)
      (let* ([r (root x)] [c (const-of r)])
        (cond [c (iv-const c)]
              [(href span-table r #f)]
              [(href lf r #f)
               => (lambda (f)
                    (iv-add (iv-mul (iv-const (cadr f)) (base-span (car f)))
                            (offset-interval (caddr f))))]
              [else iv-top])))

    ;; --- the call graph, and which lambdas are loops --------------------------

    (define (fn-list)
      (vector->list (hashtable-keys fn-known)))

    (define (reaches? from to)
      (let go ([work (href callees from '())] [seen '()])
        (cond [(null? work) #f]
              [(eq? (car work) to) #t]
              [(memq (car work) seen) (go (cdr work) seen)]
              [else (go (append (href callees (car work) '()) (cdr work))
                        (cons (car work) seen))])))

    (define (scc-of f others)
      (cons f (filter (lambda (g) (and (not (eq? g f)) (reaches? f g) (reaches? g f)))
                      others)))

    ;; --- per-loop analysis ----------------------------------------------------

    (define (loop-depth-of f)
      (let go ([p (href fn-parent f #f)] [n 0] [acc #f])
        (cond [(not p) (values (or acc #f) n)]
              [(href fn-known p #f)
               (if (loop-header? p)
                   (go (href fn-parent p #f) (+ n 1) (or acc p))
                   (go (href fn-parent p #f) n acc))]
              [else (go (href fn-parent p #f) n acc)])))

    (define (loop-header? f) (and (href fn-known f #f) (reaches? f f)))

    ;; Basic IV classification for one parameter position.
    ;;   0          the argument is the phi itself
    ;;   an integer the step
    ;;   'unknown   a step that is loop invariant but whose value is not known
    ;;   #f         not an induction variable
    (define (step-of arg h l)
      (let* ([r (root arg)] [d (href def r #f)])
        (cond
          [(eq? r h) 0]
          [(and (pair? d) (eq? (car d) 'prim) (= (length (caddr d)) 2))
           (let* ([pr (cadr d)] [a (car (caddr d))] [b (cadr (caddr d))])
             (cond
               [(and (eq? pr 'fx+) (eq? (root a) h) (invariant? b l)) (or (const-of b) 'unknown)]
               [(and (eq? pr 'fx+) (eq? (root b) h) (invariant? a l)) (or (const-of a) 'unknown)]
               [(and (eq? pr 'fx-) (eq? (root a) h) (invariant? b l))
                (let ([c (const-of b)]) (if c (- c) 'unknown))]
               [else #f]))]
          [else #f])))

    ;; Linear forms, for derived induction variables. Offsets are an exact
    ;; integer, an invariant variable's NAME, or 'unknown: a sum of both is
    ;; where this stops, because carrying general symbolic sums is a symbolic
    ;; arithmetic package and nothing downstream has asked for one.
    (define (off+ o p)
      (cond [(or (eq? o 'unknown) (eq? p 'unknown)) 'unknown]
            [(and (integer? o) (integer? p)) (+ o p)]
            [(and (eqv? o 0) (symbol? p)) p]
            [(and (symbol? o) (eqv? p 0)) o]
            [else 'unknown]))

    (define (off* o c)
      (cond [(eq? o 'unknown) 'unknown]
            [(integer? o) (* o c)]
            [(= c 1) o]
            [else 'unknown]))

    (define (off-neg o)
      (cond [(integer? o) (- o)] [else 'unknown]))

    (define (invariant-term x l)
      ;; The operand of an affine step: an exact constant, or an invariant name.
      (cond [(const-of x) => values]
            [(invariant? x l) (root x)]
            [else #f]))

    (define (build-linear-forms! l basic-names)
      (for-each (lambda (h) (hset! lf h (list h 1 0))) basic-names)
      (for-each
        (lambda (x)
          (let ([d (href def x #f)])
            (when (and (pair? d) (eq? (car d) 'prim) (= (length (caddr d)) 2)
                       (defined-inside? x l)
                       (not (href lf x #f)))
              (let* ([pr (cadr d)]
                     [a (car (caddr d))] [b (cadr (caddr d))]
                     [fa (href lf (root a) #f)] [fb (href lf (root b) #f)]
                     [ta (invariant-term a l)] [tb (invariant-term b l)]
                     [form
                      (cond
                        [(and (eq? pr 'fx*) fa (integer? tb))
                         (list (car fa) (* (cadr fa) tb) (off* (caddr fa) tb))]
                        [(and (eq? pr 'fx*) fb (integer? ta))
                         (list (car fb) (* (cadr fb) ta) (off* (caddr fb) ta))]
                        [(and (eq? pr 'fx+) fa tb)
                         (list (car fa) (cadr fa) (off+ (caddr fa) tb))]
                        [(and (eq? pr 'fx+) fb ta)
                         (list (car fb) (cadr fb) (off+ (caddr fb) ta))]
                        [(and (eq? pr 'fx-) fa tb)
                         (list (car fa) (cadr fa) (off+ (caddr fa) (off-neg tb)))]
                        [(and (eq? pr 'fx-) fb ta)
                         (list (car fb) (- (cadr fb)) (off+ ta (off-neg (caddr fb))))]
                        [else #f])])
                (when (and form (not (eq? (cadr form) 0)))
                  (hset! lf x form))))))
        (reverse order)))

    ;; The guard facts in effect at a back edge, normalized so the induction
    ;; variable is the FIRST operand, deduplicated, and split into those that
    ;; constrain an IV and those that do not. essa emits both spellings of a
    ;; comparison (one sigma per operand) and the let/if reading produces a
    ;; third copy of the same fact; all three normalize to one entry, which
    ;; matters because the count of DISTINCT facts is what decides whether the
    ;; answer may be called exact.
    (define (guard-facts site l basic)
      (let go ([gs (vector-ref site 3)] [ivf '()] [oth '()])
        (if (null? gs)
            (values (reverse ivf) (reverse oth))
            (let* ([g (car gs)]
                   [cmp (vector-ref g 0)]
                   [a (root (vector-ref g 1))]
                   [b (root (vector-ref g 2))]
                   [in? (fn-inside? (vector-ref g 3) l)])
              (cond
                [(not in?) (go (cdr gs) ivf oth)]
                [(memq a basic)
                 (let ([f (list cmp a b)])
                   (go (cdr gs) (if (member f ivf) ivf (cons f ivf)) oth))]
                [(memq b basic)
                 (let ([f (list (cmp-flip cmp) b a)])
                   (go (cdr gs) (if (member f ivf) ivf (cons f ivf)) oth))]
                [else
                 (let ([f (list cmp a b)])
                   (go (cdr gs) ivf (if (member f oth) oth (cons f oth))))])))))

    ;; Iterations of `(loop i)` guarded by (cmp i bound), stepping by step.
    ;; Returns an interval, or #f when the shape is one this does not count.
    (define (count-of cmp init bound step)
      (cond
        [(and (memq cmp '(< <=)) (> step 0))
         (let ([d (iv-sub bound init)])
           (iv-max0 (if (eq? cmp '<)
                        (iv-div d step 'ceil)
                        (iv-add (iv-div d step 'floor) (iv-const 1)))))]
        [(and (memq cmp '(> >=)) (< step 0))
         (let ([d (iv-sub init bound)] [s (- step)])
           (iv-max0 (if (eq? cmp '>)
                        (iv-div d s 'ceil)
                        (iv-add (iv-div d s 'floor) (iv-const 1)))))]
        [else #f]))

    ;; The trip count itself. Returns the trip record and the induction-variable
    ;; guard facts it used, which the span computation then re-reads.
    ;;
    ;; EXACT is only claimed when there is one back edge, one distinct fact
    ;; constraining an induction variable, no other condition standing between
    ;; the header and that back edge, and constants for the initial value, the
    ;; step and the bound. Anything else is at best an upper BOUND, because an
    ;; extra condition can only cut the loop short. This is the Larsen rule
    ;; written out: an upper bound is usable and a guess is not.
    (define (trip-of l phis steps inits basic irreducible? back)
      (cond
        [irreducible? (values (make-trip 'unknown #f iv-top 'irreducible) '())]
        [(null? back) (values (make-trip 'unknown #f iv-top 'no-back-edge) '())]
        [(not (null? (cdr back)))
         (values (make-trip 'unknown #f iv-top 'multiple-back-edges) '())]
        [(null? basic) (values (make-trip 'unknown #f iv-top 'no-induction-variable) '())]
        [else
         (let-values ([(ivf oth) (guard-facts (car back) l basic)])
           (if (null? ivf)
               (values (make-trip 'unknown #f iv-top 'no-guard-on-induction-variable) ivf)
               (let per ([fs ivf] [count #f] [why 'counted] [failed #f])
                 (if (null? fs)
                     (values
                       (cond
                         [(not count) (make-trip 'unknown #f iv-top why)]
                         [(and (not failed) (null? oth) (iv-point count))
                          (make-trip 'exact (iv-point count) count 'counted)]
                         ;; A condition this could not read, or one that does not
                         ;; mention an induction variable, can be false on the
                         ;; FIRST iteration, so the loop may run zero times and
                         ;; the lower bound goes with it. Only the upper bound
                         ;; survives, which is the half stage 10 needs. Where
                         ;; every condition was read, the computed lower bound
                         ;; is sound and is kept.
                         [(iv-finite-hi count)
                          => (lambda (hi)
                               (let ([cut (or failed (not (null? oth)))])
                                 (make-trip 'bound #f
                                            (if cut (make-interval 0 hi) count)
                                            (cond [failed why]
                                                  [(not (null? oth)) 'extra-exit-guards]
                                                  [else 'inexact-operands]))))]
                         [else (make-trip 'unknown #f iv-top (if failed why 'unbounded))])
                       ivf)
                     (let* ([f (car fs)]
                            [cmp (car f)] [h (cadr f)] [bnd (caddr f)]
                            [k (let scan ([hs phis] [ss steps])
                                 (cond [(null? hs) #f]
                                       [(eq? (car hs) h) (car ss)]
                                       [else (scan (cdr hs) (cdr ss))]))]
                            [i0 (let scan ([hs phis] [is inits])
                                  (cond [(null? hs) iv-top]
                                        [(eq? (car hs) h) (car is)]
                                        [else (scan (cdr hs) (cdr is))]))]
                            [c (and (not (eq? k 'unknown)) k)])
                       (cond
                         [(not c) (per (cdr fs) count 'unknown-step #t)]
                         [(not (invariant? bnd l)) (per (cdr fs) count 'non-invariant-bound #t)]
                         [else
                          (let ([n (count-of cmp i0 (value-interval bnd) c)])
                            (if n
                                (per (cdr fs) (if count (iv-min count n) n) why failed)
                                (per (cdr fs) count 'unhandled-guard #t)))]))))))]))

    ;; The values an induction variable takes inside the body. Two sound
    ;; over-approximations, met: what the trip count implies, and what the guard
    ;; implies on its own. The second is what a hoisting client wants when the
    ;; count is unknown but the bound is not, which is the common case and the
    ;; one Clousot's 88.9% lives in.
    (define (span-of h step init tc ivfacts)
      (let* ([from-trip
              (let ([hi (iv-finite-hi (trip-interval tc))])
                (and hi (integer? step)
                     (iv-add init (iv-mul (iv-const step)
                                          (make-interval 0 (max 0 (- hi 1)))))))]
             [from-guard
              (let scan ([fs ivfacts])
                (cond
                  [(null? fs) #f]
                  [(and (eq? (cadr (car fs)) h) (integer? step))
                   (let* ([f (car fs)] [cmp (car f)] [b (value-interval (caddr f))])
                     (cond
                       [(and (> step 0) (memq cmp '(< <=)))
                        (make-interval (interval-lo init)
                                       (let ([hi (interval-hi b)])
                                         (if (integer? hi)
                                             (if (eq? cmp '<) (- hi 1) hi)
                                             hi)))]
                       [(and (< step 0) (memq cmp '(> >=)))
                        (make-interval (let ([lo (interval-lo b)])
                                         (if (integer? lo)
                                             (if (eq? cmp '>) (+ lo 1) lo)
                                             lo))
                                       (interval-hi init))]
                       [else #f]))]
                  [else (scan (cdr fs))]))])
        (cond [(and from-trip from-guard) (iv-meet from-trip from-guard)]
              [from-trip]
              [from-guard]
              [else iv-top])))

    ;; Derived induction variables: every name inside the loop whose linear form
    ;; is over one of the basic ones. nbody's `off = i*7` and `idx = off + k`
    ;; are exactly this, and `idx` is the name the bounds check is about.
    (define (derived-of l basic basic-ivs)
      (let per ([xs (reverse order)] [acc '()])
        (cond
          [(null? xs) (reverse acc)]
          [else
           (let ([f (href lf (car xs) #f)])
             (if (and f (not (eq? (car xs) (car f)))
                      (defined-inside? (car xs) l)
                      (memq (car f) basic))
                 (let* ([bs (let scan ([vs basic-ivs])
                              (cond [(null? vs) #f]
                                    [(eq? (iv-name (car vs)) (car f)) (car vs)]
                                    [else (scan (cdr vs))]))]
                        [step (and bs (iv-step bs) (* (iv-step bs) (cadr f)))]
                        [sp (iv-add (iv-mul (iv-const (cadr f))
                                            (if bs (iv-span bs) iv-top))
                                    (offset-interval (caddr f)))])
                   (hset! span-table (car xs) sp)
                   (per (cdr xs)
                        (cons (make-iv (car xs) 'derived (car f) (cadr f) (caddr f) step
                                       (iv-add (iv-mul (iv-const (cadr f))
                                                       (if bs (iv-init bs) iv-top))
                                               (offset-interval (caddr f)))
                                       sp)
                              acc)))
                 (per (cdr xs) acc)))])))

    ;; --- driver ---------------------------------------------------------------

    (walk top #f '() '())

    (let* ([all (fn-list)]
           [headers (filter loop-header? all)]
           [ranked (sort (lambda (a b)
                           (let-values ([(pa da) (loop-depth-of a)]
                                        [(pb db) (loop-depth-of b)])
                             (< da db)))
                         headers)])
      (let build ([hs ranked] [acc '()])
        (if (null? hs)
            (reverse acc)
            (let* ([l (car hs)]
                   [params (href fn-params l '())]
                   [phis (href fn-phis l '())]
                   [members (scc-of l headers)]
                   [irreducible? (> (length members) 1)]
                   [all-sites (href sites l '())]
                   [back (filter (lambda (s) (fn-inside? (vector-ref s 2) l)) all-sites)]
                   [entries (filter (lambda (s) (not (fn-inside? (vector-ref s 2) l))) all-sites)]
                   [arity (length params)]
                   [ok-sites (lambda (ss) (filter (lambda (s) (= (length (vector-ref s 1)) arity)) ss))]
                   [back (ok-sites back)]
                   [entries (ok-sites entries)])
              (let*-values
                ([(parent depth) (loop-depth-of l)]
                 ;; Step classification, per parameter position.
                 [(steps)
                  (if (or irreducible? (null? back))
                      (map (lambda (h) #f) phis)
                      (let per ([hs phis] [k 0] [acc '()])
                        (if (null? hs)
                            (reverse acc)
                            (let ([ss (map (lambda (s)
                                             (step-of (list-ref (vector-ref s 1) k) (car hs) l))
                                           back)])
                              (per (cdr hs) (+ k 1)
                                   (cons (cond
                                           [(memq #f ss) #f]
                                           [(null? (cdr ss)) (car ss)]
                                           [(for-all (lambda (v) (equal? v (car ss))) (cdr ss))
                                            (car ss)]
                                           [else #f])
                                         acc))))))]
                 ;; An invariant phi is one literally passed through on every
                 ;; back edge. Nothing weaker: two phis that SWAP values each
                 ;; satisfy "my new value is another invariant phi", and
                 ;; neither of them is invariant.
                 [(_1) (for-each (lambda (h s) (when (eqv? s 0) (hset! inv-phi h #t))) phis steps)]
                 ;; Entry values, joined over every entry edge.
                 [(inits)
                  (let per ([hs phis] [k 0] [acc '()])
                    (if (null? hs)
                        (reverse acc)
                        (per (cdr hs) (+ k 1)
                             (cons (if (null? entries)
                                       iv-top
                                       (fold-left (lambda (a s)
                                                    (iv-join a (value-interval
                                                                 (list-ref (vector-ref s 1) k))))
                                                  iv-bot entries))
                                   acc))))]
                 [(_2) (for-each (lambda (h s i) (when (eqv? s 0) (hset! span-table h i)))
                                 phis steps inits)]
                 [(basic)
                  (let per ([hs phis] [ss steps] [acc '()])
                    (cond [(null? hs) (reverse acc)]
                          [(and (car ss) (not (eqv? (car ss) 0)))
                           (per (cdr hs) (cdr ss) (cons (car hs) acc))]
                          [else (per (cdr hs) (cdr ss) acc)]))]
                 [(_3) (build-linear-forms! l basic)]
                 [(tc ivfacts) (trip-of l phis steps inits basic irreducible? back)]
                 [(basic-ivs)
                  (let per ([hs phis] [ss steps] [is inits] [acc '()])
                    (cond
                      [(null? hs) (reverse acc)]
                      [(and (car ss) (not (eqv? (car ss) 0)))
                       (let* ([step (if (eq? (car ss) 'unknown) #f (car ss))]
                              [sp (span-of (car hs) step (car is) tc ivfacts)])
                         (hset! span-table (car hs) sp)
                         (per (cdr hs) (cdr ss) (cdr is)
                              (cons (make-iv (car hs) 'basic (car hs) 1 0 step (car is) sp) acc)))]
                      [else (per (cdr hs) (cdr ss) (cdr is) acc)]))]
                 [(derived-ivs) (derived-of l basic basic-ivs)])
                (build (cdr hs)
                       (cons (make-loop l params phis members irreducible?
                                        parent depth (append basic-ivs derived-ivs) tc
                                        (map (lambda (s) (vector-ref s 1)) back)
                                        (map (lambda (s) (vector-ref s 1)) entries))
                             acc))))))))
  )
