# Optimization Escape Hatches: Common Lisp vs Scheme

Working document. Revision 3, 2026-07-29.

Revision 3 corrects the framing. The question is not "which implementation is
faster." It is whether Scheme ever standardized the optimization escape hatches
that let a *conformant* Common Lisp implementation reach C speed, and if not,
what a portable Scheme superset that did so would have to look like.

Revision 1 planned a ten-implementation port. Revision 2 cut it after finding that
Racket matches Chez on numeric code. Revision 3 demotes benchmarking to a
validation instrument for a language-design question.

---

## 1. The thesis being tested

Common Lisp reaches C speed because ANSI CL put the escape hatches *in the
standard*: `declare`, `declaim`, `the`, and the `optimize` qualities `speed`,
`safety`, `space`, `debug`. That is what lets SBCL trust a type assertion, elide a
bounds check, and select an unboxed register representation while remaining a
conformant implementation, and it is what lets the *user's tuned code* remain
conformant too. Verna's "How to Make Lisp Go Faster than C" (IMECS 2006, IJCS
32(4)) is the demonstration: add type declarations and set the optimization
policy, and SBCL matches or beats GCC on array-heavy numeric code.

The mechanism worth being precise about is that standardizing the notation does
two things at once. It obliges implementors to have an optimization story, and it
means code that uses that story does not fall off the standard. Revision 2 framed
"CL standardizes notation, not effect" as a weakness of the CL argument. That was
backwards. Standardizing the notation is exactly the trick, because the
alternative is what Scheme actually got: every implementation invents its own
syntax, and tuned code stops being portable the moment it is tuned.

So the question is whether Scheme ever did the same thing, and the answer turns
out to be more interesting than a flat no.

---

## 2. What the Scheme standards actually provide

Researched from primary sources rather than recalled. Two kinds of escape hatch
need separating, because they are not equivalent and Scheme's history treats them
very differently.

**Instructions** tell the compiler what to do at one site. `(fl+ a b)` means "add
these as flonums, here." **Premises** assert a fact the compiler's type inference
then propagates: `(declare (type double-float x))` licenses conclusions about
every downstream use of `x`, including bounds checks it can now prove redundant
and delete, and the derived return type of the enclosing function. Premises
compose through an inference lattice. Instructions do not compose, so a missed one
boxes the value and re-boxes everything behind it.

And there is a third thing, which is neither: a **policy switch** that says "you
may stop checking."

| standard | year | instructions | premises | policy switch |
|---|---|---|---|---|
| R5RS | 1998 | none | none | none |
| R6RS | 2007 | `(rnrs arithmetic fixnums)`, `(rnrs arithmetic flonums)`, `(rnrs arithmetic bitwise)` | none | none |
| R7RS-small | 2013 | **none, regressed** | none | none |
| R7RS-large Red | 2016 | none (data structures only) | none | none |
| R7RS-large Tangerine | 2019 | `(scheme fixnum)`, `(scheme flonum)`, `(scheme bitwise)`, `(scheme vector f64)`, `(scheme bytevector)` | none | none |
| SRFI 145 | 2016 | n/a | **`assume`** | none |
| ANSI CL | 1994 | none needed | `declare`, `declaim`, `the` | `(optimize (speed 3) (safety 0))` |

Details behind each row, since the shape of the history is the finding.

**R5RS has nothing at all.** No declarations, no type-specific operators, no
policy. It does mandate proper tail calls, which is a performance guarantee ANSI
CL never made, so on that one axis the standardization arrow points the other way.

**R6RS standardized the instruction-style hatches.** Verified from the spec:
`(rnrs arithmetic fixnums (6))` gives `fx+`, `fx*`, `fx-`, `fxdiv`, `fxmod`,
`fxand`, `fxior`, `fxxor`, `fxarithmetic-shift` and friends; `(rnrs arithmetic
flonums (6))` gives `fl+`, `fl*`, `fl-`, `fl/`, `flabs`, `flsqrt`, `flexp`,
`fllog` and the trigonometric and rounding operators; `(rnrs arithmetic bitwise
(6))` covers exact-integer bit twiddling. Fixnum operations "raise an exception
with condition type `&implementation-restriction` if the result is not a fixnum,"
which is the standard telling you these are the narrow fast path rather than the
generic tower. No declarations and no optimization qualities anywhere in it.

