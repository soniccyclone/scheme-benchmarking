# Wave 1 ingest brief

You are producing OKF `works/` documents from academic papers already downloaded to this
repo. Read this whole file before starting.

## Context

We are building an optimizing Scheme compiler that aims to reach and then exceed Common
Lisp levels of optimization. Background, if you want it: `docs/PLAN.md`,
`docs/CHEZ-ANALYSIS.md`, `docs/phases/07-compiler/CUJ.md`. You do not need to read those
to do this job well, but the last one tells you which compiler pass each paper informs.

## The job

For each work assigned to you:

1. **Read the entire PDF.** Not the abstract. Not intro-and-conclusion. Not a skim for the
   fields the frontmatter wants. If it is long, take it in passes by chapter or section and
   accumulate. This rule is not negotiable and it is the whole reason this bundle is worth
   building: the synthesis layer above `works/` is only as good as what you actually read.
   A document produced from an abstract will repeat what everyone already believes about
   the paper while looking authoritative, which is worse than no document.

2. **Write** `knowledge/works/<slug>.md`, using the exact slug of the PDF.

3. The PDF is at `knowledge/sources/<slug>.pdf`. It is already downloaded and verified.
   **Do not download anything.** If you need a detail the PDF does not contain, say so in
   the document rather than fetching.

## Document format, OKF v0.2

Spec: https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md
Only `type` is strictly required, and consumers must tolerate unknown keys, so the extra
fields below are legal.

```yaml
---
type: paper
title: "Exact title from the paper's own title page"
description: One sentence. What the paper actually contributes.
resource: knowledge/sources/<slug>.pdf
tags: [3-6 kebab-case topics]
authors: [As printed on the title page]
year: 1991
venue: "TOPLAS 13(4)" or "PLDI 1990" etc
informs: [/techniques/<technique>.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "wave1-ingest/claude", at: "2026-07-30T00:00:00Z" }
---
```

`informs` names one or more technique documents this work should feed. They do not exist
yet, and that is fine, since OKF requires consumers to tolerate broken links. Invent
sensible kebab-case names and be consistent: `interval-domain`, `pentagon-domain`,
`bounds-check-elimination`, `slp-vectorization`, `stack-segment-continuations`,
`storage-class-assignment`, `loop-analysis`, `points-to-analysis`, `register-allocation`,
`instruction-selection`, `type-feedback`, `escape-analysis`, `generational-gc`,
`procedure-inlining`, `closure-conversion`, `ssa-construction`, `dataflow-analysis`.

`pipeline_stage` maps to the pass list in `docs/phases/07-compiler/CUJ.md`: `05-intervals`,
`06-pentagon`, `07-loops`, `08-represent`, `09-alias`, `10-vectorize`, `11-select`,
`12-regalloc`, `13-assemble`, or `n/a` for foundational works that inform no single stage.

## Body

Markdown, roughly 400 to 900 words. Sections:

- `# Contribution` — what is actually new here, in your own words.
- `# Mechanism` — how it works, concretely enough to implement from. This is the most
  valuable section. Include the algorithm shape, the data structures, the complexity.
- `# Applicability` — what it needs to hold, where it fails, what it costs. Be specific
  about preconditions.
- `# Relevance` — what this means for our compiler specifically.
- `# Notes` — anything surprising, including where the paper is wrong, dated, or oversold.

Write density, not length. Prefer a concrete algorithm sketch over a paragraph describing
that there is an algorithm.

## You have explicit permission to contradict the bibliography

`docs/phases/00-compiler-research/PLAN.md` describes these works. **Some of those
descriptions are wrong.** Four citation errors have already been caught this way: a paper
listed twice under two names, two invented filenames, and a wrong author list.

If the PDF disagrees with what the plan says about it — wrong author, wrong year, wrong
venue, wrong claim about content, wrong paper entirely, or a version mismatch such as a
workshop paper standing in for a journal article — **the PDF wins.** Record the correction
prominently in your `# Notes` section and flag it in your final report. Do not quietly
reconcile to the plan.

The same applies to the slug. If `mine-octagon-ast-2001.pdf` turns out to be something
else, say so rather than writing a document that matches the filename.

## Rules

- **Do not fabricate.** If the PDF is unreadable, truncated, or is not the paper the slug
  claims, write no document and report the problem. A missing document is recoverable; a
  confident wrong one poisons everything built on top of it.
- Do not edit any file outside `knowledge/works/`. Other agents are running concurrently.
- Do not touch `tools/sources.tsv`, `knowledge/sources/manifest.tsv`, or anything in
  `docs/`. Report corrections instead of applying them.
- No network access needed. Everything is local.

## Report back

Compact. One line per work: slug, whether the document was written, and the `informs`
targets you chose. Then a separate section listing any bibliography corrections you found,
because those are the highest-value output of this wave and I need them surfaced, not
buried.
