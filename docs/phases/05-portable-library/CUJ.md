# Phase 5 CUJ: The Portable Library

Technical implementation document. The journey is an operator building the thing the
proposal describes, then proving it reaches implementation-specific performance from
portable source.

Companion to `PLAN.md` in this directory.

## Journey summary

The operator builds a macro layer providing named check suppression and type
declarations over whatever phase 1 found available. Back ends detect the host at
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

Suppression maps to `optimize-level`. The awkward part is that `optimize-level` is a
compile-time parameter rather than a lexical form, so a lexically scoped `suppress`
cannot lower to it directly. Two options, and choosing between them is real design work
in this phase:

1. Lower `suppress` to the unsafe primitive variants at each site inside the scope. More
   faithful to lexical scoping, more work, and it needs a mapping from each check name
   to the primitives it affects.
2. Document that Chez suppression is file-granular and lower to a compile-time setting.
   Honest and much simpler, but it gives up the scoping property that motivated the Ada
   design.

Option 1 is what the proposal actually promises. Start with option 2 to get an
end-to-end measurement, then implement option 1 and confirm it does not regress.

Declarations lower to native `fl` operators plus `flvector` access.

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
