---
type: paper
title: "ABCD: Eliminating Array Bounds Checks on Demand"
description: Encodes bounds-check preconditions as difference constraints on an SSA-derived inequality hypergraph, then proves each check redundant by a demand-driven shortest-path traversal costing under ten steps.
resource: knowledge/sources/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.pdf
tags: [bounds-check-elimination, difference-constraints, e-ssa, demand-driven-analysis, partial-redundancy-elimination]
authors: [Rastislav Bodík, Rajiv Gupta, Vivek Sarkar]
year: 2000
venue: "PLDI 2000, Vancouver BC, pp. 321-333"
informs: [/techniques/bounds-check-elimination.md, /techniques/loop-analysis.md, /techniques/ssa-construction.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Three moves that together make bounds-check elimination cheap enough for a JIT.

**Restrict the logic.** Only difference constraints `x - y ≤ c`, gathered from five
syntactic statement forms with no prior global analysis. Anything else makes the variable
unconstrained, which is safe — it only hides redundancy.

**Make the constraint system flow-insensitive without losing precision.** Constraints are
program-point specific, valid only within a live range. Rather than qualify each constraint
with a CFG scope, split live ranges by SSA-style renaming until each variable's live range is
contained in the scope of every constraint mentioning it. Standard SSA handles assignments;
conditionals and bounds checks need extra σ-assignments on branch out-edges. The result is
*e-SSA*, and on it a single global constraint system is exactly equivalent to the
flow-sensitive one.

**Replace the theorem prover with a graph walk.** Difference constraints over pairs of
variables are a weighted digraph; "is this check redundant" becomes "is the distance from
`A.length` to `x` less than zero." Control flow forces a generalization to a hypergraph with
min and max vertices, and the solver is a memoized depth-first search from the index vertex
backward.

Result: 45% of dynamic upper-bound checks removed, under 10 `prove` invocations per check,
~4ms per check. It eliminates *all four* bounds checks in bidirectional bubble sort, which
the authors claim no other Java compiler of the era could do.

# Mechanism

**The five constraint generators.**

```
C1  x := A.length          x ≤ A.length          A.length --0--> x
C2  x := c                 x ≤ c                 c        --0--> x
C3  x := y + c             x ≤ y + c             y        --c--> x
C4  if/while x ≤ y         (see below)
C5  check A[x]             x_new ≤ A.length - 1  A.length --(-1)--> x_new
```

Edge `u --c--> v` means `v ≤ u + c`.

**σ-assignments.** For `if (v_i ≤ w_r)`, insert `v_j := σ(v_i)` on the true edge and
`v_k := σ(v_i)` on the false edge, same for `w`. Then the true branch yields `v_j ≤ v_i`,
`w_s ≤ w_r`, and crucially `v_j ≤ w_s` (edge weight 0); the false branch yields `v_k ≤ v_i`,
`w_t ≤ w_r`, and `w_t ≤ v_k - 1` (edge weight −1). After a check `check A[i₁]`, insert
`i₂ := σ(i₁)` — the constraint must attach to the *new* name, or the check would prove itself
redundant.

**Why inequalities and not equalities.** This is the non-obvious design point. If
`v_j := σ(v_i)` and `v_k := σ(v_i)` were read as equalities, the system would imply
`v_j = v_k`, and combined with `v_j ≤ w_s = w_t ≤ v_k - 1` you get `v_k ≤ v_k - 1`.
Inconsistent. Using `≤` leaves `v_j` and `v_k` mutually unconstrained, which is correct
because they are never simultaneously live. The cost is that upper- and lower-bound checks
need two separate graphs (reverse the relational operator in C1-C3, and source the search
from the constant `0` instead of `A.length`).

**The min/max split.** Along one path, a variable is bounded by the *strongest* constraint;
across paths, by the *weakest*. So:

```
v ≤ max_{u→v} { u + d(u→v) }   if v ∈ V_φ   (φ-assignment, control-flow merge)
v ≤ min_{u→v} { u + d(u→v) }   otherwise
```

Group all in-edges of a min vertex into one hyperarc; each in-edge of a max vertex is its own
hyperarc. A hyperpath's length is the length of its *longest* component path; the distance is
the *shortest* over all hyperpaths.

**Cycles and consistency.** Negative cycles look like they'd make the system inconsistent
(`v ≤ v + c`, `c < 0`). They do not, because every cycle in `G_I` comes from cyclic control
flow and therefore contains a φ-node with an argument defined outside the cycle. At that max
vertex, `v₁ ≤ max{v₂, v₁+c} = v₂`, which breaks the cycle. Positive cycles (`amplifying`
cycles — a variable incremented in a loop body) are the dangerous ones and must be detected
and cut. `limit`'s cycle in the running example is harmless; `st`'s and `j`'s are amplifying.

**The solver.** `demandProve(G_I, ⟨b - a ≤ c⟩)` where `b` is the index variable and `a` the
array-length literal. `prove(a, v, c)` is a DFS backward against edge direction, propagating
and adjusting `c` at each edge, over a three-valued lattice `True > Reduced > False`:

```
prove(a, v, c):
  if C[v-a ≤ e] = True   for some e ≤ c: return True     # memo, stronger already proven
  if C[v-a ≤ e] = False  for some e ≥ c: return False    # memo, weaker already disproven
  if C[v-a ≤ e] = Reduced for some e ≤ c: return Reduced
  if v = a and c ≥ 0: return True                        # reached the source
  if v has no predecessor: return False                  # unconstrained
  if active[v] ≠ null:                                   # cycle
     return (c > active[v]) ? False : Reduced            # amplifying vs harmless
  active[v] ← c
  if v ∈ V_φ: for each u→v: C[v-a≤c] ← C[v-a≤c] ⊓ prove(a, u, c - d(u→v))   # meet
  else:       for each u→v: C[v-a≤c] ← C[v-a≤c] ⊔ prove(a, u, c - d(u→v))   # join
  active[v] ← null
  return C[v-a ≤ c]
```

Note it returns a boolean about a *threshold*, not the actual distance — a weaker question
that lets it stop early. It also visits nodes multiple times, once per progressively stronger
question, rather than computing a topological order (which would require traversing the whole
graph, defeating demand-driven analysis).

**Partial redundancy.** Insertion edges are collected during backtracking: a check goes into a
φ-node's in-edge exactly when *some* arguments proved True and others False; the False ones
are the insertion set. The compensating check's index expression is free — it is always
`v_i + d` where `v_i` is the φ-argument being inserted into and `d` is the propagated `c` at
that point. In the running example, `check A[j₂]` compensates with `check A[limit₀ + 2]`. At
a min vertex, pick the insertion set with lower execution frequency; at a max vertex, merge.
Profitability is decided by profile counts (speculative insertion), not by the classical
anticipability dataflow problem.

**Two extras worth knowing.** ABCD does *implicit subsumption*: the upper-bound check for
`A[i-1]` is redundant given the one for `A[i]`, and dually for lower bounds. And on
zero-based arrays both checks merge into one *unsigned* comparison, since a negative index
becomes a huge positive one.

# Applicability

Preconditions: SSA already available (ABCD assumes it, does not build it), plus the σ-node
insertion pass. Integer index arithmetic restricted to `+c`/`-c` — a multiply or a
non-constant stride makes the variable unconstrained and the check unprovable.

Where it fails, from the paper's own measurements: `Hanoi`'s remaining checks need
interprocedural analysis; `Dhrystone`'s need complex pointer analysis. Statically ~31% of
checks were fully redundant; only `bytemark` had a meaningful fraction (26%) partially
redundant. Speedup measured at ~10% on the Symantec microbenchmarks, which the authors call
lower than expected and attribute to Jalapeño lacking the downstream optimizations (global
code motion in particular) that bounds-check removal is supposed to unblock.

The transformation half is the weak part and is disclosed as such. Each check is split into a
*compare* (sets a flag) and a *trap* (raises on the flag). ABCD optimizes only the compares.
Traps for partially redundant checks stay put, which means code still cannot move freely
across array accesses — the original motivation. Fully redundant traps do get deleted, and
those are the majority. The proposed fix is dual-version loops with on-demand generation of
the unoptimized loop when a hoisted compare fails, including recovery from *spurious*
failures of speculatively hoisted checks.

Aliasing: safe in Java because locals cannot be aliased and array length is immutable. `x.f[2]`
after `y = x; y.f = new int[1]` correctly fails, because `x.f` is a memory load returning an
unknown array with no def-use edge. In a language with mutable aliased array *references*
this reasoning does not carry over unchanged.

# Relevance

The CUJ names ABCD as the better fit "if the representation moves to SSA later." The
dependency is weaker than that suggests: what ABCD needs is not a CFG in SSA form but *unique
names whose live range is contained in every constraint mentioning them*. Our core language
already gives that for `let`-bound variables, and `letrec`-as-loop parameters are the φ-nodes.
What we must add is the σ-assignment — a fresh binding on each arm of an `if` for every
variable in the test, and a fresh binding after every checked access. That is one small
nanopass producing an `Lessa` language, not a representation change.

The σ-node is the piece our plan is missing. Stage 06's Pentagon domain gives `x < y` facts,
but the CUJ never says where the fact from `(if (fx<? i n) ...)` gets *attached*. ABCD's
answer: to a new name `i₂` bound only inside the then-arm. The alternative is a flow-sensitive
map, which is what Pentagon does and is fine. The two encode the same information; the
difference is that Pentagon recomputes per program point while ABCD builds one graph and
answers queries against it. ABCD's advantage is *per-query* cost, which matters if we want to
re-check after a transformation without redoing the analysis.

Useful regardless of which we pick:

The edge table is a direct spec for stage 06's transfer functions. The CUJ sketches
`strict-lt` as a map from x to a set of y; that is ABCD's weight-(−1) edge, and ABCD's version
composes transitively for free via shortest path where a set-of-successors representation
does not.

The min/max distinction is a correctness trap. Joining at a `letrec` loop header must take the
*weakest* bound, not the strongest — obvious once stated, easy to get backward when one code
path handles both `if` merges and loop headers.

Amplifying-cycle detection is induction-variable handling without an induction-variable pass.
`active[v]` compares the propagated constant against its value one cycle ago; a strict increase
means unbounded growth along that path. Stage 07 currently plans an explicit IV analysis; ABCD
gets the same result as a side effect, so stage 07 may be thinner than planned.

`nbody` (length-5 constant arrays) falls to stage 05 intervals and needs none of this.
`fannkuchredux` (symbolic length) is ABCD's `check A[j₂]` example, whose proof path
`A.length → limit₀ → … → limit₄ → j₂` at distance −2 runs through a φ-node and two σ-nodes.
That is the shape to test against.

# Notes

**Slug mangling, not a citation error.** The slug reads `bod-k-gupta-sarkar`, which is
"Bodík" with the í dropped by the fetcher's ASCII transliteration. Title page confirms:
Rastislav Bodík (University of Wisconsin), Rajiv Gupta (University of Arizona), Vivek Sarkar
(IBM T.J. Watson). *ABCD: Eliminating Array Bounds Checks on Demand*, PLDI 2000, Vancouver,
British Columbia, pages 321-333. Title, year, venue, and author list in the bibliography are
all correct.

Text-extraction damage worth flagging: the math symbols are largely lost in this PDF. `≤`
renders blank, `φ` and `σ` render blank or as a bare `-`. Table 1 and Definition 2 are
readable only by reconstruction from surrounding prose. The reconstruction above is
cross-checked against the worked example and the consistency argument, but anyone implementing
from it should re-derive the edge table rather than copy it blind.

Two mild oversells. "45% of dynamic bounds checks" is 45% of *upper-bound* checks only, and
Figure 6 shows enormous variance — near 100% on the Symantec sort microbenchmarks, much less
on SPEC. Bubble sorts and sieves are the home turf of difference constraints over induction
variables. And "surprisingly powerful" rests on the BubbleSort example, chosen because it is
the case the method handles perfectly. The honest claim: cheap, sparse, demand-driven, and
deliberately weaker than a theorem prover.

The 10% speedup deserves emphasis rather than dismissal. It is *low* for a 45% check
reduction, and the stated reason is that Jalapeño had no global code motion to exploit the
freed-up scheduling. That is a warning for us: removing checks is worth much less if stages 10
and 11 cannot use the resulting freedom. The value of stage 06 is realized downstream, not at
the check site.
