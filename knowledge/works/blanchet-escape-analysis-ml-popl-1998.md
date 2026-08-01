---
type: paper
title: "Escape Analysis: Correctness Proof, Implementation and Experimental Results"
description: Backward escape analysis for a full functional language including references, polymorphism and inductive types, abstracted from access paths to integer type levels so it runs in O(n log² n), implemented in Caml Special Light and measured on 65,000 lines of Coq.
resource: knowledge/sources/blanchet-escape-analysis-ml-popl-1998.pdf
tags: [escape-analysis, stack-allocation, abstract-interpretation, functional-languages, type-levels]
authors: [Bruno Blanchet]
year: 1998
venue: "POPL 1998, San Diego (ACM 0-89791-979-3/98/01), pp. 25-37"
informs: [/techniques/escape-analysis.md, /techniques/storage-class-assignment.md, /techniques/procedure-inlining.md]
pipeline_stage: 09-alias
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

Three things, and the third is the one that matters.

**A correctness proof from the semantics, not from another analysis.** Park and Goldberg
introduced escape analysis on lists; Deutsch cut the complexity to O(n log² n) with the same
results on first-order expressions. Both proofs were relative. Blanchet starts from a
denotational semantics with an explicit store and proves the analysis against it, and in doing
so covers what the earlier proofs did not: `ref`/`!`/`:=`, pairs, polymorphism, arbitrary
inductive types, and an approximate treatment of higher-order functions.

**An implementation inside the O(n log² n) bound, in a real compiler**, Caml Special Light,
under 5000 lines, applied to Coq at 65,000 lines. Intermodular: escape information is written
to a file and reused.

**The measurement that overturns the folk justification.** Everyone assumes stack allocation
pays by reducing GC work. It does not. Figure 19 separates the two: the GC's contribution to
the speedup is 0-3% on most benchmarks while total speedup is 5-25%. The speedup is *data
locality*. The explanation is direct — stack allocation catches short-lived data, and
short-lived data is exactly what a generational minor collection never scans, so it was already
nearly free. `taku` allocates 12 Mwords through a 32 kword minor heap without the optimization
and uses under 1 kword of stack with it. Blanchet also takes a position on Appel's "garbage
collection can be faster than stack allocation": true only when there is much more memory than
needed.

# Mechanism

**Analysis E, on access paths.** Applies to any functional language, "even untyped" (§3), and
is too complex to implement directly. It is the semantic reference that the fast version is
abstracted from.

```
Path = l:Path | r:Path | app:Path | ⊤ | ⊥
```

`⊤` the whole value is used, `⊥` nothing is used, `l` left of a pair / head of a list /
contents of a reference, `r` right of a pair / tail of a list, `app` the value is a function
that gets applied. Contexts are *non-empty* sets of paths, and the non-emptiness is load-bearing:
under call-by-value an expression is evaluated even when its result is unused, and that
evaluation can cause escapement through assignment.

Abstract values are context transformers, `Exp# = Val# = Ctx → (Var ∪ Ind) → Ctx`. Given the
escape context of the result, they yield the escape context of each free variable and each
parameter index. `E[[M]]ρ` is defined by structural equations (Figure 7); it is a **backward**
analysis.

The subtle soundness condition is **δ-transitivity**: `f` is δ-transitive if for all `y` in the
lexical scope of `x`,

```
f c x ⊔ [[y]] ⊥ x  ⊑  [[y]] (f c y) x
```

which says the analysis accounts for locations escaping *through an intermediate variable*.
Blanchet shows by counterexample that you cannot skip it. In

```
let rec f(x) = ... z := f ... in f(3)
```

`E[[f(3)]] ⊤ = app:⊤` is correct with respect to the correctness predicate, so the naive
criterion would wrongly conclude `f` does not escape.

**Theorem 3.5, the usable criterion.** For `let x = M in N`, if the creation of the location ℓ
at the top of `x` is the last operation in `M`, and `⊤ ∉ E[[N]] ⊥_Path x`, then ℓ can be stack
allocated.

**Analyses F1 and F2, on integers.** The abstraction that makes it implementable. Type levels:

```
⊤₂[τ] = 1                              if τ ∈ {bool, int, unit}
⊤₂[τ₁ → τ₂] = ⊤₂[τ₂]
⊤₂[τ₁ × τ₂] = 1 + max(⊤₂[τ₁], ⊤₂[τ₂])
⊤₂[τ list]  = 1 + ⊤₂[τ]
⊤₂[τ ref]   = 1 + ⊤₂[τ]
⊤₁[τ] = 1 if τ contains a functional type, 0 otherwise
```

