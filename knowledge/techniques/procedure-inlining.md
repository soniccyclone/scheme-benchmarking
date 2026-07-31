---
type: technique
title: Procedure inlining
description: Replacing a call with a specialised copy of the callee's body, decided online by attempting the transformation and measuring the residual against effort and size budgets; its value is mostly that it enables other optimizations, not that it removes call overhead.
tags: [procedure-inlining, partial-evaluation, online-transformation, guarded-devirtualization, pass-ordering]
sources:
  - resource: /works/waddell-dybvig-fast-and-effective-procedure-inlining-sas-1.md
  - resource: /works/h-lzle-ungar-optimizing-dynamically-dispatched-calls-with-.md
  - resource: /works/chambers-ungar-an-efficient-implementation-of-self-oopsla-.md
  - resource: /works/steele-rabbit-a-compiler-for-scheme-1978.md
  - resource: /works/steele-lambda-the-ultimate-declarative-1976.md
  - resource: /works/steele-sussman-lambda-the-ultimate-imperative-1976.md
  - resource: /works/leroy-unboxed-objects-and-polymorphic-typing-popl-1992.md
  - resource: /works/flanagan-sabry-duba-felleisen-the-essence-of-compiling-wit.md
  - resource: /works/keep-a-nanopass-framework-for-commercial-compiler-developm.md
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
implemented_by: [/implementations/chez.md, /implementations/sbcl.md]
absent_from: []
pipeline_stage: n/a
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

A Scheme program before inlining is a graph of small closures with no visible arithmetic.
Nothing downstream can see anything: there is no constant to fold, no range to derive, no
representation to choose. The engineering question is which calls to replace with the
callee's body, decided without an expensive analysis and without unbounded code growth.

The framing sentence to keep is Waddell and Dybvig's: **inlining is copy propagation extended
to lambda expressions.** In the same way that copy propagation enables constant folding,
inlining enables β-reduction.

# Mechanism

Chez's `cp0` is the reference implementation and it has four properties, each buying
something specific.

- **Online.** Inlining decisions see the results of constant folding, copy propagation and
  dead-code elimination performed by the same pass. Analysis and transformation are one pass.
- **Polyvariant.** Every call site is attempted independently, and the decision is made on
  the size of the body *specialised to that call site's arguments*, not on the size of the
  procedure.
- **Context-sensitive.** An expression is processed knowing whether its value, its truth
  value, or only its effects are wanted.
- **Demand-driven.** Call operands are not processed until the consuming context is known.

Shape: `I : Exp → Context → Env → Continuation → Store → Exp`, a source-to-source pass over
`const`, `ref`, `primref`, `if`, `seq`, `assign`, `lambda`, `letrec`, `call`. Contexts are
`γ ::= Test | Effect | Value | App(op, γ, lγ)`. An `App` context carries the operand
structure, the context of the *call itself* so an inlined body is processed in the caller's
context rather than in `Value`, and a store location for an `inlined` flag consulted when
residualizing. Operands `Opnd(e, ρ, le)` memoize through `visit`, so an argument is processed
at most once per context. Variables carry source flags `{ref, assign}` and residual flags;
`ref` drives dead-binding elimination, `assign` blocks copy propagation and inlining through
mutated variables.

The β-step is `fold` on a lambda in `App` context: bind a fresh `x′` to the operand, process
the body, then residualize three ways depending on whether `x′` ended up referenced and
assigned. Emitting `(call (lambda x′ e′) e₁′)` is just a `let`, so a failed specialisation
degrades into a binding rather than a rollback, and applicative order survives because the
inlined call is treated as the semantically equivalent `let` with operand effects
residualized at the call site.

**The three restraints are what make this terminate and stay linear.**

1. *Effort counter.* Advances on every call to `I`, set whenever an expression will be
   processed more than once. **Not reset for nested integrations** — resetting would make the
   pass nonlinear. A fixed number of source call sites times a bounded budget is linear in
   source size.
2. *Size counter.* Incremented per residualized form; exceeding the threshold aborts the
   attempt and residualizes the call. **No size limit is imposed when the operand's variable
   is referenced exactly once in the source**, because inlining a called-once procedure
   cannot grow the program.
3. *Cycle detection.* An outer-pending flag set by `copy` catches
   `((lambda (x) (x x)) (lambda (x) (x x)))`; an inner-pending flag set by `visit` catches
   `(letrec ((f (lambda () (f)))) (f))`. This matters beyond termination: catching a cycle
   early means the effort budget is spent on the call you were trying to inline rather than
   being burned by a recursive callee.

Abort is a non-local exit to where the counter was set. Flag sets are bit vectors.

**Recursive procedures**, two admission rules. Either no recursive call survives in the
residual — bind `f` to a fresh `f′` with *no operand*, forcing recursive calls to
residualize, then check whether `f′` ended up referenced; `(f 5)` first yields `(* 5 (f′ 4))`
and modest unfold counters complete it to 120 — or the body specialises to the call site,
which needs the *invariant* formals (unassigned, passed as themselves at every recursive
call), computable in linear time and cached in the operand.

