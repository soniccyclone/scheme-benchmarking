;;; E2-RVSEL and E2-RVENC.
;;;
;;; The encoder half of this file is checked DIFFERENTIALLY against binutils,
;;; not against a table of expected words written here. Those two are not the
;;; same test. An expectation written by whoever wrote the encoder comes from
;;; the same reading of the manual as the encoder does, so it agrees with a
;;; transcription error as readily as with a correct encoding. Assembling the
;;; same listing with riscv64-linux-gnu-gcc and comparing bytes is an
;;; independent witness, and it is the only kind that can fail usefully.

(import (chezscheme) (rnrs io simple)
        (sonic lang) (sonic fixtures) (sonic select)
        (sonic regs) (sonic target-rv64) (sonic encode-rv64) (sonic litpool)
        (sonic numeric) (sonic elfexec) (sonic driver) (sonic pipeline)
        (sonic twoaddr))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))
(define (raises? thunk)
  (guard (e (#t (call-with-string-output-port
                 (lambda (p) (if (condition? e) (display-condition e p) (write e p))))))
    (thunk) #f))
(define (raises-naming? thunk needle)
  (let ((msg (raises? thunk)))
    (and msg (let loop ((i 0))
               (cond ((> (+ i (string-length needle)) (string-length msg)) #f)
                     ((string=? (substring msg i (+ i (string-length needle))) needle) #t)
                     (else (loop (+ i 1))))))))

;;; ==========================================================================
;;; 1. Selection
;;; ==========================================================================

(ck! "the RV64 selector covers nbody's lowered inner loop"
     (selector-covers? rv64-selector (nbody-inner-mach)))
(ck! "and owes nothing"
     (null? (missing-rules rv64-selector (nbody-inner-mach))))
(ck! "it enforces the RV64 partition, not some other arch's"
     (eq? (selector-partition rv64-selector) arch-rv64))

(define selected (select-program rv64-selector (nbody-inner-mach)))
(define entry-instrs (cadr (assq 'entry (cadddr selected))))

;; What the fixture must become. The three-instruction load is the headline:
;; `(load v-val raw-f64 v-b v-idx)` is one x86-64 instruction and is a shift,
;; an add and an fld here, because RISC-V has no indexed addressing mode.
(ck! "the fixture selects to exactly the rv64gc sequence it should"
     (equal? entry-instrs
             `((addi v-seven zero 7)
               (mul v-off v-i v-seven)
               (add v-idx v-off v-k)
               ;; t1, not t0: rv64-addr-scratch moved off t0 because
               ;; twoaddr.ss's own scratch table also names t0 for raw-word,
               ;; and the two collided in emitted code -- a global address
               ;; computed into t0 and then overwritten by a value staged
               ;; through it. See bead 1mp.9.
               (slli t1 v-idx 3)
               (add t1 v-b t1)
               ;; -1, not 0: the displacement absorbs the heap pointer tag,
               ;; because a pointer is tagged and nothing strips it before the
               ;; load. See numeric.ss `heap-element-disp`.
               (fld v-val t1 ,heap-element-disp)
               ;; The return move. Lmach's `(ret v)` carries no class, so this
               ;; rule reads it from `current-vreg-classes`; a double goes to
               ;; fa0 via fsgnj.d, which is what `fmv.d` is. Without it the
               ;; function returned whatever was already in a0.
               (fsgnj.d fa0 v-val v-val)
               (jalr zero ra 0))))

(define (mnemonics-of instrs) (map car instrs))

(ck! "every selected mnemonic is one the encoder knows"
     (for-all known-mnemonic? (mnemonics-of entry-instrs)))

;; The negative form of the ISA pin, applied to the selector rather than to a
;; hand-written instruction: nothing the base rules can produce may be above
;; the floor. sh3add is exactly what a real compiler emits for this shape.
(ck! "and nothing the base rules produce is above the rv64gc floor"
     (not (exists above-baseline-extension (mnemonics-of entry-instrs))))

;; A float compare's operands are floats and its destination is an integer
;; register, so reading `sc` as the destination's class cannot work. See the
;; note in target-rv64.ss.
(define (sel1 instr) (select-instr rv64-selector instr))
(ck! "fl< selects to flt.d, an ordered compare into a GPR"
     (equal? (sel1 '(cmp-lt v-t raw-f64 v-a v-b)) '((flt.d v-t v-a v-b))))
(ck! "fl> swaps the operands rather than negating the result, so NaN stays false"
     (equal? (sel1 '(cmp-gt v-t raw-f64 v-a v-b)) '((flt.d v-t v-b v-a))))
(ck! "fixnum <= is slt with the operands swapped, then xori"
     (equal? (sel1 '(cmp-le v-t raw-word v-a v-b))
             '((slt v-t v-b v-a) (xori v-t v-t 1))))
;; lang.ss: flneg is not (fl- 0.0 x); they disagree at 0.0 and the sign
;; survives a later divide. fsgnjn.d is true negation.
(ck! "flneg is fsgnjn.d, not a subtract from zero"
     (equal? (sel1 '(neg v-t raw-f64 v-a)) '((fsgnjn.d v-t v-a v-a))))
(ck! "flabs is fsgnjx.d"
     (equal? (sel1 '(abs v-t raw-f64 v-a)) '((fsgnjx.d v-t v-a v-a))))
(ck! "an f64 move is fsgnj.d, an integer move is addi rd,rs,0"
     (and (equal? (sel1 '(move v-t raw-f64 v-a)) '((fsgnj.d v-t v-a v-a)))
          (equal? (sel1 '(move v-t raw-word v-a)) '((addi v-t v-a 0)))))

;; A 12-bit immediate is one instruction; anything wider is lui/addi with the
;; carry correction.
(ck! "a small constant is one addi"
     (equal? (sel1 '(const v-t raw-word 2047)) '((addi v-t zero 2047))))
(ck! "a wide constant is lui/addi and the low half's sign is corrected for"
     (equal? (sel1 '(const v-t raw-word #x12345678))
             '((lui v-t #x12345) (addi v-t v-t #x678))))
(ck! "a constant whose low half borrows gets the +1 in the high half"
     (equal? (sel1 '(const v-t raw-word #xfff)) '((lui v-t 1) (addi v-t v-t -1))))

;; RISC-V has no flags register. numeric.ss describes a checked fx+ as "an add
;; followed by jo"; here it is four instructions and two scratches.
;; The operands are (a b sum), matching what lower.ss emits: the check is a
;; POSTcondition, so the sum is the operation's own destination and comes last.
;; The idiom is ((a^sum) & (b^sum)) < 0, so BOTH xors must name the sum -- and
;; because it is symmetric in a and b, reading the operands in the wrong order
;; still produces four plausible instructions that test nothing. The assertion
;; is therefore on which operand each xor pairs with, not on the shape.
(ck! "an overflow check becomes the sign-comparison idiom, not a flag test"
     (equal? (sel1 '(chk overflow-check checked 0 v-a v-b v-sum))
             '((xor t0 v-a v-sum)
               (xor t1 v-b v-sum)
               (and t0 t0 t1)
               (blt t0 zero trap-overflow-check))))
;; There is only ONE spelling of a check now -- see the note in lang.ss.
(ck! "the mach-op spelling of a check no longer exists"
     (and (not (mach-op? 'check-bounds))
          (not (mach-op? 'check-type))
          (not (mach-op? 'check-overflow))))
;; One unsigned compare catches the negative index too.
(ck! "a bounds check is a single bgeu"
     (equal? (sel1 '(chk bounds-check checked 0 v-i v-n))
             '((bgeu v-i v-n trap-bounds-check))))
(ck! "an unchecked check emits nothing, because the policy suppressed it"
     (null? (sel1 '(chk bounds-check unchecked 0 v-i v-n))))

;; UPDATED (milestone 1): the literal pool now exists, so a flonum constant
;; SELECTS. RV64 has no PC-relative load, so it is two instructions -- the
;; address is built with auipc and the load carries the low 12 bits -- and both
;; relocate (reloc.ss). The immediate emitted is the pool offset; the linker
;; overwrites it.
;; THE PAIR IS AGAINST THE POOL'S LABEL, not a raw offset. It used to emit the
;; offset in both immediates with relocations attached, on the reasoning that a
;; LINKER would overwrite them. That is right for an object and wrong for the
;; static image build-executable writes, which applies no relocations -- nbody
;; segfaulted on the first float it loaded. See 1mp.8.
;;
;; `pcrel-lo` names the same label as `pcrel-hi` rather than carrying its own
;; displacement, because RISC-V computes the low half relative to the AUIPC's
;; pc. That is the same reason the real R_RISCV_PCREL_LO12_I names the HI20's
;; label instead of the symbol.
(ck! "a flonum constant interns into the pool and loads via auipc + fld"
     (parameterize ((current-litpool (make-pool)))
       (let ((out (sel1 '(const v-t raw-f64 1.5))))
         (and (= (length out) 2)
              (eq? (car (car out)) 'auipc)
              (pair? (caddr (car out)))
              (eq? (car (caddr (car out))) 'pcrel-hi)
              (equal? (cadr out)
                      `(fld v-t ,(cadr (car out)) (pcrel-lo ,(cadr (caddr (car out))))))))))
;; Two references to the SAME constant must intern once. Interning twice would
;; not be wrong, but the pool is emitted into .rodata and nbody's inner loop
;; reads the same handful of constants every iteration.
(ck! "interning is by value, so the same constant gets one pool slot"
     (parameterize ((current-litpool (make-pool)))
       (let ((a (sel1 '(const v-t raw-f64 1.5)))
             (b (sel1 '(const v-u raw-f64 1.5)))
             (c (sel1 '(const v-w raw-f64 2.5))))
         (and (equal? (caddr (car a)) (caddr (car b)))
              (not (equal? (caddr (car a)) (caddr (car c))))))))
;; UPDATED: Lmach's chk now carries the expected TAG, so a type check is
;; selectable. It masks the primary tag out of the value and compares it against
;; the constant; numeric.ss fixes a 3-bit primary tag with fixnum = 000.
(ck! "a type check now SELECTS, masking the tag and comparing it"
     (let ((out (sel1 '(chk type-check checked 1 v-a))))
       (and (equal? (car out) '(andi t0 v-a 7))
            (equal? (cadr out) '(addi t1 zero 1))
            (eq? (car (caddr out)) 'bne))))

;;; ==========================================================================
;;; 2. Register numbering
;;; ==========================================================================
;;
;; regs.ss lists the float pool in ALLOCATION order, which is not f-number
;; order. Taking a position in that list as a register number puts fs2 at f10,
;; which is fa0, and the program still assembles.

(ck! "integer ABI names map to their x numbers"
     (and (= (gpr-number 'zero) 0) (= (gpr-number 'ra) 1) (= (gpr-number 'sp) 2)
          (= (gpr-number 't0) 5) (= (gpr-number 's0) 8) (= (gpr-number 'fp) 8)
          (= (gpr-number 'a0) 10) (= (gpr-number 's2) 18) (= (gpr-number 't6) 31)))
(ck! "float ABI names map to their f numbers, NOT to their position in regs.ss"
     (and (= (fpr-number 'ft0) 0) (= (fpr-number 'fs0) 8) (= (fpr-number 'fa0) 10)
          (= (fpr-number 'fs2) 18) (= (fpr-number 'fs11) 27)
          (= (fpr-number 'ft8) 28) (= (fpr-number 'ft11) 31)))
(ck! "and every register regs.ss can allocate has a number"
     (and (for-all gpr-number (append (arch-value arch-rv64) (arch-raw arch-rv64)))
          (for-all fpr-number (arch-float arch-rv64))))

;;; ==========================================================================
;;; 3. The rv64gc floor, enforced at encode time
;;; ==========================================================================

(ck! "sh3add is REFUSED and the refusal names Zba, not `unknown mnemonic`"
     (and (eq? (above-baseline-extension 'sh3add) 'Zba)
          (raises-naming? (lambda () (encode-instr '(sh3add a0 a1 a2))) "Zba")
          (raises-naming? (lambda () (encode-instr '(sh3add a0 a1 a2))) "rv64gc")))
(ck! "so is fli.d (Zfa), which is what appears and vanishes with the march"
     (raises-naming? (lambda () (encode-instr '(fli.d ft0 1))) "Zfa"))
(ck! "so is a vector instruction, even though RVA23 makes V mandatory"
     (raises-naming? (lambda () (encode-instr '(vfadd.vv ft0 ft1 ft2))) "V"))
(ck! "a genuine typo gets a DIFFERENT error than a real above-floor instruction"
     (and (raises-naming? (lambda () (encode-instr '(addd a0 a1 2))) "no such")
          (not (above-baseline-extension 'addd))))

;; A truncated immediate is a wild load, so every field is range-checked.
(ck! "an out-of-range addi immediate is refused, not truncated"
     (and (raises-naming? (lambda () (encode-instr '(addi a0 a1 2048))) "12-bit")
          (encode-instr '(addi a0 a1 2047))
          (encode-instr '(addi a0 a1 -2048))))
(ck! "a shift amount above 63 is refused"
     (raises-naming? (lambda () (encode-instr '(slli a0 a1 64))) "0..63"))
(ck! "an odd branch displacement is refused"
     (raises-naming? (lambda () (encode-instr '(beq a0 a1 3))) "even"))
(ck! "an unresolved label reaching the encoder is a bug and says so"
     (raises-naming? (lambda () (encode-instr '(jal zero somewhere))) "unresolved"))
(ck! "a label defined twice in a listing is refused"
     (raises-naming? (lambda () (encode-listing '(l1 (addi a0 zero 0) l1))) "twice"))
(ck! "a branch to an undefined label is refused"
     (raises-naming? (lambda () (encode-listing '((jal zero nowhere)))) "undefined"))

;;; ==========================================================================
;;; 4. THE differential check, against binutils
;;; ==========================================================================

(define tmp
  (let ((d (string-append (or (getenv "TMPDIR") "/tmp") "/sonic-rv64-test")))
    (system (string-append "mkdir -p " d)) d))

(define (path . parts) (apply string-append tmp "/" parts))

(define (read-all-lines file)
  (call-with-input-file file
    (lambda (p)
      (let loop ((acc '()))
        (let ((l (get-line p)))
          (if (eof-object? l) (reverse acc) (loop (cons l acc))))))))

(define (split str ch)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length str))
           (reverse (cons (substring str start i) acc)))
          ((char=? (string-ref str i) ch)
           (loop (+ i 1) (+ i 1) (cons (substring str start i) acc)))
          (else (loop (+ i 1) start acc)))))

(define (trim s)
  (let* ((n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (char-whitespace? (string-ref s i)))
                                  (loop (+ i 1)) i)))
         (b (let loop ((i n)) (if (and (> i a) (char-whitespace? (string-ref s (- i 1))))
                                  (loop (- i 1)) i))))
    (substring s a b)))

;; --- rendering a listing as assembly text --------------------------------
;; One operand order per format, shared with the encoder, so this printer is
;; total over the table by construction rather than by remembering to extend it.

;; The three mnemonics whose textual form is `op rX,imm(rY)` rather than a flat
;; comma list. Their ENCODED operand order is the same (rX rY imm); only the
;; printing differs, which is exactly the divergence the shared shape was
;; chosen to keep small.
(define offset-form '(ld lw lbu fld sd sw sb fsd jalr))

(define (op->string x) (if (symbol? x) (symbol->string x) (number->string x)))

(define (commas xs)
  (cond ((null? xs) "")
        ((null? (cdr xs)) (car xs))
        (else (string-append (car xs) "," (commas (cdr xs))))))

(define (instr->asm instr)
  (let ((mn-str (symbol->string (car instr))) (o (cdr instr)))
    (string-append
     mn-str "\t"
     (if (memq (car instr) offset-form)
         (string-append (op->string (car o)) ","
                        (op->string (caddr o)) "(" (op->string (cadr o)) ")")
         (commas (map op->string o))))))

;; The listing every check below runs on. Written out rather than generated,
;; because the immediates are the interesting part: signs, both ends of every
;; range, and branches in both directions.
(define coverage-listing
  '(;; SYSTEM. No operands, every field zero. Verified here rather than trusted
    ;; because a fixed word is exactly the kind of encoding it is easy to
    ;; transcribe confidently and wrongly.
    (ecall)
    ;; R4: the fused multiply-adds. Four register operands, and the only
    ;; instructions here whose rs3 rides where funct7 normally sits -- so the
    ;; bytes are the only way to know the field order is right. Both the plain
    ;; and negated forms, because RISC-V negates the PRODUCT and the naming
    ;; invites getting that backwards.
    (fmadd.d  fa0 fa1 fa2 fa3)   (fmsub.d  ft0 ft1 ft2 ft3)
    (fnmsub.d fs0 fs1 fs2 fs3)   (fnmadd.d fa4 fa5 fa6 fa7)
    ;; RV64I / RV64M register-register
    (add   a0 a1 a2)   (sub   t0 t1 t2)   (mul  s2 s3 s4)   (div  t3 t4 t5)
    (slt   a7 s7 t6)   (sltu  a1 a2 a3)   (xor  s11 s10 s9) (and  a4 a5 a6)
    (or    a4 a5 a6)   (sll   a0 a1 a2)   (srl  a0 a1 a2)   (sra  a0 a1 a2)
    ;; register-immediate, including both ends of the 12-bit field
    (addi  a0 a1 -1)   (addi  t0 zero 2047) (addi t1 t2 -2048)
    (slti  a0 a1 5)    (sltiu a6 a7 1)    (xori a4 a5 1)
    (ori   a0 a1 -3)   (andi  t0 a0 7)
    ;; shifts, 6-bit shamt on RV64
    (slli  a2 a3 3)    (slli  a2 a3 63)   (srli a2 a3 1)    (srai a2 a3 31)
    ;; loads and stores, positive and negative offsets, integer and float
    (ld    a0 sp 16)   (ld    t1 t2 -8)   (lw   a0 sp 4)
    ;; byte access, both directions
    (lbu   a0 t1 0)    (lbu   t2 s8 2047) (sb   a0 t1 0)    (sb   t3 s9 -2048)
    (sd    a0 sp 24)   (sd    t3 s0 -16)  (sw   a0 sp 8)
    (fld   ft0 a0 0)   (fld   fa3 t1 8)   (fld  fs11 a1 -2048)
    (fsd   fs2 sp 32)  (fsd   ft11 a1 -8) (fsd  fa0 s0 2047)
    ;; upper immediates
    (lui   a0 #x12345) (lui   t6 #xfffff) (auipc a0 1)
    ;; jumps and branches, forward
    (jalr  zero ra 0)  (jalr  ra t0 0)    (jalr ra a0 -4)
    (beq   a0 a1 fwd)  (bne   t0 zero fwd) (blt a2 a3 fwd)
    (bge   a4 a5 fwd)  (bltu  s2 s3 fwd)  (bgeu a6 a7 fwd)
    (jal   zero fwd)   (jal   ra fwd)
    ;; D extension
    (fadd.d ft0 ft1 ft2)   (fsub.d fa0 fa1 fa2)
    (fmul.d fs0 fs1 fs2)   (fdiv.d ft8 ft9 ft10)
    (fsqrt.d fa5 fa6)
    (fsgnj.d ft3 ft4 ft4)  (fsgnjn.d ft3 ft4 ft4) (fsgnjx.d ft3 ft4 ft4)
    (fmin.d fs4 fs5 fs6)   (fmax.d fs7 fs8 fs9)
    (feq.d a0 ft0 ft1)     (flt.d a1 ft2 ft3)     (fle.d a2 ft4 ft5)
    (fcvt.d.l ft0 a0)      (fmv.d.x ft1 a1)
    fwd
    ;; and backward, so the sign of every displacement field is exercised
    (jal   zero fwd)   (beq   zero zero fwd)  (bge s2 s3 fwd)))

;; Totality: a mnemonic added to the encoder without a differential case here
;; must fail, or the verification quietly stops covering it.
(ck! "the differential listing covers EVERY mnemonic the encoder knows"
     (let ((covered (map car (filter pair? coverage-listing))))
       (for-all (lambda (mn) (memq mn covered)) (instr-mnemonics))))

;; --- run the real assembler ----------------------------------------------

(define asm-available?
  (zero? (system "riscv64-linux-gnu-gcc --version >/dev/null 2>&1")))

(unless asm-available?
  (display "  FAIL riscv64-linux-gnu-gcc is not installed, and the encoder's\n")
  (display "       correctness is DEFINED as agreement with it. Install\n")
  (display "       gcc-riscv64-linux-gnu; there is no local expectation table\n")
  (display "       to fall back to, on purpose.\n")
  (set! failures (+ failures 1))
  (set! checks (+ checks 1)))

(define (hex-digit? c)
  (or (char-numeric? c) (and (char>=? c #\a) (char<=? c #\f))))

(define (downcase s)
  (list->string (map char-downcase (string->list s))))

(define (assemble-listing tag listing)
  ;; -> list of (address-string hex-word mnemonic operands)
  (let ((s (path tag ".s")) (o (path tag ".o")) (d (path tag ".dis")))
    (when (file-exists? s) (delete-file s))
    (call-with-output-file s
      (lambda (p)
        ;; norvc, not because C is wrong but because the GC metadata in
        ;; gcmeta.ss is a step function over byte offsets and mixed widths make
        ;; every offset a function of the compressor's choices.
        (display ".option norvc\n.text\n.globl sonic_cover\nsonic_cover:\n" p)
        (for-each (lambda (x)
                    (if (symbol? x)
                        (begin (display (symbol->string x) p) (display ":\n" p))
                        (begin (display "\t" p) (display (instr->asm x) p)
                               (newline p))))
                  listing)))
    (unless (zero? (system (string-append
                            "riscv64-linux-gnu-gcc -march=rv64gc -c " s " -o " o
                            " 2>" (path "as.err"))))
      (error 'assemble-listing "the real assembler rejected our listing; see"
             (path tag ".err")))
    (unless (zero? (system (string-append
                            "riscv64-linux-gnu-objdump -d -M no-aliases " o
                            " > " d " 2>/dev/null")))
      (error 'assemble-listing "objdump failed" d))
    (let loop ((ls (read-all-lines d)) (acc '()))
      (if (null? ls)
          (reverse acc)
          (let ((fs (split (car ls) #\tab)))
            (if (and (>= (length fs) 3)
                     (let ((a (trim (car fs))))
                       (and (> (string-length a) 1)
                            (char=? (string-ref a (- (string-length a) 1)) #\:)
                            ;; addresses are HEX, so "c:" and "1c:" are lines
                            ;; too; requiring a decimal digit here silently
                            ;; drops six instructions in every sixteen.
                            (hex-digit? (string-ref a 0)))))
                (loop (cdr ls) (cons (list (trim (car fs)) (trim (cadr fs))
                                           (trim (caddr fs))
                                           (if (> (length fs) 3) (trim (cadddr fs)) ""))
                                     acc))
                (loop (cdr ls) acc)))))))

(define (hex-of-word w)
  (let ((s (downcase (number->string w 16))))
    (string-append (make-string (- 8 (string-length s)) #\0) s)))

(when asm-available?
  (let* ((ref (assemble-listing "cover" coverage-listing))
         (ours (encode-listing coverage-listing))
         (instrs (filter pair? coverage-listing)))
    (ck! "binutils produced one word per instruction in our listing"
         (= (length ref) (length instrs)))
    (ck! "and we produced the same number of bytes"
         (= (length ours) (* 4 (length instrs))))
    ;; The check the whole bead exists for.
    (let loop ((rs ref) (i 0) (bad '()))
      (if (null? rs)
          (begin
            (ck! (string-append "all " (number->string (length ref))
                                " instructions encode BYTE-IDENTICALLY to binutils")
                 (null? bad))
            (unless (null? bad)
              (for-each (lambda (b)
                          (display "         ") (write b) (newline))
                        (reverse bad))))
          (let* ((r (car rs))
                 (theirs (cadr r))
                 (mine (hex-of-word
                        (let ((bs (list-tail ours (* 4 i))))
                          (+ (car bs) (* 256 (cadr bs))
                             (* 65536 (caddr bs)) (* 16777216 (cadddr bs)))))))
            (loop (cdr rs) (+ i 1)
                  (if (string=? theirs mine)
                      bad
                      (cons (list (list-ref instrs i) 'binutils theirs 'ours mine)
                            bad))))))
    ;; And the round-trip the bead's acceptance criterion names: objdump must
    ;; read back the mnemonic we asked for, canonical form, no aliases.
    (let loop ((rs ref) (is instrs) (bad '()))
      (if (null? rs)
          (begin
            (ck! "and every one disassembles back to the mnemonic we emitted"
                 (null? bad))
            (unless (null? bad)
              (for-each (lambda (b) (display "         ") (write b) (newline))
                        (reverse bad))))
          (loop (cdr rs) (cdr is)
                (if (string=? (caddr (car rs)) (symbol->string (car (car is))))
                    bad
                    (cons (list (car is) '-> (caddr (car rs))) bad)))))))

;;; ==========================================================================
;;; 5. End to end: the fixture, through selection, to bytes binutils agrees with
;;; ==========================================================================
;;
;; Selection produces vregs; the encoder needs machine registers. Standing in
;; for the allocator with a fixed map keeps this bead independent of E2-RA
;; while still exercising the whole path. Note the map avoids t0: the load rule
;; uses it as an address temporary, which is the conflict with regs.ss's raw
;; pool recorded in target-rv64.ss.

(define phys-map
  '((v-seven . t1) (v-i . t2) (v-k . t3) (v-off . t4) (v-idx . t5)
    (v-b . a0) (v-val . ft0)))

(define (physicalize instr)
  (map (lambda (x) (let ((p (and (symbol? x) (assq x phys-map))))
                     (if p (cdr p) x)))
       instr))

(define fixture-listing (map physicalize entry-instrs))

(when asm-available?
  (let ((ref (assemble-listing "nbody" fixture-listing))
        (ours (encode-listing fixture-listing)))
    (ck! "nbody's inner loop assembles to 8 rv64gc instructions"
         (and (= (length ref) 8) (= (length ours) 32)))
    (ck! "and every byte of it matches binutils"
         (let loop ((rs ref) (i 0))
           (cond ((null? rs) #t)
                 ((string=? (cadr (car rs))
                            (hex-of-word
                             (let ((bs (list-tail ours (* 4 i))))
                               (+ (car bs) (* 256 (cadr bs))
                                  (* 65536 (caddr bs)) (* 16777216 (cadddr bs))))))
                  (loop (cdr rs) (+ i 1)))
                 (else #f))))
    (ck! "the fld is a real double load and the address arithmetic is explicit"
         (equal? (map caddr ref)
                 ;; fsgnj.d is the return move: `fmv.d fa0, ft0` is an alias
                 ;; for it, and binutils prints the real mnemonic under
                 ;; -M no-aliases.
                 '("addi" "mul" "add" "slli" "add" "fld" "fsgnj.d" "jalr")))))

;;; --- an RV64 image that the kernel actually runs -------------------------
;;;
;;; EVERY OTHER RV64 CHECK IN THIS TREE INSPECTS AN ARTIFACT. The differential
;;; test above compares our bytes to binutils, and the smoke gate reads our
;;; output back through objdump. Both are real, and both stop short of the only
;;; claim that catches a wrong header: that the kernel loads the file and the
;;; program does what it says.
;;;
;;; run-x86-64-test.ss carried the reason this did not exist -- "x86-64 only,
;;; because this machine is x86-64". The container has qemu-riscv64 now, so
;;; that reason has expired the same way the two in D74 and D76 did.
;;;
;;; exit(42): a0 is the status, a7 is 93 (SYS_exit on the generic unistd ABI
;;; RISC-V uses), and ecall makes the call. Small enough to be obviously right,
;;; and it exercises the whole chain: our encoder, our ELF writer, and a real
;;; loader. It fails if e_machine, e_flags, the entry address, or the program
;;; headers are wrong -- none of which the byte-level tests can see.
(define qemu-available?
  (zero? (system "qemu-riscv64 --version >/dev/null 2>&1")))

(if (not qemu-available?)
    (begin
      (display "  SKIP qemu-riscv64 absent; the RV64 image is not executed\n")
      (display "       (byte-level checks above still ran)\n"))
    (let* ((code (u8-list->bytevector
                  (encode-listing '((addi a0 zero 42)
                                    (addi a7 zero 93)
                                    (ecall)))))
           (img (build-executable 'rv64 code (make-bytevector 0)
                                  elf-text-vaddr #x600000 4096))
           (path "/tmp/sonic-rv64-exit42"))
      (write-executable path img)
      (system (string-append "chmod +x " path))
      (ck! "an RV64 image we emit is loaded and run by the kernel, and exits 42"
           (= 42 (system (string-append "qemu-riscv64 " path))))
      ;; THE CONTROL. Without it, "exits 42" would also pass if qemu failed to
      ;; start the program and something returned 42 by accident.
      (ck! "and a different status really does come back different"
           (let* ((c2 (u8-list->bytevector
                       (encode-listing '((addi a0 zero 7)
                                         (addi a7 zero 93)
                                         (ecall)))))
                  (i2 (build-executable 'rv64 c2 (make-bytevector 0)
                                        elf-text-vaddr #x600000 4096))
                  (p2 "/tmp/sonic-rv64-exit7"))
             (write-executable p2 i2)
             (system (string-append "chmod +x " p2))
             (= 7 (system (string-append "qemu-riscv64 " p2)))))))

;;; --- how far a REAL program gets on RV64 ---------------------------------
;;;
;;; This pins the boundary rather than a capability, and the distinction is the
;;; useful part. Compiling nbody for rv64 must fail -- there is no RV64 runtime
;;; (bead 1mp.6) -- but it must fail AT THE RUNTIME, having got through
;;; selection, register allocation, encoding and object emission on a real
;;; program rather than a hand-written fixture.
;;;
;;; NBODY ON RISC-V, RUN, AND HELD TO THE SAME ORACLE AS x86-64.
;;;
;;; This is the claim D75 said could not be made: "tested on both targets" meant
;;; the back-end machinery, because no Scheme program had ever been lowered to
;;; RV64. Ten defects later it can (D81).
;;;
;;; The energies are compared BIT FOR BIT against the x86-64 build, not to nine
;;; decimals. Nine decimals is what SPEC.md publishes and would pass here too,
;;; but the value of this target is that it agrees EXACTLY -- the smoke gate is
;;; explicit that cross-ISA bit-exactness holds only with contraction and
;;; vectorization off, which is what config-sonic.sps compiles as. A weaker
;;; comparison would hide exactly the divergence that check exists to catch.
(ck! "nbody compiles for rv64 with no error at all"
     (guard (e (#t #f))
       (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs 'rv64)
       #t))

(if (not qemu-available?)
    (display "  SKIP qemu-riscv64 absent; nbody is not run on rv64\n")
    (let ((rv "/tmp/sonic-nbody-rv64") (x8 "/tmp/sonic-nbody-x86"))
      (ck! "nbody RUNS on rv64 under qemu"
           (guard (e (#t #f))
             (compile-sonic-to-file "../bench/nbody/config-sonic.sps"
                                    nbody-externs rv 'rv64)
             (system (string-append "chmod +x " rv))
             (zero? (system (string-append "qemu-riscv64 " rv " > " rv ".out")))))
      (ck! "and its energies are BIT-IDENTICAL to the x86-64 build's"
           (guard (e (#t #f))
             (compile-sonic-to-file "../bench/nbody/config-sonic.sps"
                                    nbody-externs x8 'x86-64)
             (system (string-append "chmod +x " x8))
             (system (string-append x8 " 1000 > " x8 ".out"))
             (zero? (system (string-append "cmp -s " rv ".out " x8 ".out")))))))

;;; --- INCOMING STACK ARGUMENTS, finally reached ---------------------------
;;;
;;; RV64 passes four raw-word arguments in t3-t6, so a fifth arrives on the
;;; stack. x86-64 has six such registers and never spills at five, and that
;;; asymmetry is why frame-incoming-offset's return-address word went unnoticed
;;; as an x86-only quantity: `call` pushes one and `jal` does not, so RV64 read
;;; every incoming stack argument eight bytes too high.
;;;
;;; Two earlier attempts at this test exercised NOTHING. A six-argument function
;;; called with literals is constant-folded before selection, and the
;;; nested-loop reproduction uses three arguments. This one is recursive, so
;;; inlining and folding cannot remove the call, and NOT in tail position at the
;;; top level -- a tail call from main is refused, correctly, because main
;;; receives no incoming area to write over.
;;;
;;; The value is what matters: both targets must agree, and 8.0 is only produced
;;; if the fifth argument survives the trip.
(if (not qemu-available?)
    (display "  SKIP qemu-riscv64 absent; stack arguments are not exercised\n")
    (let ((rv "/tmp/sonic-sa-rv64") (x8 "/tmp/sonic-sa-x86"))
      (ck! "a fifth raw-word argument travels via the stack on rv64, and agrees with x86-64"
           (guard (e (#t #f))
             (compile-sonic-to-file "test/rv64-stackargs.sps" '(display newline) rv 'rv64)
             (compile-sonic-to-file "test/rv64-stackargs.sps" '(display newline) x8 'x86-64)
             (system (string-append "chmod +x " rv " " x8))
             (system (string-append "qemu-riscv64 " rv " > " rv ".out"))
             (system (string-append x8 " > " x8 ".out"))
             (zero? (system (string-append "cmp -s " rv ".out " x8 ".out")))))))

;;; --- the reserved scratch registers are shared, and nothing arbitrated ----
;;;
;;; regs.ss reserves t0/t1/t2 so passes can use a register the allocator will
;;; never hand out. THREE independent consumers draw from that set, and until
;;; today two of them had both taken t0:
;;;
;;;   twoaddr.ss scratch-table   (rv64 (raw-word . t0))   two-address fixups
;;;   rv64-addr-scratch          t1                       address computation
;;;   rv64-overflow-scratch      (t0 t1)                  the overflow idiom
;;;
;;; twoaddr.ss checks its table against regs.ss on every lookup, which confirms
;;; each register IS reserved. Nothing checked that two consumers had not picked
;;; the SAME reserved one -- so a global address computed into t0 was overwritten
;;; by a value staged through t0, and nbody stored 5 to address 5. That was found
;;; by single-stepping a segfault half a megabyte into the program; this would
;;; have caught it at build time.
(ck! "the address scratch and the two-address scratch are different registers"
     (not (eq? (rv64-addr-scratch) (scratch-for 'rv64 'raw-word))))

;; KNOWN OVERLAP, PINNED RATHER THAN ASSERTED AWAY. rv64-overflow-scratch names
;; a PAIR and currently overlaps both of the above: four register-demands
;; against three integer scratches. It has not bitten because an overflow check
;; is arithmetic and does not compute an address, so the sequences do not
;; interleave -- but that is a property nothing enforces, and it is the same
;; reasoning that made the t0 collision look safe.
;;
;; This asserts the overlap EXISTS, so the day someone resolves it this test
;; fails and points at the note rather than passing silently.
(ck! "the overflow scratch pair still overlaps the others (unresolved, bead 1mp.9)"
     (let ((ov (rv64-overflow-scratch)))
       (and (memq (rv64-addr-scratch) ov) #t)))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
