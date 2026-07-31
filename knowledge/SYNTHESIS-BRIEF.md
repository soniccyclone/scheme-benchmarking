# Wave 2 synthesis brief

You are writing OKF `techniques/` documents by synthesizing across the `works/` documents
already in this bundle. Read this whole file first.

## What this layer is for

`works/` answers "what does this paper say." **`techniques/` answers "how do I do X, and
what does it cost."** That is what a later planning session actually queries. Nobody asks
what Logozzo 2008 says; they ask how to eliminate a bounds check and what domain it needs.

So a technique document is not a summary of one paper. It is the answer to an engineering
question, assembled from every work that bears on it, with the disagreements preserved
rather than averaged away.

## Inputs

- `knowledge/works/*.md` — 50 documents, one per source, already written. **These are your
  primary input.** Read every work relevant to your assigned techniques, in full.
- `knowledge/sources/*.pdf` — the original papers, if a work document is ambiguous or you
  need a detail it omitted. Available locally, no network needed.
- `docs/CHEZ-ANALYSIS.md` — what Chez and SBCL actually implement, read from source.
- `docs/phases/07-compiler/CUJ.md` — our pipeline stages, so you can map techniques to them.

## Format, OKF v0.2

```yaml
---
type: technique
title: Pentagon abstract domain
description: One sentence. What problem it solves and at what cost.
tags: [3-6 kebab-case topics]
sources:
  - resource: /works/logozzo-f-hndrich-pentagons-2008-2010.md
  - resource: /works/cousot-cousot-abstract-interpretation-popl-1977.md
implemented_by: [/implementations/sbcl.md]
absent_from: [/implementations/chez.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave2-synthesis/claude", at: "2026-07-30T00:00:00Z" }
---
```

`sources` must cite every work you drew on. `implemented_by` and `absent_from` point at
`/implementations/*.md`, which do not exist yet — that is fine, OKF requires consumers to
tolerate broken links, and wave 3 will create them. Populate them from
`docs/CHEZ-ANALYSIS.md` where it says which capability Chez has and lacks.

## Body

Markdown, 500 to 1200 words. Sections:

- `# Problem` — the engineering question this answers, stated concretely.
- `# Mechanism` — how it works, implementable. Algorithm shape, data structures,
  complexity. This is the section that earns the document.
- `# Preconditions` — what must hold. Be specific; this is where techniques actually fail.
- `# Cost` — time, space, compile time, and what precision you give up.
- `# Disagreements` — **required section, do not omit.** Where the sources conflict, say so
  and name both sides. If they all agree, say that explicitly rather than deleting the
  heading.
- `# For us` — what this means for our compiler, referencing the pipeline stage.

Prefer a concrete algorithm sketch over prose describing that an algorithm exists.

## Preserve the corrections

The works documents contain hard-won corrections: an unsound widening printed in the
Pentagons paper, a register allocation criterion that is wrong in the published ACM text
but right in our copy, math symbols that do not survive extraction from ABCD, a paper that
contains no measurements behind its performance claims. **Carry these forward.** A
technique document that silently reproduces a known-bad formula is worse than none.

You may also contradict the works documents if the underlying PDF disagrees. Say so.

## Naming and consolidation

Use exactly the technique slugs assigned to you. The works documents reference 46 distinct
names, many of them singletons that are facets of a larger technique rather than techniques
in their own right. Your assignment already reflects the intended merges — for example
`liveness-analysis` and `live-interval-analysis` both fold into `register-allocation`, and
`stop-and-copy-gc` folds into `generational-gc`. If a work's `informs` names something you
absorbed, cite that work anyway and cover the facet inside your document.

## Rules

- Write only to `knowledge/techniques/`. Other agents run concurrently. Do not touch
  `works/`, `sources/`, `tools/`, or `docs/`.
- Do not fabricate. If no source in the bundle supports a claim, leave it out or mark it
  explicitly as your inference.
- Report corrections rather than applying them outside your directory.

## Report back

One line per technique: slug, written or not, and which works you cited. Then a section
for anything that should change in `docs/` — especially where a technique's real cost or
precondition contradicts what our planning documents assume.
