---
type: technique
title: Bounds check elimination
description: Prove statically that an array index is in range so the compare and branch can be deleted. The problem the interval, pentagon, octagon and polyhedra domains all exist to solve, and the one place Chez's type lattice cannot reach.
tags: [bounds-check-elimination, abstract-interpretation, difference-constraints, e-ssa, loop-analysis, demand-driven-analysis]
sources:
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
  - resource: /works/logozzo-f-hndrich-pentagons-2008-2010.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
  - resource: /works/cousot-halbwachs-automatic-discovery-of-linear-restraints-.md
  - resource: /works/mine-octagon-abstract-domain-hosc-2006.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/cytron-et-al-efficiently-computing-ssa-toplas-1991.md
  - resource: /works/appel-ssa-is-functional-programming-1998.md
  - resource: /works/wegman-zadeck-constant-propagation-with-conditional-branch.md
implemented_by: [/implementations/sbcl.md]
absent_from: [/implementations/chez.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Every safe `(flvector-ref v i)` compiles to a length load, a compare and a conditional
branch, twice if the lower bound is checked separately. The direct cost is a few cycles. The
real cost is that the branch is a scheduling barrier: it pins the memory access, blocks code
motion, and makes a loop body ineligible for vectorization. Bodík, Gupta and Sarkar measured
this exactly. They removed 45% of dynamic upper-bound checks and got only about 10% speedup,
and they attribute the gap to Jalapeño lacking the global code motion that check removal was
supposed to unblock. The value of this optimization is realised downstream, not at the check
site.

The obligation itself is trivial: `0 <= i` and `i < length(v)`. Discharging it statically is
the hard part, and it is why the whole numeric-domain hierarchy in `docs/CHEZ-ANALYSIS.md`
exists.

# Mechanism

Four strategies, and they compose rather than compete.

**1. Prove it from a numeric abstract domain.** Run a forward abstract interpretation and
query the state at the access. Level 2 intervals suffice when the length is a compile-time
constant. Level 3 pentagons handle a symbolic length by carrying `i < len` explicitly. Levels
4 and 5 handle sums and general linear forms. Cousot and Cousot's POPL 1977 section 9.2 opens
with array bounds checking as the motivating example for intervals, so this is the original
application, not a later repurposing.

**2. Prove it on demand from a difference-constraint graph.** ABCD's move is to restrict the
logic to `x - y <= c`, which turns the whole question into a shortest-path query. Constraints
are gathered from five syntactic forms with no prior global analysis; anything else leaves
the variable unconstrained, which is safe because it only hides redundancy. An edge
`u --c--> v` means `v <= u + c`. Re-derived, since the source PDF loses the `<=`, `phi` and
`sigma` glyphs entirely and Table 1 and Definition 2 are legible only by reconstruction from
surrounding prose:

    x := A.length      x <= A.length          A.length --0--> x
    x := c             x <= c                 c        --0--> x
    x := y + c         x <= y + c             y        --c--> x
    if/while x <= y    per-branch, see below
    check A[x]         x_new <= A.length - 1  A.length --(-1)--> x_new

Anyone implementing this should re-derive the table against the paper's worked example rather
than copy it.

**e-SSA.** Constraints are program-point specific, valid only within a live range. Rather
than qualify each with a CFG scope, split live ranges by renaming until every variable's live
range is contained in the scope of every constraint mentioning it. Ordinary SSA handles
assignments. Conditionals and checks need sigma-assignments on branch out-edges: for
`if (v_i <= w_r)`, insert `v_j := sigma(v_i)` on the true edge and `v_k := sigma(v_i)` on the
false edge. The true branch then yields `v_j <= w_s` at weight 0, the false branch yields
`w_t <= v_k - 1` at weight -1. After `check A[i_1]`, insert `i_2 := sigma(i_1)`, because the
constraint must attach to the *new* name or the check proves itself redundant.

The sigma nodes must be inequalities, not equalities. As equalities the system would imply
`v_j = v_k`, and combined with `v_j <= w_s = w_t <= v_k - 1` you get `v_k <= v_k - 1`,
inconsistent. Using `<=` leaves them mutually unconstrained, which is correct because they
are never simultaneously live. The price is that upper- and lower-bound checks need two
separate graphs.

**The min/max split, which is a correctness trap.** Along one path a variable is bounded by
the strongest constraint; across paths, by the weakest. So a phi vertex takes the max over
its in-edges and every other vertex takes the min. Get this backward at a loop header and the
analysis is unsound.

**The solver** is a memoized backward DFS over a three-valued lattice `True > Reduced >
False`, answering a threshold question rather than computing a distance, which lets it stop
early. Cycles are handled by `active[v]`: on re-entry, a strictly larger propagated constant
than one cycle ago means an amplifying cycle and the answer is False; otherwise Reduced.
Negative cycles are not a consistency problem, because every cycle comes from cyclic control
flow and therefore contains a phi with an argument defined outside the cycle, and the max at
that vertex breaks it. Partial redundancy falls out of backtracking: a check goes into a
phi's in-edge exactly when some arguments proved True and others False.

**3. Hoist or coalesce across loop iterations.** If the induction variable's range is derived
from the loop guard, one check before the loop replaces one per iteration. In our core
language a loop is a `letrec`-bound procedure tail-called from its own body, an induction
variable is a parameter whose recursive argument is itself plus a constant, and
`(if (fx<? i n) ... (loop (fx+ i 1)))` gives `i in [i_0, n)` throughout the body.

**4. Cheap wins that need no analysis at all.** ABCD does implicit subsumption: the
upper-bound check for `A[i-1]` is redundant given `A[i]`, and dually for lower bounds. And on
zero-based arrays both checks merge into a single *unsigned* comparison, since a negative
index becomes a huge positive one. That halves the check count before any domain runs.

# Preconditions

**Not SSA, exactly.** ABCD assumes SSA and does not build it, but what it actually needs is
unique names whose live range is contained in every constraint mentioning them. Our core
language already gives that for `let`-bound variables, and `letrec` loop parameters are the
phi nodes. What must be added is the sigma-assignment: a fresh binding on each arm of an `if`
for every variable in the test, and a fresh binding after every checked access. That is one
small nanopass, not a representation change. The SSA Book reaches the same conclusion from
theory: range analysis takes information at conditional branches as well as at definitions,
so vanilla SSA does not satisfy Static Single Information and the splitting strategy for the
ABCD and range-analysis row is `Defs-down union Out(Conds)-down`, which is precisely e-SSA.

Index arithmetic restricted to `+c` and `-c`. A multiply or a non-constant stride makes the
variable unconstrained and the check unprovable.

Aliasing. ABCD is safe in Java because locals cannot be aliased and array length is
immutable, so `x.f[2]` after `y = x; y.f = new int[1]` correctly fails: `x.f` is a memory
load returning an unknown array with no def-use edge. Scheme vector *lengths* are immutable
too, so the length half carries over; vector *references* are freely aliasable, so any
reasoning that depends on which vector a variable holds does not. Appel is explicit that the
SSA-to-functional correspondence covers scalars only and that arrays need dependence
analysis; Cytron et al.'s `Access`/`Update` renaming is the standard workaround.

Downstream consumers must exist. Removing checks with no global code motion, no vectorizer
and no scheduler behind it buys the 10% Bodík measured rather than the 45% the check counts
suggest.

# Cost

ABCD: under 10 `prove` invocations per check, about 4ms per check, 45% of dynamic
upper-bound checks removed, all four checks in bidirectional bubble sort. Statically about
31% of checks fully redundant; only `bytemark` had a meaningful partially redundant fraction
at 26%.

Clousot with Pentagons: 88.9% of static array accesses validated across four .NET assemblies,
about three minutes each, never above 300 MB. Intervals alone: 81.45%. Octagons: 1h39m on
mscorlib.dll with 20 timeouts.

Cousot and Halbwachs with polyhedra: HEAPSORT at six variables, about 20 seconds of 1978 CPU
time, all accesses proven.

# Disagreements

**The two headline numbers are not comparable.** Logozzo's 88.9% counts *static* array
accesses validated. Bodík's 45% counts *dynamic* upper-bound checks removed, and only upper
bounds. Figure 6 of ABCD shows enormous variance behind that average, near 100% on the
Symantec sort microbenchmarks and much less on SPEC. Bubble sorts and sieves are the home
turf of difference constraints over induction variables. Neither number predicts the other,
and neither predicts ours.

**Do you need a loop analysis?** `docs/CHEZ-ANALYSIS.md` states that the classical
techniques are loop-based and that without loop structure even a Pentagon domain would only
remove checks provable locally within a basic block. Clousot is a counterexample: it is a
plain forward abstract interpretation that stores invariants only at loop headers, has no
loop recognition pass, no induction variable analysis, and validates 88.9%. The resolution is
that loop structure is needed to *hoist* a check out of a loop, not to *prove* it inside one.
A widened-and-narrowed fixpoint at the loop header already gives the index's range across all
iterations. ABCD sharpens the point from the other direction: its amplifying-cycle detection
is induction-variable handling as a side effect, with no IV pass at all. This is a real
correction to our planning documents, and it means stage 07 can be thinner than the CUJ
assumes, or can arrive later.

**Where does the fact from a comparison get attached?** Pentagon's answer is a flow-sensitive
map recomputed per program point. ABCD's answer is a fresh name bound only inside the
then-arm, with one global graph queried on demand. The two encode the same information. ABCD
wins on per-query cost, which matters when re-checking after a transformation without redoing
the analysis; Pentagon wins on having no graph to keep consistent, and composes with the
interval component that the graph formulation has no place for.

The CUJ sketches `strict-lt` as a map from `x` to a set of `y`, which is ABCD's weight `-1`
edge. ABCD's representation composes transitively for free; the set-of-successors
representation does not, which is exactly why Pentagons need hand-written
bounded-transitivity rules in their transfer functions.

**How much of the check actually goes away.** ABCD discloses that its transformation half is
weak: each check splits into a compare that sets a flag and a trap that raises on it, and
only the compares are optimized. Traps for partially redundant checks stay put, so code still
cannot move freely across the array access, which was the original motivation. Fully
redundant traps do get deleted and those are the majority.

# For us

Stage `05-intervals` should carry nbody on its own. The arrays are length 5, the length is a
compile-time constant, and the loop indices have derivable bounds, so no relational reasoning
is required. That is the falsifiable prediction in `docs/CHEZ-ANALYSIS.md` section 4 and it
is what milestone 2 tests.

Stage `06-pentagon` carries fannkuchredux, which has a symbolic length. Its check
`check A[j_2]` is ABCD's own worked example, whose proof path runs
`A.length -> limit_0 -> ... -> limit_4 -> j_2` at distance -2 through a phi node and two
sigma nodes. That is the shape to test against.

Add the sigma-assignment nanopass regardless of which prover we build. It is cheap, it makes
the guard fact attachable to a name, and it is the precondition both formulations share.

`flvector-ref` deliberately lacks the `safeongoodargs` flag and the omission is correct:
knowing `i` is a `sub-index` says it is a non-negative fixnum in representable range, not
that it is less than *this* vector's length. The needed fact is relational and no type
predicate can express it. Chez's lattice collapses `index`, `length`, `sub-index` and `u8` to
`fixnum-pred`, so the fact is not merely unproven, it is unrepresentable. SBCL reaches it by
two independent mechanisms, interval reasoning in `check-bound-empty-p` for constant lengths
and the `< > <= >= =` constraint kinds in `constraint.lisp` for dynamic ones.

Verify in the disassembly, not the timings. Milestone 2 is a grep for a bounds-check branch
in nbody's inner loop, and it should be a test rather than an observation.
