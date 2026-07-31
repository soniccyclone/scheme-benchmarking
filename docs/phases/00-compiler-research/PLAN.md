# Phase 0: Compiler Research

## Goal

Assemble the seminal works on implementing a performant Scheme, with direct links, so they
can be pulled and ingested in bulk.

**The output of this phase is an OKF bundle**, not a pile of PDFs. See section 0 below for
the bundle design.

The bibliography comes in two parts. Sections 1 through 13 cover the Lisp and Scheme
lineage. **Sections 14 through 21 cover the wider field**, and they exist because the first
draft of this document pigeonholed itself into Lisp. Most of the work on compiler
optimization happened elsewhere, and the SELF lineage in particular is the seminal work on
making a dynamically typed language fast without declarations.

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

## Ingestion rules

**Read the entire document. Every time.** Not the abstract, not the introduction and
conclusion, not a skim for the fields the frontmatter needs. If a work is long enough that
one pass will not hold it, take it in steps by chapter or by section and accumulate. A
dissertation and a book are multi-pass jobs, not skip-the-middle jobs.

The reason is that the value of this bundle is in `techniques/`, and a technique document
is a synthesis. Synthesis from abstracts produces a bundle that repeats what everyone
already believes about these papers, which is worth nothing and would be worse than
nothing because it would look authoritative.

Practical consequence: cost per work is not flat. Shivers' dissertation, the SSA Book, and
Appel's *Modern Compiler Implementation* are large. Budget them as multi-session units and
do not batch them alongside a thirty-page conference paper as if they were equivalent.

## Wave 0: discovery and prefetch

Runs before any ingestion. Two jobs, and the second one is the point.

**Job one, finish discovery.** The known-gaps list below names works with no reachable
open link found from this machine. Search for each, verify reachability the same way, and
add it to the fetch manifest. Where nothing open exists, record that explicitly rather
than leaving a hole.

**Job two, prefetch everything to a local cache before any agent reads anything.**

```
knowledge/.cache/
├── manifest.tsv          url, sha256, local path, http status, fetched-at, content-type
└── pdf/
    ├── <sha256>.pdf
    └── ...
```

Every subsequent agent reads from the cache by path, never from the network. This matters
for three reasons:

1. **A restarted agent costs nothing.** If an ingest agent fails halfway through a
   dissertation, the retry re-reads a local file rather than re-downloading it. With
   multi-pass reading of large documents, restarts are expected rather than exceptional.
2. **It removes host politeness from the fan-out calculation entirely.** The corpus is
   concentrated: 11 of the verified URLs are on `www.cs.indiana.edu` alone, 4 on
   `dspace.mit.edu`, 4 on `www.cs.princeton.edu`. Prefetching serially per host means the
   ingest wave can then fan out as wide as we like without touching those hosts again.
3. **It makes the corpus reproducible.** The sha256 in the manifest pins exactly what was
   read. A paper that moves or changes does not silently change our conclusions.

Prefetch is sequential per host, parallel across hosts, and it is the only stage that
touches the network.

---

## How to use the bibliography below

This is the fetch list that feeds section 0's bundle. Nothing here has been read or
ingested. Every link was checked for reachability on 2026-07-30 from this machine and
resolves to the document named.

Ingestion order suggestion is at the bottom. The grouping below is by role in our
pipeline (`../07-compiler/CUJ.md`), not by publication date, so an agent pulling these can
map each work to the pass it informs.

### Corpus quality: two files extract badly

Recorded so nobody quotes numbers out of them by accident.

`aiken-wimmers-lakshman-soft-typing-with-conditional-types` uses a font with unmapped digit
glyphs, so **every numeral is silently dropped** on text extraction: section numbers,
citation numbers, percentages, line counts. Any quantitative claim from that paper must be
read from the rendered page, not from extracted text.

`bod-k-gupta-sarkar-abcd-eliminating-array-bounds-checks-on` loses most math symbols on
extraction: `≤`, `φ` and `σ` render blank, so Table 1 and Definition 2 must be re-derived
from the rendered page rather than copied.

`chambers-ungar-customization-optimizing-compiler-technolog` is an OCR'd scan with garbled
code fragments (`iffrue:` for `ifTrue:`, `got0` for `goto`, `l` for `1`).

