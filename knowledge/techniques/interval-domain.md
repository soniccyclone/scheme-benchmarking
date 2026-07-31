---
type: technique
title: Interval abstract domain
description: Track one numeric range per variable, non-relationally, so that an index can be proven in bounds whenever the array length is a compile-time constant. Linear cost, no relations between variables.
tags: [interval-domain, abstract-interpretation, widening, narrowing, numerical-domains, bounds-check-elimination]
sources:
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
  - resource: /works/logozzo-f-hndrich-pentagons-2008-2010.md
  - resource: /works/mine-octagon-abstract-domain-hosc-2006.md
  - resource: /works/wegman-zadeck-constant-propagation-with-conditional-branch.md
  - resource: /works/cousot-halbwachs-automatic-discovery-of-linear-restraints-.md
implemented_by: [/implementations/sbcl.md]
absent_from: [/implementations/chez.md]
pipeline_stage: 05-intervals
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

At `(flvector-ref v i)` the compiler must decide whether `0 <= i` and `i < length(v)`. The
interval domain answers this by carrying, at every program point, one range `[a,b]` per
variable and nothing else. It is level 2 of the domain hierarchy in `docs/CHEZ-ANALYSIS.md`,
and it is the cheapest domain that can represent an index range at all. Cousot and Cousot
chose exactly this problem to motivate the domain: section 9.2 of POPL 1977 opens with
"In a PASCAL program operating on arrays, the compiler should ensure that arrays are
subscripted only by indices within bounds."

# Mechanism

An element is a map `Vars -> Intv` where `Intv = {[a,b] | a,b in Z u {-inf,+inf}}`, with
the whole map bottom if any variable is bottom (Logozzo, Figs. 3 and 4):

    order    [a1,b1] |= [a2,b2]  iff  a1 >= a2 and b1 <= b2      (inclusion)
    bottom   [a,b] = bot         iff  a > b
    top      [-inf,+inf]
    join     [min(a1,a2), max(b1,b2)]                            (convex hull)
    meet     [max(a1,a2), min(b1,b2)]                            (intersection)

Concretization is `gamma([i,s]) = {z | i <= z <= s}`. The lattice has infinite height, so
the Kleene sequence does not terminate and section 8.2 of Cousot and Cousot does not apply.
Two extrapolation operators fix that.

**Widening**, Cousot and Cousot section 9.2, and this is the form to implement:

    [i,j] widen [k,l] = [ if k < i then -inf else i ,  if l > j then +inf else j ]

Keep the *old* bound when it is stable, drop to infinity when it moved. See Disagreements
for a published variant of this that is unsound.

**Narrowing**, section 9.3.4, run as a descending pass from the widened post-fixpoint:

    [i,j] narrow [k,l] = [ if i = -inf then k else min(i,k) ,
                           if j = +inf then l else max(j,l) ]

Narrowing refines only infinite bounds and never touches a finite one, which is why the
descending sequence stays inside `{X | X |= Int(X)}` and therefore stays above the least
fixpoint. On `x := 1; while x <= 100 do x := x+1` the widened system gives `[1,+inf]` at the
loop head; the narrowing pass recovers `[1,101]`. Skipping narrowing forfeits essentially
every loop-carried bound, so it is not optional.

**Where widening is applied.** Pick `W-arcs`, a minimal arc set meeting every cycle of the
equation system. On a reducible forward graph these are the loop back-edges. Then
`A-int(q,Cv) = if q in W-arcs then Cv(q) widen Int(q,Cv) else Int(q,Cv)`. Everywhere else
the exact transfer function is used.

**The fixpoint engine.** Wegman and Zadeck's SCCP is the right skeleton with a taller
lattice: two worklists, one of CFG edges and one of SSA def-use edges, an `ExecutableFlag`
on every CFG *edge* (not node, see Figure 13 of that paper), lattice cells initialised
optimistically to top, and `Visit-phi` reading an operand as top when its incoming CFG edge
is not yet executable. That last rule is the whole of conditional-constant power expressed
sparsely, and it transfers unchanged to intervals. Their termination argument does not: it
rests entirely on "a cell can only lower twice." Replace it with the widening. Section 7 of
Wegman and Zadeck names range propagation over an infinite-height lattice as open work,
which is precisely the gap this stage fills.

**Two cheap precision upgrades from Miné, neither of which needs a relational domain.**

Widening with thresholds: given a finite set `T`, an unstable bound snaps to the next
element of `T` rather than to infinity, falling back to infinity only when `T` is exhausted.
Astrée used one dense piecewise-linear ramp of a few dozen values across all programs
without per-program tuning, and every bound stabilised at the smallest threshold above the
concrete bound. Cousot and Cousot anticipate this in section 9 by suggesting the analyser
first try a declared bound, or zero for an interval not containing zero, before giving up.

