---
type: technique
title: Convex polyhedra abstract domain
description: General linear inequalities among program variables, kept simultaneously as a restraint system and as a frame of vertices, rays and lines. The most precise classical numeric domain and the one whose cost is exponential in the number of variables.
tags: [polyhedra-domain, abstract-interpretation, relational-domain, widening, numerical-domains, bounds-check-elimination]
sources:
  - resource: /works/cousot-halbwachs-automatic-discovery-of-linear-restraints-.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
  - resource: /works/mine-octagon-abstract-domain-hosc-2006.md
  - resource: /works/logozzo-f-hndrich-pentagons-2008-2010.md
implemented_by: []
absent_from: [/implementations/chez.md, /implementations/sbcl.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Level 5, the ceiling. Octagons hold `+/-x +/-y <= c`; polyhedra hold `a1*x1 + ... + an*xn <= k`
with arbitrary coefficients over arbitrarily many variables. Cousot and Halbwachs's HEAPSORT
example infers `2L <= N+1`, `R+3 <= 2N`, `J <= 2I+1`, `2I <= J`, `L <= I` and `2L+2R+1 <= 3N`
with no user assertions, then checks statically that every array access is in bounds. This
document exists to bound our design from above: to say what the cheap domains give up, and,
more usefully, to say precisely where the expense lives, because it is not where most people
assume.

# Mechanism

A polyhedron in `R^n` is kept in *two* representations at once, and the second contribution
of the paper is that you have no choice about this. Neither representation supports all the
operations and converting on demand costs more than maintaining both.

*Restraints*: `AX <= B` with `A` an `m`-by-`n` matrix. Equalities become two opposite
inequalities. Strict inequalities are not representable, so `x != b` is approximated by
dropping the restraint, and over the integers `a*X > b` is written `a*X >= b+1`.

*Frame*: three sets, vertices `S`, extreme rays `R`, lines `D`. A point is in `P` iff it is a
convex combination of `S` plus a positive combination of `R` plus a linear combination of `D`.

**Frame to restraints.** Build by successive approximation. `P_1` is the single point `s_1`,
described by `x = s_1`. Each further vertex is incorporated as the convex hull of `P_{i-1}`
with `s_i`, which is the system `{0 <= lambda <= 1, AX + lambda(A*s_i - B) <= A*s_i}` with
`lambda` then eliminated by Fourier-Motzkin projection. Rays are adjoined by eliminating `mu`
from `{mu >= 0, AX - mu*A*r <= B}`, lines by eliminating `nu` from `{AX - nu*A*d <= B}`.
Projection to eliminate column `c` keeps every row with a zero in `c` and, for every pair of
rows with opposite signs there, emits
`(|A^l1_c|*A^l2 + |A^l2_c|*A^l1) X <= |A^l1_c|*B^l2 + |A^l2_c|*B^l1`. That is the operation
that blows up, which is why the result must then be minimised.

**Restraint minimisation** (Lanery). An inequality saturated by no vertex of the frame is
irrelevant; one saturated by all vertices and all rays is an equality; and under the
quasi-order `C1 <= C2` iff everything saturating `C1` saturates `C2`, a strict `C1 <= C2`
makes `C1` irrelevant while mutual containment lets exactly one of the pair be dropped.

**Restraints to frame.** Also Lanery, built on the simplex pivot. Put the system in standard
form with slack variables, run phase one of simplex to find a feasible basis or report the
polyhedron empty, and pivot initial variables into the basis as far as possible. If all
initial variables are in the basis there is no line and one has a vertex, so traverse the
adjacency graph of feasible bases exhaustively, reading off a vertex per basis and an extreme
ray per qualifying column. If some initial variables remain out of the basis, those columns
give a basis of the greatest linear variety in `P`, that is, the lines; adjoin the
corresponding equalities to get a section containing no line, and recurse.

**Transfer functions.** Non-linear assignment: project out the target variable, which in the
frame means adding its unit line. Invertible linear assignment `x_l0 := aX + b`: a change of
basis, `AX <= B` becomes `(MA)X' <= B - AK`, computed directly on the restraints rather than
through the frame. Non-invertible linear assignment: project out, then adjoin
`x_l0 = aX + b`. Linear test `aX <= b`: intersect, and note both branches are closed, so they
overlap on the hyperplane. Non-linear test: ignored, both branches keep `P`. Simple junction:
convex hull, which is computable only from the frame by unioning the `S`, `R`, `D` sets, and
that is precisely why the frame is kept.

**The widening**, the heart of the paper and the first widening designed for a specific
infinite-height domain rather than assumed away:

    Q1 widen Q2 = the polyhedron given by those linear restraints of Q1
                  that are satisfied by every element of the frame of Q2

Restraints that do not immediately stabilise across the loop are discarded. Any ascending
chain stabilises because the number of restraints cannot grow. In the worked example
`I + 2J <= 6` is the only restraint of `P_2^2` not satisfied by the whole frame of the hull,
so it is dropped and the polyhedron opens into a cone. Loop junctions use
`P = P widen hull(P_1, ..., P_p)`.

Two implementation notes the authors give from experience. Do not widen at a loop junction
until information has been gathered once around the cycle, or restraints are thrown away
before they have had a chance to stabilise. And computing the frame of the widened result is
cheap despite Lanery's method being expensive, because widening replaces vertices with rays
so there are few vertices left to discover, because a frame of `Q1` is already known so
simplex initialisation can be skipped, and because every restraint of the result is a
restraint of `Q1` so the two frames share most elements.

# Preconditions

Programs modelled as connected flowcharts with entry, assignment, test, junction and exit
nodes. No side effects in expressions or conditions, so everything effectful must be an
assignment. Every cycle must contain a designated loop-junction node, which is where widening
happens. Karr's earlier linear-equality algorithm needed every strictly increasing chain in
the property lattice to be finite; this paper drops that requirement, which it has to, since
`(x=1)`, `(1<=x<=2)`, `(1<=x<=n)` is an infinite ascending chain.

Rationals as fractions rather than reals. The prototype used real matrices "for simplicity"
and the authors flag the resulting precision loss themselves.

# Cost

From the authors' own measurement rather than asymptotics: "almost linear in the length of
the program but exponential in the number of variables involved." Bubble sort at four
variables took 1.582 seconds of 1978 CPU time; HEAPSORT at six took about 20. The absolute
numbers are meaningless today; the ratio, roughly 12x for two more variables, is a property
of the algorithm. The number of vertices of a polyhedron in `R^n` cut out by `m` inequalities
is bounded only by functions growing very quickly in `m` and `n`. Their own advice is to
avoid the frame search except on polyhedra expected to have few vertices, and to exploit
static scoping so outer-block variables can be analysed independently of inner-block ones.

Precision losses to expect anyway. Non-linear assignments and non-linear tests lose
everything about the assigned variable or the branch. Only closed half-spaces, so strict
inequalities are widened to non-strict. Only convex sets, so a disjunction at a merge becomes
its hull and the analysis cannot express `x < 0 or x > 10`.

# Disagreements

**Where the expense lives.** This is the single most useful thing in the paper and it
contradicts the usual framing. The expense is not the inequality reasoning. It is vertex
enumeration, the simplex traversal of the adjacency graph of feasible bases. Intervals and
Pentagons are cheap precisely because they have no frame representation and therefore no
traversal. Octagons are the practical relational domain because their answer to "do you need
a frame" is no: a difference-bound matrix with shortest-path closure suffices. The design
rule that follows is to ask of any candidate relational domain whether it needs a frame, not
how many variables its constraints mention.

**Is the widening any good?** The authors are honest that it is a "tentative definition,"
that the experiments only "seem to corroborate" the choice, and that further study is needed.
Thirty years of subsequent work says they were right to hedge. Miné notes that this widening
depended on which set of inequalities represents the argument and that Halbwachs later
corrected it, and cites the same defect in his own octagon widening as unresolved. Widening
with thresholds and a narrowing pass are the standard repairs.

**Is polyhedra worth having at all?** Logozzo cites polyhedra's scalability problems and
chooses Pentagons, but Clousot does not discard polyhedra. When Pentagons fail to discharge
an obligation, Clousot re-analyses the method with SubPolyhedra. So the position is not "too
expensive, never use it," it is "too expensive to run unconditionally, correct as the second
tier of an adaptive analyser." Miné takes the same position from the other side: he
implements the `poly` transfer-function tier for octagons only for regression testing, and he
declines to compare octagons against polyhedra fairly because no polyhedra library handles
interval linear forms or sound float arithmetic. Nobody in this bundle argues polyhedra are
useless; they argue about what runs first.

**One thing all sources agree on.** Convexity is the shared limitation, not the cost.
Intervals, pentagons, octagons and polyhedra are all convex, so all four lose a disjunction
at a merge. Getting past that needs disjunctive completion or trace partitioning, which
nothing in this bundle covers.

# For us

There is no polyhedra stage in `docs/phases/07-compiler/CUJ.md` and there should not be. This
document is recorded against `06-pentagon` because it bounds that stage from above.

Two things transfer directly. The widening principle, keep only the constraints that survived
the loop body, is exactly right at interval granularity too: an upper bound that grew goes to
infinity. And the warning about widening too early applies to us unchanged, so stage 05 must
not widen on the first visit to a loop header.

The dual-representation lesson generalises to a design rule. When an operation is natural in
one representation and impossible in another, keep both and maintain consistency rather than
converting. Our analogue is keeping interval facts alongside the pentagon's strict-less-than
map instead of deriving either from the other, which is exactly what Pentagon's refined order
does when it discharges a symbolic constraint numerically.

HEAPSORT is the target to be beaten by other means, not matched. Pentagon plus intervals will
not derive `2L + 2R + 1 <= 3N`. The empirical question our own benchmarks must answer is
whether array accesses in Scheme numeric kernels ever need coefficients other than 1. Logozzo
and Fähndrich's measured claim is that they mostly do not.

Finally, section 7's closing suggestion, which nobody followed up for years: propagate the
array-bound legality conditions *backward* to the loop junctions so they can guide the
widening, combining discovery with verification. That is the same idea as widening with
thresholds, and it is the cheap way to get more precision if Pentagon ever proves
insufficient.
