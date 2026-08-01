---
type: paper
title: "Escape Analysis for Object Oriented Languages. Application to Java™"
description: Extends integer-level escape analysis to a language dominated by assignment by pairing a backward analysis with a forward store-escape analysis, applied to stack allocation and synchronization elimination in a full-Java compiler.
resource: knowledge/sources/blanchet-escape-analysis-oopsla-1999.pdf
tags: [escape-analysis, stack-allocation, synchronization-elimination, java, bidirectional-dataflow]
authors: [Bruno Blanchet]
year: 1999
venue: "OOPSLA 1999, Denver CO"
informs: [/techniques/escape-analysis.md, /techniques/storage-class-assignment.md, /techniques/procedure-inlining.md]
pipeline_stage: 09-alias
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

The engineering paper of the three. Blanchet states the originality precisely: previous escape
analyses, including his own POPL 1998 work, "consider that a value escapes as soon as it is
stored in another value," which is tolerable in a functional language and useless in Java. This
paper determines the effect of assignments precisely, and the mechanism that does it is a
**bidirectional propagation**: a backward analysis `E` and a forward analysis `ES` that depend on
each other.

Three Java-specific problems drive the redesign and are named up front: dynamic dispatch means
the call graph must be resolved before the code can be analyzed; assignment is pervasive; and
subtyping must be carried through the escape representation because that representation is
computed from types.

A second application appears here that has no analogue in the ML work. If an object does not
escape a method it is also local to the current thread, so every `synchronized` call on it can
be replaced by an unsynchronized copy. Synchronization is expensive in the JDK and libraries
synchronize defensively even in single-threaded programs, so this turns out to be worth more
than stack allocation on some benchmarks.

Results: 13-95% of allocated data stack-allocated, more than 20% of synchronizations eliminated
on most programs (94% on JLex, 99% on Symantec), up to 44% speedup with a 21% geometric mean.
Analysis is ~10% of compile time; total compile overhead ~34%.

# Mechanism

**Type heights.** `⊤[τ]` is the smallest integer such that

```
(1) ⊤[τ] ≥ 1
(2) τ' ∈ Cont(τ)                    ⇒  ⊤[τ'] ≤ ⊤[τ]
(3) τ subtype of τ', τ ≠ Object     ⇒  ⊤[τ] ≤ ⊤[τ']
(4) if that contradicts neither (2) nor (3):  τ' ∈ Cont(τ) ⇒ 1 + ⊤[τ'] ≤ ⊤[τ]
```

Only (2) is needed for correctness. (3) keeps type conversions from losing precision, since a
conversion between a type and its subtype then becomes the identity. (4) distinguishes as many
levels as possible. Computed by splitting the graph of `Cont ∪ subtype` into strongly connected
components — same height inside a component, +1 between — in O(t) for `t` distinct types.

The escaping part of an object is the height of the type of that escaping part. An object of
type τ can be stack allocated when its escape context is strictly less than `⊤[τ]`.

**Why two analyses.** `E` propagates backward from the result to the parameters: what is read to
build the result escapes. It cannot handle "o escapes because it was stored into a parameter
`o'`", because at the assignment point a backward analyzer does not yet know `o'` is a parameter.
`ES` propagates forward and computes *store-escape*: if you store an object `o'` into `o`, does
`o'` escape. The two are mutually recursive.

**Abstract values are context transformers with a type attached.**

```
Val = ⋃_{n ∈ ℕ} ((Ctx^n → Ctx) × Type^n × Type)
```

The trailing `Type` is the type the analysis currently assumes for the value. Java has casts and
subtyping, so the static type of one object varies over its lifetime and the transformer is
meaningless without knowing which type its integers are relative to. Operations defined on this
domain: `convert(τ,τ')`, upper bound (converting to the *highest* type, which is the
precision-preserving choice), construction `cons_f` / `cons_A`, restriction `cons_f⁻¹` /
`cons_A⁻¹`, and composition.

**The assignment rule, and why it looks wrong.** For `x.f = y` at pc:

```
E(pc, Sta(0)) = cons⁻¹_(C,f,t)(ES(pc, Sta(1)))     when x.f escapes, y escapes
E(pc, Sta(1)) = cons_(C,f,t)(ES(pc, Sta(0)))       when y escapes, x.f escapes
```

