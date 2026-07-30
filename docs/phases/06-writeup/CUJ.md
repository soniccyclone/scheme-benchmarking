# Phase 6 CUJ: Write-up

Technical implementation document. The journey is an operator turning a pile of results
JSON and four reference documents into one artifact that did not exist before: the Scheme
standards timeline with measured costs attached.

Companion to `PLAN.md` in this directory.

## Journey summary

The operator generates every table mechanically from the recorded results, assembles the
argument in a fixed order, decides whether to re-run on bare metal or scope the claims to
ratios, then audits every number and every claim about a standard against its source. The
output is a document plus a venue decision.

## Preconditions

Phase 3 complete, which is the minimum viable input. Phase 4 makes it substantially
stronger. Phase 5 is optional for the write-up but is what makes an SRFI credible.

## Step 1: decide the measurement grade first

This gates everything else, because it determines what the document is allowed to claim.

Everything measured in phases 2 through 5 ran under WSL2 with no `cpufreq` access, so the
governor could not be pinned and boost could not be disabled. That is adequate for ratios
taken close together in time and inadequate for publishable absolute numbers.

Two options. Pick one and record the choice.

**Option A: publish ratios only.** State the machine limitations plainly, present every
result as a ratio against a same-session baseline, and make no absolute claims. Honest,
cheap, available today. The cost is that a reader cannot compare our numbers against any
other published figure.

**Option B: re-run on bare metal.** Official N values, pinned governor, boost disabled,
enough repetitions for real confidence intervals. Better, and it needs hardware we have
not identified. `../../METHOD.md` deliberately kept report-grade measurement out of scope
until this point precisely so this decision could be made with the results in hand.

Recommendation: option A for a first publication, with the limitation stated in the method
section rather than buried in a footnote. The finding is about standards, and the finding
survives being expressed as ratios. If the result turns out to be strong enough to argue
about, option B becomes worth the trouble.

## Step 2: generate the tables mechanically

Nothing gets hand-transcribed. Every table in the document is generated from
`results/*.json` by a script, so a re-run regenerates the document rather than requiring
an edit pass.

```
harness/report.py --format markdown --out docs/phases/06-writeup/tables/
```

Tables needed:

| table | source | content |
|---|---|---|
| deltas | phase 3 | the five deltas with spread |
| standards timeline | `RESEARCH.md` section 1 plus phase 3 | each standard, what it added, measured cost |
| cross-language taxonomy | `RESEARCH.md` section 2 | premises, policy, layout per standard |
| Ada three-build | phase 4 part A | check levels against scalar C |
| CL controls | phase 4 part B | SBCL, ECL, CLISP on identical source |
| Stalin profile | `RESEARCH.md` section 3 plus phase 4 part C | bimodal distribution |
| library ceiling | phase 5 | portable declared against implementation-specific |

The standards timeline table is the artifact. Everything else supports it.

## Step 3: assemble the argument

Fixed order, because the argument depends on it.

1. **The question.** Does Scheme have the escape hatches that let a conformant Common
   Lisp reach C speed? Cite Verna 2006 as the demonstration that CL does.
2. **What the standards actually say.** The timeline from `RESEARCH.md` section 1. R5RS
   nothing, R6RS the fixnum and flonum libraries, R7RS-small dropping them, Red not
   helping, Tangerine restoring them plus SRFI 160, SRFI 145 orphaned outside any
   edition, and no policy switch at any point in thirty years.
3. **What that costs, measured.** Phase 3's deltas attached to the timeline. This is the
   contribution: not an opinion that Scheme should have declarations, but a figure for
   what each standardization decision cost.
4. **The cross-language frame.** `RESEARCH.md` section 2. Three powers a standard can
   grant, and the observation that a policy switch is only possible if the standard first
   mandated the checks. C and C++ need no escape because they promise nothing. Ada and CL
   both check by default and both standardized an escape. Scheme mandates the checks and
   standardizes no escape, which makes it the anomaly.
5. **Ada as validation.** Phase 4 part A. The design being proposed is Ada's, and here is
   what Ada's mechanism measures.
