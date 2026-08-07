;;; Two-address fixup, over Lmach, before selection.
;;;
;;; E2-2ADDR. Lmach is three-address, `(op dst sc src1 src2)`, because RV64 is
;;; and because a machine-independent IR should not carry one ISA's register
;;; pressure. Every x86-64 ALU and SSE arithmetic instruction is two-address and
;;; destructive: `subsd dst, src` computes `dst := dst - src`. So each Lmach
;;; arithmetic op has to become a copy plus an operate, and there are four
;;; cases. sonic/src/sonic/target-x86-64.ss handles three of them inside the
;;; rule, because each has an instruction-local answer:
;;;
;;;   dst = src1                the copy is dead, emit the operate alone
;;;   dst = src2, commutative   swap the operands, emit the operate alone
;;;   dst = src2, integer sub   `sub dst, src1` then `neg dst`, exact in two's
;;;                             complement including the most negative value
;;;
;;; The fourth has no instruction-local answer. `dst = src2` for a
;;; non-commutative op needs somewhere to stand the left operand up, and a rule
;;; cannot ask for a register: a rule returns instructions and nothing else, and
;;; the allocator runs over Lmach and never sees selected output. So the rule
;;; refuses loudly and this pass is where the break happens instead.
;;;
;;; ## Why a scratch register rather than a fresh vreg
;;;
;;; A fresh vreg would work and would be the textbook answer, but it hands the
;;; allocator a new live range in the class that is already tightest, and it
;;; obliges every caller to extend its storage-class table with a name this pass
;;; invented. sonic/src/sonic/regs.ss instead takes `rax` and `xmm15` out of the
;;; allocatable pools on x86-64 and `t0`, `t1` and `ft11` on RV64, and says in
;;; as many words that they exist for address temporaries and two-address
;;; fixups. That reservation is only worth paying for if something uses it.
;;;
;;; The cost is that a physical register name now appears in an Lmach stream
;;; whose other operands are virtual, and `live-intervals` in
;;; sonic/src/sonic/regalloc.ss cannot tell the difference: it treats every
;;; symbol in an operand slot as a vreg. `strip-scratch` below is the adapter.
;;; Blanking the scratch operands rather than deleting the instructions is what
;;; keeps the live ranges of the real vregs exactly right.
;;;
;;; ## Aliasing is a vreg-level fact here, and that is sufficient
;;;
;;; This pass compares vreg names, not physical registers, because selection
;;; also runs on vregs: the x86-64 rule table sees `(sub v-x raw-f64 v-a v-x)`
;;; and it is that comparison the rule cannot serve. The allocator cannot
;;; introduce a new alias afterwards, because `dst` and `src2` of one
;;; instruction are simultaneously live by construction: linear scan expires an
;;; interval only when its end is strictly before the new interval's start, and
;;; here they are equal. So a fixup that is right on vregs is right on machine
;;; registers.
;;;
;;; ## RV64 does not need this pass
;;;
;;; RV64 arithmetic is genuinely three-address. `fsub.d rd, rs1, rs2` and
;;; `sub rd, rs1, rs2` write a destination that is unrelated to either source,
;;; so `dst = src2` is not a special case there and there is nothing to fix.
;;; `two-address-target?` says so per target rather than per instruction, and it
;;; RAISES on a target it has never heard of. A new back end that silently got
;;; `#f` from a fallback would emit wrong code for exactly the case this file
;;; exists to catch, which is the worst possible way to learn about a port.
;;;
;;; ## What this deliberately does not do
;;;
;;; It rewrites integer `sub` with `dst = src2` too, even though the x86-64 rule
;;; has the cheaper sub-then-neg for it. Three instructions where two would do.
;;; The alternative is a per-target, per-storage-class table of which cases the
;;; selector can serve in place, which duplicates the rule table's knowledge in
;;; a second file that will drift from it. Recovering the instruction is a
;;; peephole over the selected stream, where the sub-then-neg pattern is
;;; visible, not a special case here.

