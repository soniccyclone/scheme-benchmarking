# Optimization Escape Hatches: Common Lisp vs Scheme

Overview and phase index.

Every document under `docs/` is an **active plan**: it describes what we are doing and
what is currently true. The reasoning that produced it, including every position we
later reversed, lives in `LEDGER.md`. Do not add decision history here; add it there
and leave the plan describing the plan.

## Document map

| document | contents |
|---|---|
| `PLAN.md` (this file) | thesis, the experiment matrix, phase index, open questions |
| `LEDGER.md` | the decision record: what was ratified, what was reversed, what we got wrong |
| `RESEARCH.md` | standards survey, cross-language comparison, Stalin analysis, measurement evidence |
| `PROPOSAL.md` | prior art, the design we would propose, .NET architecture notes, compiler layering |
| `METHOD.md` | machine, measurement method, dependency table |
| `CHEZ-ANALYSIS.md` | what Chez's optimizer already does, read from source, and the one capability it lacks |
| `phases/NN-name/PLAN.md` | per phase: goal, inputs, work items, acceptance criteria, risks |
| `phases/NN-name/CUJ.md` | per phase: the technical implementation journey. Commands, code shapes, schemas, decision branches |
| `knowledge/` | the OKF bundle produced by phase 0. Traversable in later planning sessions |

`PLAN.md` in a phase directory says what and why. `CUJ.md` says how, concretely enough
to break into tasks. Each `CUJ.md` ends with task decomposition notes naming what is
parallelizable, what is on the critical path, and what forms a single indivisible unit.

Results land in `phases/NN-name/RESULTS.md` as each phase completes.

---

## 1. The thesis being tested

Common Lisp reaches C speed because ANSI CL put the escape hatches *in the
standard*: `declare`, `declaim`, `the`, and the `optimize` qualities `speed`,
`safety`, `space`, `debug`. That is what lets SBCL trust a type assertion, elide a
bounds check, and select an unboxed register representation while remaining a
conformant implementation, and it is what lets the *user's tuned code* remain
conformant too. Verna's "How to Make Lisp Go Faster than C" (IMECS 2006, IJCS
32(4)) is the demonstration: add type declarations and set the optimization
policy, and SBCL matches or beats GCC on array-heavy numeric code.

The mechanism worth being precise about is that standardizing the notation does
two things at once. It obliges implementors to have an optimization story, and it
means code that uses that story does not fall off the standard. That is exactly
the trick, because the alternative is what Scheme actually got: every
implementation invents its own syntax, and tuned code stops being portable the
moment it is tuned.

So the question is whether Scheme ever did the same thing, and the answer turns
out to be more interesting than a flat no.

---

## 2. The experiment

One program, ten configurations, each isolating one standards-level feature or
providing one reference point. This validates `RESEARCH.md` section 1's prediction rather than
being a benchmarking project in its own right.

**Program: nbody.** Serial in every published entry so no thread confound, pure
double-float over a small fixed working set so it isolates boxing and storage
cleanly, and the program both Pecsek and Smith used so there are external numbers
to sanity-check against.

| # | configuration | role |
|---|---|---|
| 1 | portable R7RS-small, generic arithmetic, `vector` | the floor: no hatches exist |
| 2a | **R6RS: `(rnrs arithmetic flonums)` + `(rnrs arithmetic fixnums)`** | **the only standardized hatch with a real implementation, available since 2007** |
| 2b | **Tangerine over a shim we ship: SRFI 144 + SRFI 160** | **what Tangerine would give you if anyone implemented it** |
| 2c | **predicate-guarded entry at `optimize-level 2`, otherwise portable** | **the arithmetic win Chez already gives you for free. See `CHEZ-ANALYSIS.md`** |
| 3 | **premise, in whatever form the implementation actually accepts** | what a premise buys, if anything. **SRFI 145 ships nowhere. See below** |
| 4 | implementation-specific max: Chez `optimize-level 3`, Racket unsafe ops | the folklore ceiling |
| 5 | SBCL, `declare` + `(safety 0)`, scalar, no `sb-simd` | tuned conformant CL |
| 6 | `gcc -O2 -fno-tree-vectorize`, and `-O3 -march=native` | scalar and vectorized C reference |
| 7 | Stalin, whole-program inference | the Scheme ceiling, reached by inference instead of declaration |
| 8 | GNAT Ada, `pragma Suppress`, per-check | the design we are copying, measured |
| 9 | ECL and CLISP, same source as 5 | is it Common Lisp or is it SBCL? |

