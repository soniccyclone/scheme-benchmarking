;;; Tests for ABCD: the inequality graph and the demand-driven query.
;;;
;;; The assertions here are about ANSWERS. An analysis that says yes to
;;; everything is not an analysis, so the cases that must be REFUSED carry the
;;; same weight as the ones that must be proved, and there are as many of them.
;;;
;;; WHY THE FIXTURES ARE HAND-WRITTEN Lssa. Same reason loops-test.ss gives: a
;;; stage-07 test that ran stage 06 to get its input would depend on the PASS
;;; rather than on the frozen contract, which is what EXECUTION.md section 1
;;; forbids. Where a fixture already exists in (sonic fixtures) it is used
;;; verbatim rather than copied -- `nbody-inner-ssa` appears below as itself.
;;;
;;; THE LAST SECTION IS THE CROSS-CHECK. CUJ.md records that ABCD's
;;; amplifying-cycle detection supplies induction-variable discrimination for
;;; free. Free is not the same as right, so the two analyses are run over the
;;; same term and compared, and a disagreement is REPORTED rather than resolved
;;; by preferring whichever one was written more recently.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/abcd-test.ss

(import (chezscheme) (nanopass) (sonic lang) (sonic interval)
        (sonic fixtures) (sonic abcd) (sonic loops)
        (sonic read) (sonic expand) (sonic parse) (sonic policy)
        (sonic anf) (sonic assign) (sonic inline) (sonic essa) (sonic pipeline))

(define failures 0)
(define checks 0)

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

;; --- fixtures ---------------------------------------------------------------

;; THE PAPER'S MOTIVATING SHAPE. An array traversal whose index is loop-carried
;; and bounded only by the exit test, with a second access the first dominates.
;;
;;     i = 0
;;     while (i < a.length) { ... a[i] ... a[i] ...; i = i + 1 }
;;
;; This is what ABCD is for and what a forward interval domain cannot do
;; without widening then narrowing: `i` on the back edge is `i + 1` with no
;; constant bound anywhere, and the only thing that ties it to the length is
;; the guard. The graph ties them in one edge.
(define (paper-example)
  (with-output-language (Lssa Expr)
    `(let ([len (primcall flvector-length ([type-check checked]) b)])
       (let ([z (quote 0)])
         (letrec ([loop
                   (lambda (ip)
                     (phi ([i (entry ip)])
                       (let ([t (primcall fx< () i len)])
                         (if t
                             (sigma ig i fx< len #f
                               (let ([v1 (primcall flvector-ref
                                                   ([type-check checked]
                                                    [bounds-check checked])
                                                   b ig)])
                                 (let ([v2 (primcall flvector-ref
                                                     ([type-check checked]
                                                      [bounds-check checked])
                                                     b ig)])
                                   (let ([one (quote 1)])
                                     (let ([inx (primcall fx+ ([overflow-check checked])
                                                          ig one)])
                                       (tailcall loop inx))))))
                             (quote 0)))))])
           (tailcall loop z))))))

;; A loop-carried index against a SEPARATE bound, where the bound is invariant
;; and the length is known. The chain is longer than the paper example's: the
;; index is bounded by n, n is a phi of a constant and of itself, and only then
;; does the constant meet the length.
;;
;; `bound` is the entry value of n. Passing it in lets the same shape serve as
;; the provable case (35, equal to the length) and the refused case (a free
;; variable, so nothing is known).
(define (loop-with-bound bound)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (letrec ([loop
                 (lambda (ip np)
                   (phi ([i (entry ip)] [n (entry np)])
                     (let ([t (primcall fx< () i n)])
                       (if t
                           (sigma i2 i fx< n #f
                             (sigma n2 n fx> i2 #f
                               (let ([v (primcall flvector-ref
                                                  ([type-check checked]
                                                   [bounds-check checked])
                                                  b i2)])
                                 (let ([one (quote 1)])
                                   (let ([inx (primcall fx+ ([overflow-check checked])
                                                        i2 one)])
                                     (tailcall loop inx n2))))))
                           (quote 0)))))])
         (tailcall loop z ,bound)))))

;; The same loop with the bound GROWING on the back edge. The index is still
;; guarded by `i < n`, so the guard edge is there and looks identical; what
;; fails is the second half, proving n stays under the length. n's cycle is
;; amplifying, and that is exactly the fact that must refuse this.
(define (growing-bound)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (let ([lim (quote 35)])
         (letrec ([loop
                   (lambda (ip np)
                     (phi ([i (entry ip)] [n (entry np)])
                       (let ([t (primcall fx< () i n)])
                         (if t
                             (sigma i2 i fx< n #f
                               (sigma n2 n fx> i2 #f
                                 (let ([v (primcall flvector-ref
                                                    ([type-check checked]
                                                     [bounds-check checked])
                                                    b i2)])
                                   (let ([one (quote 1)])
                                     (let ([inx (primcall fx+ ([overflow-check checked])
                                                          i2 one)])
                                       (let ([nnx (primcall fx+ ([overflow-check checked])
                                                            n2 one)])
                                         (tailcall loop inx nnx)))))))
                             (quote 0)))))])
           (tailcall loop z lim))))))

;; A countdown, for the other sign of the cycle weight.
(define (countdown)
  (with-output-language (Lssa Expr)
    `(let ([start (quote 34)])
       (let ([z (quote 0)])
         (letrec ([loop
                   (lambda (jp)
                     (phi ([j (entry jp)])
                       (let ([t (primcall fx>= () j z)])
                         (if t
                             (sigma j2 j fx>= z #f
                               (let ([one (quote 1)])
                                 (let ([jn (primcall fx- ([overflow-check checked])
                                                     j2 one)])
                                   (tailcall loop jn))))
                             (quote 0)))))])
           (tailcall loop start))))))

