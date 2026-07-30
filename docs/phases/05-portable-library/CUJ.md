# Phase 5 CUJ: The Portable Library

Technical implementation document. The journey is an operator building the thing the
proposal describes, then proving it reaches implementation-specific performance from
portable source.

Companion to `PLAN.md` in this directory.

**This library is an instrument, not the destination.** The plan is to write our own
Scheme. Building over Chez and Racket first is worth doing because every wall the macro
layer hits becomes a documented requirement for that compiler, established cheaply and
with a measurement attached. The section "What this phase tells the compiler" is the real
output of this phase; the performance number is secondary.

## Journey summary

The operator builds a macro layer providing named check suppression and type
declarations over what phase 1 found actually shipped, which is R6RS operators and native
`flvector` rather than anything Tangerine. Back ends detect the host at
expansion time and lower to native mechanisms. Then nbody gets written once, in portable
source with declarations, and measured against configuration 4. Tier two attempts an
expansion-time type propagator so the programmer stops writing `fl*` by hand.

## Preconditions

Phase 3 complete with a positive 2-to-4 delta. If that delta was inside the noise floor,
this phase should not happen.

Phase 4's Ada verdict, because it determines whether named per-check suppression stands
as designed or needs replacing.

## Library layout

```
lib/
  declare/
    core.sld            the interface, portable R7RS library form
    core.scm            shared implementation
    backend-chez.scm    Chez lowering
    backend-racket.scm  Racket lowering
    backend-none.scm    correct-but-slow fallback
    detect.scm          host detection at expansion time
  tests/
    degradation.scm     runs under an implementation with no back end
    suppression.scm     each named check
    declaration.scm     each predicate
    propagate.scm       tier two only
```

## The interface

Two forms, matching `../../PROPOSAL.md` sections 2b and 2c.

```scheme
(declare (v (f64vector-of flonum?))
         (n fixnum?)
         (suppress index-check overflow-check))
```

Check names, six of them, deliberately fewer than Ada's fourteen:
`index-check`, `type-check`, `overflow-check`, `division-check`, `arity-check`,
`all-checks`.

Predicates are the type language, not a new type syntax. `flonum?`, `fixnum?`,
`f64vector?` already exist, and SRFI 145 and SRFI 253 both already work this way. One
parameterized constructor, `(f64vector-of <predicate>)`, covers the numeric cases.
Resist adding more: `../../PROPOSAL.md` section 3 flags predicate combinator scope creep
as a real risk, and Racket's contract system is the cautionary example.

`unsuppress` mirrors `suppress` and re-enables inside a narrower scope, which is the Ada
property the design is copying.

## Host detection

`cond-expand` is standard R7RS and is the right mechanism. Feature identifiers are
implementation-specific, so phase 1's support matrix supplies the actual values.

```scheme
(cond-expand
  (chez   (include "backend-chez.scm"))
  (racket (include "backend-racket.scm"))
  (else   (include "backend-none.scm")))
```

The `else` branch is load-bearing rather than a formality. It is what makes the library
safe to publish: an implementation with no back end must run the program correctly, only
slower.

## Lowering, per back end

### Chez

Declarations lower to native `fl` operators plus `flvector` access. Straightforward.

Suppression does not lower cleanly, and that is a finding rather than a problem to solve.
Chez's `optimize-level` is a compile-time parameter, not a lexical form, so lexically
scoped `suppress` has no faithful target. The workaround is to lower each check name to
the unsafe primitive variants at every site inside the scope, which is mechanical but
partial: it covers the primitives we enumerate and silently misses anything else.

**Do not contort the design to fit this.** Chez cannot express scoped check suppression
because Chez was not built to. Record it as a requirement for our own implementation
(section "What this phase tells the compiler" below) and ship the mechanical
site-rewriting version here, which is good enough to produce the measurement this phase
exists for.

### Racket

Cleaner, because `racket/unsafe/ops` provides per-operation unchecked variants, which
maps directly onto lexically scoped suppression.

```
index-check    suppressed  ->  unsafe-flvector-ref, unsafe-vector-ref
type-check     suppressed  ->  unsafe-fl+ and friends
```

Declarations lower to `racket/flonum` operators and `flvector`.

### None

Every form expands to its checked, generic equivalent. `suppress` expands to nothing.
`declare` expands to nothing, or optionally to a `SRFI 253` style boundary check when a
debug flag is set, which would make the declarations do double duty as documentation
that gets verified.

## The measurement that validates the phase

Write nbody once, portably, with declarations:

```scheme
(import (scheme base) (declare core))

(define (advance xs ys zs vxs vys vzs ms dt n)
  (declare (xs (f64vector-of flonum?))
           (ys (f64vector-of flonum?))
           (dt flonum?)
           (n fixnum?)
           (suppress index-check type-check))
  ;; ordinary + - * / and vector-ref, no fl-prefixed operators by hand
  ...)
```

Then compare against phase 3's configuration 4 results, on both Chez and Racket. The
claim is that this single portable source reaches configuration 4's implementation-specific
performance within phase 2's noise floor.

Three outcomes, all informative:

- Reaches configuration 4. The proposal has a working reference implementation and the
  SRFI can lead with a measurement.
- Reaches part way. The remainder is exactly what a standardized policy switch would
  buy, which is a publishable number and strengthens the SRFI argument.
