# Machine, Measurement Method, and Dependencies

Shared setup for every phase. Establishing all of this is phase 1's job
(`phases/01-toolchain-gate/PLAN.md`); calibrating it is phase 2's
(`phases/02-calibration/PLAN.md`).

---

## Reference

**Machine.** AMD Ryzen AI Max+ PRO 395, 16 Zen 5 cores, 32 threads, homogeneous so
no P/E-core trap. AVX-512 present. 15 GiB in the VM. Under WSL2 kernel
6.18.33.2-microsoft, which costs us two things: `cpufreq` sysfs is absent so we
cannot pin the governor or disable boost, making absolute timings drift and
ratios-measured-close-together the only trustworthy output; and L3 sibling lists
read `0-31` for every CPU so the real 2-CCD split is invisible. SMT siblings are
adjacent pairs, so `taskset -c 0,2,4,6,8,10,12,14` gives one thread per physical
core. A `cpu` PMU node exists (type 4) and `perf_event_paranoid` is 2, so hardware
counters are a maybe worth a 30-second test. If they fail, read the emitted code
instead, which is the ground truth for this kind of question anyway:
`sb-disassem:disassemble`, Chez's `#%$assembly-output`, `raco decompile`,
`objdump`.

**Method.** `hyperfine`, pinned, three warmups, five measured runs, spread recorded
rather than only the mean. Dev N for nbody 1,000,000 and 2,000,000 against the
official 50,000,000, putting the C baseline near 42 ms. Two N values because at dev
sizes process startup varies from ~1 ms to ~200 ms across these runtimes and would
otherwise dominate; taking the slope cancels the constant, and each program also
reports its own internal elapsed time as a cross-check. Where slope and process
time disagree, the disagreement is the finding. Six configurations at two N values
and five reps is well under a minute of compute, which is the practical win of the
narrowed scope. Report-grade measurement (bare metal, official N, real confidence
intervals) stays explicitly out of scope so the dev harness does not grow into it.

**Dependencies.** All configurations, with resolved installed sizes using
`--no-install-recommends`:

| packages | for | size |
|---|---|---|
| `sbcl chezscheme racket hyperfine unzip` | configs 1 to 5 | ~872 MB, 13 pkgs |
| `ecl clisp` | config 9, the CL controls | ~199 MB |
| `gnat-15` | config 8, Ada | check at install |
| `stalin` | config 7, optional | small, 0.11-11build1 |

Versions: `sbcl` 2.6.0, `chezscheme` 10.0.0, `racket` 8.18, `hyperfine` 1.19.0,
`gnat-15` 15.2.0, `stalin` 0.11-11build1. gcc 15.2.0 is already installed and covers
configuration 6. Our toolchains are newer than the frozen corpus measured, which is
fine for internal comparison and needs stating if the numbers are ever printed
alongside theirs.

`rustc` and `cargo` stay optional. C is the reference that matters for configuration
6, and Rust adds a third compiler's variance without adding insight into the
declaration question.

**The verification gate before any number is trusted.** Ahead-of-time compilation per
implementation, which is where naive comparisons go wrong: Racket must go through
`raco make` or it recompiles per invocation and looks catastrophically slow for reasons
unrelated to Racket, Chez needs `compile-program` or it interprets, SBCL wants a saved
core or at minimum a fasl. Acceptance criterion for every configuration: the second run
is not slower than the first, and the time does not change when the source mtime is
touched.

**The Tangerine question is settled and the answer was no.** Determined by reading the
Chez and Racket source; see `phases/01-toolchain-gate/RESULTS.md`. Chez ships no
`(scheme ...)` libraries at all and provides R6RS instead, including
`(rnrs arithmetic flonums)` and `(rnrs arithmetic fixnums)` plus a native `flvector`.
Racket's SRFI package stops at SRFI 98. Configuration 2 therefore split into 2a, the
R6RS path that actually exists, and 2b, Tangerine over a shim we ship ourselves.

