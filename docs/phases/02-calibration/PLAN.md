# Phase 2: Calibration and the Noise Floor

## Goal

Replace the predicted measurement parameters with measured ones, and establish how
large a difference has to be on this machine before it means anything.

## Why this matters

Every N value in `../../METHOD.md` is an extrapolation from published gcc times using
each program's complexity. None of it has been measured here. Running the experiment
on unvalidated parameters risks either wasting time on runs that are too long or
producing numbers dominated by startup rather than by the code under test.

The noise floor matters more. This machine runs under WSL2 with no `cpufreq` access,
so we cannot pin the governor or disable boost. Absolute timings will drift with
thermal and power state. Without knowing the spread, we cannot tell a real 15%
difference from measurement noise, and several of the deltas the experiment is looking
for are that size.

## Inputs

Phase 1 complete: toolchains installed, AOT recipes verified.

## Work items

1. Measure real dev-N timings for nbody across the installed implementations. Confirm
   or correct the predicted values of 1,000,000 and 2,000,000 against the official
   50,000,000.
2. Confirm the C baseline lands near the intended 42 ms at dev N. Adjust if not.
3. Establish the noise floor: run one unchanged binary twenty times and record the
   distribution, not just the mean. Report the coefficient of variation.
4. Verify the two-N slope method cancels startup as intended. Startup ranges from
   about 1 ms for a `gsc`-style native binary to about 200 ms for Racket, so confirm
   the slope removes it rather than assuming it does.
5. Add internal timing to each program so it reports its own elapsed time. Cross-check
   against the process-level number from `hyperfine`.
6. Decide and write down the reporting convention: mean with spread, or minimum. State
   which and why, once, so later phases do not drift between them.

## Acceptance criteria

- A measured N table replacing the extrapolated one in `../../METHOD.md`.
- A stated noise floor as a percentage, with the twenty-run distribution recorded.
- Slope-based and internal-timing measurements agree with each other within the noise
  floor on at least one configuration. Where they disagree, the disagreement is
  documented, because that disagreement is itself a finding.
- A single stated reporting convention.

## Risks

**The noise floor is larger than the effects we are hunting.** Possible under WSL2 on
a mobile part. If the coefficient of variation exceeds roughly 10%, some of the
smaller deltas (2 to 3, the value of `assume`) become unmeasurable here and have to
wait for bare metal. Finding this out in phase 2 rather than phase 3 is the point.

**Thermal drift over a long sweep.** Mitigate by interleaving configurations rather
than running all reps of one configuration together, so drift affects all
configurations equally instead of biasing whichever ran last.

## Outputs

- Measured N table.
- Stated noise floor.
- Reporting convention.
- A harness that pins, warms up, runs, and emits JSON.
