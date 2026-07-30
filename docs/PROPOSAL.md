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

## 4. Sequence

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
