;;; Tests for the numeric tower and the primitives.
;;;
;;; The value of this file is entirely in its boundaries. A suite that checks
;;; (fx+ 1 2) proves that the plumbing is connected and nothing else; every
;;; interesting property of a fixnum-and-flonum tower lives at the exact range
;;; limits, at the signed zeros, at the infinities, and at NaN, and every one of
;;; those is a place where an implementation can be wrong in a way that no
;;; ordinary program reveals until a benchmark result is quietly off in the last
;;; few bits. D24 says a tolerance-based oracle is where an unsound analysis
;;; would hide; the same is true of a tolerant test suite.
;;;
;;; Four things get proved here that are not just plumbing:
;;;
;;;   1. The modelled 61-bit wrap agrees with the host's actual untagged machine
;;;      add and multiply. `fx-wrap` is written in exact integer arithmetic and
;;;      knows nothing about Chez, so agreement with #3%fx+ is independent
;;;      evidence for the tag scheme rather than a restatement of it.
;;;   2. FP contraction is observable. The witness triple below differs by
;;;      almost a factor of two between one rounding and two, which is why D24
;;;      makes contraction a permission rather than a default.
;;;   3. checked signals where unchecked does not, at the exact limits.
;;;   4. `proved` runs the same code as `unchecked` and yet is distinguishable
;;;      from it, because only `proved` made a claim that can be audited.
;;;
;;; Run: scheme -q --libdirs src:vendor/nanopass --script test/numeric-test.ss
;;;      (from sonic/)

(import (chezscheme)
        (sonic numeric)
        (sonic prims)
        (sonic lang))

(define failures 0)
(define checks 0)

(define (check! name ok)
  (set! checks (+ checks 1))
  (unless ok
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name) (newline)))

(define (check=! name got want)
  (set! checks (+ checks 1))
  (unless (equal? got want)
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name)
    (display "  got ") (write got)
    (display "  want ") (write want) (newline)))

;; Flonum equality by BITS. fl= cannot see the difference between 0.0 and -0.0
;; and reports #f for NaN against itself, so it is the wrong instrument for
;; every test in the flonum section below.
(define (check-fl! name got want)
  (set! checks (+ checks 1))
  (unless (fl-identical? got want)
    (set! failures (+ failures 1))
    (display "FAIL: ") (display name)
    (display "  got ") (write got)
    (display "  want ") (write want) (newline)))

;; --- signalling helpers ----------------------------------------------------
;; `signalled` catches EVERYTHING, deliberately. The distinction the suite cares
;; about is not raised-versus-not, it is whether one of OUR named checks ran.

