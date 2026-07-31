---
type: paper
title: "Register Allocation Using Lazy Saves, Eager Restores, and Greedy Shuffling"
description: A two-pass linear intraprocedural allocator that saves registers only once a call is provably inevitable, exploiting the fact that two thirds of Scheme activations make no calls at run time.
resource: knowledge/sources/burger-waddell-dybvig-register-allocation-pldi-1995.pdf
tags: [register-allocation, effective-leaf-routines, parallel-assignment, calling-conventions, scheme]
authors: [Robert G. Burger, Oscar Waddell, R. Kent Dybvig]
year: 1995
venue: "PLDI 1995 (SIGPLAN '95 Conference on Programming Language Design and Implementation)"
informs: [/techniques/register-allocation.md, /techniques/storage-class-assignment.md]
pipeline_stage: 12-regalloc
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The measurement is the paper. *Syntactic* leaf routines — those containing no call sites —
account for under a third of Scheme procedure activations. *Effective* leaf routines — those
that, on the path actually taken, make no call — account for over two thirds. Nobody had
measured the second number. Every save-placement strategy in the literature was optimizing
against the first.

From that fact, three mechanisms and no graph coloring:

- **Lazy saves.** Save a register exactly when a call becomes *inevitable* — later than
  callee-save-on-entry (which saves on call-free paths), earlier than caller-save-before-call
  (which saves redundantly on paths with several calls).
- **Eager restores.** Restore immediately after a call anything *possibly* referenced before
  the next call. Deliberately not lazy: they implemented both and eager won.
- **Greedy shuffling.** Do not fix argument evaluation order before allocation. Choose the
  order that minimizes the temporaries needed for the parallel assignment into argument
  registers.

Result: 72% of stack references eliminated, 43% faster, against a baseline that already had
eight globally allocated registers, local allocation in the code generator, and the greedy
shuffler. Register allocation costs 7% of compile time. Two linear passes over the AST.

# Mechanism

**Save placement.** Over the assignment-converted core language `E → x | true | false | call
| (seq E1 E2) | (if E1 E2 E3)`. The naive version is:

```
S[call] = { r | r live after the call }
S[(seq E1 E2)] = S[E1] ∪ S[E2]
S[(if E1 E2 E3)] = S[E1] ∪ (S[E2] ∩ S[E3])
```

Union in `seq` places the save as soon as it is inevitable; intersection in `if` keeps it
lazy. This is *too* lazy, and the paper finds the exact failure: `and`/`or` desugar to `if`
in test position, and `(if (if x call false) y call)` — which has no call-free path at all —
yields `S = ∅`.

The fix is to split by the value the expression produces, so impossible paths can be
identified and neutralized. `St[E]` = registers to save if `E` evaluates true, `Sf[E]` if
false. Save `r` iff `r ∈ St[E] ∩ Sf[E]`. With `R` the set of all registers:

```
St[x]=∅            Sf[x]=∅
St[true]=∅         Sf[true]=R          # impossible path -> R, the ∩ identity
St[false]=R        Sf[false]=∅
St[call]=Sf[call]= { r | r live after the call }

St[(seq E1 E2)] = (St[E1] ∩ Sf[E1]) ∪ St[E2]
Sf[(seq E1 E2)] = (St[E1] ∩ Sf[E1]) ∪ Sf[E2]
St[(if E1 E2 E3)] = (St[E1] ∪ St[E2]) ∩ (Sf[E1] ∪ St[E3])
Sf[(if E1 E2 E3)] = (St[E1] ∪ Sf[E2]) ∩ (Sf[E1] ∪ Sf[E3])
```

Union along a path, intersection across paths; `R` for impossible paths so they impose no
constraint. Two properties are claimed: the revised algorithm is never *too* eager
(`St[E] ∩ Sf[E] = ∅` whenever a call-free path through `E` exists), and it is at least as
eager as the naive one (`S[E] ⊆ St[E] ∩ Sf[E]`). Derived equations for `not`, `and`, `or`
fall out — e.g. `St[(and E1 E2)] = St[E1] ∪ St[E2]`, `Sf[(and E1 E2)] = (St[E1] ∪ Sf[E2]) ∩
Sf[E1]`.

**Callee-save, for free.** Add a caller-save return-address register `ret` that must be saved
around any call. Then `ret ∈ St[E] ∩ Sf[E]` *is* the predicate "E inevitably calls." Use
caller-save registers on paths where that fails, and defer moving a value into a callee-save
register until the inevitable-call region begins. One mechanism serves both register classes.

**Greedy shuffling.** At each call:

1. Build the argument dependency graph, traversing only down to nested calls (calls destroy
   argument registers, so nothing below matters).
2. Partition into *simple* (no calls inside) and *complex* (contains a call).
3. Pick as the last complex argument one that no simple argument depends on; it evaluates
   straight into its argument register. All other complex arguments go to temporary stack
   slots — evaluating them would force a save anyway.
4. Topologically peel simple arguments with no remaining dependencies onto a "do last" stack;
   evaluate those directly into argument registers at the end.
5. On a cycle, greedily remove the argument causing the most dependencies into a temporary
   (another argument register if one is free, otherwise the stack) and resume at 4.

O(n³) in the number of argument registers, but n is fixed at six, so the pass stays linear.
Finding the temporary-minimal ordering is NP-complete; the greedy heuristic was optimal on
every call site in every benchmark except six of 20,245 in the compiler itself, each of which
needed one extra temporary. Only 7% of call sites have cycles at all.

