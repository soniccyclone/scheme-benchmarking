#lang racket/base
;;; nbody, configuration 4 (Racket): implementation-specific maximum.
;;;
;;; Racket's folklore ceiling, and note how differently it is spelled from
;;; Chez's. There is no policy switch here at all. Instead of asking the
;;; compiler to stop checking, you call a different set of procedures:
;;; racket/unsafe/ops exports unchecked twins of the safe operators.
;;;
;;; That distinction matters for the thesis. Chez's optimize-level 3 is a
;;; global policy; Racket's unsafe ops are per-call-site instructions. Neither
;;; is standardized, and they are not even the same KIND of mechanism, which is
;;; the portability problem stated as concretely as it can be stated.
;;;
;;; Written from SPEC.md. Expression order matches ref.c exactly.

(require racket/flonum
         racket/unsafe/ops
         (only-in racket/cmdline))

(define pi- 3.141592653589793)
(define solar-mass (fl* 4.0 (fl* pi- pi-)))
(define days-per-year 365.24)
(define dt 0.01)
(define nbody 5)
(define slots 7)

(define b (make-flvector (* nbody slots) 0.0))

(define-syntax-rule (g i k) (unsafe-flvector-ref b (unsafe-fx+ (unsafe-fx* i slots) k)))
(define-syntax-rule (s! i k v) (unsafe-flvector-set! b (unsafe-fx+ (unsafe-fx* i slots) k) v))

(define (put! i x y z vx vy vz m)
  (s! i 0 x) (s! i 1 y) (s! i 2 z)
  (s! i 3 (fl* vx days-per-year))
  (s! i 4 (fl* vy days-per-year))
  (s! i 5 (fl* vz days-per-year))
  (s! i 6 (fl* m solar-mass)))

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
  (let loop ([i 0] [px 0.0] [py 0.0] [pz 0.0])
    (if (unsafe-fx= i nbody)
        (begin (s! 0 3 (unsafe-fl/ (unsafe-fl- 0.0 px) solar-mass))
               (s! 0 4 (unsafe-fl/ (unsafe-fl- 0.0 py) solar-mass))
               (s! 0 5 (unsafe-fl/ (unsafe-fl- 0.0 pz) solar-mass)))
        (loop (unsafe-fx+ i 1)
              (unsafe-fl+ px (unsafe-fl* (g i 3) (g i 6)))
              (unsafe-fl+ py (unsafe-fl* (g i 4) (g i 6)))
              (unsafe-fl+ pz (unsafe-fl* (g i 5) (g i 6)))))))

;; Velocities from forces at current positions, then positions. Not fused.
(define (advance!)
  (let outer ([i 0])
    (when (unsafe-fx< i nbody)
      (let inner ([j (unsafe-fx+ i 1)])
        (when (unsafe-fx< j nbody)
          (let* ([dx (unsafe-fl- (g i 0) (g j 0))]
                 [dy (unsafe-fl- (g i 1) (g j 1))]
                 [dz (unsafe-fl- (g i 2) (g j 2))]
                 [d2 (unsafe-fl+ (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy))
                                 (unsafe-fl* dz dz))]
                 [mag (unsafe-fl/ dt (unsafe-fl* d2 (unsafe-flsqrt d2)))]
                 [mj (unsafe-fl* (g j 6) mag)]
                 [mi (unsafe-fl* (g i 6) mag)])
            (s! i 3 (unsafe-fl- (g i 3) (unsafe-fl* dx mj)))
            (s! i 4 (unsafe-fl- (g i 4) (unsafe-fl* dy mj)))
            (s! i 5 (unsafe-fl- (g i 5) (unsafe-fl* dz mj)))
            (s! j 3 (unsafe-fl+ (g j 3) (unsafe-fl* dx mi)))
            (s! j 4 (unsafe-fl+ (g j 4) (unsafe-fl* dy mi)))
            (s! j 5 (unsafe-fl+ (g j 5) (unsafe-fl* dz mi))))
          (inner (unsafe-fx+ j 1))))
      (outer (unsafe-fx+ i 1))))
  (let loop ([i 0])
    (when (unsafe-fx< i nbody)
      (s! i 0 (unsafe-fl+ (g i 0) (unsafe-fl* dt (g i 3))))
      (s! i 1 (unsafe-fl+ (g i 1) (unsafe-fl* dt (g i 4))))
      (s! i 2 (unsafe-fl+ (g i 2) (unsafe-fl* dt (g i 5))))
      (loop (unsafe-fx+ i 1)))))

(define (kinetic i)
  (unsafe-fl* (unsafe-fl* 0.5 (g i 6))
              (unsafe-fl+ (unsafe-fl+ (unsafe-fl* (g i 3) (g i 3))
                                      (unsafe-fl* (g i 4) (g i 4)))
                          (unsafe-fl* (g i 5) (g i 5)))))

(define (pair-potential i j)
  (let* ([dx (unsafe-fl- (g i 0) (g j 0))]
         [dy (unsafe-fl- (g i 1) (g j 1))]
         [dz (unsafe-fl- (g i 2) (g j 2))]
         [d (unsafe-flsqrt (unsafe-fl+ (unsafe-fl+ (unsafe-fl* dx dx) (unsafe-fl* dy dy))
                                       (unsafe-fl* dz dz)))])
    (unsafe-fl/ (unsafe-fl* (g i 6) (g j 6)) d)))

(define (subtract-pairs i j e)
  (if (unsafe-fx= j nbody)
      e
      (subtract-pairs i (unsafe-fx+ j 1) (unsafe-fl- e (pair-potential i j)))))

(define (energy-from i e)
  (if (unsafe-fx= i nbody)
      e
      (energy-from (unsafe-fx+ i 1)
                   (subtract-pairs i (unsafe-fx+ i 1) (unsafe-fl+ e (kinetic i))))))

(define (energy) (energy-from 0 0.0))

(module+ main
  (define n (let ([a (current-command-line-arguments)])
              (if (zero? (vector-length a)) 1000 (string->number (vector-ref a 0)))))
  (init!)
  (offset-momentum!)
  (displayln (energy))
  (let loop ([i 0]) (when (unsafe-fx< i n) (advance!) (loop (unsafe-fx+ i 1))))
  (displayln (energy)))
