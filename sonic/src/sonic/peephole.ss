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
  (define (fuse-compare-branch instrs stats)
    (let loop ((is instrs) (out '()))
      (cond
       ((null? is) (reverse out))
       ;; look for setcc immediately after a cmp, with the branch next
       ((and (pair? is) (pair? (cdr is)) (pair? (cddr is)) (pair? (cdddr is))
             (eq? (car (car is)) 'cmp)
             (jump-for (car (cadr is)))
             (eq? (car (caddr is)) 'cmp)
             (memq (car (cadddr is)) '(jne je))
             ;; the setcc's destination is what the second cmp tests
             (eq? (cadr (cadr is)) (cadr (caddr is)))
             ;; and it is dead after the branch
             (not (used-later? (cadr (cadr is)) (cddddr is))))
        (let* ((cmp (car is))
               (setcc (cadr is))
               (branch (cadddr is))
               (jmp (jump-for (car setcc)))
               ;; (jne L) on a boolean means "branch when the cc held";
               ;; (je L) means the opposite, so the jump inverts.
               (j (if (eq? (car branch) 'jne) jmp (invert jmp))))
          (peephole-stats-fused-set! stats (+ 1 (peephole-stats-fused stats)))
          (loop (cddddr is) (cons (list j (cadr branch)) (cons cmp out)))))
       (else (loop (cdr is) (cons (car is) out))))))

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
               (and (eq? (cadr (cadr is)) t)
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

  (define (peephole target instrs)
    (let ((stats (make-peephole-stats 0)))
      (values (if (needs-fusion? target)
                  (fuse-sub-neg (fuse-compare-branch instrs stats) stats)
                  instrs)
              stats)))
  )
