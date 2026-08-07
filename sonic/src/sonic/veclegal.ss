;;; SonicScheme: vectorization legality.
;;;
;;; Stage 10, over Lssa. Answers one question per loop: may this loop be
;;; vectorized, and at what width? It emits nothing. The verdict is the
;;; deliverable, and (sonic veclegal) is deliberately separate from the two
;;; emitters so that "is it legal" and "what does AVX-512 spell it as" cannot
;;; drift apart.
;;;
;;; IT INVENTS NO FACTS. Every input already exists.
;;;
;;;   trip count            (sonic loops)     how many iterations, or unknown
;;;   distinctness          (sonic alias)     may these two arrays be the same
;;;   storage class         (sonic repr)      is the element unboxed
;;;   checks discharged     (sonic elide)     did a branch survive in the body
;;;
;;; That is the whole of it. If this file starts deriving a bound of its own,
;;; the fact belongs in the pass that owns it, because a second opinion about an
;;; index is a second thing to keep sound.
;;;
;;; WHY A GUESSED TRIP COUNT IS THE WORST AVAILABLE ANSWER.
;;;
;;; Larsen's measurements on `applu`: 22.56% of the kernel is vectorizable at
;;; 256 bits and 0.01% at 1024. The collapse is not a property of the kernel, it
;;; is what happens when the vector is wider than the loop is long. A vectorizer
;;; that guesses a count picks lanes that never execute; a vectorizer told
;;; `unknown` declines and loses nothing but an opportunity.
;;;
;;; So `unknown` propagates. (sonic loops) makes it the default and attaches a
;;; reason, and this file refuses on it rather than substituting a plausible
;;; number. It is also why the answer is a LIST of widths and not a single
;;; blessing: a loop of 7 iterations is legal at 128 and 256 bits and pointless
;;; at 512, and saying so is the difference between a result and a slogan.
;;;
;;; D24 FORBIDS REASSOCIATION, SO A REDUCTION IS NOT VECTORIZABLE. FULL STOP.
;;;
;;; Vectorizing `s = s + a[i]` means computing four partial sums and adding them
;;; up at the end, which is a different association of the same operands. For
;;; flonums that changes the result bits, and the project's strongest
;;; correctness evidence is oracle check 2, the eleven-way bit-exact
;;; cross-agreement. A tolerance-based oracle is exactly where an unsound
;;; abstract domain would hide, since a wrong interval deletes a needed check and
;;; the symptom is a value that is only slightly wrong.
;;;
;;; The fixnum case is refused for a different reason and not by generalisation.
;;; Integer addition is associative in Z, but `fx+` carries an overflow check,
;;; and reassociating changes WHICH addition overflows. A program that traps
;;; under one association and not under another is not the same program.
;;;
;;; Element-wise loops are legal, reductions are not, and that distinction is
;;; the whole content of this pass. It is a REFUSAL rather than a limitation to
;;; be lifted later: D24 would have to be reversed first, and the ledger records
;;; that it was already reversed once and reverted within four tests.
;;;
;;; WHAT COUNTS AS A CHECK, AND WHAT DOES NOT.
;;;
;;; A surviving bounds check is a conditional branch out of the loop body, and a
;;; branch in the body makes the body non-uniform: lane 3 may take it while
;;; lanes 0 to 2 do not. So `checked` on any of the four real checks refuses.
;;;
;;; `fp-contract` is NOT one of them. lang.ss puts it in the same vocabulary
;;; because D24 makes it the same KIND of thing, a named lexically scoped
;;; permission, but it is a rewrite being permitted rather than a check being
;;; emitted, and it compiles to no branch at all. Treating it as one would
;;; refuse every flonum kernel in the benchmark set for a branch that does not
;;; exist.
;;;
;;; `unchecked` is accepted and REPORTED SEPARATELY. It emits no branch, so the
;;; body is uniform and the transform is legal, but it got that way by
;;; permission and not by proof. elide.ss refuses to launder the one into the
;;; other and neither does this file.
;;;
;;; ONE EXCEPTION, AND IT IS STRUCTURAL. The overflow check on the loop's own
;;; induction update is loop CONTROL, not body. Stage 10 replaces `i = i + 1`
;;; with a strided update, so the scalar increment and its check do not survive
;;; the transform to be branched on. The exception is confined to fixnum
;;; arithmetic bound to a name the BACK EDGE carries, which is precisely the
;;; loop-control update and nothing else. `off` and `idx` in nbody are neither,
;;; so their checks are body checks and they refuse.
;;;
;;; ALIASING, AND THE ONE PLACE THE SEAM SHOWS.
;;;
;;; alias.ss runs over Lanf and this pass reads Lssa, so the table is a
;;; PARAMETER rather than something computed here. That works because binder
;;; uniqueness survives the ANF-to-SSA boundary for the array names: a sigma
;;; renames the guarded index, not the array. The premise the table carries is
;;; recorded per program rather than per program point, which alias.ss's header
;;; argues is sound for the same reason, so a table built once is the table this
;;; stage needs.
;;;
;;; With NO table, every pair may alias. That is the safe direction: saying
;;; `must-not` when two arrays might be the same one is a miscompile with no
;;; runtime check anywhere downstream to catch it.
;;;
;;; Two accesses to the SAME name are not covered by that question at all, and
;;; the answer is not `must-not` either, since alias.ss correctly reports that a
;;; name may-aliases itself. So this file asks the narrower question a
;;; dependence test would ask: same array, same index variable, is element-wise
;;; and legal; same array, different index, is a loop-carried memory dependence
;;; and refuses. `a[i] = a[i] + s * b[i]` is the first shape and it is exactly
;;; what alias.ss's header names as the motivating case.

