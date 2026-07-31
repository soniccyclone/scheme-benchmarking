---
type: paper
title: "Fast and Effective Procedure Inlining"
description: Chez Scheme's cp0 — an online, polyvariant, context-sensitive, demand-driven source-to-source inliner that runs in linear time and matches or beats offline flow-directed inlining while being two to three orders of magnitude faster.
resource: knowledge/sources/waddell-dybvig-fast-and-effective-procedure-inlining-sas-1.pdf
tags: [procedure-inlining, partial-evaluation, online-transformation, chez-scheme, copy-propagation]
authors: [Oscar Waddell, R. Kent Dybvig]
year: 1997
venue: "Indiana University CS Technical Report No. 484; expanded version of the paper presented at SAS 1997"
informs: [/techniques/procedure-inlining.md, /techniques/closure-conversion.md, /techniques/type-feedback.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The prevailing view in 1997 was that good inlining for higher-order languages required a
polyvariant control-flow analysis to decide where to inline. Waddell and Dybvig show the analysis
is unnecessary and, worse, counterproductive: an offline analysis has to *estimate* what
subsequent optimisation will do to an inlined body, and both directions of error hurt — pessimism
misses opportunities, optimism blows up code size. Their algorithm instead inlines speculatively
and measures the actual optimised residual code, aborting when it gets too big. Analysis and
transformation are the same pass.

The numbers make the case. Jagannathan & Wright's polyvariant CFA took 110 seconds to analyse
`dynamic`; this algorithm optimises the whole program in 0.56 s and gets a better speedup and a
better code-size ratio. Ashley's 1CFA exhausted 128 MB of core plus 100 MB of swap on `interpret`.
Speedups reach 4.57x (`lattice`), 2.45x (`graphs`), 2.7x (`conform`), with no benchmark regressing,
and code size *decreases* for many programs.

The framing sentence is the one to remember: **inlining is copy propagation extended to lambda
expressions**, in the same way that copy propagation enables constant folding, inlining enables
β-reduction.

# Mechanism

Four properties, each buying something specific.

- **Online** — inlining decisions see the results of constant folding, copy propagation, and
  dead-code elimination performed by the same pass.
- **Polyvariant** — every call site is attempted independently, and the decision is made on the
  size of the body *specialised to that call site's arguments*, not on the size of the procedure.
- **Context-sensitive** — an expression is processed knowing whether its value, its truth value,
  or only its effects are wanted.
- **Demand-driven** — call operands are not processed until the context that consumes them is
  known.

**Shape.** `I : Exp → Context → Env → Continuation → Store → Exp`, a source-to-source pass over a
core language of `const`, `ref`, `primref`, `if`, `seq`, `assign`, `lambda`, `letrec`, `call`.
Presented as a CPS interpreter with an explicit store; implemented in direct style, using
one-shot continuations for the abort path.

**Contexts** `γ ::= Test | Effect | Value | App(op, γ, lγ)`. An `App` context carries the operand
structure for the argument, the context of the call *itself* (so an inlined body is processed in
the caller's context, not in `Value`), and a store location for an `inlined` flag consulted when
residualizing.

**Operands** `Opnd(e, ρ, le)` — the unprocessed argument plus the environment that closes it, with
`σ(le)` caching the residual code or `unvisited`. `visit` memoizes, so an argument is processed at
most once per context.

**Variables** `Var(x, op, s, lx)`: `op` is the operand bound to this variable (from an inlined
formal or a `letrec` binding, `null` otherwise); `s ⊆ {ref, assign}` are source-program flags;
`σ(lx)` are residual-program flags. `ref` drives dead-binding and dead-assignment elimination;
`assign` blocks copy propagation and inlining through mutated variables. `ρ` renames bound
variables to fresh ones so duplicated code cannot capture.

**The β-step** is `fold` on a lambda in `App` context:

    fold (lambda x e) App(op,γ₁,lγ) ρ κ σ = I e γ₁ ρ₁ κ₁ σ₁
      where x′ fresh, bound to op, inheriting x's residual flags as its source flags
            ρ₁ = ρ[x ↦ x′]
      and after processing the body:
            if ref ∉ σ₂(lx′) and assign ∉ σ₂(lx′) → visit op for Effect, emit seq(op′, body′)
            if ref ∉ σ₂(lx′) and assign ∈ σ₂(lx′) → visit op for Effect, emit a let
            otherwise                            → visit op for Value,  emit a let

Emitting `(call (lambda x′ e′) e₁′)` is just a `let`, so a failed specialisation degrades into a
binding rather than a rollback. Applicative order is preserved because the inlined call is treated
as the semantically equivalent `let`, with operand effects residualized at the call site.

**Contexts doing real work.** `(seq e₁ e₂)` processes `e₁` for `Effect`, where constants, primrefs,
lambdas, variable references, and effect-free primitive calls all collapse to `void`.
`(if e₁ e₂ e₃)` processes `e₁` for `Test`, folds when the residual guard's result is constant, and
also collapses when both branches residualize to the *same* constant — which happens more than you
would guess, because `Test`/`Effect` flattening manufactures such cases: `(let ((x 3)) (if (and
(read) (= x 0)) e₁ e₂))` reduces to `(seq (read) e₂)`.

**Restraints (§3)** — the three mechanisms that make this terminate and stay linear:

1. *Effort counter.* Advances on every call to `I`; set whenever an expression will be processed
   more than once, i.e. on each inlining attempt. **Not reset for nested integrations** — resetting
   would make the pass nonlinear. Since the number of source call sites is fixed and each gets a
   bounded budget, total time is linear in source size.
2. *Size counter.* Incremented on each residualized form; exceeding the threshold aborts the
   attempt and residualizes the call. **No size limit is imposed when the operand's variable is
   referenced exactly once in the source**, because inlining a called-once procedure cannot grow
   the program (except when procedural arguments to it get inlined).
3. *Cycle detection.* An "outer-pending" flag set by `copy` catches recursive references while
   inlining a procedural operand — `((lambda (x) (x x)) (lambda (x) (x x)))`. An "inner-pending"
   flag set by `visit` catches recursion inside an operand — `(letrec ((f (lambda () (f)))) (f))`.
   This matters for more than termination: detecting a cycle early means the effort budget is spent
   on the call you were actually trying to inline, instead of being burned by a recursive callee
   and taking the whole attempt down with it.

Abort is a non-local exit to the point where the counter was set. Flag sets are bit-vectors;
copying residual flags to source flags on variable creation is one shift.

**Extensions (§4).**

- *Primitive handlers* with algebraic identities: `(member e₁ '())` becomes `(seq e₁ false)`. Added
  only if the handler either removes the need to process an operand for value or exposes further
  folding — deliberately not a general strength-reduction facility.
- *Letrec pruning.* After the body, operands of still-unreferenced variables are visited for effect
  under an effort counter (falling back to value if exceeded), with residual code cached separately
  per context so an operand is processed at most twice. A binding is dropped only if unassigned,
  unreferenced, and its operand cannot diverge, side-effect, or capture a continuation.
- *Test-context operands.* Visiting a `Test`-context reference's operand in `Value` loses precision:
  `(let ((x (cons e₁ e₂))) (if x 1 2))` fails to fold where `(if (cons e₁ e₂) 1 2)` succeeds.
  Fixed by visiting in `Test` under an effort counter with per-context caching.
- *Recursive procedures.* Inlined if the size and effort limits hold and either (1) no recursive
  call survives in the residual, or (2) the body specialises to the call site. For (1), bind `f` to
  a fresh `f′` with *no operand*, forcing recursive calls to residualize, then check whether `f′`
  ended up referenced; `(f 0)` folds outright, and `(f 5)` first yields `(* 5 (f′ 4))`, after which
  modest effort and unfold counters complete the unfolding to `120`. For (2), compute the
  *invariant* formals — unassigned, and passed as themselves at every recursive call — in linear
  time, cache the set in the operand, and re-process the body with operands supplied only for
  invariant formals. Specialising `(fold * x 1 zero? (lambda (x) x) (lambda (x) (- x 1)))` produces
  factorial, modulo renaming, wrapped in a local `letrec`.

# Applicability

Requires the pass to preserve applicative order and effect sequencing; that is what the
inlined-call-as-`let` treatment buys, and it is why the algorithm cannot simply substitute
operands. Requires assignment tracking, since copy propagation and inlining must not cross a
`set!`. The input is not CPS-converted — deliberately, since converting would exaggerate the
apparent benefit of inlining.

Free variables are the sharp edge. The implementation inlines a procedure with free variables only
when those variables get eliminated during optimisation or when their scope already contains the
call site; in the second case inlining can add free variables to closures, and the authors flag
closure growth as an unresolved interaction they intend to study.

"Linear time" means linear in *source* size for a fixed effort bound; the constant scales with the
bound. Table 4 shows a 10x effort increase roughly doubling runtime. Iterating the pass is
possible but rarely helps.

No profile feedback. The authors note that spending more effort on hot code is the obvious next
move and point at Burger's recompilation framework.

# Relevance

This is the pass that has to run before anything downstream can see anything. A Scheme program
before inlining is a graph of small closures with no visible arithmetic; after `cp0` it has
straight-line integer code with known constants, which is the only form on which stage
`05-intervals` and `06-pentagon` have anything to say. `lattice`'s 4.57x speedup is mostly the
complete unfolding of a user-defined `memv` against short constant lists — the same shape as the
constant-length vector indexing our bounds-check work targets.

Three transferable mechanisms beyond the inliner itself:

- **The effort/size counter pair as a general shape for speculative passes.** Attempt the
  transformation, measure the actual residual, abort on a budget, and get a linear-time guarantee
  out of a fixed number of sites times a fixed budget. Our vectorizer at stage `10-vectorize` wants
  exactly this structure.
- **Contexts.** `Test`/`Effect`/`Value` is the same distinction our interval transfer functions
  want — an expression processed for effect need not have its range computed at all, and one
  processed for test only needs a zero/non-zero verdict.
- **Termination without a call graph.** The pending flags in operand structures give cycle
  detection for free during the traversal. No separate SCC pass.

And one architectural argument: Ashley found that inlining invalidates the flow information that
justified it, so a flow analysis has to be re-run afterward. That is a direct argument for our pass
ordering — inline first, then analyse, and do not try to make an expensive analysis do double duty
across an inlining boundary.

# Notes

**Bibliography correction.** The plan cites this as "Waddell & Dybvig, *Fast and Effective
Procedure Inlining* (SAS 1997)". The PDF is **Indiana University Computer Science Technical Report
No. 484**, whose own footnote reads "This report is an expanded version of a paper to be presented
at the 1997 International Static Analysis Symposium." It is not the SAS'97 LNCS 1302 proceedings
text; it is longer, and sections 3 and 4 in particular carry material the proceedings version
compresses. The title page is dated 15 May 2004, which is a rebuild date on a 1997 report, not a
publication date. Cite it as IU CS TR-484 if the extended content matters and as SAS 1997 if only
the result does.

Reference [16] misdates Wegman & Zadeck's TOPLAS constant-propagation paper as `3(2), 1991`; it is
`13(2)`, April 1991. Reference [2], Appel & Jim, *Shrinking Lambda Expressions in Linear Time*, is
listed as "to appear in JFP" and appeared as JFP 7(5):515-540, 1997.

The comparison tables need care. Table 5's baseline for Jagannathan & Wright is not block-compiled
while their optimizer effectively block-compiles, so the authors report their own results both
ways; the "non-block" columns are the apples-to-apples ones. Table 6's processing times for `<0cfa`
and `1cfa` are **analysis time only** and exclude the cost of the inlining and simplification those
analyses then justify, which makes the speed gap larger than the table shows.

`nbody` is the one benchmark that regresses (0.92-1.05 on the R4400), and the authors attribute it
to cache effects from three-level nested array indexing, backed by the observation that it speeds
up consistently on a Pentium Pro. That is a plausible story rather than a measurement, and it is
the only place the paper's "no benchmark regresses" claim is doing any work.
