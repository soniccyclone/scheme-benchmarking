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
  (export lower-program lower-expr lower-toplevel lowered-classes lowered-params
          make-lower-stats lower-stats? lower-stats-proved
          lower-stats-unchecked lower-stats-emitted)
  (import (chezscheme)
          (sonic repr)
          (sonic order)
          (sonic numeric)
          (nanopass)
          (sonic lang))

  (define-record-type (lower-stats make-lower-stats lower-stats?)
    (fields (mutable proved) (mutable unchecked) (mutable emitted)))

  ;; primcall name -> Lmach op. Anything absent is not lowerable and says so.
  (define prim->op
    '((fx+ . add) (fx- . sub) (fx* . mul) (fxneg . neg)
      (fl+ . add) (fl- . sub) (fl* . mul) (fl/ . div)
      (flneg . neg) (flabs . abs) (flsqrt . sqrt)
      (fx< . cmp-lt) (fx<= . cmp-le) (fx= . cmp-eq)
      (fx>= . cmp-ge) (fx> . cmp-gt)
      (fl< . fcmp-lt) (fl<= . fcmp-le) (fl= . fcmp-eq)
      (fl>= . fcmp-ge) (fl> . fcmp-gt)
      (fx->fl . cvt-f64-from-int) (fl->fx . cvt-int-from-f64)
      (flvector-ref . load) (flvector-set! . store)
      (vector-ref . load) (vector-set! . store)
      ;; ONE MACH-OP FOR BOTH, and that is D29 rather than a shortcut. The
      ;; length word sits at the same offset for every heap type, so `vlen` is
      ;; a load at a constant displacement and knows nothing about what it is
      ;; reading the length of -- see the selector rule, which absorbs the
      ;; header offset and the pointer tag into one displacement and asks no
      ;; question about the type word.
      ;;
      ;; Neither was wired because nbody carries its own `n` and never asks,
      ;; and `vlen` reached the emitted code only through bounds checks, which
      ;; the elision pass materialises directly. A program that asks in source
      ;; was refused with "primitive has no machine op".
      (flvector-length . vlen) (vector-length . vlen)
      ;; Allocation and anything else with no single machine op becomes a call
      ;; into the runtime. `alloc.ss` owns the fast path and `gc.ss` the slow
      ;; one, and neither is expressible as one Lmach instruction: the claim,
      ;; the fill and the restart region are a sequence, and inlining that here
      ;; would duplicate a decision those files already made.
      ;; INTEGER DIVISION IS A CALL, for the reason runtime.ss gives: idiv
      ;; hardwires rdx:rax and regs.ss allocates from disjoint class pools, so
      ;; no selector rule can ask for it. Before this the selector refused
      ;; `div` outright and no program using fxquotient compiled at all.
      (fxquotient . call) (fxremainder . call) (fxmodulo . call)
      (make-flvector . call) (make-vector . call)
      (cons . call) (car . call) (cdr . call) (error . call)
      (null? . call) (pair? . call) (eq? . call)
      (fixnum? . call) (flonum? . call) (vector? . call) (flvector? . call)))

  ;; WHICH runtime routine. This is not decoration.
  ;;
  ;; `(call dst sc callee arg ...)` -- the callee is the FIRST source. Lowering
  ;; a primitive to `call` without naming one left the first ARGUMENT sitting in
  ;; the callee slot, so `(make-flvector 15)` lowered to a call to 15. It
  ;; type-checked, it selected, it allocated, and it only surfaced at assembly
  ;; as "undefined label" naming a vreg that held a literal.
  ;;
  ;; The `%` prefix marks a runtime entry point rather than a user procedure,
  ;; which the reader of a disassembly needs and which keeps these out of the
  ;; source namespace.
  (define prim->runtime
    '((make-flvector . %make-flvector) (make-vector . %make-vector)
      (cons . %cons) (car . %car) (cdr . %cdr) (error . %error)
      (null? . %null?) (pair? . %pair?) (eq? . %eq?)
      (fxquotient . %fxquotient) (fxremainder . %fxremainder)
      (fxmodulo . %fxmodulo)
      (fixnum? . %fixnum?) (flonum? . %flonum?)
      (vector? . %vector?) (flvector? . %flvector?)))

  (define (runtime-entry pr)
    (let ((p (assq pr prim->runtime)))
      (unless p
        (error 'lower
               (string-append
                "this primitive lowers to a runtime call but names no runtime "
                "entry point, so the first argument would be used as the callee")
               pr))
      (cdr p)))

  ;; numeric.ss fixes a 3-bit tag scheme with fixnum at 000. A type check needs
  ;; to name which tag it expects; the other checks have no such constant.
  ;; The tag a surviving type check compares against.
  ;;
  ;; `heap-tag` for a type check, and it is the same for every heap type on
  ;; purpose: numeric.ss puts the TYPE in the object header rather than in the
  ;; pointer tag, so a load's displacement is one constant instead of one per
  ;; type. A type check here therefore asks "is this a heap object", and the
  ;; predicates that need more than that pay a header load.
  ;;
  ;; The other checks have no tag to compare -- there is no such thing as the
  ;; expected tag of a bounds check -- and pass 0, which is why the mach-op
  ;; spelling that could not distinguish "no tag" from "tag 0" had to go (D27).
  (define (expected-tag name) (if (eq? name 'type-check) heap-tag 0))

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

  ;; --- what a primitive requires of its arguments, in the RAW direction ------
  ;;
  ;; repr.ss's `prim-arg-classes` declares the TAGGED requirements and pushes
  ;; them backward, so convert.ss can retag at the definition. A `raw-word`
  ;; requirement cannot travel that way: the join only ever moves a class UP
  ;; toward `tagged`, so asking a tagged value to become a machine word changes
  ;; nothing and the program compiles with the mismatch intact.
  ;;
  ;; So this one is read at the CONSUMER and the conversion lands at the USE.
  ;; That is deliberately not D31's rule. convert.ss's header states the
  ;; definition placement as though it were general; it is general only for the
  ;; direction a requirement can be propagated in, and this is the other one.
  ;;
  ;; A row lists one entry per argument -- `raw-word` where a machine word is
  ;; required, `#f` where anything goes. `vector-ref` is why the distinction is
  ;; per position: the vector is a tagged pointer and the index is a machine
  ;; word, in the same call.
  (define prim-raw-args
    '((fx+ raw-word raw-word) (fx- raw-word raw-word) (fx* raw-word raw-word)
      (fxneg raw-word)
      (fxquotient raw-word raw-word) (fxremainder raw-word raw-word)
      (fxmodulo raw-word raw-word)
      (fx< raw-word raw-word) (fx<= raw-word raw-word) (fx= raw-word raw-word)
      (fx>= raw-word raw-word) (fx> raw-word raw-word)
      (fx->fl raw-word)
      (vector-ref #f raw-word) (flvector-ref #f raw-word)
      (vector-set! #f raw-word #f) (flvector-set! #f raw-word #f)))

  (define (op-for pr)
    (let ((p (assq pr prim->op)))
      (unless p (error 'lower "primitive has no machine op" pr))
      (cdr p)))

  ;; --- D24: carrying the contraction permission past this pass ---------------
  ;;
  ;; `fp-contract` is a permission, not a check, so `checks->instrs` consumes it
  ;; and emits nothing -- correctly, since there is no branch to emit. But it
  ;; then threw it away, and the back end that has to ACT on it runs later. The
  ;; permission was parsed, scoped, counted and dropped, and no program ever got
  ;; a fused multiply-add out of granting it.
  ;;
  ;; So a flonum add, subtract or multiply standing in a granted scope lowers to
  ;; the `-c` spelling of its op. Those compute exactly what the unmarked ones
  ;; compute and select to the same instructions; the mark is what lets
  ;; contract.ss tell an expression it may fuse from one it may not.
  ;;
  ;; `unchecked` is the granted control. `checked` is D24's default -- round
  ;; twice, do not fuse -- and `proved` never reaches here.
  (define contractible-op '((add . add-c) (sub . sub-c) (mul . mul-c)))

  (define (contraction-granted? controls)
    (exists (lambda (c)
              (and (pair? c) (eq? (car c) 'fp-contract) (eq? (cadr c) 'unchecked)))
            controls))

  (define (op-for/controls pr sc controls)
    (let ((op (op-for pr)))
      (if (and (eq? sc 'raw-f64) (contraction-granted? controls))
          (let ((m (assq op contractible-op)))
            (if m (cdr m) op))
          op)))

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
      ;; (fxquotient a b): the DIVISOR is operand 2, and it is the only one the
      ;; check reads. Without this case the `else` below handed both operands
      ;; to a rule that takes one, and both targets refused with "division
      ;; check expects a divisor" -- so `(fxquotient 6 0)` did not compile at
      ;; all, and the trap it was supposed to reach did not exist.
      ((div-check)    (list (cadr srcs)))
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
      (reset-classes!)
      (reset-params!) (set! blocks '()))

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

  ;; repr.ss's record of which raw words hold a 0/1 TRUTH VALUE rather than a
  ;; number. Module state for the same reason `vreg-classes` is: the branch that
  ;; needs it is built deep in the Expr walk, not in `lower-toplevel`.
  ;;
  ;; #f means "not supplied", and it must mean "assume every raw word is a
  ;; boolean" -- the behaviour before this table was passed at all. An empty
  ;; table would mean the opposite and would turn every raw-word branch into an
  ;; unconditional jump.
  (define vreg-booleans #f)
  (define (set-booleans! t) (set! vreg-booleans t))
  (define (raw-word-truth-value? v)
    (or (not vreg-booleans) (and (hashtable-ref vreg-booleans v #f) #t)))
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

  ;; Each function's PARAMETER LIST, in order: label -> (param ...).
  ;;
  ;; Lmach's `(program ([lbl blk] ...) lbl)` records no signatures, and without
  ;; one nothing downstream can emit the moves that bring arguments out of the
  ;; convention's registers into whatever the allocator gave the parameters. A
  ;; function then reads its first argument from wherever its own scan happened
  ;; to place the vreg -- `rdx`, say, while the caller put it in `rcx`.
  ;;
  ;; This is the same gap the return move had, at the other end of the call.
  ;; Order matters and liveness cannot supply it: the entry block's live-in set
  ;; says WHICH vregs arrive, not in which argument position.
  (define fn-params (make-eq-hashtable))
  (define (reset-params!) (set! fn-params (make-eq-hashtable)))
  (define (note-params! lbl ps) (hashtable-set! fn-params lbl ps))
  (define (lowered-params) fn-params)

  ;; Untag every argument a primitive needs as a machine word that arrives
  ;; tagged. Returns the instructions to prepend and the rewritten sources.
  ;;
  ;; A fixnum's tagged form is the value shifted left by the tag width, so the
  ;; inverse is an ARITHMETIC shift right -- `ashr-imm`, which exists for this
  ;; and nothing else. Signed, because a negative fixnum's tagged word has its
  ;; sign bit set and a logical shift would turn it into a large positive one.
  ;;
  ;; Only a SYMBOL is converted. A literal in an argument position carries its
  ;; own class from `const-class` and is materialised directly, so there is
  ;; nothing to shift back.
  (define (untag-args pr srcs)
    (let ((req (assq pr prim-raw-args)))
      (if (not req)
          (values '() srcs)
          (let loop ((ss srcs) (rs (cdr req)) (acc '()) (out '()))
            (if (null? ss)
                (values (reverse acc) (reverse out))
                (let ((s (car ss))
                      (r (and (pair? rs) (car rs)))
                      (rest (if (pair? rs) (cdr rs) '())))
                  (if (and (eq? r 'raw-word) (symbol? s)
                           (eq? (hashtable-ref vreg-classes s #f) 'tagged))
                      (let ((t (fresh! "u")))
                        (note-class! t 'raw-word)
                        (loop (cdr ss) rest
                              (cons `(ashr-imm ,t raw-word ,fx-tag-bits ,s) acc)
                              (cons t out)))
                      (loop (cdr ss) rest acc (cons s out)))))))))

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
  ;; Returns (values instrs result-vreg exit-label). The instructions belong to
  ;; the block named by exit-label, which the CALLER must emit.
  ;;
  ;; The label has to be threaded, and the earlier version of this pass not
  ;; threading it is why the lowered CFG was disconnected. An `if` emits three
  ;; blocks and the code that follows the join belongs in the JOIN block -- but
  ;; the walk went on accumulating into a list the caller then emitted under its
  ;; own label, with no edge from the join to it. So the arms jumped to a join
  ;; that fell off the end, and everything after the conditional sat in a block
  ;; nothing branched to. It selected, it allocated, and 287 of nbody's 551
  ;; virtual registers lived in blocks no entry could reach.
  ;;
  ;; `lower-expr` keeps the two-value shape for callers that lower a
  ;; straight-line expression and supply their own label.

  (define (lower-expr e stats)
    (let-values (((is v lbl) (lower-into e stats (fresh! "L.b") #f)))
      (values is v)))

  ;; `tail?` says the expression's value is the function's return value.
  ;;
  ;; It exists so a TAIL CALL stays one. essa.ss wraps an `if` in value
  ;; position in a phi, so a loop's recursive call came out as
  ;;
  ;;     (call t raw-word loop args...)     ; in an arm
  ;;     (move if60 raw-word t)             ; the phi copy
  ;;     -> (jump L.join)                   ; and the block ends in a jump
  ;;
  ;; which is a plain call: `tail-call-instr` in select.ss recognises a call
  ;; that is the block's LAST instruction and whose result the block's `ret`
  ;; returns, and the copy plus the jump destroy both halves of that. Every
  ;; iteration of every loop in nbody pushed a frame.
  ;;
  ;; In tail position an `if` needs neither the copies nor the join: each arm
  ;; ends in its own `ret`, so the arm's call is last, its result is what the
  ;; ret returns, and the shape is recognised. This is the R5RS guarantee that
  ;; ANSI CL never made, and it is the reason this compiler can express a loop
  ;; as a procedure at all.
  ;;
  ;; An exit label of #f means the walk already emitted terminated blocks and
  ;; nothing falls through -- the caller must NOT emit another block.
  (define (lower-into e stats start-label tail?)
    (let walk ((e (if (pair? e) e (unparse-Lrepr e))) (acc '()) (lbl start-label)
               (tail? tail?))
      (cond
       ((symbol? e) (values (reverse acc) e lbl))
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
               (walk body (append (reverse is) acc) lbl tail?))))
          ((quote) (let ((v (fresh! "k")))
                     (values (reverse (cons `(const ,v ,(const-class (cadr e)) ,(cadr e)) acc))
                             v lbl)))
          ;; The unspecified value. numeric.ss assigns it an immediate
          ;; encoding, so it is a real object with a real bit pattern rather
          ;; than a placeholder zero -- which matters the moment it merges with
          ;; anything, since the collector reads the value class unconditionally.
          ((void)  (let ((v (fresh! "k")))
                     (values (reverse (cons `(const ,v raw-word ,sonic-unspecified) acc))
                             v lbl)))
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
                  (dst (fresh! "if")))
             ;; The instructions accumulated so far end THIS block, under the
             ;; label the caller is building, so the predecessor's edge into it
             ;; is preserved.
             ;; A TAGGED CONDITION IS FALSE ONLY WHEN IT IS sonic-false.
             ;;
             ;; `branch-if` lowers to `cmp r, 0` and a non-zero jump, which is
             ;; exactly right for a raw-word boolean -- the fixnum comparisons
             ;; produce 0 or 1 -- and WRONG for a tagged one, because Scheme's
             ;; false is the immediate numeric.ss calls sonic-false, which is 7.
             ;; Comparing it against 0 makes `#f` read as TRUE:
             ;;
             ;;     (if #f 7 9)  =>  7
             ;;
             ;; That is a wrong answer on ordinary Scheme, not a conformance
             ;; nicety, and it was reachable the moment a boolean literal became
             ;; selectable at all.
             ;;
             ;; So a tagged test is compared against sonic-false first, and the
             ;; ARMS ARE SWAPPED because the comparison asks the opposite
             ;; question: `is-false` is 1 exactly when the branch should go to
             ;; the else arm. No new mach-op and no selector change -- `cmp-eq`
             ;; already yields the raw-word 0/1 `branch-if` wants.
             ;; A RAW WORD THAT IS NOT A BOOLEAN IS ALWAYS TRUE.
             ;;
             ;; R6RS: every object but `#f` is true, so `(if 0 a b)` evaluates
             ;; `a`. Here 0 and the raw-word false share a representation, and
             ;; `cmp r, 0` cannot tell a fixnum from a truth value -- so a
             ;; fixnum 0 took the else arm. repr.ss already knows the
             ;; difference: `booleans` records exactly which raw words hold 0/1
             ;; as a TRUTH VALUE, and the table simply never reached here.
             ;;
             ;; Where it says the test is not a boolean, the branch is not a
             ;; branch: control always goes to the then arm, and the else arm is
             ;; unreachable. `partition-into-functions` gathers unreachable
             ;; blocks and finalize drops them, so the dead arm costs nothing.
             (let ((tc (vreg-class-of test)))
               (if (and (eq? tc 'raw-word) (not (raw-word-truth-value? test)))
                   (emit-block! lbl acc (list 'jump then-lbl))
               (if (eq? tc 'tagged)
                   (let ((kf (fresh! "kf")) (isf (fresh! "isf")))
                     (emit-block!
                      lbl
                      (cons `(cmp-eq ,isf raw-word ,test ,kf)
                            (cons `(const ,kf tagged ,sonic-false) acc))
                      (list 'branch-if isf else-lbl then-lbl)))
                   (emit-block! lbl acc (list 'branch-if test then-lbl else-lbl)))))
             ;; emit-block! takes its instructions REVERSED (it is fed the
             ;; walk's accumulator). Handing it an ordered list reverses the
             ;; block, which puts every use before its def -- so every vreg
             ;; looked live-in from position 0 and the allocator spilled half
             ;; the inner loop.
             (let ((arm
                    (lambda (sub arm-lbl)
                      (let-values (((is v xl) (walk sub '() arm-lbl tail?)))
                        (when xl
                          (record-classes! is)
                          (if tail?
                              ;; Tail position: the arm returns directly, so a
                              ;; call at the end of it stays a TAIL call.
                              (emit-block! xl (reverse is) (list 'ret v))
                              (let ((sc (vreg-class-of v)))
                                (note-class! dst sc)
                                (emit-block! xl
                                             (cons `(move ,dst ,sc ,v) (reverse is))
                                             (list 'jump join-lbl)))))))))
               (arm (caddr e) then-lbl)
               (arm (cadddr e) else-lbl))
             (if tail?
                 ;; Both arms returned. Nothing follows and there is no join.
                 (values '() dst #f)
                 ;; Everything after the conditional belongs to the JOIN block,
                 ;; so that is the label the walk continues under.
                 (values '() dst join-lbl))))
          ;; Premises and policies carry no code. They constrained the ANALYSIS,
          ;; which has already run and left its answers in the controls, so by
          ;; here they are annotation and the body is the program. Dropping them
          ;; is not losing information -- keeping them would be, since nothing
          ;; downstream reads them and a stale premise outliving its analysis is
          ;; how a wrong assumption gets reused.
          ;; All three are (form <annotation> body), so the body is caddr.
          ((declare declare-distinct policy)
           (walk (caddr e) acc lbl tail?))
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
           ;; A phi whose body is exactly the name it binds, with one binding,
           ;; is essa.ss's wrapper around an `if` in value position. When the
           ;; phi is in tail position, so is that `if`: the phi's whole meaning
           ;; is "the operand's value is the result". Passing `tail?` through is
           ;; what lets the arms keep their tail calls.
           (let* ((one-binding? (and (= (length (cadr e)) 1)
                                     (eq? (caddr e) (car (car (cadr e))))))
                  (op-tail? (and tail? one-binding?)))
           (let loop ((bs (cadr e)) (out acc) (lbl lbl))
             (if (null? bs)
                 (walk (caddr e) out lbl tail?)
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
                           (loop (cdr bs) (cons `(move ,x ,sc ,val) out) lbl))
                         ;; An expression operand: lower it in the CURRENT
                         ;; block, carrying what has accumulated so far, so an
                         ;; `if` inside it splits at the right place.
                         (let-values (((is v lbl2) (walk val out lbl op-tail?)))
                           (if (not lbl2)
                               ;; The operand terminated every path itself.
                               (values '() v #f)
                               (begin
                                 (record-classes! is)
                                 (let ((sc (vreg-class-of v)))
                                   (note-class! x sc)
                                   (loop (cdr bs)
                                         (cons `(move ,x ,sc ,v) (reverse is))
                                         lbl2))))))))))))
          ((sigma)
           ;; (sigma x-out x-in cmp x-other negated? body). A refinement of a
           ;; name, so the same representation -- the class comes from the
           ;; source rather than being hardcoded raw-word, which would move a
           ;; refined DOUBLE through an integer register.
           (let ((sc (vreg-class-of (caddr e))))
             (note-class! (cadr e) sc)
             (walk (list-ref e 6) (cons `(move ,(cadr e) ,sc ,(caddr e)) acc) lbl tail?)))
          ((letrec)
           ;; Each binding becomes its own labelled block, then the body runs.
           (for-each
            (lambda (b)
              (let ((x (car b)) (v (cadr b)))
                (when (and (pair? v) (eq? (car v) 'lambda))
                  (note-params! x (cadr v)))
                (let-values (((is r xl) (walk (if (and (pair? v) (eq? (car v) 'lambda))
                                                  (caddr v) v)
                                              '() x #t)))
                  ;; xl = #f means every path already returned.
                  (when xl
                    (record-classes! is)
                    (emit-block! xl (reverse is) (list 'ret r))))))
            (cadr e))
           (walk (caddr e) acc lbl tail?))
          ((lambda)
           ;; A lambda in value position: its own block, and the value is the
           ;; label. Closures are a later bead; this is enough for a program
           ;; whose procedures are all top-level or letrec-bound.
           (let ((fn (fresh! "L.fn")))
             (let-values (((is r xl) (walk (caddr e) '() fn #t)))
               (when xl
                 (record-classes! is)
                 (emit-block! xl (reverse is) (list 'ret r))))
             (values (reverse acc) fn lbl)))
          ((seq)
           (let-values (((a av a-lbl) (walk (cadr e) acc lbl #f)))
             (walk (caddr e) (reverse a) a-lbl tail?)))
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
             (values (reverse (cons `(call ,v raw-word ,@(cdr e)) acc)) v lbl)))
          (else
           ;; a bare simple expression in tail position
           (let ((v (fresh! "t")))
             (let-values (((is r) (lower-simple e v 'raw-word stats)))
               (record-classes! is)
               (values (reverse (append (reverse is) acc)) r lbl)))))))))

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
        ((void)  (values `((const ,dst ,sc ,sonic-unspecified)) dst))
        ;; (retag KIND x) -- convert.ss's output, and the only producer of a
        ;; tagged value from a raw one.
        ;;
        ;; Both directions are arithmetic on a machine word, so this needs NO
        ;; new mach-op and no new selection rule on either target. A fixnum's
        ;; tagged form is the value shifted left `fx-tag-bits`, which is a
        ;; multiply by 8; an immediate's is `(sec << 3) | imm-tag`, and since a
        ;; boolean's shifted form has its low three bits clear, the OR is an
        ;; ADD. `mul` and `add` are already machine-independent ops with rules
        ;; on x86-64 and RV64, which is worth more than the shift instruction a
        ;; dedicated op would buy: this is not a hot path -- it appears only
        ;; where a program mixes representations -- and a new op costs two
        ;; selectors, two encoders and the tests for both.
        ((retag)
         (let* ((kind (cadr se))
                (src (caddr se))
                (k (fresh! "t"))
                (shift `((const ,k raw-word ,(expt 2 fx-tag-bits)))))
           (case kind
             ((fixnum)
              (values (append shift `((mul ,dst ,sc ,src ,k))) dst))
             ((boolean)
              ;; 0 and 1 become 7 and 15, which are sonic-false and sonic-true.
              ;; Shifting alone would give the FIXNUMS 0 and 1 -- a wrong answer
              ;; that looks entirely plausible, which is why repr.ss tracks
              ;; which raw words hold booleans instead of guessing from the type.
              (let ((t (fresh! "t")) (k2 (fresh! "t")))
                (values (append shift
                                `((mul ,t raw-word ,src ,k)
                                  (const ,k2 raw-word ,imm-tag)
                                  (add ,dst ,sc ,t ,k2)))
                        dst)))
             ;; A double becomes a heap object. Unlike the other two kinds this
             ;; is a CALL, so it is a safepoint and the collector may run here --
             ;; which is correct and is why the conversion is a call rather than
             ;; an inline bump: the allocation has to be visible to the metadata
             ;; the call site already emits.
             ((boxed)
              (values `((call ,dst ,sc %box-flonum ,src)) dst))
             (else (error 'lower "unknown retag kind" kind)))))
        ((primcall)
         (let* ((pr (cadr se))
                (controls (caddr se))
                (srcs0 (cdddr se))
                (op (op-for/controls pr sc controls)))
           ;; BEFORE the checks rather than between them and the op: a bounds
           ;; check compares the index against the vector's RAW length, so it
           ;; has to see the machine word too.
           (let*-values (((untags srcs) (untag-args pr srcs0))
                         ((pre post) (checks->instrs controls srcs dst stats)))
             (values (append untags pre
                             (list (cond
                                    ((eq? op 'call)
                                     `(call ,dst ,sc ,(runtime-entry pr) ,@srcs))
                                    ;; A STORE's storage class must describe the
                                    ;; VALUE, not the result. `flvector-set!`
                                    ;; and `vector-set!` have no useful result
                                    ;; and repr.ss classifies them raw-word so
                                    ;; the dead destination does not pull a
                                    ;; value register -- but the selector reads
                                    ;; `sc` to pick the mnemonic and the scale,
                                    ;; so a double was being stored with the
                                    ;; integer `mov`. The encoder caught it as
                                    ;; "bad mov operands"; had the mnemonic been
                                    ;; encodable it would have written the wrong
                                    ;; eight bytes.
                                    ((eq? op 'store)
                                     `(store ,dst ,(vreg-class-of (car (reverse srcs)))
                                             ,@srcs))
                                    (else `(,op ,dst ,sc ,@srcs))))
                             post)
                     dst))))
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
      (reset-params!)
      (let-values (((instrs result exit) (lower-into e stats name #t)))
        (unless exit
          (error 'lower-program
                 "the expression returned on every path, so there is no entry block to build"))
        (record-classes! instrs)
        ;; The block emitted here is the one the walk ENDED in, which is not
        ;; `name` when control flow split. Emitting under `name` regardless
        ;; would leave the last block unreachable and duplicate the entry label.
        (values `(program ((,exit (block ,instrs (ret ,result)))
                           ,@(filter (lambda (b) (not (eq? (car b) exit))) blocks))
                          ,name)
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
          ;; repr.ss's record of which raw words hold a 0/1 TRUTH VALUE rather
          ;; than a number. Optional, and its absence means "assume every raw
          ;; word is a boolean", which is what this pass did before it was
          ;; passed at all -- so an old caller gets the old behaviour.
          (entry (fresh! (string-append (symbol->string name) ".entry"))))
      (reset-blocks!)
      (reset-classes!)
      (reset-params!)
      (set-booleans! (and (pair? opt) (pair? (cdr opt)) (cadr opt)))
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
                           (sorted-keys known)))
        (unless (eq? (car form) 'top)
          (error 'lower-toplevel "not a top-level program" form))
        (let ((binds (cadr form)) (body (cadddr form)) (init '()))
          (for-each
           (lambda (b)
             (let ((x (car b)) (v (cadr b)))
               (if (and (pair? v) (eq? (car v) 'lambda))
                   ;; A defined procedure: its own block, named for the binding.
                   (begin
                     (note-params! x (cadr v))
                     (let-values (((is r xl) (lower-into (caddr v) stats x #t)))
                       (when xl
                         (record-classes! is)
                         (emit-block! xl (reverse is) (list 'ret r)))))
                   ;; A value: initialization, in source order.
                   (let-values (((is r) (lower-simple-or-expr v x stats)))
                     (set! init (append init is))))))
           binds)
          (let-values (((bis bres exit) (lower-into body stats entry #t)))
            ;; The entry block is built here rather than through `emit-block!`,
            ;; so its instructions have to be recorded explicitly -- otherwise
            ;; every vreg the program's own body defines is missing from the
            ;; class table and the allocator refuses to place it.
            (record-classes! init)
            (record-classes! bis)
            ;; `init` belongs at the top of the ENTRY block. Where the body
            ;; branched, `entry` was already emitted by the split with the
            ;; body's leading instructions in it, so the initialization is
            ;; prepended to that block rather than given one of its own -- a
            ;; separate entry block would either duplicate the label or leave
            ;; the initialization with no edge to the rest.
            (let* ((tail-block (list exit (list 'block bis (list 'ret bres))))
                   (all (cons tail-block
                              (filter (lambda (b) (not (eq? (car b) exit))) blocks)))
                   (prog `(program ,(map (lambda (b)
                                           (if (eq? (car b) entry)
                                               (list entry
                                                     (list 'block
                                                           (append init (cadr (cadr b)))
                                                           (caddr (cadr b))))
                                               b))
                                         all)
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
