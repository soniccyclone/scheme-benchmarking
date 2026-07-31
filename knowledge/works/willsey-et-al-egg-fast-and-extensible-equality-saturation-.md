---
type: paper
title: "egg: Fast and Extensible Equality Saturation"
description: Specializes e-graphs to the equality saturation workload with deferred invariant restoration (rebuilding) and a semilattice-based extension mechanism (e-class analyses), yielding asymptotic speedups over per-merge congruence maintenance.
resource: knowledge/sources/willsey-et-al-egg-fast-and-extensible-equality-saturation-.pdf
tags: [e-graphs, equality-saturation, congruence-closure, phase-ordering, rewriting]
authors: [Max Willsey, Chandrakana Nandi, Yisu Remy Wang, Oliver Flatt, Zachary Tatlock, Pavel Panchekha]
year: 2020
venue: "arXiv:2004.03082v3, 7 Nov 2020 (published version: PACMPL 5, POPL 2021)"
informs: [/techniques/equality-saturation.md, /techniques/phase-ordering.md, /techniques/dataflow-analysis.md]
pipeline_stage: n/a
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Two ideas, both about *when* rather than *what*. Rebuilding observes that equality
saturation, unlike an SMT solver, never backtracks and can be split into a read phase and a
write phase, so the congruence invariant does not need to hold continuously; restoring it
once per iteration lets a deduplicating worklist coalesce overlapping upward-merge paths.
E-class analyses observe that most of the ad hoc e-graph hacking in prior equality
saturation tools (constant folding, free-variable sets, tensor shapes) is abstract
interpretation lifted to the e-class level, and can be given a single interface with a
semilattice invariant maintained by the same worklist. The rest is engineering: a reusable
Rust library, roughly 5000 lines, generic over language, analysis, and cost function.

# Mechanism

E-graph is a triple (U, M, H): union-find U over e-class ids, map M from canonical id to
e-class (a set of e-nodes), hashcons H from canonical e-node to id. An e-node is a function
symbol plus a list of child e-class ids. E-classes have identity; e-nodes do not. Two
invariants: congruence (equivalence over e-nodes is closed under `f(a_i) ~ f(b_i)` when
`a_i = b_i`) and hashcons (`n in M[a]` iff `H[canonicalize(n)] = find(a)`).

Traditional maintenance is upward merging: each e-class keeps a parent list, and `merge`
recursively re-canonicalizes and re-hashconses parents, possibly merging further. The cost
is dominated by this, and the paths traced through the graph substantially overlap when
merges arrive in bursts.

Rebuilding splits it. `merge` unions in the union-find and pushes the new id onto a
worklist, then returns. `rebuild()` drains the worklist in chunks, canonicalizing and
deduplicating each chunk before calling `repair(c)` on each remaining class. `repair` does
one layer of upward merging: rewrite the hashcons entries for `c`'s parents, then
deduplicate the parent map, merging any two parents that became congruent (which pushes
back onto the worklist). Calling `rebuild` immediately after each `merge` reproduces the
traditional behavior exactly, so this is a generalization, not a replacement.

Termination and correctness: let `I` be the incongruent-pair set and `W` the worklist. Each
`repair` decreases `(|I|, |W|)` lexicographically, so rebuild terminates with congruence
restored. Two worked cost examples make the win concrete. Merging `x` with `y_1..y_n` when
`f_1(x)..f_n(x)` exist takes O(n^2) hashcons updates eagerly and O(n) deferred. A group of
`w` terms each nested `d` deep takes O(wd) `repair` calls eagerly and O(d) deferred, because
after deduplication the worklist holds exactly one class per layer.

Equality saturation is then restructured: iterate, first e-match every rule against the
frozen e-graph collecting `(rule, subst, eclass)` triples, then apply all of them, then
`rebuild()` once. This makes results independent of rule ordering, which the traditional
interleaved loop is not when saturation is not reached.

An e-class analysis is `(D, make, join, modify)` with `D` a join-semilattice. `make(n)`
abstracts a new e-node from its children's data; `join` merges data when e-classes merge;
`modify(c)` may write back into the e-graph and must be idempotent. Invariant: for every
class, `d_c` is the join of `make(n)` over `n in c`, and `modify(c) = c`. Maintenance folds
into `repair`: after the parent deduplication, re-`make` each parent and join into its data,
pushing the parent back on the worklist if the data changed. Constant folding falls out with
`D = Option<Constant>`, `make` as the abstraction function, and `modify` as the
concretization that adds the folded constant e-node back into the class. Extraction with a
local cost function is itself an analysis over `(best e-node, cost)`.