`(α₂, γ₂)` and `(α₁, γ₁)` are semi-dual Galois connections from `Ctx` to `ℕ ∪ {∞}` and to
`{0,1} × ℕ`. **Two analyses, not one, and the reason is specific:** the level of a variable
captured in a closure may exceed the level of the closure itself, so the escape function would
not be *inferior* and Knuth's solver would not apply. F1 tracks escape through closures
(boolean), F2 gives precise levels for everything else.

Stack allocation criterion, condition (13):

```
if neither N nor x is functional:  F₁[[N]] ρ₁ 0 x = 0  and  F₂[[N]] ρ₂ ⊤₂N x < ⊤₂x
if N is functional:                F₁[[N]] ρ₁ 1 x = 0
otherwise:                         F₁[[N]] ρ₁ 0 x = 0
```

**Inductive types.** The level must satisfy: if a value of type τ₁ can sit inside a value of
type τ₂ then `⊤₂[τ₁] ≤ ⊤₂[τ₂]`. So all types in one strongly connected component of the
containment graph share a level, and you add 1 between components. Types where the constraint
cannot be satisfied (`type α t = None | Some of α × α list t`, infinitely many distinct
`α list…list t`) are called *not level preserving*, get level ∞, and are handled like functional
types. Blanchet notes such a type has no practical use since you cannot write an iterator on it.

**Polymorphism.** Analyze monomorphically with type variables atomic (`⊤₂[α] = 1`), then infer
instantiations via `I₂`/`G₂` (and `I₁`, `G₁ = id`). The analysis is **not polymorphically
invariant**: instantiating can be *more* precise than analyzing the instance directly, or less.
Theorems 4.6 and 4.8 prove instantiation and generalization correct anyway. The enabling fact
is that every function the analysis manipulates has the form `λc.(c ⊓ a) ⊔ b`, and that form is
closed under composition, meet and join.

**Solving.** Equations are a tree; nodes are occurrences of `Fk[[M]]ρ`, edges are operations
`λc.(c ⊓ f) ⊔ i` represented as pairs `(f, i)`. Composition:

```
(f₁, i₁) ∘ (f₂, i₂) = (f₁ ⊓ f₂, (i₂ ⊓ f₁) ⊔ i₁)
```

`eval(n)` composes the edges from node `n` to the root with Tarjan **path compression**,
maintaining `Fk[[M]]ρ = ⊔_{x ∈ FV(M), n ∈ σ(x)} ρ[[x]] ∘ eval(n)`. The system is solved with
Knuth's generalization of Dijkstra's shortest-path algorithm, which gives the least fixed point
of `Y = ⊔ᵢ gᵢ(X₁…Xₖ)` when the `gᵢ` are *inferior* (`gᵢ(x₁…xₖ) ≤ min(x₁…xₖ)`). The instantiation
function `I₂` is not inferior, which would break this. The fix: split into strongly connected
components, solve each with Knuth's algorithm, approximate instantiation *inside* a component by
the constant function equal to the type level (less precise, still correct), and use the precise
instantiation *between* components, which is the common case.

**Complexity.** Equations, unknowns, and time to compute all right-hand sides are O(n log n)
after Deutsch, giving `O(e log u + r) = O(n log² n)` solving. The program transformation does
O(n) path compressions in an O(n) forest, so O(2n log n). Total O(n log n + t) with `t` the
type-level computation time, which is bounded by the size of the type declarations used. With
inlining bounded by a user-set maximum inlined size `I`, O(nI + n' log n' + n log² n).

**The transformation, which is half the paper's practical value.** Two forms:

- `letstack x = M in N` — stack allocate the outer constructor of `x`, deallocate at the end of `N`.
- `letstack' x = M in N` — same, but deallocate *before* the tail call of `N`, so tail call
  optimization survives.

`C[let x = M in N]` becomes `letstack x = M in C[N]`. The head of `M` must be an allocator (a
type constructor or an allocating primitive). Choose `C[]` **as small as possible** to minimize
the time `x` sits on the stack; the lets are collected in a tree whose edges carry context
transformers, path-compressed with Tarjan's algorithm as the walk goes up the AST, and a let is
emitted as soon as it stops escaping the current expression. Evaluation order constrains this:
CSL evaluates right to left, so stack-allocating `Mᵢ` in `M₀ M₁ … Mₙ` requires let-binding every
`Mⱼ` with `j > i` outside it.

Putting a `letstack` in tail position inside a recursive loop grows the stack every iteration
and can crash the program; that is why `letstack'` exists and why the three configurations
(All / Rec. / None tail calls preserved) are measured separately.

**Inlining as an enabler.** Small allocating functions are inlined only when this actually
creates a stack-allocation opportunity. `let f x = [x];; hd (f 3)` becomes
`hd (let x = 3 in [x])` and then `let x = 3 in letstack %t1 = [x] in hd %t1`.

