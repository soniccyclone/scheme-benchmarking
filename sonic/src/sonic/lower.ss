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
  (export lower-program lower-expr lower-toplevel lowered-classes
          make-lower-stats lower-stats? lower-stats-proved
          lower-stats-unchecked lower-stats-emitted)
  (import (chezscheme)
          (sonic repr)
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

  ;; Returns two lists: instructions that must run BEFORE the operation, and
  ;; instructions that must run after it.
  ;;
  ;; Most checks are preconditions -- a bounds check exists precisely so the
  ;; load never happens with a bad index, and emitting it afterwards would be
  ;; the out-of-bounds access it was meant to prevent. Overflow is the
  ;; exception and is inherently a POSTcondition: neither RV64 nor x86-64 can
  ;; answer "did this add overflow" without the sum, and the sum is the
  ;; operation's own destination. So it is emitted after, with `dst` appended
  ;; as the third operand.
  ;;
  ;; This is safe in a way a late bounds check would not be: a wrapped add has
  ;; produced a wrong number but has not touched memory, so trapping one
  ;; instruction later observes nothing that has escaped.
  (define (checks->instrs controls srcs dst stats)
    (let loop ((cs controls) (out '()) (post '()))
      (if (null? cs)
          (values (reverse out) (reverse post))
          (let* ((pair (car cs)) (name (car pair)) (ctl (cadr pair)))
            (case ctl
              ((proved)
               ;; The analysis discharged it. This is the elision, and it is the
               ;; number the project exists to produce.
               (lower-stats-proved-set! stats (+ 1 (lower-stats-proved stats)))
               (loop (cdr cs) out post))
              ((unchecked)
               ;; A policy suppressed it. Also no instruction, and deliberately
               ;; counted apart from `proved`: emitting it would reinstate a
               ;; check the programmer switched off, which is the mechanism D5
               ;; exists to provide, but it is NOT a proof and must not be
               ;; reported as one.
               (lower-stats-unchecked-set! stats (+ 1 (lower-stats-unchecked stats)))
               (loop (cdr cs) out post))
              ((checked)
               ;; fp-contract is a PERMISSION, not a check. `checked` for it
               ;; means the conservative obligation is in force -- round twice,
               ;; do not fuse -- which is a constraint on how arithmetic is
               ;; SELECTED, not an instruction to emit. Emitting a chk for it
               ;; asks the target for a branch that tests nothing, and both
               ;; selectors correctly refuse.
               ;;
               ;; It is consumed here and counted apart, so the report still
               ;; says how many operations ran under strict IEEE.
               (when (eq? name 'fp-contract)
                 (lower-stats-emitted-set! stats (lower-stats-emitted stats)))
               (lower-stats-emitted-set! stats (+ 1 (lower-stats-emitted stats)))
               ;; The expected tag rides on the instruction. Only type-check
               ;; uses it; everything else passes 0, because there is no
               ;; constant a bounds or overflow check compares against.
               (let ((ops (check-operands name srcs)))
                 (cond
                  ;; A permission, not an instruction.
                  ((eq? name 'fp-contract) (loop (cdr cs) out post))
                  ((eq? name 'bounds-check)
                   ;; Materialise the limit, then check the index against it.
                   (let ((lim (fresh! "len")))
                     (loop (cdr cs)
                           (cons `(chk bounds-check checked 0 ,(car ops) ,lim)
                                 (cons `(vlen ,lim raw-word ,(cadr ops)) out))
                           post)))
                  ((eq? name 'overflow-check)
                   (loop (cdr cs) out
                         (cons `(chk overflow-check checked ,(expected-tag name)
                                     ,@ops ,dst)
                               post)))
                  (else
                   (loop (cdr cs)
                         (cons `(chk ,name checked ,(expected-tag name) ,@ops)
                               out)
                         post)))))
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
    (record-classes! (reverse instrs))
    (set! blocks (cons (list lbl (list 'block (reverse instrs) transfer)) blocks)))
  (define (reset-blocks!)
      (reset-classes!) (set! blocks '()))

  ;; --- what class is a vreg in --------------------------------------------
  ;;
  ;; Needed by the `if` copies: the move has to declare a storage class, and
  ;; declaring the wrong one is not a performance bug. A double moved as a word
  ;; lands in an integer register and every instruction after it is the wrong
  ;; one; a tagged value moved as raw loses a GC root (repr.ss, header).
  ;;
  ;; Two sources, and they agree by construction. Lrepr's `let` carries the
  ;; class repr.ss computed, and every Lmach instruction carries it in slot 3.
  (define vreg-classes (make-eq-hashtable))
  (define (reset-classes!) (set! vreg-classes (make-eq-hashtable)))
  (define (note-class! v sc)
    (when (and (symbol? v) (memq sc '(tagged raw-word raw-f64)))
      (hashtable-set! vreg-classes v sc)))
  (define (record-classes! instrs)
    (for-each (lambda (i)
                (when (and (pair? i) (not (eq? (car i) 'chk)) (>= (length i) 3))
                  (note-class! (cadr i) (caddr i))))
              instrs))
  ;; The class of every vreg in the program just lowered: repr.ss's answers for
  ;; the source names, plus the temporaries this pass invented.
  ;;
  ;; The allocator needs exactly this and cannot rebuild it from Lmach alone. A
  ;; LAMBDA PARAMETER has no defining instruction, so scanning instructions for
  ;; (op v sc ...) never sees it, and the allocator dies on a vreg it is being
  ;; asked to place.
  (define (lowered-classes) vreg-classes)

  (define (vreg-class-of v)
    (or (hashtable-ref vreg-classes v #f)
        (error 'lower
               (string-append
                "no storage class for this vreg, so an `if` cannot say how to "
                "copy it into the join destination; classifying it wrongly "
                "would either lose a GC root or put a double in an integer "
                "register")
               v)))

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
             (note-class! x sc)
             (let-values (((is v) (lower-simple se x sc stats)))
               (record-classes! is)
               (walk body (append (reverse is) acc)))))
          ((quote) (let ((v (fresh! "k")))
                     (values (reverse (cons `(const ,v ,(const-class (cadr e)) ,(cadr e)) acc)) v)))
          ;; The unspecified value.
          ;;
          ;; Materialised as a raw ZERO, not as the datum `()`. numeric.ss
          ;; assigns tags to fixnums and flonums and to nothing else, so there
          ;; is no immediate encoding for unspecified yet, and neither selector
          ;; can turn `()` into bits. Picking one here would be an object-
          ;; representation decision made in the wrong file.
          ;;
          ;; Zero is sound in the raw class because `raw-word` promises only an
          ;; untagged machine word that the collector never scavenges, and
          ;; repr.ss classifies `(void)` raw-word. If it ever merged with a
          ;; tagged value the join would raise rather than hand the collector a
          ;; zero to chase. Open question: immediates (booleans, nil,
          ;; unspecified) still need tag assignments.
          ((void)  (let ((v (fresh! "k")))
                     (values (reverse (cons `(const ,v raw-word 0) acc)) v)))
          ;; Control flow. The accumulated straight-line instructions become the
          ;; current block, ending in a branch; each arm gets a label; both
          ;; converge on a join block whose only job is to be the continuation.
          ((if)
           ;; PHI ELIMINATION BY COPY.
           ;;
           ;; An `if` in value position has to produce ONE vreg, and the two
           ;; arms leave their results in two different ones -- that is what a
           ;; phi is for, and Lmach deliberately has none.
           ;;
           ;; This used to return the JOIN LABEL as the result vreg, on the
           ;; reasoning that the arms had already written the vregs the analysis
           ;; named. That is false after SSA: the arms write t-v and e-v, which
           ;; are distinct names, and nothing merged them. The label then flowed
           ;; onward as if it were a value, and an `if` in tail position emitted
           ;; `(ret L.join.35)` -- a return of a code address.
           ;;
           ;; So each arm ends with a `move` into a common destination and the
           ;; destination is the result. That is the standard elimination, and
           ;; it is correct here for the reason it is correct in general: the
           ;; copies sit at the END of each predecessor, where the arm's value
           ;; is live and the other arm's is not, so the two never interfere and
           ;; no parallel-copy cycle is possible with a single phi.
           (let* ((test (cadr e))
                  (then-lbl (fresh! "L.then"))
                  (else-lbl (fresh! "L.else"))
                  (join-lbl (fresh! "L.join"))
                  (cur (fresh! "L.cur"))
                  (dst (fresh! "if")))
             (emit-block! cur acc (list 'branch-if test then-lbl else-lbl))
             (let-values (((t-is t-v) (lower-expr (caddr e) stats)))
               (record-classes! t-is)
               (let ((sc (vreg-class-of t-v)))
                 (note-class! dst sc)
                 (emit-block! then-lbl
                              (reverse (cons `(move ,dst ,sc ,t-v) (reverse t-is)))
                              (list 'jump join-lbl))))
             (let-values (((e-is e-v) (lower-expr (cadddr e) stats)))
               (record-classes! e-is)
               (let ((sc (vreg-class-of e-v)))
                 (emit-block! else-lbl
                              (reverse (cons `(move ,dst ,sc ,e-v) (reverse e-is)))
                              (list 'jump join-lbl))))
             ;; The join carries no instructions of its own; the copies above
             ;; are what a phi there would have been.
             (values '() dst)))
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
           ;; (phi ([x (pred val) ...] ...) body)
           ;;
           ;; This had two defects and both were silent.
           ;;
           ;; It hardcoded `raw-word`, so a phi merging two DOUBLES emitted a
           ;; move that puts the value in an integer register and makes every
           ;; instruction after it the wrong one (repr.ss, header). The class
           ;; now comes from the operand.
           ;;
           ;; And when the operand was an EXPRESSION rather than a name it
           ;; emitted nothing at all, leaving the phi variable undefined while
           ;; the body went on referring to it. essa.ss produces exactly that
           ;; shape for an `if` in value position, so `main` ended in
           ;; `(ret join.35)` -- a return of a name nothing ever wrote.
           (let loop ((bs (cadr e)) (out acc))
             (if (null? bs)
                 (walk (caddr e) out)
                 (let* ((b (car bs)) (x (car b)) (ops (cdr b)))
                   ;; One operand is the only case essa.ss currently produces,
                   ;; and it is the only one that can be handled HERE. A real
                   ;; multi-predecessor phi needs its copies placed at the end
                   ;; of each predecessor block, which this walk cannot do
                   ;; because it does not know which block each operand came
                   ;; from. Taking the first operand and dropping the rest --
                   ;; which is what this did -- is wrong code, so it says so.
                   (unless (= (length ops) 1)
                     (error 'lower
                            (string-append
                             "a phi with more than one operand needs its copies "
                             "placed in the predecessor blocks, which this pass "
                             "cannot do; taking the first operand would silently "
                             "drop the others")
                            x (length ops)))
                   (let ((val (cadr (car ops))))
                     (if (symbol? val)
                         (let ((sc (vreg-class-of val)))
                           (note-class! x sc)
                           (loop (cdr bs) (cons `(move ,x ,sc ,val) out)))
                         ;; An expression operand: lower it here, then copy its
                         ;; result into the phi variable.
                         (let-values (((is v) (lower-expr val stats)))
                           (record-classes! is)
                           (let ((sc (vreg-class-of v)))
                             (note-class! x sc)
                             (loop (cdr bs)
                                   (cons `(move ,x ,sc ,v)
                                         (append (reverse is) out))))))))))) 
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
        ;; Raw zero, not the datum `()` -- see the note at the `void` case in
        ;; `lower-expr`: no immediate encoding for unspecified exists yet.
        ((void)  (values `((const ,dst ,sc 0)) dst))
        ((primcall)
         (let* ((pr (cadr se))
                (controls (caddr se))
                (srcs (cdddr se))
                (op (op-for pr)))
           (let-values (((pre post) (checks->instrs controls srcs dst stats)))
             (values (append pre (list `(,op ,dst ,sc ,@srcs)) post) dst))))
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
      (reset-classes!)
      (let-values (((instrs result) (lower-expr e stats)))
        (record-classes! instrs)
        (values `(program ((,name (block ,instrs (ret ,result))) ,@blocks) ,name)
                stats))))

  ;; Whole program. Each top-level binding whose value is a lambda becomes its
  ;; own labelled function; everything else is initialization that runs before
  ;; the body, in source order, because a later definition may read an earlier
  ;; one.
  (define (lower-toplevel p name . opt)
    ;; The entry block gets a FRESH label, not `name`. A top-level binding may
    ;; itself be called `main`, and two blocks with one label make the program
    ;; ambiguous in a way nothing downstream can detect: selection walks both
    ;; and the second silently wins.
    (let ((stats (make-lower-stats 0 0 0))
          (known (and (pair? opt) (car opt)))
          (entry (fresh! (string-append (symbol->string name) ".entry"))))
      (reset-blocks!)
      (reset-classes!)
      (let* ((form (if (pair? p) p (unparse-Lrepr p))))
        ;; Seed from repr.ss, which owns storage classes. This is where LAMBDA
        ;; PARAMETERS come from: they have no defining instruction here, so
        ;; nothing in this pass could classify them.
        ;;
        ;; The table is passed IN rather than recomputed, because it is derived
        ;; from Lssa and this pass reads Lrepr -- whose `let` carries an extra
        ;; slot, so the same walk reads the storage class where the initializer
        ;; should be and silently classifies nothing.
        (when known
          (vector-for-each (lambda (v) (note-class! v (hashtable-ref known v #f)))
                           (hashtable-keys known)))
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
            ;; The entry block is built here rather than through `emit-block!`,
            ;; so its instructions have to be recorded explicitly -- otherwise
            ;; every vreg the program's own body defines is missing from the
            ;; class table and the allocator refuses to place it.
            (record-classes! init)
            (record-classes! bis)
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

  ;; A top-level binding whose value is not a procedure.
  ;;
  ;; The class used to be hardcoded `raw-word`, which is wrong for every one of
  ;; nbody's own top-level bindings: `pos`, `vel` and `mass` are flvectors and
  ;; belong in the value class, and calling them raw loses three GC roots at
  ;; once (repr.ss, header).
  ;;
  ;; And when the value was an EXPRESSION rather than a simple one, the result
  ;; landed in a fresh vreg and the binding's own name was never written at all,
  ;; so every later reference named something nothing defined.
  (define (lower-simple-or-expr v x stats)
    (let ((sc (vreg-class-of x)))
      (if (and (pair? v)
               (memq (car v) '(let if seq tailcall letrec lambda phi sigma
                               declare declare-distinct policy)))
          (let-values (((is r) (lower-expr v stats)))
            (values (append is (list `(move ,x ,sc ,r))) x))
          (lower-simple v x sc stats))))
  )