Rewrites generalize from a right-hand pattern to an `apply` function that sees the analysis
data, giving conditional rewrites (`x/x -> 1` if the class is provably nonzero) and dynamic
rewrites (right-hand side computed, e.g. capture-avoiding substitution guarded by a free-
variable analysis, or a solver that turns a concrete list into a `Tabulate`).

Measurements: 88x geomean on congruence, 21x on whole runs across 32 tests, with the speedup
growing with problem size (Figure 7). Herbie's simplification went from 5022 minutes (98% of
run time) to 1.4 minutes; batching alone bought most of it and deferred rebuilding a further
2.2x. Szalinski ~1000x. Verifying TASO's synthesized equalities: Z3 24.65s, egg 1.56s, 0.52s
batched.

# Applicability

Requires the workload to be additive and backtrack-free. An SMT solver cannot use this.
Requires the analysis domain to actually be a join-semilattice with idempotent `modify`;
the paper says plainly that egg will fail to restore the invariant or fail to terminate
otherwise, and does not check.

The real costs are the ones the paper is quiet about. Binding is unsolved: the lambda
example uses explicit substitution rewrites and is called "rather high in performance cost",
with better binding support listed as future work. Alpha-equivalence is not free. Expansive
rules (associativity, distributivity) blow the e-graph up exponentially, which is why egg
ships a backoff scheduler that temporarily bans rules matching in exponentially growing
locations; that is a heuristic, not a bound. Extraction is only cheap for *local* cost
functions, where a term's cost is a function of its symbol and its children's costs. Any
cost model with sharing, register pressure, or scheduling in it is not local, and the paper
points at pseudo-boolean solvers and ILP for those without endorsing them. No theoretical
analysis of rebuilding in the online setting is offered; the authors say it is likely highly
workload dependent.

# Relevance

The pitch is that this dissolves phase ordering, and for a *local algebraic* rewrite set on
straight-line expressions it does. For our pipeline the honest read is narrower. Stages
`05` through `07` (intervals, pentagon, loops) are abstract interpretation over a CFG, and
e-class analyses are the right shape for them only in the sense that both are semilattices;
egg gives no story for control flow, loops, or effects beyond "Tate's PEGs are a
user-defined language you could port."

Where it plausibly pays for us: an algebraic simplifier over the pure numeric fragment
between `04-declare` and `05-intervals`, where the classic ordering hazard bites (strength
reduction destroying a cancellation, as in the paper's own `(a*2)/2` example), and
`11-select` if instruction selection is expressed as rewrites with a local cost model,
which is tree-pattern matching with a saturated search instead of a greedy one.

The mechanisms worth stealing independently of adopting e-graphs at all: the read-phase /
write-phase split, which makes any rewrite engine order-independent, and the deduplicating
worklist, which is a general amortization trick for any invariant restoration in a pass. If
we do build an e-graph, `modify` as concretization is the pattern that lets our interval
domain feed the rewriter, since a class proven to hold a constant can have that constant
inserted as an e-node and every downstream rewrite sees it for free.

Cost estimate before committing: the extraction cost function must be local or we lose the
main efficiency claim, and a Scheme compiler's real cost model (allocation, closure
creation, register pressure) is not local. Treat egg as a candidate for a *sub*-optimizer,
not for the whole of `07-compiler`.

# Notes

**Version note.** The PDF in `sources/` is arXiv:2004.03082v3 dated 7 November 2020, and
its title page carries no venue. The published article is PACMPL vol. 5, issue POPL (2021),
which the plan cites correctly; the file is the preprint of that. Content is the camera-ready
(acknowledgments thank the shepherd, Simon Peyton Jones), so the mismatch is cosmetic. Cite
POPL 2021 but note the resource is the arXiv version.

The headline speedups deserve a caveat the paper does not put in the abstract. The Herbie
number (3000x) is against Herbie's own Racket e-graph, and Figure 12 shows batching, not
rebuilding, accounts for the bulk of it: 5022 -> 49.4 minutes from batching, 49.4 -> 22.4
from rebuilding, 22.4 -> 1.4 from switching to Rust. Attributing the whole 3000x to
rebuilding would be wrong. The isolated rebuilding contribution is the 88x / 21x on egg's
own test suite, and that suite is two applications (a small CAS and a lambda partial
evaluator), which is a thin basis for an asymptotic claim.

Also worth flagging: "the first general-purpose, reusable e-graph implementation" is a claim
about packaging, not about the data structure. The congruence algorithm is Downey, Sethi and
Tarjan (1980) rearranged; the paper says so directly in related work, and the contribution
is stated precisely as "not how it restores the invariants but when."
