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
| D25 | **The runtime is Scheme, not C. No libc in the running system** | 2026-08-06 | `CUJ.md`'s layout inherited `gc.c` and `rt.c`; that was drift, caught by Nathan asking whether we were emitting C. Per `compare-operating-systems` `lessons/metacircular-bootstrap.md`, Loko's collector is a Scheme library returning assembler instruction lists **at compile time**, so at run time there is no collector to bootstrap, only a label in the text segment. What genuinely must be written in something else is ~60 straight-line instructions that discover nothing, and we emit those. A C runtime under a Scheme kernel drags a C toolchain and libc into CIVICS, which is what that OS exists not to be. Build-time bootstrapping is separate and free: Chez is the seed, and **the seed is a build dependency, not a component**. Licensing: Loko is copyleft, so take the shape from the published description and do not copy code; read Mezzano (MIT) and Chez (Apache 2.0) for detail. |
| D26 | **Keep our callee-saved set inside System V's. Do not claim `rcx`/`rdx`** | 2026-08-07 | x86-64 has four raw registers after scratch reservation and all four are caller-saved in System V, so every raw-word live range crossing a call spills unconditionally; float is worse, since System V has no callee-saved xmm at all. Declaring one or two ours would buy them back and make every foreign call pay a save/restore. **Declined**, for three reasons. It does not touch nbody, whose inner loop has no calls, so it buys nothing on the program every number in this project is measured against. The cost it removes lands only on x86-64, which D22 already made the secondary target; RV64 has `s8-s11` and never had the problem. And it trades a cheap foreign boundary — the thing that makes a Scheme usable next to existing code — for register pressure on the target we care about least. Revisit only if a benchmark whose hot loop contains a call enters the matrix. |
| D24 | **FP contraction is a named, lexically-scoped permission, default off. Reassociation forbidden** | 2026-08-06 | Found by the RISC-V smoke gate: RV64 gcc contracts to `fmadd.d` by default while baseline x86-64 has no FMA to contract into, so cross-ISA bit-exactness holds only with contraction and vectorization both off. Default-off keeps oracle check 2, the eleven-way bit-exact cross-agreement, which is the strongest correctness evidence the project has; a tolerance-based oracle is exactly where an unsound abstract domain would hide, since a wrong interval deletes a needed check and the symptom is a value that is only slightly wrong. Making it a *named scoped permission* rather than a global flag is the same mechanism D5 ratified for check suppression, and it is the intellectually consistent answer for a project whose thesis is that optimization permissions should be explicit rather than implementation-defined. It also makes the contraction delta measurable, which is a publishable result. Reassociation stays forbidden: it is a global reordering whose result depends on the vectorizer, and deferring it is cheap, whereas contraction must be in the IR before the back end emits anything. |
| D23 | **Vendor nanopass as a submodule**, not hand-rolled | 2026-08-06 | Pinned at `bb47b56` in `sonic/vendor/nanopass`. It typechecks the IR contracts that `EXECUTION.md` §1's whole parallelism argument rests on: a pass emitting a form its output language does not declare fails at compile time rather than as a wrong-code bug three stages later. Leverage is largest for many near-identical grammars, which is exactly a 13-stage pipeline. By the Chez authors, and Chez is built with it. Identity-pass smoke test green before anything real was written, per `CUJ.md` step 1. Note this adds no license claim of ours: a submodule references an upstream repo under its own terms. |
| D22 | **RISC-V is a first-class SonicScheme target, not a later port** | 2026-08-06 | Nathan's call. SonicScheme is intended to carry CIVICS, the OS in `soniccyclone/compare-operating-systems`. Consequence for `EXECUTION.md`: E2 splits into a machine-independent lowered IR plus per-target selection and encoding, and the metadata vocabulary becomes a per-target definition from the start rather than a shared enum with per-target semantics. Note also that no shipped Scheme has a RISC-V port, per that repo's `bundle/experiments/rv64-prologue.md`. |
| D21 | **PC-total GC metadata with a static register partition, not safepoint polls** | 2026-08-06 | See `docs/phases/07-compiler/PREEMPTION.md`. Zero mutator cost, which is the only option that does not tax the exact code this project exists to emit; a tight numeric loop with no calls is by construction a loop with no safepoint. Space is `O(c·s/8)`, the **same order** as conventional safepoint maps, because the assembler dedupes to a step function over calling-convention transitions and the static partition deletes the register half. Its dominant cost is register pressure, which is binding on x86-64 (7 value / 5 raw of 15) and is not on RISC-V (31 GPRs plus 32 unpartitioned FPRs), so D22 decides it. Cannot be retrofitted: Emacs is 1842 primitives never audited. |
| D20 | **The phase 7 compiler is named SonicScheme** | 2026-08-06 | Nathan's choice. Matches the `soniccyclone` GitHub handle that owns the repo. Names the compiler only; the benchmarking project around it stays `scheme-benchmarking`. |
| D19 | **Diff configurations for operator class, not only expression order** | 2026-08-06 | `config4-chez.ss` used generic `+`/`*` for index arithmetic where `config4-racket.rkt` used `unsafe-fx+`/`unsafe-fx*`, and `slots` was a global rather than a syntactic constant. That made Chez look 3.8x worse than Racket. Fixing it moved `chez-4` from 5703.42 to 1788.41 instr/step, 3.2x, with no algorithm change. **Bit-exact output did not catch it**, because correctness says nothing about whether two variants were written with equal care. This is the entry-quality contamination `PLAN.md` phase 3 warns about, and it is now a review step. |
| D18 | **Do not containerize the benchmarks. Docker buys nothing here** | 2026-08-06 | WSL2 runs **one** utility VM shared by every distro, and Docker Desktop's engine is a distro inside it. Proven: a container and this shell report identical `boot_id` (`53fc36a4-...`), identical `MemTotal` (12242652 kB) and uptimes 3s apart. Same kernel instance, same memory pool, same `.wslconfig`. Docker's cgroup limits are ceilings carved *below* that pool, never an expansion, and hitting one triggers cgroup reclaim, i.e. another stall source. It also fixes neither thing WSL2 actually costs us: `cpufreq` is absent inside containers too and the L3 sibling list still reads `0-31`. |
| D17 | **Retired instruction count is the primary instrument for check elision; wall time is secondary** | 2026-08-06 | The PMU works under WSL2 and is exactly deterministic: a gcc `-O1` loop measured 70123493 / 140123501 / 280123513 instructions at N = 10M / 20M / 40M, i.e. 7.0000 per iteration with ~123485 constant startup, linear across 4x. A deleted bounds check is a deleted compare-and-branch, so instruction count measures elision **directly and without noise** on a machine that has no `cpufreq` control and therefore drifting wall-clock. Bootstrap CIs (D13) still govern every time-based delta; they are not needed for counts. `perf` needed no sudo, extracted from `linux-perf` plus `libdw1t64`, `libdebuginfod1t64`, `libtraceevent1`. |
| D16 | **Vendor no upstream benchmark sources. Write all eleven variants ourselves** | 2026-08-06 | Completes D1/D2/D3, which had already refused the harness, the entries and the numbers, leaving only an output fixture as the reason to keep the corpus around. That reason does not survive inspection: matching one downloaded string is satisfiable by copying the string, while eleven independent implementations agreeing to nine decimals is real evidence. The algorithm comes from the problem specification and the numerical-methods literature; the initial conditions are physical constants, not anyone's IP. Also removes third-party BSD attribution obligations from a public repo. |
| D15 | **Keep `sb-simd` out of configuration 5**, now for a second and stronger reason | 2026-08-06 | It defines no `SB-SIMD-AVX512` package; the contrib stops at AVX2. This machine is Zen 5 with full AVX-512 and `gcc -march=native` reaches it. Including `sb-simd` would measure vector width, not language. The same fact hands phase 7 stage 10 a target SBCL cannot reach at all. |
| D14 | **Rebuild configuration 3 around implementation-native premises**, not SRFI 145 | 2026-08-06 | SRFI 145 imports fail on both Chez and Racket. There is no implementation on which a premise is portably expressible, which is the R7RS-large finding one level up and a better result than the delta config 3 would have produced. Chez gets a predicate guard `cptypes` narrows on (= config 2c); Racket gets nothing, since `racket/unsafe/ops` has no premise notion. |
| D13 | **Bootstrap CIs, not t-tests**, from phase 2 onward | 2026-07-30 | Stabilizer shows repeated runs sample one memory layout, not independent draws; five of eighteen of their benchmarks fail normality without re-randomization. We cannot run Stabilizer (LLVM 3.1 pass; we emit x86-64 directly), so normality is not available and parametric tests are unlicensed. Bootstrap is distribution-free and yields the ratio we already report. |
| D12 | **Serial-only**, for now | 2026-07-30 | Benchmarks Game comparison is thread-count confounded (binarytrees 1.93-3.49 across languages). This machine cannot support parallel measurement: no `cpufreq`, and L3 sibling list reads `0-31` for every CPU so the 2-CCD split is invisible. nbody is serial in every published entry anyway. **Does not constrain vectorization** — stage 10 is SIMD, orthogonal to threads. Revisit on dedicated hardware. |
| D11 | **R6RS in scope** as configuration 2a | 2026-07-30 | Chez ships `(rnrs arithmetic flonums)` and `(rnrs arithmetic fixnums)`. It is the only standardized instruction-level hatch with a real implementation, so omitting it would measure a path nobody can take. |
| D10 | **OKF v0.2** as the knowledge bundle format | 2026-07-30 | `sources`/`verified` frontmatter maps onto link-checked bibliography directly. Only `type` is required and consumers must tolerate unknown keys and broken links, so domain fields are legal and a partial bundle stays conformant. Note the GC blog describes v0.1; build against v0.2. |
| D9 | **Build our own compiler** (phase 7) | 2026-07-30 | Reverses R3. Four architectural walls in Chez, none reachable from outside: level-1 category lattice cannot represent an index range; no classical loop optimizer; `optimize-level` global not lexical; no user-facing way to feed the lattice. Measuring on Chez measures Chez's ceiling. |
| D8 | **Native x86-64 back end**, not C emission | 2026-07-30 | Reverses R4. C forecloses precise GC roots, calling-convention control, full `call/cc`, and representation control — the last being the thing that makes Lisp fast. Also, emitting C and letting gcc vectorize would prove gcc is fast, not that Lisp is. |
| D7 | **Declaration-anchored local inference** | 2026-07-29 | Stalin has nothing to anchor on, so it derives everything from closed-world analysis: 2-4x over Chez where it works, 5-16x under where lifetime analysis fails, with nothing in the source saying which. Declarations supply anchors that keep inference local and preserve separate compilation. This is what SBCL already does (IR1 derives, IR2 selects). |
| D6 | **Pentagon, not Octagon**, for stage 06 | 2026-07-29 | Logozzo §8.1: closure made Pentagons *less* precise on three of four .NET assemblies (82.77% vs 83.19% on mscorlib) while tripling analysis time. Architectural, not just cost: Pentagon's `Sub` has no closure, so Miné's infinite-chain widening hazard cannot arise. |
| D5 | **Ada-style named check suppression**, not a CL safety dial | 2026-07-29, **ratified 2026-08-06** | Ada names each check and allows scoped re-enable; CL's 0-3 dial bundles risks deserving separate decisions. Draft status is now discharged: `ada-8-named` and `ada-8-all` measure **801.00 instr/step each, identical**, so granularity is free. `ada-8-named` also lands at 1.22x scalar C, clearing the bar `PLAN.md` set for validating the mechanism at the language level, and beats every Lisp in the matrix while staying fully standard. |
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

