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

;; nbody's actual access pattern: b[i*7 + k], i in [0,4], k in [0,6],
;; against a flvector of length 35.
(let* ((i (iv-range 0 4))
       (k (iv-range 0 6))
       (off (iv-add (iv-mul i (iv-const 7)) k)))
  (check-eq! "nbody offset i*7+k is [0,34]" off (iv-range 0 34))
  (check! "nbody bounds check is ELIMINABLE" (iv-within? off (iv-const 35))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
