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
        (sonic regs) (sonic target-rv64) (sonic encode-rv64) (sonic litpool) (sonic numeric))

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
               (slli t0 v-idx 3)
               (add t0 v-b t0)
               ;; -1, not 0: the displacement absorbs the heap pointer tag,
               ;; because a pointer is tagged and nothing strips it before the
               ;; load. See numeric.ss `heap-element-disp`.
               (fld v-val t0 ,heap-element-disp)
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
(ck! "a flonum constant interns into the pool and loads via auipc + fld"
     (parameterize ((current-litpool (make-pool)))
       (let ((out (sel1 '(const v-t raw-f64 1.5))))
         (and (= (length out) 2)
              (eq? (car (car out)) 'auipc)
              (equal? (cadr out) `(fld v-t ,(cadr (car out)) ,(caddr (car out))))))))
;; Two references to the SAME constant must intern once. Interning twice would
;; not be wrong, but the pool is emitted into .rodata and nbody's inner loop
;; reads the same handful of constants every iteration.
(ck! "interning is by value, so the same constant gets one pool slot"
     (parameterize ((current-litpool (make-pool)))
       (let ((a (sel1 '(const v-t raw-f64 1.5)))
             (b (sel1 '(const v-u raw-f64 1.5)))
             (c (sel1 '(const v-w raw-f64 2.5))))
         (and (= (caddr (car a)) (caddr (car b)))
              (not (= (caddr (car a)) (caddr (car c))))))))
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
(define offset-form '(ld lw fld sd sw fsd jalr))

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
  '(;; RV64I / RV64M register-register
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
    (ck! "nbody's inner loop assembles to 7 rv64gc instructions"
         (and (= (length ref) 7) (= (length ours) 28)))
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
                 '("addi" "mul" "add" "slli" "add" "fld" "jalr")))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
