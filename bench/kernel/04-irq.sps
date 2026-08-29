#!r6rs
;;; Acknowledging an interrupt, which is the case where a load's VALUE is not
;;; what the load is for.
;;;
;;; Two shapes here, and today's compiler gets both wrong:
;;;
;;;   1. A read whose result is discarded. On a 16550, reading the interrupt
;;;      identification register is what CLEARS the interrupt. Dead-code
;;;      elimination deletes it -- probe 5 watched loads go 4 to 2 at DCE -- and
;;;      the device then interrupts forever.
;;;
;;;   2. Two reads of one address with no write between them. Common-subexpression
;;;      elimination rewrites the second use onto the first load -- probe 7 caught
;;;      `add t.5 t.7` becoming `add t.5 t.5` -- so a FIFO drained twice returns
;;;      the same byte twice.

(define uart-base #x10000000)
(define uart-rbr  (+ uart-base 0))   ; receive buffer, reading pops the FIFO
(define uart-iir  (+ uart-base 2))   ; interrupt identification, reading clears
(define uart-lsr  (+ uart-base 5))
(define lsr-data-ready #x01)

;; Shape 1. The value is deliberately unused; the READ is the side effect.
(define (irq-ack)
  (begin (mmio-u8-ref uart-iir)
         0))

;; Shape 2. Two pops of the FIFO. These are two different bytes and must be two
;; loads.
(define (read-pair)
  (let ((a (mmio-u8-ref uart-rbr))
        (b (mmio-u8-ref uart-rbr)))
    (fx+ (fx* a 256) b)))

(define (data-ready?)
  (u64and (mmio-u8-ref uart-lsr) lsr-data-ready))

(define (service n acc)
  (if (fx= n 0)
      acc
      (if (u64= (data-ready?) 0)
          (begin (irq-ack) acc)
          (service (fx- n 1) (fx+ acc (read-pair))))))

(define (main)
  (display-word (service 4 0)))

(main)
