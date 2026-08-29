;;; Build the bare-metal boot image the rv64 suite runs. Kept as a script as
;;; well as a test helper because shrinking a boot failure means running it by
;;; hand, and a boot failure is silent by nature: there is no exit code, no
;;; message, and nothing on the serial line to distinguish "did not load" from
;;; "loaded and faulted on the first instruction".
;;;
;;; Entry at 0x80000000, a 16550 at 0x10000000: qemu's `virt` machine.
(import (chezscheme) (sonic encode-rv64) (sonic elfexec))

(define code
  (u8-list->bytevector
   (encode-listing
    '((lui  t0 #x10000)            ; UART base 0x10000000
      (addi t1 zero 75)            ; K
      (sb   t1 t0 0)
      (addi t1 zero 10)            ; newline
      (sb   t1 t0 0)
      spin
      (jal  zero spin)))))

;; THE LOAD BASE AND THE ENTRY ARE TWO DIFFERENT ADDRESSES, and only the second
;; was ever a parameter. `build-executable` takes `entry`, so the first attempt
;; set e_entry to 0x80000000 and still emitted a text segment at 0x400000 --
;; qemu loaded the code where the program header said, jumped where e_entry
;; said, and executed empty RAM in silence. `elf-load-base` is a parameter now.
;;
;; WITH `-bios none` THE RESET VECTOR GOES TO 0x80000000 AND e_entry IS NOT
;; CONSULTED. That is why the base is one page below: `text-file-offset` puts
;; the code on the second page, so a base of 0x7FFFF000 lands the first
;; instruction exactly on the reset vector. The header page is below RAM and
;; qemu simply does not place it, which is harmless -- nothing reads a program
;; header at run time -- but it is the fragile part of this arrangement and the
;; alternative is a freestanding layout with no header page at all.
;;
;; The OpenSBI path was tried and rejected on evidence: `-machine virt -kernel`
;; without `-bios none` boots OpenSBI, which prints its banner and hands off in
;; S-mode with PMP configured, and the same store to 0x10000000 then produces
;; nothing at all. Bare M-mode is both simpler and the thing a kernel wants.
(define img
  (parameterize ((elf-load-base #x7FFFF000))
    (build-executable 'rv64 code (make-bytevector 0)
                      (elf-text-vaddr) #x80300000 4096)))

(write-executable "/tmp/sonic-boot.elf" img)
