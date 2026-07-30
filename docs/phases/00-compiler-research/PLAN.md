# Phase 0: Compiler Research

## Goal

Assemble the seminal works on implementing a performant Scheme, with direct links, so they
can be pulled and ingested in bulk.

**The output of this phase is an OKF bundle**, not a pile of PDFs. See section 0 below for
the bundle design. The bibliography in sections 1 through 13 is the fetch list that feeds
it.

---

## 0. The deliverable: an OKF bundle

### What OKF is

The Open Knowledge Format is an open specification from Google Cloud that formalizes the
LLM-wiki pattern: a bundle is a directory tree of markdown files with YAML frontmatter, and
nothing more. It is vendor-neutral, readable in any editor, and shippable as a tarball or a
git repo.

| resource | link |
|---|---|
| Specification, currently **v0.2** | https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md |
| Raw spec, for an agent to fetch | https://raw.githubusercontent.com/GoogleCloudPlatform/knowledge-catalog/main/okf/SPEC.md |
| The `okf` directory, with sample bundles and the visualizer | https://github.com/GoogleCloudPlatform/knowledge-catalog/tree/main/okf |
| Announcement, McVeety & Hormati, 2026-06-12 | https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing |
| Karpathy's LLM-wiki gist, the pattern OKF formalizes | https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f |
| `openknowledge` CLI for managing bundles | https://github.com/openknowledge-sh/openknowledge |
| `okf-skills`, an OKF toolkit packaged for Claude Code | https://github.com/scaccogatto/okf-skills |

All seven verified reachable 2026-07-30.

**Note the version.** The Google Cloud announcement describes v0.1, and `SPEC.md` is now
v0.2. Two breaking changes matter for us: `timestamp` is superseded by
`generated: {by, at}`, and a body `# Citations` list is superseded by a `sources`
frontmatter family. Build against v0.2.

### Why this format for this project

The `sources` and `verified` frontmatter families map onto exactly what this phase
produces. Every entry in the bibliography below has a checked-reachable URL and a date, and
those become `sources[].resource` and a `verified` event rather than prose in a table.

More importantly, `type` is the only required field and consumers **must not** reject a
bundle for unknown additional frontmatter keys or broken cross-links. So we can add
domain-specific fields without leaving the format, and a partially-ingested bundle is still
conformant and still traversable.

### Bundle layout

```
knowledge/                        bundle root
├── index.md                      carries okf_version: 0.2
├── log.md                        chronological ingest record
├── works/                        one file per paper. The ingest target
│   ├── index.md
│   ├── steele-1978-rabbit.md
│   ├── dybvig-1987-three-implementation-models.md
│   ├── logozzo-2008-pentagons.md
│   └── ...
├── techniques/                   synthesis across works. What later sessions query
│   ├── index.md
│   ├── interval-domain.md
│   ├── pentagon-domain.md
│   ├── bounds-check-elimination.md
│   ├── slp-vectorization.md
│   ├── stack-segment-continuations.md
│   └── storage-class-assignment.md
├── implementations/              what we learned reading real compilers
│   ├── index.md
│   ├── chez.md
│   ├── sbcl.md
│   ├── stalin.md
│   └── bigloo.md
└── decisions/                    our choices, each traceable to evidence
    ├── index.md
    ├── native-back-end.md
    ├── pentagon-not-octagon.md
    ├── declaration-anchored-inference.md
    └── ada-style-check-suppression.md
```

Four layers, and the separation is the point.

`works/` is raw ingest, one document per paper, and is what a bulk-fetch agent produces.

`techniques/` is the synthesis layer, and it is what a later planning session actually
queries. Nobody asks "what does Logozzo 2008 say"; they ask "how do I eliminate a bounds
check, and what does it cost." A technique document answers that and cites the works
underneath it.

`implementations/` encodes what we already established by reading source. That knowledge
currently lives in `../../CHEZ-ANALYSIS.md` as prose and should be queryable: which
techniques Chez implements, which it lacks, and where in its source the evidence is.

`decisions/` closes the loop. A later session can ask "why native rather than C" and get a
document that cites the implementation findings and the works behind them, rather than
re-deriving the argument.

### Frontmatter conventions

Only `type` is required by the spec. These are the four types we use and the fields we
attach, all of which are legal additions under v0.2's tolerance rules.

