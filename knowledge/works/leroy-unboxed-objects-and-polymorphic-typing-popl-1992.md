---
type: paper
title: "Unboxed objects and polymorphic typing"
description: A type-directed source-to-source translation that inserts wrap/unwrap coercions at polymorphic instantiation points, so monomorphic code can use unboxed multi-word representations while polymorphic code is still compiled once.
resource: knowledge/sources/leroy-unboxed-objects-and-polymorphic-typing-popl-1992.pdf
tags: [unboxing, data-representation, polymorphism, coercions, calling-conventions]
authors: [Xavier Leroy]
year: 1992
venue: "POPL 1992, pp. 177-188"
informs: [/techniques/storage-class-assignment.md, /techniques/procedure-inlining.md, /techniques/generational-gc.md]
pipeline_stage: 08-represent
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-31T00:00:00Z" }
---

# Contribution

Establishes precisely where unboxing is legal in a language with parametric polymorphism,
and gives a translation rather than an analysis. Prior answers were: specialize per
instantiation (Ada generics; kills separate compilation, duplicates code), or make
everything one word (every ML compiler of the day; kills numeric performance), or restrict
polymorphism so type variables only range over boxed types (Peyton Jones). Leroy's answer:
compile polymorphic code *once* under the assumption that anything of type variable type is
one word in a default location, and insert coercions at the boundary where a polymorphic
value is used at a more specific type. The paper proves the translation preserves both types
and semantics, and reports a working compiler.

# Mechanism

Two representation styles coexist. *Unwrapped*: floats are two unallocated words in an FP
register, tuples are unallocated and spread across registers, closures are two unallocated
words (code pointer, environment pointer). *Wrapped*: everything is one word, boxed if it
does not fit.

The translation is defined on a typing derivation, not on the term. Every rule propagates
translations structurally except one, the variable-instantiation rule. When `x : forall a. t`
is used at `rho(t)`, emit `S_rho(x : t)`, where `S` walks the *type* inserting coercions:

```
S_rho(a' : alpha)     = unwrap(rho(alpha))(a')
S_rho(a' : int)       = a'
S_rho(a' : float)     = a'
S_rho(a' : t1 x t2)   = let x = a' in (S_rho(fst x : t1), S_rho(snd x : t2))
S_rho(a' : t1 -> t2)  = \x. S_rho(a'(G_rho(x : t1)) : t2)
```

`G` is the dual (`wrap` at type variables) and appears in the argument position of the arrow
case because the arrow is contravariant. The higher-order case is the interesting one: it
does not recompile the functional argument, it wraps it in stub code. `map_pair
int_of_float` becomes `map_pair (\x. wrap(int)(int_of_float(unwrap(float)(x))))`.

Target type system makes the discipline explicit: add a type former `[t]` for "wrapped t",
and restrict instantiation so a type variable may only be instantiated by a wrapped type.
Then "objects of type-variable type are one word" is a theorem about well-typed target
terms, not an assumption. Type correctness (Prop 1) is one lemma about `S`/`G` plus
induction; semantic correctness (Prop 2) needs a size-indexed logical relation
`Gamma |= v : t ~ v' : t'` where legal interpretations of a type variable are sets of value
pairs whose second component has size 1. Sizes are assigned: `int` 1, `float` 2, arrow 2,
product is the sum, `[t]` 1, `alpha` 1. `wrap` is boxing when size > 1 and a no-op when
size = 1; the operational semantics for the target adds a new failure mode, applying a
closure to an argument of the wrong size.

Concrete data types (section 4) are where the naive reading breaks. Coercing a `float list`
to an `alpha list` elementwise is O(n) in time and space, which is unusable, so the rule is
that a parameterized type's layout is fixed *once, at declaration*, with components of the
parameter type always wrapped. Then `S_rho(a' : t list) = a'`, and the coercions move into
the constructors and accessors, which are treated as polymorphic functions used at a
specific type. This forces *recursive wrapping*: the wrapped form of `float x float` must be
a boxed pair of two boxed floats, not a boxed pair of two raw floats, because a function of
type `forall a. (a x a) list -> ...` will look inside and no coercion fires on a list. So
`wrap` and `unwrap` for products and arrows are redefined in terms of `G` and `S` at the
type constructor, not at the whole type. Sum types stay boxed always, both because a sum's
size is only bounded, not known, and because they can be recursive.