Interval linear forms with formal cancellation (Miné, Fig. 17): represent an expression as
`[a0,b0] + sum [ak,bk]*Vk` and simplify `expr (-) Vj` *symbolically* before evaluating with
interval arithmetic, so `(Y+Z) (-) Y` becomes `Z` rather than `max(Y)+max(Z)-min(Y)`.

**The payoff transfer function.**

    at (primcall flvector-ref v i):
      if lo(i) >= 0 and hi(i) < len(v) then unchecked else checked

# Preconditions

The array length must be known as a concrete integer, or at least have a finite upper bound
in the same interval environment. A symbolic length defeats the domain entirely: this is
exactly why level 2 is not enough and level 3 exists.

Optimistic initialisation means the analysis produces *wrong* answers if stopped early.
Budget for running it to completion.

Do not widen on the first visit to a loop header. Cousot and Halbwachs give this as an
implementation note from experience: widening before information has propagated once around
the cycle discards restraints that had not yet had a chance to stabilise.

The `W-arcs` choice is a real design decision. On irreducible graphs it is arbitrary and a
bad cut widens more than necessary.

Soundness is proved per instruction, not per program. Cousot and Cousot's condition 6.5,
`gamma(Int(a,x)) >= Int(a,gamma(x))`, on each primitive transfer function, transfers to the
fixpoint by theorems T1/T2. That is the proof obligation for our own transfer functions.

Integer overflow is not modelled by any of the sources' formal developments. Logozzo's
shipping implementation handles it; the paper does not.

# Cost

One interval per live variable per program point, `O(1)` per transfer function, and the
fixpoint is linear in the SSA graph modulo widening iterations. This is the only domain in
the hierarchy whose cost does not depend on the number of variables *pairwise*.

Precision given up: everything relational. `[1,+inf] - [0,+inf] = top`, so the common
underflow pattern `if (x > y) r := x - y; assert r >= 0` is unprovable. Measured on four
.NET framework assemblies, intervals alone validated 81.45% of array accesses (Logozzo,
Fig. 11), against 88.82% for intervals plus strict upper bounds run side by side.

# Disagreements

**A published interval widening that is unsound.** Figure 3 of the Pentagons paper prints

    [a1,b1] widen_i [a2,b2] = [ a1 <= a2 ? a2 : -inf , b1 >= b2 ? b2 : +inf ]

Taking `a2` when `a1 <= a2` *raises* the lower bound, so the result does not contain the
left argument and violates the upper-bound requirement 9.1.3.2. The upper half has the same
defect symmetrically: taking `b2` when `b1 >= b2` lowers the upper bound. Verified against
the PDF. Both branches are one-operand typos; the intent is `a1` and `b1`, which is
Cousot's form given above. The error is masked whenever the iteration sequence is monotone
increasing, since then `a2 <= a1` and the correct branch fires, and it bites exactly when an
iterate is not increasing. Use the Cousot form. Figure 5's `Sub` widening in the same paper
carries the identical typo, which is covered in `pentagon-domain.md`.

**Is level 2 enough?** Cousot and Cousot present intervals plus narrowing as sufficient for
their motivating array-bounds example, and on a constant-length array it is. Logozzo's
measurement says one array access in five still fails. These are not in conflict about the
domain; they disagree about the program population. Constant-length numeric kernels fall to
intervals, general library code does not.

**How aggressive widening should be.** Cousot and Halbwachs close by calling their widening
"tentative" and saying the experiments only "seem to corroborate" it. Miné's thresholds and
Cousot and Cousot's declared-bounds hint are both responses to the same complaint. All three
sources agree the plain infinity widening is too blunt; none of them offers a principled way
to choose the threshold set, and Miné concedes that a representation-insensitive widening is
future work.

# For us

This is stage `05-intervals`. `docs/CHEZ-ANALYSIS.md` places Chez at level 1: the categories
`index`, `length`, `sub-index` and `u8` in `cptypes-lattice.ss` lines 573-574 all collapse to
`fixnum-pred`, so Chez cannot express "i is in [0,5)" at all. SBCL reaches level 2 through
the standard CL type language, building a `mod` type from the bound and intersecting it with
the index type in `check-bound-empty-p`.

Build the domain as a standalone module with `join`, `meet`, `widen`, `narrow`, `implies?`
and `bottom?`, and unit-test monotonicity and termination before wiring it into a pass. An
unsound `implies?` deletes a check that was needed and corrupts memory, which is the worst
failure mode in the project. Ship widening with thresholds on day one rather than the plain
infinity form. nbody's arrays are length 5 with a compile-time-constant length, so theory
predicts milestone 2 falls out of this stage alone with no relational reasoning at all.
