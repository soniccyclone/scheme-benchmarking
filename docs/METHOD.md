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