- **The reserve reported success for the one guarantee it exists to make.**
  `raise-exhausted!` builds the heap-exhaustion condition inside the nursery reserve, which
  is right: allocating it from the space you just failed to find is the circularity that
  turns a recoverable error into an abort. But it did so under `(when p ...)`, so if
  `reserve-claim!` returned `#f` it silently skipped the write and raised `&heap-exhausted`
  anyway. The condition would have been reported as raised while the reserve had in fact run
  out. Now a loud, distinct error, with a test that reads the reserve words back and checks
  for a parseable header above both mutator pointers rather than merely checking the pointer
  moved.

- **The tagged-cell hazard in assignment conversion does not fire on nbody, and the reason
  is structural rather than lucky.** Boxing a mutated variable makes the cell tagged even
  when the value is a `raw-f64`, which would push every mutated flonum local out of the
  float registers and destroy exactly what this project measures. Measured on
  `bench/nbody/config-sonic.sps`: 18 top-level definitions, 187 primcalls, **zero `set!`
  forms**, so nothing is boxed. That is what idiomatic Scheme does — every loop carries its
  state in the parameters of a tail call, and every array update is `flvector-set!`, a
  store to a heap object rather than an assignment to a variable. The hazard is real for
  other programs and the mitigation is in place (a variable provably flonum gets a one-slot
  `flvector`, not a `vector`, so the value stays unboxed even though the cell is tagged).

