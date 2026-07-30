# Phase 1 Results: The Tangerine Gate

Determined by reading implementation source, 2026-07-29. Not by probing. Both
implementations are open source and the question was answerable by reading them.

## Verdict: nobody implements Tangerine

Neither Chez Scheme nor Racket ships R7RS-large Tangerine's numeric libraries. The
standard is a dead letter seven years after it was assembled.

## Chez Scheme

Read from `cisco/ChezScheme` at commit `2026-06-10`, 35 MB shallow clone.

**No R7RS support of any kind.** A grep across every `.ss`, `.sls` and `.sps` file for
`(scheme base)`, `(scheme flonum)`, `(scheme fixnum)` and `(scheme vector` returns
nothing. The only occurrences of the string "r7rs" in the entire codebase are two
incidental comments, one in `s/read.ss:484` about R7RS boolean syntax and one in
`mats/6.ms:2060` noting that R7RS-style booleans are not R6RS.

**Full R6RS support, including both instruction-level hatches.** Shipped libraries
include:

```
(rnrs arithmetic bitwise)
(rnrs arithmetic fixnums)
(rnrs arithmetic flonums)
(rnrs base)
(rnrs bytevectors)
(rnrs chezscheme)
...
```

`(rnrs arithmetic fixnums)` and `(rnrs arithmetic flonums)` are exactly the 2007
standardized operator libraries that R7RS-small dropped.

**Native unboxed float storage.** `flvector` is a first-class primitive with a complete
set of operations defined in `s/5_1.ss`: `make-flvector`, `flvector-ref`,
`flvector-set!`, `flvector-length`, `flvector-fill!`, `flvector?`, plus
`flvector-pred`, `flvector*-pred` and `flvector-dispatch-table` internals. It appears
in `cptypes.ss` and `cptypes-lattice.ss`, which means the type recovery pass knows
about it, and in `cp0.ss`, the source optimizer.

**Native flonum operators.** `flsqrt`, `flabs`, `flfloor`, `flround` and the arithmetic
operators are primitives.

## Racket

Read from `racket/srfi`, 4.9 MB.

**The SRFI package tops out at SRFI 98.** Complete list of SRFIs shipped:

```
1 2 5 6 8 9 11 13 14 16 17 18 19 23 25 26 27 28 29 31 38 39
41 42 43 45 48 54 57 59 60 61 63 64 66 67 69 71 74 78 86 87 98
```

No SRFI 143 (fixnums), no 144 (flonums), no 145 (assumptions), no 160 (homogeneous
numeric vectors), no 253 (data type-checking).

**Native equivalents exist.** `racket/flonum` provides `flvector` and the `fl`
operators. `racket/unsafe/ops` provides unchecked variants including
`unsafe-flvector-ref`.

## How the r7rs-benchmarks corpus actually runs Chez

Worth recording, because it retroactively qualifies the numbers in `RESEARCH.md`
sections 3 and 4.

From `ecraven/r7rs-benchmarks`, the `bench` script, line 684:

```
time "${CHEZ}" --optimize-level 2 --compile-imported-libraries \
     --libdirs /home/nex/scheme/chez --program "$1" < "$2"
```

Three things follow.

First, Chez runs those benchmarks in R6RS top-level program mode via `--program`, with
`--libdirs` pointing at a hand-maintained local directory of shim libraries on the
author's machine. Chez's apparent R7RS support in that corpus is entirely a private
shim, not anything Chez ships.

Second, `--optimize-level 2`, not 3. So every Chez number quoted in `RESEARCH.md` is
safe-mode with checks on. The Chez-versus-Racket comparison remains fair, since both ran
safe. The Chez-versus-Stalin comparison understates Chez, because Stalin compiles with
its analysis fully applied while Chez was held at its safe default.

Third, the benchmark programs import only R7RS-small: `(scheme base)`, `(scheme write)`,
`(scheme time)`, `(scheme read)`, `(scheme file)`, `(scheme cxr)`, `(scheme char)`,
`(scheme inexact)`, `(scheme complex)`. Zero Tangerine imports anywhere in the corpus.
That corroborates the caveat already recorded in `RESEARCH.md` section 4: the corpus
measures each implementation's generic safe path.

## Consequences for the experiment

**Configuration 2 as originally specified is not writeable.** There is no
implementation on which `(import (scheme flonum) (scheme vector f64))` resolves. The
configuration has to be redefined.

**The portable path that actually exists is R6RS, not R7RS-large.** Chez ships
`(rnrs arithmetic flonums)` and `(rnrs arithmetic fixnums)`. Racket does not ship the
R6RS arithmetic libraries either, but Racket has native equivalents. So R6RS is the only
standardized instruction-level hatch with a real implementation behind it, and it has
been available since 2007.

**The finding is stronger than a measured delta.** The escape hatches were standardized
in R6RS in 2007, removed by R7RS-small in 2013, nominally restored by R7RS-large
Tangerine in 2019, and remain unimplemented by either leading implementation in 2026.
That is a more interesting result than any number this project was going to produce, and
it should lead the write-up.

## Still to determine at runtime

Reading source settled the library question. These need the installed toolchains:

- Whether SRFI 145 `assume`, where obtainable at all, is honored as an optimization
  license. Chez does not ship it and Racket does not ship it, so this may be moot.
- Whether packaged SBCL 2.6.0 includes `contrib/sb-simd` and detects AVX-512.
- Whether `perf` hardware counters work under this WSL2 kernel.
- The AOT recipes and the recompilation trap test.
