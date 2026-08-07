;;; Tests for the check elision pass.
;;;
;;; The pass has one output that matters and one that must never happen. The
;;; output that matters is a `checked` control turned into `proved`. The thing
;;; that must never happen is an `unchecked` control appearing where the input
;;; did not have one: `unchecked` means a policy suppressed the check and
;;; `proved` means we discharged it, lower.ss counts them apart, and the number
;;; this project exists to produce is the second one. Laundering a permission
;;; into a proof would corrupt the headline result while leaving every test
;;; that only counts eliminations green, so there is an explicit test for it.
;;;
;;; The refusals carry the same weight as the eliminations. Leaving a check
;;; that could have gone costs instructions; removing one that was needed
;;; corrupts memory.
;;;
;;; Fixtures are hand-written Lssa for the reason loops-test.ss gives, and
;;; nbody's access is the frozen one from (sonic fixtures) spliced in rather
;;; than a copy.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/elide-test.ss

(import (chezscheme) (nanopass) (sonic lang) (sonic interval)
        (sonic fixtures) (sonic elide))

(define failures 0)
(define checks 0)

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

;; --- reading the answer out of a rewritten term -----------------------------

;; Every control in the term, as (check prim control), in source order.
(define (controls s)
  (cond
    [(and (pair? s) (eq? (car s) 'primcall) (pair? (cdr s)) (pair? (cddr s)))
     (append (map (lambda (c) (list (car c) (cadr s) (cadr c))) (caddr s))
             (apply append (map controls (cdddr s))))]
    [(pair? s) (append (controls (car s)) (controls (cdr s)))]
    [else '()]))

;; The term with every control list emptied. Two terms equal under this are the
;; same program: the pass is only allowed to move controls, and anything else
;; it changed is a miscompile no count would reveal.
(define (strip s)
  (cond
    [(and (pair? s) (eq? (car s) 'primcall) (pair? (cdr s)) (pair? (cddr s)))
     (cons* 'primcall (cadr s) '() (map strip (cdddr s)))]
    [(pair? s) (cons (strip (car s)) (strip (cdr s)))]
    [else s]))

;; Run the pass and hand back everything a test might assert on.
(define (run term facts)
  (let-values ([(out st) (elide term facts)])
    (values (unparse-Lssa out) st)))

(define (structure-preserved? term facts)
  (let-values ([(out st) (run term facts)])
    (equal? (strip out) (strip (unparse-Lssa term)))))

;; --- fixtures ---------------------------------------------------------------

;; The paper's motivating shape, with a second access the first dominates.
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

;; A loop-carried index against a separate bound. `bound` is the entry value of
;; n, so the same shape serves the provable and the refused case.
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

(define (bounded-loop lim)
  (with-output-language (Lssa Expr)
    `(let ([lim (quote ,lim)]) ,(loop-with-bound 'lim))))

;; The same loop with the bound growing on the back edge.
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

;; Two accesses at the same index, nothing known about either. The first must
;; keep its check; the second is redundant because the first dominates it.
(define (dominated-pair)
  (with-output-language (Lssa Expr)
    `(let ([v1 (primcall flvector-ref ([type-check checked] [bounds-check checked])
                         b idx)])
       (let ([v2 (primcall flvector-ref ([type-check checked] [bounds-check checked])
                           b idx)])
         v2))))

;; The same two accesses, but the second is inside one arm of a conditional the
;; first does not dominate. Nothing may be carried across.
(define (undominated-pair)
  (with-output-language (Lssa Expr)
    `(let ([t (primcall fx< () idx len)])
       (if t
           (let ([v1 (primcall flvector-ref ([type-check checked] [bounds-check checked])
                               b idx)])
             v1)
           (let ([v2 (primcall flvector-ref ([type-check checked] [bounds-check checked])
                               b idx)])
             v2)))))

;; --- 1. nbody's inner loop, the program this project is measured on ---------

(printf "nbody's inner loop:\n")

;; `i`, `n`, `k`, `seven` and `b` are free in the fixture, which is what an
;; inner loop looks like when its enclosing scope is somewhere else. The facts
;; are that scope. Note what is NOT stated: `i` has no upper bound. The bound
;; on the index comes from the guard, through sigma, which is stage 06 earning
;; its place.
(define nbody-facts
  '((b flvector 35)
    (i interval 0 posinf)
    (n interval 5 5)
    (k interval 0 6)
    (seven interval 7 7)))

(let-values ([(out st) (run (nbody-inner-ssa) nbody-facts)])
  (check! "every check in the access is discharged"
          (controls out)
          '((overflow-check fx* proved)
            (overflow-check fx+ proved)
            (type-check flvector-ref proved)
            (bounds-check flvector-ref proved)))
  (check! "four proved, none kept" (list (elide-proved st) (elide-kept st)) '(4 0))
  (check! "the bounds check went by the interval domain, not by ABCD"
          (map elide-site-why (elide-proved-by st 'bounds-check)) '(interval))
  (check! "and the pass changed nothing but the controls"
          (structure-preserved? (nbody-inner-ssa) nbody-facts) #t))

;; The refusal that proves the fixture above is not proving itself. One element
;; short and the same index no longer fits.
(let-values ([(out st) (run (nbody-inner-ssa)
                            '((b flvector 34)
                              (i interval 0 posinf) (n interval 5 5)
                              (k interval 0 6) (seven interval 7 7)))])
  (check! "a vector one element too short refuses the bounds check"
          (assq 'bounds-check
                (map (lambda (c) (cons (car c) (caddr c))) (controls out)))
          '(bounds-check . checked)))

;; --- 2. the paper's motivating example --------------------------------------

(printf "\nthe paper's motivating example:\n")

;; `b` is stated to be an flvector, and its LENGTH is deliberately not stated:
;; the program computes it with flvector-length, and the whole point of the
;; example is that the guard ties the index to that symbolic length. If the
;; length were given here the interval domain would answer and ABCD would not
;; be under test.
(let-values ([(out st) (run (paper-example) '((b flvector)))])
  (check! "both bounds checks are removed"
          (map caddr (filter (lambda (c) (eq? (car c) 'bounds-check)) (controls out)))
          '(proved proved))
  (check! "the first by ABCD, from the guard edge"
          (map elide-site-why (elide-proved-by st 'bounds-check))
          '(abcd dominating-check))
  (check! "the type checks go too, from the premise"
          (map caddr (filter (lambda (c) (eq? (car c) 'type-check)) (controls out)))
          '(proved proved proved))
  (check! "the increment's overflow check is NOT claimed"
          (map caddr (filter (lambda (c) (eq? (car c) 'overflow-check)) (controls out)))
          '(checked))
  (check! "structure preserved" (structure-preserved? (paper-example) '((b flvector))) #t))

;; --- 3. a loop-carried index proven in range --------------------------------

(printf "\na loop-carried index against an invariant bound:\n")

(let-values ([(out st) (run (bounded-loop 35) '((b flvector 35)))])
  (check! "the index is proved in range"
          (map caddr (filter (lambda (c) (eq? (car c) 'bounds-check)) (controls out)))
          '(proved))
  (check! "by ABCD, since no interval reaches inside a loop here"
          (map elide-site-why (elide-proved-by st 'bounds-check)) '(abcd)))

;; --- 4. what must be refused ------------------------------------------------

(printf "\nwhat must be refused:\n")

(define (bounds-controls out)
  (map caddr (filter (lambda (c) (eq? (car c) 'bounds-check)) (controls out))))

(let-values ([(out st) (run (loop-with-bound 'm) '((b flvector 35)))])
  (check! "an index bounded by something unknown is refused"
          (bounds-controls out) '(checked)))

(let-values ([(out st) (run (bounded-loop 36) '((b flvector 35)))])
  (check! "a bound one past the end is refused" (bounds-controls out) '(checked)))

(let-values ([(out st) (run (growing-bound) '((b flvector 35)))])
  (check! "a bound that is not loop-invariant is refused"
          (bounds-controls out) '(checked))
  ;; The type check on `b` still goes, from the premise. What must NOT happen
  ;; is a bounds check being credited to make the count look better.
  (check! "and no bounds check is credited anywhere in it"
          (length (elide-proved-by st 'bounds-check)) 0))

(let-values ([(out st) (run (undominated-pair) '())])
  (check! "a check in the other arm of a conditional does not dominate"
          (bounds-controls out) '(checked checked)))

;; --- 5. a check that already ran is a fact ----------------------------------

(printf "\nredundancy against a dominating check:\n")

(let-values ([(out st) (run (dominated-pair) '())])
  (check! "the first access keeps both checks, the second keeps neither"
          (controls out)
          '((type-check flvector-ref checked)
            (bounds-check flvector-ref checked)
            (type-check flvector-ref proved)
            (bounds-check flvector-ref proved)))
  (check! "and the reason is recorded as the dominating check"
          (map elide-site-why (elide-proved-by st 'bounds-check))
          '(dominating-check)))

;; --- 6. the rule that must never be broken ----------------------------------

(printf "\nproved is not unchecked:\n")

;; A policy already suppressed this bounds check, and the index is one the pass
;; could prove. It must still come out `unchecked`: the programmer switched it
;; off, we did not prove it away, and the two numbers are not interchangeable.
(define (suppressed)
  (with-output-language (Lssa Expr)
    `(let ([v (primcall flvector-ref ([type-check checked] [bounds-check unchecked])
                        b idx)])
       v)))

(let-values ([(out st) (run (suppressed) '((b flvector 35) (idx interval 0 3)))])
  (check! "a suppressed check stays suppressed"
          (bounds-controls out) '(unchecked))
  (check! "and is counted as a permission, never as a proof"
          (list (elide-proved st) (elide-unchecked st)) '(1 1))
  (check! "the proof it is credited with is the type check, not the bounds check"
          (map elide-site-check (elide-proved-by st 'type-check)) '(type-check)))

;; The general form of the same rule, over every fixture in this file: no
;; control anywhere in any output may be `unchecked` unless the input said so.
(let ([terms (list (nbody-inner-ssa) (paper-example) (bounded-loop 35)
                   (growing-bound) (dominated-pair) (undominated-pair))]
      [facts (list nbody-facts '((b flvector)) '((b flvector 35))
                   '((b flvector 35)) '() '())])
  (check! "no fixture gains an unchecked control"
          (map (lambda (term f)
                 (let-values ([(out st) (run term f)])
                   (length (filter (lambda (c) (eq? (caddr c) 'unchecked)) (controls out)))))
               terms facts)
          '(0 0 0 0 0 0))
  (check! "and none of them is structurally changed"
          (map structure-preserved? terms facts)
          '(#t #t #t #t #t #t)))

;; --- 7. the report ----------------------------------------------------------
;;
;; ABCD removed 45% of bounds checks for about 10% speedup, because nothing
;; downstream consumed the freedom. So the deliverable is WHICH checks went and
;; not how many; a count alone cannot be handed to stage 10.

(printf "\nnbody's inner loop, in full:\n")
(let-values ([(out st) (run (nbody-inner-ssa) nbody-facts)])
  (elide-report st))

(printf "\n~a checks, ~a failures\n" checks failures)
(if (> failures 0) (exit 1) (begin (printf "PASS\n") (exit 0)))
