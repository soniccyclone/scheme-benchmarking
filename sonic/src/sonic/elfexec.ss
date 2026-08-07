;;; A static ELF executable.
;;;
;;; `object.ss` emits a relocatable object, which is the right thing to hand a
;;; linker. This emits something the KERNEL will run, because for a benchmark
;;; there is nothing to link against: D25 puts no libc in the running system, so
;;; the image is our code, our constants, and our heap.
;;;
;;; Two PT_LOAD segments rather than one RWX segment. One RWX segment is shorter
;;; to write and every modern kernel is entitled to refuse it; more to the point,
;;; a benchmark that runs with its code writable is measuring a configuration
;;; nobody would ship. Code and constants are R+X, the heap is R+W.
;;;
;;; The heap segment has filesz 0 and a nonzero memsz -- it is .bss, zeroed by
;;; the kernel. That is why the image is a few kilobytes rather than a megabyte.

(library (sonic elfexec)
  (export build-executable write-executable pool-offset-for
          elf-load-base elf-text-vaddr elf-page-size)
  (import (chezscheme))

  (define elf-page-size 4096)
  (define elf-load-base #x400000)
  (define elf-header-size 64)
  (define ph-entry-size 56)
  (define ph-count 2)

  ;; Code starts on the second page: the headers live on the first, and giving
  ;; the text its own page is what lets the two segments have different
  ;; permissions without overlapping.
  (define text-file-offset elf-page-size)
  (define elf-text-vaddr (+ elf-load-base text-file-offset))

  (define (u16 n) (list (bitwise-and n #xff) (bitwise-and (ash n -8) #xff)))
  (define (u32 n)
    (let loop ((i 0) (acc '()))
      (if (= i 4) (reverse acc)
          (loop (+ i 1) (cons (bitwise-and (ash n (* -8 i)) #xff) acc)))))
  (define (u64 n)
    (let loop ((i 0) (acc '()))
      (if (= i 8) (reverse acc)
          (loop (+ i 1) (cons (bitwise-and (ash n (* -8 i)) #xff) acc)))))

  (define (align-up n a) (if (zero? (modulo n a)) n (+ n (- a (modulo n a)))))

  ;; Where the constant pool lands, given the code size.
  ;;
  ;; It must be aligned to `pool-alignment` (16), and not because it is tidy: a
  ;; sign mask is a 128-bit SSE operand, and a non-VEX `xorpd` reading an
  ;; unaligned 16-byte memory operand FAULTS. litpool.ss aligns entries within
  ;; the pool; that is worth nothing if the pool itself starts at an odd offset,
  ;; which is exactly what happened -- `flneg` on its own segfaulted while every
  ;; other instruction in the program was fine.
  (define (pool-offset-for code-size) (align-up code-size 16))

  ;; code    : bytevector, already at its final addresses
  ;; pool    : bytevector of constants, placed immediately after the code
  ;; entry   : absolute virtual address of _start
  ;; data-va : virtual address of the writable segment
  ;; data-sz : its size in memory (filesz is 0; it is .bss)
  (define (build-executable target code pool entry data-va data-sz)
    (unless (eq? target 'x86-64)
      (error 'build-executable
             "only x86-64 is emitted as a runnable image; RV64 output is
              verified by the smoke gate and run under qemu from an object"
             target))
    (let* ((code-size (bytevector-length code))
           (pool-size (bytevector-length pool))
           (pool-at (pool-offset-for code-size))
           (text-size (+ pool-at pool-size))
           (phdrs
            (append
             ;; PT_LOAD, R+X: the headers, the code, and the constants. The
             ;; segment starts at file offset 0 so the ELF header itself is
             ;; mapped, which is what a p_offset of 0 conventionally means.
             (u32 1) (u32 5)                        ; type=PT_LOAD, flags=R|X
             (u64 0) (u64 elf-load-base) (u64 elf-load-base)
             (u64 (+ text-file-offset text-size))
             (u64 (+ text-file-offset text-size))
             (u64 elf-page-size)
             ;; PT_LOAD, R+W: the heap. filesz 0, so the kernel zeroes it.
             (u32 1) (u32 6)                        ; type=PT_LOAD, flags=R|W
             (u64 0) (u64 data-va) (u64 data-va)
             (u64 0) (u64 data-sz)
             (u64 elf-page-size)))
           (ehdr
            (append
             '(#x7f #x45 #x4c #x46)                 ; magic
             '(2 1 1 0)                             ; 64-bit, LSB, version, SysV
             '(0 0 0 0 0 0 0 0)                     ; padding
             (u16 2)                                ; ET_EXEC
             (u16 #x3e)                             ; EM_X86_64
             (u32 1)                                ; version
             (u64 entry)
             (u64 elf-header-size)                  ; e_phoff
             (u64 0)                                ; e_shoff: no sections
             (u32 0)                                ; e_flags
             (u16 elf-header-size)
             (u16 ph-entry-size) (u16 ph-count)
             (u16 0) (u16 0) (u16 0)))              ; no section headers
           (total (+ text-file-offset text-size))
           (bv (make-bytevector total 0)))
      (let blit ((bs (append ehdr phdrs)) (i 0))
        (unless (null? bs)
          (bytevector-u8-set! bv i (car bs))
          (blit (cdr bs) (+ i 1))))
      (bytevector-copy! code 0 bv text-file-offset code-size)
      ;; The gap between the code and the pool stays zero, which is what
      ;; `make-bytevector` already gave us.
      (bytevector-copy! pool 0 bv (+ text-file-offset pool-at) pool-size)
      bv))

  (define (write-executable path bv)
    (when (file-exists? path) (delete-file path))
    (let ((p (open-file-output-port path)))
      (put-bytevector p bv)
      (close-port p)))
  )
