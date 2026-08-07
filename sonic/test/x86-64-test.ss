;;; E2-X86SEL and E2-X86ENC.
;;;
;;; The encoder is NOT checked against hand-written expected bytes. Every
;;; instruction here is assembled by gcc and disassembled by objdump, and the
;;; bytes are compared. Hand-derived x86-64 encodings are wrong more often than
;;; they are right, so an expectation table would test this file's author rather
;;; than the encoder.
;;;
;;; Needs gcc and objdump on PATH. If they are missing the differential checks
;;; FAIL rather than skip: a green run that silently verified nothing is worse
;;; than a red one.

(import (chezscheme) (nanopass) (rnrs io simple)
        (sonic lang) (sonic fixtures) (sonic select) (sonic regs) (sonic regalloc)
        (sonic target-x86-64) (sonic encode-x86-64) (sonic litpool))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (raises? thunk)
  (guard (e (#t #t)) (thunk) #f))

;; --- selection over THE fixture -------------------------------------------

(ck! "the x86-64 target covers nbody's lowered inner loop"
     (selector-covers? x86-64-selector (nbody-inner-mach)))
(ck! "and reports nothing missing"
     (null? (missing-rules x86-64-selector (nbody-inner-mach))))
(ck! "the selector carries the x86-64 partition, not a copy of it"
     (eq? (selector-partition x86-64-selector) arch-x86-64))

(define selected (select-program x86-64-selector (nbody-inner-mach)))
(define nbody-vreg-instrs (cadr (car (cadddr selected))))

(define (flat x) (cond ((pair? x) (append (flat (car x)) (flat (cdr x))))
                       ((symbol? x) (list x)) (else '())))

(let ((syms (flat selected)) (mn (map car nbody-vreg-instrs)))
  (ck! "the multiply became imul and the load became a movsd"
       (and (memq 'imul mn) (memq 'movsd mn) (memq 'add mn) (memq 'mov mn) (memq 'ret mn)))
  (ck! "no Lmach op name survived selection"
       (not (or (memq 'mul syms) (memq 'load syms) (memq 'const syms))))
  (ck! "the index computation folded into an addressing mode rather than an lea"
       (let ((ld (assq 'movsd nbody-vreg-instrs)))
         (and ld (pair? (caddr ld)) (eq? (car (caddr ld)) 'mem)
              (= (list-ref (caddr ld) 3) 8))))
  (ck! "every selected mnemonic is one the encoder actually has"
       (for-all x86-64-supports? mn)))

;; The three-address to two-address rewrite, which is the real mismatch.
(let ((r (cdr (assq 'sub x86-64-rules))))
  (ck! "a three-address op becomes a copy plus a destructive operate"
       (equal? (r 'rbx 'raw-word '(r8 r9)) '((mov rbx r8) (sub rbx r9))))
  (ck! "the copy is dropped when the destination is already the first operand"
       (equal? (r 'rbx 'raw-word '(rbx r9)) '((sub rbx r9))))
  (ck! "integer subtract into its own second operand negates instead of spilling"
       (equal? (r 'rbx 'raw-word '(r8 rbx)) '((sub rbx r8) (neg rbx))))
  (ck! "subsd into its own second operand REFUSES rather than emitting wrong code"
       (raises? (lambda () (r 'xmm1 'raw-f64 '(xmm2 xmm1))))))
(let ((r (cdr (assq 'add x86-64-rules))))
  (ck! "a commutative op swaps instead of needing a scratch"
       (equal? (r 'rbx 'raw-word '(r8 rbx)) '((add rbx r8)))))

;; UPDATED: `abs` is no longer owed. The constant pool exists, so the sign mask
;; it needs exists, and it selects. It is still IEEE-correct by construction --
;; a bit mask, not a compare and branch -- so it agrees with the reference on
;; negative zero and on NaN payloads.
(ck! "`abs` now selects, as a sign-bit AND against a pooled mask"
     (let ((r (cdr (assq 'abs x86-64-rules))))
       (parameterize ((current-litpool (make-pool)))
         (let ((out (r 'xmm1 'raw-f64 '(xmm2))))
           (and (equal? (car out) '(movsd xmm1 xmm2))
                (eq? (car (cadr out)) 'andpd)
                (equal? (cadr (cadr out)) 'xmm1)
                (eq? (car (caddr (cadr out))) 'mem))))))
;; And negation is a DIFFERENT mask. Sharing one slot would make (- x) compute
;; (abs x), which no type error and no crash would reveal.
(ck! "negation and abs intern two distinct pool slots"
     (parameterize ((current-litpool (make-pool)))
       (let ((n ((cdr (assq 'neg x86-64-rules)) 'xmm1 'raw-f64 '(xmm1)))
             (a ((cdr (assq 'abs x86-64-rules)) 'xmm1 'raw-f64 '(xmm1))))
         (not (equal? (list-ref (caddr (car n)) 4)
                      (list-ref (caddr (car a)) 4))))))

;; There is only ONE spelling of a check now. The mach-ops check-bounds,
;; check-type and check-overflow are gone from lang.ss: they could carry
;; neither the control nor the expected tag, so a type check through that path
;; passed 0 -- the FIXNUM tag, not a no-answer marker -- and compiled "check
;; this is something" into "check this is a fixnum". Asserted as absence, so
;; reintroducing the duplication fails here.
(ck! "the mach-op spelling of a check no longer exists"
     (and (not (mach-op? 'check-bounds))
          (not (mach-op? 'check-type))
          (not (mach-op? 'check-overflow))
          (not (assq 'check-bounds x86-64-rules))
          (not (assq 'check-type x86-64-rules))
          (not (assq 'check-overflow x86-64-rules))))

;; A suppressed check must stay suppressed.
(ck! "an `unchecked` chk emits nothing"
     (null? (select-instr x86-64-selector '(chk bounds-check unchecked 0 v0 v1))))
(ck! "a `checked` chk emits a compare and a trap branch"
     (equal? (select-instr x86-64-selector '(chk bounds-check checked 0 v0 v1))
             '((cmp v0 v1) (jge (label sonic-bounds-error)))))

;; --- allocate the fixture onto real registers ------------------------------

(define nbody-mach-instrs
  (let* ((p (unparse-Lmach (nbody-inner-mach)))
         (blk (cadr (car (cadr p)))))
    (cadr blk)))

(define classes
  (let ((t (make-eq-hashtable)))
    ;; The three block-live-in vregs have no defining instruction, so their
    ;; classes come from the fixture's prose: `b` is the tagged flvector, `i`
    ;; and `k` are raw indices.
    (for-each (lambda (p) (hashtable-set! t (car p) (cdr p)))
              '((v-b . tagged) (v-i . raw-word) (v-k . raw-word)
                (v-seven . raw-word) (v-off . raw-word) (v-idx . raw-word)
                (v-val . raw-f64)))
    t))

(define alloc (allocate arch-x86-64 nbody-mach-instrs classes))

(define (resolve x)
  (cond ((pair? x) (cons (resolve (car x)) (resolve (cdr x))))
        ((symbol? x) (or (hashtable-ref (alloc-result-map alloc) x #f) x))
        (else x)))

(define nbody-instrs (resolve nbody-vreg-instrs))

(ck! "the allocator placed the whole fixture without spilling"
     (null? (alloc-result-spills alloc)))
(ck! "the tagged flvector landed in the value class and the f64 in an SSE register"
     (and (eq? (reg-class arch-x86-64 (hashtable-ref (alloc-result-map alloc) 'v-b #f)) 'value)
          (eq? (reg-class arch-x86-64 (hashtable-ref (alloc-result-map alloc) 'v-val #f)) 'float)))

;; --- the differential harness ----------------------------------------------

(define tmpdir "/tmp")
(define stem (string-append tmpdir "/sonic-x86-check-"
                            (number->string (random 100000000))))
(define asm-file (string-append stem ".s"))
(define obj-file (string-append stem ".o"))
(define dis-file (string-append stem ".txt"))

(define (cleanup!)
  (for-each (lambda (f) (when (file-exists? f) (delete-file f)))
            (list asm-file obj-file dis-file)))

(define (string-split s ch)
  (let loop ((i 0) (start 0) (acc '()))
    (cond ((= i (string-length s)) (reverse (cons (substring s start i) acc)))
          ((char=? (string-ref s i) ch)
           (loop (+ i 1) (+ i 1) (cons (substring s start i) acc)))
          (else (loop (+ i 1) start acc)))))

(define (non-empty ss) (filter (lambda (s) (> (string-length s) 0)) ss))

(define (trim s)
  (let* ((n (string-length s))
         (a (let loop ((i 0)) (if (and (< i n) (char-whitespace? (string-ref s i)))
                                  (loop (+ i 1)) i)))
         (b (let loop ((i n)) (if (and (> i a) (char-whitespace? (string-ref s (- i 1))))
                                  (loop (- i 1)) i))))
    (substring s a b)))

;; --- printing a target instruction as gas Intel syntax ---------------------
;; Intel syntax so the operand order matches our instructions directly; getting
;; the order backwards in an AT&T template would make the differential test
;; compare the wrong thing and still look green on the symmetric cases.

(define (gas-mem m size?)
  (let ((b (cadr m)) (i (caddr m)) (s (cadddr m)) (d (list-ref m 4)))
    (unless b (error 'gas-mem "the harness does not print baseless addressing" m))
    ;; `size?` is #f, 'qword or 'xmmword. A packed-double operand is 128 bits
    ;; and gas rejects QWORD PTR on it, which would look like an encoder bug.
    (string-append (case size?
                     ((#f) "")
                     ((xmmword) "XMMWORD PTR ")
                     (else "QWORD PTR "))
                   "[" (symbol->string b)
                   (if i (string-append " + " (symbol->string i) "*" (number->string s)) "")
                   " + " (number->string d) "]")))

(define (gas-op x size?)
  (cond ((and (pair? x) (eq? (car x) 'imm)) (number->string (cadr x)))
        ((and (pair? x) (eq? (car x) 'mem)) (gas-mem x size?))
        ((symbol? x) (symbol->string x))
        (else (error 'gas-op "cannot print operand" x))))

(define packed-mnemonics '(xorpd andpd))

(define setcc-mnemonics '(sete setne setl setge setle setg))
(define jcc-mnemonics '(je jne jl jge jle jg jo))

(define (instr->gas i)
  (let ((m (car i)) (ops (cdr i)))
    (define (name) (symbol->string m))
    (cond
     ((eq? m 'ret) "ret")
     ((memq m '(jmp call))
      (string-append (name) " .+" (number->string (+ 5 (cadr (car ops))))))
     ((memq m jcc-mnemonics)
      (string-append (name) " .+" (number->string (+ 6 (cadr (car ops))))))
     ((memq m setcc-mnemonics)
      (string-append (name) " " (symbol->string (gpr-8bit-name (car ops)))))
     ((eq? m 'movzx)
      (string-append "movzx " (gas-op (car ops) #f) ", "
                     (symbol->string (gpr-8bit-name (cadr ops)))))
     ((eq? m 'lea)
      ;; no size prefix: lea computes an address, it does not access memory
      (string-append "lea " (gas-op (car ops) #f) ", " (gas-op (cadr ops) #f)))
     ((eq? m 'neg) (string-append "neg " (gas-op (car ops) #t)))
     (else
      (let ((sz (if (memq m packed-mnemonics) 'xmmword 'qword)))
        (string-append (name) " " (gas-op (car ops) sz) ", " (gas-op (cadr ops) sz)))))))

;; --- assemble one instruction and read its bytes back ----------------------

;; stderr only. Redirecting stdout here would clobber the objdump command's own
;; redirect, since the last one on the line wins.
(define (shell cmd) (zero? (system (string-append cmd " 2>/dev/null"))))

(define (gas-bytes line)
  (with-output-to-file asm-file
    (lambda ()
      (display ".intel_syntax noprefix\n.text\n") (display line) (newline))
    'replace)
  (unless (shell (string-append "gcc -c " asm-file " -o " obj-file))
    (error 'gas-bytes "gcc refused the instruction" line))
  (unless (shell (string-append "objdump -d --insn-width=16 -M intel "
                                obj-file " > " dis-file))
    (error 'gas-bytes "objdump failed" line))
  ;; Take the instruction at offset 0. Anything after it is padding or the
  ;; branch-target filler, and objdump will happily disassemble that as garbage.
  (call-with-input-file dis-file
    (lambda (p)
      (let loop ()
        (let ((l (get-line p)))
          (cond
           ((eof-object? l) (error 'gas-bytes "no instruction at offset 0" line))
           (else
            (let ((fields (string-split l #\tab)))
              (if (and (>= (length fields) 2) (string=? (trim (car fields)) "0:"))
                  (map (lambda (h) (string->number h 16))
                       (non-empty (string-split (trim (cadr fields)) #\space)))
                  (loop))))))))))

(define verified 0)

(define (differential! i)
  (set! checks (+ checks 1))
  (let* ((line (instr->gas i))
         (mine (encode-instr i))
         (theirs (guard (e (#t 'error)) (gas-bytes line))))
    (cond
     ((equal? mine theirs)
      (set! verified (+ verified 1))
      (display "  ok   ") (display line) (newline))
     (else
      (set! failures (+ failures 1))
      (display "  FAIL ") (display line)
      (display "  mine=") (write mine) (display " gas=") (write theirs) (newline)))))

;; Every mnemonic the encoder claims to support appears below at least once, and
;; the register choices are deliberately weighted toward r8-r15: the partition in
;; regs.ss puts six of the eight VALUE registers there, so REX is the common case
;; and an encoder that only ever got rax-rdi right would look fine on a toy test.
(define instruction-corpus
  `(;; moves and immediates
    (mov rbx (imm 7))
    (mov r13 (imm 7))                       ; REX.B
    (mov rbx (imm #x123456789))             ; movabs, the only 64-bit immediate
    (mov r14 r8)                            ; REX.R and REX.B together
    (mov rax (mem rbx r9 8 0))              ; REX.X
    (mov (mem r13 r8 8 0) rbx)              ; r13 base forces an explicit disp8 0
    (mov rax (mem rsp #f 1 0))              ; rsp base forces a SIB byte
    (mov rcx (mem r12 #f 1 0))              ; r12 base forces a SIB byte too
    ;; RIP-relative, which every pooled f64 constant load uses. mod=00 rm=101
    ;; and NO SIB byte; gas takes the displacement literally in Intel syntax,
    ;; so the bytes are directly comparable.
    (mov rax (mem rip #f 1 64))
    (mov r11 (mem rip #f 1 -8))             ; REX.R on a RIP operand
    (movsd xmm3 (mem rip #f 1 16))
    (movsd xmm12 (mem rip #f 1 0))          ; REX.R with a zero displacement
    ;; IEEE negation and abs: a sign-bit mask, packed because SSE has no
    ;; scalar bitwise form
    (xorpd xmm1 xmm2)
    (xorpd xmm9 xmm14)                      ; REX.R and REX.B
    (andpd xmm0 xmm3)
    (xorpd xmm2 (mem rip #f 1 32))          ; the pooled mask, RIP-relative
    (andpd xmm11 (mem rip #f 1 16))
    ;; the type check's tag mask
    (and rbx (imm 7))
    (and r13 (imm 7))                       ; REX.B on the immediate form
    (and r14 r8)
    ;; integer arithmetic
    (add rbx r8)
    (add r14 (imm 7))                       ; imm8 form
    (add rbx (imm 200))                     ; imm32 form
    (sub r9 r10)
    (sub rbx (imm 7))
    (imul r13 rbx)
    (imul rax r11)
    (imul r10 (mem r14 r9 8 16))
    (lea rbx (mem r14 r9 8 24))
    (lea r10 (mem rax #f 1 8))
    (shl r12 (imm 3))
    (neg r13)
    (neg rax)
    ;; comparison and materialisation
    (cmp rbx r9)
    (cmp r10 (imm 0))
    (cmp rbx (imm 300))
    (setl rbx)
    (setl rsi)                              ; sil needs a bare REX to exist
    (setne r11)
    (sete rax)
    (setge r13)
    (setle r12)
    (setg rdi)
    (movzx rbx rsi)
    (movzx r13 r14)
    ;; scalar double, baseline SSE2
    (addsd xmm3 xmm11)
    (subsd xmm9 xmm2)
    (mulsd xmm0 xmm15)
    (divsd xmm7 xmm7)
    (sqrtsd xmm13 xmm4)
    (addsd xmm4 (mem rsp #f 1 32))
    (movsd xmm1 xmm12)
    (movsd xmm2 (mem r12 rbx 8 0))
    (movsd (mem r13 r8 8 0) xmm3)
    (movsd xmm3 (mem rbx #f 1 0))
    (movsd xmm3 (mem rbp #f 1 16))
    (cvtsi2sd xmm8 r14)
    (cvtsi2sd xmm5 rdi)
    ;; control. The displacements are all past rel8 range so gas cannot relax
    ;; the branch to the short form and quietly disagree with us about width.
    (jmp (rel 256))
    (je (rel 512))
    (jne (rel 300))
    (jl (rel 512))
    (jge (rel 200))
    (jle (rel 1000))
    (jg (rel 128))
    (jo (rel 4096))
    (call (rel 0))
    (ret)))

(display "\n-- differential against gcc/objdump --\n")
(for-each differential! instruction-corpus)

(display "\n-- nbody's inner loop, selected and allocated --\n")
(for-each (lambda (i) (display "   ") (write i) (newline)) nbody-instrs)
(for-each differential! nbody-instrs)

(cleanup!)

(let ((rex-verified
       (length (filter (lambda (i)
                         (let ((b (guard (e (#t '())) (encode-instr i))))
                           (and (pair? b) (<= #x40 (car b) #x4f))))
                       (append instruction-corpus nbody-instrs)))))
  (ck! "at least three verified instructions carried a REX prefix"
       (>= rex-verified 3))
  (display "   (") (display rex-verified) (display " of ")
  (display (+ (length instruction-corpus) (length nbody-instrs)))
  (display " needed REX)") (newline))

(ck! "the differential harness actually ran against the real assembler"
     (= verified (+ (length instruction-corpus) (length nbody-instrs))))

;; --- the baseline guard -----------------------------------------------------
;;
;; D24 makes FP contraction a named permission that is OFF by default, and phase
;; 3 measured that baseline x86-64 gcc emits zero FMA instructions. An encoder
;; that fused a multiply-add would round differently from ref.c and the
;; bit-exactness oracle would be comparing two different programs. So this is a
;; correctness test, not a scope test.

(for-each
 (lambda (m)
   (ck! (string-append "refuses " (symbol->string m))
        (and (not (x86-64-supports? m))
             (raises? (lambda () (encode-instr (list m 'xmm0 'xmm1 'xmm2)))))))
 '(vfmadd231sd vfmadd132sd vfnmadd213sd vaddsd vmulsd))

(ck! "the refusal names the reason rather than reading as a missing feature"
     (guard (e (#t (let ((s (with-output-to-string
                              (lambda () (display (condition-message e))))))
                     (and (> (string-length s) 0)
                          (let scan ((i 0))
                            (cond ((> (+ i 3) (string-length s)) #f)
                                  ((string=? (substring s i (+ i 3)) "SSE") #t)
                                  (else (scan (+ i 1)))))))))
       (encode-instr '(vfmadd231sd xmm0 xmm1 xmm2))
       #f))

(ck! "nothing the selector emits for the fixture is a VEX-encoded mnemonic"
     (for-all (lambda (i) (x86-64-supports? (car i))) nbody-instrs))

;; --- encoder refuses malformed operands rather than emitting something ------

(ck! "rsp cannot be a SIB index, and saying so beats emitting `no index`"
     (raises? (lambda () (encode-instr '(mov rax (mem rbx rsp 8 0))))))
(ck! "an unresolved label is refused rather than encoded as displacement zero"
     (raises? (lambda () (encode-instr '(jmp (label somewhere))))))
(ck! "a scalar-double destination must be an SSE register"
     (raises? (lambda () (encode-instr '(addsd rbx xmm1)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures, ")
(display verified) (display " instructions verified byte-for-byte against gcc/objdump")
(newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
