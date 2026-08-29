#!r6rs
;;; The smallest useful driver, compiled and booted on bare metal.
;;;
;;; Allocates nothing -- every value is a machine word in a register, which is
;;; the class of program the freestanding entry can serve and the class an early
;;; boot path is. It uses a GLOBAL, which is not incidental: a global cell lives
;;; in RAM above 2^31 on this machine, and reaching one there needs two more
;;; instructions than `lui`+`addi` (see rv64-address-of).
(define uart #x10000000)

(define (down n)
  (if (fx= n 0)
      0
      (begin (mmio-u8-set! uart (+ 48 n))
             (down (fx- n 1)))))

(define (main)
  (begin (mmio-u8-set! uart 83)      ; S
         (down 3)                    ; 3 2 1
         (mmio-u8-set! uart 10)))

(main)
