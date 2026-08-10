;;; Tests for loop recognition, induction variables and trip counts.
;;;
;;; The assertions here are about ANSWERS, not about the absence of a crash,
;;; and the answer that gets the most attention is `unknown`. Larsen's applu
;;; number is the reason: 22.56% of the kernel vectorizes at 256 bits and 0.01%
;;; at 1024, and the collapse is what a guessed trip count does to an unroll
;;; factor. So a wrong count is worse than none, and the cases below that must
;;; return `unknown` are as load bearing as the ones that must return 5.
;;;
;;; WHY THE FIXTURES ARE HAND-WRITTEN Lssa RATHER THAN essa's OUTPUT.
;;;
;;; fixtures.ss's philosophy, and one hard blocker. The philosophy first: a
;;; stage-07 test that ran stage 06 to get its input would depend on the PASS
;;; instead of on the frozen contract, which is exactly what EXECUTION.md
;;; section 1 forbids. The blocker second: essa.ss has no `tailcall` clause, so
;;; nanopass's auto-generated one copies the operands through unrenamed and
;;; every back edge it emits names variables that do not exist
;;; ((tailcall loop i2 n) where the binders are loop.1, i2.11 and n.5). The back
;;; edge is the one thing this stage cannot do without, so its input is written
;;; here in the shape essa is specified to produce rather than the shape it
;;; currently produces. See the bead filed against stage 06.
;;;
;;; nbody's access is the real fixture spliced in, not a copy: `nbody-inner-ssa`
;;; appears verbatim inside the innermost loop below, so `off`, `idx` and the
;;; flvector-ref under test are the frozen ones.

(import (chezscheme) (nanopass) (sonic lang) (sonic interval)
        (sonic fixtures) (sonic loops)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic pipeline))

;; MATCHED BY PREFIX. The `%NN` comes from the expander and is stable with the
;; source; the trailing `.NNN` is a global gensym counter that every pass
;; upstream shifts -- unrolling and inlining have each moved it. A test pinning
;; the counter fails whenever an unrelated pass allocates a name, and reports it
;; as a missing loop rather than as what it is.
(define (name-prefix? prefix nm)
  (let ((s (symbol->string nm)) (p (symbol->string prefix)))
    (and (>= (string-length s) (string-length p))
         (string=? (substring s 0 (string-length p)) p))))

(define failures 0)
(define checks 0)

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

(define (iv-pair a) (list (interval-lo a) (interval-hi a)))

;; What a loop answered, in a form a test can be written against.
(define (summary l)
  (list (loop-name l)
        (loop-depth l)
        (trip-kind (loop-trip l))
        (trip-count (loop-trip l))))

