# Phase 2 CUJ: Calibration and the Noise Floor

Technical implementation document. The journey is an operator turning a set of guessed
measurement parameters into measured ones, and finding out how large a difference has
to be on this machine before it means anything.

Companion to `PLAN.md` in this directory.

## Journey summary

The operator builds the measurement harness, runs one unchanged binary twenty times to
get the spread, then measures real timings at two N values per configuration to check
that the predicted N table produces the intended runtimes. The two-N slope method gets
validated against internal program timing. The phase ends with a measured N table, a
stated noise floor as a percentage, and one written-down reporting convention that
later phases must not drift from.

## Preconditions

Phase 1 complete. Toolchains installed, AOT recipes written, every configuration
passing the recompilation trap test.

## Step 1: build the harness

Three scripts, kept deliberately small.

```
harness/compile.sh    from phase 1, dispatches on configuration name
harness/run.sh        pins, warms up, invokes hyperfine, emits JSON
harness/report.py     reads JSON, computes ratios, slopes, and spread
```

`run.sh` invariants, all of which matter and none of which are negotiable once results
start accumulating:

```
taskset -c 0,2,4,6,8,10,12,14 \
  hyperfine \
    --warmup 3 \
    --runs 5 \
    --export-json "results/<config>-<N>.json" \
    --command-name "<config>" \
    "<command>"
```

Pinning to even-numbered CPUs gives one thread per physical core, because SMT siblings
are adjacent pairs on this part. Whether those eight cores share a CCD is unverified,
since WSL2 flattens the L3 sibling list to `0-31` for every CPU. Accept that and keep
the set fixed so the unknown is at least constant.

## Step 2: the noise floor

Run first, before any comparison, because without it no delta means anything.

Take one compiled binary, change nothing, run it twenty times:

```
taskset -c 0,2,4,6,8,10,12,14 \
  hyperfine --warmup 3 --runs 20 --export-json results/noise-floor.json "<binary>"
```

Compute and record: mean, standard deviation, coefficient of variation, min, max, and
the ratio of max to min. The coefficient of variation is the number that gets quoted
for the rest of the project.

Decision point:

- CV under about 3%: comfortable. All the deltas the experiment hunts are measurable.
- CV 3% to 10%: workable. The 2-to-4 delta should still be visible. The 2-to-3 delta,
  the value of `assume`, may not be.
- CV over 10%: the machine is too noisy for the smaller effects. Record it, proceed
  with the large deltas only, and mark the small ones as requiring bare metal.

Repeat the twenty-run measurement on both the fastest and slowest configuration
available, because absolute spread and relative spread behave differently at 40 ms
than at 2 s.

## Step 3: validate the N table

Every N in `../../METHOD.md` is extrapolated from published gcc times using each
program's complexity. Check them.

Predicted for nbody: dev N of 1,000,000 and 2,000,000, against the official
50,000,000, targeting a C baseline near 42 ms.

```
for N in 250000 500000 1000000 2000000 4000000; do
  run gcc-scalar $N
done
```

Confirm the timing scales linearly in N, which it should for nbody, and that
1,000,000 lands near the intended 42 ms. Adjust if the real machine disagrees with the
extrapolation.

Then set the slow bound: run the slowest configuration available at the chosen N and
confirm it stays near or under one second. If a 20x-slower implementation pushes past
a couple of seconds, lower N. The target for the full sweep is under a minute of
compute so the loop stays interactive.

## Step 4: validate the two-N slope method

The problem this solves: at dev N, process startup is a large fraction of elapsed time
and varies enormously across runtimes. Order 1 ms for a native binary, order 10 ms for
an SBCL core, order 200 ms for Racket. Comparing raw elapsed times at dev N would
partly rank startup cost rather than code quality.

The slope cancels the constant. For two N values:

```
slope = (t(N2) - t(N1)) / (N2 - N1)
intercept = t(N1) - slope * N1
```

The intercept estimates fixed startup. The slope estimates per-unit work, which is
what we actually want to compare.

