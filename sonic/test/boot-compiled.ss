;;; Compile a SonicScheme program for bare metal and boot it.
;;;
;;; Everything the hosted path does, minus a loader: nothing set `sp`, there is
;;; no argv, and there is nothing to exit to. See rv64-freestanding-listing.
;;;
;;; ALLOCATION-FREE ONLY. The heap pointer cell is not initialised, so a program
;;; that allocates bumps from whatever the cell holds. That is stated at the
;;; entry and is what bead 5em makes checkable.
(import (chezscheme) (sonic driver) (sonic pipeline) (sonic runtime) (sonic elfexec))

(define src "test/boot-uart.sps")

;; Text at 0x80000000, which is where `-bios none` sends the reset vector; the
;; load base is one page lower because text-file-offset puts code on the second
;; page. Data at 0x80200000, well clear of the image. The heap is never touched
;; but its size still sizes the .bss LOAD, so it is small here rather than the
;; hosted 256 MB -- qemu's virt default is 128 MB of RAM.
(parameterize ((elf-load-base #x7FFFF000)
               (data-base     #x80200000)
               (heap-size     (* 1024 1024))
               (freestanding? #t))
  (compile-sonic-to-file src '() "/tmp/sonic-boot-compiled.elf" 'rv64))
