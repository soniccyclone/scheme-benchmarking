#!r6rs
;;; A 16550 UART driver for the RV64 `virt` machine.
;;;
;;; This is the smallest useful driver there is, and it is what a freestanding
;;; image needs before it can say anything at all. qemu's `virt` puts a 16550 at
;;; 0x10000000: byte 0 is the transmit holding register, byte 5 is the line
;;; status register, and bit 5 of LSR means "THR is empty, you may write".
;;;
;;; Every line here is a capability this compiler does not have. That is the
;;; point of the file.

;; The device window. A raw physical address with a fixed width -- not a Scheme
;; object with a length header, which is what makes `mmio-*` a different family
;; from `vector-ref` rather than a control on it.
(define uart-base #x10000000)
(define uart-thr  (+ uart-base 0))
(define uart-lsr  (+ uart-base 5))
(define lsr-thr-empty #x20)

;; Poll until the transmitter is ready. The two reads of `uart-lsr` in one loop
;; iteration MUST both happen: folding them makes this loop either spin forever
;; or fall through on a stale bit.
(define (uart-ready?)
  (u64and (mmio-u8-ref uart-lsr) lsr-thr-empty))

(define (uart-wait)
  (if (u64= (uart-ready?) 0)
      (uart-wait)
      0))

(define (uart-put-byte b)
  (begin (uart-wait)
         (mmio-u8-set! uart-thr b)))

;; A string is a bytevector as far as a UART is concerned.
(define (uart-write bv i n)
  (if (fx< i n)
      (begin (uart-put-byte (bytevector-u8-ref bv i))
             (uart-write bv (fx+ i 1) n))
      0))

(define hello (bytevector 72 101 108 108 111 10))

(define (main)
  (uart-write hello 0 (bytevector-length hello)))

(main)
