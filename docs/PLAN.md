# Optimization Escape Hatches: Common Lisp vs Scheme

Overview and phase index. Revision 4, 2026-07-29.

Revision 4 splits the former single plan document into an overview plus per-phase
documents, so each phase can get a CUJ document and a task breakdown of its own.

## Document map

| document | contents |
|---|---|
| `PLAN.md` (this file) | thesis, the experiment matrix, phase index, open questions |
| `RESEARCH.md` | standards survey, cross-language comparison, Stalin analysis, measurement evidence |
| `PROPOSAL.md` | prior art, the design we would propose, .NET architecture notes, compiler layering |
| `METHOD.md` | machine, measurement method, dependency table |
| `phases/NN-name/PLAN.md` | per phase: goal, inputs, work items, acceptance criteria, risks |
| `phases/NN-name/CUJ.md` | per phase: the technical implementation journey. Commands, code shapes, schemas, decision branches |

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
means code that uses that story does not fall off the standard. Revision 2 framed
"CL standardizes notation, not effect" as a weakness of the CL argument. That was
backwards. Standardizing the notation is exactly the trick, because the
alternative is what Scheme actually got: every implementation invents its own
syntax, and tuned code stops being portable the moment it is tuned.

So the question is whether Scheme ever did the same thing, and the answer turns
out to be more interesting than a flat no.

---


---

## 2. The experiment

One program, nine configurations, each isolating one standards-level feature or
providing one reference point. This validates section 2's prediction rather than
being a benchmarking project in its own right.

**Program: nbody.** Serial in every published entry so no thread confound, pure
double-float over a small fixed working set so it isolates boxing and storage
cleanly, and the program both Pecsek and Smith used so there are external numbers
to sanity-check against.

| # | configuration | role |
|---|---|---|
| 1 | portable R7RS-small, generic arithmetic, `vector` | the floor: no hatches exist |
| 2 | R7RS-large Tangerine: `(scheme flonum)` + `(scheme vector f64)` | what portable tuned Scheme can do today |
| 3 | Tangerine + SRFI 145 `assume` | what the orphaned premise hatch is worth |
| 4 | implementation-specific max: Chez `optimize-level 3`, Racket unsafe ops | the folklore ceiling |
| 5 | SBCL, `declare` + `(safety 0)`, scalar, no `sb-simd` | tuned conformant CL |
| 6 | `gcc -O2 -fno-tree-vectorize`, and `-O3 -march=native` | scalar and vectorized C reference |
| 7 | **Stalin, whole-program inference** | **the Scheme ceiling, reached by the other route** |
| 8 | **GNAT Ada, `pragma Suppress`, per-check** | **the design we are copying, measured** |
| 9 | **ECL and CLISP, same source as 5** | **is it Common Lisp or is it SBCL?** |

Run configurations 1 through 4 on both Chez and Racket, since section 5's data says
they are within 15% on numeric code and any large divergence here would itself be a
finding.

The deltas answer specific questions. 1 to 2 is what Tangerine bought Scheme. 2 to
3 is what ratifying `assume` would buy. 2 to 4 is the cost of the missing policy
switch, which is the number the whole project exists to produce. 4 to 5 is whether
CL's inference beats Scheme's hand-written instructions with both sides maximally
tuned. 5 to 6 re-runs Verna's claim on 2026 hardware.

### Why 7, 8 and 9 are in the matrix

These three are not filler. Each one can falsify a different part of the argument,
which is the point of including them.

**Stalin (7) is the Scheme ceiling and the control on our whole approach.** It
reaches C-competitive numeric code by inference instead of declaration. If Stalin
already beats every declaration-based configuration by a wide margin, then the
interesting problem is inference and not standardization, and this project is aimed
at the wrong target. Section 5a covers what it actually does and what the existing
data says. Caveats about its vintage go there too.

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

**SIMD stays out of scope**, deliberately. The fast Benchmarks Game and PLB Common
Lisp entries use `sb-simd` (verified: `grep -rl sb-simd` hits nbody 3 through 6 and
spectral-norm 2 through 7 in the PLB tree, with Bela Pecsek's attribution and
"Based on 2.zig" headers). That is why configuration 5 excludes it. A portable
Scheme SIMD library is writeable and is a separate project. Mixing it in here would
confound the standards question with an intrinsics question.

**SIMD is out of scope**, deliberately. The fast Benchmarks Game and PLB Common
Lisp entries use `sb-simd` (verified: `grep -rl sb-simd` hits nbody 3 through 6
and spectral-norm 2 through 7 in the PLB tree, with Bela Pecsek's attribution and
"Based on 2.zig" headers). That is why configuration 5 excludes it. You are right
that a portable Scheme SIMD library is writeable, and it is a separate project;
mixing it in here would confound the standards question with an intrinsics
question. Noted in section 7 as a follow-on.

---


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
noted. The numbering is now contiguous; an earlier revision skipped phase 4 by
accident.

| phase | directory | goal | gates |
|---|---|---|---|
| 1 | `phases/01-toolchain-gate/` | install, and find out whether Tangerine is implemented anywhere | everything |
| 2 | `phases/02-calibration/` | real dev-N timings and the machine noise floor | 3, 4 |
| 3 | `phases/03-core-measurement/` | configurations 1 to 6. The number the project exists for | 5, 6 |
| 4 | `phases/04-reference-points/` | configurations 7, 8, 9. Ada, the CL controls, Stalin | 6 |
| 5 | `phases/05-portable-library/` | build the compatibility layer from `PROPOSAL.md` | 6 |
| 6 | `phases/06-writeup/` | the standards timeline with measured deltas attached | nothing |

Phase 1 can invalidate the premise of phases 3 and 5. Phase 3 can invalidate the
whole proposal. Both are deliberate: the cheap falsification steps come first.

---

## 5. Open questions

**Is the deliverable the writeup or the library?** Phases 3 and 4 answer the
question and produce the timeline-plus-numbers artifact. Phase 5 produces a thing
people could use. I lean writeup first, because the measurement tells us whether
the library's ceiling is worth the effort, and because if Tangerine turns out to be
unimplemented then phase 5's shape changes completely.

**How much does the expansion-time propagator matter to you?** It is the novel part
and it is also the part most likely to eat a week. The honest compatibility layer
is a weekend.

**Should R6RS implementations be in scope?** R6RS standardized the fx/fl operators
in 2007 and R7RS-small dropped them, so R6RS Schemes (Larceny, Ypsilon, Mosh,
Sagittarius, IronScheme, and Chez in R6RS mode) had a portable tuned numeric path
for twelve years that R7RS users did not. Including one would let us measure
whether that path was actually faster in practice, which speaks directly to
whether standardizing instructions without a policy switch accomplishes anything.
I think this is worth one implementation, and Chez can do it without adding a
dependency.

**Do you want the SIMD question kept out?** I scoped it out to keep the standards
question clean, but you raised it and you may want it in. My view is it is a strong
follow-on precisely because it is orthogonal: a portable Scheme SIMD library over
SRFI 160 storage would be a real contribution, and it is a different paper.