**Corpora already fetched**, parked in the scratchpad so nothing refetches: the
Benchmarks Game clone (60 MB, program sources in
`public/download/benchmarksgame-sourcecode.zip` as 1106 files with output
fixtures, per-entry flags only in `public/program/*.html`), `r7rs-benchmarks`, and
`plb`. Upstream programs carry per-program BSD-style licenses with attribution
requirements, so preserve headers.

---

---

## Decisions, ratified 2026-07-30

**R6RS is in scope.** Configuration 2a uses `(rnrs arithmetic flonums)` and
`(rnrs arithmetic fixnums)`, which Chez ships. It is the only standardized
instruction-level hatch with a real implementation behind it, so omitting it would measure a
path nobody can take.

**Serial-only, for now.** Every configuration runs single-threaded, enforced rather than
intended: any run whose cpu-time over elapsed-time ratio exceeds 1.3 is rejected as
contaminated. Reasons, in order of weight:

1. The Benchmarks Game comparison is confounded by thread count. Measured: fannkuchredux,
   mandelbrot and spectralnorm run about 3.9-way parallel in every language, which is
   internally fair, but binarytrees ranges 1.93 to 3.49, so part of that spread is thread
   count rather than code generation.
2. This machine cannot support parallel measurement. No `cpufreq` access under WSL2, and the
   L3 sibling list reads `0-31` for every CPU, so the real 2-CCD split on this part is
   invisible and we cannot tell whether our pinned cores share a die.
3. nbody is serial in every published entry, so it costs nothing for our chosen program.

**Serial-only does not constrain vectorization.** Stage 10 is SIMD, data parallelism inside
one core. Threading and vectorization get conflated constantly and are orthogonal here.

What it gives up: SBCL's threading story against Chez's, which is a separate project, and
comparability with the Game's parallel headline numbers, which `RESEARCH.md` already forbids
mixing into our tables anyway.

## Statistical protocol, and it applies from phase 2 onward

An earlier version of this document put statistical rigour only in the CI section below, as
though it were a future concern. It is not. Phases 2 and 3 said "report with spread" and
"above the noise floor", and **neither of those is a test**. If we are hand-rolling this, get
it right from the first measurement.

### We are not licensed to use t-tests

This follows directly from Stabilizer. Parametric tests assume the samples are normally
distributed, and the whole argument of that paper is that repeated runs of one binary are
samples of **one memory layout**, not independent draws. Without layout re-randomization the
distribution is unknown and can be multi-modal. Stabilizer's Table 1 measured exactly this:
five of eighteen benchmarks fail a normality test without it.

**And we cannot run Stabilizer.** It is an LLVM 3.1 pass; stage 13 emits x86-64 directly and
no implementation in our matrix touches LLVM. So we do not get normality handed to us, and
Student's t, ANOVA and anything else assuming Gaussian samples are off the table. Using them
anyway would produce a tight, confident, wrong interval, which is the specific failure
Stabilizer exists to name.

### Use bootstrap confidence intervals on the ratio

The distribution-free option, and it happens to produce exactly the quantity we report.

```
given samples A[1..n], B[1..n] for two configurations
repeat 10000 times:
    a* = resample A with replacement, n draws
    b* = resample B with replacement, n draws
    record ratio = median(b*) / median(a*)
report the 2.5th and 97.5th percentiles of the recorded ratios
```

If that interval excludes 1.0, the difference is real at the 95% level. No normality
assumption anywhere. Report the interval, not just the point estimate.

Non-parametric rank tests (Mann-Whitney U unpaired, Wilcoxon signed-rank paired) are the
alternative and are fine, but they test "are these distributions different" where we want
"how much faster, and how sure are we". Bootstrap answers the question we actually have.

### Three ways to get this wrong that are easy to miss