**`type: paper`**, in `works/`:

```yaml
---
type: paper
title: "Pentagons: A Weakly Relational Abstract Domain for the Efficient Validation of Array Accesses"
description: An abstract domain capturing x in [a,b] and x < y, designed for array bounds validation.
resource: https://web.archive.org/web/2020/https://www.microsoft.com/en-us/research/wp-content/uploads/2009/01/pentagons.pdf
tags: [abstract-domain, bounds-check, relational, level-3]
authors: [Francesco Logozzo, Manuel Fahndrich]
year: 2008
venue: SAC 2008, Science of Computer Programming 2010
informs: [/techniques/pentagon-domain.md]
pipeline_stage: 06-pentagon
status: stable
generated: { by: "process:phase-0-ingest", at: "2026-07-30T00:00:00Z" }
verified: [{ by: "process:link-check", at: "2026-07-30T00:00:00Z" }]
---
```

**`type: technique`**, in `techniques/`:

```yaml
---
type: technique
title: Pentagon abstract domain
description: Intervals plus strict upper-bound relations between variables. Level 3 in the domain hierarchy.
tags: [abstract-domain, bounds-check]
sources:
  - resource: /works/logozzo-2008-pentagons.md
  - resource: /works/cousot-1977-abstract-interpretation.md
implemented_by: [/implementations/sbcl.md]
absent_from: [/implementations/chez.md]
used_by: [/decisions/pentagon-not-octagon.md]
pipeline_stage: 06-pentagon
---
```

**`type: implementation`**, in `implementations/`. The `lacks` field is the one that earns
its keep, because it turns the central finding of this project into queryable data:

```yaml
---
type: implementation
title: Chez Scheme
description: Fast-compiling native Scheme with a category-level type lattice and no loop analysis.
resource: https://github.com/cisco/ChezScheme
tags: [scheme, native, nanopass]
implements: [/techniques/stack-segment-continuations.md, /techniques/predicate-narrowing.md]
lacks: [/techniques/interval-domain.md, /techniques/pentagon-domain.md, /techniques/loop-analysis.md, /techniques/slp-vectorization.md]
evidence:
  - s/cptypes-lattice.ss:573-574 collapses index, length, sub-index to fixnum-pred
  - no induction, licm or hoist anywhere in s/*.ss
  - s/x86_64.ss emits only scalar sd instructions
verified: [{ by: "human:nathan", at: "2026-07-30T00:00:00Z" }]
---
```

**`type: decision`**, in `decisions/`:

```yaml
---
type: decision
title: Native back end, not C emission
description: Emit x86-64 directly rather than C, because C forecloses precise GC roots, calling convention control, and full continuations.
status: stable
sources:
  - resource: /implementations/chez.md
  - resource: /implementations/stalin.md
supersedes: []
tags: [architecture, back-end]
generated: { by: "human:nathan", at: "2026-07-30T00:00:00Z" }
---
```

### Acceptance criteria for the bundle

- Bundle root `index.md` carries `okf_version: 0.2`.
- Every non-reserved `.md` file has parseable YAML frontmatter with a non-empty `type`.
- Every `works/` document has a `resource` that was checked reachable, and a `verified`
  event recording when.
- Every `works/` document names at least one `techniques/` document in `informs`, so no
  paper is ingested without being connected to something we are building.
- Every `techniques/` document cites at least one work in `sources`.
- Every `decisions/` document cites either an implementation or a work. No decision rests
  on nothing.
- `log.md` records each ingest batch, newest first.
- The bundle validates against the `openknowledge` CLI, and renders in Google's static
  visualizer.

### Traversal, which is the point

Later planning and design sessions read this bundle rather than re-deriving. The questions
it should answer without further research:

- What eliminates a bounds check, what domain does it need, and what does that domain cost?
- Which of these techniques does Chez have, which does SBCL have, and where is the evidence?
- Why did we choose Pentagon over Octagon, and what would change that?
- Which paper informs pipeline stage 06, and what does it actually require?

The `pipeline_stage` field on works and techniques is what makes the last one a lookup
rather than a search. It maps directly onto the pass list in `../07-compiler/CUJ.md`.

---

## How to use the bibliography below

