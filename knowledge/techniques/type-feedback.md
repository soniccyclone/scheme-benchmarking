---
type: technique
title: Type feedback and guarded devirtualization
description: Records the operand or receiver types actually seen at a call site, then compiles the site as a type guard plus an inlined body with the general path split off into a non-merging copy; absorbs customization and message splitting as the static-specialization forms of the same idea.
tags: [type-feedback, guarded-devirtualization, customization, message-splitting, uncommon-branch]
sources:
  - resource: /works/h-lzle-ungar-optimizing-dynamically-dispatched-calls-with-.md
  - resource: /works/chambers-ungar-customization-optimizing-compiler-technolog.md
  - resource: /works/chambers-ungar-an-efficient-implementation-of-self-oopsla-.md
  - resource: /works/waddell-dybvig-fast-and-effective-procedure-inlining-sas-1.md
  - resource: /works/wegman-zadeck-constant-propagation-with-conditional-branch.md
  - resource: /works/cartwright-fagan-soft-typing-retrospective.md
implemented_by: []
absent_from: [/implementations/chez.md, /implementations/sbcl.md]
pipeline_stage: 10-vectorize
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

`(+ a b)` in Scheme is a dynamically dispatched operation on unknown operand representations,
exactly as `p->get_x()` is a dynamically dispatched call on an unknown receiver class. When
static analysis cannot prove the operand types, you still want the fast path compiled as
straight-line code. The question is how to get an unconditionally optimizable body out of a
merely probable fact, and what the guard costs.

# Mechanism

**The transformation.** A type profile is a list of receiver or operand types per call site,
optionally with frequencies. Compile the site as

```
if (p->class == CartesianPoint) { x = p->x; }        // inlined
else                            { x = p->get_x(); }  // dispatch, all other types
```

In SELF the profile was free, because polymorphic inline caches record receiver types as a side
effect of dispatching. Hölzle and Ungar are emphatic that this is incidental: a gprof-style
profiler suffices, the only gap being that gprof's data is caller-specific rather than
call-site-specific.

**Uncommon branch elimination is the mechanism that makes the guard useful rather than merely
correct.** Credited to John Maloney, first implemented in SELF-91:

```
if (p->class != CartesianPoint) goto uncommon_case;  // separate copy, never merges back
x = p->x;                                            // p's class known for the rest of the method
```

Without the non-merging copy, the optimized path's dataflow is polluted at the merge by the
pessimistic alias and kill information from the uncommon case, and the recovered type is lost
one statement later. This is the ancestor of deoptimization and it is the single mechanism
worth taking from this literature.

**Message splitting** is the static form of the same move, and it runs in the other direction.
Primitives have multiple exits: success with a known result type, failure with an unknown one,
and comparison primitives have separate true and false exits. Normally control rejoins and the
merged type is the least specific one, usually unknown. Splitting pushes the *following*
expression back through the merge point, producing one copy per incoming branch, each compiled
against that branch's specific type. On `0 = i ifTrue: [...]` the `ifTrue:` send gets three
copies (true, false, primitive-failure); the first two inline to compile-time constants and
vanish, so the boolean object is never materialized and control flow carries the result. This
is the direct answer to join-point information loss, and it is worth knowing it exists before
writing a join operator, because the abstract-interpretation literature presents widening as
the only option.

**Customization** is monomorphization keyed on run-time representation. Compile one machine-code
version of a source method per receiver map, usable only by that clone family, so the receiver's
type is a compile-time constant inside it. The `sumTo:` derivation is the worked example worth
reading: customization for integer receivers resolves and inlines `to:Do:`, then `to:By:Do:`, at
which point `1 = 0` and `1 < 0` constant-fold and collapse the guard structure of the general
iteration method, after which `ifTrue:False:`, `whileTrue:`, `loop`, `value` and `value:` all
inline because their receivers are compile-time constants. A cascade of sends through four
library methods becomes a loop with a register-allocated index.

**Static type prediction** is the floor: a hard-coded table saying `+`, `-` and `<` predict
integer and `ifTrue:` predicts boolean, justified by Ungar's Smalltalk measurements (90% and
100% respectively). Emit a tag test, then split. Costs almost nothing to implement once
splitting and inlining exist, and unlike Smalltalk's parser-level hardwiring it remains a
compiler bet the programmer can invalidate by redefining `+`.

**Recompilation policy, if you build the dynamic version.** Every unoptimized method has an
invocation counter in its prologue, decaying exponentially so the system measures invocation
*rates*. On overflow the recompiler does not recompile the method whose counter tripped: it
walks *up* the call chain and recompiles a caller that makes many calls to unoptimized or small
methods, or creates closures, because a hot method returning a constant should be inlined into
its caller. Replacement is on-stack. There is an effectiveness check: if the old and new
compiled methods have exactly the same set of non-inlined calls, the method is flagged and never
reconsidered. Inlining size estimates come from *previously compiled optimized code*, not from
source, because compiled size accounts for transitive inlining. The authors state directly that
the trigger ("when") mattered far less than the selection ("what").

# Preconditions

Low polymorphism per site, which is the same property that makes inline caching work. Measured:
1.08 type tests per inlined send, so nearly every optimized site had a single dominant type.
Sends with five or more receiver types are not inlined at all and stay as PIC dispatch, which
skews the remaining sends toward higher polymorphism (dispatch tests per send rises from 1.35 to
1.7). The whole technique rests on the empirical claim, taken from Garrett, Dean, Grove and
Chambers (1994), that type profiles are more stable across runs than time profiles.

