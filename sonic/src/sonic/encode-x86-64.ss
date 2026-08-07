;;; x86-64 machine code encoding.
;;;
;;; E2-X86ENC. Takes the target instructions `sonic/src/sonic/target-x86-64.ss`
;;; produces and turns them into bytes.
;;;
;;; ## Baseline SSE2, and why that is a correctness constraint
;;;
;;; This encoder knows no AVX and no FMA, and it refuses a VEX-encoded mnemonic
;;; loudly rather than ignoring it. That is not a scope note, it is the oracle.
;;; Phase 3 measured that baseline x86-64 gcc emits zero FMA instructions, and
;;; D24 makes FP contraction a NAMED permission that is off by default. An
;;; `vfmadd231sd` here would fuse a multiply and an add that the reference C
;;; rounds separately, so our answer and ref.c's answer would differ in the low
;;; bits and the bit-exactness check would be comparing two different programs.
;;; A permission that the code generator can grant behind the policy's back is
;;; not a permission.
;;;
;;; ## Why this is harder than the RISC-V side will be
;;;
;;; RV64 has fixed 32-bit instructions and one operand layout per format. Here
;;; the length is variable, the register number is split across a REX prefix and
;;; a ModRM field, and an addressing mode may need a SIB byte whose meaning
;;; depends on which register landed in the base slot. Three encodings are
;;; special-cased by the hardware and every one of them bites us:
;;;
;;;   rsp/r12 in the base slot forces a SIB byte, because ModRM rm=100 means
;;;   "there is a SIB" rather than "the register numbered 4".
;;;
;;;   rbp/r13 in the base slot with mod=00 means "disp32, no base", so a zero
;;;   displacement has to be spelled as an explicit disp8 of 0.
;;;
;;;   rsp cannot be a SIB index at all; index=100 means "no index".
;;;
;;; And REX is the COMMON case, not the exception: the register partition in
;;; sonic/src/sonic/regs.ss puts six of the eight value registers in r8-r14, so
;;; almost every instruction touching a tagged value needs REX.B or REX.R.
;;;
;;; Which is why none of this is verified against hand-derived expectations.
;;; sonic/test/x86-64-test.ss assembles the same mnemonic with gcc and compares
;;; bytes with objdump. Hand-written x86 encodings are wrong more often than not.

