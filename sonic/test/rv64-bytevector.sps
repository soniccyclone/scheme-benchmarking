#!r6rs
;;; Byte-addressed storage, run on both targets and compared.
;;;
;;; A 4 KiB ring buffer in `make-vector` is 32 KiB of heap and every element is
;;; scanned by the collector for a pointer it cannot contain. The same ring in a
;;; bytevector is 4 KiB and is skipped entirely, because the header says
;;; `heap-type-bytevector` and the collector does not trace those. That is why a
;;; kernel needs these, and it is why the payload width had to reach the
;;; allocator rather than being emulated on top of a vector.

(define b (make-bytevector 6 65))

;; A second one, allocated after the first, so that if the first's bump rounded
;; its byte count wrongly the two would overlap and this would corrupt it.
(define c (make-bytevector 3 7))

(define (main)
  (begin
    (bytevector-u8-set! b 0 72)
    (bytevector-u8-set! b 5 10)
    ;; The length field is the BYTE count the program asked for, not the word
    ;; count the allocator rounded up to.
    (display-word (bytevector-length b))
    (display-word (bytevector-length c))
    (display-word (bytevector-u8-ref b 0))
    ;; UNTOUCHED NEIGHBOURS. A byte store that wrote a whole word would have
    ;; flattened these to 0, and the fill value is what proves it did not.
    (display-word (bytevector-u8-ref b 1))
    (display-word (bytevector-u8-ref b 4))
    (display-word (bytevector-u8-ref b 5))
    ;; And the second object is intact, which is the alignment claim.
    (display-word (bytevector-u8-ref c 0))
    (display-word (bytevector-u8-ref c 2))))

(main)
