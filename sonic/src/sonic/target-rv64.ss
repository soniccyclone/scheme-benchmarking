;;; RV64 instruction selection.
;;;
;;; E2-RVSEL. A `selector` for the framework in sonic/src/sonic/select.ss: this
;;; file is nothing but a rule table plus the target knowledge the framework
;;; refuses to hold. It consumes `nbody-inner-mach` from sonic/src/sonic/fixtures.ss,
;;; which is E2-LIR's acceptance criterion.
;;;
;;; ## The ISA is PINNED, not inherited
;;;
;;; sonic/doc/register-partition.md section "The baseline: RVA23, not rv64gc"
;;; records that `riscv64-linux-gnu-gcc` here defaults to an ISA string carrying
;;; every RVA23U64 mandatory extension, and that the same source silently
;;; produces different instructions depending on a flag nobody wrote down. Two
;;; demonstrations from that document: `sh3add` (Zba) appears for something as
;;; ordinary as `p[k]`, and `fli.d` (Zfa) appears and disappears with the march.
;;;
;;; So: **rv64gc is the floor and this selector never leaves it.** RVA23 is the
;;; optimization target, and an RVA23 rule table is a later bead that overrides
;;; rules here rather than a flag on this one. The refusal that makes that
;;; enforceable lives in sonic/src/sonic/encode-rv64.ss, which knows the
;;; above-baseline mnemonics by name and by extension and will not encode them.
;;;
;;; ## Target instruction shape
;;;
;;; `(mnemonic operand ...)`, operands in a single order per format rather than
;;; in the assembler's textual order:
;;;
;;;   R      (add rd rs1 rs2)          I      (addi rd rs1 imm)
;;;   load   (ld rd rs1 imm)           store  (sd rs2 rs1 imm)
;;;   branch (beq rs1 rs2 target)      U      (lui rd imm20)
;;;   jump   (jal rd target)           jalr   (jalr rd rs1 imm)
;;;
;;; One order means the encoder and the assembly printer in the test are two
;;; consumers of one shape, so the differential check is total by construction
;;; rather than by a table someone has to remember to extend.
;;;
;;; ## What Lmach does not tell us, and what we do about it
;;;
;;; Recorded here rather than worked around silently. Each of these is a place
;;; the machine-independent IR is underspecified for RV64 specifically.
;;;
;;; 1. RISC-V HAS NO INDEXED ADDRESSING. `(load dst sc base idx)` is one x86-64
;;;    instruction and three here: shift, add, load. The address temporary is a
;;;    register selection has no way to ask for, because a rule returns
;;;    instructions and nothing else. We use t0, which sonic/doc/gc-metadata.md
;;;    names as one of RV64's three scratch registers in the raw class. See
;;;    `rv64-addr-scratch` below for the conflict that creates with regs.ss.
;;;
;;; 2. RISC-V HAS NO FLAGS REGISTER. numeric.ss describes a checked fx+ as "an
;;;    add followed by `jo`". There is no `jo`. The signed-overflow test is the
;;;    sign-comparison idiom, four instructions and two scratches, and that cost
;;;    asymmetry between the two targets is a real finding, not an inconvenience.
;;;
;;; 3. A COMPARISON'S OPERAND CLASS IS NOT CARRIED. `(cmp-lt v sc a b)` has one
;;;    storage class and it is nominally the destination's, but the destination
;;;    of a float compare on RV64 is an integer register. We read `sc` as the
;;;    class of the OPERANDS, which is the same reading the fixture's
;;;    `(load v-val raw-f64 v-b v-idx)` already forces: there `raw-f64` is the
;;;    loaded value while both source vregs are integers.
;;;
;;; 4. A TRANSFER CARRIES NO STORAGE CLASS. `select-block` calls transfer rules
;;;    with `sc` = #f, so `(ret v)` cannot choose between `mv a0, v` and
;;;    `fmv.d fa0, v`. We emit only the return jump. Getting the value into the
;;;    ABI return register is a precoloring constraint on allocation, not an
;;;    instruction, and the selector has no channel to state one.

