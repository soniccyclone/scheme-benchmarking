;;; AVX-512 packed-double emission.
;;;
;;; E5-AVX512. Takes a verdict from `sonic/src/sonic/veclegal.ss` and a
;;; kernel -- the loop body written in a tiny target-neutral vector op language
;;; -- and produces x86-64 instructions, plus their bytes.
;;;
;;; ## This file decides NOTHING about legality
;;;
;;; Whether a loop may be vectorized, and at what widths, is `veclegal`'s answer
;;; and this file consumes it. `plan-for-verdict` refuses an illegal verdict and
;;; refuses to exceed the widths the verdict lists. That refusal is the whole
;;; reason the two files are separate: nbody's `fields` loop runs 7 times, a
;;; 512-bit vector of doubles is 8 lanes, and a back end that picked its own
;;; width would emit a zmm operation whose every lane but none is a real
;;; iteration. veclegal already says `(128 256)`; asking it is cheaper than
;;; being wrong.
;;;
;;; ## Why a SEPARATE encoder from sonic/src/sonic/encode-x86-64.ss
;;;
;;; That file refuses every VEX-shaped mnemonic by name, loudly, and the refusal
;;; is a correctness property rather than a scope note: the scalar back end is
;;; the side of the differential oracle that has to round exactly like baseline
;;; gcc. Widening it to know `vfmadd231pd` would delete that guard for the
;;; scalar path too. So the vector encoder is its own library and the baseline
;;; one keeps refusing.
;;;
;;; ## D24: a fused multiply-add is CONTRACTION, and contraction is a permission
;;;
;;; `vfmadd231pd` keeps one rounding where `vmulpd` + `vaddpd` keep two. D24
;;; makes FP contraction a named, lexically scoped permission that is OFF by
;;; default, so `vmuladd` in a kernel lowers to the unfused pair unless the plan
;;; carries the grant. `vec-contraction-evidence` reports the fused mnemonics in
;;; an emitted stream, which is exactly the `evidence` argument
;;; `check-fp-policy!` in sonic/src/sonic/differential.ss wants: a bit-exact
;;; comparison in the presence of an FMA is refused rather than reported.
;;;
;;; The 132/213/231 suffix selects which operand is the addend and which is
;;; overwritten. It is not a semantic difference -- gcc 15.2 happens to pick
;;; `vfmadd132pd` for this shape and we pick `vfmadd231pd`, and both compute
;;; `a*b+c` with one rounding. All three are in the table so a peephole can
;;; choose the one that avoids a copy.
;;;
;;; ## Tail handling exists here and does not exist on RVV
;;;
;;; The width is fixed at compile time, so a trip count that is not a multiple
;;; of the lane count leaves a remainder that has to be computed some other way.
;;; `vec-emit-loop` returns the vector body and the scalar tail separately, and
;;; for nbody's 7-iteration `fields` loop at 4 lanes the tail is 3 scalar
;;; iterations -- 43% of the loop. sonic/src/sonic/vec-rv64.ss has no equivalent
;;; because RVV reads its vector length at run time and the last pass simply
;;; runs short.
;;;
;;; ## Verification
;;;
;;; NOT against hand-derived bytes. EVEX is four prefix bytes carrying five
;;; separate inverted register-number extension bits and a displacement that is
;;; scaled by the vector width, and a hand-derived encoding of that is wrong
;;; more often than right. sonic/test/vec-x86-64-test.ss assembles every
;;; mnemonic with gcc and compares against objdump, the same discipline
;;; sonic/test/x86-64-test.ss uses for the scalar encoder.