This is the fetch list that feeds section 0's bundle. Nothing here has been read or
ingested. Every link was checked for reachability on 2026-07-30 from this machine and
resolves to the document named.

Ingestion order suggestion is at the bottom. The grouping below is by role in our
pipeline (`../07-compiler/CUJ.md`), not by publication date, so an agent pulling these can
map each work to the pass it informs.

### Verification method and what the status codes mean

Each URL was checked with `curl -sIL`, falling back to a ranged GET where HEAD was
refused, following redirects, 20-second timeout.

- **200**: fetchable directly. 33 of 37.
- **202**: DSpace returns this on its handle endpoints while still serving the record. All
  four were separately confirmed through the DSpace REST API
  (`/server/api/pid/find?id=hdl:1721.1/NNNN`), which returned the exact titles listed.
- Not included: anything that returned 403, 404, or a connection failure.

Two host notes for whoever runs the ingest. `legacy.cs.indiana.edu` has **no A record** and
`cs.indiana.edu` resolves **IPv6-only**, so if your fetcher lacks IPv6 egress use the
`www.cs.indiana.edu` links below, which are IPv4-reachable and are what is listed here.
`dl.acm.org`, `sciencedirect.com`, `researchgate.net` and `microsoft.com/en-us/research`
all return 403 to scripted fetches; where a work exists only there, a mirror is listed
instead.

---

## 1. Scheme compilation, the founding works

These establish that Scheme is compilable to efficient code at all, and they are where the
core-language design in `../07-compiler/CUJ.md` step 2 comes from.

| work | why it matters here | link |
|---|---|---|
| Sussman & Steele, *SCHEME: An Interpreter for Extended Lambda Calculus* (1975) | the origin document | https://dspace.mit.edu/handle/1721.1/5794 |
| Steele & Sussman, *Lambda: The Ultimate Imperative* (1976) | compiling control constructs to lambda | https://dspace.mit.edu/handle/1721.1/5790 |
| Steele & Sussman, *LAMBDA: The Ultimate Declarative* (1976) | procedure calls as the universal primitive | https://dspace.mit.edu/handle/1721.1/6091 |
| Steele, *RABBIT: A Compiler for SCHEME* (1978) | the first optimizing Scheme compiler | https://dspace.mit.edu/handle/1721.1/6913 |
| Dybvig, *Three Implementation Models for Scheme* (1987) | heap, stack and string models. The stack model is why Chez is fast | https://www.cs.indiana.edu/~dyb/pubs/3imp.pdf |
| Dybvig et al., *The Development of Chez Scheme* (ICFP 2006) | retrospective on the implementation we are measuring against | https://www.cs.indiana.edu/~dyb/pubs/hocs.pdf |
| Ghuloum, *An Incremental Approach to Compiler Construction* (2006) | the practical bootstrap path, Scheme to x86 in stages | http://scheme2006.cs.uchicago.edu/11-ghuloum.pdf |

## 2. Nanopass, the framework we build in

| work | why | link |
|---|---|---|
| Sarkar, Waddell & Dybvig, *A Nanopass Infrastructure for Compiler Education* | the original formulation | https://www.cs.indiana.edu/~dyb/pubs/nano-jfp.pdf |
| Keep & Dybvig, *A Nanopass Framework for Commercial Compiler Development* (ICFP 2013) | the version Chez itself is written in | https://www.cs.indiana.edu/~dyb/pubs/nano-icfp.pdf |
| Keep, *A Nanopass Framework for Commercial Compiler Development* (dissertation) | full treatment | https://andykeep.com/pubs/dissertation.pdf |
| Keep & Dybvig, nanopass preprint | | https://andykeep.com/pubs/np-preprint.pdf |

## 3. Continuations

Relevant because owning the back end puts full `call/cc` back on the table
(`../07-compiler/PLAN.md`, scope discipline). Chez's stack-segment design is the reference.

| work | why | link |
|---|---|---|
| Hieb, Dybvig & Bruggeman, *Representing Control in the Presence of First-Class Continuations* (PLDI 1990) | **the** stack-segment paper. How to have `call/cc` and cheap calls | https://www.cs.indiana.edu/~dyb/pubs/stack.pdf |
| Bruggeman, Waddell & Dybvig, *Representing Control in the Presence of One-Shot Continuations* (PLDI 1996) | the cheaper common case | https://www.cs.indiana.edu/~dyb/pubs/oneshot.pdf |
| Dybvig & Hieb, on `call/1cc` | one-shot continuations | https://www.cs.indiana.edu/~dyb/pubs/call1cc.pdf |