- **Nanopass's generated fallthrough clause is the dangerous kind of default.** `essa.ss`
  had no `tailcall` clause, so nanopass generated one that copies operands verbatim with no
  environment lookup. It typechecks, it round-trips, and it is wrong: a back edge emitted
  `(tailcall loop i2 n)` while the binders were `loop.1`, `i2.11`, `n.5`, so every operand
  named a variable that did not exist. Silent, and it broke every loop consumer downstream,
  since a back edge is exactly where the induction step is read. `set!` and
  `declare-distinct` had the same hole. Found by the loop agent, which noticed its input was
  unusable and filed it rather than working around it. **Lesson: in a renaming pass, every
  production that mentions a variable needs an explicit clause; the ones you forget do not
  fail, they quietly pass the wrong name through.**

- **`(fl- 0.0 px)` is not floating-point negation**, and every Scheme nbody config we wrote
  uses it where `ref.c` writes `-px`. Verified: `(fl- 0.0 0.0)` is `0.0`, `(- 0.0)` is
  `-0.0`, and the sign survives the division that follows. Latent rather than active, since
  `px` is never exactly zero for five bodies, so the oracle passes today. It is still a
  divergence from `SPEC.md` and a bit-exactness hazard the moment a momentum sum cancels.
  Tracked as a bug bead; needs an `flneg` primitive and a normative spelling in `SPEC.md`.
