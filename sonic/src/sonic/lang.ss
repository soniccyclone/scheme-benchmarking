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
          primitive? control? policy-name? datum?
          check-name? all-check-names
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
  (define (policy-name? x) (check-name? x))

  ;; --- Lcore ----------------------------------------------------------------
  ;; Surface syntax has already been expanded away. Still tree-shaped: operands
  ;; may be arbitrary expressions. A-normalization is a later pass.

  (define-language Lcore
    (terminals
      (symbol      (x))
      (primitive   (pr))
      (control     (c))
      (policy-name (pn))
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
      (declare ([x* pn*] ...) body)
      ;; LEXICAL check policy. The thing no Scheme standard has ever had.
      ;; (policy ((pn on?) ...) body)
      (policy ([pn* b*] ...) body)
      (begin e* ... e)))

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
         (begin e* ... e))
      ;; Operands are now atoms only.
      (+ (if x e0 e1)
         (let ([x se]) body)
         (seq e0 e1)))
    ;; Simple expressions: what may appear on the right of a let.
    (SimpleExpr (se)
      (+ x
         (quote d)
         (lambda (x* ...) body)
         (call x x* ...)
         (primcall pr ([pn* c*] ...) x* ...))))
  )
