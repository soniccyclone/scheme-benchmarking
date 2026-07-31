---
type: technique
title: SSA construction
description: Gives every value a single name whose definition dominates every use, either eagerly via dominance frontiers or lazily by demand-driven search during IR construction.
tags: [ssa-form, dominance, dominance-frontier, phi-placement, ir-construction]
sources:
  - resource: /works/cytron-et-al-efficiently-computing-ssa-toplas-1991.md
  - resource: /works/cytron-ferrante-rosen-wegman-zadeck-efficiently-computing-.md
  - resource: /works/cooper-harvey-kennedy-a-simple-fast-dominance-algorithm.md
  - resource: /works/braun-et-al-simple-and-efficient-construction-of-static-si.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/appel-ssa-is-functional-programming-1998.md
  - resource: /works/click-global-value-numbering-and-code-motion.md
  - resource: /works/lattner-adve-llvm-a-compilation-framework-for-lifelong-pro.md
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
implemented_by: []
absent_from: [/implementations/chez.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

An analysis that keys facts on a variable name is wrong whenever the name is assigned
twice, so every classical dataflow analysis pays for a `(variable, program point)` map.
SSA removes the cost by renaming until each name has exactly one definition, and that
definition dominates every use. The concrete driver for us is ABCD: it does not need a CFG,
it needs names whose live range is contained in the scope of every constraint mentioning
them. This document covers how to produce such names, including the dominance machinery
that the eager algorithm needs first.

# Mechanism

**Dominance, the prerequisite.** Cooper, Harvey and Kennedy solve `Dom(n) = {n} U
(intersect over p in preds(n) of Dom(p))` iteratively in reverse postorder, but never
materialize a set. For every node but the entry, `Dom(b) = {b} U IDom(b) U IDom(IDom(b))
... U {n0}`, so an ordered Dom set is exactly the root-to-`b` path in the dominator tree.
Store one array `doms[]` holding `IDom(b)` and reconstruct the set by walking it.
Intersection becomes a two-finger walk on postorder numbers:

    intersect(b1, b2):
      f1 <- b1; f2 <- b2
      while f1 != f2:
        while f1 < f2: f1 <- doms[f1]
        while f2 < f1: f2 <- doms[f2]
      return f1

The main loop initializes `doms[start] <- start`, then per reverse-postorder node picks the
first already-processed predecessor and folds `intersect` over the rest. `IDom` falls out
directly, which fixes the standard complaint that iterative dominance gives `Dom` but not
`IDom`.

**Dominance frontiers, two formulations.** Cytron et al. decompose
`DF(X) = DF_local(X) U { DF_up(Z) : Z in Children(X) }`, where both parts collapse to the
single test `idom(Y) != X`, giving one bottom-up dominator-tree walk at `O(E + size(DF))`.
Cooper-Harvey-Kennedy invert the direction:

    for all nodes b with >= 2 predecessors:
      for all p in preds(b):
        runner <- p
        while runner != doms[b]:
          add b to DF(runner); runner <- doms[runner]

Work is exactly the sum of the DF set sizes, and it beats the Cytron formulation by 25 to
33 percent. This upward walk is Ferrante, Ottenstein and Warren 1987, not Cooper et al.;
they say so themselves.

**Phi placement.** Per variable `V`, seed a worklist with `A(V)`, the assigning nodes. Pop
`X`; for each `Y` in `DF(X)` with no phi for `V` yet, insert `V <- phi(V,...,V)` with arity
`|Pred(Y)|` and push `Y`. Two per-node integer flags (`HasAlready`, `Work`) compared
against a global `IterCount` avoid an `O(N)` clear per variable. This computes `DF+`, and
Theorem 2 (`J+(S) = DF+(S)` when `Entry` is in `S`) makes the result minimal.

**Renaming.** A top-down dominator-tree DFS carrying a per-variable stack `S(V)` and
counter `C(V)`: rewrite RHS uses from `Top(S(V))`, allocate `i = C(V)++` for each LHS,
push, then for each CFG successor `Y` fill the `WhichPred(Y,X)`-th operand of each phi in
`Y`. Recurse into dominator-tree children, pop on exit. Note the asymmetry that makes it
work: phi operands travel CFG edges, everything else walks the dominator tree. The SSA Book
gives a slot-based variant using a per-variable `reachingDef` field instead of a stack,
which reuses an existing scratch field and is faster in practice.

**The lazy alternative.** Braun et al. build no dominator tree at all. Two maps,
`currentDef[var][block]` and `incompletePhis[block][var]`, plus per-block *filled* and
*sealed* flags:

    readVariableRecursive(v, b):
      if b not sealed:      val = new Phi(b); incompletePhis[b][v] = val
      elif |b.preds| == 1:  val = readVariable(v, b.preds[0])
      else:
        val = new Phi(b)
        writeVariable(v, b, val)        # break cycles BEFORE recursing
        val = addPhiOperands(v, val)
      writeVariable(v, b, val); return val

The cycle-breaking line is the crux: the operandless phi becomes the current definition
before the recursive lookup, so a back edge terminates against it. A phi is trivial when
every operand is itself or one other value `v`; replace it by `v` and recursively re-check
its users. This yields pruned SSA unconditionally and minimal SSA on reducible graphs; an
SCC contraction post-pass recovers minimality under irreducible flow.

# Preconditions

Every node on some `Entry`-to-`Exit` path, and a nominal `Entry` assignment for every
variable. That last one is not cosmetic: Theorem 2 depends on `Entry` being in the
assignment set, and it is also what makes Appel's placement argument work (a node on the
frontier is reachable from two definitions, one of them the entry initialization).

