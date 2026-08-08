(import (chezscheme) (sonic peephole))

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

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