Also: this machine has no `poppler-utils`, so the `Read` tool's PDF path fails outright.
Working route is PyMuPDF. Installing `poppler-utils` would save every ingest agent from
rebuilding a venv.

### Correction: several entries in this bibliography were wrong

The largest was two SSA papers with their labels swapped. `ssa.pdf` from c9x.me is the
11-page **POPL 1989** conference paper; the UT Austin file, listed as "same, mirror", is the
40-page **TOPLAS 1991** journal article. They are different documents, not two scans of one:
different sha256, and the journal version alone carries arrays and aliasing, translation out
of SSA, the correctness proofs, and the measurements. Worse, an earlier draft of this
document claimed the c9x.me row's "title confirmed by text extraction" — the extraction had
in fact returned the POPL title, *An Efficient Method of...*, and it was misread as
confirming the TOPLAS one. Two agents reached this independently from opposite files.

Beyond the reachability problem below, running the recovery found that some entries here
were simply incorrect, and all four errors were mine:

- `oneshot.pdf` never existed at that path. The one-shot continuations paper was published
  as `call1cc.pdf`. There is also no separate Dybvig & Hieb `call/1cc` paper, so what were
  listed as two works are one work.
- `nano-icfp.pdf` never existed either. The ICFP 2013 nanopass paper was
  `commercial-nanopass.pdf`, and it is byte-identical to the copy already held from
  `andykeep.com`.
- The PLDI 1995 register allocation paper is Burger, **Waddell** & Dybvig. There is no
  Fernández on it.
- A file named for the ICFP nanopass paper is in fact Keep's dissertation.

The lesson generalizes past this document: a plausible-looking filename on an author's
publication index is not evidence that the file exists or that the citation is right.
`scheme.com/pubs/` supplied the authoritative filename-to-title mapping even though every
one of its links is dead.

### Correction: status codes are not payload verification

An earlier revision of this document claimed all 55 links verified reachable. That claim
was wrong and is retracted.

The check used `curl -sIL` and looked only at the HTTP status. Running the actual fetch
showed that **20 of the 55 URLs do not serve a PDF**, and several return HTTP 200 while
doing it. All 11 `www.cs.indiana.edu` links returned the identical 67253-byte HTML landing
page, a soft-404 with a 200 status. arXiv `/abs/` pages, DSpace `/handle/` pages, and the
Cousot `.shtml` pages are HTML by design and need their `/pdf/`, bitstream, or linked-PDF
form instead.

`tools/fetch-sources.sh` now validates the `%PDF` magic bytes on every download and on
every cached file, and records `not_pdf` rather than `ok`. A 200 is not evidence.

Current state: `tools/sources.tsv` holds 35 URLs confirmed to serve real PDFs, all fetched.
`tools/sources-rediscover.tsv` holds the 20 that need a correct URL found, which is wave
0's first job.

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
| **Steele**, *LAMBDA: The Ultimate Declarative* (1976) | procedure calls as the universal primitive. **Single-authored**: the title page names only Guy Lewis Steele Jr. Sussman appears in the acknowledgements. An earlier draft credited both, inheriting the author list from AI Memo 353 above, which genuinely is co-authored | https://dspace.mit.edu/handle/1721.1/6091 |
| Steele, *RABBIT: A Compiler for SCHEME* (1978) | the first optimizing Scheme compiler | https://dspace.mit.edu/handle/1721.1/6913 |
| Dybvig, *Three Implementation Models for Scheme* (1987) | heap, stack and string models. The stack model is why Chez is fast | https://www.cs.indiana.edu/~dyb/pubs/3imp.pdf |
| Dybvig et al., *The Development of Chez Scheme* (ICFP 2006) | retrospective on the implementation we are measuring against | https://www.cs.indiana.edu/~dyb/pubs/hocs.pdf |
| Ghuloum, *An Incremental Approach to Compiler Construction* (2006) | the practical bootstrap path, Scheme to x86 in stages. Our file is the 11-page workshop paper (Chicago TR-2006-06, pp. 27-37), not the longer extended tutorial it points at via a dead IU URL | http://scheme2006.cs.uchicago.edu/11-ghuloum.pdf |

## 2. Nanopass, the framework we build in

