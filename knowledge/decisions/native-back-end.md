---
type: decision
title: Native x86-64 back end, not C emission
description: Emit machine code directly, because C forecloses precise GC roots, calling convention control, full continuations, and representation control.
status: stable
tags: [architecture, back-end]
sources:
  - resource: /implementations/chez.md
  - resource: /implementations/stalin.md
  - resource: /techniques/storage-class-assignment.md
  - resource: /techniques/generational-gc.md
  - resource: /techniques/stack-segment-continuations.md
generated: { by: "human:nathan", at: "2026-07-30T00:00:00Z" }
---
# Decision

Own the back end. Instruction selection, register allocation and assembly are ours.

# Why not C

Emitting C and letting gcc vectorize would prove gcc is fast, not that Lisp is fast. Every
language can escape to C for a hot loop; that is the null result. But the technical
objections are worse than the aesthetic one, and each caps the compiler below both
references:

- **No precise GC roots.** C will not say which registers hold live references at a call
  site, forcing a shadow stack or conservative scanning. [Stalin](/implementations/stalin.md)
  loses 5x to 16x on allocation-heavy code for exactly this reason.
- **No calling convention control.** No multiple values in registers, no custom register
  partitioning, no general tail calls. `musttail` is per-site and misses mutual recursion
  through unknown callees.
- **Continuations permanently capped at escape-only**, because C owns the stack.
- **Representation control is the whole point**, and through C you describe intent and hope
  gcc infers it. See [storage-class-assignment](/techniques/storage-class-assignment.md).

# What it costs

The back end gates milestone 1, so it precedes every analysis pass. Chez spends 10912 lines
in `cpnanopass.ss` plus 3504 in `x86_64.ss`, though we need enough x86-64 for three
benchmark programs rather than a general compiler.

# What it buys beyond the objections

Owning the stack puts full `call/cc` back on the table rather than foreclosing it, and it
makes precise stack maps possible, which is what a generational collector needs.
