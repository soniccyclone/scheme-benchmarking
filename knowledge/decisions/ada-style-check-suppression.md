---
type: decision
title: Ada-style named check suppression, not a CL safety dial
description: Suppress checks by name in a lexical scope, following Ada pragma Suppress, rather than a single 0-to-3 safety quality.
status: draft
tags: [design, policy, safety]
sources:
  - resource: /techniques/bounds-check-elimination.md
  - resource: /techniques/type-recovery.md
generated: { by: "human:nathan", at: "2026-07-30T00:00:00Z" }
---
# Decision

Check policy is per-check and lexically scoped. Six names: `index-check`, `type-check`,
`overflow-check`, `division-check`, `arity-check`, `all-checks`. `unsuppress` re-enables
inside a narrower scope.

# Why Ada rather than Common Lisp

Ada names each check and lets a program re-enable one inside a region. The Ada Reference
Manual lists fourteen. Common Lisp offers a single `safety` dial from 0 to 3, which bundles
risks that deserve separate decisions: dropping a bounds check in a numeric kernel is a
small, auditable choice, while dropping type checks on data from a socket is not, and a dial
makes you buy both.

# Why this is `status: draft`

**The decision has a measurement attached and the measurement has not run.** Phase 4
configuration 8 builds nbody in Ada three ways — all checks on, named suppression of the
safe checks, and `Suppress(All_Checks)` — with `-O` held constant.

The interesting number is build 2 against build 3. If they are indistinguishable, granularity
costs nothing and this decision is vindicated. If `All_Checks` is meaningfully faster, then
granularity has a price and CL's cruder dial has a real argument behind it that this document
currently dismisses.

Until that runs, this is a design preference with a plausible rationale, not a validated
choice, and it is marked accordingly.

# Consequence for the compiler

Policy must be a first-class lexical form carried in the compilation environment, not a
global parameter. [Chez](/implementations/chez.md) cannot host this: its `optimize-level` is
a compile-time parameter, which is one of the four walls that made building our own compiler
necessary.
