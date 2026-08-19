#!r6rs
;;; PROBE 4: can a leaf function be allocation-free?
;;; Interrupt handlers and early boot cannot allocate. If pure fixnum work still
;;; reaches the allocator, kernel paths are not expressible today.
;;; FALSIFIABLE: any call to %make-vector / a bump-allocator in `kernelish`.
(define v (make-vector 8 0))

(define (kernelish i)
  (fx+ (fx* (vector-ref v i) 3) (fx- (vector-ref v i) 1)))

(display (fx->fl (kernelish 2)))
(newline)
