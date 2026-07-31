---
type: technique
title: Pentagon abstract domain
description: Intervals paired with a per-variable set of strict upper bounds, x in [a,b] and x < y, with no transitive closure anywhere. Proves array accesses against symbolic lengths at roughly interval cost.
tags: [pentagon-domain, abstract-interpretation, weakly-relational, bounds-check-elimination, widening, numerical-domains]
sources:
  - resource: /works/logozzo-f-hndrich-pentagons-2008-2010.md
  - resource: /works/mine-octagon-abstract-domain-hosc-2006.md
  - resource: /works/mine-octagon-ast-2001.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
  - resource: /works/cousot-halbwachs-automatic-discovery-of-linear-restraints-.md
  - resource: /works/bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on.md
implemented_by: [/implementations/sbcl.md]
absent_from: [/implementations/chez.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

Intervals fail the moment an array length is symbolic. `(flvector-ref v i)` inside a loop
guarded by `(fx<? i (flvector-length v))` needs the relational fact `i < len`, and no
non-relational domain and no type predicate can hold it. Octagons can hold it and cost
`O(n^2)` space and `O(n^3)` time. Pentagons are the domain built to hold exactly that fact
and nothing more expensive: `x in [a,b] and x < y`. This is level 3 of the hierarchy in
`docs/CHEZ-ANALYSIS.md` and our stated implementation target for stage 06.

# Mechanism

An element is a pair `<b, s>`.

`b : Vars -> Intv` is an interval environment, exactly the level-2 domain, lifted pointwise.

`s : Vars -> P(Vars)` is the strict-upper-bound map `Sub`. `y in s(x)` means `x < y`.
Implement as a variable-indexed array of bitsets. Its lattice is *reverse* inclusion,
because more constraints is more information and therefore lower:

    order     s1 |=s s2  iff  forall x in s2. s1(x) superset-of-or-equal s2(x)
    bottom    exists x,y. y in s(x) and x in s(y)        (x < y and y < x)
    top       forall x. s(x) = {}
    join      lambda x. s1(x) intersect s2(x)
    meet      lambda x. s1(x) union s2(x)
    widening  lambda x. s1(x) subset-of-or-equal s2(x) ? s1(x) : {}

`gamma_Sub(s) = intersect over x of {sigma | y in s(x) implies sigma(x) < sigma(y)}`.

**The pentagon operations** (Fig. 6). The order is refined, not a plain product order:

    <b1,s1> |=p <b2,s2>  iff  b1 |=b b2
                          and forall x in s2, y in s2(x).
                                y in s1(x) or sup(b1(x)) < inf(b1(y))

A symbolic constraint on the right is discharged either explicitly on the left or
numerically by the left's intervals. Bottom if either component is bottom, top if both are.
Meet and widening delegate componentwise, and no closure is performed before widening.

The join is the operator that earns the domain:

    <b1,s1> join_p <b2,s2> =
      b_join = b1 join_b b2
      s_join = lambda x. s'(x) union s''(x) union s'''(x)
        where s'   = lambda x. s1(x) intersect s2(x)
              s''  = lambda x. { y in s1(x) | sup(b2(x)) < inf(b2(y)) }
              s''' = lambda x. { y in s2(x) | sup(b1(x)) < inf(b1(y)) }

Keep what both sides assert, plus what one side asserts and the other side's *intervals*
already imply. Nothing new is materialised. This is the transferable idea beyond this one
domain: at a control-flow merge, compute nothing, cross-check what is already written down
against the cheap component. It costs two table lookups and a comparison instead of a
fixpoint.

**No transitive closure, ever.** Saturating `y in s(x), z in s(y) => z in s(x)` is `O(n^3)`
and Clousot does not do it. The lost transitivity is paid back in hand-written transfer
functions that carry bounded transitivity:

    [| x := y - 1 |](s) = s[x -> {y} union s(y)]     (if x does not occur in s)
    [| x == y |](s)     = s[x, y -> s(x) union s(y)]
    [| x < y |](s)      = s[x -> s(x) union s(y) union {y}]
    [| x <= y |](s)     = s[x -> s(x) union s(y)]

**Two transfer functions cross the interval/symbolic boundary**, and they are the ones that
kill real checks. Subtraction eliminates array underflow, where intervals give
`[1,+inf] - [0,+inf] = top`:

    [| r := sub x y |]<b,s> =
      < b[r -> (b(x) - b(y)) meet_i (x in s(y) ? [1,+inf] : top_i)],
        s[r -> inf(b(y)) > 0 ? {x} union s(x) : {}] >

Remainder eliminates array overflow, where the length has no finite upper bound and `Sub`
alone cannot determine the divisor's sign:

    [| r := rem u d |]<b,s> =
      < [| r := rem u d |](b),
        s[r -> inf(b(d)) >= 0 ? {d} : {}] >

Both map straight onto Scheme: `fx-` under a known ordering, and `fxmodulo` with a
non-negative divisor, are the shapes indexing code actually has.

# Preconditions

The analysis runs on a normalised scalar program with named variables, "similar to SSA
form," with the evaluation stack removed and the heap already abstracted. That front-end
work is a precondition, not a detail.

Because there is no closure, precision is bought case by case. The domain gets better only
as you write more transfer-function cases, not by turning on a general saturation rule. A
missing case is a silently weaker analysis, not an error.

Pentagons cannot express `x + y <= k` or any equality like `x + y == 22`. Any obligation
needing a relation between two variables plus a numeric offset is out of reach.

The 88.9% validation rate is a property of the .NET framework's coding style. Run on
Clousot's own source, Pentagons validate 72%.

Where the fact from `(if (fx<? i n) ...)` gets attached is a design decision the domain
itself does not settle. Pentagon's answer is a flow-sensitive map per program point. ABCD's
answer is a fresh name bound only inside the then-arm, a sigma-assignment. Both encode the
same information; pick one deliberately.

# Cost

`O(n^2)` worst case in time and space, from the bitsets. In practice the quadratic step is
skipped or done lazily and the domain behaves close to linearly. Measured on four .NET
assemblies with a two-minute per-method timeout: 88.89% of array accesses validated at about
three minutes per assembly, never exceeding 300 MB of RAM. Intervals alone: 81.45%.
Octagons on the same problem: 1h39m on mscorlib.dll with 20 method timeouts, 35 timeouts
across all four.

Precision given up against Octagon: 177 additional validated accesses on mscorlib.dll. Real,
and small.

# Disagreements

**Closure makes the operator more precise and the analysis less precise.** Miné proves the
closed union is the *best* abstraction (Thm. 10) and that closing before joining is
necessary while closing after is wasted work. Logozzo measured the opposite outcome at the
whole-analysis level. Section 8.1: the closure-based join `join*_p` validated 82.77% on
mscorlib.dll against 83.19% for the cheap join, and 94.56% against 96.35% on
System.Design.dll, while taking 10:33 instead of 3:10 and causing three method timeouts. The
mechanism is stated in the paper: at joins, closure materialises a quadratic number of new
symbolic constraints out of the many distinct integer constants that .NET methods contain,
and those constraints are almost all meaningless. Both results are correct. Miné's is about
one operator on one pair of arguments; Logozzo's is about a fixpoint under a time budget
with a non-monotone widening in the loop. Miné concedes the same point when he writes that
extrapolation operators are naturally non-monotonic, so strongly closed arguments do not
always give a more precise result. This is the authors' own measurement supporting our
choice, and it is buried in section 8.1 rather than stated in the abstract.

**Reduced product versus Cartesian product.** The paper sells a reduced product. Its own
tables say the unreduced Cartesian product `Intv x Sub` validates 88.82% and full Pentagons
88.89%. The whole refined order and the cross-checking join are worth 0.07 percentage
points. If the reduced product turns out fiddly, running both domains side by side captures
almost all of it.

**Set-of-successors versus shortest path.** ABCD represents the same `x < y` fact as a
weight `-1` edge in a difference-constraint graph, which composes transitively for free via
a shortest-path query, where Pentagon's set-of-successors representation does not. Pentagon
recomputes per program point; ABCD builds one graph over e-SSA and answers queries against
it. ABCD's advantage is per-query cost, which matters when re-checking after a
transformation. Pentagon's is that there is no graph to keep consistent.

**Two printing errors in the source paper, both verified against the PDF.** Figure 3's
interval widening `[a1 <= a2 ? a2 : -inf, b1 >= b2 ? b2 : +inf]` is unsound in both halves;
use Cousot's form, which keeps `a1` and `b1`. Figure 5's `Sub` widening
`s1(x) subset s2(x) ? s2(x) : {}` carries the identical one-operand typo and is not an upper
bound of `s1` either; the correct form keeps `s1(x)`. Section 6.2.1's `sub` transfer function
prints `b(inf(y))`, which is not well typed; it means `inf(b(y))`. Section 6.2.2's `rem`
transfer function prints `s[x -> ...]` where the assigned variable is `r` and `x` does not
appear in the statement at all. Section 6.2.2's prose reads "so that any interesting relation
between r and len can be inferred" where it means *no* interesting relation.

# For us

This is stage `06-pentagon` and this document is its specification. Take: the two maps as
the representation with `Sub` as variable-to-bitset; the reverse-inclusion lattice; the
approximate join and not the closure-based one; no transitive closure anywhere; no closure
before widening; the four bounded-transitivity rules; and the `sub` and `rem` transfer
functions.

**Never strongly-close the left argument of a widening.** Miné exhibits a strictly
increasing infinite chain (Fig. 25) produced by a four-line program with non-deterministic
loop exit and test conditions (Fig. 26). Termination of widening rests on replacing more and
more entries with infinity; closure fills them back in. His framing generalises past
octagons: a domain like this is a reduced product of many one-constraint domains, closure is
an n-way reduction between them, and widenings cannot be applied pointwise across a reduced
product. Pentagon's `Sub` has no closure operation at all, so the hazard does not arise and
the widening can delegate componentwise without thought. That is an architectural argument
for this choice, not merely a cost one.

`docs/CHEZ-ANALYSIS.md` places SBCL near this level through `src/compiler/constraint.lisp`,
whose constraint kinds include `< > = >= <=` between variables, which is the strict-
inequality component of a Pentagon. Chez has nothing: grepping `cptypes.ss` for `fx<` finds
only the pass's own internal arithmetic, and there is no `define-specialize` for
`vector-ref` or `flvector-ref`, so writing the guard by hand buys nothing today. That single
gap is the argument for stage 06.