**Estimating size differently.** Hölzle and Ungar take the size estimate from *previously
compiled optimized code* rather than from source, because nearly every SELF source token is a
message send of wildly variable cost, and compiled code already includes its own inlinees, so
compiled size is both more accurate and accounts for transitive inlining.

**Guarded inlining, when the callee is not statically known.** Hölzle and Ungar rewrite
`x = p->get_x()` as a type test plus the inlined body, with the general dispatch on the
fall-through path. Two supporting transformations make the guard pay: *splitting* copies the
code following the `if` into both arms, which only helps close to the branch; and *uncommon
branch elimination*, the important one, jumps to a separate, less optimized copy that **never
merges back**. Without the non-merging copy, the optimized path's dataflow gets polluted by
pessimistic alias and kill information at the merge and the type information is lost one
statement later. This is the ancestor of deoptimization and it is what makes a guard useful
rather than merely correct.

**Ancestry.** RABBIT's META-EVALUATE has the same shape thirty years earlier: source-to-source,
memoized by a `METAP` flag with incremental `REANALYZE1` to repair analysis slots after a
rewrite, beta-substituting when `PASSABLE` proves the effect sets commute, gated by a timid
size heuristic. Steele's argument for a tiny core is why inlining pays at all: over a small
basis a handful of transformations combine *multiplicatively*, so `(IF (AND P1 P2) X Y)`
collapses to good code through generic beta-substitution with no knowledge of `AND` anywhere
in the compiler. *Lambda: The Ultimate Declarative* makes the same bet at the data level —
`(CAR FOO)` compiles to one PDP-10 `HLRZ` given integration plus folding plus dead-code
elimination.

**Across compilation units.** Keep ch. 4: the expander leaves a breadcrumb node per export
and the source optimizer fills a mutable field on the library global when the result is a
copyable constant (not a pair, vector or record, since those must stay `eq?` to themselves)
or a free-variable-free procedure under a score limit measured **before** inlining, since the
call site is unknown. 24% on a symbolic math program with many small cross-library calls.

# Preconditions

Applicative order and effect sequencing must be preserved; that is what the
inlined-call-as-`let` treatment buys and why the algorithm cannot simply substitute operands.
Assignment tracking is required, since copy propagation and inlining must not cross a `set!`.
The input is deliberately not CPS-converted, since converting would exaggerate the apparent
benefit of inlining.

**ANF is not closed under the beta reductions inlining performs.** Substituting a `let`-bound
call into a nested position produces a term no longer in normal form, so an ANF compiler must
renormalize after inlining. CPS is closed under its beta rule. Flanagan et al. do not discuss
this and it is the main practical argument the CPS camp retained.

Free variables are the sharp edge. Chez inlines a procedure with free variables only when
those variables get eliminated during optimisation or when their scope already contains the
call site; in the second case inlining can *add* free variables to closures, and the authors
flag closure growth as an unresolved interaction.

# Cost

Linear in *source* size for a fixed effort bound, with the constant scaling with the bound: a
10x effort increase roughly doubles runtime. Iterating the pass rarely helps.

Absolute numbers are the argument. `cp0` optimises the whole of `dynamic` in 0.56 s;
Jagannathan and Wright's polyvariant CFA took 110 s to *analyse* the same program. Ashley's
1CFA exhausted 128 MB of core plus 100 MB of swap on `interpret`. Speedups reach 4.57x
(`lattice`), 2.45x (`graphs`), 2.7x (`conform`), and code size *decreases* for many programs.
SELF's profile is the other shape: 7 seconds to compile 900 lines of the Stanford benchmarks,
which the authors concede is "not yet fast enough for our interactive programming
environment."

Read the comparison tables with care. Table 5's baseline for Jagannathan and Wright is not
block-compiled while their optimizer effectively block-compiles, so the "non-block" columns
are the apples-to-apples ones. Table 6's times for `<0cfa` and `1cfa` are **analysis time
only** and exclude the inlining and simplification those analyses justify, which makes the
speed gap larger than the table shows.

**`nbody` is the one benchmark that regresses** (0.92-1.05 on the R4400). The authors
attribute it to cache effects from three-level nested array indexing, backed only by the
observation that it speeds up consistently on a Pentium Pro. That is a plausible story rather
than a measurement, and it is the only place the "no benchmark regresses" claim is doing any
work. It is also our headline benchmark.

# Disagreements

**1. What inlining is actually worth, and why.** Folklore says inlining removes call
overhead. Hölzle and Ungar measured it and the folklore is wrong: the direct saving from
eliminating call overhead is a *minority* of the speedup, median 13% and mean 25% of total
time saved. The bulk, median 45%, is "other" — ordinary optimizations working better on
larger method bodies. **Inlining is an enabling optimization, not a terminal one.** That
changes what you optimize for: the objective is to hand downstream passes a bigger body with
known constants, not to save a `call` instruction. It is corroborated from another direction
in the same paper, where total type tests fall 27% because inlining lets constant and type
propagation reach into the callee, each guard removing 0.8 other type tests on average with
only rudimentary dataflow.

