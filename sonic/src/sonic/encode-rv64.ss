;;; RV64 instruction encoding, byte-exact.
;;;
;;; E2-RVENC. RV64 has fixed-width 32-bit instructions in six regular formats,
;;; so the tractable thing is to encode the FORMAT and let the per-mnemonic
;;; table be nothing but opcode, funct3 and funct7. That is what this file does:
;;; the six `enc-*` procedures below are the entire encoder, and everything else
;;; is a lookup.
;;;
;;; We deliberately do not emit the C extension. RVC would shorten this stream
;;; by roughly a third, but a compressed instruction is 2 bytes where its
;;; expansion is 4, and the GC metadata in sonic/src/sonic/gcmeta.ss is a step
;;; function keyed by byte offset. Mixing widths is fine for the metadata but it
;;; makes every hand-checked offset in a test a function of the compressor's
;;; choices. Uncompressed first, RVC as a later measured bead.
;;;
;;; ## The refusal is the point
;;;
;;; sonic/doc/register-partition.md records that the toolchain here defaults to
;;; an RVA23 ISA string, so `sh3add` (Zba) shows up for something as ordinary as
;;; `p[k]` and `fli.d` (Zfa) appears and vanishes with the march. An encoder that
;;; answered "unknown mnemonic" for those would be telling you the wrong thing:
;;; they are real instructions, correctly spelled, that a `rv64gc` board cannot
;;; execute. `above-baseline-extension` knows them by name and by extension, and
;;; `encode-instr` refuses them with the extension named, so an RVA23 rule table
;;; leaking into the base selector fails at encode time rather than on hardware.
;;;
;;; ## Verification
;;;
;;; Every mnemonic in `instr-table` is checked byte-for-byte against
;;; riscv64-linux-gnu-gcc in sonic/test/rv64-test.ss. Encodings are not asserted
;;; from the manual here; they are asserted from binutils. That is the only
;;; check that can catch a transcription error, because a transcription error
;;; and its expectation come from the same reading.

