---
type: paper
title: "COZ: Finding Code that Counts with Causal Profiling"
description: Measures what a line of code is actually worth by running experiments that virtually speed it up, inserting pauses in every other thread whenever it executes, which has the same relative effect as making it faster.
resource: knowledge/sources/curtsinger-berger-coz-causal-profiling.pdf
tags: [causal-profiling, virtual-speedup, profiling, concurrency, benchmarking-methodology]
authors: [Charlie Curtsinger, Emery D. Berger]
year: 2015
venue: "SOSP 2015, Monterey CA. This PDF is the arXiv:1608.03676v1 postprint, 12 Aug 2016"
informs: [/techniques/sound-performance-measurement.md, /techniques/bounds-check-elimination.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-05T00:00:00Z" }
---

# Contribution

A conventional profiler answers "where did time go", and the paper's opening example shows
why that is the wrong question. Two threads run `a` for 6.7s and `b` for 6.4s. gprof reports
55% and 45%. Deleting `a` entirely buys 4.5% because `b` becomes the critical path, and
deleting `b` buys nothing. Time share and causal impact are different quantities, and only
one of them tells you where to spend a week.

Causal profiling measures the second one directly, by experiment rather than by model. It
cannot make a line faster, so it makes everything else slower by the same relative amount,
which is observationally the same thing. The output is not a ranked list but a graph per
line: virtual speedup applied to that line on the x-axis, resulting program speedup on the
y-axis, sorted by the slope of the regression. Flat means do not bother. **Negative slope
means the line is contended and optimizing it will make the program slower**, which turned
out to be the most valuable signal in practice: three of the paper's eight optimizations came
from downward-sloping profiles.

The second contribution is that "program speedup" is user-defined rather than end-to-end
runtime. The developer marks a progress point, and Coz measures the rate of visits to it, so
the optimization target can be throughput. Two progress points measure latency instead, via
Little's Law: visits to the first give arrival rate lambda, the difference in counts gives
requests in flight L, and average latency is L/lambda.

# Mechanism

**Setup.** `coz run --- <program> <args>`. `LD_PRELOAD` injects the profiling runtime, which
builds an address-to-source-line map from DWARF at startup, using GDB's search procedure for
external debug info if the binary lacks it, then spawns a profiler thread. Source scope and
binary scope flags restrict which lines are candidates, and the right setting is "the code I
am actually willing to change".

**One experiment.** The profiler picks a line and a virtual speedup amount, both randomly.
Line selection works by having every thread sample its instruction pointer; the first thread
to report an in-scope line wins, which biases toward recently executed lines. Speedup is a
multiple of 5% in [0%, 100%], where 100% means the line is eliminated. 0% is drawn with 50%
probability because a per-line baseline is needed to compute a percentage, and measuring the
baseline per line rather than globally cancels any line-dependent overhead of the delay
machinery itself. Both choices must be random: exploring speedups in increasing order, or
skipping lines that showed no effect early, would systematically mis-measure any line whose
importance varies over time (a line that only matters after warmup, or only during
initialization). The experiment runs for a fixed time, extended by doubling if fewer than
five progress point visits landed in it, then logs the effective duration (real time minus
total inserted delay), the line, the speedup, and all progress point counters. A cooloff
period follows so in-flight samples do not leak into the next experiment.

**Virtual speedup, the idealized version.** Each time `f` runs, pause every other thread for
`d`. If `f` averages `t_f`, its effective average is `t_f - d`. The pauses add `n_f * d` to
total runtime, so subtracting `n_f * d` from the measured total gives the runtime the program
would have had if `f` really took `t_f - d`. Figure 3 is the whole idea.

**Virtual speedup as actually implemented.** Instrumenting every execution of a line would
have prohibitive probe effect, so Coz samples instead. `perf_event` collects the program
counter and user-space call stack from every thread every 1ms, processed in batches of ten.
The number of samples landing in the selected line is `s ~= n * t_bar / P` for sampling period
`P`. Delaying only on sampled executions gives an effective average line time of
`t_e = ((n-s) * t_bar + s * (t_bar - d)) / n`, which reduces to `t_bar * (1 - d/P)`. So the
virtual speedup is exactly `d/P`, independent of `n` and of `t_bar`. **A delay of one quarter
of the sampling period is a 25% virtual speedup of that line, with no instrumentation
whatsoever.** That derivation is the engineering core of the paper.

**Pausing.** POSIX signals are too expensive, so pausing is done with counters: one global
count of required pauses, one local count per thread. A thread whose local count trails the
global must pause and increment. `nanosleep` only guarantees a minimum, so overshoot is
tracked and subtracted from later pauses. The optimization in Section 3.4.3 preserves the
invariant *pauses + own-samples-in-selected-line = global count* per thread, so a thread that
executed the line gets credit instead of sleeping, and if every thread runs the line nobody
sleeps at all.

**Blocked threads.** Delays accumulate against a suspended thread. For blocking I/O that is
right, since pausing an already-blocked thread adds nothing. For synchronization it is wrong:
if a thread wakes because another thread unlocked a mutex, and that other thread already paid
the delays, the woken thread has effectively already been delayed. The rule is that a resumed
thread is credited for delays inserted in whichever thread woke it. Coz implements this by
interposing on POSIX calls that can block (`pthread_mutex_lock`, `pthread_cond_wait`,
`pthread_barrier_wait`, `pthread_join`, the `sigwait` family) and calls that can wake someone
(`pthread_mutex_unlock`, `pthread_cond_signal`/`broadcast`, `pthread_barrier_wait`,
`pthread_kill`, `pthread_exit`), forcing all outstanding delays to be executed before either,
so a resumed thread may skip whatever accumulated while it was blocked. Ad-hoc
synchronization that never suspends a thread needs no special handling. `pthread_create` is
interposed to start sampling in the child and to inherit the parent's local delay count.

**Phase correction.** Lines are selected from currently-executing code, so a line that only
runs during one phase is only ever experimented on during that phase, and its measured impact
would be overstated relative to whole-program time. Coz splits execution into phase A (the
line runs) and phase B (it does not), estimates `t_A ~= s * t_obs / s_obs` from the ratio of
total samples in the line to samples during the experiment, and multiplies every measured
speedup by the correction factor `(t_obs / s_obs) * (s / T)`.

**Attribution.** Samples outside the scope walk the call chain to the first in-scope address,
so time inside `printf` and everything it calls is charged to the call site.

# Applicability

Overhead averages 17.6% (min 0.1%, max 65%), decomposed as 2.6% startup for DWARF processing,
4.8% sampling, 10.2% inserted delays. Compare gprof at up to 6x on ferret. Startup is
amortized on the PARSEC mean runtime of 103s but hurts large binaries (x264, vips). Sampling
overhead is mostly starting and stopping `perf_event` per thread at creation and exit, which
would vanish if `perf_event` could sample all threads in a process. Delay overhead trades
directly against profiling wall time.

Preconditions. Linux, x86-64, unmodified binaries, but DWARF line information must exist or
be findable, and the evaluation builds with `-g -fno-omit-frame-pointer` so call stacks are
walkable. Threads must be pthreads: the delay accounting hangs entirely off interposing the
tables of blocking and waking POSIX calls, so a runtime with its own scheduler, green threads
or a custom suspend mechanism outside those tables breaks the correctness argument for
virtual speedup. A progress point must exist and must be visited often enough that a
fixed-length experiment sees at least five visits. Latency measurement additionally requires
the system to be stable in Little's Law's sense, arrival rate not exceeding service rate,
which the paper correctly notes is true of every usable system.

Accuracy where it can be checked. Two case studies allow the predicted and realized speedups
to be compared directly. Ferret: raising indexing-stage throughput by 27% was predicted at
21.4% program speedup and delivered 21.2%. dedup: fixing the hash function sped the
identified line by 96%, predicted 9%, delivered 8.95%. The toy example in Figure 1 is
predicted within 0.5%. Three data points, all from the authors, but they are honest ones.

Results: Memcached 9.39%, SQLite 25.6%, streamcluster 68.4%, fluidanimate 37.5%, ferret
21.3%, swaptions 15.8%, dedup 8.95%, blackscholes 2.56%, mostly in under ten lines of diff.
The SQLite case is the sharpest demonstration: the three lines Coz identified accounted for
0.15% of runtime under `perf`, and converting those indirect calls to direct calls was worth
25.6%. gprof segfaulted on SQLite outright, and on ferret its output was essentially
unchanged before and after a 21% speedup.

# Relevance

Read the mechanism before deciding this applies to us. Virtual speedup is *pause the other
threads*. Its entire reason for being is that in a concurrent program, time share and causal
impact diverge, and they diverge because of critical paths, queues between pipeline stages,
lock contention, barriers and I/O. Every case study in the paper is multithreaded, and the
three largest wins (streamcluster 68%, fluidanimate 37%, Memcached 9%) are contention, not
slowness.

`METHOD.md` commits us to serial-only measurement, enforced by rejecting any run whose
cpu-time over elapsed-time ratio exceeds 1.3. In a strictly single-threaded program there is
no divergence for Coz to find. The causal answer collapses to "fraction of time in the line
times the line speedup", which is what a flat sampling profiler already prints. Coz would
still be *correct* on such a program, since the accounting subtracts credited delays from the
effective duration whether or not any thread actually slept, but it would be an expensive way
to reproduce `perf record`.

On the ABCD question, see `# Notes`.

Where it would earn its keep for us: profiling *our compiler*, which is a normal Linux
application, with a progress point after each compiled top-level form. And later, if the
serial-only decision in `METHOD.md` is revisited once dedicated hardware makes the CCD
topology visible, causal profiling becomes the right tool for the parallel runtime and the
collector, because "which of my GC threads is actually on the critical path" is precisely the
question conventional profilers answer badly.

# Notes

**Bibliography correction.** Our planning documents cite this as "arXiv:1608.03676". The
arXiv posting is a postprint. The paper is SOSP 2015 (Monterey CA, October 4-7 2015, DOI
10.1145/2815400.2815409), and the copyright block inside the PDF says so. Cite the SOSP
version. Curtsinger's affiliation on this printing is Grinnell College, with a footnote that
the work was begun while he was a PhD student at UMass Amherst; Berger's affiliation is
printed as the College of Information and Computer Sciences, UMass Amherst, not the
Department of Computer Science as on the 2013 Stabilizer paper.

**Coz would only partly have answered the ABCD question, and it is worth being precise about
which part.** `METHOD.md` says causal profiling is how you learn in advance that removing 45%
of bounds checks buys only 10%. For the direct cost that is right: virtually speeding up the
check lines to 100% models their complete removal from the time budget, and would have shown
the ~10% ceiling before anyone wrote the pass. That is a real and useful pre-check, and it is
the conservative direction, so it will not talk you into a pass that cannot pay.

But the reason ABCD fell short was not that the checks were cheap to execute. Bodík, Gupta
and Sarkar attribute the gap to Jalapeño lacking the global code motion that check removal
was supposed to enable. Virtual speedup can only model *this existing instruction stream,
running faster*. It cannot model *this instruction disappears, and the scheduling barrier it
constituted disappears with it, and now the loop body vectorizes*. Enabling effects change
the code, not its speed, and they are invisible to an experiment that only inserts delays.
For a compiler pass whose value is mostly enablement, which is exactly what stages 06 and 10
are to each other, Coz measures the floor and cannot see the ceiling. The correct reading is
that causal profiling bounds the payoff of a pass that only *removes* work, and says nothing
about a pass that *unlocks* work.

The paper is careful about a subtle methodological point that is easy to miss and easy to get
wrong when reimplementing: both the line and the speedup amount must be chosen randomly, and
the tempting optimizations (ramp the speedup up until it stops mattering, prune lines that
looked flat) are both invalid, because a line's importance is not constant over a program's
lifetime.

The evaluation reports speedups with Efron's bootstrap for standard error and tests
significance with the one-tailed Mann-Whitney U test, explicitly chosen because it assumes
nothing about the distribution of execution times. Given that Stabilizer, by the same authors
two years earlier, exists to make that distribution known, the choice of a non-parametric
test here is a quiet admission that the Coz evaluation was not run under Stabilizer.
