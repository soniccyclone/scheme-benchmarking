;;; May this loop be vectorized, and at what width?
;;;
;;; Like alias-test.ss, the REFUSALS are the load-bearing half. A vectorizer
;;; that permits one loop it should not does not lose an optimization, it
;;; reorders reads against writes and computes the wrong numbers with no
;;; diagnostic anywhere. So one case here is permitted and six refuse, and each
;;; refusal names a different one of the four facts this pass consumes.
;;;
;;; NOTHING IS HAND-FORGED. The four inputs are the real passes:
;;;
;;;   (sonic loops)  is called by (sonic veclegal) itself
;;;   (sonic elide)  is RUN on each fixture, so the `proved` controls the legal
;;;                  cases rely on were produced by the analysis rather than
;;;                  typed in here
;;;   (sonic alias)  builds the table, from the same `declare-distinct` premise
;;;                  a kernel would carry
;;;   (sonic repr)   supplies the element's storage class, through veclegal
;;;
;;; nbody's access is the frozen fixture, EXTRACTED rather than retyped:
;;; `access-chain` runs elide.ss over `nbody-inner-ssa` with elide-test.ss's own
;;; facts and pulls the discharged `off`/`idx`/`flvector-ref` chain out of the
;;; result. Splicing the fixture whole would put its guard, which is the OUTER
;;; loop's test, inside the inner loop as a branch, and the branch is an artifact
;;; of the fragment being written to stand alone.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/veclegal-test.ss

(import (chezscheme) (nanopass) (sonic lang) (sonic fixtures)
        (sonic loops) (sonic elide) (sonic alias) (sonic veclegal)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic pipeline)
        (sonic driver))

(define failures 0)
(define checks 0)

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

(define (check-true! name v) (check! name (and v #t) #t))

;; --- the four inputs, each from its own pass --------------------------------

(define (elided e facts)
  (let-values ([(out st) (elide e facts)]) out))

;; The premise a kernel carries. alias.ss records it per program rather than per
;; program point, which is what lets one table serve the whole stage.
(define distinct-tbl
  (alias-analyze
   (with-output-language (Lanf Expr) `(declare-distinct (a b) (seq a b)))))

;; The same two names with nothing asserted about them. Both are parameters, so
;; allocation-site reasoning runs out at the procedure boundary and the honest
;; answer is `may`.
(define may-tbl
  (alias-analyze (with-output-language (Lanf Expr) `(seq a b))))

(check! "the premise gives must-not" (alias-query distinct-tbl 'a 'b) 'must-not)
(check! "and without it, may" (alias-query may-tbl 'a 'b) 'may)

;; elide-test.ss's facts, verbatim. Note what is NOT stated: `i` has no upper
;; bound, and the bound on the index comes from the guard through sigma.
(define nbody-facts
  '((b flvector 35)
    (i interval 0 posinf)
    (n interval 5 5)
    (k interval 0 6)
    (seven interval 7 7)))

;; nbody's access, discharged by elide.ss and lifted out of its standalone
;; guard. What comes back is `off = i2 * 7`, `idx = off + k`, `b[idx]`, with
;; every control on all three reading `proved`.
(define (access-chain)
  (let find ([e (elided (nbody-inner-ssa) nbody-facts)])
    (nanopass-case (Lssa Expr) e
      [(let ([,x ,se]) ,body) (find body)]
      [(if ,x ,e0 ,e1) (find e0)]
      [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body) body]
      [else e])))

;; --- fixtures ----------------------------------------------------------------

;; nbody's three loops. The outer one walks the 5 bodies, `pairs` is the
;; triangular half of the pairwise interaction, and `fields` is the 7 doubles per
;; body that carry the frozen access.
;;
;;   for (i = 0; i < 5; i++)
;;     for (j = i+1; j < 5; j++)      triangular: a bounded count, not an exact
;;     for (k = 0; k < 7; k++)
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
                                 (sigma i2 i fx< n #f
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
                                                   (seq ,(access-chain)
                                                        (let ([k2 (primcall
                                                                    fx+ ([overflow-check checked])
                                                                    k.g one)])
                                                          (tailcall fields k2 m))))
                                                 (quote 0)))))])
                                     (let ([j0 (primcall fx+ ([overflow-check checked])
                                                         i2 one)])
                                       (let ([r1 (call pairs j0 n)])
                                         (let ([r2 (call fields zero seven)])
                                           (let ([i.n (primcall fx+ ([overflow-check checked])
                                                                i2 one)])
                                             (tailcall bodies i.n n)))))))
                                 (quote 0)))))])
               (tailcall bodies zero five))))))))

