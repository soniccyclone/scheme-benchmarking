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

;; (sigma x0 x1 pr x2 body) -> (x0-base x1-base pr x2-base)
(define (sigma-shapes s)
  (map (lambda (g)
         (list (base (cadr g)) (base (caddr g)) (cadddr g) (base (car (cddddr g)))))
       (collect 'sigma s)))

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
  (check! "the merged value is the conditional itself"
          (car (cadr (car (cadr (car (collect 'phi out))))))
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
  (check! "the header phi's operands are the parameters, in order"
          (map cadr (cadr hdr)) (cadr lam))
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
          '((i i fx<  n)      ; true:  i is the i that is < n
            (n n fx>  i)      ; true:  n is the n that is > i
            (i i fx>= n)      ; false: i is the i that is >= n
            (n n fx<= i)))    ; false: n is the n that is <= i
  (check! "definitions are uniquely named" (all-distinct? (binders out)) #t)
  ;; The second sigma on an edge refers to the first one's OUTPUT, which is
  ;; what makes the pair of constraints mutually refining rather than two
  ;; independent facts about the pre-branch values.
  (check! "the second sigma of an edge refines against the first's output"
          (let ([sig (collect 'sigma out)])
            (equal? (list-ref (car sig) 5)                 ; body of sigma 1
                    (cadr sig)))                           ; is sigma 2
          #t)
  (check! "sigma 2's other operand is sigma 1's output"
          (list-ref (cadr (collect 'sigma out)) 4)
          (cadr (car (collect 'sigma out)))))

;; The remaining fixnum comparisons, so the negation table is exercised rather
;; than assumed. `fx=` has no false-edge spelling: the primitive table has no
;; disequality, so that edge carries no sigma at all.
(define (edge-facts pr)
  (sigma-shapes (run (with-output-language (Lanf Expr)
                       `(let ([c (primcall ,pr () i n)]) (if c i n))))))

(check! "fx<= negates to fx>" (edge-facts 'fx<=)
        '((i i fx<= n) (n n fx>= i) (i i fx> n) (n n fx< i)))
(check! "fx>= negates to fx<" (edge-facts 'fx>=)
        '((i i fx>= n) (n n fx<= i) (i i fx< n) (n n fx> i)))
(check! "fx> negates to fx<=" (edge-facts 'fx>)
        '((i i fx> n) (n n fx< i) (i i fx<= n) (n n fx>= i)))
(check! "fx= splits the true edge only: there is no fx<> to spell the other"
        (edge-facts 'fx=)
        '((i i fx= n) (n n fx= i)))

;; NaN. lang.ss states it at the fl< entry and it lands here: (not (fl< a b))
;; is TRUE when either operand is NaN, where (fl>= a b) is false. So the false
;; edge of a flonum test is not expressible as a comparison primitive and this
;; pass emits nothing there rather than asserting an ordering that does not
;; hold. The true edge is fine, because a comparison that succeeded had no NaN.
(check! "flonum branches split the true edge only, because of NaN"
        (edge-facts 'fl<)
        '((i i fl< n) (n n fl> i)))

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
          (sigma-shapes out) '((i i fx< i) (i i fx>= i))))

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
          '((n n fx> i) (n n fx<= i))))

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
