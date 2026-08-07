;;; SonicScheme core languages.
;;;
;;; E1-CORE and E1-IR. Every inter-stage contract lives here, each defined as a
;;; diff against its predecessor, which is the whole reason for vendoring
;;; nanopass (D23): a pass that emits a form its output language does not
;;; declare fails at compile time rather than as a wrong-code bug three stages
;;; downstream.
;;;
;;; Read docs/phases/07-compiler/EXECUTION.md section 1 for why freezing these
;;; before writing passes is what makes the work parallel.

(library (sonic lang)
  (export Lcore unparse-Lcore
          Lanf  unparse-Lanf
          Lssa  unparse-Lssa
          Lrepr unparse-Lrepr
          Lmach unparse-Lmach
          storage-class? vreg? mach-op?
          primitive? control? policy-name? datum?
          check-name? all-check-names
          premise-name? all-premise-names
          prim-checks prim-arity default-controls)
  (import (chezscheme) (nanopass))

  ;; --- terminals ------------------------------------------------------------

  (define (datum? x)
    (or (number? x) (boolean? x) (char? x) (string? x) (null? x) (symbol? x)))

  ;; The primitives the benchmarks need. Deliberately small: the numeric tower
  ;; is fixnum and flonum only, so no bignum, ratnum or complex.
  ;; Each entry is (name arity . applicable-checks).
  ;;
  ;; ARITY IS STATED, not left open. `(primcall pr ... e* ...)` would otherwise
  ;; admit any operand count, and for flonums the association order of a
  ;; multi-operand form is observable in the result bits. So the expander fixes
  ;; the order and the runtime never sees a variadic flonum op. `make-flvector`
  ;; and `make-vector` take a MANDATORY fill: an unfilled flvector is a
  ;; determinism hazard the bit-exact oracle cannot tolerate, and an unfilled
  ;; vector is a wild pointer under a scanning collector.
  (define prim-table
    '(;; fixnum arithmetic
      (fx+ 2 overflow-check) (fx- 2 overflow-check) (fx* 2 overflow-check)
      (fxneg 1 overflow-check)
      ;; integer division. Present so that div-check is REACHABLE: without
      ;; these it was a declared check name nothing could ever attach to.
      ;; Note fl/ by zero is deliberately NOT a div-check: IEEE says infinity,
      ;; and trapping it would make the C arm right and us wrong.
      (fxquotient 2 div-check overflow-check)
      (fxremainder 2 div-check)
      (fxmodulo 2 div-check)
      ;; fixnum comparison
      (fx< 2) (fx<= 2) (fx= 2) (fx>= 2) (fx> 2)
      ;; flonum arithmetic. fl/ has no div-check on purpose, see above.
      (fl+ 2 fp-contract) (fl- 2 fp-contract) (fl* 2 fp-contract) (fl/ 2)
      ;; flneg is NOT (fl- 0.0 x): they disagree at x = 0.0, where the first
      ;; gives 0.0 and true negation gives -0.0, and the sign survives a
      ;; subsequent divide. ref.c writes -px. This is the normative spelling.
      (flneg 1) (flabs 1) (flsqrt 1)
      ;; flonum comparison. fl> and fl>= are NOT derivable from fl< and fl<= by
      ;; negation, because NaN makes every comparison false, so (not (fl<= a b))
      ;; is true for NaN while (fl> a b) is false.
      (fl< 2) (fl<= 2) (fl= 2) (fl>= 2) (fl> 2)
      ;; conversion
      (fl->fx 1 overflow-check) (fx->fl 1)
      ;; unboxed float storage
      (flvector-ref 2 type-check bounds-check)
      (flvector-set! 3 type-check bounds-check)
      (flvector-length 1 type-check)
      (make-flvector 2 type-check)
      ;; general storage
      (vector-ref 2 type-check bounds-check)
      (vector-set! 3 type-check bounds-check)
      (vector-length 1 type-check)
      (make-vector 2 type-check)
      ;; pairs
      (car 1 type-check) (cdr 1 type-check) (cons 2) (eq? 2)
      ;; TYPE PREDICATES. Without these, configuration 2c is inexpressible in
      ;; Lcore, because 2c is DEFINED by its predicate guards, and phase 3's
      ;; finding that guards recover nothing could not be reproduced through
      ;; our own compiler.
      (null? 1) (pair? 1) (fixnum? 1) (flonum? 1) (vector? 1) (flvector? 1)
      ;; and something for a failed guard to do
      (error 1)))

  (define (primitive? x) (and (assq x prim-table) #t))
  (define (prim-arity pr) (cadr (assq pr prim-table)))
  ;; Which named checks this primitive can even have. A control may only be
  ;; given for a check in this list; anything else is a malformed primcall.
  (define (prim-checks pr) (cddr (assq pr prim-table)))
  ;; Default is fully checked. The expander starts here and the policy form
  ;; and the analysis are the only things that may weaken it.
  (define (default-controls pr) (map (lambda (n) (list n 'checked)) (prim-checks pr)))

  ;; A CONTROL INPUT on a primcall. This is the mechanism the whole project
  ;; argued for: whether a primitive checks is a property of the CALL SITE, not
  ;; a global dial. Chez's optimize-level being global rather than lexical is
  ;; wall 3 of the four that made it unable to host the experiment.
  ;;
  ;;   checked    emit the check
  ;;   unchecked  the policy suppressed it
  ;;   proved     the analysis DISCHARGED it; semantically identical to checked
  ;;
  ;; `proved` and `unchecked` emit the same code and mean very different things.
  ;; Keeping them distinct is what lets us report how many checks were removed
  ;; by proof versus by permission, which is the number phase 3 says matters.
  (define (control? x) (and (memq x '(checked unchecked proved)) #t))

  ;; Named checks, Ada-style, per D5. Measured: named per-check suppression and
  ;; Suppress(All_Checks) are identical to the instruction at 801.00 instr/step,
  ;; so granularity costs nothing.
  ;;
  ;; fp-contract is here rather than in a separate flags namespace because D24
  ;; makes it the same KIND of thing: a named permission, lexically scoped,
  ;; default off. It is not a check being suppressed, it is a rewrite being
  ;; permitted, and the policy form carries both.
  (define check-names
    '(bounds-check type-check overflow-check div-check fp-contract))
  (define (check-name? x) (and (memq x check-names) #t))
  (define (all-check-names) check-names)

  ;; POLICY names a check to suppress. PREMISE asserts a fact for the
  ;; inferencer to propagate. They were the same vocabulary, which meant
  ;; `declare` could only ever say "this check may be omitted" and could not say
  ;; anything about the VALUE -- no way to assert non-aliasing (which got its
  ;; own production) and no way to assert non-NaN.
  ;;
  ;; non-nan is why this split had to happen now. A negated flonum comparison
  ;; licenses nothing, because NaN makes every comparison false, so
  ;; (not (fl< a b)) is true for NaN while (fl>= a b) is false. With a non-NaN
  ;; premise in scope the negation becomes usable again, and without one the
  ;; false edge of every float guard is dead to the analysis forever.
  (define (policy-name? x) (check-name? x))

  (define premise-names
    (append check-names '(non-nan fixnum flonum flvector vector)))
  (define (premise-name? x) (and (memq x premise-names) #t))
  (define (all-premise-names) premise-names)

  ;; --- storage classes, for Lrepr -------------------------------------------
  ;; SBCL's IR2 is the reference: values get assigned to a specific storage
  ;; class and register file, and that assignment is what makes unboxed f64 in
  ;; registers possible at all.
  ;;
  ;; `tagged` and `raw` are not decoration: they ARE the register partition from
  ;; sonic/doc/register-partition.md, so this is where D21's invariant enters the
  ;; IR. A `tagged` value may only be allocated to the value class; the
  ;; collector scavenges that class unconditionally, consulting no metadata.
  (define storage-classes '(tagged raw-word raw-f64))
  (define (storage-class? x) (and (memq x storage-classes) #t))

  ;; --- machine-independent lowered ops, for Lmach ---------------------------
  ;; Deliberately NOT target instructions. This is the last IR both back ends
  ;; consume, so an op here must be expressible on x86-64 AND RV64. Anything
  ;; that is not goes in the target-specific selector, not here.
  (define mach-ops
    '(add sub mul div neg sqrt abs                  ; arithmetic
      ;; Comparison is split by OPERAND type, not result type. The `sc` a
      ;; selection rule receives is the class of the boolean RESULT, so a single
      ;; cmp-lt cannot tell whether it is comparing two fixnums or two flonums,
      ;; and the two need different instructions: x86-64 wants cmp + signed
      ;; setcc for integers and ucomisd + UNSIGNED setcc for doubles, because
      ;; IEEE comparison sets the carry flag. Without the split, flonum
      ;; comparison is unselectable.
      cmp-lt cmp-le cmp-eq cmp-ge cmp-gt            ; integer comparison
      fcmp-lt fcmp-le fcmp-eq fcmp-ge fcmp-gt       ; f64 comparison
      load store                                    ; memory, with a scale
      move                                          ; data movement
      ;; int<->float conversion. fl->fx and fx->fl were in the primitive table
      ;; with no mach op to select from, so fcvt.d.l was encodable and
      ;; unreachable.
      cvt-f64-from-int cvt-int-from-f64
      ;; Load a vector's length field. A bounds check needs a LIMIT, and the
      ;; limit is not in the IR anywhere: the primcall carries the vector, not
      ;; its length. Without this op, lowering a bounds check has nothing to
      ;; compare the index against, and both targets read the check's second
      ;; operand as an already-materialised limit.
      vlen
      branch branch-if jump                         ; control
      call ret))                                    ; calls
  ;; There is deliberately NO mach-op spelling of a check.
  ;;
  ;; `check-bounds`, `check-type` and `check-overflow` used to live here
  ;; alongside the `chk` production, and the duplication was pure cost. `chk`
  ;; carries the CONTROL -- whether the analysis proved the check, a policy
  ;; suppressed it, or it survived -- and the EXPECTED TAG. The mach-ops
  ;; carried neither, and there was nowhere to put them: a mach-op is
  ;; (op v sc v* ...) and every slot is spoken for.
  ;;
  ;; So a type check through that spelling had no tag and passed 0, which is
  ;; not a no-answer marker but the fixnum tag: "check this is something"
  ;; compiled to "check this is a fixnum", a branch that always traps for any
  ;; other type. That, plus an arity skew between the two spellings that Chez
  ;; warned about on every build, was bd 5hs.
  ;;
  ;; Nothing ever emitted them. lower.ss produces `chk` and only `chk`.
  (define (mach-op? x) (and (memq x mach-ops) #t))

  ;; Virtual registers are symbols; the allocator maps them to real ones under
  ;; the partition. Kept as symbols rather than a record so fixtures stay
  ;; writable by hand, which is the whole point of freezing these contracts.
  (define (vreg? x) (symbol? x))

  ;; --- Lcore ----------------------------------------------------------------
  ;; Surface syntax has already been expanded away. Still tree-shaped: operands
  ;; may be arbitrary expressions. A-normalization is a later pass.

  (define-language Lcore
    (terminals
      ;; `lbl` is a second meta-variable for the same terminal, used where a
      ;; symbol names a control-flow predecessor rather than a variable. Lmach
      ;; uses it the same way.
      (symbol      (x lbl))
      (primitive   (pr))
      (control     (c))
      (policy-name (pn))
      (premise-name (prem))
      (boolean     (b))
      (datum       (d)))
    (Expr (e body)
      x
      (quote d)
      (if e0 e1 e2)
      (let ([x* e*] ...) body)
      (letrec ([x* e*] ...) body)
      (lambda (x* ...) body)
      (call e0 e* ...)
      ;; The control input rides on the call, not on the primitive, and there
      ;; is ONE PER APPLICABLE CHECK rather than one per call.
      ;;
      ;; A single tri-state per primcall would collapse D5's granularity to one
      ;; bit exactly where it matters: flvector-ref has both a type check and a
      ;; bounds check, and "bounds elided, type still checked" is precisely the
      ;; state the analysis produces. D5 was ratified on the measurement that
      ;; named granularity is free (ada-8-named and ada-8-all identical at
      ;; 801.00 instr/step), so collapsing it here would discard the finding the
      ;; whole project rests on.
      (primcall pr ([pn* c*] ...) e* ...)
      ;; PREMISES. (declare ((x pn) ...) body) asserts facts the inferencer may
      ;; propagate. This is what SRFI 145 would have been if anyone shipped it,
      ;; and phase 1 found nobody does.
      ;; The unspecified value. NOT (quote ()) and not any other datum: a
      ;; one-armed `if`, a `when` that does not fire, a falling-off `cond` and
      ;; an empty `begin` all need a value that is not confusable with a real
      ;; one. Spelling it as the empty list makes it TRUTHY, so
      ;; (if (when #f 1) 'a 'b) would give 'a, which is wrong.
      (void)
      ;; Assignment. `letrec` alone cannot express it, and every benchmark past
      ;; config1 mutates a vector, so the expander had nowhere to put `set!`.
      ;; Assignment conversion (boxing a mutated variable into a one-slot cell)
      ;; is a later pass and needs this production to consume.
      (set! x e)
      ;; letrec* as well as letrec. R7RS gives letrec* SEQUENTIAL initialization
      ;; and internal defines expand to it, so collapsing the two at the
      ;; expander boundary silently drops a guarantee that let*-heavy code
      ;; leans on.
      (letrec* ([x* e*] ...) body)
      (declare ([x* prem*] ...) body)
      ;; DISTINCTNESS as a premise. `declare` can only assert check names, so
      ;; there was no way to write "these arrays do not alias each other" and
      ;; alias analysis had to answer `may` for every kernel that receives its
      ;; arrays as parameters, which is what a real entry point looks like:
      ;; nbody's kernel takes its flvectors as arguments and the allocation
      ;; happened in a caller the compiler may not even have.
      ;;
      ;; C99 spells this `restrict` and Ada spells it as a pragma. It is a
      ;; PREMISE in the D5 sense, not a check being suppressed, so it gets its
      ;; own production rather than widening the check vocabulary: a premise the
      ;; programmer asserts and the compiler propagates, with undefined
      ;; behaviour if violated.
      (declare-distinct (x* ...) body)
      ;; LEXICAL check policy. The thing no Scheme standard has ever had.
      ;; (policy ((pn on?) ...) body)
      (policy ([pn* b*] ...) body)
      (begin e* ... e))
    ;; A top-level program. Lmach had a `program` production and Lcore did not,
    ;; so the expander had nowhere to put top-level definitions and stage 03
    ;; would have had to invent the shape.
    ;;
    ;; The second list names what is OUTSIDE this compilation unit.
    ;;
    ;; Without it, "opaque, I cannot see this" had to be spelled as an unbound
    ;; free variable in operator position. That works, and it is
    ;; indistinguishable from a misspelling, so a genuine typo read as a
    ;; deliberate external reference and silently got the conservative answer
    ;; instead of an error. Naming externs explicitly makes an unbound variable
    ;; a bug again.
    ;;
    ;; (nanopass will not take a keyword inside a production, so this is
    ;; positional: bindings, then externs, then the body.)
    (Program (prog)
      (top ([x* e*] ...) (x2* ...) body)))

  ;; --- Lanf -----------------------------------------------------------------
  ;; A-normal form. Every intermediate is named.
  ;;
  ;; This is a PRECONDITION for the analysis, not a tidiness preference: the
  ;; abstract interpreter hangs an interval on each variable, so an unnamed
  ;; subexpression has nowhere to put its value and the transfer functions
  ;; cannot compose. sonic/src/sonic/analyze.ss already assumes it.

  (define-language Lanf
    (extends Lcore)
    (Expr (e body)
      (- (if e0 e1 e2)
         (let ([x* e*] ...) body)
         (call e0 e* ...)
         (primcall pr ([pn* c*] ...) e* ...)
         (letrec* ([x* e*] ...) body)
         (begin e* ... e))
      ;; Operands are now atoms only.
      ;;
      ;; `tailcall` is an Expr while an ordinary `call` is a SimpleExpr, and the
      ;; split is the point of ANF rather than an accident. A non-tail call has
      ;; its result named by the enclosing `let`; a tail call has no result to
      ;; name because the frame is gone. Without this production a loop written
      ;; as tail recursion is inexpressible, which is most loops in Scheme.
      (+ (if x e0 e1)
         (let ([x se]) body)
         (tailcall x x* ...)
         (seq e0 e1)))
    ;; Simple expressions: what may appear on the right of a let.
    (SimpleExpr (se)
      (+ x
         (quote d)
         (lambda (x* ...) body)
         (call x x* ...)
         (primcall pr ([pn* c*] ...) x* ...))))

  ;; --- Lssa -----------------------------------------------------------------
  ;; Extended SSA. Adds phi at control-flow joins and SIGMA at branch edges.
  ;;
  ;; Sigma is what distinguishes e-SSA from plain SSA and it is why ABCD needs
  ;; this language rather than the previous one: it gives the branch condition a
  ;; NAME on each edge, so `i < n` on the true edge becomes a fact attached to a
  ;; variable the analysis can refine. Without it the interval domain cannot see
  ;; which side of a test it is on.

  (define-language Lssa
    (extends Lanf)
    (Expr (e body)
      ;; phi carries PER-PREDECESSOR operands, not just the merged name.
      ;;
      ;; (phi ([x (pred val) ...] ...) body) : x is the merge of val from each
      ;; labelled predecessor.
      ;;
      ;; The earlier shape named the merge and not the incoming values, which
      ;; the loop pass reported as costing something specific. A header phi was
      ;; recoverable anyway, because a tailcall's argument list is positionally
      ;; parallel to the lambda's parameter list, so the back-edge operands
      ;; could be found by indexing call sites. But a VALUE-position diamond
      ;; carried nothing: an induction variable stepped inside a conditional,
      ;; `i2 = if c then i+1 else i+2` or any loop with a `continue`, had an
      ;; opaque back-edge operand and came back `unknown` forever.
      ;;
      ;; ABCD needs per-predecessor operands for its constraint graph, so this
      ;; had to land before that bead rather than after.
      (+ (phi ([x* (lbl* e*) ...] ...) body)
         ;; (sigma x-out x-in cmp x-other negated?) : x-out is x-in, refined by
         ;; knowing that (cmp x-in x-other) HELD on this edge when negated? is
         ;; #f, and that it FAILED when negated? is #t.
         ;;
         ;; THE FLAG IS NOT FOLDED INTO `pr`, and that is the whole point of it.
         ;; A comparison that failed is not in general the same as its opposite
         ;; comparison. NaN compares false against everything, so (not (fl< a b))
         ;; is TRUE when either operand is NaN while (fl>= a b) is FALSE.
         ;; Spelling the false edge as fl>= would assert an ordering in exactly
         ;; the case where none holds, and the consumer is bounds-check elision,
         ;; so that is a wrong-code bug rather than a lost optimization.
         ;;
         ;; So sigma records the SYNTACTIC fact -- the comparison as written,
         ;; plus which edge this is -- and the DOMAIN decides what follows from
         ;; it. (sonic interval) turns not(a<b) into a>=b for fixnums and into
         ;; nothing at all for flonums, and that is the only place the NaN rule
         ;; is encoded. The alternative, a table of negated primitives, needs an
         ;; fx<> and five flonum spellings that do not exist and must not.
         (sigma x0 x1 pr x2 b body))))

  ;; --- Lrepr ----------------------------------------------------------------
  ;; Storage classes assigned. Every binding now says where its value lives.

  (define-language Lrepr
    (extends Lssa)
    (terminals
      (+ (storage-class (sc))))
    (Expr (e body)
      (- (let ([x se]) body))
      (+ (let ([x sc se]) body))))

  ;; --- Lmach ----------------------------------------------------------------
  ;; Machine-independent lowered form. Virtual registers, explicit memory ops,
  ;; a flat instruction list per block. Both back ends consume THIS.
  ;;
  ;; An op here must be expressible on x86-64 AND RV64. Anything that is not
  ;; belongs in the target selector.

  (define-language Lmach
    (terminals
      (symbol        (lbl))
      (vreg          (v))
      (mach-op       (op))
      (storage-class (sc))
      (policy-name   (pn))
      (control       (c))
      (datum         (d)))
    (Prog (prog)
      (program ([lbl* blk*] ...) lbl))
    (Block (blk)
      (block (i* ...) t))
    (Instr (i)
      (op v sc v* ...)
      ;; `const` is a production rather than a mach-op: it takes a datum where
      ;; every other op takes vregs, so folding it in would make (op v sc ...)
      ;; ambiguous.
      (const v sc d)
      ;; A check that survived to codegen, still carrying WHY. `proved` never
      ;; reaches here (the elision pass drops it); `unchecked` and `checked` do,
      ;; and they are distinguishable so the report can say which.
      ;; A check that survived to codegen, carrying WHY (the control) and, for
      ;; a type check, WHAT TAG was expected.
      ;;
      ;; The tag is not optional decoration. `chk type-check` names the check
      ;; but, without it, there is no constant to compare the value against, so
      ;; a surviving type check was unselectable on BOTH targets: numeric.ss
      ;; fixes a 3-bit tag scheme, the constant exists, and `chk` simply could
      ;; not say which one. `d` is that tag, and it is meaningless for the
      ;; other checks, which pass 0.
      (chk pn c d v* ...))
    (Transfer (t)
      (jump lbl)
      (branch-if v lbl0 lbl1)
      (ret v)))
  )