| work | why | link |
|---|---|---|
| Sarkar, Waddell & Dybvig, *A Nanopass **Framework** for Compiler Education* (JFP, marked EDUCATIONAL PEARL) | the original formulation. **Our file is the JFP version, not the ICFP 2004 paper** whose title is *Infrastructure*, pp. 201-212. Citing the ICFP pagination against this document is wrong | https://www.cs.indiana.edu/~dyb/pubs/nano-jfp.pdf |
| Keep & Dybvig, *A Nanopass Framework for Commercial Compiler Development* (ICFP 2013) | the version Chez itself is written in | https://www.cs.indiana.edu/~dyb/pubs/nano-icfp.pdf |
| Keep, *A Nanopass Framework for Commercial Compiler Development* (dissertation) | full treatment | https://andykeep.com/pubs/dissertation.pdf |
| Keep & Dybvig, nanopass preprint | | https://andykeep.com/pubs/np-preprint.pdf |

## 3. Continuations

Relevant because owning the back end puts full `call/cc` back on the table
(`../07-compiler/PLAN.md`, scope discipline). Chez's stack-segment design is the reference.

| work | why | link |
|---|---|---|
| Hieb, Dybvig & Bruggeman, *Representing Control in the Presence of First-Class Continuations* (PLDI 1990) | **the** stack-segment paper. How to have `call/cc` and cheap calls | https://www.cs.indiana.edu/~dyb/pubs/stack.pdf |
| Bruggeman, Waddell & Dybvig, *Representing Control in the Presence of One-Shot Continuations* (PLDI 1996) | the cheaper common case. Published as `call1cc.pdf`; there was never an `oneshot.pdf`, and there is no separate Dybvig & Hieb call/1cc paper | see `tools/sources.tsv` |

## 4. Intermediate representation, CPS and ANF

Informs the core language and whether we go SSA later for ABCD-style analysis.

| work | why | link |
|---|---|---|
| Flanagan, Sabry, Duba & Felleisen, *The Essence of Compiling with Continuations* (PLDI 1993) | A-normal form. Why you may not need full CPS | https://users.soe.ucsc.edu/~cormac/papers/pldi93.pdf |
| Appel, *SSA is Functional Programming* (1998) | the bridge between our functional core and SSA-based analyses | https://www.cs.princeton.edu/~appel/papers/ssafun.pdf |
| Appel, *Compiling with Continuations* (1992) | the standard treatment. **Not free.** Purchase reference, ISBN 978-0-521-03311-4. Cite Cambridge Core, not the Princeton sales page | (no open full text) |

## 5. Inlining and closure representation

| work | why | link |
|---|---|---|
| Waddell & Dybvig, *Fast and Effective Procedure Inlining* (SAS 1997) | Chez's `cp0`. Inlining is what makes the rest of the analysis see anything | https://www.cs.indiana.edu/~dyb/pubs/inlining.pdf |
| Keep, Hearn & Dybvig, *Optimizing Closures in O(0) Time* | closure representation, directly relevant to escape analysis | https://www.cs.indiana.edu/~dyb/pubs/closureopt.pdf |

## 6. Flow analysis and type recovery

The anchor for declaration-anchored local inference (`../../PROPOSAL.md` section 4d).

| work | why | link |
|---|---|---|
| Shivers, *Control-Flow Analysis of Higher-Order Languages, or Taming Lambda* (1991) | the foundation of higher-order flow analysis. **Note "k-CFA" is the field's later shorthand, not Shivers' term**: the dissertation defines 0CFA and 1CFA, sketches two incompatible 2CFA variants, and says they "are not intended to be the last word" | https://www.ccs.neu.edu/home/shivers/papers/diss.pdf |
| Cartwright & Fagan, *Soft Typing* retrospective **plus a facsimile of the full PLDI 1991 paper** | The 2-page retrospective (pp. 1-2) does **not** discuss adoption or standardization, so it is not the source for the declarations-beat-inference argument. Pages 3-17 are a scan of the complete original, and that is where the argument lives: adding the `SUB` rule destroys principal types (Example 4), and Example 9 shows an inferred type silently breaking a distant, well-defined call site | https://www.cs.rice.edu/~javaplt/papers/sigplan39-4.pdf |
| Aiken, Wimmers & Lakshman, *Soft Typing with Conditional Types* (POPL 1994) | conditional types, closest to what predicate narrowing needs | https://theory.stanford.edu/~aiken/publications/papers/popl94.pdf |

## 7. Abstract domains