Scalars only, unaliased. Cytron's TOPLAS 3.1 folds aggregates in by treating the whole
array as one scalar with `Access(A,i)` / `Update(A,j,V)` and one variable for the heap;
LLVM instead leaves memory out of SSA entirely and promotes `alloca` slots in a later pass.
Both are admissions that memory does not fit.

Braun's preconditions are about construction discipline, not the program: fill a block
before adding successors, seal only when the predecessor set is final. Sealing a loop
header before its back edge exists leaves incomplete phis that never get operands.

If a scheduler consumes the result, do not simplify `x = phi(x, top)`. Click's Figure 3
shows those phis are load-bearing: they encode the assertion that a value is available on
all paths, and deleting them leaves instructions with no legal placement.

If a range or relational analysis consumes the result, vanilla SSA is the wrong flavor.
Range analysis takes information at conditional branches, not only at definitions, so it
needs sigma-functions on branch exits and a split set of `DF+` forward plus iterated
post-dominance frontier `pDF+` backward. That is e-SSA, and it is what ABCD assumes.

# Cost

Cytron's stated worst case for the full translation is `O(R^3)`, with `size(DF)` and
`A_tot` at `O(R^2)` and `M_tot` (phi operands) at `O(R^3)`. The witness is a nest of `n`
`repeat-until` loops, where DF size is `O(n^2)` while only `O(n)` phis are needed. Theorem 4
proves `|DF(X)| <= 2` for programs built from straight-line code, `if-then-else` and
`while-do`. Measurement on 221 FORTRAN procedures (23,181 statements): `size(DF)` per
statement 0.6 to 2.1, phi count ratio 0.5 to 5.2 with 95 percent under 2.3, average DF
between 1 and 2 with median 1.3, no correlation with program size.

Dominance: `O(N + E*D)` per iteration, halting in at most `d(G) + 3` passes with `d(G)`
averaging 1.11 on real code. The crossover where Lengauer-Tarjan wins is around 30,000
nodes; the largest CFG in the Rice suite was 744 blocks and took one hundredth of a second.

Braun: `Theta(P + (B+E)*V)` base, `O(B^2 * V^2)` with on-the-fly phi optimization, `O(P +
B*(B+E)*V^2)` for SCC contraction. Against LLVM 3.1's tuned Cytron implementation on SPEC
CINT2000: executed x86 instructions 99.72 percent of Cytron's, on-the-fly optimization cost
0.84s of construction and returned 1.49s of compile time by shrinking the graph to 88.2
percent of its nodes.