**R7RS-small went backwards.** It dropped the R6RS fixnum and flonum libraries
entirely. What remains that touches performance is bytevectors, which are the only
unboxed homogeneous aggregate and are `u8` only, plus `define-record-type` for
flat nominal records. So the most widely implemented Scheme standard has *fewer*
escape hatches than its predecessor.

**R7RS-large Red (2016) is data structures and does not help.** Verified against
the frozen ballot: SRFI 1, 13, 14, 41, 101, 111, 113, 116, 117, 121, 124, 125,
127, 128, 132, 133, 134, 135. No fixnums, no flonums, no numeric vectors.

**R7RS-large Tangerine (2019) is the restoration, and it is the most important row
in the table.** Verified from the edition document: `(scheme fixnum)` is SRFI 143,
`(scheme flonum)` is SRFI 144, `(scheme bitwise)` is SRFI 151, `(scheme
bytevector)` is the R6RS bytevector library, and `(scheme vector @)` is SRFI 160,
which is where `f64vector` lives. That last one matters most, because SRFI 160
homogeneous numeric vectors plus SRFI 144 flonum operators is structurally the
same thing as CL's `(simple-array double-float (*))` plus declared double-float
arithmetic. The unboxed-storage half of the problem *is* standardized, as of 2019,
in a Scheme standard.

**SRFI 145 is the only premise-style hatch Scheme has, and it is in no ratified
edition.** `(assume obj message ...)` evaluates to `obj` if true and is an error
otherwise. The SRFI explicitly grants the optimization license in as many words:
"An optimizing compiler may deduce that `x` is an exact integer after the first
expression in the procedure body so may emit specialised monomorphic code," and it
"may also remove the whole test at the beginning of the procedure body because the
test has only one branch." Violating an assumption is undefined behaviour, which
the document compares directly to C's UB: "A program that, for some input, would
eventually evaluate `(assume #f)` is invalid and execution of it is an error
itself, so anything may happen." That is `declare` in spirit, expressed as an
assertion over arbitrary predicates rather than over a fixed type language. It is
in neither Red nor Tangerine.

**No Scheme standard has ever had a policy switch.** This is the finding I am most
confident about and it is the sharpest part of the answer. Nothing in R5RS, R6RS,
R7RS-small, Red, Tangerine, or any SRFI I found provides an equivalent of
`(optimize (speed 3) (safety 0))`. Turning off checking is implementation-specific
folklore in every single Scheme: Chez `optimize-level 3`, Racket
`racket/unsafe/ops`, Gambit `(declare (not safe))`, Chicken `(declare (unsafe))`.
This is the one thing CL has that Scheme has never had at any point in its
standardization history.

### So: "no more portability once you optimize"?

Partially, and the boundary is specific enough to be useful.

If you target R7RS-large Tangerine you *can* write portable tuned numeric Scheme.
`(scheme flonum)` gives monomorphic float arithmetic and `(scheme vector f64)`
gives unboxed float storage. That covers the two effects I expect to dominate on
float benchmarks, and it is portable, standard code.

What you cannot express portably is a premise or a policy. `assume` is orphaned
outside any edition, so type facts cannot be asserted for the inferencer to
propagate. And nothing at all can tell a conformant implementation to stop
checking, so `fl+` in a safe implementation is still entitled to verify its
arguments are flonums, and `f64vector-ref` is still entitled to bounds-check.

That gives a precise prediction: **portable Tangerine Scheme should close most of
the boxing and storage gap and none of the check-elision gap.** The residual
distance from there to implementation-specific tuned code is exactly the cost of
what the standards left out. That residual is a number we can measure, and it is
the quantitative answer to your question.

**The risk that would change everything: Tangerine may be largely unimplemented.**
A standard nobody implements is not an escape hatch. Whether Chez, Racket, Guile
and Gambit actually ship `(scheme flonum)` and `(scheme vector f64)`, as opposed to
having native `flvector` under a different name, is the first thing phase 1 checks.
If the answer is that almost nobody implements Tangerine, that is *also* an answer
to your question and a more damning one than the standards history alone.

Also flagged as unresolved: whether any edition after Tangerine has been ratified,
and whether SRFI 145 was ever docketed for one. The process notes say many
docketed proposals are "stalled for lack of an implementation," which is
suggestive but not evidence about `assume` specifically.

---

