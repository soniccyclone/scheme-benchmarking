---
type: paper
title: "Optimizing Dynamically-Dispatched Calls with Run-Time Type Feedback"
description: Feeds per-call-site receiver type profiles back into the compiler so any dynamic dispatch can be inlined behind a type guard, cutting SELF's call frequency 3.6x and run time 1.7x.
resource: knowledge/sources/h-lzle-ungar-optimizing-dynamically-dispatched-calls-with-.pdf
tags: [type-feedback, guarded-devirtualization, procedure-inlining, adaptive-recompilation, uncommon-branch]
authors: [Urs Hölzle, David Ungar]
year: 1994
venue: "PLDI 1994, Orlando FL, June 1994"
informs: [/techniques/type-feedback.md, /techniques/guarded-devirtualization.md, /techniques/procedure-inlining.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Type feedback: record the set of receiver types seen at each call site, hand that back to the
compiler, and compile the dispatch as a type test plus an inlined body, with the general
dispatch on the fall-through path. This is the transformation .NET, HotSpot and V8 all
implement, and this is where it comes from.

Two results in the paper matter more than the transformation itself, and both are routinely
lost in retellings. First, the direct saving from eliminating call overhead is a *minority* of
the speedup: median 13%, mean 25% of total time saved. The bulk, median 45%, is "other," meaning
ordinary optimizations working better on larger method bodies. Inlining here is an enabling
optimization, not an end in itself. Second, SELF-91's iterative static type analysis was worth
almost nothing on these programs. SELF-91 is only marginally faster than SELF-93 with feedback
disabled and no type analysis at all, and it performs about the same number of calls. Static
analysis of receiver types lost to a profile counter.

# Mechanism

A type profile is a list of receiver types per call site, optionally with frequencies. In SELF
it is free because polymorphic inline caches already record receiver types as a side effect of
dispatching. The paper is emphatic that this is incidental: a gprof-style profiler suffices,
the only gap being that gprof's data is caller-specific rather than call-site-specific.

The transformation on `x = p->get_x()`:

```
if (p->class == CartesianPoint) { x = p->x; }        // inlined
else                            { x = p->get_x(); }  // dispatch, covers all other types
```

Two optimizations make the guarded form pay. *Splitting* (Chambers and Ungar 1990) copies the
code following the `if` into both arms, which only helps for code close to the branch.
*Uncommon branch elimination* is the important one, credited to John Maloney and first
implemented in SELF-91: the guard jumps to a separate, less optimized copy of the code that
never merges back into the optimized version.

```
if (p->class != CartesianPoint) goto uncommon_case;   // separate copy, no merge back
x = p->x;                                             // and now p's class is known for the
                                                      // rest of the method
```

Without the non-merging copy, the optimized path's dataflow gets polluted by the pessimistic
alias and kill information from the uncommon case at the merge, and the type information is lost
one statement later. This is the ancestor of deoptimization, and it is the mechanism that makes
a guard useful rather than merely correct.

Recompilation policy in SELF-93. Every unoptimized method has an invocation counter incremented
in its prologue, decaying exponentially so the system measures invocation *rates*. On overflow
the recompiler does not recompile the method whose counter tripped. It walks *up* the call chain
and recompiles a caller that either makes many calls to unoptimized or small methods, or creates
closures, because a hot method that returns a constant should be inlined into its caller, not
optimized in place. The authors state directly that the trigger ("when") turned out to matter
far less than the selection ("what"). The earlier proof-of-concept with PIC-based inlining and
no such policy achieved only about 11%; the policy is what turns that into 1.7x.

Replacement is on-stack: the compiler marks a restart point, computes the live register contents
there, and if it succeeds the new optimized frame replaces several unoptimized frames at once.
This is the inverse of dynamic deoptimization. If it fails, the old activation finishes and only
subsequent calls use the new code. There is also an effectiveness check: if the old and new
compiled methods have exactly the same set of non-inlined calls, recompilation gained nothing and
the method is flagged so it is never reconsidered.

Inlining decisions are size-based, with the size estimate taken from *previously compiled
optimized code* rather than from source. In SELF nearly every source token is a message send of
wildly variable cost, and compiled code for a method already includes its own inlinees, so
compiled size is both more accurate and accounts for transitive inlining.

The back end is deliberately weak and the paper says so: no full dataflow analysis, no coloring
register allocator. Copy propagation within basic blocks plus globally for singly-assigned pseudo
registers, closure analysis, dead code elimination, a usage-count register allocator, single-pass
machine code emission. SELF-93 is 11,000 lines of C++ against SELF-91's 26,000.

# Applicability

The precondition is low receiver polymorphism per call site, the same property that makes inline
caching work. Measured: 1.08 type tests per inlined send, meaning nearly every optimized site has
a single dominant receiver. The paper leans on Garrett, Dean, Grove and Chambers (1994) for the
claim that type profiles are more stable across runs than time profiles, which is the empirical
assumption the whole technique rests on.

It does not require dynamic compilation. The paper argues static profile-guided compilation is
*easier*, because you get a complete call graph and a complete profile instead of partial data
gathered while the program is still initializing. The advantage a dynamic system retains is
adapting to phase changes.

Failure modes, stated by the authors: sends with five or more receiver types are not inlined and
stay as PIC dispatch, which skews the remaining sends toward higher polymorphism (dispatch tests
per send rises from 1.35 to 1.7). Increased register pressure and instruction cache misses can
make the "other" contribution negative, and it did on one benchmark. DeltaBlue's code growth
comes from overcustomization, not from type feedback, which actually shrinks it.

Numbers: 1.7x geometric mean over no-feedback, 1.5x over SELF-91, 3.6x fewer calls, calls down to
about 5% of unoptimized. Code growth only 15-25%, sometimes negative, because SELF methods are
tiny and a dispatched call costs more instructions than the body it calls. Total type tests down
27%, because inlining lets constant and type propagation reach into the callee: each feedback
guard removes 0.8 other type tests on average, with only rudimentary dataflow. 2.2x and 3.3x
faster than ParcPlace Smalltalk, 2.6x faster than Sun CommonLisp on Richards at full optimization
and minimum safety, 2.3x slower than GNU C++ -O2 with virtuals minimized but only 1.1x to 1.4x
slower with everything virtual.

# Relevance

The paper's own conclusion names our case explicitly: languages with type-dependent generic
operators, "e.g. APL and Lisp." Scheme's `(+ a b)` is exactly a dynamically dispatched operation
on unknown operand representations, and the guarded-inline transformation is the same.

The mechanism we need most is uncommon branch elimination, not the profiling. CUJ stage 10
requires every value in a vectorizable loop body to be a proven unboxed f64 with no control flow
in the body. When the proof is only probable, the way to get an unconditionally vectorizable body
is to hoist the representation guard to the loop head and emit the general version as a separate
copy that never merges back. That is exactly this construction, and it is worth building into the
core language early because retrofitting a non-merging duplicate onto a merge-based CFG is
painful.

The second thing to take is the ordering lesson from the 27% type-test reduction: narrowing gets
much cheaper after inlining, because constants and known representations flow into callee bodies.
Do not run stage 5 narrowing before inlining and then declare victory.

The third thing is uncomfortable and should be held rather than resolved. Our design bets on
static analysis reaching Common Lisp levels of optimization without profiles. This paper is the
strongest single piece of evidence against that bet, and it is not a rhetorical claim but a
measurement on nine real programs. The counter-argument is that SELF's problem was receiver
dispatch over an open, user-extensible object graph with dynamic inheritance, whereas ours is a
closed finite set of numeric representations that declarations plus predicate narrowing genuinely
do resolve. That counter-argument is plausible and unproven. It should be tested against nbody
before it is believed.

# Notes

The authors state that SELF-93's inferior back end (no delay slot filling, branches to branches,
repeated loads within a basic block, redundant type tests from the missing dataflow analysis)
costs at least 10% on the measured programs, so the reported speedups are conservative. That
qualifier is genuine, not modesty.

The frequently repeated version of this paper's story, "PICs give you type feedback and then you
inline," is the 1991 ECOOP proof-of-concept, which achieved about 11%. The 1.7x reported here
comes from the recompilation *selection* policy of walking up the call chain plus on-stack
replacement plus uncommon branch elimination. The inlining transformation alone is not the result.

Bibliography entry is accurate: Hölzle and Ungar, PLDI 1994, ancestor of .NET's guarded
devirtualization. Affiliations on the title page are Stanford CSL and Sun Microsystems
Laboratories. The paper is 11 pages including a data appendix.