(define (signalled thunk)
  (guard (e (#t e)) (begin (thunk) 'no-signal)))

(define (signals-kind? kind thunk)
  (let ((r (signalled thunk)))
    (and (sonic-condition? r) (eq? (sonic-condition-kind r) kind))))

(define (no-sonic-signal? thunk)
  (not (sonic-condition? (signalled thunk))))

(define (p pr c . args) (apply prim-apply pr c args))

;; ===========================================================================
;; 1. the tag scheme and the fixnum range that falls out of it
;; ===========================================================================

(check=! "word is 64 bits" fx-word-bits 64)
(check=! "tag costs 3 bits" fx-tag-bits 3)
(check=! "value bits are 64 - 3" fx-value-bits 61)

;; The range stated two ways: as the derived constants, and as the literal
;; decimal a reader can check against the comment in numeric.ss.
(check=! "fx-greatest is 2^60 - 1" fx-greatest (- (expt 2 60) 1))
(check=! "fx-least is -2^60"       fx-least    (- (expt 2 60)))
(check=! "fx-greatest literal" fx-greatest 1152921504606846975)
(check=! "fx-least literal"    fx-least   -1152921504606846976)

;; 61 value bits, sign included: the range spans exactly 2^61 integers.
(check=! "range spans 2^61" (+ (- fx-greatest fx-least) 1) (expt 2 61))

(check! "fx-greatest is a fixnum"      (sonic-fixnum? fx-greatest))
(check! "fx-least is a fixnum"         (sonic-fixnum? fx-least))
(check! "fx-greatest + 1 is not"  (not (sonic-fixnum? (+ fx-greatest 1))))
(check! "fx-least - 1 is not"     (not (sonic-fixnum? (- fx-least 1))))
(check! "a flonum is not a fixnum" (not (sonic-fixnum? 1.0)))
(check! "an inexact integer is not a fixnum" (not (sonic-fixnum? 3.0)))

;; --- the wrap, and the machine op as an independent witness ----------------
;; fx-wrap is exact integer arithmetic over a stated modulus. #3%fx+ is Chez's
;; untagged machine add. They were written by different people for different
;; reasons and they must agree, or the modelled tag scheme is not the one the
;; hardware has.

(check=! "wrap: greatest + 1 is least"  (fx-wrap (+ fx-greatest 1)) fx-least)
(check=! "wrap: least - 1 is greatest"  (fx-wrap (- fx-least 1)) fx-greatest)
(check=! "wrap: in range is identity"   (fx-wrap 12345) 12345)
(check=! "wrap: greatest is identity"   (fx-wrap fx-greatest) fx-greatest)
(check=! "wrap: 2^61 is zero"           (fx-wrap (expt 2 61)) 0)

(let ((pairs (list (cons fx-greatest 1)
                   (cons fx-greatest fx-greatest)
                   (cons fx-least -1)
                   (cons fx-least fx-least)
                   (cons fx-greatest -1)
                   (cons (- fx-greatest 1) 1)
                   (cons 0 0)
                   (cons -1 1)
                   (cons 123456789 987654321))))
  (for-each
   (lambda (ab)
     (let ((a (car ab)) (b (cdr ab)))
       (check=! "modelled add wrap matches the machine add"
                (fx-wrap (+ a b)) (#3%fx+ a b))
       (check=! "modelled sub wrap matches the machine sub"
                (fx-wrap (- a b)) (#3%fx- a b))
       (check=! "modelled mul wrap matches the machine mul"
                (fx-wrap (* a b)) (#3%fx* a b))))
   pairs))

;; ===========================================================================
;; 2. fixnum arithmetic at the exact limits, under each control
;; ===========================================================================

;; --- checked: lands on the limit, does not go past it ----------------------

(check=! "checked fx+ reaches fx-greatest exactly"
         (p 'fx+ 'checked (- fx-greatest 1) 1) fx-greatest)
(check=! "checked fx- reaches fx-least exactly"
         (p 'fx- 'checked (+ fx-least 1) 1) fx-least)
(check=! "checked fx+ at the limit with 0 is fine"
         (p 'fx+ 'checked fx-greatest 0) fx-greatest)
(check=! "checked fx* reaches the limit"
         (p 'fx* 'checked (- (expt 2 59)) 2) fx-least)

(check! "checked fx+ overflow signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fx+ 'checked fx-greatest 1))))
(check! "checked fx+ underflow signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fx+ 'checked fx-least -1))))
(check! "checked fx- underflow signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fx- 'checked fx-least 1))))
(check! "checked fx- overflow signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fx- 'checked fx-greatest -1))))
(check! "checked fx* overflow signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fx* 'checked fx-greatest 2))))
(check! "checked fx* underflow signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fx* 'checked fx-least -1))))

;; The condition carries WHO and WHAT, because D5's granularity argument only
;; pays off if the diagnostic can be counted by name afterwards.
(let ((e (signalled (lambda () (p 'fx+ 'checked fx-greatest 1)))))
  (check! "condition is a sonic-condition" (sonic-condition? e))
  (check=! "condition names the primitive" (sonic-condition-who e) 'fx+)
  (check=! "condition carries the operands"
           (sonic-condition-irritants e) (list fx-greatest 1)))

;; --- unchecked: no signal, and the documented wrap --------------------------

(check! "unchecked fx+ overflow does not signal"
        (no-sonic-signal? (lambda () (p 'fx+ 'unchecked fx-greatest 1))))
(check=! "unchecked fx+ wraps greatest+1 to least"
         (p 'fx+ 'unchecked fx-greatest 1) fx-least)
(check=! "unchecked fx- wraps least-1 to greatest"
         (p 'fx- 'unchecked fx-least 1) fx-greatest)
(check=! "unchecked fx+ wraps least-1 to greatest"
         (p 'fx+ 'unchecked fx-least -1) fx-greatest)
;; 2 * (2^60 - 1) = 2^61 - 2, which wraps to -2.
(check=! "unchecked fx* wraps greatest*2 to -2"
         (p 'fx* 'unchecked fx-greatest 2) -2)
(check=! "unchecked fx* wraps least*-1 to least"
         (p 'fx* 'unchecked fx-least -1) fx-least)
(check=! "unchecked result is always a fixnum again"
         (sonic-fixnum? (p 'fx* 'unchecked fx-greatest fx-greatest)) #t)

;; --- proved: identical instructions to unchecked ---------------------------

(check=! "proved fx+ overflow behaves exactly like unchecked"
         (p 'fx+ 'proved fx-greatest 1) (p 'fx+ 'unchecked fx-greatest 1))
(check! "proved fx+ overflow does not signal when the audit is off"
        (no-sonic-signal? (lambda () (p 'fx+ 'proved fx-greatest 1))))
(check=! "the audit is off by default" (proved-audit) #f)

;; --- proved, audited: the analysis is what gets accused, not the program ---

(parameterize ((proved-audit #t))
  (check! "audited proved fx+ overflow signals analysis-unsound"
          (signals-kind? 'analysis-unsound (lambda () (p 'fx+ 'proved fx-greatest 1))))
  (check=! "audited proved fx+ in range is unaffected"
           (p 'fx+ 'proved 2 3) 5)
  ;; The whole reason the two controls stay distinct: `unchecked` never made a
  ;; claim, so there is nothing to audit and the audit must not touch it.
  (check! "unchecked is never audited"
          (no-sonic-signal? (lambda () (p 'fx+ 'unchecked fx-greatest 1))))
  (check=! "unchecked still wraps under the audit"
           (p 'fx+ 'unchecked fx-greatest 1) fx-least))

;; --- comparisons at the limits ---------------------------------------------

(check=! "fx< across the whole range" (p 'fx< 'checked fx-least fx-greatest) #t)
(check=! "fx< is strict at the top"   (p 'fx< 'checked fx-greatest fx-greatest) #f)
(check=! "fx<= is not"                (p 'fx<= 'checked fx-greatest fx-greatest) #t)
(check=! "fx= at the top"             (p 'fx= 'checked fx-greatest fx-greatest) #t)
(check=! "fx> across the whole range" (p 'fx> 'checked fx-greatest fx-least) #t)
(check=! "fx>= at the bottom"         (p 'fx>= 'checked fx-least fx-least) #t)
(check=! "comparisons agree unchecked"
         (p 'fx< 'unchecked fx-least fx-greatest) #t)

(check! "checked fx< type-checks its operands"
        (signals-kind? 'type-check (lambda () (p 'fx< 'checked 1.0 2))))
(check! "checked fx+ type-checks an out-of-range integer"
        (signals-kind? 'type-check (lambda () (p 'fx+ 'checked (+ fx-greatest 1) 0))))
(check! "unchecked fx< does not type-check"
        (no-sonic-signal? (lambda () (p 'fx< 'unchecked 1.0 2.0))))

;; ===========================================================================
;; 3. flonums: IEEE 754 binary64
;; ===========================================================================

;; --- signed zeros ----------------------------------------------------------
;; The pair of values that fl= says are equal and that behave differently in
;; every other respect. Getting this wrong is silent until a division shows up.

(check=! "-0.0 has the sign bit set"   (fl-bits -0.0) (expt 2 63))
(check=! "0.0 is all zero bits"        (fl-bits 0.0) 0)
(check! "fl= cannot tell the zeros apart"   (p 'fl= 'checked -0.0 0.0))
(check! "fl-identical? can"        (not (fl-identical? -0.0 0.0)))
(check! "fl-negative-zero? on -0.0"      (fl-negative-zero? -0.0))
(check! "fl-negative-zero? not on 0.0" (not (fl-negative-zero? 0.0)))
(check=! "neither zero is less than the other" (p 'fl< 'checked -0.0 0.0) #f)

;; IEEE 754 round-to-nearest: (-0) + (+0) is +0, and only (-0) + (-0) is -0.
(check-fl! "(-0.0) + 0.0 is 0.0"   (p 'fl+ 'checked -0.0 0.0) 0.0)
(check-fl! "(-0.0) + (-0.0) is -0.0" (p 'fl+ 'checked -0.0 -0.0) -0.0)
(check-fl! "0.0 - 0.0 is 0.0"      (p 'fl- 'checked 0.0 0.0) 0.0)
(check-fl! "-1.0 * 0.0 is -0.0"    (p 'fl* 'checked -1.0 0.0) -0.0)
(check-fl! "flabs clears the sign of -0.0" (p 'flabs 'checked -0.0) 0.0)
(check-fl! "flsqrt of -0.0 is -0.0, per IEEE" (p 'flsqrt 'checked -0.0) -0.0)

;; The gap this exposes: the frozen table has no flonum negation primitive, and
;; (fl- 0.0 x) is NOT negation. It disagrees with IEEE negation at x = 0.0, so
;; a program that spells negation this way is not bit-exact against a C arm
;; that spells it -x. bench/nbody/config2c-chez.ss line 78 spells it this way.
(check-fl! "(fl- 0.0 0.0) is 0.0, so it is not negation" (p 'fl- 'checked 0.0 0.0) 0.0)
(check-fl! "true negation of 0.0 would be -0.0" (fl- 0.0) -0.0)
(check! "so the two disagree at zero"
        (not (fl-identical? (p 'fl- 'checked 0.0 0.0) (fl- 0.0))))

;; --- infinities ------------------------------------------------------------
;; Values, not errors. Nothing here signals under any control.

(check-fl! "1.0 / 0.0 is +inf"   (p 'fl/ 'checked 1.0 0.0) +inf.0)
(check-fl! "1.0 / -0.0 is -inf"  (p 'fl/ 'checked 1.0 -0.0) -inf.0)
(check-fl! "-1.0 / 0.0 is -inf"  (p 'fl/ 'checked -1.0 0.0) -inf.0)
(check! "division by zero does not signal"
        (no-sonic-signal? (lambda () (p 'fl/ 'checked 1.0 0.0))))
(check-fl! "inf + 1.0 is inf"    (p 'fl+ 'checked +inf.0 1.0) +inf.0)
(check-fl! "inf * 2.0 is inf"    (p 'fl* 'checked +inf.0 2.0) +inf.0)
(check-fl! "1.0 / inf is 0.0"    (p 'fl/ 'checked 1.0 +inf.0) 0.0)
(check-fl! "1.0 / -inf is -0.0"  (p 'fl/ 'checked 1.0 -inf.0) -0.0)
(check-fl! "flabs of -inf is +inf" (p 'flabs 'checked -inf.0) +inf.0)
(check-fl! "flsqrt of +inf is +inf" (p 'flsqrt 'checked +inf.0) +inf.0)
(check! "fl-infinite? on +inf" (fl-infinite? +inf.0))
(check! "fl-infinite? on -inf" (fl-infinite? -inf.0))
(check! "fl-finite? on 1.0"    (fl-finite? 1.0))
(check! "fl-finite? not on inf" (not (fl-finite? +inf.0)))

;; Overflow of the flonum range produces an infinity and does not signal. There
;; is no overflow-check on a flonum operation, and that is IEEE, not laziness.
(check-fl! "flonum overflow yields +inf" (p 'fl* 'checked 1e308 10.0) +inf.0)
(check! "flonum overflow does not signal"
        (no-sonic-signal? (lambda () (p 'fl* 'checked 1e308 10.0))))
;; Underflow to zero, likewise silent.
(check-fl! "flonum underflow yields 0.0" (p 'fl* 'checked 1e-308 1e-308) 0.0)

;; --- NaN -------------------------------------------------------------------
;; The value that is not equal to itself. Every ordered comparison against NaN
;; is false, INCLUDING fl<=, which is the one people get wrong by assuming it is
;; the negation of fl>.

(check! "0.0 / 0.0 is NaN"     (fl-nan? (p 'fl/ 'checked 0.0 0.0)))
(check! "inf - inf is NaN"     (fl-nan? (p 'fl- 'checked +inf.0 +inf.0)))
(check! "0.0 * inf is NaN"     (fl-nan? (p 'fl* 'checked 0.0 +inf.0)))
(check! "inf / inf is NaN"     (fl-nan? (p 'fl/ 'checked +inf.0 +inf.0)))
(check! "flsqrt of a negative is NaN" (fl-nan? (p 'flsqrt 'checked -1.0)))
(check! "flsqrt of a negative does not signal"
        (no-sonic-signal? (lambda () (p 'flsqrt 'checked -1.0))))
(check! "flabs of NaN is still NaN" (fl-nan? (p 'flabs 'checked +nan.0)))

(check=! "fl= NaN NaN is false"   (p 'fl= 'checked +nan.0 +nan.0) #f)
(check=! "fl= NaN 1.0 is false"   (p 'fl= 'checked +nan.0 1.0) #f)
(check=! "fl< NaN 1.0 is false"   (p 'fl< 'checked +nan.0 1.0) #f)
(check=! "fl< 1.0 NaN is false"   (p 'fl< 'checked 1.0 +nan.0) #f)
(check=! "fl<= NaN NaN is false"  (p 'fl<= 'checked +nan.0 +nan.0) #f)
(check=! "fl<= NaN 1.0 is false"  (p 'fl<= 'checked +nan.0 1.0) #f)
;; So fl<= is not the complement of anything, and a loop guarded by (fl< x y)
;; exits on NaN while one guarded by (not (fl>= x y)) would not.
(check! "not fl< and not fl>=, both, on NaN"
        (and (not (p 'fl< 'checked +nan.0 1.0))
             (not (p 'fl<= 'checked +nan.0 1.0))))
(check! "NaN is not identical to a different NaN payload by fl="
        (not (p 'fl= 'checked (p 'fl/ 'checked 0.0 0.0) (p 'fl/ 'checked 0.0 0.0))))

;; --- FP contraction is default OFF, per D24 --------------------------------
;;
;; The witness. Two roundings and one rounding differ by nearly a factor of two
;; here, which is what makes contraction a correctness question and not a
;; performance one. Found by the RISC-V smoke gate: RV64 gcc contracts to
;; fmadd.d by default, baseline x86-64 has no FMA to contract into, and the
;; eleven-way bit-exact cross-agreement holds only with contraction off.

(define (contracted a b c)                  ; single rounding, as an FMA would
  (exact->inexact (+ (* (inexact->exact a) (inexact->exact b))
                     (inexact->exact c))))

(let* ((a 0.1) (b 0.1) (c -0.01)
       (two-step (p 'fl+ 'checked (p 'fl* 'checked a b) c))
       (one-step (contracted a b c)))
  (check-fl! "uncontracted a*b+c rounds twice" two-step 1.734723475976807e-18)
  (check-fl! "contracted a*b+c rounds once"    one-step 9.020562075079397e-19)
  (check! "contraction is observable, and not in the last bit"
          (not (fl-identical? two-step one-step)))
  ;; the ratio is close to 1.92, not 1 + epsilon
  (check! "the two answers differ by more than a factor of 1.5"
          (fl> (fl/ two-step one-step) 1.5)))

;; And under every control, because contraction is a permission granted by
;; `fp-contract`, not a check suppressed by `unchecked`. Suppressing checks must
;; never change the value computed.
(let ((a 0.1) (b 0.1) (c -0.01))
  (check-fl! "unchecked does not contract"
             (p 'fl+ 'unchecked (p 'fl* 'unchecked a b) c) 1.734723475976807e-18)
  (check-fl! "proved does not contract"
             (p 'fl+ 'proved (p 'fl* 'proved a b) c) 1.734723475976807e-18))

;; ===========================================================================
;; 4. conversion between the towers
;; ===========================================================================

;; fl->fx truncates toward zero. Not floor, not round: cvttsd2si.
(check=! "fl->fx truncates 2.7 toward zero"  (p 'fl->fx 'checked 2.7) 2)
(check=! "fl->fx truncates -2.7 toward zero" (p 'fl->fx 'checked -2.7) -2)
(check=! "fl->fx of -0.5 is 0"               (p 'fl->fx 'checked -0.5) 0)
(check=! "fl->fx of -0.0 is 0"               (p 'fl->fx 'checked -0.0) 0)
(check=! "fl->fx of exactly fx-least"
         (p 'fl->fx 'checked (exact->inexact fx-least)) fx-least)

;; Checked conversion signals rather than producing a wrong fixnum.
(check! "fl->fx of NaN signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fl->fx 'checked +nan.0))))
(check! "fl->fx of +inf signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fl->fx 'checked +inf.0))))
(check! "fl->fx of -inf signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fl->fx 'checked -inf.0))))
(check! "fl->fx of 1e30 signals overflow-check"
        (signals-kind? 'overflow-check (lambda () (p 'fl->fx 'checked 1e30))))

;; Unchecked reproduces the hardware. cvttsd2si writes the integer indefinite
;; value -2^63 for NaN, infinities and out-of-range sources; the tagging shift
;; then discards three bits, and -2^63 is -4 * 2^61, so the answer is 0 with no
;; diagnostic at all. That silence is the argument for checked being the
;; default at this site.
(check=! "unchecked fl->fx of NaN is 0"   (p 'fl->fx 'unchecked +nan.0) 0)
(check=! "unchecked fl->fx of +inf is 0"  (p 'fl->fx 'unchecked +inf.0) 0)
(check=! "unchecked fl->fx of -inf is 0"  (p 'fl->fx 'unchecked -inf.0) 0)
(check=! "unchecked fl->fx of 1e30 is 0"  (p 'fl->fx 'unchecked 1e30) 0)
(check! "unchecked fl->fx of NaN does not signal"
        (no-sonic-signal? (lambda () (p 'fl->fx 'unchecked +nan.0))))
(check=! "unchecked fl->fx still truncates a normal value"
         (p 'fl->fx 'unchecked -2.7) -2)

;; fx->fl rounds, and there is no control under which it does not. binary64 has
;; 53 significand bits and a fixnum has 61.
(check! "fx->fl is exact up to 2^53"       (fx->fl-exact? (expt 2 53)))
(check! "fx->fl is not exact past 2^53" (not (fx->fl-exact? (+ (expt 2 53) 1))))
(check! "fx-greatest is past the exact range" (not (fx->fl-exact? fx-greatest)))
(check-fl! "fx->fl of fx-greatest rounds UP to 2^60"
           (p 'fx->fl 'checked fx-greatest) (exact->inexact (expt 2 60)))
(check-fl! "fx->fl of fx-least is exact, being a power of two"
           (p 'fx->fl 'checked fx-least) (exact->inexact (- (expt 2 60))))

;; The consequence worth naming: fx-greatest does not survive a round trip, and
;; the return leg is where it is caught rather than where it went wrong.
(check! "round-tripping fx-greatest through a flonum signals on the way back"
        (signals-kind? 'overflow-check
                       (lambda () (p 'fl->fx 'checked (p 'fx->fl 'checked fx-greatest)))))
(check=! "round trip is exact well inside 2^53"
         (p 'fl->fx 'checked (p 'fx->fl 'checked 123456789)) 123456789)
(check=! "round trip is exact at 2^53"
         (p 'fl->fx 'checked (p 'fx->fl 'checked (expt 2 53))) (expt 2 53))

(check! "checked fx->fl type-checks"
        (signals-kind? 'type-check (lambda () (p 'fx->fl 'checked 1.0))))
(check! "checked fl->fx type-checks"
        (signals-kind? 'type-check (lambda () (p 'fl->fx 'checked 1))))

;; ===========================================================================
;; 5. checked signals where unchecked does not: the memory primitives
;; ===========================================================================
;;
;; The hosted model does not reproduce the target's wild load; see the header of
;; prims.ss for why relying on the host's unsafe primitives was tried and
;; rejected. What is asserted here is the part that IS specified: that our named
;; check ran, or did not.

(define v4 (p 'make-flvector 'checked 4 1.5))

(check=! "flvector-length" (p 'flvector-length 'checked v4) 4)
(check-fl! "flvector-ref in bounds" (p 'flvector-ref 'checked v4 0) 1.5)
(check-fl! "flvector-ref at the last index" (p 'flvector-ref 'checked v4 3) 1.5)

(check! "checked flvector-ref past the end signals bounds-check"
        (signals-kind? 'bounds-check (lambda () (p 'flvector-ref 'checked v4 4))))
(check! "checked flvector-ref at a negative index signals bounds-check"
        (signals-kind? 'bounds-check (lambda () (p 'flvector-ref 'checked v4 -1))))
(check! "UNCHECKED flvector-ref past the end runs no bounds check"
        (no-sonic-signal? (lambda () (p 'flvector-ref 'unchecked v4 4))))
(check! "PROVED flvector-ref past the end runs no bounds check either"
        (no-sonic-signal? (lambda () (p 'flvector-ref 'proved v4 4))))
;; and yet proved is still distinguishable from unchecked
(parameterize ((proved-audit #t))
  (check! "audited proved flvector-ref past the end accuses the analysis"
          (signals-kind? 'analysis-unsound (lambda () (p 'flvector-ref 'proved v4 4))))
  (check! "audited unchecked flvector-ref past the end accuses nobody"
          (no-sonic-signal? (lambda () (p 'flvector-ref 'unchecked v4 4)))))

;; Index type and index range are separately named checks, so a non-fixnum index
;; must report type-check and not bounds-check.
(check! "a flonum index is a type-check, not a bounds-check"
        (signals-kind? 'type-check (lambda () (p 'flvector-ref 'checked v4 1.0))))
(check! "a non-flvector is a type-check"
        (signals-kind? 'type-check (lambda () (p 'flvector-ref 'checked 5 0))))

(let ((v (p 'make-flvector 'checked 2 0.0)))
  (p 'flvector-set! 'checked v 0 2.5)
  (check-fl! "flvector-set! then ref" (p 'flvector-ref 'checked v 0) 2.5)
  (p 'flvector-set! 'unchecked v 1 -0.0)
  (check-fl! "flvector storage is bit-faithful, including -0.0"
             (p 'flvector-ref 'checked v 1) -0.0)
  (check! "flvector-set! of a non-flonum is a type-check"
          (signals-kind? 'type-check (lambda () (p 'flvector-set! 'checked v 0 1))))
  (check! "flvector-set! past the end is a bounds-check"
          (signals-kind? 'bounds-check (lambda () (p 'flvector-set! 'checked v 2 1.0)))))

(check! "make-flvector of a negative length is a type-check"
        (signals-kind? 'type-check (lambda () (p 'make-flvector 'checked -1 0.0))))
(check! "make-flvector with a non-flonum fill is a type-check"
        (signals-kind? 'type-check (lambda () (p 'make-flvector 'checked 2 0))))
(check=! "make-flvector of length 0 is fine"
         (p 'flvector-length 'checked (p 'make-flvector 'checked 0 0.0)) 0)

;; --- general vectors, same shape -------------------------------------------

(let ((v (p 'make-vector 'checked 3 'z)))
  (check=! "vector-length" (p 'vector-length 'checked v) 3)
  (check=! "vector-ref" (p 'vector-ref 'checked v 0) 'z)
  (p 'vector-set! 'checked v 2 'q)
  (check=! "vector-set! then ref" (p 'vector-ref 'checked v 2) 'q)
  (check! "checked vector-ref past the end signals bounds-check"
          (signals-kind? 'bounds-check (lambda () (p 'vector-ref 'checked v 3))))
  (check! "unchecked vector-ref past the end runs no bounds check"
          (no-sonic-signal? (lambda () (p 'vector-ref 'unchecked v 3))))
  (check! "a non-vector is a type-check"
          (signals-kind? 'type-check (lambda () (p 'vector-ref 'checked 'nope 0)))))

;; --- pairs and identity ----------------------------------------------------

(let ((pr (p 'cons 'checked 1 2)))
  (check=! "car" (p 'car 'checked pr) 1)
  (check=! "cdr" (p 'cdr 'checked pr) 2)
  (check=! "pair?" (p 'pair? 'checked pr) #t)
  (check=! "null? on a pair" (p 'null? 'checked pr) #f)
  (check=! "null? on the empty list" (p 'null? 'checked '()) #t))

(check! "checked car of a non-pair signals type-check"
        (signals-kind? 'type-check (lambda () (p 'car 'checked '()))))
(check! "checked cdr of a non-pair signals type-check"
        (signals-kind? 'type-check (lambda () (p 'cdr 'checked 7))))
(check! "unchecked car of a non-pair runs no type check"
        (no-sonic-signal? (lambda () (p 'car 'unchecked '()))))

;; eq? is exact over the whole fixnum range as a CONSEQUENCE of the tag scheme:
;; a fixnum is an immediate, so equal fixnums are the identical machine word.
(check=! "eq? on fx-greatest" (p 'eq? 'checked fx-greatest fx-greatest) #t)
(check=! "eq? on fx-least"    (p 'eq? 'checked fx-least fx-least) #t)
(check=! "eq? distinguishes adjacent fixnums"
         (p 'eq? 'checked fx-greatest (- fx-greatest 1)) #f)
(let ((x '(a)))
  (check=! "eq? on the same pair" (p 'eq? 'checked x x) #t)
  (check=! "eq? on distinct pairs" (p 'eq? 'checked x (list 'a)) #f))

;; ===========================================================================
;; 6. the table agrees with the frozen one in lang.ss, both directions
;; ===========================================================================
;;
;; Copied verbatim from sonic/src/sonic/lang.ss. prims.ss deliberately does not
;; import (sonic lang) -- the runtime must not depend on the compiler's IR
;; library -- so the agreement is asserted here instead, where a divergence is a
;; test failure rather than an architecture violation.

(define frozen-primitives
  '(fx+ fx- fx* fx< fx<= fx= fx>= fx>
    fl+ fl- fl* fl/ fl< fl<= fl= flsqrt flabs
    fl->fx fx->fl
    flvector-ref flvector-set! flvector-length make-flvector
    vector-ref vector-set! vector-length make-vector
    car cdr cons null? pair? eq?))

;; the copy is honest
(for-each (lambda (n)
            (check! (string-append "lang.ss agrees " (symbol->string n))
                    (primitive? n)))
          frozen-primitives)

;; nothing frozen is missing
(for-each (lambda (n)
            (check! (string-append "implemented: " (symbol->string n))
                    (prim-implemented? n)))
          frozen-primitives)

;; nothing extra is implemented
(for-each (lambda (n)
            (check! (string-append "not a smuggled extra: " (symbol->string n))
                    (primitive? n)))
          (prim-names))

(check=! "the two tables are the same size"
         (length (prim-names)) (length frozen-primitives))
(check=! "thirty-three primitives" (length frozen-primitives) 33)

;; the control vocabulary matches too
(for-each (lambda (c)
            (check! (string-append "lang.ss knows control " (symbol->string c))
                    (control? c)))
          (prim-controls))
(check=! "three controls" (length (prim-controls)) 3)

;; every check name a condition can carry is a check name lang.ss declares,
;; except analysis-unsound, which is not a check at all: it accuses the
;; analysis, not the program, and has no suppression story.
(for-each (lambda (k)
            (unless (eq? k 'analysis-unsound)
              (check! (string-append "lang.ss knows check " (symbol->string k))
                      (check-name? k))))
          (sonic-condition-kinds))
(check! "analysis-unsound is deliberately NOT a lang.ss check name"
        (not (check-name? 'analysis-unsound)))
;; fp-contract is a check name in lang.ss with no runtime condition, and that is
;; correct: D24 makes it a rewrite being PERMITTED, not a check being suppressed,
;; so nothing at run time can fail it.
(check! "fp-contract is a lang.ss name with no runtime condition"
        (and (check-name? 'fp-contract)
             (not (memq 'fp-contract (sonic-condition-kinds)))))
;; div-check is likewise declared and unreachable, but for a different reason:
;; there is no integer division primitive in the frozen table, and fl/ by zero
;; is an IEEE infinity rather than an error. Pinned so that adding fx/ later has
;; to come past this test.
(check! "div-check is declared but unreachable: no integer division primitive"
        (and (check-name? 'div-check)
             (not (memq 'fx/ frozen-primitives))
             (not (memq 'fxquotient frozen-primitives))))

;; --- arity, and malformed primcalls ----------------------------------------
;; A bad primcall is a COMPILER bug and must be a hard error, never a
;; sonic-condition, or a handler counting check failures would swallow it.

(check=! "arity of fx+" (prim-arity 'fx+) 2)
(check=! "arity of car" (prim-arity 'car) 1)
(check=! "arity of flvector-set!" (prim-arity 'flvector-set!) 3)
(check=! "arity of make-flvector" (prim-arity 'make-flvector) 2)
(check=! "an unknown primitive has no arity" (prim-arity 'fx/) #f)
(check! "a wrong argument count is a hard error, not a check failure"
        (let ((r (signalled (lambda () (p 'fx+ 'checked 1)))))
          (and (not (eq? r 'no-signal)) (not (sonic-condition? r)))))
(check! "an unknown control is a hard error"
        (let ((r (signalled (lambda () (p 'fx+ 'maybe 1 2)))))
          (and (not (eq? r 'no-signal)) (not (sonic-condition? r)))))
(check! "an unknown primitive is a hard error"
        (let ((r (signalled (lambda () (p 'fx/ 'checked 1 2)))))
          (and (not (eq? r 'no-signal)) (not (sonic-condition? r)))))

;; ===========================================================================
;; 7. the nbody inner loop, end to end
;; ===========================================================================
;; Not a plumbing test: it is the one place the suite checks that the pieces
;; compose into the access pattern the benchmark actually has, b[i*7 + k] over a
;; length-35 flvector, and that the answer is identical under all three controls
;; when no check would have fired. If suppressing a check ever changes a value,
;; the whole measurement is meaningless.

(let* ((slots 7) (nbody 5) (len (* nbody slots))
       (b (p 'make-flvector 'checked len 0.0))
       (g (lambda (control i k)
            (p 'flvector-ref control b
               (p 'fx+ control (p 'fx* control i slots) k))))
       ;; the pairwise distance kernel, one step, under a single control
       (kernel (lambda (control i j)
                 (let* ((dx (p 'fl- control (g control i 0) (g control j 0)))
                        (d2 (p 'fl* control dx dx)))
                   (p 'fl/ control 0.01
                      (p 'fl* control d2 (p 'flsqrt control d2)))))))
  (let loop ((i 0))
    (when (< i len)
      (p 'flvector-set! 'checked b i (p 'fx->fl 'checked i))
      (loop (+ i 1))))
  (check-fl! "b[4*7+6] is the last element" (g 'checked 4 6) 34.0)
  (check-fl! "unchecked agrees exactly"     (g 'unchecked 4 6) 34.0)
  (check-fl! "proved agrees exactly"        (g 'proved 4 6) 34.0)
  (let ((a (kernel 'checked 0 1))
        (u (kernel 'unchecked 0 1))
        (r (kernel 'proved 0 1)))
    (check! "kernel is bit-identical checked vs unchecked" (fl-identical? a u))
    (check! "kernel is bit-identical checked vs proved"    (fl-identical? a r))))

(newline)
(display checks) (display " checks, ") (display failures) (display " failures") (newline)
(if (> failures 0) (exit 1) (begin (display "PASS") (newline) (exit 0)))