## 2b. How other standards compare

Common Lisp is not the high-water mark. Ada is. This section ranks the standards
by how much optimization machinery each one puts in the document itself.

Three separate powers matter, and they are easy to confuse:

1. **Premises.** The program asserts a fact. The compiler propagates it.
2. **Policy.** The program tells the compiler to stop checking.
3. **Layout.** The program dictates the representation of data in memory.

| standard | premises | policy | layout |
|---|---|---|---|
| Ada | `Pre`/`Post`, `INTENT`-like modes | **`pragma Suppress`, 14 named checks, plus `Unsuppress`** | **bit-exact record clauses, `Size`, `Alignment`, `Component_Size`, `Bit_Order`, `Pack`** |
| ANSI CL | `declare`, `declaim`, `the`, `ftype`, `dynamic-extent` | **`(optimize (safety 0))`, one dial** | specialized array types |
| Fortran 2008+ | `PURE`, `ELEMENTAL`, `INTENT`, `CONTIGUOUS`, `DO CONCURRENT` | none in the standard | array storage rules, `SEQUENCE` |
| C++23 | `[[assume]]`, `noexcept`, `[[likely]]` | not needed | `alignas`, `[[no_unique_address]]` |
| C99+ | `restrict`, `register`, `inline`, `[static N]` | not needed | `_Alignas`, bitfields |
| Haskell 2010 | `INLINE`, `SPECIALIZE`, but non-binding | none | none |
| R7RS-large | none | none | SRFI 160 numeric vectors |

### Ada is the winner

`pragma Suppress` takes the name of a single check. The Ada Reference Manual lists
Access_Check, Discriminant_Check, Division_Check, Index_Check, Length_Check,
Overflow_Check, Range_Check, Tag_Check, Accessibility_Check, Allocation_Check,
Elaboration_Check, Program_Error_Check, Storage_Check, Tasking_Check, and
All_Checks. Ada 2005 added `pragma Unsuppress`, so a program can turn a check back
on inside a small region. Common Lisp offers one dial from 0 to 3. Ada offers
fourteen named switches and a way to scope each one.

The manual states the price directly: "If a given check has been suppressed, and
the corresponding error situation occurs, the execution of the program is
erroneous."

Ada also standardizes data layout far past what CL reaches. The standard defines
the aspects `Size`, `Object_Size`, `Alignment`, `Component_Size`, `Address`,
`Bit_Order`, `Storage_Size`, and `Pack`. Record representation clauses set the
exact bit position of every field. CL gives you specialized arrays such as
`(simple-array double-float (*))` and stops there. Ada lets you map a record onto
a hardware register.

Ada 2012 moved most of these pragmas to aspect syntax, so `pragma Inline` became
`with Inline`. The pragmas remain legal but the manual marks several as obsolescent.

### What CL still holds over Ada

`dynamic-extent` is the interesting one. It declares that an object does not
outlive the current block, which licenses stack allocation instead of heap
allocation. That is a lifetime premise, and few standards have anything like it.
CL also has `ftype`, which types a function rather than a variable, and feeds the
inference engine across call boundaries.

### Fortran is strongest for arrays

Fortran standardizes premises that C needs compiler flags for. `CONTIGUOUS`
(Fortran 2008) promises that an assumed-shape array or pointer target occupies
contiguous storage. `DO CONCURRENT` (Fortran 2008) promises that loop iterations
carry no interdependency, which is a portable license to vectorize or parallelize.
`PURE` and `ELEMENTAL` promise the absence of side effects. `INTENT(IN)`,
`INTENT(OUT)`, and `INTENT(INOUT)` state the data flow of every argument. The
non-aliasing rule for dummy arguments sits in the standard, which is the old
reason Fortran beat C on numeric code.

Fortran has no standard check-suppression pragma. Bounds checking is a compiler
flag in every implementation.

### C++ arrived at the same idea recently

C++23 added `[[assume(expr)]]`. The compiler assumes the expression is true and
never evaluates it. Violating it is undefined behavior. That is the same mechanism
as SRFI 145 `assume` and the same purpose as CL `declare`. C++23 also added
`std::unreachable()`. C++26 work on contracts continues, and the rationale paper
treats `[[assume]]` as the stopgap until contracts land.

