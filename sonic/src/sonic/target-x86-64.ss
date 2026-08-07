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
;;; save the copy. It does not set flags. `check-overflow` is a separate Lmach op
;;; that reads the flags the preceding arithmetic left, so selecting `lea` here
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
  (export x86-64-selector x86-64-rules)
  (import (chezscheme)
          (sonic select)
          (sonic regs))

  ;; Every Lmach storage class is eight bytes wide on x86-64, so the scale on an
  ;; indexed access is 8 regardless of class. That is the machine-independent
  ;; fact fixtures.ss notes on the load: an f64 is 8 bytes, and so is a tagged
  ;; word and so is a raw word.
  (define word-scale 8)

  (define (fp? sc) (eq? sc 'raw-f64))

  (define (mov-for sc) (if (fp? sc) 'movsd 'mov))

  (define (mem base index) `(mem ,base ,index ,word-scale 0))

  ;; --- the three-address to two-address rewrite -----------------------------

  (define (two-address who mn sc dst a b commutative?)
    (let ((mv (mov-for sc)))
      (cond
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
       (unless (= (length srcs) 2)
         (error 'x86-64-selector "type check expects a value and a tag" srcs))
       `((cmp ,(car srcs) ,(cadr srcs)) (jne (label sonic-type-error))))
      ((div-check)
       (unless (= (length srcs) 1)
         (error 'x86-64-selector "division check expects a divisor" srcs))
       `((cmp ,(car srcs) (imm 0)) (je (label sonic-div-error))))
      ((overflow-check)
       ;; Reads the flags the preceding arithmetic left. Nothing may be selected
       ;; between them that writes flags, which is why `add` is not `lea`.
       `((jo (label sonic-overflow-error))))
      (else (error 'x86-64-selector "no rule for this check" pn))))

  ;; --- the rule table -------------------------------------------------------

  (define x86-64-rules
    (list
     ;; `const` takes a datum where every other op takes vregs.
     (cons 'const
           (lambda (dst sc srcs)
             (let ((d (car srcs)))
               (when (fp? sc)
                 (error 'x86-64-selector
                        "an f64 literal needs a constant pool, which does not exist yet"
                        dst d))
               (unless (and (integer? d) (exact? d))
                 (error 'x86-64-selector "only exact integer literals are selectable" d))
               `((mov ,dst (imm ,d))))))

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

     (cons 'neg
           (lambda (dst sc srcs)
             (when (fp? sc)
               ;; Not `(sub 0.0 x)`: those disagree at x = 0.0, and lang.ss says
               ;; so. True negation is a sign-bit xor against a pooled mask.
               (error 'x86-64-selector
                      "f64 negation needs a pooled sign mask, which does not exist yet"
                      dst))
             (let ((a (car srcs)))
               (if (eq? dst a) `((neg ,dst)) `((mov ,dst ,a) (neg ,dst))))))

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
     (cons 'load
           (lambda (dst sc srcs)
             (let ((addr (case (length srcs)
                           ((1) (mem (car srcs) #f))
                           ((2) (mem (car srcs) (cadr srcs)))
                           (else (error 'x86-64-selector
                                        "load expects a base and an optional index" srcs)))))
               `((,(mov-for sc) ,dst ,addr)))))

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
             `((,(mov-for sc) ,(mem (car srcs) (cadr srcs)) ,(caddr srcs)))))

     (cons 'move
           (lambda (dst sc srcs) `((,(mov-for sc) ,dst ,(car srcs)))))

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

     (cons 'call (lambda (dst sc srcs) `((call (label ,(car srcs))))))

     ;; No move of the result into the return register: the Lmach Transfer
     ;; `(ret v)` carries no storage class, so this rule cannot tell whether the
     ;; value should go to rax or to xmm0. The move belongs to a calling
     ;; convention pass that has the function's signature.
     (cons 'ret (lambda (dst sc srcs) `((ret))))

     ;; The mach-op spelling of a check. `chk` is the one lower.ss emits, and it
     ;; carries the expected tag; these do not, because the tag is only
     ;; meaningful for a type check and a mach-op check-bounds has no operand to
     ;; put it in. So they pass 0 and check-type via this path is refused by
     ;; check-rule rather than guessing a tag.
     (cons 'check-bounds   (lambda (dst sc srcs) (check-rule 'bounds-check srcs 0)))
     (cons 'check-type     (lambda (dst sc srcs) (check-rule 'type-check srcs 0)))
     (cons 'check-overflow (lambda (dst sc srcs) (check-rule 'overflow-check srcs 0)))

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
