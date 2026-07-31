---
type: implementation
title: SBCL
description: Common Lisp implementation with interval and relational constraint propagation, SIMD intrinsics, and no autovectorizer.
resource: https://github.com/sbcl/sbcl
tags: [common-lisp, native, baseline]
implements: [/techniques/interval-domain.md, /techniques/bounds-check-elimination.md, /techniques/storage-class-assignment.md, /techniques/type-recovery.md, /techniques/dataflow-analysis.md, /techniques/loop-analysis.md, /techniques/register-allocation.md, /techniques/generational-gc.md, /techniques/procedure-inlining.md]
lacks: [/techniques/slp-vectorization.md, /techniques/stack-segment-continuations.md]
verified: [{ by: "human:nathan", at: "2026-07-30T00:00:00Z" }]
status: stable
---
# What it is

The Common Lisp implementation whose speed prompted this project. The target for
milestone 3 of the compiler.

# What it implements

**Interval reasoning, from the standard type language.** ANSI CL standardized integer range
types, so `(integer 0 9)`, `(mod 10)` and `(unsigned-byte 8)` are standard specifiers every
conforming implementation must understand. `src/compiler/array-tran.lisp:2183`,
`check-bound-empty-p`, builds a `mod` type from the bound, intersects it with the index type,
and folds the check when the intersection is empty. `srctran.lisp` carries 598 `interval`
references.

**Relational constraints.** `src/compiler/constraint.lisp`, 1791 lines, line 95:
`(kind nil :type (member typep < > = >= <= eql equality set))`. Those inequality kinds are
the strict-inequality component of a Pentagon-class domain. `equality-constraints.lisp` adds
1366 more.

Together these put SBCL at roughly level 3 in the hierarchy, by two independent mechanisms:
intervals suffice when an array length is a compile-time constant, and the relational
constraints carry the dynamic-length case.

**Storage class assignment.** IR2 assigns values to specific register files and unboxes
`double-float` into registers and into `(simple-array double-float (*))`. This is the pass
that produces the actual speed.

**Loop analysis.** `src/compiler/loop.lisp` with `loop-analyze` and natural-loop detection.

# What it lacks

**No autovectorizer.** `src/compiler/x86-64/` carries `avx512-insts.lisp` and
`avx2-insts.lisp`, so the assembler knows the encodings, and `contrib/sb-simd` exposes them
as user-callable intrinsics. But `grep -rlin 'vectoriz' src/compiler/*.lisp` returns
nothing. Vector code exists only where a human wrote an intrinsic, which is why the fast
Benchmarks Game entries are hand transliterations of Zig.

**Full `call/cc`.** CL offers escaping continuations only. Note this row is inference from
the language standard rather than from reading SBCL source, and should be verified before
being relied on.

# The standards connection

CL standardized integer *range* types, which obliged every implementation to represent
ranges and is what makes declaration-driven bounds elision possible. Scheme standardized no
type language at all, so its implementations built lattices of flat predicates. A standards
difference produced a compiler capability difference.