The core of `../../CHEZ-ANALYSIS.md` section 4. This is the capability Chez lacks and we
must build.

| work | why | link |
|---|---|---|
| Cousot & Cousot, *Abstract Interpretation* (POPL 1977) | the framework everything below sits in. Has widening, narrowing and fixpoint approximation, but **not Galois connections**: the α/γ pair here is a Galois *insertion*, and the adjunction is from Cousot & Cousot POPL **1979** | https://www.di.ens.fr/~cousot/COUSOTpapers/POPL77.shtml |
| Cousot & Halbwachs, *Automatic Discovery of Linear Restraints* (POPL 1978) | polyhedra, the expensive upper bound | https://www.di.ens.fr/~cousot/COUSOTpapers/POPL78.shtml |
| Miné, *The Octagon Abstract Domain* (**AST 2001**, 10pp) | the workshop version. Punts on the integer case, and has neither widening nor narrowing | https://arxiv.org/pdf/cs/0703084 |
| Miné, *The Octagon Abstract Domain* (**HOSC 2006**, 90pp) | **not a mirror, a different document.** The journal version adds all proofs including the 17-page closure appendix, solves the integer case with tight closure, and adds incremental strong closure, widening with thresholds, narrowing, and the Astrée evidence. Its own first footnote identifies it as the journal version of the 2001 paper | https://hal.science/hal-00136664/document |
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
| **Serrano** (alone), *Control Flow Analysis: a Functional Languages Compilation Paradigm* (SAC 1995) | 0CFA-driven closure representation, the direct ancestor of the Keep closure work. **This is not the paper the row originally claimed**: the URL `serrano-sac95.pdf` was recorded against a citation for Serrano & Weis, *Bigloo*, SAS 1995, which is a different paper and is **still missing from the bundle** | https://www-sop.inria.fr/members/Manuel.Serrano/publi/serrano-sac95.pdf |

## 11. Register allocation

| work | why | link |
|---|---|---|
| Burger, **Waddell** & Dybvig, *Register Allocation Using Lazy Saves, Eager Restores, and Greedy Shuffling* (PLDI 1995) | what Chez actually does. Author list corrected against the title page; there is no Fernández | see `tools/sources.tsv` |
| Poletto & Sarkar, *Linear Scan Register Allocation* (TOPLAS 1999) | the documented baseline | https://web.cs.ucla.edu/~palsberg/course/cs132/linearscan.pdf |

## 12. Memory management

| work | why | link |
|---|---|---|
| Appel, *Simple Generational Garbage Collection and Fast Allocation* (**Princeton CS-TR-143-88, 1988**) | the collector design in `../07-compiler/CUJ.md` step 5. We hold the tech report; 1989 is the *Software—Practice and Experience* 19(2) journal version | https://www.cs.princeton.edu/~appel/papers/143.pdf |
| Dybvig, **Eby & Bruggeman**, *Don't Stop the BIBOP: Flexible and Efficient Storage Management for Dynamically Typed Languages* (Indiana CS TR #400, **1994**) | Chez's object layout and allocation. Never published beyond the tech report | see `tools/sources.tsv` |

## 13. Books

| work | link |
|---|---|
| Abelson, Sussman & **Julie Sussman**, *Structure and Interpretation of Computer Programs*, 2nd ed. 1996 | https://web.mit.edu/6.001/6.037/sicp.pdf |

**Caveat on the SICP file.** That URL serves the Unofficial Texinfo Format re-typeset (CC BY-SA 4.0), not the MIT Press original. Text and section numbering are faithful to the 2nd edition but pagination is not: 883 PDF pages against 657 printed, so any page citation must state which numbering it means. Text extraction from this file also silently drops the `Th` and `tt` ligatures, turning "The" into "e" and "after" into "aer", which will corrupt any automated quotation pipeline built on it.

---

## Part II: the wider field

Sections 1 through 13 are Lisp-heavy by construction, and that is a defect rather than a
scope decision. Most of the work on compiler optimization did not happen in the Lisp world,
and the sections below are the pillars that were missing. All links verified reachable
2026-07-30.

The most important omission was the SELF lineage. It is the seminal work on making a
dynamically typed language fast, it is not Lisp, and its techniques (type feedback,
customization, polymorphic inline caches) are the direct ancestors of everything .NET and
the JVM do today.

### 14. Dynamically typed language optimization: the SELF lineage