Validate it two ways:

1. Measure startup directly. Run each configuration at N=0 or the smallest N the
   program accepts, and compare against the computed intercept. They should agree.
2. Add internal timing to each program and compare the internally reported elapsed
   time against `slope * N`.

Where the two methods disagree by more than the noise floor, that disagreement is a
finding and gets recorded rather than averaged away. The most likely cause is
non-linear behavior, for example a garbage collection threshold crossed between N1 and
N2, and that is worth knowing before phase 3 runs.

## Step 5: internal timing instrumentation

One pattern per language, reporting to stderr so it does not corrupt the output being
checked against the fixture.

```scheme
;; Scheme, portable R7RS
(let ((t0 (current-jiffy)))
  (run n)
  (let ((dt (/ (- (current-jiffy) t0) (jiffies-per-second))))
    (display dt (current-error-port))))
```

```lisp
;; Common Lisp
(let ((t0 (get-internal-real-time)))
  (run n)
  (format *error-output* "~F~%"
          (/ (- (get-internal-real-time) t0)
             internal-time-units-per-second)))
```

```c
/* C, and the same shape for Ada via Ada.Real_Time */
struct timespec t0, t1;
clock_gettime(CLOCK_MONOTONIC, &t0);
run(n);
clock_gettime(CLOCK_MONOTONIC, &t1);
fprintf(stderr, "%.6f\n", (t1.tv_sec - t0.tv_sec) + 1e-9*(t1.tv_nsec - t0.tv_nsec));
```

Keep the timed region identical across configurations: it starts after argument
parsing and any one-time setup, and ends before output is written.

## Step 6: fix the reporting convention

Decide once, write it down, and do not drift.

The choice is mean with spread versus minimum. Arguments both ways: the minimum
estimates the machine's capability with noise removed and is what the Benchmarks Game
effectively reports; the mean with spread is honest about a machine we cannot quiet and
lets a reader see when a difference is inside the noise.

Recommendation, given no frequency control under WSL2: report the mean with the
coefficient of variation, and additionally record the minimum. Never quote a mean
without its spread, since the whole point of step 2 is knowing when a delta is real.

Also decide and record: interleave configurations rather than running all repetitions
of one configuration consecutively. Thermal drift over a long sweep would otherwise
bias whichever configuration ran last. Interleaving spreads that error across all of
them equally.

## Results schema

One JSON file per configuration per N, plus a rollup. `report.py` reads them all.

```json
{
  "config": "chez-tangerine",
  "program": "nbody",
  "n": 1000000,
  "runs": 5,
  "mean_s": 0.0421,
  "stddev_s": 0.0009,
  "cv": 0.021,
  "min_s": 0.0412,
  "internal_mean_s": 0.0388,
  "toolchain": "chez 10.0.0",
  "pinned_cpus": "0,2,4,6,8,10,12,14",
  "timestamp": "2026-07-29T00:00:00Z"
}
```

Commit these. They are the evidence trail behind every number in phase 6, and phase 6's
acceptance criteria require that every published figure trace back to a recorded run.

## Artifacts produced

```
harness/run.sh
harness/report.py
results/noise-floor.json
results/<config>-<N>.json
docs/phases/02-calibration/RESULTS.md    measured N table, noise floor, convention
```

## Exit gates

- A measured N table replacing the extrapolated one in `../../METHOD.md`.
- A stated noise floor as a coefficient of variation, measured at both a fast and a
  slow configuration.
- Slope-based and internal-timing measurements agreeing within the noise floor on at
  least one configuration, or the disagreement documented.
- One written reporting convention.

## Task decomposition notes

Step 1 gates everything else. Step 2 is independent of steps 3 through 5 and should run
first anyway, since its result determines whether the rest of the project can measure
what it wants to. Steps 3 and 4 are coupled: validating the N table and validating the
slope method use the same runs. Step 5 touches every program variant and is the widest
piece of work here. Step 6 is a decision, not an implementation, and takes minutes.
