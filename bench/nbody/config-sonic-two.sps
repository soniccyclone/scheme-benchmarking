#!r6rs
;;; nbody, SonicScheme configuration -- TWO PAIRS PER ITERATION.
;;;
;;; A PROBE FOR qaq.7.22, and it found a WRONG ANSWER (qaq.22).
;;;
;;; The pairwise inner loop is restructured to do two pair interactions per
;;; iteration with the odd one peeled, which is the source-level equivalent of
;;; the unroll-with-remainder shape that issue needs:
;;;
;;;     (let inner ((j (fx+ i 1)))
;;;       (if (fx< (fx+ j 1) n-bodies)
;;;           (begin <pair j> <pair j+1> (inner (fx+ j 2)))
;;;           (when (fx< j n-bodies) <pair j> 0)))
;;;
;;; IT ANSWERS THE QUESTION IT WAS WRITTEN FOR. Two divider chains land in ONE
;;; basic block -- L.then348 holds sqrtsd at 0x401b2b and 0x401ce0 -- which is
;;; the precondition slp.ss would need before it could pack them, and which
;;; neither unrolling nor inlining produced on the hot path. So the transform
;;; qaq.7.22 wants would work; what is missing is the packer.
;;;
;;; AND IT MISCOMPILES. Chez computes both energies correctly and agrees with
;;; the unmodified benchmark; SonicScheme returns NaN for the second. See
;;; qaq.22. It is kept here because it is the reproduction, and because a
;;; probe that finds a wrong answer has earned its place in the tree.
;;;
;;; The original header follows.
;;;
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
          (if (fx< (fx+ j 1) n-bodies)
              (begin
            (let* ((bia (fx* i 3))
                   (bja (fx* j 3))
                   (dxa (fl- (flvector-ref p bia) (flvector-ref p bja)))
                   (dya (fl- (flvector-ref p (fx+ bia 1)) (flvector-ref p (fx+ bja 1))))
                   (dza (fl- (flvector-ref p (fx+ bia 2)) (flvector-ref p (fx+ bja 2))))
                   (d2a (fl+ (fl+ (fl* dxa dxa) (fl* dya dya)) (fl* dza dza)))
                   (maga (fl/ dt (fl* d2a (flsqrt d2a))))
                   (mja (fl* (flvector-ref m j) maga))
                   (mia (fl* (flvector-ref m i) maga)))
              (flvector-set! v bia (fl- (flvector-ref v bia) (fl* dxa mja)))
              (flvector-set! v (fx+ bia 1) (fl- (flvector-ref v (fx+ bia 1)) (fl* dya mja)))
              (flvector-set! v (fx+ bia 2) (fl- (flvector-ref v (fx+ bia 2)) (fl* dza mja)))
              (flvector-set! v bja (fl+ (flvector-ref v bja) (fl* dxa mia)))
              (flvector-set! v (fx+ bja 1) (fl+ (flvector-ref v (fx+ bja 1)) (fl* dya mia)))
              (flvector-set! v (fx+ bja 2) (fl+ (flvector-ref v (fx+ bja 2)) (fl* dza mia))))
            (let* ((bib (fx* i 3))
                   (bjb (fx* (fx+ j 1) 3))
                   (dxb (fl- (flvector-ref p bib) (flvector-ref p bjb)))
                   (dyb (fl- (flvector-ref p (fx+ bib 1)) (flvector-ref p (fx+ bjb 1))))
                   (dzb (fl- (flvector-ref p (fx+ bib 2)) (flvector-ref p (fx+ bjb 2))))
                   (d2b (fl+ (fl+ (fl* dxb dxb) (fl* dyb dyb)) (fl* dzb dzb)))
                   (magb (fl/ dt (fl* d2b (flsqrt d2b))))
                   (mjb (fl* (flvector-ref m (fx+ j 1)) magb))
                   (mib (fl* (flvector-ref m i) magb)))
              (flvector-set! v bib (fl- (flvector-ref v bib) (fl* dxb mjb)))
              (flvector-set! v (fx+ bib 1) (fl- (flvector-ref v (fx+ bib 1)) (fl* dyb mjb)))
              (flvector-set! v (fx+ bib 2) (fl- (flvector-ref v (fx+ bib 2)) (fl* dzb mjb)))
              (flvector-set! v bjb (fl+ (flvector-ref v bjb) (fl* dxb mib)))
              (flvector-set! v (fx+ bjb 1) (fl+ (flvector-ref v (fx+ bjb 1)) (fl* dyb mib)))
              (flvector-set! v (fx+ bjb 2) (fl+ (flvector-ref v (fx+ bjb 2)) (fl* dzb mib))))
                (inner (fx+ j 2)))
              (when (fx< j n-bodies)
            (let* ((bic (fx* i 3))
                   (bjc (fx* j 3))
                   (dxc (fl- (flvector-ref p bic) (flvector-ref p bjc)))
                   (dyc (fl- (flvector-ref p (fx+ bic 1)) (flvector-ref p (fx+ bjc 1))))
                   (dzc (fl- (flvector-ref p (fx+ bic 2)) (flvector-ref p (fx+ bjc 2))))
                   (d2c (fl+ (fl+ (fl* dxc dxc) (fl* dyc dyc)) (fl* dzc dzc)))
                   (magc (fl/ dt (fl* d2c (flsqrt d2c))))
                   (mjc (fl* (flvector-ref m j) magc))
                   (mic (fl* (flvector-ref m i) magc)))
              (flvector-set! v bic (fl- (flvector-ref v bic) (fl* dxc mjc)))
              (flvector-set! v (fx+ bic 1) (fl- (flvector-ref v (fx+ bic 1)) (fl* dyc mjc)))
              (flvector-set! v (fx+ bic 2) (fl- (flvector-ref v (fx+ bic 2)) (fl* dzc mjc)))
              (flvector-set! v bjc (fl+ (flvector-ref v bjc) (fl* dxc mic)))
              (flvector-set! v (fx+ bjc 1) (fl+ (flvector-ref v (fx+ bjc 1)) (fl* dyc mic)))
              (flvector-set! v (fx+ bjc 2) (fl+ (flvector-ref v (fx+ bjc 2)) (fl* dzc mic))))
                0)))
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
                1000)))
    (init!)
    (offset-momentum! vel mass)
    (display (energy pos vel mass)) (newline)
    (let loop ((i 0))
      (when (fx< i n) (advance! pos vel mass) (loop (fx+ i 1))))
    (display (energy pos vel mass)) (newline)))

(main)
