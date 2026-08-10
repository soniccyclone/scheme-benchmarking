;;; SonicScheme: the interval abstract domain.
;;;
;;; Stage 06. This is the crux of the whole project, and phase 3 is why.
;;;
;;; Measured: holding storage constant and flipping only Chez's check policy is
;;; a 4.77x difference, while unboxing with checks on is 1.12x. And predicate
;;; guards at optimize-level 2 recover NOTHING, because cptypes had already
;;; narrowed the types unaided. So the entire residual is bounds checking, and
;;; bounds checking is what a level-1 category lattice cannot reason about:
;;; cptypes-lattice.ss collapses index, length and sub-index into fixnum-pred,
;;; so `i is in [0,35)` is not a representable fact.
;;;
;;; This file makes it representable. Level 2 in the Cousot hierarchy.
;;;
;;; Reference: Cousot & Cousot, POPL 1977, section 7 for the domain itself and
;;; the widening; the Galois ADJUNCTION is POPL 1979, not 1977, and 1977 has a
;;; Galois *insertion*.

(library (sonic interval)
  (export make-interval interval-lo interval-hi interval?
          iv-top iv-bot iv-bot? iv-top?
          iv-const iv-range
          iv-join iv-meet iv-leq
          iv-add iv-sub iv-mul iv-neg
          iv-widen iv-narrow
          iv-lt-refine iv-le-refine iv-ge-refine
          iv-comparison? iv-edge-cmp iv-refine
          iv-within? iv->string)
  (import (rnrs base)
          (rnrs lists)
          (rnrs control)
          (rnrs records syntactic)
          (rnrs io simple))

  ;; Bounds are exact integers, or the symbols -inf and +inf. Exact integers
  ;; rather than flonums on purpose: an index domain that cannot represent a
  ;; bound exactly is not sound, and Scheme gives us bignums for free.
  (define-record-type (interval make-interval interval?) (fields lo hi))

  (define (inf- ) 'neginf)
  (define (inf+ ) 'posinf)
  (define (neg-inf? x) (eq? x 'neginf))
  (define (pos-inf? x) (eq? x 'posinf))

  ;; Bottom is the empty interval. It is represented as [+inf, -inf], which is
  ;; the standard trick: any lo > hi is empty, and this one is canonical.
  ;; Bottom is [posinf, neginf]: any lo > hi is empty, and this is canonical.
  (define iv-bot (make-interval 'posinf 'neginf))
  (define iv-top (make-interval 'neginf 'posinf))

  (define (iv-bot? a)
    (let ((lo (interval-lo a)) (hi (interval-hi a)))
      (cond ((or (neg-inf? lo) (pos-inf? hi)) #f)
            ((pos-inf? lo) #t)
            ((neg-inf? hi) #t)
            (else (> lo hi)))))

  (define (iv-top? a)
    (and (neg-inf? (interval-lo a)) (pos-inf? (interval-hi a))))

  (define (iv-const n) (make-interval n n))
  (define (iv-range lo hi) (make-interval lo hi))

  ;; --- bound arithmetic ----------------------------------------------------
  ;; Kept separate from the interval operations because the infinity cases are
  ;; where sign errors hide, and they are easier to test in isolation.

  (define (b<= x y)
    (cond ((neg-inf? x) #t)
          ((pos-inf? y) #t)
          ((pos-inf? x) (pos-inf? y))
          ((neg-inf? y) (neg-inf? x))
          (else (<= x y))))

  (define (bmin x y) (if (b<= x y) x y))
  (define (bmax x y) (if (b<= x y) y x))

  (define (b+ x y)
    (cond ((or (neg-inf? x) (neg-inf? y)) 'neginf)
          ((or (pos-inf? x) (pos-inf? y)) 'posinf)
          (else (+ x y))))

  (define (bneg x)
    (cond ((neg-inf? x) 'posinf) ((pos-inf? x) 'neginf) (else (- x))))

  (define (b* x y)
    (cond ((and (number? x) (zero? x)) 0)      ; 0 * inf is 0 here, not NaN:
          ((and (number? y) (zero? y)) 0)      ; the concrete product is always 0
          ((or (neg-inf? x) (pos-inf? x) (neg-inf? y) (pos-inf? y))
           (let ((sx (if (neg-inf? x) -1 (if (pos-inf? x) 1 (if (negative? x) -1 1))))
                 (sy (if (neg-inf? y) -1 (if (pos-inf? y) 1 (if (negative? y) -1 1)))))
             (if (= (* sx sy) 1) 'posinf 'neginf)))
          (else (* x y))))

  ;; --- lattice operations --------------------------------------------------

  (define (iv-leq a b)
    (cond ((iv-bot? a) #t)
          ((iv-bot? b) #f)
          (else (and (b<= (interval-lo b) (interval-lo a))
                     (b<= (interval-hi a) (interval-hi b))))))

  (define (iv-join a b)
    (cond ((iv-bot? a) b)
          ((iv-bot? b) a)
          (else (make-interval (bmin (interval-lo a) (interval-lo b))
                               (bmax (interval-hi a) (interval-hi b))))))

  (define (iv-meet a b)
    (if (or (iv-bot? a) (iv-bot? b))
        iv-bot
        (let ((lo (bmax (interval-lo a) (interval-lo b)))
              (hi (bmin (interval-hi a) (interval-hi b))))
          (if (b<= lo hi) (make-interval lo hi) iv-bot))))

  ;; --- transfer functions --------------------------------------------------

  (define (iv-add a b)
    (if (or (iv-bot? a) (iv-bot? b)) iv-bot
        (make-interval (b+ (interval-lo a) (interval-lo b))
                       (b+ (interval-hi a) (interval-hi b)))))

  (define (iv-neg a)
    (if (iv-bot? a) iv-bot
        (make-interval (bneg (interval-hi a)) (bneg (interval-lo a)))))

  (define (iv-sub a b) (iv-add a (iv-neg b)))

  ;; All four corner products, because the sign of either operand can flip
  ;; which corner is extremal. Getting this wrong by taking lo*lo and hi*hi is
  ;; the classic interval-multiply bug.
  (define (iv-mul a b)
    (if (or (iv-bot? a) (iv-bot? b)) iv-bot
        (let* ((al (interval-lo a)) (ah (interval-hi a))
               (bl (interval-lo b)) (bh (interval-hi b))
               (c1 (b* al bl)) (c2 (b* al bh))
               (c3 (b* ah bl)) (c4 (b* ah bh)))
          (make-interval (bmin (bmin c1 c2) (bmin c3 c4))
                         (bmax (bmax c1 c2) (bmax c3 c4))))))

  ;; --- widening and narrowing ----------------------------------------------
  ;;
  ;; Cousot & Cousot 1977 section 7. Widening is what makes the fixpoint
  ;; terminate over an infinite-height lattice: an unstable bound jumps
  ;; straight to infinity rather than creeping up one integer per iteration.
  ;;
  ;; NOTE the argument order. iv-widen takes (old new) and is applied as
  ;; `new := old widen (old join f(old))`. Applying it backwards produces a
  ;; sequence that looks convergent on monotone-increasing iterates and is
  ;; unsound in general. That is precisely the bug printed in Figure 3 of the
  ;; Pentagons paper, in both halves, and it is masked by exactly the naive
  ;; monotone test suite a reader would write. See LEDGER.md.

  (define (iv-widen old new)
    (cond ((iv-bot? old) new)
          ((iv-bot? new) old)
          (else
           (make-interval
            (if (b<= (interval-lo old) (interval-lo new)) (interval-lo old) 'neginf)
            (if (b<= (interval-hi new) (interval-hi old)) (interval-hi old) 'posinf)))))

  ;; Narrowing recovers precision after widening, and only where widening went
  ;; to infinity. It must never move a finite bound, or the result is unsound.
  (define (iv-narrow old new)
    (cond ((iv-bot? old) iv-bot)
          ((iv-bot? new) iv-bot)
          (else
           (make-interval
            (if (neg-inf? (interval-lo old)) (interval-lo new) (interval-lo old))
            (if (pos-inf? (interval-hi old)) (interval-hi new) (interval-hi old))))))

  ;; --- refinement from comparisons -----------------------------------------
  ;; This is the part cptypes cannot do at all, and it is where bounds-check
  ;; elimination comes from: on the true branch of (< i n), i is known to be
  ;; strictly below n's upper bound.

  (define (iv-lt-refine a b)          ; a, given (< a b) is true
    (if (or (iv-bot? a) (iv-bot? b)) iv-bot
        (iv-meet a (make-interval 'neginf (b+ (interval-hi b) -1)))))

  (define (iv-le-refine a b)          ; a, given (<= a b) is true
    (if (or (iv-bot? a) (iv-bot? b)) iv-bot
        (iv-meet a (make-interval 'neginf (interval-hi b)))))

  (define (iv-ge-refine a b)          ; a, given (>= a b) is true
    (if (or (iv-bot? a) (iv-bot? b)) iv-bot
        (iv-meet a (make-interval (interval-lo b) 'posinf))))

  ;; --- branch edges, and the one place the NaN rule lives -------------------
  ;;
  ;; e-SSA hands the domain a SYNTACTIC fact: the comparison exactly as the
  ;; program wrote it, plus a flag saying whether this is the edge where it
  ;; FAILED. See the `sigma` production in lang.ss. Turning that pair into a
  ;; refinement is a domain question, and the two numeric types answer it
  ;; differently.
  ;;
  ;; Fixnums are totally ordered. (not (fx< a b)) is (fx>= a b), so the false
  ;; edge refines exactly as well as the true one, and the false edge of an
  ;; equality is the one case the ORDER cannot express: a disequality is not an
  ;; interval, so it refines nothing.
  ;;
  ;; Flonums are not totally ordered. NaN compares false against everything,
  ;; itself included, so (not (fl< a b)) is TRUE when either operand is NaN,
  ;; where (fl>= a b) is false. Concluding a >= b on that edge asserts an
  ;; ordering in precisely the case where no ordering holds, and the consumer is
  ;; bounds-check elision, so it is a wrong-code bug and not a lost
  ;; optimization. A NEGATED FLONUM COMPARISON THEREFORE REFINES NOTHING.
  ;;
  ;; Recovering that edge needs a premise that neither operand is NaN. No
  ;; production in lang.ss carries one today; when one exists it is consumed
  ;; HERE and nowhere else, by widening iv-edge-cmp's second argument. The true
  ;; edge needs no such premise and is unaffected: a comparison that SUCCEEDED
  ;; had no NaN operand, so the ordering it states holds.
  ;;
  ;; Comparisons are named three ways because three languages meet here: the
  ;; bare symbols of this file's own client, the fixnum primitives of lang.ss,
  ;; and the flonum ones. Only the last group is special.

  (define cmp-table
    ;;  spelling  base  negation-of-the-base, or #f for "conclude nothing"
    '((<     <   >=)   (<=    <=  >)   (>     >   <=)   (>=    >=  <)   (=  =  #f)
      (fx<   <   >=)   (fx<=  <=  >)   (fx>   >   <=)   (fx>=  >=  <)   (fx= =  #f)
      (fl<   <   #f)   (fl<=  <=  #f)  (fl>   >   #f)   (fl>=  >=  #f)  (fl= =  #f)))

  (define (iv-comparison? c) (and (assq c cmp-table) #t))

  ;; The comparison the domain may assume on this edge, as one of < <= > >= =,
  ;; or #f for "this edge licenses no conclusion".
  ;; `non-nan?` is the premise that unlocks negated flonum comparisons.
  ;;
  ;; Without it, (not (fl< a b)) licenses nothing, because NaN makes every
  ;; comparison false so the negation is TRUE for NaN while (fl>= a b) is FALSE.
  ;; With a non-NaN premise in scope for both operands, the ordering is total
  ;; again and the flonum rows behave exactly like the fixnum ones.
  ;;
  ;; Defaults to #f, so the safe answer is what you get for free and the
  ;; permissive one has to be asked for.
  (define iv-edge-cmp
    (case-lambda
      ((cmp negated?) (iv-edge-cmp cmp negated? #f))
      ((cmp negated? non-nan?)
       (let ((row (assq cmp cmp-table)))
         (cond
          ((not row) #f)
          ((not negated?) (cadr row))
          ;; a negated flonum comparison, under a non-NaN premise, gets the
          ;; ordering the fixnum spelling would have given.
          ((and non-nan? (flonum-cmp? cmp)) (caddr (assq (fx-twin cmp) cmp-table)))
          (else (caddr row)))))))

  (define (flonum-cmp? c) (and (memq c '(fl< fl<= fl> fl>= fl=)) #t))
  (define (fx-twin c)
    (cond ((eq? c 'fl<) 'fx<) ((eq? c 'fl<=) 'fx<=) ((eq? c 'fl>) 'fx>)
          ((eq? c 'fl>=) 'fx>=) (else 'fx=)))

  ;; Refine BOTH operands of a comparison on one of its edges. Returns
  ;; (values a' b'), and returns them unchanged when the edge licenses nothing,
  ;; which is the answer for every negated flonum comparison.
  ;;
  ;; Both operands, because the edge constrains both: the true edge of a < b
  ;; says as much about b as it does about a, and ABCD's constraint graph wants
  ;; the vertex either way.
  (define iv-refine
    (case-lambda
      ((cmp negated? a b) (iv-refine cmp negated? a b #f))
      ((cmp negated? a b non-nan?) (iv-refine* cmp negated? a b non-nan?))))

  ;; a != b, which is the FALSE EDGE OF AN EQUALITY TEST.
  ;;
  ;; An interval cannot say "everything except c", so the general answer is to
  ;; refine nothing -- which is what `cmp-table` records for the negation of
  ;; `=`, and it stays recorded, because four passes read `iv-edge-cmp` and one
  ;; of them turns the edge into a trip count.
  ;;
  ;; But the case that MATTERS is expressible: when the excluded value sits at
  ;; an ENDPOINT, the interval simply shrinks by one. That is not a corner case,
  ;; it is how a loop written against an equality guard is bounded at all:
  ;;
  ;;     (define (next r ...) (if (fx= r n) <stop> ... (vector-ref cnt r) ...))
  ;;
  ;; The fixpoint already derives r in [1,7] and n = 7, and without this the
  ;; index can be 7 into a length-7 vector, so the check stays. With it the
  ;; false edge gives [1,6] and the check goes. fannkuch-redux's `next` and
  ;; `rotate` are both this shape, and `ref.c` writes the same `if (r == N)`.
  ;;
  ;; INTEGERS ONLY. Shrinking by one is a statement about the successor of c,
  ;; which reals do not have -- and for flonums the false edge of `fl=` is
  ;; taken by NaN as well, so there is nothing to conclude even with a non-NaN
  ;; premise. `=` and `fx=` only.
  (define (iv-exclude a b)
    (let ((blo (interval-lo b)) (bhi (interval-hi b)))
      (if (or (iv-bot? a) (iv-bot? b)
              (neg-inf? blo) (pos-inf? bhi) (not (eqv? blo bhi)))
          a
          (let ((c blo) (lo (interval-lo a)) (hi (interval-hi a)))
            (cond
             ;; a is exactly {c}, and a != c leaves nothing
             ((and (eqv? lo c) (eqv? hi c)) iv-bot)
             ((eqv? lo c) (make-interval (+ c 1) hi))
             ((eqv? hi c) (make-interval lo (- c 1)))
             (else a))))))

  (define (integer-equality? cmp) (and (memq cmp '(= fx=)) #t))

  (define (iv-refine* cmp negated? a b non-nan?)
    (if (and negated? (integer-equality? cmp))
        (values (iv-exclude a b) (iv-exclude b a))
    (let ((c (iv-edge-cmp cmp negated? non-nan?)))
      (cond
       ((not c) (values a b))
       ((eq? c '<)  (values (iv-lt-refine a b)
                            (iv-ge-refine b (iv-add a (iv-const 1)))))
       ((eq? c '<=) (values (iv-le-refine a b) (iv-ge-refine b a)))
       ((eq? c '>)  (values (iv-ge-refine a (iv-add b (iv-const 1)))
                            (iv-lt-refine b a)))
       ((eq? c '>=) (values (iv-ge-refine a b) (iv-le-refine b a)))
       ((eq? c '=)  (let ((m (iv-meet a b))) (values m m)))
       (else (values a b))))))

  ;; --- the query the whole file exists to answer ---------------------------
  ;; Is every value of `idx` a valid index into a vector of length `len`?
  ;; If yes, the bounds check is dead and the compiler may delete it.

  (define (iv-within? idx len)
    (and (not (iv-bot? idx))
         (not (iv-bot? len))
         (let ((lo (interval-lo idx)) (hi (interval-hi idx)))
           (and (not (neg-inf? lo))
                (>= lo 0)
                (not (pos-inf? hi))
                (not (neg-inf? (interval-lo len)))
                (< hi (interval-lo len))))))

  (define (iv->string a)
    (if (iv-bot? a)
        "_|_"
        (string-append "["
                       (if (neg-inf? (interval-lo a)) "-inf" (number->string (interval-lo a)))
                       ", "
                       (if (pos-inf? (interval-hi a)) "+inf" (number->string (interval-hi a)))
                       "]")))
  )
