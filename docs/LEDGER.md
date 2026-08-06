# Decision ledger

Chronological record of what was decided, what was reversed, and why. Plan files describe
the **active plan**; this file carries the reasoning that produced it, so plans do not
accumulate history and so a session that loses context can recover the argument rather than
re-deriving it.

Newest first within each section. A decision that was later reversed stays here with the
reversal attached, never edited away.

---

## Ratified decisions

| # | decision | date | rationale |
|---|---|---|---|
| D13 | **Bootstrap CIs, not t-tests**, from phase 2 onward | 2026-07-30 | Stabilizer shows repeated runs sample one memory layout, not independent draws; five of eighteen of their benchmarks fail normality without re-randomization. We cannot run Stabilizer (LLVM 3.1 pass; we emit x86-64 directly), so normality is not available and parametric tests are unlicensed. Bootstrap is distribution-free and yields the ratio we already report. |
| D12 | **Serial-only**, for now | 2026-07-30 | Benchmarks Game comparison is thread-count confounded (binarytrees 1.93-3.49 across languages). This machine cannot support parallel measurement: no `cpufreq`, and L3 sibling list reads `0-31` for every CPU so the 2-CCD split is invisible. nbody is serial in every published entry anyway. **Does not constrain vectorization** — stage 10 is SIMD, orthogonal to threads. Revisit on dedicated hardware. |
| D11 | **R6RS in scope** as configuration 2a | 2026-07-30 | Chez ships `(rnrs arithmetic flonums)` and `(rnrs arithmetic fixnums)`. It is the only standardized instruction-level hatch with a real implementation, so omitting it would measure a path nobody can take. |
| D10 | **OKF v0.2** as the knowledge bundle format | 2026-07-30 | `sources`/`verified` frontmatter maps onto link-checked bibliography directly. Only `type` is required and consumers must tolerate unknown keys and broken links, so domain fields are legal and a partial bundle stays conformant. Note the GC blog describes v0.1; build against v0.2. |
| D9 | **Build our own compiler** (phase 7) | 2026-07-30 | Reverses R3. Four architectural walls in Chez, none reachable from outside: level-1 category lattice cannot represent an index range; no classical loop optimizer; `optimize-level` global not lexical; no user-facing way to feed the lattice. Measuring on Chez measures Chez's ceiling. |
| D8 | **Native x86-64 back end**, not C emission | 2026-07-30 | Reverses R4. C forecloses precise GC roots, calling-convention control, full `call/cc`, and representation control — the last being the thing that makes Lisp fast. Also, emitting C and letting gcc vectorize would prove gcc is fast, not that Lisp is. |
| D7 | **Declaration-anchored local inference** | 2026-07-29 | Stalin has nothing to anchor on, so it derives everything from closed-world analysis: 2-4x over Chez where it works, 5-16x under where lifetime analysis fails, with nothing in the source saying which. Declarations supply anchors that keep inference local and preserve separate compilation. This is what SBCL already does (IR1 derives, IR2 selects). |
| D6 | **Pentagon, not Octagon**, for stage 06 | 2026-07-29 | Logozzo §8.1: closure made Pentagons *less* precise on three of four .NET assemblies (82.77% vs 83.19% on mscorlib) while tripling analysis time. Architectural, not just cost: Pentagon's `Sub` has no closure, so Miné's infinite-chain widening hazard cannot arise. |
| D5 | **Ada-style named check suppression**, not a CL safety dial | 2026-07-29 | Ada names each check and allows scoped re-enable; CL's 0-3 dial bundles risks deserving separate decisions. **`status: draft`** — phase 4 config 8 measures it, and if `All_Checks` beats named suppression meaningfully, granularity has a price and this needs rewriting. |
| D4 | **nbody first**, five programs down to one | 2026-07-29 | Serial in every published entry (no thread confound), pure double-float over a small fixed working set (isolates boxing and storage), and the program both Pecsek and Smith used, so external numbers exist to sanity-check against. |
| D3 | **Drop the Benchmarks Game harness** for `hyperfine` | 2026-07-29 | Its own README says the Python measurement scripts are "OBSOLETE and NO LONGER MAINTAINED". Take the sources and output fixtures, leave the framework. |
| D2 | **Own entries, not upstream entries** | 2026-07-29 | "Fastest entry per language" measures contributor effort as much as compiler quality, across 33 SBCL and 26 Racket entries by different people over two decades. |
| D1 | **Cite the frozen corpus, never mix it into our tables** | 2026-07-29 | CLBG is frozen at SBCL 2.4.8 / Racket v8.15 with a STOPPED README, and our toolchains are newer on a virtualized machine. It is the thing being explained, not a comparator. |

## Reversals