Field observation from the SSA Book worth more than either bound: in production compilers
renaming, not phi placement, is the expensive phase, and minimality is never actually
required by any optimization.

# Disagreements

**Eager versus lazy.** Cytron needs a dominator tree and dominance frontiers over an
existing non-SSA CFG; Braun needs neither and keeps the IR in SSA at every intermediate
moment. Braun's claim of parity is thin: a 0.28 percent instruction-count edge is noise
between two implementations, and they compare their unoptimized code against LLVM's tuned
code. The honest claim is that the simple algorithm is not slower in any way that matters.

**Pruning.** Cytron's Figure 16 argues explicitly *for* keeping dead phis, because they
expose value-numbering opportunities, and against pruned SSA. Modern practice went the
other way, and the SSA Book puts the cost/benefit point at semi-pruned (filter block-local
variables first). Braun gets pruned form for free, since a phi only exists because
something read the variable.

**What minimal means.** Cytron's minimality is relative to the assignment sets, not to
liveness. Braun's redundancy criterion is strictly stronger, and the measurement matters:
3 of 11 non-trivial phi SCCs in their SPEC runs did not come from irreducible control flow,
so Cytron's algorithm leaves them behind too. Braun's Algorithm 5 is a useful cleanup pass
whichever constructor you use.

**Which dominance algorithm.** Cooper et al. argue the iterative version, then concede that
on real programs both are so fast the choice does not affect compile time, so the real
argument is simplicity and confidence in correctness.

**The two Cytron papers are different documents.** `cytron-et-al-...-toplas-1991` is the
40-page journal article; `cytron-ferrante-...` is the 11-page POPL 1989 paper. The POPL
version has no Section 3.1 (arrays, aliasing), no Section 7 (translating out of SSA), and
no renaming correctness proofs. They must not be merged.

# For us

There is no construction pass to write. Appel's correspondence says a basic block is a
function, a phi left-hand side is a formal parameter, a phi argument on the k-th in-edge is
the actual at the k-th call site, and "definition dominates every use" is lexical scope.
Our `letrec`-bound loop procedures already have that shape after `03-parse`, and the
expander plus `cp0` already alpha-convert. Cite Appel for the dictionary and nothing more:
it is a four-page SIGPLAN Notices column with no evaluation and no new algorithm, and the
formal conversion algorithms are Kelsey's.

The SSA Book's chapter 6 makes the same point constructively: building minimal SSA from a
naive functional encoding is lambda-dropping, block sinking (nest each function inside its
dominator) followed by parameter dropping (delete a parameter whose binding at the
declaration site coincides with the binding at every call site). The phi we cannot drop is
exactly a loop-carried value. Section and page numbers cited here come from the 2018
unfinished draft in `sources/`, not the 2022 Springer edition, so they will not match the
published book.

What we do need is the e-SSA extension for stage 06, which is one nanopass inserting a
fresh binding on each arm of an `if` for every variable in the test and a fresh binding
after every checked access. Budget for a `clean` pass as well, since sigma-splitting
inflates the name space.

If a later stage ever needs a real CFG, most plausibly 11 or 12 once `letrec` loops are
lowered, implement Cooper-Harvey-Kennedy for dominators regardless (about forty lines of
Scheme, no union-find to get wrong, and the `doms` array answers the ancestry queries the
interval and pentagon domains need) and Braun for the SSA itself, because any nanopass that
rewrites control flow invalidates a dominance computation and Braun's `readVariable` pair
is directly usable as SSA reconstruction afterward.

Chez is recorded as absent here on the basis of `docs/CHEZ-ANALYSIS.md` section 4, which
enumerates Chez's passes as `cp0`, `cptypes` and a nanopass backend with no SSA stage. That
is an inference from an enumeration, not a grep for phi-functions.
