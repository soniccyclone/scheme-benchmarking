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
          rv64-trap-label rv64-call-emitter)
  (import (chezscheme)
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

  (define (r:const dst sc srcs)
    (let ((d (car srcs)))
      (cond
       ((float? sc)
        ;; Two routes exist and both need something selection cannot produce.
        ;; A literal pool plus `fld` needs a pool and a pc-relative `auipc`
        ;; anchor; `fmv.d.x` needs the 64-bit pattern materialized in an
        ;; integer register first, which is a second destination register. Both
        ;; are decisions above this file's pay grade, so we refuse rather than
        ;; guess. `fmv.d.x` and `fcvt.d.l` are encodable regardless, because
        ;; the encoder's job is the ISA and not the calling sequence.
        (error 'rv64-select
               "a flonum constant needs a literal pool or a second (integer) destination register, and an Lmach `const` gives selection neither"
               dst d))
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
  (define (r:load dst sc srcs)
    (arity-check! 'rv64-select 2 srcs)
    (let ((t (rv64-addr-scratch)) (base (car srcs)) (idx (cadr srcs)))
      (append (address-into t base idx sc)
              (if (float? sc)
                  `((fld ,dst ,t 0))
                  `((ld ,dst ,t 0))))))

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
                  `((fsd ,val ,t 0))
                  `((sd ,val ,t 0))))))

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

  (define (r:ret dst sc srcs)
    ;; See note 4 at the top: no class for the returned vreg, so no move.
    `((jalr zero ra 0)))

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
     (lambda (callee) `((jal zero ,callee)))))

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

  (define (overflow-check-seq sum a b)
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

  ;; The same three checks also exist as mach-ops.
  (define (check-op name)
    ;; The mach-op spelling. Unlike `chk` these carry no expected tag, because a
    ;; mach-op check-bounds has no operand to put one in, so type-check through
    ;; this path passes 0 and emit-check refuses it rather than guessing.
    (lambda (dst sc srcs) (emit-check 'rv64-select name srcs 0)))

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
     (cons 'load   r:load)
     (cons 'store  r:store)
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
     (cons 'chk    r:chk)
     (cons 'check-bounds   (check-op 'bounds-check))
     (cons 'check-type     (check-op 'type-check))
     (cons 'check-overflow (check-op 'overflow-check))))

  (define rv64-selector (make-selector 'rv64 rv64-rules arch-rv64))
  )
