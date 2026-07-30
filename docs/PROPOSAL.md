# Optimization Declarations for Scheme: Prior Art and Design

Working document. Started 2026-07-29.

Companion to `PLAN.md`. That document asks whether Scheme standardized the
optimization escape hatches Common Lisp has. This document surveys who has already
tried, then designs what is missing.

---

## 1. Prior art

Searched the SRFI database (`srfi-common/admin/srfi-data.scm`), the R7RS-large
dockets, and the academic record. Grouped by which of the three powers each item
provides. `PLAN.md` section 2b defines the three: premises, policy, layout.

### 1a. Instructions (type-specific operators): crowded, and active right now

| item | status | what it gives |
|---|---|---|
| R6RS `(rnrs arithmetic fixnums)` and `(rnrs arithmetic flonums)` | standard, 2007 | `fx+`, `fl+` and the rest |
| SRFI 143 Fixnums | Final, in Tangerine as `(scheme fixnum)` | the R7RS-large version of the above |
| SRFI 144 Flonums | Final, in Tangerine as `(scheme flonum)` | same for floats |
| **SRFI 276 Type-specific Flonum Libraries** | **Draft, received 2026-06-23, deadline 2026-08-22** | reworks SRFI 144 for multiple float widths (binary16/32/64), operators prefixed `:` |
| SRFI 278 Supplemental Numerics | Draft | more numeric procedures |

SRFI 276 matters twice. It is live, so the comment window is open until 22 August
2026. And its rationale states the performance goal directly, that type-specific
procedures let a compiler emit a single hardware instruction. So the instruction
side of the problem has an active, competent working group. We should not duplicate
it.

### 1b. Premises and checking: well-trodden, and closer than I expected

| item | status | what it gives |
|---|---|---|
| **SRFI 145 Assumptions** | Final | `assume`. The only true premise. Explicitly licenses removing the check and emitting "specialised monomorphic code". Violation is undefined behavior. |
| **SRFI 253 Data (Type-)Checking** | **Final** | `check-arg`, `values-checked`, `check-case`, `lambda-checked`, `case-lambda-checked`, `define-checked`, `define-record-type-checked` |
| SRFI 273 Extensions to Data (Type-)Checking | Draft | extends 253 |
| SRFI 259 Tagged procedures with type safety | Final | procedure tagging |
| SRFI 92 ALAMBDA, SRFI 187 ALAMBDA and ADEFINE | both Withdrawn | argument checking, no optimization intent |

SRFI 253 is the closest prior art and I had not found it before. Its abstract says
"Data validation and type checking (supposedly) make for more correct code. And
faster code too, sometimes." It cites Common Lisp `check-type` and `the` as
inspiration, and it cites SRFI 145. Its `lambda-checked` attaches a predicate to
each parameter, which is structurally a type declaration at a procedure boundary.
Its `values-checked` is close to CL `the`.

The gap between SRFI 253 and a CL declaration is precise and worth stating.
SRFI 253 says an implementation "can turn these primitives into cheap and strong
type checks if need be." Cheap checks, not absent checks. The forms are checks by
design and they validate at run time. CL `declare` is an assertion the compiler
trusts, which lets it delete the check entirely. SRFI 145 `assume` does grant
deletion, but it takes an arbitrary expression rather than binding a type to a
variable for a scope, so nothing propagates.

### 1c. Layout: solved

SRFI 160 homogeneous numeric vectors, in Tangerine as `(scheme vector f64)` and
friends, plus R6RS bytevectors. This half of the problem is standardized and needs
no new work.

### 1d. Policy: nobody has ever proposed it

This is the finding. No SRFI, draft, withdrawn or final, proposes a way to turn off
runtime checks. No R7RS-large docket item does either.

One near-miss to rule out. SRFI 172 is titled "Two Safer Subsets of R7RS" and it
is not related. It sandboxes `eval` so a program can run code of doubtful origin.
That is a different meaning of the word safe. It restricts capability, not
checking.

So across roughly thirty years of Scheme standardization there is no proposal for
the one thing Ada and Common Lisp both have.

### 1e. The academic line, and why it failed

Worth knowing, because it tried to solve this and it lost for reasons that are not
about performance.

Soft typing is the relevant tradition. Cartwright and Fagan introduced it in 1991,
and Wright and Cartwright published "A Practical Soft Type System for Scheme" in
1994 and again in TOPLAS in 1997. The goal was exactly ours. A soft type system
infers types for a dynamically typed program and then, in the words of the
retrospective, "uses the types inferred by a soft type system to eliminate run-time
checks that are provably unnecessary." Rather than reject untypable programs, it
inserts checks only where it cannot prove them unnecessary.

