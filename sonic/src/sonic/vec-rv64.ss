;;; NOTHING IN THE COMPILATION PIPELINE CALLS THIS. Measured 2026-08-17 by
;;; sweeping every import: driver.ss does not import (sonic vectorize), and the
;;; only importers are vec-x86-64.ss, vec-rv64.ss and vectorize-test.ss. The
;;; pass is written, has green assertions on BOTH targets including
;;; length-agnostic RVV, and reaches no binary. Read that before treating a
;;; green vectorize-test.ss as evidence about compiled output -- it tests the
;;; kernel, not the program.
;;;
;;; WHY IT WAS NEVER WIRED, since it is not an oversight: vec-emit-loop* returns
;;; a LISTING of machine instructions, fully unrolled at fixed byte offsets,
;;; with physical register roles already chosen (ptrs, count, vl, stride). That
;;; bypasses selection and allocation, so there is nowhere in driver.ss to put
;;; it -- the surrounding function's register assignment has no way to agree
;;; with a kernel that picked its own. slp.ss is the pass that DOES reach every
;;; binary, and it works because its packed values are ordinary raw-f64 vregs
;;; the allocator needs no special case for.
;;;
;;; See beads 1mp.4 and 1mp.5.
;;;
;;; RVV emission, length agnostic.
;;;
;;; E5-RVV. Not the same problem as AVX-512, and the difference is structural
;;; rather than a matter of spelling.
;;;
;;; ## The vector length is a RUN-TIME value
;;;
;;; `vsetvli rd, rs1, e64, m1, ta, ma` asks the hardware for as many 64-bit
;;; elements as it will give, up to the `rs1` still outstanding, and writes the
;;; answer back into `rd`. The loop then does that many elements, advances its
;;; pointers by `vl * 8` bytes, subtracts `vl` from the count and branches back.
;;; The last pass runs short and needs no separate code, so the tail that
;;; sonic/src/sonic/vec-x86-64.ss has to emit -- 3 of nbody's 7 iterations,
;;; scalar -- simply does not exist here. The same binary runs on a 128-bit part
;;; and a 1024-bit part.
;;;
;;; That is also why this file never asks the verdict for a WIDTH. It asks for
;;; legality and for the element class, which fixes SEW at 64, and the width
;;; question that dominates the AVX-512 file has no answer to give.
;;;
;;; ## RVV is the baseline, rv64gc is the legacy floor
;;;
;;; sonic/doc/register-partition.md: RVA23 makes V mandatory, Ubuntu ships RVA23
;;; images and dropped pre-RVA23 hardware in October 2025. So the vector path is
;;; first-class. But `harness/smoke-riscv.sh` still smoke-tests `PROFILE=legacy`
;;; against `rv64gc`, which has no V at all, so `rv64gc-emit-loop` emits the same
;;; kernel scalar with nothing above the floor, and the gate keeps passing.
;;;
;;; ## THE DECISION THIS BEAD OWED: vl and the collector
;;;
;;; sonic/doc/gc-metadata.md reserves `vl-live?` in the RV64 vocabulary and
;;; leaves the question open for E5: does the restart-region mechanism extend to
;;; a `vsetvl`-established context, or do vector loops need their own discipline?
;;;
;;; ANSWER: restart regions extend, and no new mechanism is needed, because the
;;; loop is laid out so that the region is idempotent on rewind.
;;;
;;;   the region STARTS at the `vsetvli` and ENDS after the last vector
;;;   instruction. Every pointer bump, the count decrement and the back branch
;;;   are OUTSIDE it.
;;;
;;; Rewinding to the region start re-executes the `vsetvli` with the same `rs1`,
;;; which re-establishes the same vl and the same vtype, and then redoes loads,
;;; arithmetic and the store from unchanged pointers. Same inputs, same
;;; addresses, same result. sonic/src/sonic/preempt.ss states that obligation as
;;; "everything a region does before its commit point must be safe to do twice";
;;; the store is the commit point and the layout is what discharges it.
;;;
;;; `vl-live?` is still set across the region, and it is not redundant with
;;; `restart?`. A collector that only rewound would be relying on the rewind
;;; never being skipped; the bit says out loud that there is machine state here
;;; which is neither a register the collector scavenges nor memory it can read,
;;; and that resuming without it computes a WRONG ANSWER rather than crashing.
;;; A wrong answer with no diagnostic is the failure mode this project's whole
;;; oracle exists to catch, so it gets a bit of its own.
;;;
;;; ## Verification
;;;
;;; Byte-for-byte against `riscv64-linux-gnu-gcc -march=rv64gcv`, in
;;; sonic/test/vec-rv64-test.ss. The RVV encodings are regular but the operand
;;; ORDER is not uniform -- `vfadd.vv vd, vs2, vs1` puts its second operand in
;;; the vs2 field while `vfmacc.vv vd, vs1, vs2` puts its second in vs1 -- and
;;; that is precisely the kind of thing a hand-written expectation table
;;; reproduces faithfully from the same misreading that produced the encoder.

