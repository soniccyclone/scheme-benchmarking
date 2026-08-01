---
type: paper
title: "Escape Analysis for Java™. Theory and Practice"
description: The journal treatment of Blanchet's Java escape analysis, adding the correctness proof the OOPSLA paper omitted via a novel dated-alias-relation technique, an explicit four-level abstraction hierarchy, SSA-based flow sensitivity that improves the complexity bound, and the Java features the conference version excluded.
resource: knowledge/sources/blanchet-escape-analysis-java-toplas-2003.pdf
tags: [escape-analysis, stack-allocation, synchronization-elimination, alias-analysis, abstract-interpretation, ssa-construction]
authors: [Bruno Blanchet]
year: 2003
venue: "ACM TOPLAS (this PDF is the accepted preprint; its running head reads Vol. TBD, No. TDB, Month Year, so it carries no volume, issue or page numbers)"
informs: [/techniques/escape-analysis.md, /techniques/points-to-analysis.md, /techniques/storage-class-assignment.md, /techniques/ssa-construction.md]
pipeline_stage: 09-alias
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-08-01T00:00:00Z" }
---

# Contribution

**This is not a reprint of OOPSLA 1999 and the two are not interchangeable in either direction.**
Blanchet states the relationship himself in §1: "Our implementation was presented, in
[Blanchet 1999], with benchmark results but no correctness proof. This paper complements
[Blanchet 1999]." *Complements*, not supersedes — and §10.3 sends the reader back to the
conference paper for the inlining-condition algorithm, which TOPLAS removes. Keep both.

What TOPLAS adds, in order of how much it matters to an implementer:

**1. The correctness proof, via a new technique.** OOPSLA said "We have done a correctness proof,
but we shall not detail it here." TOPLAS is organized around it. §4 introduces an alias analysis
as an intermediate step, §5.3 proves analysis `E` correct against it, Appendix C proves the
integer abstraction correct, and Appendices A/B/C run about fifteen pages. Blanchet claims the
technique is novel as far as he knows, and the reason it was needed is specific to bidirectional
analysis (see Mechanism).

**2. A four-level analysis hierarchy** (Fig. 2), each derived from the previous by abstract
interpretation: *alias analysis → analysis E (access paths) → analysis L (integers) → analysis L1
(integers, one-step approximation)*. OOPSLA presented only what is effectively L1, with no path
level and no stated Galois connection. TOPLAS gives `α_τ(γ) = ⊔{⊤[τ.p] | p ∈ γ}` and
`γ_τ(n) = {p | ⊤[τ.p] ≤ n}` and proves the connection.

**3. SSA form, made explicit, which improves the complexity bound.** OOPSLA analyzed the operand
stack and local variable array directly and paid `(l+s)` factors for it:
`O(n(l+s)pp'ni) = O(n²(l+s)²pp'²H)`. TOPLAS assumes SSA form, so there is one unknown per SSA
variable rather than an abstract state per program point, and the bound becomes
`O(npp'ni) = O(n²pp'²H)` with `n` the size of the SSA form. Equations and unknowns drop from
`O(n(l+s))` to `O(n)`. It also lets Blanchet characterize the flow sensitivity exactly instead of
denying it: "as flow sensitive as the static single assignment form" — flow sensitive on local
variables, flow *insensitive* on assignments to object fields. §9.2 then admits the
implementation does not build SSA; it inserts φ-functions for all variables at meet points in
loops, which is an over-φ'd equivalent with identical flow sensitivity.

**4. §8, Extensions** — a whole section on the Java features OOPSLA declared out of scope
("we do not consider jsr and ret bytecodes and exceptions here"). Exceptions, subroutines, native
code, reflection, dynamic loading, and a type-analysis specialization. None of this is in the
conference paper.

**5. A real comparison against the 1999 competitors**, including the one we do not hold.

**6. Formalized global synchronization analysis** (`L1syn`, three equations, Theorem 10.4.1) and a
third implementation option — a `Cnosync` subclass per synchronized class, after Bogda and Hölzle
— that OOPSLA does not mention.

**7. Thread-locality measured separately from stack-allocatability**, a new column in Table II.

# Mechanism

