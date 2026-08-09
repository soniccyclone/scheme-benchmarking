;;; E5-AVX512. Packed double emission, and the width veclegal permits.
;;;
;;; NOTHING HERE IS CHECKED AGAINST A HAND-DERIVED BYTE. EVEX is a four-byte
;;; prefix carrying five separate INVERTED register-extension bits plus a
;;; displacement that is scaled by the vector width, and an expectation table
;;; written by whoever wrote the encoder comes from the same reading of the
;;; manual that the encoder does. Every instruction below is assembled by gcc
;;; and disassembled by objdump, and the bytes are compared, which is the same
;;; discipline sonic/test/x86-64-test.ss uses for the scalar encoder.
;;;
;;; Needs gcc and objdump on PATH. If they are missing the differential checks
;;; FAIL rather than skip.
;;;
;;; The other half is the width, and it is not this file's to choose. The
;;; verdict for nbody's `fields` loop comes out of (sonic veclegal), run on the
;;; same fixture veclegal-test.ss uses, and it says 128 and 256 and NOT 512:
;;; seven iterations, eight doubles to a zmm. So the test asserts what is
;;; emitted AND what is not.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/vec-x86-64-test.ss

(import (chezscheme) (nanopass) (rnrs io simple)
        (sonic lang) (sonic fixtures) (sonic elide) (sonic alias)
        (sonic loops) (sonic veclegal) (sonic differential)
        (sonic vec-x86-64) (sonic vex) (sonic regs) (sonic runtime))

(define failures 0) (define checks 0)

(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (check! name got expected)
  (set! checks (+ checks 1))
  (if (equal? got expected)
      (printf "  ok   ~a\n" name)
      (begin (set! failures (+ failures 1))
             (printf "  FAIL ~a\n         expected ~s\n         got      ~s\n"
                     name expected got))))

