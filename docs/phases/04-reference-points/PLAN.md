# Phase 4: Reference Points

## Goal

Measure configurations 7, 8 and 9. Each one can falsify a different part of the
argument, which is why they are in the matrix rather than being decoration.

## Inputs

Phase 3 complete. These are reference points for a result that already exists, so
running them first would waste effort if phase 3 kills the project.

## Order, and why

Deliberately not the numeric order of the configurations.

### First: configuration 8, Ada with GNAT

`../../PROPOSAL.md` section 2b commits to Ada's named per-check suppression over
Common Lisp's single `safety` dial. That decision currently rests on the Ada
Reference Manual being well designed, which is not evidence.

Build nbody in Ada, then measure it three ways: all checks on, `pragma Suppress` on
the specific checks a numeric kernel can safely drop (`Index_Check`, `Range_Check`,
`Overflow_Check`), and `Suppress(All_Checks)`.

If Ada with checks suppressed approaches scalar C, the mechanism is validated at the
language level and we are copying something that demonstrably works. If it stays well
off scalar C, then per-check suppression buys less than the manual implies and section
2b needs rewriting. Cheap, and it is the only configuration that directly tests a
design decision we have already made.

The three-way split matters more than the single number. The gap between named
suppression and `All_Checks` tells us whether granularity costs performance, which is
the one real argument for CL's cruder dial.

### Second: configuration 9, ECL and CLISP

Run configuration 5's source unchanged under ECL and CLISP.

This tests the framing of the original question. If tuned Common Lisp is fast under
SBCL and slow under CLISP, which largely ignores declarations, then "Common Lisp is
fast" is really "SBCL is fast," and what the standard supplied was the portable
notation rather than the performance. That sharpens `../../PLAN.md` section 1 instead
of undermining it. Cheapest item in the matrix.

### Last, and optional: configuration 7, Stalin

Stalin is the Scheme ceiling reached by inference rather than declaration. If it beats
every declaration-based configuration by a wide margin, the interesting problem is
inference and this project is aimed at the wrong target.

It is last because it is the highest-effort item here. Stalin 0.11 targets R4RS,
predates R7RS by seven years, and failed 23 of 57 benchmarks in the existing corpus on
language coverage grounds. Porting nbody to it is real work.

It is optional because `RESEARCH.md` section 3 already extracted most of what Stalin
has to say from the `r7rs-benchmarks` data: bimodal, 2x to 4x faster than Chez on
float and array code, 5x to 16x slower where lifetime analysis fails and everything
falls through to the Boehm collector. Drop this configuration if it fights.

## Work items

1. nbody in Ada, three check configurations, built with `gnatmake`.
2. Configuration 5's Common Lisp source run under ECL and CLISP unchanged.
3. Optional: nbody ported to Stalin's R4RS dialect, compiled through C.
4. Output verification against the fixture for each, same as phase 3.

## Acceptance criteria

- Ada measured at all three check levels, with a stated verdict on whether section 2b
  of `../../PROPOSAL.md` survives.
- ECL and CLISP numbers, with a stated verdict on the "CL or SBCL" question.
- Stalin either measured or explicitly dropped with the reason recorded.

## Risks

**Ada refutes the design decision.** A real possibility and the reason to run it. If
per-check suppression underperforms, `../../PROPOSAL.md` section 2b gets rewritten
toward something closer to the CL dial, or toward a different mechanism entirely.

**GNAT's default optimization settings confound the check-suppression result.** Hold
`-O` level constant across the three Ada variants so the only variable is check
suppression.

**Stalin cannot compile nbody at all.** Acceptable. Drop it and cite the existing
corpus data instead.

## Outputs

- Ada results at three check levels.
- ECL and CLISP results.
- Stalin result or a recorded reason for dropping it.
- A verdict on `../../PROPOSAL.md` section 2b.
