;;; SonicScheme: the primitives, parameterised by control input.
;;;
;;; Stage E7. Every primitive in the frozen table in sonic/src/sonic/lang.ss,
;;; and NOTHING ELSE. Thirty-three of them. If a benchmark needs a thirty-fourth
;;; the answer is to unfreeze the table in lang.ss and argue for it there, not
;;; to add it here, because the table is an inter-stage contract and a runtime
;;; that implements a superset of it is a runtime that lets a back-end bug
;;; through as a working program.
;;;
;;; The interface is one entry point:
;;;
;;;     (prim-apply 'flvector-ref 'checked v i)
;;;
;;; which is the shape of Lcore's `(primcall pr c e* ...)` with the operands
;;; already evaluated. The control rides on the CALL, not on the primitive, and
;;; this file is where that stops being a grammar decision and starts being
;;; behaviour. lang.ss states the vocabulary:
;;;
;;;   checked    emit the check
;;;   unchecked  the policy suppressed it
;;;   proved     the analysis DISCHARGED it; semantically identical to checked
;;;
;;; So `proved` and `unchecked` run the same instructions here, deliberately and
;;; without exception. What separates them is what they CLAIM. `proved` claims
;;; the obligation cannot fail, which is a testable claim, so (proved-audit #t)
;;; re-runs it and signals `analysis-unsound` when the analysis was wrong.
;;; `unchecked` claims nothing except that someone granted permission, so it is
;;; never audited. That asymmetry is the whole reason to carry two symbols for
;;; one instruction sequence, and it is what lets phase 3 report checks removed
;;; by proof separately from checks removed by permission.
;;;
;;; --- on modelling unchecked memory access ---------------------------------
;;;
;;; An unchecked `flvector-ref` past the end is a wild load on the target. This
;;; file does NOT reproduce that, and the choice is deliberate.
;;;
;;; Chez can express it: `#3%flvector-ref` selects the unsafe variant. That was
;;; tried and rejected, because it is not stable enough to build a semantics on.
;;; Measured on Chez 10.0.0: the same `#3%flvector-ref` call returns garbage
;;; silently when it reaches the callee through a closure, and raises Chez's own
;;; bounds condition when the call site is inlinable and the arguments are
;;; literals. The behaviour of the model would then depend on cp0's inlining
;;; decisions rather than on anything we specified. A semantic model whose
;;; answer changes with the host optimizer's mood is worse than no model.
;;;
;;; So: the unchecked path simply omits OUR check and calls the host operation.
;;; Out of bounds is undefined behaviour and the model says so; what it
;;; guarantees, and what numeric-test.ss asserts, is the thing that is actually
;;; specified — that the named bounds-check did not run, observable as the
;;; absence of a sonic-condition. The fixnum overflow case IS reproduced
;;; exactly, via `fx-wrap`, because there the target's behaviour is a defined
;;; two's-complement wrap rather than a wild load. See numeric.ss section 2.
;;;
;;; --- what this file does not import ---------------------------------------
;;;
;;; Not (sonic lang). The runtime must not depend on the compiler's IR library
;;; or the dependency graph inverts and the runtime drags nanopass in at run
;;; time. The control vocabulary and the primitive names are therefore repeated
;;; here as plain data, and numeric-test.ss asserts that this file's table and
;;; lang.ss's table are the same set in both directions. The agreement belongs
;;; in a test, where a divergence is a failure, rather than in an import, where
;;; it would be an architecture violation.
;;;
;;; Style follows sonic/src/sonic/interval.ss. Run the tests with:
;;;   cd sonic && scheme -q --libdirs src:vendor/nanopass --script test/numeric-test.ss

(library (sonic prims)
  (export prim-apply prim-procedure prim-arity
          prim-implemented? prim-names prim-controls)

  ;; (chezscheme) for flvectors, which are unboxed f64 storage and are in no
  ;; Scheme standard, and which are the single storage decision the whole nbody
  ;; measurement rests on.
  (import (chezscheme) (sonic numeric))

  ;; --- the table ------------------------------------------------------------
  ;; An association list, name -> (arity . procedure). Data, not a set of
  ;; exported bindings: the consumer is a pass walking `(primcall pr c e* ...)`
  ;; with `pr` in hand as a symbol, so a table is what it wants, and a table can
  ;; be compared against lang.ss's frozen list without reflection.

  (define prim-table '())

  (define (register! name arity proc)
    (when (assq name prim-table)
      (error 'sonic-prims "duplicate primitive" name))
    (set! prim-table (append prim-table (list (cons name (cons arity proc))))))

  (define-syntax define-prim
    (syntax-rules ()
      ((_ (name c a ...) b0 b ...)
       (register! 'name (length '(a ...)) (lambda (c a ...) b0 b ...)))))

  (define (prim-controls) '(checked unchecked proved))

  (define (prim-entry pr) (let ((e (assq pr prim-table))) (and e (cdr e))))
  (define (prim-implemented? pr) (and (prim-entry pr) #t))
  (define (prim-arity pr) (let ((e (prim-entry pr))) (and e (car e))))
  (define (prim-procedure pr) (let ((e (prim-entry pr))) (and e (cdr e))))
  (define (prim-names) (map car prim-table))

  ;; A missing primitive, a wrong argument count or an unknown control is a
  ;; COMPILER bug, so it is a hard error and never a sonic-condition. Keeping
  ;; the two apart matters: a handler installed to count check failures must not
  ;; also swallow a malformed primcall, or a broken pass shows up in the results
  ;; as a suspiciously high check count.
  (define (prim-apply pr c . args)
    (let ((e (prim-entry pr)))
      (unless e (error 'prim-apply "not a primitive" pr))
      (unless (memq c (prim-controls)) (error 'prim-apply "not a control" c pr))
      (unless (= (length args) (car e))
        (error 'prim-apply "wrong argument count" pr (car e) (length args)))
      (apply (cdr e) c args)))

  ;; --- check helpers --------------------------------------------------------
  ;; Called only on the checked path. Each signals with the NAMED check it
  ;; implements, from the same vocabulary as lang.ss's check-names, so that a
  ;; handler can count bounds checks separately from type checks. D5's argument
  ;; is that the granularity is free at the instruction level; it is only free
  ;; at the reporting level if the diagnostic carries the name.

  (define (need-fixnum who x)
    (unless (sonic-fixnum? x) (signal-check 'type-check who x)))

  (define (need-flonum who x)
    (unless (sonic-flonum? x) (signal-check 'type-check who x)))

  (define (need-flvector who x)
    (unless (flvector? x) (signal-check 'type-check who x)))

  (define (need-vector who x)
    (unless (vector? x) (signal-check 'type-check who x)))

  (define (need-pair who x)
    (unless (pair? x) (signal-check 'type-check who x)))

  ;; A length is a non-negative fixnum. Failing that is a type-check and not a
  ;; bounds-check: there is no object yet whose bounds could be violated.
  (define (need-length who n)
    (unless (and (sonic-fixnum? n) (>= n 0)) (signal-check 'type-check who n)))

  ;; Index type and index range are two DIFFERENT named checks and must signal
  ;; separately, because `(policy ([type-check #f]) ...)` and
  ;; `(policy ([bounds-check #f]) ...)` are independently grantable.
  (define (need-index who i len)
    (need-fixnum who i)
    (unless (and (>= i 0) (< i len)) (signal-check 'bounds-check who i len)))

  ;; The proved-site audit. A macro rather than a procedure so that the
  ;; obligation is not evaluated at all when the audit is off, which is the
  ;; normal case and the one whose cost the whole project is measuring.
  (define-syntax audit
    (syntax-rules ()
      ((_ c who ok irritant ...)
       (when (and (eq? c 'proved) (proved-audit))
         (unless ok (signal-check 'analysis-unsound who irritant ...))))))

  (define-syntax checked?
    (syntax-rules () ((_ c) (eq? c 'checked))))

  ;; The two families that differ only in which host operation they call.
  ;; Declared here rather than beside their uses because a library body is
  ;; definitions and then expressions, and every `define-prim` below expands to
  ;; a `register!` call, which is an expression.
  ;;
  ;; Fixnum comparisons cannot overflow, so type-check is the only check they
  ;; carry. They are still control-parameterised: on the target the type test is
  ;; a `test r, 7` and a branch per operand, and deleting it is what the
  ;; analysis is for.
  (define-syntax define-fx-compare
    (syntax-rules ()
      ((_ name op)
       (define-prim (name c a b)
         (cond ((checked? c)
                (need-fixnum 'name a) (need-fixnum 'name b)
                (op a b))
               (else
                (audit c 'name (and (sonic-fixnum? a) (sonic-fixnum? b)) a b)
                (op a b)))))))

  (define-syntax define-fl-binary
    (syntax-rules ()
      ((_ name op)
       (define-prim (name c a b)
         (cond ((checked? c)
                (need-flonum 'name a) (need-flonum 'name b)
                (op a b))
               (else
                (audit c 'name (and (sonic-flonum? a) (sonic-flonum? b)) a b)
                (op a b)))))))

  ;; ==========================================================================
  ;; fixnum arithmetic
  ;; ==========================================================================
  ;;
  ;; Strictly binary. No variadic forms anywhere in this file: Lanf is A-normal
  ;; and each primcall is meant to become one machine instruction, and for the
  ;; flonum operations the association order of a multi-operand form is
  ;; observable in the result bits, so the expander must fix it rather than the
  ;; runtime.
  ;;
  ;; The unchecked path is `(fx-wrap (+ a b))` rather than the host's unsafe
  ;; fx+. Same answer, but stated in terms of the model's own 61-bit modulus, so
  ;; the model does not inherit its overflow semantics from whatever Chez was
  ;; built for. numeric-test.ss checks the two against each other, which makes
  ;; the host's machine op an independent witness instead of the definition.

  (define-prim (fx+ c a b)
    (cond ((checked? c)
           (need-fixnum 'fx+ a) (need-fixnum 'fx+ b)
           (when (fx-add-overflows? a b) (signal-check 'overflow-check 'fx+ a b))
           (+ a b))
          (else
           (audit c 'fx+ (and (sonic-fixnum? a) (sonic-fixnum? b)
                              (not (fx-add-overflows? a b))) a b)
           (fx-wrap (+ a b)))))

  (define-prim (fx- c a b)
    (cond ((checked? c)
           (need-fixnum 'fx- a) (need-fixnum 'fx- b)
           (when (fx-sub-overflows? a b) (signal-check 'overflow-check 'fx- a b))
           (- a b))
          (else
           (audit c 'fx- (and (sonic-fixnum? a) (sonic-fixnum? b)
                              (not (fx-sub-overflows? a b))) a b)
           (fx-wrap (- a b)))))

  (define-prim (fx* c a b)
    (cond ((checked? c)
           (need-fixnum 'fx* a) (need-fixnum 'fx* b)
           (when (fx-mul-overflows? a b) (signal-check 'overflow-check 'fx* a b))
           (* a b))
          (else
           (audit c 'fx* (and (sonic-fixnum? a) (sonic-fixnum? b)
                              (not (fx-mul-overflows? a b))) a b)
           (fx-wrap (* a b)))))

  (define-fx-compare fx<  <)
  (define-fx-compare fx<= <=)
  (define-fx-compare fx=  =)
  (define-fx-compare fx>= >=)
  (define-fx-compare fx>  >)

  ;; ==========================================================================
  ;; flonum arithmetic
  ;; ==========================================================================
  ;;
  ;; IEEE 754 binary64 throughout, round-to-nearest-ties-to-even, one correctly
  ;; rounded operation per primitive and NEVER a fused one. Infinities and NaN
  ;; are values and not errors, so no flonum operation here signals under any
  ;; control except on a type violation. In particular fl/ by zero yields an
  ;; infinity per IEEE and the named check `div-check` does not apply to it;
  ;; trapping it would make the reference C arm of the oracle disagree with us
  ;; on inputs where C is right.
  ;;
  ;; FP contraction is default off per D24, and nothing in this file contracts.
  ;; The obligation that follows is on the back end: when the `fp-contract`
  ;; permission is NOT granted, the emitted code must round twice for
  ;; (fl+ (fl* a b) c) and must agree with this file bit for bit.

  (define-fl-binary fl+ fl+)
  (define-fl-binary fl- fl-)
  (define-fl-binary fl* fl*)
  (define-fl-binary fl/ fl/)          ; x/0.0 is an infinity, not an error
  (define-fl-binary fl< fl<)
  (define-fl-binary fl<= fl<=)
  (define-fl-binary fl= fl=)          ; #f whenever either operand is NaN

  ;; flsqrt of a negative is NaN per IEEE, not an error. flsqrt of -0.0 is -0.0,
  ;; which is the case a naive `(if (fl< x 0.0) nan (sqrt x))` gets wrong.
  (define-prim (flsqrt c x)
    (cond ((checked? c) (need-flonum 'flsqrt x) (flsqrt x))
          (else (audit c 'flsqrt (sonic-flonum? x) x) (flsqrt x))))

  ;; flabs clears the sign bit. -0.0 becomes 0.0 and NaN stays NaN; it is a bit
  ;; operation, not a comparison against zero.
  (define-prim (flabs c x)
    (cond ((checked? c) (need-flonum 'flabs x) (flabs x))
          (else (audit c 'flabs (sonic-flonum? x) x) (flabs x))))

  ;; ==========================================================================
  ;; conversion
  ;; ==========================================================================

  ;; TRUNCATES TOWARD ZERO, because that is cvttsd2si. Checked signals
  ;; overflow-check when the source is NaN, infinite, or truncates outside the
  ;; fixnum range. Unchecked reproduces the hardware: the indefinite value
  ;; -2^63 tagged by a three-bit left shift, which is fixnum 0, so NaN and both
  ;; infinities convert silently to 0. See numeric.ss fl->fx-wrap.
  (define-prim (fl->fx c x)
    (cond ((checked? c)
           (need-flonum 'fl->fx x)
           (unless (fl->fx-representable? x) (signal-check 'overflow-check 'fl->fx x))
           (fl->fx-truncate x))
          (else
           (audit c 'fl->fx (and (sonic-flonum? x) (fl->fx-representable? x)) x)
           (fl->fx-wrap x))))

  ;; ROUNDS, and there is no control that makes it not round: binary64 has 53
  ;; significand bits and the fixnum has 61, so this is a lossy conversion for
  ;; magnitudes above 2^53 and the loss is silent by design. fx-greatest is the
  ;; sharp case, rounding up to 2^60, which is not a fixnum. Not signalling that
  ;; is correct, because rounding a real to the nearest binary64 is the defined
  ;; behaviour of the conversion and not an error condition.
  (define-prim (fx->fl c n)
    (cond ((checked? c) (need-fixnum 'fx->fl n) (exact->inexact n))
          (else (audit c 'fx->fl (sonic-fixnum? n) n) (exact->inexact n))))

  ;; ==========================================================================
  ;; flvectors: unboxed binary64 storage
  ;; ==========================================================================
  ;;
  ;; The storage decision the nbody measurement rests on. An flvector holds raw
  ;; doubles with no per-element box and no header per element, so a reference
  ;; is one load and no pointer chase, and the collector never has to scan the
  ;; payload. That last part is why flvector-set! needs no write barrier while
  ;; vector-set! does.

  (define-prim (flvector-ref c v i)
    (cond ((checked? c)
           (need-flvector 'flvector-ref v)
           (need-index 'flvector-ref i (flvector-length v))
           (flvector-ref v i))
          (else
           (audit c 'flvector-ref
                  (and (flvector? v) (sonic-fixnum? i)
                       (>= i 0) (< i (flvector-length v))) v i)
           (flvector-ref v i))))

  (define-prim (flvector-set! c v i x)
    (cond ((checked? c)
           (need-flvector 'flvector-set! v)
           (need-index 'flvector-set! i (flvector-length v))
           (need-flonum 'flvector-set! x)
           (flvector-set! v i x))
          (else
           (audit c 'flvector-set!
                  (and (flvector? v) (sonic-fixnum? i)
                       (>= i 0) (< i (flvector-length v)) (sonic-flonum? x)) v i x)
           (flvector-set! v i x))))

  ;; The length is a header field, so this is one load and it is the operand
  ;; the interval domain needs in order to discharge a bounds check at all.
  (define-prim (flvector-length c v)
    (cond ((checked? c) (need-flvector 'flvector-length v) (flvector-length v))
          (else (audit c 'flvector-length (flvector? v) v) (flvector-length v))))

  ;; The fill is MANDATORY, unlike Chez's own make-flvector. An uninitialised
  ;; flvector is not a GC hazard, because the payload is never scanned, but it
  ;; is a determinism hazard: the bit-exact oracle cannot tolerate a program
  ;; whose output depends on what was previously in the nursery.
  (define-prim (make-flvector c n x)
    (cond ((checked? c)
           (need-length 'make-flvector n)
           (need-flonum 'make-flvector x)
           (make-flvector n x))
          (else
           (audit c 'make-flvector
                  (and (sonic-fixnum? n) (>= n 0) (sonic-flonum? x)) n x)
           (make-flvector n x))))

  ;; ==========================================================================
  ;; general vectors
  ;; ==========================================================================
  ;;
  ;; Boxed slots, so the collector scans them and vector-set! carries the write
  ;; barrier: store, test one tag bit, push the slot address if the stored value
  ;; is not a fixnum. That barrier is the price of choosing a generational
  ;; collector and is not modelled here, but it is why an algorithm that can use
  ;; an flvector should never use a vector.

  (define-prim (vector-ref c v i)
    (cond ((checked? c)
           (need-vector 'vector-ref v)
           (need-index 'vector-ref i (vector-length v))
           (vector-ref v i))
          (else
           (audit c 'vector-ref
                  (and (vector? v) (sonic-fixnum? i)
                       (>= i 0) (< i (vector-length v))) v i)
           (vector-ref v i))))

  (define-prim (vector-set! c v i x)
    (cond ((checked? c)
           (need-vector 'vector-set! v)
           (need-index 'vector-set! i (vector-length v))
           (vector-set! v i x))
          (else
           (audit c 'vector-set!
                  (and (vector? v) (sonic-fixnum? i)
                       (>= i 0) (< i (vector-length v))) v i)
           (vector-set! v i x))))

  (define-prim (vector-length c v)
    (cond ((checked? c) (need-vector 'vector-length v) (vector-length v))
          (else (audit c 'vector-length (vector? v) v) (vector-length v))))

  ;; Fill mandatory here for a harder reason than for flvectors: a general
  ;; vector's slots are scanned by the collector, so an unfilled slot is a wild
  ;; pointer the moment the allocation is interrupted. Per D21 the allocator's
  ;; claim-then-fill window is a restart region for exactly this reason.
  (define-prim (make-vector c n x)
    (cond ((checked? c) (need-length 'make-vector n) (make-vector n x))
          (else (audit c 'make-vector (and (sonic-fixnum? n) (>= n 0)) n x)
                (make-vector n x))))

  ;; ==========================================================================
  ;; pairs and identity
  ;; ==========================================================================

  (define-prim (car c p)
    (cond ((checked? c) (need-pair 'car p) (car p))
          (else (audit c 'car (pair? p) p) (car p))))

  (define-prim (cdr c p)
    (cond ((checked? c) (need-pair 'cdr p) (cdr p))
          (else (audit c 'cdr (pair? p) p) (cdr p))))

  ;; Total on its arguments, so no control affects it. It can still fail, by
  ;; exhausting the heap, and per EXECUTION.md the collection worst case is
  ;; reserved before it is needed rather than discovered on the failing
  ;; allocation. That is a collector obligation, not a check, and there is no
  ;; check name for it.
  (define-prim (cons c a d) (cons a d))

  (define-prim (null? c x) (null? x))
  (define-prim (pair? c x) (pair? x))

  ;; Pointer identity. Reliable on fixnums as a CONSEQUENCE OF THE TAG SCHEME:
  ;; a fixnum is an immediate whose whole 64-bit word is value bits followed by
  ;; tag 000, so two equal fixnums are the identical word and eq? is exact over
  ;; the entire fixnum range. It is NOT reliable on flonums, which are boxed, so
  ;; (eq? 1.0 1.0) may be either answer and comparing flonums with eq? is always
  ;; a bug. Use fl= for numeric equality, or fl-identical? for bit equality.
  (define-prim (eq? c a b) (eq? a b))
  )
