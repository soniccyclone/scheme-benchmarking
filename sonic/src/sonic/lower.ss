;;; Lowering: Lrepr to Lmach.
;;;
;;; E2-LOWER. The pass that closes the hole between analysis and codegen.
;;;
;;; This bead did not exist in the original breakdown. E2-LIR froze the Lmach
;;; language and shipped the fixture both selectors consume, but nothing
;;; actually lowered into it, so the pipeline had a gap and milestone 1 was
;;; unreachable no matter how good the selectors were.
;;;
;;; Four jobs:
;;;
;;;   1. Flatten the expression tree into basic blocks with an explicit
;;;      transfer. Lrepr is still a tree; Lmach is a CFG.
;;;   2. Turn `let` bindings into vreg definitions carrying their storage class.
;;;      This is where Lrepr's storage classes become Lmach's, and it is what
;;;      the register allocator later reads.
;;;   3. Turn primcalls into mach ops.
;;;   4. Turn each surviving check into a `chk` instruction, and DROP the ones
;;;      the analysis discharged.
;;;
;;; Job 4 is the one that matters and the reason the control vocabulary has
;;; three values rather than two. `proved` means the analysis discharged the
;;; obligation, so no instruction is emitted and the elision is real. `unchecked`
;;; means a policy suppressed it, so no instruction is emitted either — but the
;;; two are counted separately, because "how many checks did we PROVE away"
;;; is the number this whole project exists to produce, and it is not the same
;;; number as "how many did the programmer switch off".

(library (sonic lower)
  (export lower-program lower-expr
          make-lower-stats lower-stats? lower-stats-proved
          lower-stats-unchecked lower-stats-emitted)
  (import (chezscheme)
          (nanopass)
          (sonic lang))

  (define-record-type (lower-stats make-lower-stats lower-stats?)
    (fields (mutable proved) (mutable unchecked) (mutable emitted)))

  ;; primcall name -> Lmach op. Anything absent is not lowerable and says so.
  (define prim->op
    '((fx+ . add) (fx- . sub) (fx* . mul) (fxneg . neg)
      (fxquotient . div)
      (fl+ . add) (fl- . sub) (fl* . mul) (fl/ . div)
      (flneg . neg) (flabs . abs) (flsqrt . sqrt)
      (fx< . cmp-lt) (fx<= . cmp-le) (fx= . cmp-eq)
      (fx>= . cmp-ge) (fx> . cmp-gt)
      (fl< . fcmp-lt) (fl<= . fcmp-le) (fl= . fcmp-eq)
      (fl>= . fcmp-ge) (fl> . fcmp-gt)
      (fx->fl . cvt-f64-from-int) (fl->fx . cvt-int-from-f64)
      (flvector-ref . load) (flvector-set! . store)
      (vector-ref . load) (vector-set! . store)))

  (define (op-for pr)
    (let ((p (assq pr prim->op)))
      (unless p (error 'lower "primitive has no machine op" pr))
      (cdr p)))

  (define counter 0)
  (define (fresh! prefix)
    (set! counter (+ counter 1))
    (string->symbol (string-append prefix (number->string counter))))

  ;; --- checks ---------------------------------------------------------------
  ;; Returns the chk instructions that must be emitted for this primcall, and
  ;; records why each one was or was not.
  (define (checks->instrs controls srcs stats)
    (let loop ((cs controls) (out '()))
      (if (null? cs)
          (reverse out)
          (let* ((pair (car cs)) (name (car pair)) (ctl (cadr pair)))
            (case ctl
              ((proved)
               ;; The analysis discharged it. This is the elision, and it is the
               ;; number the project exists to produce.
               (lower-stats-proved-set! stats (+ 1 (lower-stats-proved stats)))
               (loop (cdr cs) out))
              ((unchecked)
               ;; A policy suppressed it. Also no instruction, and deliberately
               ;; counted apart from `proved`: emitting it would reinstate a
               ;; check the programmer switched off, which is the mechanism D5
               ;; exists to provide, but it is NOT a proof and must not be
               ;; reported as one.
               (lower-stats-unchecked-set! stats (+ 1 (lower-stats-unchecked stats)))
               (loop (cdr cs) out))
              ((checked)
               (lower-stats-emitted-set! stats (+ 1 (lower-stats-emitted stats)))
               (loop (cdr cs) (cons `(chk ,name checked ,@srcs) out)))
              (else (error 'lower "unknown control" ctl)))))))

  ;; --- the walk -------------------------------------------------------------
  ;; Returns (values instrs result-vreg). Straight-line only for now: an `if`
  ;; needs block splitting, which is the next increment and is why `lower-expr`
  ;; is exported separately.

  (define (lower-expr e stats)
    (let walk ((e (if (pair? e) e (unparse-Lrepr e))) (acc '()))
      (cond
       ((symbol? e) (values (reverse acc) e))
       ((not (pair? e)) (error 'lower "not an expression" e))
       (else
        (case (car e)
          ((let)
           ;; (let ([x sc se]) body)
           (let* ((b (car (cadr e)))
                  (x (car b)) (sc (cadr b)) (se (caddr b))
                  (body (caddr e)))
             (let-values (((is v) (lower-simple se x sc stats)))
               (walk body (append (reverse is) acc)))))
          ((quote) (let ((v (fresh! "k")))
                     (values (reverse (cons `(const ,v raw-word ,(cadr e)) acc)) v)))
          ((void)  (let ((v (fresh! "k")))
                     (values (reverse (cons `(const ,v raw-word ()) acc)) v)))
          (else
           ;; a bare simple expression in tail position
           (let ((v (fresh! "t")))
             (let-values (((is r) (lower-simple e v 'raw-word stats)))
               (values (reverse (append (reverse is) acc)) r)))))))))

  ;; Lower one SimpleExpr into instructions defining `dst`.
  (define (lower-simple se dst sc stats)
    (cond
     ((symbol? se) (values `((move ,dst ,sc ,se)) dst))
     ((not (pair? se)) (error 'lower "not a simple expression" se))
     (else
      (case (car se)
        ((quote) (values `((const ,dst ,sc ,(cadr se))) dst))
        ((void)  (values `((const ,dst ,sc ())) dst))
        ((primcall)
         (let* ((pr (cadr se))
                (controls (caddr se))
                (srcs (cdddr se))
                (chks (checks->instrs controls srcs stats))
                (op (op-for pr)))
           (values (append chks (list `(,op ,dst ,sc ,@srcs))) dst)))
        ((call) (values `((call ,dst ,sc ,@(cdr se))) dst))
        (else (error 'lower "cannot lower simple expression" se))))))

  ;; Whole program: one entry block for now.
  ;;
  ;; Returns the program as a DATUM in Lmach's unparsed shape rather than as a
  ;; nanopass record. A nanopass template cannot splice a list of instructions
  ;; computed at run time, and the consumer does not need it to: `select.ss`
  ;; calls `unparse-Lmach` on its input and works on the datum anyway.
  ;;
  ;; The type checking that gives up is bought back by the test, which asserts
  ;; the lowered nbody is EQUAL to `nbody-inner-mach` — a value that was
  ;; constructed through the grammar and therefore is checked. If the shape
  ;; drifts, the comparison fails.
  (define (lower-program e name)
    (let ((stats (make-lower-stats 0 0 0)))
      (let-values (((instrs result) (lower-expr e stats)))
        (values `(program ((,name (block ,instrs (ret ,result)))) ,name)
                stats))))
  )
