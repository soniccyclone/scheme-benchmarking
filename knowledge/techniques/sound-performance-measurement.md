---
type: technique
title: Sound performance measurement
description: Make a speedup claim survive contact with a statistician. Memory layout moves performance more than most optimizations do, so repeated runs of one binary are one sample and not many; re-randomizing layout during execution is what makes the samples independent and the p-values real.
tags: [measurement-bias, layout-randomization, benchmarking-methodology, causal-profiling, central-limit-theorem]
sources:
  - resource: /works/curtsinger-berger-stabilizer-asplos-2013.md
  - resource: /works/curtsinger-berger-coz-causal-profiling.md
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
  - resource: /works/cheney-nonrecursive-list-compacting-1970.md
implemented_by: []
absent_from: []
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-05T00:00:00Z" }
---

# Problem

We intend to claim that a pass made something faster. The claim has two failure modes and
only one of them is about statistics.

The first is that the number is noise wearing a confidence interval. Caches and branch
predictors are indexed by address, so performance depends on where things sit in memory.
Curtsinger and Berger measure a 57% swing from link order alone, and cite Mytkowicz for 300%
from the size of an environment variable. Any code change perturbs layout, so the effect of
an optimization arrives inseparably fused to the effect of its layout perturbation. Since a
compiled binary has exactly one layout, running it a thousand times produces a thousand
measurements of **one** sample from the layout population. The variance you measure is
run-to-run jitter; the term that dominates sits pinned at a constant you never observe. Feed
those runs to a t-test and it returns a tight, confident, wrong interval.

The second is that the pass was real, measured honestly, and still bought nothing, because
what it removed was not what was costing you. Bodík, Gupta and Sarkar removed 45% of dynamic
bounds checks for roughly 10%, and blamed the gap on the compiler downstream not consuming
the freedom the removal created. That is a question you would rather answer before writing
the pass.

# Mechanism

Two separate tools for the two failure modes.

## Stabilizer: randomize layout during execution

An LLVM pass plus a runtime library, driven by `szc` in place of the compiler. Three
randomizations, independently switchable.

**Heap, per object.** A power-of-two size-segregated allocator is wrapped in a shuffling
layer. Each size class holds an array of N pointers, filled at startup and Fisher-Yates
shuffled. `malloc` pulls a fresh object from the base heap, picks random `i` in `[0,N)`, swaps
it into `array[i]`, returns what came out. `free` swaps the freed pointer into a random slot
and releases what came out. N = 256, the smallest value at which returned addresses pass six
NIST SP800-22 tests. Only the cache index bits are worth randomizing (bits 6 to 17 on Core2):
below that you misalign, above it you thrash the TLB.

**Code, per function, every 500ms.** Functions live in a second randomized heap. Each
relocated copy carries its own relocation table immediately after its body, PC-relative
addressed, holding every global and function it references. Relocation is lazy: an `int3` at
each entry traps on first call, the handler copies the body to a random address, builds the
table, and patches the original entry to a static jump. A 500ms timer re-traps every live
function; the move itself happens at the next trapped call rather than in the signal handler,
which is what keeps it out of non-reentrant code. Dead copies are reclaimed by walking the
stack and freeing anything without a live return address.

**Stack, per call.** Each function gets a 256-byte pad table and a one-byte index. On entry it
loads `table[index++]`, multiplies by 16, moves the stack down by that much, restores on
return. Padding is 0 to 4080 bytes. The runtime refills every pad table at each
re-randomization. A frame's position is the sum of the pads below it, which is where the
entropy comes from.

**Why this licenses parametric tests.** One execution becomes a sum over roughly `T/500ms`
i.i.d. random-layout intervals. Total time is therefore the sample mean over layouts times a
constant, and the Central Limit Theorem makes it Gaussian at about 30 randomizations
*regardless of what the layout-effect distribution itself looks like*. That is the whole
payoff: an unknown, possibly multi-modal population is converted into a normal one, so
Student's t per benchmark and one-way within-subjects ANOVA across a suite become legal.
ANOVA matters because 36 pairwise t-tests at alpha = 0.05 expect 1.8 false positives, and
partitioning variance by source tests the whole suite at once instead.

