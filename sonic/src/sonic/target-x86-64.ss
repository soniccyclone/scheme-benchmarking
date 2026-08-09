;;; x86-64 instruction selection.
;;;
;;; E2-X86SEL. A `selector` for the target-parametric framework in
;;; sonic/src/sonic/select.ss: a name, a rule table from Lmach op to a procedure
;;; `(lambda (dst sc srcs) -> list of target instructions)`, and the register
;;; partition it enforces.
;;;
;;; Scoped to what the benchmarks need. `nbody-inner-mach` in
;;; sonic/src/sonic/fixtures.ss is the acceptance criterion, and everything past
;;; the arithmetic, memory and control subset is on the path to no milestone.
;;;
;;; ## The one real fight: three operands versus two
;;;
;;; Lmach is three-address, `(op dst sc src1 src2)`, because RV64 is and because
;;; a machine-independent IR should not carry one ISA's register pressure. Every
;;; x86-64 ALU and SSE arithmetic instruction is two-address and DESTRUCTIVE:
;;; `addsd` computes `dst := dst + src`. So each Lmach arithmetic op becomes a
;;; copy plus an operate, and the copy is not always insertable:
;;;
;;;   dst = src1            the copy is dead; emit the operate alone.
;;;   dst = src2, op comm.  swap the operands; emit the operate alone.
;;;   dst = src2, integer   `sub dst, src1` then `neg dst` gets the sign back.
;;;   dst = src2, subsd/divsd
;;;                         nothing works without a scratch register, and this
;;;                         pass has none to give: the partition in
;;;                         sonic/src/sonic/regs.ss is fully spoken for and
;;;                         inventing a vreg here would be invisible to the
;;;                         allocator, which runs over Lmach and never sees
;;;                         selected output. So we refuse loudly. The right home
;;;                         for this is a two-address fixup pass between
;;;                         selection and allocation, which x86-64 needs and
;;;                         RV64 will not.
;;;
;;; ## Why not `lea` for `add`
;;;
;;; `lea dst, [a + b]` is a genuine three-operand non-destructive add and would
;;; save the copy. It does not set flags. An overflow `chk` reads the flags the
;;; preceding arithmetic left, so selecting `lea` here
;;; would silently make every overflow check downstream test stale flags. One
;;; instruction is not worth a wrong-code bug, so `add` is spelled `mov` + `add`
;;; and `lea`'s addressing machinery is used where it is actually free: folded
;;; into the memory operand of `load` and `store`.
;;;
;;; ## Deliberate omissions
;;;
;;; `abs` has no rule, so `missing-rules` reports it rather than a rule raising
;;; at selection time. That is the framework's design: a port in progress states
;;; what it still owes. f64 `abs` and f64 `neg` both need a 16-byte sign mask
;;; from a constant pool, and there is no constant pool yet; the same is true of
;;; an f64 `const`. Integer `div` needs the rdx:rax pair that `idiv` hardwires,
;;; which is a fight with the partition rather than an encoding problem.

