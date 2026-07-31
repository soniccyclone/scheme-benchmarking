---
type: index
title: decisions
description: Index of decisions documents in this bundle.
---
# decisions

- [Ada-style named check suppression, not a CL safety dial](/decisions/ada-style-check-suppression.md) - Suppress checks by name in a lexical scope, following Ada pragma Suppress, rather than a single 0-to-3 safety quality.
- [Declaration-anchored local inference](/decisions/declaration-anchored-inference.md) - Declarations are the contract and the anchor. Local inference propagates from them. Global analysis is best-effort on top and never load-bearing.
- [Native x86-64 back end, not C emission](/decisions/native-back-end.md) - Emit machine code directly, because C forecloses precise GC roots, calling convention control, full continuations, and representation control.
- [Pentagon domain, not Octagon](/decisions/pentagon-not-octagon.md) - Target intervals plus strict upper bounds at stage 06. Octagon is more precise, more expensive, and carries a widening hazard Pentagon structurally avoids.