**Alias analysis, the proof scaffold (§4).** Objects get *object names* `N ∈ OName`, like
locations except that different names may denote the same location. Access paths are
`Path = (Field ∪ ℕ)*`. The analysis produces two things: an abstract trace `T#` giving each
variable's object name at each *date* (the number of instructions executed, not a program point —
loops are followed by iteration, so there are no fixpoint equations here), and a **dated alias
relation** `R` where every alias `π₁ ≈ π₂` is registered with its creation date, together with its
symmetric element and right-regular closure.

Stack allocation, Theorem 4.3: with `Es` the set of paths reachable from static fields, the
result, and the parameters, an object `o` with name `N` can be stack allocated in `m` if
`∀π ∈ Es, (N.ε ≈ π) ∉ R(r)` where `r` is the return date.

**Why this scaffold is necessary.** The bidirectional `E`/`ES` construction creates mutual
dependencies between unknowns *even when the program contains no loop*. Example 5.2.2:

```
static List m() {
  a = new List();
  a.next = a;
  return a;
}
```

The equations reduce to `ES ⊒ next⁻¹.ES ⊔ next.ES ⊔ firstE`, whose solution
`ES = E = {γ ↦ next*.(next*)⁻¹.γ}` can only be found by iterating infinitely on a straight-line
instruction. That iteration cannot be mapped onto any iteration in the operational semantics. It
*can* be mapped onto the iteration that computes the transitive closure of the alias relation.
That is the whole reason aliases appear.

The proof machinery is the **partial closure**

```
R_k(r/d/s) = {π₁ ≈ πₚ | ∀i, (πᵢ ≈ πᵢ₊₁, dᵢ) ∈ R, s < dᵢ ≤ r, d₁ > d, p ≤ k, the πᵢ pairwise distinct}
```

Alias chains created during the execution of `m`, whose first link postdates `d`, using at most
`k−1` aliases transitively. The pairwise-distinctness condition is not cosmetic; without it you
can pad any chain with `π₁ ≈ π₂ ≈ π₁ ≈ …` and defeat the `d₁ > d` restriction. The proof is then
a double induction:

```
(1) ∀d. corrS(0,d), corrE(0,d)                              trivial, R⁰ = ∅
(2) (∀d. corrS(k,d) ∧ corrE(k,d)) ⇒ (∀d. corrE(k+1,d))      backward induction on d
(3) (∀d. corrE(k,d)) ⇒ (∀d. corrS(k,d))                     forward induction on d
(4) ∀k. corrE(k,d) ⇒ corrE(∞,d)                             since ⋃ₖ R_k = R^∞
```

Two nested iterations: over `k`, the number of aliases composed transitively, and over `d`, the
date. `E` uses backward induction because it is the backward analysis; `ES` forward.

**Analysis E, on paths (§5).** `Ctx_E = P(Path)`. Constructions `f.γ = {f.p | p ∈ γ}`,
restrictions `f⁻¹.γ = {p | f.p ∈ γ} ∪ {ε if ε ∈ γ}`, and array versions that deliberately merge
all elements. An object is stack allocatable if its escape context does not contain the empty
path `ε`. Abstract values are context transformers `Val_E = Ctx_E^{j+2} → Ctx_E`, parameterized on
the escape contexts of the parameters (from `ES`) and of the result (from `E`) — which is what
makes the analysis **context sensitive** without reanalyzing a method per calling context. `E`
does not use types at all; types enter only at analysis L.

Figure 7 is the equation table, on SSA instructions rather than bytecodes:

```
                     forward (LS = ES(m))                 backward (L = E(m))
entry of m           LS = P_E                             ∀i. ρ(m)(i) ⊒ L(pᵢ)
v₁ = v₂ / (t)v₂      LS(v₁) = LS(v₂)                      L(v₂) ⊒ L(v₁)
v₁ = φ(v₂,v₃)        LS(v₁) = LS(v₂) ⊔ LS(v₃)             L(v₂) ⊒ L(v₁); L(v₃) ⊒ L(v₁)
v₁ = v₂.f            LS(v₁) = f⁻¹.LS(v₂)                  L(v₂) ⊒ f.L(v₁)
v₁.f = v₂                                                 L(v₂) ⊒ f⁻¹.LS(v₁); L(v₁) ⊒ f.LS(v₂)
v = C.f              LS(v) = ⊤_E[f]
C.f = v                                                   L(v) ⊒ ⊤_E[f]
v₁ = v₂[v₃]          LS(v₁) = ℕ⁻¹.LS(v₂)                  L(v₂) ⊒ ℕ.L(v₁)
v₁[v₂] = v₃                                               L(v₃) ⊒ ℕ⁻¹.LS(v₁); L(v₁) ⊒ ℕ.LS(v₃)
v = new C / new t[w] LS(v) = L(v)
w = v₀.m'(v₁…vₙ)     LS(w) = ρ'S(m') ∘ (L(w), LS(v₀)…LS(vₙ))
                     L(vᵢ) ⊒ ρ'(m')(i) ∘ (L(w), LS(v₀)…LS(vₙ))
return v             ρS(m) ⊒ LS(v)                        L(v) ⊒ first_E
```