;; --- 1. the paper's motivating example --------------------------------------

(printf "the paper's motivating example:\n")

(let ([g (build-inequality-graph (paper-example))])
  (check! "the guard is one edge in the graph: ig <= len - 1"
          (assq 'len (abcd-edges g 'up 'ig)) '(len . -1))
  (check! "and nothing flows back to the unrefined name"
          (assq 'ig (abcd-edges g 'up 'i)) #f)
  (check! "the loop header is a meet vertex" (abcd-phi-vertex? g 'i) #t)
  (check! "so is the parameter it merges" (abcd-phi-vertex? g 'ip) #t)
  (check! "the index is in bounds for the length it was guarded against"
          (abcd-in-bounds? g 'ig (abcd-length-vertex 'b)) #t)
  (check! "upper half: proved outright from the guard edge"
          (abcd-prove g 'up (abcd-length-vertex 'b) 'ig -1) 'true)
  (check! "lower half: proved through a REDUCING cycle, not outright"
          (abcd-prove g 'lo abcd-zero 'ig 0) 'reduced)
  ;; The unguarded name is the control. If the graph proved THIS the sigma
  ;; would be doing nothing and the whole of stage 06 would be waste.
  (check! "the pre-guard index is NOT in bounds"
          (abcd-in-bounds? g 'i (abcd-length-vertex 'b)) #f))

;; --- 2. a loop-carried index proven in range --------------------------------

(printf "\na loop-carried index against an invariant bound:\n")

(let ([g (build-inequality-graph (loop-with-bound 'lim)
                                 '((b . 35)))])
  ;; `lim` is free here, so the bound is unknown and the answer must be no.
  (check! "an unknown entry bound proves nothing"
          (abcd-in-bounds? g 'i2 35) #f))

(let* ([e (with-output-language (Lssa Expr)
            `(let ([lim (quote 35)]) ,(loop-with-bound 'lim)))]
       [g (build-inequality-graph e '((b . 35)))])
  (check! "with the bound bound to the length, the index is in range"
          (abcd-in-bounds? g 'i2 35) #t)
  (check! "the bound itself is proved invariant under 35"
          (abcd-prove g 'up abcd-zero 'n 35) 'true)
  (check! "and the index's lower half still comes from the reducing cycle"
          (abcd-prove g 'lo abcd-zero 'i2 0) 'reduced))

;; --- 3. refusals ------------------------------------------------------------

(printf "\nwhat must be refused:\n")

(let* ([e (with-output-language (Lssa Expr)
            `(let ([lim (quote 36)]) ,(loop-with-bound 'lim)))]
       [g (build-inequality-graph e '((b . 35)))])
  (check! "a bound one past the end is refused"
          (abcd-in-bounds? g 'i2 35) #f))

(let ([g (build-inequality-graph (growing-bound) '((b . 35)))])
  (check! "a bound that is not loop-invariant is refused"
          (abcd-in-bounds? g 'i2 35) #f)
  (check! "because its cycle amplifies"
          (abcd-prove g 'up abcd-zero 'n 35) 'false)
  ;; The guard edge is still there; it is the second half of the chain that
  ;; fails. Asserting this keeps the refusal honest rather than accidental.
  (check! "even though the guard edge is present"
          (assq 'n (abcd-edges g 'up 'i2)) '(n . -1)))

(let ([g (build-inequality-graph (paper-example))])
  ;; No length fact and no flvector-length for a DIFFERENT array, so the
  ;; length vertex has no edges at all.
  (check! "an index against a vector we know nothing about is refused"
          (abcd-in-bounds? g 'ig (abcd-length-vertex 'other)) #f))

;; nbody's index is a product, and a product is not a difference constraint.
;; ABCD must say no here; (sonic elide) gets it from the interval domain
;; instead. Pinning the limit stops it being rediscovered as a bug.
(let ([g (build-inequality-graph (nbody-inner-ssa) '((b . 35)))])
  (check! "a multiplied index is outside the constraint language"
          (abcd-in-bounds? g 'idx 35) #f)
  (check! "though the guard on the multiplicand is still recorded"
          (assq 'n (abcd-edges g 'up 'i2)) '(n . -1)))

;; --- 4. the free lunch: induction variables ---------------------------------

(printf "\ninduction variables from amplifying cycles:\n")

(define (iv-summary g)
  (list-sort (lambda (a b) (string<? (symbol->string (car a)) (symbol->string (car b))))
             (map (lambda (v) (list (abcd-iv-name v) (abcd-iv-step v)))
                  (abcd-ivs g))))

(let ([g (build-inequality-graph (paper-example))])
  (check! "an increment of one is a cycle of weight one"
          (iv-summary g) '((i 1) (ip 1))))

(let ([g (build-inequality-graph (countdown))])
  (check! "a decrement is the same cycle with the other sign"
          (iv-summary g) '((j -1) (jp -1))))

(let* ([e (with-output-language (Lssa Expr)
            `(let ([lim (quote 35)]) ,(loop-with-bound 'lim)))]
       [g (build-inequality-graph e '((b . 35)))])
  (check! "an invariant phi has cycles of weight zero, so it is not an IV step"
          (iv-summary g) '((i 1) (ip 1) (n 0) (np 0))))

;; --- 5. the cross-check against (sonic loops) -------------------------------
;;
;; Two independent derivations of the same fact. Where they disagree the test
;; FAILS rather than picking one, because a silent disagreement between two
;; analyses that both feed check elision is the failure mode that produces
;; wrong code rather than slow code.

(printf "\ncross-check against loops.ss:\n")

;; Returns a list of (loop iv-name loops-step abcd-step) for every basic
;; induction variable loops.ss found, so a disagreement prints both answers.
(define (compare-ivs term)
  (let* ([g (build-inequality-graph term)]
         [ivs (abcd-ivs g)])
    (apply append
      (map (lambda (l)
             (map (lambda (v)
                    (let ([a (abcd-iv-ref ivs (iv-name v))])
                      (list (loop-name l) (iv-name v)
                            (iv-step v)
                            (and a (abcd-iv-step a)))))
                  (filter (lambda (v) (eq? (iv-kind v) 'basic)) (loop-ivs l))))
           (analyze-loops term)))))

(define (agree? row) (equal? (caddr row) (cadddr row)))

(let ([rows (compare-ivs (paper-example))])
  (check! "loops.ss finds one basic IV in the paper example" (length rows) 1)
  (check! "and ABCD gives it the same step" (map agree? rows) '(#t))
  (check! "which is +1" (map caddr rows) '(1)))

(let ([rows (compare-ivs (countdown))])
  (check! "a countdown agrees too" (map agree? rows) '(#t))
  (check! "at -1" (map caddr rows) '(-1)))

(let* ([e (with-output-language (Lssa Expr)
            `(let ([lim (quote 35)]) ,(loop-with-bound 'lim)))]
       [rows (compare-ivs e)])
  (check! "the two-parameter loop has one basic IV and both agree"
          (map agree? rows) '(#t))
  (check! "the invariant parameter is not reported as a basic IV by either"
          (map cadr rows) '(i)))

(let ([rows (compare-ivs (growing-bound))])
  ;; Both bound and index step by one here, so both are basic IVs and both
  ;; analyses have to say so.
  (check! "a growing bound is an induction variable to both analyses"
          (map agree? rows) '(#t #t))
  (check! "with steps of one apiece" (map caddr rows) '(1 1)))

;; The structural difference, stated rather than hidden. loops.ss reports
;; DERIVED induction variables (nbody's off = i*7 and idx = off + k); ABCD
;; cannot, because a product is not a difference constraint. This is not a
;; disagreement about a shared answer, it is one analysis answering a question
;; the other cannot ask, and CUJ.md's "stage 07 shrinks but does not vanish" is
;; exactly this line.
(let* ([e (with-output-language (Lssa Expr)
            `(let ([seven (quote 7)])
               (let ([z (quote 0)])
                 (letrec ([loop
                           (lambda (ip)
                             (phi ([i (entry ip)])
                               (let ([t (primcall fx< () i seven)])
                                 (if t
                                     (sigma i2 i fx< seven #f
                                       (let ([off (primcall fx* ([overflow-check checked])
                                                            i2 seven)])
                                         (let ([one (quote 1)])
                                           (let ([inx (primcall fx+ ([overflow-check checked])
                                                                i2 one)])
                                             (tailcall loop inx)))))
                                     (quote 0)))))])
                   (tailcall loop z)))))]
       [g (build-inequality-graph e)]
       [ls (analyze-loops e)]
       [derived (apply append
                  (map (lambda (l)
                         (map iv-name
                              (filter (lambda (v) (eq? (iv-kind v) 'derived)) (loop-ivs l))))
                       ls))])
  (check! "loops.ss finds the multiplied index as a derived IV"
          (and (memq 'off derived) #t) #t)
  (check! "ABCD does not, and must not claim to"
          (abcd-iv-ref (abcd-ivs g) 'off) #f)
  (check! "the basic IV underneath it still agrees"
          (map agree? (compare-ivs e)) '(#t)))

;; --- a REAL program, which every fixture above is not -----------------------
;;
;; `walk` is a `nanopass-case` over Lssa Expr and the pipeline hands an Lssa
;; Program. It matched nothing, so the graph came out with two vertices -- the
;; constants -- and no induction variables, for a benchmark with seven loops.
;;
;; That failure is particularly hard to see from the outside. An empty graph
;; proves nothing, and proving nothing is a legitimate answer here, so the
;; result reads as conservatism rather than as a walk that never happened. The
;; only way to tell them apart is to assert that the graph has CONTENT for a
;; program known to have some.

(printf "\nreal programs, not fixtures:\n")

(let* ((src (let* ((p (open-file-input-port "../bench/nbody/config-sonic.sps"))
                   (bv (get-bytevector-all p)))
              (close-port p)
              (utf8->string bv)))
       (_ (let ((o (open-file-output-port "/tmp/sonic-abcd-real.sps" (file-options no-fail)
                                          (buffer-mode block) (native-transcoder))))
            (put-string o src) (close-port o)))
       (ssa (essa-program
             (inline-program
              (assign-convert-program
               (anf-program
                (resolve-policy-program
                 (parse-program (expand-program (read-all-from-file "/tmp/sonic-abcd-real.sps"))
                                nbody-externs)))))))
       (g (build-inequality-graph ssa)))
  (check! "nbody's inequality graph has more than the two constant vertices"
          (> (length (abcd-vertices g)) 2) #t)
  ;; Seven loops, each with at least a counter. Zero would mean the graph was
  ;; built from a walk that visited nothing.
  (check! "and its loop counters are recognised as induction variables"
          (> (length (abcd-ivs g)) 0) #t)
  (check! "each stepping by a known amount"
          (for-all (lambda (iv) (integer? (abcd-iv-step iv))) (abcd-ivs g)) #t))

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