### Why configuration 2 split

Phase 1 answered the gate question by reading the Chez and Racket source, and the answer
killed configuration 2 as originally written. See
`phases/01-toolchain-gate/RESULTS.md` for the evidence.

Chez has **no R7RS support of any kind**. Zero `(scheme ...)` libraries; the only
occurrences of "r7rs" in the entire codebase are two incidental comments. It ships full
R6RS instead, including `(rnrs arithmetic fixnums)` and `(rnrs arithmetic flonums)`, plus
a native `flvector` that its type recovery pass already understands. Racket's SRFI
package stops at SRFI 98, so no 143, 144, 145, 160 or 253.

So there is no implementation on which `(import (scheme flonum) (scheme vector f64))`
resolves. Tangerine is a dead letter seven years after it was assembled.

That reshapes the finding into something stronger than a measured delta. The
instruction-level escape hatches were standardized by R6RS in 2007, removed by R7RS-small
in 2013, nominally restored by R7RS-large Tangerine in 2019, and remain unimplemented by
either leading implementation in 2026. Configuration 2a measures the path that actually
exists. Configuration 2b measures the path the standard promises, with the shim cost
reported alongside it.

### Why configuration 3 needs the same treatment

Phase 1's runtime pass found that **SRFI 145 is not obtainable on either implementation**.
`(import (srfi :145))` fails in Chez and `(require srfi/145)` fails in Racket. So the
premise configuration is not writeable as specified either, for the same reason
configuration 2 was not.

This is the R7RS-large finding one level up, and it is worth more than the delta
configuration 3 was going to produce: **there is no implementation on which a premise can
be portably expressed at all.** Rebuild configuration 3 around what each implementation
actually accepts. On Chez that is a predicate guard `cptypes` narrows on, which is already
configuration 2c. On Racket it is nothing, because `racket/unsafe/ops` has an
unchecked-operator notion and no premise notion.

Run configurations 1 through 4 on both Chez and Racket, since section 5's data says
they are within 15% on numeric code and any large divergence here would itself be a
finding.

The deltas answer specific questions. 1 to 2a is what R6RS bought Scheme in 2007. 2a to
2b is whether Tangerine over a shim beats the R6RS path or just adds shim cost. 2b to 3
is what a premise buys where one can be expressed at all. **2a to 2c is what Chez's
existing type-driven unsafe promotion gives you for free. 2c to 4 isolates bounds-check
elision, which is the capability Chez's lattice cannot express.** 2a to 4 is the total cost
of the missing policy switch. 4 to 5 is
whether CL's inference beats Scheme's hand-written instructions with both sides maximally
tuned. 5 to 6 re-runs Verna's claim on 2026 hardware.

### Why 7, 8 and 9 are in the matrix

These three are not filler. Each one can falsify a different part of the argument,
which is the point of including them.

**Stalin (7) is the Scheme ceiling and the control on our whole approach.** It
reaches C-competitive numeric code by inference instead of declaration. If Stalin
already beats every declaration-based configuration by a wide margin, then the
interesting problem is inference and not standardization, and this project is aimed
at the wrong target. `RESEARCH.md` section 3 covers the machinery, the measured profile,
and the caveats about its vintage.

**Ada (8) measures the design we decided to copy.** `PROPOSAL.md` follows Ada's
named per-check suppression rather than CL's single dial. That decision should not
rest on the elegance of the Ada manual. If GNAT with `pragma Suppress` lands at or
near scalar C on this program, the mechanism is validated at the language level and
we are copying something that demonstrably works. If Ada with all checks suppressed
is still well off scalar C, then per-check suppression buys less than the manual
implies, and the design needs revisiting. `gnat-15` 15.2.0 is packaged, so this is
cheap.

**ECL and CLISP (9) test the framing of the original question.** Running the same
tuned CL source under three implementations separates "Common Lisp is fast" from
"SBCL is fast." CLISP largely ignores declarations, so it should be slow, and that
result is the demonstration that the standard obliges implementors to accept the
notation without obliging them to act on it. This sharpens section 1's thesis
instead of undermining it.

**SIMD stays out of the measurement matrix**, deliberately. The fast Benchmarks Game
and PLB Common Lisp entries use `sb-simd` (verified: `grep -rl sb-simd` hits nbody 3
through 6 and spectral-norm 2 through 7 in the PLB tree, with Bela Pecsek's
attribution and "Based on 2.zig" headers). That is why configuration 5 excludes it:
mixing it in would confound the standards question with an intrinsics question. This
is a scoping decision about phases 3 and 4 only. Phase 7 stage 10 *is* vectorization,
and configuration 6's `-O3 -march=native` arm is there as its eventual target.

