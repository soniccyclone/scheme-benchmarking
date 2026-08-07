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
          selector-covers?  missing-rules selector-owed)
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

  (define (program-ops prog)
    (let walk ((x (unparse-Lmach prog)) (acc '()))
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
    (let ((instrs (cadr blk)) (transfer (caddr blk)))
      (append (apply append (map (lambda (i) (select-instr sel i)) instrs))
              (let ((r (rule-for sel (car transfer))))
                (unless r
                  (error 'select-block "target has no rule for transfer"
                         (selector-name sel) (car transfer)))
                (r #f #f (cdr transfer))))))

  (define (select-program sel prog)
    (let ((missing (missing-rules sel prog)))
      (unless (null? missing)
        (error 'select-program "target cannot select these ops"
               (selector-name sel) missing)))
    (let* ((p (unparse-Lmach prog))
           (blocks (cadr p))
           (entry (caddr p)))
      (list 'selected (selector-name sel) entry
            (map (lambda (lb) (list (car lb) (select-block sel (cadr lb)))) blocks))))
  )
