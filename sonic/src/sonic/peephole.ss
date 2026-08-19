;;; Peephole over the selected instruction stream.
;;;
;;; E2-PEEP (bead 6gk.12). Patterns that no per-instruction selection rule can
;;; see, because they span two Lmach instructions.
;;;
;;; ## Why compare-and-branch cannot be fused during selection
;;;
;;; Lmach names a comparison's result as a vreg, and `branch-if` is a separate
;;; instruction with anything at all permitted between them. So the only
;;; correct instruction-local lowering is:
;;;
;;;     cmp a, b        ; set flags
;;;     setl r          ; materialise the boolean
;;;     movzx r, r      ; zero-extend it
;;;     ...             ; anything may appear here
;;;     cmp r, 0        ; test the boolean
;;;     jne target      ; branch on it
;;;
;;; Both target agents reached that shape independently and both flagged it.
;;; When nothing intervenes and the boolean is dead after the branch, five
;;; instructions collapse to two:
;;;
;;;     cmp a, b
;;;     jl target
;;;
;;; That is visible only over the stream, which is what this pass is.
;;;
;;; ## The liveness condition is not optional
;;;
;;; The boolean may be used again — stored, returned, passed. Fusing then would
;;; delete a value someone reads. So the rewrite fires only when the vreg is
;;; dead immediately after the branch, and `last-use?` is the check.