It did not reach the standards. The reasons recorded in the retrospective and the
follow-on literature are about usability, not speed. Type systems built on
Hindley-Milner suffer an error-recovery problem, because a reported type error is
very hard to trace back to its cause. Inferred types grow unwieldy and become hard
for a person to read. And with no declarations in the source, a programmer gets no
help from tools.

Stalin took the other inference route, whole-program analysis with no annotations.
An earlier draft of this document dismissed it on the grounds that it had few
users. That was a bad argument and it is retracted. Adoption count says nothing
about whether a technique works, and Stalin's technique demonstrably works: it
reaches C-competitive numeric code and beats a current Chez by 2x to 4x on float
and array benchmarks. `PLAN.md` section 5a covers the machinery and the measured
profile in detail, and Stalin is now configuration 7 in the experiment.

What Stalin's numbers do show is a different limitation, and it is the one that
matters here. Its performance is bimodal. Where the flow analysis succeeds it
unboxes and wins by multiples. Where lifetime analysis cannot bound the data,
everything falls to the Boehm collector and it loses by 5x to 16x. Nothing in the
source tells you which case you are in.

Typed Racket is the modern successor. It works, its optimizer does use the types,
and it is a Racket feature rather than a portable one.

The lesson is the one Common Lisp encoded in 1994, and it is not about achievable
speed. Inference clearly reaches higher than declarations on the cases it handles.
Declarations win on *predictability*: a person writes one on purpose, reads it back
later, and owns the mistake when it is wrong, and the performance consequence is
local to the code you can see. That is what makes tuning an engineering activity
rather than a guessing game. So this design is declaration-first and treats
inference as an optional extra.

### 1f. Summary of the gap

| power | Scheme status |
|---|---|
| instructions | standardized and actively developed. Do not duplicate. |
| layout | standardized. Do not duplicate. |
| premises | partly there. `assume` grants deletion but does not bind or propagate. SRFI 253 binds but only checks. |
| **policy** | **never proposed by anyone.** |
| **propagation** | **never proposed by anyone.** |

Two gaps, then, not one. The missing policy switch, and the missing rule that a
declared type flows to the operations that use it.

---

## 2. What we would propose

Design sketch, not a finished specification. Reuse everything above and add only
the two missing pieces.

### 2a. The core idea

The value of a declaration is that you declare once and ordinary code gets faster.
Today a Scheme programmer who wants speed must write `fl+` and `f64vector-ref` by
hand at every single site, and one missed site reboxes the value and undoes the
work downstream. That is the human doing a compiler's job.

We want this instead:

```scheme
(define (kernel v n)
  (declare (v (f64vector-of flonum?))
           (n fixnum?)
           (suppress index-check))
  (let loop ((i 0) (acc 0.0))
    (declare (acc flonum?))
    (if (fx=? i n)
        acc
        (loop (fx+ i 1) (+ acc (* (f64vector-ref v i) 2.0))))))
```

Here `+` and `*` are the ordinary generic operators. Because `acc` and the vector
elements are declared flonums, a conforming implementation may compile them as the
flonum operations, keep `acc` unboxed in a register, and omit the bounds check on
`f64vector-ref`. The source stays portable. An implementation that ignores the
declarations still runs it correctly, only slower.

### 2b. Piece one: named check suppression

**Decision, ratified 2026-07-29: follow Ada, not Common Lisp.** Ada names each check
and lets a program re-enable one inside a region. CL offers a single `safety` dial
from 0 to 3, which conflates risks that deserve separate decisions.

The decision does not rest on the Ada manual reading well. `PLAN.md` configuration 8
measures GNAT with `pragma Suppress` on nbody for exactly this reason. If Ada with
checks suppressed does not approach scalar C, then per-check suppression buys less
than the manual implies and this section needs rewriting. Turning off a bounds check in a numeric
kernel is a bounded and auditable choice. Turning off type checks on data that came
from a network socket is not. A dial makes you buy both.

Proposed check names, deliberately fewer than Ada's fourteen:

- `index-check`, for sequence bounds
- `type-check`, for operator argument types
- `overflow-check`, for fixnum overflow to bignum
- `division-check`, for division by zero
- `arity-check`, for procedure arity
- `all-checks`

With `(suppress ...)` and `(unsuppress ...)`, both lexically scoped to the
enclosing body, and both usable as library-level declarations.

### 2c. Piece two: declarations that bind and propagate

Two design commitments.