C and C++ need no policy switch. Neither language promises checks, so nothing
exists to turn off. `restrict` in C99 is a true premise about aliasing, and the
optimizer propagates it much as SBCL propagates a type declaration.

### Haskell standardizes the notation and then disclaims it

The Haskell 2010 Report defines `INLINE`, `NOINLINE`, and `SPECIALIZE`. It then
says: "An implementation is not required to respect any pragma, although pragmas
that are not recognised by the implementation should be ignored." That is the
weakest useful form. The notation is portable and the effect is optional.

### The pattern that explains all of it

A standard can only offer a policy switch if it first required the checks. C and
C++ never promised checks, so they need no escape. Ada and CL both check by
default, so both had to supply an escape, and both did.

That produces four groups:

1. Unsafe by default, no switch needed: C, C++.
2. Safe by default, standard switch: **Ada, Common Lisp.**
3. Safe by default, switch exists only as a compiler flag: Fortran, Haskell.
4. Safe by default, no standard switch at any point in its history: **Scheme.**

Scheme is the anomaly. It shares group 2's safe-by-default semantics and group 4's
empty toolbox. Every other safe-by-default language in this table either
standardized the escape or leaves checks to compiler flags that nobody pretends
are portable. Scheme mandates the checks and then supplies no standard words for
declining them. That is the gap this project measures.

---

## 3. Could we build the superset?

Yes, and the more useful observation is that five Schemes already did, mutually
incompatibly, which is the strongest available evidence that the standard failed
to meet a real need.

**Prior art.** Bigloo puts types in the syntax: `(define (f x::double)::double
...)`, with type-inference-driven unboxing behind it. Gambit transplanted CL's form
almost verbatim as `(declare (fixnum) (flonum) (not safe) (block) (inline))`.
Chicken has `(declare (unsafe))` plus a `:` type syntax and a local inference pass
called the scrutinizer. Typed Racket is a full gradual type system whose optimizer
genuinely uses the types for unboxing and arithmetic specialization. Stalin took
the opposite route, whole-program type inference with no annotations at all. Every
one of these is a reinvention of the same missing feature, and no two are
compatible.

**The fundamental constraint on a portable version.** A declaration is worth
exactly as much as the inference engine that consumes it. CL's `declare` is
powerful because SBCL has a type lattice, flow analysis, and a representation
selection pass behind it. A portable macro layer has no compiler to inform. It can
rewrite operators at sites it can see lexically, and that is all. So a macro-based
`(declare (type f64 x))` can get you monomorphic operator selection, which SRFI
143 and 144 already give you more verbosely, and it cannot get you check elision or
cross-procedure type propagation, because those live in the compiler and no
standard obliges the compiler to cooperate.