The second is the surprising one. Example 2.8 shows it is necessary:

```
C.static_field = y;
x.f = y;
x.f.f' = z;
```

`y` escapes into a static field. Without the second equation the escaping parts of `x` would be
empty and we would conclude `z` does not escape, which is wrong — the code is equivalent to
`y.f' = z` and `y` escapes.

**Stack allocation criterion (Theorem 2.3).** For a `new` at pc with
`E(pc, Sta(0)) = (φ, (τ₀…τⱼ), τ')`: if `φ(⊤[τ₀], …, ⊤[τⱼ]) < ⊤[τ']` the object can be stack
allocated. Intuitively: assume the parameters and result escape, then test the allocated object.

**Additivity (Theorem 2.4)** lets `φ` split as `g₀(c₀) ⊔ … ⊔ gⱼ(cⱼ)`, so only monotone `ℕ → ℕ`
functions have to be represented. Those are built from constants, identity, intersection
`n ↦ n ⊓ ⊤[t]`, and step `n ↦ if n ≥ ⊤[τ] then ⊤[τ'] else 0`, which suggests the general form

```
λc. (if c ≥ s then i⁺ else 0) ⊔ (c ⊓ f) ⊔ i
```

This cannot represent every monotone function, so upper bound, composition and array-to-array
conversion get explicit approximate definitions (§3.1). A **sparse representation** carries only
the parameters a context actually depends on, which is what keeps the quoted complexity from
being the real cost.

**Virtual calls** use class hierarchy analysis: every method with the right signature defined in
a subclass of `C` may be called, and the environments are the join over redefiners.

**Reusing allocated space in loops.** An allocation inside a loop grows the stack every
iteration, which can overflow, and stack-referenced data is pinned alive by a conservative
stack scan. The criterion for reuse: *assume every variable live just before the allocation
escapes; if the allocated object still does not escape, the space can be reused next iteration.*
Implemented by emitting, per live variable, `φ(p₀…pₙ) ⊒ p_k ⊓ ⊤[tᵢ]` with a fresh parameter
`p_k` that is 0 for the normal analysis and 1 for the reuse question. One extra parameter per
in-loop allocation.

**Inlining to create opportunities.** An object may be live at the end of `m` but dead at the end
of its caller `m'`; inline and stack allocate in `m'` (Theorem 3.1, extended to call chains).
Storing every interesting inlining chain is quadratic in program size, so instead each method
keeps three constant-size summaries, all *(j+1)-cells* — right-angled parallelepipeds in
`ℝ^{j+1}` with sides on the coordinate axes:

- `m.inter_cond` — all stack allocations succeed if the entry escaping parts land in it
- `m.maxvol_cond` — the largest-volume cell for an allocation that requires inlining
- `m.englob_cond` — a cell containing every cell for an allocation not certainly done without inlining

Then `C ∈ maxvol_cond` ⇒ inline; `C ∉ englob_cond` ⇒ do not; otherwise fall back to the exact
computation. The fallback fired **21 times across more than 2 Mb of classes**.

**Synchronization elimination**, two transformations combined. A global analysis proves that
over every call chain from `main` or `Thread.run`, the receiver does not escape, and calls an
unsynchronized copy. Plus a runtime "is this object on the stack" test before acquiring a lock.
The second one is worth a lot: on `javac` it takes elimination from 5% to 31%, on `turboJ` 21%
to 46%, on JLex 78% to 94%.

**Complexity.** With `n` bytecode size, `l` local variables, `s` stack height, `p` method
parameters, `p'` context parameters, `H` maximum type height: equation building `O(n(l+s)p')`,
`O(n(l+s))` equations and unknowns, `ni = O(n(l+s)p'H)` iterations, solving `O(n(l+s)pp'ni)`,
total `O(n²(l+s)²pp'²H)`. In practice `ni ≤ 17`, average 3.9 per equation, with 44.8% of
equations iterated at most twice.

# Applicability

**Needs the whole call graph.** Dynamic dispatch means class hierarchy analysis first. Separate
compilation of libraries is supported but costs precision.

**Needs types**, harder than in the ML paper — the escape representation *is* the type height,
and subtyping is what forces the type tag onto every abstract value.