(library (sonic target-rv64)
  (export rv64-selector rv64-rules rv64-addr-scratch rv64-overflow-scratch
          current-litpool
          rv64-trap-label rv64-call-emitter)
  (import (chezscheme)
          (sonic litpool)
          (sonic numeric)
          (sonic lang)
          (sonic regs)
          (sonic callconv)
          (sonic callseq)
          (sonic select))

  ;; --- the scratch registers, and the conflict they carry -------------------
  ;;
  ;; sonic/doc/gc-metadata.md: "RV64 has three scratch registers in the raw
  ;; class (t0-t2)", and reserves a 3-bit `scratch-live` bitmap over exactly
  ;; those three. sonic/src/sonic/regs.ss nonetheless lists t0, t1 and t2 at the
  ;; head of the ALLOCATABLE raw pool, so linear scan will hand them to virtuals.
  ;; Those two statements cannot both hold once selection emits an address
  ;; temporary. Parameters rather than constants so the conflict is visible and
  ;; a later bead can settle it by rebinding rather than by editing rules.
  ;;
  ;; Note what this does NOT owe the collector: t0 here holds a raw address, not
  ;; a tagged value, so `scratch-live` stays clear across these sequences. The
  ;; bit exists for calling-convention windows, which these are not.
  (define rv64-addr-scratch (make-parameter 't0))
  (define rv64-overflow-scratch (make-parameter '(t0 t1)))

  ;; Where a failed check goes. One label per check name; the handler is E3's.
  (define (rv64-trap-label check-name)
    (string->symbol (string-append "trap-" (symbol->string check-name))))

  ;; --- storage classes ------------------------------------------------------

  (define (float? sc) (eq? sc 'raw-f64))

  ;; Every class this compiler has is 8 bytes wide: a double, a machine word,
  ;; and a tagged value (numeric.ss, 3-bit tag on a 64-bit word) all are. Stated
  ;; as a function anyway so the one place it stops being true is findable.
  (define (class-scale sc)
    (case sc
      ((raw-f64 raw-word tagged) 8)
      (else (error 'class-scale "no scale for storage class" sc))))

  (define (log2-scale n)
    (case n ((8) 3) ((4) 2) ((2) 1) ((1) 0)
      (else (error 'log2-scale "scale is not a power of two" n))))

  ;; --- helpers --------------------------------------------------------------

  ;; base + idx*scale into the scratch, then the memory instruction. Three
  ;; instructions where x86-64 needs zero: see note 1 at the top.
  (define (address-into scratch base idx sc)
    (list `(slli ,scratch ,idx ,(log2-scale (class-scale sc)))
          `(add ,scratch ,base ,scratch)))

  (define (arity-check! who n srcs)
    (unless (= (length srcs) n)
      (error who "wrong operand count for this op on RV64" n srcs)))

  ;; --- rules ----------------------------------------------------------------

  ;; The pool a pooled constant is interned into. A parameter rather than an
  ;; argument because the rule signature (dst sc srcs) is the contract both
  ;; targets and the framework's toy target implement, and widening it for one
  ;; case would break all three.
  ;;
  ;; Defaults to a fresh pool so a rule can be exercised standalone; a real
  ;; compilation parameterizes it to the function's own pool, which object.ss
  ;; then emits into .rodata with the relocations reloc.ss builds.
  (define (r:const dst sc srcs)
    (let ((d (car srcs)))
      (cond
       ((float? sc)
        ;; RESOLVED (bead 6gk.13/6gk.17). litpool.ss interns it and reloc.ss builds the two
        ;; relocations RV64 needs, because it has no PC-relative load: the
        ;; address is built in two instructions and BOTH relocate, with the
        ;; LO12 naming the HI20's label rather than the symbol.
        ;;
        ;; The immediates are the pool offset; the linker overwrites both via
        ;; the relocations, and emitting the offset rather than zero keeps the
        ;; disassembly readable when nothing has linked it yet.
        (let* ((off (pool-intern-f64! (current-litpool) d))   ; returns the offset
               (t (rv64-addr-scratch)))
          `((auipc ,t ,off)
            (fld ,dst ,t ,off))))
       ;; The empty list is a real Scheme object, not an immediate. numeric.ss
       ;; assigns tags to fixnums and flonums and to nothing else, so there is
       ;; no bit pattern to materialise -- and there does not need to be: the
       ;; partition in regs.ss dedicates `gp` to nil precisely so that nil is a
       ;; register move rather than a tag.
       ((null? d)
        `((addi ,dst ,(arch-register-for arch-rv64 'nil) 0)))
       ((not (and (integer? d) (exact? d)))
        (error 'rv64-select "RV64 const rule takes an exact integer" d))
       ((<= -2048 d 2047)
        `((addi ,dst zero ,d)))
       ((<= (- (expt 2 31)) d (- (expt 2 31) 1))
        ;; The standard lui/addi pair. The +#x800 is the carry correction: addi
        ;; sign-extends its 12 bits, so a low half above #x7ff borrows one from
        ;; the high half.
        (let* ((lo (- (bitwise-and (+ d #x800) #xfff) #x800))
               (hi (bitwise-and (ash (- d lo) -12) #xfffff)))
          (if (zero? lo)
              `((lui ,dst ,hi))
              `((lui ,dst ,hi) (addi ,dst ,dst ,lo)))))
       (else
        ;; A full 64-bit constant is lui/addi/slli/addi/slli/addi..., six to
        ;; eight instructions, and every serious RISC-V compiler puts it in a
        ;; constant pool instead. Same missing pool as the flonum case.
        (error 'rv64-select
               "a constant outside the 32-bit range wants a literal pool, not a six-instruction materialization sequence"
               d)))))

  (define (binop int-mn float-mn)
    (lambda (dst sc srcs)
      (arity-check! 'rv64-select 2 srcs)
      (if (float? sc)
          (if float-mn
              `((,float-mn ,dst ,(car srcs) ,(cadr srcs)))
              (error 'rv64-select "no rv64gc float instruction for this op" int-mn))
          (if int-mn
              `((,int-mn ,dst ,(car srcs) ,(cadr srcs)))
              (error 'rv64-select "no rv64gc integer instruction for this op" float-mn)))))

  (define (r:neg dst sc srcs)
    (arity-check! 'rv64-select 1 srcs)
    (if (float? sc)
        ;; fneg.d IS fsgnjn.d rd, rs, rs. Not `fsub.d rd, zero, rs`, which
        ;; disagrees at 0.0 exactly as lang.ss's note on `flneg` says: true
        ;; negation gives -0.0 and the sign survives a subsequent divide.
        `((fsgnjn.d ,dst ,(car srcs) ,(car srcs)))
        `((sub ,dst zero ,(car srcs)))))

  (define (r:abs dst sc srcs)
    (arity-check! 'rv64-select 1 srcs)
    (if (float? sc)
        `((fsgnjx.d ,dst ,(car srcs) ,(car srcs)))   ; fabs.d
        ;; Integer abs is branchless only with Zbb's `max`, which is above the
        ;; floor, or three instructions with `srai`/`xor`/`sub`. Lmach never
        ;; produces it (flabs is the only abs primitive), so refuse rather than
        ;; carry an untested sequence.
        (error 'rv64-select "integer abs is not in the rv64gc selection scope" dst)))

  (define (r:sqrt dst sc srcs)
    (arity-check! 'rv64-select 1 srcs)
    (unless (float? sc)
      (error 'rv64-select "sqrt on RV64 is a float instruction only" sc))
    `((fsqrt.d ,dst ,(car srcs))))

  (define (r:move dst sc srcs)
    (arity-check! 'rv64-select 1 srcs)
    (if (float? sc)
        `((fsgnj.d ,dst ,(car srcs) ,(car srcs)))    ; fmv.d
        `((addi ,dst ,(car srcs) 0))))               ; mv

  ;; Comparisons. `sc` is read as the OPERAND class; see note 3 at the top.
  ;;
  ;; The float cases are why fl> and fl>= exist separately in lang.ss's prim
  ;; table. `flt.d`/`fle.d` are quiet-NaN-signalling ordered comparisons that
  ;; give 0 for any NaN operand, so swapping the operands gives a correct > and
  ;; >=, while negating the result would give 1 for NaN and be wrong.
  (define (cmp int-seq float-mn swap?)
    (lambda (dst sc srcs)
      (arity-check! 'rv64-select 2 srcs)
      (let ((a (car srcs)) (b (cadr srcs)))
        (if (float? sc)
            (if swap? `((,float-mn ,dst ,b ,a)) `((,float-mn ,dst ,a ,b)))
            (int-seq dst a b)))))

  (define r:cmp-lt (cmp (lambda (d a b) `((slt ,d ,a ,b))) 'flt.d #f))
  (define r:cmp-gt (cmp (lambda (d a b) `((slt ,d ,b ,a))) 'flt.d #t))
  ;; a <= b is not(b < a); a >= b is not(a < b). The xori is the `not`.
  (define r:cmp-le (cmp (lambda (d a b) `((slt ,d ,b ,a) (xori ,d ,d 1))) 'fle.d #f))
  (define r:cmp-ge (cmp (lambda (d a b) `((slt ,d ,a ,b) (xori ,d ,d 1))) 'fle.d #t))
  ;; seqz of the difference. `sub`+`sltiu` would work equally; `xor` avoids any
  ;; question about overflow in the subtraction.
  (define r:cmp-eq (cmp (lambda (d a b) `((xor ,d ,a ,b) (sltiu ,d ,d 1))) 'feq.d #f))

  ;; (load dst sc base idx). idx is an ELEMENT index; the scale is implied by
  ;; the class, per fixtures.ss: "The scale on the load is 8 because an f64 is 8
  ;; bytes, and that is a machine-independent fact both ISAs share."
  ;; A vector's length lives in its header, one word before the element data,
  ;; which is the layout numeric.ss's tagging implies and gc.ss's collector
  ;; walks. One load at a constant offset.
  (define (r:vlen dst sc srcs)
    (arity-check! 'rv64-select 1 srcs)
    ;; The length word. The displacement absorbs both the header offset and the
    ;; pointer tag (numeric.ss): a pointer is tagged and nothing strips it.
    `((ld ,dst ,(car srcs) ,heap-length-disp)))

  (define (r:load dst sc srcs)
    (arity-check! 'rv64-select 2 srcs)
    (let ((t (rv64-addr-scratch)) (base (car srcs)) (idx (cadr srcs)))
      (append (address-into t base idx sc)
              (if (float? sc)
                  `((fld ,dst ,t ,heap-element-disp))
                  `((ld ,dst ,t ,heap-element-disp))))))

  ;; The same, at a constant ELEMENT offset. RV64 has one addressing mode --
  ;; register plus a 12-bit signed immediate -- and the tag adjustment already
  ;; rides in that immediate, so the offset folds into it for free as long as it
  ;; fits. It always does here: the offsets are small component indices, and a
  ;; larger one is refused rather than silently truncated.
  (define (offset-disp who d)
    (let ((n (+ heap-element-disp (* d 8))))
      (unless (<= -2048 n 2047)
        (error who "element offset does not fit RV64's 12-bit displacement" d n))
      n))

  (define (r:load-at dst sc srcs)
    (arity-check! 'rv64-select 3 srcs)
    (let ((t (rv64-addr-scratch)) (d (car srcs))
          (base (cadr srcs)) (idx (caddr srcs)))
      (append (address-into t base idx sc)
              (let ((n (offset-disp 'rv64-select d)))
                (if (float? sc) `((fld ,dst ,t ,n)) `((ld ,dst ,t ,n)))))))

  (define (r:store-at dst sc srcs)
    (arity-check! 'rv64-select 4 srcs)
    (let ((t (rv64-addr-scratch)) (d (car srcs))
          (base (cadr srcs)) (idx (caddr srcs)) (val (cadddr srcs)))
      (append (address-into t base idx sc)
              (let ((n (offset-disp 'rv64-select d)))
                (if (float? sc) `((fsd ,val ,t ,n)) `((sd ,val ,t ,n)))))))

  ;; Adding a constant. RV64 spells it directly and three-address, so this is
  ;; the one selection rule in this file that is a single instruction with
  ;; nothing to arrange around it.
  ;;
  ;; The range is the I-type's 12-bit signed field. Outside it the constant has
  ;; to be built in a register, which is exactly the instruction the pass that
  ;; produced `add-imm` was removing -- so it refuses rather than silently
  ;; emitting a truncated offset.
  (define (r:add-imm dst sc srcs)
    (arity-check! 'rv64-select 2 srcs)
    (let ((d (car srcs)) (src (cadr srcs)))
      (unless (and (exact? d) (integer? d) (<= -2048 d 2047))
        (error 'rv64-select "add-imm constant does not fit an I-type field" d))
      `((addi ,dst ,src ,d))))

  ;; Multiplying by a constant. RV64 has no multiply-immediate, so the constant
  ;; has to be built -- which is exactly the instruction the pass that produced
  ;; `mul-imm` removed. Nothing is lost: it goes into the reserved address
  ;; scratch instead of into an allocatable register, so the saving is the
  ;; REGISTER, which is what the pass was after, and the instruction count is
  ;; unchanged.
  (define (r:mul-imm dst sc srcs)
    (arity-check! 'rv64-select 2 srcs)
    (let ((d (car srcs)) (src (cadr srcs)) (t (rv64-addr-scratch)))
      (unless (and (exact? d) (integer? d) (<= -2048 d 2047))
        (error 'rv64-select "mul-imm constant does not fit an I-type field" d))
      `((addi ,t zero ,d)
        (mul ,dst ,src ,t))))

  ;; (store <unused> sc base idx val). Lmach's `(op v sc v* ...)` makes the
  ;; destination slot mandatory even for an op with no result, and `store-mach`
  ;; in sonic/src/sonic/fixtures.ss PINS that slot as unused with the base, the
  ;; index and the value all riding in the sources: `live-intervals` reads the
  ;; destination slot as a DEFINITION, so putting a live operand there would
  ;; shorten its range and miscompile.
  ;;
  ;; This rule used to read the base out of the destination slot, which is the
  ;; opposite convention and disagreed with both the fixture and the x86-64
  ;; table. It survived because nothing had ever selected a lowered store: the
  ;; RV64 selector died on the call sequence first.
  (define (r:store dst sc srcs)
    (arity-check! 'rv64-select 3 srcs)
    (let ((t (rv64-addr-scratch))
          (base (car srcs)) (idx (cadr srcs)) (val (caddr srcs)))
      (append (address-into t base idx sc)
              (if (float? sc)
                  `((fsd ,val ,t ,heap-element-disp))
                  `((sd ,val ,t ,heap-element-disp))))))

  ;; A top-level binding's cell. RV64 has no absolute addressing, so the
  ;; address is materialised with lui/addi and then loaded through -- three
  ;; instructions where x86-64 needs one, for the same reason indexed loads cost
  ;; three: the ISA has one addressing mode and it is register plus a 12-bit
  ;; immediate.
  ;;
  ;; The +#x800 is the carry correction, as in `r:const`: addi sign-extends its
  ;; 12 bits, so a low half above #x7ff borrows one from the high half.
  (define (rv64-address-of name t)
    (let* ((a (global-address name))
           (lo (- (bitwise-and (+ a #x800) #xfff) #x800))
           (hi (bitwise-and (ash (- a lo) -12) #xfffff)))
      (if (zero? lo)
          `((lui ,t ,hi))
          `((lui ,t ,hi) (addi ,t ,t ,lo)))))

  (define (r:gref dst sc srcs)
    (let ((t (rv64-addr-scratch)))
      (append (rv64-address-of (car srcs) t)
              (if (float? sc) `((fld ,dst ,t 0)) `((ld ,dst ,t 0))))))

  (define (r:gset dst sc srcs)
    (let ((t (rv64-addr-scratch)))
      (append (rv64-address-of (car srcs) t)
              (if (float? sc) `((fsd ,dst ,t 0)) `((sd ,dst ,t 0))))))

  ;; --- control --------------------------------------------------------------
  ;; Reached from `select-block` with dst and sc both #f.

  (define (r:jump dst sc srcs)
    (arity-check! 'rv64-select 1 srcs)
    `((jal zero ,(car srcs))))

  ;; RISC-V has no condition codes, so the test and the branch are one
  ;; instruction. The false edge is an explicit jump: block layout that would
  ;; make it a fallthrough is E4's, and eliding it here would emit wrong code
  ;; for any layout that does not happen to place lbl1 next.
  (define (r:branch-if dst sc srcs)
    (arity-check! 'rv64-select 3 srcs)
    `((bne ,(car srcs) zero ,(cadr srcs))
      (jal zero ,(caddr srcs))))

  ;; The returned value has to reach the return register, and the class decides
  ;; which -- a0 or fa0. Lmach's `(ret v)` carries no storage class, which is
  ;; why this used to emit a bare return and leave the move to "a calling
  ;; convention pass". There is no such pass, so every function returned
  ;; whatever was already in a0.
  (define (r:ret dst sc srcs)
    (if (null? srcs)
        `((jalr zero ra 0))
        (let* ((v (car srcs)) (c (vreg-class v)))
          (unless c
            (error 'rv64-select
                   "the returned vreg has no storage class, so nothing says whether it goes to a0 or fa0"
                   v))
          (if (eq? c 'raw-f64)
              `((fsgnj.d ,(return-register callconv-rv64 c) ,v ,v)
                (jalr zero ra 0))
              `((addi ,(return-register callconv-rv64 c) ,v 0)
                (jalr zero ra 0))))))

  ;; --- calls ----------------------------------------------------------------
  ;;
  ;; The convention itself is in sonic/src/sonic/callconv.ss and the sequencing
  ;; in sonic/src/sonic/callseq.ss. All this target contributes is how to spell
  ;; a move, a store into the outgoing area, a call and a jump -- which is the
  ;; whole of what is RV64-specific about a call.
  ;;
  ;; `jal ra, target` rather than `jalr ra, rs, 0`: the callee slot of an Lmach
  ;; call holds a block label in every program lower.ss produces, and a label in
  ;; a register operand is not a thing the encoder can spell. Indirect calls
  ;; through a closure are a later bead and will need the callee's class, which
  ;; the same class map that types the arguments already has.
  ;;
  ;; The outgoing stack area is addressed from sp with an 8-byte word, because
  ;; every storage class this compiler has is 8 bytes wide (`class-scale`).
  (define rv64-call-emitter
    (make-call-emitter
     'rv64
     (lambda (sc reg src)
       (if (float? sc) `((fsgnj.d ,reg ,src ,src)) `((addi ,reg ,src 0))))
     (lambda (sc slot src)
       (let ((off (* (class-scale sc) slot)))
         (if (float? sc) `((fsd ,src sp ,off)) `((sd ,src sp ,off)))))
     (lambda (callee) `((jal ra ,callee)))
     (lambda (callee) `((jal zero ,callee)))
     ;; A tail call writes the caller's own incoming argument area -- see
     ;; callseq.ss. The offset depends on the caller's frame size, so it is
     ;; symbolic here and finalize.ss substitutes the number. RV64 spells a
     ;; store's offset as a bare field rather than inside a memory operand, so
     ;; the marker sits where the integer would.
     (lambda (sc slot src)
       (if (float? sc) `((fsd ,src sp (incoming ,slot))) `((sd ,src sp (incoming ,slot)))))))

  (define (r:call dst sc srcs)
    (call-sequence callconv-rv64 rv64-call-emitter dst sc srcs))

  ;; A block whose last instruction is a call and whose transfer returns that
  ;; call's result. select.ss finds the shape; this says what it becomes: a
  ;; jump, with no return address pushed and the caller's frame reused.
  (define (r:tailcall dst sc srcs)
    (tail-call-sequence callconv-rv64 rv64-call-emitter dst sc srcs))

  ;; --- checks ---------------------------------------------------------------

  (define (bounds-check-seq idx limit)
    ;; ONE unsigned compare, not two signed ones. A negative index read as
    ;; unsigned is enormous, so it fails the same test the too-large index
    ;; fails. This is the standard trick and it halves the fast-path cost.
    `((bgeu ,idx ,limit ,(rv64-trap-label 'bounds-check))))

  ;; Operands are (a b sum), matching what lower.ss emits: the check is a
  ;; POSTcondition, so the sum is the operation's own destination and comes
  ;; last. This used to read them as (sum a b), which computed
  ;; ((b^a)&(sum^a))<0 -- a test with no meaning. x86-64 was unaffected because
  ;; it reads the flags and ignores the operands entirely, which is exactly why
  ;; the disagreement could sit here undetected.
  (define (overflow-check-seq a b sum)
    ;; No flags register: see note 2 at the top. Signed addition overflowed iff
    ;; both operands differ in sign from the result, i.e.
    ;;   ((a ^ sum) & (b ^ sum)) < 0
    ;; which is four instructions and two scratches against x86-64's one `jo`.
    (let* ((s (rv64-overflow-scratch)) (t0 (car s)) (t1 (cadr s)))
      `((xor ,t0 ,a ,sum)
        (xor ,t1 ,b ,sum)
        (and ,t0 ,t0 ,t1)
        (blt ,t0 zero ,(rv64-trap-label 'overflow-check)))))

  (define (emit-check who name srcs tag)
    (case name
      ((bounds-check)
       (arity-check! who 2 srcs)
       (bounds-check-seq (car srcs) (cadr srcs)))
      ((overflow-check)
       (arity-check! who 3 srcs)
       (overflow-check-seq (car srcs) (cadr srcs) (caddr srcs)))
      ((type-check)
       ;; Lmach's chk NOW carries the expected tag, so this is selectable:
       ;; mask the primary tag out of the value and compare it against the
       ;; constant. numeric.ss fixes a 3-bit primary tag with fixnum = 000.
       (unless (= (length srcs) 1)
         (error who "type check expects one value" srcs))
       (let ((v (car srcs)))
         `((andi t0 ,v 7)
           (addi t1 zero ,tag)
           (bne t0 t1 %type-error))))
      (else (error who "no RV64 sequence for this check" name))))

  ;; (chk pn c v* ...) arrives as dst = pn, sc = c. select-instr already refuses
  ;; `proved`, so only checked and unchecked reach here.
  ;; srcs is (expected-tag operand ...). Lmach's chk now carries the tag, so a
  ;; type check finally has a constant to compare against.
  (define (r:chk pn c srcs)
    (let ((tag (car srcs)) (ops (cdr srcs)))
      (case c
        ((unchecked) '())  ; the policy suppressed it; emitting it would be wrong
        ((checked)   (emit-check 'rv64-select pn ops tag))
        (else (error 'rv64-select "unexpected control on a chk" c)))))

  (define rv64-rules
    (list
     (cons 'const  r:const)
     (cons 'add    (binop 'add 'fadd.d))
     (cons 'sub    (binop 'sub 'fsub.d))
     (cons 'mul    (binop 'mul 'fmul.d))
     (cons 'div    (binop 'div 'fdiv.d))
     (cons 'neg    r:neg)
     (cons 'sqrt   r:sqrt)
     (cons 'abs    r:abs)
     (cons 'cmp-lt r:cmp-lt)
     (cons 'cmp-le r:cmp-le)
     (cons 'cmp-eq r:cmp-eq)
     (cons 'cmp-ge r:cmp-ge)
     (cons 'cmp-gt r:cmp-gt)
          ;; D24 contraction. RV64 has three-address fused forms natively:
     ;; `fmadd.d rd, rs1, rs2, rs3` is rs1*rs2 + rs3 and `fnmsub.d` is
     ;; rs3 - rs1*rs2, so unlike x86-64 neither needs the addend moved into the
     ;; destination first.
     (cons 'fma
           (lambda (dst sc srcs)
             (unless (= (length srcs) 3)
               (error 'rv64-selector "fma expects a, b and the addend" srcs))
             `((fmadd.d ,dst ,(car srcs) ,(cadr srcs) ,(caddr srcs)))))
     (cons 'fnma
           (lambda (dst sc srcs)
             (unless (= (length srcs) 3)
               (error 'rv64-selector "fnma expects a, b and the addend" srcs))
             `((fnmsub.d ,dst ,(car srcs) ,(cadr srcs) ,(caddr srcs)))))
     ;; RV64's fused forms are three-address, so the destination is free and
     ;; the 132/231 distinction does not exist. Both spellings lower the same.
     (cons 'fma132
           (lambda (dst sc srcs)
             (unless (= (length srcs) 2)
               (error 'rv64-selector "fma132 expects the other factor and the addend" srcs))
             `((fmadd.d ,dst ,dst ,(car srcs) ,(cadr srcs)))))
     (cons 'fnma132
           (lambda (dst sc srcs)
             (unless (= (length srcs) 2)
               (error 'rv64-selector "fnma132 expects the other factor and the addend" srcs))
             `((fnmsub.d ,dst ,dst ,(car srcs) ,(cadr srcs)))))
     (cons 'vlen   r:vlen)
     (cons 'load     r:load)
     (cons 'store    r:store)
     (cons 'load-at  r:load-at)
     (cons 'store-at r:store-at)
     (cons 'add-imm  r:add-imm)
     (cons 'mul-imm  r:mul-imm)
     (cons 'move   r:move)
     (cons 'branch    r:jump)
     (cons 'branch-if r:branch-if)
     (cons 'jump      r:jump)
     (cons 'call     r:call)
     ;; Not a mach-op: `tailcall` is a rule name the framework asks for when it
     ;; recognises the shape, so `missing-rules` neither demands it nor reports
     ;; it. See `tail-call-instr` in sonic/src/sonic/select.ss.
     (cons 'tailcall r:tailcall)
     (cons 'ret    r:ret)
     ;; int -> double. `fcvt.d.l` was encodable long before anything could
     ;; select it; see the note at the top of this file.
     (cons 'cvt-f64-from-int
           (lambda (dst sc srcs) `((fcvt.d.l ,dst ,(car srcs)))))
     (cons 'chk    r:chk)
     (cons 'gref   r:gref)
     (cons 'gset   r:gset)
     ))

  (define rv64-selector (make-selector 'rv64 rv64-rules arch-rv64))
  )
