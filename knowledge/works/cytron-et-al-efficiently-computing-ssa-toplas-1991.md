---
type: paper
title: "Efficiently Computing Static Single Assignment Form and the Control Dependence Graph"
description: Shows that phi-function placement is exactly the iterated dominance frontier and that control dependence is the dominance frontier of the reversed CFG, making both structures cheap enough to use in a real compiler.
resource: knowledge/sources/same-mirror.pdf
tags: [ssa-form, dominance-frontier, control-dependence, dead-code-elimination, compiler-ir]
authors: [Ron Cytron, Jeanne Ferrante, Barry K. Rosen, Mark N. Wegman, F. Kenneth Zadeck]
year: 1991
venue: "TOPLAS 13(4), October 1991, pp. 451-490"
informs: [/techniques/ssa-construction.md, /techniques/dataflow-analysis.md, /techniques/bounds-check-elimination.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Two prior representations, SSA form and the control dependence graph, were believed to be
too expensive to build and too large to carry. This paper kills both objections with one
idea. The set of nodes needing a phi-function for a variable `V` is exactly the *iterated
dominance frontier* of the set of nodes assigning `V`, and control dependence is exactly
the dominance frontier relation computed on the reverse control flow graph. Both fall out
of one linear-in-output-size dominance frontier computation.

The paper also covers the parts most people skip: what SSA does to arrays, structures,
aliases and calls; a correctness proof of the renaming pass; how to get *out* of SSA form
without emitting garbage; and measurements on 221 real FORTRAN procedures showing the
structures are linear in program size in practice.

Note this is the journal article, which is substantially larger than the 1989 POPL paper
of a similar name. See `# Notes`.

# Mechanism

`DF(X) = { Y | (exists P in Pred(Y)) X dom P and not X sdom Y }`. Computing that directly
per node is quadratic even when the sets are tiny. The trick is the decomposition

    DF(X) = DF_local(X)  union  { DF_up(Z) : Z in Children(X) }
    DF_local(X) = { Y in Succ(X) : idom(Y) != X }
    DF_up(Z)    = { Y in DF(Z)   : idom(Y) != X }

Both intermediate sets collapse to a single `idom(Y) != X` equality test (Lemmas 2 and 3),
so the whole computation is one bottom-up walk of the dominator tree: for each `X`, scan
`Succ(X)` and then scan `DF(Z)` for each dominator-tree child `Z`, keeping any `Y` whose
immediate dominator is not `X`. Cost `O(E + size(DF))`. The dominator tree itself comes
from Lengauer-Tarjan at `O(E alpha(E,N))`.

Phi placement (Fig. 11) is a worklist over the assignment nodes `A(V)` of each variable
`V`, one outer iteration per variable. Two per-node integer flags, `HasAlready` and
`Work`, are compared against a global `IterCount` rather than reset, which avoids an
`O(N)` clear per variable. Pop `X`, and for every `Y` in `DF(X)` that has no phi yet,
insert `V <- phi(V,...,V)` at `Y` and push `Y`. That computes `DF+` and, by Theorem 2
(`J+(S) = DF+(S)` when `Entry` is in `S`), gives *minimal* SSA. Cost
`O(A_tot * avrgDF)`, where `avrgDF` is the assignment-weighted average dominance frontier
size.

Renaming (Fig. 12) is a top-down dominator-tree DFS carrying a per-variable stack `S(V)`
and counter `C(V)`. At each statement: rewrite RHS uses from `Top(S(V))`, then for each
LHS target allocate `i = C(V)++`, rewrite, and push `i`. Then, for each CFG successor `Y`,
fill in the `WhichPred(Y,X)`-th operand of each phi in `Y` from `Top(S(V))`. Recurse on
dominator-tree children. On exit, pop one entry per assignment in `oldLHS`. `O(M_tot)`.

Control dependence (Fig. 14): build `RCFG`, build its dominator tree, run the same Fig. 10
dominance frontier algorithm to get `RDF`, then invert it. `Y` is control dependent on `X`
iff `X` is in `RDF(Y)`. That is the whole algorithm, `O(E + size(RDF))`.

Getting out (Section 7): replace each k-input phi by k ordinary copies, one at the end of
each predecessor. That is correct but naive, so bracket it. First run dead code
elimination (Fig. 17): mark everything dead, seed a worklist with `PreLive` (I/O, side
effects), propagate liveness backwards through `Definers(S)` *and* through `CD^-1` so
that a branch is live only when something control dependent on it is live. This is
broader than textbook DCE, which pins every conditional live. Then run graph coloring over
the renamed variables to coalesce; most inserted copies become `V <- V` and are deleted.
Coloring per original variable gives readable source, coloring globally gives machine code.

Non-scalars are folded in by making the whole aggregate one "scalar": `Access(A,i)` and
`Update(A,j,V)` for arrays and structures, one variable for the whole heap as the
conservative pointer model, and per-statement `MustMod`/`MayMod`/`MayUse` tuples on the
LHS/RHS of a generalized assignment to capture calls and aliasing.

# Applicability

Preconditions are mild: an ordinary CFG with `Entry` and `Exit`, every node on some
`Entry`-to-`Exit` path, an `Entry -> Exit` edge added so the control dependence graph is
rooted, and a nominal `Entry` assignment for every variable. That last one is not
cosmetic. Theorem 2 depends on `Entry` being in the assignment set (Lemma 7).

Worst case is bad and the paper says so. For a program of size `R`, `size(DF)` is
`O(R^2)`, `A_tot` is `O(R^2)`, and `M_tot` is `O(R^3)`, so the stated worst-case bound
for the full translation is `O(R^3)`. The pathological shape is a nest of `repeat-until`
loops: for `n` nested loops the dominance frontier mapping is `O(n^2)` while only `O(n)`
phis are actually needed, so you pay for frontier entries you never use. Theorem 4 proves
`|DF(X)| <= 2` for programs built only from straight-line code, `if-then-else` and
`while-do`, and the measurements (EISPACK, FLO52, SPICE; 221 procedures, 23,181
statements) show `size(DF)/statements` in 0.6 to 2.1, phi count ratio 0.5 to 5.2 with 95%
under 2.3, `avrgDF` between 1 and 2 with median 1.3, and no correlation with program size.

Cost of ignoring the exit path: naive phi lowering plus no coloring produces a copy
storm. The two supporting passes are not optional in a production compiler.

# Relevance

This is the construction to build the IR on if we go SSA, and section 15 of the
bibliography plus stage 7 of the CUJ both point that way. ABCD is formulated directly on
SSA, so bounds-check elimination in the inner loop depends on having this. Three concrete
takeaways for us:

The dominance frontier algorithm is cheap to implement and shares its output with control
dependence for free, which we want anyway for aggressive dead code elimination and for
predication decisions during vectorization. One computation, two consumers.

The `Access`/`Update` treatment of arrays is directly what we need for the nbody and
fannkuchredux kernels. Renaming an array to `A9 <- Update(A8, j, V)` kills anti- and
output-dependences and legalizes reordering, and the paper's `HiddenUpdate` variant is a
clean channel for feeding dependence-analysis results into an otherwise dependence-blind
scalar framework. The coloring pass on the way out reclaims the storage, so the array is
not actually copied.

The renaming pass is a dominator-tree DFS over stacks. That is the same traversal shape as
our closure-conversion and storage-class passes, so it composes with a nanopass layout
rather than fighting it.

Do read Braun et al. before implementing. Cytron gives you minimal SSA from an explicit
dominance frontier; Braun gives you nearly the same result built on the fly during IR
construction with no dominator tree at all, which is much less machinery for a compiler
that is generating its own IR rather than importing one.

# Notes

**Bibliography correction, high value.** `docs/phases/00-compiler-research/PLAN.md`
section 15 lists two rows, `https://c9x.me/compile/bib/ssa.pdf` labeled as the TOPLAS 1991
paper with "Title confirmed by text extraction", and `Same, mirror` pointing at
`https://www.cs.utexas.edu/~pingali/CS380C/2010/papers/ssaCytron.pdf`. The labels are
swapped. The c9x.me file is the 11-page POPL 1989 conference paper, *An Efficient Method
of Computing Static Single Assignment Form*. The "mirror" is the real 40-page TOPLAS 13(4)
journal article, *Efficiently Computing Static Single Assignment Form and the Control
Dependence Graph*, PDF metadata `/Title` and `/Subject` `(0164-0925) 13:4 0451-0490
(Oct. 1991)`. They are not duplicates and neither should be deleted. This document
describes the TOPLAS version, which currently sits at the slug `same-mirror`.

The two versions are not interchangeable. The POPL paper has no Section 3.1 (arrays,
structures, implicit references), no Section 7 (translating out of SSA, dead code
elimination, coloring), no Lemmas 8 through 10 or Theorem 3 (renaming correctness), and a
thinner control dependence treatment. Anything downstream that wants the exit path or the
aggregate handling must cite the journal version.

Two things read as dated. The `Update` operator on whole arrays is honest about being
crude, and the authors' own answer is "accept it or do dependence analysis" rather than
the memory SSA / heap partitioning that later compilers use. And the paper argues *for*
keeping dead phi-functions to expose value-numbering opportunities (Fig. 16), explicitly
preferring that to pruned SSA. Modern practice went the other way and prunes by default,
because dead phis inflate the IR that every subsequent pass walks. The paper is right that
pruning can cost you an equivalence, but wrong about the balance for a compiler with many
passes.

Minor: the stated worst-case `O(R^3)` is honest but oversells the danger, since the cubic
term comes from `M_tot` counting phi operands and only materializes on control flow no
real program has. The measurement section is the more useful claim, and it holds up.

The PDF is a 1997 ACM re-scan with OCR damage. Author names and body text are readable but
mangled in places ("R. i3yiru:I" for R. Cytron, "clef-use" for def-use, `@` and `#` for
phi). Everything reported here was cross-checked against surrounding context; nothing was
reconstructed from a single garbled token.
