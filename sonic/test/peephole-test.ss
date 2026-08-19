(import (chezscheme) (sonic peephole) (sonic driver) (sonic pipeline))

(define failures 0) (define checks 0)
(define (ck! name ok)
  (set! checks (+ checks 1))
  (if ok (begin (display "  ok   ") (display name) (newline))
         (begin (set! failures (+ failures 1))
                (display "  FAIL ") (display name) (newline))))

(define (run t is) (let-values ([(o s) (peephole t is)]) (list o (peephole-stats-fused s))))

;; --- the fusion ------------------------------------------------------------
(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (jne L1) (ret v-x))]
       [r (run 'x86-64 in)])
  (ck! "cmp/setl/cmp/jne collapses to cmp/jl"
       (equal? (car r) '((cmp v-a v-b) (jl L1) (ret v-x))))
  (ck! "and is counted" (= (cadr r) 1)))

;; (je L) on the boolean means branch when the condition FAILED, so the jump
;; inverts. Getting this backwards is a wrong branch, not a slow one.
(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (je L1) (ret v-x))]
       [r (run 'x86-64 in)])
  (ck! "je on the boolean inverts the jump: jl becomes jge"
       (equal? (car r) '((cmp v-a v-b) (jge L1) (ret v-x)))))

;; --- the liveness condition, which is the whole safety of the pass ---------
(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (jne L1) (ret v-t))]
       [r (run 'x86-64 in)])
  (ck! "NO fusion when the boolean is used after the branch"
       (equal? (car r) in))
  (ck! "and nothing is counted" (= (cadr r) 0)))

(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-t 0) (jne L1) (store v-o v-t))]
       [r (run 'x86-64 in)])
  (ck! "NO fusion when the boolean is stored: it is a value someone reads"
       (equal? (car r) in)))

;; --- non-patterns are untouched -------------------------------------------
(let* ([in '((add v-a v-b v-c) (mul v-d v-a v-a) (ret v-d))]
       [r (run 'x86-64 in)])
  (ck! "ordinary arithmetic passes through unchanged" (equal? (car r) in)))

(let* ([in '((cmp v-a v-b) (setl v-t) (cmp v-u 0) (jne L1))]
       [r (run 'x86-64 in)])
  (ck! "no fusion when the branch tests a DIFFERENT vreg" (equal? (car r) in)))

;; --- RV64 needs no fusion at all ------------------------------------------
;; Its branches ARE compare-and-branch, so the selector emits the fused form
;; directly. This is the mirror of the two-address pass: x86-64 needs it, RV64
;; does not.
(let* ([in '((blt v-a v-b L1) (ret v-x))]
       [r (run 'rv64 in)])
  (ck! "rv64 stream is returned untouched" (equal? (car r) in))
  (ck! "and nothing is fused" (= (cadr r) 0)))

;; An unknown target RAISES rather than defaulting to no-fusion, because a
;; quiet default silently leaves five instructions where two would do, forever.
(set! checks (+ checks 1))
(let ([caught #f])
  (guard (e (#t (set! caught #t))) (peephole 'arm64 '()))
  (if caught (display "  ok   an unknown target RAISES rather than silently skipping\n")
             (begin (set! failures (+ failures 1))
                    (display "  FAIL unknown target silently skipped\n"))))


;; --- sub through a dead temp collapses ------------------------------------
;; twoaddr.ss emits move/operate/move uniformly. When the temp is dead the
;; destination can play its role, and three instructions become two.
(let* ([in '((mov v-t v-a) (sub v-t v-t v-b) (mov v-d v-t) (ret v-d))]
       [r (run 'x86-64 in)])
  (ck! "mov/sub/mov through a dead temp becomes mov/sub"
       (equal? (car r) '((mov v-d v-a) (sub v-d v-b) (ret v-d))))
  (ck! "which is TWO instructions, not three"
       (= (length (car r)) 3)))   ; two plus the ret

;; The operand order is the thing to get wrong, and it computes the negation of
;; the right answer when you do. src1 must survive as the minuend.
(let* ([in '((mov v-t v-a) (sub v-t v-t v-b) (mov v-d v-t) (ret v-d))]
       [r (run 'x86-64 in)]
       [sub (cadr (car r))])
  (ck! "the destination is loaded with src1, and src2 is subtracted from it"
       (and (equal? (car (car r)) '(mov v-d v-a))
            (equal? sub '(sub v-d v-b))))
  (ck! "no spurious neg is emitted: that form is for dst aliasing src2"
       (not (memq 'neg (map car (car r))))))

;; Live temp: the collapse would delete a value someone reads.
(let* ([in '((mov v-t v-a) (sub v-t v-t v-b) (mov v-d v-t) (ret v-t))]
       [r (run 'x86-64 in)])
  (ck! "NO collapse when the temp is still live" (equal? (car r) in)))

;; --- constants into immediate operands --------------------------------------
;;
;; ALL USES OR NONE, which is the property worth pinning. The first version
;; folded only a use in the very next instruction and required the register to
;; be unused afterwards; that matched almost nothing real, because a constant
;; materialised once and used twice failed on the second use and the spill
;; scratch failed because its next REDEFINITION counted as a use.

(define (peeped is) (let-values (((out st) (peephole 'x86-64 is))) out))

(ck! "a constant feeding one add becomes an immediate, and the mov goes"
     (equal? (peeped '((mov rax (imm 1))
                       (add rsi rax)
                       (mov rax (imm 9))))
             '((add rsi (imm 1)) (mov rax (imm 9)))))

;; The case that motivated this: 3 scaling two different indices. Both uses
;; fold, not just the first.
(ck! "a constant used TWICE folds into both, and the mov still goes"
     (equal? (peeped '((mov rdi (imm 3))
                       (imul r10 rdi)
                       (imul r11 rdi)
                       (mov rdi (imm 2))))
             '((imul r10 r10 (imm 3)) (imul r11 r11 (imm 3)) (mov rdi (imm 2)))))

;; imul's immediate form is THREE-address, so the fold changes the instruction's
;; shape rather than one operand. Asserted separately because a rewrite that
;; produced the two-operand form would encode a different multiply.
(ck! "imul folds to its three-address form"
     (equal? (peeped '((mov rdi (imm 48)) (imul rsi rdi) (mov rdi (imm 1))))
             '((imul rsi rsi (imm 48)) (mov rdi (imm 1)))))

;; FOLDING A USE AND DELETING THE DEFINITION ARE SEPARATE DECISIONS, and
;; conflating them was the bug. A use that cannot take an immediate -- an
;; address component, where there is no immediate form of a base register --
;; keeps the materialisation alive. It does NOT stop the other uses folding.
(ck! "a use that cannot fold keeps the mov, but the others still fold"
     (equal? (peeped '((mov rdi (imm 3))
                       (add rsi rdi)
                       (movsd xmm0 (mem r8 rdi 8 0))
                       (mov rdi (imm 1))))
             '((mov rdi (imm 3))
               (add rsi (imm 3))
               (movsd xmm0 (mem r8 rdi 8 0))
               (mov rdi (imm 1)))))

;; Deleting the materialisation needs proof the register is dead, and this pass
;; has no liveness -- it sees one straight-line run. A later REDEFINITION is the
;; proof; without one the register may be read in another block, so the
;; definition stays. The USE still folds, which is the point: keeping the
;; register alive costs the allocator a register, and that is worth more than
;; the one instruction left behind.
(ck! "with no later redefinition the mov stays, but the use folds anyway"
     (equal? (peeped '((mov rdi (imm 3)) (imul r10 rdi)))
             '((mov rdi (imm 3)) (imul r10 r10 (imm 3)))))

;; Folding into the destination would be a different instruction: `add rax, rax`
;; doubles, `add rax, imm` does not.
(ck! "a register that is also the destination is not folded"
     (equal? (peeped '((mov rax (imm 1)) (add rax rax) (mov rax (imm 2))))
             '((mov rax (imm 1)) (add rax rax) (mov rax (imm 2)))))

;; --- copy-then-add becomes lea ----------------------------------------------

(ck! "a copy followed by an immediate add becomes one lea"
     (equal? (peeped '((mov rsi r10) (add rsi (imm 1)) (movsd xmm0 xmm1)))
             '((lea rsi (mem r10 #f 1 1)) (movsd xmm0 xmm1))))

;; lea does NOT set flags and add does. Firing when something reads them is a
;; wrong-branch bug, not a slow one, so the guard is a correctness check.
(ck! "it does NOT fire when a branch reads the flags the add would have set"
     (equal? (peeped '((mov rsi r10) (add rsi (imm 1)) (jl (label L))))
             '((mov rsi r10) (add rsi (imm 1)) (jl (label L)))))

(ck! "but it does when something else writes the flags first"
     (equal? (peeped '((mov rsi r10) (add rsi (imm 1)) (cmp rax rbx) (jl (label L))))
             '((lea rsi (mem r10 #f 1 1)) (cmp rax rbx) (jl (label L)))))

;; --- an index computation folds into the addressing mode --------------------
;;
;; [r8 + (r10+1)*8 - 1] IS [r8 + r10*8 + 7]: the scale distributes over the
;; constant, so a derived index never needs computing. This is where nbody's
;; three component offsets go, and it is worth more than its instruction count
;; because the vreg it deletes was one of the ones spilling.

(ck! "a lea feeding a scaled index folds into the displacement"
     (equal? (peeped '((lea rsi (mem r10 #f 1 1))
                       (movsd xmm0 (mem r8 rsi 8 -1))
                       (mov rsi rax)))
             '((movsd xmm0 (mem r8 r10 8 7)) (mov rsi rax))))

(ck! "the scale is applied to the constant, not added to it"
     (equal? (peeped '((lea rsi (mem r10 #f 1 2))
                       (movsd xmm0 (mem r8 rsi 8 -1))
                       (mov rsi rax)))
             '((movsd xmm0 (mem r8 r10 8 15)) (mov rsi rax))))

;; The BASE is not scaled, so folding a constant there would multiply it by one
;; while the index multiplies it by the scale. Different address, same shape.
(ck! "a use as the base rather than the index does NOT fold"
     (equal? (peeped '((lea rsi (mem r10 #f 1 1))
                       (movsd xmm0 (mem rsi r9 8 0))
                       (mov rsi rax)))
             '((lea rsi (mem r10 #f 1 1))
               (movsd xmm0 (mem rsi r9 8 0))
               (mov rsi rax))))

;; A bare register use cannot absorb the constant at all.
(ck! "a plain register use blocks it"
     (equal? (peeped '((lea rsi (mem r10 #f 1 1)) (add rdx rsi) (mov rsi rax)))
             '((lea rsi (mem r10 #f 1 1)) (add rdx rsi) (mov rsi rax))))

;; Same liveness rule as the immediate fold: the lea is only removed when a
;; later write proves its destination dead.
(ck! "with no later redefinition the lea stays"
     (equal? (peeped '((lea rsi (mem r10 #f 1 1)) (movsd xmm0 (mem r8 rsi 8 -1))))
             '((lea rsi (mem r10 #f 1 1)) (movsd xmm0 (mem r8 rsi 8 -1)))))

;; End to end: a copy, an immediate add and a scaled load are ONE instruction.
(ck! "copy + add + scaled load collapses to a single addressed load"
     (equal? (peeped '((mov rax (imm 1))
                       (mov rsi r10)
                       (add rsi rax)
                       (movsd xmm0 (mem r8 rsi 8 -1))
                       (mov rsi rdx)
                       (mov rax rcx)))
             '((movsd xmm0 (mem r8 r10 8 7)) (mov rsi rdx) (mov rax rcx))))

;; A copy feeding a three-address multiply IS the multiply. The immediate fold
;; produces `imul D, D, k` because that is what the two-operand form it replaced
;; meant; when D was itself a fresh copy, the second source operand can read the
;; original directly, which is what having one is for.
(ck! "a copy into a three-address imul collapses into it"
     (equal? (peeped '((mov r10 rcx) (imul r10 r10 (imm 3))))
             '((imul r10 rcx (imm 3)))))

(ck! "end to end: copy, two-operand imul and a materialised 3 become one imul"
     (equal? (peeped '((mov rdi (imm 3))
                       (mov r10 rcx)
                       (imul r10 rdi)
                       (mov rdi rax)))
             '((imul r10 rcx (imm 3)) (mov rdi rax))))

;; --- copies nobody reads ----------------------------------------------------
;;
;; These two DELETE instructions, so the refusals matter more than the hits. A
;; register wrongly believed dead is a deleted definition, which is a wrong
;; program rather than a slow one -- and the tests that would catch it are the
;; ones below where the answer is "left alone".

(ck! "a copy overwritten before it is read is dropped"
     (equal? (peeped '((mov r8 rax) (mov rdx r13) (mov r8 r12)))
             '((mov rdx r13) (mov r8 r12))))

;; THE READ THROUGH AN ADDRESSING MODE is the case a shallow membership test
;; gets wrong, and it gets it wrong silently: `rbx` appears nowhere in the
;; instruction's top-level operands, only inside the memory operand.
(ck! "a register read only as an ADDRESS BASE is not dead"
     (equal? (peeped '((mov rbx rax) (mov rdx (mem rbx #f 1 8)) (mov rbx r12)))
             '((mov rbx rax) (mov rdx (mem rbx #f 1 8)) (mov rbx r12))))

(ck! "nor as an address INDEX"
     (equal? (peeped '((mov rbx rax) (mov rdx (mem r9 rbx 8 0)) (mov rbx r12)))
             '((mov rbx rax) (mov rdx (mem r9 rbx 8 0)) (mov rbx r12))))

;; A call reads its argument registers, and they appear nowhere in its operands.
;; Stopping at the call is the only safe answer.
(ck! "a copy into an argument register before a call is NOT dropped"
     (equal? (peeped '((mov r8 rax) (call (label f)) (mov r8 r12)))
             '((mov r8 rax) (call (label f)) (mov r8 r12))))

(ck! "and a copy into the return register before a ret is not dropped"
     (equal? (peeped '((mov rax rbx) (ret)))
             '((mov rax rbx) (ret))))

;; NO LABEL CASE HERE, and that is the contract rather than an omission:
;; `peephole-runs` in finalize.ss splits the listing at every label and calls
;; this on straight-line runs only, because fusing a compare with a branch
;; across a branch target would hand the branch flags that some paths never
;; set. `dead-from?` still refuses at a label, defensively, but no caller can
;; reach it -- and the passes above this one assume a label-free run outright.

;; `lea rax, [rax+1]` writes rax and READS it, so it does not kill the value the
;; instruction before it put there. Both writes survive here because the third
;; instruction reads the result: drop either one and the read gets the wrong
;; number.
(ck! "a self-referencing lea reads its own destination, so it kills nothing"
     (equal? (peeped '((mov rax rbx) (lea rax (mem rax #f 1 1)) (mov rdx rax)))
             '((mov rax rbx) (lea rax (mem rax #f 1 1)) (mov rdx rax))))

;; --- a store that went through the scratch ----------------------------------

(ck! "a register stored via the scratch stores directly, and the copy goes"
     (equal? (peeped '((mov rax rcx) (mov (mem rsp #f 1 8) rax) (mov rax r12)))
             '((mov (mem rsp #f 1 8) rcx) (mov rax r12))))

;; x86-64 has no memory-to-memory move, so a memory SOURCE cannot be folded --
;; doing it would hand the encoder two memory operands and the report would come
;; from somewhere else entirely.
(ck! "a memory source is NOT folded into the store: that mov does not exist"
     (equal? (peeped '((mov rax (mem rsp #f 1 0))
                       (mov (mem rsp #f 1 8) rax)
                       (mov rax r12)))
             '((mov rax (mem rsp #f 1 0))
               (mov (mem rsp #f 1 8) rax)
               (mov rax r12))))

(ck! "nor when the scratch is still live afterwards"
     (equal? (peeped '((mov rax rcx) (mov (mem rsp #f 1 8) rax) (mov rdx rax)))
             '((mov rax rcx) (mov (mem rsp #f 1 8) rax) (mov rdx rax))))

;; The address itself may be built out of the scratch, and then the fold would
;; destroy the address before using it.
(ck! "nor when the scratch is part of the ADDRESS"
     (equal? (peeped '((mov rax rcx) (mov (mem rax #f 1 8) rax) (mov rax r12)))
             '((mov rax rcx) (mov (mem rax #f 1 8) rax) (mov rax r12))))

;; --- a load folded into the arithmetic that reads it ------------------------

(ck! "a load feeding the SECOND source folds into the instruction"
     (equal? (peeped '((movsd xmm3 (mem r8 rdi 8 15))
                       (vsubsd xmm4 xmm1 xmm3)
                       (movsd xmm3 (mem rsp #f 1 0))))
             '((vsubsd xmm4 xmm1 (mem r8 rdi 8 15))
               (movsd xmm3 (mem rsp #f 1 0)))))

(ck! "and the packed form folds the packed load"
     (equal? (peeped '((vmovupd xmm1 (mem r8 rdi 8 -1))
                       (vsubpd xmm2 xmm0 xmm1)
                       (vmovupd xmm1 (mem rsp #f 1 0))))
             '((vsubpd xmm2 xmm0 (mem r8 rdi 8 -1))
               (vmovupd xmm1 (mem rsp #f 1 0)))))

;; VEX's first source is the vvvv prefix field, which holds a register number.
;; The encoder refuses memory there by name; this must never hand it one.
;; VEX's first source is the vvvv prefix field, which holds a register number.
;; For a NON-commutative op there is nothing to be done: the operands cannot be
;; exchanged, so the load stays.
(ck! "a load feeding the FIRST source of a SUBTRACT is refused: order matters"
     (equal? (peeped '((movsd xmm1 (mem r8 rdi 8 15))
                       (vsubsd xmm4 xmm1 xmm0)
                       (movsd xmm1 (mem rsp #f 1 0))))
             '((movsd xmm1 (mem r8 rdi 8 15))
               (vsubsd xmm4 xmm1 xmm0)
               (movsd xmm1 (mem rsp #f 1 0)))))

;; For a COMMUTATIVE one the operands are exchanged so the load lands second and
;; folds. a+b and a*b are identical to b+a and b*a for every finite value, zero
;; and infinity; only the NaN payload x86 propagates changes, and differential.ss
;; compares flonums by bit pattern precisely so that it extends to payloads.
(ck! "a load feeding the first source of an ADD is swapped and folded"
     (equal? (peeped '((movsd xmm1 (mem r8 rdi 8 15))
                       (vaddsd xmm4 xmm1 xmm0)
                       (movsd xmm1 (mem rsp #f 1 0))))
             '((vaddsd xmm4 xmm0 (mem r8 rdi 8 15))
               (movsd xmm1 (mem rsp #f 1 0)))))

(ck! "and a MULTIPLY, the other commutative one"
     (equal? (peeped '((movsd xmm1 (mem r8 rdi 8 15))
                       (vmulsd xmm4 xmm1 xmm0)
                       (movsd xmm1 (mem rsp #f 1 0))))
             '((vmulsd xmm4 xmm0 (mem r8 rdi 8 15))
               (movsd xmm1 (mem rsp #f 1 0)))))

;; A DIVIDE is not commutative either, and swapping it would compute the
;; reciprocal of the right answer.
(ck! "a divide is never swapped"
     (equal? (peeped '((movsd xmm1 (mem r8 rdi 8 15))
                       (vdivsd xmm4 xmm1 xmm0)
                       (movsd xmm1 (mem rsp #f 1 0))))
             '((movsd xmm1 (mem r8 rdi 8 15))
               (vdivsd xmm4 xmm1 xmm0)
               (movsd xmm1 (mem rsp #f 1 0)))))

;; The loaded value in BOTH sources is `x*x`, and folding it would leave one
;; operand naming a register the load no longer wrote.
(ck! "a load feeding BOTH sources is refused"
     (equal? (peeped '((movsd xmm1 (mem r8 rdi 8 15))
                       (vmulsd xmm4 xmm1 xmm1)
                       (movsd xmm1 (mem rsp #f 1 0))))
             '((movsd xmm1 (mem r8 rdi 8 15))
               (vmulsd xmm4 xmm1 xmm1)
               (movsd xmm1 (mem rsp #f 1 0)))))

;; Folding an 8-byte load into a 16-byte operand reads memory the program never
;; asked for, which off the end of an allocation is a fault rather than a wrong
;; number.
(ck! "widths are not mixed: a scalar load does not fold into a packed op"
     (equal? (peeped '((movsd xmm1 (mem r8 rdi 8 15))
                       (vsubpd xmm2 xmm0 xmm1)
                       (movsd xmm1 (mem rsp #f 1 0))))
             '((movsd xmm1 (mem r8 rdi 8 15))
               (vsubpd xmm2 xmm0 xmm1)
               (movsd xmm1 (mem rsp #f 1 0)))))

(ck! "nor a packed load into a scalar op"
     (equal? (peeped '((vmovupd xmm1 (mem r8 rdi 8 -1))
                       (vsubsd xmm2 xmm0 xmm1)
                       (vmovupd xmm1 (mem rsp #f 1 0))))
             '((vmovupd xmm1 (mem r8 rdi 8 -1))
               (vsubsd xmm2 xmm0 xmm1)
               (vmovupd xmm1 (mem rsp #f 1 0)))))

(ck! "a loaded value still wanted afterwards is not folded away"
     (equal? (peeped '((movsd xmm3 (mem r8 rdi 8 15))
                       (vsubsd xmm4 xmm1 xmm3)
                       (vmulsd xmm5 xmm3 xmm3)))
             '((movsd xmm3 (mem r8 rdi 8 15))
               (vsubsd xmm4 xmm1 xmm3)
               (vmulsd xmm5 xmm3 xmm3))))

;; --- half-register writes ---------------------------------------------------
;;
;; SLP puts a PAIR in one xmm, so "this register is overwritten" has to mean all
;; 128 bits of it. `sqrtsd d, s` and the REGISTER form of `movsd` write the low
;; half and leave the high half alone, so neither kills what was there. Getting
;; this wrong deletes a definition whose high lane is still read.

(ck! "a register-to-register movsd MERGES, so it does not kill the high lane"
     (equal? (peeped '((vmovupd xmm1 (mem r8 #f 1 0))
                       (movsd xmm1 xmm2)
                       (vunpckhpd xmm3 xmm1 xmm1)))
             '((vmovupd xmm1 (mem r8 #f 1 0))
               (movsd xmm1 xmm2)
               (vunpckhpd xmm3 xmm1 xmm1))))

(ck! "and two-operand sqrtsd merges too"
     (equal? (peeped '((vmovupd xmm0 (mem r8 #f 1 0))
                       (sqrtsd xmm0 xmm3)
                       (vunpckhpd xmm1 xmm0 xmm0)))
             '((vmovupd xmm0 (mem r8 #f 1 0))
               (sqrtsd xmm0 xmm3)
               (vunpckhpd xmm1 xmm0 xmm0))))

;; A movsd FROM MEMORY zeroes the upper half, so that one really does kill.
(ck! "a movsd from memory zeroes the high lane, so it does kill"
     (equal? (peeped '((vmovupd xmm1 (mem r8 #f 1 0))
                       (movsd xmm1 (mem r9 #f 1 0))
                       (vunpckhpd xmm3 xmm1 xmm1)))
             '((movsd xmm1 (mem r9 #f 1 0))
               (vunpckhpd xmm3 xmm1 xmm1))))

;; A three-address VEX op writes ALL of its destination -- that is what having a
;; separate first source means -- so it kills, and the copy before it is dead.
(ck! "a three-address VEX write kills its destination"
     (equal? (peeped '((movsd xmm3 xmm2)
                       (vmulsd xmm3 xmm0 xmm0)
                       (vaddsd xmm4 xmm3 xmm1)))
             '((vmulsd xmm3 xmm0 xmm0) (vaddsd xmm4 xmm3 xmm1))))

;; --- read, modify, write, through the scratch -------------------------------

;; Each fixture ends in a TRANSFER, which is what a real run ends in --
;; `peephole-runs` splits the listing at every label, so a run that simply stops
;; is a shape the pass never sees and is not worth widening `dead-from?` for.
(ck! "a spilled counter incremented in place becomes one instruction"
     (equal? (peeped '((mov rax (mem rsp #f 1 48))
                       (add rax (imm 1))
                       (mov (mem rsp #f 1 48) rax)
                       (mov rcx r9)
                       (jmp (label L))))
             '((add (mem rsp #f 1 48) (imm 1)) (mov rcx r9) (jmp (label L)))))

(ck! "and subtraction, which is the other shape a counter takes"
     (equal? (peeped '((mov rax (mem rsp #f 1 8))
                       (sub rax (imm 4))
                       (mov (mem rsp #f 1 8) rax)
                       (mov rcx r9)
                       (jmp (label L))))
             '((sub (mem rsp #f 1 8) (imm 4)) (mov rcx r9) (jmp (label L)))))

;; The store must be to the SAME address. Two different slots are a copy with
;; arithmetic in the middle, not a read-modify-write, and folding it would drop
;; the write to one of them.
(ck! "a different slot is not a read-modify-write and is left alone"
     (equal? (peeped '((mov rax (mem rsp #f 1 48))
                       (add rax (imm 1))
                       (mov (mem rsp #f 1 56) rax)
                       (mov rcx r9)
                       (jmp (label L))))
             '((mov rax (mem rsp #f 1 48))
               (add rax (imm 1))
               (mov (mem rsp #f 1 56) rax)
               (mov rcx r9)
               (jmp (label L)))))

;; The address must not be built out of the register the load overwrites, or
;; the two memory references are not the same place at all.
(ck! "an address built from the loaded register is refused"
     (equal? (peeped '((mov rax (mem rax #f 1 0))
                       (add rax (imm 1))
                       (mov (mem rax #f 1 0) rax)
                       (mov rcx r9)
                       (jmp (label L))))
             '((mov rax (mem rax #f 1 0))
               (add rax (imm 1))
               (mov (mem rax #f 1 0) rax)
               (mov rcx r9)
               (jmp (label L)))))

;; A NON-scratch register carrying the value must still be proved dead, because
;; an allocated value can be live across a call and a scratch cannot.
(ck! "with a non-scratch register the value must be visibly dead"
     (equal? (peeped '((mov rbx (mem rsp #f 1 48))
                       (add rbx (imm 1))
                       (mov (mem rsp #f 1 48) rbx)
                       (mov rcx rbx)))
             '((mov rbx (mem rsp #f 1 48))
               (add rbx (imm 1))
               (mov (mem rsp #f 1 48) rbx)
               (mov rcx rbx))))

;; --- the scratch is dead at a boundary, except at a ret ---------------------
;;
;; regs.ss keeps the scratches out of every allocatable pool so that no live
;; range can occupy one, and the convention passes no argument in one. So
;; nothing can be reading a scratch across a call or a branch -- which is what
;; lets the fold above fire when a call follows it.

(ck! "a scratch is dead across a call, so the fold still fires before one"
     (equal? (peeped '((mov rax (mem rsp #f 1 48))
                       (add rax (imm 1))
                       (mov (mem rsp #f 1 48) rax)
                       (call (label f))))
             '((add (mem rsp #f 1 48) (imm 1)) (call (label f)))))

;; rax IS the return register, so a value there at a `ret` is the result. This
;; is the one boundary where a scratch is emphatically live.
(ck! "but a scratch is LIVE at a ret: that is the return value"
     (equal? (peeped '((mov rax rbx) (ret)))
             '((mov rax rbx) (ret))))

;; --- THE PASS IS NOT INERT ON A REAL PROGRAM --------------------------------
;;
;; Fixtures cannot catch inertness: each tests the shape it was written for,
;; which the rule it exercises by construction handles. D132 is the case -- a
;; pass that did nothing on RV64 for two entries, invisible because every check
;; here asks whether the output is CORRECT and none asked whether the pass did
;; ANYTHING.
;;
;; peephole cannot be asserted from the finished code: after it runs, running it
;; again finds nothing, so a working pass and a removed one look identical. It is
;; asserted on the listing it is HANDED, captured through the stage hook.
;;
;; The run-splitting is repeated here rather than imported. `peephole` expects a
;; straight-line run and raises on a label -- which is why `finalize.ss` calls it
;; through `peephole-runs` -- and an oracle that reuses the implementation it
;; checks is not an oracle (D133).
(define captured #f)
(parameterize ((compile-stage-hook
                (lambda (stage prog)
                  (unless captured
                    (when (eq? stage 'listing/pre-peephole) (set! captured prog))))))
  (compile-sonic "../bench/nbody/config-sonic.sps" nbody-externs))

(ck! "the stage hook delivered nbody's pre-peephole listing" (and captured #t))

(when captured
  (let loop ((xs captured) (run '()) (fused 0))
    (cond
     ((null? xs)
      (let-values (((done st) (peephole 'x86-64 (reverse run))))
        (let ((total (+ fused (peephole-stats-fused st))))
          (ck! "peephole rewrites something in nbody: the pass is not inert"
               (> total 0))
          (unless (> total 0)
            (display "       fused=") (display total) (newline)))))
     ((symbol? (car xs))
      (let-values (((done st) (peephole 'x86-64 (reverse run))))
        (loop (cdr xs) '() (+ fused (peephole-stats-fused st)))))
     (else (loop (cdr xs) (cons (car xs) run) fused)))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