(library (sonic target-x86-64)
  (export x86-64-selector x86-64-rules x86-64-call-emitter)
  (import (chezscheme)
          (sonic select)
          (sonic litpool)
          (sonic numeric)
          (sonic callconv)
          (sonic callseq)
          (sonic regs))

  ;; Every Lmach storage class is eight bytes wide on x86-64, so the scale on an
  ;; indexed access is 8 regardless of class. That is the machine-independent
  ;; fact fixtures.ss notes on the load: an f64 is 8 bytes, and so is a tagged
  ;; word and so is a raw word.
  (define word-scale 8)

  (define (fp? sc) (eq? sc 'raw-f64))

  (define (mov-for sc) (if (fp? sc) 'movsd 'mov))

  (define (mem base index) `(mem ,base ,index ,word-scale 0))
  ;; Same addressing mode with a constant displacement and no index, for header
  ;; fields at a fixed negative offset from the element data.
  (define (mem-disp base disp) `(mem ,base #f ,word-scale ,disp))
  (define (mem/disp base index disp) `(mem ,base ,index ,word-scale ,disp))

  ;; --- the three-address to two-address rewrite -----------------------------

  ;; The THREE-ADDRESS counterpart of each destructive float op, when one
  ;; exists. See (sonic vex): `vmulsd d, a, b` is the same multiply as
  ;; `movsd d, a` + `mulsd d, b` -- same operands, same rounding, same bits --
  ;; encoded so the destination need not be one of the inputs.
  ;;
  ;; It is not contraction. `vfmadd*` is, and the encoder still refuses that by
  ;; name, which is the line D24 draws.
  (define three-address-fp
    '((addsd . vaddsd) (subsd . vsubsd) (mulsd . vmulsd) (divsd . vdivsd)))

  (define (two-address who mn sc dst a b commutative?)
    (let ((mv (mov-for sc))
          (v3 (assq mn three-address-fp)))
      (cond
       ;; ONE INSTRUCTION, in every case, when the op has a three-address form.
       ;;
       ;; This is where the fixup move came from: in SSA the destination is a
       ;; fresh name, so it aliases neither source, and the two-address form
       ;; below has to stand the left operand up in it first. nbody's pairwise
       ;; force loop paid that 29 times in 119 instructions.
       ;;
       ;; It also removes the case that had no instruction-local answer at all.
       ;; `dst = b` for a non-commutative op used to need a scratch register a
       ;; selection rule cannot ask for; `vsubsd d, a, b` reads both sources
       ;; before it writes, so d aliasing b is simply fine.
       (v3 `((,(cdr v3) ,dst ,a ,b)))
       ((eq? dst a) `((,mn ,dst ,b)))
       ((eq? dst b)
        (cond
         (commutative? `((,mn ,dst ,a)))
         ;; a - b with the result register already holding b: compute b - a in
         ;; place and negate. Exact for two's complement, including the most
         ;; negative value, where it traps the same way the direct form would.
         ((eq? mn 'sub) `((sub ,dst ,a) (neg ,dst)))
         (else
          (error who
                 (string-append
                  "x86-64's two-address form cannot express this without a scratch "
                  "register: the destination already holds the second operand of a "
                  "non-commutative op. A two-address fixup pass between selection "
                  "and register allocation is the right place to break this")
                 mn dst a b))))
       (else `((,mv ,dst ,a) (,mn ,dst ,b))))))

  ;; A packed-pair binary op. Three-address, so no copy is ever needed.
  (define (packed mn)
    (lambda (dst sc srcs)
      (unless (= (length srcs) 2)
        (error 'x86-64-selector "a packed pair op expects two sources" mn srcs))
      `((,mn ,dst ,(car srcs) ,(cadr srcs)))))

  (define (arith who int-mn fp-mn commutative?)
    (lambda (dst sc srcs)
      (unless (= (length srcs) 2)
        (error who "expects two source operands" dst srcs))
      (let ((a (car srcs)) (b (cadr srcs)))
        (two-address who (if (fp? sc) fp-mn int-mn) sc dst a b commutative?))))

  ;; --- comparisons ----------------------------------------------------------
  ;;
  ;; Lmach names the comparison's result as a vreg, so the flags cannot stay in
  ;; the flags register: `branch-if` is a separate instruction and anything at
  ;; all may sit between them. The correct instruction-local lowering is
  ;; therefore compare, materialise with setcc, zero-extend. Fusing the compare
  ;; into the branch is a peephole over the selected stream, not something a
  ;; per-instruction rule table can see.
  ;;
  ;; These are the SIGNED forms, which is right for fixnums. A flonum comparison
  ;; needs `ucomisd` and the unsigned setcc forms, and it is NOT selectable here:
  ;; the `sc` a rule receives is the class of the comparison's BOOLEAN result,
  ;; not of its operands, so Lmach as it stands does not say whether `cmp-lt`
  ;; compares two fixnums or two flonums.

  (define setcc-for
    '((cmp-lt . setl) (cmp-le . setle) (cmp-eq . sete)
      (cmp-ge . setge) (cmp-gt . setg)))

  (define (compare op)
    (lambda (dst sc srcs)
      (unless (= (length srcs) 2)
        (error 'x86-64-selector "comparison expects two source operands" op srcs))
      (when (fp? sc)
        (error 'x86-64-selector
               "a comparison result cannot live in an SSE register" op dst))
      `((cmp ,(car srcs) ,(cadr srcs))
        (,(cdr (assq op setcc-for)) ,dst)
        (movzx ,dst ,dst))))

  ;; --- checks ---------------------------------------------------------------
  ;; A check that survived the analysis. It branches to a runtime trap; the trap
  ;; labels are resolved with everything else.

  (define (check-rule pn srcs tag)
    (case pn
      ((bounds-check)
       (unless (= (length srcs) 2)
         (error 'x86-64-selector "bounds check expects an index and a limit" srcs))
       `((cmp ,(car srcs) ,(cadr srcs)) (jge (label sonic-bounds-error))))
      ((type-check)
       ;; Lmach's `chk` carries the expected tag as a field, so the tag arrives
       ;; in `tag` and NOT as a second source. This rule used to read it out of
       ;; srcs, which is the shape from before that field existed; it survived
       ;; because no test ever selected a type check with the current lowering.
       ;;
       ;; `and` is destructive, so the mask goes through the scratch register
       ;; rather than clobbering the value being checked. rax is reserved
       ;; outside every allocatable pool for exactly this (regs.ss).
       (unless (= (length srcs) 1)
         (error 'x86-64-selector "type check expects one value" srcs))
       `((mov rax ,(car srcs))
         (and rax (imm 7))
         (cmp rax (imm ,tag))
         (jne (label sonic-type-error))))
      ((div-check)
       (unless (= (length srcs) 1)
         (error 'x86-64-selector "division check expects a divisor" srcs))
       `((cmp ,(car srcs) (imm 0)) (je (label sonic-div-error))))
      ((overflow-check)
       ;; Reads the flags the preceding arithmetic left. Nothing may be selected
       ;; between them that writes flags, which is why `add` is not `lea`.
       `((jo (label sonic-overflow-error))))
      (else (error 'x86-64-selector "no rule for this check" pn))))

  ;; --- calls ----------------------------------------------------------------
  ;;
  ;; The convention is sonic/src/sonic/callconv.ss's and the sequencing is
  ;; sonic/src/sonic/callseq.ss's. This target contributes only the spelling.
  ;;
  ;; Four tagged argument registers, against RV64's eight, is the honest
  ;; consequence of an eight-register value class on a machine with sixteen
  ;; GPRs; overflow goes to the outgoing area at [rsp + 8*slot]. The scale is 8
  ;; because every storage class here is a machine word wide.
  (define x86-64-call-emitter
    (make-call-emitter
     'x86-64
     (lambda (sc reg src) `((,(mov-for sc) ,reg ,src)))
     (lambda (sc slot src)
       `((,(mov-for sc) (mem rsp #f ,word-scale ,(* word-scale slot)) ,src)))
     (lambda (callee) `((call (label ,callee))))
     (lambda (callee) `((jmp (label ,callee))))
     ;; A tail call's outgoing area IS the caller's incoming one. The
     ;; displacement is symbolic because it depends on the caller's frame size,
     ;; which is not known until finalize.ss has laid the frame out.
     (lambda (sc slot src)
       `((,(mov-for sc) (mem rsp #f 1 (incoming ,slot)) ,src)))))

  ;; --- the rule table -------------------------------------------------------

  (define x86-64-rules
    (list
     ;; `const` takes a datum where every other op takes vregs.
     (cons 'const
           (lambda (dst sc srcs)
             (let ((d (car srcs)))
               ;; A double has no immediate form on x86-64: there is no
               ;; `movsd xmm, imm64`. It goes in the constant pool and comes
               ;; back RIP-relative, which is ONE instruction here against
               ;; RV64's two, because x86-64 has a PC-relative addressing mode
               ;; and RV64 does not (reloc.ss, header).
               ;;
               ;; The displacement emitted is the pool offset. The linker
               ;; overwrites it from the relocation; writing the offset rather
               ;; than zero keeps an unlinked disassembly readable.
               (cond
                ((fp? sc)
                 (let ((off (pool-intern-f64! (current-litpool) d)))
                   `((movsd ,dst (mem rip #f 1 (label ,(pool-label off)))))))
                ;; The empty list is a real Scheme object, not an immediate --
                ;; see the same case in target-rv64.ss. `r15` holds nil.
                ((null? d) `((mov ,dst ,(arch-register-for arch-x86-64 'nil))))
                ((and (integer? d) (exact? d)) `((mov ,dst (imm ,d))))
                (else
                 (error 'x86-64-selector
                        "only exact integer and flonum literals are selectable" d))))))

     (cons 'add (arith 'x86-64-selector 'add 'addsd #t))
     (cons 'sub (arith 'x86-64-selector 'sub 'subsd #f))
     (cons 'mul (arith 'x86-64-selector 'imul 'mulsd #t))
     (cons 'div
           (lambda (dst sc srcs)
             (unless (fp? sc)
               (error 'x86-64-selector
                      (string-append
                       "integer division needs the rdx:rax pair idiv hardwires, which "
                       "the register partition does not model")
                      dst srcs))
             ((arith 'x86-64-selector 'idiv 'divsd #f) dst sc srcs)))

     ;; f64 negation is a sign-bit XOR against a pooled mask, NOT `(sub 0.0 x)`.
     ;; The two disagree at x = 0.0 and the sign survives a division, which
     ;; bench/nbody/SPEC.md step 0 states as its own first item. Getting this
     ;; wrong would not show up as a crash; it would show up as the last bits of
     ;; the energy, which is what the bit-exact oracle exists to catch.
     ;;
     ;; The mask must be in the destination register, so the operand order is
     ;; `xorpd dst, mask` after moving the value in.
     (cons 'neg
           (lambda (dst sc srcs)
             (let ((a (car srcs)))
               (if (fp? sc)
                   (let ((off (pool-intern-sign-mask! (current-litpool) 'neg)))
                     (if (eq? dst a)
                         `((xorpd ,dst (mem rip #f 1 (label ,(pool-label off)))))
                         `((movsd ,dst ,a)
                           (xorpd ,dst (mem rip #f 1 (label ,(pool-label off)))))))
                   (if (eq? dst a) `((neg ,dst)) `((mov ,dst ,a) (neg ,dst)))))))

     ;; `abs` had no rule at all, so `missing-rules` reported it as owed. Same
     ;; mask machinery, clearing the sign bit rather than flipping it.
     (cons 'abs
           (lambda (dst sc srcs)
             (unless (fp? sc)
               (error 'x86-64-selector
                      "integer abs has no rule; it is a branch or a cmov and neither is written"
                      dst sc))
             (let ((a (car srcs))
                   (off (pool-intern-sign-mask! (current-litpool) 'abs)))
               (if (eq? dst a)
                   `((andpd ,dst (mem rip #f 1 (label ,(pool-label off)))))
                   `((movsd ,dst ,a)
                     (andpd ,dst (mem rip #f 1 (label ,(pool-label off)))))))))

     (cons 'sqrt
           (lambda (dst sc srcs)
             (unless (fp? sc)
               (error 'x86-64-selector "sqrt is defined on f64 only" dst sc))
             ;; The one arithmetic SSE form that is genuinely non-destructive
             ;; for our purposes: it reads only the source's low quadword.
             `((sqrtsd ,dst ,(car srcs)))))

     (cons 'cmp-lt (compare 'cmp-lt))
     (cons 'cmp-le (compare 'cmp-le))
     (cons 'cmp-eq (compare 'cmp-eq))
     (cons 'cmp-ge (compare 'cmp-ge))
     (cons 'cmp-gt (compare 'cmp-gt))

     ;; `(load dst sc base index)` reads `base[index]`, or `(load dst sc base)`
     ;; reads `base[0]`. The scale is 8 because every storage class is a machine
     ;; word wide, and it folds into the addressing mode for free.
     ;; A vector's length lives in its header, one word before the element
     ;; data, which is the layout numeric.ss's tagging implies and gc.ss's
     ;; collector walks. One load at a constant displacement.
     (cons 'vlen
           (lambda (dst sc srcs)
             (unless (= (length srcs) 1)
               (error 'x86-64-selector "vlen expects one vector" srcs))
             ;; The length word, at a displacement that absorbs BOTH the header
             ;; offset and the pointer tag (numeric.ss). A pointer is tagged and
             ;; nothing strips it, so the displacement has to.
             `((mov ,dst ,(mem-disp (car srcs) heap-length-disp)))))

     (cons 'load
           (lambda (dst sc srcs)
             (let ((addr (case (length srcs)
                           ((1) (mem/disp (car srcs) #f heap-element-disp))
                           ((2) (mem/disp (car srcs) (cadr srcs) heap-element-disp))
                           (else (error 'x86-64-selector
                                        "load expects a base and an optional index" srcs)))))
               `((,(mov-for sc) ,dst ,addr)))))

     ;; The same load and store at a constant ELEMENT offset. The offset is in
     ;; elements because Lmach is machine-independent; here it becomes bytes by
     ;; the element scale, and folds into the displacement the tag adjustment
     ;; already uses. Nothing is computed: the address was going to carry a
     ;; displacement anyway.
     (cons 'load-at
           (lambda (dst sc srcs)
             (unless (= (length srcs) 3)
               (error 'x86-64-selector
                      "load-at expects (load-at dst sc d base index)" dst srcs))
             (let ((d (car srcs)) (base (cadr srcs)) (idx (caddr srcs)))
               `((,(mov-for sc) ,dst
                  ,(mem/disp base idx (+ heap-element-disp (* d word-scale))))))))

     (cons 'store-at
           (lambda (dst sc srcs)
             (unless (= (length srcs) 4)
               (error 'x86-64-selector
                      "store-at expects (store-at <unused> sc d base index value)" dst srcs))
             (let ((d (car srcs)) (base (cadr srcs))
                   (idx (caddr srcs)) (val (cadddr srcs)))
               `((,(mov-for sc)
                  ,(mem/disp base idx (+ heap-element-disp (* d word-scale)))
                  ,val)))))

     ;; Adding a constant, with the constant in the instruction.
     ;;
     ;; The whole gain here is that the constant no longer occupies a register.
     ;; The two-address `mov`/`add` is deliberately NOT collapsed into the `lea`
     ;; that computes the same thing in one instruction, even though the encoder
     ;; has it and the peephole emits it.
     ;;
     ;; `lea` cannot address memory for its destination, and `add` can. A
     ;; spilled source together with a spilled destination is two operands to
     ;; serve, and x86-64 reserves ONE integer scratch; `add [rsp+n], k` serves
     ;; that shape and `lea` refuses it outright. Emitting `lea` here took the
     ;; compiler from working to raising on a loop that has nothing to do with
     ;; this optimisation.
     ;;
     ;; Nothing is lost. peephole.ss fuses this exact pair back into `lea` once
     ;; registers are known -- which is the point at which the choice can be
     ;; made on evidence rather than on hope.
     (cons 'add-imm
           (lambda (dst sc srcs)
             (unless (= (length srcs) 2)
               (error 'x86-64-selector
                      "add-imm expects (add-imm dst sc d src)" dst srcs))
             `((mov ,dst ,(cadr srcs))
               (add ,dst (imm ,(car srcs))))))

     ;; Multiplying by a constant. Unlike the add, this one IS emitted in its
     ;; three-address form: x86-64's `imul r, r/m, imm` (opcodes 6B and 69)
     ;; takes its source from memory, so a spilled operand costs the memory
     ;; operand this instruction was not otherwise using rather than a scratch
     ;; the target does not have.
     (cons 'mul-imm
           (lambda (dst sc srcs)
             (unless (= (length srcs) 2)
               (error 'x86-64-selector
                      "mul-imm expects (mul-imm dst sc d src)" dst srcs))
             `((imul ,dst ,(cadr srcs) (imm ,(car srcs))))))

     ;; --- packed pairs -------------------------------------------------------
     ;;
     ;; One 128-bit register holds two doubles, so these are `xmm` operations on
     ;; ordinary raw-f64 vregs. The unaligned move is deliberate: a pair starting
     ;; at an arbitrary element index is 8-byte aligned, not 16, and `movapd`
     ;; FAULTS on that. `vmovupd` costs nothing extra on any machine this
     ;; compiler targets.
     ;;
     ;; The arithmetic is the VEX three-address form for the same reason the
     ;; scalar ops are (D33): the destination need not be a source, which is what
     ;; keeps a pack from needing a copy. `vsubpd` is two independent
     ;; subtractions, lane by lane, so it rounds exactly as the two scalar
     ;; subtractions it replaces -- there is no reassociation and no contraction.
     (cons 'p2load
           (lambda (dst sc srcs)
             (unless (= (length srcs) 3)
               (error 'x86-64-selector "p2load expects (p2load dst sc d base index)" srcs))
             `((vmovupd ,dst ,(mem/disp (cadr srcs) (caddr srcs)
                                        (+ heap-element-disp (* (car srcs) word-scale)))))))
     (cons 'p2store
           (lambda (dst sc srcs)
             (unless (= (length srcs) 4)
               (error 'x86-64-selector
                      "p2store expects (p2store <unused> sc d base index value)" srcs))
             `((vmovupd ,(mem/disp (cadr srcs) (caddr srcs)
                                   (+ heap-element-disp (* (car srcs) word-scale)))
                        ,(cadddr srcs)))))
     (cons 'p2splat
           (lambda (dst sc srcs)
             (unless (= (length srcs) 1)
               (error 'x86-64-selector "p2splat expects one source" srcs))
             `((vmovddup ,dst ,(car srcs)))))
     (cons 'p2pack
           (lambda (dst sc srcs)
             (unless (= (length srcs) 2)
               (error 'x86-64-selector "p2pack expects two sources" srcs))
             `((vunpcklpd ,dst ,(car srcs) ,(cadr srcs)))))
     (cons 'p2hi
           (lambda (dst sc srcs)
             (unless (= (length srcs) 1)
               (error 'x86-64-selector "p2hi expects one source" srcs))
             `((vunpckhpd ,dst ,(car srcs) ,(car srcs)))))
     (cons 'p2add (packed 'vaddpd))
     (cons 'p2sub (packed 'vsubpd))
     (cons 'p2mul (packed 'vmulpd))
     (cons 'p2div (packed 'vdivpd))

     ;; `(store ignored sc base index value)`. Lmach's Instr production makes the
     ;; destination slot mandatory and a store has no result, so the slot is
     ;; dead and the stored value rides in the sources, where the allocator's
     ;; liveness pass will treat it as the USE that it is rather than as a
     ;; definition.
     (cons 'store
           (lambda (dst sc srcs)
             (unless (= (length srcs) 3)
               (error 'x86-64-selector
                      "store expects (store <unused> sc base index value)" dst srcs))
             `((,(mov-for sc)
                ,(mem/disp (car srcs) (cadr srcs) heap-element-disp)
                ,(caddr srcs)))))

     ;; int -> double. `cvtsi2sd` was encodable and byte-verified long before
     ;; anything could select it, which is the shape of gap `missing-rules`
     ;; exists to report.
     (cons 'cvt-f64-from-int
           (lambda (dst sc srcs) `((cvtsi2sd ,dst ,(car srcs)))))

     (cons 'move
           (lambda (dst sc srcs) `((,(mov-for sc) ,dst ,(car srcs)))))

     ;; A top-level binding's cell. Absolute addressing: the cells are in the
     ;; writable segment, megabytes from the code, so a RIP displacement would
     ;; depend on the final layout. `(mem #f ...)` is mod=00 rm=100 with a SIB
     ;; naming no base -- the absolute disp32 form, which is exactly what
     ;; `(mem rip ...)` is NOT (see encode-x86-64.ss).
     (cons 'gref
           (lambda (dst sc srcs)
             `((,(mov-for sc) ,dst (mem #f #f 1 ,(global-address (car srcs)))))))
     (cons 'gset
           (lambda (dst sc srcs)
             `((,(mov-for sc) (mem #f #f 1 ,(global-address (car srcs))) ,dst))))

     (cons 'jump   (lambda (dst sc srcs) `((jmp (label ,(car srcs))))))
     (cons 'branch (lambda (dst sc srcs) `((jmp (label ,(car srcs))))))

     ;; The boolean lives in a register, so test it and branch. `cmp r, 0`
     ;; rather than `test r, r` keeps the selected stream inside the mnemonic
     ;; set the encoder is differentially verified over.
     (cons 'branch-if
           (lambda (dst sc srcs)
             (unless (= (length srcs) 3)
               (error 'x86-64-selector "branch-if expects a value and two labels" srcs))
             `((cmp ,(car srcs) (imm 0))
               (jne (label ,(cadr srcs)))
               (jmp (label ,(caddr srcs))))))

     (cons 'call
           (lambda (dst sc srcs)
             (call-sequence callconv-x86-64 x86-64-call-emitter dst sc srcs)))

     ;; A block whose last instruction is a call and whose transfer returns that
     ;; call's result. select.ss finds the shape; this makes it a jump, so no
     ;; return address is pushed and the caller's frame is reused. Not a rule
     ;; for a mach-op: `missing-rules` neither demands nor reports it.
     (cons 'tailcall
           (lambda (dst sc srcs)
             (tail-call-sequence callconv-x86-64 x86-64-call-emitter dst sc srcs)))

     ;; No move of the result into the return register: the Lmach Transfer
     ;; `(ret v)` carries no storage class, so this rule cannot tell whether the
     ;; value should go to rax or to xmm0. The move belongs to a calling
     ;; convention pass that has the function's signature.
     ;; The returned value has to reach the return register, and the class it
     ;; travels in decides WHICH register -- rax or xmm0. Lmach's `(ret v)`
     ;; carries no storage class, which is why this rule used to emit a bare
     ;; `ret` and leave the move to "a calling convention pass". There is no
     ;; such pass, so every function returned whatever was already in rax.
     ;;
     ;; The class IS available: select-program parameterises
     ;; `current-vreg-classes` over the whole program precisely so a rule can
     ;; ask. A vreg with no class is a bug, not a default, so it raises.
     (cons 'ret
           (lambda (dst sc srcs)
             (if (null? srcs)
                 `((ret))
                 (let* ((v (car srcs)) (c (vreg-class v)))
                   (unless c
                     (error 'x86-64-selector
                            "the returned vreg has no storage class, so nothing says whether it goes to rax or xmm0"
                            v))
                   `((,(mov-for c) ,(return-register callconv-x86-64 c) ,v)
                     (ret))))))

     ;; `(chk pn c v* ...)`: the framework hands the check name as `dst` and the
     ;; control as `sc`. `proved` never arrives; select.ss refuses it upstream.
     ;; `checked` and `unchecked` both do, and they mean opposite things:
     ;; `unchecked` is a check the policy SUPPRESSED, carried this far only so
     ;; the report can count it, so it must emit nothing. Emitting it would
     ;; quietly reinstate a check the programmer switched off, which is the
     ;; whole mechanism D5 exists to give them.
     ;; srcs is (expected-tag operand ...). The tag is meaningful only for
     ;; type-check, where it is the constant the value's tag is compared
     ;; against; every other check passes 0. Splitting it here rather than
     ;; leaving it in the operand list means check-rule keeps the operand
     ;; positions it already documents.
     (cons 'chk
           (lambda (pn c srcs)
             (let ((tag (car srcs)) (ops (cdr srcs)))
               (case c
                 ((unchecked) '())
                 ((checked) (check-rule pn ops tag))
                 (else (error 'x86-64-selector "unexpected check control" pn c))))))))

  (define x86-64-selector
    (make-selector 'x86-64 x86-64-rules arch-x86-64))
  )