## 4. Intermediate representation, CPS and ANF

Informs the core language and whether we go SSA later for ABCD-style analysis.

| work | why | link |
|---|---|---|
| Flanagan, Sabry, Duba & Felleisen, *The Essence of Compiling with Continuations* (PLDI 1993) | A-normal form. Why you may not need full CPS | https://users.soe.ucsc.edu/~cormac/papers/pldi93.pdf |
| Appel, *SSA is Functional Programming* (1998) | the bridge between our functional core and SSA-based analyses | https://www.cs.princeton.edu/~appel/papers/ssafun.pdf |
| Appel, *Compiling with Continuations* (book) | the standard treatment | https://www.cs.princeton.edu/~appel/papers/cwc.html |

## 5. Inlining and closure representation

| work | why | link |
|---|---|---|
| Waddell & Dybvig, *Fast and Effective Procedure Inlining* (SAS 1997) | Chez's `cp0`. Inlining is what makes the rest of the analysis see anything | https://www.cs.indiana.edu/~dyb/pubs/inlining.pdf |
| Keep, Hearn & Dybvig, *Optimizing Closures in O(0) Time* | closure representation, directly relevant to escape analysis | https://www.cs.indiana.edu/~dyb/pubs/closureopt.pdf |

## 6. Flow analysis and type recovery

The anchor for declaration-anchored local inference (`../../PROPOSAL.md` section 4d).

| work | why | link |
|---|---|---|
| Shivers, *Control-Flow Analysis of Higher-Order Languages* (1991) | k-CFA. The foundation of higher-order flow analysis | https://www.ccs.neu.edu/home/shivers/papers/diss.pdf |
| Cartwright & Fagan, *Soft Typing* retrospective | why inference-first lost on usability, which is our argument for declarations | https://www.cs.rice.edu/~javaplt/papers/sigplan39-4.pdf |
| Aiken, Wimmers & Lakshman, *Soft Typing with Conditional Types* (POPL 1994) | conditional types, closest to what predicate narrowing needs | https://theory.stanford.edu/~aiken/publications/papers/popl94.pdf |

## 7. Abstract domains

The core of `../../CHEZ-ANALYSIS.md` section 4. This is the capability Chez lacks and we
must build.

| work | why | link |
|---|---|---|
| Cousot & Cousot, *Abstract Interpretation* (POPL 1977) | the framework everything below sits in | https://www.di.ens.fr/~cousot/COUSOTpapers/POPL77.shtml |
| Cousot & Halbwachs, *Automatic Discovery of Linear Restraints* (POPL 1978) | polyhedra, the expensive upper bound | https://www.di.ens.fr/~cousot/COUSOTpapers/POPL78.shtml |
| Miné, *The Octagon Abstract Domain* (2006) | level 4. What we do **not** need first | https://arxiv.org/abs/cs/0703084 |
| Miné, Octagon, HAL mirror | alternate host | https://hal.science/hal-00136664/document |
| Logozzo & Fähndrich, *Pentagons* (2008/2010) | **level 3, our actual target.** Purpose-built for array bounds | https://web.archive.org/web/2020/https://www.microsoft.com/en-us/research/wp-content/uploads/2009/01/pentagons.pdf |

## 8. Bounds check elimination

| work | why | link |
|---|---|---|
| Bodík, Gupta & Sarkar, *ABCD: Eliminating Array Bounds Checks on Demand* (PLDI 2000) | demand-driven, SSA inequality graph. The practical algorithm | https://www.classes.cs.uchicago.edu/archive/2006/spring/32630-1/papers/p321-bodik.pdf |

## 9. Vectorization

Stage 10, the pass no Lisp compiler has.

| work | why | link |
|---|---|---|
| Larsen & Amarasinghe, *Exploiting Superword Level Parallelism with Multimedia Instruction Sets* (PLDI 2000) | SLP. Basic-block vectorization, the right model for a straight-line f64 body | https://groups.csail.mit.edu/cag/slp/SLP-PLDI-2000.pdf |

## 10. Representation selection and unboxing