;; saxpy: a[i] = a[i] + s * b[i]. The shape alias.ss's header names as the
;; motivating case, and the one every element-wise rule has to get right: `a` is
;; read and written at the SAME index, which is legal, while `a` against `b` is
;; the pair that needs the premise.
(define (saxpy lim)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (let ([lim (quote ,lim)])
         (let ([one (quote 1)])
           (letrec ([lp (lambda (ip np)
                          (phi ([i (entry ip)] [n (entry np)])
                            (let ([t (primcall fx< () i n)])
                              (if t
                                  (sigma i2 i fx< n #f
                                    (let ([av (primcall flvector-ref
                                                        ([type-check checked]
                                                         [bounds-check checked])
                                                        a i2)])
                                      (let ([bv (primcall flvector-ref
                                                          ([type-check checked]
                                                           [bounds-check checked])
                                                          b i2)])
                                        (let ([p (primcall fl* ([fp-contract checked]) s bv)])
                                          (let ([nv (primcall fl+ ([fp-contract checked]) av p)])
                                            (let ([w (primcall flvector-set!
                                                               ([type-check checked]
                                                                [bounds-check checked])
                                                               a i2 nv)])
                                              (let ([inx (primcall fx+
                                                                   ([overflow-check checked])
                                                                   i2 one)])
                                                (tailcall lp inx n))))))))
                                  (quote 0)))))])
             (tailcall lp z lim)))))))

;; A reduction: acc = acc + b[i]. The value the back edge carries is arithmetic
;; on the phi itself, so splitting it across lanes reassociates it.
(define (reduction lim)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (let ([lim (quote ,lim)])
         (let ([one (quote 1)])
           (letrec ([lp (lambda (ip np ap)
                          (phi ([i (entry ip)] [n (entry np)] [acc (entry ap)])
                            (let ([t (primcall fx< () i n)])
                              (if t
                                  (sigma i2 i fx< n #f
                                    (let ([bv (primcall flvector-ref
                                                        ([type-check checked]
                                                         [bounds-check checked])
                                                        b i2)])
                                      (let ([acc2 (primcall fl+ ([fp-contract checked])
                                                            acc bv)])
                                        (let ([inx (primcall fx+ ([overflow-check checked])
                                                             i2 one)])
                                          (tailcall lp inx n acc2)))))
                                  (quote 0)))))])
             (tailcall lp z lim zero)))))))

;; The same element-wise shape over a general vector rather than an flvector.
;; Every element is a Scheme object, so there is nothing to load into a lane.
(define (tagged-loop lim)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (let ([lim (quote ,lim)])
         (let ([one (quote 1)])
           (letrec ([lp (lambda (ip np)
                          (phi ([i (entry ip)] [n (entry np)])
                            (let ([t (primcall fx< () i n)])
                              (if t
                                  (sigma i2 i fx< n #f
                                    (let ([vv (primcall vector-ref
                                                        ([type-check checked]
                                                         [bounds-check checked])
                                                        v i2)])
                                      (let ([inx (primcall fx+ ([overflow-check checked])
                                                           i2 one)])
                                        (tailcall lp inx n))))
                                  (quote 0)))))])
             (tailcall lp z lim)))))))

;; The step is a free variable: loop invariant, and its VALUE is not known. So
;; there is an induction variable and no trip count.
;;
;; It carries no array access on purpose. The refusal under test is the trip
;; count, and an index built from an unknown step would keep its bounds check
;; too, which would report two reasons and prove neither.
(define (unknown-step)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (let ([lim (quote 35)])
         (letrec ([lp (lambda (ip np)
                        (phi ([i (entry ip)] [n (entry np)])
                          (let ([t (primcall fx< () i n)])
                            (if t
                                (sigma i2 i fx< n #f
                                  (let ([inx (primcall fx+ ([overflow-check checked])
                                                       i2 stp)])
                                    (tailcall lp inx n)))
                                (quote 0)))))])
           (tailcall lp z lim))))))