(define (basic-ivs l) (filter (lambda (v) (eq? (iv-kind v) 'basic)) (loop-ivs l)))
(define (derived-ivs l) (filter (lambda (v) (eq? (iv-kind v) 'derived)) (loop-ivs l)))

;; --- fixtures --------------------------------------------------------------

;; A letrec-bound lambda that does not call itself. Not a loop, and the whole
;; point of the SCC test is that this is decided rather than assumed.
(define (not-a-loop)
  (with-output-language (Lssa Expr)
    `(let ([zero (quote 0)])
       (letrec ([f (lambda (a) a)])
         (let ([r (call f zero)])
           r)))))

;; The counted loop, in the shape essa specifies: the header is the letrec-bound
;; lambda, its parameters are the phis, and BOTH operands of the guard get a
;; sigma on the taken edge.
;;
;;   for (i = from; i < upto; i += by) ;
(define (counted from upto by)
  (with-output-language (Lssa Expr)
    `(let ([lo (quote ,from)])
       (let ([hi (quote ,upto)])
         (let ([by (quote ,by)])
           (letrec ([lp (lambda (i.p n.p)
                          (phi ([i (entry i.p)] [n (entry n.p)])
                            (let ([c (primcall fx< () i n)])
                              (if c
                                  (sigma i.g i fx< n #f
                                    (sigma n.g n fx> i.g #f
                                      (let ([i2 (primcall fx+ ([overflow-check checked])
                                                          i.g by)])
                                        (tailcall lp i2 n.g))))
                                  (quote 0)))))])
             (tailcall lp lo hi)))))))

;; The same loop with the exit test written the other way round: the back edge
;; is on the FALSE edge of (fx>= i n), so the fact carries negated? = #t and the
;; domain, not this pass, decides that it licenses `<`.
(define (counted-negated from upto)
  (with-output-language (Lssa Expr)
    `(let ([lo (quote ,from)])
       (let ([hi (quote ,upto)])
         (let ([one (quote 1)])
           (letrec ([lp (lambda (i.p n.p)
                          (phi ([i (entry i.p)] [n (entry n.p)])
                            (let ([c (primcall fx>= () i n)])
                              (if c
                                  (quote 0)
                                  (sigma i.g i fx>= n #t
                                    (let ([i2 (primcall fx+ ([overflow-check checked])
                                                        i.g one)])
                                      (tailcall lp i2 n)))))))])
             (tailcall lp lo hi)))))))

;; The bound is recomputed on the back edge, so it is not loop invariant and no
;; count may be claimed. This is the case a pass that reads only the initial
;; value of `n` gets confidently wrong.
(define (shrinking-bound)
  (with-output-language (Lssa Expr)
    `(let ([lo (quote 0)])
       (let ([hi (quote 10)])
         (let ([one (quote 1)])
           (letrec ([lp (lambda (i.p n.p)
                          (phi ([i (entry i.p)] [n (entry n.p)])
                            (let ([c (primcall fx< () i n)])
                              (if c
                                  (sigma i.g i fx< n #f
                                    (let ([i2 (primcall fx+ ([overflow-check checked])
                                                        i.g one)])
                                      (let ([n2 (primcall fx- ([overflow-check checked])
                                                          n one)])
                                        (tailcall lp i2 n2))))
                                  (quote 0)))))])
             (tailcall lp lo hi)))))))

;; loop-anf's shape, promoted to Lssa. Its step is the free variable `one`,
;; which is loop invariant and whose VALUE is unknown, so there is an induction
;; variable with no step and therefore no trip count.
(define (symbolic-step)
  (with-output-language (Lssa Expr)
    `(let ([lo (quote 0)])
       (let ([hi (quote 10)])
         (letrec ([lp (lambda (i.p n.p)
                        (phi ([i (entry i.p)] [n (entry n.p)])
                          (let ([c (primcall fx< () i n)])
                            (if c
                                (sigma i.g i fx< n #f
                                  (let ([i2 (primcall fx+ ([overflow-check checked])
                                                      i.g one)])
                                    (tailcall lp i2 n)))
                                (quote 0)))))])
           (tailcall lp lo hi))))))

;; Two levels. The inner loop is entered from inside the outer one, so its entry
;; value is read in the outer loop's context.
(define (nest)
  (with-output-language (Lssa Expr)
    `(let ([zero (quote 0)])
       (let ([five (quote 5)])
         (let ([seven (quote 7)])
           (let ([one (quote 1)])
             (letrec ([outer
                       (lambda (i.p n.p)
                         (phi ([i (entry i.p)] [n (entry n.p)])
                           (let ([c1 (primcall fx< () i n)])
                             (if c1
                                 (sigma i.g i fx< n #f
                                   (letrec ([inner
                                             (lambda (k.p m.p)
                                               (phi ([k (entry k.p)] [m (entry m.p)])
                                                 (let ([c2 (primcall fx< () k m)])
                                                   (if c2
                                                       (sigma k.g k fx< m #f
                                                         (let ([k2 (primcall
                                                                     fx+ ([overflow-check checked])
                                                                     k.g one)])
                                                           (tailcall inner k2 m)))
                                                       (quote 0)))))])
                                     (let ([r (call inner zero seven)])
                                       (let ([i2 (primcall fx+ ([overflow-check checked])
                                                           i.g one)])
                                         (tailcall outer i2 n)))))
                                 (quote 0)))))])
               (tailcall outer zero five))))))))

;; nbody. Three loops, and `nbody-inner-ssa` is spliced in verbatim as the body
;; of the innermost one, so `i` and `k` there are these loops' phis and
;; `b[i*7 + k]` is a derived induction variable of the pair.
;;
;;   for (i = 0; i < 5; i++)                 5 bodies
;;     for (j = i+1; j < 5; j++)             the pairwise half, a triangular
;;                                           loop whose count is bounded, not
;;                                           exact, and must not be reported
;;                                           as exact
;;     for (k = 0; k < 7; k++)               7 doubles per body
;;       b[i*7 + k]
(define (nbody-loops)
  (with-output-language (Lssa Expr)
    `(let ([zero (quote 0)])
       (let ([five (quote 5)])
         (let ([seven (quote 7)])
           (let ([one (quote 1)])
             (letrec ([bodies
                       (lambda (i.p n.p)
                         (phi ([i (entry i.p)] [n (entry n.p)])
                           (let ([c1 (primcall fx< () i n)])
                             (if c1
                                 (sigma i.g i fx< n #f
                                   (letrec
                                     ([pairs
                                       (lambda (j.p q.p)
                                         (phi ([j (entry j.p)] [q (entry q.p)])
                                           (let ([c3 (primcall fx< () j q)])
                                             (if c3
                                                 (sigma j.g j fx< q #f
                                                   (let ([j2 (primcall
                                                               fx+ ([overflow-check checked])
                                                               j.g one)])
                                                     (tailcall pairs j2 q)))
                                                 (quote 0)))))]
                                      [fields
                                       (lambda (k.p m.p)
                                         (phi ([k (entry k.p)] [m (entry m.p)])
                                           (let ([c2 (primcall fx< () k m)])
                                             (if c2
                                                 (sigma k.g k fx< m #f
                                                   (seq ,(nbody-inner-ssa)
                                                        (let ([k2 (primcall
                                                                    fx+ ([overflow-check checked])
                                                                    k.g one)])
                                                          (tailcall fields k2 m))))
                                                 (quote 0)))))])
                                     (let ([j0 (primcall fx+ ([overflow-check checked])
                                                         i.g one)])
                                       (let ([r1 (call pairs j0 n)])
                                         (let ([r2 (call fields zero seven)])
                                           (let ([i.n (primcall fx+ ([overflow-check checked])
                                                                i.g one)])
                                             (tailcall bodies i.n n)))))))
                                 (quote 0)))))])
               (tailcall bodies zero five))))))))

;; An irreducible cycle: two lambdas that call each other, both entered from
;; outside. There is no single header, so there is no natural loop in the
;; textbook sense, and the honest answer is to name the cycle and refuse to
;; count it.
(define (irreducible)
  (with-output-language (Lssa Expr)
    `(let ([zero (quote 0)])
       (let ([one (quote 1)])
         (letrec ([ping (lambda (a.p)
                          (phi ([a (entry a.p)])
                            (let ([a2 (primcall fx+ ([overflow-check checked]) a one)])
                              (tailcall pong a2))))]
                  [pong (lambda (b.p)
                          (phi ([b (entry b.p)])
                            (let ([b2 (primcall fx+ ([overflow-check checked]) b one)])
                              (tailcall ping b2))))])
           (let ([r1 (call ping zero)])
             (let ([r2 (call pong one)])
               r2)))))))

;; --- 1. what is not a loop --------------------------------------------------

(printf "not loops:\n")

(check! "straight-line Lssa has no loop"
        (analyze-loops (nbody-inner-ssa)) '())

(check! "a letrec-bound lambda that cannot reach itself is not a loop"
        (analyze-loops (not-a-loop)) '())

;; --- 2. the counted loop ----------------------------------------------------

(printf "\ncounted loops:\n")

(let* ([ls (analyze-loops (counted 0 10 1))]
       [l (car ls)])
  (check! "one loop is found" (length ls) 1)
  (check! "its header is the letrec-bound lambda" (loop-name l) 'lp)
  (check! "its phis are the parameters' merges" (loop-phis l) '(i n))
  (check! "it is reducible" (loop-irreducible? l) #f)
  (check! "one basic induction variable" (map iv-name (basic-ivs l)) '(i))
  (check! "stepping by one" (map iv-step (basic-ivs l)) '(1))
  (check! "from zero" (iv-pair (iv-init (car (basic-ivs l)))) '(0 0))
  (check! "over [0,9]" (iv-pair (iv-span (car (basic-ivs l)))) '(0 9))
  (check! "trip count is exact" (trip-kind (loop-trip l)) 'exact)
  (check! "and it is 10" (trip-count (loop-trip l)) 10)
  ;; `n` is a phi and is NOT reported: it is passed through unchanged, so it is
  ;; invariant rather than induction. `i2` is, because the increment expression
  ;; is an affine function of `i` like any other and strength reduction wants it.
  (check! "the bound is an invariant phi, not an induction variable"
          (map iv-name (loop-ivs l)) '(i i2))
  (check! "the increment is a derived induction variable"
          (let ([d (loop-iv-ref l 'i2)])
            (list (iv-kind d) (iv-base d) (iv-coeff d) (iv-offset d)))
          '(derived i 1 1)))

(let ([l (car (analyze-loops (counted-negated 0 10)))])
  (check! "a back edge on the false edge of fx>= counts the same"
          (list (trip-kind (loop-trip l)) (trip-count (loop-trip l)))
          '(exact 10)))

;; The error this test exists for is reporting 9 or 10 instead of 5: forgetting
;; to divide by the step, or dividing and truncating instead of rounding up.
;; i takes 0 2 4 6 8, so the count is ceil(9/2) = 5 and neither 4 nor 9.
(let ([l (car (analyze-loops (counted 0 9 2)))])
  (check! "an induction variable stepping by 2"
          (map iv-step (basic-ivs l)) '(2))
  (check! "a bound of 9 and a step of 2 is 5 iterations, not 4 and not 9"
          (list (trip-kind (loop-trip l)) (trip-count (loop-trip l)))
          '(exact 5))
  (check! "and it ranges over [0,8]"
          (iv-pair (iv-span (car (basic-ivs l)))) '(0 8)))

(let ([l (car (analyze-loops (counted 0 10 2)))])
  (check! "an even span divides exactly"
          (trip-count (loop-trip l)) 5))

(let ([l (car (analyze-loops (counted 3 3 1)))])
  (check! "a loop whose guard is false on entry runs zero times"
          (list (trip-kind (loop-trip l)) (trip-count (loop-trip l)))
          '(exact 0)))

;; A descending loop: i from 10 down while i > 0, stepping by -1. The count is
;; 10 and the values are [1,10], not [0,10].
(let* ([l (car (analyze-loops
                 (with-output-language (Lssa Expr)
                   `(let ([lo (quote 10)])
                      (let ([hi (quote 0)])
                        (let ([one (quote 1)])
                          (letrec ([lp (lambda (i.p n.p)
                                         (phi ([i (entry i.p)] [n (entry n.p)])
                                           (let ([c (primcall fx> () i n)])
                                             (if c
                                                 (sigma i.g i fx> n #f
                                                   (let ([i2 (primcall
                                                               fx- ([overflow-check checked])
                                                               i.g one)])
                                                     (tailcall lp i2 n)))
                                                 (quote 0)))))])
                            (tailcall lp lo hi))))))))]
       [v (car (basic-ivs l))])
  (check! "a descending loop steps by -1" (iv-step v) -1)
  (check! "and runs 10 times" (list (trip-kind (loop-trip l)) (trip-count (loop-trip l)))
          '(exact 10))
  (check! "over [1,10], since the last value the body sees is 1"
          (iv-pair (iv-span v)) '(1 10)))

;; --- 3. the answers that must be unknown ------------------------------------

(printf "\nunknown, and deliberately so:\n")

(let* ([l (car (analyze-loops (shrinking-bound)))]
       [t (loop-trip l)])
  (check! "a bound that is not loop invariant yields no count"
          (trip-kind t) 'unknown)
  (check! "and says why" (trip-why t) 'non-invariant-bound)
  (check! "no count is offered as a bound either" (trip-count t) #f)
  (check! "the interval of possible counts is top"
          (iv-pair (trip-interval t)) '(neginf posinf)))

(let* ([l (car (analyze-loops (symbolic-step)))]
       [t (loop-trip l)])
  (check! "an invariant step of unknown value is still an induction variable"
          (map iv-name (basic-ivs l)) '(i))
  (check! "but it has no step" (map iv-step (basic-ivs l)) '(#f))
  (check! "and so no trip count" (list (trip-kind t) (trip-why t))
          '(unknown unknown-step)))

;; A second condition stands between the header and the back edge, so the loop
;; can leave early and the count is an upper BOUND. Claiming `exact 10` here is
;; the same class of error as guessing one.
(let* ([l (car (analyze-loops
                 (with-output-language (Lssa Expr)
                   `(let ([lo (quote 0)])
                      (let ([hi (quote 10)])
                        (let ([one (quote 1)])
                          (letrec ([lp (lambda (i.p n.p)
                                         (phi ([i (entry i.p)] [n (entry n.p)])
                                           (let ([c (primcall fx< () i n)])
                                             (if c
                                                 (sigma i.g i fx< n #f
                                                   (let ([c2 (primcall fx< () p q)])
                                                     (if c2
                                                         (let ([i2 (primcall
                                                                     fx+ ([overflow-check checked])
                                                                     i.g one)])
                                                           (tailcall lp i2 n))
                                                         (quote 9))))
                                                 (quote 0)))))])
                            (tailcall lp lo hi))))))))]
       [t (loop-trip l)])
  (check! "an early exit makes the count a bound, not an exact figure"
          (list (trip-kind t) (trip-count t) (trip-why t))
          '(bound #f extra-exit-guards))
  (check! "the bound itself is still 10" (iv-pair (trip-interval t)) '(0 10)))

;; Two back edges with different guards on them. One step, two paths, and no
;; attempt to reconcile them.
(let ([t (loop-trip
           (car (analyze-loops
                  (with-output-language (Lssa Expr)
                    `(let ([lo (quote 0)])
                       (let ([hi (quote 10)])
                         (let ([one (quote 1)])
                           (letrec ([lp (lambda (i.p n.p)
                                          (phi ([i (entry i.p)] [n (entry n.p)])
                                            (let ([c (primcall fx< () i n)])
                                              (if c
                                                  (sigma i.g i fx< n #f
                                                    (let ([i2 (primcall
                                                                fx+ ([overflow-check checked])
                                                                i.g one)])
                                                      (if p
                                                          (tailcall lp i2 n)
                                                          (tailcall lp i2 n))))
                                                  (quote 0)))))])
                             (tailcall lp lo hi)))))))))])
  (check! "two back edges yield no count"
          (list (trip-kind t) (trip-why t)) '(unknown multiple-back-edges)))

;; A bound that is loop invariant but whose value is not known: nbody's step
;; count is a command-line argument and this is its shape. No trip count, but
;; the induction variable's lower bound survives, which is what a hoisting
;; client actually needs.
(let* ([l (car (analyze-loops
                 (with-output-language (Lssa Expr)
                   `(let ([lo (quote 0)])
                      (let ([one (quote 1)])
                        (letrec ([lp (lambda (i.p n.p)
                                       (phi ([i (entry i.p)] [n (entry n.p)])
                                         (let ([c (primcall fx< () i n)])
                                           (if c
                                               (sigma i.g i fx< n #f
                                                 (let ([i2 (primcall
                                                             fx+ ([overflow-check checked])
                                                             i.g one)])
                                                   (tailcall lp i2 n)))
                                               (quote 0)))))])
                          (tailcall lp lo nsteps)))))))]
       [t (loop-trip l)])
  (check! "an unknown bound yields no count" (trip-kind t) 'unknown)
  (check! "but the index is still known to start at 0 and only grow"
          (iv-pair (iv-span (car (basic-ivs l)))) '(0 posinf)))

;; --- 4. nesting -------------------------------------------------------------

(printf "\nnesting:\n")

(let* ([ls (analyze-loops (nest))]
       [o (loops-ref ls 'outer)]
       [i (loops-ref ls 'inner)])
  (check! "both levels are found" (length ls) 2)
  (check! "outermost first" (map loop-name ls) '(outer inner))
  (check! "the outer loop is at depth 0 with no parent"
          (list (loop-depth o) (loop-parent o)) '(0 #f))
  (check! "the inner loop is at depth 1, inside the outer"
          (list (loop-depth i) (loop-parent i)) '(1 outer))
  (check! "the outer count" (summary o) '(outer 0 exact 5))
  (check! "the inner count" (summary i) '(inner 1 exact 7))
  (check! "the inner bound is invariant, so its phi is not an induction variable"
          (map iv-name (basic-ivs i)) '(k)))

;; --- 5. nbody ---------------------------------------------------------------
;;
;; The acceptance criterion. Three loops, three answers, one of them a bound
;; rather than a number, and no guesses.

(printf "\nnbody:\n")

(let* ([ls (analyze-loops (nbody-loops))]
       [b (loops-ref ls 'bodies)]
       [p (loops-ref ls 'pairs)]
       [f (loops-ref ls 'fields)])
  (check! "three loops" (length ls) 3)
  (check! "the outer loop over the 5 bodies" (summary b) '(bodies 0 exact 5))
  (check! "the inner loop over the 7 doubles of a body"
          (summary f) '(fields 1 exact 7))
  (check! "both inner loops are nested in the outer one"
          (list (loop-parent p) (loop-parent f)) '(bodies bodies))

  ;; The triangular loop. j starts at i+1 with i in [0,4], so the count is
  ;; between 0 and 4 and is not the same on every outer iteration. Reporting
  ;; `exact 4` here is the Larsen failure in miniature.
  (check! "the pairwise loop is BOUNDED, not exact" (trip-kind (loop-trip p)) 'bound)
  (check! "no exact count is offered" (trip-count (loop-trip p)) #f)
  (check! "at most 4 iterations" (iv-pair (trip-interval (loop-trip p))) '(0 4))

  ;; The access the whole project is about. b[i*7 + k] against a 35-element
  ;; flvector: recovered as an affine function of the inner index with the outer
  ;; index folded into its offset, and a range that fits.
  (let ([idx (loop-iv-ref f 'idx)]
        [off (loop-iv-ref b 'off)])
    (check! "off is a derived induction variable of the outer loop"
            (list (iv-kind off) (iv-base off) (iv-coeff off) (iv-offset off) (iv-step off))
            '(derived i 7 0 7))
    (check! "and ranges over [0,28]" (iv-pair (iv-span off)) '(0 28))
    (check! "idx is a derived induction variable of the inner loop"
            (list (iv-kind idx) (iv-base idx) (iv-coeff idx) (iv-offset idx) (iv-step idx))
            '(derived k 1 off 1))
    (check! "b[i*7 + k] ranges over exactly [0,34], which fits a 35-flvector"
            (iv-pair (iv-span idx)) '(0 34))))

;; --- 6. the irreducible case ------------------------------------------------

(printf "\nirreducible:\n")

(let* ([ls (analyze-loops (irreducible))]
       [names (map loop-name ls)])
  (check! "both members of the cycle are recognized as loops"
          (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b))) names)
          '(ping pong))
  (check! "each reports the whole strongly connected component"
          (map (lambda (l) (length (loop-members l))) ls) '(2 2))
  (check! "and each is flagged irreducible"
          (map loop-irreducible? ls) '(#t #t))
  (check! "with no count claimed for either"
          (map (lambda (l) (list (trip-kind (loop-trip l)) (trip-why (loop-trip l)))) ls)
          '((unknown irreducible) (unknown irreducible))))

;; --- a REAL program, which is the case every fixture above missed -----------
;;
;; Every fixture in this file is an Lssa Expr. `analyze-loops` is a
;; `nanopass-case` over Lssa Expr, and a program the front end produces is an
;; Lssa PROGRAM -- so it matched nothing, recorded nothing, and returned the
;; empty list. Not an error: `()`, which reads exactly like "this program has
;; no loops".
;;
;; The whole file was green while the pass answered "no loops" for every
;; program that has ever been compiled, and the damage did not stop here.
;; veclegal.ss asks this pass which loops exist, got none, produced no
;; verdicts, and the vectorizer had nothing to consider -- quietly, at each
;; step.
;;
;; So this test compiles SOURCE. A fixture cannot catch a bug about the shape
;; the front end hands over, because a fixture is not that shape.

(printf "\nreal programs, not fixtures:\n")

(define (ssa-of src externs)
  (let ((p (open-file-output-port "/tmp/sonic-loops-real.sps" (file-options no-fail)
                                  (buffer-mode block) (native-transcoder))))
    (put-string p src) (close-port p))
  (essa-program
   (inline-program
    (assign-convert-program
     (anf-program
      (resolve-policy-program
       (parse-program (expand-program (read-all-from-file "/tmp/sonic-loops-real.sps"))
                      externs)))))))

;; A named let: a letrec-bound lambda that tail-calls itself.
;;
;; TWICE, because `main` is named by exactly one call -- the one the top level
;; makes -- so inline.ss splices it and leaves its definition behind for
;; reachability to drop. `ssa-of` stops before that sweep, so the loop is here
;; once inside the splice and once inside the definition nothing calls.
(let ((ls (analyze-loops
           (ssa-of (string-append
                    "(define (main)\n"
                    "  (display (fx->fl (let loop ((i 0) (a 0))\n"
                    "    (if (fx= i 10) a (loop (fx+ i 1) (fx+ a i))))))\n"
                    "  (newline))\n(main)\n")
                   '(display newline)))))
  (check! "a named let in a real program IS a loop, spliced and original" (length ls) 2)
  (check! "and its induction variable is found"
          (> (length (loop-ivs (car ls))) 0) #t))

;; A top-level `define` that calls itself. Bound by the PROGRAM, not by a
;; letrec, so it needs the top-level binding to be entered under its own name.
(let ((ls (analyze-loops
           (ssa-of (string-append
                    "(define (go i a) (if (fx= i 10) a (go (fx+ i 1) (fx+ a i))))\n"
                    "(define (main) (display (fx->fl (go 0 0))) (newline))\n(main)\n")
                   '(display newline)))))
  (check! "a self-tail-recursive top-level procedure IS a loop" (length ls) 1)
  (check! "and it is named after its binding" (loop-name (car ls)) 'go))

;; THE BENCHMARK. Six named lets and two self-recursive procedures, one nested
;; pair among them -- and the nesting is the part a flat answer would fake.
;;
;; ELEVEN, NOT SEVEN, AND FOUR OF THEM ARE DEAD. `ssa-of` above stops after
;; inlining, and inline.ss SPLICES a body without deleting the binding it came
;; from: a procedure named by exactly one call (rule 2') is copied into its
;; caller and its original definition stays where it was, for reachability to
;; drop later. So `offset-momentum!`'s `loop%12` is here twice -- once inside
;; `main` where it was spliced, once in the definition nothing calls any more --
;; and the same goes for `outer%22`, `inner%24` and `loop%35`.
;;
;; The duplicates do not reach code generation. Compiling the same source all
;; the way through gives 13 functions with `loop%12` appearing ONCE, because
;; finalize drops what nothing calls. This count is of the IR at one stage, and
;; the stage is before the sweep.
(let* ((src (let* ((p (open-file-input-port "../bench/nbody/config-sonic.sps"))
                   (bv (get-bytevector-all p)))
              (close-port p)
              (utf8->string bv)))
       (ls (analyze-loops (ssa-of src nbody-externs))))
  (check! "nbody has eleven loops after inlining, four of them dead copies"
          (length ls) 11)
  (check! "and one of them is nested inside another"
          (> (fold-left max 0 (map loop-depth ls)) 0) #t)
  ;; THE TRIP COUNT, which is the deliverable rather than a bonus.
  ;;
  ;; `(define n-bodies 5)` bounds four of nbody's loops. A top-level binding is
  ;; not always a procedure, and treating one as `(fn nm)` regardless makes it
  ;; opaque -- so `j < n-bodies` compares an induction variable against
  ;; something unknowable and every one of those loops comes back `unbounded`,
  ;; which is the answer this pass gives when it has nothing, and is therefore
  ;; indistinguishable from not having looked.
  ;; FOUR, not two, for the same reason the count above is eleven: the spliced
  ;; copy and the definition it came from are both still here, and both are
  ;; bounded by `n-bodies`. What this asserts is that the bound is RECOGNISED,
  ;; and doubling the copies doubles the recognitions rather than losing them.
  (check! "the loops bounded by n-bodies are counted EXACTLY, at five"
          (let count ((xs ls) (n 0))
            (cond ((null? xs) n)
                  ((and (trip-exact? (loop-trip (car xs)))
                        (= 5 (trip-count (loop-trip (car xs)))))
                   (count (cdr xs) (+ n 1)))
                  (else (count (cdr xs) n))))
          4)
  ;; The pairwise inner loop starts at i+1, so its count varies per outer
  ;; iteration. `bound` rather than `exact` is the honest answer and the one
  ;; this pass's header argues for at length: a guessed count is worse than
  ;; none, because a guessed one is acted on.
  (check! "and the pairwise loop is BOUNDED rather than exactly counted"
          (let find ((xs ls))
            (cond ((null? xs) #f)
                  ((name-prefix? 'inner% (loop-name (car xs)))
                   (and (trip-bound? (loop-trip (car xs)))
                        (not (trip-exact? (loop-trip (car xs))))))
                  (else (find (cdr xs)))))
          #t))

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