Phased programs decompose recursively into subprograms that each reduce to the single-loop
case; each is normal and sums of normals are normal. Verified with Shapiro-Wilk on 18 SPEC
benchmarks: five are non-normal without re-randomization, one (cactusADM) with it. Note also
that re-randomization *reduces* variance significantly in eight benchmarks, by regression to
the mean, because drawing an extreme total requires drawing many more unlucky layouts than
lucky ones.

## Coz: virtual speedup

You cannot make a line faster on demand, so make everything else slower by the same relative
amount and subtract. Pause every other thread by `d` each time line `f` runs, and `f`'s
effective time is `t_f - d`; the pauses add `n_f * d` to the total, so subtract that back.

Instrumenting every execution would destroy the measurement, so it is done by sampling.
`perf_event` samples every thread's PC every 1ms. Samples landing in the selected line number
`s ~= n * t_bar / P`. Delaying only on sampled executions gives effective line time
`t_bar * (1 - d/P)`, so **the virtual speedup is exactly `d/P`**, independent of how often the
line runs or how long it takes. A delay of a quarter of the sampling period is a 25% virtual
speedup, with zero instrumentation. Pausing is done with a global and per-thread counter pair
rather than signals; a thread that ran the line itself is credited rather than slept.

Output is a graph per line: virtual speedup against program speedup, ranked by regression
slope. Flat means do not bother. Downward means the line is contended and optimizing it will
make things worse, which is where three of the paper's eight wins came from. "Program
speedup" is measured at a developer-placed progress point, so the target can be throughput,
or latency via Little's Law from a pair of progress points.

# Preconditions

Stabilizer needs the whole program buildable to LLVM bitcode; more than one function; a
supply of short-lived heap objects, which the authors tie to the generational hypothesis
holding in unmanaged code; no custom allocator and no hand sub-allocation out of one big
array, since it can see inside neither and cannot split a large allocation. C++ exceptions
were unsupported as of the paper. On x86-64 it needs `mmap MAP_32BIT` for 32-bit jump
displacements, falling back to a much slower push-and-`ret` sequence.

Coz needs Linux x86-64, DWARF line info (build with `-g -fno-omit-frame-pointer`), and real
pthreads. The delay accounting is correct only because Coz interposes on the specific tables
of POSIX calls that block or wake a thread, so a runtime with green threads, its own
scheduler, or a custom suspend path outside those tables invalidates the virtual speedup
argument. A progress point must be hit at least five times per experiment.

# Cost

Stabilizer: 6.7% median, under 40% everywhere, over 30% for four of eighteen. gobmk, gcc and
perlbench pay for stack randomization because thousands of functions means thousands of
256-byte pad tables and a fat working set; cactusADM pays for power-of-two rounding on large
arrays. The defence of overhead is sound and worth keeping: it shifts both arms of a
comparison equally, and a t-test resolves differences smaller than the overhead.

Coz: 17.6% mean, 0.1% to 65%. Decomposed as 2.6% DWARF processing at startup, 4.8% sampling,
10.2% inserted delays. Compare gprof at up to 6x. Delay overhead trades directly against how
long you must profile to fill in the graphs.

What neither fixes. Stabilizer never moves a live heap object, because C and C++ forbid it,
so a long-lived data structure keeps whatever layout it was born with for the entire run.
Global and BSS placement is not randomized at all. Branch predictor *history* is untouched
(basic-block relocation with branch-sense swapping is listed as future work). And the
normality claim is explicitly conditioned on "no other large sources of measurement bias":
frequency scaling, co-tenancy and thermals are all outside its scope. Stabilizer removes one
term. It is not a general noise remedy.

# Disagreements

**Setup randomization against runtime re-randomization.** Mytkowicz et al. propose exploring
link orders and environment sizes. Stabilizer Section 7 argues this needs far more runs and
does not eliminate the bias: link order only changes inter-module placement, so a change in
one function's size still shifts every function after it, and environment size moves the
stack base without changing the distance between frames. Both sides agree layout is the
problem; they disagree on whether sampling it between runs is enough. Stabilizer's evidence
is Table 1, where one-time randomization leaves five benchmarks non-normal and
re-randomization fixes four of them.

