;;; nbody, configuration 4 (Chez): implementation-specific maximum.
;;;
;;; The folklore ceiling. Everything Chez offers and nothing portable:
;;;   - flvector, native unboxed double storage. Not in any Scheme standard.
;;;   - fl+ / fl* / flsqrt, Chez primitives the back end knows.
;;;   - optimize-level 3, which is where Chez stops emitting checks.
;;;
;;; optimize-level is a GLOBAL compile-time parameter, not a lexical form, so it
;;; is set by the compile step in harness/configs.sh rather than in this file.
;;; That is wall 3 of the four in docs/phases/07-compiler/PLAN.md, and it is why
;;; this configuration cannot be expressed as a scoped policy the way Ada's
;;; pragma Suppress can.
;;;
;;; Written from SPEC.md. Expression order matches ref.c exactly.

(define pi 3.141592653589793)
(define solar-mass (fl* 4.0 (fl* pi pi)))
(define days-per-year 365.24)
(define dt 0.01)
(define nbody 5)
(define slots 7)

(define b (make-flvector (fx* nbody slots) 0.0))

(define (put! i x y z vx vy vz m)
  (let ([o (fx* i slots)])
    (flvector-set! b o x)
    (flvector-set! b (fx+ o 1) y)
    (flvector-set! b (fx+ o 2) z)
    (flvector-set! b (fx+ o 3) (fl* vx days-per-year))
    (flvector-set! b (fx+ o 4) (fl* vy days-per-year))
    (flvector-set! b (fx+ o 5) (fl* vz days-per-year))
    (flvector-set! b (fx+ o 6) (fl* m solar-mass))))

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

;; Index arithmetic uses fx ops, not generic + and *, to match what
;; config4-racket.rkt spells as unsafe-fx+ and unsafe-fx*. `slots` is a
;; syntactic constant so the multiply folds; as a global variable it could not,
;; since Chez must reload and re-dispatch on it at every reference.
(define-syntax slots* (syntax-rules () [(_ i) (fx* i 7)]))
(define-syntax g (syntax-rules () [(_ i k) (flvector-ref b (fx+ (slots* i) k))]))
(define-syntax s! (syntax-rules () [(_ i k v) (flvector-set! b (fx+ (slots* i) k) v)]))

(define (offset-momentum!)
  (let loop ([i 0] [px 0.0] [py 0.0] [pz 0.0])
    (if (fx= i nbody)
        (begin (s! 0 3 (fl/ (fl- 0.0 px) solar-mass))
               (s! 0 4 (fl/ (fl- 0.0 py) solar-mass))
               (s! 0 5 (fl/ (fl- 0.0 pz) solar-mass)))
        (loop (fx+ i 1)
              (fl+ px (fl* (g i 3) (g i 6)))
              (fl+ py (fl* (g i 4) (g i 6)))
              (fl+ pz (fl* (g i 5) (g i 6)))))))

;; Velocities from forces at current positions, then positions. Not fused.
(define (advance!)
  (let outer ([i 0])
    (when (fx< i nbody)
      (let inner ([j (fx+ i 1)])
        (when (fx< j nbody)
          (let* ([dx (fl- (g i 0) (g j 0))]
                 [dy (fl- (g i 1) (g j 1))]
                 [dz (fl- (g i 2) (g j 2))]
                 [d2 (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz))]
                 [mag (fl/ dt (fl* d2 (flsqrt d2)))]
                 [mj (fl* (g j 6) mag)]
                 [mi (fl* (g i 6) mag)])
            (s! i 3 (fl- (g i 3) (fl* dx mj)))
            (s! i 4 (fl- (g i 4) (fl* dy mj)))
            (s! i 5 (fl- (g i 5) (fl* dz mj)))
            (s! j 3 (fl+ (g j 3) (fl* dx mi)))
            (s! j 4 (fl+ (g j 4) (fl* dy mi)))
            (s! j 5 (fl+ (g j 5) (fl* dz mi))))
          (inner (fx+ j 1))))
      (outer (fx+ i 1))))
  (let loop ([i 0])
    (when (fx< i nbody)
      (s! i 0 (fl+ (g i 0) (fl* dt (g i 3))))
      (s! i 1 (fl+ (g i 1) (fl* dt (g i 4))))
      (s! i 2 (fl+ (g i 2) (fl* dt (g i 5))))
      (loop (fx+ i 1)))))

(define (kinetic i)
  (fl* (fl* 0.5 (g i 6))
       (fl+ (fl+ (fl* (g i 3) (g i 3)) (fl* (g i 4) (g i 4)))
            (fl* (g i 5) (g i 5)))))

(define (pair-potential i j)
  (let* ([dx (fl- (g i 0) (g j 0))]
         [dy (fl- (g i 1) (g j 1))]
         [dz (fl- (g i 2) (g j 2))]
         [d (flsqrt (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz)))])
    (fl/ (fl* (g i 6) (g j 6)) d)))

(define (subtract-pairs i j e)
  (if (fx= j nbody) e (subtract-pairs i (fx+ j 1) (fl- e (pair-potential i j)))))

(define (energy-from i e)
  (if (fx= i nbody)
      e
      (energy-from (fx+ i 1) (subtract-pairs i (fx+ i 1) (fl+ e (kinetic i))))))

(define (energy) (energy-from 0 0.0))

(let* ([args (command-line-arguments)]
       [n (if (null? args) 1000 (string->number (car args)))])
  (init!)
  (offset-momentum!)
  (display (energy)) (newline)
  (let loop ([i 0]) (when (fx< i n) (advance!) (loop (fx+ i 1))))
  (display (energy)) (newline))