(library (sonic twoaddr)
  (export twoaddr twoaddr-instrs
          two-address-target? non-commutative-op? needs-fixup?
          scratch-for scratch-register? strip-scratch)
  (import (chezscheme)
          (nanopass)
          (sonic lang)
          (sonic regs))

  ;; nanopass gives no parser with the language definition, so we ask for one.
  ;; The pass works on the unparsed datum (a list of instructions computed at
  ;; run time is not something a nanopass template can splice) and re-parses on
  ;; the way out, so the output is grammar-checked rather than merely
  ;; list-shaped. It also means `select-program`, which calls `unparse-Lmach` on
  ;; its input, can consume this directly.
  (define-parser parse-Lmach Lmach)

  (define (as-arch a)
    (cond ((arch? a) a)
          ((symbol? a) (arch-by-name a))
          (else (error 'twoaddr "not a target architecture" a))))

  ;; --- what needs fixing ----------------------------------------------------

  (define (two-address-target? target)
    (case (arch-name (as-arch target))
      ((x86-64) #t)
      ((rv64)   #f)
      (else (error 'two-address-target?
                   (string-append
                    "unknown target: whether its arithmetic is destructive is "
                    "not something to guess at, because guessing #f emits wrong "
                    "code for the one case this pass exists to catch")
                   (arch-name (as-arch target))))))

  ;; Only the binary arithmetic ops matter. Comparisons on x86-64 lower to
  ;; `cmp` plus `setcc`, which reads both operands before it writes the
  ;; destination, so `dst = src2` is already safe there.
  (define non-commutative-ops '(sub div))

  (define (non-commutative-op? op) (and (memq op non-commutative-ops) #t))

  (define (needs-fixup? target i)
    (and (two-address-target? target)
         (pair? i)
         (non-commutative-op? (car i))
         (let ((dst (cadr i)) (srcs (cdddr i)))
           (and (= (length srcs) 2)
                (vreg? dst)
                (eq? dst (cadr srcs))))))

  ;; --- the scratch registers ------------------------------------------------
  ;;
  ;; regs.ss is the source of truth for WHICH registers are reserved; this table
  ;; only says which reserved register serves which storage class, and it is
  ;; checked against regs.ss on every lookup. A register renamed there and not
  ;; here would otherwise produce a fixup through a register the allocator is
  ;; free to hand out, which is silent corruption.
  (define scratch-table
    '((x86-64 (raw-word . rax)  (raw-f64 . xmm15))
      (rv64   (raw-word . t0)   (raw-f64 . ft11))))

  (define (scratch-for target sc)
    (let* ((arch (as-arch target))
           (row (assq (arch-name arch) scratch-table)))
      (unless row
        (error 'scratch-for "no scratch register table for this target"
               (arch-name arch)))
      (when (eq? sc 'tagged)
        ;; A tagged value parked in a scratch register is a root the collector
        ;; will never find: under D21 it scavenges the value class
        ;; unconditionally and the scratch registers are outside every class.
        ;; The `scratch-live` flag in sonic/doc/gc-metadata.md is what covers a
        ;; window like that, and this pass has no channel to set it, so it
        ;; refuses rather than opening one silently. No Lmach arithmetic is
        ;; tagged today, so this is a guard on a door rather than a limitation.
        (error 'scratch-for
               (string-append
                "refusing to route a tagged value through a scratch register: "
                "it is outside the value class the collector scavenges, and "
                "this pass cannot set the scratch-live flag that would cover it")
               (arch-name arch)))
      (let ((p (assq sc (cdr row))))
        (unless p (error 'scratch-for "no scratch register for this storage class"
                         (arch-name arch) sc))
        (unless (memq (cdr p) (arch-scratch arch))
          (error 'scratch-for
                 "this table names a register regs.ss does not reserve as scratch"
                 (arch-name arch) sc (cdr p)))
        (cdr p))))

  (define (scratch-register? target x)
    (and (symbol? x) (memq x (arch-scratch (as-arch target))) #t))

  ;; --- the rewrite ----------------------------------------------------------

  (define (fixup target i)
    (if (needs-fixup? target i)
        (let* ((op (car i)) (dst (cadr i)) (sc (caddr i))
               (a (car (cdddr i))) (b (cadr (cdddr i)))
               (s (scratch-for target sc)))
          ;; s := a; s := s op b; dst := s.
          ;; The middle instruction is now the `dst = src1` case, which the
          ;; selector emits as a bare destructive operate, and the two moves
          ;; bracket it. `b` is read before `dst` is written, which is the whole
          ;; property the aliased form could not give us.
          (list `(move ,s ,sc ,a)
                `(,op ,s ,sc ,s ,b)
                `(move ,dst ,sc ,s)))
        (list i)))

  ;; A flat instruction list, for callers that hold one rather than a Prog.
  (define (twoaddr-instrs target instrs)
    (if (two-address-target? target)
        (apply append (map (lambda (i) (fixup target i)) instrs))
        instrs))

  (define (rewrite-block target blk)
    ;; (block (i ...) t)
    (list 'block (twoaddr-instrs target (cadr blk)) (caddr blk)))

  (define (rewrite-prog target p)
    ;; (program ((lbl blk) ...) entry)
    (list 'program
          (map (lambda (lb) (list (car lb) (rewrite-block target (cadr lb))))
               (cadr p))
          (caddr p)))

  ;; Accepts a parsed Lmach Prog or the unparsed datum that `lower-program`
  ;; produces, and always returns a parsed Prog, which is what `select-program`
  ;; needs. On a three-address target this is a re-parse and nothing else.
  (define (twoaddr target prog)
    (let* ((arch (as-arch target))
           (d (if (pair? prog) prog (unparse-Lmach prog))))
      (parse-Lmach (if (two-address-target? arch) (rewrite-prog arch d) d))))

  ;; --- the allocator adapter ------------------------------------------------
  ;;
  ;; `live-intervals` reads every symbol in an operand slot as a vreg and
  ;; `allocate` then demands a storage class for it, so a physical scratch name
  ;; reaching it is a crash at best and a renamed scratch at worst. Blank them.
  ;; `#f` is exactly what Lmach already uses for an absent operand, and
  ;; `live-intervals` skips non-symbols in both the destination and the source
  ;; slots, so the surviving intervals are the real vregs' and nothing else.
  ;;
  ;; This is for the ALLOCATOR's input only. The stream that goes to selection
  ;; keeps its scratch names.
  (define (strip-scratch target instrs)
    (let ((arch (as-arch target)))
      (map (lambda (i)
             (map (lambda (x) (if (scratch-register? arch x) #f x)) i))
           instrs)))
  )
