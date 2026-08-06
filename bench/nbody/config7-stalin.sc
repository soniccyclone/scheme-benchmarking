;;; nbody, configuration 7: Stalin, whole-program inference.
;;;
;;; The Scheme ceiling reached by INFERENCE instead of declaration, and the
;;; control on this project's whole approach. If Stalin beats every
;;; declaration-based configuration by a wide margin, the interesting problem is
;;; inference and not standardization.
;;;
;;; Source is config1.scm, the portable R5RS floor, with exactly two changes:
;;; N is a compile-time constant, and `read` is gone.
;;;
;;; That second change is not cosmetic and it is itself a finding. Compiling
;;; config1.scm unmodified makes Stalin emit a cascade of "argument to
;;; CHAR->INTEGER might not be a character" and "argument to READ-CHAR1 might
;;; not be an input port" warnings, all of them originating in `read`. Stalin
;;; has no declarations to anchor on, so an unprovable region does not stay
;;; local: it poisons everything downstream that touches it. That is exactly
;;; the bimodality RESEARCH.md section 3 records, and exactly the failure mode
;;; LEDGER.md D7 cites as the reason to anchor inference on declarations.
;;;
;;; This was specified as "portable R7RS-small" until phase 1 found that
;;; `(import (scheme base))` resolves on neither Chez nor Racket. R5RS is the
;;; oldest standard that actually runs on both, which is the floor in a stronger
;;; sense than intended.
;;;
;;; Build: sed the @N@ marker, then `stalin -On config7-stalin.sc`.
;;;
;;; Written from SPEC.md. Expression order matches ref.c exactly.

(define pi 3.141592653589793)
(define solar-mass (* 4.0 pi pi))
(define days-per-year 365.24)
(define dt 0.01)
(define nbody 5)
(define slots 7)

(define b (make-vector (* nbody slots) 0.0))

(define (g i k) (vector-ref b (+ (* i slots) k)))
(define (s! i k v) (vector-set! b (+ (* i slots) k) v))

(define (put! i x y z vx vy vz m)
  (s! i 0 x) (s! i 1 y) (s! i 2 z)
  (s! i 3 (* vx days-per-year))
  (s! i 4 (* vy days-per-year))
  (s! i 5 (* vz days-per-year))
  (s! i 6 (* m solar-mass)))

(define (init!)
  (put! 0 0.0 0.0 0.0 0.0 0.0 0.0 1.0)
  (put! 1 4.84143144246472090e+00 -1.16032004402742839e+00 -1.03622044471123109e-01
          1.66007664274403694e-03 7.69901118419740425e-03 -6.90460016972063023e-05
          9.54791938424326609e-04)
  (put! 2 8.34336671824457987e+00 4.12479856412430479e+00 -4.03523417114321381e-01
          -2.76742510726862411e-03 4.99852801234917238e-03 2.30417297573763929e-05
          2.85885980666130812e-04)
  (put! 3 1.28943695621391310e+01 -1.51111514016986312e+01 -2.23307578892655734e-01
          2.96460137564761618e-03 2.37847173959480950e-03 -2.96589568540237556e-05
          4.36624404335156298e-05)
  (put! 4 1.53796971148509165e+01 -2.59193146099879641e+01 1.79258772950371181e-01
          2.68067772490389322e-03 1.62824170038242295e-03 -9.51592254519715870e-05
          5.15138902046611451e-05))

(define (offset-momentum!)
  (let loop ((i 0) (px 0.0) (py 0.0) (pz 0.0))
    (if (= i nbody)
        (begin (s! 0 3 (/ (- 0.0 px) solar-mass))
               (s! 0 4 (/ (- 0.0 py) solar-mass))
               (s! 0 5 (/ (- 0.0 pz) solar-mass)))
        (loop (+ i 1)
              (+ px (* (g i 3) (g i 6)))
              (+ py (* (g i 4) (g i 6)))
              (+ pz (* (g i 5) (g i 6)))))))

;; Velocities from forces at current positions, then positions. Not fused.
(define (advance!)
  (let outer ((i 0))
    (if (< i nbody)
        (begin
          (let inner ((j (+ i 1)))
            (if (< j nbody)
                (begin
                  (let* ((dx (- (g i 0) (g j 0)))
                         (dy (- (g i 1) (g j 1)))
                         (dz (- (g i 2) (g j 2)))
                         (d2 (+ (+ (* dx dx) (* dy dy)) (* dz dz)))
                         (mag (/ dt (* d2 (sqrt d2))))
                         (mj (* (g j 6) mag))
                         (mi (* (g i 6) mag)))
                    (s! i 3 (- (g i 3) (* dx mj)))
                    (s! i 4 (- (g i 4) (* dy mj)))
                    (s! i 5 (- (g i 5) (* dz mj)))
                    (s! j 3 (+ (g j 3) (* dx mi)))
                    (s! j 4 (+ (g j 4) (* dy mi)))
                    (s! j 5 (+ (g j 5) (* dz mi))))
                  (inner (+ j 1)))))
          (outer (+ i 1)))))
  (let loop ((i 0))
    (if (< i nbody)
        (begin
          (s! i 0 (+ (g i 0) (* dt (g i 3))))
          (s! i 1 (+ (g i 1) (* dt (g i 4))))
          (s! i 2 (+ (g i 2) (* dt (g i 5))))
          (loop (+ i 1))))))

(define (kinetic i)
  (* (* 0.5 (g i 6))
     (+ (+ (* (g i 3) (g i 3)) (* (g i 4) (g i 4))) (* (g i 5) (g i 5)))))

(define (pair-potential i j)
  (let* ((dx (- (g i 0) (g j 0)))
         (dy (- (g i 1) (g j 1)))
         (dz (- (g i 2) (g j 2)))
         (d (sqrt (+ (+ (* dx dx) (* dy dy)) (* dz dz)))))
    (/ (* (g i 6) (g j 6)) d)))

(define (subtract-pairs i j e)
  (if (= j nbody) e (subtract-pairs i (+ j 1) (- e (pair-potential i j)))))

(define (energy-from i e)
  (if (= i nbody) e (energy-from (+ i 1) (subtract-pairs i (+ i 1) (+ e (kinetic i))))))

(define (energy) (energy-from 0 0.0))

(define (main)
  (let ((n @N@))
    (init!)
    (offset-momentum!)
    (display (energy)) (newline)
    (let loop ((i 0)) (if (< i n) (begin (advance!) (loop (+ i 1)))))
    (display (energy)) (newline)))

(main)
