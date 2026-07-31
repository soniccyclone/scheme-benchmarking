---
type: implementation
title: Chez Scheme
description: Fast-compiling native Scheme with a category-level type lattice, automatic unsafe promotion, and no classical loop optimizer.
resource: https://github.com/cisco/ChezScheme
tags: [scheme, native, nanopass, baseline]
implements: [/techniques/stack-segment-continuations.md, /techniques/type-recovery.md, /techniques/closure-conversion.md, /techniques/procedure-inlining.md, /techniques/register-allocation.md, /techniques/generational-gc.md, /techniques/nanopass-framework.md, /techniques/tail-call-optimization.md]
lacks: [/techniques/interval-domain.md, /techniques/pentagon-domain.md, /techniques/bounds-check-elimination.md, /techniques/slp-vectorization.md, /techniques/loop-analysis.md, /techniques/ssa-construction.md]
verified: [{ by: "human:nathan", at: "2026-07-30T00:00:00Z" }]
status: stable
---
# What it is

The performance reference for the Scheme family, and the implementation this project
measures against. Written in nanopass style by the people who invented it. Source read at
commit dated 2026-06-10.

# What it implements

**Flow-sensitive type recovery, automatically.** `s/cptypes.ss` returns `t-types` and
`f-types`, separate type environments per branch of a conditional, so the then-branch of
`(if (flonum? x) A B)` knows `x` is a flonum. `pred-env-add/ref` records the fact against a
variable's prelex counter.

**Automatic unsafe promotion at the safe optimize level.** `fold-primref/try-unsafe`
(`cptypes.ss:1963`) intersects each argument's inferred type with the primitive's declared
argument predicate, and if all of them imply it, swaps the primitive for its unsafe variant.
Gated on the `safeongoodargs` flag, carried by 270 primitives including `fl+`.

Consequence, and it is underappreciated: a five-line `syntax-rules` macro over a predicate
guard is a working declaration mechanism on Chez **today**, and it is sounder than CL's
`(safety 0)` because the boundary check is real. See [type-recovery](/techniques/type-recovery.md).

**Stack-segment continuations**, from Hieb, Dybvig and Bruggeman 1990. Full `call/cc` with
ordinary calls staying cheap.

# What it lacks, and why it matters

**The type lattice is level 1 in the abstract-domain hierarchy.** `cptypes-lattice.ss:573-574`
collapses `index`, `length`, `sub-index` and `u8` to `fixnum-pred`. These are flat categories,
not intervals. Chez cannot represent `i ∈ [0,5)`, so
[bounds-check-elimination](/techniques/bounds-check-elimination.md) is *unrepresentable*
rather than merely unimplemented. `flvector-ref` correctly lacks `safeongoodargs`, because
proving both argument types does not make the access safe: the needed fact is relational.

**No classical loop optimizer.** Grepping `s/*.ss` for `induction`, `licm` and `hoist`
returns nothing, and the ICFP 2006 paper never mentions induction variables, strength
reduction, unrolling or vectorization. Bounded claim: Chez's own Version 2 highlights list
"optimizing letrec expressions and loops", so some loop handling exists. The classical passes
do not.

**Scalar SSE only.** `s/x86_64.ss` emits `addsd`, `mulsd`, `subsd`, `divsd`, `sqrtsd`,
`movsd`, `cvtsi2sd`. Every one is an `sd`. No packed encodings exist in the file at all.

**`optimize-level` is a global compile-time parameter**, not a lexical form, so scoped check
suppression has no faithful target.

# Why it is built this way

Deliberate, not oversight. Dybvig optimized for compilation speed, and the ICFP 2006 paper
states a payback rule that classical loop passes would not survive. Chez compiles very fast
and produces good code, and the absent loop optimizer is part of how it achieves the first.

# Evidence

- `s/cptypes.ss` 2534 lines, `s/cptypes-lattice.ss` 1547 lines, `s/primdata.ss` signatures
- `s/x86_64.ss` 3504 lines, `s/cpnanopass.ss` 10912 lines
- Full reading in `docs/CHEZ-ANALYSIS.md`