**Not control-flow sensitive.** The result does not depend on the order of assignments to fields
of objects. Example 2.7 gives the case it loses: `putstatic` followed later by
`aconst_null; putstatic` on the same field does not un-escape the variable, because the analyzer
believes it escapes as soon as it sees the first `putstatic`. Blanchet says fixing it needs alias
analysis, which is much more costly, and that experiments show the loss does not matter.

**Aliases are never removed.** Overwriting does not kill.

**Stack overflow is a real failure mode.** In the "All" configuration (`alloca` allowed inside
loops), the stack grows by a factor of 10 for `javacc` and 129% for JLex. The "No loops"
configuration caps `javacc`'s growth at 75%. Blanchet recommends "No loops" and notes that even
a single allocation of a very large array could overflow; a dynamic size test would fix it but
is not implemented.

**Inlining can lose.** It hurts `turboJ` and `jess`, from code size and from disturbing register
allocation. `jess` ends up net *slower*, -1% to -3%.

# Relevance

Read this one for the *shape* of the algorithm, not the domain. The Java object model —
subtyping, casts, `synchronized`, the operand stack — is not ours, and the pieces that exist to
serve it (type conversion, the `Type` tag on every abstract value, the whole synchronization
half) do not transfer.

What transfers is the answer to the question the ML paper dodged: how to handle mutation
precisely. Scheme has `set!`, `set-car!`, and vectors. If we take the POPL 1998 analysis at face
value, `(vector-set! v 0 x)` makes `x` escape unconditionally, which will kill exactly the
numeric-kernel case that matters to us — an flvector written in a loop. The bidirectional
`E`/`ES` construction is the fix, and the two-equation rule for `x.f = y` with Example 2.8's
justification is the part to copy.

The second transferable piece is the **inlining-driven opportunity discovery**. Blanchet's ML
data says inlining takes Coq from 11% to 25% stack-allocated; here it accounts for 4% of javac's
data, 20% of turboJ's, 29% of javacc's. That means our stage 09 cannot be a one-shot pass placed
after inlining decisions have been finalized — the escape criterion is an *input* to the
inlining decision. The `(j+1)`-cell summary is how you get that without quadratic blowup.

The third is negative and useful: **the loop-reuse criterion**. Every Scheme loop is a tail-recursive
call, and if we stack-allocate inside one without the reuse test we grow the stack without bound.
"Assume everything live before the allocation escapes; if the object still does not escape, reuse
the slot" is a cheap criterion expressed inside the same analysis, needing only one extra
parameter.

# Notes

**The GC finding reverses relative to the ML paper, and Blanchet says so explicitly.** In ML,
data locality dominated and GC contributed little. In Java the speedup is roughly half GC, a
quarter locality, a quarter allocation time. The cause is named: the JDK used a mark-and-sweep
collector, which is bad at short-lived data, while CSL had a generational collector for which
short-lived data was already nearly free. **Which way this goes for us is decided by our
collector, not by the analysis.** Our plan specifies a precise generational copying collector,
which puts us on the ML side of that line: expect locality and allocation-time wins, not GC
wins.

**Choi et al. is cited but not compared numerically.** Reference [9], "uses an escape analysis
based on connection graphs… similar to alias graphs and points-to graphs but can be easier
summarized… It is however more costly than ours." That is the whole comparison in this paper.
The substantive comparison appears only in the TOPLAS version.

**Blanchet declines a precision improvement on cost grounds and is candid about it.** §2 Example
2.7: assignments that *decrease* the alias set could improve precision "but at the cost of an
increased complexity."

**Benchmark sizes here exclude the Java standard library** ("the size is the total size of the
.class files, Java standard library excluded"), which is why `dhry` is listed at 6 kb. TOPLAS
reports the same benchmarks on the other basis and lists `dhry` at 73 kb. Do not compare the two
tables.

**Extraction artifact.** `pdftotext` drops `ff`/`fi`/`ffi` ligatures throughout — "e ect",
"de ne", " rst", "speci c". Subscripts and superscripts detach from their bases in the formula
figures, so Figure 5's transition table and §3.1's approximate composition should be read from
the PDF rendering rather than from extracted text if the exact formula is needed.
