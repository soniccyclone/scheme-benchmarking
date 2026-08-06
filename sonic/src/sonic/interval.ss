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
