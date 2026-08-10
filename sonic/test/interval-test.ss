;;; Tests for the interval domain.
;;;
;;; The important half of this file is the SOUNDNESS test, not the lattice
;;; laws. An abstract domain that satisfies every lattice law can still be
;;; wrong: what makes it a sound abstraction is Cousot's local consistency
;;; condition, that the abstract operation over-approximates the concrete one.
;;;
;;;     for all concrete x in gamma(a), y in gamma(b):
;;;         f(x, y)  must be in  gamma(f#(a, b))
;;;
;;; We check it by exhaustive concretization over small finite intervals, which
;;; for this domain is a proof over the tested range rather than a sample.
;;;
;;; Run: scheme --script test/interval-test.ss   (from sonic/)

(import (rnrs base)
        (rnrs lists)
        (rnrs control)
        (rnrs io simple)
        (sonic interval))

(define failures 0)
(define checks 0)

(define (check! name ok)
  (set! checks (+ checks 1))
  (unless ok
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name) (newline)))

(define (check-eq! name a b)
  (check! name (and (equal? (interval-lo a) (interval-lo b))
                    (equal? (interval-hi a) (interval-hi b)))))

;; --- concretization, for finite intervals only ----------------------------

(define (gamma a)
  (if (iv-bot? a)
      '()
      (let loop ((i (interval-lo a)) (acc '()))
        (if (> i (interval-hi a)) (reverse acc) (loop (+ i 1) (cons i acc))))))

(define (member? x lst) (and (memv x lst) #t))

;; --- soundness: the test that actually matters -----------------------------

(define (soundness-test name abstract-op concrete-op lo hi)
  (let outer ((al lo))
    (when (<= al hi)
      (let outer2 ((ah al))
        (when (<= ah hi)
          (let inner ((bl lo))
            (when (<= bl hi)
              (let inner2 ((bh bl))
                (when (<= bh hi)
                  (let* ((a (iv-range al ah))
                         (b (iv-range bl bh))
                         (r (abstract-op a b))
                         (cr (gamma r)))
                    ;; every concrete result must be inside the abstract result
                    (for-all (lambda (x)
                               (for-all (lambda (y)
                                          (let ((c (concrete-op x y)))
                                            (or (member? c cr)
                                                (begin
                                                  (set! failures (+ failures 1))
                                                  (display "UNSOUND ") (display name)
                                                  (display ": ") (display (iv->string a))
                                                  (display " op ") (display (iv->string b))
                                                  (display " = ") (display (iv->string r))
                                                  (display " but ") (display x)
                                                  (display " op ") (display y)
                                                  (display " = ") (display c) (newline)
                                                  #f))))
                                        (gamma b)))
                             (gamma a))
                    (set! checks (+ checks 1)))
                  (inner2 (+ bh 1))))
              (inner (+ bl 1))))
          (outer2 (+ ah 1))))
      (outer (+ al 1)))))

(display "soundness, exhaustive over [-4,4] x [-4,4]:") (newline)
(soundness-test "iv-add" iv-add + -4 4)
(display "  add done") (newline)
(soundness-test "iv-sub" iv-sub - -4 4)
(display "  sub done") (newline)
(soundness-test "iv-mul" iv-mul * -4 4)
(display "  mul done") (newline)

;; --- lattice laws ----------------------------------------------------------

(check! "join is upper bound (left)"  (iv-leq (iv-range 1 3) (iv-join (iv-range 1 3) (iv-range 5 7))))
(check! "join is upper bound (right)" (iv-leq (iv-range 5 7) (iv-join (iv-range 1 3) (iv-range 5 7))))
(check-eq! "join spans the gap" (iv-join (iv-range 1 3) (iv-range 5 7)) (iv-range 1 7))
(check-eq! "meet overlaps" (iv-meet (iv-range 1 5) (iv-range 3 9)) (iv-range 3 5))
(check! "disjoint meet is bottom" (iv-bot? (iv-meet (iv-range 1 2) (iv-range 5 6))))
(check! "bottom is least" (iv-leq iv-bot (iv-range 1 2)))
(check! "top is greatest" (iv-leq (iv-range 1 2) iv-top))
(check-eq! "join with bottom is identity" (iv-join iv-bot (iv-range 1 2)) (iv-range 1 2))

;; --- widening --------------------------------------------------------------
;; The Pentagons Figure 3 hazard: a widening applied with its arguments
;; reversed still looks convergent when the iterates increase monotonically.
;; These tests pin the direction explicitly.

(check-eq! "widen: stable bounds are kept"
           (iv-widen (iv-range 0 10) (iv-range 0 10)) (iv-range 0 10))
(check-eq! "widen: unstable upper bound goes to +inf"
           (iv-widen (iv-range 0 10) (iv-range 0 11)) (iv-range 0 'posinf))
(check-eq! "widen: unstable lower bound goes to -inf"
           (iv-widen (iv-range 0 10) (iv-range -1 10)) (iv-range 'neginf 10))
(check! "widen is extensive: result contains the new value"
        (iv-leq (iv-range 0 11) (iv-widen (iv-range 0 10) (iv-range 0 11))))
(check-eq! "widen from bottom is the new value"
           (iv-widen iv-bot (iv-range 3 4)) (iv-range 3 4))

;; Termination: widening must reach a fixpoint in bounded steps even when the
;; concrete sequence grows without limit. This is the property that makes the
;; whole analysis usable, and it is what a monotone-only test cannot show.
(let loop ((cur (iv-range 0 0)) (i 0))
  (cond ((> i 100) (check! "widening terminates" #f))
        ((iv-top? cur) (check! "widening terminates" #t))
        (else
         (let ((next (iv-widen cur (iv-join cur (iv-add cur (iv-const 1))))))
           (if (iv-leq next cur)
               (check! "widening terminates" (iv-leq (iv-range 0 'posinf) next))
               (loop next (+ i 1)))))))

(check-eq! "narrow recovers a widened upper bound"
           (iv-narrow (iv-range 0 'posinf) (iv-range 0 10)) (iv-range 0 10))
(check-eq! "narrow never moves a finite bound"
           (iv-narrow (iv-range 0 10) (iv-range 0 99)) (iv-range 0 10))

;; --- refinement, and the query the domain exists for -----------------------

(check-eq! "refine i by (< i 5)"
           (iv-lt-refine iv-top (iv-const 5)) (iv-range 'neginf 4))
(check-eq! "refine i by (>= i 0)"
           (iv-ge-refine (iv-range 'neginf 4) (iv-const 0)) (iv-range 0 4))

;; The whole point: the loop `for i from 0 below 35` over a length-35 vector.
(let* ((len (iv-const 35))
       (i   (iv-ge-refine (iv-lt-refine iv-top len) (iv-const 0))))
  (check-eq! "loop index is recovered as [0,34]" i (iv-range 0 34))
  (check! "bounds check on a length-35 vector is ELIMINABLE" (iv-within? i len)))

;; And the cases where it must refuse.
(check! "unknown index is not eliminable" (not (iv-within? iv-top (iv-const 35))))
(check! "index that can be negative is not eliminable"
        (not (iv-within? (iv-range -1 34) (iv-const 35))))
(check! "index that can reach len is not eliminable"
        (not (iv-within? (iv-range 0 35) (iv-const 35))))
(check! "index against unknown length is not eliminable"
        (not (iv-within? (iv-range 0 34) iv-top)))

;; --- branch edges, and NaN -------------------------------------------------
;;
;; e-SSA reports a comparison plus which edge we are on; `iv-refine` decides
;; what follows. The FALSE edge is where the two numeric types part company, and
;; getting it wrong is a wrong-code bug rather than a lost optimization, so it is
;; pinned per type rather than assumed from the fixnum case.

(define (refine-first cmp neg a b)
  (let-values (((a2 b2) (iv-refine cmp neg a b))) a2))
(define (refine-second cmp neg a b)
  (let-values (((a2 b2) (iv-refine cmp neg a b))) b2))

(check-eq! "true edge of (< i 5) bounds i above"
           (refine-first '< #f iv-top (iv-const 5)) (iv-range 'neginf 4))
(check-eq! "true edge of (< i n) bounds n below too"
           (refine-second '< #f (iv-const 3) iv-top) (iv-range 4 'posinf))
(check-eq! "false edge of (fx< i 5) is i >= 5"
           (refine-first 'fx< #t iv-top (iv-const 5)) (iv-range 5 'posinf))
(check-eq! "false edge of (fx>= i 5) is i < 5"
           (refine-first 'fx>= #t iv-top (iv-const 5)) (iv-range 'neginf 4))

;; A disequality is not an interval. The primitive table has no fx<>, and even
;; if it did, [0,10] minus one point is not representable here.
(check-eq! "false edge of an equality refines nothing"
           (refine-first 'fx= #t (iv-range 0 10) (iv-const 5)) (iv-range 0 10))

;; THE NaN CASE. This is the one the sigma negation flag exists for.
;;
;; (fl< a b) being FALSE does not mean (fl>= a b). NaN compares false against
;; everything, so a NaN operand makes the negation true while no ordering holds
;; at all. A domain that narrowed here would hand bounds-check elision a fact
;; that is false for a real input, and there is no check downstream to catch it.
(check-eq! "false edge of (fl< a b) must NOT narrow a"
           (refine-first 'fl< #t (iv-range 0 10) (iv-const 5)) (iv-range 0 10))
(check-eq! "false edge of (fl< a b) must NOT narrow b"
           (refine-second 'fl< #t (iv-range 0 10) (iv-range 0 10)) (iv-range 0 10))
(check-eq! "false edge of (fl>= a b) must NOT narrow either"
           (refine-first 'fl>= #t (iv-range 0 10) (iv-const 5)) (iv-range 0 10))
(check! "no flonum comparison has a usable negation"
        (for-all (lambda (c) (not (iv-edge-cmp c #t)))
                 '(fl< fl<= fl> fl>= fl=)))

;; The TRUE edge is unaffected, and that asymmetry is the whole content of the
;; rule: a comparison that SUCCEEDED had no NaN operand, so the ordering it
;; states really holds and refines exactly as the fixnum one does.
(check-eq! "true edge of (fl< a b) refines normally"
           (refine-first 'fl< #f iv-top (iv-const 5)) (iv-range 'neginf 4))
(check! "every fixnum comparison but equality has a negation"
        (for-all (lambda (c) (and (iv-edge-cmp c #t) #t))
                 '(fx< fx<= fx> fx>=)))

;; nbody's actual access pattern: b[i*7 + k], i in [0,4], k in [0,6],
;; against a flvector of length 35.
(let* ((i (iv-range 0 4))
       (k (iv-range 0 6))
       (off (iv-add (iv-mul i (iv-const 7)) k)))
  (check-eq! "nbody offset i*7+k is [0,34]" off (iv-range 0 34))
  (check! "nbody bounds check is ELIMINABLE" (iv-within? off (iv-const 35))))

;; --- the false edge of an equality test ------------------------------------
;;
;; `a != c` is not an interval, so the general answer is to refine nothing --
;; which is what `cmp-table` still records, because four passes read
;; `iv-edge-cmp` and one turns the edge into a trip count.
;;
;; The case that MATTERS is expressible, though: when the excluded value is an
;; ENDPOINT the interval shrinks by one. That is how a loop written against an
;; equality guard gets bounded at all -- `(if (fx= r n) <stop> ... v[r] ...)`
;; is fannkuch-redux's `next` and `rotate`, and `ref.c` writes the same
;; `if (r == N)`.

(check-eq! "false edge of (fx= r 7) with r in [1,7] excludes the top endpoint"
           (refine-first 'fx= #t (iv-range 1 7) (iv-const 7)) (iv-range 1 6))
(check-eq! "and the bottom endpoint, from the other side"
           (refine-first 'fx= #t (iv-range 1 7) (iv-const 1)) (iv-range 2 7))
(check-eq! "an INTERIOR value refines nothing: an interval cannot say 'not 4'"
           (refine-first 'fx= #t (iv-range 1 7) (iv-const 4)) (iv-range 1 7))
(check-eq! "excluding the only value leaves bottom"
           (refine-first 'fx= #t (iv-const 5) (iv-const 5)) iv-bot)
(check-eq! "it refines the SECOND operand too, symmetrically"
           (refine-second 'fx= #t (iv-const 7) (iv-range 1 7)) (iv-range 1 6))
(check-eq! "an unbounded endpoint excludes nothing"
           (refine-first 'fx= #t (iv-range 1 'posinf) (iv-const 7)) (iv-range 1 'posinf))
(check-eq! "a non-constant right operand excludes nothing"
           (refine-first 'fx= #t (iv-range 1 7) (iv-range 6 7)) (iv-range 1 7))

;; THE TRUE EDGE IS UNCHANGED: both operands meet, which is what equality says.
(check-eq! "true edge of (fx= r 7) still meets"
           (refine-first 'fx= #f (iv-range 1 9) (iv-const 7)) (iv-const 7))

;; FLONUMS GET NOTHING, for two reasons at once. Shrinking by one is a claim
;; about the successor of a value, which reals do not have; and the false edge
;; of `fl=` is taken by NaN, which no ordering describes.
(check-eq! "false edge of (fl= x 7.0) refines nothing"
           (refine-first 'fl= #t (iv-range 1 7) (iv-const 7)) (iv-range 1 7))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