- Reaches nowhere near. Something about the design is wrong. Find out what before
  writing any specification.

## Tier two: the expansion-time propagator

The novel part, and the part most likely to consume a week. Timebox it.

The goal is that the source above stops needing `suppress` and per-site operator choices
at all, because the macro derives them. Given declared parameter types, walk the
procedure body and propagate.

```scheme
;; sketch: a syntax-case pass over a body with a type environment
(define (propagate stx env)
  (syntax-case stx (let if + - * / vector-ref)
    ;; (+ a b) where env says both are flonum? -> fl+
    ((+ a b)
     (and (flonum-typed? #'a env) (flonum-typed? #'b env))
     #'(fl+ a b))
    ;; (let ((x rhs)) body) -> extend env with the derived type of rhs
    ((let ((x rhs)) body ...)
     (let ((t (derive-type #'rhs env)))
       (with-syntax ((body* (propagate #'(begin body ...)
                                       (env-extend env #'x t))))
         #'(let ((x rhs)) body*))))
    ...))
```

What it can and cannot do, stated up front so the result is not a surprise. It can
select monomorphic operators, propagate through `let` and `letrec` bindings and
arithmetic, and handle loop induction variables where the recursion is syntactically
visible. It cannot elide checks, because that requires the host compiler's cooperation
and no standard obliges it. It cannot see across procedure boundaries without a
declaration at the callee, which is the correct limitation: it is what keeps the analysis
local and predictable, unlike Stalin's whole-program approach.

Acceptance for tier two: the portable source no longer contains hand-written
type-specific operators, and performance does not regress against tier one.

## Test strategy

Integration tests over unit tests, since the library's whole purpose is an end-to-end
property.

1. Degradation: run the full nbody under an implementation with no back end. It must
   produce correct output. This is the most important test in the suite, because it is
   the property that makes the design safe to standardize.
2. Suppression: one test per check name, confirming the checked version raises and the
   suppressed version does not check. Note that a suppressed check on bad input is
   undefined behavior, so these tests must not assert on what happens, only that the
   check is gone. Read emitted code rather than provoking a crash.
3. Declaration: one test per predicate, confirming the expansion selects the expected
   operator. Compare expanded output, not timing.
4. Propagation, tier two only: property-style tests that a declared type flows to every
   arithmetic site in a body.

## What this phase tells the compiler

The library is a measurement instrument, not the deliverable. Its job is to establish
what a macro layer over existing implementations can and cannot reach, so that our own
Scheme knows what it has to do differently. Every place the library hits a wall is a
requirement, and those requirements are the real output of this phase.

Running list, to be extended as the work turns up more:

**Scoped check suppression must be a first-class lexical form.** Chez's `optimize-level`
is a compile-time parameter, so scoped suppression cannot be expressed faithfully over
it. Our compiler needs suppression in the core language, entering and leaving scope like
any other binding form, with the policy carried in the compilation environment rather
than in a global parameter. This is the Ada model and neither Chez nor Racket can host
it.

**The type lattice must carry integer ranges, not just categories.** This is now the top
requirement and it is specific. `../../CHEZ-ANALYSIS.md` records the source reading: Chez
already narrows types from predicate tests and already promotes safe primitives to unsafe
ones automatically when the argument types check out, so a macro is sufficient for the
arithmetic half and no compiler is needed there. What Chez cannot do is elide a bounds
check, because that needs the relational fact `i < (flvector-length v)` and its lattice
holds flat categories rather than intervals. ANSI CL standardized integer range types, so
SBCL had to build ranges into its lattice and can therefore elide bounds checks from
declarations. Our compiler needs ranges for the same reason.

**Suppression must interact soundly with continuations.** Flagged as the hardest open
problem in `../../PROPOSAL.md` section 3, and no macro layer can address it because the
capture happens at runtime. Our compiler has to decide what a re-entered continuation
means for an in-scope suppression, and Ada and Common Lisp offer no precedent because
neither has first-class continuations.

**Separate compilation must survive.** Stalin's closed-world assumption is what makes its
inference powerful and what makes it unusable. Declaration-anchored local inference does
not need a closed world, which is the property worth preserving deliberately rather than
by accident.

## Artifacts produced

```
lib/declare/                                  the library
bench/programs/nbody/09-portable-declared.scm  one portable source
results/<config>-<N>.json
docs/phases/05-portable-library/RESULTS.md      measured ceiling, what stays out of reach
```

## Exit gates

- Tier one: portable declared nbody reaches configuration 4 on both Chez and Racket
  within phase 2's noise floor, or the shortfall is quantified.
- Degradation demonstrated on an implementation with no back end.
- Tier two, if attempted: no hand-written type-specific operators remain and no
  performance regression against tier one.
- A written statement of the ceiling reached and what remains unreachable without a
  standardized policy switch.

## Task decomposition notes

The interface and `core.scm` gate everything. `backend-none.scm` should come second, not
last, because it is the correctness baseline and the degradation test depends on it. The
two real back ends are independent of each other and parallelizable. Racket is the easier
one and makes a better first target, since `racket/unsafe/ops` maps onto the design
directly while Chez needs the `optimize-level` scoping decision resolved. Tier two is a
separate track entirely and should not block tier one's measurement.