---

## 3. Where the design lives

The question of whether we could build a portable Scheme superset with these
declarations, and what it would look like, moved to `PROPOSAL.md`. Sections 1 and 2
there cover the prior art and the design. Section 4 covers the optimization
architecture and the case for declaration-anchored local inference.

The short version, retained here because it constrains the experiment: at least five
Schemes already invented incompatible versions of this feature (Bigloo type
annotations, Gambit `declare`, Chicken `declare` plus its scrutinizer, Typed Racket,
and Stalin's annotation-free whole-program inference). A declaration is worth exactly
as much as the inference engine that consumes it, which is why a portable macro layer
can reach monomorphic operator selection but not check elision.

---

## 4. Phase index

Each phase has its own directory under `phases/`. Phases run in order except where
noted.

| phase | directory | goal | gates |
|---|---|---|---|
| **0** | **`phases/00-compiler-research/`** | **an OKF bundle of compiler and language-design knowledge, built from a verified bibliography** | **7** |
| 1 | `phases/01-toolchain-gate/` | install, and find out whether Tangerine is implemented anywhere | everything |
| 2 | `phases/02-calibration/` | real dev-N timings and the machine noise floor | 3, 4 |
| 3 | `phases/03-core-measurement/` | configurations 1 to 6. The number the project exists for | 5, 6 |
| 4 | `phases/04-reference-points/` | configurations 7, 8, 9. Ada, the CL controls, Stalin | 6 |
| 5 | `phases/05-portable-library/` | the compatibility layer. **Optional now, see below** | 6 |
| 6 | `phases/06-writeup/` | the standards timeline with measured deltas attached | nothing |
| **7** | **`phases/07-compiler/`** | **an optimizing Scheme that reaches and beats CL-level optimization** | **nothing** |

Phase 1 can invalidate the premise of phases 3 and 5. Phase 3 can invalidate the
proposal. Both are deliberate: the cheap falsification steps come first.

**Phase 7 is the point, and it does not wait on the measurement.** It needs only phase 1,
and can run in parallel with everything else. The reason is that `CHEZ-ANALYSIS.md` already
established, by reading source against the compiler literature, what Chez structurally
cannot do: its lattice is level 1 in the abstract-domain hierarchy, it has no classical loop
optimizer, its `optimize-level` is global rather than lexical, and it offers no way to feed
the lattice beyond predicates. Those are architectural, not configurable, so no amount of
measurement on Chez tells us anything about the design's ceiling. Answering "can Scheme
reach and beat CL" requires a compiler.

**Phase 5 is demoted to optional.** It was designed as an instrument for discovering
compiler requirements. Reading the Chez and SBCL source supplied those requirements
directly and more precisely than a measurement would have. Build it only if an SRFI is
still wanted for its own sake.

Phases 1 through 4 stay because they are cheap and because they establish the baseline
phase 7 has to beat: configuration 5 is milestone 4's target, configuration 6 is milestone
5's.

---

## 5. Open questions

Only questions still genuinely open. Settled ones and their reasoning are in `LEDGER.md`.

**Is the deliverable the writeup or the library?** Phases 3 and 4 answer the
question and produce the timeline-plus-numbers artifact. Phase 5 produces a thing
people could use. I lean writeup first, because the measurement tells us whether the
library's ceiling is worth building toward. Affects phase 5 and 6 emphasis, nothing
upstream, so it does not need answering yet.

**How much does the expansion-time propagator matter?** It is the novel part of the
library track. `CHEZ-ANALYSIS.md` found that Chez already narrows types from predicate
tests, so a propagator over Chez has less to do than originally thought. In our own
compiler it is stage 5 onward and is the main event.

**Does Chez's `cptypes` already do our job at `optimize-level 2`?** Configuration 2c
is the experiment. `fold-primref/try-unsafe` (`cptypes.ss:1963`) promotes 270 safe
primitives to unsafe automatically once argument types check out. If a predicate guard
at level 2 emits the same code as level 3, the standards gap is narrower than section
1 implies and `PROPOSAL.md` changes.

**A portable Scheme SIMD library over SRFI 160 storage** is a real contribution and a
different paper. Follow-on, tracked here so it is not lost.