**Predicates are the type language.** Not a new type syntax. `flonum?`, `fixnum?`,
`f64vector?` are already the Scheme way, and SRFI 145 and SRFI 253 both already do
this. It keeps the proposal small and it composes with SRFI 253's forms. A very
small set of parameterized predicates such as `(f64vector-of flonum?)` covers the
numeric cases we care about, and resisting further growth here is important.

**The specification says what an implementation may assume, never how.** It grants
permission and defines the undefined-behavior boundary. It mandates no analysis.
That keeps it implementable by a simple interpreter, which ignores everything, and
by an optimizing compiler, which uses everything.

The propagation rule is the actual new content. Roughly: within the scope of a
declaration binding a variable to a predicate, an implementation may assume the
predicate holds for that variable, may select a type-specific operation for any
primitive applied only to such variables, and may choose an unboxed representation.
Getting the wording right is most of the work of a real SRFI.

### 2d. Degradation, which is the part that makes it safe to standardize

The asymmetry matters. An implementation that ignores every declaration is slow and
correct. An implementation that trusts them is fast, and unsafe only if the program
lied. So the fallback direction is the safe one, and a portable program is never
broken by an implementation that does not participate. This is the same bargain
SRFI 145 and C++23 `[[assume]]` already make, and it is why undefined behavior on
violation is acceptable here.

### 2e. Relationship to existing SRFIs

Build on, do not replace. Storage comes from SRFI 160. Operators come from
SRFI 143, 144 and eventually 276. Arbitrary premises come from SRFI 145. Boundary
checking comes from SRFI 253, and `lambda-checked` is the natural place to attach
argument declarations. We add the policy switch, the binding form, and the
propagation rule.

---

## 3. Open problems

Honest list. Several of these could sink the design.

**Continuations.** If a program suppresses a type check and then captures a
continuation and re-enters with a different type, the assumption is void. Ada and
CL never had to solve this because neither has first-class continuations. This is
the hardest problem here and it may need the specification to say that suppression
and re-entrant continuations do not mix.

**Separate compilation.** Declarations at a library boundary need an export story.
CL has `declaim` and `ftype`. Whether SRFI 253's `define-checked` already gives us
enough is an open question.

**Predicate combinator scope creep.** `(f64vector-of flonum?)` invites a whole
contract language. Racket has one and it is large. Drawing the line early and
defending it is a design requirement, not a detail.

**Whether anybody implements it.** `PLAN.md` already flags that Tangerine itself
may be thinly implemented. A proposal nobody implements changes nothing. The right
sequence is to build the thing, measure the win on real code, and lead with the
number.

**Whether the win is real.** This is what the `PLAN.md` experiment measures. If the
gap between portable Tangerine Scheme and implementation-specific tuned code turns
out to be small, then the policy switch is not worth standardizing and this
document should be abandoned. Measure first.

---

## 4. Where optimization information comes from

Notes toward an eventual implementation, prompted by the question of how .NET got
fast and whether we should copy its "lowering" architecture.

### 4a. Correcting the model: lowering is not the optimizer

Roslyn's lowering phase runs at the end of the Binding phase, after type checking
has passed. It is semantics-preserving desugaring, not optimization. `foreach`
becomes an enumerator-driven `while` loop via `LocalRewriter_ForEachStatement.cs`.
`using` becomes `try`/`finally`. `async`/`await` becomes a state machine class.
`yield return` becomes an iterator state machine. Records get generated members.
Roslyn then emits fairly naive IL on purpose and does very little optimization.

Every optimization decision in .NET happens later, in RyuJIT. So "lowering" is the
wrong thing to borrow, and Scheme already has a better version of it. Macro
expansion is a user-extensible lowering pass, and the declaration forms in section 2
are exactly that: surface syntax lowered into core forms plus permissions.

### 4b. What actually makes .NET fast

Two things, and the order matters.

**The type system keeps representation information that Java throws away.** `struct`
is genuinely inline: no header, no pointer. Generics are reified rather than erased,
so the CLR instantiates a separate native specialization per value type and
`List<int>` is a flat array of ints. Java's `ArrayList<Integer>` is an array of
pointers to boxed Integers, because type erasure was forced on it by the need to
stay compatible with pre-Java 5 bytecode. Microsoft had no such legacy and changed
the runtime instead.

This is the same axis as our project. The question is whether representation
information survives to the point where a compiler can act on it. Java erases it and
asks the JIT to guess. C# keeps it. SBCL keeps it through declarations and
specialized array types. `(scheme vector f64)` keeps it. A boxed `vector` of flonums
throws it away and no amount of optimizer cleverness fully recovers it.

