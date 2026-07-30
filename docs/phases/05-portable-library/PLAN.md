# Phase 5: The Portable Library

## Goal

Build the compatibility layer designed in `../../PROPOSAL.md` section 2, and show it
reaches configuration 4's performance from configuration 2's portable source.

## The claim being tested

That a portable macro layer can give you implementation-specific tuned performance
without implementation-specific source. If true, the proposal has a working reference
implementation and the SRFI can lead with a measurement instead of an argument. If
false, we learn where the ceiling actually is.

## Inputs

Phase 3 complete, with a positive result on the 2-to-4 delta. If that delta is small,
this phase should not happen at all.

Phase 4's Ada verdict, since it determines whether the check-suppression design in
section 2b stands as written.

## Work items

### Tier one, the honest layer

1. Named check suppression: `(suppress ...)` and `(unsuppress ...)`, lexically scoped,
   over the six check names in `../../PROPOSAL.md` section 2b. Expands to each
   implementation's native mechanism where one exists (Chez `optimize-level`, Racket
   unsafe operations) and to nothing where none does.
2. Declaration binding: attach a predicate to a variable for a scope, using predicates
   as the type language per section 2c. Expands to `assume` where honored, to
   type-specific operators where derivable, and to plain portable code otherwise.
3. Back ends for Chez and Racket. Detect the host at expansion time.
4. Correct degradation: an implementation that participates in none of this must still
   run the program correctly, only slower. Verify this by running under an
   implementation with no back end at all.

### Tier two, the expansion-time propagator

5. A `syntax-case` pass that walks a procedure body, propagates declared types through
   `let` bindings and arithmetic, and selects the monomorphic operator per site
   automatically rather than making the programmer write `fl+` everywhere.

This is the novel part. It is a small type propagator running at expansion time, and
it recovers the composability of premises without needing the host compiler to
cooperate. It cannot elide checks, because that requires the compiler. The boundary of
what expansion-time inference can recover is, as far as I know, not well explored.

## Acceptance criteria

- Tier one: nbody written once in portable source with declarations reaches
  configuration 4's measured performance on both Chez and Racket, within phase 2's
  noise floor.
- Correct degradation demonstrated on an implementation with no back end.
- Tier two, if attempted: the portable source no longer needs hand-written
  type-specific operators, and performance does not regress against tier one.

## Risks

**The layer cannot close the gap.** Most likely cause is check elision, since no
standard mechanism exists to request it and `assume` is honored by few if any
implementations. If so, the honest result is that tier one reaches part of the way and
the remainder is exactly what the missing policy switch would buy. That is still a
publishable number and it strengthens the SRFI argument rather than weakening it.

**The propagator eats a week.** Tier one is a weekend. Tier two is open-ended. Timebox
it and stop at tier one if the schedule matters, since tier one is sufficient to
validate the proposal.

**Scope creep in the predicate language.** `(f64vector-of flonum?)` invites a full
contract language. Racket has one and it is large. Draw the line at the parameterized
predicates the numeric cases need and defend it.

## Outputs

- The portable library, checked in with tests.
- Measured comparison against configuration 4.
- A statement of the ceiling the layer actually reaches, and what remains out of reach
  without a standardized policy switch.
