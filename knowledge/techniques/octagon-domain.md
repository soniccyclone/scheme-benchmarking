---
type: technique
title: Octagon abstract domain
description: Invariants of the form +/-x +/-y <= c held in a coherent difference-bound matrix, normalised by strong closure. O(n^2) memory and O(n^3) time per operation, made affordable by variable packing and incremental closure.
tags: [octagon-domain, abstract-interpretation, weakly-relational, difference-bound-matrices, widening, numerical-domains]
sources:
  - resource: /works/mine-octagon-abstract-domain-hosc-2006.md
  - resource: /works/mine-octagon-ast-2001.md
  - resource: /works/logozzo-f-hndrich-pentagons-2008-2010.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
  - resource: /works/cousot-halbwachs-automatic-discovery-of-linear-restraints-.md
implemented_by: []
absent_from: [/implementations/chez.md, /implementations/sbcl.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Pentagons hold `x < y` and nothing with a coefficient or a sum. Some invariants need a sum.
Miné's motivating fragment is four lines: `X := 10; Y := 0; while X >= 0 { X := X-1; if
random() { Y := Y+1 } }`. Proving the non-relational fact `Y <= 11` at loop exit requires
first proving the relational loop invariant `X + Y <= 10` and combining it with `X = -1`.
Intervals cannot. Pentagons cannot. Octagons can, at level 4 of the hierarchy in
`docs/CHEZ-ANALYSIS.md`, for `O(n^2)` memory and `O(n^3)` time per operation.

# Mechanism

**Encoding.** `n` program variables become `2n` DBM variables, `V'_{2i-1} = V_i` and
`V'_{2i} = -V_i`. Then `V_i + V_j <= c` is the potential constraint `V'_{2i-1} - V'_{2j} <= c`
and `V_i <= c` is `V'_{2i-1} - V'_{2i} <= 2c`, so no phantom zero variable is needed. Index
flipping is `i xor 1` on 0-based indices. Each octagonal constraint has two encodings, so
matrices are kept *coherent*: `m_ij = m_{j-bar,i-bar}`.

**Lattice.** Order is pointwise `<=` on the matrix, join is pointwise max, meet pointwise
min, plus an adjoined bottom. Order implies concrete inclusion but not conversely, which is
the whole reason a normal form is needed. Emptiness of the potential set is a strictly
negative simple cycle, testable by Bellman-Ford in `O(n*s + n^2)`.

**Strong closure is the contribution.** Floyd-Warshall closure is a normal form for
potential sets but not for octagons: from `2V_i <= c` and `2V_j <= d` you can deduce
`V_i + V_j <= (c+d)/2`, which is not a path in the potential graph and so is invisible to
Floyd-Warshall. A strongly closed matrix satisfies `m_ii = 0`, `m_ij <= m_ik + m_kj`, and
`m_ij <= (m_{i,i-bar} + m_{j-bar,j})/2`. The algorithm runs `n` steps of
`m^k = S(C_{2k-1}(m^{k-1}))` where

    C_k(n)_ij = min( n_ij, n_ik + n_kj, n_{i,k-bar} + n_{k-bar,j},
                     n_ik + n_{k,k-bar} + n_{k-bar,j},
                     n_{i,k-bar} + n_{k-bar,k} + n_kj )
    S(n)_ij   = min( n_ij, (n_{i,i-bar} + n_{j-bar,j})/2 )

Five terms, not two. Miné is candid that "there does not seem to exist a simple and
intuitive reason for the exact formulas"; they are what keeps the interleaved `S` and `C`
passes from destroying each other, and the justification is a 25-case proof in the appendix
of the journal version. `O(n^3)`. Closure doubles as the emptiness test, since
`gamma(m) = {}` iff some `m^n_ii < 0`.

Strong closure buys *saturation* (Thm. 3): every finite entry of a strongly closed matrix is
attained by an actual point of the octagon. Saturation is what makes the normal form a
normal form, and what makes union, forget and projection *best* abstractions rather than
merely sound ones.

**Incremental strong closure** is what makes the domain affordable. If only the rows and
columns for one variable changed, `Inc` restores the normal form in `O(n^2)`. It is not
decomposable: all modified rows must be handled at once. In Astrée it accounts for 6% of
total analysis time and the non-incremental closure is a rounding error because it is
rarely called.

    operator        domain      incr-1 / incr-var / full     number set
    closure         potential   n^2 / n^2 / n^3              Z,Q,R
    strong closure  octagons    n^2 / n^2 / n^3              Q,R
    tight closure   octagons    n^2 / n^3 / n^4              Z

**Set operations.** Meet is pointwise min, exact, arguments need not be closed, result
rarely is. Join is pointwise max and is the best abstraction *only* if both arguments are
strongly closed, in which case the result is automatically closed. The rule of thumb is
asymmetric: close before joining, do not bother before meeting.

**Transfer functions come in four tiers per operator**: `exact` for assignments of the shape
`V := [a,b]` or `V := +/-V_i + [a,b]` and for tests that already are octagonal constraints;
`nonrel`, which projects to intervals and pushes back, inferring nothing; `rel`, over
interval linear forms `[a0,b0] + sum [ak,bk]*Vk`, computing bounds of `expr (-) V_j` for
every `j`, with the subtraction done *formally* so occurrences cancel before interval
evaluation; and `poly`, which converts to a polyhedron and back, best and exponential, and
which Miné implements only for regression testing.