It does *not* require dynamic compilation. The paper argues static profile-guided compilation is
easier, since you get a complete call graph and a complete profile instead of partial data
gathered while the program is still initializing; the only advantage a dynamic system retains is
adapting to phase changes.

It does require an IR that can express a duplicate which never merges back. Retrofitting that
onto a merge-based CFG is painful, which is the argument for building it in early.

# Cost

1.7x geometric mean over the same compiler with feedback disabled, 1.5x over SELF-91, 3.6x fewer
calls, calls down to about 5% of unoptimized. Code growth only 15 to 25%, sometimes negative,
because SELF methods are tiny and a dispatched call costs more instructions than the body it
calls. Total type tests down 27%, because inlining lets constant and type propagation reach into
the callee: each feedback guard removes 0.8 other type tests on average, with only rudimentary
dataflow.

The decomposition matters more than the total. Direct saving from eliminating call overhead is a
*minority* of the speedup: median 13%, mean 25% of total time saved. The bulk, median 45%, is
"other," meaning ordinary optimizations working better on larger method bodies. Inlining here is
an enabling optimization, not an end in itself. Increased register pressure and instruction cache
misses can make the "other" contribution negative, and it did on one benchmark.

Customization costs space, one compiled body per receiver type. Overcustomization is real:
DeltaBlue's code growth came from customizing constraint methods for three constraint types, not
from type feedback, which actually shrank it. Compile time in the 1989 system was 7 seconds for
roughly 900 lines and 3 seconds for Richards, which the authors conceded was too slow for their
interactive environment.

# Disagreements

**The commonly retold story names the wrong result.** "PICs give you type feedback and then you
inline" describes the 1991 ECOOP proof-of-concept, which achieved about 11%. The 1.7x reported in
1994 comes from the recompilation *selection* policy of walking up the call chain, plus on-stack
replacement, plus uncommon branch elimination. The inlining transformation alone is not the
result, and a project that implements only the transformation should expect the 11%.

**Whether you need a profile at all, or an analysis at all.** Waddell and Dybvig take a third
position against both static CFA and profiling: inline speculatively, then measure the *actual
optimized residual code* and abort when it gets too big. Their argument is that an offline
analysis has to estimate what subsequent optimization will do to an inlined body, and both
directions of error hurt, pessimism missing opportunities and optimism blowing up code size.
The numbers are hard to argue with. Jagannathan and Wright's polyvariant CFA took 110 seconds to
analyze `dynamic`; cp0 optimizes the whole program in 0.56 seconds with a better speedup and a
better code-size ratio. This does not contradict type feedback (cp0 has no profile and does not
devirtualize on operand representation), but it removes inlining-site selection as a reason to
want either a profile or a flow analysis.

**Whether inlining's enabling effect is real and additive.** Wegman and Zadeck, discussing
procedure integration, cite Richardson and Ganapathi finding that integration and optimization
together bought no more than the product of their separate benefits, against Ball and Appel and
Jim reporting positive results, and conclude that no single study settles it. Hölzle and Ungar's
median-45%-is-other is a measurement on the positive side of that question, and it is the best
one in this bundle, but it is one system.

**Same lab, five years, opposite conclusions about static analysis.** Chambers and Ungar in 1989
asserted type inference held little promise and built customization and prediction instead;
Hölzle and Ungar in 1994 measured SELF-91's iterative static type analysis performing no better
than no analysis at all. The 1994 measurement is the load-bearing one and belongs in
`type-recovery.md`'s disagreements, where it is the counter-evidence to our architecture. It is
recorded here as the reason this technique exists. Note also the caveat the authors volunteer:
SELF-93's back end was deliberately weak, which they say costs at least 10% on the measured
programs, so the reported speedups are conservative.

# For us

The paper's own conclusion names our case: languages with type-dependent generic operators, "e.g.
APL and Lisp."

Take uncommon branch elimination, not the profiling. Stage 10 requires every value in a
vectorizable loop body to be a proven unboxed f64 with no control flow in the body. When the
proof is only probable, the way to get an unconditionally vectorizable body is to hoist the
representation guard to the loop head and emit the general version as a separate copy that never
merges back into the optimized one. That is precisely this construction, and it belongs in the
core language early. Chambers and Ungar state the goal in terms that could be pasted into our
CUJ: split off entire sections of the control flow graph corresponding to the most common data
types, so that along those sections every variable's type is known and there are no run-time type
checks, with exceptional cases transferring control out to a more general section. That is stage
10's precondition list arrived at from the other direction.

Take customization as the shape of stage 08. Our storage classes (unboxed f64 in xmm, boxed
flonum, tagged fixnum, untagged loop index, tagged descriptor) are a small finite lattice, so
specializing a procedure per argument representation set is a bounded, tractable version of what
SELF did over an unbounded space of maps. The pattern is a specialized entry point whose prologue
checks representations, a general entry point, and a specialized body with no further checks.
Note that customization only ever helped sends to `self`; arguments and mutable slot contents
stayed unknown, and the authors named argument customization as their top open issue. Our version
is argument customization, so we do not get to inherit their measurements.

Take static type prediction as the control experiment. A table saying `+` is probably fixnum,
emit a guarded fast path, gets most of the win for none of the analysis. If the interval and
pentagon domains do not beat that by a clear margin on the benchmark kernels, they are not paying
for themselves, and we should learn that early rather than after stage 06.

Take the ordering lesson from the 27% type-test reduction: narrowing gets much cheaper after
inlining. Do not run stage 05 before inlining and then declare victory.