**Lemma 5.3.4, new in TOPLAS and load-bearing:** `ES(m)(v) ⊑ E(m)(v)` whenever the calling-context
condition `∀i. γᵢ ⊑ E(m)(pᵢ)(…)` holds. It is used to show that as soon as `y` is stored into `x`
by `x.f = y`, `E(m)(y) = ES(m)(y)`. Blanchet then explains why he still keeps the two analyses
separate: merging them would halve the unknowns but leave the bidirectional propagation intact,
and it loses precision on the pattern where a default value is read from a static field into a
φ-merge and no field assignment on the merged value ever happens. He cites Ruf's analysis as
having exactly this problem.

**Analysis L, on integers (§6).** Type heights by the same four rules as OOPSLA. The path height
`⊤[τ.p]` is defined carefully for paths that are not statically valid for `τ`, because a value
believed to be `Object` may in fact be a `Node`:

```
⊤[t[].n.p]        = ⊤[t.p]                    (n ∈ ℕ)
⊤[t.n.p]          = ⊤[t.p]                    t not an array
⊤[t.(C,f,t').p]   = ⊤[t] ⊓ ⊤[t'.p]
⊤[t.ε]            = ⊤[t]
```

The `⊤[t] ⊓` in the field case is not the intuitive definition and Blanchet flags it: it exists to
guarantee `⊤[τ.p] ≤ ⊤[τ]`, since `ε` denotes the whole value escaping and must be maximal.

**The type-conversion formula** (Lemma 6.3, proved in Appendix C) is the fiddly part, for
`τ = t[]^k → τ' = t'[]^{k'}`:

```
convert(τ,τ')(n) = (n ⊓ ⊤[τ'])
                 ⊔ ⊤[t'[]^{k'−i}]  if i ≥ 0 minimal with i ≤ k, i ≤ k' and n = ⊤[t[]^{k−i}]
                 ⊔ ⊤[t']           if k > k' and ⊤[t] ≤ n < ⊤[t[]^{k−k'}]
                 ⊔ 0               if n < ⊤[t]
```

For non-array types it collapses to `(n ⊓ ⊤[τ']) ⊔ (if n = ⊤[τ] then ⊤[τ'] else 0)`.

**Do not convert to the static type.** §6.2 is emphatic. Conversions lose precision, so they are
delayed until an abstract operation needs an argument of a specific type, and the upper bound
converts to the *higher* of the two types. Example 6.5 shows a `NodeList`/`Node[]` φ-merge where
converting to the least common supertype `Object` would report both objects as fully escaping and
the delayed choice reports neither escaping. Blanchet also notes why the exact type, not just the
height, must be carried: `⊤[t[]^i]` for all `i ≤ k` is needed for array conversions and cannot be
recovered from `⊤[t[]^k]`.

**Analysis L1, the one-step approximation (§7).** Additivity splits `φ` into
`g₁(γ₁) ⊔ … ⊔ gⱼ(γⱼ) ⊔ u` with each `gᵢ` monotone and `gᵢ(0) = 0`, stored **sparsely** as
`(u, ((i_{k1}, g_{i_{k1}}), …))` with pairs ordered by increasing index so every operation is a
single left-to-right scan. Each `g` is then a triple `(s, s⁺, l)` meaning
`γ ↦ (if γ ≥ s then s⁺ else 0) ⊔ (γ ⊓ l)`, with approximate `⊔` and `∘`:

```
(g₁ ⊔'' g₂)(γ) = (if γ ≥ s₁ ⊓ s₂ then s₁⁺ ⊔ s₂⁺ else 0) ⊔ (γ ⊓ (l₁ ⊔ l₂))
(g₁ ∘'' g₂)(γ) = if γ ≥ (if l₂ ≥ s₁ then s₁ ⊓ s₂ else s₂)
                 then ((if l₂ ⊔ s₂⁺ ≥ s₁ then s₁⁺ else 0) ⊔ (s₂⁺ ⊓ l₁)) else 0
                 ⊔ (γ ⊓ (l₂ ⊓ l₁))
```

**A trap worth carrying forward:** the representation is not unique, and `⊔''` and `∘''` depend on
the *representation*, not only on the function. Blanchet gives a concrete example where two
representations of the same function `γ ↦ γ ⊓ 2` compose to results of different precision.
Always pick the smallest triple under `(s₁,s₁⁺,l₁) ⊑'' (s₂,s₂⁺,l₂) ⟺ s₁ ≥ s₂ ∧ s₁⁺ ≤ s₂⁺ ∧ l₁ ≤ l₂`.
Hence the deliberate choices `g_id = γ ↦ (if γ ≥ 1 then 0 else 0) ⊔ (γ ⊓ ∞)` and
`g_{⊓n} = γ ↦ (if γ ≥ ∞ then 0 else 0) ⊔ (γ ⊓ n)`.

**§8 extensions, condensed.** Exceptions: thrown objects escape unconditionally; handlers are
analyzed as if every point in the `try` block jumps to the handler. Subroutines: for variables the
subroutine does not modify, keep the *same* SSA name across the `jsr`, so a lock-release
subroutine costs no precision — but the bidirectional propagation still merges escape information
across call sites for variables used in field assignments, so subroutine analysis is *not fully
context sensitive*. Native code: worst case assumed, with a printed list of hand-annotated
exceptions (`Object.getClass/hashCode/clone`, `System.arraycopy/identityHashCode`, six `Class`
predicates, all natives of `FileOutputStream`/`FileInputStream`/`RandomAccessFile`/`Inflater`/
`Deflater` except `setDictionary`). Reflection: `Field.get`/`Array.set` escape everything;
`Method.invoke` and `Constructor.newInstance` escape everything; `Class.newInstance` is handled
precisely because only the no-argument constructor can run, and it is the most frequently called
reflection method. Dynamic loading: resolve `Class.forName("literal")` and `name.class`; for
`(C)Class.forName(s).newInstance()`, consider every subclass of `C` on the class path. Type
analysis: specialize a method whose parameter is declared `Object` on the more precise type seen
at the call site, limited to methods of at most 20 bytes of bytecode — which is what proves the
objects in `"s1" + o1 + "s2" + o2` do not escape.

# Applicability

Everything in the OOPSLA document applies. What changes:

**SSA is now a precondition of the stated complexity.** The `(l+s)` factors go away because of
SSA, not because of a better algorithm.

**The flow sensitivity is precisely bounded and it is a real limit.** Flow sensitive on local
variables, flow insensitive on object fields. §5.3 states plainly that taking control flow into
account more precisely "would require a much more costly analysis such as [Whaley and Rinard;
Choi et al.]."

**Dynamic loading can defeat the synchronization analysis entirely.** When the loaded class
cannot be determined, `L1syn(m) = (⊤[τ_{−1}], …, ⊤[τⱼ])` — everything shared.

**Precision does not come from the type graph statistics.** Table IV reports average type height
5.7 and average SCC cardinality 2.7 across the benchmarks, then concedes "it is difficult to see a
real correlation between these figures and the precision of the analysis."

# Relevance

Three findings change what stage 09 should look like.

**Stage 09 wants SSA, and that reorders things.** The whole complexity improvement over OOPSLA
comes from analyzing SSA form rather than an abstract state per program point. Our SSA
construction sits earlier in the pipeline, so this costs nothing and buys a factor of `(l+s)²`.

**Analysis E is type-free and analysis L is not.** §5 says explicitly that `E` does not use types
and that subtyping only enters at L. So the *path-based* analysis is directly applicable to
untyped Scheme; the *integer* abstraction that makes it fast is not, without type recovery. This
is the same constraint the POPL 1998 document reaches, arrived at independently, and it is now
sourced twice. Escape analysis at stage 09 is downstream of type recovery if we want the cheap
version.

**The bidirectional `E`/`ES` pair is what makes mutation tractable, and it is not optional.**
Example 5.2.2 is the argument: the mutual dependence is not loop iteration and no ordinary
fixpoint reasoning covers it. For us `(vector-set! v 0 x)` is `x.f = y`, and the alternative — the
POPL 1998 rule that a value escapes as soon as it is stored — kills the flvector case that stage
08 exists to serve.

