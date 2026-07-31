---
type: decision
title: Declaration-anchored local inference
description: Declarations are the contract and the anchor. Local inference propagates from them. Global analysis is best-effort on top and never load-bearing.
status: stable
tags: [architecture, analysis, type-recovery]
sources:
  - resource: /techniques/type-recovery.md
  - resource: /techniques/type-feedback.md
  - resource: /techniques/control-flow-analysis.md
  - resource: /implementations/stalin.md
  - resource: /implementations/sbcl.md
generated: { by: "human:nathan", at: "2026-07-30T00:00:00Z" }
---
# Decision

Three layers, in strict priority order:

1. **Declarations are the contract.** Always honored, always predictable. The floor.
2. **Local inference propagates from them.** Anchored, so no closed world is needed and
   separate compilation survives.
3. **Opportunistic global analysis on top**, strictly best-effort, never required for the
   declared performance.

# Why

[Stalin](/implementations/stalin.md) has nothing to anchor on, so it derives everything from
closed-world whole-program analysis. Where that succeeds it beats Chez 2x to 4x; where
lifetime analysis loses precision the effects cascade and it loses 5x to 16x, **with nothing
in the source indicating which case you got**. The closed world also rules out separate
compilation.

Declarations fix this not merely by supplying facts but by supplying *anchors that make
inference local*. Given declared parameter types, ordinary flow analysis propagates through a
body with no whole-program analysis. This is not speculative: it is what
[SBCL](/implementations/sbcl.md) does, IR1 deriving types from declarations and IR2 selecting
representations from them.

# The live counter-evidence

Hölzle and Ungar measured SELF-91's iterative static type analysis performing **no better
than no type analysis at all** — same call counts, marginally better run time — while a
profile counter delivered 1.7x. Our architecture bets static analysis suffices without
profiles.

The defense is that SELF faced open-world receiver dispatch, where the type set at a call
site is unbounded and genuinely needs observation, while ours is a closed finite set of
numeric representations that declarations pin exactly. **That is plausible and unproven.**
If it fails, the answer is to add profile feedback, not to abandon the analysis. Test it
against nbody.

# Note on Chez

Chez already does the local half automatically, and a five-line macro reaches it today. See
[type-recovery](/techniques/type-recovery.md) and [chez](/implementations/chez.md). What it
cannot do is the range reasoning bounds elision needs.