- **`Lcore`'s single control input discards what D5 argued for.** Five named checks and a
  lexical `policy` form, but `primcall` carries one tri-state, so the IR cannot say
  "bounds unchecked, type still checked" at a call site. D5 was ratified precisely on the
  measurement that named granularity is free. Found by a subagent reviewing the frozen
  table, and it is right.

- **"The distro default `-march` is a trap; baseline should be `rv64gc`."** Wrong, and
  wrong in the expensive direction. Checked against current sources: **RVA23 makes the V
  extension mandatory** where RVA22 had it optional, **Ubuntu 26.04 LTS ships RVA23 images**
  and **dropped pre-RVA23 hardware in October 2025**, RHEL targets RVA23, and SiFive's
  P550/P870 align on it. Every RVA23U64 mandatory extension is present in the toolchain
  default, verified one by one, so the default is deliberate rather than accidental.
  `rv64gc` is the **legacy floor**, not the baseline. Consequence: E5-RVV is a first-class
  path for PC-class RISC-V, not a bolt-on, and the scalar path is the fallback for old
  hardware. The claim that survives is only that the march must be *stated* rather than
  inherited, since the same source silently changes instruction set with a flag nobody
  wrote down.

- **"Trip-count proof bounds preemption latency."** Raised as a cheap alternative to
  PC-total metadata. It does not: proving `i in [0, 50000000)` proves the loop is finite,
  not short. Omission is legal only when `trip_count × body_cost` is inside the latency
  budget. The general answer is strip-mining, and the trip count keeps its original job of
  deleting bounds checks and feeding the vectorizer's unroll factor.
- **"PC-total metadata is space-expensive."** Assumed, and wrong by an order. It is not one
  entry per instruction: the assembler drops any entry identical to its predecessor, so the
  table is a step function whose breakpoints are calling-convention transitions, the same
  population conventional stack maps use. The static register partition then removes the
  register half entirely. Same asymptotic space, ~2-3x constant, and approximately zero for
  call-free numeric loops.

- **"Stalin is 2-4x faster than Chez on float and array benchmarks"**, taken from
  `r7rs-benchmarks` into `RESEARCH.md` section 3 and used to frame Stalin as the Scheme
  ceiling. The comparison does not hold. **Stalin computes in IEEE single precision**, with
  no option to change it: its generated C has 335 `float` and zero `double`, and
  `(/ 1.0 3.0)` returns `0.3333333492279052734375`. The corpus was therefore comparing
  Stalin's binary32 against Chez's binary64, and phase 1 already found the same corpus ran
  Chez at `--optimize-level 2` with checks on. Measured head to head on nbody, Stalin
  retires 1889.99 instructions per step against `chez-4`'s 1788.41 **while doing half-width
  arithmetic**, so it loses by 5.7% with an advantage. Configuration 7 is closed as not
  measurable on equal terms.

- **Chez was suspected of boxing flonum intermediates**, offered as the explanation for a
  bad `chez-4` number. Measured and false: `bytes-allocated` around a tight `fl+`/`fl*`
  loop shows **0.18 bytes per iteration** at `optimize-level 3`, 0.22 at level 2. That is
  GC bookkeeping. The real cause was our own generic index arithmetic (D19).
- **"Scheme is slower than Common Lisp" was the project's opening premise.** Measured, on
  nbody, it is backwards: `racket-4` at 2.28x and `chez-4` at 2.73x scalar C both beat
  `sbcl-5` at 3.08x. Scheme's problem is not speed, it is that neither fast spelling is
  standardized, and the two implementations' mechanisms are not even the same kind
  (per-call-site unsafe operators vs a global compile-time policy).

