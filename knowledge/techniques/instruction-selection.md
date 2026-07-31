---
type: technique
title: Instruction selection
description: Cover an expression tree with target instructions at minimum cost by matching a tree grammar bottom-up and running dynamic programming over the matches, either at table-construction time or at compile time.
tags: [instruction-selection, tree-pattern-matching, dynamic-programming, code-generator-generator, burs]
sources:
  - resource: /works/aho-ganapathi-tjiang-code-generation-using-tree-matching-a.md
  - resource: /works/fraser-hanson-proebsting-engineering-a-simple-efficient-co.md
  - resource: /works/rastello-et-al-ssa-based-compiler-design-the-ssa-book.md
  - resource: /works/ghuloum-an-incremental-approach-to-compiler-construction-2.md
  - resource: /works/keep-dybvig-nanopass-preprint.md
implemented_by: [/implementations/chez.md, /implementations/sbcl.md]
absent_from: []
pipeline_stage: 11-select
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Given an expression tree at the target machine's semantic level, choose a covering set of
instructions at minimum cost, without committing to an addressing mode for one operand before
the rest of the tree has been seen. The subordinate question, *tree pattern matching*, is how to
find every place a set of templates matches a subject tree in one pass. It is not a separate
technique, because the whole point of the tree formulation is that matching and costing are
fused. Separate them and you get back the Graham-Glanville left-operand bias: the mode for `A`
in `op A B` is picked without seeing `B`, and on machines with mode restrictions that selection
has to be undone.

# Mechanism

A specification is a tree grammar. A rule is `nonterminal : pattern (cost) = {action}`, the
pattern a fully parenthesized prefix tree whose leaves are operators or nonterminals.
Nonterminals name storage classes and addressing modes. A rule whose pattern is a bare
nonterminal is a *chain rule*. Selection is two traversals: bottom-up labeling annotating each
node with the cheapest rule per nonterminal, then top-down reduction from a goal nonterminal
emitting instructions.

**Matching by Aho-Corasick over path strings (twig).** Decompose each template into its
root-to-leaf path strings, alternating child index and symbol, so depth `j` gives a string of
length `2j+1`. The template `plus(r, i(plus(c, r)))` yields `+1r`, `+2i1+1c`, `+2i1+2r`. Build
one Aho-Corasick trie over all path strings with failure links, linear in total path-string
length. One DFS threads the automaton state through the subject tree:

```
visit(n):
  n.state = (n is root) ? succ(0, n.symbol)
                        : succ(succ(n.parent.state, k), n.symbol)   # n is kth child
  for each child c: visit(c)
  post_process(n)
```

Partial matches are bit strings, not Hoffmann-O'Donnell counters, which is what allows
overlapping matches of one template. `n.b_i` has a bit per depth in template `t_i`; bit `j` set
means `n` matches at depth `j` of `t_i`. Accepting states set bits, then

```
n.b_i  <-  n.b_i  OR  (AND over children c of  c.b_i >> 1)
```

and `t_i` matches the subtree at `n` iff `n.b_i` is odd. Only nonzero bit strings are stored, in
a shadow tree isomorphic to the IR rather than in the IR.

**Dynamic programming, and where to put it.** Twig runs it per node inside `post_process`.
`n.cost[l]` is the cheapest cost of a rule labelled `l` matching at `n`, initialized to infinity;
chain reductions are simulated by taking the automaton transition on the label symbol from the
parent state. Chain-rule cycles terminate with no explicit cycle breaking, because the second
match through a cycle costs more than the first. BURS moves all of this to table-construction
time: constant time per node, but every cost must be an integer constant.

**iburg keeps the DP at compile time and emits hard code instead of tables.** The generated
record is the idea:

```c
struct state { int op; struct state *left, *right;
               short cost[NNT+1]; short rule[NNT+1]; };
```

one cost and one rule slot per nonterminal, costs initialized to 32767 as infinity. `state`
switches on the operator; each non-leaf case is a sequence of `if`s testing descendants' `rule`
fields for the required nonterminals, summing costs, and calling `record(p, nt, cost, ruleno)`,
which overwrites only on strict improvement. Patterns may reach past immediate children:
`reg: CVCI(INDIRC(disp))` compiles to `if (l->op == INDIRC && l->left->rule[disp_NT])`.

Four structural decisions carry the performance and the measured table is the paper's most
useful artifact. Closure routines are the size win, 4x: one `closure_X(p,c)` per chain-reachable
nonterminal, which records the chain match if cheaper and tail-calls the next, instead of a
`record` chain at every match site. Inlining `record` lets a failed cost test skip the whole
chain, valid because costs increase monotonically. Rule packing replaces `short rule[]` with a
bitfield struct sized by counting rules per nonterminal, shrinking the VAX grammar's rule vector
from 96 bytes to 16, turning 47 assignments into one struct copy. Precomputed leaf states are
the time win, since leaves always match and their whole state record can be a static initializer.

