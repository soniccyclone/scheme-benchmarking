#!r6rs
;;; nbody, configuration 2a: portable R6RS.
;;;
;;; The only standardized instruction-level escape hatch with a real
;;; implementation behind it. (rnrs arithmetic flonums) has existed since 2007
;;; and both Chez and Racket ship it.
;;;
;;; Note what it does NOT give you: R6RS standardized flonum *operators* and no
;;; unboxed flonum *storage*. Bodies therefore live in an ordinary `vector`,
;;; whose slots are boxed. That gap is exactly what this configuration measures
;;; against 2b and 4.
;;;
;;; Written from SPEC.md in this directory. Expression order is load-bearing.
;;;
;;; Chez:   scheme --program config2a.sps <steps>
;;; Racket: racket -I r6rs config2a.sps <steps>

(import (rnrs base)
        (rnrs arithmetic flonums)
        (rnrs programs)
        (rnrs io simple)
        (rnrs control))

;; --- constants, per SPEC.md -------------------------------------------------

(define pi 3.141592653589793)
(define solar-mass (fl* 4.0 (fl* pi pi)))
(define days-per-year 365.24)
(define dt 0.01)
(define nbody 5)

;; Each body is 7 consecutive slots: x y z vx vy vz mass.
(define slots 7)

(define (mk x y z vx vy vz m)
  (list x y z
        (fl* vx days-per-year) (fl* vy days-per-year) (fl* vz days-per-year)
        (fl* m solar-mass)))

(define initial
  (list
   (mk 0.0 0.0 0.0 0.0 0.0 0.0 1.0)
   (mk 4.84143144246472090e+00 -1.16032004402742839e+00 -1.03622044471123109e-01
       1.66007664274403694e-03 7.69901118419740425e-03 -6.90460016972063023e-05
       9.54791938424326609e-04)
   (mk 8.34336671824457987e+00 4.12479856412430479e+00 -4.03523417114321381e-01
       -2.76742510726862411e-03 4.99852801234917238e-03 2.30417297573763929e-05
       2.85885980666130812e-04)
   (mk 1.28943695621391310e+01 -1.51111514016986312e+01 -2.23307578892655734e-01
       2.96460137564761618e-03 2.37847173959480950e-03 -2.96589568540237556e-05
       4.36624404335156298e-05)
   (mk 1.53796971148509165e+01 -2.59193146099879641e+01 1.79258772950371181e-01
       2.68067772490389322e-03 1.62824170038242295e-03 -9.51592254519715870e-05
       5.15138902046611451e-05)))

(define b (make-vector (* nbody slots) 0.0))

(define (init!)
  (let loop ((i 0) (bs initial))
    (unless (null? bs)
      (let inner ((k 0) (fs (car bs)))
        (unless (null? fs)
          (vector-set! b (+ (* i slots) k) (car fs))
          (inner (+ k 1) (cdr fs))))
      (loop (+ i 1) (cdr bs)))))

;; --- accessors -------------------------------------------------------------

(define-syntax define-slot
  (syntax-rules ()
    ((_ get set k)
     (begin (define (get i) (vector-ref b (+ (* i slots) k)))
            (define (set i v) (vector-set! b (+ (* i slots) k) v))))))

(define-slot bx bx! 0)
(define-slot by by! 1)
(define-slot bz bz! 2)
(define-slot bvx bvx! 3)
(define-slot bvy bvy! 4)
(define-slot bvz bvz! 5)
(define (bm i) (vector-ref b (+ (* i slots) 6)))

;; --- procedure, per SPEC.md ------------------------------------------------

(define (offset-momentum!)
  (let loop ((i 0) (px 0.0) (py 0.0) (pz 0.0))
    (if (= i nbody)
        (begin (bvx! 0 (fl/ (fl- 0.0 px) solar-mass))
               (bvy! 0 (fl/ (fl- 0.0 py) solar-mass))
               (bvz! 0 (fl/ (fl- 0.0 pz) solar-mass)))
        (loop (+ i 1)
              (fl+ px (fl* (bvx i) (bm i)))
              (fl+ py (fl* (bvy i) (bm i)))
              (fl+ pz (fl* (bvz i) (bm i)))))))

;; Velocities first, from the forces at the current positions. Then positions.
;; The two loops must not be fused; see SPEC.md.
(define (advance!)
  (let outer ((i 0))
    (when (< i nbody)
      (let inner ((j (+ i 1)))
        (when (< j nbody)
          (let* ((dx (fl- (bx i) (bx j)))
                 (dy (fl- (by i) (by j)))
                 (dz (fl- (bz i) (bz j)))
                 (d2 (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz)))
                 (mag (fl/ dt (fl* d2 (flsqrt d2))))
                 (mj (fl* (bm j) mag))
                 (mi (fl* (bm i) mag)))
            (bvx! i (fl- (bvx i) (fl* dx mj)))
            (bvy! i (fl- (bvy i) (fl* dy mj)))
            (bvz! i (fl- (bvz i) (fl* dz mj)))
            (bvx! j (fl+ (bvx j) (fl* dx mi)))
            (bvy! j (fl+ (bvy j) (fl* dy mi)))
            (bvz! j (fl+ (bvz j) (fl* dz mi))))
          (inner (+ j 1))))
      (outer (+ i 1))))
  (let loop ((i 0))
    (when (< i nbody)
      (bx! i (fl+ (bx i) (fl* dt (bvx i))))
      (by! i (fl+ (by i) (fl* dt (bvy i))))
      (bz! i (fl+ (bz i) (fl* dt (bvz i))))
      (loop (+ i 1)))))

;; Kinetic term for body i is added before that body's pair terms. Order is
;; load-bearing for bit-exact cross-agreement.
(define (kinetic i)
  (fl* (fl* 0.5 (bm i))
       (fl+ (fl+ (fl* (bvx i) (bvx i)) (fl* (bvy i) (bvy i)))
            (fl* (bvz i) (bvz i)))))

(define (pair-potential i j)
  (let* ((dx (fl- (bx i) (bx j)))
         (dy (fl- (by i) (by j)))
         (dz (fl- (bz i) (bz j)))
         (d (flsqrt (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz)))))
    (fl/ (fl* (bm i) (bm j)) d)))

(define (subtract-pairs i j e)
  (if (= j nbody)
      e
      (subtract-pairs i (+ j 1) (fl- e (pair-potential i j)))))

(define (energy-from i e)
  (if (= i nbody)
      e
      (energy-from (+ i 1)
                   (subtract-pairs i (+ i 1) (fl+ e (kinetic i))))))

(define (energy) (energy-from 0 0.0))

(define (main)
  (let* ((args (command-line))
         (n (if (> (length args) 1)
                (string->number (cadr args))
                1000)))
    (init!)
    (offset-momentum!)
    (display (energy)) (newline)
    (let loop ((i 0))
      (when (< i n) (advance!) (loop (+ i 1))))
    (display (energy)) (newline)))

(main)