(library (sonic encode-rv64)
  (export encode-instr encode-word encode-listing
          gpr-number fpr-number
          above-baseline-extension known-mnemonic?
          instr-mnemonics)
  (import (chezscheme))

  ;; --- registers ------------------------------------------------------------
  ;;
  ;; TRAP, and it is one this tree can walk into: sonic/src/sonic/regs.ss lists
  ;; the float pool in ALLOCATION order, `(ft0..ft7 fs0..fs7 fa0..fa7 fs8..fs11
  ;; ft8..ft11)`, which is NOT the ABI's f-number order. In lp64d, f8/f9 are
  ;; fs0/fs1, f10-f17 are fa0-fa7, and f18-f27 are fs2-fs11. Taking the position
  ;; in that list as the register number would put fs2 at f10, which is fa0, and
  ;; the program would still assemble.
  (define gpr-names
    '#(zero ra sp gp tp t0 t1 t2 s0 s1 a0 a1 a2 a3 a4 a5
       a6 a7 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 t3 t4 t5 t6))

  (define fpr-names
    '#(ft0 ft1 ft2 ft3 ft4 ft5 ft6 ft7 fs0 fs1 fa0 fa1 fa2 fa3 fa4 fa5
       fa6 fa7 fs2 fs3 fs4 fs5 fs6 fs7 fs8 fs9 fs10 fs11 ft8 ft9 ft10 ft11))

  (define (index-of vec x)
    (let loop ((i 0))
      (cond ((= i (vector-length vec)) #f)
            ((eq? (vector-ref vec i) x) i)
            (else (loop (+ i 1))))))

  (define (gpr-number r)
    (cond ((eq? r 'fp) 8)                       ; s0 and fp are one register
          ((index-of gpr-names r))
          (else (error 'gpr-number "not an RV64 integer register" r))))

  (define (fpr-number r)
    (or (index-of fpr-names r)
        (error 'fpr-number "not an RV64 float register" r)))

  ;; --- the six formats ------------------------------------------------------
  ;;
  ;; RV64 immediates are scattered across the word so that a given bit of the
  ;; immediate lands in the same instruction bit in every format that carries
  ;; it. That is what makes the hardware's immediate mux cheap, and it is why
  ;; the B and J cases below look like bit surgery rather than a shift.

  (define (bits v hi lo) (bitwise-and (ash v (- lo)) (- (ash 1 (+ 1 (- hi lo))) 1)))

  (define (enc-r opcode funct3 funct7 rd rs1 rs2)
    (bitwise-ior (ash funct7 25) (ash rs2 20) (ash rs1 15)
                 (ash funct3 12) (ash rd 7) opcode))

  (define (enc-i opcode funct3 rd rs1 imm)
    (bitwise-ior (ash (bitwise-and imm #xfff) 20) (ash rs1 15)
                 (ash funct3 12) (ash rd 7) opcode))

  ;; Shifts are I-format with the shift amount in the low bits of the immediate
  ;; and a discriminator above it: 6 bits of shamt on RV64, not 5.
  (define (enc-shift opcode funct3 top rd rs1 shamt)
    (bitwise-ior (ash top 26) (ash shamt 20) (ash rs1 15)
                 (ash funct3 12) (ash rd 7) opcode))

  (define (enc-s opcode funct3 rs1 rs2 imm)
    (bitwise-ior (ash (bits imm 11 5) 25) (ash rs2 20) (ash rs1 15)
                 (ash funct3 12) (ash (bits imm 4 0) 7) opcode))

  (define (enc-b opcode funct3 rs1 rs2 imm)
    (bitwise-ior (ash (bits imm 12 12) 31) (ash (bits imm 10 5) 25)
                 (ash rs2 20) (ash rs1 15) (ash funct3 12)
                 (ash (bits imm 4 1) 8) (ash (bits imm 11 11) 7) opcode))

  (define (enc-u opcode rd imm20)
    (bitwise-ior (ash (bitwise-and imm20 #xfffff) 12) (ash rd 7) opcode))

  (define (enc-j opcode rd imm)
    (bitwise-ior (ash (bits imm 20 20) 31) (ash (bits imm 10 1) 21)
                 (ash (bits imm 11 11) 20) (ash (bits imm 19 12) 12)
                 (ash rd 7) opcode))

  ;; --- range checks, loud -------------------------------------------------
  ;; A silently truncated immediate is a wrong-code bug that surfaces as a wild
  ;; load. Every one of these is checked before it is packed.

  (define (want! ok who what v)
    (unless ok (error 'encode-instr (string-append who ": " what) v))
    v)

  (define (simm12 who v)
    (want! (and (integer? v) (exact? v) (<= -2048 v 2047))
           who "immediate does not fit a signed 12-bit field" v))
  (define (shamt6 who v)
    (want! (and (integer? v) (exact? v) (<= 0 v 63))
           who "shift amount is not in 0..63" v))
  (define (uimm20 who v)
    (want! (and (integer? v) (exact? v) (<= -524288 v 1048575))
           who "lui immediate is not a 20-bit field" v))
  (define (bdisp who v)
    (want! (and (integer? v) (exact? v) (even? v) (<= -4096 v 4094))
           who "branch displacement is not an even offset in +/-4KiB" v))
  (define (jdisp who v)
    (want! (and (integer? v) (exact? v) (even? v) (<= -1048576 v 1048574))
           who "jal displacement is not an even offset in +/-1MiB" v))

  ;; --- opcodes --------------------------------------------------------------

  (define op-op      #b0110011)
  (define op-imm     #b0010011)
  (define op-load    #b0000011)
  (define op-store   #b0100011)
  (define op-branch  #b1100011)
  (define op-lui     #b0110111)
  (define op-auipc   #b0010111)
  (define op-jal     #b1101111)
  (define op-jalr    #b1100111)
  (define op-load-fp #b0000111)
  (define op-store-fp #b0100111)
  (define op-fp      #b1010011)
  ;; SYSTEM. Needed because a runtime cannot exit or write without a syscall,
  ;; and `ecall` was absent from this encoder -- which is a prerequisite for
  ;; bead 1mp.6 that sizing the RV64 gap by counting what EXISTS did not reveal.
  (define op-system  #b1110011)

  ;; Rounding mode `dyn`, i.e. take the mode from fcsr. This is what gcc emits
  ;; for ordinary double arithmetic and it is what the differential test pins:
  ;; a static rm here would silently change results under a non-default fcsr,
  ;; which for a project whose oracle is bit-exact agreement is the whole ball
  ;; game.
  (define rm-dyn #b111)

  ;; --- the table ------------------------------------------------------------
  ;;
  ;; (mnemonic kind . fields). `kind` picks the encoder; `fields` are the fixed
  ;; opcode bits. Operand order is one per format and is documented in
  ;; sonic/src/sonic/target-rv64.ss.

  (define instr-table
    `(;; RV64I / RV64M register-register: (op rd rs1 rs2)
      (add   r ,op-op #b000 #b0000000)
      (sub   r ,op-op #b000 #b0100000)
      (sll   r ,op-op #b001 #b0000000)
      (slt   r ,op-op #b010 #b0000000)
      (sltu  r ,op-op #b011 #b0000000)
      (xor   r ,op-op #b100 #b0000000)
      (srl   r ,op-op #b101 #b0000000)
      (sra   r ,op-op #b101 #b0100000)
      (or    r ,op-op #b110 #b0000000)
      (and   r ,op-op #b111 #b0000000)
      (mul   r ,op-op #b000 #b0000001)
      (div   r ,op-op #b100 #b0000001)
      ;; SYSTEM: (ecall), no operands. Fixed word 0x00000073 -- rd, rs1,
      ;; funct3 and imm are all zero. Linux/RV64 takes the syscall number
      ;; in a7 and arguments in a0-a5.
      (ecall system ,op-system #b000)
      ;; register-immediate: (op rd rs1 imm)
      (addi  i ,op-imm #b000)
      (slti  i ,op-imm #b010)
      (sltiu i ,op-imm #b011)
      (xori  i ,op-imm #b100)
      (ori   i ,op-imm #b110)
      (andi  i ,op-imm #b111)
      ;; shifts: (op rd rs1 shamt), 6-bit shamt on RV64
      (slli  shift ,op-imm #b001 #b000000)
      (srli  shift ,op-imm #b101 #b000000)
      (srai  shift ,op-imm #b101 #b010000)
      ;; loads: (op rd rs1 imm)
      (ld    load ,op-load #b011)
      (lw    load ,op-load #b010)
      (fld   load-fp ,op-load-fp #b011)
      ;; stores: (op rs2 rs1 imm)
      (sd    store ,op-store #b011)
      (sw    store ,op-store #b010)
      (fsd   store-fp ,op-store-fp #b011)
      ;; branches: (op rs1 rs2 target)
      (beq   b ,op-branch #b000)
      (bne   b ,op-branch #b001)
      (blt   b ,op-branch #b100)
      (bge   b ,op-branch #b101)
      (bltu  b ,op-branch #b110)
      (bgeu  b ,op-branch #b111)
      ;; upper immediates: (op rd imm20)
      (lui   u ,op-lui)
      (auipc u ,op-auipc)
      ;; jumps
      (jal   j ,op-jal)                  ; (jal rd target)
      (jalr  jalr ,op-jalr #b000)        ; (jalr rd rs1 imm)
      ;; --- D extension. rd and both sources are FPRs ---------------------
      (fadd.d    fr ,op-fp ,rm-dyn #b0000001)
      (fsub.d    fr ,op-fp ,rm-dyn #b0000101)
      (fmul.d    fr ,op-fp ,rm-dyn #b0001001)
      (fdiv.d    fr ,op-fp ,rm-dyn #b0001101)
      (fsgnj.d   fr ,op-fp #b000 #b0010001)   ; fmv.d  rd, rs
      (fsgnjn.d  fr ,op-fp #b001 #b0010001)   ; fneg.d rd, rs
      (fsgnjx.d  fr ,op-fp #b010 #b0010001)   ; fabs.d rd, rs
      (fmin.d    fr ,op-fp #b000 #b0010101)
      (fmax.d    fr ,op-fp #b001 #b0010101)
      ;; one FPR source, rs2 field is a fixed selector: (op rd rs1)
      (fsqrt.d   fr1 ,op-fp ,rm-dyn #b0101101 #b00000)
      ;; FPR sources, GPR destination: (op rd rs1 rs2)
      (feq.d     fcmp ,op-fp #b010 #b1010001)
      (flt.d     fcmp ,op-fp #b001 #b1010001)
      (fle.d     fcmp ,op-fp #b000 #b1010001)
      ;; GPR source, FPR destination: (op rd rs1)
      (fcvt.d.l  fint ,op-fp ,rm-dyn #b1101001 #b00010)  ; signed long -> double
      (fmv.d.x   fint ,op-fp #b000 #b1111001 #b00000)))  ; bit pattern -> double

  ;; --- what we refuse, and why ----------------------------------------------
  ;;
  ;; Correctly spelled instructions that a `rv64gc` part cannot execute. The
  ;; message names the extension, because "unknown mnemonic" would send someone
  ;; hunting for a typo in a line that is perfectly good RVA23 assembly.
  (define above-baseline
    '((sh1add . Zba) (sh2add . Zba) (sh3add . Zba) (add.uw . Zba)
      (sh1add.uw . Zba) (sh2add.uw . Zba) (sh3add.uw . Zba) (slli.uw . Zba)
      (andn . Zbb) (orn . Zbb) (xnor . Zbb) (clz . Zbb) (ctz . Zbb)
      (cpop . Zbb) (max . Zbb) (maxu . Zbb) (min . Zbb) (minu . Zbb)
      (sext.b . Zbb) (sext.h . Zbb) (zext.h . Zbb) (rol . Zbb) (ror . Zbb)
      (rori . Zbb) (orc.b . Zbb) (rev8 . Zbb)
      (bclr . Zbs) (bext . Zbs) (binv . Zbs) (bset . Zbs)
      (fli.d . Zfa) (fli.s . Zfa) (fminm.d . Zfa) (fmaxm.d . Zfa)
      (fround.d . Zfa) (fleq.d . Zfa) (fltq.d . Zfa) (fmvh.x.d . Zfa)
      (czero.eqz . Zicond) (czero.nez . Zicond)
      (vsetvli . V) (vsetivli . V) (vsetvl . V)
      (vle64.v . V) (vse64.v . V) (vfadd.vv . V) (vfmul.vv . V)
      (vadd.vv . V) (vfmacc.vv . V) (vfredusum.vs . V)
      ;; The rest of what sonic/src/sonic/vec-rv64.ss emits. Listed so the base
      ;; encoder names the EXTENSION rather than reporting "no such instruction"
      ;; for a correctly spelled RVV mnemonic that reached the wrong encoder.
      (vfsub.vv . V) (vfdiv.vv . V) (vfsqrt.v . V)
      (vfmv.v.f . V) (vmv.v.v . V)))

  (define (above-baseline-extension mn)
    (let ((p (assq mn above-baseline))) (and p (cdr p))))

  (define (known-mnemonic? mn) (and (assq mn instr-table) #t))
  (define (instr-mnemonics) (map car instr-table))

  ;; --- encoding -------------------------------------------------------------

  (define (lookup mn)
    (or (assq mn instr-table)
        (let ((ext (above-baseline-extension mn)))
          (if ext
              (error 'encode-instr
                     "this instruction is above the rv64gc floor and a rv64gc part cannot execute it; the base selector must not emit it (see sonic/doc/register-partition.md)"
                     mn ext)
              (error 'encode-instr "no such rv64gc instruction" mn)))))

  ;; -> a 32-bit unsigned integer. Branch and jump targets must already be
  ;; resolved to a byte displacement relative to THIS instruction; a symbol here
  ;; means the caller skipped `encode-listing`, which is a bug rather than a
  ;; thing to guess about.
  (define (encode-word instr)
    (let* ((mn (car instr))
           (e (lookup mn))
           (kind (cadr e))
           (f (cddr e))
           (ops (cdr instr))
           (who (symbol->string mn)))
      (define (arity! n)
        (unless (= (length ops) n)
          (error 'encode-instr "wrong operand count" mn n ops)))
      (define (target v)
        (when (symbol? v)
          (error 'encode-instr
                 "unresolved label; branch and jump targets must be byte displacements by the time they reach the encoder"
                 mn v))
        v)
      (case kind
        ((r)     (arity! 3) (enc-r (car f) (cadr f) (caddr f)
                                 (gpr-number (car ops)) (gpr-number (cadr ops))
                                 (gpr-number (caddr ops))))
        ((i)     (arity! 3) (enc-i (car f) (cadr f)
                                 (gpr-number (car ops)) (gpr-number (cadr ops))
                                 (simm12 who (caddr ops))))
        ;; Every field is zero, so this takes no operands and reads none.
        ((system) (arity! 0) (enc-i (car f) (cadr f) 0 0 0))
        ((shift) (arity! 3) (enc-shift (car f) (cadr f) (caddr f)
                                     (gpr-number (car ops)) (gpr-number (cadr ops))
                                     (shamt6 who (caddr ops))))
        ((load)  (arity! 3) (enc-i (car f) (cadr f)
                                 (gpr-number (car ops)) (gpr-number (cadr ops))
                                 (simm12 who (caddr ops))))
        ((load-fp) (arity! 3) (enc-i (car f) (cadr f)
                                   (fpr-number (car ops)) (gpr-number (cadr ops))
                                   (simm12 who (caddr ops))))
        ((store) (arity! 3) (enc-s (car f) (cadr f)
                                 (gpr-number (cadr ops)) (gpr-number (car ops))
                                 (simm12 who (caddr ops))))
        ((store-fp) (arity! 3) (enc-s (car f) (cadr f)
                                    (gpr-number (cadr ops)) (fpr-number (car ops))
                                    (simm12 who (caddr ops))))
        ((b)     (arity! 3) (enc-b (car f) (cadr f)
                                 (gpr-number (car ops)) (gpr-number (cadr ops))
                                 (bdisp who (target (caddr ops)))))
        ((u)     (arity! 2) (enc-u (car f) (gpr-number (car ops))
                                 (uimm20 who (cadr ops))))
        ((j)     (arity! 2) (enc-j (car f) (gpr-number (car ops))
                                 (jdisp who (target (cadr ops)))))
        ((jalr)  (arity! 3) (enc-i (car f) (cadr f)
                                 (gpr-number (car ops)) (gpr-number (cadr ops))
                                 (simm12 who (caddr ops))))
        ((fr)    (arity! 3) (enc-r (car f) (cadr f) (caddr f)
                                 (fpr-number (car ops)) (fpr-number (cadr ops))
                                 (fpr-number (caddr ops))))
        ((fr1)   (arity! 2) (enc-r (car f) (cadr f) (caddr f)
                                 (fpr-number (car ops)) (fpr-number (cadr ops))
                                 (cadddr f)))
        ((fcmp)  (arity! 3) (enc-r (car f) (cadr f) (caddr f)
                                 (gpr-number (car ops)) (fpr-number (cadr ops))
                                 (fpr-number (caddr ops))))
        ((fint)  (arity! 2) (enc-r (car f) (cadr f) (caddr f)
                                 (fpr-number (car ops)) (gpr-number (cadr ops))
                                 (cadddr f)))
        (else (error 'encode-instr "unhandled instruction format" mn kind)))))

  ;; -> a list of 4 bytes, little-endian, which is the only endianness RISC-V
  ;; defines for instruction fetch regardless of the data endianness.
  (define (encode-instr instr)
    (let ((w (encode-word instr)))
      (list (bitwise-and w #xff)
            (bitwise-and (ash w -8) #xff)
            (bitwise-and (ash w -16) #xff)
            (bitwise-and (ash w -24) #xff))))

  ;; --- listings, so branch targets can be labels ----------------------------
  ;;
  ;; A listing is a list whose elements are either a bare symbol (a label
  ;; definition) or an instruction. Two passes, and the second one cannot
  ;; change any address because every instruction is exactly 4 bytes. That is
  ;; the whole reason fixed-width ISAs are pleasant to assemble: there is no
  ;; branch-relaxation fixpoint to iterate.
  (define (encode-listing listing)
    (let ((labels (make-eq-hashtable)))
      (define (resolve instr pc)
        (let ((mn (car instr)))
          (if (memq mn '(beq bne blt bge bltu bgeu jal))
              (let* ((n (length instr))
                     (t (list-ref instr (- n 1))))
                (if (symbol? t)
                    (let ((at (hashtable-ref labels t #f)))
                      (unless at (error 'encode-listing "undefined label" t instr))
                      (append (list-head instr (- n 1)) (list (- at pc))))
                    instr))
              instr)))
      (let pass1 ((xs listing) (pc 0))
        (cond ((null? xs) 'done)
              ((symbol? (car xs))
               (when (hashtable-ref labels (car xs) #f)
                 (error 'encode-listing "label defined twice" (car xs)))
               (hashtable-set! labels (car xs) pc)
               (pass1 (cdr xs) pc))
              (else (pass1 (cdr xs) (+ pc 4)))))
      (let pass2 ((xs listing) (pc 0) (acc '()))
        (cond ((null? xs) (apply append (reverse acc)))
              ((symbol? (car xs)) (pass2 (cdr xs) pc acc))
              (else
               (pass2 (cdr xs) (+ pc 4)
                      (cons (encode-instr (resolve (car xs) pc)) acc)))))))
  )
