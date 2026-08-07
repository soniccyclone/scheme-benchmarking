;;; Instruction selection framework.
;;;
;;; E2-SEL. Target-parametric: this file walks Lmach and calls a target's rule
;;; table; it contains no x86-64 and no RV64 knowledge whatsoever.
;;;
;;; That split is not tidiness. `nbody-inner-mach` in sonic/src/sonic/fixtures.ss
;;; is E2-LIR's acceptance criterion precisely because BOTH selectors consume
;;; that one value, so anything target-specific leaking in here would silently
;;; make the two back ends consume different things.
;;;
;;; ## What a target supplies
;;;
;;; A rule table: an alist from Lmach op name to a procedure
;;;
;;;     (lambda (dst sc srcs) -> list of target instructions)
;;;
;;; plus a name and the register partition it enforces. A target instruction is
;;; an opaque list here; the encoder gives it meaning. This module only cares
;;; that selection is TOTAL over the ops the program actually uses, and it fails
;;; loudly when it is not, because a missing rule that silently emits nothing is
;;; a wrong-code bug that surfaces as a crash somewhere else entirely.

(library (sonic select)
  (export make-selector selector? selector-name selector-rules selector-partition
          select-instr select-block select-program
          selector-covers?  missing-rules selector-owed
          program-vreg-classes current-vreg-classes vreg-class
          tail-call-instr)
  ;; (chezscheme) rather than the (rnrs ...) pieces: nanopass needs Chez's
  ;; syntax anyway, and importing both collides on syntax-rules.
  (import (chezscheme)
          (nanopass)
          (sonic lang))

  (define-record-type (selector make-selector selector?)
    (fields name rules partition))

  (define (rule-for sel op)
    (let ((p (assq op (selector-rules sel))))
      (and p (cdr p))))

  ;; --- coverage, checked before selection rather than during ---------------
  ;;
  ;; Ask "can this target select every op in this program" as a QUESTION, so a
  ;; port in progress can report what it still owes instead of dying on the
  ;; first gap. `select-program` still refuses to run on an uncovered program.

  ;; Accepts either a nanopass record or the datum `lower.ss` produces, because
  ;; both are legitimate inputs: fixtures are built through the grammar and the
  ;; lowering pass emits a datum for the reason its header gives.
  (define (as-datum prog) (if (pair? prog) prog (unparse-Lmach prog)))

  (define (program-ops prog)
    (let walk ((x (as-datum prog)) (acc '()))
      (cond ((and (pair? x) (symbol? (car x)))
             (walk (cdr x) (cons (car x) acc)))
            ((pair? x) (walk (car x) (walk (cdr x) acc)))
            (else acc))))

  ;; A rule that RAISES is not coverage. Both target agents used raising rules
  ;; for the things they could not implement yet -- flonum constants needing a
  ;; literal pool, integer division needing the rdx:rax pair -- which is honest,
  ;; but it made `selector-covers?` overstate readiness: it checked rule
  ;; PRESENCE, not success.
  ;;
  ;; A target declares those explicitly instead, so "I have no rule" and "I have
  ;; a rule that cannot run yet" are different answers to a caller bringing up a
  ;; second back end.
  (define (selector-owed sel)
    (let ((p (assq '%owed (selector-rules sel))))
      (if p (cdr p) '())))

  (define (missing-rules sel prog)
    (let ((ops (filter mach-op? (program-ops prog))))
      (let ((owed (selector-owed sel)))
        (let loop ((os ops) (missing '()))
          (cond ((null? os) (reverse missing))
                ((memq (car os) missing) (loop (cdr os) missing))
                ;; declared-owed counts as missing, because it is
                ((memq (car os) owed) (loop (cdr os) (cons (car os) missing)))
                ((rule-for sel (car os)) (loop (cdr os) missing))
                (else (loop (cdr os) (cons (car os) missing))))))))

  (define (selector-covers? sel prog) (null? (missing-rules sel prog)))

  ;; --- what class is this vreg? ---------------------------------------------
  ;;
  ;; An Lmach instruction states the storage class of the value it DEFINES, and
  ;; nothing else. That is enough for every rule that reads its operands as
  ;; anonymous registers, and it is not enough for a call: `(call v sc f a b c)`
  ;; carries one class, the destination's, while the calling convention needs
  ;; the class of every argument, because the argument registers are three
  ;; disjoint pools rather than one list (sonic/src/sonic/callconv.ss).
  ;;
  ;; The classes are not missing, only elsewhere: each argument is defined by
  ;; some instruction in the program, and that instruction states its class. So
  ;; we build the map once per program and let a rule ask.
  ;;
  ;; A parameter rather than a fourth rule argument, because the rule signature
  ;; is the contract every target already implements and widening it for the one
  ;; op that needs it would touch every rule in both tables plus the toy target
  ;; the framework test uses to prove target-independence.
  (define current-vreg-classes (make-parameter #f))

  ;; A vreg with no defining instruction entered from outside the instruction
  ;; stream: a procedure parameter, or a top-level binding. Lmach has no
  ;; parameter list, so there is nowhere for its class to be written down.
  ;; `tagged` is the right default and not merely the safe one -- anything that
  ;; crosses a procedure boundary in this compiler without a declared unboxed
  ;; representation is a Scheme object -- but it IS a default, and the day Lmach
  ;; grows block parameters this should read them instead.
  (define (vreg-class v)
    (let ((tbl (current-vreg-classes)))
      (or (and tbl (hashtable-ref tbl v #f)) 'tagged)))

  ;; The one instruction whose destination slot does NOT define a value of the
  ;; stated class: a store's `sc` is the class of the element being stored and
  ;; its destination slot holds the base address, which is a different thing.
  ;; Recording it would tell a caller that an flvector is a double.
  (define (defines-class? i) (not (memq (car i) '(store chk))))

  (define (program-vreg-classes prog)
    (let ((tbl (make-eq-hashtable)))
      (for-each
       (lambda (lb)
         (let ((blk (cadr lb)))
           (for-each
            (lambda (i)
              (when (and (defines-class? i) (symbol? (cadr i)))
                (hashtable-set! tbl (cadr i) (caddr i))))
            (cadr blk))))
       (cadr (as-datum prog)))
      tbl))

  ;; --- tail calls -----------------------------------------------------------
  ;;
  ;; Lmach has no `tailcall`. lower.ss turns Lanf's tailcall into an ordinary
  ;; call whose result is the block's returned vreg, so the shape survives even
  ;; though the name did not: a block ending in `(call v sc f a ...)` with the
  ;; transfer `(ret v)` IS a tail call, and nothing else has that shape, because
  ;; v is defined by the last instruction and consumed by the transfer.
  ;;
  ;; Recognising it here rather than adding a production to Lmach keeps the
  ;; frozen language frozen. The cost is that a call separated from its `ret` by
  ;; even one instruction is not recognised, which is conservative in the safe
  ;; direction: it emits a call where a jump would have done.
  ;;
  ;; Target-independent, so it belongs here. What to EMIT for one is the
  ;; target's business, and it asks for it by the rule name `tailcall`.
  (define (tail-call-instr blk)
    (let ((instrs (cadr blk)) (transfer (caddr blk)))
      (and (pair? instrs)
           (eq? (car transfer) 'ret)
           (let ((last (car (reverse instrs))))
             (and (eq? (car last) 'call)
                  (eq? (cadr last) (cadr transfer))
                  last)))))

  ;; --- selection ------------------------------------------------------------

  (define (select-instr sel i)
    ;; `i` is an unparsed Lmach Instr. Three shapes: (op dst sc src ...),
    ;; (const dst sc datum), (chk name control expected-tag src ...).
    (let ((head (car i)))
      (cond
       ((eq? head 'const)
        (let ((r (rule-for sel 'const)))
          (unless r (error 'select-instr "target has no rule for const" (selector-name sel)))
          (r (cadr i) (caddr i) (list (cadddr i)))))
       ((eq? head 'chk)
        ;; A check that survived the analysis. It reaches the target as a real
        ;; instruction sequence, and the target decides its shape. `proved`
        ;; must never arrive here: the elision pass drops those, so seeing one
        ;; means a pass upstream is broken and we say so rather than emitting
        ;; a check the analysis already discharged.
        (when (eq? (caddr i) 'proved)
          (error 'select-instr
                 "a `proved` check reached selection; the elision pass should have dropped it"
                 i))
        (let ((r (rule-for sel 'chk)))
          (unless r (error 'select-instr "target has no rule for chk" (selector-name sel)))
          ;; The expected tag is passed through as the first source, so a rule
          ;; that needs it has it and one that does not can ignore it.
          (r (cadr i) (caddr i) (cdddr i))))
       (else
        (let ((r (rule-for sel head)))
          (unless r
            (error 'select-instr "target has no rule for op" (selector-name sel) head))
          (r (cadr i) (caddr i) (cdddr i)))))))

  (define (select-block sel blk)
    ;; blk unparsed: (block (instr ...) transfer)
    (let* ((instrs (cadr blk))
           (transfer (caddr blk))
           ;; A tail call is taken only when the target says how to emit one.
           ;; A target with no `tailcall` rule keeps the old behaviour, which is
           ;; correct code that happens to stack a frame it did not need.
           (tc (and (rule-for sel 'tailcall) (tail-call-instr blk))))
      (if tc
          (let ((body (reverse (cdr (reverse instrs))))
                (r (rule-for sel 'tailcall)))
            (append (apply append (map (lambda (i) (select-instr sel i)) body))
                    ;; The jump IS the transfer. Emitting the `ret` rule as well
                    ;; would put dead code after an unconditional jump, and on a
                    ;; target where the return is a register jump it would be a
                    ;; branch to whatever `ra` last held.
                    (r (cadr tc) (caddr tc) (cdddr tc))))
          (append (apply append (map (lambda (i) (select-instr sel i)) instrs))
                  (let ((r (rule-for sel (car transfer))))
                    (unless r
                      (error 'select-block "target has no rule for transfer"
                             (selector-name sel) (car transfer)))
                    (r #f #f (cdr transfer)))))))

  (define (select-program sel prog)
    (let ((missing (missing-rules sel prog)))
      (unless (null? missing)
        (error 'select-program "target cannot select these ops"
               (selector-name sel) missing)))
    (let* ((p (as-datum prog))
           (blocks (cadr p))
           (entry (caddr p)))
      ;; The class map is a property of the whole program, so it is built once
      ;; here and read by whichever rules need it -- today, the call sequence.
      (parameterize ((current-vreg-classes (program-vreg-classes p)))
        (list 'selected (selector-name sel) entry
              (map (lambda (lb) (list (car lb) (select-block sel (cadr lb)))) blocks)))))
  )