**Multiple comparisons.** The matrix has ten configurations. Testing every pairwise delta at
α=0.05 means roughly a one-in-three chance of at least one spurious result across
45 comparisons. Either correct with Holm-Bonferroni, or **pre-register** the specific deltas
that matter before looking at any data. `PLAN.md` section 2 already names them: 1→2a, 2a→2b,
2a→2c, 2c→4, 2a→4, 4→5, 5→6. That is seven, decided in advance, and no others get a p-value.

**Effect size is not significance.** With enough repetitions any nonzero difference becomes
statistically significant. Decide the minimum interesting effect *before* measuring. For this
project a ratio inside roughly 1.05 is not interesting regardless of its p-value, because it
cannot support a claim about a language design decision.

**The noise floor is a precondition, not a result.** Phase 2's coefficient of variation tells
us whether a given effect size is detectable at all on this machine. It does not by itself
establish that any observed difference is real. If the CV comes in above about 10%, the
smaller deltas are unmeasurable here and should be reported as such rather than given a
number.

### What this changes in the phases

Phase 2 additionally reports the **distribution shape**, not only mean and spread: run one
unchanged binary twenty times, and check normality (Shapiro-Wilk) so we know from the outset
whether we are in the non-normal regime Stabilizer predicts. Phase 3's exit gate becomes a
bootstrap CI on every pre-registered delta, with any interval spanning 1.0 reported as no
detected difference rather than as a small one.

---

## Later: CI-based measurement

**Not now.** This section describes where measurement goes *after* the initial findings land.
Until then everything runs serially on this machine.

### The design

The unit of measurement is **one complete benchmark suite run inside one CI job**, and
comparisons are only ever made *within* such a run. Never across them.

That constraint dissolves the objections that make CI benchmarking look hopeless. Shared
tenancy, rotating CPU generations, invisible frequency scaling and absent PMU access all
break *cross-run* comparison. None of them break A-against-B measured on the same runner,
in the same job, minutes apart, because whatever silicon and neighbours that job drew apply
equally to both arms.

Then get statistics honestly:

- Repeat each configuration enough times **within the job** to produce a real confidence
  interval rather than a single number.
- **Fan out across many CI nodes**, each running a complete comparable set. Every node yields
  one independent full-suite sample. Many nodes give a distribution of ratios, and the
  microarchitecture heterogeneity that would poison a cross-run comparison becomes a sampled
  variable instead of a confound.
- Report ratios across the whole suite, with p-values. A ratio is what the project cares
  about anyway: `RESEARCH.md` already forbids mixing absolute numbers with anyone else's.

This is strictly better than the deterministic-instruction-counting workaround an earlier
draft of this section proposed. Instruction counts under `cachegrind` are noise-immune but
answer a different question, and for a vectorization project they are actively misleading:
packed AVX-512 wins by doing the same work in fewer instructions **and** by better cache
behaviour, and an instruction count shows only the first.

### The trap: repetition alone does not fix measurement bias

Source talk: Emery Berger, *Performance Matters*, published 2019-09-15,
https://youtu.be/r-TLSBdHe1A. Randomizing memory layout is its central thesis, not an aside.

The two papers behind it are now **in this corpus** and should be read rather than
paraphrased:

- `knowledge/sources/curtsinger-berger-stabilizer-asplos-2013.pdf` — Curtsinger and Berger,
  *STABILIZER: Statistically Sound Performance Evaluation*, ASPLOS 2013.
- `knowledge/sources/curtsinger-berger-coz-causal-profiling.pdf` — Curtsinger and Berger,
  *COZ: Finding Code that Counts with Causal Profiling*, arXiv:1608.03676.

Also Mytkowicz et al., *Producing Wrong Data Without Doing Anything Obviously Wrong!*
(ASPLOS 2009), which is the underlying result and is **not** yet in the corpus.

Running one binary a thousand times gives a thousand samples of **one memory layout**, not a
thousand independent draws. Layout is not neutral: stack frame placement, heap object
placement and code placement all affect cache and branch-predictor behaviour, and the
observed effect can exceed the size of the optimization being measured. Mytkowicz et al.
showed that changing an environment variable, or renaming a function, can move measured
performance by more than the compiler change under test. Standard statistics applied to
those samples produce a tight, confident, wrong interval.

