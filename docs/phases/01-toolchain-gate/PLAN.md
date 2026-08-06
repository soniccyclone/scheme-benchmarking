# Phase 1: Toolchain and the Tangerine Gate

## Goal

Install every toolchain the experiment needs, then answer one question: does any
Scheme implementation actually provide R7RS-large Tangerine's `(scheme flonum)` and
`(scheme vector f64)`?

## Why this is first

The whole project assumes portable tuned numeric Scheme is expressible today. That
rests entirely on Tangerine being implemented somewhere. A standard nobody ships is
not an escape hatch.

If the answer is no, configurations 2 and 3 in `../../PLAN.md` are not measurable as
written, and both the experiment and `../../PROPOSAL.md` section 2 need reshaping. So
this is the cheapest available falsification of the premise and it runs before
anything else.

## Inputs

Nothing. This is the first phase.

## Work items

1. Install the measurement and Scheme toolchains: `sbcl chezscheme racket hyperfine`.
   Roughly 872 MB across 13 packages with `--no-install-recommends`.
2. Install the reference-point toolchains: `gnat-15` for Ada, `ecl` and `clisp` for
   the Common Lisp controls, `stalin` as optional.
3. Determine Tangerine support per implementation. For Chez and Racket, check whether
   `(scheme flonum)` and `(scheme vector f64)` are importable under each one's R7RS
   mode, and separately whether native equivalents exist (`flvector` and friends).
   Record what is native, what needs a portable SRFI shim, and what is absent.
4. Determine whether any implementation honors SRFI 145 `assume` as an optimization
   license rather than as a plain runtime assertion. Reading emitted code is the only
   reliable test here, since a conforming implementation may treat it as a no-op
   check either way.
5. Verify `sb-simd` loads on the packaged SBCL 2.6.0 and detects AVX-512. Only needed
   to confirm configuration 5 correctly excludes it, but cheap.
6. Write the ahead-of-time compilation recipes, one per implementation. Racket needs
   `raco make`, Chez needs `compile-program` or at minimum `compile-file`, SBCL wants
   a saved core or a fasl, GNAT needs `gnatmake`, Stalin compiles through C.
7. Test whether `perf` hardware counters work under this WSL2 kernel. A `cpu` PMU node
   exists and `perf_event_paranoid` is 2, so it may. Do not block on it.
8. Write the nbody reference variant and pin the initial conditions and expected
   energies. We vendor no upstream sources; see `../../METHOD.md`'s correctness oracle.

## Acceptance criteria

- Every toolchain in `../../METHOD.md`'s dependency table is installed and reports a
  version.
- A written answer to the Tangerine question, per implementation, with evidence.
- For every configuration, the second run is not slower than the first, and the
  reported time does not change when the source file's mtime is touched. This is the
  test that catches accidental recompilation, which is the single most common way a
  benchmark of this kind goes wrong.
- A yes or no on `perf` hardware counters.

## Risks

**Tangerine is thinly implemented or absent.** The most likely bad outcome. Fallbacks,
in preference order: use the standalone SRFI 143, 144 and 160 reference
implementations; or use each implementation's native unboxed float vector with a
portability caveat attached to every number that comes out of it. Either way, record
the finding prominently, because "the standard exists and nobody ships it" is itself
an answer worth publishing.

**Racket recompiles per invocation.** Without `raco make` Racket looks catastrophically
slow for reasons that have nothing to do with Racket. The mtime check in the acceptance
criteria exists to catch this.

**`perf` counters do not work.** Annoying, not blocking. Fall back to reading emitted
code, which is the ground truth for this kind of question anyway.

## Outputs

- Installed toolchains.
- `../../METHOD.md` updated with what was actually found, replacing what was predicted.
- A per-implementation AOT recipe, checked in, that later phases call.
- The Tangerine support matrix.
