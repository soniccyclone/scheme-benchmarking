;;;; nbody, configuration 5: tuned conformant Common Lisp.
;;;;
;;;; This is the thing the whole project is measured against. Everything used
;;;; here is ANSI CL, in the standard, portable in principle to any conforming
;;;; implementation:
;;;;
;;;;   (declaim (optimize (speed 3) (safety 0) ...))   the POLICY SWITCH
;;;;   (simple-array double-float (*))                  declared unboxed storage
;;;;   (declare (type ...))                             PREMISES the inferencer
;;;;                                                    propagates
;;;;
;;;; No sb-simd: scalar only. See LEDGER.md D15 for why, which is that the
;;;; contrib stops at AVX2 while this machine and gcc -march=native reach
;;;; AVX-512, so including it would measure vector width instead of language.
;;;;
;;;; Configuration 9 runs this same file under ECL and CLISP unchanged, which
;;;; separates "Common Lisp is fast" from "SBCL is fast".
;;;;
;;;; Written from SPEC.md. Expression order matches ref.c exactly.

#+sbcl (require :sb-posix)

(declaim (optimize (speed 3) (safety 0) (debug 0) (compilation-speed 0)))

(defconstant +pi+ 3.141592653589793d0)
(defconstant +solar-mass+ (* 4d0 +pi+ +pi+))
(defconstant +days-per-year+ 365.24d0)
(defconstant +dt+ 0.01d0)
(defconstant +nbody+ 5)
(defconstant +slots+ 7)

(deftype dvec () '(simple-array double-float (*)))

(defvar *b* (make-array (* +nbody+ +slots+)
                        :element-type 'double-float
                        :initial-element 0d0))
(declaim (type dvec *b*))

(declaim (inline g s!))
(defun g (i k)
  (declare (type (integer 0 4) i) (type (integer 0 6) k))
  (aref *b* (+ (* i +slots+) k)))
(defun s! (i k v)
  (declare (type (integer 0 4) i) (type (integer 0 6) k) (type double-float v))
  (setf (aref *b* (+ (* i +slots+) k)) v))

(defun put! (i x y z vx vy vz m)
  (declare (type (integer 0 4) i) (type double-float x y z vx vy vz m))
  (s! i 0 x) (s! i 1 y) (s! i 2 z)
  (s! i 3 (* vx +days-per-year+))
  (s! i 4 (* vy +days-per-year+))
  (s! i 5 (* vz +days-per-year+))
  (s! i 6 (* m +solar-mass+)))

(defun init! ()
  (put! 0 0d0 0d0 0d0 0d0 0d0 0d0 1d0)
  (put! 1 4.84143144246472090d+00 -1.16032004402742839d+00 -1.03622044471123109d-01
          1.66007664274403694d-03 7.69901118419740425d-03 -6.90460016972063023d-05
          9.54791938424326609d-04)
  (put! 2 8.34336671824457987d+00 4.12479856412430479d+00 -4.03523417114321381d-01
          -2.76742510726862411d-03 4.99852801234917238d-03 2.30417297573763929d-05
          2.85885980666130812d-04)
  (put! 3 1.28943695621391310d+01 -1.51111514016986312d+01 -2.23307578892655734d-01
          2.96460137564761618d-03 2.37847173959480950d-03 -2.96589568540237556d-05
          4.36624404335156298d-05)
  (put! 4 1.53796971148509165d+01 -2.59193146099879641d+01 1.79258772950371181d-01
          2.68067772490389322d-03 1.62824170038242295d-03 -9.51592254519715870d-05
          5.15138902046611451d-05))

(defun offset-momentum! ()
  (let ((px 0d0) (py 0d0) (pz 0d0))
    (declare (type double-float px py pz))
    (dotimes (i +nbody+)
      (incf px (* (g i 3) (g i 6)))
      (incf py (* (g i 4) (g i 6)))
      (incf pz (* (g i 5) (g i 6))))
    (s! 0 3 (/ (- 0d0 px) +solar-mass+))
    (s! 0 4 (/ (- 0d0 py) +solar-mass+))
    (s! 0 5 (/ (- 0d0 pz) +solar-mass+))))

;; Velocities from forces at current positions, then positions. Not fused.
(defun advance! ()
  (dotimes (i +nbody+)
    (loop for j of-type fixnum from (1+ i) below +nbody+ do
      (let* ((dx (- (g i 0) (g j 0)))
             (dy (- (g i 1) (g j 1)))
             (dz (- (g i 2) (g j 2)))
             (d2 (+ (+ (* dx dx) (* dy dy)) (* dz dz)))
             (mag (/ +dt+ (* d2 (sqrt d2))))
             (mj (* (g j 6) mag))
             (mi (* (g i 6) mag)))
        (declare (type double-float dx dy dz d2 mag mj mi))
        (s! i 3 (- (g i 3) (* dx mj)))
        (s! i 4 (- (g i 4) (* dy mj)))
        (s! i 5 (- (g i 5) (* dz mj)))
        (s! j 3 (+ (g j 3) (* dx mi)))
        (s! j 4 (+ (g j 4) (* dy mi)))
        (s! j 5 (+ (g j 5) (* dz mi))))))
  (dotimes (i +nbody+)
    (s! i 0 (+ (g i 0) (* +dt+ (g i 3))))
    (s! i 1 (+ (g i 1) (* +dt+ (g i 4))))
    (s! i 2 (+ (g i 2) (* +dt+ (g i 5))))))

(defun kinetic (i)
  (declare (type (integer 0 4) i))
  (* (* 0.5d0 (g i 6))
     (+ (+ (* (g i 3) (g i 3)) (* (g i 4) (g i 4))) (* (g i 5) (g i 5)))))

(defun pair-potential (i j)
  (declare (type (integer 0 4) i j))
  (let* ((dx (- (g i 0) (g j 0)))
         (dy (- (g i 1) (g j 1)))
         (dz (- (g i 2) (g j 2)))
         (d (sqrt (+ (+ (* dx dx) (* dy dy)) (* dz dz)))))
    (declare (type double-float dx dy dz d))
    (/ (* (g i 6) (g j 6)) d)))

(defun energy ()
  (let ((e 0d0))
    (declare (type double-float e))
    (dotimes (i +nbody+ e)
      (setf e (+ e (kinetic i)))
      (loop for j of-type fixnum from (1+ i) below +nbody+ do
        (setf e (- e (pair-potential i j)))))))

(defun main ()
  ;; N comes from the NBODY_N environment variable. SBCL, ECL and CLISP each
  ;; expose command-line arguments differently, and CLISP's -x rejects a
  ;; trailing argument outright, so an environment variable is the one channel
  ;; all three share. Configuration 9 runs this file unchanged under all three,
  ;; which is the whole point of it.
  (let* ((raw #+sbcl  (sb-posix:getenv "NBODY_N")
              #+ecl   (ext:getenv "NBODY_N")
              #+clisp (ext:getenv "NBODY_N")
              #-(or sbcl ecl clisp) nil)
         (n (or (and raw (parse-integer raw :junk-allowed t)) 1000)))
    (declare (type fixnum n))
    (init!)
    (offset-momentum!)
    (format t "~,9f~%" (energy))
    (dotimes (i n) (advance!))
    (format t "~,9f~%" (energy))))