(library (sonic encode-x86-64)
  (export encode-instr encode-instrs instr-length
          x86-64-supports? x86-64-mnemonics
          reject-non-baseline!
          gpr? xmm? reg-number gpr-8bit-name)
  (import (chezscheme))

  ;; --- registers ------------------------------------------------------------
  ;; The numbering is the hardware's, not the partition's. regs.ss decides which
  ;; class a register belongs to; this table only says how to spell it.

  (define gpr-table
    '((rax . 0)  (rcx . 1)  (rdx . 2)  (rbx . 3)
      (rsp . 4)  (rbp . 5)  (rsi . 6)  (rdi . 7)
      (r8  . 8)  (r9  . 9)  (r10 . 10) (r11 . 11)
      (r12 . 12) (r13 . 13) (r14 . 14) (r15 . 15)))

  (define xmm-table
    (let loop ((i 0) (acc '()))
      (if (= i 16)
          (reverse acc)
          (loop (+ i 1)
                (cons (cons (string->symbol (string-append "xmm" (number->string i))) i)
                      acc)))))

  ;; The low byte of each GPR. rsp/rbp/rsi/rdi are the trap: without a REX
  ;; prefix those encodings mean ah/ch/dh/bh, so `setl sil` needs a REX byte
  ;; that carries no bits at all (0x40) purely to change what rm=110 means.
  (define gpr8-table
    '((rax . al)  (rcx . cl)  (rdx . dl)  (rbx . bl)
      (rsp . spl) (rbp . bpl) (rsi . sil) (rdi . dil)
      (r8 . r8b) (r9 . r9b) (r10 . r10b) (r11 . r11b)
      (r12 . r12b) (r13 . r13b) (r14 . r14b) (r15 . r15b)))

  (define (gpr? x) (and (symbol? x) (assq x gpr-table) #t))
  (define (xmm? x) (and (symbol? x) (assq x xmm-table) #t))
  (define (mem? x) (and (pair? x) (eq? (car x) 'mem)))
  (define (imm? x) (and (pair? x) (eq? (car x) 'imm)))
  (define (rel? x) (and (pair? x) (eq? (car x) 'rel)))

  (define (reg-number r)
    (cond ((assq r gpr-table) => cdr)
          ((assq r xmm-table) => cdr)
          (else (error 'reg-number "not an x86-64 register" r))))

  (define (gpr-8bit-name r)
    (cond ((assq r gpr8-table) => cdr)
          (else (error 'gpr-8bit-name "not a general-purpose register" r))))

  ;; True for the four registers whose 8-bit encoding is ambiguous without REX.
  (define (needs-rex-for-byte? r) (and (gpr? r) (<= 4 (reg-number r) 7)))

  ;; --- little-endian immediates ---------------------------------------------

  (define (imm8-bytes n)
    (unless (<= -128 n 255) (error 'imm8-bytes "does not fit in a byte" n))
    (list (bitwise-and n #xff)))

  (define (imm32-bytes n)
    (unless (<= (- (expt 2 31)) n (- (expt 2 32) 1))
      (error 'imm32-bytes "does not fit in 32 bits" n))
    (let ((u (bitwise-and n #xffffffff)))
      (list (bitwise-and u #xff)
            (bitwise-and (bitwise-arithmetic-shift-right u 8) #xff)
            (bitwise-and (bitwise-arithmetic-shift-right u 16) #xff)
            (bitwise-and (bitwise-arithmetic-shift-right u 24) #xff))))

  (define (imm64-bytes n)
    (let ((u (bitwise-and n #xffffffffffffffff)))
      (let loop ((i 0) (acc '()))
        (if (= i 8)
            (reverse acc)
            (loop (+ i 1)
                  (cons (bitwise-and (bitwise-arithmetic-shift-right u (* 8 i)) #xff) acc))))))

  (define (fits-imm8? n) (<= -128 n 127))
  (define (fits-imm32? n) (<= (- (expt 2 31)) n (- (expt 2 31) 1)))

  ;; --- ModRM / SIB ----------------------------------------------------------
  ;;
  ;; Returns four values: the REX.R, REX.X and REX.B bits, and the bytes that
  ;; follow the opcode (ModRM, then SIB and displacement if the addressing mode
  ;; needs them). `regf` is either a register number or a /digit opcode
  ;; extension; the hardware does not distinguish them and neither do we.

  (define (scale-bits s)
    (case s ((1) 0) ((2) 1) ((4) 2) ((8) 3)
      (else (error 'encode-instr "SIB scale must be 1, 2, 4 or 8" s))))

  (define (rm-encoding who regf rm)
    (let ((rhi (bitwise-arithmetic-shift-right regf 3))
          (rlo (bitwise-and regf 7)))
      (cond
       ((or (gpr? rm) (xmm? rm))
        (let ((n (reg-number rm)))
          (values rhi 0 (bitwise-arithmetic-shift-right n 3)
                  (list (bitwise-ior #b11000000
                                     (bitwise-arithmetic-shift-left rlo 3)
                                     (bitwise-and n 7))))))
       ((mem? rm)
        (let* ((parts (cdr rm))
               (base  (list-ref parts 0))
               (index (list-ref parts 1))
               (scale (list-ref parts 2))
               (disp  (list-ref parts 3)))
          ;; RIP-relative: mod=00, rm=101, disp32, and NO SIB byte. This is the
          ;; one addressing form that is not expressible through the general
          ;; base/index path, because mod=00 rm=101 means "disp32 from RIP" in
          ;; 64-bit mode and "absolute disp32" in 32-bit mode -- the same
          ;; encoding, different meaning. It is spelled as a distinct base
          ;; rather than as base=#f because base=#f already means the absolute
          ;; form (SIB with base=101), and conflating them would silently turn
          ;; every pooled constant load into a load from a low absolute
          ;; address.
          ;;
          ;; The displacement is measured from the END of the instruction, so
          ;; the caller supplies the addend and the linker resolves it; see
          ;; reloc.ss `pool-load-relocs`, which subtracts 4 for exactly this.
          (when (eq? base 'rip)
            (when index (error who "RIP-relative addressing takes no index" rm)))
          (when (and base (not (eq? base 'rip)) (not (gpr? base)))
            (error who "memory base must be a general-purpose register" base))
          (when (and index (not (gpr? index)))
            (error who "memory index must be a general-purpose register" index))
          ;; rsp is index=100, which the hardware reads as "no index". There is
          ;; no REX bit that rescues this: r12 is fine because REX.X makes it
          ;; index=1100, but rsp is simply not addressable as an index.
          (when (eq? index 'rsp)
            (error who "rsp cannot be a SIB index register" rm))
          (if (eq? base 'rip)
              (values rhi 0 0
                      (append (list (bitwise-ior #b00000101
                                                 (bitwise-arithmetic-shift-left rlo 3)))
                              (imm32-bytes disp)))
          (let* ((bn (and base (reg-number base)))
                 (xn (and index (reg-number index)))
                 (need-sib (or xn (not bn) (= (bitwise-and bn 7) 4)))
                 (mod (cond ((not bn) 0)
                            ;; base&7 = 101 with mod=00 means "no base, disp32",
                            ;; so rbp and r13 must spell a zero displacement out.
                            ((and (zero? disp) (not (= (bitwise-and bn 7) 5))) 0)
                            ((fits-imm8? disp) 1)
                            (else 2)))
                 (rm-field (if need-sib 4 (bitwise-and bn 7)))
                 (modrm (bitwise-ior (bitwise-arithmetic-shift-left mod 6)
                                     (bitwise-arithmetic-shift-left rlo 3)
                                     rm-field))
                 (sib (and need-sib
                           (bitwise-ior
                            (bitwise-arithmetic-shift-left
                             (scale-bits (if xn scale 1)) 6)
                            (bitwise-arithmetic-shift-left (if xn (bitwise-and xn 7) 4) 3)
                            (if bn (bitwise-and bn 7) 5))))
                 (disp-bytes (cond ((not bn) (imm32-bytes disp))
                                   ((= mod 1) (imm8-bytes disp))
                                   ((= mod 2) (imm32-bytes disp))
                                   (else '()))))
            (values rhi
                    (if xn (bitwise-arithmetic-shift-right xn 3) 0)
                    (if bn (bitwise-arithmetic-shift-right bn 3) 0)
                    (append (list modrm) (if sib (list sib) '()) disp-bytes))))))
       (else (error who "not an r/m operand" rm)))))

  ;; Assemble one instruction from its pieces. Prefix order is fixed by the
  ;; hardware: legacy prefix (F2 for the scalar-double forms), then REX, then
  ;; the opcode. Putting REX before F2 silently changes the instruction.
  (define (asm who prefixes w opbytes regf rm imm-tail force-rex?)
    (let-values (((r x b tail) (rm-encoding who regf rm)))
      (let ((rex (bitwise-ior #x40
                              (bitwise-arithmetic-shift-left w 3)
                              (bitwise-arithmetic-shift-left r 2)
                              (bitwise-arithmetic-shift-left x 1)
                              b)))
        (append prefixes
                (if (or force-rex? (not (= rex #x40))) (list rex) '())
                opbytes tail imm-tail))))

  ;; --- the instruction table ------------------------------------------------
  ;;
  ;; Deliberately small: the subset the benchmarks need. Encoding the rest of
  ;; the ISA is on the path to no milestone.
  ;;
  ;; Where more than one legal encoding exists we take the one gas takes, so the
  ;; differential test in sonic/test/x86-64-test.ss can compare bytes rather
  ;; than compare disassembled text. For the reg-to-reg ALU forms that means the
  ;; "r/m64, r64" direction (opcodes 01/29/39/89), with the destination in the
  ;; ModRM rm field.

  ;; op-mr: dst is r/m, src is the reg field.  op-rm: the other direction.
  ;; ext:   the /digit for the immediate form.
  (define int-alu
    '((add . (#x01 #x03 0))
      (sub . (#x29 #x2B 5))
      ;; `and` is here for the type check: masking the 3-bit primary tag out of
      ;; a value is the one place the compiler needs bitwise work on the
      ;; integer side, and numeric.ss fixes that tag width.
      (and . (#x21 #x23 4))
      ;; `or` is here for the runtime: tagging a heap pointer is
      ;; `(raw + header) | 1`, and tagging a boolean is `(x << 3) | 7` (D28).
      (or  . (#x09 #x0B 1))
      (cmp . (#x39 #x3B 7))))

  (define sse-arith
    '((addsd . #x58) (subsd . #x5C) (mulsd . #x59)
      (divsd . #x5E) (sqrtsd . #x51)))

  ;; PACKED double bitwise ops, 66-prefixed rather than F2.
  ;;
  ;; They are here for one job: IEEE negation and absolute value. `sub 0.0 x` is
  ;; not negation -- the two disagree at x = 0.0 and the sign survives a
  ;; division, which bench/nbody/SPEC.md step 0 states -- so negation is a
  ;; sign-bit XOR against a pooled mask and abs is an AND.
  ;;
  ;; The packed form is the only form: there is no scalar xorpd, because SSE
  ;; has no scalar bitwise ops at all. Operating on both lanes is harmless
  ;; because we only ever read the low one, and litpool.ss gives the mask 16
  ;; bytes at 16-byte alignment, which non-VEX SSE requires of a 128-bit memory
  ;; operand -- an unaligned one faults.
  (define sse-bitwise
    '((andpd . #x54) (xorpd . #x57)))

  (define jcc-table
    '((je . #x84) (jne . #x85) (jl . #x8C) (jge . #x8D)
      (jle . #x8E) (jg . #x8F) (jo . #x80)))

  (define setcc-table
    '((sete . #x94) (setne . #x95) (setl . #x9C) (setge . #x9D)
      (setle . #x9E) (setg . #x9F)))

  (define (mnemonic-known? m)
    (or (assq m int-alu) (assq m sse-arith) (assq m sse-bitwise)
        (assq m jcc-table) (assq m setcc-table)
        (memq m '(mov movsd movzx imul lea shl sar shr neg cvtsi2sd jmp call ret
                  syscall))
        #f))

  (define (x86-64-supports? m) (and (mnemonic-known? m) #t))

  (define (x86-64-mnemonics)
    (append (map car int-alu) (map car sse-arith) (map car sse-bitwise)
            (map car jcc-table) (map car setcc-table)
            '(mov movsd movzx imul lea shl sar shr neg cvtsi2sd jmp call ret
              syscall)))

  ;; --- the baseline guard ---------------------------------------------------
  ;;
  ;; Refusing an unknown mnemonic would already stop `vfmadd231sd`, but it would
  ;; stop it with "unknown instruction", which reads like a gap to be filled.
  ;; It is not a gap. Say so.

  (define (avx-shaped? m)
    (let* ((s (symbol->string m)) (n (string-length s)))
      (or (and (> n 1) (char=? (string-ref s 0) #\v))
          (let scan ((i 0))
            (cond ((> (+ i 5) n) #f)
                  ((string=? (substring s i (+ i 5)) "fmadd") #t)
                  ((string=? (substring s i (+ i 5)) "fmsub") #t)
                  (else (scan (+ i 1))))))))

  (define (reject-non-baseline! m)
    (when (and (avx-shaped? m) (not (mnemonic-known? m)))
      (error 'encode-instr
             (string-append
              "refusing to emit a non-baseline (AVX/FMA) instruction: this back end "
              "is baseline SSE2 only. D24 makes FP contraction a named permission "
              "that is OFF by default, and fusing a multiply-add here would round "
              "differently from the reference C, breaking the bit-exact oracle")
             m))
    m)

  ;; --- encoding -------------------------------------------------------------

  (define (rel-value who x)
    (cond ((rel? x) (cadr x))
          ((and (pair? x) (eq? (car x) 'label))
           (error who
                  "labels must be resolved to a (rel n) displacement before encoding"
                  x))
          ((integer? x) x)
          (else (error who "not a branch displacement" x))))

  (define (int-alu-encode m dst src)
    (let* ((spec (cdr (assq m int-alu)))
           (op-mr (car spec)) (op-rm (cadr spec)) (ext (caddr spec)))
      (cond
       ((imm? src)
        (let ((n (cadr src)))
          (unless (or (gpr? dst) (mem? dst))
            (error 'encode-instr "immediate destination must be a register or memory" dst))
          (if (fits-imm8? n)
              (asm 'encode-instr '() 1 '(#x83) ext dst (imm8-bytes n) #f)
              (asm 'encode-instr '() 1 '(#x81) ext dst (imm32-bytes n) #f))))
       ((gpr? src)
        (asm 'encode-instr '() 1 (list op-mr) (reg-number src) dst '() #f))
       ((and (gpr? dst) (mem? src))
        (asm 'encode-instr '() 1 (list op-rm) (reg-number dst) src '() #f))
       (else (error 'encode-instr "bad operands" m dst src)))))

  (define (mov-encode dst src)
    (cond
     ((imm? src)
      (let ((n (cadr src)))
        (cond
         ((and (gpr? dst) (not (fits-imm32? n)))
          ;; movabs: the only 64-bit immediate the ISA has.
          (let ((num (reg-number dst)))
            (append (list (bitwise-ior #x48 (bitwise-arithmetic-shift-right num 3))
                          (+ #xB8 (bitwise-and num 7)))
                    (imm64-bytes n))))
         (else (asm 'encode-instr '() 1 '(#xC7) 0 dst (imm32-bytes n) #f)))))
     ((gpr? src) (asm 'encode-instr '() 1 '(#x89) (reg-number src) dst '() #f))
     ((and (gpr? dst) (mem? src)) (asm 'encode-instr '() 1 '(#x8B) (reg-number dst) src '() #f))
     (else (error 'encode-instr "bad mov operands" dst src))))

  (define (movsd-encode dst src)
    (cond
     ;; xmm <- xmm/m64
     ((and (xmm? dst) (or (xmm? src) (mem? src)))
      (asm 'encode-instr '(#xF2) 0 '(#x0F #x10) (reg-number dst) src '() #f))
     ;; m64 <- xmm
     ((and (mem? dst) (xmm? src))
      (asm 'encode-instr '(#xF2) 0 '(#x0F #x11) (reg-number src) dst '() #f))
     (else (error 'encode-instr "bad movsd operands" dst src))))

  (define (encode-instr i)
    (unless (and (pair? i) (symbol? (car i)))
      (error 'encode-instr "not an instruction" i))
    (let ((m (reject-non-baseline! (car i)))
          (ops (cdr i)))
      (define (arg n) (list-ref ops n))
      (cond
       ((assq m int-alu) (int-alu-encode m (arg 0) (arg 1)))
       ((eq? m 'mov)   (mov-encode (arg 0) (arg 1)))
       ((eq? m 'movsd) (movsd-encode (arg 0) (arg 1)))
       ((assq m sse-arith)
        (let ((dst (arg 0)) (src (arg 1)))
          (unless (xmm? dst) (error 'encode-instr "scalar-double destination must be xmm" i))
          (unless (or (xmm? src) (mem? src))
            (error 'encode-instr "scalar-double source must be xmm or memory" i))
          (asm 'encode-instr '(#xF2) 0 (list #x0F (cdr (assq m sse-arith)))
               (reg-number dst) src '() #f)))
       ((assq m sse-bitwise)
        (let ((dst (arg 0)) (src (arg 1)))
          (unless (xmm? dst) (error 'encode-instr "packed-double destination must be xmm" i))
          (unless (or (xmm? src) (mem? src))
            (error 'encode-instr "packed-double source must be xmm or memory" i))
          (asm 'encode-instr '(#x66) 0 (list #x0F (cdr (assq m sse-bitwise)))
               (reg-number dst) src '() #f)))
       ((eq? m 'cvtsi2sd)
        (let ((dst (arg 0)) (src (arg 1)))
          (unless (xmm? dst) (error 'encode-instr "cvtsi2sd destination must be xmm" i))
          (unless (or (gpr? src) (mem? src))
            (error 'encode-instr "cvtsi2sd source must be a GPR or memory" i))
          ;; REX.W is what makes this the 64-bit-integer form rather than the
          ;; 32-bit one, and it sits AFTER the F2 prefix.
          (asm 'encode-instr '(#xF2) 1 '(#x0F #x2A) (reg-number dst) src '() #f)))
       ((eq? m 'imul)
        (let ((dst (arg 0)) (src (arg 1)))
          (unless (gpr? dst) (error 'encode-instr "imul destination must be a GPR" i))
          (asm 'encode-instr '() 1 '(#x0F #xAF) (reg-number dst) src '() #f)))
       ((eq? m 'lea)
        (let ((dst (arg 0)) (src (arg 1)))
          (unless (gpr? dst) (error 'encode-instr "lea destination must be a GPR" i))
          (unless (mem? src) (error 'encode-instr "lea source must be a memory operand" i))
          (asm 'encode-instr '() 1 '(#x8D) (reg-number dst) src '() #f)))
       ((memq m '(shl sar shr))
        (let ((dst (arg 0)) (src (arg 1))
              (ext (case m ((shl) 4) ((shr) 5) ((sar) 7))))
          (unless (imm? src) (error 'encode-instr "shift count must be an immediate" i))
          (asm 'encode-instr '() 1 '(#xC1) ext dst (imm8-bytes (cadr src)) #f)))
       ;; SYSCALL. Two bytes, no operands, and no REX -- the only way this
       ;; runtime talks to the kernel, since D25 puts no libc in the running
       ;; system. Adding it here rather than as a magic byte string keeps it
       ;; inside the differential test like every other instruction.
       ((eq? m 'syscall) '(#x0F #x05))
       ((eq? m 'neg) (asm 'encode-instr '() 1 '(#xF7) 3 (arg 0) '() #f))
       ((assq m setcc-table)
        (let ((dst (arg 0)))
          (unless (gpr? dst) (error 'encode-instr "setcc destination must be a GPR" i))
          (asm 'encode-instr '() 0 (list #x0F (cdr (assq m setcc-table))) 0 dst '()
               (needs-rex-for-byte? dst))))
       ((eq? m 'movzx)
        (let ((dst (arg 0)) (src (arg 1)))
          (unless (gpr? dst) (error 'encode-instr "movzx destination must be a GPR" i))
          (unless (or (gpr? src) (mem? src)) (error 'encode-instr "bad movzx source" i))
          ;; REX.W is always present here, so the 8-bit ambiguity resolves itself.
          (asm 'encode-instr '() 1 '(#x0F #xB6) (reg-number dst) src '() #f)))
       ((eq? m 'jmp)  (cons #xE9 (imm32-bytes (rel-value 'encode-instr (arg 0)))))
       ((eq? m 'call) (cons #xE8 (imm32-bytes (rel-value 'encode-instr (arg 0)))))
       ((assq m jcc-table)
        (append (list #x0F (cdr (assq m jcc-table)))
                (imm32-bytes (rel-value 'encode-instr (arg 0)))))
       ((eq? m 'ret) '(#xC3))
       (else (error 'encode-instr "no encoding for this mnemonic" m)))))

  (define (encode-instrs is) (apply append (map encode-instr is)))
  (define (instr-length i) (length (encode-instr i)))
  )