**2. Whether representation decisions beat optimization.** RABBIT's own measurements, which
are less than its reputation suggests: compiled unoptimized over interpreted is 25x overall
and 17x excluding GC, while optimized compiled over unoptimized compiled is only **1.2x**
overall and 1.37x excluding GC. Consing barely moved, because the phase-2 closure analysis
had already eliminated most of it. The optimizer roughly doubles compile time and the
pairwise argument conflict check adds 20-30% on top. So in the first optimizing Scheme
compiler, the closure and representation analysis outperformed the optimizer by a wide
margin. Set that against Hölzle and Ungar's 1.7x from feedback-driven inlining plus a
recompilation policy, and against Keep's 3.6% average from the full modern closure optimizer
on Chez, and the honest reading is that neither layer dominates permanently. Whichever layer
is currently naive is the one that pays.

**3. Does inlining need a flow analysis?** Waddell and Dybvig say no, and worse than no: an
offline analysis has to *estimate* what subsequent optimisation will do to an inlined body,
and both directions of error hurt, since pessimism misses opportunities and optimism blows up
code size. Shivers' entire dissertation takes the opposite position, that the flow graph is
the prerequisite for the optimizations higher-order languages lack. Ashley settles the
pass-ordering half of it: inlining invalidates the flow information that justified it, so a
flow analysis has to be re-run afterward. The Chez retrospective confirms the practical
outcome — flow-directed inlining got results too good to ignore, twice, and was impractical
both times, before the online inliner beat it outright.

**4. Heuristic versus measured limit.** Waddell and Dybvig: "Heuristics inevitably inhibit or
allow more inlining than they should," so attempt every inlining and abort on a fixed
residual-size and elapsed-time limit. Chambers, Ungar and Lee's SELF-89 inliner used a fixed
bytecode-count cutoff and the authors themselves call it "not a very good algorithm." Dybvig
names this as one of two cases where a crude limit measured against real workloads beat every
clever model of the workload they tried.

**5. Static analysis versus profile feedback for selection.** Hölzle and Ungar found SELF-91's
iterative static type analysis worth almost nothing: SELF-91 is only marginally faster than
SELF-93 with feedback disabled and no type analysis at all, and performs about the same number
of calls. Static analysis of receiver types lost to a profile counter. They also report that
the trigger ("when to recompile") mattered far less than the selection ("what to recompile"):
the PIC-based proof-of-concept with no selection policy got about 11%, and walking *up* the
call chain to recompile a caller is what turns that into 1.7x. The counter-argument for us is
that SELF's problem was receiver dispatch over an open, user-extensible object graph, whereas
ours is a closed finite set of numeric representations. Plausible and unproven; test it
against `nbody` before believing it.

# For us

**There is no inlining stage in the CUJ pipeline, and that is a defect.** Stages 01 through
13 contain no inliner, no closure conversion and no assignment conversion, yet stages 05, 06,
08 and 10 each depend on inlining having run:

- Leroy: storage class assignment should run *after* inlining, because inlining either
  creates `wrap(unwrap(a))` redexes that cancel or gives the callee a more specific type.
  Inline everything and the program becomes monomorphic and gets optimal layout.
- Hölzle and Ungar: narrowing gets much cheaper after inlining. Do not run stage 05 before
  inlining and then declare victory on the interval domain.
- Waddell and Dybvig via Ashley: inline first, then analyse, and do not try to make an
  expensive analysis do double duty across an inlining boundary.

An inlining pass belongs between `04-declare` and `05-intervals`, with A-normalization re-run
after it, per Flanagan et al.

Three mechanisms transfer beyond the inliner itself:

- **The effort/size counter pair as the general shape for any speculative pass.** Attempt the
  transformation, measure the actual residual, abort on a budget, and get a linear-time
  guarantee from a fixed number of sites times a fixed budget. Stage `10-vectorize` wants
  exactly this structure.
- **Contexts.** `Test`/`Effect`/`Value` is the same distinction the interval transfer
  functions want. An expression processed for effect needs no range computed at all; one
  processed for test needs only a zero/non-zero verdict.
- **Uncommon branch elimination.** Stage 10 requires every value in a vectorizable loop body
  to be a proven unboxed f64 with no control flow. When the proof is only probable, hoist the
  representation guard to the loop head and emit the general version as a separate copy that
  never merges back. Build the non-merging duplicate into the core language early; retrofitting
  it onto a merge-based CFG is painful.

One warning about what the headline numbers mean. `lattice`'s 4.57x is mostly the complete
unfolding of a user-defined `memv` against short constant lists, which is the same shape as
the constant-length vector indexing our bounds-check work targets — good news. `nbody` is the
one benchmark `cp0` does not help, and it is the benchmark our milestones are written against.

Citation notes to carry: the `cp0` document is Indiana University CS Technical Report No. 484,
an expanded version of the SAS 1997 paper, not the LNCS 1302 proceedings text; sections 3 and
4 carry material the proceedings version compresses. Its reference [16] misdates Wegman and
Zadeck's TOPLAS constant-propagation paper as `3(2), 1991`; it is `13(2)`, April 1991.