(library (sonic vec-x86-64)
  (export ;; registers
          vec-reg? vec-reg-width vec-reg-number vec-reg-name
          vec-lane-reg vec-scalar-reg
          ;; encoding
          vec-encode-instr vec-encode-instrs vec-instr-length
          vec-mnemonics vec-supports? vec-fused-mnemonic?
          vec-contraction-evidence
          ;; planning
          vec-plan? vec-plan-width vec-plan-lanes vec-plan-bytes
          vec-plan-contraction? vec-plan-scratch vec-plan-verdict
          plan-for-verdict x86-64-vector-widths
          ;; emission
          vec-emit-kernel vec-emit-scalar-kernel vec-emit-loop
          nbody-fields-kernel)
  (import (chezscheme)
          (sonic vex)
          (only (sonic encode-x86-64) gpr? reg-number)
          (only (sonic loops) trip-count trip-kind)
          (sonic veclegal))

  ;;; ========================================================================
  ;;; 1. Vector registers
  ;;; ========================================================================
  ;;
  ;; Named, not numbered, for the same reason sonic/src/sonic/encode-rv64.ss
  ;; insists on ABI names: a bare number carries no width, and an xmm/ymm/zmm
  ;; mix-up assembles cleanly and computes on lanes that were never loaded.

  (define (reg-prefix-width s)
    (cond ((< (string-length s) 4) #f)
          ((string=? (substring s 0 3) "xmm") 128)
          ((string=? (substring s 0 3) "ymm") 256)
          ((string=? (substring s 0 3) "zmm") 512)
          (else #f)))

  (define (vec-reg-parse r)
    ;; -> (values width number) or (values #f #f)
    (if (not (symbol? r))
        (values #f #f)
        (let* ((s (symbol->string r)) (w (reg-prefix-width s)))
          (if (not w)
              (values #f #f)
              (let ((n (string->number (substring s 3 (string-length s)))))
                (if (and n (exact? n) (integer? n) (<= 0 n 31))
                    (values w n)
                    (values #f #f)))))))

  (define (vec-reg? r) (let-values (((w n) (vec-reg-parse r))) (and w #t)))

  (define (vec-reg-width r)
    (let-values (((w n) (vec-reg-parse r)))
      (or w (error 'vec-reg-width "not a vector register" r))))

  (define (vec-reg-number r)
    (let-values (((w n) (vec-reg-parse r)))
      (if w n (error 'vec-reg-number "not a vector register" r))))

  (define (vec-reg-name width n)
    (unless (<= 0 n 31) (error 'vec-reg-name "no such vector register" n))
    (string->symbol
     (string-append (case width
                      ((128) "xmm") ((256) "ymm") ((512) "zmm")
                      (else (error 'vec-reg-name "not a vector width" width)))
                    (number->string n))))

  ;; A lane register at the plan's width, and the same numbered register as an
  ;; xmm for the scalar tail. One number, two spellings, so a kernel written
  ;; once can be emitted both ways.
  (define (vec-lane-reg plan n) (vec-reg-name (vec-plan-width plan) n))
  (define (vec-scalar-reg n) (vec-reg-name 128 n))

  (define (mem? x) (and (pair? x) (eq? (car x) 'mem) (= (length x) 5)))
  (define (mem-base m) (list-ref m 1))
  (define (mem-index m) (list-ref m 2))
  (define (mem-scale m) (list-ref m 3))
  (define (mem-disp m) (list-ref m 4))
  (define (mem-with-disp m d) (list 'mem (mem-base m) (mem-index m) (mem-scale m) d))

  ;;; ========================================================================
  ;;; 2. The instruction table
  ;;; ========================================================================
  ;;
  ;; (mnemonic map opcode pp vex-w evex-w form)
  ;;
  ;;   map     1 = 0F, 2 = 0F38
  ;;   pp      1 = 66, 3 = F2. The legacy prefix, folded into the VEX/EVEX byte.
  ;;   vex-w   what gas emits under VEX. WIG for the 0F packed forms, so 0.
  ;;   evex-w  significant under EVEX: the pd forms are W1 there, which is how
  ;;           the hardware tells `vaddpd` from `vaddps` when there is no room
  ;;           left for a legacy prefix to do it.
  ;;   form    rvm    (dst src1 src2), vvvv = src1, rm = src2
  ;;           rm     (dst src),       vvvv = 0
  ;;           mov    direction chosen by which operand is memory; the opcode
  ;;                  field is (load-op . store-op)
  ;;
  ;; `vsqrtpd` is `rm` and `vsqrtsd` is `rvm`: the scalar form merges the upper
  ;; lanes of a third operand, and that operand is not optional in the encoding.

  (define vec-table
    '(;; packed double, 0F map
      (vaddpd       1 #x58 1 0 1 rvm)
      (vsubpd       1 #x5C 1 0 1 rvm)
      (vmulpd       1 #x59 1 0 1 rvm)
      (vdivpd       1 #x5E 1 0 1 rvm)
      (vxorpd       1 #x57 1 0 1 rvm)
      (vsqrtpd      1 #x51 1 0 1 rm)
      (vmovupd      1 (#x10 . #x11) 1 0 1 mov)
      (vmovapd      1 (#x28 . #x29) 1 0 1 mov)
      ;; packed double, 0F38 map. W1 under both encodings.
      (vfmadd132pd  2 #x98 1 1 1 rvm)
      (vfmadd213pd  2 #xA8 1 1 1 rvm)
      (vfmadd231pd  2 #xB8 1 1 1 rvm)
      (vfnmadd231pd 2 #xBC 1 1 1 rvm)
      ;; scalar double, for the tail the fixed width leaves behind
      (vaddsd       1 #x58 3 0 1 rvm)
      (vsubsd       1 #x5C 3 0 1 rvm)
      (vmulsd       1 #x59 3 0 1 rvm)
      (vdivsd       1 #x5E 3 0 1 rvm)
      (vsqrtsd      1 #x51 3 0 1 rvm)
      (vmovsd       1 (#x10 . #x11) 3 0 1 mov)
      (vfmadd231sd  2 #xB9 1 1 1 rvm)))

  (define (vec-entry m) (assq m vec-table))
  (define (vec-supports? m) (and (vec-entry m) #t))
  (define (vec-mnemonics) (map car vec-table))

  (define (entry-map e) (list-ref e 1))
  (define (entry-op e) (list-ref e 2))
  (define (entry-pp e) (list-ref e 3))
  (define (entry-vex-w e) (list-ref e 4))
  (define (entry-evex-w e) (list-ref e 5))
  (define (entry-form e) (list-ref e 6))

  ;; A fused multiply-add is contraction. Named by shape rather than listed, so
  ;; an FMA added to the table above cannot escape the D24 accounting by having
  ;; been forgotten here.
  (define (vec-fused-mnemonic? m)
    (let* ((s (symbol->string m)) (n (string-length s)))
      (let scan ((i 0))
        (cond ((> (+ i 5) n) #f)
              ((string=? (substring s i (+ i 5)) "fmadd") #t)
              ((string=? (substring s i (+ i 5)) "fmsub") #t)
              (else (scan (+ i 1)))))))

  ;; The `evidence` argument for check-fp-policy! in (sonic differential).
  (define (vec-contraction-evidence instrs)
    (let loop ((is instrs) (acc '()))
      (cond ((null? is) (reverse acc))
            ((and (pair? (car is)) (vec-fused-mnemonic? (caar is)))
             (loop (cdr is) (cons (caar is) acc)))
            (else (loop (cdr is) acc)))))

  ;;; ========================================================================
  ;;; 3. Encoding
  ;;; ========================================================================

  (define (imm8-bytes n)
    (unless (<= -128 n 127) (error 'vec-encode-instr "disp8 out of range" n))
    (list (bitwise-and n #xff)))

  (define (imm32-bytes n)
    (unless (<= (- (expt 2 31)) n (- (expt 2 31) 1))
      (error 'vec-encode-instr "disp32 out of range" n))
    (let ((u (bitwise-and n #xffffffff)))
      (list (bitwise-and u #xff)
            (bitwise-and (bitwise-arithmetic-shift-right u 8) #xff)
            (bitwise-and (bitwise-arithmetic-shift-right u 16) #xff)
            (bitwise-and (bitwise-arithmetic-shift-right u 24) #xff))))

  (define (scale-bits s)
    (case s ((1) 0) ((2) 1) ((4) 2) ((8) 3)
      (else (error 'vec-encode-instr "SIB scale must be 1, 2, 4 or 8" s))))

  ;; ModRM/SIB/displacement, and the R/X/B extension bits the prefix carries.
  ;;
  ;; `n` is the EVEX displacement-compression stride: under EVEX a disp8 is
  ;; MULTIPLIED by the memory operand's size, so a 64-byte-aligned step of 64
  ;; encodes as 1. Under VEX it is a plain byte and `n` is 1. Getting this
  ;; backwards produces an instruction that assembles and reads the wrong
  ;; address, which is why nothing here is checked against a hand-derived byte.
  (define (rm-encoding who regf rm n)
    (let ((rlo (bitwise-and regf 7))
          (rhi (bitwise-and (bitwise-arithmetic-shift-right regf 3) 1))
          (rhi2 (bitwise-and (bitwise-arithmetic-shift-right regf 4) 1)))
      (cond
       ((vec-reg? rm)
        (let ((num (vec-reg-number rm)))
          (values rhi rhi2
                  (bitwise-and (bitwise-arithmetic-shift-right num 3) 1)   ; B
                  (bitwise-and (bitwise-arithmetic-shift-right num 4) 1)   ; X (EVEX high)
                  (list (bitwise-ior #b11000000
                                     (bitwise-arithmetic-shift-left rlo 3)
                                     (bitwise-and num 7))))))
       ((mem? rm)
        (let ((base (mem-base rm)) (index (mem-index rm))
              (scale (mem-scale rm)) (disp (mem-disp rm)))
          (unless (and base (gpr? base))
            (error who "memory base must be a general-purpose register" rm))
          (when (and index (not (gpr? index)))
            (error who "memory index must be a general-purpose register" rm))
          (when (eq? index 'rsp)
            (error who "rsp cannot be a SIB index register" rm))
          (let* ((bn (reg-number base))
                 (xn (and index (reg-number index)))
                 (need-sib (or xn (= (bitwise-and bn 7) 4)))
                 ;; Compressed disp8 only when the displacement is a multiple
                 ;; of the stride AND the quotient fits a signed byte.
                 (q (and (not (zero? disp)) (zero? (remainder disp n))
                         (quotient disp n)))
                 (mod (cond ((and (zero? disp) (not (= (bitwise-and bn 7) 5))) 0)
                            ((and q (<= -128 q 127)) 1)
                            ((zero? disp) 1)
                            (else 2)))
                 (rm-field (if need-sib 4 (bitwise-and bn 7)))
                 (modrm (bitwise-ior (bitwise-arithmetic-shift-left mod 6)
                                     (bitwise-arithmetic-shift-left rlo 3)
                                     rm-field))
                 (sib (and need-sib
                           (bitwise-ior
                            (bitwise-arithmetic-shift-left
                             (scale-bits (if xn scale 1)) 6)
                            (bitwise-arithmetic-shift-left
                             (if xn (bitwise-and xn 7) 4) 3)
                            (bitwise-and bn 7))))
                 (disp-bytes (cond ((= mod 1) (imm8-bytes (or q 0)))
                                   ((= mod 2) (imm32-bytes disp))
                                   (else '()))))
            (values rhi rhi2
                    (bitwise-and (bitwise-arithmetic-shift-right bn 3) 1)
                    (if xn (bitwise-and (bitwise-arithmetic-shift-right xn 3) 1) 0)
                    (append (list modrm) (if sib (list sib) '()) disp-bytes)))))
       (else (error who "not an r/m operand" rm)))))

  (define (ll-bits width)
    (case width ((128) 0) ((256) 1) ((512) 2)
      (else (error 'vec-encode-instr "not a vector width" width))))

  ;; VEX and EVEX prefix bytes come from (sonic vex), which encode-x86-64.ss
  ;; also uses for the three-address SCALAR forms. Two copies would have to
  ;; agree to the bit -- five register-extension bits in these are stored
  ;; inverted -- and a second implementation that inverted four of them would
  ;; assemble cleanly and address the wrong registers.

  ;; The operand width an instruction's registers agree on, and the memory
  ;; stride that follows from it.
  (define (operand-width who ops)
    (let loop ((os ops) (w #f))
      (cond ((null? os) (or w (error who "no vector register operand" ops)))
            ((vec-reg? (car os))
             (let ((rw (vec-reg-width (car os))))
               (when (and w (not (= w rw)))
                 (error who "vector operands disagree about width" ops))
               (loop (cdr os) rw)))
            (else (loop (cdr os) w)))))

  (define (any-high-reg? ops)
    (exists (lambda (o) (and (vec-reg? o) (> (vec-reg-number o) 15))) ops))

  (define (vec-encode-instr i)
    (unless (and (pair? i) (symbol? (car i)))
      (error 'vec-encode-instr "not an instruction" i))
    (let* ((m (car i))
           (ops (cdr i))
           (e (or (vec-entry m)
                  (error 'vec-encode-instr
                         "no encoding for this mnemonic in the vector encoder" m)))
           (form (entry-form e))
           (pp (entry-pp e))
           (mp (entry-map e))
           (scalar? (= pp 3))
           (width (operand-width 'vec-encode-instr ops)))
      ;; Which register goes in which field. `mov` is the only form whose
      ;; direction is not fixed by the mnemonic.
      (let-values
          (((regop vvvv rmop opcode)
            (case form
              ((rvm)
               (unless (= (length ops) 3)
                 (error 'vec-encode-instr "expects three operands" i))
               (values (car ops) (vec-reg-number (cadr ops)) (caddr ops) (entry-op e)))
              ((rm)
               (unless (= (length ops) 2)
                 (error 'vec-encode-instr "expects two operands" i))
               (values (car ops) 0 (cadr ops) (entry-op e)))
              ((mov)
               (unless (= (length ops) 2)
                 (error 'vec-encode-instr "expects two operands" i))
               (cond
                ((mem? (car ops))
                 (values (cadr ops) 0 (car ops) (cdr (entry-op e))))
                ((mem? (cadr ops))
                 (values (car ops) 0 (cadr ops) (car (entry-op e))))
                (else
                 ;; register to register takes the load direction, which is
                 ;; what gas picks and therefore what a byte comparison needs.
                 (values (car ops) 0 (cadr ops) (car (entry-op e))))))
              (else (error 'vec-encode-instr "unhandled form" m form)))))
        (unless (vec-reg? regop)
          (error 'vec-encode-instr "the register operand must be a vector register" i))
        (let* ((evex? (or (= width 512) (any-high-reg? ops)))
               (w (if evex? (entry-evex-w e) (entry-vex-w e)))
               (n (if scalar? 8 (div width 8)))
               (regf (vec-reg-number regop)))
          (let-values (((r r2 b x tail) (rm-encoding 'vec-encode-instr regf rmop
                                                     (if evex? n 1))))
            (append
             (if evex?
                 (evex-bytes r r2 x b w (bitwise-and vvvv #xf)
                             (bitwise-and (bitwise-arithmetic-shift-right vvvv 4) 1)
                             (ll-bits (if scalar? 128 width)) pp mp)
                 (begin
                   (when (or (= r2 1) (> vvvv 15))
                     (error 'vec-encode-instr
                            "this operand needs EVEX but the width does not select it" i))
                   (vex-bytes r x b w vvvv (ll-bits (if scalar? 128 width)) pp mp)))
             (list opcode)
             tail))))))

  (define (vec-encode-instrs is) (apply append (map vec-encode-instr is)))
  (define (vec-instr-length i) (length (vec-encode-instr i)))

  ;;; ========================================================================
  ;;; 4. The plan: what veclegal permits, spelled as a width
  ;;; ========================================================================

  ;; The widths this back end can name. veclegal's candidate list also contains
  ;; 1024, which no x86-64 register is, so the intersection is taken rather than
  ;; the verdict's list being trusted to be a subset.
  (define x86-64-vector-widths '(128 256 512))

  (define-record-type (vec-plan mk-vec-plan vec-plan?)
    (fields width lanes bytes contraction? scratch verdict))

  ;; `scratch` is the lane register the unfused lowering of `vmuladd` needs.
  ;; sonic/src/sonic/regs.ss reserves xmm15 as the x86-64 float scratch and
  ;; keeps it out of the allocatable pool for exactly this: a rule that needs a
  ;; temporary has no channel to ask the allocator for one.
  (define default-scratch 15)

  (define plan-for-verdict
    (case-lambda
      ((v contraction?) (plan-for-verdict v contraction? default-scratch))
      ((v contraction? scratch)
       (unless (vl? v) (error 'plan-for-verdict "not a vectorization verdict" v))
       (unless (vl-legal? v)
         (error 'plan-for-verdict
                (string-append
                 "this loop is not vectorizable and the reasons are veclegal's to "
                 "give; emitting packed code for it would be a miscompile with no "
                 "runtime check downstream to catch it")
                (vl-loop v) (vl-reasons v)))
       (unless (eq? (vl-elt-class v) 'raw-f64)
         (error 'plan-for-verdict
                "this back end emits packed DOUBLE arithmetic and the element is not one"
                (vl-loop v) (vl-elt-class v)))
       (let* ((usable (filter (lambda (w) (memq w x86-64-vector-widths)) (vl-widths v)))
              (width (if (null? usable)
                         (error 'plan-for-verdict
                                "no width this back end can name has a guaranteed iteration to fill it"
                                (vl-loop v) (vl-widths v))
                         (car (reverse usable))))
              (bits (vl-element-bits (vl-elt-class v))))
         (mk-vec-plan width (div width bits) (div width 8)
                      (and contraction? #t) scratch v)))))

  ;;; ========================================================================
  ;;; 5. The kernel op language
  ;;; ========================================================================
  ;;
  ;; A loop body, one element-wise operation per form, with lane registers
  ;; named by NUMBER so the same kernel can be emitted packed at the plan's
  ;; width and scalar for the tail. Deliberately small: this is a spelling
  ;; layer, not an IR.
  ;;
  ;;   (vload  d mem)        d := mem
  ;;   (vstore mem s)        mem := s
  ;;   (vmove  d s)          d := s
  ;;   (vadd d a b)          d := a + b, and vsub / vmul / vdiv likewise
  ;;   (vsqrt d a)           d := sqrt a
  ;;   (vmuladd d a b)       d := d + a * b
  ;;   (vzero d)             d := 0
  ;;
  ;; `vmuladd` is the one form whose lowering is a POLICY question rather than a
  ;; spelling question, and it is separate from `(vmul t a b)` `(vadd d d t)`
  ;; precisely so that the policy has one place to look.

  (define (kernel-op k) (car k))

  (define (check-lane who n plan)
    (unless (and (integer? n) (exact? n) (<= 0 n 31))
      (error who "not a lane register number" n))
    n)

  ;; Emit one kernel packed at the plan's width. `disp-bias` shifts every memory
  ;; operand, which is how the unrolled vector body walks the array.
  (define vec-emit-kernel
    (case-lambda
      ((plan kernel) (vec-emit-kernel plan kernel 0))
      ((plan kernel disp-bias)
       (let* ((width (vec-plan-width plan))
              (scratch (vec-plan-scratch plan)))
         (define (R n) (vec-reg-name width (check-lane 'vec-emit-kernel n plan)))
         (define (M m) (mem-with-disp m (+ (mem-disp m) disp-bias)))
         (emit-kernel 'vec-emit-kernel kernel R M
                      '((vadd . vaddpd) (vsub . vsubpd)
                        (vmul . vmulpd) (vdiv . vdivpd))
                      'vsqrtpd 'vmovupd 'vmovapd 'vxorpd 'vfmadd231pd
                      (vec-plan-contraction? plan) scratch)))))

  ;; The same kernel, one element at a time, for the remainder a fixed width
  ;; leaves. Scalar VEX forms rather than the baseline SSE2 ones: the tail of an
  ;; AVX-512 loop is already inside an AVX region, and mixing legacy SSE with
  ;; VEX costs a transition penalty on every boundary.
  (define vec-emit-scalar-kernel
    (case-lambda
      ((plan kernel) (vec-emit-scalar-kernel plan kernel 0))
      ((plan kernel disp-bias)
       (let ((scratch (vec-plan-scratch plan)))
         (define (R n) (vec-scalar-reg (check-lane 'vec-emit-scalar-kernel n plan)))
         (define (M m) (mem-with-disp m (+ (mem-disp m) disp-bias)))
         (emit-kernel 'vec-emit-scalar-kernel kernel R M
                      '((vadd . vaddsd) (vsub . vsubsd)
                        (vmul . vmulsd) (vdiv . vdivsd))
                      'vsqrtsd 'vmovsd 'vmovapd 'vxorpd 'vfmadd231sd
                      (vec-plan-contraction? plan) scratch)))))

  ;; One walker, two spellings. `sqrt-scalar?` is not a parameter because the
  ;; scalar form's third operand is the merge source, which is the destination
  ;; itself when nothing else is being merged.
  (define (emit-kernel who kernel R M arith sqrt-mn mov-mn reg-mov-mn zero-mn
                       fma-mn contraction? scratch)
    (define scalar? (memq sqrt-mn '(vsqrtsd)))
    (apply append
           (map
            (lambda (k)
              (unless (pair? k) (error who "not a kernel operation" k))
              (case (kernel-op k)
                ((vload)
                 (unless (= (length k) 3) (error who "vload takes a lane and a memory operand" k))
                 `((,mov-mn ,(R (cadr k)) ,(M (caddr k)))))
                ((vstore)
                 (unless (= (length k) 3) (error who "vstore takes a memory operand and a lane" k))
                 `((,mov-mn ,(M (cadr k)) ,(R (caddr k)))))
                ((vmove)
                 `((,reg-mov-mn ,(R (cadr k)) ,(R (caddr k)))))
                ((vzero)
                 (let ((d (R (cadr k)))) `((,zero-mn ,d ,d ,d))))
                ((vadd vsub vmul vdiv)
                 (unless (= (length k) 4) (error who "expects a destination and two sources" k))
                 `((,(cdr (assq (kernel-op k) arith))
                    ,(R (cadr k)) ,(R (caddr k)) ,(R (cadddr k)))))
                ((vsqrt)
                 (unless (= (length k) 3) (error who "vsqrt takes a destination and a source" k))
                 (if scalar?
                     `((,sqrt-mn ,(R (cadr k)) ,(R (caddr k)) ,(R (caddr k))))
                     `((,sqrt-mn ,(R (cadr k)) ,(R (caddr k))))))
                ((vmuladd)
                 (unless (= (length k) 4) (error who "vmuladd takes a destination and two sources" k))
                 (let ((d (cadr k)) (a (caddr k)) (b (cadddr k)))
                   (if contraction?
                       ;; ONE rounding. Emitted only because the policy granted
                       ;; the permission D24 makes explicit.
                       `((,fma-mn ,(R d) ,(R a) ,(R b)))
                       (begin
                         (when (or (= d scratch) (= a scratch) (= b scratch))
                           (error who
                                  (string-append
                                   "the unfused lowering of vmuladd needs the float scratch "
                                   "register and this kernel is already using it; regs.ss "
                                   "reserves exactly one and selection has no channel to "
                                   "ask the allocator for another")
                                  k scratch))
                         ;; TWO roundings, which is what the reference C does
                         ;; without -ffp-contract, and therefore what the
                         ;; bit-exact oracle compares against.
                         `((,(cdr (assq 'vmul arith)) ,(R scratch) ,(R a) ,(R b))
                           (,(cdr (assq 'vadd arith)) ,(R d) ,(R d) ,(R scratch)))))))
                (else (error who "unknown kernel operation" (kernel-op k)))))
            kernel)))

  ;;; ========================================================================
  ;;; 6. The loop, and the tail a fixed width cannot avoid
  ;;; ========================================================================
  ;;
  ;; -> (values vector-body tail-body full-passes remainder)
  ;;
  ;; The trip count is the one veclegal read off (sonic loops), and it is exact
  ;; here, so the loop is emitted straight-line rather than as a counted loop:
  ;; nbody's `fields` is 7 iterations and there is nothing to branch on. A loop
  ;; whose count is only BOUNDED never reaches this file, because veclegal
  ;; refuses it upstream.

  ;; `elements` overrides the verdict's trip count.
  ;;
  ;; A verdict counts ITERATIONS; a linearized loop covers elements. nbody's
  ;; position update steps one body per iteration and touches three elements, so
  ;; its trip is 5 and its element count is 15 -- unrolling five would write a
  ;; third of the array and leave the rest. (sonic vectorize) proves the
  ;; linearization and supplies the number; passing nothing keeps the old
  ;; behaviour, which is right for a loop whose iterations ARE its elements.
  (define vec-emit-loop
    (case-lambda
      ((plan kernel) (vec-emit-loop* plan kernel #f))
      ((plan kernel elements) (vec-emit-loop* plan kernel elements))))

  (define (vec-emit-loop* plan kernel elements)
    (let* ((v (vec-plan-verdict plan))
           (trip (or elements (trip-count (vl-trip v))))
           (lanes (vec-plan-lanes plan))
           (bytes (vec-plan-bytes plan)))
      (unless (and trip (exact? trip))
        (error 'vec-emit-loop
               "the verdict carries no exact trip count, which veclegal should have refused"
               (vl-loop v)))
      (let* ((full (div trip lanes))
             (rem (- trip (* full lanes))))
        (values
         (apply append
                (let loop ((i 0) (acc '()))
                  (if (= i full)
                      (reverse acc)
                      (loop (+ i 1)
                            (cons (vec-emit-kernel plan kernel (* i bytes)) acc)))))
         (apply append
                (let loop ((i 0) (acc '()))
                  (if (= i rem)
                      (reverse acc)
                      (loop (+ i 1)
                            (cons (vec-emit-scalar-kernel
                                   plan kernel (* 8 (+ (* full lanes) i)))
                                  acc)))))
         full rem))))

  ;;; ========================================================================
  ;;; 7. nbody's fields loop
  ;;; ========================================================================
  ;;
  ;; The 7 doubles per body, and what `advance` does to them: each is stepped by
  ;; the corresponding velocity component times dt, which is `f[k] += v[k] * dt`
  ;; and is element-wise in exactly the sense veclegal permits. The verdict says
  ;; raw-f64, 7 iterations, widths (128 256).
  ;;
  ;; The registers are the CALLER's, not this file's, because a benchmark kernel
  ;; has no business naming machine registers: `fbase` and `vbase` hold tagged
  ;; flvectors and belong in the value class, `idx` is a raw word, and
  ;; sonic/src/sonic/regs.ss is what decides which registers those are.

  (define (nbody-fields-kernel fbase vbase idx dt-lane)
    (let ((f `(mem ,fbase ,idx 8 0))
          (v `(mem ,vbase ,idx 8 0)))
      `((vload 0 ,f)
        (vload 1 ,v)
        (vmuladd 0 1 ,dt-lane)
        (vstore ,f 0))))
  )
