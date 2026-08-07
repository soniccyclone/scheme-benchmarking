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
  (export lower-program lower-expr lower-toplevel
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
      (vector-ref . load) (vector-set! . store)
      ;; Allocation and anything else with no single machine op becomes a call
      ;; into the runtime. `alloc.ss` owns the fast path and `gc.ss` the slow
      ;; one, and neither is expressible as one Lmach instruction: the claim,
      ;; the fill and the restart region are a sequence, and inlining that here
      ;; would duplicate a decision those files already made.
      (make-flvector . call) (make-vector . call)
      (cons . call) (car . call) (cdr . call) (error . call)
      (null? . call) (pair? . call) (eq? . call)
      (fixnum? . call) (flonum? . call) (vector? . call) (flvector? . call)))

  ;; numeric.ss fixes a 3-bit tag scheme with fixnum at 000. A type check needs
  ;; to name which tag it expects; the other checks have no such constant.
  (define (expected-tag name) (if (eq? name 'type-check) 1 0))

  ;; A literal's storage class follows its TYPE, and hardcoding raw-word was a
  ;; real bug: (define days-per-year 365.24) lowered to (const t raw-word
  ;; 365.24), so a double was declared an integer. The allocator would then put
  ;; it in a GPR and every arithmetic instruction reading it would be the wrong
  ;; one -- integer add on a bit pattern that is an IEEE double.
  ;;
  ;; Same rule as repr.ss's datum-class, restated here rather than imported
  ;; because lower.ss must not depend on an analysis pass: the two are checked
  ;; against each other in repr-test.ss.
  (define (const-class d)
    (cond ((flonum? d) 'raw-f64)
          ((and (integer? d) (exact? d)) 'raw-word)
          (else 'tagged)))

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
  ;; Which operands a check actually wants, and where the limit comes from.
  ;;
  ;; `lower` used to hand every check the WHOLE primcall's operand list, so a
  ;; bounds check on (flvector-set! v i x) arrived with three operands where
  ;; both targets read two -- and the limit it wanted, the vector's length, was
  ;; not in the IR at all. The primcall carries the vector, not its length.
  ;;
  ;; So a bounds check emits a `vlen` first to materialise the limit, then
  ;; compares the index against it. A type check wants only the value. Overflow
  ;; and division checks want the operands they guard.
  (define (check-operands name srcs)
    (case name
      ;; (vector-ref v i) / (vector-set! v i x): index is operand 2, vector is 1
      ((bounds-check) (list (cadr srcs) (car srcs)))
      ((type-check)   (list (car srcs)))
      (else srcs)))

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
               ;; The expected tag rides on the instruction. Only type-check
               ;; uses it; everything else passes 0, because there is no
               ;; constant a bounds or overflow check compares against.
               (let ((ops (check-operands name srcs)))
                 (if (eq? name 'bounds-check)
                     ;; Materialise the limit, then check the index against it.
                     (let ((lim (fresh! "len")))
                       (loop (cdr cs)
                             (cons `(chk bounds-check checked 0 ,(car ops) ,lim)
                                   (cons `(vlen ,lim raw-word ,(cadr ops)) out))))
                     (loop (cdr cs)
                           (cons `(chk ,name checked ,(expected-tag name) ,@ops)
                                 out)))))
              (else (error 'lower "unknown control" ctl)))))))

  ;; --- blocks ---------------------------------------------------------------
  ;;
  ;; Lrepr is a tree and Lmach is a CFG, so `if` is where the shape actually
  ;; changes. Each arm becomes its own labelled block and the test becomes a
  ;; `branch-if` transfer; the join is a third block both arms jump to.
  ;;
  ;; Blocks accumulate in a mutable list rather than being threaded, because the
  ;; alternative is passing a block list through every return and the walk
  ;; already returns two values.

  (define blocks '())
  (define (emit-block! lbl instrs transfer)
    (set! blocks (cons (list lbl (list 'block (reverse instrs) transfer)) blocks)))
  (define (reset-blocks!) (set! blocks '()))

  ;; --- the walk -------------------------------------------------------------
  ;; Returns (values instrs result-vreg) for straight-line code, and emits
  ;; blocks as a side effect where control flow forces a split.

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
                     (values (reverse (cons `(const ,v ,(const-class (cadr e)) ,(cadr e)) acc)) v)))
          ((void)  (let ((v (fresh! "k")))
                     (values (reverse (cons `(const ,v raw-word ()) acc)) v)))
          ;; Control flow. The accumulated straight-line instructions become the
          ;; current block, ending in a branch; each arm gets a label; both
          ;; converge on a join block whose only job is to be the continuation.
          ((if)
           (let* ((test (cadr e))
                  (then-lbl (fresh! "L.then"))
                  (else-lbl (fresh! "L.else"))
                  (join-lbl (fresh! "L.join"))
                  (cur (fresh! "L.cur")))
             (emit-block! cur acc (list 'branch-if test then-lbl else-lbl))
             (let-values (((t-is t-v) (lower-expr (caddr e) stats)))
               (emit-block! then-lbl (reverse t-is) (list 'jump join-lbl)))
             (let-values (((e-is e-v) (lower-expr (cadddr e) stats)))
               (emit-block! else-lbl (reverse e-is) (list 'jump join-lbl)))
             ;; The join carries no instructions of its own. A phi would live
             ;; here; Lmach has none, so the arms' results are already in the
             ;; vregs the analysis named and nothing needs merging.
             (values '() join-lbl)))
          ;; Premises and policies carry no code. They constrained the ANALYSIS,
          ;; which has already run and left its answers in the controls, so by
          ;; here they are annotation and the body is the program. Dropping them
          ;; is not losing information -- keeping them would be, since nothing
          ;; downstream reads them and a stale premise outliving its analysis is
          ;; how a wrong assumption gets reused.
          ;; All three are (form <annotation> body), so the body is caddr.
          ((declare declare-distinct policy)
           (walk (caddr e) acc))
          ;; phi and sigma are SSA bookkeeping, not code.
          ;;
          ;; A phi says "this name is the merge of these values". Lmach has no
          ;; phi, and it does not need one here: the arms already wrote their
          ;; results into the vregs the analysis named, so the merge is a
          ;; register that is already correct on both paths. Emitting moves for
          ;; it would be out-of-SSA translation, which matters once the
          ;; allocator can split live ranges and does not yet.
          ;;
          ;; sigma is pure annotation -- a name for a fact on one edge -- so it
          ;; becomes a move from the refined name to the original, which the
          ;; allocator then coalesces away.
          ((phi)
           (let loop ((bs (cadr e)) (out acc))
             (if (null? bs)
                 (walk (caddr e) out)
                 (let* ((b (car bs)) (x (car b))
                        (first-val (cadr (cadr b))))   ; (x (pred val) ...)
                   (loop (cdr bs)
                         (if (symbol? first-val)
                             (cons `(move ,x raw-word ,first-val) out)
                             out))))))
          ((sigma)
           ;; (sigma x-out x-in cmp x-other negated? body)
           (walk (list-ref e 6) (cons `(move ,(cadr e) raw-word ,(caddr e)) acc)))
          ((letrec)
           ;; Each binding becomes its own labelled block, then the body runs.
           (for-each
            (lambda (b)
              (let ((x (car b)) (v (cadr b)))
                (let-values (((is r) (lower-expr (if (and (pair? v) (eq? (car v) 'lambda))
                                                     (caddr v) v)
                                                 stats)))
                  (emit-block! x (reverse is) (list 'ret r)))))
            (cadr e))
           (walk (caddr e) acc))
          ((lambda)
           ;; A lambda in value position: its own block, and the value is the
           ;; label. Closures are a later bead; this is enough for a program
           ;; whose procedures are all top-level or letrec-bound.
           (let ((lbl (fresh! "L.fn")))
             (let-values (((is r) (lower-expr (caddr e) stats)))
               (emit-block! lbl (reverse is) (list 'ret r)))
             (values (reverse acc) lbl)))
          ((seq)
           (let-values (((a av) (lower-expr (cadr e) stats)))
             (let-values (((b bv) (lower-expr (caddr e) stats)))
               (values (append (reverse acc) a b) bv))))
          ;; Lmach has no `tailcall` production, so the name is lost here. The
          ;; SHAPE is not: the call is the block's last instruction and its
          ;; result is what the block's `(ret v)` returns, and nothing else has
          ;; that shape, because v is defined by the last instruction and
          ;; consumed by the transfer. `tail-call-instr` in
          ;; sonic/src/sonic/select.ss recognises it and the targets emit a jump
          ;; rather than a call, which is what makes tail calls proper.
          ;;
          ;; So do NOT insert anything between this call and the transfer, and
          ;; do not name the result something the transfer will not return. Both
          ;; would silently turn every loop iteration back into a stacked frame.
          ((tailcall)
           (let ((v (fresh! "t")))
             (values (reverse (cons `(call ,v raw-word ,@(cdr e)) acc)) v)))
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
        ;; The binding's declared class wins where it is not raw-word, since
        ;; repr.ss computed it from the same rule; otherwise fall back to the
        ;; datum's own type, which is what catches a flonum lowered as a word.
        ((quote) (values `((const ,dst ,(if (eq? sc 'raw-word) (const-class (cadr se)) sc)
                                  ,(cadr se))) dst))
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
      (reset-blocks!)
      (let-values (((instrs result) (lower-expr e stats)))
        (values `(program ((,name (block ,instrs (ret ,result))) ,@blocks) ,name)
                stats))))

  ;; Whole program. Each top-level binding whose value is a lambda becomes its
  ;; own labelled function; everything else is initialization that runs before
  ;; the body, in source order, because a later definition may read an earlier
  ;; one.
  (define (lower-toplevel p name)
    ;; The entry block gets a FRESH label, not `name`. A top-level binding may
    ;; itself be called `main`, and two blocks with one label make the program
    ;; ambiguous in a way nothing downstream can detect: selection walks both
    ;; and the second silently wins.
    (let ((stats (make-lower-stats 0 0 0))
          (entry (fresh! (string-append (symbol->string name) ".entry"))))
      (reset-blocks!)
      (let* ((form (if (pair? p) p (unparse-Lrepr p))))
        (unless (eq? (car form) 'top)
          (error 'lower-toplevel "not a top-level program" form))
        (let ((binds (cadr form)) (body (cadddr form)) (init '()))
          (for-each
           (lambda (b)
             (let ((x (car b)) (v (cadr b)))
               (if (and (pair? v) (eq? (car v) 'lambda))
                   ;; A defined procedure: its own block, named for the binding.
                   (let-values (((is r) (lower-expr (caddr v) stats)))
                     (emit-block! x (reverse is) (list 'ret r)))
                   ;; A value: initialization, in source order.
                   (let-values (((is r) (lower-simple-or-expr v x stats)))
                     (set! init (append init is))))))
           binds)
          (let-values (((bis bres) (lower-expr body stats)))
            (let ((prog `(program ((,entry (block ,(append init bis) (ret ,bres)))
                                   ,@blocks)
                                  ,entry)))
              ;; Duplicate labels are a wrong-code bug, so say so here rather
              ;; than letting selection pick one arbitrarily.
              (let dup ((ls (map car (cadr prog))) (seen '()))
                (cond ((null? ls) 'ok)
                      ((memq (car ls) seen)
                       (error 'lower-toplevel "duplicate block label" (car ls)))
                      (else (dup (cdr ls) (cons (car ls) seen)))))
              (values prog stats)))))))

  (define (lower-simple-or-expr v x stats)
    (if (and (pair? v)
             (memq (car v) '(let if seq tailcall letrec lambda phi sigma
                             declare declare-distinct policy)))
        (lower-expr v stats)
        (lower-simple v x 'raw-word stats)))
  )
