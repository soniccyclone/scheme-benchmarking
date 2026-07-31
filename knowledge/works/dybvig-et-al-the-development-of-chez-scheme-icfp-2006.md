---
type: paper
title: "The Development of Chez Scheme"
description: Twenty-year retrospective on Chez Scheme, version by version, giving the reasoning behind display closures, stack-based control, the BiBOP/tagged hybrid, the fast register allocator, and the compile-time-payback rule that governs which optimizations exist at all.
resource: knowledge/sources/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.pdf
tags: [scheme, compiler-design, closure-conversion, register-allocation, generational-gc, procedure-inlining]
authors: [R. Kent Dybvig]
year: 2006
venue: "ICFP 2006, Portland, Oregon"
informs: [/techniques/closure-conversion.md, /techniques/stack-segment-continuations.md, /techniques/register-allocation.md, /techniques/procedure-inlining.md, /techniques/generational-gc.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Not a technique paper. It is the design rationale for the system we benchmark against,
written by the person who made every call, and it is the only place several of those calls
are explained rather than merely published. The value is in the *why not* as much as the
*why*: which optimizations were built and then thrown away, and on what criterion.

The single most important sentence in it, for our purposes, is the rule Dybvig and Hieb
adopted around Version 2:

> if an optimization doesn't make the compiler itself enough faster to make up for the cost
> of doing the optimization, the optimization is discarded.

Chez is bootstrapped, so the compiler is its own benchmark and its own beneficiary. An
optimization must pay for its analysis time out of the speedup it delivers to the compiler
compiling itself. That rule killed an early source optimizer outright and, per the paper,
"ruled out several optimizations we tried." It is the reason Chez's optimization set has the
shape it has.

# Mechanism

The version-by-version substance, in the order it was decided.

**Version 1 (1984), the two founding representation choices.** Profiling C-Scheme showed
time going to variable lookup and stack-frame creation. Diagnosis: the standard model
heap-allocates environments and call frames, which "made closure creation fast at the expense
of the more common variable references, and made continuation operations fast at the expense
of the more common procedure calls." Both were inverted:

- *Display closures* (flat closures): a heap-allocated vector holding a code pointer and the
  **values** of free variables, derived by Dybvig from the Algol 60 display of Randell and
  Russell. Cost moves from access to creation. Access is one memory reference; creation is
  proportional to the free-variable count. Closures also retain no more environment than they
  need, which helps the collector. Cardelli independently used a flat representation in ML.
- *Assigned-variable boxing*: any variable appearing on the left of a `set!` anywhere in its
  scope gets its value replaced by a pointer to a one-cell heap box. This is what makes flat
  closures sound (a value can be duplicated into several closures) *and* what makes stack
  allocation of locals sound, since a frame may be copied by a continuation capture. Access
  to an assigned variable costs two references instead of one; the paper's position is that
  `set!` is rare and should be.
- *Control*: stack for calls, capture by copying the stack into the heap, reinstatement by
  copying back. Cost of continuation ops becomes proportional to stack size; calls get cheap.

Also Version 1: a **code-pointer slot in every symbol** alongside the value slot, so a global
call is an unconditional indirect jump with no `procedure?` check. The slot initially points
at a trap handler that patches itself on first successful call. Dybvig explicitly declined to
extend this to multiple code pointers for arity dispatch, on four stated grounds, of which
the load-bearing one is that argument-count checks live at the entry point while type checks
live at every call site, and call sites are more numerous.

**Version 2 (1987).** Optimization levels as capability flags: level 1 buys time, level 2
assumes primitive names are bound to the primitives, level 3 generates unsafe code.
Destination-driven code generation replaces the peephole optimizer entirely. `case-lambda`
arrives, deliberately weaker than the original design, which would have removed lists from
the variable-arity interface. The compile-time-payback rule is instituted here.

**Version 3 (1989).** Stack copying replaced with the Hieb/Dybvig/Bruggeman **segmented
stack**: capture copies nothing, reinstatement copies a small constant (at most one frame),
normal calls and returns pay zero overhead, and stack overflow recovers automatically as long
as heap remains. A side effect worth stealing: with segmented stacks, "is this a tail call?"
becomes a pointer `eq?` on continuations, which is how the tracer distinguishes tail from
non-tail calls without an interpreter.

**Version 4 (1991), the overhaul.** BiBOP alone had become untenable: fixnum range was
carved out of virtual address space, and growing memories wanted both a bigger fixnum range
(for vector indices) and more address space (for the vectors). Resolution is a **hybrid**:
low tags on pointers, T-style, for specific type discrimination; BiBOP retained but now
segregating by *collector-relevant* properties (contains pointers, mutable, code vs data)
rather than by type. Fixnums go to 30 bits. Consequences that fall out:

- Single allocation area, therefore a single allocation pointer in a register, therefore
  inline allocation of pairs and closures.
- Intermediate code moves from lists to immutable **c-records** (compiler-specific record
  structures): smaller, cheaper field access, less dispatch overhead, statically checked
  shape at creation and dispatch sites.
- Flonums lose their forwarding-address space entirely. The collector never forwards a
  flonum; it may duplicate it. Legal because `eq?` on numbers may always return `#f`. That
  halves flonum size and lets an inexact complexnum be two adjacent doubles with pointer
  arithmetic for real/imaginary extraction, with no indirection and no allocation.
- Generational GC, five generations, generation 4 static. Default policy: collect generation
  *n* every 4^n collections. The paper is candid that this "rather arbitrary strategy was
  initially just a hack for testing, but it turned out to work well, indeed better than
  several more elaborate strategies we tried."
- **The register allocator.** Arguments move from stack to registers. Graph coloring was
  considered and rejected on two grounds: it offers no special help for calls, and its
  compile-time cost was unacceptable for incremental interactive compilation. The
  replacement: assign registers first to incoming arguments, then first-come-first-served over
  bindings found in a bottom-up pass from the AST leaves, using a cheap fixnum-bitwise live
  analysis over register values only. Then two refinements found from dynamic measurement,
  not theory: *lazy save*, where live registers are saved as soon as a call is inevitable but
  not before; and a *shuffler* at each call site that reorders arguments to cut saves and
  place values directly in outgoing locations. The shuffler subsumed Version 1's tail-call
  argument shifting.

Net for the overhaul: ~50% faster generated code and a 30% faster compiler, despite adding
register allocation passes.

**Version 5 (1994), local-call optimization.** Before this, a local call cost a `procedure?`
check plus an indirect jump through the closure, making local calls *more expensive than
global* ones. Fix: when an unassigned variable is bound by `let`/`letrec` directly to a
`lambda` or `case-lambda`, the compiler eliminates the `procedure?` check, jumps into the
body past the argument-count check (or straight to the right `case-lambda` clause), passes a
closure pointer only if there are free variables, and builds rest-argument lists at the call
site where the count is known. If a procedure is only ever called this way and has no free
variables, closure creation and the binding both vanish. Extra recognition: a group of
mutually recursive procedures whose closures exist only to hold each other's closures can be
collapsed. Worth 15-50% on benchmarks rewritten to use local calls, and 25% on the compiler
itself.

**Version 6 (1998), the inliner.** Jagannathan and Wright's flow-directed inlining ran as a
prepass to Chez and got results too good to ignore, but its analysis cost was impractical.
Ashley reimplemented it faster, still impractical. Waddell and Dybvig then built a **linear,
online** inliner that beat the flow-directed ones on some benchmarks. Two reasons given:
online transformation lets the inliner decide based on subexpressions it has already
transformed, whereas flow-directed analysis is entirely offline; and the stopping rule is not
a heuristic. It attempts every inlining and aborts the attempt when residual code size or
elapsed time crosses a fixed limit. "Heuristics inevitably inhibit or allow more inlining
than they should."

**Version 7 (2005), threads.** Earlier decisions pay off: BiBOP segments make per-thread
allocation areas trivial, and segmented stacks let each thread start small. The one hard
problem was the card-marking remembered set, since logging a mutation is not atomic and
synchronizing per mutation is unaffordable. Solution: a per-thread log of mutated locations
growing downward from the end of the local allocation area toward the allocation pointer.
Synchronization happens only when the two pointers meet.

# Applicability

This is a retrospective, so nothing here is a recipe with stated preconditions. The
transferable content is the decision structure, and it has two strong preconditions of its
own. First, **bootstrapping**: the payback rule only works if the compiler is written in the
language it compiles and is representative of the workload. Second, **interactive incremental
compilation as a hard requirement**. There was no interpreter in Versions 1 through 5, so
compile time is user-visible latency. Remove either and the whole optimization budget changes.

The paper gives essentially no numbers. There is one 50% figure for the Version 4 overhaul,
one 30% compiler-speed figure, a 15-50% range for local calls, and a 25x for gensym creation.
No benchmark tables, no methodology, no baselines. Do not cite it for measurements.

# Relevance

Direct, in three ways.

**It tells us where Chez's headroom is.** The payback rule systematically excludes any
analysis whose cost is not repaid by compiling the compiler faster. A Scheme compiler is not
a numeric kernel: it allocates, it calls, it pattern-matches, it does not run tight float
loops. So the entire class of optimization that helps float loops and nothing else (interval
and relational domains, induction-variable analysis, bounds-check elimination, vectorization,
our stages 5 through 10) is exactly the class the rule discards. That is our
opening, and it is structural rather than accidental. Chez is not slow at these things
because Dybvig missed them; it does not do them because they fail his acceptance test.

**It tells us what we must not regress.** Chez's baseline is genuinely fast on calls,
closures, allocation, and continuations, for concrete documented reasons: flat closures with
one-reference access, inline allocation from a register-held pointer, no `procedure?` check
on global or recognized-local calls, argument passing in registers with call-site shuffling,
and segmented stacks that make `call/cc` free at the capture point. If our compiler is slower
on a call-heavy benchmark, one of these is the reason, and each is independently affordable.

**The register allocator is a direct precedent for stage 12.** Dybvig rejected graph coloring
for a reason that also applies to us in reverse: we have chosen linear scan, which is the same
tradeoff. Two of his refinements are not in the linear-scan literature and are worth lifting:
lazy save (defer register saves until a call is inevitable) and call-site shuffling (place
argument values directly in outgoing locations). Both target call-heavy code, which is where
the Fortran-derived allocation literature is weakest and where Scheme lives.

Two smaller things to steal outright. The unforwarded-flonum trick (never leave a forwarding
address in a flonum, allow duplication, justify it by `eq?`'s licence on numbers) halves
flonum size and enables adjacent-double representations, which matters if we box at all. And
the c-record decision, immutable records with statically checked shapes for the IR, is the
same argument the nanopass framework makes at greater length.

# Notes

**Bibliography correction.** The slug says `dybvig-et-al`. The paper has **one author**,
R. Kent Dybvig (Indiana University and Cadence Research Systems). There is no "et al." The
title page is unambiguous. Suggest `dybvig-the-development-of-chez-scheme-icfp-2006`.

**Partial correction to the assignment framing.** The brief describes this paper as
explaining "why Chez optimizes for compile speed and therefore has no loop optimizer." The
first half is exactly right and is the payback rule quoted above. The second half is not
supported by the text: the Version 2 highlights list "optimizing letrec expressions and
loops" as an implemented feature, and Section 5 says the same in prose. Chez has *some* loop
handling. What the paper does not describe anywhere is a classical loop optimizer in the
Fortran sense: no induction-variable analysis, no strength reduction, no unrolling, no
bounds-check elimination, no vectorization, and no mention of any of these being attempted
and rejected. So the correct claim is weaker and still useful to us: the payback rule is a
general filter that such passes would not survive, and the paper is silent on them rather
than reporting their absence.

**Also worth flagging**, since a plan describing this paper may say otherwise: the paper is a
history of Versions 1 through 7 (1984-2005). It predates the nanopass rewrite entirely. Andy
Keep's dissertation compiler, which became Chez 9, is later work and is a different compiler
in the back end. Do not use this paper as a description of the Chez we are currently
measuring against without checking which version that is.

The candor is the best thing about it. Two admissions in particular are more instructive than
the successes: the 4^n generation-collection schedule was a testing hack that beat the
elaborate strategies, and the inliner's fixed size-and-time cutoff beat every heuristic they
tried. Both are the same lesson, that a crude limit measured against real workloads
outperforms a clever model of the workload. The register allocator's lazy-save strategy was
also found by measurement after the fact, not designed in.

One dated element: Section 7's rejection of graph coloring rests partly on 1991 compile-time
costs. Iterated register coalescing (George and Appel, 1996) and the SSA-chordality results
changed that calculus considerably. The "no special help for calls" objection, however, still
stands, and it is the one that matters for Scheme.