Stage 8. Where the actual speed comes from.

| work | why | link |
|---|---|---|
| Leroy, *Unboxed Objects and Polymorphic Typing* (POPL 1992) | the canonical treatment of when you may unbox | https://xavierleroy.org/publi/unboxed-polymorphism.pdf |
| Serrano & Weis, *Bigloo: a portable and optimizing compiler for strict functional languages* (SAS 1995) | the other Scheme that took types seriously | https://www-sop.inria.fr/members/Manuel.Serrano/publi/serrano-sac95.pdf |

## 11. Register allocation

| work | why | link |
|---|---|---|
| Burger, Dybvig & Fernández, *Register Allocation Using Lazy Saves, Eager Restores, and Greedy Shuffling* (PLDI 1995) | what Chez actually does | https://www.cs.indiana.edu/~dyb/pubs/Reg-Alloc-PLDI95.pdf |
| Poletto & Sarkar, *Linear Scan Register Allocation* (TOPLAS 1999) | the documented baseline | https://web.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf |

## 12. Memory management

| work | why | link |
|---|---|---|
| Appel, *Simple Generational Garbage Collection and Fast Allocation* (1989) | the collector design in `../07-compiler/CUJ.md` step 5 | https://www.cs.princeton.edu/~appel/papers/143.pdf |
| Dybvig et al., *BIBOP* | Chez's object layout and allocation | https://www.cs.indiana.edu/~dyb/pubs/bibop.pdf |

## 13. Books

| work | link |
|---|---|
| Abelson & Sussman, *SICP* | https://web.mit.edu/6.001/6.037/sicp.pdf |
| Appel, *Modern Compiler Implementation* | https://www.cs.princeton.edu/~appel/modern/ |

---

## Known gaps

Works that belong in this bibliography but for which no reachable open link was found from
this machine. Listed so the ingesting agent knows to look rather than assuming the list is
complete. Most exist behind `dl.acm.org`, which is bot-blocked but valid in a browser.

- Kranz et al., *ORBIT: An Optimizing Compiler for Scheme* (SIGPLAN 1986), and Kranz's 1988
  Yale dissertation.
- Gupta, *Optimizing Array Bound Checks Using Flow Analysis* (1993). The predecessor to
  ABCD.
- Chaitin, *Register Allocation and Spilling via Graph Coloring* (1982), and Briggs, Cooper
  & Torczon, *Improvements to Graph Coloring Register Allocation* (1994).
- Cheney, *A Nonrecursive List Compacting Algorithm* (1970).
- Tofte & Talpin, *Region-Based Memory Management* (1997). Relevant if region inference is
  revisited as a Stalin-style alternative to generational collection.
- Allen & Kennedy, *Automatic Translation of FORTRAN Programs to Vector Form* (TOPLAS
  1987). The loop-based vectorization tradition, complementary to SLP.
- Serrano & Feeley, *Storage Use Analysis and its Applications* (ICFP 1996).
- Siskind, *Flow-Directed Lightweight Closure Conversion* (1999). Stalin's core technique;
  `engineering.purdue.edu/~qobi/papers/pldi99.pdf` is dead.
- Wright & Cartwright, *A Practical Soft Type System for Scheme* (TOPLAS 1997). Only the
  retrospective was reachable.
- Würthinger, Wimmer & Mössenböck, *Array Bounds Check Elimination for the Java HotSpot
  Client Compiler* (2007).
- Muchnick, *Advanced Compiler Design and Implementation*, and Queinnec, *Lisp in Small
  Pieces*. Commercial books, no legitimate free source.

## Suggested ingestion order

Grouped by what unblocks what, rather than by importance.

1. **Build the thing at all**: sections 1 (Ghuloum, 3imp), 2 (nanopass), 4 (ANF).
2. **Make it correct on the hard parts**: section 3 (continuations), 5 (inlining and
   closures).
3. **The contribution**: sections 7 (domains, Pentagon especially), 8 (ABCD), 6 (flow
   analysis).
4. **Make it fast**: sections 10 (unboxing), 11 (register allocation), 9 (vectorization).
5. **Keep it alive**: section 12 (GC).

Sections 7 and 8 are the ones that matter most, because they are the capability
`../../CHEZ-ANALYSIS.md` proved Chez structurally lacks and SBCL has.