**Semantic predicates.** Twig expresses them through cost code: `ABORT` is infinite cost, so a
rule fires only when its guard holds. iburg as published has no equivalent; the authors note it
could take BEG-style predicates and had not. A corrigendum adds that match tests need not read
`rule` fields at all, since cost tests suffice, except for embedded terminals like the `INDIRC`.

# Preconditions

A sequence of expression *trees* at the target's semantic level, with arities agreeing between
subject and templates. DAGs break the model: once common subexpressions exist, optimal code
generation is combinatorially hard, and twig does no CSE and no algebraic simplification.
iburg's client interface is hard-wired to two children, so n-ary operators must be curried.
Optimality is per-tree, so common subexpressions, register pressure and scheduling all sit
outside the model. Twig's scalar cost per subtree (Aho-Johnson used a vector `C[i]` indexed by
available registers, justified by the contiguous-evaluation theorem) is valid only where
register management genuinely separates from selection, verified for VAX and MIPS-X and stated
as open elsewhere. Context sensitivity must be smuggled into the operator set: `lcc` rewrites
`CNSTI` to `I0I` before labeling so `ASGNI(disp,I0I)` can select a clear instruction, and VAX
indexed addressing costs 12 rules.

# Cost

Twig: 115 VAX rules in 853 lines compile in 5.2s on a VAX-11/780 to 7.5KB of tables and a 47.5KB
code generator, and the resulting compiler beat pcc2 by 23% over 13 programs. Inside the
generated selector 80% of time is in the matcher: 20% automaton simulation, 35% DP bookkeeping,
6% cost evaluation. iburg's matcher is 6 to 12 times slower than burg's, 8.5-12.4% of `lcc`'s
runtime versus 1.1-2.0%, but up to 25x faster than twig. Generator sizes: iburg 642 lines of
Icon or 950 of C, burg 5100, twig 3000. Choosing iburg costs compile speed; choosing burg costs
dynamic costs, which is the thing BURS structurally cannot do.

# Disagreements

The three main sources agree on the model and disagree on where the dynamic programming belongs.
That is a genuine engineering fork with measured costs on both sides, not a dispute about
correctness, and the deciding variable is whether your costs are constants.

Two claims are weaker than they read. Aho, Ganapathi and Tjiang say twig output is "at least as
good as" a hand-crafted generator, conditioned on the IR being generated with care and the cost
model being faithful, which is doing most of the work in that sentence; they concede the
generated selector is still slower than a hand-written one and that the real win is
specification effort. Fraser, Hanson and Proebsting claim iburg "admits a larger class of tree
grammars" than burg, citing Pelegri-Llopart, but never name the class or give a grammar burg
rejects. That claim is unsupported in the text.

The SSA Book's ch. 19 argues past all three: PBQP selection over SSA graphs handles multi-result
and DAG patterns that tree matching structurally cannot express. The book's own framing is that
this chapter's cost/benefit is the worst in Part IV for a small compiler, so the disagreement is
about scope rather than correctness.

One historical fact reads as a warning rather than a disagreement. iburg exists because twig
produced incorrect matchers for large CISC grammars and the bug proved unfindable. The
throwaway prototype was 200 lines and two days, and shipped.

# For us

Stage 11, and our situation matches iburg's design point rather than burg's. The deciding count
is that our costs are not constant: after stage 08 assigns storage classes, a pattern's cost
depends on whether an operand is already in an `xmm` register, whether an index is tagged or
untagged, and whether a flonum is boxed. Encoding that in the operator set the way `lcc` encodes
zero as `I0I` is a combinatorial blowup of terminals. Compile-time DP with dynamic costs is the
right trade and BURS cannot make it. Compile speed is not our currency; iburg's penalty was a
tenth of compiler runtime on a 1992 MIPS box and we are optimizing generated code on numeric
kernels.

Debuggability is worth real money to a sole implementor. When a table-driven matcher picks the
wrong rule you get an integer; when iburg picks the wrong rule every node carries its rule and
cost per nonterminal and you diff the matcher's choices against your expectation. Our back-end
acceptance test is "count spills in the emitted inner loop," so being able to read why a pattern
won is the difference between a morning and a week.

The two register files fall out as separate nonterminals rather than as special cases, which is
the main reason to use a grammar at all here. And `ABORT` is how representation predicates enter
selection: a packed-f64 rule aborts unless stage 08 proved the operand unboxed, so an unproven
value never matches the vector rule. That is the cleanest available join between stage 08's
storage classes, stage 10's packs, and the emitted encoding.

Do not port the C. The transferable artifact is the specification language plus the four
structural decisions (per-nonterminal cost and rule vectors, closure routines for chain rules,
monotone-cost early exit, precomputed leaf states), all of which transcribe into a nanopass
emitting Scheme. Nanopass already gives us the grammar-per-stage discipline a tree grammar
wants, so stage 11's input language is the specification's terminal set by construction.
