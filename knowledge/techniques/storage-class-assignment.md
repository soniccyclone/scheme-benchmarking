---
type: technique
title: Storage class assignment
description: Assigns every value a machine location and encoding (unboxed f64 in xmm/zmm, untagged integer, low-tagged immediate, tagged descriptor) and inserts coercions wherever a value crosses between them; this is the pass that produces the speed, and it is bounded by what escape and type analysis can prove.
tags: [unboxing, tagging, data-representation, register-classes, coercions]
sources:
  - resource: /works/leroy-unboxed-objects-and-polymorphic-typing-popl-1992.md
  - resource: /works/dybvig-et-al-bibop.md
  - resource: /works/dybvig-three-implementation-models-for-scheme-1987.md
  - resource: /works/keep-hearn-dybvig-optimizing-closures-in-o-0-time.md
  - resource: /works/ghuloum-an-incremental-approach-to-compiler-construction-2.md
  - resource: /works/burger-waddell-dybvig-register-allocation-pldi-1995.md
  - resource: /works/appel-simple-generational-garbage-collection-and-fast-allo.md
  - resource: /works/cartwright-fagan-soft-typing-retrospective.md
  - resource: /works/chambers-ungar-an-efficient-implementation-of-self-oopsla-.md
  - resource: /works/sussman-steele-scheme-an-interpreter-for-extended-lambda-c.md
  - resource: /works/shivers-control-flow-analysis-of-higher-order-languages-19.md
  - resource: /works/dybvig-et-al-the-development-of-chez-scheme-icfp-2006.md
implemented_by: [/implementations/sbcl.md, /implementations/chez.md]
absent_from: []
pipeline_stage: 08-represent
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-31T00:00:00Z" }
---

# Problem

A value of unknown type must be a tagged descriptor: one machine word, low bits carrying
the type, a heap pointer when the payload does not fit. A double does not fit in 61 bits,
so `(fl+ a b)` on descriptors is two loads, an add, a heap allocation and a store where one
`addsd` should do. Shivers names this exactly (§11.2.1, representation analysis) and does
not solve it. Storage class assignment is the pass that decides, per value, which of a
small fixed set of locations and encodings it lives in, and where the conversions go. Every
later stage can only preserve what this pass decided; a vectorizer cannot pack values that
are not already unboxed.

This document absorbs `tagging`, because the tag scheme is not a separate decision. It is
the encoding of the fallback storage class, and its width sets the boundary of the untagged
one.

# Mechanism

Three layers, in dependency order.

**Layer 1, the tag scheme.** Ghuloum's discipline: low bits carry type, heap pointers get a
3-bit tag, every heap object is 8-byte aligned so those bits are free. Tags are chosen so
conversions are shifts, not table lookups (`integer->char` is a shift by 6 plus an `or`
because the fixnum and char tags were picked to make it so). Chambers, Ungar and Lee's
2-bit variant makes the point sharper: integers need a shift to convert and *nothing at
all* to add, subtract or compare. Chez's hybrid separates the layers by consumer: primary
types in the low three bits, which the mutator reads, and collector-facing metatypes in a
per-segment BIBOP table, which the mutator never touches. Take that split as the design
rule. Storage class assignment then decides only primary representation and can ignore
everything the collector needs.

**Layer 2, the wrap/unwrap discipline.** Leroy gives the theory, and it is a translation,
not an analysis. Define a wrapped and an unwrapped representation per type, define the
coercion pair, and require a coercion at every point where a value crosses from
statically-known to statically-unknown type. Leroy's crossing point is polymorphic
instantiation. Ours is dynamic typing, so the crossings are: escaping arguments, stores
into general vectors and pairs, arguments to unknown callees. Same theorem, our analysis in
place of the instantiation rule.

Two constraints from Leroy §4 that are hard, not stylistic:

1. **Recursive wrapping.** A wrapped object's components must themselves be wrapped. The
   wrapped form of `float × float` is a boxed pair of two *boxed* floats, not a boxed pair
   of two raw floats, because a generic accessor will look inside and no coercion fires.
   Allow a packed f64 pair inside a boxed pair and something will read it as a pointer.
2. **Container layout is fixed at declaration, not at use.** Coercing a `float list` to an
   `α list` elementwise is O(n) in time and space, which is unusable, so a parameterized
   type's layout is fixed once when the type is declared, with components of the parameter
   type always wrapped. The coercions move into the constructors and accessors, which are
   then treated as polymorphic functions used at a specific type. Leroy keeps array
   elements wrapped too, and for a second reason: arrays are mutable, so copying coercions
   would be semantically wrong.

   **Consequence for us: a flat f64 vector must be a distinct type with its own accessors,
   not a specialization of the general vector.** Otherwise packed data cannot legally
   escape into a generic structure. Leroy sketches the alternative (a flat block plus
   access functions, §5.1) and does not implement it.

