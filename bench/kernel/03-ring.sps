#!r6rs
;;; A single-producer single-consumer ring buffer, of the kind that sits between
;;; an interrupt handler and the thread it wakes.
;;;
;;; Two things this needs that the language does not have: a RECORD, so head and
;;; tail and storage are one object with named fields rather than three parallel
;;; vectors, and a BYTEVECTOR, so the storage is bytes rather than one tagged
;;; word per byte. A 4 KiB ring in `make-vector` is 32 KiB of heap and every
;;; element is scanned by the collector for pointers it cannot contain.

(define-record-type ring
  (make-ring storage capacity head tail)
  ring?
  (storage  ring-storage)
  (capacity ring-capacity)
  (head     ring-head  set-ring-head!)
  (tail     ring-tail  set-ring-tail!))

(define (ring-new n)
  (make-ring (make-bytevector n 0) n 0 0))

(define (wrap r i)
  (if (fx= i (ring-capacity r)) 0 i))

(define (ring-empty? r)
  (fx= (ring-head r) (ring-tail r)))

(define (ring-full? r)
  (fx= (wrap r (fx+ (ring-tail r) 1)) (ring-head r)))

;; The producer. Returns 1 on success and 0 if the ring is full; a kernel drops
;; rather than blocks here, because the caller is an interrupt handler.
(define (ring-push! r b)
  (if (ring-full? r)
      0
      (let ((t (ring-tail r)))
        (bytevector-u8-set! (ring-storage r) t b)
        (set-ring-tail! r (wrap r (fx+ t 1)))
        1)))

;; The consumer. Raises rather than returning a sentinel, because "the ring was
;; empty" is a different kind of answer from "the byte was zero".
(define (ring-pop! r)
  (if (ring-empty? r)
      (raise 'ring-empty)
      (let* ((h (ring-head r))
             (b (bytevector-u8-ref (ring-storage r) h)))
        (set-ring-head! r (wrap r (fx+ h 1)))
        b)))

(define (drain r acc)
  (guard (e (#t acc))
    (drain r (fx+ acc (ring-pop! r)))))

(define (main)
  (let ((r (ring-new 16)))
    (ring-push! r 3)
    (ring-push! r 4)
    (display-word (drain r 0))))

(main)