Berger's answer is **Stabilizer**: randomize layout repeatedly during execution, so the
measurement is drawn from the distribution *over* layouts. That makes the samples genuinely
independent, which is the precondition for the statistics above to mean anything.

**An earlier draft of this section said to vary layout across the fanned-out nodes. That is
the position Stabilizer explicitly argues against**, and its §7 rebuts it directly: link
order only changes inter-module placement, so one function growing still shifts everything
after it, and environment size moves the stack base without changing inter-frame distance.
Per-node one-time randomization buys sampling but neither normality nor variance reduction,
both of which require re-randomizing *inside* a run. Their Table 1 is the evidence: one-time
randomization leaves five benchmarks non-normal, re-randomization fixes four.

Mechanism specifics worth having, since they set what we would have to reimplement. Heap is
randomized per object through a size-segregated allocator with a Fisher-Yates shuffling
layer, touching only cache index bits. Code is randomized per function on a **500ms timer**,
lazily via a trap at each entry so the move never lands inside non-reentrant code. Stack is
randomized per call with 0 to 4080 bytes of padding in 16-byte steps. One run then becomes a
sum over roughly `T/500ms` i.i.d. layout intervals, so the central limit theorem makes total
time Gaussian at around 30 randomizations *whatever the layout-effect distribution looks
like*, which is what licenses Student's t and ANOVA. Overhead is 6.7% median and under 40%
everywhere, so cost was never the obstacle.

**Stabilizer itself is not adoptable as shipped.** It is an LLVM 3.1 `opt` pass driven
through clang or dragonegg, and stage 13 emits x86-64 objects directly while Chez, SBCL and
Racket never touch LLVM. It could only be pointed at the C baseline. The mechanism is
portable though, and **our runtime is better placed than C for the part that matters most**:
Stabilizer cannot move live heap objects because C forbids it, whereas a precise generational
copying collector already relocates survivors, so randomized survivor placement behind a
benchmark flag gives continuous heap re-randomization that C cannot have.

**The inverse risk, which is live right now.** A plain Cheney scan lays survivors out in
deterministic BFS order, so our collector as specified *reduces* cross-run layout diversity
rather than supplying it. That bites nbody, with its one long-lived `flvector`, and
binarytrees, precisely.

**Turn stack randomization off when measuring stage 10.** Stabilizer's pads are 16-byte
multiples and AVX-512 aligned moves want 64, so leaving it on makes vector-data alignment a
one-in-four coin flip. The authors attribute `hmmer` losing normality to exactly this, and
their §2.5 gives the protocol: disable the randomization your optimization targets, keep the
others on.

**Coz** (causal profiling, SOSP 2015; the arXiv copy we hold is the 2016 postprint) answers
"what would happen if I sped up this component" by slowing everything else down. It is
half-relevant to our stages, and the missing half is the one stage 06 depends on.

Virtually speeding a bounds-check line to 100% models removing it from the time budget, so it
would have shown ABCD's roughly 10% ceiling in advance, and it errs conservative so it will
not talk you into a pass that cannot pay. But ABCD's shortfall was not that the checks were
cheap to run: Bodík et al. blamed Jalapeño for lacking the global code motion the removal
existed to enable. Virtual speedup models "this instruction stream runs faster". It cannot
model "this instruction disappears, its scheduling barrier goes with it, and the loop now
vectorizes". **Enablement is not a speed change**, so for the stage 06 to stage 10
relationship Coz measures the floor and is blind to the ceiling.

Also unresolved: virtual speedup is implemented as pausing the other threads, and the paper
never treats the single-threaded case. That sits in tension with the serial-only decision
above and needs working out before Coz is relied on here.

### What still needs dedicated hardware

Absolute wall-clock claims, and the thread-count axis. Once hardware is fixed and CCD
topology is actually visible, **parallelism can be reintroduced** and the serial-only
decision above revisited. Not before.