**Two passes total.** Pass 1 (bottom-up): greedy shuffling, liveness, `St`/`Sf`, insert
saves. Liveness is an n-bit integer, so union is `or`, intersection is `and`, singleton is a
shift. Pass 2: delete saves already covered by an enclosing save set, and insert restores for
possibly-referenced registers immediately after each call. Pass 2 runs the eager-restore
computation in parallel with save elimination.

# Applicability

Preconditions: assignment conversion already done, so each variable is saved at most once
(this is what makes "save as early as inevitable" sound). Tail calls are jumps and do not
count as calls. A fixed calling convention: `n` allocatable registers, two reserved for
return address and closure pointer, the first `c` actual parameters in registers, rest on the
stack.

The critical structural precondition is that argument evaluation order is *not* fixed before
allocation. That is what makes shuffling avoidable, and it forces register allocation,
shuffling, and liveness to run in the same pass, because you cannot compute liveness before
you know the order.

Where it does not apply: any compiler that fixes evaluation order early (the paper notes
Shao and Appel's CPS compiler needs several complex heuristics precisely because CPS fixes
the order). Any language where effective and syntactic leaf rates coincide — the whole
advantage evaporates. Any setting where interprocedural analysis is actually available and
anonymous calls are rare.

Costs and honest limits: eager restores do issue unnecessary restores at control-flow joins,
accepted on the grounds that hiding memory latency pays for them. Performance rises
monotonically from zero to six argument registers, but five to six is nearly flat, so there
is little to gain past six. Before greedy shuffling existed, performance *decreased* past two
argument registers — the shuffler is what makes the register-passing convention viable at
all.

# Relevance

This is the load-bearing paper for stage 12, more than the graph-coloring literature, because
it is what Chez actually does and Chez is our reference implementation and our host.

The direct architectural consequence: the allocator operates on the *AST*, bottom-up, in two
linear passes, with liveness as a machine word. That fits nanopass exactly. Compare against
George-Appel, which needs a CFG, a liveness dataflow pass, an interference graph with a
sparse-set hash table, and iteration to a fixpoint with program rewriting on spills. Our
stage 12 is specified as linear scan; this paper is a third option, and arguably the one that
matches our IR shape best, since it never leaves the tree.

Two things transfer regardless of which allocator we pick. First, `St`/`Sf` is a general
technique for "does this expression inevitably do X," and we will want exactly that shape at
stage 07 for hoisting (does this loop body inevitably execute the check?) and stage 08 (does
this flonum inevitably escape?). The `R`-for-impossible-paths trick is the non-obvious part
and it is reusable verbatim.

Second, the effective-leaf statistic is a fact about Scheme workloads that should inform
stage 08's storage class decisions: most activations at run time never call anything, so
values in those activations never need to survive a call, so the boxed/unboxed decision
should be biased toward the call-free path. The paper's own throwaway suggestion — static
branch prediction assuming call-free paths are more likely, worth a consistent 2-3% — is
cheap to implement at stage 13 and we should take it.

The interprocedural comparison matters for scoping our ambitions: Steenkiste and Hennessy got
88% of stack accesses with combined intra- plus interprocedural allocation, of which ~51% came
from the intraprocedural half. This paper gets 72% with no interprocedural analysis at all,
and works in the presence of first-class anonymous procedures where the interprocedural
approaches break down. That is the argument against building call-graph-based register
allocation for a Scheme.

# Notes

**Bibliography correction, confirmed.** Our bibliography credited this to "Burger, Dybvig and
Fernández." The title page reads **Robert G. Burger, Oscar Waddell, R. Kent Dybvig**, all
three at Indiana University CS, Lindley Hall 215. There is no Fernández. (The name likely
bled in from Fernández's separate work on Scheme compilation.) Author order is
Burger-Waddell-Dybvig, matching the slug. Title, venue, and year in the slug are all correct:
*Register Allocation Using Lazy Saves, Eager Restores, and Greedy Shuffling*, SIGPLAN '95
PLDI.

**This copy is a corrected version, not the proceedings text.** Footnote 2 on page 5 reads
"This was in error in the proceedings," attached to the condition `ret ∈ St[E] ∩ Sf[E]`. So
the callee-save criterion as printed in the ACM proceedings is wrong and this PDF has the
fix. Anything citing the published page image should be checked against this.

The tak comparison in Tables 4 and 5 is the most interesting and the most oversold part.
Chez beats `cc -O3` by 14% on tak(26,18,9) despite stack-overflow checks and admittedly worse
instruction scheduling. But the authors then hand-modify both C compilers' assembly output to
use lazy saves and get 91% and 60% speedups, and hand-code a caller-save assembly version.
That is a real experiment and it isolates the variable properly. It is also one
call-recursion microbenchmark chosen because it "isolates the effect of register save/restore
strategies," which is another way of saying it is the best possible case. Do not read 14% as
a general Scheme-beats-C result.

Table 3 has a genuinely odd row: `div-iter` shows 100% stack-reference reduction and 133%
speedup, which means the baseline was doing something pathological. `tak` at 109% is
similar. The 43% average is pulled hard by a handful of tiny call-recursion benchmarks; the
four large real programs (Compiler, DDD, Similix, SoftScheme) sit at 30%, 47%, 26%, 22%. The
large-program numbers are the ones to plan against.

One claim is asserted rather than shown: "it can be shown that this placement is never too
eager." No proof is given for either the naive or the revised algorithm, only the statement
and a worked example. The property is believable and probably easy, but if we implement
`St`/`Sf` we should verify it ourselves rather than inherit it.