(define (raises? thunk) (guard (e (#t #t)) (thunk) #f))

(define (raises-naming? thunk needle)
  (guard (e (#t (let ((s (call-with-string-output-port
                          (lambda (p) (if (condition? e) (display-condition e p)
                                          (write e p))))))
                  (let loop ((i 0))
                    (cond ((> (+ i (string-length needle)) (string-length s)) #f)
                          ((string=? (substring s i (+ i (string-length needle))) needle) #t)
                          (else (loop (+ i 1))))))))
    (thunk) #f))

;;; ==========================================================================
;;; 1. The fixture, and the verdict that governs the width
;;; ==========================================================================
;;
;; nbody's three loops, the same shape veclegal-test.ss carries: `bodies` walks
;; the 5 bodies, `pairs` is the triangular half, `fields` is the 7 doubles per
;; body. The access chain inside `fields` is EXTRACTED by running elide.ss over
;; the frozen `nbody-inner-ssa` fixture rather than retyped, so the checks the
;; legality verdict depends on were discharged by the analysis.

(define (elided e facts)
  (let-values ([(out st) (elide e facts)]) out))

(define nbody-facts
  '((b flvector 35) (i interval 0 posinf) (n interval 5 5)
    (k interval 0 6) (seven interval 7 7)))

(define (access-chain)
  (let find ([e (elided (nbody-inner-ssa) nbody-facts)])
    (nanopass-case (Lssa Expr) e
      [(let ([,x ,se]) ,body) (find body)]
      [(if ,x ,e0 ,e1) (find e0)]
      [(sigma ,x0 ,x1 ,pr ,x2 ,b ,body) body]
      [else e])))

(define (nbody-loops)
  (with-output-language (Lssa Expr)
    `(let ([zero (quote 0)])
       (let ([five (quote 5)])
         (let ([seven (quote 7)])
           (let ([one (quote 1)])
             (letrec ([bodies
                       (lambda (i.p n.p)
                         (phi ([i (entry i.p)] [n (entry n.p)])
                           (let ([c1 (primcall fx< () i n)])
                             (if c1
                                 (sigma i2 i fx< n #f
                                   (letrec
                                     ([pairs
                                       (lambda (j.p q.p)
                                         (phi ([j (entry j.p)] [q (entry q.p)])
                                           (let ([c3 (primcall fx< () j q)])
                                             (if c3
                                                 (sigma j.g j fx< q #f
                                                   (let ([j2 (primcall
                                                               fx+ ([overflow-check checked])
                                                               j.g one)])
                                                     (tailcall pairs j2 q)))
                                                 (quote 0)))))]
                                      [fields
                                       (lambda (k.p m.p)
                                         (phi ([k (entry k.p)] [m (entry m.p)])
                                           (let ([c2 (primcall fx< () k m)])
                                             (if c2
                                                 (sigma k.g k fx< m #f
                                                   (seq ,(access-chain)
                                                        (let ([k2 (primcall
                                                                    fx+ ([overflow-check checked])
                                                                    k.g one)])
                                                          (tailcall fields k2 m))))
                                                 (quote 0)))))])
                                     (let ([j0 (primcall fx+ ([overflow-check checked])
                                                         i2 one)])
                                       (let ([r1 (call pairs j0 n)])
                                         (let ([r2 (call fields zero seven)])
                                           (let ([i.n (primcall fx+ ([overflow-check checked])
                                                                i2 one)])
                                             (tailcall bodies i.n n)))))))
                                 (quote 0)))))])
               (tailcall bodies zero five))))))))

;; An element-wise loop long enough that 512 bits IS legal, so the cap on
;; `fields` can be shown to be the verdict's and not this back end's.
(define (saxpy lim)
  (with-output-language (Lssa Expr)
    `(let ([z (quote 0)])
       (let ([lim (quote ,lim)])
         (let ([one (quote 1)])
           (letrec ([lp (lambda (ip np)
                          (phi ([i (entry ip)] [n (entry np)])
                            (let ([t (primcall fx< () i n)])
                              (if t
                                  (sigma i2 i fx< n #f
                                    (let ([av (primcall flvector-ref
                                                        ([type-check proved]
                                                         [bounds-check proved])
                                                        a i2)])
                                      (let ([bv (primcall flvector-ref
                                                          ([type-check proved]
                                                           [bounds-check proved])
                                                          b i2)])
                                        (let ([p (primcall fl* ([fp-contract checked]) s bv)])
                                          (let ([nv (primcall fl+ ([fp-contract checked]) av p)])
                                            (let ([w (primcall flvector-set!
                                                               ([type-check proved]
                                                                [bounds-check proved])
                                                               a i2 nv)])
                                              (let ([inx (primcall fx+
                                                                   ([overflow-check checked])
                                                                   i2 one)])
                                                (tailcall lp inx n))))))))
                                  (quote 0)))))])
             (tailcall lp z lim)))))))

(define distinct-tbl
  (alias-analyze
   (with-output-language (Lanf Expr) `(declare-distinct (a b) (seq a b)))))

(define (verdict-for e tbl name)
  (let scan ([vs (vectorize-legal e tbl)])
    (cond [(null? vs) #f]
          [(eq? (vl-loop (car vs)) name) (car vs)]
          [else (scan (cdr vs))])))

(define fields-verdict (verdict-for (nbody-loops) #f 'fields))
(define pairs-verdict (verdict-for (nbody-loops) #f 'pairs))
(define saxpy-verdict (verdict-for (saxpy 64) distinct-tbl 'lp))

(display "\n-- what veclegal says, which this file obeys --\n")
(vl-report fields-verdict)
(vl-report saxpy-verdict)

(ck! "the fields loop is vectorizable at all" (vl-legal? fields-verdict))
(check! "and veclegal caps it at 256 bits" (vl-widths fields-verdict) '(128 256))
(ck! "the long loop is legal at 512" (memq 512 (vl-widths saxpy-verdict)))

;;; ==========================================================================
;;; 2. The plan: the widest width the verdict permits, and no wider
;;; ==========================================================================

(define plan (plan-for-verdict fields-verdict #f))
(define plan/fma (plan-for-verdict fields-verdict #t))
(define wide-plan (plan-for-verdict saxpy-verdict #f))

(check! "nbody's fields loop plans at 256 bits" (vec-plan-width plan) 256)
(check! "which is four lanes of double" (vec-plan-lanes plan) 4)
(check! "and 32 bytes a pass" (vec-plan-bytes plan) 32)
(check! "the long loop plans at 512, so 256 above is a CAP and not a limit"
        (vec-plan-width wide-plan) 512)

(ck! "a refused loop cannot be planned at all"
     (raises? (lambda () (plan-for-verdict pairs-verdict #f))))
(ck! "and the refusal points at veclegal rather than restating its reasoning"
     (raises-naming? (lambda () (plan-for-verdict pairs-verdict #f)) "veclegal"))

;;; ==========================================================================
;;; 3. nbody's fields loop, emitted
;;; ==========================================================================
;;
;; The kernel is what `advance` does to the 7 doubles per body: each is stepped
;; by the matching velocity component times dt, `f[k] += v[k] * dt`. The
;; registers are the caller's: r8 and r9 hold tagged flvectors and are in the
;; value class, rcx is a raw index, per sonic/src/sonic/regs.ss.

(define kernel (nbody-fields-kernel 'r8 'r9 'rcx 2))

(define body (vec-emit-kernel plan kernel))
(define body/fma (vec-emit-kernel plan/fma kernel))

(display "\n-- nbody's fields loop, contraction OFF (the D24 default) --\n")
(for-each (lambda (i) (display "   ") (write i) (newline)) body)
(display "-- and contraction ON, by permission --\n")
(for-each (lambda (i) (display "   ") (write i) (newline)) body/fma)

(define (mnemonics is) (map car is))
(define (regs-of is)
  (apply append (map (lambda (i) (filter vec-reg? (cdr i))) is)))
(define (any-zmm? is) (exists (lambda (r) (= (vec-reg-width r) 512)) (regs-of is)))
(define (any-ymm? is) (exists (lambda (r) (= (vec-reg-width r) 256)) (regs-of is)))

(ck! "it is PACKED arithmetic, not scalar" (memq 'vmulpd (mnemonics body)))
(ck! "at 256 bits" (any-ymm? body))
(ck! "and NOT at 512, which veclegal refused" (not (any-zmm? body)))
(check! "the whole body, unfused" body
        '((vmovupd ymm0 (mem r8 rcx 8 0))
          (vmovupd ymm1 (mem r9 rcx 8 0))
          (vmulpd ymm15 ymm1 ymm2)
          (vaddpd ymm0 ymm0 ymm15)
          (vmovupd (mem r8 rcx 8 0) ymm0)))

;; The same kernel at a width the verdict DOES permit 512 for.
(define wide-body (vec-emit-kernel wide-plan kernel))
(ck! "the same kernel does reach zmm when the trip count earns it"
     (any-zmm? wide-body))

;;; ==========================================================================
;;; 4. D24: contraction is a permission, and an FMA is contraction
;;; ==========================================================================

(check! "WITHOUT the permission, no fused mnemonic is emitted at all"
        (vec-contraction-evidence body) '())
(check! "and the multiply and the add keep their two roundings"
        (filter (lambda (m) (memq m '(vmulpd vaddpd))) (mnemonics body))
        '(vmulpd vaddpd))
(check! "WITH it, exactly one FMA"
        (vec-contraction-evidence body/fma) '(vfmadd231pd))
(check! "on a ymm, because the permission grants contraction and not width"
        (vec-plan-width plan/fma) 256)
(ck! "the fused body is shorter by exactly the instruction that was fused"
     (= (length body/fma) (- (length body) 1)))

;; The guard in sonic/src/sonic/differential.ss, wired to real evidence rather
;; than to a hand-passed symbol. A bit-exact comparison in the presence of an
;; FMA is refused, and refused BEFORE it can report a divergence that is not an
;; unsoundness.
(ck! "check-fp-policy! accepts the unfused build under the bit-exact policy"
     (fp-policy? (check-fp-policy! bit-exact-policy
                                  (vec-contraction-evidence body)
                                  'vec-x86-64-test)))
(ck! "and REFUSES the fused one"
     (raises? (lambda () (check-fp-policy! bit-exact-policy
                                           (vec-contraction-evidence body/fma)
                                           'vec-x86-64-test))))
(ck! "naming D24 rather than reading as a comparison that came out wrong"
     (raises-naming? (lambda () (check-fp-policy! bit-exact-policy
                                                  (vec-contraction-evidence body/fma)
                                                  'vec-x86-64-test))
                     "D24"))

;; The source-level half of the same permission: a program that grants
;; fp-contract is what turns the plan on in the first place.
(define granting-program
  '(policy ((fp-contract #t))
     (primcall fl* ((fp-contract unchecked)) s bv)))
(define plain-program
  '(primcall fl* ((fp-contract checked)) s bv))

(ck! "a program that grants contraction plans with it"
     (vec-plan-contraction?
      (plan-for-verdict fields-verdict (program-grants-contraction? granting-program))))
(ck! "and one that does not, does not"
     (not (vec-plan-contraction?
           (plan-for-verdict fields-verdict (program-grants-contraction? plain-program)))))

;;; ==========================================================================
;;; 5. The tail a FIXED width cannot avoid
;;; ==========================================================================
;;
;; Seven iterations, four lanes. One full vector pass and three scalar ones,
;; which is 43% of the loop left over. sonic/src/sonic/vec-rv64.ss has no
;; equivalent of this section, and that absence is the finding.

(define-values (vbody tail full rem) (vec-emit-loop plan kernel))

(check! "one full vector pass" full 1)
(check! "and three iterations left over" rem 3)
(ck! "the tail is scalar, not packed"
     (and (memq 'vmulsd (mnemonics tail))
          (not (exists (lambda (m) (memq m '(vmulpd vaddpd))) (mnemonics tail)))))
(ck! "and it walks on from where the vector pass stopped"
     (equal? (car tail) '(vmovsd xmm0 (mem r8 rcx 8 32))))
(check! "the fused tail fuses too, or the two halves would round differently"
        (vec-contraction-evidence
         (let-values (((v t f r) (vec-emit-loop plan/fma kernel))) t))
        '(vfmadd231sd vfmadd231sd vfmadd231sd))

(display "\n-- the vector pass and the scalar tail --\n")
(for-each (lambda (i) (display "   ") (write i) (newline)) vbody)
(for-each (lambda (i) (display "   ") (write i) (newline)) tail)

;;; ==========================================================================
;;; 6. THE differential check, against gcc and objdump
;;; ==========================================================================

(define stem (string-append "/tmp/sonic-vec-x86-" (number->string (random 100000000))))
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

;; --- printing one instruction as gas Intel syntax --------------------------
;; Intel syntax so the operand order matches ours directly. An AT&T template
;; with the order reversed would compare the wrong thing and stay green on the
;; symmetric cases, which is most of them.

(define (ends-with-sd? m)
  (let ((s (symbol->string m)))
    (and (>= (string-length s) 2)
         (string=? (substring s (- (string-length s) 2) (string-length s)) "sd"))))

(define (ptr-keyword i)
  (if (ends-with-sd? (car i))
      "QWORD PTR "
      (let ((r (let scan ((os (map (lambda (o)
                                     (if (and (pair? o) (memq (car o) '(mask maskz)))
                                         (cadr o) o))
                                   (cdr i))))
                 (cond ((null? os) (error 'ptr-keyword "no vector register" i))
                       ((vec-reg? (car os)) (car os))
                       (else (scan (cdr os)))))))
        (case (vec-reg-width r)
          ((128) "XMMWORD PTR ") ((256) "YMMWORD PTR ") ((512) "ZMMWORD PTR ")
          (else (error 'ptr-keyword "not a width" r))))))

(define (gas-mem i m)
  (let ((b (cadr m)) (x (caddr m)) (s (cadddr m)) (d (list-ref m 4)))
    (if (eq? b 'rip)
        (string-append (ptr-keyword i) "[rip + " (number->string d) "]")
    (string-append (ptr-keyword i)
                   "[" (symbol->string b)
                   (if x (string-append " + " (symbol->string x)
                                        "*" (number->string s)) "")
                   " + " (number->string d) "]"))))

;; A masked destination. gas writes the mask register in braces after the
;; register, and the zeroing modifier as a second brace group -- `ymm3{k1}` and
;; `ymm3{k1}{z}`. There is no `{k0}`: aaa=0 IS the unmasked encoding, so gas
;; rejects it, which is the assembler agreeing with vex.ss's refusal.
(define (gas-masked i x)
  (string-append (if (and (pair? (cadr x)) (eq? (car (cadr x)) 'mem))
                     (gas-mem i (cadr x))
                     (symbol->string (cadr x)))
                 "{" (symbol->string (caddr x)) "}"
                 (if (eq? (car x) 'maskz) "{z}" "")))

;; `kmovw` names its GPR operand at 32 bits. Our listings have one register
;; vocabulary and it is the 64-bit one; W=0 is what makes the operand 32 bits,
;; so the BYTES are identical and only the printed name differs. Translating
;; here keeps the encoder from carrying a second naming scheme for one
;; instruction.
(define gpr32
  '((rax . eax) (rcx . ecx) (rdx . edx) (rbx . ebx)
    (rsp . esp) (rbp . ebp) (rsi . esi) (rdi . edi)))

(define (gas-op i x)
  (cond ((and (pair? x) (eq? (car x) 'mem)) (gas-mem i x))
        ((and (pair? x) (memq (car x) '(mask maskz))) (gas-masked i x))
        ((and (eq? (car i) 'kmovw) (assq x gpr32)) => (lambda (p) (symbol->string (cdr p))))
        ((symbol? x) (symbol->string x))
        ;; An immediate. Only `vextractf128` has one, and it selects the half.
        ((and (integer? x) (exact? x)) (number->string x))
        (else (error 'gas-op "cannot print operand" x))))

(define (commas ss)
  (cond ((null? ss) "")
        ((null? (cdr ss)) (car ss))
        (else (string-append (car ss) ", " (commas (cdr ss))))))

(define (instr->gas i)
  (string-append (symbol->string (car i)) " "
                 (commas (map (lambda (o) (gas-op i o)) (cdr i)))))

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

;; A three-lane mnemonic is not something gas has ever heard of. It is our
;; name for a masked 256-bit form, so the instruction ENCODED is the v3 one and
;; the instruction ASSEMBLED is what it claims to rewrite to -- which is the
;; whole content of the claim, and the only way to test it against a toolchain.
(define (differential! i)
  (set! checks (+ checks 1))
  (let* ((shown (if (three-lane-entry (car i)) (three-lane-rewrite i) i))
         (line (instr->gas shown))
         (mine (vec-encode-instr i))
         (theirs (guard (e (#t 'error)) (gas-bytes line))))
    (cond
     ((equal? mine theirs)
      (set! verified (+ verified 1))
      (display "  ok   ") (display line) (newline))
     (else
      (set! failures (+ failures 1))
      (display "  FAIL ") (display line)
      (display "  mine=") (write mine) (display " gas=") (write theirs) (newline)))))

;; The register choices are deliberately weighted past xmm7. The plan's scratch
;; is xmm15 and EVEX reaches 31, and a 3-bit or 4-bit extension field that is
;; never exercised looks fine on a toy corpus and corrupts a real one.
(define instruction-corpus
  '(;; packed double at all three widths
    (vaddpd xmm3 xmm1 xmm2)
    (vaddpd ymm3 ymm1 ymm2)
    (vaddpd zmm3 zmm1 zmm2)                     ; EVEX
    (vsubpd xmm0 xmm15 xmm7)
    (vsubpd zmm10 zmm20 zmm30)                  ; EVEX high registers
    (vmulpd ymm13 ymm11 ymm12)                  ; 3-byte VEX, both high
    (vmulpd zmm5 zmm6 zmm7)
    (vdivpd zmm31 zmm30 zmm29)                  ; every extension bit set
    (vdivpd ymm2 ymm3 ymm4)
    (vsqrtpd ymm5 ymm6)
    (vsqrtpd zmm17 zmm18)
    (vxorpd ymm0 ymm0 ymm0)
    (vmovapd ymm1 ymm2)
    (vmovapd zmm21 zmm22)
    ;; loads and stores, and the EVEX disp8*N compression that scales by the
    ;; vector length rather than by one
    (vmovupd ymm0 (mem rdi rax 8 0))
    (vmovupd xmm7 (mem r8 rcx 8 16))
    (vmovupd ymm7 (mem r8 rcx 8 32))
    (vmovupd (mem r9 rcx 8 64) ymm7)
    (vmovupd (mem rsi rax 8 64) zmm2)           ; disp8 of 1, times 64
    (vmovupd zmm4 (mem r12 r9 8 128))           ; r12 base forces a SIB
    (vmovupd zmm4 (mem r13 #f 1 0))             ; r13 base forces an explicit 0
    (vmovupd zmm9 (mem rax #f 1 8))             ; not a multiple of 64: disp32
    (vaddpd xmm3 xmm1 (mem r8 rcx 8 16))
    (vfmadd231pd zmm5 zmm6 (mem r8 rcx 8 64))
    ;; the three FMA orderings. 132/213/231 choose which operand is the addend
    ;; and are not a semantic difference; gcc 15.2 picks 132 for this shape.
    (vfmadd231pd ymm0 ymm1 ymm2)
    (vfmadd231pd zmm0 zmm1 zmm2)
    (vfmadd132pd xmm0 xmm1 xmm2)
    (vfmadd213pd ymm8 ymm9 ymm10)
    (vfnmadd231pd ymm4 ymm5 ymm6)
    ;; scalar double, which is what the tail is made of
    (vmovsd xmm0 (mem r8 rcx 8 0))
    (vmovsd (mem r8 rcx 8 8) xmm0)
    (vaddsd xmm3 xmm1 xmm2)
    (vsubsd xmm9 xmm2 xmm4)
    (vmulsd xmm3 xmm1 xmm2)
    (vdivsd xmm7 xmm7 xmm7)
    (vsqrtsd xmm3 xmm1 xmm2)
    (vfmadd231sd xmm0 xmm1 xmm2)
    ;; --- masking, which is what (x,y,z,pad) needs ---------------------------
    ;;
    ;; A mask forces EVEX at every width, including 128, because there is no
    ;; VEX field to put `aaa` in. So these also exercise a four-byte prefix on
    ;; instructions that would otherwise take the two-byte one.
    (vaddpd (mask ymm3 k1) ymm1 ymm2)
    (vaddpd (maskz ymm3 k1) ymm1 ymm2)
    (vaddpd (mask xmm3 k7) xmm1 xmm2)           ; 128-bit, EVEX only because masked
    (vmulpd (mask ymm0 k2) ymm1 ymm2)
    (vsubpd (maskz zmm10 k3) zmm20 zmm30)       ; masked AND high registers
    (vdivpd (mask ymm13 k4) ymm11 ymm12)
    (vsqrtpd (mask ymm5 k5) ymm6)               ; the rm form, which has no vvvv
    (vaddpd (mask ymm3 k6) ymm1 (mem r8 rcx 8 32))   ; masked with a memory source
    (vmovupd (mask ymm7 k1) (mem r9 rcx 8 32))       ; a masked LOAD
    (vfmadd231pd (mask zmm5 k1) zmm6 zmm7)
    ;; --- kmovw, which is how a mask gets its value --------------------------
    (kmovw k1 rax)
    (kmovw k7 rdi)
    (kmovw rax k1)
    (kmovw rdx k5)
    (kmovw k2 k3)
    ;; A masked STORE, which three-lane work cannot do without: an unmasked
    ;; 256-bit store of (x,y,z,pad) writes four doubles and the fourth lands on
    ;; the next body's x.
    (vmovupd (mask (mem r9 rcx 8 32) k1) ymm7)
    (vmovupd (mask (mem rsi rax 8 0) k2) ymm0)
    (vmovapd (mask (mem r8 rdx 8 64) k3) zmm2)
    ;; Lane assembly and extraction. These are what slp.ss emits today through
    ;; the SCALAR encoder, and they are here because that encoder is about to
    ;; delegate: the same mnemonic must not have two implementations.
    (vunpcklpd xmm4 xmm5 xmm6)
    (vunpckhpd xmm1 xmm1 xmm1)
    (vunpcklpd ymm12 ymm13 ymm14)
    (vunpckhpd zmm20 zmm21 zmm22)
    ;; RIP-relative, which is how a pooled constant is addressed and what the
    ;; emitted image hands this encoder now that object.ss delegates to it.
    (vmovupd xmm7 (mem rip #f 1 0))
    (vaddpd ymm3 ymm1 (mem rip #f 1 64))
    (vmulpd zmm20 zmm21 (mem rip #f 1 -128))
    ;; --- the three-lane forms, (x, y, z, pad) -------------------------------
    ;;
    ;; Written with XMM operands because that is what the allocator produces and
    ;; what the listing carries; the width is the mnemonic's, not the operand's.
    (v3addpd xmm3 xmm1 xmm2)
    (v3subpd xmm0 xmm5 xmm7)
    (v3mulpd xmm9 xmm11 xmm13)
    (v3divpd xmm2 xmm2 xmm2)
    (v3sqrtpd xmm5 xmm6)
    (v3xorpd xmm4 xmm4 xmm6)
    (v3movupd xmm7 (mem r8 rcx 8 16))            ; a masked LOAD, disp32
    (v3movupd xmm7 (mem r8 rcx 8 32))            ; disp8 of 1, times 32
    (v3movupd (mem r9 rcx 8 32) xmm7)            ; a masked STORE
    (v3addpd xmm3 xmm1 (mem r8 rcx 8 64))
    ;; Lane 2 of a triple: the low double of the HIGH half. Lane 0 is free and
    ;; lane 1 is the vunpckhpd slp.ss already emits, on ymm3's low 128 bits --
    ;; which ARE xmm3, so that instruction reads lane 1 of a triple unchanged.
    (vextractf128 xmm5 ymm3 1)
    (vextractf128 xmm0 ymm9 0)
    (vextractf128 xmm12 ymm13 1)))

;; --- what masking must REFUSE ----------------------------------------------
;;
;; Each of these is a shape that assembles to something plausible if it is not
;; caught, which is the only kind of refusal worth testing.

(display "\n-- masking, and what it refuses --\n")

(ck! "k0 as a mask is refused: aaa=0 is the UNMASKED encoding"
     (raises-naming? (lambda () (vec-encode-instr '(vaddpd (mask ymm3 k0) ymm1 ymm2)))
                     "unmasked"))
(ck! "a mask on a SOURCE operand is refused: the ISA has no field for it"
     (raises-naming? (lambda () (vec-encode-instr '(vaddpd ymm3 (mask ymm1 k1) ymm2)))
                     "destination"))
(ck! "kmovw with a high GPR is refused rather than encoding rax"
     (raises-naming? (lambda () (vec-encode-instr '(kmovw k1 r9)))
                     "three-byte"))
(ck! "kmovw between two GPRs is not a kmovw"
     (raises? (lambda () (vec-encode-instr '(kmovw rax rcx)))))
(ck! "zeroing on a STORE is refused: masked-off lanes are simply not written"
     (raises-naming? (lambda ()
                       (vec-encode-instr '(vmovupd (maskz (mem r9 rcx 8 32) k1) ymm7)))
                     "not written"))
(ck! "zeroing with no mask register is refused at the prefix"
     (raises-naming? (lambda () (evex-bytes 0 0 0 0 1 0 0 1 1 1 0 1))
                     "zeroing"))
(ck! "a mask selector wider than three bits is refused"
     (raises? (lambda () (evex-bytes 0 0 0 0 1 0 0 1 1 1 8 0))))

;; A mask forces EVEX even at 128 bits, because VEX has nowhere to put `aaa`.
;; Asserted on the byte rather than inferred: the first prefix byte is 0x62 for
;; EVEX and 0xC5/0xC4 for VEX.
(check! "a masked 128-bit operation takes the four-byte EVEX prefix"
        (car (vec-encode-instr '(vaddpd (mask xmm3 k7) xmm1 xmm2)))
        #x62)
(check! "and the same operation unmasked takes the two-byte VEX one"
        (car (vec-encode-instr '(vaddpd xmm3 xmm1 xmm2)))
        #xC5)

;; The register partition. k1..k7 are a fourth file and no storage class
;; reaches them -- see regs.ss on why that is the intended answer and not a
;; gap. k0 is not in the pool at all.
(check! "mask registers are their own partition class"
        (map (lambda (r) (reg-class arch-x86-64 r)) '(k1 k4 k7))
        '(mask mask mask))
(check! "k0 is not in the allocatable mask pool"
        (memq 'k0 (arch-mask arch-x86-64))
        #f)
(ck! "no storage class may be assigned to a mask register"
     (not (exists (lambda (sc) (assignment-ok? arch-x86-64 sc 'k1))
                  '(tagged raw-word raw-f64))))
(ck! "and the mask file is disjoint from the other three"
     (not (exists (lambda (r) (or (memq r (arch-value arch-x86-64))
                                  (memq r (arch-raw arch-x86-64))
                                  (memq r (arch-float arch-x86-64))))
                  (arch-mask arch-x86-64))))

;; --- the mask is established once, for the whole image ----------------------
;;
;; Three-lane forms predicate on k1 and never set it, so something has to. It
;; is the runtime's entry, and the invariant that makes one setup sound is a
;; property of the whole image rather than of a function: nothing we emit
;; writes a k register except this instruction, because we produce a static
;; binary and call no external code. No ABI convention can take k1 away, which
;; is not true of any caller-saved GPR.
(let ((rt (runtime-listing 'x86-64 'main)))
  (ck! "the runtime sets the lane mask at _start"
       (exists (lambda (i) (equal? i '(kmovw k1 rax))) rt))
  (ck! "and it is 0b0111: lanes x, y, z active and the padding lane off"
       (exists (lambda (i) (equal? i '(mov rax (imm 7)))) rt))
  (ck! "nothing else in the runtime writes a mask register"
       (= 1 (length (filter (lambda (i)
                              (and (pair? i) (eq? (car i) 'kmovw)
                                   (mask-reg? (cadr i))))
                            rt)))))

(display "\n-- differential against gcc/objdump --\n")
(for-each differential! instruction-corpus)

(display "\n-- and the emitted nbody fields loop, byte for byte --\n")
(for-each differential! (append body body/fma vbody tail))

(cleanup!)

(let ((evex (length (filter (lambda (i)
                              (let ((b (guard (e (#t '())) (vec-encode-instr i))))
                                (and (pair? b) (= (car b) #x62))))
                            instruction-corpus))))
  (ck! "at least eight verified instructions were EVEX-encoded" (>= evex 8))
  (display "   (") (display evex) (display " of ")
  (display (length instruction-corpus)) (display " needed EVEX)") (newline))

(ck! "the differential harness actually ran against the real assembler"
     (= verified (+ (length instruction-corpus)
                    (length body) (length body/fma) (length vbody) (length tail))))

;;; ==========================================================================
;;; 7. Refusals
;;; ==========================================================================

(ck! "the baseline scalar encoder still refuses everything in here"
     (and (raises? (lambda () ((eval 'encode-instr
                                     (environment '(sonic encode-x86-64)))
                               '(vfmadd231pd ymm0 ymm1 ymm2))))
          (raises? (lambda () ((eval 'encode-instr
                                     (environment '(sonic encode-x86-64)))
                               '(vaddpd ymm0 ymm1 ymm2))))))
(ck! "mixing register widths in one instruction is refused, not silently taken"
     (raises-naming? (lambda () (vec-encode-instr '(vaddpd ymm0 xmm1 ymm2)))
                     "disagree"))
(ck! "a GPR where a vector register belongs is refused"
     (raises? (lambda () (vec-encode-instr '(vaddpd rax ymm1 ymm2)))))
(ck! "rsp still cannot be a SIB index"
     (raises? (lambda () (vec-encode-instr '(vmovupd ymm0 (mem rbx rsp 8 0))))))
(ck! "a mnemonic this encoder does not have is refused rather than guessed"
     (raises? (lambda () (vec-encode-instr '(vaddps ymm0 ymm1 ymm2)))))
(ck! "the unfused lowering refuses to clobber a lane the kernel is using"
     (raises-naming?
      (lambda () (vec-emit-kernel plan `((vmuladd 15 1 2))))
      "scratch"))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures, ")
(display verified) (display " instructions verified byte-for-byte against gcc/objdump")
(newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