**Stabilizer's abstract contradicts its own Section 6.1.** The abstract says -O2 has a
significant impact over -O1. Section 6.1 reports F(1) = 3.235, p = 0.0898, and states that
-O2 is significant at 90% but not 95%, while every other test in the paper uses alpha = 0.05.
By the paper's own threshold, -O2 over -O1 also fails across the suite. The famous -O3 result
(F = 1.335, p = 0.264) stands as stated. Do not repeat the abstract's version.

**The authors did not use their own tool.** Coz, two years later, reports speedups with
Efron's bootstrap and tests significance with the one-tailed Mann-Whitney U test, chosen
because it assumes nothing about the distribution of execution times. That is a quiet
admission that the Coz evaluation was not run under Stabilizer, and it is the honest fallback
when you cannot establish normality: use a non-parametric test and accept the loss of power.

**Coz models the wrong kind of optimization for a compiler.** Virtual speedup models "this
existing instruction stream runs faster". A compiler pass frequently delivers its value as
"this instruction disappears, the scheduling barrier it constituted goes with it, and now the
loop vectorizes". Enabling effects change the code, not its speed, and are invisible to an
experiment that only inserts delays. See `# For us`.

# For us

Neither tool is adoptable as shipped, and the reason is the build path rather than the
overhead. Stabilizer is an LLVM 3.1 pass driven through clang or gfortran-plus-dragonegg.
Stage 13 emits x86-64 object files directly and never touches LLVM, and neither do Chez,
SBCL or Racket, so the one configuration Stabilizer could be pointed at is the C baseline.
Overhead was never the obstacle: at 6.7% median against a suite that runs in well under a
minute, we could afford it per CI job many times over.

What we can have is the mechanism rather than the tool, and our runtime is in a *better*
position than C for the part that matters most. Stabilizer cannot re-randomize long-lived
heap objects because C forbids relocating them. A precise generational copying collector
already relocates survivors, so a randomized survivor-placement mode behind a benchmark flag
gives us continuous heap re-randomization that Stabilizer cannot get in C at all. Note that a
plain Cheney scan is the opposite of this: it lays survivors out in breadth-first traversal
order deterministically, so our collector currently *reduces* layout diversity across runs
rather than supplying it. This matters directly for nbody, which holds one long-lived
`flvector`, and for binarytrees, which is nothing but a long-lived pointer structure. Those
are exactly the shapes Stabilizer's heap randomization cannot reach.

Stack randomization is the one to leave off when measuring stage 10. Pads are multiples of 16
bytes and AVX-512 aligned moves want 64, so stack randomization turns the alignment of
stack-resident vector data into a one-in-four coin flip. The Stabilizer authors themselves
blame hmmer's loss of normality on alignment-sensitive floating point. Their Section 2.5 has
the right protocol: to evaluate an optimization that targets layout, disable the randomization
it targets and leave the others on.

On Coz and the ABCD question. `METHOD.md` says causal profiling is how you learn in advance
that removing 45% of bounds checks buys 10%. Half right, and the half that is right is worth
having: virtually speeding a check line to 100% models its complete removal from the time
budget and would show the ~10% ceiling before anyone writes stage 06. It errs conservative,
so it will not talk you into a pass that cannot pay. But ABCD's shortfall was not that the
checks were cheap to execute; it was that Jalapeño lacked the global code motion the removal
was supposed to enable. Coz cannot see that, because enablement is not a speed change. For
the stage 06 to stage 10 relationship, where the whole point of removing the check is to
unpin the memory access so the loop body becomes vectorizable, causal profiling measures the
floor and is blind to the ceiling.

There is also a plainer problem. `METHOD.md` enforces serial-only measurement by rejecting
any run whose cpu-over-elapsed ratio exceeds 1.3. Virtual speedup *is* "pause the other
threads". In a single-threaded program the causal answer collapses to time-fraction times
line-speedup, which a flat sampling profiler already prints. The paper never treats the
serial case, and whether Coz reports that answer correctly or reports a flat zero depends on
an accounting detail the PDF does not state; see the `# Relevance` section of the Coz work
document, and check the source before pointing it at a serial benchmark. Either way the best
case is an expensive `perf record`. Its natural targets for us are our own compiler
as a normal Linux application, with a progress point after each compiled top-level form, and
later the runtime and collector if the serial-only decision is revisited on real hardware.
