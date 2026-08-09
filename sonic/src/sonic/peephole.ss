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
  (import (chezscheme))

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
                  (fuse-index
                   (fuse-copy-imul
                    (fuse-lea
                    (fold-immediates
                     (fuse-sub-neg (fuse-compare-branch instrs stats) stats)
                     stats)
                     stats)
                    stats)
                   stats)
                  instrs)
              stats)))
  )
