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
          check-name? all-check-names)
  (import (chezscheme) (nanopass))

  ;; --- terminals ------------------------------------------------------------

  (define (datum? x)
    (or (number? x) (boolean? x) (char? x) (string? x) (null? x) (symbol? x)))

  ;; The primitives the benchmarks need. Deliberately small: the numeric tower
  ;; is fixnum and flonum only, so no bignum, ratnum or complex.
  (define primitives
    '(fx+ fx- fx* fx< fx<= fx= fx>= fx>
      fl+ fl- fl* fl/ fl< fl<= fl= flsqrt flabs
      fl->fx fx->fl
      flvector-ref flvector-set! flvector-length make-flvector
      vector-ref vector-set! vector-length make-vector
      car cdr cons null? pair? eq?))
  (define (primitive? x) (and (memq x primitives) #t))

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
      ;; The control input rides on the call, not on the primitive.
      (primcall pr c e* ...)
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
         (primcall pr c e* ...)
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
         (primcall pr c x* ...))))
  )
