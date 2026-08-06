# Research Notes: Standards Survey and Measurement Evidence

Reference material. Not a phase. Everything here was gathered before any
measurement and is what the phased plan is built on.

Companion documents: `PLAN.md` for the overview and phase index, `PROPOSAL.md` for
the design, `METHOD.md` for machine and measurement setup.

---

## 1. What the Scheme standards actually provide

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

## 2. How other standards compare

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


---

## 3. How Stalin works, and what its numbers already show

Stalin deserves its own section because it is the strongest counterexample to
"Scheme is slow." It has almost no users, which is not evidence about the technique.
Stalin producing C-competitive numeric code is the relevant fact, and it makes Stalin
the ceiling that any declaration-based approach has to be measured against.

### The machinery

Stalin is a batch whole-program compiler by Jeffrey Mark Siskind that emits C.
Everything it does follows from one decision: it assumes a closed world, meaning it
sees the entire program at once and no code can be added later. That assumption is
what licenses the rest.

From Siskind's own announcement, the pass list is polyvariant interprocedural flow
analysis, flow-directed interprocedural escape analysis, flow-directed lightweight
CPS conversion, flow-directed lightweight closure conversion, flow-directed
interprocedural lifetime analysis, automatic inlining, unboxing, and flow-directed
program-specific and program-point-specific low-level representation selection and
code generation.

Two of those matter most for our question.

**Representation selection is the one that produces the speed.** Because the
analysis derives a precise type for every expression, Stalin picks the machine
representation per program point. A value known to be a double becomes a raw
unboxed C double with no tag and no header. This is the same thing SBCL's IR2
representation pass does, and the same thing `(scheme vector f64)` plus
`(scheme flonum)` approximate by hand. Stalin derives it instead of being told.

**Lifetime analysis decides where allocation goes.** Siskind's announcement says it
"automatically estimates the lifetime of data allocated at each allocation point"
and then chooses stack, region, or heap. Whatever it cannot bound falls to the
heap, and the heap is managed by the Boehm conservative collector.

That last detail is load-bearing, and it predicts the shape of Stalin's results.

### What the existing data shows

Extracted from `ecraven/r7rs-benchmarks` `all.csv`, the same corpus section 5 uses.
Stalin against Chez 10.3.0, on the 31 benchmarks both completed. Ratio above 1 means
Stalin is faster.

| benchmark | stalin | chez | chez/stalin | character |
|---|---|---|---|---|
| mbrot | 1.850 | 7.155 | **3.87** | float, mandelbrot |
| pnpoly | 1.540 | 4.319 | **2.80** | float, point-in-polygon |
| array1 | 2.590 | 5.783 | **2.23** | vector alloc and fill |
| paraffins | 2.990 | 5.494 | 1.84 | mixed |
| simplex | 1.190 | 2.174 | 1.83 | float, linear programming |
| ntakl | 2.670 | 3.990 | 1.49 | recursion on lists |
| primes | 0.640 | 0.921 | 1.44 | fixnum |
| ... | | | | |
| destruc | 8.950 | 1.878 | 0.21 | destructive list ops |
| sum | 16.550 | 2.649 | 0.16 | fixnum loop |
| graphs | 19.230 | 2.093 | **0.11** | heavy allocation |
| ack | 25.770 | 2.037 | **0.08** | deep non-tail recursion |
| divrec | 22.270 | 1.592 | **0.07** | recursive list division |
| diviter | 19.550 | 1.156 | **0.06** | iterative list division |

Median 0.77, geometric mean 0.63, range 0.06 to 3.87.

The distribution is bimodal and the mechanism explains it exactly. On float and
array code, where the analysis succeeds and representation selection can unbox,
Stalin beats a 2026 Chez by 2x to 4x. On allocation-heavy list code, where lifetime
analysis cannot bound the data and everything falls through to Boehm, Stalin loses
by 5x to 16x. Stalin's wins come from the analysis. Its losses come from the
collector it falls back to when the analysis runs out.

### The finding that matters for our design

**Whole-program inference is all-or-nothing, and you cannot tell from the source
which case you are in.** Where it works it is spectacular. Where it fails you fall
off a cliff, silently, with no annotation in the program to indicate which happened.

That is the same complaint the soft typing retrospective records, showing up as a
performance profile rather than as an error message. `PROPOSAL.md` section 1e
records the usability failure. This table is the performance shadow of it.

It argues directly for declarations over inference, and not on grounds of achievable
speed. Inference clearly reaches higher on the cases it handles. Declarations give
you *predictable and local* performance: you can read a procedure, see what was
asserted, and reason about what the compiler was permitted to do. That property is
what makes tuning an engineering activity instead of a guessing game.

### Caveats, stated plainly

Stalin 0.11 dates from October 2006 and is unmaintained. Chez 10.3.0 is current.
Comparing them on absolute time is unfair to Stalin by roughly twenty years of
compiler engineering, and the wins above are more impressive than they look for
that reason. The bimodal *shape*, though, is a property of the technique rather
than the vintage, and that is what we are drawing from it.

Stalin completed 33 of the 57 benchmarks. It failed 23 that Chez ran, including
`sumfp`, `fibfp`, `mbrotZ`, `matrix`, `ray`, `quicksort`, `bv2string` and
`chudnovsky`. That is a language coverage problem and not an optimizer limit:
Stalin targets full R4RS with minor omissions, and these are R7RS-era programs
using bytevectors, exactness features and libraries that postdate it by seven years
or more. Do not read the failures as "Stalin cannot optimize floats," because
`mbrot`, `pnpoly`, `array1` and `simplex` all ran and Stalin won all four.

Documented practical limitations: the compiler runs slowly, there is little or no
support for debugging, and the closed-world assumption rules out separate
compilation entirely. For our purposes none of that matters, because nbody is one
small file and we only want the number.

`stalin` 0.11-11build1 is packaged for Ubuntu 26.04. Porting nbody to its R4RS dialect is
mechanical: no `import`, no `define-record-type`, no bytevectors, `exact->inexact` instead of
`inexact`. The arithmetic expression order has to stay identical so the output still matches
the fixture.

---

## 4. Supporting measurement evidence

Kept because it constrains the design, compressed because it is no longer the point.

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