;; a[i] = a[i-1] + 1: the same array, read and written at different indices.
;; Two lanes computed at once would read a value the previous lane has not
;; written yet.
(define (carried-memory lim)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (let ([lim (quote ,lim)])
         (let ([one (quote 1)])
           (letrec ([lp (lambda (ip np)
                          (phi ([i (entry ip)] [n (entry np)])
                            (let ([t (primcall fx< () i n)])
                              (if t
                                  (sigma i2 i fx< n #f
                                    (let ([av (primcall flvector-ref
                                                        ([type-check checked]
                                                         [bounds-check checked])
                                                        a i2)])
                                      (let ([nv (primcall fl+ ([fp-contract checked]) av av)])
                                        (let ([inx (primcall fx+ ([overflow-check checked])
                                                             i2 one)])
                                          (let ([w (primcall flvector-set!
                                                             ([type-check checked]
                                                              [bounds-check checked])
                                                             a inx nv)])
                                            (tailcall lp inx n))))))
                                  (quote 0)))))])
             (tailcall lp z lim)))))))

;; --- helpers ----------------------------------------------------------------

(define (verdict-for e tbl name)
  (let scan ([vs (vectorize-legal e tbl)])
    (cond [(null? vs) #f]
          [(eq? (vl-loop (car vs)) name) (car vs)]
          [else (scan (cdr vs))])))

(define (only-verdict e tbl)
  (let ([vs (vectorize-legal e tbl)])
    (if (= (length vs) 1) (car vs) (error 'only-verdict "expected one loop" vs))))

(define flvec-facts '((a flvector 35) (b flvector 35)))

;; --- 1. nbody's three loops -------------------------------------------------

(printf "\nnbody's three loops:\n")

(define nbody-verdicts (vectorize-legal (nbody-loops)))
(for-each vl-report nbody-verdicts)

;; Compared as a SET. Loop discovery order is not part of any contract -- it
;; falls out of how loops.ss walks the letrec graph -- so asserting a sequence
;; makes this fail on an unrelated change upstream, which it did.
(check! "all three loops are found"
        (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                   (map vl-loop nbody-verdicts))
        '(bodies fields pairs))

;; THE ONE THAT MUST BE PERMITTED. Seven doubles per body, one unboxed read, no
;; write, no branch, and every check on the access discharged by elide.ss.
(let ([v (verdict-for (nbody-loops) #f 'fields)])
  (check-true! "nbody's inner loop is VECTORIZABLE" (vl-legal? v))
  (check! "its element is unboxed" (vl-elt-class v) 'raw-f64)
  (check! "its trip count is exact and is 7"
          (list (trip-kind (vl-trip v)) (trip-count (vl-trip v))) '(exact 7))
  ;; Larsen's applu number, in miniature. A 512-bit vector of doubles is 8 lanes
  ;; and the loop runs 7 times, so the widest legal vector is 256.
  (check! "so it is legal at 128 and 256 bits and at neither wider one"
          (vl-widths v) '(128 256))
  (check! "which is four lanes" (vl-lanes v) 4)
  ;; The check on `k2` is the loop's own increment. Stage 10 replaces that
  ;; update, so it is reported rather than counted against the body.
  (check! "the increment's overflow check is reported as loop control, not body"
          (map car (vl-notes v)) '(loop-control-check)))

;; The outer loop contains two calls and a letrec. Lanes cannot disagree about
;; whether to call a procedure.
(let ([v (verdict-for (nbody-loops) #f 'bodies)])
  (check! "the outer loop is refused" (vl-legal? v) #f)
  (check-true! "for control flow in its body"
               (vl-refused-for? v 'control-flow-in-body))
  ;; `j0` is not a value the back edge carries, so its overflow check is a body
  ;; check and gets no exemption.
  (check-true! "and for a check that survived in the body"
               (vl-refused-for? v 'surviving-check))
  (check! "and it commits to no width" (vl-widths v) '()))

;; The triangular loop. Its count depends on the outer index, so (sonic loops)
;; returns a BOUND rather than an exact count, and a bound's lower end is zero.
(let ([v (verdict-for (nbody-loops) #f 'pairs)])
  (check! "the pairwise loop is refused" (vl-legal? v) #f)
  (check! "because its count is bounded, not exact"
          (trip-kind (vl-trip v)) 'bound)
  (check-true! "so no width has a guaranteed iteration to fill it"
               (vl-refused-for? v 'trip-count-too-short))
  (check! "and it commits to no width" (vl-widths v) '()))

;; --- 2. the element-wise loop, and the premise ------------------------------

(printf "\nsaxpy, with and without the distinctness premise:\n")

(let ([v (only-verdict (elided (saxpy 35) flvec-facts) distinct-tbl)])
  (vl-report v)
  (check-true! "an element-wise loop over distinct arrays is VECTORIZABLE"
               (vl-legal? v))
  (check! "at every width, since 35 iterations fill 16 lanes"
          (vl-widths v) '(128 256 512 1024))
  (check! "reading and writing ONE array at the same index is element-wise"
          (vl-refused-for? v 'loop-carried-memory-dependence) #f))

;; THE MISCOMPILE THIS PASS EXISTS TO PREVENT. Same program, same trip count,
;; same discharged checks: only the premise is gone.
(let ([v (only-verdict (elided (saxpy 35) flvec-facts) may-tbl)])
  (vl-report v)
  (check! "without the premise the same loop is refused" (vl-legal? v) #f)
  (check-true! "because the arrays may alias" (vl-refused-for? v 'may-alias))
  (check! "and it commits to no width" (vl-widths v) '()))

;; And with no table at all, which is what a caller that did not run alias
;; analysis gets. The default is the safe direction.
(let ([v (only-verdict (elided (saxpy 35) flvec-facts) #f)])
  (check-true! "with no alias table every pair may alias"
               (vl-refused-for? v 'may-alias)))

;; --- 3. a check that survived -----------------------------------------------

(printf "\na bounds check still in the body:\n")

(let ([v (only-verdict (saxpy 35) distinct-tbl)])
  (vl-report v)
  (check! "the un-elided loop is refused" (vl-legal? v) #f)
  (check-true! "for a surviving check" (vl-refused-for? v 'surviving-check))
  (check-true! "and the bounds check is named among them"
               (exists (lambda (c) (and (eq? (car c) 'surviving-check)
                                        (eq? (cadr (cdr c)) 'bounds-check)))
                       (vl-cites v)))
  ;; fp-contract is in the same vocabulary and is NOT a check. It permits a
  ;; rewrite, it emits no branch, and refusing on it would refuse every flonum
  ;; kernel in the benchmark set.
  (check! "fp-contract is not counted as a surviving check"
          (exists (lambda (c) (and (eq? (car c) 'surviving-check)
                                   (eq? (cadr (cdr c)) 'fp-contract)))
                  (vl-cites v))
          #f))

;; --- 4. the reduction, and D24 ----------------------------------------------

(printf "\na loop-carried reduction:\n")

(let ([v (only-verdict (elided (reduction 35) '((b flvector 35))) distinct-tbl)])
  (vl-report v)
  (check! "a reduction is refused" (vl-legal? v) #f)
  (check-true! "and the reason is reassociation"
               (vl-refused-for? v 'reassociation-forbidden))
  ;; The trip count is exact and the checks are discharged, so nothing else is
  ;; standing in the way. The refusal is the decision, not a side effect.
  (check! "with an exact trip count and no other objection"
          (list (trip-kind (vl-trip v)) (vl-reasons v))
          '(exact (reassociation-forbidden)))
  (check-true! "the citation names the accumulator, its operator and D24"
               (exists (lambda (c)
                         (and (eq? (car c) 'reassociation-forbidden)
                              (equal? (cdr c) '(acc acc2 fl+ D24))))
                       (vl-cites v)))
  (check! "and it commits to no width" (vl-widths v) '()))

;; --- 5. an unknown trip count -----------------------------------------------

(printf "\nan unknown trip count:\n")

(let ([v (only-verdict (unknown-step) distinct-tbl)])
  (vl-report v)
  (check! "an unknown trip count is refused" (vl-legal? v) #f)
  (check! "and that is the only objection"
          (vl-reasons v) '(unknown-trip-count))
  ;; Larsen: applu goes from 22.56% vectorizable at 256 bits to 0.01% at 1024,
  ;; and the collapse is what a guessed count does to the lane choice. Unknown
  ;; stays unknown, and the reason (sonic loops) attached comes through.
  (check! "carrying the reason the loop pass gave"
          (cdr (assq 'unknown-trip-count (vl-cites v))) 'unknown-step)
  (check! "and no width is proposed" (vl-widths v) '()))

;; --- 6. a tagged element ----------------------------------------------------

(printf "\na tagged element type:\n")

(let ([v (only-verdict (elided (tagged-loop 35) '((v vector 35))) distinct-tbl)])
  (vl-report v)
  (check! "a general vector is refused" (vl-legal? v) #f)
  (check-true! "because its element is tagged" (vl-refused-for? v 'tagged-element))
  (check! "and repr.ss is the pass that said so"
          (vl-elt-class v) 'tagged)
  (check! "and it commits to no width" (vl-widths v) '()))

;; --- 7. a loop-carried memory dependence ------------------------------------

(printf "\na dependence through memory:\n")

(let ([v (only-verdict (elided (carried-memory 35) '((a flvector 35))) distinct-tbl)])
  (vl-report v)
  (check! "reading and writing one array at DIFFERENT indices is refused"
          (vl-legal? v) #f)
  (check-true! "as a loop-carried memory dependence"
               (vl-refused-for? v 'loop-carried-memory-dependence))
  ;; Not as an alias failure. `a` against `a` is one array and the question is
  ;; the distance between the two subscripts, which no alias analysis answers.
  (check! "and not as an aliasing failure" (vl-refused-for? v 'may-alias) #f))

;; --- a REAL program, which every fixture above is not -----------------------
;;
;; `each-expr` is an Lssa Expr walker whose `else` is `(void)`, so a whole Lssa
;; Program visited nothing and every query built on it came back empty. The
;; symptom was not silence: it was `loop-body-not-found` on all seven of
;; nbody's loops, which reads like a broken loop pass rather than like this
;; file never looking inside a `top`.
;;
;; A verdict of "not legal" is only worth having if the REASON is real. So this
;; asserts what the refusals are, not merely that they happen: a loop refused
;; for `loop-body-not-found` has been analysed by nobody.

(newline)
(printf "real programs, not fixtures:\n")

(define (real-ssa src externs)
  (let ((p (open-file-output-port "/tmp/sonic-veclegal-real.sps" (file-options no-fail)
                                  (buffer-mode block) (native-transcoder))))
    (put-string p src) (close-port p))
  (essa-program
   (inline-program
    (assign-convert-program
     (anf-program
      (resolve-policy-program
       (parse-program (expand-program (read-all-from-file "/tmp/sonic-veclegal-real.sps"))
                      externs)))))))

(let* ((src (let* ((p (open-file-input-port "../bench/nbody/config-sonic.sps"))
                   (bv (get-bytevector-all p)))
              (close-port p)
              (utf8->string bv)))
       ;; ELIDED, which is the IR the back end sees. One `elide-program` call
       ;; discharges 68 of nbody's 227 checks; this fixpoint discharges nearly
       ;; all of them, and a legality pass looking at the un-fixed IR refuses
       ;; every loop for checks the compiled program does not contain.
       (vs (let-values (((el st) (elide-to-fixpoint (real-ssa src nbody-externs))))
             (vectorize-legal el))))
  (check! "nbody yields a verdict per loop" (length vs) 7)
  (check! "and NONE of them is refused for a body this file could not find"
          (fold-left (lambda (a v) (or a (vl-refused-for? v 'loop-body-not-found)))
                     #f vs)
          #f)
  ;; What they ARE refused for, which is the analysis actually running. These
  ;; are the three that stand between nbody and milestone 4.
  ;; Every REFUSED loop gives a reason, and no legal one carries a stray reason
  ;; it was not actually refused for. Written over the refused set rather than
  ;; over all of them because a licensed loop has nothing to explain -- which
  ;; is how this check first failed, and it was right to.
  (check! "every refused loop gives at least one substantive reason"
          (fold-left (lambda (a v)
                       (and a (if (vl-legal? v) (null? (vl-reasons v))
                                  (pair? (vl-reasons v)))))
                     #t vs)
          #t)
  ;; THE WALK REACHES THE ARRAY ACCESSES, which is the thing a refusal for
  ;; `control-flow-in-body` prevented. essa wraps a loop's exit test in a phi
  ;; over its two arms, so what `strip-header` leaves looks like a diamond's
  ;; join; treating it as one refused all seven loops before the scan saw a
  ;; single subscript, and every verdict reported zero accesses.
  ;;
  ;; Zero accesses in a loop that indexes three vectors is not a conservative
  ;; answer, it is an absent one, and asserting the COUNT is what tells them
  ;; apart.
  (check! "the pairwise loop's array accesses are actually found"
          (let find ((xs vs))
            (cond ((null? xs) 0)
                  ((eq? (vl-loop (car xs)) 'inner%24.201) (length (vl-accesses (car xs))))
                  (else (find (cdr xs)))))
          20)
  (check! "and it is no longer refused for control flow it does not have"
          (let find ((xs vs))
            (cond ((null? xs) #f)
                  ((eq? (vl-loop (car xs)) 'inner%24.201)
                   (vl-refused-for? (car xs) 'control-flow-in-body))
                  (else (find (cdr xs)))))
          #f)
  ;; The two outer loops are bounded by `n-bodies`, which is 5, and (sonic
  ;; loops) now proves it exactly -- so neither is refused for its trip count
  ;; any more and `control-flow-in-body` is all that stands between them and a
  ;; verdict.
  (check! "the loops bounded by n-bodies are no longer refused for their count"
          (let loop ((xs vs) (n 0))
            (cond ((null? xs) n)
                  ((memq (vl-loop (car xs)) '(outer%22.193 loop%35.293))
                   (loop (cdr xs)
                         (if (vl-refused-for? (car xs) 'unknown-trip-count) n (+ n 1))))
                  (else (loop (cdr xs) n))))
          2)
  ;; THE INNER LOOP IS TOO SHORT, and that is a fact about nbody rather than a
  ;; gap in the analysis. Its counter starts at i+1, so over five bodies it runs
  ;; 4, 3, 2, 1 and 0 times. A 512-bit vector holds eight doubles. There is no
  ;; unroll factor that pays, and saying so is the right answer -- guessing one
  ;; is the failure mode this whole pass exists to avoid.
  ;;
  ;; It matters for milestone 4: the axis worth vectorizing in nbody is not j.
  ;; THE FIRST LOOP THIS COMPILER HAS EVER LICENSED.
  ;;
  ;; nbody's position update, `p[3i+k] += dt * v[3i+k]` over three components.
  ;; Getting here needed four separate things to be true at once, and each was
  ;; false: the loop had to be FOUND, its body REACHED, its checks discharged
  ;; by the same fixpoint the back end uses, its arrays known distinct, and its
  ;; subscripts compared by affine form rather than by name.
  ;;
  ;; Asserted with the widths, because "legal" without a width is not an answer
  ;; a back end can use, and because a width above what the trip count supports
  ;; is the specific failure veclegal's header is written against.
  (check! "nbody's position update is LEGAL to vectorize, at 128 and 256 bits"
          (let find ((xs vs))
            (cond ((null? xs) #f)
                  ((eq? (vl-loop (car xs)) 'loop%35.293)
                   (list (vl-legal? (car xs)) (vl-widths (car xs))
                         (vl-elt-class (car xs))))
                  (else (find (cdr xs)))))
          '(#t (128 256) raw-f64))
  (check! "and the inner loop is refused for being SHORT, not for being unknown"
          (let loop ((xs vs))
            (cond ((null? xs) #f)
                  ((eq? (vl-loop (car xs)) 'inner%24.201)
                   (and (vl-refused-for? (car xs) 'trip-count-too-short)
                        (not (vl-refused-for? (car xs) 'unknown-trip-count))))
                  (else (loop (cdr xs)))))
          #t))

(newline)
(printf "~a checks, ~a failures\n" checks failures)
(if (> failures 0) (begin (printf "FAIL\n") (exit 1)) (begin (printf "PASS\n") (exit 0)))
