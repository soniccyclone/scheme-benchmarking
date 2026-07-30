# Phase 0: Compiler Research

## Goal

Assemble the seminal works on implementing a performant Scheme, with direct links, so
they can be pulled and ingested in bulk.

## How to use this document

This is a fetch list, not a reading list that has been read. Nothing here has been
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
