#!r6rs
;;; nbody, SonicScheme configuration.
;;;
;;; Written from SPEC.md in this directory, like every other variant here.
;;; Expression order is load-bearing and matches `ref.c` term for term.
;;;
;;; WHAT THIS VARIANT IS FOR. Every other configuration keeps the five bodies in
;;; ONE array, because in a Scheme with no unboxed float storage there is
;;; nothing to gain by splitting them. This one splits positions, velocities and
;;; masses into three separate `flvector`s and hands all three to the kernels as
;;; ARGUMENTS. That is what a real entry point looks like, and it is exactly the
;;; shape `(sonic alias)` says it cannot analyse: the `make-flvector` calls are
;;; in a caller the kernel may never see, so allocation-site reasoning runs out
;;; at the procedure boundary and every query about `p` against `v` answers
;;; `may`. One `may` is the difference between vectorizing the inner loop and
;;; not.
;;;
;;; So the kernels state the premise. `(declare-distinct (p v m) ...)` is C99's
;;; `restrict`: these three name distinct storage, and inside the body they are
;;; the only paths to it. Nothing checks this. Pass the same flvector twice and
;;; the program computes wrong numbers with no diagnostic; see the undefined
;;; behaviour note at the top of `sonic/src/sonic/alias.ss`.
;;;
;;; The premise is true here by construction: `pos`, `vel` and `mass` are three
;;; separate allocations and nothing ever aliases them.
;;;
;;; SURFACE SYNTAX. Fixnum and flonum operators are spelled out (`fx+`, `fl*`),
;;; because SonicScheme's numeric tower is fixnum and flonum only and its
;;; primitive table has no generic arithmetic; there is no tower to dispatch
;;; through, so there is no `+`. Negation is `flneg`, per SPEC.md item 0, not
;;; `(fl- 0.0 x)`.
;;;
;;; Chez:      scheme --libdirs bench/nbody --program bench/nbody/config-sonic.sps <steps>
;;; SonicScheme: read -> expand -> parse; see sonic/test/parse-test.ss

(import (chezscheme) (sonic-compat))

;; --- constants, per SPEC.md -------------------------------------------------

(define pi 3.141592653589793)
(define solar-mass (fl* 4.0 (fl* pi pi)))
(define days-per-year 365.24)
(define dt 0.01)
(define n-bodies 5)

;; Three slots per body in `pos` and `vel`, one in `mass`.
(define pos (make-flvector 15 0.0))
(define vel (make-flvector 15 0.0))
(define mass (make-flvector 5 0.0))

(define (put! i x y z vx vy vz m)
  (let ((b (fx* i 3)))
    (flvector-set! pos b x)
    (flvector-set! pos (fx+ b 1) y)
    (flvector-set! pos (fx+ b 2) z)
    (flvector-set! vel b (fl* vx days-per-year))
    (flvector-set! vel (fx+ b 1) (fl* vy days-per-year))
    (flvector-set! vel (fx+ b 2) (fl* vz days-per-year))
    (flvector-set! mass i (fl* m solar-mass))))

(define (init!)
  (put! 0
        0.0 0.0 0.0
        0.0 0.0 0.0
        1.0)
  (put! 1
        4.84143144246472090e+00 -1.16032004402742839e+00 -1.03622044471123109e-01
        1.66007664274403694e-03 7.69901118419740425e-03 -6.90460016972063023e-05
        9.54791938424326609e-04)
  (put! 2
        8.34336671824457987e+00 4.12479856412430479e+00 -4.03523417114321381e-01
        -2.76742510726862411e-03 4.99852801234917238e-03 2.30417297573763929e-05
        2.85885980666130812e-04)
  (put! 3
        1.28943695621391310e+01 -1.51111514016986312e+01 -2.23307578892655734e-01
        2.96460137564761618e-03 2.37847173959480950e-03 -2.96589568540237556e-05
        4.36624404335156298e-05)
  (put! 4
        1.53796971148509165e+01 -2.59193146099879641e+01 1.79258772950371181e-01
        2.68067772490389322e-03 1.62824170038242295e-03 -9.51592254519715870e-05
        5.15138902046611451e-05))

;; --- procedure, per SPEC.md ------------------------------------------------

;; Step 1. The Sun's velocity is the NEGATED momentum sum over SOLAR_MASS.
(define (offset-momentum! v m)
  (declare-distinct (v m)
    (let loop ((i 0) (px 0.0) (py 0.0) (pz 0.0))
      (if (fx= i n-bodies)
          (begin (flvector-set! v 0 (fl/ (flneg px) solar-mass))
                 (flvector-set! v 1 (fl/ (flneg py) solar-mass))
                 (flvector-set! v 2 (fl/ (flneg pz) solar-mass)))
          (let ((b (fx* i 3))
                (mi (flvector-ref m i)))
            (loop (fx+ i 1)
                  (fl+ px (fl* (flvector-ref v b) mi))
                  (fl+ py (fl* (flvector-ref v (fx+ b 1)) mi))
                  (fl+ pz (fl* (flvector-ref v (fx+ b 2)) mi))))))))