(library (sonic veclegal)
  (export vectorize-legal vectorize-legal-loop
          vl? vl-loop vl-legal? vl-trip vl-elt-class
          vl-widths vl-lanes vl-reasons vl-cites vl-notes vl-accesses
          vl-refused-for? vl-report
          vl-candidate-widths vl-element-bits)
  (import (chezscheme) (nanopass)
          (sonic lang) (sonic loops) (sonic alias) (sonic repr) (sonic interval))

  ;; --- what a verdict looks like from outside -------------------------------
  ;;
  ;; `reasons` is a LIST, not a first cause. A loop can be illegal several ways
  ;; at once and reporting only the first turns fixing one into discovering the
  ;; next, which is how a vectorizer report becomes a game of whack-a-mole.
  ;; `cites` carries the operands, so the report can name the pair of arrays or
  ;; the surviving check rather than only its kind.
  (define-record-type (vl make-vl vl?)
    (fields loop trip elt-class widths lanes reasons cites notes accesses))

  (define (vl-legal? v) (null? (vl-reasons v)))
  (define (vl-refused-for? v r) (and (memq r (vl-reasons v)) #t))

  ;; --- widths ---------------------------------------------------------------
  ;;
  ;; The register widths the two back ends can name. RVV is length agnostic and
  ;; would rather be told a lane count than a width, but the legality question is
  ;; the same one either way: how many iterations must exist for one vector
  ;; operation to be worth issuing.
  (define vl-candidate-widths '(128 256 512 1024))

  ;; Both non-tagged classes are 64 bits wide here: raw-f64 is an IEEE double
  ;; and raw-word is a machine word on both targets. Deriving the lane count
  ;; from the class rather than assuming 8 bytes keeps the arithmetic honest if
  ;; a narrower class is ever added.
  (define (vl-element-bits class)
    (case class
      [(raw-f64 raw-word) 64]
      [else #f]))

  ;; The element type of an access, taken from repr.ss rather than restated. The
  ;; setters have no useful result and are classified raw-word there, so the
  ;; element's class is read off the corresponding getter, which is the
  ;; primitive whose RESULT is the element.
  (define (element-class pr)
    (case pr
      [(flvector-ref flvector-set!) (prim-result-class 'flvector-ref)]
      [(vector-ref vector-set!) (prim-result-class 'vector-ref)]
      [else #f]))

  ;; --- what the scan collects ------------------------------------------------

  ;; An access: (kind array index prim), kind being read or write.
  (define (access-of pr args)
    (and (>= (length args) 2)
         (case pr
           [(flvector-ref vector-ref) (list 'read (car args) (cadr args) pr)]
           [(flvector-set! vector-set!) (list 'write (car args) (cadr args) pr)]
           [else #f])))

  (define (acc-kind a) (car a))
  (define (acc-array a) (cadr a))
  (define (acc-index a) (caddr a))
  (define (acc-prim a) (cadddr a))

  ;; The checks that compile to a branch. Derived by removing the one entry that
  ;; is a permission rather than a check, so a check name added to lang.ss is
  ;; treated as a branch by default, which is the safe direction.
  (define branch-checks
    (filter (lambda (n) (not (eq? n 'fp-contract))) (all-check-names)))

  (define (branch-check? n) (and (memq n branch-checks) #t))

  ;; The shape of an induction update. Nothing else gets the loop-control
  ;; exception, however it is bound.
  (define (loop-control-prim? pr) (and (memq pr '(fx+ fx- fx*)) #t))

  ;; Accumulating arithmetic. `-` and `/` are here with `+` and `*` because a
  ;; running difference or quotient is the same hazard: splitting it across
  ;; lanes and combining at the end is a reassociation of the same operands.
  (define (accumulating-prim? pr)
    (and (memq pr '(fl+ fl- fl* fl/ fx+ fx- fx* fxquotient)) #t))

  ;; --- generic traversal -----------------------------------------------------
  ;; Used only for the two whole-tree questions: where is this loop's lambda,
  ;; and does this subtree reach the back edge.

  (define (each-expr e proc)
    (proc e)
    (nanopass-case (Lssa Expr) e
      [(let ([,x ,se]) ,body) (each-simple se proc) (each-expr body proc)]
      [(seq ,e0 ,e1) (each-expr e0 proc) (each-expr e1 proc)]
      [(if ,x ,e0 ,e1) (each-expr e0 proc) (each-expr e1 proc)]
      [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body) (each-expr body proc)]
      [(phi ([,x* (,lbl** ,e**) ...] ...) ,body)
       (for-each (lambda (es) (for-each (lambda (o) (each-expr o proc)) es)) e**)
       (each-expr body proc)]
      [(letrec ([,x* ,e*] ...) ,body)
       (for-each (lambda (r) (each-expr r proc)) e*)
       (each-expr body proc)]
      [(lambda (,x* ...) ,body) (each-expr body proc)]
      [(declare ([,x* ,prem*] ...) ,body) (each-expr body proc)]
      [(declare-distinct (,x* ...) ,body) (each-expr body proc)]
      [(policy ([,pn* ,b*] ...) ,body) (each-expr body proc)]
      [(set! ,x ,e) (each-expr e proc)]
      [else (void)]))

  (define (each-simple se proc)
    (nanopass-case (Lssa SimpleExpr) se
      [(lambda (,x* ...) ,body) (each-expr body proc)]
      [else (void)]))

  (define (lambda-body-of e)
    (nanopass-case (Lssa Expr) e
      [(lambda (,x* ...) ,body) body]
      [else #f]))

  ;; The letrec-bound lambda whose name this loop carries. (sonic loops) found
  ;; it by an SCC over the call graph; this walks back to the syntax.
  (define (loop-lambda-body e name)
    (let ([found #f])
      (each-expr
       e
       (lambda (t)
         (unless found
           (nanopass-case (Lssa Expr) t
             [(letrec ([,x* ,e*] ...) ,body)
              (let scan ([xs x*] [es e*])
                (unless (or found (null? xs))
                  (if (eq? (car xs) name)
                      (set! found (lambda-body-of (car es)))
                      (scan (cdr xs) (cdr es)))))]
             [else (void)]))))
      found))

  (define (reaches-back-edge? e f)
    (let ([hit #f])
      (each-expr e
                 (lambda (t)
                   (nanopass-case (Lssa Expr) t
                     [(tailcall ,x ,x* ...) (when (eq? x f) (set! hit #t))]
                     [else (void)])))
      hit))

  ;; --- the body scan ---------------------------------------------------------
  ;;
  ;; One walk. The FIRST `if` that has exactly one arm reaching the back edge is
  ;; the loop's exit test: every loop has one and it is not a branch IN the body,
  ;; so it is stepped through into the taken arm and not reported. Any `if` after
  ;; that is a branch in the body and refuses, which is also how a surviving
  ;; check would have shown up had elide.ss expanded it here rather than leaving
  ;; it as a control on the primcall.
  ;;
  ;; A nested `letrec` is not descended into. It is a nested loop, the outer loop
  ;; is refused for containing it, and walking inside would attribute the inner
  ;; loop's accesses to the outer one.

  (define (scan-body body f carried)
    (let ([accs '()] [chks '()] [permits '()] [ctrl '()] [defs '()] [ivchk '()])

      (define (ctrl! r) (set! ctrl (cons r ctrl)))
      (define (def! x d) (set! defs (cons (cons x d) defs)))

      (define (primcall! pr pns cs args bound)
        (let ([exempt (and bound (memq bound carried) (loop-control-prim? pr))])
          (for-each
           (lambda (pn c)
             (cond
              [(not (branch-check? pn)) (void)]
              [(eq? c 'checked)
               (if exempt
                   (set! ivchk (cons (list pr pn args) ivchk))
                   (set! chks (cons (list pr pn args) chks)))]
              [(eq? c 'unchecked) (set! permits (cons (list pr pn args) permits))]
              [else (void)]))
           pns cs))
        (let ([a (access-of pr args)])
          (when a (set! accs (cons a accs))))
        (when bound (def! bound (cons pr args))))

      (define (Expr e guard-pending?)
        (nanopass-case (Lssa Expr) e
          [(let ([,x ,se]) ,body) (Simple se x) (Expr body guard-pending?)]
          [(seq ,e0 ,e1) (Expr e0 guard-pending?) (Expr e1 guard-pending?)]
          [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body)
           (def! x0 (list 'copy x1))
           (Expr body guard-pending?)]
          [(if ,x ,e0 ,e1)
           (let ([a (reaches-back-edge? e0 f)] [b (reaches-back-edge? e1 f)])
             (cond
              [(and guard-pending? a (not b)) (Expr e0 #f)]
              [(and guard-pending? b (not a)) (Expr e1 #f)]
              [else (ctrl! 'branch) (Expr e0 #f) (Expr e1 #f)]))]
          [(phi ([,x* (,lbl** ,e**) ...] ...) ,body)
           (ctrl! 'merge)
           (Expr body guard-pending?)]
          [(letrec ([,x* ,e*] ...) ,body)
           (ctrl! 'nested-loop)
           (Expr body guard-pending?)]
          [(lambda (,x* ...) ,body) (ctrl! 'nested-lambda)]
          [(tailcall ,x ,x* ...) (unless (eq? x f) (ctrl! 'tailcall))]
          [(set! ,x ,e) (ctrl! 'assignment) (Expr e guard-pending?)]
          [(declare ([,x* ,prem*] ...) ,body) (Expr body guard-pending?)]
          [(declare-distinct (,x* ...) ,body) (Expr body guard-pending?)]
          [(policy ([,pn* ,b*] ...) ,body) (Expr body guard-pending?)]
          [(quote ,d) (void)]
          [(void) (void)]
          [,x (void)]
          [else (ctrl! 'unhandled-form)]))

      (define (Simple se bound)
        (nanopass-case (Lssa SimpleExpr) se
          [(primcall ,pr ([,pn* ,c*] ...) ,x* ...) (primcall! pr pn* c* x* bound)]
          [(call ,x ,x* ...) (ctrl! 'call)]
          [(lambda (,x* ...) ,body) (ctrl! 'nested-lambda)]
          [,x (when bound (def! bound (list 'copy x)))]
          [(quote ,d) (when bound (def! bound (list 'const d)))]
          [else (void)]))

      ;; The HEADER phi is the loop's parameter list under another name, not a
      ;; merge inside the body, so it is peeled before the walk starts. loops.ss
      ;; says it is optional on input, and peeling nothing is the same code.
      (Expr (strip-header body) #t)
      (values (reverse accs) (reverse chks) (reverse permits)
              (reverse ctrl) defs (reverse ivchk))))

  (define (strip-header e)
    (nanopass-case (Lssa Expr) e
      [(phi ([,x* (,lbl** ,e**) ...] ...) ,body) (strip-header body)]
      [else e]))

  ;; --- loop-carried values ---------------------------------------------------

  (define (root defs x)
    (let ([d (assq x defs)])
      (if (and d (pair? (cdr d)) (eq? (cadr d) 'copy))
          (root defs (caddr d))
          x)))

  ;; What the back edge does to each phi. Four answers, and only the last two
  ;; refuse.
  ;;
  ;;   invariant   the same value goes round, so every lane sees it
  ;;   induction   (sonic loops) recognised it, so stage 10 rewrites it as a
  ;;               strided update
  ;;   reduction   arithmetic on the phi itself. D24 refuses it.
  ;;   carried     something else flows round the loop and we cannot say what
  ;;
  ;; A BASIC INDUCTION VARIABLE IS INDUCTION EVEN WHEN ITS STEP IS UNKNOWN.
  ;; `i = i + stp` for an invariant stp of unknown value is affine, not
  ;; accumulating, and calling it a reduction would blame D24 for what is
  ;; actually a missing trip count. The trip count refuses that loop on its own
  ;; and says why, which is the accurate report.
  ;;
  ;; What separates the two is where the OTHER operand comes from. A reduction
  ;; folds in a value that changes every iteration, so at least one operand
  ;; besides the phi has to be defined inside the body; an affine update's other
  ;; operand is loop invariant and is not defined there at all.
  (define (carried-kind l defs p v)
    (let ([rv (root defs v)]
          [iv (loop-iv-ref l p)])
      (cond
       [(eq? rv p) 'invariant]
       [(and iv (eq? (iv-kind iv) 'basic)) 'induction]
       [else
        (let ([d (assq rv defs)])
          (cond
           [(and d (pair? (cdr d))
                 (accumulating-prim? (cadr d))
                 (exists (lambda (a) (eq? (root defs a) p)) (cddr d))
                 (exists (lambda (a)
                           (and (not (eq? (root defs a) p))
                                (assq (root defs a) defs)))
                         (cddr d)))
            'reduction]
           [else 'carried]))])))

  ;; --- trip count to widths --------------------------------------------------
  ;;
  ;; The number of iterations that are GUARANTEED to run, which is not the same
  ;; as the number that might. An exact count is itself; a bounded count gives
  ;; only its lower end, and a triangular inner loop's lower end is zero, so it
  ;; commits to no width at all. That refusal is the applu number in miniature.
  (define (guaranteed-trips t)
    (cond
     [(trip-unknown? t) #f]
     [(trip-exact? t) (trip-count t)]
     [else (let ([lo (interval-lo (trip-interval t))]) (if (integer? lo) lo 0))]))

  (define (widths-for bits n)
    (if (or (not bits) (not n))
        '()
        (filter (lambda (w) (<= (/ w bits) n)) vl-candidate-widths)))

  ;; --- the verdict -----------------------------------------------------------

  (define (distinct? tbl x y) (and tbl (must-not-alias? tbl x y)))

  (define vectorize-legal-loop
    (case-lambda
      [(e l) (vectorize-legal-loop* e l #f)]
      [(e l tbl) (vectorize-legal-loop* e l tbl)]))

  (define (vectorize-legal-loop* e l tbl)
    (let* ([f (loop-name l)]
           [t (loop-trip l)]
           [body (loop-lambda-body e f)]
           [carried (apply append (loop-back-edges l))]
           [reasons '()]
           [cites '()]
           [notes '()])
      (define (refuse! r detail)
        (unless (memq r reasons) (set! reasons (cons r reasons)))
        (set! cites (cons (cons r detail) cites)))
      (define (note! n) (set! notes (cons n notes)))
      (cond
       [(not body)
        (make-vl f t #f '() #f '(loop-body-not-found) '() '() '())]
       [else
        (let-values ([(accs chks permits ctrl defs ivchk) (scan-body body f carried)])

          ;; 1. control flow. A branch in the body makes the lanes disagree.
          (when (loop-irreducible? l) (refuse! 'irreducible (loop-members l)))
          (unless (null? ctrl) (refuse! 'control-flow-in-body ctrl))

          ;; 2. checks that survived elision. Each is a branch out of the body.
          (for-each (lambda (c) (refuse! 'surviving-check c)) chks)
          (for-each (lambda (c) (note! (cons 'policy-suppressed c))) permits)
          (for-each (lambda (c) (note! (cons 'loop-control-check c))) ivchk)

          ;; 3. storage class. A tagged element is a Scheme object, it is
          ;;    scavenged, and there is no vector load for it.
          (for-each
           (lambda (a)
             (let ([cls (element-class (acc-prim a))])
               (when (eq? cls 'tagged)
                 (refuse! 'tagged-element (list (acc-prim a) (acc-array a) cls)))))
           accs)

          ;; 4. distinctness. Only writes create the obligation.
          (for-each
           (lambda (w)
             (when (eq? (acc-kind w) 'write)
               (for-each
                (lambda (o)
                  (unless (eq? w o)
                    (cond
                     [(eq? (acc-array w) (acc-array o))
                      (unless (eq? (acc-index w) (acc-index o))
                        (refuse! 'loop-carried-memory-dependence
                                 (list (acc-array w) (acc-index w) (acc-index o))))]
                     [(distinct? tbl (acc-array w) (acc-array o)) (void)]
                     [else (refuse! 'may-alias (list (acc-array w) (acc-array o)))])))
                accs)))
           accs)

          ;; 5. what the back edge carries. The operand list is positionally
          ;;    parallel to the phis, which is what makes this a zip. More than
          ;;    one back edge means (sonic loops) already returned an unknown
          ;;    trip count, so the loop refuses below without this pass having to
          ;;    guess which edge to read.
          (let ([back (loop-back-edges l)])
            (when (and (= (length back) 1)
                       (= (length (car back)) (length (loop-phis l))))
              (for-each
               (lambda (p v)
                 (case (carried-kind l defs p v)
                   [(invariant induction) (void)]
                   [(reduction)
                    (refuse! 'reassociation-forbidden
                             (list p v (let ([d (assq (root defs v) defs)])
                                         (and d (cadr d)))
                                   'D24))]
                   [else (refuse! 'loop-carried-dependence (list p v))]))
               (loop-phis l)
               (car back))))

          ;; 6. the trip count, and the widths that follow from it.
          (let* ([cls (let scan ([as accs])
                        (cond [(null? as) #f]
                              [(element-class (acc-prim (car as)))]
                              [else (scan (cdr as))]))]
                 [bits (or (vl-element-bits cls) 64)]
                 [n (guaranteed-trips t)]
                 [ws (widths-for bits n)])
            (when (null? accs) (note! 'no-memory-operations))
            (cond
             [(not n) (refuse! 'unknown-trip-count (trip-why t))]
             [(null? ws) (refuse! 'trip-count-too-short (list (trip-kind t) n))])
            (let ([legal? (null? reasons)])
              (make-vl f t cls
                       (if legal? ws '())
                       (and legal? (not (null? ws))
                            (/ (car (reverse ws)) bits))
                       (reverse reasons) (reverse cites) (reverse notes) accs))))])))

  (define vectorize-legal
    (case-lambda
      [(e) (vectorize-legal e #f)]
      [(e tbl)
       (map (lambda (l) (vectorize-legal-loop e l tbl)) (analyze-loops e))]))

  ;; --- reporting -------------------------------------------------------------

  (define (vl-report v)
    (printf "  ~a ~a"
            (if (vl-legal? v) "[+] VECTORIZABLE" "[-] refused     ")
            (vl-loop v))
    (if (vl-legal? v)
        (printf "  ~a at ~a\n" (or (vl-elt-class v) 'no-elements) (vl-widths v))
        (printf "\n"))
    (printf "        trip ~a ~a, ~a accesses\n"
            (trip-kind (vl-trip v))
            (or (trip-count (vl-trip v)) (trip-why (vl-trip v)))
            (length (vl-accesses v)))
    (for-each (lambda (c) (printf "        because ~a ~s\n" (car c) (cdr c)))
              (vl-cites v))
    (for-each (lambda (n) (printf "        note ~s\n" n)) (vl-notes v)))
  )
