;;; SonicScheme: the numeric tower. Fixnum and flonum, and nothing else.
;;;
;;; Stage E7. This is the SEMANTIC MODEL, hosted on Chez. A later bead lowers it
;;; to machine code. Per D25 there is no C anywhere in the running system, so
;;; "the runtime" means this file and its neighbours, not a libm shim.
;;;
;;; Two towers were on the table and only one of them is defensible for this
;;; project. A full R7RS tower (bignum, ratnum, rectangular and polar complex)
;;; costs a type dispatch on every single arithmetic site, because `+` must ask
;;; what it was handed before it can add. That dispatch is exactly where a naive
;;; implementation loses its performance, and none of the benchmarks need any of
;;; it: nbody is flonums in an flvector with fixnum indices, and that is the
;;; whole numeric surface. So the tower is two disjoint types with no implicit
;;; coercion between them, `fx->fl` and `fl->fx` are explicit primitives, and
;;; there is no generic `+` at all. The frozen primitive table in
;;; sonic/src/sonic/lang.ss already commits to this: there is no `+`, only `fx+`
;;; and `fl+`.
;;;
;;; What this file does NOT contain is the control logic. A primitive's checking
;;; behaviour is a property of the call site (`checked` / `unchecked` / `proved`
;;; on the primcall), and that lives in sonic/src/sonic/prims.ss. This file
;;; supplies the facts prims.ss composes: the range, the wrap, the classifiers,
;;; and the signalling machinery.
;;;
;;; ===========================================================================
;;; 1. THE TAG SCHEME, AND THE FIXNUM RANGE THAT FALLS OUT OF IT
;;; ===========================================================================
;;;
;;; Target is 64-bit. A value word is 64 bits and carries a 3-bit primary tag in
;;; its low bits, with fixnum tag 000. A fixnum's machine representation is
;;; therefore the value shifted left by 3.
;;;
;;;   63                                    3   2 1 0
;;;  +---------------------------------------+---+---+
;;;  |  value, two's complement, 61 bits     | 0 0 0 |   fixnum
;;;  +---------------------------------------+---+---+
;;;
;;;   value bits = 64 - 3 = 61, sign included
;;;   fx-greatest =  2^60 - 1 =  1152921504606846975
;;;   fx-least    = -2^60     = -1152921504606846976
;;;
;;; Why 3 bits and not 1, which is what SBCL uses on 64-bit and which would buy
;;; two more bits of range:
;;;
;;;   - The 3 bits are already free. Heap objects are 8-byte aligned, so the low
;;;     3 bits of every heap pointer are zero whether we use them or not. Taking
;;;     1 bit for fixnums leaves 7 odd encodings that then have to be subdivided
;;;     anyway, and the subdivision is not free: it moves work out of a single
;;;     `test r, 7` and into a second mask.
;;;   - Tag 000 makes fx+ and fx- plain machine add and sub with NO untagging,
;;;     because (a<<3) + (b<<3) = (a+b)<<3. fx* needs exactly one arithmetic
;;;     shift right. This is the same reason every serious implementation puts
;;;     zero in the fixnum tag.
;;;   - 2^60 is 1.15e18. Nothing in the benchmark set comes within twelve orders
;;;     of magnitude of it. Two more bits of range would buy nothing measurable
;;;     and would cost the tag space.
;;;
;;; And why it must be 61 specifically rather than any other reasonable width:
;;; the hosted model is one arm of the differential oracle (D24, oracle check 2,
;;; eleven-way bit-exact cross-agreement). Chez on a 64-bit build has
;;; (fixnum-width) = 61 with the identical tag layout. Picking the same width
;;; means the model's boundary IS the host's boundary, so overflow is detected
;;; at exactly the same place in both arms and the unsafe host primitive can be
;;; used as an independent witness for our wrap. Picking any other width would
;;; leave the model emulating a boundary the host does not have, which is a
;;; place for a silent disagreement to hide. The assertion at the bottom of this
;;; file enforces the equality and dies loudly if a host ever breaks it.
;;;
;;; docs/phases/07-compiler/CUJ.md stage 8 already says "bounds fit 61-bit tag",
;;; so this is a ratification of an existing choice, not a new one.
;;;
;;; ===========================================================================
;;; 2. FIXNUM OVERFLOW UNDER THE THREE CONTROLS
;;; ===========================================================================
;;;
;;; `checked`   fx+ computes the exact mathematical sum, tests whether it lies
;;;             in [fx-least, fx-greatest], and if not RAISES a sonic-condition
;;;             of kind overflow-check. It does not promote to a bignum: there
;;;             are no bignums. On the target this is an add followed by `jo`,
;;;             one not-taken branch on the fast path.
;;;
;;;             This matches R6RS, whose fx+ raises &implementation-restriction
;;;             when the result is not a fixnum, and it is what R7RS's "it is an
;;;             error" permits. Chez's own fx+ raises here too.
;;;
;;; `unchecked` UNDEFINED BEHAVIOUR, in the load-bearing sense: the compiler is
;;;             permitted to assume the overflow does not happen, and the range
;;;             analysis in sonic/src/sonic/interval.ss relies on that
;;;             permission to keep its intervals from having to model wraparound
;;;             at every add. An analysis that had to be sound under wrapping
;;;             would lose almost every bound it derives.
;;;
;;;             What ACTUALLY HAPPENS on this target, which is a separate
;;;             question from what is defined: the emitted instruction is a bare
;;;             64-bit add with no `jo`. Both operands have low bits 000, the
;;;             carry out of bit 63 is discarded, and the result's low bits are
;;;             still 000. So the tag survives and the value wraps two's
;;;             complement modulo 2^61:
;;;
;;;                 result = ((a + b + 2^60) mod 2^61) - 2^60
;;;
;;;             That is `fx-wrap` below. It is documented and implemented, not
;;;             because the language promises it, but because the differential
;;;             harness needs both arms to produce the same bits when a
;;;             benchmark strays into the region, and "undefined" with no stated
;;;             behaviour would make a divergence there unattributable.
;;;
;;;             Note the asymmetry that follows: it is legal for a future pass
;;;             to constant-fold an unchecked fx+ under the no-overflow
;;;             assumption and get a different answer than fx-wrap. That is not
;;;             a bug in either. It is what undefined means, and it is why
;;;             `unchecked` is a permission you have to grant deliberately.
;;;
;;; `proved`    Emits the SAME code as unchecked: no `jo`, wrap on overflow.
;;;             Semantically it is identical to `checked`, because the claim
;;;             attached to it is that the analysis DISCHARGED the check, so the
;;;             overflow cannot occur and the two agree on every reachable
;;;             input. If a proved site ever does overflow, the program was not
;;;             wrong; the ANALYSIS was unsound, and an unsound interval domain
;;;             is the single failure mode this project most needs to catch
;;;             early, because its symptom is a value that is only slightly
;;;             wrong. So `proved-audit` below turns proved sites into checked
;;;             sites that signal `analysis-unsound` instead of the ordinary
;;;             check name. Default off, because on the target a proved site has
;;;             no check to run.
;;;
;;;             Keeping proved distinct from unchecked costs nothing at run time
;;;             and is what lets phase 3 report checks removed by PROOF against
;;;             checks removed by PERMISSION, which lang.ss says is the number
;;;             that matters.
;;;
;;; fx- and fx* wrap by the same rule. fx* is the interesting one: the machine
;;; sequence is `sar 3` on one operand then `imul`, so the product wraps modulo
;;; 2^61 in the tagged value exactly as the sum does.
;;;
;;; ===========================================================================
;;; 3. FLONUMS ARE IEEE 754 binary64, AND CONTRACTION IS OFF
;;; ===========================================================================
;;;
;;; One flonum type, IEEE 754-2008 binary64. No single-precision, no extended.
;;; Round-to-nearest-ties-to-even, and the rounding mode is not settable: a
;;; dynamically settable mode is a hidden global input to every arithmetic site
;;; and would sink the bit-exactness oracle on its own.
;;;
;;; Every operation here is a single correctly-rounded binary64 operation.
;;; Infinities and NaN are VALUES, not errors: division by zero yields an
;;; infinity, 0/0 and inf-inf yield NaN, and `flsqrt` of a negative yields NaN.
;;; None of these signal under any control, and the named check `div-check` does
;;; not apply to fl/ for exactly this reason. Trapping them would contradict
;;; IEEE 754 and would make the reference C arm of the oracle disagree with us
;;; on inputs where C is right.
;;;
;;; FP CONTRACTION IS DEFAULT OFF, per D24. Contraction means fusing
;;; (fl+ (fl* a b) c) into a single fused-multiply-add, which rounds ONCE
;;; instead of twice and therefore returns different bits. It is observable and
;;; it is not small; numeric-test.ss carries the witness triple
;;;
;;;     a = 0.1, b = 0.1, c = -0.01
;;;       two roundings:  1.734723475976807e-18
;;;       one rounding:   9.020562075079397e-19
;;;
;;; which differ by nearly a factor of two. D24 was found by the RISC-V smoke
;;; gate, where RV64 gcc contracts to fmadd.d by default while baseline x86-64
;;; has no FMA to contract into, so cross-ISA bit-exactness holds only with
;;; contraction off. Off by default preserves oracle check 2, the eleven-way
;;; bit-exact cross-agreement, which is the strongest correctness evidence the
;;; project has. A tolerance-based oracle is precisely where an unsound abstract
;;; domain would hide.
;;;
;;; Contraction is a named, lexically scoped PERMISSION (`fp-contract` in
;;; lang.ss's check-names), not a global flag, and not a check being suppressed:
;;; it is a rewrite being permitted. This file never contracts. When the
;;; permission is granted, the obligation is on the back end to emit the fused
;;; instruction, and on the harness to report the delta rather than hide it.
;;; Reassociation stays forbidden outright and has no permission name.
;;;
;;; A consequence that belongs here rather than in the expander: because every
;;; flonum operation is strictly binary and rounds, the association order of a
;;; multi-operand sum is OBSERVABLE. There are no variadic flonum primitives in
;;; this file. Whoever expands surface `(+ a b c)` fixes the answer's bits, so
;;; that expansion must be pinned by the front end and must not be left to the
;;; back end to choose.
;;;
;;; Style follows sonic/src/sonic/interval.ss. Run the tests with:
;;;   cd sonic && scheme -q --libdirs src:vendor/nanopass --script test/numeric-test.ss

(library (sonic numeric)
  (export ;; representation
          fx-tag-bits fx-value-bits fx-word-bits
          ;; immediates
          imm-tag imm-tag-bits imm-sec-bits make-immediate sonic-immediate?
          sonic-false sonic-true sonic-null sonic-unspecified sonic-eof
          sonic-boolean-tag
          ;; heap objects
          heap-tag heap-pointer?
          heap-type-vector heap-type-flvector heap-type-pair
          heap-type-string heap-type-procedure
          heap-header-words heap-header-bytes
          heap-element-disp heap-length-disp heap-type-disp
          fx-least fx-greatest
          sonic-fixnum? sonic-flonum?
          fx-fits? fx-wrap
          fx-add-overflows? fx-sub-overflows? fx-mul-overflows?

          ;; flonum classification and bit-level identity
          fl-nan? fl-infinite? fl-finite? fl-negative-zero? fl-zero?
          fl-bits fl-identical?

          ;; conversion, both directions, with the lossy parts named
          fx->fl-exact? fl->fx-representable? fl->fx-truncate fl->fx-wrap

          ;; signalling
          make-sonic-condition sonic-condition?
          sonic-condition-kind sonic-condition-who sonic-condition-irritants
          signal-check sonic-condition-kinds

          ;; the proved-site audit
          proved-audit)

  ;; (chezscheme) rather than the (rnrs ...) set that interval.ss uses. Two
  ;; reasons, both about the model being faithful rather than portable:
  ;; `fixnum-width` is how we assert the host's tag layout matches the target's,
  ;; and the bytevector IEEE accessors are how we compare flonums by BITS rather
  ;; than by fl=, which cannot see the difference between 0.0 and -0.0 and
  ;; cannot see NaN at all. prims.ss needs Chez for a third reason on top:
  ;; flvectors and the #3% unsafe primitives.
  (import (chezscheme))

  ;; --- representation -------------------------------------------------------
  ;; Derived, not typed in. The three constants below are the entire tag scheme;
  ;; everything else in the file is a consequence of them.

  (define fx-word-bits  64)
  ;; --- immediates -----------------------------------------------------------
  ;;
  ;; Everything above assigns exactly one primary tag: 000, to fixnums. That
  ;; left the empty list, the booleans and the unspecified value with no bit
  ;; pattern at all, which is not a gap you can leave open once a merge can
  ;; force a raw word into the tagged class -- a comparison's 0/1 would land in
  ;; the value class, and under D21 the collector scavenges that unconditionally
  ;; and chases address 0 or 1.
  ;;
  ;; Primary tag 111 is the immediate tag, with a secondary tag above it:
  ;;
  ;;   63                        8   7     3   2 1 0
  ;;  +---------------------------+-----+---+---+---+
  ;;  |  payload                  | secondary | 1 1 1 |
  ;;  +---------------------------+-----+---+---+---+
  ;;
  ;; 111 rather than one of the low tags for two reasons. It is the one pattern
  ;; that cannot be mistaken for an 8-byte-aligned heap pointer under ANY
  ;; partial mask, so a bug that checks fewer bits than it should still fails
  ;; closed. And it keeps 001..110 contiguous for the heap types, which is what
  ;; makes a heap-type dispatch a jump table rather than a chain of compares.
  ;;
  ;; The booleans are adjacent and #f is the LOW one on purpose: a raw
  ;; comparison result is 0 or 1, so tagging it is `(x << 3) | 7` -- a shift and
  ;; an or, with no branch and no table. That is the conversion an eventual
  ;; representation-conversion pass will emit.
  ;;
  ;; The empty list has an encoding here even though `null?` never reads it:
  ;; regs.ss dedicates a register to nil on both targets, so the test is a
  ;; register compare. The register still has to be INITIALIZED to something,
  ;; and that something is this.
  (define imm-tag        #b111)
  (define imm-tag-bits   3)
  (define imm-sec-bits   5)          ; secondary tag occupies bits 3..7

  (define (make-immediate sec) (bitwise-ior (bitwise-arithmetic-shift-left sec 3) imm-tag))

  (define sonic-false        (make-immediate 0))   ;  7
  (define sonic-true         (make-immediate 1))   ; 15
  (define sonic-null         (make-immediate 2))   ; 23
  (define sonic-unspecified  (make-immediate 3))   ; 31
  (define sonic-eof          (make-immediate 4))   ; 39
  ;; Secondary tags 5..31 are unassigned. A character will take one, with the
  ;; code point as the payload above bit 8.

  (define (sonic-immediate? w)
    (= (bitwise-and w #b111) imm-tag))

  (define (sonic-boolean-tag b) (if b sonic-true sonic-false))

  ;; --- heap objects ---------------------------------------------------------
  ;;
  ;; One pointer tag for every heap type, with the type in the object's HEADER
  ;; rather than in the tag.
  ;;
  ;; The alternative -- a tag per heap type, which the three spare tags would
  ;; almost afford -- looks cheaper and is not, because of what a LOAD then
  ;; costs. `flvector-ref` and `vector-ref` lower to the same Lmach `load`, and
  ;; a load's displacement has to absorb the tag: element i sits at
  ;; [ptr + 8i - tag]. With one tag that displacement is a constant the selector
  ;; already emits for free. With a tag per type, Lmach's `load` would have to
  ;; carry the base's heap type so the selector could pick the right constant --
  ;; an IR change, on the instruction in the hot loop, to answer a question only
  ;; `vector?` and `flvector?` ever ask.
  ;;
  ;; So: tag 001 is a heap pointer, and the type is a word in the header. The
  ;; predicates pay one load; the loop pays nothing.
  ;;
  ;;   [raw +  0]  type word
  ;;   [raw +  8]  length, a RAW count (what `vlen` yields, used directly as a
  ;;               bounds limit -- so it is not a fixnum)
  ;;   [raw + 16]  element 0
  ;;
  ;;   pointer = raw + 16 + heap-tag
  ;;
  ;; The pointer aims at ELEMENT ZERO, not at the header, so indexing needs no
  ;; addition beyond the tag adjustment the displacement already carries.
  (define heap-tag 1)

  (define heap-type-vector    0)
  (define heap-type-flvector  1)
  (define heap-type-pair      2)
  (define heap-type-string    3)
  (define heap-type-procedure 4)

  (define heap-header-words 2)
  (define heap-header-bytes (* 8 heap-header-words))

  ;; Displacements, stated once so the two selectors cannot drift apart.
  (define heap-element-disp (- heap-tag))                 ; [ptr + 8i - 1]
  (define heap-length-disp  (- (- 8) heap-tag))           ; [ptr - 9]
  (define heap-type-disp    (- (- 16) heap-tag))          ; [ptr - 17]

  (define (heap-pointer? w) (= (bitwise-and w #b111) heap-tag))

  (define fx-tag-bits    3)
  (define fx-value-bits (- fx-word-bits fx-tag-bits))       ; 61, sign included

  (define fx-modulus  (expt 2 fx-value-bits))               ; 2^61
  (define fx-halfmod  (expt 2 (- fx-value-bits 1)))         ; 2^60

  (define fx-greatest (- fx-halfmod 1))                     ;  1152921504606846975
  (define fx-least    (- fx-halfmod))                       ; -1152921504606846976

  (define (fx-fits? n) (and (<= fx-least n) (<= n fx-greatest)))

  ;; Written with exact integer arithmetic on purpose. This is the SPEC of what
  ;; the untagged add does, stated independently of any host primitive, so that
  ;; numeric-test.ss can check it against the host's actual unsafe machine op
  ;; and have that agreement be evidence rather than a tautology.
  (define (fx-wrap n) (- (modulo (+ n fx-halfmod) fx-modulus) fx-halfmod))

  ;; A sonic fixnum is an exact integer inside the range. Deliberately NOT
  ;; `(fixnum? x)`: that would delegate the model's range to the host's, and the
  ;; whole point of naming the range here is that it is ours.
  (define (sonic-fixnum? x)
    (and (integer? x) (exact? x) (fx-fits? x)))

  (define (sonic-flonum? x) (flonum? x))

  ;; Overflow predicates take the OPERANDS, not the result, because that is the
  ;; shape the back end needs: on the target these become `jo` after the
  ;; instruction, and stating them over operands keeps the model honest about
  ;; never having computed the wide result in the first place.
  (define (fx-add-overflows? a b) (not (fx-fits? (+ a b))))
  (define (fx-sub-overflows? a b) (not (fx-fits? (- a b))))
  (define (fx-mul-overflows? a b) (not (fx-fits? (* a b))))

  ;; --- flonum classification ------------------------------------------------
  ;;
  ;; NaN is not equal to itself, so `(fl= x x)` is the classification test, and
  ;; it is the only one that works: `(eqv? x +nan.0)` is a host-dependent
  ;; question about boxes, not about IEEE.

  (define (fl-nan? x) (not (fl= x x)))
  (define (fl-infinite? x) (or (fl= x +inf.0) (fl= x -inf.0)))
  (define (fl-finite? x) (and (not (fl-nan? x)) (not (fl-infinite? x))))
  (define (fl-zero? x) (fl= x 0.0))                 ; true for BOTH signed zeros

  ;; -0.0 is where a comparison-based classifier goes wrong: fl= says the two
  ;; zeros are equal, IEEE says so, and they are still different values with
  ;; different reciprocals. Dividing is the classical test and needs no bit
  ;; access; fl-bits below is the general answer.
  (define (fl-negative-zero? x)
    (and (flonum? x) (fl= x 0.0) (fl= (fl/ 1.0 x) -inf.0)))

  ;; The 64 bits of the binary64 encoding, as an exact non-negative integer.
  ;; This is the ONLY equality that means what the D24 oracle needs it to mean:
  ;; it separates 0.0 from -0.0 and it makes NaN comparable to NaN.
  (define fl-bits-buffer (make-bytevector 8))
  (define (fl-bits x)
    (bytevector-ieee-double-native-set! fl-bits-buffer 0 x)
    (bytevector-u64-native-ref fl-bits-buffer 0))

  (define (fl-identical? a b)
    (and (flonum? a) (flonum? b) (= (fl-bits a) (fl-bits b))))

  ;; --- conversion between the two towers ------------------------------------
  ;;
  ;; Both directions are lossy and the losses are in opposite places. Neither is
  ;; implicit: there is no coercion anywhere in this tower, only fx->fl and
  ;; fl->fx, and that is the point of having exactly two types.

  ;; fx->fl ROUNDS. binary64 has a 53-bit significand and our fixnums are 61
  ;; bits, so every fixnum with magnitude above 2^53 that is not a multiple of
  ;; the appropriate power of two comes back changed. fx-greatest is the sharp
  ;; case: 2^60 - 1 rounds up to exactly 2^60, which is not a fixnum at all.
  (define (fx->fl-exact? n) (<= (abs n) (expt 2 53)))

  ;; fl->fx TRUNCATES TOWARD ZERO. That is cvttsd2si, which is the instruction
  ;; the back end will emit, and it is not `round` and not `floor`. There is no
  ;; rounding-mode-respecting conversion primitive in the frozen table.
  (define (fl->fx-truncate x) (exact (fltruncate x)))

  (define (fl->fx-representable? x)
    (and (fl-finite? x) (fx-fits? (fl->fx-truncate x))))

  ;; What the unchecked conversion actually produces on x86-64. cvttsd2si writes
  ;; the "integer indefinite" value, -2^63, whenever the source is NaN, infinite,
  ;; or truncates outside signed 64-bit range; otherwise it writes the truncated
  ;; value. The tagging shift `shl 3` then discards the top three bits, which is
  ;; a wrap modulo 2^61. Note the arithmetic: -2^63 is -4 * 2^61, so it wraps to
  ;; exactly 0, and NaN and both infinities all convert to fixnum 0 with no
  ;; diagnostic whatsoever. That silence is the argument for `checked` being the
  ;; default at this site.
  (define fl->fx-indefinite (- (expt 2 63)))
  (define (fl->fx-wrap x)
    (if (fl-nan? x)
        (fx-wrap fl->fx-indefinite)
        (let ((t (and (fl-finite? x) (fl->fx-truncate x))))
          (if (and t (< (abs t) (expt 2 63)))
              (fx-wrap t)
              (fx-wrap fl->fx-indefinite)))))

  ;; --- signalling -----------------------------------------------------------
  ;;
  ;; A failed check raises a record, not a string. The `kind` field carries WHICH
  ;; named check fired, drawn from the same vocabulary as lang.ss's check-names,
  ;; because D5's whole argument is that checks are named and separately
  ;; suppressible, and a diagnostic that says only "error" cannot be counted by
  ;; name afterwards.
  ;;
  ;; Note what is NOT imported here: (sonic lang). The runtime must not depend on
  ;; the compiler's IR library, or the dependency graph inverts and the runtime
  ;; drags nanopass in. So the kind vocabulary is repeated as bare symbols and
  ;; numeric-test.ss asserts that the two lists agree. The check belongs in a
  ;; test rather than in an import.

  (define-record-type (sonic-condition make-sonic-condition sonic-condition?)
    (fields kind who irritants))

  (define (sonic-condition-kinds)
    '(bounds-check type-check overflow-check div-check analysis-unsound))

  (define (signal-check kind who . irritants)
    (raise (make-sonic-condition kind who irritants)))

  ;; --- the proved-site audit ------------------------------------------------
  ;;
  ;; OFF by default, and it must stay off by default, because a proved site with
  ;; a check in it is just a checked site and the entire measurement is about
  ;; the check being gone.
  ;;
  ;; On, every `proved` primcall re-runs the obligation the analysis claimed to
  ;; have discharged and signals `analysis-unsound` if it does not hold. This is
  ;; a debugging instrument for the abstract interpreter, not a safety net for
  ;; user code: an `unchecked` site is NEVER audited, because it never claimed
  ;; anything. That asymmetry is the operational content of keeping `proved` and
  ;; `unchecked` as separate controls when they emit identical instructions.
  (define proved-audit (make-parameter #f))

  ;; --- fail fast if the host is not the machine we are modelling ------------
  ;;
  ;; The hosted model is one arm of a bit-exactness oracle. If the host's fixnum
  ;; layout differs from the target's, prims.ss's unsafe fast paths stop being a
  ;; faithful witness for fx-wrap and the oracle silently starts comparing two
  ;; different machines. Die at load time rather than produce that.
  (unless (= (fixnum-width) fx-value-bits)
    (error 'sonic-numeric
           "host fixnum width does not match the modelled tag scheme"
           (fixnum-width) fx-value-bits))
  (unless (and (= (most-positive-fixnum) fx-greatest)
               (= (most-negative-fixnum) fx-least))
    (error 'sonic-numeric
           "host fixnum range does not match the modelled range"
           (most-positive-fixnum) fx-greatest))
  )