;; Velocities first, from the forces at the current positions. Then positions.
;; The two loops must not be fused; SPEC.md says why, and a fused version is
;; no longer symplectic.
(define (advance! p v m)
  (declare-distinct (p v m)
    (let outer ((i 0))
      (when (fx< i n-bodies)
        (let inner ((j (fx+ i 1)))
          (when (fx< j n-bodies)
            (let* ((bi (fx* i 3))
                   (bj (fx* j 3))
                   (dx (fl- (flvector-ref p bi) (flvector-ref p bj)))
                   (dy (fl- (flvector-ref p (fx+ bi 1)) (flvector-ref p (fx+ bj 1))))
                   (dz (fl- (flvector-ref p (fx+ bi 2)) (flvector-ref p (fx+ bj 2))))
                   (d2 (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz)))
                   (mag (fl/ dt (fl* d2 (flsqrt d2))))
                   (mj (fl* (flvector-ref m j) mag))
                   (mi (fl* (flvector-ref m i) mag)))
              (flvector-set! v bi
                             (fl- (flvector-ref v bi) (fl* dx mj)))
              (flvector-set! v (fx+ bi 1)
                             (fl- (flvector-ref v (fx+ bi 1)) (fl* dy mj)))
              (flvector-set! v (fx+ bi 2)
                             (fl- (flvector-ref v (fx+ bi 2)) (fl* dz mj)))
              (flvector-set! v bj
                             (fl+ (flvector-ref v bj) (fl* dx mi)))
              (flvector-set! v (fx+ bj 1)
                             (fl+ (flvector-ref v (fx+ bj 1)) (fl* dy mi)))
              (flvector-set! v (fx+ bj 2)
                             (fl+ (flvector-ref v (fx+ bj 2)) (fl* dz mi))))
            (inner (fx+ j 1))))
        (outer (fx+ i 1))))
    (let loop ((i 0))
      (when (fx< i n-bodies)
        (let ((b (fx* i 3)))
          (flvector-set! p b
                         (fl+ (flvector-ref p b) (fl* dt (flvector-ref v b))))
          (flvector-set! p (fx+ b 1)
                         (fl+ (flvector-ref p (fx+ b 1))
                              (fl* dt (flvector-ref v (fx+ b 1)))))
          (flvector-set! p (fx+ b 2)
                         (fl+ (flvector-ref p (fx+ b 2))
                              (fl* dt (flvector-ref v (fx+ b 2))))))
        (loop (fx+ i 1))))))

;; The kinetic term for body i is added BEFORE that body's pair terms. The
;; interleaving is load-bearing for bit-exact cross-agreement.
(define (kinetic v m i)
  (let ((b (fx* i 3)))
    (fl* (fl* 0.5 (flvector-ref m i))
         (fl+ (fl+ (fl* (flvector-ref v b) (flvector-ref v b))
                   (fl* (flvector-ref v (fx+ b 1)) (flvector-ref v (fx+ b 1))))
              (fl* (flvector-ref v (fx+ b 2)) (flvector-ref v (fx+ b 2)))))))

(define (pair-potential p m i j)
  (let* ((bi (fx* i 3))
         (bj (fx* j 3))
         (dx (fl- (flvector-ref p bi) (flvector-ref p bj)))
         (dy (fl- (flvector-ref p (fx+ bi 1)) (flvector-ref p (fx+ bj 1))))
         (dz (fl- (flvector-ref p (fx+ bi 2)) (flvector-ref p (fx+ bj 2))))
         (d (flsqrt (fl+ (fl+ (fl* dx dx) (fl* dy dy)) (fl* dz dz)))))
    (fl/ (fl* (flvector-ref m i) (flvector-ref m j)) d)))

(define (subtract-pairs p m i j e)
  (if (fx= j n-bodies)
      e
      (subtract-pairs p m i (fx+ j 1) (fl- e (pair-potential p m i j)))))

(define (energy-from p v m i e)
  (if (fx= i n-bodies)
      e
      (energy-from p v m (fx+ i 1)
                   (subtract-pairs p m i (fx+ i 1) (fl+ e (kinetic v m i))))))

(define (energy p v m)
  (declare-distinct (p v m)
    (energy-from p v m 0 0.0)))

(define (main)
  (let* ((args (command-line))
         (n (if (fx> (length args) 1)
                (string->number (cadr args))
                3000)))
    (init!)
    (offset-momentum! vel mass)
    (display (energy pos vel mass)) (newline)
    (let loop ((i 0))
      (when (fx< i n) (advance! pos vel mass) (loop (fx+ i 1))))
    (display (energy pos vel mass)) (newline)))

(main)