# Applicability

**Needs a type system.** Analysis E works on untyped functional languages, but E is explicitly
unimplementable. The fast analysis is `α₂`, and `⊤₂[τ]` is defined only over types. Without
types there are no levels, and without levels the O(n log² n) representation as a pair of
integers per edge does not exist.

**Needs call-by-value.** Non-empty contexts, and the whole treatment of "evaluated even when
unused," assume it.

**No first-class continuations.** The semantics of Figure 4 has no control operator. `callcc`,
`throw`, and the RABBIT problem are simply outside the paper.

**Precision on assignments is poor by design.** A value escapes as soon as it is stored into
another value. That is stated as adequate for functional languages and is exactly the
limitation the 1999 and 2003 Java papers exist to fix.

**Higher-order costs precision** and the paper says so, citing Deutsch: the loss is unavoidable
in the higher-order case.

**Compile-time cost is real.** Analysis alone is 16-19% of compile time; the total compile is
19-21% longer because the transformed code takes longer to compile too. Measured near-linear in
practice (Figure 20) because each recursive declaration is analyzed independently, reducing the
effective `n`.

# Relevance

This is the paper in the bundle closest to our shape: a backward, whole-function, AST-level
escape analysis for a strict functional language with mutable references and closures,
implemented in a production compiler and measured. Stage `09-alias` should be built from this
and not from Steensgaard.

Three things carry directly. First, the **δ-transitivity condition** — our escape predicate must
account for escape through intermediate bindings, and Blanchet's counterexample shows a naive
predicate is unsound in exactly the recursive-closure case Scheme is full of. Second, the
**minimal-lifetime transformation**: it is not enough to prove a value does not escape, you have
to place the deallocation as early as possible, and the Tarjan-path-compression trick that does
it is cheap. Third, the **`letstack'` distinction** — stack allocation and tail calls fight, and
in a Scheme where every loop is a tail call, this fight is our default case, not an edge case.
Blanchet's data says preserving recursive tail calls costs little stack allocation on most
programs and prevents unbounded stack growth.

The thing that does *not* carry is the cheap representation. Our integer levels would have to
come from the type recovery / soft typing layer. That makes escape analysis **downstream of
type recovery**, which is a pipeline constraint we did not have written down.

Numbers to size any proposal against: 25% of Coq's 5.25 gigawords stack-allocated (17% when
recursive tail calls are preserved), for a 3-4.3% speedup on Coq. Small benchmarks do far better
— `taku` 74% of memory stack-allocated for a 25% speedup — but Coq is the honest one at scale.
Without inlining, Coq could not exceed 11%.

# Notes

**Title correction.** The bibliography and this file's slug call this "escape analysis for ML."
The paper's own title page reads *Escape Analysis: Correctness Proof, Implementation and
Experimental Results*. The word "ML" appears nowhere in the title; the ML connection is that the
implementation is in Caml Special Light. Cite it by its real title.

**The GC result is the paper's most useful finding and it is counter-intuitive.** Figure 19
shows GC speedup of 83-100% on `taku`/`reynolds2` yet only a 2-3% contribution to total runtime,
because GC time was a small fraction to begin with. The speedup is locality. This confirms Jones
and White's "is compile time garbage collection worth the effort." It also means our own
justification for escape analysis should be phrased in terms of cache behaviour and unboxing,
not GC pressure — and it is a direct warning that a bundle-level argument of the form "escape
analysis cuts allocation therefore it cuts GC therefore it is fast" does not survive measurement.

**The result is machine-dependent in a way that would not be reported today.** On Sparc 5 and
Alpha, abandoning tail call optimization gives the best speedups. On Pentium Pro, preserving
recursive tail calls is often better. Blanchet explains it: stack allocation pays more when the
allocated data is larger, so a size threshold exists above which stack allocation beats tail
call optimization, and where that threshold sits depends on cache and GC behaviour. He also
flags abandoning tail calls as **unsafe** — it can overflow the stack — and only says it did not
happen on these benchmarks.

**Inlining alone slows things down.** On Sparc 5 the "let" curve for `nucleic-inl` is negative;
Blanchet attributes it to larger code transfer between memory and chip. Inlining pays here only
because it unlocks stack allocation.

**Extraction artifact.** `pdftotext` on this PDF drops the `ff`/`fi`/`ffi` ligatures — "e ect"
for "effect", "de ne" for "define", " rst" for "first". Superscripts detach, so the abstract's
`O(n log² n)` extracts as "the small complexity bound of O(n log n)" with a stray `2` before
"implemented". The bound is O(n log² n) throughout; do not propagate the stray reading.