**Packing** (Astrée, section 6). One octagon over 14,000 globals is impossible. Assign one
pack per syntactic C block; within a block take simple expressions only, extracting variables
from `+ - *`, comparisons, `&& ||` and the left argument of `/`, but not from bit operators,
calls, array lookups or address-of; add an expression's variables only if there are at least
two; add loop-condition and incremented variables to the loop-body pack; discard packs
subsumed by larger ones. Measured average pack size is about 3 variables regardless of code
size and pack count is linear in code size, so total cost is linear in program size.

# Preconditions

Needs `Q` or `R` for the cubic algorithms and for best-precision operators. Analysing
integers as rationals is the recommended default and is sound, since the only error is
spurious non-integer points. Tight closure recovers the integer normal form but costs
`O(n^4)` from scratch, and Miné reports never finding a real program that needed it.

Needs packing. Without it the quadratic and cubic costs are on the whole variable set and
the domain is unusable. With it, no information passes between packs except through pivot
variables, so the packing strategy is where precision actually gets decided.

Needs a float discipline if implemented in floats: always round upper bounds toward
infinity.

**Never strongly-close the left argument of a widening.** The sequence `m_{i+1} = m_i widen
n_{i+1}` terminates; `m_{i+1} = closure(m_i) widen n_{i+1}` does not, and Fig. 25 exhibits a
strictly increasing infinite chain from the four-line program of Fig. 26. Termination rests
on replacing more and more entries with infinity, and closure fills them back in. The domain
is a reduced product of `2n^2` one-constraint domains and closure is a `2n^2`-way reduction
between them; widenings cannot be applied pointwise across a reduced product. The right
argument may be closed, and narrowing may close either.

# Cost

`O(n^2)` memory and `O(n^3)` time per operation on the pack, plus the packing heuristic,
plus the closure/widening hazard as a permanent architectural constraint on how the fixpoint
loop is written. On 400k lines of avionics C with packing: 804 false alarms reduced to 0,
memory up 30%, and analysis time *down* from 20h31 to 13h52, because the relational
invariants stabilised in 96 iterations instead of 172.

Precision given up against polyhedra: anything involving three variables or a coefficient
other than 1. Miné's rate limiter needs `R = X - S` exactly, gets `Y in [-144,144]` instead
of `[-128,128]`, and finds any bound at all only because of the `rel` assignment plus a
threshold widening.

The normal form is redundancy-maximal. Strong closure makes every implicit constraint
explicit, so octagon matrices have very few infinite entries, while polyhedra remove
redundant constraints and can therefore be smaller and faster where a handful of
inequalities suffice.

# Disagreements

**Does the domain scale?** This is the sharpest conflict in the bundle and it is not really
about the domain. Miné's answer is yes, with the 400k-line Astrée result and analysis time
that went *down*. Logozzo's answer is no: octagons on MSIL took 1h39m on mscorlib.dll with
20 method timeouts and 35 across four assemblies, a larger timeout did not help, and he
concludes octagons are "not a good compromise" for a build environment. Both ran the same
domain. The difference is packing. Logozzo says explicitly that in MSIL it is not clear how
to partition variables into buckets or select pivots, because syntactic scope-based
approaches do not work when nested scopes inside methods are compiled away. Astrée's packing
is built entirely on C block structure. So the honest statement is not "octagons scale" or
"octagons do not scale," it is that octagons scale exactly as well as your IR admits a
syntactic packing heuristic, and the answer depends on the front end rather than the domain.

**What closure costs at the fixpoint level.** Miné proves the closed join is the best
abstraction. Logozzo measures that closure at joins materialises a quadratic number of
meaningless constraints out of distinct integer constants: `b = 1, y = 2` for a bool and an
int yields four garbage octagonal constraints. Miné names the same failure and cites Venet's
bucket solution for it. They agree on the mechanism and disagree on whether a workable
bucketing exists outside C.

**Is this the last word on octagons?** Miné says no, in his own footnotes: Bagnara et al.
2005 gives a simpler cubic strong closure and better widenings, published while the article
was being written. He also flags that he does not know the true complexity of integer
closure, and that making widening depend on which DBM represents an octagon "is not fully
satisfactory."

**Two documents, not one.** arXiv `cs/0703084` is the ten-page AST 2001 workshop paper; the
HOSC 2006 article is the 90-page journal version. They are not two hosts of one PDF, and the
2001 paper lacks all the proofs, the integer case, incremental closure, the transfer-function
taxonomy, backward assignment, thresholds, narrowing, and Astrée. Read 2001 for orientation,
cite 2006 for anything load-bearing.

# For us

We are not implementing this. The document exists to say what stage `06-pentagon` gives up
and to harvest what transfers.

What octagons buy that pentagons cannot: anything needing a sum. `X + Y <= 10` for the
counted-loop pattern, mutual exclusion as `X <= 1 and Y <= 1 and X + Y <= 1`, absolute value
as `|X| <= Y + 1`, and `X + I = 17` for a counter-up/counter-down pair. Logozzo measured
that as 177 additional validated array accesses on mscorlib.dll.

Three things worth stealing outright, none requiring octagons. Widening with thresholds
belongs in stage `05-intervals` on day one. Interval linear forms with formal cancellation
are a pure precision win inside the interval domain at almost no cost. The packing algorithm
is domain-independent and worth having if a relational domain over more than a pair of
variables is ever added.

One warning to internalise, because it contradicts the intuition the rest of this document
builds: enabling a more precise domain made Astrée *faster*. Benchmark the whole fixpoint,
not the operator.
