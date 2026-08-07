;;; Tests for e-SSA construction, Lanf -> Lssa.
;;;
;;; These assert on the SHAPE of the output, not on "it did not crash".
;;; nanopass already guarantees the output is a well-formed Lssa term, so a
;;; test that only checks for the absence of an exception checks nothing this
;;; file's grammar has not already checked at expansion time. What is worth
;;; asserting is the three properties a downstream client depends on:
;;;
;;;   - every definition in the output has a distinct name (the SSA property);
;;;   - phi appears exactly where a merge is, and nowhere else;
;;;   - sigma appears on both edges of a comparison branch, over exactly the
;;;     variables that branch constrains, with the comparison oriented so the
;;;     refined variable is the FIRST operand.
;;;
;;; The last one is what ABCD reads. If the orientation is wrong the constraint
;;; graph gets its edges backwards and the analysis is silently unsound rather
;;; than noisily broken, so it is spelled out per sigma rather than counted.

(import (chezscheme) (nanopass) (sonic lang) (sonic essa))

(define failures 0)
(define checks 0)

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

(define (run t) (unparse-Lssa (essa t)))

;; --- structural probes over the unparsed output ---------------------------

;; Every subform tagged `tag`, in document order.
(define (collect tag s)
  (reverse
    (let walk ([s s] [acc '()])
      (if (not (pair? s))
          acc
          (let ([acc (if (eq? (car s) tag) (cons s acc) acc)])
            (let loop ([l s] [acc acc])
              (if (pair? l) (loop (cdr l) (walk (car l) acc)) acc)))))))

;; Every name the output DEFINES: let, letrec, lambda parameters, phi and the
;; out-variable of sigma.
(define (binders s)
  (let walk ([s s] [acc '()])
    (if (not (pair? s))
        acc
        (let ([acc (case (car s)
                     [(let letrec phi) (append (map car (cadr s)) acc)]
                     [(lambda) (append (cadr s) acc)]
                     [(sigma) (cons (cadr s) acc)]
                     [else acc])])
          (let loop ([l s] [acc acc])
            (if (pair? l) (loop (cdr l) (walk (car l) acc)) acc))))))

(define (all-distinct? xs)
  (let loop ([xs xs])
    (cond [(null? xs) #t]
          [(memq (car xs) (cdr xs)) #f]
          [else (loop (cdr xs))])))

;; `i.7` -> `i`, so a test can name a variable without knowing the counter.
(define (base x)
  (let* ([s (symbol->string x)] [n (string-length s)])
    (let loop ([i (- n 1)])
      (cond [(< i 0) (string->symbol s)]
            [(char-numeric? (string-ref s i)) (loop (- i 1))]
            [(char=? (string-ref s i) #\.) (string->symbol (substring s 0 i))]
            [else (string->symbol s)]))))

;; (sigma x0 x1 pr x2 neg body) -> (x0-base x1-base pr x2-base neg)
;; The flag is part of the shape, not an afterthought: the whole point of the
;; production is that the false edge says "this comparison FAILED" rather than
;; naming an opposite comparison that, for flonums, does not exist.
(define (sigma-shapes s)
  (map (lambda (g)
         (list (base (cadr g)) (base (caddr g)) (cadddr g)
               (base (list-ref g 4)) (list-ref g 5)))
       (collect 'sigma s)))

;; The body of a sigma, which is where the next one on the same edge sits.
(define (sigma-body g) (list-ref g 6))

;; (phi ([x e] ...) body) -> the number of merged names
(define (phi-widths s) (map (lambda (p) (length (cadr p))) (collect 'phi s)))

;; --- 1. straight line: nothing to merge, nothing to refine ----------------

(printf "straight-line block:\n")

(let* ([out (run (with-output-language (Lanf Expr)
                   `(let ([a (quote 1)])
                      (let ([b (primcall fx+ ([overflow-check checked]) a a)])
                        (seq b b)))))])
  (check! "no phi in straight-line code" (length (collect 'phi out)) 0)
  (check! "no sigma in straight-line code" (length (collect 'sigma out)) 0)
  (check! "definitions are uniquely named" (all-distinct? (binders out)) #t)
  ;; The renaming actually happened and uses reach their new definition.
  (check! "uses are rewritten to the renamed definition"
          out
          '(let ([a.1 (quote 1)])
             (let ([b.2 (primcall fx+ ((overflow-check checked)) a.1 a.1)])
               (seq b.2 b.2)))))

;; --- 2. diamond: exactly one merge ----------------------------------------

(printf "\ndiamond:\n")

(let* ([out (run (with-output-language (Lanf Expr)
                   `(let ([c (primcall fx< () i n)])
                      (if c (quote 1) (quote 2)))))])
  (check! "one phi at the join" (length (collect 'phi out)) 1)
  (check! "the join phi merges one value" (phi-widths out) '(1))
  (check! "the phi's name is what the join returns"
          (car (car (cadr (car (collect 'phi out)))))    ; (phi ([j <if>]) j) -> j
          (caddr (car (collect 'phi out))))              ; body is that same j
  ;; phi bindings are now (x (pred val) ...). A value-position diamond carries
  ;; ONE operand on a `join` edge, because Lanf's `if` is not a SimpleExpr and
  ;; there is no syntactic point where the arms' values are named. See the note
  ;; in essa.ss.
  (check! "the diamond's single operand is labelled join"
          (car (cadr (car (cadr (car (collect 'phi out))))))
          'join)
  (check! "and the value under it is the conditional itself"
          (car (cadr (cadr (car (cadr (car (collect 'phi out)))))))
          'if)
  (check! "definitions are uniquely named" (all-distinct? (binders out)) #t))

;; A conditional in statement position has a dead merge, so no phi is named
;; for it. Getting this wrong is how a pass ends up with a phi per `if` in the
;; program whether or not anything reads the value.
(let* ([out (run (with-output-language (Lanf Expr)
                   `(seq (let ([c (primcall fx< () i n)])
                           (if c (quote 1) (quote 2)))
                         (quote 3))))])
  (check! "no phi for a discarded diamond" (length (collect 'phi out)) 0)
  (check! "but the branch is still split" (length (collect 'sigma out)) 4))

;; --- 3. loop: phi at the header -------------------------------------------
;;
;; The header of a loop in this IR is a letrec-bound lambda, and its phis are
;; its parameters: each is the merge of the entry value and the back-edge
;; value. The phi names that merge so ABCD has a vertex for it.

(printf "\nloop:\n")

(let* ([out (run (with-output-language (Lanf Expr)
                   `(letrec ([f (lambda (i s)
                                  (let ([c (primcall fx< () i n)])
                                    (if c
                                        (let ([s2 (primcall fx+ ([overflow-check checked]) s i)])
                                          (let ([i2 (primcall fx+ ([overflow-check checked]) i one)])
                                            (let ([r (call f i2 s2)]) r)))
                                        s)))])
                      (let ([r (call f z z)]) r))))]
       [lam (car (collect 'lambda out))]
       [hdr (caddr lam)])
  (check! "the loop header body is a phi" (car hdr) 'phi)
  (check! "the header phi merges both parameters" (length (cadr hdr)) 2)
  ;; A header phi's operands are now per-predecessor: each is (entry param).
  ;; That is the fix for cqs.13 -- ABCD needs to know which edge a value came
  ;; from, and before this the phi named only the merge.
  (check! "each header operand is labelled with its predecessor edge"
          (map caadr (cadr hdr)) '(entry entry))
  (check! "the header phi's operands are the parameters, in order"
          (map (lambda (b) (cadr (cadr b))) (cadr hdr)) (cadr lam))
  (check! "the header phi names are fresh, not the parameters"
          (all-distinct? (append (map car (cadr hdr)) (cadr lam))) #t)
  (check! "header phi plus the tail join, and no others"
          (length (collect 'phi out)) 2)
  (check! "definitions are uniquely named" (all-distinct? (binders out)) #t)
  ;; The loop-carried uses go through the header phi, not the raw parameter.
  (check! "the test reads the header phi name"
          (let ([hdr-i (car (car (cadr hdr)))])
            (memq hdr-i (car (collect 'primcall out))))
          (let ([hdr-i (car (car (cadr hdr)))])
            (list hdr-i 'n))))

;; A letrec that is not recursive is not a loop and gets no header phi.
(let* ([out (run (with-output-language (Lanf Expr)
                   `(letrec ([g (lambda (u) u)])
                      (let ([r (call g z)]) r))))])
  (check! "no header phi for a non-recursive letrec"
          (length (collect 'phi out)) 0))

;; --- 4. sigma on both edges of a comparison -------------------------------
;;
;; ABCD splits BOTH operands on BOTH edges: the true edge of i<n says as much
;; about n as it does about i. The false edge carries i>=n, which is the fact
;; that discharges an upper-bound check on the other side.

(printf "\nconditional on a comparison:\n")

(let* ([out (run (with-output-language (Lanf Expr)
                   `(let ([c (primcall fx< () i n)])
                      (if c i n))))])
  (check! "four sigmas: two operands, two edges"
          (length (collect 'sigma out)) 4)
  (check! "the facts, in order: true edge then false edge"
          (sigma-shapes out)
          '((i i fx< n #f)    ; true:  i is the i that is < n
            (n n fx> i #f)    ; true:  n is the n that is > i
            (i i fx< n #t)    ; false: i is the i for which i < n FAILED
            (n n fx> i #t)))  ; false: n is the n for which n > i failed
  (check! "definitions are uniquely named" (all-distinct? (binders out)) #t)
  ;; The second sigma on an edge refers to the first one's OUTPUT, which is
  ;; what makes the pair of constraints mutually refining rather than two
  ;; independent facts about the pre-branch values.
  (check! "the second sigma of an edge refines against the first's output"
          (let ([sig (collect 'sigma out)])
            (equal? (sigma-body (car sig))                 ; body of sigma 1
                    (cadr sig)))                           ; is sigma 2
          #t)
  (check! "sigma 2's other operand is sigma 1's output"
          (list-ref (cadr (collect 'sigma out)) 4)
          (cadr (car (collect 'sigma out)))))

;; The remaining comparisons. Every one of them splits BOTH edges now: the false
;; edge repeats the comparison as written and sets the flag, so no primitive has
;; to exist for the opposite relation. Swapping still applies on both edges,
;; because (p a b) and (swap(p) b a) are the same test and fail together.
(define (edge-facts pr)
  (sigma-shapes (run (with-output-language (Lanf Expr)
                       `(let ([c (primcall ,pr () i n)]) (if c i n))))))

(check! "fx<= splits both edges" (edge-facts 'fx<=)
        '((i i fx<= n #f) (n n fx>= i #f) (i i fx<= n #t) (n n fx>= i #t)))
(check! "fx>= splits both edges" (edge-facts 'fx>=)
        '((i i fx>= n #f) (n n fx<= i #f) (i i fx>= n #t) (n n fx<= i #t)))
(check! "fx> splits both edges" (edge-facts 'fx>)
        '((i i fx> n #f) (n n fx< i #f) (i i fx> n #t) (n n fx< i #t)))

;; The false edge of an equality is a DISEQUALITY, and the primitive table has
;; no fx<> to name it. Before the flag existed that edge carried no sigma at
;; all; now it carries the equality with the flag set, and the interval domain
;; declines to refine it, which is the same conclusion reached one layer down
;; where it belongs.
(check! "fx= splits both edges; the false one is a disequality"
        (edge-facts 'fx=)
        '((i i fx= n #f) (n n fx= i #f) (i i fx= n #t) (n n fx= i #t)))

;; NaN, and this is the case the flag exists for. (not (fl< a b)) is TRUE when
;; either operand is NaN, where (fl>= a b) is false, so the false edge must NOT
;; be spelled fl>=. It is spelled fl< with negated? set: a faithful report of
;; what the branch tested, leaving the conclusion to a domain that knows about
;; NaN. interval-test.ss and analyze-test.ss pin that the domain then refuses to
;; narrow anything on that edge.
(check! "a flonum false edge repeats the comparison and sets the flag"
        (edge-facts 'fl<)
        '((i i fl< n #f) (n n fl> i #f) (i i fl< n #t) (n n fl> i #t)))
(check! "no flonum sigma ever names the opposite comparison"
        (exists (lambda (s) (memq (caddr s) '(fl>= fl<=)))
                (append (edge-facts 'fl<) (edge-facts 'fl>)))
        #f)

;; --- 5. conditional on a non-comparison -----------------------------------

(printf "\nconditional on a non-comparison:\n")

(let* ([out (run (with-output-language (Lanf Expr)
                   `(let ([p (primcall pair? () v)])
                      (if p (quote 1) (quote 2)))))])
  (check! "a type predicate constrains no interval, so no sigma"
          (length (collect 'sigma out)) 0)
  (check! "the join is still named" (length (collect 'phi out)) 1))

(let* ([out (run (with-output-language (Lanf Expr)
                   `(if p (quote 1) (quote 2))))])
  (check! "a free variable as the test yields no sigma"
          (length (collect 'sigma out)) 0))

;; A comparison whose two operands are the same variable constrains one
;; variable, not two.
(let* ([out (run (with-output-language (Lanf Expr)
                   `(let ([c (primcall fx< () i i)]) (if c i i))))])
  (check! "a self-comparison splits one variable per edge"
          (sigma-shapes out) '((i i fx< i #f) (i i fx< i #t))))

;; --- 5b. the guarded loop, which is why the expander nests -----------------
;;
;; This is the Lanf shape a conjunctive guard MUST arrive in, and the reason
;; (sonic expand) lowers `and` in test position to nested ifs rather than to a
;; boolean temporary. Written the other way, the outer test is a let-bound
;; boolean produced by an `if`, `simple-fact` finds no comparison, and the
;; branch gets no sigma at all -- the analysis goes blind at exactly the shape
;; every bounds-guarded loop in the benchmark set has.
;;
;; Nested, each comparison gets its own pair, and the inner one is converted
;; under the outer edge's refined environment, so the two facts COMPOSE: the
;; index reaching flvector-ref is the one known both >= 0 and < n.

(printf "\nguarded loop:\n")

(let* ([out (run (with-output-language (Lanf Expr)
                   `(letrec ([f (lambda (i)
                                  (let ([c1 (primcall fx<= () zero i)])
                                    (if c1
                                        (let ([c2 (primcall fx< () i n)])
                                          (if c2
                                              (let ([v (primcall flvector-ref
                                                                 ([type-check checked]
                                                                  [bounds-check checked])
                                                                 a i)])
                                                v)
                                              (quote 0)))
                                        (quote 0))))])
                      (let ([r (call f z)]) r))))]
       [sigmas (collect 'sigma out)])
  ;; Two guards, two operands each, two edges each.
  (check! "a two-comparison guard yields eight sigmas"
          (length sigmas) 8)
  (check! "the guard's facts, both edges of both tests"
          (sigma-shapes out)
          '((zero zero fx<= i #f)     ; 0 <= i
            (i i fx>= zero #f)        ; i >= 0, and this is the one that matters
            (i i fx< n #f)            ; i < n, under the refined i
            (n n fx> i #f)
            (i i fx< n #t)            ; the inner guard failing
            (n n fx> i #t)
            (zero zero fx<= i #t)     ; the outer guard failing
            (i i fx>= zero #t)))
  ;; The composition. The index handed to flvector-ref must be the name the
  ;; INNER sigma produced, not the loop parameter and not the outer sigma's
  ;; output: only that name carries both bounds.
  (check! "the indexed load reads the doubly-refined index"
          (let* ([load (car (filter (lambda (p) (eq? (cadr p) 'flvector-ref))
                                    (collect 'primcall out)))]
                 ;; (primcall flvector-ref (controls) a idx)
                 [idx (list-ref load 4)]
                 ;; sigma 3 is (i i fx< n #f), the inner refinement of i
                 [inner-i (cadr (list-ref sigmas 2))])
            (eq? idx inner-i))
          #t)
  (check! "definitions are uniquely named" (all-distinct? (binders out)) #t))

;; --- 6. the fact must not outlive the value it is about -------------------
;;
;; If the tested variable is rebound between the comparison and the branch,
;; the fact is about the OLD binding. Refining the new one would be unsound,
;; and it is the kind of unsoundness that shows up three stages later as a
;; deleted bounds check on the wrong array.

(printf "\nshadowing:\n")

(let* ([out (run (with-output-language (Lanf Expr)
                   `(let ([c (primcall fx< () i n)])
                      (let ([i (quote 5)])
                        (if c i n)))))])
  (check! "a rebound operand drops its sigma, keeps the other's"
          (sigma-shapes out)
          '((n n fx> i #f) (n n fx> i #t))))


;; --- regression: nanopass's generated clause is the dangerous kind of default
;; It typechecks, it round-trips, and it is WRONG. Without an explicit tailcall
;; clause the operands are copied verbatim with no env-lookup, so a back edge
;; emits (tailcall loop i2 n) while the binders are loop.1, i2.11, n.5. Every
;; loop consumer downstream then reads an induction step naming variables that
;; do not exist.
(let* ([prog (with-output-language (Lanf Expr)
               `(letrec ([loop (lambda (i n)
                                 (let ([t (primcall fx< () i n)])
                                   (if t
                                       (let ([i2 (primcall fx+ ([overflow-check checked]) i one)])
                                         (tailcall loop i2 n))
                                       (quote 0))))])
                  (tailcall loop zero ten)))]
       [out (unparse-Lssa (essa prog))]
       [syms (let f ([x out]) (cond [(pair? x) (append (f (car x)) (f (cdr x)))]
                                    [(symbol? x) (list x)] [else '()]))]
       [renamed? (lambda (base)
                   ;; the ORIGINAL name must not survive anywhere a binder was renamed
                   (not (memq base syms)))])
  (check! "tailcall operator is renamed, not copied verbatim" (renamed? 'loop) #t)
  (check! "tailcall argument is renamed" (renamed? 'i2) #t)
  (check! "free variables are untouched" (and (memq 'zero syms) (memq 'ten syms) #t) #t))

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