| # | position | reversed | why it was wrong |
|---|---|---|---|
| R7 | "Statistical rigour is a CI-era concern" | 2026-07-30 | It appeared only in the future-CI section while phases 2-3 said "report with spread" and "above the noise floor". Neither is a test. Now applies from phase 2. |
| R6 | "Vary layout across the fanned-out CI nodes" | 2026-07-30 | This is the position Stabilizer §7 explicitly rebuts. Link order changes only inter-module placement; environment size moves the stack base but not inter-frame distance. One-time randomization buys sampling but neither normality nor variance reduction. |
| R5 | Coz predicts pass value before building | 2026-07-30 | Half right. Virtual speedup models "this stream runs faster", not "this instruction disappears, its scheduling barrier goes with it, and the loop vectorizes". **Enablement is not a speed change**, so for stage 06→10 it measures the floor and is blind to the ceiling. |
| R4 | Emit C, inherit gcc's vectorizer | 2026-07-30 | See D8. Verified gcc does vectorize bounds-free `restrict` loops to AVX-512, so the idea worked technically. It was still wrong. |
| R3 | "Do not build a compiler to prove a claim about a standard" | 2026-07-30 | True for the standards question, which a five-line macro settles. False for "can Scheme reach and beat CL", which is a compiler question. I was answering a question that had stopped being asked. |
| R2 | "Chez has no loop analysis at all" | 2026-07-30 | Built on grepping for `induction|licm|hoist`. Chez's Version 2 highlights list "optimizing letrec expressions and loops". Absence of those greps is not absence of the feature. Bounded to "no *classical* loop optimizer". |
| R1 | "SICP chapter 5 is a compiler" as tractability evidence | 2026-07-30 | §5.5's entire optimizer is one rule (`preserving`, no liveness dataflow), it has no IR, and it targets an abstract machine whose primitives include `extend-environment`. Evidence about shape, not difficulty. |

## Corrections to our own claims

- **Stack-segment paper cited as an existence proof** that full continuations are cheap. It contains **no measurements at all** — three performance claims in the abstract, no table or figure in twelve pages. Our own `ctak`/`fibc` numbers carry that claim instead.
- **Cousot & Cousot 1977 credited with Galois connections.** The phrase never appears; it is a Galois *insertion*. The adjunction is POPL **1979**.
- **C# described as "1.2-2x off Rust"** from recall. Measured: gmean 1.64, median 1.45 on CLBG, but bimodal — C# *beats* Rust on fannkuchredux (0.57), ties on spectralnorm and pidigits, loses on binarytrees (5.84, GC vs arena) and mandelbrot (3.10). TechEmpower inverts it entirely (ASPLNET 1.9x ahead of Actix), because it measures engineering investment in a server stack, not codegen.
- **"All 55 links verified reachable."** Status-code checking is not payload verification. 20 of 55 served non-PDF, including 11 identical HTML soft-404s at HTTP 200.
- **Two SSA papers swapped**, and the bibliography claimed "title confirmed by text extraction" for the wrong one. The extraction had returned the POPL title and I misread it as confirming TOPLAS.
- **Soft-typing usability argument attributed to the retrospective**, which never discusses adoption. It lives in the PLDI 1991 facsimile at pages 3-17 of the same file.

## Errors found *in the sources*

Kept because they are implementation hazards, not trivia.

- **Kildall's Theorem 2 is false** for his own constant propagation. The proof needs distributivity, not monotonicity; his function fails it. Algorithm A computes MFP, not MOP. Kam & Ullman 1977 corrected it.
- **Pentagons Figure 3 prints an unsound widening**, in both halves, and **the bug is masked whenever the iterate sequence is monotone increasing** — exactly what a naive test suite produces. Three further transcription errors in the same paper.
- **Chaitin's prose and SETL appendix disagree** on the spill heuristic (`cost/degree` vs plain minimum cost). Implement from the prose.
- **Allen & Kennedy Figures 4.2 and 4.4** print `worklist := worklist – {x}` where the algorithm needs `+ {y}`. As printed, neither loop can progress.
- **Stabilizer's abstract contradicts its own §6.1** on the -O2 result, which fails at the α=0.05 used everywhere else in the paper.

## Open questions

| question | status |
|---|---|
| Writeup or library as the deliverable? | Unanswered. Affects phase 5/6 emphasis only. |
| How much does the expansion-time propagator matter? | Unanswered. Phase 5 tier two. |
| Deutsch & Schiffman 1984 | **Genuinely unavailable.** No OA location per OpenAlex and Semantic Scholar. Only real loss in the corpus. |
| Does Chez's `cptypes` already do our job at `optimize-level 2`? | Open experiment. If a predicate guard at level 2 emits the same code as level 3, the gap is smaller than the standards analysis implies and `PROPOSAL.md` changes. |

## Housekeeping conventions learned the hard way

- **Never `git add -A` while agents are running.** It swept another agent's in-progress files into an unrelated commit. Stage paths explicitly.
- **A 200 is not a PDF.** Check `%PDF` magic bytes; the fetcher now does.
- **Pre-2000 papers may exist only as `.ps` or `.ps.gz`.** A PDF-shaped search reports them missing. Recovered Bigloo, Allen & Kennedy and all three Blanchet papers this way.
- **Guessing filenames is not a search surface.** It failed every time. Enumerate the directory via the Wayback CDX index instead.
- **Four search surfaces, not one**: per-paper web search, CDX directory enumeration, OpenAlex by DOI (the only way to learn a paywalled-looking ACM paper is open), and archive.org scanned periodicals.