(library (sonic peephole)
  (export peephole fuse-compare-branch
          peephole-stats peephole-stats? peephole-stats-fused)
  (import (chezscheme) (sonic regs))

  (define-record-type (peephole-stats make-peephole-stats peephole-stats?)
    (fields (mutable fused)))

  ;; setcc mnemonic -> the conditional jump testing the same flags.
  ;; Signed forms for integers; the unsigned forms are what a `ucomisd`
  ;; comparison would need, and they are listed so a float path can use the
  ;; same table when it exists.
  (define cc-table
    '((setl . jl) (setle . jle) (sete . je) (setne . jne)
      (setge . jge) (setg . jg)
      ;; unsigned: for ucomisd, where IEEE comparison sets the carry flag
      (setb . jb) (setbe . jbe) (seta . ja) (setae . jae)))

  (define (jump-for setcc)
    (let ((p (assq setcc cc-table))) (and p (cdr p))))

  ;; RV64 needs no fusion pass: its branches ARE compare-and-branch
  ;; (`blt a, b, target`), so the selector emits the fused form directly and
  ;; there is nothing to collapse. This is the mirror of the two-address pass,
  ;; which x86-64 needs and RV64 does not.
  (define (needs-fusion? target)
    (case target
      ((x86-64) #t)
      ((rv64) #f)
      (else (error 'peephole "unknown target" target))))

  ;; Is `v` used anywhere in `rest`?
  (define (used-later? v rest)
    (let loop ((is rest))
      (cond ((null? is) #f)
            ((memq v (cdr (car is))) #t)
            (else (loop (cdr is))))))

  ;; --- reading a register, including through an addressing mode -------------
  ;;
  ;; `used-later?` above asks `(memq v (cdr i))`, which is a SHALLOW test: it
  ;; sees `(mov rax rbx)` and misses `(mov rax (mem rbx rcx 8 16))` entirely.
  ;; That is fine for the pattern it serves, where the operands are known to be
  ;; bare registers, and it is not fine for the two passes below, which delete
  ;; instructions on the strength of the answer. A base register mistaken for
  ;; dead is a deleted definition and a wrong program.
  (define (mentions-reg? x r)
    (cond ((symbol? x) (eq? x r))
          ;; An immediate holds no register, and a label is a name that only
          ;; looks like one.
          ((and (pair? x) (memq (car x) '(imm label))) #f)
          ((pair? x) (or (mentions-reg? (car x) r) (mentions-reg? (cdr x) r)))
          (else #f)))

  ;; Two different questions, and conflating them cost real folds.
  ;;
  ;; `pure-moves` is what this file may DELETE: a copy, and nothing else.
  ;;
  ;; `kills-dst?` is the wider question of which instructions write their first
  ;; operand without reading it, which is what decides whether a value is still
  ;; live. Every three-address VEX form does -- that is what having three
  ;; addresses means -- and so does the three-operand `imul`. Reading a VEX
  ;; destination as a use made `(vmulsd xmm3, xmm0, xmm0)` look like a reader of
  ;; xmm3, so every value whose register was later reused by arithmetic looked
  ;; live forever.
  (define pure-moves '(mov movsd lea movzx vmovupd vmovddup))

  (define three-address '(vaddsd vsubsd vmulsd vdivsd
                          vaddpd vsubpd vmulpd vdivpd
                          vunpcklpd vunpckhpd))

  ;; THE HALF-REGISTER WRITES, which are why this is not just a list of opcodes.
  ;;
  ;; `sqrtsd dst, src` and the REGISTER form of `movsd` write the low 64 bits of
  ;; an xmm and leave the upper 64 alone. They therefore do not kill a value
  ;; living in that register -- half of it survives. `movsd dst, [mem]` is
  ;; different: loading from memory ZEROES the upper half, so it does.
  ;;
  ;; It matters because SLP puts a PAIR in one xmm. Treating a merging write as
  ;; a kill would let a definition whose high lane is still read be deleted, and
  ;; the register allocator's one-value-per-register model is the only thing
  ;; that would have made it unreachable -- which is a property of another pass,
  ;; not an argument this one gets to rely on.
  ;;
  ;; The VEX forms do not have this problem by construction: `vsqrtsd d, a, b`
  ;; takes its upper lane from `a`, so it writes all of `d`.
  (define (kills-dst? i)
    (and (pair? i) (pair? (cdr i)) (symbol? (cadr i))
         (or (and (memq (car i) '(mov lea movzx vmovupd vmovddup))
                  (= (length i) 3))
             ;; movsd kills only when it loads from memory
             (and (eq? (car i) 'movsd) (= (length i) 3)
                  (pair? (caddr i)) (eq? (car (caddr i)) 'mem))
             (and (memq (car i) three-address) (= (length i) 4))
             (and (eq? (car i) 'vsqrtsd) (= (length i) 4))
             ;; two-operand `imul dst, src` READS dst; the three-operand form
             ;; does not.
             (and (eq? (car i) 'imul) (= (length i) 4)))))

  (define (kills? i r)
    (and (kills-dst? i) (eq? (cadr i) r)
         ;; `lea rax, [rax+1]` writes rax and reads it; not a kill.
         (not (mentions-reg? (cddr i) r))))

  (define (reads-reg? i r)
    (and (pair? i)
         (if (kills-dst? i)
             ;; the destination slot is written, not read
             (mentions-reg? (cddr i) r)
             (mentions-reg? (cdr i) r))))

  ;; Anything that leaves the block. A `call` is here because it reads argument
  ;; registers that appear nowhere in its operands, and a branch is here because
  ;; the other path is not in front of us.
  (define (leaves-block? i)
    (and (pair? i)
         (memq (car i) '(call ret jmp syscall
                         jl jle je jne jge jg jb jbe ja jae jo jno))))

  ;; A SCRATCH register is dead at every boundary, and that is a property of the
  ;; register file rather than of this listing. regs.ss keeps the scratches
  ;; outside every allocatable pool precisely so no live range can occupy one,
  ;; and the convention passes no argument in one -- so nothing reads a scratch
  ;; across a call or a branch.
  ;;
  ;; `ret` is the exception and it is not a small one: rax IS the return
  ;; register, so a value there at a `ret` is the function's result.
  (define (scratch-reg? r)
    (and (memq r (arch-scratch arch-x86-64)) #t))

  ;; Is `r` dead from here -- overwritten before it is read, without leaving the
  ;; block? Conservative at every edge: a label means another path arrives here
  ;; and a transfer means we cannot see what reads it, and both answer "no"
  ;; unless the register is a scratch, which nothing can be reading.
  (define (dead-from? r is)
    (let scan ((is is))
      ;; End of the run stays #f, deliberately, even for a scratch. A real run
      ;; always ends at a label or a transfer and both are handled below; only a
      ;; hand-written fixture runs off the end, and widening this to satisfy one
      ;; changes what every other pass in this file deletes.
      (cond ((null? is) #f)
            ((symbol? (car is)) (scratch-reg? r))  ; a label: another path joins
            ((reads-reg? (car is) r) #f)
            ((kills? (car is) r) #t)           ; overwritten, so it was dead
            ((leaves-block? (car is))
             (and (not (eq? (car (car is)) 'ret)) (scratch-reg? r)))
            (else (scan (cdr is))))))

  ;; --- a copy nobody reads --------------------------------------------------
  ;;
  ;;     call inner%24        ->    call inner%24
  ;;     mov  r8, rax              ...
  ;;     ...                       mov  r8, r12
  ;;     mov  r8, r12
  ;;
  ;; A call's result is moved out of the return register whether or not anything
  ;; wants it, because selection names every value including the ones nobody
  ;; reads. nbody's outer loop calls the inner loop for its EFFECT on the
  ;; velocity vectors; the value it returns is nil and is dropped.
  ;;
  ;; Not doable before allocation. The vreg has a live interval there, however
  ;; short, and the allocator gives it a register accordingly; it is only over
  ;; the finished listing that the write is visibly overwritten before any read.
  (define (drop-dead-copies instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((and (pair? (car is)) (memq (car (car is)) pure-moves)
             (= (length (car is)) 3) (symbol? (cadr (car is)))
             (dead-from? (cadr (car is)) (cdr is)))
        (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
        (loop (cdr is) out))
       (else (loop (cdr is) (cons (car is) out))))))

  ;; --- a store that went through the scratch --------------------------------
  ;;
  ;;     mov rax, rcx          ->   mov [rsp+8], rcx
  ;;     mov [rsp+8], rax
  ;;
  ;; The spiller stores a value by way of the scratch register because that is
  ;; the shape that always works. When the value was already in a register it
  ;; did not need to: x86-64 stores a register to memory directly.
  ;;
  ;; SOURCE MUST BE A REGISTER. Folding a memory source would ask for a
  ;; memory-to-memory `mov`, which x86-64 does not have, and the encoder would
  ;; report bad operands somewhere far from here.
  (define (fold-store-through-scratch instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((and (pair? (cdr is))
             (let ((a (car is)) (b (cadr is)))
               (and (pair? a) (memq (car a) pure-moves) (= (length a) 3)
                    (symbol? (cadr a)) (symbol? (caddr a))
                    (pair? b) (eq? (car b) (car a)) (= (length b) 3)
                    (pair? (cadr b)) (eq? (car (cadr b)) 'mem)
                    (eq? (caddr b) (cadr a))
                    ;; the address must not be built out of the scratch
                    (not (mentions-reg? (cadr b) (cadr a)))
                    (dead-from? (cadr a) (cddr is)))))
        (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
        (loop (cddr is)
              (cons (list (car (car is)) (cadr (cadr is)) (caddr (car is))) out)))
       (else (loop (cdr is) (cons (car is) out))))))

  ;; --- a load folded into the arithmetic that reads it ----------------------
  ;;
  ;;     movsd  xmm3, [r8+rdi*8+15]      ->   vsubsd xmm4, xmm1, [r8+rdi*8+15]
  ;;     vsubsd xmm4, xmm1, xmm3
  ;;
  ;; gcc does this at every site; we emitted the load separately because
  ;; selection names every value. A folded load reads the same address and
  ;; produces the same bits, so this is safe under the bit-exact oracle in a way
  ;; that contraction (D24) is not -- nothing is refactored, one instruction
  ;; simply addresses memory that the instruction before it was addressing.
  ;;
  ;; ONLY THE SECOND SOURCE. VEX's first source rides in the prefix's vvvv
  ;; field, which holds a register number and has no memory form; the encoder
  ;; refuses it by name. That halves the hit rate here, because Lmach's
  ;; `(sub d a b)` puts the loaded value in `a` more often than in `b`, and the
  ;; remedy -- swapping the operands of the commutative ops so the load lands
  ;; second -- is exactly commutative for finite values and NOT for NaN
  ;; payloads, which x86 takes from the first source. That is a decision about
  ;; numerics rather than an optimisation, so it is not taken here.
  ;;
  ;; WIDTHS MUST MATCH. Folding an 8-byte `movsd` into a 16-byte packed operand
  ;; would read memory the program never asked for -- possibly off the end of an
  ;; allocation. The pairing is explicit rather than inferred.
  (define vex-scalar-arith '(vaddsd vsubsd vmulsd vdivsd))
  (define vex-packed-arith '(vaddpd vsubpd vmulpd vdivpd))

  ;; COMMUTATIVE, so a load feeding the FIRST source can be swapped into the
  ;; second and folded there. Lmach's `(sub d a b)` puts the loaded value in `a`
  ;; more often than in `b`, so without this most loads cannot fold at all.
  ;;
  ;; a+b and a*b are identical to b+a and b*a for every finite value, every
  ;; zero, and every infinity. The one thing that changes is which NaN PAYLOAD
  ;; propagates when both operands are NaN: x86 takes the first source's. That
  ;; is a real difference and differential.ss compares flonums by bit pattern
  ;; precisely so that it "extends to NaN payloads", so this is not waved away
  ;; -- it is put in front of that oracle and kept only because the oracle
  ;; passes.
  (define commutative '(vaddsd vmulsd vaddpd vmulpd))

  (define (fold-load-into-arith instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((and (pair? (cdr is))
             (let ((a (car is)) (b (cadr is)))
               (and (pair? a) (= (length a) 3) (symbol? (cadr a))
                    (pair? (caddr a)) (eq? (car (caddr a)) 'mem)
                    (pair? b) (= (length b) 4)
                    (or (and (eq? (car a) 'movsd)   (memq (car b) vex-scalar-arith))
                        (and (eq? (car a) 'vmovupd) (memq (car b) vex-packed-arith)))
                    ;; the loaded register is a source, and not BOTH sources
                    (or (eq? (list-ref b 3) (cadr a))
                        (and (eq? (list-ref b 2) (cadr a))
                             (memq (car b) commutative)))
                    (not (and (eq? (list-ref b 2) (cadr a))
                              (eq? (list-ref b 3) (cadr a))))
                    ;; nothing else wants the loaded value
                    (dead-from? (cadr a) (cddr is)))))
        (let* ((a (car is)) (b (cadr is))
               ;; whichever source is NOT the load becomes the first operand,
               ;; which for a commutative op is the swap that lets it fold
               (keep (if (eq? (list-ref b 3) (cadr a))
                         (list-ref b 2)
                         (list-ref b 3))))
          (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
          (loop (cddr is)
                (cons (list (car b) (list-ref b 1) keep (caddr a)) out))))
       (else (loop (cdr is) (cons (car is) out))))))

  ;; --- read, modify, write, through the scratch -----------------------------
  ;;
  ;;     mov rax, [rsp+48]        ->   add [rsp+48], 1
  ;;     add rax, 1
  ;;     mov [rsp+48], rax
  ;;
  ;; A spilled value incremented in place goes through the scratch because that
  ;; is the shape the spiller always emits: reload, operate, store. x86-64 does
  ;; the whole thing in one instruction against memory, and the encoder already
  ;; takes a memory destination with an immediate -- it says so by name.
  ;;
  ;; nbody's outer loop does this twice per unrolled body for its counter, which
  ;; is the loop that spills most and computes least.
  ;;
  ;; FLAGS ARE PRESERVED, which matters because an overflow check follows some of
  ;; these: `add [m], imm` sets OF exactly as `add r, imm` did. Restricted to add
  ;; and sub, which is what a counter uses; the other ALU ops have the same
  ;; memory form and are simply not emitted in this shape.
  (define rmw-ops '(add sub))

  (define (fold-read-modify-write instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((and (pair? (cdr is)) (pair? (cddr is))
             (let ((a (car is)) (b (cadr is)) (c (caddr is)))
               (and (pair? a) (memq (car a) '(mov)) (= (length a) 3)
                    (symbol? (cadr a))
                    (pair? (caddr a)) (eq? (car (caddr a)) 'mem)
                    ;; the address must not be built out of the register the
                    ;; load is about to overwrite
                    (not (mentions-reg? (caddr a) (cadr a)))
                    (pair? b) (memq (car b) rmw-ops) (= (length b) 3)
                    (eq? (cadr b) (cadr a))
                    (pair? (caddr b)) (eq? (car (caddr b)) 'imm)
                    (pair? c) (eq? (car c) 'mov) (= (length c) 3)
                    (equal? (cadr c) (caddr a))     ; same address
                    (eq? (caddr c) (cadr a))
                    (dead-from? (cadr a) (cdddr is)))))
        (let ((a (car is)) (b (cadr is)))
          (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
          (loop (cdddr is)
                (cons (list (car b) (caddr a) (caddr b)) out))))
       (else (loop (cdr is) (cons (car is) out))))))

  ;; The pattern, over the SELECTED stream:
  ;;   (cmp a b) (setcc r) (movzx r r) ... (cmp r 0) (jne L)
  ;; collapses when nothing between them touches the flags or r, and r is dead.
  ;; The selector widens a setcc's byte result before testing it, so the real
  ;; sequence is FIVE instructions:
  ;;
  ;;     cmp a, b ; setl v ; movzx v, v ; cmp v, 0 ; jne L
  ;;
  ;; and the flags from the first `cmp` are already exactly what the branch
  ;; wants. This matched a FOUR-instruction form with no widening, which is not
  ;; what this compiler emits -- so wiring the peephole into the pipeline at all
  ;; changed the instruction count by zero, on every branch in every program.
  ;;
  ;; Dropping the widening is safe for the same reason dropping the setcc is:
  ;; the match already requires the boolean to be dead after the branch.
  (define (widened? is)
    (and (pair? is) (pair? (cdr is))
         (eq? (car (cadr is)) 'movzx)
         (eq? (cadr (cadr is)) (cadr (car is)))
         (eq? (caddr (cadr is)) (cadr (car is)))))

  (define (fuse-compare-branch instrs stats)
    (let loop ((is instrs) (out '()))
      (if (null? is)
          (reverse out)
          ;; `tail` is what follows the setcc once any widening is skipped, and
          ;; `n` is how many instructions the whole shape occupies in the input.
          (let* ((setcc-at (and (pair? (cdr is)) (cdr is)))
                 (widen? (and setcc-at (widened? setcc-at)))
                 (tail (and setcc-at (if widen? (cddr setcc-at) (cdr setcc-at))))
                 (n (if widen? 5 4)))
            (cond
             ((and setcc-at tail
                   (eq? (car (car is)) 'cmp)
                   (jump-for (car (car setcc-at)))
                   (pair? tail) (pair? (cdr tail))
                   (eq? (car (car tail)) 'cmp)
                   (memq (car (cadr tail)) '(jne je))
                   ;; the setcc's destination is what the second cmp tests
                   (eq? (cadr (car setcc-at)) (cadr (car tail)))
                   ;; and it is dead after the branch
                   (not (used-later? (cadr (car setcc-at)) (cddr tail))))
              (let* ((cmp (car is))
                     (setcc (car setcc-at))
                     (branch (cadr tail))
                     (jmp (jump-for (car setcc)))
                     ;; (jne L) on a boolean means "branch when the cc held";
                     ;; (je L) means the opposite, so the jump inverts.
                     (j (if (eq? (car branch) 'jne) jmp (invert jmp))))
                (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
                (loop (list-tail is n)
                      (cons (list j (cadr branch)) (cons cmp out)))))
             (else (loop (cdr is) (cons (car is) out))))))))

  (define (invert j)
    (cond ((eq? j 'jl) 'jge) ((eq? j 'jge) 'jl)
          ((eq? j 'jle) 'jg) ((eq? j 'jg) 'jle)
          ((eq? j 'je) 'jne) ((eq? j 'jne) 'je)
          ((eq? j 'jb) 'jae) ((eq? j 'jae) 'jb)
          ((eq? j 'jbe) 'ja) ((eq? j 'ja) 'jbe)
          (else (error 'invert "no inverse for" j))))

  ;; --- recover the sub-then-neg the two-address pass discards ---------------
  ;;
  ;; twoaddr.ss rewrites EVERY non-commutative op whose dst aliases src2 into
  ;; move / operate / move, uniformly. For integer `sub` that is one instruction
  ;; more than necessary: `sub dst, src1` followed by `neg dst` computes
  ;; src1 - src2 into dst directly, and is exact in two's complement.
  ;;
  ;; The uniform rewrite was the right call in that pass: the alternative is a
  ;; per-target, per-storage-class table of which cases a rule can serve in
  ;; place, which duplicates the rule table's knowledge in a second file that
  ;; will drift from it. Here, over the selected stream, the pattern is simply
  ;; visible.
  ;;
  ;; NOT applied to floating point. `sub` then `neg` on doubles is not the same
  ;; as subtraction: negating zero gives -0.0, so (0.0 - 0.0) would come out
  ;; -0.0 instead of 0.0. That is exactly the divergence SPEC.md records and
  ;; bench/nbody's oracle would catch it.
  (define (fuse-sub-neg instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((and (pair? is) (pair? (cdr is)) (pair? (cddr is))
             ;; move t <- src1 ; sub t <- t src2 ; move dst <- t
             (eq? (car (car is)) 'mov)
             (eq? (car (cadr is)) 'sub)
             (eq? (car (caddr is)) 'mov)
             (let ((t (cadr (car is))))
               (and
                ;; THE SUB MUST BE THREE-ADDRESS: (sub t t src2). Only slot 1
                ;; was checked, which a two-address `(sub t src2)` also
                ;; satisfies -- and then `src2` was read from slot 3, off the
                ;; end of the list. It never fired that way because no
                ;; two-address sub had previously landed in this position, so
                ;; the pass raised the first time one did. Requiring both slots
                ;; to name the temp is the shape the rewrite below assumes.
                ;;
                ;; The two-address case IS fusible by the same argument, and is
                ;; deliberately left alone here: adding it is a new
                ;; optimisation, not part of making this one match its body.
                (= (length (cadr is)) 4)
                (eq? (cadr (cadr is)) t)
                (eq? (caddr (cadr is)) t)
                (eq? (caddr (caddr is)) t)
                ;; the temp must be dead after
                (not (used-later? t (cdddr is))))))
        (let* ((src1 (caddr (car is)))
               (src2 (cadddr (cadr is)))
               (dst  (cadr (caddr is))))
          ;; Three instructions become two: the temp existed only to hold src1
          ;; while the destructive sub ran, and if it is dead afterwards the
          ;; destination can play that role itself.
          ;;
          ;;   mov t, src1 ; sub t, t, src2 ; mov dst, t
          ;;   ->  mov dst, src1 ; sub dst, src2
          ;;
          ;; NOT `sub` then `neg`. That form is for the case where dst ALIASES
          ;; src2, where `sub dst, src1` computes src2 - src1 and the neg
          ;; corrects it. Applying it here would compute src2 - src1 and leave
          ;; it negated wrongly, and it would be three instructions rather than
          ;; two. Writing it that way first, and having no test that could tell
          ;; the difference, is why this comment exists.
          (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
          (loop (cdddr is)
                (cons (list 'sub dst src2)
                      (cons (list 'mov dst src1) out)))))
       (else (loop (cdr is) (cons (car is) out))))))

  ;; --- constants into immediate operands -------------------------------------
  ;;
  ;; A constant reaches an arithmetic instruction as a register:
  ;;
  ;;     mov  rax, 1        mov  rdi, 3
  ;;     add  rsi, rax      imul r10, rdi
  ;;
  ;; because selection names every value, including a literal, and the
  ;; instruction it feeds is chosen without knowing the operand is constant.
  ;; x86-64 takes an immediate directly in both cases -- 83 /0 for `add`, and
  ;; the three-address 6B /r for `imul`, which is why the encoder grew that
  ;; form -- so the materialisation is pure waste. nbody's pairwise force body
  ;; does this four times per iteration.
  ;;
  ;; This runs over the ALLOCATED stream, so the register holding the constant
  ;; is usually the spill scratch and dead one instruction later. `used-later?`
  ;; is what establishes that, and it is not optional: the same register may be
  ;; a genuine allocated value with more readers.
  ;;
  ;; `imul` is the reason this is not simply a table of two-operand rewrites:
  ;; its immediate form is three-address, so the fold changes the shape of the
  ;; instruction rather than just an operand.
  (define fold-target '(add sub and or cmp))

  (define (imm-of i)
    (and (pair? i) (eq? (car i) 'mov) (= (length i) 3)
         (pair? (caddr i)) (eq? (car (caddr i)) 'imm)
         (cadr (caddr i))))

  ;; Does this instruction WRITE r and read nothing of it? Then r's old value is
  ;; dead from here, which is what makes deleting the materialisation safe.
  (define (redefines? i r)
    (and (pair? i)
         (memq (car i) '(mov movsd movzx lea cvtsi2sd))
         (>= (length i) 2)
         (eq? (cadr i) r)
         (not (mentions? (cddr i) r))))

  (define (mentions? x r)
    (cond ((eq? x r) #t)
          ((pair? x) (or (mentions? (car x) r) (mentions? (cdr x) r)))
          (else #f)))

  ;; A use of r that can take the constant instead: r is the SECOND operand of a
  ;; two-operand arithmetic instruction and is not also its destination.
  (define (foldable-use? i r)
    (and (pair? i)
         (memq (car i) (cons 'imul fold-target))
         (= (length i) 3)
         (eq? (caddr i) r)
         (not (eq? (cadr i) r))))

  ;; Rewrite one use to take the immediate. `imul`'s immediate form is
  ;; three-address, so the shape changes rather than just the operand.
  (define (fold-use i k)
    (if (eq? (car i) 'imul)
        (list 'imul (cadr i) (cadr i) (list 'imm k))
        (list (car i) (cadr i) (list 'imm k))))

  ;; --- constants into immediate operands -------------------------------------
  ;;
  ;; A constant reaches an arithmetic instruction as a register:
  ;;
  ;;     mov  rdi, 3        mov  rax, 1
  ;;     imul r10, rdi      add  rsi, rax
  ;;     imul r11, rdi
  ;;
  ;; because selection names every value, including a literal, and the
  ;; instruction it feeds is chosen without knowing the operand is constant.
  ;; x86-64 takes an immediate directly in both cases -- 83 /0 for `add`, and
  ;; the three-address 6B /r for `imul`, which is why the encoder grew that
  ;; form. nbody's pairwise force body does this four times per iteration.
  ;;
  ;; ALL USES OR NONE. The first version folded only a use in the very next
  ;; instruction and required the register to be unused afterwards, which
  ;; matched almost nothing: a constant materialised once and used twice --
  ;; `3` scaling two different indices -- failed on the second use, and the
  ;; spill scratch failed because its next REDEFINITION counted as a use.
  ;;
  ;; So this collects every use of the register up to its next redefinition. If
  ;; all of them can take an immediate, all are folded and the materialisation
  ;; is deleted; if any cannot -- it is an address component, or the register is
  ;; the destination -- nothing changes.
  ;;
  ;; The redefinition is also what makes deleting the materialisation SAFE. This
  ;; pass runs over one straight-line run with no liveness information, so a
  ;; register still live at the end of the run must keep its value. Requiring a
  ;; later write proves it does not.
  ;; FOLDING A USE IS ALWAYS SAFE. Only DELETING the materialisation needs proof
  ;; that the register is dead, and the two were conflated at first: requiring a
  ;; later redefinition before folding anything meant a constant used twice with
  ;; no redefinition in the run kept both its register uses, which then kept the
  ;; register live, which then spilled. nbody's `+2` component went that way.
  ;;
  ;; So the two decisions are now separate. Every use that can take an immediate
  ;; takes one. The materialisation is removed only when every use was folded
  ;; AND a later write proves the register dead -- this pass sees one
  ;; straight-line run and has no liveness, so without that write the register
  ;; may be read in another block and the definition has to stay.
  ;;
  ;; A left-behind `mov` is one wasted instruction. Not folding is worth several,
  ;; because the register it keeps alive is one the allocator then cannot use.
  (define (fold-immediates instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((imm-of (car is))
        => (lambda (k)
             (let ((r (cadr (car is))))
               (let scan ((rest (cdr is)) (folds 0) (all #t))
                 (cond
                  ((or (null? rest) (redefines? (car rest) r))
                   (cond
                    ((zero? folds) (loop (cdr is) (cons (car is) out)))
                    (else
                     (peephole-stats-fused-set!
                      stats (+ 1 (peephole-stats-fused stats)))
                     (let ((rewritten (fold-run (cdr is) r k)))
                       ;; Dead only if nothing else read it AND a later write
                       ;; proves it. `(null? rest)` is the end of the run, where
                       ;; neither holds.
                       (if (and all (pair? rest))
                           (loop rewritten out)
                           (loop rewritten (cons (car is) out)))))))
                  ;; A BARRIER KEEPS THE MATERIALISATION. `leaves-block?` says
                  ;; why in its own header: a `call` reads argument registers
                  ;; that appear nowhere in its operands, so `mentions?` returns
                  ;; false for it and this scan walked straight past. Folding
                  ;; USES past a barrier stays sound -- the immediate is the
                  ;; value -- so this clears `all` and keeps scanning.
                  ((leaves-block? (car rest)) (scan (cdr rest) folds #f))
                  ((foldable-use? (car rest) r) (scan (cdr rest) (+ folds 1) all))
                  ((mentions? (cdr (car rest)) r) (scan (cdr rest) folds #f))
                  (else (scan (cdr rest) folds all)))))))
       (else (loop (cdr is) (cons (car is) out))))))

  ;; Substitute the immediate into every use of r, stopping at its redefinition.
  (define (fold-run is r k)
    (let walk ((is is) (out '()))
      (cond
       ((null? is) (reverse out))
       ((redefines? (car is) r) (append (reverse out) is))
       ((foldable-use? (car is) r) (walk (cdr is) (cons (fold-use (car is) k) out)))
       (else (walk (cdr is) (cons (car is) out))))))

  ;; --- copy-then-add becomes lea ---------------------------------------------
  ;;
  ;;     mov rsi, r10        ->    lea rsi, [r10+1]
  ;;     add rsi, 1
  ;;
  ;; `lea` computes an address without touching memory, which makes it the
  ;; three-address integer add x86-64 otherwise lacks. The pattern appears
  ;; wherever an index is derived from a loop counter, which after immediate
  ;; folding is every component offset in nbody's force loop.
  ;;
  ;; IT DOES NOT SET FLAGS, and `add` does. So this fires only when nothing
  ;; reads the flags before something else writes them -- otherwise a later
  ;; branch would test flags this instruction no longer produces, which is a
  ;; wrong-branch bug and not a slow one.
  (define flag-readers '(jl jle je jne jge jg jb jbe ja jae jo jno
                         setl setle sete setne setge setg setb setbe seta setae))
  (define flag-writers '(add sub and or cmp imul neg shl sar shr))

  (define (flags-dead-before-rewrite? is)
    (let scan ((is is))
      (cond ((null? is) #t)
            ((memq (car (car is)) flag-readers) #f)
            ((memq (car (car is)) flag-writers) #t)
            (else (scan (cdr is))))))

  (define (fuse-lea instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((and (pair? (cdr is))
             (let ((m (car is)) (a (cadr is)))
               (and (eq? (car m) 'mov) (= (length m) 3)
                    (symbol? (cadr m)) (symbol? (caddr m))
                    (not (eq? (cadr m) (caddr m)))
                    (eq? (car a) 'add) (= (length a) 3)
                    (eq? (cadr a) (cadr m))
                    (pair? (caddr a)) (eq? (car (caddr a)) 'imm)
                    (flags-dead-before-rewrite? (cddr is)))))
        (let ((d (cadr (car is)))
              (b (caddr (car is)))
              (k (cadr (caddr (cadr is)))))
          (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
          (loop (cddr is) (cons `(lea ,d (mem ,b #f 1 ,k)) out))))
       (else (loop (cdr is) (cons (car is) out))))))

  ;; --- an index computation folds into the addressing mode --------------------
  ;;
  ;;     lea   rsi, [r10+1]              movsd xmm0, [r8 + r10*8 + 7]
  ;;     movsd xmm0, [r8 + rsi*8 - 1]
  ;;
  ;; because [r8 + (r10+1)*8 - 1] IS [r8 + r10*8 + 7]. The scale distributes
  ;; over the constant, so a derived index never needs computing at all: it is a
  ;; displacement, and the displacement was already there.
  ;;
  ;; This is strength reduction arriving at the cheapest place to do it. nbody
  ;; indexes three components off one base -- 3i, 3i+1, 3i+2 -- and the second
  ;; and third were each costing a constant, an add and a register that then had
  ;; to stay live. Folding them into the displacement removes the instructions
  ;; AND the register pressure, which is why it is worth more than its
  ;; instruction count suggests: the vregs it deletes were the ones spilling.
  ;;
  ;; ALL USES OR NONE, and every use must be as the INDEX of a memory operand.
  ;; A use as a plain register operand cannot absorb the constant, and a use as
  ;; the BASE cannot either -- the base is not scaled, so folding there would
  ;; multiply the constant by one while the index multiplies it by the scale.
  (define (lea-of i)
    ;; (lea D (mem B #f 1 k)) -- a base plus a constant, nothing else.
    (and (pair? i) (eq? (car i) 'lea) (= (length i) 3)
         (symbol? (cadr i))
         (let ((m (caddr i)))
           (and (pair? m) (eq? (car m) 'mem)
                (symbol? (cadr m)) (not (caddr m))
                (eqv? (cadddr m) 1)
                (integer? (list-ref m 4))
                (list (cadr i) (cadr m) (list-ref m 4))))))

  ;; Every occurrence of d in this instruction is as a memory INDEX, and the
  ;; displacement that results still fits.
  (define (index-only-uses i d k)
    (let scan ((xs (cdr i)) (hits 0))
      (cond
       ((null? xs) hits)
       ((eq? (car xs) d) #f)                       ; a bare register operand
       ((and (pair? (car xs)) (eq? (car (car xs)) 'mem))
        (let* ((m (car xs)) (base (cadr m)) (idx (caddr m)) (sc (cadddr m))
               (disp (list-ref m 4)))
          (cond
           ((eq? base d) #f)                       ; the base is not scaled
           ((eq? idx d)
            (if (and (integer? disp) (integer? sc)
                     (let ((n (+ disp (* k sc))))
                       (<= (- (expt 2 31)) n (- (expt 2 31) 1))))
                (scan (cdr xs) (+ hits 1))
                #f))
           (else (scan (cdr xs) hits)))))
       ((mentions? (car xs) d) #f)
       (else (scan (cdr xs) hits)))))

  (define (fold-index-into i d b k)
    (cons (car i)
          (map (lambda (x)
                 (if (and (pair? x) (eq? (car x) 'mem) (eq? (caddr x) d))
                     (list 'mem (cadr x) b (cadddr x)
                           (+ (list-ref x 4) (* k (cadddr x))))
                     x))
               (cdr i))))

  ;; A copy feeding a three-address multiply is the multiply.
  ;;
  ;;     mov  r10, rcx          ->    imul r10, rcx, 3
  ;;     imul r10, r10, 3
  ;;
  ;; The immediate fold above produces `imul D, D, k` because that is what the
  ;; two-operand form it replaced meant. When D was itself a fresh copy, the
  ;; three-address form can read the original directly -- which is what having a
  ;; second source operand is FOR, and the same reason the float ops went
  ;; three-address.
  (define (fuse-copy-imul instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((and (pair? (cdr is))
             (let ((m (car is)) (u (cadr is)))
               (and (eq? (car m) 'mov) (= (length m) 3)
                    (symbol? (cadr m)) (symbol? (caddr m))
                    (not (eq? (cadr m) (caddr m)))
                    (eq? (car u) 'imul) (= (length u) 4)
                    (eq? (cadr u) (cadr m)) (eq? (caddr u) (cadr m))
                    (pair? (cadddr u)) (eq? (car (cadddr u)) 'imm))))
        (let ((d (cadr (car is))) (src (caddr (car is))) (k (cadddr (cadr is))))
          (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
          (loop (cddr is) (cons (list 'imul d src k) out))))
       (else (loop (cdr is) (cons (car is) out))))))

  (define (fuse-index instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ((lea-of (car is))
        => (lambda (spec)
             (let ((d (car spec)) (b (cadr spec)) (k (caddr spec)))
               (let scan ((rest (cdr is)) (uses 0))
                 (cond
                  ((null? rest) (loop (cdr is) (cons (car is) out)))
                  ((redefines? (car rest) d)
                   (if (> uses 0)
                       (begin
                         (peephole-stats-fused-set!
                          stats (+ 1 (peephole-stats-fused stats)))
                         (loop (fold-index-run (cdr is) d b k) out))
                       (loop (cdr is) (cons (car is) out))))
                  ((index-only-uses (car rest) d k)
                   => (lambda (n) (scan (cdr rest) (+ uses n))))
                  (else (loop (cdr is) (cons (car is) out))))))))
       (else (loop (cdr is) (cons (car is) out))))))

  (define (fold-index-run is d b k)
    (let walk ((is is) (out '()))
      (cond
       ((null? is) (reverse out))
       ((redefines? (car is) d) (append (reverse out) is))
       (else (walk (cdr is) (cons (fold-index-into (car is) d b k) out))))))

  (define (peephole target instrs)
    (let ((stats (make-peephole-stats 0)))
      (values (if (needs-fusion? target)
                  ;; Immediates LAST: compare-and-branch fusion matches a `cmp`
                  ;; against a register, and folding a constant into that `cmp`
                  ;; first would change the shape it looks for.
                  ;; lea LAST: it consumes the `add` with an immediate that
                  ;; immediate folding produces, so the order is forced.
                  ;; index folding LAST: it consumes the `lea` that the copy-add
                  ;; fold produces, so the order is forced twice over.
                  ;; The two copy passes go LAST, and in this order. Folding a
                  ;; store through the scratch leaves the scratch's own load
                  ;; with no reader, which is then a dead copy -- so running
                  ;; them the other way round finds half as much. Both want
                  ;; every earlier rewrite already done, since each of those
                  ;; removes readers.
                  (drop-dead-copies
                   (fold-read-modify-write
                    (fold-load-into-arith
                    (fold-store-through-scratch
                    (fuse-index
                     (fuse-copy-imul
                      (fuse-lea
                       (fold-immediates
                        (fuse-sub-neg (fuse-compare-branch instrs stats) stats)
                        stats)
                       stats)
                      stats)
                     stats)
                    stats)
                    stats)
                    stats)
                   stats)
                  instrs)
              stats)))
  )