6. **The counterpoint.** Stalin. Inference reaches higher where it works and is bimodal,
   2x to 4x faster than Chez on float and array code, 5x to 16x slower where lifetime
   analysis fails and allocation falls through to Boehm. That argues for declarations on
   predictability rather than on achievable speed, which is a weaker and more defensible
   claim than "declarations are faster."
7. **The proposal.** `PROPOSAL.md` section 2, with phase 5's reference implementation if it
   exists.
8. **Method and limits.** Step 1's decision, stated where a reader would otherwise be
   misled.

## Step 4: the claim audit

Two passes, both mechanical enough to be checklists.

**Numbers.** Every figure in the document traces to a file in `results/`. Grep the
document for numeric literals and confirm each one either appears in a generated table or
cites an external source. No number survives that came from memory, which is a specific
failure this project has already committed once and corrected.

**Standards claims.** Every statement about what a standard says cites the standard
itself, not a summary, a blog post, or a wiki. The research in `RESEARCH.md` was done
against primary sources (R6RS library document, SRFI 145, SRFI 253, the Tangerine edition
document, the Ada Reference Manual, the Haskell 2010 Report) and the citations should
point there. Where a claim rests on something not verified directly, say so in the text
rather than in a footnote.

## Step 5: scope the claims honestly

The single largest overclaiming risk is generalizing from one program. nbody is
float-heavy, serial, small working set. It says nothing about allocation-heavy or
polymorphic code.

Two acceptable responses:

- Scope every claim to numeric kernels explicitly, in the abstract and the conclusion,
  not just the method section.
- Add `fannkuchredux` for an integer-only data point. This is the better option if there
  is time, because it isolates the declaration question from float boxing entirely: SIMD
  and flonum representation both drop out, leaving only check elision and operator
  selection. It is the cleanest possible read on the policy switch question.

If the result is negative, publish it with the same clarity. A finding that the missing
policy switch costs little would tell the Scheme community that the Tangerine operators
were the load-bearing part and no further standardization is needed here. That is useful
and it should not get buried.

## Step 6: venue

Not mutually exclusive, and they want different things.

- **Scheme Workshop paper.** The right home for the standards timeline plus measurement.
  Wants rigor and related work, and would benefit from option B measurement.
- **An SRFI, with the measurement in its rationale.** The right home if phase 5 produced
  a working library. An SRFI with a reference implementation and a measured justification
  is far stronger than one with an argument.
- **Long-form post.** Fastest, widest reach, no gatekeeping. Good for the cross-language
  taxonomy, which is interesting to more people than the Scheme-specific result.

One time-sensitive note carried from the research: SRFI 276, Type-specific Flonum
Libraries, was in draft with a comment deadline of 22 August 2026. That deadline has
almost certainly passed by the time this phase runs. Check whether it finalized and
whether anything in it changes the section 2 timeline before publishing.

## Artifacts produced

```
docs/phases/06-writeup/tables/*.md      generated, never hand-edited
docs/phases/06-writeup/WRITEUP.md       the document
docs/phases/06-writeup/RESULTS.md       venue decision, measurement grade decision
```

## Exit gates

- Every number traces to a recorded run or a cited external source.
- Every standards claim cites a primary source.
- WSL2 limitations stated where a reader would otherwise be misled.
- Claims scoped to what was measured: one or two programs, one machine, the
  implementations actually tested.
- A venue decision recorded.

## Follow-ons, both separate projects

A portable Scheme SIMD library over SRFI 160 storage. No Scheme has SIMD intrinsics and
SBCL now ships them in `contrib/sb-simd`, so this is a real gap with a real precedent.

Exposing SIMD to Chez through its FFI or assembler. Larger, and as far as the research
found, nobody has done it.

Both were deliberately scoped out of this project to keep the standards question clean.
Neither belongs in this write-up beyond a sentence noting they exist.

## Task decomposition notes

Step 1 gates the whole phase and is a decision rather than work. Step 2 is scripting and
is independent of steps 3 through 5. Step 3 is the bulk of the writing. Steps 4 and 5 are
audit passes and must run after step 3 rather than alongside it. Step 6 can happen any
time. If `fannkuchredux` gets added per step 5, that is really a phase 3 task executed
late and should be tracked as such rather than buried inside the write-up.