(library (sonic vec-rv64)
  (export ;; registers and vtype
          vreg? vreg-number vreg-name
          vtype-bits vtype-fields
          ;; encoding
          rvv-encode-word rvv-encode-instr rvv-encode-listing
          rvv-mnemonics rvv-supports? rvv-vector-instr?
          rvv-fused-mnemonic? rvv-contraction-evidence
          ;; planning
          rvv-plan? rvv-plan-sew rvv-plan-vtype rvv-plan-contraction?
          rvv-plan-verdict rvv-plan-for-verdict
          ;; emission
          rvv-emit-kernel rvv-emit-loop rv64gc-emit-loop
          nbody-fields-kernel
          ;; GC metadata and preemption
          rvv-loop-metadata rvv-vl-live-span)
  (import (chezscheme)
          (rename (only (sonic encode-rv64) encode-word gpr-number fpr-number)
                  (encode-word base-encode-word))
          (only (sonic loops) trip-count)
          (only (sonic gcmeta) make-entry)
          (only (sonic preempt) make-region)
          (sonic veclegal))

  ;;; ========================================================================
  ;;; 1. Vector registers and vtype
  ;;; ========================================================================

  (define (vreg? r)
    (and (symbol? r)
         (let ((s (symbol->string r)))
           (and (>= (string-length s) 2)
                (char=? (string-ref s 0) #\v)
                (let ((n (string->number (substring s 1 (string-length s)))))
                  (and n (exact? n) (integer? n) (<= 0 n 31)))))))

  (define (vreg-number r)
    (unless (vreg? r) (error 'vreg-number "not an RVV vector register" r))
    (string->number (let ((s (symbol->string r))) (substring s 1 (string-length s)))))

  (define (vreg-name n)
    (unless (and (integer? n) (exact? n) (<= 0 n 31))
      (error 'vreg-name "no such vector register" n))
    (string->symbol (string-append "v" (number->string n))))

  ;; vtype is written the way the assembler writes it, `(e64 m1 ta ma)`, and
  ;; packed here. Carrying the symbols rather than the packed integer means the
  ;; assembly printer in the test and the encoder read the SAME operand, which
  ;; is what makes the differential check total.
  (define sew-codes '((e8 . 0) (e16 . 1) (e32 . 2) (e64 . 3)))
  (define lmul-codes '((m1 . 0) (m2 . 1) (m4 . 2) (m8 . 3)
                       (mf8 . 5) (mf4 . 6) (mf2 . 7)))

  (define (vtype-fields vt)
    (unless (and (list? vt) (= (length vt) 4))
      (error 'vtype-bits "vtype must be (sew lmul tail mask), e.g. (e64 m1 ta ma)" vt))
    (let ((sew (assq (car vt) sew-codes))
          (lmul (assq (cadr vt) lmul-codes))
          (ta (case (caddr vt) ((ta) 1) ((tu) 0) (else #f)))
          (ma (case (cadddr vt) ((ma) 1) ((mu) 0) (else #f))))
      (unless (and sew lmul ta ma) (error 'vtype-bits "not a vtype" vt))
      (values (cdr sew) (cdr lmul) ta ma)))

  (define (vtype-bits vt)
    (let-values (((sew lmul ta ma) (vtype-fields vt)))
      (bitwise-ior (bitwise-arithmetic-shift-left ma 7)
                   (bitwise-arithmetic-shift-left ta 6)
                   (bitwise-arithmetic-shift-left sew 3)
                   lmul)))

  ;;; ========================================================================
  ;;; 2. The instruction table
  ;;; ========================================================================
  ;;
  ;; (mnemonic kind . fields). Operands are in the ASSEMBLER's textual order,
  ;; unlike sonic/src/sonic/encode-rv64.ss which normalises to one order per
  ;; format. The reason is the irregularity this table exists to survive:
  ;; `vfadd.vv vd, vs2, vs1` and `vfmacc.vv vd, vs1, vs2` disagree about which
  ;; field the second operand lands in, so a "canonical" order would have to
  ;; encode that disagreement anyway and would then differ from every reference
  ;; anyone checks it against.
  ;;
  ;;   setvli   (vsetvli rd rs1 vtype)
  ;;   setivli  (vsetivli rd uimm vtype)
  ;;   setvl    (vsetvl rd rs1 rs2)
  ;;   vload    (vle64.v vd rs1)
  ;;   vstore   (vse64.v vs3 rs1)
  ;;   vv       (op vd vs2 vs1)
  ;;   vv-macc  (op vd vs1 vs2)         accumulate INTO vd
  ;;   vunary   (op vd vs2)             vs1 field is a fixed selector
  ;;   vf       (op vd rs1)             scalar float broadcast, vs2 = 0
  ;;   r4       (op rd rs1 rs2 rs3)     the D-extension fused form

  (define op-v      #b1010111)
  (define op-loadfp #b0000111)
  (define op-storefp #b0100111)
  (define op-madd   #b1000011)

  (define opivv #b000)
  (define opfvv #b001)
  (define opfvf #b101)
  (define opcfg #b111)

  ;; Written out one line per instruction rather than quasiquoted in a lump, so
  ;; each stays readable next to the format it belongs to.
  (define instr-table
    (list
     (list 'vsetvli  'setvli)
     (list 'vsetivli 'setivli)
     (list 'vsetvl   'setvl)
     (list 'vle64.v  'vload  #b111)
     (list 'vse64.v  'vstore #b111)
     ;; OPFVV, (vd vs2 vs1)
     (list 'vfadd.vv 'vv opfvv #b000000)
     (list 'vfsub.vv 'vv opfvv #b000010)
     (list 'vfmul.vv 'vv opfvv #b100100)
     (list 'vfdiv.vv 'vv opfvv #b100000)
     ;; OPIVV
     (list 'vadd.vv  'vv opivv #b000000)
     ;; accumulate into vd: vd += vs1 * vs2. THE fused form, and the one D24
     ;; makes a permission rather than an optimisation.
     (list 'vfmacc.vv 'vv-macc opfvv #b101100)
     ;; vs1 field is the operation selector, not a register
     (list 'vfsqrt.v 'vunary opfvv #b010011 #b00000)
     ;; splat an f64 from an FPR across the vector
     (list 'vfmv.v.f 'vf opfvf #b010111)
     ;; whole-vector move, (vmv.v.v vd vs1), vs2 field is zero
     (list 'vmv.v.v  'vmv opivv #b010111)
     ;; scalar D-extension fused multiply-add, rd = rs1*rs2 + rs3. Lives here
     ;; and NOT in encode-rv64.ss for the same reason vfmadd231pd lives outside
     ;; the baseline x86-64 encoder: it is contraction, it is a permission, and
     ;; the baseline encoder's job includes not having one.
     (list 'fmadd.d  'r4 #b111 #b01)))

  (define (rvv-entry m) (assq m instr-table))
  (define (rvv-supports? m) (and (rvv-entry m) #t))
  (define (rvv-mnemonics) (map car instr-table))

  ;; True for the ones that need the V extension. `fmadd.d` is in the table but
  ;; is plain rv64gc D, so the legacy profile can still use it.
  (define (rvv-vector-instr? m)
    (and (rvv-supports? m) (not (eq? m 'fmadd.d))))

  (define (rvv-fused-mnemonic? m) (and (memq m '(vfmacc.vv fmadd.d)) #t))

  (define (rvv-contraction-evidence instrs)
    (let loop ((is instrs) (acc '()))
      (cond ((null? is) (reverse acc))
            ((and (pair? (car is)) (rvv-fused-mnemonic? (caar is)))
             (loop (cdr is) (cons (caar is) acc)))
            (else (loop (cdr is) acc)))))

  ;;; ========================================================================
  ;;; 3. Encoding
  ;;; ========================================================================

  (define (want! ok who what v)
    (unless ok (error 'rvv-encode-instr (string-append who ": " what) v))
    v)

  (define (uimm5 who v)
    (want! (and (integer? v) (exact? v) (<= 0 v 31)) who
           "vsetivli element count is not a 5-bit unsigned field" v))

  (define (rvv-encode-word instr)
    (unless (and (pair? instr) (symbol? (car instr)))
      (error 'rvv-encode-instr "not an instruction" instr))
    (let* ((mn (car instr))
           (e (rvv-entry mn))
           (ops (cdr instr))
           (who (symbol->string mn)))
      (unless e
        (error 'rvv-encode-instr
               "this vector encoder does not know that mnemonic" mn))
      (let ((kind (cadr e)) (f (cddr e)))
        (define (arity! n)
          (unless (= (length ops) n)
            (error 'rvv-encode-instr "wrong operand count" mn n ops)))
        (case kind
          ((setvli)
           (arity! 3)
           (bitwise-ior (bitwise-arithmetic-shift-left (vtype-bits (caddr ops)) 20)
                        (bitwise-arithmetic-shift-left (gpr-number (cadr ops)) 15)
                        (bitwise-arithmetic-shift-left opcfg 12)
                        (bitwise-arithmetic-shift-left (gpr-number (car ops)) 7)
                        op-v))
          ((setivli)
           (arity! 3)
           (bitwise-ior (bitwise-arithmetic-shift-left #b11 30)
                        (bitwise-arithmetic-shift-left (vtype-bits (caddr ops)) 20)
                        (bitwise-arithmetic-shift-left (uimm5 who (cadr ops)) 15)
                        (bitwise-arithmetic-shift-left opcfg 12)
                        (bitwise-arithmetic-shift-left (gpr-number (car ops)) 7)
                        op-v))
          ((setvl)
           (arity! 3)
           (bitwise-ior (bitwise-arithmetic-shift-left #b1000000 25)
                        (bitwise-arithmetic-shift-left (gpr-number (caddr ops)) 20)
                        (bitwise-arithmetic-shift-left (gpr-number (cadr ops)) 15)
                        (bitwise-arithmetic-shift-left opcfg 12)
                        (bitwise-arithmetic-shift-left (gpr-number (car ops)) 7)
                        op-v))
          ;; nf = 0, mew = 0, mop = 00 (unit stride), vm = 1 (unmasked),
          ;; lumop/sumop = 00000 (plain unit stride, not fault-only-first)
          ((vload)
           (arity! 2)
           (bitwise-ior (bitwise-arithmetic-shift-left 1 25)
                        (bitwise-arithmetic-shift-left (gpr-number (cadr ops)) 15)
                        (bitwise-arithmetic-shift-left (car f) 12)
                        (bitwise-arithmetic-shift-left (vreg-number (car ops)) 7)
                        op-loadfp))
          ((vstore)
           (arity! 2)
           (bitwise-ior (bitwise-arithmetic-shift-left 1 25)
                        (bitwise-arithmetic-shift-left (gpr-number (cadr ops)) 15)
                        (bitwise-arithmetic-shift-left (car f) 12)
                        (bitwise-arithmetic-shift-left (vreg-number (car ops)) 7)
                        op-storefp))
          ((vv)
           (arity! 3)
           (enc-opv (cadr f) (vreg-number (cadr ops)) (vreg-number (caddr ops))
                    (car f) (vreg-number (car ops))))
          ((vv-macc)
           ;; second operand is vs1, third is vs2. The whole reason this file
           ;; keeps textual order.
           (arity! 3)
           (enc-opv (cadr f) (vreg-number (caddr ops)) (vreg-number (cadr ops))
                    (car f) (vreg-number (car ops))))
          ((vunary)
           (arity! 2)
           (enc-opv (cadr f) (vreg-number (cadr ops)) (caddr f)
                    (car f) (vreg-number (car ops))))
          ((vf)
           (arity! 2)
           (enc-opv (cadr f) 0 (fpr-number (cadr ops))
                    (car f) (vreg-number (car ops))))
          ((vmv)
           (arity! 2)
           (enc-opv (cadr f) 0 (vreg-number (cadr ops))
                    (car f) (vreg-number (car ops))))
          ((r4)
           (arity! 4)
           (bitwise-ior (bitwise-arithmetic-shift-left (fpr-number (cadddr ops)) 27)
                        (bitwise-arithmetic-shift-left (cadr f) 25)
                        (bitwise-arithmetic-shift-left (fpr-number (caddr ops)) 20)
                        (bitwise-arithmetic-shift-left (fpr-number (cadr ops)) 15)
                        (bitwise-arithmetic-shift-left (car f) 12)
                        (bitwise-arithmetic-shift-left (fpr-number (car ops)) 7)
                        op-madd))
          (else (error 'rvv-encode-instr "unhandled instruction format" mn kind))))))

  ;; funct6 | vm=1 | vs2 | vs1 | funct3 | vd | opcode
  (define (enc-opv funct6 vs2 vs1 funct3 vd)
    (bitwise-ior (bitwise-arithmetic-shift-left funct6 26)
                 (bitwise-arithmetic-shift-left 1 25)
                 (bitwise-arithmetic-shift-left vs2 20)
                 (bitwise-arithmetic-shift-left vs1 15)
                 (bitwise-arithmetic-shift-left funct3 12)
                 (bitwise-arithmetic-shift-left vd 7)
                 op-v))

  ;; A vector loop is a MIX: the vector body plus the scalar pointer bumps and
  ;; the back branch, which are ordinary rv64gc. Anything this table does not
  ;; know goes to the base encoder, which keeps one encoder per instruction and
  ;; no second opinion about `add`.
  (define (rvv-encode-word* instr)
    (if (rvv-entry (car instr))
        (rvv-encode-word instr)
        (base-encode-word instr)))

  (define (rvv-encode-instr instr)
    (let ((w (rvv-encode-word* instr)))
      (list (bitwise-and w #xff)
            (bitwise-and (bitwise-arithmetic-shift-right w 8) #xff)
            (bitwise-and (bitwise-arithmetic-shift-right w 16) #xff)
            (bitwise-and (bitwise-arithmetic-shift-right w 24) #xff))))

  ;; Two passes over a listing whose elements are instructions or bare label
  ;; symbols. Every instruction is 4 bytes, vector or not, because we do not
  ;; emit RVC, so the second pass cannot move anything the first pass placed.
  (define (rvv-encode-listing listing)
    (let ((labels (make-eq-hashtable)))
      (define (resolve instr pc)
        (let ((mn (car instr)))
          (if (memq mn '(beq bne blt bge bltu bgeu jal))
              (let* ((n (length instr)) (t (list-ref instr (- n 1))))
                (if (symbol? t)
                    (let ((at (hashtable-ref labels t #f)))
                      (unless at (error 'rvv-encode-listing "undefined label" t instr))
                      (append (list-head instr (- n 1)) (list (- at pc))))
                    instr))
              instr)))
      (let pass1 ((xs listing) (pc 0))
        (cond ((null? xs) 'done)
              ((symbol? (car xs))
               (when (hashtable-ref labels (car xs) #f)
                 (error 'rvv-encode-listing "label defined twice" (car xs)))
               (hashtable-set! labels (car xs) pc)
               (pass1 (cdr xs) pc))
              (else (pass1 (cdr xs) (+ pc 4)))))
      (let pass2 ((xs listing) (pc 0) (acc '()))
        (cond ((null? xs) (apply append (reverse acc)))
              ((symbol? (car xs)) (pass2 (cdr xs) pc acc))
              (else (pass2 (cdr xs) (+ pc 4)
                           (cons (rvv-encode-instr (resolve (car xs) pc)) acc)))))))

  ;;; ========================================================================
  ;;; 4. The plan
  ;;; ========================================================================
  ;;
  ;; Note what is NOT in here: a width. veclegal's width list is consumed only
  ;; to check that SOME width was permitted, i.e. that at least one full vector
  ;; operation has iterations to fill it; which width is a question this target
  ;; does not answer at compile time and does not need to.

  (define-record-type (rvv-plan mk-rvv-plan rvv-plan?)
    (fields sew vtype contraction? verdict))

  (define (rvv-plan-for-verdict v contraction?)
    (unless (vl? v) (error 'rvv-plan-for-verdict "not a vectorization verdict" v))
    (unless (vl-legal? v)
      (error 'rvv-plan-for-verdict
             (string-append
              "this loop is not vectorizable and the reasons are veclegal's to give; "
              "length agnosticism does not make an illegal transform legal")
             (vl-loop v) (vl-reasons v)))
    (unless (eq? (vl-elt-class v) 'raw-f64)
      (error 'rvv-plan-for-verdict
             "this back end emits SEW=64 float arithmetic and the element is not a double"
             (vl-loop v) (vl-elt-class v)))
    (when (null? (vl-widths v))
      (error 'rvv-plan-for-verdict
             "the verdict permits no width at all, so not even the narrowest vector has a guaranteed iteration"
             (vl-loop v)))
    (mk-rvv-plan 64 '(e64 m1 ta ma) (and contraction? #t) v))

  ;;; ========================================================================
  ;;; 5. The kernel op language
  ;;; ========================================================================
  ;;
  ;; The same shape sonic/src/sonic/vec-x86-64.ss consumes, with one deliberate
  ;; difference: a memory operand is a POINTER REGISTER and nothing else. RISC-V
  ;; has no indexed addressing and RVV's unit-stride loads take a bare base, so
  ;; an x86-style (base index scale disp) would be a fiction this target then
  ;; has to undo. The pointers are what the loop advances anyway.
  ;;
  ;;   (vload  d ptr)     (vstore ptr s)     (vmove d s)
  ;;   (vadd d a b)  (vsub ...)  (vmul ...)  (vdiv ...)
  ;;   (vsqrt d a)
  ;;   (vmuladd d a b)    d := d + a * b
  ;;   (vsplat d fpr)     every lane := the double in an FPR

  ;; v31 is the top of the vector file and no kernel this file emits reaches it,
  ;; which is what makes it usable as the product temporary the unfused
  ;; lowering of `vmuladd` needs. RVV has no equivalent of regs.ss's reserved
  ;; float scratch because there is no vector allocator yet to reserve it from.
  (define rvv-scratch-lane 31)

  (define (rvv-emit-kernel plan kernel)
    (define (R n)
      (unless (and (integer? n) (exact? n) (<= 0 n 31))
        (error 'rvv-emit-kernel "not a lane register number" n))
      (vreg-name n))
    (apply append
           (map
            (lambda (k)
              (unless (pair? k) (error 'rvv-emit-kernel "not a kernel operation" k))
              (case (car k)
                ((vload)   `((vle64.v ,(R (cadr k)) ,(caddr k))))
                ((vstore)  `((vse64.v ,(R (caddr k)) ,(cadr k))))
                ((vmove)   `((vmv.v.v ,(R (cadr k)) ,(R (caddr k)))))
                ((vsplat)  `((vfmv.v.f ,(R (cadr k)) ,(caddr k))))
                ((vadd)    `((vfadd.vv ,(R (cadr k)) ,(R (caddr k)) ,(R (cadddr k)))))
                ((vsub)    `((vfsub.vv ,(R (cadr k)) ,(R (caddr k)) ,(R (cadddr k)))))
                ((vmul)    `((vfmul.vv ,(R (cadr k)) ,(R (caddr k)) ,(R (cadddr k)))))
                ((vdiv)    `((vfdiv.vv ,(R (cadr k)) ,(R (caddr k)) ,(R (cadddr k)))))
                ((vsqrt)   `((vfsqrt.v ,(R (cadr k)) ,(R (caddr k)))))
                ((vmuladd)
                 (let ((d (cadr k)) (a (caddr k)) (b (cadddr k)))
                   (if (rvv-plan-contraction? plan)
                       ;; ONE rounding, and only because the policy said so.
                       `((vfmacc.vv ,(R d) ,(R a) ,(R b)))
                       ;; TWO roundings, which is what the reference C does and
                       ;; therefore what the bit-exact oracle compares against.
                       (begin
                         (when (memv rvv-scratch-lane (list d a b))
                           (error 'rvv-emit-kernel
                                  "the unfused lowering of vmuladd needs the scratch lane and this kernel already uses it"
                                  k rvv-scratch-lane))
                         `((vfmul.vv ,(R rvv-scratch-lane) ,(R a) ,(R b))
                           (vfadd.vv ,(R d) ,(R d) ,(R rvv-scratch-lane)))))))
                (else (error 'rvv-emit-kernel "unknown kernel operation" (car k)))))
            kernel)))

  ;;; ========================================================================
  ;;; 6. The length-agnostic loop
  ;;; ========================================================================
  ;;
  ;; (rvv-emit-loop plan kernel ptrs count vl stride label) -> a listing
  ;;
  ;;   ptrs    the pointer registers the kernel loads and stores through, each
  ;;           advanced by vl*8 bytes per pass
  ;;   count   elements still to do; the loop reads it and decrements it
  ;;   vl      where vsetvli writes back how many it actually took
  ;;   stride  a scratch GPR for vl*8
  ;;
  ;; THE ORDER IS LOAD-BEARING, not stylistic. Every pointer bump and the
  ;; decrement come AFTER the last vector instruction, which is what makes the
  ;; restart region idempotent on rewind. See the header.

  (define (rvv-emit-loop plan kernel ptrs count vl stride label)
    (when (memq vl ptrs)
      (error 'rvv-emit-loop "the vl register cannot also be a data pointer" vl))
    (when (memq stride ptrs)
      (error 'rvv-emit-loop "the stride scratch cannot also be a data pointer" stride))
    (append
     (list label)
     ;; ask the hardware how many elements it will take, up to what is left
     (list `(vsetvli ,vl ,count ,(rvv-plan-vtype plan)))
     (rvv-emit-kernel plan kernel)
     ;; --- restart region ends here; nothing below is redone on rewind -------
     (list `(slli ,stride ,vl 3))
     (map (lambda (p) `(add ,p ,p ,stride)) ptrs)
     (list `(sub ,count ,count ,vl)
           `(bne ,count zero ,label))))

  ;;; ========================================================================
  ;;; 7. The legacy floor: the same kernel, scalar, nothing above rv64gc
  ;;; ========================================================================
  ;;
  ;; harness/smoke-riscv.sh runs PROFILE=legacy against `rv64gc`, which has no V
  ;; and where `vsetvli` does not assemble. So the vector path is a path and not
  ;; the only one. The trip count is exact, so this is straight-line rather than
  ;; a counted loop, matching what the AVX-512 side does with its tail.

  ;; `elements` overrides the verdict's trip count.
  ;;
  ;; A verdict counts ITERATIONS; a linearized loop covers elements. nbody's
  ;; position update steps one body per iteration and touches three elements, so
  ;; its trip is 5 and its element count is 15 -- unrolling five would write a
  ;; third of the array and leave the rest. (sonic vectorize) proves the
  ;; linearization and supplies the number; passing nothing keeps the old
  ;; behaviour, which is right for a loop whose iterations ARE its elements.
  (define rv64gc-emit-loop
    (case-lambda
      ((plan kernel) (rv64gc-emit-loop* plan kernel #f))
      ((plan kernel elements) (rv64gc-emit-loop* plan kernel elements))))

  (define (rv64gc-emit-loop* plan kernel elements)
    (let* ((v (rvv-plan-verdict plan))
           (trip (or elements (trip-count (vl-trip v)))))
      (unless (and trip (exact? trip))
        (error 'rv64gc-emit-loop
               "the verdict carries no exact trip count" (vl-loop v)))
      (apply append
             (let loop ((i 0) (acc '()))
               (if (= i trip)
                   (reverse acc)
                   (loop (+ i 1)
                         (cons (scalar-kernel plan kernel (* 8 i)) acc)))))))

  ;; Lane number to an FPR. The float pool in sonic/src/sonic/regs.ss is in
  ;; ALLOCATION order and ft11 is its reserved scratch, so a lane index is
  ;; mapped through ft0..ft7 / fs0.. rather than by arithmetic on a number.
  (define scalar-lane-names
    '#(ft0 ft1 ft2 ft3 ft4 ft5 ft6 ft7 fs0 fs1 fs2 fs3 fs4 fs5 fs6 fs7
       fa0 fa1 fa2 fa3 fa4 fa5 fa6 fa7 fs8 fs9 fs10 fs11 ft8 ft9 ft10 ft11))

  (define (scalar-lane n)
    (unless (and (integer? n) (exact? n) (<= 0 n 31))
      (error 'rv64gc-emit-loop "not a lane register number" n))
    (vector-ref scalar-lane-names n))

  (define scalar-scratch 'ft11)

  (define (scalar-kernel plan kernel disp)
    (define (F n) (scalar-lane n))
    (apply append
           (map
            (lambda (k)
              (case (car k)
                ((vload)   `((fld ,(F (cadr k)) ,(caddr k) ,disp)))
                ((vstore)  `((fsd ,(F (caddr k)) ,(cadr k) ,disp)))
                ((vmove)   `((fsgnj.d ,(F (cadr k)) ,(F (caddr k)) ,(F (caddr k)))))
                ((vsplat)  `((fsgnj.d ,(F (cadr k)) ,(caddr k) ,(caddr k))))
                ((vadd)    `((fadd.d ,(F (cadr k)) ,(F (caddr k)) ,(F (cadddr k)))))
                ((vsub)    `((fsub.d ,(F (cadr k)) ,(F (caddr k)) ,(F (cadddr k)))))
                ((vmul)    `((fmul.d ,(F (cadr k)) ,(F (caddr k)) ,(F (cadddr k)))))
                ((vdiv)    `((fdiv.d ,(F (cadr k)) ,(F (caddr k)) ,(F (cadddr k)))))
                ((vsqrt)   `((fsqrt.d ,(F (cadr k)) ,(F (caddr k)))))
                ((vmuladd)
                 (let ((d (F (cadr k))) (a (F (caddr k))) (b (F (cadddr k))))
                   (if (rvv-plan-contraction? plan)
                       `((fmadd.d ,d ,a ,b ,d))
                       `((fmul.d ,scalar-scratch ,a ,b)
                         (fadd.d ,d ,d ,scalar-scratch)))))
                (else (error 'rv64gc-emit-loop "unknown kernel operation" (car k)))))
            kernel)))

  ;;; ========================================================================
  ;;; 8. GC metadata: vl-live? and the restart region
  ;;; ========================================================================
  ;;
  ;; -> (values start-offset end-offset), the half-open byte range over which
  ;; the vsetvli-established vector length and element width are live. Computed
  ;; from the LISTING rather than asserted, so it cannot drift from the code.

  (define (rvv-vl-live-span listing)
    (let loop ((xs listing) (pc 0) (start #f) (end #f))
      (cond
       ((null? xs)
        (unless start
          (error 'rvv-vl-live-span "this listing establishes no vector length" listing))
        (values start end))
       ((symbol? (car xs)) (loop (cdr xs) pc start end))
       (else
        (let ((mn (caar xs)))
          (loop (cdr xs) (+ pc 4)
                (if (and (not start) (memq mn '(vsetvli vsetivli vsetvl))) pc start)
                (if (rvv-vector-instr? mn) (+ pc 4) end)))))))

  ;; The metadata a vector loop contributes, per sonic/doc/gc-metadata.md's RV64
  ;; vocabulary. Two entries because the answer changes twice and the encoder
  ;; drops anything that repeats: vl comes live at the vsetvli and dies after
  ;; the last vector instruction.
  ;;
  ;; `restart?` rides the same span. That is the DECISION this bead owed: the
  ;; restart mechanism extends to a vsetvl-established context and needs no new
  ;; discipline, because the loop above puts every side effect that is not
  ;; idempotent outside the span.
  (define (rvv-loop-metadata listing frame-bits)
    (let-values (((start end) (rvv-vl-live-span listing)))
      (values
       (list (make-entry start '((restart? . 1) (vl-live? . 1)) frame-bits)
             (make-entry end  '((restart? . 0) (vl-live? . 0)) frame-bits))
       (make-region 'rvv-vector-body start end))))

  ;;; ========================================================================
  ;;; 9. nbody's fields loop
  ;;; ========================================================================
  ;;
  ;; The 7 doubles per body, stepped by the matching velocity component times
  ;; dt: `f[k] += v[k] * dt`, element-wise, which is what veclegal permits and
  ;; the shape alias.ss's header names as the motivating case.

  (define (nbody-fields-kernel fptr vptr dt-lane)
    `((vload 0 ,fptr)
      (vload 1 ,vptr)
      (vmuladd 0 1 ,dt-lane)
      (vstore ,fptr 0)))
  )