That is the real asymmetry, and it is a sharper version of your point. CL did not
merely standardize notation. By standardizing it, CL *told implementors they needed
an optimizer to hang it on*, and the good ones built one. Scheme never issued that
instruction, so the inference engines that exist (Bigloo's, Stalin's, Chicken's
scrutinizer, Typed Racket's) are each attached to private syntax.

**What is actually buildable, in order of ambition.**

The honest version is a portable compatibility layer: CL-flavoured surface syntax
over Tangerine plus `assume`, expanding to `(scheme flonum)` and `(scheme vector
f64)` operations where available, to `assume` where the implementation honours it,
to native hatches where we can detect them (Chez `optimize-level`, Racket unsafe
ops, Gambit `declare`), and to plain portable code where nothing is available. It
degrades correctly and it is real R7RS, since macros are standard. Its ceiling is
the ceiling described above.

The ambitious version is a lexical type propagator written as a `syntax-case`
macro that walks a whole procedure body, propagates declared types through `let`
bindings and arithmetic, and selects the monomorphic operator at each site
automatically instead of making the human do it. This is where it stops being
plumbing and becomes interesting, because it is a small type inferencer running at
expansion time, and it recovers the *composability* of premises without needing
the host compiler's cooperation. It still cannot elide checks. Worth knowing that
the boundary of what expansion-time inference can recover is, as far as I know,
not well explored, and that is the genuinely novel part of this project.

The thing not to build is a new implementation. The point is a portable layer over
existing ones.

---

## 4. The experiment

One program, six configurations, each step isolating exactly one standards-level
feature. This is now validation for section 2's prediction rather than a
benchmarking project in its own right.

**Program: nbody.** Serial in every published entry so no thread confound, pure
double-float over a small fixed working set so it isolates boxing and storage
cleanly, and the program both Pecsek and Smith used so there are external numbers
to sanity-check against.

| # | configuration | what it isolates |
|---|---|---|
| 1 | portable R7RS-small, generic arithmetic, `vector` | the floor: no hatches exist |
| 2 | R7RS-large Tangerine: `(scheme flonum)` + `(scheme vector f64)` | what portable tuned Scheme can do today |
| 3 | Tangerine + SRFI 145 `assume` | what the orphaned premise hatch is worth |
| 4 | implementation-specific max: Chez `optimize-level 3`, Racket unsafe ops | the folklore ceiling |
| 5 | SBCL, `declare` + `(safety 0)`, scalar, no `sb-simd` | tuned conformant CL |
| 6 | `gcc -O2 -fno-tree-vectorize`, and `-O3 -march=native` | scalar and vectorized reference |

The deltas are the results, and each one answers a specific question. 1 to 2 is
what Tangerine bought Scheme. 2 to 3 is what ratifying `assume` would buy. 2 to 4
is the cost of the missing policy switch, which is the number that answers your
question. 4 to 5 is whether CL's inference beats Scheme's hand-written
instructions once both sides are maximally tuned. 5 to 6 is Verna's claim,
re-run on 2026 hardware.

Run configurations 1 through 4 on both Chez and Racket, since revision 2's data
says they are within 15% on numeric code and any large divergence here would be a
finding in itself.

**SIMD is out of scope**, deliberately. The fast Benchmarks Game and PLB Common
Lisp entries use `sb-simd` (verified: `grep -rl sb-simd` hits nbody 3 through 6
and spectral-norm 2 through 7 in the PLB tree, with Bela Pecsek's attribution and
"Based on 2.zig" headers). That is why configuration 5 excludes it. You are right
that a portable Scheme SIMD library is writeable, and it is a separate project;
mixing it in here would confound the standards question with an intrinsics
question. Noted in section 7 as a follow-on.

---

## 5. Supporting evidence already gathered

Kept from revision 2 because it constrains the design, compressed because it is no
longer the point.

**The Debian Benchmarks Game is frozen and is not evidence about tuned
performance.** Verified from the corpus: SBCL 2.4.8, Racket v8.15, README saying
"STOPPED. Updates will be infrequent" and "The Python measurement scripts are
__OBSOLETE__ and __NO LONGER MAINTAINED__." Its published SBCL/Racket gap runs
1.7x to 3.2x, but both sides are untuned to unknown and unequal degrees, and the
maintainer declined further optimized submissions. Cite it as the thing being
explained, never mixed into our own tables. Its harness gets dropped in favour of
`hyperfine`, which its own README endorses by declaring the scripts obsolete.

**Racket matches Chez on numeric code, so implementation choice is not the
variable.** From `ecraven/r7rs-benchmarks` (live, last commit 2026-02-03, 26
implementations, `all.csv`), Racket 9.0 over Chez 10.3.0 across 56 benchmarks:
median 1.34, geometric mean 1.72, but the distribution is what matters. Every
numeric benchmark is within about 15%: mbrot 0.95, array1 0.94, sum 0.99, fft 1.02,
fib 1.04, fibfp 1.10, sumfp 1.17, simplex 1.08, nqueens 1.09. Racket CS runs on
Chez, so this holds codegen constant and varies only the runtime layer, and the
layer is nearly free on tight numeric code. Where Racket loses is call/cc (fibc
2.45, ctak 2.51, which is Chez's stack-segment continuations showing quality) and
I/O and reader work (cat 3.88, slatex 4.41, sum1 19.5, read1 26.7, where read1 at
26.7x is implausible as a real property of Racket's reader and is almost certainly
its R7RS shim).

The load-bearing caveat: that corpus runs *portable* R7RS with safety on and the
generic tower live. It measures each implementation's generic safe path, which is
configuration 1 in section 4. It says nothing about tuned ceilings. That is
precisely the gap section 4 exists to fill.

---

## 6. Machine, method, dependencies

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

**Dependencies.** Tier 1 is `sbcl chezscheme racket hyperfine unzip`, about 872 MB
resolved across 13 packages with `--no-install-recommends`. `sbcl` 2.6.0,
`chezscheme` 10.0.0, `racket` 8.18, `hyperfine` 1.19.0; gcc 15.2.0 is already
installed and covers configuration 6. Note our toolchains are newer than the frozen
corpus measured, which is fine for internal comparison and needs stating if the
numbers are ever printed alongside theirs.

`ecl` and `clisp` are worth 199 MB as a cheap control on section 1's thesis. If
tuned CL is fast under SBCL and slow under CLISP, which largely ignores
declarations, that demonstrates the standard obliges implementors to have a story
without guaranteeing they tell a good one. It sharpens the thesis rather than
undermining it, and it is the cheapest experiment here.

**The two verification gates before any number is trusted.** First, does any
implementation actually ship Tangerine's `(scheme flonum)` and `(scheme vector
f64)`? Section 2's whole argument depends on this and it may fail. Fallbacks are
the standalone SRFI 143/144/160 reference implementations, or native `flvector`
with a portability caveat attached to every result. Second, ahead-of-time
compilation per implementation, which is where naive comparisons go wrong: Racket
must go through `raco make` or it recompiles per invocation and looks
catastrophically slow for reasons unrelated to Racket, Chez needs `compile-program`
or it interprets, SBCL wants a saved core or at minimum a fasl. Acceptance
criterion for every configuration: the second run is not slower than the first, and
the time does not change when the source mtime is touched.

**Corpora already fetched**, parked in the scratchpad so nothing refetches: the
Benchmarks Game clone (60 MB, program sources in
`public/download/benchmarksgame-sourcecode.zip` as 1106 files with output
fixtures, per-entry flags only in `public/program/*.html`), `r7rs-benchmarks`, and
`plb`. Upstream programs carry per-program BSD-style licenses with attribution
requirements, so preserve headers.

---

## 7. Phases

**Phase 1, the gate.** Install tier 1 plus `ecl` and `clisp`. Determine which
implementations actually provide Tangerine's `(scheme flonum)` and `(scheme vector
f64)`, and whether any honours SRFI 145 `assume` as an optimization license rather
than as a plain assertion. This single question determines whether section 4's
configurations 2 and 3 are measurable at all. Write and verify the AOT recipes.
Test `perf` counters.

**Phase 2, calibrate.** Real dev-N timings, fix the N table, establish the noise
floor by running one binary twenty times so we know how large a difference has to
be before it means anything on this machine.

**Phase 3, the six-way measurement.** Section 4, on Chez and Racket for
configurations 1 through 4. Produces the number that answers the question.

**Phase 4, the CL control.** Same tuned CL program under SBCL, ECL and CLISP.

**Phase 5, the superset.** Build the compatibility layer from section 3, starting
with the honest version. Validate by showing it reaches configuration 4's
performance from configuration 2's portable source. If that works, attempt the
expansion-time type propagator.

**Phase 6, write up.** The standards timeline in section 2 with the measured
deltas attached is a genuinely publishable artifact, and as far as I can tell
nobody has written it. Optional follow-on: portable Scheme SIMD, and exposing SIMD
to Chez, both of which are separate projects.

---

## 8. Open questions

**Is the deliverable the writeup or the library?** Phases 3 and 4 answer the
question and produce the timeline-plus-numbers artifact. Phase 5 produces a thing
people could use. I lean writeup first, because the measurement tells us whether
the library's ceiling is worth the effort, and because if Tangerine turns out to be
unimplemented then phase 5's shape changes completely.

**How much does the expansion-time propagator matter to you?** It is the novel part
and it is also the part most likely to eat a week. The honest compatibility layer
is a weekend.

**Should R6RS implementations be in scope?** R6RS standardized the fx/fl operators
in 2007 and R7RS-small dropped them, so R6RS Schemes (Larceny, Ypsilon, Mosh,
Sagittarius, IronScheme, and Chez in R6RS mode) had a portable tuned numeric path
for twelve years that R7RS users did not. Including one would let us measure
whether that path was actually faster in practice, which speaks directly to
whether standardizing instructions without a policy switch accomplishes anything.
I think this is worth one implementation, and Chez can do it without adding a
dependency.

**Do you want the SIMD question kept out?** I scoped it out to keep the standards
question clean, but you raised it and you may want it in. My view is it is a strong
follow-on precisely because it is orthogonal: a portable Scheme SIMD library over
SRFI 160 storage would be a real contribution, and it is a different paper.
