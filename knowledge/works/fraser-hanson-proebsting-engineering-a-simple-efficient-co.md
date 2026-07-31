---
type: paper
title: "Engineering a Simple, Efficient Code Generator Generator"
description: Describes iburg, a code generator generator that accepts burg specifications but emits hard-coded tree matchers doing dynamic programming at compile time, trading a 6-12x slower matcher for dynamic costs, readability, and a 600-line implementation.
resource: knowledge/sources/fraser-hanson-proebsting-engineering-a-simple-efficient-co.pdf
tags: [instruction-selection, tree-pattern-matching, dynamic-programming, code-generator-generator, burs]
authors: [Christopher W. Fraser, David R. Hanson, Todd A. Proebsting]
year: 1992
venue: "ACM Letters on Programming Languages and Systems 1(3), Sep. 1992, pp. 213-226"
informs: [/techniques/instruction-selection.md]
pipeline_stage: 11-select
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Identity confirmed. The first page reads "Engineering a Simple, Efficient Code Generator
Generator," Fraser (AT&T Bell Labs), Hanson (Princeton), Proebsting (Arizona), with the header
"Appeared in ACM Letters on Programming Languages and Systems 1, 3 (Sep. 1992), 213-226." This
is the iburg paper. The program is named `iburg` in section 1 and throughout.

The contribution is a deliberate de-optimization with a payoff. `burg` uses BURS theory to move
all dynamic programming to compile-compile time, yielding optimal selection in constant time per
node but requiring all costs to be integer constants. `iburg` keeps the DP at compile time and
emits hard code instead of tables. What that buys: costs may be computed dynamically, a larger
class of tree grammars is admitted (per Pelegri-Llopart), the generated matcher is legible and
debuggable, and the generator is 642 lines of Icon (or 950 of C) against 5100 for burg and 3000
for Twig. What it costs: the matcher is 6 to 12 times slower than burg's, which shows up as
8.5-12.4% of `lcc`'s runtime versus 1.1-2.0%. Against Twig it is faster, by up to 25x, and it
handles large CISC grammars that Twig got wrong.

# Mechanism

Specifications are burg-compatible: `%term` declarations assigning external symbol numbers to
operators, then rules `nonterm : tree = ruleno (cost);` where a tree is a fully parenthesized
prefix pattern. Non-terminals are declared by appearing on a left-hand side; operator arity is
inferred from use. A rule whose pattern is a bare non-terminal is a *chain rule*. Omitted costs
default to zero.

Labeling is a bottom-up left-to-right pass. The client-visible interface is a recursive `label(p)`
that calls a non-recursive `state(op, left, right)`, where `state` numbers are opaque `int`s;
under burg they index a table, under iburg they are pointers to `struct state` records.

The generated record is the whole idea:

```c
struct state { int op; struct state *left, *right;
               short cost[NNT+1]; short rule[NNT+1]; };
```

one cost and one rule slot per non-terminal, costs initialized to 32767 as infinity. `state`
switches on the external symbol number; each non-leaf case is a sequence of `if` statements that
test descendants' `rule` fields for the required non-terminals, compute the summed cost, and call
`record(p, nt, cost, eruleno)`, which overwrites only on strict improvement. Chain rules become
further `record` calls, one for the transitive closure of chain rules reachable from the matched
non-terminal. Patterns may reach past immediate children: `reg: CVCI(INDIRC(disp))` compiles to
`if (l->op == INDIRC && l->left->rule[disp_NT])`. Reduction is a separate top-down traversal
driven by `rule(state, goalnt)`, supplied by the client.

Five engineering improvements are measured, and the table is the most useful part of the paper
(iburg source lines / matcher object bytes / lcc time / matcher time):

```
566  240140  2.5  .69   original
580   56304  2.4  .59   inline record, add closure routines
580   56120  2.4  .59   initialize only rule[start]
616   58760  2.2  .39   precompute leaf states
642   66040  2.2  .39   pack rule numbers
```