**Layer 3, the escape and liveness inputs.** Well-knownness decides closure representation
(Keep, Hearn and Dybvig's table keyed on well-known × free-variable count). Assignment
conversion decides which variables need a heap box; Dybvig's `find-sets` computes it and
the *callee* creates the boxes on entry, because the caller cannot know which of its
arguments the callee assigns. And the collector needs to know which stack slots hold
pointers: BIBOP stores three words behind each return point in the instruction stream,
frame size, live-pointer mask, and code-object offset. That last mechanism is what makes an
unboxed f64 in a stack slot safe across a collection.

Algorithm shape:

```
for each binding site b:
    t  <- proven type   (stage 05 / 06)
    e  <- escapes?(b)   (stage 09)
    a  <- used only as an address?(b)
    sc(b) <- select(t, e, a)          ; table lookup, no search
for each dataflow edge p -> c with sc(p) != sc(c):
    insert coerce(sc(p) -> sc(c))
for each store of v into container k:
    assert wrapped(sc(v))             ; recursive wrapping check
```

# Preconditions

- **Inlining has run.** Leroy: inlining a polymorphic function either creates
  `wrap(t)(unwrap(t)(a))` redexes that cancel, or gives the callee a more specific type and
  better representations. Either order pays, and if you inline everything the program
  becomes monomorphic and gets optimal layout. Storage class assignment runs after inlining
  for exactly this reason. Gallium did no inlining at all, and Leroy's slowdowns are the
  bill for that.
- **Assignment conversion has run.** RABBIT's CLOSE-ANALYZE keeps a third variable set
  purely because of `ASET'`: a mutated variable must have exactly one home, so it is forced
  out of registers into the shared environment before any closure is built. Assignment and
  escape analysis precede register assignment, not the other way round.
- Escape facts. Without them every value that might be stored anywhere gets the descriptor.
- 8-byte alignment, stack maps from the code generator, collector cooperation for unboxed
  stack slots.

# Cost

Compile time is negligible; it is a linear pass over the IR plus a table lookup per binding.
The real cost is the analyses that feed it.

The run-time cost is coercion at boundaries, and it can go negative. Leroy's test 7 (`quad
quad (λx. x+1)` over Church numerals) is a *slowdown*, because `double`'s closure is used at
`α`, `α → α` and `(α → α) → (α → α)` in quick succession and the program spends its time
switching representations. Tests 3 and 4 show mild slowdowns from stub-code call overhead
around functional arguments. The payoff on the cases it fits is large: on a DECStation
5000/200 against the same compiler with boxed representations, Takeuchi 3.00 vs 5.09,
integral 0.80 vs 2.83, solitaire 5.84 vs 10.8, Boyer 1.80 vs 2.76, with C at `-O2` on the
three it ran at 1.96, 0.40, 0.70. Numeric code approaches C; symbolic code gains from
unallocated tuples and closures even though its data types stay boxed.

Space cost: recursive wrapping means three heap objects where a naive scheme has one.

Precision given up: anything that might escape gets the descriptor, and "might" is whatever
the escape analysis cannot refute. Burger, Waddell and Dybvig's measurement biases this the
right way, though — over two thirds of Scheme activations make no call on the path actually
taken, so the boxed/unboxed decision should favour the call-free path.

Leroy's own open problem is still open and still the right one: every cost here is an
*eager* coercion at a boundary the program may not actually cross. Lazy coercions are
listed as future work in 1992 and nobody in this bundle implements them.

# Disagreements

**Boxed wrapped integers versus low-tagged immediates.** Leroy boxes wrapped ints so that
every value of type-variable type is a valid heap pointer, and is explicit that this is what
buys a simple exact copying collector instead of an ambiguous-roots collector. Chez and
Ghuloum use low-tagged immediate fixnums and keep an exact collector anyway, because the tag
distinguishes. Both are coherent; Leroy states the alternative he rejected. Given the BIBOP
work we take Chez's, and pay 61-bit fixnums for it.

**Where the object's format lives.** Appel enumerates three schemes (a tag word per record,
a per-region layout lookup by address, which is BIBOP, and a compiler-supplied map of the
static type system) and chooses the tag word. Dybvig, Eby and Bruggeman choose the second
for collector metadata and low tags for the mutator. Same menu, different pick, and the
difference is visible to this pass only through how much header the wrapped representation
costs.

**Where the type fact comes from.** Cartwright and Fagan's soft typing infers it. The
reprinted 1991 paper undercuts that for our purposes twice: adding the `SUB` rule destroys
principal types (Example 4), and Example 9 shows an inference result at a definition
silently constraining what is legal at a *distant* call site. A programmer cannot predict
which typing the compiler picks, so cannot predict whether the inner loop unboxes.
Declaration-anchored assignment does not have that failure mode. This is a disagreement
about the input, not about the table.

No source in the bundle contradicts Leroy §4 on recursive wrapping or on fixed container
layout. On that point the sources agree, and the agreement is load-bearing.

# For us

Stage `08-represent`. The CUJ's six-row table is right as far as it goes. Three amendments:

Add a closure row. Keep, Hearn and Dybvig's decision table (well-known with 0 free
variables: delete; 1: replace with the variable; 2: a pair; ≥3: a vector; not well-known
with 0: statically allocate) is representation selection keyed on a proven property plus a
count, which is the same mechanism as the rest of the table, not a separate pass.

Decide `f64vector` as a distinct type in stages 03 and 04, not in stage 08. This is a
language design consequence of a compiler constraint, and it is the constraint that will
bite `10-vectorize` when packed data escapes into a generic structure.

Adopt the never-do-harm rule verbatim from Keep, Hearn and Dybvig: nothing here may add an
allocation or a memory operation relative to the naive case. Our pitch is predictable
performance from declarations, and an optimization that sometimes regresses makes the cost
model unteachable.

On the untagged loop index row specifically: this is the row the interval domain buys, and
it is the one Chez cannot express. `CHEZ-ANALYSIS.md` §4 confirms `index`, `length`,
`sub-index` and `u8` all collapse to `fixnum-pred` in `cptypes-lattice.ss` lines 573-574,
so Chez has the tagging half of this technique and the flonum-unboxing half (`fl+` carries
`unboxed-arguments`) but cannot represent the range fact the untagged row needs. SBCL's IR2
storage classes cover all of it.
