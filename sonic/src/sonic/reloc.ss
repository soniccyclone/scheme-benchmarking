;;; Relocations against the constant pool.
;;;
;;; Bead 6gk.17. `object.ss` emits `.rodata` and reserves an 8-aligned slot for
;;; it, but nothing referenced it: a pooled f64 is RIP-relative on x86-64 and an
;;; `auipc` pair on RV64, and both need a relocation. This is that.
;;;
;;; ## Why the two targets need structurally different relocations
;;;
;;; x86-64 has a PC-relative addressing mode, so loading a pooled double is ONE
;;; instruction with a 32-bit displacement the linker fills in:
;;;
;;;     movsd xmm0, [rip + disp32]        R_X86_64_PC32
;;;
;;; RV64 has no such mode. The address is built in two instructions, and BOTH
;;; need relocating against the same symbol, because the low 12 bits and the
;;; high 20 are split across them:
;;;
;;;     auipc t0, %pcrel_hi(sym)          R_RISCV_PCREL_HI20
;;;     fld   fa0, %pcrel_lo(label)(t0)   R_RISCV_PCREL_LO12_I
;;;
;;; And the LO12 relocation does not name the symbol. It names the LABEL OF THE
;;; HI20 INSTRUCTION, because the linker has to recover which high part this low
;;; part pairs with. That is the detail that makes a naive port emit an object
;;; the linker silently mis-resolves, so it is modelled explicitly here rather
;;; than left to whoever writes the emitter.

(library (sonic reloc)
  (export make-reloc reloc? reloc-offset reloc-type reloc-symbol reloc-addend
          reloc-type-code
          pool-load-relocs
          relocs->bytevector reloc-entry-size
          R_X86_64_PC32 R_RISCV_PCREL_HI20 R_RISCV_PCREL_LO12_I)
  (import (chezscheme))

  ;; ELF relocation type codes, per each psABI.
  (define R_X86_64_PC32          2)
  (define R_RISCV_PCREL_HI20    23)
  (define R_RISCV_PCREL_LO12_I  24)

  (define-record-type (reloc make-reloc reloc?)
    (fields offset      ; byte offset into .text
            type        ; symbolic
            symbol      ; symbol index, or the paired HI20's label for LO12
            addend))

  (define (reloc-type-code t)
    (case t
      ((pc32)       R_X86_64_PC32)
      ((pcrel-hi20) R_RISCV_PCREL_HI20)
      ((pcrel-lo12) R_RISCV_PCREL_LO12_I)
      (else (error 'reloc-type-code "unknown relocation type" t))))

  ;; What a pooled-constant load needs, per target.
  ;;
  ;; `text-offset` is where the instruction sequence starts; `sym` is the
  ;; .rodata symbol index; `pool-offset` is the constant's offset within the
  ;; pool, which rides in the addend.
  ;;
  ;; Returns the relocations only. The instruction bytes are the encoder's job;
  ;; this says what the linker must patch and where.
  (define (pool-load-relocs target text-offset sym pool-offset)
    (case target
      ;; movsd xmm, [rip+disp32] : the disp32 sits at byte 4 of the
      ;; instruction (F2 0F 10 /r with a RIP-relative ModRM), and the addend is
      ;; -4 because PC-relative displacement on x86-64 is measured from the END
      ;; of the instruction, not from the field.
      ((x86-64)
       (list (make-reloc (+ text-offset 4) 'pc32 sym (- pool-offset 4))))
      ;; auipc + fld. Two relocations, and the second names the FIRST
      ;; instruction's label rather than the symbol -- see the header.
      ((rv64)
       (list (make-reloc text-offset 'pcrel-hi20 sym pool-offset)
             (make-reloc (+ text-offset 4) 'pcrel-lo12 text-offset 0)))
      (else (error 'pool-load-relocs "unknown target" target))))

  ;; Elf64_Rela is 24 bytes: offset, info, addend, all 8 bytes little-endian.
  (define reloc-entry-size 24)

  (define (u64->bytes n)
    (let loop ((i 0) (acc '()))
      (if (= i 8)
          (reverse acc)
          (loop (+ i 1)
                (cons (bitwise-and (bitwise-arithmetic-shift-right n (* 8 i)) #xff)
                      acc)))))

  (define (relocs->bytevector rs)
    (u8-list->bytevector
     (apply append
            (map (lambda (r)
                   (append (u64->bytes (reloc-offset r))
                           ;; info = (sym << 32) | type
                           (u64->bytes
                            (bitwise-ior
                             (bitwise-arithmetic-shift-left (reloc-symbol r) 32)
                             (reloc-type-code (reloc-type r))))
                           (u64->bytes (reloc-addend r))))
                 rs))))
  )
