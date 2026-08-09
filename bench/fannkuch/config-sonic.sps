#!r6rs
;;; fannkuch-redux, SonicScheme configuration.
;;;
;;; Written from SPEC.md in this directory, like every other variant. The
;;; enumeration order is part of that specification -- the checksum depends on
;;; which permutation is numbered even -- so the control flow here matches
;;; `ref.c` step for step and is not rearranged for taste.
;;;
;;; WHAT THIS VARIANT IS FOR. nbody's indices are `3i+k` off a vector whose
;;; length was proved at its allocation, so its bounds checks fall to the
;;; interval domain almost for free. Every access here is different: the index
;;; comes from arithmetic on a loop variable, or out of ANOTHER element of the
;;; array. `(vector-ref perm (vector-ref perm 0))` is the shape the domain has
;;; to actually work on, and `cnt[r]` is indexed by a value that only the
;;; enumeration invariant keeps below `n`.
;;;
;;; The vectors are TOP-LEVEL rather than parameters, which is deliberate and
;;; the opposite of what nbody's variant does: it hands its arrays to the
;;; kernels to defeat allocation-site reasoning, and this one leaves them where
;;; the allocation is visible, so the two exercise opposite halves of the same
;;; analysis.

(define n 7)

(define perm  (make-vector 7 0))
(define perm1 (make-vector 7 0))
(define cnt   (make-vector 7 0))

;; Reverse perm[0..k] in place.
(define (flip-prefix k)
  (let loop ((i 0) (j k))
    (if (fx< i j)
        (let ((t (vector-ref perm i)))
          (vector-set! perm i (vector-ref perm j))
          (vector-set! perm j t)
          (loop (fx+ i 1) (fx- j 1)))
        0)))

;; Flip until the head is 0, counting. Destroys perm, which is why the caller
;; works on a copy.
(define (count-flips f)
  (let ((k (vector-ref perm 0)))
    (if (fx= k 0)
        f
        (begin (flip-prefix k) (count-flips (fx+ f 1))))))

(define (copy-perm i)
  (if (fx< i n)
      (begin (vector-set! perm i (vector-ref perm1 i)) (copy-perm (fx+ i 1)))
      0))

;; count[r-1] := r, down to r = 1.
(define (fill-counts r)
  (if (fx> r 1)
      (begin (vector-set! cnt (fx- r 1) r) (fill-counts (fx- r 1)))
      0))

;; Rotate perm1[0..r] left by one: perm1[0] moves to perm1[r].
(define (rotate r)
  (let ((p0 (vector-ref perm1 0)))
    (let shift ((i 0))
      (if (fx< i r)
          (begin (vector-set! perm1 i (vector-ref perm1 (fx+ i 1)))
                 (shift (fx+ i 1)))
          (vector-set! perm1 r p0)))))

;; `sign` is the parity of the permutation number: 0 adds, 1 subtracts.
(define (step r maxflips checksum sign)
  (begin
    (fill-counts r)
    (copy-perm 0)
    (let ((f (count-flips 0)))
      (let ((mx (if (fx> f maxflips) f maxflips))
            (cs (if (fx= sign 0) (fx+ checksum f) (fx- checksum f))))
        (next 1 mx cs (fx- 1 sign))))))

;; Advance to the next permutation. Returns through `step` unless the
;; enumeration is finished, which is `r = n`.
(define (next r maxflips checksum sign)
  (if (fx= r n)
      (begin (display (fx->fl checksum)) (newline)
             (display (fx->fl maxflips)) (newline)
             0)
      (begin
        (rotate r)
        (vector-set! cnt r (fx- (vector-ref cnt r) 1))
        (if (fx> (vector-ref cnt r) 0)
            (step r maxflips checksum sign)
            (next (fx+ r 1) maxflips checksum sign)))))

(define (init i)
  (if (fx< i n)
      (begin (vector-set! perm1 i i) (init (fx+ i 1)))
      0))

(define (main)
  (begin (init 0) (step n 0 0 0)))

(main)