The Java-model pieces that do not transfer: type conversion and `convert`, subtype rule (3) on
heights, the `Type` tag on abstract values, `Cnosync` subclassing, and the entire synchronization
half. We have no subtyping and no monitors.

# Notes

**The version distinction matters in the direction opposite to the usual assumption.** The
journal version does *not* subsume the conference version. §10.3: "The technical details of this
algorithm can be found in [Blanchet 1999]" — the `(j+1)`-cell inlining-summary machinery, with its
`inter_cond`/`maxvol_cond`/`englob_cond` and the `AddCond` pseudocode, is in OOPSLA and removed
from TOPLAS. And OOPSLA's Figure 5 gives the analysis as bytecode transitions (`aload`, `astore`,
`getfield`, `putfield`, `invokevirtual`, `dup`) where TOPLAS gives it on SSA instructions. If you
implement on a stack machine you need OOPSLA; on SSA you need TOPLAS.

**On Choi et al. (OOPSLA 1999, connection graphs), which we do not hold.** TOPLAS §1.1.2 gives the
substantive comparison the conference paper did not. Choi et al. and Whaley-Rinard "are more
precise than our analysis because they distinguish different fields of objects and are flow
sensitive." Blanchet's counter is that integer manipulation costs less time and memory than graph
manipulation and that his precision suffices on his benchmarks. Then the decisive line:
**"Choi et al. consider a new statement as stack allocatable only when it is so in all calling
contexts of the method. Therefore, inlining cannot be used to increase stack allocation
opportunities."** Blanchet's own ML data says inlining is what takes Coq from 11% to 25%
stack-allocated, so this is a structural limitation of the connection-graph approach, not a
tuning difference.

**Bibliographic caveat.** This PDF is the accepted preprint. Its running head reads "Vol. TBD,
No. TDB, Month Year" and the title page carries no volume, issue, or page numbers. We cannot cite
a volume/issue/page range from this file. The affiliation also differs from OOPSLA: École Normale
Supérieure and Max-Planck-Institut für Informatik, with a footnote that the work was partly done
at INRIA Rocquencourt.

**Benchmark numbers drift from OOPSLA and the two tables are not comparable.** Program sizes are
measured on a different basis: OOPSLA excluded the Java standard library ("total size of the
.class files, Java standard library excluded") and lists `dhry` at 6 kb; TOPLAS counts library
methods that may be called and lists `dhry` at 73 kb. Runtimes were re-measured: `dhry` 44% → 43%,
`javac` 8/8 → 10/11, `turboJ` 11/9 → 10/13, `jess` −1/−3 → −4/−1, `JLex` 42/41 → 42/40, `javacc`
6/10 → 6/9. The headline geometric mean of 21% is unchanged. Total compile overhead moves 34% →
29%. `javacc` stack growth in the "All" configuration is a factor of 10 in both; the "No loops"
figure is 75% in OOPSLA and 77% in TOPLAS.

**A negative locality result appears here that OOPSLA did not explain.** In `javacc` with `alloca`
allowed in loops, stack-allocated char arrays become unreachable at the next iteration but the
analysis cannot see it, leaving gaps in the stack unreused until the method returns — whereas heap
allocation would have let a GC reclaim and reuse them. So stack allocation can *hurt* locality.
OOPSLA had blamed the write-miss increase on the Pentium MMX write-through cache; TOPLAS instead
says write-miss changes barely affect runtime because writes go into the write buffer without
stalling, and quantifies a read miss at about 60 cycles.

**A concrete engineering data point on the solver.** Splitting the dependence graph into strongly
connected components before iterating takes `jess` from 156 s to 129 s and `turboJ` from 143 s to
100 s. Depth-first ordering alone is not enough.

**Extraction artifact, worse than the other two.** `pdftotext`, `pdfminer`, and the `pdftotext
-layout` variant all drop the letter `c` from this PDF — "es ape analysis", "orre tness",
"ba kward". The dvips Type 1 font encoding is broken for that glyph. Ligatures drop as well. The
text is readable if you reinsert the `c`, but do not machine-process this extraction, and do not
trust extracted formulas from Figures 11 and 13 without checking the rendering.