- **Stack-segment paper cited as an existence proof** that full continuations are cheap. It contains **no measurements at all** — three performance claims in the abstract, no table or figure in twelve pages. Our own `ctak`/`fibc` numbers carry that claim instead.
- **Cousot & Cousot 1977 credited with Galois connections.** The phrase never appears; it is a Galois *insertion*. The adjunction is POPL **1979**.
- **C# described as "1.2-2x off Rust"** from recall. Measured: gmean 1.64, median 1.45 on CLBG, but bimodal — C# *beats* Rust on fannkuchredux (0.57), ties on spectralnorm and pidigits, loses on binarytrees (5.84, GC vs arena) and mandelbrot (3.10). TechEmpower inverts it entirely (ASPLNET 1.9x ahead of Actix), because it measures engineering investment in a server stack, not codegen.
- **"All 55 links verified reachable."** Status-code checking is not payload verification. 20 of 55 served non-PDF, including 11 identical HTML soft-404s at HTTP 200.
- **Two SSA papers swapped**, and the bibliography claimed "title confirmed by text extraction" for the wrong one. The extraction had returned the POPL title and I misread it as confirming TOPLAS.
- **Soft-typing usability argument attributed to the retrospective**, which never discusses adoption. It lives in the PLDI 1991 facsimile at pages 3-17 of the same file.

## Errors found *in the sources*

- **ABCD's neutral-cycle rule is unsound as textbooks state it.** "Revisit an active vertex
  at the same slack, conclude true" assumes the cycle you closed was a loop iteration. It
  need not be: an equality edge pair, such as a length and its alias, is a zero-weight
  two-cycle with no phi on it, and reading that as an iteration proves **every** inequality
  about that length, including the false ones. Caught by a test rather than by reading. The
  fix is to count meet vertices on the active path and refuse a cycle that crossed none —
  the coinduction needs a merge point to induct over.

Kept because they are implementation hazards, not trivia.

- **Kildall's Theorem 2 is false** for his own constant propagation. The proof needs distributivity, not monotonicity; his function fails it. Algorithm A computes MFP, not MOP. Kam & Ullman 1977 corrected it.
- **Pentagons Figure 3 prints an unsound widening**, in both halves, and **the bug is masked whenever the iterate sequence is monotone increasing** — exactly what a naive test suite produces. Three further transcription errors in the same paper.
- **Chaitin's prose and SETL appendix disagree** on the spill heuristic (`cost/degree` vs plain minimum cost). Implement from the prose.
- **Allen & Kennedy Figures 4.2 and 4.4** print `worklist := worklist – {x}` where the algorithm needs `+ {y}`. As printed, neither loop can progress.
- **Stabilizer's abstract contradicts its own §6.1** on the -O2 result, which fails at the α=0.05 used everywhere else in the paper.

## Open questions

| question | status |
|---|---|
| Does Chez's `cptypes` already do our job at `optimize-level 2`? | **Answered no, 2026-08-06.** Predicate guards cost 12 instr/step and recover nothing: 8533.41 guarded vs 8521.42 unguarded vs 1788.41 at level 3. `cptypes` had already narrowed the type unaided, so the whole 4.77x residual is bounds checking, which its level-1 lattice cannot represent. Direct validation of `PROPOSAL.md`. |
| Writeup or library as the deliverable? | Unanswered. Affects phase 5/6 emphasis only. |
| How much does the expansion-time propagator matter? | Unanswered. Phase 5 tier two. |
| Deutsch & Schiffman 1984 | **Genuinely unavailable.** No OA location per OpenAlex and Semantic Scholar. Only real loss in the corpus. |

## Housekeeping conventions learned the hard way

- **Never `git add -A` while agents are running.** It swept another agent's in-progress files into an unrelated commit. Stage paths explicitly.
- **A 200 is not a PDF.** Check `%PDF` magic bytes; the fetcher now does.
- **Pre-2000 papers may exist only as `.ps` or `.ps.gz`.** A PDF-shaped search reports them missing. Recovered Bigloo, Allen & Kennedy and all three Blanchet papers this way.
- **Guessing filenames is not a search surface.** It failed every time. Enumerate the directory via the Wayback CDX index instead.
- **Four search surfaces, not one**: per-paper web search, CDX directory enumeration, OpenAlex by DOI (the only way to learn a paywalled-looking ACM paper is open), and archive.org scanned periodicals.