**RyuJIT then wins with information a static compiler cannot have.** Tier0 compiles
fast with instrumentation probes collecting block execution counts, type histograms
at virtual and interface call sites, and edge frequencies. Tier1 recompiles using
that profile. The headline optimization is guarded devirtualization: when the profile
shows one type dominating a call site, the JIT emits a type test and devirtualizes
and inlines on the hit path. The runtime design doc is explicit that static
compilation cannot do this, because static analysis has no data on which types
actually appear. Profile-guided inlining is described there as the biggest win.

.NET 9 and 10 added conditional escape analysis, which stack-allocates enumerators
once devirtualization and inlining prove they do not escape. That is Stalin's
lifetime analysis arriving in a mainstream runtime twenty years later.

### 4c. Three sources of optimization information

Naming them separately clarifies what we are choosing between.

| source | example | reliable? | cost to programmer | needs |
|---|---|---|---|---|
| declared facts | SBCL `declare`, Ada `pragma Suppress`, section 2 | yes, always honored | annotation effort | nothing |
| statically inferred facts | Stalin | no, bimodal | none | closed world |
| dynamically observed facts | RyuJIT dynamic PGO | mostly | none | JIT plus warmup |

The idea of a static analysis layer that inserts optimizations where it sees fit is
the middle row. `PLAN.md` section 5a measured what that alone produces: 2x to 4x
faster than Chez where the analysis succeeds, 5x to 16x slower where it does not,
and nothing in the source tells you which you got. The bottom row works well but
requires a JIT, and buys its wins precisely where static analysis is weakest, on
polymorphic dispatch.

### 4d. The architecture worth building: declaration-anchored local inference

Stalin's bimodality has a specific cause. It has nothing to anchor on, so it must
derive every type from a closed-world whole-program analysis, and wherever that
analysis loses precision the imprecision cascades. The closed-world requirement is
also what rules out separate compilation.

Declarations fix this, and not only by supplying facts the compiler must honor. They
supply *anchors that make inference tractable and local*. Given declared parameter
types at a procedure boundary, ordinary local flow analysis propagates through the
body with no whole-program analysis and no closed-world assumption. You get Stalin's
representation selection on the declared paths, you can reason about it by reading
one procedure, and separate compilation survives.

This is not speculative. It is what SBCL already does: IR1 derives types from
declarations by flow analysis, and IR2 selects representations from the derived
types. The model exists and is known to work. Scheme simply lacks the declarations
to anchor it, which is the whole subject of this document.

So the layering for an eventual implementation:

1. Declarations are the contract. Always honored, always predictable, the floor.
2. Local inference propagates from them. Anchored, so no closed world needed.
3. Opportunistic global analysis on top, strictly best-effort, never required for
   the declared performance. This is where a Stalin-style pass belongs.

Ordering matters and the .NET history argues for it. .NET got value types and
reified generics into the type system in 2005, and spent twenty years building
optimizers that exploit them. Dynamic PGO only became the default in .NET 8, in
2023. The representation decisions came first. The clever analysis came second and
took two decades. That is the case for getting the knobs specified before building
the analysis layer.

### 4e. Other .NET features worth stealing later

Hardware intrinsics, `Vector128<T>` through `Vector512<T>` plus platform-specific
classes, are a far more developed story than Java's still-incubating Vector API and
are the direct analogue of `sb-simd`. `Span<T>`, `ref struct` and `stackalloc` allow
allocation-free code without leaving the safe language. `[MethodImpl(AggressiveInlining)]`
and `[SkipLocalsInit]` are per-site policy attributes, which is the Ada model rather
than the CL dial. And `unsafe` with `fixed` is the ECMA-334 standardized escape
hatch, which puts C# in group 1 of `PLAN.md` section 2b's taxonomy.

A caveat on the framing that prompted this section. .NET is generally not as fast as
Rust. On compute-bound work it usually sits somewhere around 1.2x to 2x off, and the
gap is smallest on code written with structs and spans. What is true is that it got
dramatically closer than Java, and the reason is the type system decision in 4b
rather than JIT cleverness.

---

## 5. Sequence

1. Run the `PLAN.md` nbody experiment. Get the number for what the missing policy
   switch actually costs. Everything else waits on this.
2. Build the portable library from section 2 over existing SRFIs, with
   implementation-specific back ends for Chez and Racket.
3. Show it reaches implementation-specific tuned speed from portable source.
4. Only then write the SRFI, leading with the measurement.
5. Comment on SRFI 276 before 22 August 2026 if we have anything useful by then,
   which we probably will not, but the deadline is worth recording.

An optimizing Scheme implementation of our own is a much later step and should not
be started to prove a point about the standard. The point is provable with a
library over existing implementations, and that is a far cheaper experiment.
