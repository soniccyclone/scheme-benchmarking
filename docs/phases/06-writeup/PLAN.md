# Phase 6: Write-up

## Goal

Publish the standards timeline with measured deltas attached. As far as I can tell
nobody has written this, which is the main reason it is worth doing.

## The artifact

`RESEARCH.md` section 1 traces what each Scheme standard provided: R5RS nothing, R6RS
the fixnum and flonum operator libraries, R7RS-small dropping them, Red not helping,
Tangerine restoring them and adding SRFI 160, SRFI 145 `assume` orphaned outside any
edition, and no policy switch at any point in thirty years.

That timeline is currently an argument. Attaching phase 3's and phase 4's numbers turns
it into a measurement. The combination is the contribution: not "Scheme should have
declarations" as an opinion, but "here is what each standardization decision cost, in
seconds."

## Inputs

Phase 3 complete, which is the minimum. Phase 4 makes it substantially stronger, since
Ada validates the design and the CL controls separate the language from SBCL. Phase 5
is optional for the write-up but makes the SRFI credible.

## Work items

1. The timeline with deltas attached, per standard, per configuration.
2. The cross-language taxonomy from `RESEARCH.md` section 2: which standards give
   premises, policy, and layout, and the observation that a standard can only offer a
   policy switch if it first mandated the checks. Scheme is the anomaly among
   safe-by-default languages.
3. The Stalin analysis as the counterpoint: inference reaches higher where it works and
   is bimodal, which argues for declarations on predictability rather than on
   achievable speed.
4. Method and reproducibility. State the WSL2 limitations honestly, including the
   absence of `cpufreq` control, and mark every absolute number as machine-relative.
5. Decide the venue. Options are a Scheme Workshop paper, an SRFI with the measurement
   in its rationale, or a long-form post. These are not exclusive.

## The report-grade measurement question

Everything measured in phases 2 through 5 runs under WSL2 with no frequency control,
which is adequate for ratios taken close together in time and not adequate for
publishable absolutes.

Before publishing, decide one of: re-run on bare metal at official N with enough
repetitions for real confidence intervals; or publish ratios only, with the machine
limitations stated plainly and no absolute claims. The second is honest and cheaper.
The first is better. This is a real decision, not a formality, and it is the reason
`METHOD.md` keeps report-grade measurement explicitly out of scope until here.

## Acceptance criteria

- Every number in the write-up traces to a recorded run.
- The WSL2 limitations are stated where a reader would otherwise be misled.
- Claims are scoped to what was measured: one program, one machine, the
  implementations actually tested.
- Any claim about what a standard says cites the standard, not a summary of it.

## Risks

**Overclaiming from one program.** nbody is float-heavy and serial. It says nothing
about allocation-heavy or polymorphic code. Either scope the claims to numeric kernels
or add `fannkuchredux` for an integer-only data point, which would also isolate the
declaration question from float boxing entirely.

**The result is negative and gets buried.** If the missing policy switch turns out to
cost little, that is a genuinely useful finding and it should be published as clearly
as a positive one would be. It would tell the Scheme community that the Tangerine
operators were the load-bearing part and that no further standardization is needed
here.

## Outputs

- The write-up.
- A venue decision.
- Optional follow-ons, both separate projects: a portable Scheme SIMD library over
  SRFI 160 storage, and exposing SIMD intrinsics to Chez.
