#!r6rs
;;; PROBE 8: the shape that decides region-scoped vs object-scoped volatile.
;;; A driver copies FROM a device register INTO ordinary memory. One expression,
;;; two objects, different volatility.
;;; FALSIFIABLE: if this shape cannot arise, a region can express volatility.
(define dev (make-vector 4 0))   ; device registers
(define buf (make-vector 64 0))  ; ordinary RAM

(define (drain i)
  ;; one expression touching both: the read must happen every time,
  ;; the write and the index arithmetic should optimise normally
  (vector-set! buf i (vector-ref dev 0)))

(drain 0)
(drain 1)
(display 0.0)
(newline)
