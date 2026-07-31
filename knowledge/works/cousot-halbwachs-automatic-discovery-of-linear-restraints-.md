---
type: paper
title: "Automatic Discovery of Linear Restraints Among Variables of a Program"
description: Instantiates abstract interpretation with the domain of closed convex polyhedra, using a dual restraint/frame representation and a widening that keeps only the restraints stable across a loop, to infer linear inequalities among program variables without user-supplied assertions.
resource: knowledge/sources/cousot-halbwachs-automatic-discovery-of-linear-restraints-.pdf
tags: [abstract-interpretation, convex-polyhedra, relational-domain, widening, bounds-check-elimination]
authors: [Patrick Cousot, Nicolas Halbwachs]
year: 1978
venue: "POPL 1978, pp. 84-96"
informs: [/techniques/polyhedra-domain.md, /techniques/interval-domain.md, /techniques/pentagon-domain.md, /techniques/bounds-check-elimination.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

The first relational numeric abstract domain. Karr had solved linear *equalities* using
Wegbreit's algorithm, which requires that every strictly increasing chain in the property
lattice be finite. That assumption fails for inequalities, since `(x=1)`, `(1<=x<=2)`,
`(1<=x<=n)` is an infinite ascending chain. This paper drops the finite-chain requirement and
recovers termination with a widening operator, which is the durable contribution: it is the
first widening designed for a specific infinite-height domain rather than assumed away.

Second contribution, and the one implementers forget until they have implemented it: a
polyhedron must be kept in *two* representations simultaneously, as a system of linear
restraints and as a frame of vertices, rays and lines. Neither alone supports all the
operations, and converting on demand costs more than maintaining both.

The opening example is a bubble sort from Knuth, analyzed in 1.582 seconds of 1978 CPU time,
producing invariants like `B<=N, J>=1, J+1<=B, J=T` at program point 7 with no user
assertions. The stated applications are compile-time overflow detection, integer subrange
checking, array bound checking, symbolic constant propagation, common-subexpression
recognition up to semantic equivalence, induction-variable detection, and dead-code
detection. That list is a superset of what our numeric stages are for.

# Mechanism

A polyhedron in R^n has two characterizations.

Restraints: `AX <= B`, with A an m-by-n real matrix. Equalities are two opposite
inequalities. Strict inequalities are not representable, so `x != b` is approximated by
dropping the restraint, and for integers `a*X > b` is written `a*X >= b+1`.

Frame: three sets `S` (vertices), `R` (extreme rays), `D` (lines), such that x is in P iff x
is a convex combination of S plus a positive combination of R plus a linear combination of D.

Conversions, both needed:

Frame to restraints. Build the polyhedron by successive approximations `P_1, ..., P_(sigma +
rho + delta)`. `P_1` is the single point s1, described by `x = s1`. Each subsequent vertex is
incorporated as the convex hull of `P_(i-1)` with `s_i`, which is the system
`{0<=lambda<=1, AX + lambda(A*s_i - B) <= A*s_i}` with lambda then eliminated by Fourier-Motzkin
projection. Rays are adjoined by eliminating mu from `{mu>=0, AX - mu*A*r <= B}`, lines by
eliminating nu from `{AX - nu*A*d <= B}`. Projection to eliminate column c: keep every row with
`A^l_c = 0`; for every pair of rows with opposite signs in column c, emit
`(|A^l1_c|*A^l2 + |A^l2_c|*A^l1) X <= |A^l1_c|*B^l2 + |A^l2_c|*B^l1`. This is the operation that
blows up, and it is why the result must then be minimized.

Restraint minimization, from Lanery: an inequality never saturated by a vertex of the frame is
irrelevant; an inequality saturated by all vertices and all rays is an equality; and given the
quasi-order `C1 <= C2` iff everything saturating C1 saturates C2, `C1 <= C2` without `C2 <= C1`
makes C1 irrelevant, while mutual containment lets exactly one of the pair be dropped.

Restraints to frame. Lanery's method, built on the simplex pivot. Put the system in standard
form `AX = B, X^E >= 0` with slack variables; run phase one of simplex to find a feasible basis
or report the polyhedron empty; pivot initial variables into the basis as far as possible. If
all initial variables are in the basis, the polyhedron contains no line and one has a vertex, so
traverse the adjacency graph of feasible bases exhaustively (Dyer-Proll's traversal), reading off
a vertex per basis and an extreme ray per column satisfying condition 3.4.2.1. If some initial
variables remain out of the basis and satisfy condition 3.4.2.2, those columns give a basis of
the greatest linear variety in P, that is, the lines; adjoin the corresponding equalities to get
a *section* of P that contains no line, and recurse. Frames are minimized dually: a vertex or ray
saturating no inequality is irrelevant, a ray saturating all restraints is a line, and the same
quasi-order argument applies.

Transfer functions, in the two representations:

- Entry node: no restraints, equivalently frame with the origin as sole vertex, no rays, and the
  n unit vectors as lines.
- Non-linear assignment `x_l0 := E(X)`: eliminate `x_l0` by projection. In the frame, add the
  unit line `d_l0`. Then simplify.
- Invertible linear assignment `x_l0 := aX + b` with `a_l0 != 0`: a change of basis. Substituting
  `X = MX' + K` turns `AX <= B` into `(MA)X' <= B - AK`, computed directly rather than through
  the frame (credited to Karr). In the frame, each vertex, ray and line has its l0 component
  replaced by `a*v + b` for vertices and `a*v` for rays and lines.
- Non-invertible linear assignment (`a_l0 = 0`): project out `x_l0` as in the non-linear case,
  then adjoin the restraint `x_l0 = aX + b`.
- Linear test `aX <= b`: `P_t = P and (aX <= b)`, `P_f = P and (aX >= b)`. Note both are closed,
  so the two branches overlap on the hyperplane. The frame of `P intersect H` is built from
  adjacency data: a vertex of the intersection is a vertex of P on H, or a convex combination of
  two *adjacent* vertices straddling H, or a vertex plus a positive multiple of an adjacent ray,
  or a vertex plus a multiple of a line. Extreme rays similarly come from rays on H, positive
  combinations `r1 + mu*r2` of adjacent rays, or `r1 - (a*r1/a*d1)*d1`.
- Non-linear test: ignored, `P_t = P_f = P`.
- Simple junction: convex hull of the incoming polyhedra, which is the least polyhedron
  containing their union. Computable only from the frame (union the S, R, D sets), which is
  precisely why the frame is kept.
- Loop junction: `P = P widen convex-hull(P_1, ..., P_p)`.

The widening, which is the heart:

    Q1 widen Q2  =  the polyhedron given by those linear restraints of Q1
                    that are satisfied by every element of the frame of Q2

`Q1 <= Q1 widen Q2` and `Q2 <= Q1 widen Q2` hold, and any ascending chain stabilizes because at
each step the number of restraints describing S_n is finite and no greater than the number
describing S_(n-1). Restraints that do not immediately stabilize across the loop are simply
discarded. In the worked example, `I+2J<=6` is the only restraint of `P_2^2` not satisfied by the
whole frame of the hull, so it is dropped and the polyhedron opens out into a cone.

Two implementation notes the authors give from experience. Widening at a loop junction should not
be applied until information has been gathered around the cycle containing that junction, or it
throws away restraints before they have had a chance to stabilize. And computing the frame of
`Q1 widen Q2` is cheap despite Lanery's method being expensive, because widening replaces vertices
with rays (so there are few vertices left to discover, and vertex discovery is the costly part),
because a frame of Q1 is already known so simplex initialization can be skipped, and because
every restraint of the widened result is a restraint of Q1, so the two frames share most elements.

# Applicability

Preconditions. Programs modeled as connected flowcharts with entry, assignment, test, junction and
exit nodes; no side effects in expressions or conditions, so everything effectful must be an
assignment. Every cycle in the graph must contain a designated loop-junction node, which is where
widening happens.

Costs, from the authors' own measurement rather than asymptotics: "almost linear in the length of
the program but exponential in the number of variables involved." The number of vertices of a
polyhedron in R^n cut out by m inequalities is bounded only by functions growing very quickly in m
and n (they cite Saaty and Klee). Their advice is explicit: avoid the frame search except on
polyhedra expected to have few vertices, and exploit static scoping so that outer-block variables
can be analyzed independently of inner-block ones. HEAPSORT with six variables took about 20
seconds. Bubble sort took 1.582.

Precision losses to expect. Non-linear assignments and non-linear tests lose everything about the
assigned variable or the branch. Only closed half-spaces, so strict inequalities are widened to
non-strict. Only convex sets, so a disjunction at a merge becomes its hull, and the analysis
cannot express `x < 0 or x > 10`. Real coefficients in the prototype cost precision (they note
rationals as fractions are more costly but exact, and that the applications they care about are
integer, so rationals are the right choice). Numeric constants in source are better replaced by
symbolic constants: the systems get bigger but convergence is often faster.

The last paragraph is the honest one. Widening is a tentative definition, the experiments
"seem to corroborate" the choice, and further study is needed. Thirty years of subsequent work on
widening with thresholds and narrowing confirms that this widening is too aggressive on its own.

# Relevance

This is level 5 of our domain hierarchy and it is the upper bound we are deliberately not paying
for. Read it to know what the cheap domains give up, and to know where the expense actually lives.

The specific lessons for `05-intervals` and `06-pentagon`:

The expense is not the inequality reasoning. It is the vertex enumeration. Intervals and Pentagon
are cheap precisely because they have no frame representation and therefore no simplex traversal.
Any future extension that reaches for a relational domain should ask first whether it needs a
frame; Octagon's answer is no (it uses a difference-bound matrix with shortest-path closure), and
that is why Octagon is the practical relational domain and polyhedra is not.

The widening principle transfers verbatim and we need it. Our interval lattice also has infinite
height, so the interval analysis needs a widening at loop headers, and the rule "keep only the
constraints that survived the loop body" is exactly right at interval granularity too: an upper
bound that grew is set to +infinity. The authors' warning about widening too early applies to us
unchanged. Do not widen on the first visit to a loop header; propagate around the cycle once
first.

The dual-representation lesson generalizes to a design rule: when an operation is natural in one
representation and impossible in another, keep both and maintain consistency rather than
converting. For us the analogue is keeping interval facts alongside the pentagon's strict-less-than
map instead of deriving one from the other.

Section 6's HEAPSORT result is the target to beat, not to match. It infers `2L<=N+1, R+3<=2N,
J<=2I+1, 2I<=J, L<=I, 2L+2R+1<=3N` and then checks statically that all array accesses are in
bounds. Pentagon plus interval will not derive `2L+2R+1<=3N`. The question we need to answer with
our own benchmarks is whether accesses in Scheme numeric kernels actually need coefficients other
than 1, and Logozzo and Fahndrich's argument is that they do not.

Note also section 7's final suggestion, which nobody followed up until much later: propagate the
array-bound legality conditions *backward* to the loop junctions so they can guide the widening,
combining discovery with verification. That is the same idea as widening with thresholds, and if
we ever need more than Pentagon it is the cheap way to get it.

# Notes

Title, authors and venue verified against the scanned title page: "AUTOMATIC DISCOVERY OF LINEAR
RESTRAINTS AMONG VARIABLES OF A PROGRAM", Patrick Cousot and Nicolas Halbwachs, Laboratoire
d'Informatique, U.S.M.G., Grenoble, in the Conference Record of the Fifth Annual ACM Symposium on
Principles of Programming Languages, pages 84-96. The bibliography entry ("polyhedra, the expensive
upper bound", POPL 1978) is correct in every particular.

The PDF is a bilevel scan with no text layer at all; pypdf extracts 327 characters from fourteen
pages. It was read by decoding the CCITT G4 strips and stitching them into page images. Anything
built on top of this document that expects to grep the source will find nothing. That is a property
of the file, not of the paper.

`pipeline_stage` is recorded as `06-pentagon` because the stage list in `docs/phases/07-compiler/CUJ.md`
has no polyhedra pass. Polyhedra is the level-5 domain that sits above Pentagon (level 3) in the
hierarchy, and this work bounds that stage from above rather than implementing it. If a level-4 or
level-5 stage is ever added, this document should move.

Where the paper is dated. The prototype is 2500 lines of Pascal on a CII-IRIS 80, and the timings
are meaningless as absolute numbers; the useful figure is the ratio between bubble sort at four
variables and HEAPSORT at six, which is roughly 12x for two more variables, and that ratio is a
property of the algorithm rather than the machine. The use of real matrices "for simplicity" with an
acknowledged loss of precision is a wart the authors flag themselves and would not be repeated today.

Where it is oversold, mildly: "without user provided inductive assertions nor human interaction we
have automatically determined..." is true, but the flowchart abstraction has already assumed away
procedures, aliasing, and side effects in expressions. The analysis is fully automatic on the
language it analyzes, and that language is not one anybody writes in.