Closure routines are the big win, 4x on size: instead of emitting a `record` chain at every match
site, emit one `closure_X(p, c)` per chain-reachable non-terminal and call it once. The routine
records the chain match if cheaper and tail-calls the next closure routine. Inlining `record`
also lets a failed cost test skip the whole chain, valid because costs increase monotonically.
Rule packing replaces `short rule[]` with a bitfield struct sized by counting the rules defining
each non-terminal (`decode_X[]` tables map back to external numbers); on the VAX grammar with 47
non-terminals this shrinks the rule vector from 96 bytes to 16, which turns 47 assignments into
one struct copy. Leaf precomputation is the time win: leaves always match, so their entire state
record can be computed at compile-compile time and emitted as a `static struct state z = {...}`,
skipping allocation and initialization entirely.

Two improvements are reported as failures, which is rare and welcome: inlining the closure
routines made the matcher faster but larger than the original, and rewriting them to avoid tail
recursion produced no measurable speedup because the `switch` bounds check ate the gain. A
corrigendum adds one more, from BEG: the match tests need not read `rule` fields at all, since the
cost tests suffice; only embedded terminals such as the `INDIRC` above require a real test.

# Applicability

Preconditions: an expression-tree IR with fixed operator arity, a covering tree grammar, and a
client willing to supply `OP_LABEL`, `LEFT_CHILD`, `RIGHT_CHILD`, `STATE_LABEL` accessors. Binary
maximum: the interface is hard-wired to two children, so n-ary operators must be currified in the
IR.

Where it fails. Optimality is per-tree, so anything crossing a tree boundary (common
subexpressions, register pressure, scheduling) is outside the model. Context sensitivity has to be
smuggled in through the operator set: `lcc` rewrites `CNSTI` to `I0I` before labeling so that
`ASGNI(disp,I0I)` can select a clear instruction, and the VAX indexed addressing mode costs 12
rules. The authors note iburg could be extended with BEG-style predicates but had not been. The
matcher allocates a state record per node, which the leaf optimization mitigates but does not
remove.

# Relevance

Direct input to stage 11. Our situation matches iburg's design point better than burg's on three
counts.

Costs are not constant for us. After stage 8 assigns storage classes, the cost of a pattern depends
on whether an operand is already in an `xmm` register, whether an index is tagged or untagged, and
whether a flonum is boxed. Encoding all of that in the operator set the way `lcc` encodes zero as
`I0I` means a combinatorial blowup of terminals. Compile-time DP with dynamic costs is the right
trade, and it is the one thing BURS structurally cannot do.

Compile speed is not our constraint. iburg's penalty is roughly 10% of compiler runtime on a 1992
MIPS box. We are optimizing generated code quality on numeric kernels; a tenth of compile time is
not a currency we care about.

Debuggability is worth real money here. The paper's teaching argument applies to us as the sole
implementor: when a table-driven matcher picks the wrong rule you get an integer, when iburg picks
the wrong rule every node carries its matching rule and cost per non-terminal and you diff the
matcher's actual choices against your expectation. Given that the acceptance test for our back end
is "count spills in the emitted inner loop," being able to read why a pattern won is the difference
between a morning and a week.

Practical note on shape: we would not port the C code. The interesting artifact is the
specification language plus the four structural decisions (per-non-terminal cost/rule vectors,
closure routines for chain rules, monotone-cost early exit, precomputed leaf states). Those
transcribe into a nanopass emitting Scheme without difficulty.

# Notes

No bibliography errors found. Plan line 532 lists this as "Fraser, Hanson & Proebsting,
*Engineering a Simple, Efficient Code Generator Generator* (iburg)," which the title page confirms
exactly. The slug's truncated `-co` is just a filename length artifact, not a mislabel. Author
order, affiliations, venue and year all check out.

Text extraction caveat for anyone re-reading it: the PDF's text layer drops `ffi` and `ffi`-family
ligatures, so "efficient" extracts as "ecient" and "identifies" as "identies." The rendered pages
are correct; only the extracted text is damaged. Section 2's grammar figure and the `%term`
examples survive intact.

One thing the paper oversells slightly. It claims iburg "admits a larger class of tree grammars"
and cites Pelegri-Llopart, but never says which class or gives an example of a grammar burg rejects
and iburg accepts. That claim is unsupported in the text.

Historical detail worth knowing: iburg was written as a testbed for what became burg's
specification language and interface, after Twig produced incorrect matchers for large CISC
grammars and the bug proved unfindable. The initial version took two days and 200 lines. The
project's actual lesson is that the throwaway prototype was good enough to ship, teach with, and
publish.