Implementation (Gallium, Caml Light to MIPS R3000): unwrapped ints are raw 32-bit, wrapped
ints are boxed, so that every value of type variable type is a valid heap pointer. That is
what buys a simple exact copying collector instead of an ambiguous-roots collector. 8-bit
integers (bool, char) stay unboxed in both states. Unit is the empty tuple unwrapped and a
constant wrapped. Closure environment is boxed unless it fits in one word; the paper is
explicit that types cannot help here, since a function's type says nothing about its free
variables. Arrays keep elements wrapped, like lists, because they are mutable so copying
coercions would be semantically wrong. GC uses machine-level type headers, per-frame
descriptors of `address`-typed slots, and a table of global address locations.

# Applicability

Preconditions: a principal typing derivation, and types of external identifiers available,
which any module system gives, so separate compilation survives. No static analysis is
required at all, which is the load-bearing practical claim; escape and boxing analyses of
the era were expensive and failed on higher-order code, and this fails on neither.

Failure mode is real and measured. Test 7 (`quad quad (\x. x+1)` over Church numerals) is a
*slowdown*, because `double`'s closure is used at `alpha`, `alpha -> alpha`, and
`(alpha -> alpha) -> (alpha -> alpha)` in quick succession and the program spends its time
switching representations. Tests 3 and 4 (list summation, sieve) show mild slowdowns from
stub-code call overhead around functional arguments. The fix offered is compile-time
reduction of the redexes the translation creates, plus inlining, and the author admits
Gallium does no inlining at all.

Benchmarks (DECStation 5000/200, vs. a version of the same compiler with boxed
representations): Takeuchi 3.00 vs 5.09, integral 0.80 vs 2.83, solitaire 5.84 vs 10.8,
Boyer 1.80 vs 2.76. C at `-O2` was 1.96, 0.40, 0.70 on the three it ran. Numeric code
approaches C; symbolic code gains from unallocated tuples and closures even though its data
types stay boxed.

# Relevance

This is the theory for `08-represent`, and it is worth being precise about the mismatch.
Leroy's boundary is *static polymorphism*; ours is *dynamic typing*. Scheme has no `forall`
to instantiate, so there is no syntactic site where a coercion obviously belongs. What
transfers is the discipline, not the algorithm: define a wrapped and an unwrapped
representation per type, define the wrap/unwrap coercion pair, and require that every point
where a value crosses from statically-known to statically-unknown type inserts the coercion.
For us the crossing points are the ones our type recovery cannot prove: escaping arguments,
values stored into general vectors and pairs, arguments to unknown callees. That is the same
theorem with our own analysis in place of the instantiation rule.

Three specific rules to adopt outright:

1. **Recursive wrapping.** A wrapped object's components must themselves be wrapped. If we
   allow a packed f64 pair inside a boxed pair, some generic accessor will read it as a
   pointer. This is exactly the constraint that will bite `10-vectorize` when packed data
   escapes into a generic structure.
2. **Fix container layout at declaration.** Vectors and lists keep elements wrapped. The
   coercion goes into `vector-ref` and `vector-set!`, not into the vector. Flat f64 vectors
   must be a *distinct type* (an f64vector) with its own accessors, not a specialization of
   the general vector, precisely because Leroy shows the coercion is O(n) otherwise. Section
   5.1 sketches the alternative (flat block plus access functions) and does not implement it.
3. **Box wrapped integers so every type-variable-typed value is a valid pointer.** This is
   what lets the collector be exact and simple. Chez's answer is different, low-tagged
   immediates, and given the BIBOP work we will take Chez's; but Leroy is clear about the
   trade being made and the alternative he rejected (ambiguous-roots collection).

The inlining note is directly actionable for `07-compiler`: inlining a polymorphic function
either creates `wrap(t)(unwrap(t)(a))` redexes that cancel to `a`, or (if done first) gives
the callee a more specific type and better representations. Either order pays, and if you
inline everything the program becomes monomorphic and gets optimal layout. Our storage class
assignment should run *after* inlining for exactly this reason.

# Notes

Bibliography entry is correct in every field. The PDF's own header reads "Proc. 19th Symp.
Principles of Programming Languages, 1992, pages 177-188", author Xavier Leroy, Ecole
Normale Superieure and INRIA. No correction needed.

The honest part of the paper is section 5.3 and the conclusion. The technique is described
as "essentially local" and the author volunteers the Church-numeral regression rather than
burying it. The claim that "this data representation issue was the main bottleneck that
prevented C-like code written in ML from being compiled as efficiently as in C" is stated as
belief, not measurement, and the benchmark set is eight programs.

One idea listed as future work is still worth pursuing thirty years on: *lazy* coercions,
performed on demand rather than eagerly at the boundary. Every cost in this paper is an
eager coercion at a boundary that the program may not actually cross.