| work | why it matters here | link |
|---|---|---|
| Chambers & Ungar, *An Efficient Implementation of SELF* (OOPSLA 1989) | how you make a dynamic language fast without declarations | https://bibliography.selflanguage.org/_static/implementation.pdf |
| Hölzle & Ungar, *Optimizing Dynamically-Dispatched Calls with Run-Time Type Feedback* (PLDI 1994) | the ancestor of .NET's guarded devirtualization, which `../../PROPOSAL.md` section 4b covers | https://bibliography.selflanguage.org/_static/type-feedback.pdf |
| Chambers & Ungar, *Customization: Optimizing Compiler Technology for SELF* (PLDI 1989) | monomorphizing a dynamic language by specializing per receiver type | https://people.cs.umass.edu/~emery/classes/cmpsci710-spring2003/p146-chambers.pdf |

### 15. SSA form

Relevant because ABCD (section 8) is formulated on SSA, and stage 7 of
`../07-compiler/CUJ.md` notes the representation may move there.

| work | why | link |
|---|---|---|
| Cytron, Ferrante, Rosen, Wegman & Zadeck, *An Efficient Method of Computing Static Single Assignment Form* (**POPL 1989**) | the 11-page conference paper | https://c9x.me/compile/bib/ssa.pdf |
| Cytron, Ferrante, Rosen, Wegman & Zadeck, *Efficiently Computing Static Single Assignment Form and the Control Dependence Graph* (**TOPLAS 13(4), 1991**) | **the** SSA paper, 40 pages. Adds arrays and aliasing (§3.1), translation *out* of SSA (§7), the correctness proofs, and the FORTRAN measurements. None of that is in the POPL version | https://www.cs.utexas.edu/~pingali/CS380C/2010/papers/ssaCytron.pdf |
| Braun et al., *Simple and Efficient Construction of Static Single Assignment Form* (CC 2013) | the construction you would actually implement | https://c9x.me/compile/bib/braun13cc.pdf |
| Cooper, Harvey & Kennedy, *A Simple, Fast Dominance Algorithm* | prerequisite for SSA construction. Title confirmed | https://c9x.me/compile/bib/quickdom.pdf |
| Rastello et al., *SSA-based Compiler Design* (the SSA Book) | book-length treatment of everything downstream of SSA. **This file is a 2018 unfinished draft, not the 2022 Springer edition**: its title page reads "Lots of authors / Static Single Assignment Book", the dedication is Lorem ipsum, the preface is "TODO: Roadmap", two figures in ch.10's induction-variable walkthrough fail to render, and several cross-references print as "Chapter ??". Section and page numbers will not match the published book | https://pfalcon.github.io/ssabook/latest/book-full.pdf |

### 16. Classical dataflow optimization

