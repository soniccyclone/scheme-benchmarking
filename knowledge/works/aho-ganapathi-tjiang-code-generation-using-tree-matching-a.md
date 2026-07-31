---
type: paper
title: "Code Generation Using Tree Matching and Dynamic Programming"
description: Introduces twig, a tree-translation language whose compiler fuses a top-down Aho-Corasick tree-pattern matcher with dynamic programming to pick a minimum-cost instruction cover.
resource: knowledge/sources/aho-ganapathi-tjiang-code-generation-using-tree-matching-a.pdf
tags: [instruction-selection, tree-pattern-matching, dynamic-programming, code-generator-generator, retargetable-compilers]
authors: [Alfred V. Aho, Mahadevan Ganapathi, Steven W. K. Tjiang]
year: 1989
venue: "TOPLAS 11(4), October 1989, 491-516"
informs: [/techniques/instruction-selection.md, /techniques/tree-pattern-matching.md]
pipeline_stage: 11-select
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Instruction selection stated as tree rewriting, and made practical by combining two
previously separate results: Hoffmann and O'Donnell's reduction of tree matching to
Aho-Corasick string matching, and Aho and Johnson's dynamic-programming code generator.
Earlier table-driven selectors were LR parsers over a linearized prefix IR (Graham-Glanville),
which forces a left-operand bias: the addressing mode for `A` in `op A B` gets picked without
seeing `B`, and on machines with mode restrictions (iAPX-86, Z-8000, MC-68000) that selection
has to be undone. Tree matching has no left-to-right bias, and dynamic programming makes rule
order irrelevant, which removes the whole category of parsing-action conflicts and
grammar-factoring work.

# Mechanism

A rule is `replacement <- template (cost) = {action}`. `replacement` is a single node (a
nonterminal), `template` a tree whose leaves are either node-ids (terminals) or label-ids
(nonterminals), `cost` and `action` are C fragments.

Matching. Each template is decomposed into the set of root-to-leaf path strings, alternating
child index and symbol, so a path of depth `j` yields a string of length `2j+1`: the template
`plus(r, i(plus(c, r)))` gives `+1r`, `+2i1+1c`, `+2i1+2r`. Build the Aho-Corasick trie over
all path strings of all templates, convert to an automaton with failure links, in time linear
in the total path-string length. Then one DFS over the subject tree:

```
visit(n):
  n.state = (n is root) ? succ(0, n.symbol)
                        : succ(succ(n.parent.state, k), n.symbol)   # n is kth child
  for each child c: visit(c)
  post_process(n)
```

Partial matches are tracked as bit strings rather than Hoffmann-O'Donnell counters, which is
what lets overlapping matches of the same template be recorded. `n.b_i` has one bit per depth
in template `t_i`; bit `j` set means `n` matches a node at depth `j` of `t_i`. Accepting states
set bits via `set_partial`; then

```
n.b_i  <-  n.b_i  OR  (AND over children c of  c.b_i >> 1)
```

`t_i` matches the subtree rooted at `n` iff `n.b_i` is odd. Only nonzero bit strings are
stored, and the bit strings live in a structurally isomorphic shadow tree, not in the IR.

Dynamic programming rides along in `do_reduce(n)`, called from `post_process`. `n.cost[l]` is
the cheapest cost of any rule labelled `l` matching at `n`, `n.match[l]` the winning rule
index, both initialized to infinity and 0. For every `t_i` whose bit 0 is set, if
`cost(t_i, n) < n.cost[l_i]` then record it and simulate the chain reduction by taking the
automaton transition on the label symbol `l_i` from the parent state, calling `set_partial` if
that state accepts. Chain-rule cycles (`temp: operand` with `operand: temp`) terminate because
the second match costs more than the first, so no explicit cycle breaking is needed.

The costs come from Aho-Johnson, which computes a vector `C[i]` = optimal cost of the subtree
into a register given `i` available registers, `C[0]` = into memory, justified by the
contiguous-evaluation theorem for uniform-register machines. Twig drops the vector for a scalar
cost per subtree and hands register management to a user routine. That simplification is why
twig is fast and why it stops modelling register pressure.

Match modes are set from the cost code: `ABORT` means infinite cost, which is how semantic
predicates get expressed (rule 8 fires only when the constant is 1). `TOPDOWN` runs the action
before the children's, with `tDO($%n$)` to trigger each labelled leaf explicitly. `REWRITE`
runs the action during matching, before any cover is computed, then re-visits the node, which
is safe because the bit-string scheme does not propagate stale partial matches past `n`. That
is the hook for commutative-operand canonicalization and constant folding.

# Applicability

The IR must be a sequence of trees at the target machine's semantic level, and node arities
must agree between subject tree and templates. DAGs break it: once common subexpressions exist,
optimal code generation is combinatorially hard, and twig does no CSE, no algebraic
simplification, no high-level optimization at all. The scalar-cost simplification is only valid
when register management genuinely separates from selection, which held for the VAX and MIPS-X
but is stated as an open question elsewhere.

Costs measured: a 115-rule VAX specification (17 addressing modes, 17 chain rules, 3 labels, 1
evaluation-order reversal) in 853 lines, compiled by twig in 5.2 seconds on a VAX-11/780,
producing 7.5KB of tables and a 47.5KB code generator. The resulting compiler was 23% faster
than pcc2 on average across 13 programs. Inside the generated code generator, 80% of time is in
the matcher: 20% automaton simulation, 35% dynamic-programming bookkeeping, 6% cost evaluation.
The authors note the linear-list state representation is the obvious thing to fix.

# Relevance

This is the reference formulation for stage 11. After representation assignment our core
language is tree-shaped per expression, and a tree-translation scheme is the right way to
describe x86-64 selection: one syntactic pattern can cover several instructions, and the two
register files (tagged/untagged GPR versus xmm/zmm) fall out as separate nonterminals rather
than as special cases. The `ABORT` mechanism is how representation predicates enter selection:
a packed-f64 rule aborts unless stage 8 proved the operand unboxed, so an unproven value simply
never matches the vector rule.

The dynamic-programming-at-match-time design is the part to reconsider. BURS (Pelegri-Llopart
and Graham, POPL 1988, cited here as [38]) and its descendants move the cost computation into
table construction, and `fraser-hanson-proebsting-engineering-a-simple-efficient-co` in this
same corpus is iburg, the practical successor. Twig spends 35% of code-generation time on DP
bookkeeping precisely because it does the work per node instead of once. Read this paper for the
model and the tree-matching algorithm; take the table-generation strategy from iburg.

# Notes

Title and venue confirmed from the title page: TOPLAS Vol. 11 No. 4, October 1989, pages
491-516, received January 1986 and revised three times. The bibliography entry gives only
"(twig)" with no venue, so the year and journal are new information rather than a correction.

The paper is honest that a twig-generated code generator is still slower than a hand-crafted
one, and that the win is specification effort plus table size plus generation speed, not raw
throughput. The claim that output code is "at least as good as" a hand-crafted generator is
conditioned on the IR being generated with care and the cost model being faithful, which is
doing a lot of work in that sentence.

One artifact worth knowing: the scanned text renders "30 percent" of total compile time in code
generation as "130 percent". The original figure has to be 30.
