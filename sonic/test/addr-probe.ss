;;; Does lui+addi reach an address at or above 2^31 on RV64?
;;;
;;; The falsifiable claim: `lui` sign-extends its 32-bit result on RV64, so any
;;; address with bit 31 set materialises as a huge negative number. If that is
;;; wrong, the sequence below computes 0x80200000 and this prints Y. qemu's
;;; `virt` machine starts RAM exactly at 0x80000000, so if the claim holds, a
;;; freestanding heap cannot be addressed by the sequence the whole RV64 runtime
;;; uses -- every `lui`/`addi` pair in runtime.ss.
(import (chezscheme) (sonic encode-rv64) (sonic elfexec))

(define (lo12 a) (let ((l (bitwise-and a #xfff))) (if (>= l 2048) (- l 4096) l)))
(define (hi20 a) (bitwise-and (ash (+ a 2048) -12) #xfffff))

(define code
  (u8-list->bytevector
   (encode-listing
    `((lui  t3 #x10000)                       ; UART base
      ;; runtime.ss's sequence, verbatim
      (lui  t0 ,(hi20 #x80200000))
      (addi t0 t0 ,(lo12 #x80200000))
      ;; the value it is supposed to be: (1 << 31) + 0x200000
      (addi t1 zero 1)
      (slli t1 t1 31)
      (lui  t2 #x200)
      (add  t1 t1 t2)
      (beq  t0 t1 same)
      (addi t4 zero 78)                       ; N
      (sb   t4 t3 0)
      (jal  zero done)
      same
      (addi t4 zero 89)                       ; Y
      (sb   t4 t3 0)
      done
      (addi t4 zero 10)
      (sb   t4 t3 0)
      spin
      (jal  zero spin)))))

(define img
  (parameterize ((elf-load-base #x7FFFF000))
    (build-executable 'rv64 code (make-bytevector 0)
                      (elf-text-vaddr) #x80300000 4096)))
(write-executable "/tmp/sonic-addr.elf" img)