| work | why | link |
|---|---|---|
| Wegman & Zadeck, *Constant Propagation with Conditional Branches* (SCCP) | the algorithm our interval domain generalizes | https://c9x.me/compile/bib/constpropssa.pdf |
| Click, *Global Code Motion **Global Value Numbering*** (SIGPLAN '95, pp. 246-257) | redundancy elimination on SSA. Title word order is code motion first with no conjunction, and the order is the paper's argument | https://c9x.me/compile/bib/click-gvn.pdf |

### 17. Instruction selection

Stage 11 of `../07-compiler/CUJ.md`.

| work | why | link |
|---|---|---|
| Aho, Ganapathi & Tjiang, *Code Generation Using Tree Matching and Dynamic Programming* (twig) | the foundational formulation. Title confirmed | https://c9x.me/compile/bib/twig.pdf |
| Fraser, Hanson & Proebsting, *Engineering a Simple, Efficient Code Generator Generator* (iburg) | the practical one | https://c9x.me/compile/bib/iburg.pdf |

### 18. Register allocation, beyond linear scan

Stage 12. Section 11 has only two entries and both are baselines.

| work | why | link |
|---|---|---|
| George & Appel, *Iterated Register Coalescing* (TOPLAS 1996) | the graph-coloring answer, and coalescing is what makes it usable | https://c9x.me/compile/bib/irc.pdf |
| Wimmer & Franz, *Linear Scan Register Allocation on SSA Form* (CGO 2010) | the bridge if we adopt SSA | https://c9x.me/compile/bib/Wimmer10a.pdf |

### 19. Pointer and alias analysis

Stage 9, which currently has no literature behind it at all.

| work | why | link |
|---|---|---|
| Steensgaard, *Points-to Analysis in Almost Linear Time* (POPL 1996) | the cheap unification-based approach, right scale for our needs | https://www.cs.cornell.edu/courses/cs711/2005fa/papers/steensgaard-popl96.pdf |

### 20. Modern compiler architecture and rewriting

| work | why | link |
|---|---|---|
| Lattner & Adve, *LLVM: A Compilation Framework for Lifelong Program Analysis* (CGO 2004) | the reference architecture we are deliberately not using, worth understanding before rejecting | https://llvm.org/pubs/2004-01-30-CGO-LLVM.pdf |
| Willsey et al., *egg: Fast and Extensible Equality Saturation* (POPL 2021) | e-graphs. The modern answer to phase-ordering, and a candidate for our optimizer structure | https://arxiv.org/abs/2004.03082 |

### 21. Books, wider field

| work | link |
|---|---|
| Appel, *Modern Compiler Implementation in C* (1998) | **Not free.** Purchase reference, ISBN 978-0-521-60765-0 |
| Appel, Tiger compiler skeleton source | free and live, and the part we would actually use: https://www.cs.princeton.edu/~appel/modern/c/project.html |

### A note on four links in this part

`iburg.pdf`, `irc.pdf`, `constpropssa.pdf` and `click-gvn.pdf` are all reachable and all
served from `c9x.me/compile/bib`, a curated compiler bibliography maintained by the author
of QBE. Text extraction failed on them because they use Type 1 font encoding, so their
identity is inferred from conventional filenames in a curated list rather than confirmed by
reading the file. The ingesting agent should confirm the title on first read and correct
this document if any is wrong.

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
  Pieces*. Commercial books, no legitimate free source. Same for Appel's *Compiling with
  Continuations* and *Modern Compiler Implementation in C*, checked directly: Appel
  self-archives paywalled papers on his own index with `[local copy]` links and pointedly
  did not do so for these, and the advertised sample chapters at `modern/*/extract.pdf`
  now 404. A full scan of *Compiling with Continuations* circulates on a third party's
  course-reserve page; it is not authorized and is deliberately not used here.

- Serrano & Weis, *Bigloo: a portable and optimizing compiler for strict functional
  languages* (SAS 1995), LNCS 983, doi `10.1007/3-540-60360-3_50`. **Searched again and not
  found open.** Springer serves it at
  `link.springer.com/content/pdf/10.1007/3-540-60360-3_50.pdf` but returns non-PDF to a
  scripted fetch. Serrano's INRIA page is reachable at
  `www-sop.inria.fr/members/Manuel.Serrano/` and its publication index carries no PDF for
  this paper; the `publi/` path that served his SAC 1995 CFA paper has no SAS 1995
  counterpart. Likely needs institutional access or a manual browser download.

Wider-field gaps, found while assembling Part II and still unresolved:

- Kildall, *A Unified Approach to Global Program Optimization* (POPL 1973). The dataflow
  framework everything in section 16 sits inside.
- Morel & Renvoise, *Global Optimization by Suppression of Partial Redundancies* (CACM
  1979), and Knoop, Rüthing & Steffen, *Lazy Code Motion* (PLDI 1992). Partial redundancy
  elimination.
- Choi et al., *Escape Analysis for Java* (OOPSLA 1999), and Blanchet, *Escape Analysis for
  Object-Oriented Languages* (OOPSLA 1999). Directly relevant, since automatic stack
  allocation is one of the four ways `../07-compiler/PLAN.md` claims we exceed SBCL.
- Feautrier's affine scheduling work and Bondhugula et al., *Pluto* (PLDI 2008). The
  polyhedral tradition. Section 9 currently has only SLP, which is basic-block
  vectorization; polyhedral is the loop-nest answer and is the stronger technique where it
  applies.
- Wolf & Lam, *A Data Locality Optimizing Algorithm* (PLDI 1991). Cache blocking.
- Deutsch & Schiffman, *Efficient Implementation of the Smalltalk-80 System* (POPL 1984).
  Inline caches, the technique section 14's type feedback builds on.
- Andersen's 1994 dissertation on points-to analysis, the inclusion-based counterpart to
  Steensgaard.

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
