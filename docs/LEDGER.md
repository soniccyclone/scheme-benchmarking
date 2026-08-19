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
| D27 | **One spelling of a check. `chk` only; the `check-*` mach-ops are gone** | 2026-08-07 | Lmach had two ways to say the same thing. `chk` carries the CONTROL — whether the analysis proved it, a policy suppressed it, or it survived — and the EXPECTED TAG. The mach-ops `check-bounds`/`check-type`/`check-overflow` carried neither, and there was nowhere to put them: a mach-op is `(op v sc v* ...)` and every slot is spoken for. So a type check through that path had no tag and passed 0 — which is not a no-answer marker but the fixnum tag, so "check this is something" compiled to "check this is a fixnum", a branch that always traps for any other type. That plus an arity skew Chez warned about on every build was bd 5hs, and the duplication is what produced it. Nothing ever emitted them; lower.ss produces `chk` and only `chk`. Removed from `lang.ss` and from both selectors, and asserted as ABSENCE in both target tests so the duplication cannot come back. Lmach has no consumer outside this repo, so this is an internal refactor and not a contract change. |
| D28 | **Immediates get primary tag 111 with a 5-bit secondary tag** | 2026-08-07 | `numeric.ss` assigned exactly one tag — 000, to fixnums — leaving the empty list, the booleans and the unspecified value with no bit pattern at all. That stopped being survivable the moment `repr.ss` learned to merge a raw word into the tagged class: `(fx< 1 2)` is a 0/1 in a raw word, and joining it to `tagged` put 0 or 1 in the VALUE class, which under D21 the collector scavenges unconditionally and chases as an address. Confirmed on a real program, not reasoned about. So: `#f`=7, `#t`=15, `()`=23, unspecified=31, eof=39, secondary tags 5..31 free (a character takes one, code point above bit 8). Three constraints drove the layout. 111 is the one tag that cannot be mistaken for an 8-byte-aligned heap pointer under ANY partial mask, so a check that tests too few bits still fails closed. 001..110 stay contiguous for heap types, which keeps a heap-type dispatch a jump table rather than a compare chain. And `#f` is the LOW boolean so a raw comparison result tags by `(x << 3) \| 7` — a shift and an or, no branch, no table. The empty list has an encoding even though `null?` never reads it: regs.ss dedicates a register to nil on both targets, but that register still has to be initialized to something. |
| D29 | **One pointer tag for every heap type; the type lives in the object header** | 2026-08-07 | The type check was comparing against a hardcoded tag 1 that nothing justified, and no load stripped it: `vlen` read `[vec-8]` and an element read `[base + 8i]`, both of which are off by the tag on a tagged pointer. So the tag had to be settled and the displacements had to absorb it. A tag PER heap type is what the three spare primary tags would almost afford, and it is the wrong trade — `flvector-ref` and `vector-ref` lower to the same Lmach `load`, so Lmach's load would have to carry the base's heap type for the selector to pick the right displacement. That is an IR change, on the instruction in the hot loop, to answer a question only `vector?` and `flvector?` ever ask. Instead tag 001 means "heap object" and a header word carries the type: `[raw+0]` type, `[raw+8]` length as a RAW count (it is what `vlen` yields and it feeds a bounds compare directly, so it is not a fixnum), `[raw+16]` element 0, and the pointer aims at ELEMENT ZERO so indexing needs no addition beyond the tag adjustment the displacement already carries. The predicates pay one load; the loop pays nothing. `heap-element-disp`, `heap-length-disp` and `heap-type-disp` are stated once in `numeric.ss` so the two selectors cannot drift. |
| D30 | **Everything runs in a container, and the resource limits live in `docker-compose.yml`** | 2026-08-07 | Forced by a failure, not chosen for tidiness. An unguarded loop in `resolve-parallel-copy` consed once per iteration until a single Chez process held 31,204,756 kB — the whole WSL VM — and the kernel OOM killer took everything else down with it, three times in one session. The bug is fixed and guarded, but the CLASS is not going away: this compiler is a dozen fixpoints and hand-rolled worklists, and "a pass that does not terminate" will recur. The first answer tried was a per-invocation `ulimit` wrapper, and it was the wrong shape: it is a DISCIPLINE guarantee, and discipline is exactly what had just failed. A container carries its limits whether anyone remembers or not — Nathan's argument, and it is the deciding one: if the agent forgets, a container dies rather than the machine. Three things fall out of it for free. The toolchain becomes pinned, which matters because 81 x86-64 instructions are byte-verified against `gas` and the RISC-V gate reads our output back through `riscv64-linux-gnu-objdump` — tests that only mean something if the assembler is the same everywhere; it retires the `apt-get download` + `dpkg-deb -x` hack that stood in for having no sudo; and it mirrors how GHA will run the suite, so local and CI stop being different machines. `make test-suite` REFUSES to run outside a container, so there is one path and no second one for a later agent to reach for. Two traps recorded because both are silent: `deploy.resources.limits.memory` is IGNORED by `docker compose` outside Swarm, so the service-level `mem_limit` is the one that works; and `memswap_limit` unset defaults to twice memory, which buys a container the right to thrash its way to the same death instead of dying at the limit. Docker has no run-duration limit at all — `--stop-timeout` is a SIGTERM grace period and `--health-timeout` bounds one probe — so wall clock comes from `timeout` as PID 1 in the ENTRYPOINT. Deliberately NOT done: capping WSL in `.wslconfig`. The cgroup is the real bound and Nathan should not have to reconfigure his machine around our bug. |
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

- **I flipped `policy`'s boolean polarity and it was wrong.** The ANF agent read `b` as "is
  the conservative OBLIGATION in force" — run the check, or round twice rather than fuse —
  which makes `#t` the safe value for every name, keeps the default uniform, and keeps
  `checked` uniformly meaning the conservative thing happens. It reads oddly for one name,
  since `(policy ([fp-contract #f]) …)` is what *grants* contraction. I flipped it so `#t`
  meant "permission granted", which reads better for `fp-contract` and **makes contraction
  default on, inverting D24**. Four tests said so immediately. Reverted, with the reasoning
  written into `policy.ss` so it is not flipped a third time: the oddness is in one name's
  English, the alternative is wrong in the semantics.

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

- **Pentagons Figure 3, now caught by construction rather than by reading.** The defective
  widening was reconstructed and run against exhaustive concretization: it is **unsound on
  33,744 pairs through the interval half and 25,216 through the `Sub` half**, and the same
  harness reports it **clean on all 6,075 monotone-increasing pairs**. That second number is
  the finding — it is the proof that a naive test suite, which is what a reader would write,
  would have shipped the bug.

- **ABCD's neutral-cycle rule is unsound as textbooks state it.** "Revisit an active vertex
  at the same slack, conclude true" assumes the cycle you closed was a loop iteration. It
  need not be: an equality edge pair, such as a length and its alias, is a zero-weight
  two-cycle with no phi on it, and reading that as an iteration proves **every** inequality
  about that length, including the false ones. Caught by a test rather than by reading. The
  fix is to count meet vertices on the active path and refuse a cycle that crossed none —
  the coinduction needs a merge point to induct over.

### D31 --- a representation conversion belongs at the definition, not the edge

The obvious placement is the edge: convert at the call site for a parameter, in the
predecessor for a phi, before the return for a result. That is what the note asking for this
pass proposed, and it is three placements with three sets of control-flow reasoning.

It is not what the pass needs to do. `repr.ss` already pushes requirements BACKWARD along
all three edge kinds -- call site to argument, phi to operand, procedure result to tail
variable. Once its fixpoint settles, a value that must be tagged **is** classified tagged
everywhere it is named, so a mismatch cannot survive on an edge. It survives in exactly one
place: a `let` whose variable joined up to `tagged` while its initializer still produces a
raw word.

One site, one rule, no control flow. The backward propagation was two thirds present
already -- the call-site rule was there, the phi and tail-position rules were not, and
adding them is what collapses three placements into one.

The conversion itself needs no new machine op. A fixnum's tagged form is the value shifted
left 3, which is a multiply by 8; a boolean's is `(x << 3) | 7`, and since the shifted form
has its low three bits clear the OR is an add. `mul` and `add` already have rules on both
targets, which is worth more than the one instruction a dedicated shift op would save:
conversions appear only where a program mixes representations, never in a kernel, and a new
op costs two selectors, two encoders and the tests for both.

The three cases are not equally missing. A fixnum literal was always free and is why nbody
compiles. A boolean and a computed fixnum were both instructions-that-nobody-emitted, and
are now emitted. A double is a heap box with a GC map, which is a different kind of missing,
and the join still refuses it and says so.

The FIXNUM case was the one that mattered. The boolean join raised, which is visible; the
fixnum join answered `tagged` silently and left an untagged machine word in the value class
for D21's collector to scavenge. A refusal is a bug report. A silent wrong class is memory
corruption that nothing downstream will ever look at again.

### D32 --- a fixture cannot test the shape the front end produces

Five analysis passes -- `loops.ss`, `veclegal.ss`, `escape.ss`, `alias.ss`, `abcd.ss` -- were
written as a `nanopass-case` over an Lssa or Lanf **Expr**. The pipeline hands them a
**Program**. Every one matched nothing and returned its empty answer, and every one of them
was green across its whole test file while doing it.

The tests could not have caught it. Every fixture in all five files is a hand-built Expr, so
each test exercised the one shape that works. A fixture is a claim about a pass's behaviour
on an input the pass will never receive.

The failure mode is worse than a crash, and three of the five demonstrate why: an empty
answer is a legitimate answer for an analysis. No loops found, no allocation sites, an
inequality graph that proves nothing --- each is what a correct pass says about a program
with nothing in it. `alias.ss` raised, and was the easiest of the five to notice.

The damage compounded quietly. `veclegal.ss` asks `loops.ss` which loops exist, got none,
produced no verdicts, and the vectorizer had nothing to consider. Three passes agreeing that
nbody has nothing worth looking at.

**Every pass gets at least one test that starts from source text.** Not instead of fixtures
--- fixtures are how you test a specific shape --- but alongside, asserting something
knowable independently of the compiler. nbody allocates exactly three vectors; that number
is a fact about the benchmark, not about our IR, which is what makes it worth asserting.

Two repair shapes, chosen per file rather than uniformly. Normalising `(top ...)` into a
`letrec` at the entry point is exact --- top-level bindings are mutually recursive and
visible to one another, which is what letrec means --- and is right where several walks in
one file would otherwise each need teaching. Handling `top` directly is right where entering
a function needs its NAME (a top-level lambda arrives as an Expr, so a SimpleExpr walker
never sees it) or its parameters, because then the top-level case is the same line as the
letrec case and cannot drift from it.

### D33 --- the baseline guard is aimed at FUSION, not at the letter v

`encode-x86-64.ss` refused every VEX-shaped mnemonic by name. That was a fair approximation
while the encoder had none, and it is the wrong rule now that it does.

D24 makes FP contraction a named permission that is off by default, because a fused
multiply-add rounds differently from the reference C and the bit-exact oracle would be
comparing two different programs. That argument applies to `vfmadd*` and `vfmsub*`. It does
not apply to `vmulsd`, which computes exactly what `movsd` + `mulsd` computes --- same
operands, same rounding, same bits --- in one instruction rather than two. The only
difference is that VEX has a second source field, so the destination need not be one of the
inputs.

So the guard now admits the five three-address scalar forms by name and refuses the fused
ones by name. Both halves are tested: a guard that refused everything would pass the refusal
checks while making the three-address forms unreachable.

**This raises the ISA floor** from baseline SSE2 to AVX for the scalar back end. That is a
real cost and it is accepted rather than overlooked: the vector path already emits AVX-512,
so the project had accepted AVX hardware before this, and the floor is Sandy Bridge, 2011.
A machine that cannot run our vector output cannot run our scalar output either, and
pretending otherwise would have meant carrying two scalar back ends to serve a CPU nobody is
measuring on.

Worth 29 of 119 instructions in nbody's pairwise force loop --- every binary float op was
paying a `movsd` to stand its left operand up in the destination --- and it removes the one
case that had no instruction-local answer at all. `dst = src2` for a non-commutative op
needed a scratch register a selection rule cannot ask for; `vsubsd d, a, b` reads both
sources before it writes, so `d` aliasing `b` is simply fine.

The cost is a second float scratch. A two-address `addsd d, s` has two operands and one may
ride in memory, so one scratch covers it; `vaddsd d, a, b` has three, and `a` sits in the
prefix's `vvvv` field, which holds a register number and has no memory form. Fourteen
allocatable float registers remain, and the float class was never the one under pressure ---
nbody has 179 raw-f64 values against 196 raw-word ones, and it was the raw-word pool that
spilled.

### D34 --- instruction count stopped predicting cycles, so the instrument changes

Retired instructions have been the primary instrument since D17, and the reason was good:
wall time on a loaded machine is noise, and instruction count is exactly reproducible. It
is also, up to a point, a fair proxy. That point has been passed.

Pinning loop parameters and getting two constants out of registers removed **122
instructions per step, and bought about 7 cycles**:

|                | instr/step | cycles/step | IPC  |
|----------------|-----------:|------------:|-----:|
| before         |       1004 |         211 | 4.76 |
| after          |        882 |       203.8 | 4.33 |
| c-native       |        333 |       180.5 | 1.84 |

That is 0.057 cycles per instruction, against the 0.21 the milestone-5 arithmetic assumed.
The explanation is not subtle and it should have been anticipated: every instruction removed
here was a register-to-register `mov`, and x86 has eliminated those in the RENAMER since
Sandy Bridge. They retire, so `instructions:u` counts them; they never issue to a port, so
they cost nothing to remove. A register rotation on a loop back edge is the single most
move-shaped thing a compiler emits, which is why the effect showed up all at once.

Note what the IPC column really says. Ours FELL, from 4.76 to 4.33, and that is the
optimisation working: the instructions removed were the cheapest ones in the mix, so what
remains is denser. Rising IPC would have been the bad outcome.

We are within 13% of `gcc -O3 -march=native` in cycles while issuing 2.6x its instructions.
Both programs compute the same `sqrt` and the same divide per pair, and c-native's IPC of
1.84 says it is waiting on that chain rather than on issue bandwidth. It is very likely the
floor for both of us, and we are 23 cycles/step above it.

**So: cycles are the instrument for milestone 5, with instruction count kept as a
secondary.** Not a repudiation of D17 --- instruction count remains the right way to compare
ACROSS runtimes, where startup and GC would otherwise dominate, and it is what every
cross-implementation number in this project rests on. It is the wrong way to steer inside a
back end that has already removed the expensive work, because what is left to remove is
disproportionately free.

The practical consequence is that the remaining milestone-5 work has to shorten or overlap
the DEPENDENCE CHAIN, not the listing. Cutting another 100 moves is now known to be worth
about 6 cycles.

**Addendum, 2026-08-09: the ratio is steadier than the absolutes and is still not steady.**
Cycles on this laptop APU vary about 5% run to run, so a single reading steers nothing. The
ratio between the two binaries is better, because both ride the same clock excursion --- but
only somewhat. Seven trials of `perf stat -r 20`, two-point:

    n=7   min 1.003   median 1.142   max 1.207

**So: report the MEDIAN OF AT LEAST SEVEN TRIALS, with the spread.** An earlier version of
this note claimed 1.12 ± 0.02 on the strength of three trials that happened to agree; the
next three included a run where c-native alone read 191.8 against its usual 167, which
drags the ratio to 1.00 and would have been reported as "we caught gcc" by anyone taking
one measurement. Three trials is not enough to see that, and the failure is asymmetric ---
a lucky outlier reads as success.

Instruction and op counts have none of this: they are exact and repeat to the digit. Steer
on those, and use cycles only to confirm direction, over enough trials to see the tail.

**Second addendum, 2026-08-09: most of that spread was N, not the machine.**

The addendum above read `min 1.003 median 1.142 max 1.207` as run-to-run clock variation on
this APU and prescribed more trials. More trials was the right answer to the wrong
diagnosis. Those readings came from a two-point slope between **N=1000 and N=3000**, and at
that size the slope is measuring process startup:

    c-native, seven samples of cycles/step, N=1000 -> N=3000
    -118.3  163.7  174.7  177.1  192.1  231.1  236.8

A negative slope means the 3000-step run retired fewer cycles than the 1000-step run. The
difference being measured is 2000 steps at ~190 cycles, about 380k cycles, against a process
startup in the same range --- so the subtraction is noise minus noise. `measure.sh`'s own
default has been `N1=1000000` since it was written, for exactly this reason. The ad-hoc
scripts that produced the unstable numbers did not use it.

At N=1e6 -> 3e6, seven repetitions, the same machine and the same binaries:

|            | cycles/step | spread | instructions/step | spread |
|------------|------------:|-------:|------------------:|-------:|
| c-native   |      168.59 |  0.24% |               333 |  0.00% |
| SonicScheme|      189.01 |  1.49% |             717.5 |  0.00% |

Ratio **1.121**, and the two ratios previously quoted from the small-N measurements --- 1.07
and 1.13 --- were indistinguishable rather than different. The APU's clock does move, and
1.5% is what it actually contributes here; it was never the 20% the small-N spread showed.

**So: state the N with the ratio.** The median-of-seven-with-spread rule stands and did its
job --- a spread that wide is the instrument reporting its own inadequacy, and reading it as
a property of the hardware is what cost the extra measurements. `harness/measure-sonic.sh`
now does this one, because a number produced by whatever shell was convenient is a number
nobody can reproduce, and this project had two of them.

SonicScheme retires **2.15x** c-native's instructions and takes **1.12x** its cycles, which
is D34's whole thesis in one line.

Where the remaining ~14% lives is not a mystery. FP is 420 ops/step against c-native's 297,
and the difference is almost entirely fused multiply-add: gcc emits `vfmadd` and `vfnmadd`
throughout and each replaces two of ours. That is D24's contraction permission, off by
default because it protects the bit-exact oracle. Integer is 329 against 17, and that is
`outer%22`, whose counters cannot stay in registers for the reason recorded on its bead.

So beating gcc on cycles requires re-opening D24. Nothing in the back end reaches it.


### D36 --- D24 is re-opened as it was written: a variant that grants contraction

D34 ends "beating gcc on cycles requires re-opening D24. Nothing in the back end reaches
it." That was true in both halves, and the second was the more embarrassing one:
`fp-contract` had been a fully-formed permission since D24 --- parsed by policy.ss, scoped
lexically, carried on every flonum primcall, counted in lower.ss's report, deliberately
excluded from veclegal's check vocabulary --- and **nothing ever acted on it**. A program
that granted contraction got byte-identical code to one that refused it.

So re-opening D24 required changing nothing about D24. Contraction stays OFF by default and
stays a named, lexically scoped permission. `bench/nbody/config-sonic.sps` is untouched and
stays BIT-EXACT against Chez, which is oracle check 2 and the strongest evidence this
project has. What was added is a second variant, `config-sonic-fma.sps`, generated from the
first so the two cannot drift in anything but the policy wrapper, whose kernels grant the
permission. Its answers differ from the strict one in the last bit of the second energy ---
`-0.16908760523460614` against `...620` --- which is what one rounding instead of two does,
and is what was asked for.

**The comparison was never apples to apples, and that is the part worth recording.** gcc
contracts BY DEFAULT: `-ffp-contract=fast` is the default at every optimisation level, so
`ref.c` under `-O3 -march=native` has been emitting `vfmadd` and `vfnmadd` since the first
measurement in this project. Every ratio quoted here compared our twice-rounded arithmetic
against its once-rounded arithmetic --- two different computations, one of them allowed
fewer instructions. D24's own entry anticipated this ("it also makes the contraction delta
measurable, which is a publishable result"); what it did not anticipate is that the
un-contracted comparison would be the one on the record for two months.

|                    | cycles/step | instructions/step | FP ops/step | integer ops/step |
|--------------------|------------:|------------------:|------------:|-----------------:|
| c-native           |      168.71 |               333 |         297 |               36 |
| sonic, strict      |      189.19 |             717.5 |           - |                - |
| sonic, contracting |      178.05 |             650.5 |         280 |              370 |

**1.055.** And the FP side is past parity: 280 operations against gcc's 297, where D34
recorded 420. That half of D34's diagnosis is closed.

**CONTRACTION AND PACKING ARE NOT ALTERNATIVES, and treating them as such cost most of the
benefit.** Fusing before packing left slp.ss nothing to pack --- it packs add, sub, mul and
div, and a multiply-add already rewritten to `fma` is none of them --- so nbody's velocity
updates went from `vsubpd`/`vmulpd` back to six scalar load/fma/store sequences.
Contraction measured 4.5 cycles that way against the 15 it is worth. Packing first, and
packing the MARKED spellings so the permission survives into the packed form, is what
delivers both: a `vfmadd231pd` is two independent fused multiply-adds, lane by lane, each
rounding once where the two packed instructions it replaces round twice. Same permission,
same argument, twice over.

**What is left is entirely integer**: 370 operations per step against 36. gcc's 36 is not
tighter loop control, it is the absence of a loop --- five separate `vsqrtsd` sites in its
`main` say it fully unrolled the ten-pair nest, so every index is a constant displacement
and every `bi = i*3` folded. That is a structural difference and not an increment, and it
is tracked on its own bead rather than here.


### D37 --- the remaining nbody gap is divider occupancy, and instruction count cannot reach it

D34 said instruction count stopped predicting cycles. This is the cause, measured rather
than inferred.

**THE INSTRUMENT.** `bench/micro/divider-width.c`, independent chains so the number is
throughput and not a latency chain, on the Zen 5 part this project measures on:

| form | cycles per sqrt+div lane |
|---|---:|
| scalar | 7.601 |
| 128-bit | 4.220 |
| 256-bit | 2.109 |

Clean 1:2:4. **The floating-point divider does not care how wide the operand is.** A
256-bit `vsqrtpd`/`vdivpd` retires four lanes for about what one scalar lane costs.

**WHAT THAT MAKES OF nbody.** Ten pairs a step, each needing one square root and one
divide. Scalar, that is about 76 cycles of pure divider occupancy against a 188-cycle
step. Four-wide it would be about 21. Against gcc we run 717.5 instructions to its 333 and
take 188 cycles to its 169 --- IPC 3.81 against 1.97. We are not short of throughput; we
are waiting on one unit and on a dependence chain.

**THE EXPERIMENT THAT PROVES INSTRUCTIONS ARE NOT THE LEVER.** qaq.7.16 removed 92
instructions per step from nbody and bought 0.04 cycles: 188.58 to 188.54. Anything that
counts instructions and calls the count progress is measuring the wrong quantity on this
benchmark.

**TWO ROUTES CLOSED BY MEASUREMENT, BOTH BEFORE BUILDING ANYTHING.**

*Approximating the reciprocal is worthless.* A D24-style `fp-reciprocal` permission ---
`rsqrt` plus Newton refinement, which is what gcc's `-mrecip` buys --- would have removed
the divider work entirely. At 256 bits it measures 2.371 cycles a lane against the exact
form's 2.042. It LOSES. Once packed, the divider costs about two cycles a lane and
Newton's multiplies cost more than that. So bit-exactness stays and no new rounding
permission is introduced. The alternative was to build a lexically scoped permission, and
teach the differential oracle to expect divergence, in order to buy a regression.

*Staging the work through memory is worse than the divider.* Splitting nbody's pair loop
so the divides land in adjacent memory, where slp.ss's store-rooted seeding can reach
them, measured 274.89 cycles a step against a 189.59 baseline, bit-identical answers and
double the instructions. The third pass recomputes the distances the first pass had, which
costs 85 cycles against the ~55 packing ten divides four-wide is worth.

**SO THE ONLY LEVER LEFT ON nbody IS CROSS-ITERATION VECTORISATION WITH THE VALUES KEPT IN
REGISTERS.** slp.ss packs the three COORDINATES of one pair; the square root and the divide
are on that pair's scalar distance, one each, so nothing adjacent exists to pack them with.
Packing them needs the other axis --- pair 0 against pair 1, 2 and 3 --- which is loop
vectorisation of a triangular nest, not superword packing inside one expression.

**AND gcc LEAVES IT ON THE TABLE.** Its `main` has four scalar `vsqrtsd` and seven scalar
`vdivsd`, alongside 43 FMAs and 128-bit `vmovddup` packing that mirrors ours. This is the
first item in this project that is not catching up.

**A SECOND HARDWARE FACT, FROM THE SAME INVESTIGATION.** A masked 256-bit STORE does not
store-to-load forward on this part. nbody's inner loop holds `bi` invariant, so each
iteration stores `v[bi]` and the next reloads that address; `ls_stlf` per step is 132.34
unmasked against 63.48 masked, and the 65 lost forwards cost 7.6 cycles each --- which was
the whole of a 495-cycle regression, and looked for a while like a penalty for being
256 bits wide. It is not. Pad the layout and use the unmasked form. Cache-line splits were
ruled out separately: aligning every body to 64 bytes changed nothing, 682.89 against
683.88.


### D38 --- fannkuch's gap is not the checks, and the ceiling says so before the work starts

qaq.13 proposed a new abstract domain: an invariant over a vector's CONTENTS
("every element of perm is in [0,n)"), established where the array is filled and
preserved by every write, to discharge the last four bounds checks. The issue set
its own condition --- "do not start without a number" --- and the number is
obtainable without writing any of it, because D5's policy mechanism can suppress
a check on request and that is exactly the code a perfect proof would produce.

fannkuch-redux n=11, every variant answering 556355/51:

| variant | cycles | instructions | ratio |
|---|---:|---:|---:|
| gcc -O3 -march=native | 8.273G | 11.129G | 1.000 |
| sonic | 11.162G | 37.705G | 1.349 |
| bounds check off in flip-prefix | 10.969G | 33.783G | 1.326 |
| overflow check off everywhere | 10.764G | 32.061G | 1.301 |
| neither | 10.578G | 27.088G | 1.279 |

**The four bounds checks are 10.4% of instructions and 2.8% of cycles.** The
branches predict perfectly and the length load hits L1, so the machine absorbs
almost all of them. Removing EVERY check of every kind --- the combined ceiling
for all check-elimination work this compiler could ever do on this program ---
deletes 28% of the instructions and buys 5.2% of the cycles.

**AND THE HOT LOOP IS ALREADY RIGHT.** With the checks off, flip-prefix compiles
to eight instructions a swap, unrolled two-up, with peephole folding both index
updates into a load-effective-address:

    mov -0x1(%rbx,%rsi,8),%r10 ; mov -0x1(%rbx,%rdi,8),%r11
    mov %r11,-0x1(%rbx,%rsi,8) ; mov %r10,-0x1(%rbx,%rdi,8)
    lea 0x1(%rsi),%r10         ; lea -0x1(%rdi),%rsi
    cmp %rsi,%r10 ; jl

That is what a C compiler emits. The back end is not the problem, the register
allocator is no longer the problem, and the hottest loop in the benchmark is not
the problem.

**WHAT IS LEFT IS STRUCTURE.** With no checks at all we still run 27.088G
instructions against gcc's 11.129G and 5.31G branches against its 2.21G. gcc's
whole fannkuch `main` is 214 instructions: it inlined the nest and vectorised the
element copies. Ours are scalar loops --- correct, tight, and one element at a
time. slp.ss packs add, sub, mul and div on raw-f64; there is no integer packing
at all, and an eleven-element copy is eleven iterations.

**THE METHOD IS THE POINT.** Two measurements, an afternoon apart, each killed a
plausible piece of work before it was built: D37 refused an `fp-reciprocal`
permission because the approximation loses once packed, and this refuses a
contents domain because its ceiling is 2.8%. Both were reachable with a compiler
switch and a benchmark. Neither would have been visible from reading the code.

**ADDENDUM --- the integer packing this entry pointed at is also closed, at 5%.**
The paragraph above ends by naming integer packing as the next candidate, on the
grounds that an eleven-element copy is eleven iterations. `harness/profile-sonic.sh`
now attributes cycles to functions in an executable with no symbol table, and the
answer is that `copy-perm` is 5.13% of fannkuch and `rotate`'s shift loop is
3.31%. Those are the only two loops such a pass would touch, so its ceiling is
eight percent and its yield a fraction of that.

The profile also explains every conversion ratio in this entry. `flip-prefix`'s
swap loop is **51.98%** of the program, and taking its bounds checks out --- 17
instructions a swap down to 8 --- moved the whole benchmark about two percent.
Each unrolled iteration issues four loads and four stores, and that is the limit;
the checks ride in the shadow of the memory operations. `count-flips` is another
20.37%, and its loop reloads `perm[0]` immediately after `flip-prefix` stored it,
which is a store-to-load forwarding chain once per flip.

So fannkuch is memory-throughput-bound where nbody is divider-bound, and neither
responds to instruction removal. That is the same finding twice, in two units,
and it is why every instruction-cutting candidate measured this session came back
between 1:3 and 1:9. The remaining open passes --- LICM, inline rule 5, the
literal-index fold, the contents domain --- are all instruction-count
optimisations, and each now has a measured ceiling small enough that none should
be started for a benchmark number.


### D39 --- four gaps holding each other up: the tagged fixnum was half-implemented

`(fixnum? 5)` answered FALSE about the number five, and fixing it took one change
in four files because each gap was propping up the others.

numeric.ss has always specified a fixnum's tagged form as the value shifted left
three, tag 000. What the compiler did:

| | |
|---|---|
| a COMPUTED value joined up to `tagged` | shifted, correctly, by `retag fixnum` |
| a LITERAL classified `tagged` | **not** shifted; convert.ss exempted literals |
| a value stored into a tagged-element vector | **not** tagged |
| a tagged fixnum reaching `fx+`, `fx<`, `fx->fl` | **not** shifted back |

Nothing noticed because nothing read a tag. Fixnum arithmetic is `raw-word` and
consumes the machine word directly, so the two encodings coincided everywhere
they met. The predicates are the first code in this compiler's history whose
answer depends on the tag actually being there.

**AND THE DEPENDENCY IS CIRCULAR**, which is why three staged attempts failed and
each looked like a regression:

    untag on read     needs  tagging on store
    tagging on store  needs  literals encoded
    literals encoded  needs  untag on read

Enabling any one alone breaks a balance the others were holding. The fix landed
as one commit across convert.ss, lower.ss, repr.ss and runtime.ss, with nbody and
fannkuch unchanged to the instruction.

**THE PLACEMENT ASYMMETRY IS THE REUSABLE PART.** D31 says a representation
conversion lands at the DEFINITION, and that is general only for the direction a
requirement can be propagated in. repr.ss pushes a `tagged` requirement BACKWARD,
so convert.ss can retag where the value is made. A `raw-word` requirement cannot
travel backward at all: the join only ever moves a class UP toward `tagged`, so
asking a tagged value to become a machine word changes nothing and the program
compiles with the mismatch intact. It is therefore read at the CONSUMER and the
shift lands at the USE.

**AND A HAZARD DEFERRED ON A BAD ARGUMENT.** `%make-vector`'s fill was left raw
because "every program here fills with 0, which is the same word either way".
Every program in the SUITE did. The first one that did not was three lines long,
and it read back 0 instead of 7. Deferring on "no test covers it" rather than on
"no program can hit it" is the mistake; the three-line program should have been
written before the decision, not after it.

### D40 --- the divider prize is real, the route to it is not

D37 priced nbody's remaining gap at the FP divider: 7.601 cycles a sqrt+div lane
scalar against 4.220 two-wide and 2.109 four-wide, ten of them a step against a
188-cycle step. That measurement stands. What does not is the assumption that the
chains are sitting side by side waiting to be packed.

**THERE IS ONE HOT DIVIDER CHAIN.** The ten pair interactions are ten EXECUTIONS
of one site, not ten sites. Four routes to putting two in one block were built and
measured:

| route | result |
|---|---|
| stage the divides through memory | 274.89 cycles against 189.59 --- the split recomputes distances |
| full unrolling (qaq.7.19) | fixed so it compiles, bit-exact, still a net loss at 204.00 against 190.50, and 25 sqrt sites in 25 blocks |
| inline once-called procedures (qaq.7.24) | landed, worth -6.9% instructions, merged three chains --- all cold |
| unroll with a remainder | works, and costs **25.4 cycles** before any packing |

The last is the one that matters. A hand-written source-level remainder form does
put two chains in one block --- validated, `L.then348` holds two `sqrtsd` --- and
it costs 25.4 cycles and 401 instructions a step, because the pair body appears
three times instead of once. Against a two-wide packing prize of about 29 cycles.
Buys 29, costs 25.

**FOUR LANES IS WORSE, NOT BETTER**, which is the part worth carrying forward. It
saves more per lane, but needs four chains in a block and pays the duplication
twice over. The thing that creates the packing opportunity is the same thing that
costs the instructions, so the trade moves the wrong way as the width grows.

What would change the answer is a way to get two chains into one block WITHOUT
duplicating the body --- closer to software pipelining than to unrolling. The
prize is still there if one appears.

**AND THE PROBE FOUND A WRONG ANSWER.** The variant written to validate the shape
also miscompiled: slp.ss seeded a store pack by scanning the block from the top,
so with two groups accumulating into the same three elements the second group's
seed reached BACKWARD into the first and packed one value from one computation
with two from the other. One group per block had always been fine, which is every
program this compiler had seen. Had the transform been built first, this would
have read as "the transform is wrong".


### D35 --- a call destroys what its callee writes, not the whole register file

regalloc.ss spilled every value live across a call, and said why:

> Our own convention saves nothing: a called function uses the whole pool. So a value live
> ACROSS a call cannot stay in a register.

True of the CONVENTION and false of the PROGRAM, and this compiler has the whole program.
Integer registers actually written by each function in nbody, against the twelve in the
pool:

| function | writes | free for a caller |
|---|---:|---|
| `inner%24` | 5 | r8 r9 r12 r13 r14 rcx rdx |
| `outer%22` | 6 | r12 r13 r14 rdi r10 r11 |
| `energy-from` | 4 | rbx r12 r13 r14 rsi rdi r10 r11 |
| `init!` | 1 | everything but rax |

Not one writes more than half. `inner%24` leaves r8 and r9 alone because its parameters
ARRIVE there and the parameter pins keep them there --- it reads them and never writes them
--- while its caller was spilling exactly those two values across the call to it.

So a value live across a call may keep any register the call does not destroy. Functions are
finalised CALLEE-FIRST, so a caller is allocated knowing what its callees write; the image's
layout is unchanged, since that is not the call graph's business. A cycle, an unknown callee
and a runtime routine all answer "everything", which is precisely the old behaviour, so a
recursive knot costs nothing that was not already lost.

**A call destroys two things and only one is the callee's doing.** The callee writes what
its body writes; the CALL SITE writes the ARGUMENT REGISTERS, which are the caller's own
writes and appear in no callee's set. Reading only the callee's half hands a value a
register the argument setup overwrites a few instructions later. The return registers count
too, because xmm0 is allocatable.

Program-wide spills fall from 82 to 52. `init!` --- three allocations and their fills,
almost no arithmetic --- goes from 27 to 6.

**Two latent ordering bugs became reachable the same day, and both produced a program that
looped for ever rather than one that answered wrongly.** Each was safe only because every
value live across a call used to be in a frame slot, and neither rule can go wrong about
memory:

- `resolve-argument-moves` reads the moves before a transfer as a PARALLEL copy. A call's
  result move is not part of that permutation --- it makes a new value --- and left in the
  run, `movsd xmm4, xmm0` beside `movsd xmm0, xmm4` is a swap. The loop carried its previous
  accumulator round for ever.
- A load from an absolute address is hoisted to the front of the run because a load makes a
  value rather than permuting one. That argument is about its SOURCES. Its DESTINATION can
  be a register the run still reads, and in `subtract-pairs` the global `n-bodies` lands in
  the very register the loop counter arrived in, so the copy read `n` and the counter never
  advanced.

Both are now conditions on the hoist rather than exceptions to it, and both have a running
regression test, because a silent infinite loop is the one failure the suite cannot report.

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
| Where do representation CONVERSIONS get inserted? | **Answered 2026-08-07: at the DEFINITION, not the edge.** See D31. Two of the three cases are closed; the double still refuses. |
| How much does the expansion-time propagator matter? | Unanswered. Phase 5 tier two. |
| Deutsch & Schiffman 1984 | **Genuinely unavailable.** No OA location per OpenAlex and Semantic Scholar. Only real loss in the corpus. |

## Housekeeping conventions learned the hard way

- **Never `git add -A` while agents are running.** It swept another agent's in-progress files into an unrelated commit. Stage paths explicitly.
- **A 200 is not a PDF.** Check `%PDF` magic bytes; the fetcher now does.
- **Pre-2000 papers may exist only as `.ps` or `.ps.gz`.** A PDF-shaped search reports them missing. Recovered Bigloo, Allen & Kennedy and all three Blanchet papers this way.
- **Guessing filenames is not a search surface.** It failed every time. Enumerate the directory via the Wayback CDX index instead.
- **Four search surfaces, not one**: per-paper web search, CDX directory enumeration, OpenAlex by DOI (the only way to learn a paywalled-looking ACM paper is open), and archive.org scanned periodicals.

## The D-numbered record

Everything below is one decision per entry, appended in order, newest last. The
D number is the index -- entries are never reordered or edited away, and a
decision later reversed keeps its entry with the reversal attached.

The run starts at D41 because this file was split out of the plan documents
(`623f1f7`); D1-D40 are the decisions those plans already carried and were not
renumbered into here. Citations to them by number -- D24's fp-contract default,
D29's heap layout -- refer to that earlier record, not to a gap in this one.

## D41 -- fannkuch's gap is an unroller, and the note that said "inlining" was wrong

qaq.13 closed with a pointer: after check elimination "the remaining gap is call
structure and inlining, which is qaq.7.21's territory." Both halves are wrong,
and the pointer would have cost the next reader a pass.

MEASURED, in this order.

Rule 5 refuses NOTHING. Instrumenting the `(= 1 (tail-count b))` test that
gates the non-tail splice and compiling both benchmarks produced not one
refusal. qaq.7.21's ceiling is 0, not the 0.4% recorded from hand-inlining
`flip-prefix` -- and that number was stale anyway, because rule 2' now inlines
a once-named callee whatever its size.

Cycles at n=11 are 77.3% in three places: the two flip loops at 30.2% and
25.8%, and `count-flips` at 21.3%. `next` is 8.7%. Of `next`'s ten call sites
eight are `display`/`newline` for the first-thirty-permutations print and are
cold; the two hot ones reach `shift`. Every hot callee here -- `shift`,
`loop%2` -- is a named let, so it is RECURSIVE, so rule 4 refuses it and always
will. The calls that remain in the hot path are the ones no inliner is
permitted to touch, which is why rule 5 finding nothing is not a surprise.

WHAT GCC ACTUALLY DID. Its reversal is fully unrolled to N swaps, the low side
addressed by literal displacement and only the high side indexed:

    mov 0x8(%rbx),%r9d ; mov (%rbx,%rdx,4),%r10d
    mov %r10d,0x8(%rbx) ; mov %r9d,(%rbx,%rdx,4)
    lea -0x3(%rax),%edx ; cmp $0x3,%edx ; jle <done>

About seven instructions per swap, no low-side counter, no back edge -- an
exit chain instead. Its main is 198 instructions with 11 vector ops, so this is
not vectorisation; it is knowing the trip count. `#define N 11` bounds the
reversal at compile time and gcc spent the bound on unrolling.

So the missing transformation is a LOOP UNROLLER against a constant bound, and
inline.ss says in rule 4's own comment that it is deliberately not one:
"unrolling a loop is a different transformation with a different cost model and
this pass is not it." That was the right call and it is still right. It just
means the work does not live behind any inlining rule.

THE CEILING IS ALREADY MEASURED AND IT DOES NOT REACH PARITY. qaq.13's
no-checks variant runs the flip loop at roughly eight instructions per swap,
within one of gcc's seven, and it lands at 10.578G cycles against gcc's 8.273G
-- 1.28x. Matching gcc's instruction density in the hottest loop in the program
does not match gcc. At IPC 3.57 against gcc's 1.35 this machine is absorbing
our extra instructions, which is the same thing D37 said about nbody from the
other direction: on neither benchmark does the instruction count predict the
cycles, and on neither is the fix the one the instruction count suggests.

### D41 addendum -- the unroller needs qaq.13, and that revalues qaq.13

Reading gcc's chain again settles where its bound comes from, and the answer
changes what qaq.13 is for.

`flip-prefix` runs `i` up from 0 and `j` down from `k`, exiting at `i >= j`,
and `k` is `(vector-ref perm 0)` -- a RUNTIME value in both languages. gcc has
no more idea what perm[0] holds than we do. Yet its unrolled chain of eleven
swaps has NO BACK EDGE: the only `jne 1180` in that region is count-flips' own
loop, and the swap chain falls straight out the bottom into it. gcc therefore
proved the reversal runs at most N times.

The only justification available is that `k` indexes `int perm[N]`, so any
`k >= N` is out of bounds and gcc is entitled to assume it does not happen.
That is C's get-out. We do not have it and should not want it: out of range
here is a bounds check that fires, which is a defined outcome we are obliged
to produce.

WHICH MEANS THE BOUND HAS TO BE PROVED. To unroll `flip-prefix` we need
`(vector-ref perm 0) < n`, and that is exactly the element-range invariant
filed as qaq.13 and closed with "recommendation: keep open, do not start" on
the grounds that it buys 2.8% of cycles in check elimination.

That valuation was of the wrong product. Check elimination is the SMALL use of
an element-range invariant. The large one is supplying a trip-count bound to a
transformation that cannot run without it -- and that transformation covers
77.3% of fannkuch's cycles. The 2.8% number stands; what was wrong was reading
it as the invariant's whole worth.

The two issues are therefore ordered, not independent: qaq.13 is a prerequisite
for the unroller, and neither is worth pricing alone. The pair still has to be
argued against the 1.28x floor above, which no amount of instruction removal in
that loop has been shown to break.

## D42 -- a vector's contents, and the ascent that has to run alone

fannkuch's last eight bounds checks are gone, and the interesting part is not
that they went. It is what removing them did not buy, and what the fix had to
avoid to work at all.

THE FACT. The loop is `(fx< i j)` with `j` from `(vector-ref perm 0)`, so
bounding it needs every element of `perm` to be below `n` -- a statement about
the array's CONTENTS, which no scalar domain tracks. SPEC.md chose the program
for that shape and the test that asserted the eight checks said so.

WHICH VECTORS MAY CARRY ONE. Only a vector whose every occurrence is the vector
operand of `vector-ref`, `vector-set!` or `vector-length`. Anything else drops
it, because a vector passed as an argument is written through a parameter under
a name this analysis never connects to the global, and the join would then miss
that write and claim a range the program violates -- silent, and only on
programs whose vectors are shared. The rule counts occurrences rather than
reasoning about them, so no use can be examined and wrongly excused.

WHY TWO ASCENTS. This is the part worth carrying. An element range's own reads
feed its own writes: every write of `perm1` except `init`'s stores a value read
back out of `perm1`, so the equation is X = fill ⊔ init ⊔ X, and EVERY
over-approximation is a fixpoint of it, not just the least one. Interleaving
the element ascent with the interval ascent caught `init`'s parameter still at
top on round 1, X went to top there, and it never came back: narrowing walks an
upper bound back because the loop guard reimposes it, and nothing reimposes a
lower bound on a value that is only ever copied. The result was `perm elements
neginf 6` -- the right bound and a useless one, from a transient that became
permanent.

Separated, each ascent is a Kleene iteration from bottom under premises that
are already settled: intervals first with elements read as top, then elements
from the allocation fill with the intervals frozen, then intervals again to
spend the result. `perm` and `perm1` land at [0, n-1]; `cnt` stays unbounded
below, which is correct, it is a counter.

THE MEASUREMENT, AND WHAT IT KILLS. n=11, bit-exact:

    instructions   35.005G -> 27.161G    -22.4%
    cycles         10.880G -> 10.885G    unchanged

The stored note "fannkuch is instruction-bound, so instruction reduction
converts almost directly into cycles" is FALSE and is now corrected. IPC went
3.22 -> 2.50 across this change: the machine was absorbing all eight checks and
the bound is somewhere else entirely. That was foreseeable -- qaq.13 measured
this exact ceiling before the work started and recorded 2.8% -- and the honest
reading is that the ceiling measurement was right and the mental model beside
it was wrong.

So D34, D37 and now D42 all say the same thing from three different programs
and two different directions: on this machine the instruction count has not
once predicted the cycles. Anything proposed on an instruction-count argument
alone should be assumed not to move the clock until it is measured on the
clock.

### D42 addendum -- what is actually left, counted rather than inferred

The post-change guard count is `bounds 0, overflow 6`. Worth stating because the
instruction total invites a wrong inference: 27.161G sits next to the 27.088G
that qaq.13's table recorded for "neither bounds nor overflow", which reads like
both families went. They did not. That table was measured against a 37.705G
baseline and is -28% from it; this change is -22.4% from a 35.005G baseline that
had already absorbed a session of other work. Different denominators, and the
proximity of the two totals is coincidence.

Six overflow checks survive. Bounding an element bounds the INDEX arithmetic it
feeds, and that is what discharged the bounds family; it does not bound every
`fx+` in the program, and the six that remain are not in the reversal.

nbody is unaffected, as intended -- its flvectors are parameters, so
elemrange.ss declines to track them and the driver takes the untouched path.
Measured after the change at 186.92 cycles/step against c-native's 168.71,
which is 1.108x and if anything marginally better than the 1.12x before it.

## D43 -- the unroll ceiling is 8.4% of CYCLES, and that is the first one that converts

Probed before building, per D38. `flip-prefix` hand-unrolled to gcc's shape --
the low index a literal in every copy, no back edge, five copies because n=11
bounds k at 10 and floor(10/2) swaps can run -- compiled and measured against
the real thing. Bit-exact 556355/51.

    n=11                  cycles      instructions    vs gcc
    gcc -O3 -march=native  8.275G        11.129G       1.000
    sonic today           10.802G        27.161G       1.305
    sonic hand-unrolled    9.896G        24.812G       1.196

MINUS 8.4% OF CYCLES, against minus 8.6% of instructions. Set that beside D42,
where minus 22.4% of instructions moved the clock by nothing at all. Same
program, same machine, same week. The difference is what was removed: a bounds
check the machine was already absorbing costs nothing to delete, and a loop back
edge costs its full price. This is the first lever measured on fannkuch that
converts roughly one-for-one, and it is the reason qaq.23 should be built while
qaq.7.21 should not.

THE MECHANISM IS CONFIRMED, not assumed. The emitted probe carries
`mov -0x1(%rbx),%rsi` for perm[0] and `mov 0x7(%rbx),%rsi` for perm[1] -- the
low side folded to a literal displacement by addrfold, the high side still
indexed as `-0x1(%rbx,%rdx,8)`. That is gcc's shape, reached by the pass we
already have, once the index is a constant it can see.

AND IT IS AN UNDER-ESTIMATE, which is the useful part. Every copy pays an
instruction it should not:

    mov $0x0,%rsi ; cmp %rdx,%rsi        ; and $0x1, and $0x2, once per copy

The literal is materialised into a register instead of riding in the compare.
peephole.ss folds immediates but not with the constant on the LEFT of a
comparison, which is exactly where unrolling puts it -- `(fx< 1 j1)`.

THAT PARAGRAPH WAS WRONG ABOUT THE COST, and the correction is worth more than
the claim was. The swap was built (qaq.24), it works, and it buys NOTHING: the
compare becomes `cmp $0x0,%rdx ; jg` as intended and the `mov` stays, because
the constant 0 is ALSO flip-prefix's return value and the register has a second
genuine reader. Instructions came out identical to the digit. Reverted.

So `mov $imm` next to its only apparent use is not evidence of waste. The
register may be read somewhere the eye does not travel -- here, the epilogue --
and the peephole's "all uses or none" test knows it even when the reader of the
disassembly does not. 8.4% is the whole prize, not a prize through a waste.

## D44 -- bottom is not top, and the whole elision collapse was partly that

qaq.23 has been blocked since it was filed on a regression with a simple name
and no diagnosis: turning full unrolling on takes fannkuch from 0 surviving
bounds checks to 79 and nbody from 0 to 97. Nine hypotheses died on it in one
session -- out-of-range copies, lost `declare` premises, missing parameter
status, a broken refinement chain, edge polarity, a missing call site, and
three variants of "the trip count". Two of them were published here and
retracted.

The answer was in the domain, not the program.

`bounds-ok?` had rules for a dominating check, the interval domain and ABCD.
Every one of them asks a question about the index's VALUE. When the index's
interval is EMPTY -- bottom, the meet of disjoint constraints -- there is no
value to ask about, `iv-within?` is false, ABCD's query is false, and the site
falls through to `kept`. Bottom was being treated as though it were top.

It is the opposite of top. Top is "this index could be anything". Bottom is
"no value reaches here at all", so the access cannot execute and its check can
never fire. Discharging it is sound for the same reason unreachable code may be
deleted -- and sound in the safe direction even if the emptiness were spurious,
because the worst case is a check removed from code that does not run.

One clause. Measured on the emitted labels, not on elide's verdicts:

    specialization ON      before   after
    nbody                     97       0
    fannkuch                  79      34
    the 20-line probe          3       0

Zero regression on nbody, better than half of fannkuch's, and no change to
either benchmark with the pass off, where both were already at zero.

TWO THINGS TO CARRY.

First, the obvious one: a lattice's bottom needs its own case in any rule that
consults a value, and "no rule matched" is the wrong default for it. Worth
checking `type-ok?` and the overflow rules for the same gap; this fixed only
`bounds-ok?` because that is where it was measured.

Second, and it is the reason nine hypotheses died: every one of them was about
the PROGRAM -- which pass copied what, which procedure was live, which edge a
sigma was on. The defect was in the analysis's own algebra and would have been
found by asking what each rule does at each lattice point, which is a question
about twenty lines of `elide.ss` and no program at all. When a fact is missing
from an abstract interpretation, interrogate the domain before the input.

### D44 addendum -- the rule belongs at the dispatch, and the extension is free

`type-ok?`, `overflow-ok?` and `div-ok?` are written exactly like `bounds-ok?`:
consult a value, return "not discharged" when no rule matches. So all four had
the same gap, and the fix was moved up to `discharge?` where it governs the
family list at once and tests EVERY operand rather than the one a given rule
inspects -- an operation needs all its arguments to have values before it can
run.

THE EXTENSION MEASURES NOTHING. fannkuch keeps its six overflow checks with the
pass off and on, and neither benchmark has a type check left to discharge; the
numbers are identical to what the bounds-only rule gave.

It is kept anyway, and the distinction from D43's retracted compare-swap is
worth stating because both measured zero. That one was eighty lines of new pass
justified entirely by a performance win that did not appear, and it was
reverted. This is five lines generalising a rule already in the tree and
already load-bearing, justified by three sibling families carrying an identical
latent defect that a fourth would have acquired on arrival. The test is whether
the change would be worth making if it never appeared in any measurement: for a
defect class, yes; for a speculative optimisation, no.

## D45 -- every estimate denominated in instructions is now suspect

D42 killed the exchange rate the project had been using. It is worth saying
plainly what that invalidates, because the rate is buried inside estimates that
still read as if they were measurements.

D38 recorded fannkuch converting instructions to cycles at somewhere between
1:3 and 1:9, and several issues priced their prizes by multiplying an
instruction saving by it. D42 measured the conversion end to end -- 22.4% of
fannkuch's instructions removed, 35.005G to 27.161G, and the cycles moved from
10.880G to 10.885G, which is nothing. IPC fell 3.22 to 2.50. The machine had
been absorbing the instructions all along.

So: an estimate of the form "this removes N% of instructions, therefore about
M% of cycles" is not an estimate. It is an instruction count with a
multiplier attached that no longer has evidence behind it.

WHAT ACTUALLY CONVERTED, once, and it is the only case so far: D43's unroll
probe removed 8.6% of instructions and 8.4% of cycles. The difference between
that and D42 is what was removed -- a loop back edge in one case, bounds checks
the machine was already hiding in the other. Removing control flow converts.
Removing absorbed work does not.

Applied immediately to qaq.7.23, whose recorded prize of "a third of a percent
of cycles" was 1.1% of instructions times D38's rate; restated as
approximately nothing, which strengthens a recommendation that was already to
leave it alone.

THE RULE GOING FORWARD. Price in cycles or do not price. If only an instruction
count is available, say so and say that the cycle effect is unknown -- on this
part, for these programs, the honest prior is zero unless a branch is going
away.

## D46 -- control flow converts; work does not

Three results from one session, on one machine, that only make sense together.

    qaq.13   removed every surviving bounds check   -22.4% instr    0 cycles
    qaq.24   folded a materialised compare constant   0    instr    0 cycles
    D43      unrolled a loop, removing its back edge  -8.6% instr   -8.4% cycles

The first two look like bad luck and the third like a lucky guess. They are one
fact. This part issues wide enough to absorb arithmetic the program does not
need -- fannkuch was running at IPC 3.22 and fell to 2.50 when a fifth of its
instructions went, which is the machine reclaiming slots it had been filling
with checks. What it cannot absorb is a branch it has to predict and a loop it
has to close.

So the useful question about any proposed optimisation here is not "how many
instructions does this remove" but "does this remove control flow". Only the
second predicts anything. gcc's advantage on both benchmarks is of the second
kind: it deleted loops, and every index became a displacement because there was
no longer an induction variable to compute.

This subsumes D34 and D45 rather than repeating them. D34 observed that
instruction count had stopped predicting cycles; D45 said stop pricing in
instructions; D46 says what to price in instead.

A caveat that keeps this honest: three points is three points. The claim is
calibrated to this microarchitecture and these two programs, both of which are
small-working-set integer or FP kernels with predictable branches. A program
that misses cache or mispredicts would report a different exchange rate, and
the first such benchmark added here should be expected to overturn this.

## D47 -- fannkuch's gap decomposed, and we are not the one mispredicting

Milestone 5 recorded that even granting D43's whole 8.4%, 1.196x of fannkuch
remains unexplained. Following D46's own advice -- ask about control flow, not
work -- the counters say what it is made of.

    n=11            cycles    instructions   branches   mispredicts  miss%  IPC
    gcc -O3          8.281G      11.129G      2.209G      164.5M     7.45   1.34
    sonic           10.880G      27.161G      5.652G      144.2M     2.55   2.50
    sonic unrolled   9.901G      24.812G      5.257G      144.9M     2.76   2.51

THE FIRST SURPRISE IS THAT WE MISPREDICT LESS THAN GCC, in absolute terms:
144M against 164M. Our rate is lower too, but the rate is the uninteresting
half -- it is diluted by the two and a half times more branches we execute,
nearly all of them checks that predict perfectly. The count is what costs
cycles, and ours is smaller.

THE SECOND IS THAT GCC IS THE ONE THAT IS MISPREDICT-BOUND. IPC 1.34 on a part
this wide is not issue width. At a ~15-cycle penalty, 164M misses is about
2.5G cycles -- some 30% of gcc's 8.28G. fannkuch's inner loop is a
data-dependent permutation walk and those branches are not predictable by
anybody; gcc is paying the algorithm's own price with very little else in
flight to hide it behind.

DECOMPOSED, on that penalty assumption and stating it because the conclusion
depends on it:

                   mispredict cost    everything else
    gcc               ~2.5G               ~5.8G
    sonic             ~2.2G               ~8.7G        1.50x

So the residual gap is not branch behaviour and never was. It is that we do
half again as much real work per unit of progress, at an IPC that is already
1.9x gcc's. The machine is doing us a favour and we are still behind.

WHAT THIS CHANGES. D46 said price in control flow rather than instructions, and
that stands -- the unroll removed 7% of branches for 9% of cycles, which is the
only clean conversion measured here. But it would be a misreading to conclude
that branch COUNT is the target: our branches are cheap and well predicted, and
the mispredicts are the algorithm's, not the compiler's. The target is the work
underneath, which no instruction-count argument has been able to price because
the machine absorbs so much of it.

A caveat on the arithmetic: the ~15-cycle penalty is a book figure, not
measured on this part. The qualitative conclusion survives a wide range of it,
because our mispredict count is LOWER than gcc's -- any penalty makes gcc's
share larger than ours, and the residual work gap larger, not smaller.

### D47 addendum -- the surplus work is stack traffic and register shuffling

D47 left the residual as "1.50x of real work" without saying what the work is.
Static instruction mix over the functions holding 77% of fannkuch's cycles --
the two flip loops, count-flips, copy-perm and next -- says:

    mov                143   51.1%   of which  reg->reg shuffle   41  28.7%
    jmp                 19    6.8%             store to memory    24  16.8%
    cmp                 16    5.7%
    add                 16    5.7%
    call                12    4.3%

    instructions touching %rsp:  67 of 280   23.9%

NEARLY A QUARTER OF THE HOT CODE IS STACK TRAFFIC, and more than a quarter of
its moves are register-to-register shuffling. gcc's reversal loop touches the
stack not once; it holds everything in registers and its moves are the memory
swap the algorithm actually asks for.

And there are NO SHIFTS AT ALL in these loops, which retires a standing
suspicion: the tagged representation is not costing tag arithmetic here,
because repr.ss has already given this code raw-word class. Whatever the
surplus is, it is not tagging.

So the 1.50x is substantially register pressure -- values that will not fit in
the allocatable set, spilled and reloaded around a loop that gcc runs entirely
in registers, plus the copies a parallel-copy sequencer leaves behind.

THIS IS A STATIC COUNT AND THE CAVEAT MATTERS: it is the mix of the code, not
of the executed stream. It is a fair proxy here only because these functions
are 77% of the profile and are almost entirely loop bodies, so static and
dynamic mix should track. A dynamic count would settle it and has not been
taken.

IT ALSO PARTLY REVIVES qaq.7.23, which was priced at 1.1% of instructions and
reprioritised down. That measurement stands, and it is now in tension with 24%
stack traffic: if the partition were the binding constraint, widening it should
have bought far more than 1.1%. Either the constraint is elsewhere -- the
allocator's own choices rather than the size of the pool -- or the 1.1% was
measured on a total where the hot loops are a small share. Worth resolving
before either issue is acted on, and it is one dynamic measurement away.

### D47 second addendum -- the dynamic count corrects the static one

The addendum above read 24% of hot-loop instructions touching `%rsp` and
concluded the surplus is substantially spill traffic. It said a dynamic count
had not been taken and should be first. Taken:

    n=11              loads      stores    instructions
    gcc              6.097G      5.047G      11.129G
    sonic            9.850G      5.906G      27.161G       1.62x  1.17x  2.44x
    sonic unrolled   8.698G      5.320G      24.812G

MEMORY TRAFFIC GROWS LESS THAN INSTRUCTION COUNT, not more. Loads are 1.62x
gcc's and stores 1.17x, against 2.44x the instructions. If spill and reload
were the dominant surplus, memory would grow at least as fast as the
instruction count; it grows at two thirds the rate. So the excess is dominated
by NON-memory instructions -- register shuffling, compares, control -- and the
static `%rsp` share overstated the case.

That correction also relieves the tension the addendum raised with qaq.7.23. A
wider register partition buying only 1.1% is perfectly consistent with spill
traffic not being the main cost. The 1.1% stands and nothing about it needs
re-explaining.

STILL TRUE from the static read: no shifts in these loops, so the tagged
representation is not the cost; and the unroll moves memory and instructions
together (-12% loads, -10% stores, -9% cycles), which is what D46 predicts for
a transformation that removes a loop.

METHOD, since this is the second time in two entries: a static mix is a
statement about the code and a dynamic count is a statement about the
execution, and the two answer different questions. The static number was not
wrong -- a quarter of that code does touch the stack -- it simply does not
support the conclusion drawn from it. Take the dynamic count before drawing
one.

A caveat on the counters themselves: gcc's loads plus stores come to almost
exactly its instruction count, which cannot mean one memory op per
instruction, so `ls_dispatch` is not counting what its name suggests. Only the
RATIOS between the two binaries are used here, and those are sound because both
were measured the same way.

## D48 -- count-flips is 22.7% of fannkuch and does almost no work

Re-profiled after qaq.13, and the distribution is unchanged from before it:

    loop%2 (two copies)   30.0% + 24.5%
    count-flips           22.7%
    next                   8.9%
    copy-perm              5.0%

Removing 22.4% of the program's instructions moved the shape of the profile not
at all, which is D42 arriving from a third direction: the checks were absorbed
everywhere in proportion, so deleting them changed no function's share.

THE ANOMALY IS count-flips. Its entire body is

    (let ((k (vector-ref perm 0)))
      (if (fx= k 0) f (begin (flip-prefix k) (count-flips (fx+ f 1)))))

-- one load, one compare, an increment, a call and a tail call. It cannot be
22.7% of the program on throughput. It is 22.7% on LATENCY, and there are two
candidates sitting in plain sight.

The first is a store-to-load dependency the algorithm cannot avoid: `perm[0]`
is read immediately after the flip that just wrote it, so each iteration waits
on the previous iteration's store forwarding. Zen 5's forwarding is measured
elsewhere in this ledger at around 7 cycles when it fails to forward
(qaq.7.16); even when it succeeds it is not free.

The second is the call boundary. `flip-prefix` is inlined into count-flips by
rule 2', but the flip LOOP inside it stays a separate procedure -- rule 4
refuses to inline anything recursive -- so every flip pays a call and a return
between the store and the dependent load, and pays them inside the dependency
chain rather than beside it.

WHICH MATTERS IS NOT ESTABLISHED, and the distinction is the whole question:
the first is the algorithm's and nobody can remove it, while the second is
ours. gcc has the same data dependency and no call, so the difference between
8.28G and 10.88G may be largely this one boundary.

This is the first specific, testable account of D47's residual -- which is
known to be non-memory work at 1.50x, and which nothing else has localised. The
test is cheap and does not need the inliner changed: hand-write a fannkuch
variant whose flip loop is spliced into count-flips, compile it, and measure.
That is D43's technique and it settled the unroll question in one turn.

### D48 addendum -- answered: the call is 2.2%, the latency is the rest

D48 asked which of two things makes count-flips 22.7% of fannkuch: a
store-to-load dependency the algorithm owns, or the call boundary we own. Test
as filed -- hand-splice the unrolled flip body into count-flips so no call sits
between the flip's stores and the dependent load of perm[0]:

    n=11                        cycles    instructions   vs gcc
    gcc -O3 -march=native        8.259G      11.129G      1.000
    sonic today                 10.822G      27.161G      1.310
    + unroll (D43)               9.934G      24.812G      1.203
    + unroll, no call            9.713G      22.506G      1.176

THE CALL BOUNDARY IS WORTH 2.2% OF CYCLES. So the algorithm's dependency
dominates count-flips' 22.7%, and the part that is ours is a fifth of it at
most. Candidate one wins, which is the answer that closes a line of enquiry
rather than opening one.

Note the shape: removing the call took 9.3% of the instructions and 2.2% of the
cycles, while removing the back edge took 8.6% and 8.4%. Both are control flow
and D46 predicts both convert, but a call happens once per flip and a back edge
once per swap, so the back edge is the one that is in the way. D46 is refined
rather than contradicted: it is not "control flow converts" but "control flow
converts in proportion to how often it is executed", which is obvious in
retrospect and was not the reading before this measurement.

AND IT REVIVES qaq.7.21, which I measured at a ceiling of zero earlier in this
session and reprioritised to P3 on that basis. That measurement was correct for
the sources as they stand: rule 5 refuses nothing today. But the reason
`flip-prefix` stays a separate procedure in the unrolled variant IS rule 5 --
an unrolled body is a chain of nested ifs, so it has many tail positions and
the non-tail splice refuses it. So rule 5's ceiling is 0 before the unroll and
2.2% after it. The two are coupled and neither is worth building alone.

Total available from the two source-level transformations measured so far:
1.310x to 1.176x, of which the unroll is 10.7 points and the call 2.2.

## D49 -- the elision regression is a function of the copy budget, and peeling needs no trip count

Two things about qaq.23 that were wrong in the framing rather than in any
measurement.

FIRST, THE BLOCKER IS NOT "SPECIALISATION BREAKS ELISION". Measured after
qaq.25, with the pass enabled and only the growth budget varying:

    growth budget   1      2      3      4
    surviving       0      4     18     34
    functions      16     30     44     60

At budget 1 there is NO regression at all. The checks appear as the budget lets
copies run past what the program can execute -- copies at i = 11, 12, 13 into an
eleven-element vector, whose checks are correctly kept because if reached they
must trap. So the blocker is copies generated beyond the reachable range, and
it is governed by a knob that already exists.

SECOND, AND IT DISSOLVES THE ORDERING PROBLEM: PEELING NEEDS NO TRIP COUNT.
This issue has been stated as needing a proved bound, which lives in elide's
interval domain, which runs after the pass that would consume it -- an ordering
knot with no cheap answer. But peeling K iterations at the loop's ENTRY and
falling into the original loop at i = K is sound unconditionally, for any K,
with no bound required. The peeled copies have literal indices because they are
the first K iterations counted from entry; the residual handles everything
else. If K happens to exceed the real trip count the residual never runs, which
is D43's structure exactly, and if it does not the program is still correct.

A trip count is needed only to DELETE the residual loop. That is worth having
and it is not on the critical path.

WHAT THIS DOES NOT DELIVER, and the honest part: enabling the pass at budget 1
today is answer-preserving and check-free, and buys nothing measurable.

    n=11             cycles      instructions
    off             10.878G        27.161G
    budget 1        10.787G        26.939G      -0.84%, -0.8%
    budget 2        10.825G        26.981G

The 0.84% sits inside the roughly 1% run-to-run band measured repeatedly here,
so it is not a result. Budget 1 makes two copies of the cheap loops and never
reaches the reversal, which is where D43's 8.4% lives. The point is not that
this is shippable; it is that the path to the 8.4% is no longer blocked on an
unsolved ordering problem, only on peeling the right loop to the right depth.

## D50 -- the peel lands: fannkuch 1.318x -> 1.198x, and instructions went UP

specialize.ss is on. Three changes, each of which had to be true:

  1. `eligible?` requires ONE literal argument rather than all of them. The
     reversal is entered as `(loop 0 k)` -- i literal, j the runtime perm[0] --
     so under the old rule the pass never saw the loop that matters and spent
     its budget on the cheap ones.

  2. The copy keeps its non-literal parameters instead of being a thunk, and
     the call passes them. This is PEELING, and peeling needs no trip count:
     the copies are the first K iterations counted from entry, so their literal
     index is exactly right, and the residual loop still handles everything
     past K.

  3. repr.ss's "a procedure nothing calls gets raw-word parameters" step moved
     BEFORE the class fixpoint instead of after it. `called` comes from `sites`,
     which is complete before any propagation runs, so nothing about that step
     ever needed the fixpoint's results -- but running it afterwards meant a
     parameter defaulted there could never be the SOURCE of another parameter's
     class. Harmless while every procedure was called or a leaf; fatal once a
     pass introduces copies that call each other.

The third was the whole blocker and it took the longest to find, because every
input to the propagation was present and correct -- the copy in the table, the
site recorded, the argument classified raw-word -- and the propagation simply
did not run.

MEASURED, n=11, bit-exact 556355/51, zero surviving bounds checks:

    fannkuch    10.891G -> 9.877G cycles     -9.3%     1.318x -> 1.198x
                27.161G -> 27.616G instr     +1.7%
    nbody        188.08M -> 187.99M cycles   unchanged, bit-exact

INSTRUCTIONS WENT UP AND CYCLES WENT DOWN. That is D46 stated as a measurement
rather than a claim, and it is the second time this session the two moved in
opposite directions -- qaq.13 removed 22.4% of the instructions for nothing,
and this adds 1.7% for 9.3%. Anybody tuning this pass by instruction count will
tune it backwards.

THE BUDGET IS 1 AND THAT IS ALSO MEASURED. Larger budgets copy the loop past
the point the program can reach; those copies index out of range, their checks
are correctly kept, and both currencies get worse: 0 / 8 / 34 surviving checks
and 9.832G / 9.864G / 9.999G cycles at budgets 1 / 2 / 4.

WHAT IS STILL ON THE TABLE. The residual loop is still emitted -- deleting it
needs the trip count this issue was originally filed for, and D43's probe says
the fully-unrolled form reaches 1.196x with the call still in place and 1.176x
without it. So the remaining unroll work is worth about two more points, and
rule 5 (qaq.7.21) is worth 2.2 of them.

## D51 -- rule 5 built, and the 2.2% I predicted for it does not exist

inline.ss's rule 5 is implemented. A callee whose body has more than one tail
position is no longer refused at a non-tail call site; the continuation is
bound once as a join procedure and every tail position calls it:

    (letrec ([join (lambda (r) k)])
      (if a (tailcall join b) (tailcall join a)))

`k` appears once so nothing is duplicated, each arm ends in a tail call so
nothing grows the stack, and the join's parameter carries the result. 54 suites
green, both benchmarks bit-exact.

IT IS WORTH NOTHING, AND MY REASON FOR EXPECTING OTHERWISE WAS WRONG.
fannkuch's instruction count is identical to the digit -- 27,615,516,631
against 27,615,516,613, a difference of eighteen out of twenty-seven billion,
which is process startup -- and the cycles sit inside the run-to-run band.

D48's addendum claimed this rule's ceiling was 0 before the peel and 2.2%
after it, on the strength of a hand-spliced probe. The error is in what that
probe spliced. It removed the call between count-flips and a FULLY UNROLLED
flip-prefix -- a body with no loop in it at all, hence many tail positions,
hence rule 5's shape. The shipped peel does not produce that body. It peels
copies and leaves the residual loop, so the call that survives is to a
RECURSIVE loop, and recursion is refused by rule 4, which is a different rule
with a different and deliberate reason.

So the 2.2% belongs to a program the compiler does not emit. Rule 5 is not what
stands between us and it; rule 4 is, and rule 4's refusal of recursion is the
termination argument for the whole pass.

KEPT ANYWAY, on the qaq.26 test rather than the qaq.24 one: would this be worth
having if it never appeared in a measurement? Rule 5 is a documented capability
gap -- `(let ([r (f x)]) k)` where `f` ends in a conditional is a shape ordinary
Scheme produces constantly, and both benchmarks happen to avoid it. That is a
fact about two programs, not about the language. The qaq.24 compare-swap was
reverted because it was justified ONLY by a performance number that evaporated;
this is justified by the gap, and the number was a bonus I should not have
predicted.

THE LESSON, and it is the same one D48 taught in the other direction: a probe
measures the program you wrote, not the program the compiler will produce. D43's
unroll probe predicted the peel correctly because the compiler can produce that
shape. This one did not, because it cannot.

## D52 -- the collector is not lowered, and that is what limits the benchmark set

Filing the third-benchmark issue turned up a constraint worth stating on its
own, because it shapes more than that issue.

`gc.ss` is a precise generational copying collector, written in Scheme, and its
own header says what it is: "A later bead lowers it; what it lowers is these
steps, in this order, over this object layout." `(sonic gc)` is imported by
`elide.ss` alone, for tag widths. Nothing emits it. Compiled programs bump-
allocate and never collect.

Everything measured in this project so far is therefore allocation-free by
construction. nbody allocates three vectors at startup; fannkuch allocates
three; neither allocates in a loop. Both fit in L2 and both branch predictably.
Every ledger entry from D42 onward -- the exchange rate, control flow versus
work, the decomposition of fannkuch's residual -- is calibrated to programs of
that one shape, and D46 says so explicitly.

THE CONSEQUENCE FOR CHOOSING A THIRD BENCHMARK is sharper than it looks. The
Benchmarks Game entries that would break the shape are the allocation-heavy
ones: binary-trees is nothing but allocation and pointer chasing, k-nucleotide
is hash tables over a large input. Both are unavailable until the collector is
lowered. What remains available -- spectral-norm, mandelbrot -- is another
small-working-set FP kernel, which is a third data point on an axis that
already has two.

AND RESEARCH.md ALREADY SAYS THIS IS THE AXIS THAT MATTERS. Section 3 records
Stalin losing 5x to 16x to C on allocation-heavy code, with the cause being its
conservative Boehm collector rather than its analysis -- the argument this
project's whole GC design is built on. The compiler has never once been
measured on the workload its collector was designed for.

So the honest reading of the current standing -- fannkuch 1.198x, nbody 1.118x
-- is that it covers the half of the language that does not allocate. That is
not a small half, and it is not the whole one.

### D52 addendum -- verified, and it is a segfault rather than a limitation

The paragraph above was inferred from an import graph, which is not evidence.
Bead 6cm.5, "Precise generational copying collector", is CLOSED, so the
inference and the tracker disagreed and one of them had to be wrong. Measured
instead, with a loop consing one pair per iteration and keeping none:

    30,000 pairs      exit 0, correct answer      (~480 KB)
    60,000 pairs      exit 139, SIGSEGV           (~960 KB)
     3,000,000 pairs  exit 139, SIGSEGV

The inference was right and the consequence is worse than "the collector is not
lowered". A program that allocates past the nursery does not get a collection,
and does not get a diagnosis either -- it gets a segmentation fault. The usable
heap is under a megabyte.

What was closed as 6cm.5 is the MODEL. gc.ss says so in its own header. The
tracker cannot currently tell a reader that emitted programs are unable to
allocate, and that is worth more than a relabelling: it is the only
correctness-shaped defect in a tree otherwise entirely about speed.

Filed as a P1 with a minimum useful fix that is much smaller than the lowering:
make nursery exhaustion fail loudly. A program out of heap should say so and
exit non-zero, the way a failed bounds check does. That converts a segfault
into a diagnosis, which is the difference between "the compiler is broken" and
"this program needs more heap than this runtime has".


### D52 second addendum -- the 1 MB heap was a number, not a decision

Two changes followed from the segfault, and the second is nearly free.

The guards (qaq.31) turn exhaustion into exit 104 rather than SIGSEGV. That is
the honest minimum: the runtime says it is out of heap instead of the process
dying in a way that reads as a compiler bug.

Then the heap went from 1 MB to 256 MB, and the interesting part is that this
costs NOTHING. The heap is its own PT_LOAD with filesz 0 and a nonzero memsz --
it is .bss -- so the kernel zeroes it lazily and only touched pages become
resident. The emitted binary is 5,824 bytes at either size, byte for byte.

    before   1 MB     ~65,000 pairs      a loop consing anything hit the wall
    after    256 MB   ~16.7M pairs       3,000,000 pairs now completes correctly

1 MB was not a judgement anyone made against a cost; it was a number nobody had
had reason to revisit, in a runtime whose header says plainly "the allocator is
a bump pointer and nothing reclaims". The cost it was implicitly trading against
does not exist.

WHAT THIS DOES NOT CHANGE. Nothing reclaims, so a program whose live set is
bounded but whose allocation is not still fails -- just later, and with a
diagnosis. binary-trees at the sizes the Benchmarks Game uses allocates far past
256 MB, so qaq.30's conclusion stands: the allocation-heavy benchmarks need the
collector lowered, not a bigger nursery.

The constraint on going further is now stated in the source: the allocator
guards compare against base-plus-size using a signed 32-bit immediate, so the
heap has to stay under 2 GB until the encoder grows a 64-bit compare.


## D53 -- lowering the collector is smaller than it sounds, and one line is why

D52 says the collector is not lowered. Read rather than estimated, what is
actually missing is narrower than that phrasing suggests, and the narrowest
piece is the one nobody would guess.

ALREADY PRESENT. `gc.ss` models the whole collector in Scheme -- two
generations, bump allocation, Cheney scan, roots from stack maps -- and says in
its header that a later bead lowers exactly these steps. `gcmeta.ss` is the
stack-map format WITH an emitter and a decoder, wired into `object.ss`, so
`assemble-function` already produces a function object carrying its metadata.
`alloc.ss` has the allocation-check design including the reserved collection
worst case. And since qaq.31 the allocator stubs compare against the heap limit
and jump to a label.

So the model exists, the metadata format exists and is tested, and the trigger
point exists. Three of the four hard parts are done.

WHAT IS MISSING, AND THE FIRST ONE IS ONE LINE. driver.ss builds the executable
with

    (build-executable 'x86-64 (function-object-code o) pool ...)

-- the CODE of the function object, and nothing else. The metadata is computed,
sits on the same object, and is dropped one accessor away from where the
collector will need it. driver.ss does not mention metadata or gcmeta anywhere.

The other two are real work: emit the collector's steps as code, and turn the
allocator's `jmp sonic-heap-error` into a call and a retry, which is the
restart-region design 6cm.2 already closed.

WHY THIS ENTRY EXISTS RATHER THAN A BEAD ALONE. "The collector is not lowered"
sounds like a subsystem is absent. It is not. A model, a metadata format, an
emitter, a decoder, a check design and a trigger label are all present and
tested, and the executable simply never carries the roots. That is worth
recording because the phrasing in D52 would otherwise price the work an order
of magnitude too high -- and because the same shape recurs: this session found
the elision collapse to be one missing lattice case, the peel blocker to be one
misordered step, and the segfault to be one absent comparison.


### D53 addendum -- the maps are carried now, and one claim in D53 is unverified

The one-line piece is done: `build-executable` takes the metadata and places it
after the constant pool in the R+X segment, driver.ss passes
`(function-object-metadata o)` instead of dropping it, and a test reads it back
out of a compiled binary at the offset the layout gives and compares byte for
byte. The image grew by exactly the blob: 7,856 to 7,859. Nothing moved,
because the code is first and the pool is aligned after it.

WHAT I CANNOT YET SHOW, and D53 asserted more confidently than the evidence
supports. The blob is THREE BYTES on every program tried -- fannkuch, nbody, a
loop that conses, and a probe written to hold several tagged values live across
an allocation. Three bytes is a header and one entry.

There are two readings and this session could not separate them:

  - It is correct and expected. `gcmeta` drops an entry that says the same
    thing as its predecessor, D21 scavenges the value REGISTERS unconditionally
    so they need no bitmap at all, and none of these programs spills a TAGGED
    value to its frame. Under this reading the maps are right and small.
  - The frame bits are never populated, and the entries collapse because they
    are all empty rather than because they all agree.

The probe that would separate them needs more than four simultaneously live
tagged values, since that is how many value registers there are, and the one I
wrote fit in them. Writing that probe is the next step and it is small.

Until then, "the metadata format exists and is tested" is true of `object.ss`
and unproven of what codegen actually records. The carrying is done and is
worth having either way; the roots half of D21 is not established.


### D53 second addendum -- the maps are empty, and D53 was wrong about it

The previous addendum said the blob is three bytes on every program and offered
two readings: correct-and-small, or never-populated. Comparing SIZES could not
separate them, because a single entry with nonzero frame bits is also three
bytes. Comparing CONTENT settles it immediately.

    nine live tagged values across allocations   (0 0 0)
    a loop that conses                           (0 0 0)
    fannkuch                                     (0 0 0)
    nbody                                        (0 0 0)

Three zero bytes, everywhere. The emitter runs, `emit!` makes an entry per
instruction, and every entry carries flags of zero and frame bits of zero, so
gcmeta collapses them all into one empty record. The maps are not small; they
are blank.

SO D53 WAS WRONG WHERE IT MATTERED. It said the metadata format "exists and is
tested" and that only the carrying was missing. The FORMAT exists, the emitter
exists, the decoder exists and object.ss tests them -- and nothing in codegen
ever records a live tagged frame slot, so what they emit and decode is nothing.
Lowering the collector needs the roots to be computed, not merely delivered.

WHAT THAT ADDS TO qaq.32. Between "the model exists" and "a collection can run"
there is now a fourth item, and it is the one with real content: at every
safepoint, codegen has to state which frame slots hold tagged values. That is
liveness crossed with storage class at spill sites, which regalloc and finalize
know and currently never report. D21's argument -- PC-total metadata for the
stack, a static partition for the registers, therefore no shadow stack -- is a
design that is half built: the register half is real, and the stack half is a
format with no data in it.

THE METHOD NOTE, because it is the third time this session. I inferred from an
import graph that the collector was unlowered (right, but unverified until a
program segfaulted); I inferred from a size that the maps might be fine (wrong);
and both times the deciding measurement was one command against the artefact
rather than the source. Read the bytes, not the build.


## D54 -- the stack half of D21 now has data in it

D53 and its addenda tracked one claim through three corrections: the collector
is not lowered; the maps are carried but might be blank; the maps ARE blank.
This is the end of that thread.

`assemble-function` had accepted an option all along --

    (frame-bits . (<boolean> ...))   one per stack slot, set if it is tagged

-- and driver.ss passed `constants` and `extra-labels` and not that. The format
existed, the emitter existed, the decoder existed and object.ss tested all
three. They carried nothing because nobody handed them anything.

THE ONE REAL OBSTACLE was that `frame-bits` describes ONE frame while driver.ss
assembles the entire program as a single listing, so every procedure in it has
a different frame and a different spill set. The emitter's field is mutable, so
the bits now arrive as (instruction-index . bits) in order and the emitter is
re-pointed as emission crosses each boundary. Indices rather than labels because
`resolve-labels` has already consumed the labels by then, and the caller knows
the boundaries anyway -- it built the listing by appending one function's to the
next.

The bits themselves need nothing new computed. `finalized-spills` returns the
spilled vregs IN SLOT ORDER, which is the order `build-frame` numbers them in,
so a slot is tagged exactly when its vreg's class is.

    probe, nine tagged values live       (0 0 0)  ->  (0 0 0 192 10 0 18 255 255 1)
    fannkuch                             3 bytes  ->  35 bytes

Eighteen slots and a bitmap with most of them set, which is what a function
spilling eight pairs should say. 54 suites green, fannkuch bit-exact and
unchanged at 1.191x -- the metadata is data after the constant pool and no
address moves.

WHAT THIS IS AND IS NOT. It is the roots half of D21, which was a design with
one side unbuilt: the register side was always real, since the static partition
means the collector scavenges the value class unconditionally and needs no
bitmap, and the stack side was a format with zeros in it. It is NOT a collector.
Nothing reclaims yet; qaq.32 still wants the scan emitted and the allocator's
`jmp sonic-heap-error` turned into a call and a retry.

The test asserts a nonzero byte, not merely a present blob. Asserting presence
would have passed throughout the entire period the maps were blank -- which is
the same failure the size comparison made two entries ago, in a different
costume.

### D54 addendum -- a nonzero byte was still the wrong assertion

Decoding the blob rather than counting its bytes moves the claim again, and
this time in a direction worth keeping.

    fannkuch      8 entries, slot counts 0, 2, 0, 2, 0, 15 ... tagged 0 EVERYWHERE
    the probe     18 slots, 17 tagged

fannkuch's frame bits are all clear and that is CORRECT: it spills raw words and
doubles and never a pair, so it has no roots in its frames. The nonzero bytes
the previous test was satisfied by are offsets and slot counts, not roots. A
test written against either benchmark would have passed throughout the period
the maps were blank -- the third time in this thread that an assertion has been
weaker than it looked.

What fannkuch DOES demonstrate is the thing that was hardest to get right: its
slot counts differ between entries, which is the evidence that the bits are
re-pointed at each function boundary rather than set once for the listing. That
is now what the test asserts about it.

The root claim needs a program that spills a pair, and neither benchmark does,
so `bench/probe-tagged-spills.sps` is committed as a fixture -- nine tagged
values live across allocations against a four-register value class. It reports
17 tagged slots of 18, seventeen rather than eight because fixnums are tagged
too.

The general lesson, stated because it has now cost three corrections in one
thread: an assertion about a compiler artefact should fail on the artefact that
was wrong. "Nonzero", "present", "three bytes" all passed on blank maps.


## D55 -- the gate on the collector was imaginary; the encoder already had it

D53's last note said the runtime cannot find the maps, because labels in this
compiler appear only in control-flow operands, and offered three ways to fix it
with a recommendation to teach the encoder a RIP-relative `lea`.

The encoder already has RIP-relative addressing, and `lea` already takes it.

    ours   lea rax, 16(%rip)   (72 141 5 16 0 0 0)
    gas                        48 8d 05 10 00 00 00
    ours   lea r11, -8(%rip)   (76 141 29 248 255 255 255)
    gas                        4c 8d 1d f8 ff ff ff

Byte for byte, both. `rm-encoding` carries a whole comment on why `(mem 'rip
...)` is spelled as a distinct base rather than as base=#f, and every pooled
constant load in target-x86-64.ss is already written as
`(mem rip #f 1 (label ,(pool-label off)))` -- a label inside a displacement,
resolved by `resolve-labels` against the driver's `extra-labels`.

So the whole of what was missing was two lines: a `%gcmeta` label in that same
`extra-labels` list, at the offset where build-executable puts the blob, and a
`lea` plus a store in `_start`. Verified against the layout rather than against
itself -- the address the lea computes must equal `elf-load-base` plus
`metadata-offset-for`, and it does, 0x401800 both ways.

WHAT I GOT WRONG AND WHY IT MATTERS. I looked for `lea` and `label` in the same
grep, found labels only in `jmp`/`call`/`jle`, and concluded the capability was
absent. The capability was in a different file, expressed differently, with the
comment explaining it sitting directly above the code. Three options were
weighed and a recommendation made about work that was already done.

That is the fourth time in this thread that reading structure produced a wrong
answer a one-command experiment settled: the import graph, the blob size, the
nonzero byte, and now this. The pattern is specific enough to state as a rule --
when the question is "can the compiler express X", the cheap answer is to ask it
to emit X, not to search for where it might.


## D56 -- the maps were indexed by the wrong thing, and only one program showed it

D54 built the stack maps from `finalized-spills`, the spilled vregs in slot
order, on the reasoning that `build-frame` numbers slots walking that same list.
It does -- except when it shares one.

`build-frame` gives a vreg and its coalescing representative the SAME slot. So
the spill list is longer than the frame wherever coalescing happened:

    fannkuch  `next`            15 spilled vregs, 14 slots
    nbody     `outer%22.201`     4 spilled vregs,  3 slots
    the probe `main.entry1`     18 and 18          -- no sharing, so it agreed

A bitmap laid out per vreg is correct up to the first shared slot and shifted by
one for every slot after it. For a collector that is the worst available
failure: not a missed root, which loses an object, but a root read from the
wrong word, which follows whatever the neighbour happens to hold.

AND THE FIXTURE COULD NOT SEE IT. `bench/probe-tagged-spills.sps` was written to
force tagged spills, and it has no coalescing, so its 18 vregs land in 18 slots
and its map was right the whole time. Every assertion in D54 passed. What
exposed it was asking a different question -- does the spill list length equal
the frame's slot count -- of every function in every program, rather than
checking the fixture harder.

The fix is to build from `frame-layout-map`, the vreg-to-slot table, which is
the only structure that knows the answer. Sharing is between coalesced copies
and those have the same storage class, so the vregs at one slot agree; that is
now asserted rather than assumed, because a slot holding a tagged value on one
path and a raw one on another has no sound bit and picking either silently is
how a collector learns to follow an integer.

The regression test compares the widest map against the widest frame. It fails
on the old code, which is the only property a test of this kind needs.

THE PATTERN, since this is the fifth correction in one thread: every one has
come from checking the artefact against something INDEPENDENT of how it was
built. Nonzero bytes, present blobs, matching sizes and a passing fixture all
agreed with the bug. The slot count came from finalize and the map came from
the driver, and only comparing the two settled it.


## D57 -- the standing drifted 1% with the code byte-identical

Re-measured fannkuch at the end of a long session, nine samples per binary:

    gcc      min 8.239G   median 8.251G   max 8.276G
    sonic    min 9.945G   median 9.964G   max 9.977G     1.207x

Earlier the same day, with the same peel and the same everything that matters,
it measured 9.835G, 9.846G and 9.877G -- around 1.191x to 1.198x. The
instruction count across all of those readings is IDENTICAL to the digit
(27,615,516,6xx, the tens varying with process startup), so no code change
explains the difference.

WHAT CHANGED IS THE MACHINE, not the compiler. A single seven-sample run during
this check produced a max of 11.076G against a min of 9.936G -- an 11.5% spread
from one outlier -- while a nine-sample run minutes later held inside 0.3%. The
box is shared with the container doing the compiling, and a long session of it
leaves the part in a different state than a fresh one.

CONSEQUENCES, and they are practical rather than philosophical:

  - A 1% result measured hours apart from its baseline is not a result. Both
    arms have to be measured in the same run, on the same binaries, close
    together. `harness/measure-fannkuch.sh` does that and it is why its numbers
    have been the reliable ones all session.
  - A five-sample spread can miss an outlier entirely and report ±0.5% while
    the true range is 11%. Report the MIN alongside the median: it is the least
    contaminated estimator, and a min that moves is a real change while a
    median that moves might be the neighbours.
  - The standing figures in this ledger carry roughly a point of uncertainty
    against each other. 1.318x -> 1.198x from the peel is far outside that and
    stands; the difference between 1.191x and 1.207x is not a difference.

Recorded because several entries here turn on differences of a few percent, and
because the honest version of the current standing is "fannkuch is a little
over 1.2x" rather than any particular three-digit number.

---

## D58 -- podman needs a compose provider, and `/.dockerenv` was never the question we meant to ask

The host moved off WSL2 + Docker Desktop onto native Ubuntu with podman 5.7.0.
D30 survives intact: the limits still live in `docker-compose.yml`, they are
still 8g / 512 pids / 8 cpus, and there is still one way to run things. What
changed is the two things about podman that are not interchangeable with docker,
and one of them was silent.

**A compose provider is a separate install.** `podman compose` is a shim: it
shells out to `docker-compose` or `podman-compose` if one is on PATH, and
neither was. Installed podman-compose 1.6.0 user-level -- a venv at
`~/.local/opt/podman-compose` symlinked into `~/.local/bin`, driving system
`/usr/bin/podman`. No sudo. Homebrew has the formula and it was DECLINED: it
depends on the `podman` formula, so it would have installed a second podman
alongside the system one, and two podmans is the same shape of mistake as two
ways to run the tests. Only python came from brew, because Ubuntu's system
python ships no `ensurepip` and PEP 668 marks it externally-managed.

**`/.dockerenv` does not exist under podman, and six guards were built on it.**
Docker writes that file; podman writes `/run/.containerenv`. Every guard in this
tree tested the docker one to mean "am I contained", so on the new host they all
inverted at once: `make test-suite` REFUSED to run inside a perfectly good
container, `harness/configs.sh` took the host branch while inside one, and
`diff-run.sh`, `measure-fannkuch.sh` and `disasm-sonic.sh` would each have
re-exec'd into a container from within a container, without bound. The lesson is
narrower than "check both files": an engine's implementation detail was
load-bearing for a question about a property. `sonic_in_container` in
`tools/container.sh` now answers it in one place and both spellings. It stays a
FILE test rather than an environment variable we export, because a variable set
on the host would walk straight through the guard.

**The limits are now verified rather than declared, and that is the part worth
keeping.** D30 records being bitten by a limit key that parsed, validated and did
nothing (`deploy.resources.limits.memory`, ignored outside Swarm). The general
answer to a failure whose whole character is silence is to read the limit back
out of the kernel, so every container start now passes through
`--preflight-exec`, which reads `memory.max` and `pids.max` from the cgroup and
refuses to run if they are absent. Two file reads. Unverifiable counts as
absent, since "I could not check" and "it is not there" have the same blast
radius.

**And the guarantee is now TESTED, which in five months it never was.**
`tools/test-containment.sh`, wired to `make containment` and to CI, tries to
violate each property rather than asserting the config that ought to prevent it.
Measured on this host, all passing: a Python allocator touching every page was
SIGKILLed by the cgroup OOM killer (exit 137) while host swap moved **0 MiB**; a
loop spawning 2000 processes did not get there; a spinning process was killed by
the ENTRYPOINT's `timeout` and reported 124. That last one exists because this
image's `timeout` is uutils rather than GNU and the Dockerfile already documents
`--signal=KILL` being inert in it -- a guard that read as the stronger choice
and was no guard at all, found only when a miscompiled program wedged the suite.
Every argument in D30 was about which file the limits are declared in; nothing
ever checked the outcome. This does.

FOOTNOTE, recorded so nobody re-derives it: podman-compose does not implement
`memswap_limit`. `grep -c memswap` over `podman_compose.py` returns 0, and
`container_to_cpu_res_args` handles only `cpus`, `cpu_shares`, `mem_limit`,
`mem_reservation`, `pids_limit` and the `deploy.resources.limits.*` forms. There
is no `mem_swappiness` and no generic podman-arg passthrough, so the key cannot
be expressed at all. Consequence: a runaway gets 8g of RAM plus up to the host's
8g swapfile before the OOM killer fires, rather than dying at 8g total. On the
12 GiB WSL VM that comment was written for, 16g was the whole world; on a 122 GiB
workstation it is the difference between dying fast and dying slightly less
fast, and the containment test above measured the host swap cost of an actual
runaway at zero. Not worth a second mechanism. Noted, not fixed.

Two unrelated holes closed while consolidating. `harness/smoke-riscv.sh` guarded
its Chez compile with `command -v scheme`, so on a host without Chez it SKIPPED
the compile and exited GREEN -- `make smoke` reported a passing gate that had
never run, and CI never showed it because CI arrived already inside a container
where Chez exists. It re-execs like everything else now. And the old call sites
all passed `--entrypoint bash`, which discards the ENTRYPOINT along with it; the
wall-clock guard was absent from every harness path and is back. The container
also gets `network_mode: none`, which kills a `level=error` netns-teardown line
rootless podman emitted on every run -- noise that trains a reader to ignore
errors in CI logs -- and makes a compile that suddenly wants the network justify
itself.

PERF DOES NOT WORK ON THIS HOST AND NO CONTAINER FLAG FIXES IT, which took
three wrong answers to establish. `kernel.perf_event_paranoid` is 4 here where
the old host ran 2. Measured, all EACCES:

    seccomp default, rootless          EPERM   (seccomp denies the syscall)
    seccomp unconfined, rootless       EACCES  (the paranoid check denies it)
    + --cap-add=CAP_PERFMON, rootless  EACCES
    + --privileged, rootless           EACCES
    --sysctl kernel.perf_event_paranoid=2   REFUSED by podman

It denies ALL unprivileged perf, not just hardware events -- `task-clock` fails
identically. `perfmon_capable()` tests CAP_PERFMON against the INITIAL user
namespace and a rootless container's capabilities live in its own, so
`--privileged` is not a stronger `--cap-add` here, it is the same nothing. And
that sysctl is not namespaced, so there is no per-container form. This is kernel
design rather than a podman gap, and the flag surface is a dead end.

Two answers were written down here before the right one and both were wrong.
"Lower the sysctl" leaves unprivileged profiling on for every process on the
machine, permanently, to fix one benchmark script. "Run bench rootful" needs
sudo, and avoiding root is the reason for podman in the first place. Nathan
rejected both, and the second rejection is what forced the actual question:
counters were never the goal, INSTRUCTION COUNTS were. See D59, which gets them
without perf, without privilege and more accurately than perf ever did.

Still genuinely blocked: `perf record` SAMPLING in `harness/profile-sonic.sh`,
which answers "which function holds the cycles". callgrind emits per-address
costs and the label-mapping code in that script could consume them, but nobody
has written it. Wall-clock measurement and the test suite are unaffected
throughout.


---

## D59 -- the runtime required AVX-512 of every program, which cost portability and all instrumentation

`runtime.ss` set the three-lane predicate mask in the image prologue --
`mov rax, 7; kmovw k1, rax` -- unconditionally, for every binary this compiler
emits. The reasoning for doing it once per image rather than once per function
was sound and still is: nothing we emit writes a k register, we produce a static
binary and call no external code, so no ABI convention can take k1 away. What
was wrong is the "always".

`kmovw` is AVX-512. So a hello-world with no vector work anywhere in it came out
as a binary that faults on any machine without AVX-512. That is the x86
counterpart of precisely what the RISC-V smoke gate exists to catch -- depending
on something the target may not have -- and nothing was checking for it on the
target we actually run on.

IT ALSO COST US EVERY USERSPACE INSTRUMENTATION TOOL, which is how it was found.
With the host at `perf_event_paranoid=4` (D58) there are no hardware counters,
so instruction counts had to come from simulation instead. Both candidates died
in the prologue, before a single line of the program ran:

    valgrind/callgrind   I refs: 0, "vex amd64->IR: unhandled instruction
                         bytes: 0xC5 0xF8 0x92 0xC8"
    qemu-x86_64          uncaught target signal 4 (Illegal instruction)

Those bytes are the `kmovw`. Valgrind's VEX does not decode AVX-512 and QEMU's
TCG does not implement it, so one dead instruction made the entire class of
tooling unusable on our output. Removing it by hand and rebuilding fannkuch:
same answer (8629, 30), callgrind counted 199,436,247, qemu ran it correctly.

So the mask is now emitted only when the image contains a three-lane
instruction. `listing-uses-three-lane?` in `vec-x86-64.ss` answers that from the
finalized code; it is conservative by construction, saying yes for every
mnemonic in the table including the two shapes that are not actually predicated,
because a spurious mask costs two instructions once at entry while a missing one
is a wrong answer in a loop. Neither benchmark triggers it today -- nbody uses
the four-lane unmasked layout that D-era measurement preferred, and fannkuch has
no vector work at all -- so both now emit AVX-512-free binaries.

THE FLAG IS THREADED, NOT DEFAULTED TWICE, and that is the whole risk of this
change. `driver.ss` calls `runtime-listing` in two places: once to build the
image and once to COUNT its instructions, because that count is where the GC
frame maps start. A listing built with the mask and counted without it shifts
every map by two -- plausible addresses, all wrong, which is D56 exactly. So it
is computed once, in a `let`, and passed to both; `runtime-labels` forwards it
rather than defaulting again; and the default remains #t so any caller that
cannot answer the question gets a binary that runs everywhere the old ones did.
`vec-x86-64-test.ss` asserts both directions, that the two listings differ by
exactly two instructions, and that the default is the masked one.

The payoff is `harness/count-instructions.sh`, and it is a better instrument
than the one it replaces rather than a fallback. callgrind counts by simulation,
so the answer is DETERMINISTIC: fannkuch at n=9 returned 199,436,224 three runs
in a row, exactly. D57 records the standing drifting 1% with the code
byte-identical and a five-sample perf run reporting +-0.5% where the true range
was 11.5%; there is no spread here to report. What it does not measure is time
-- no cache or branch-predictor model -- so it answers "how much work" and never
"how fast", and wall clock still comes from `measure-fannkuch.sh`. First numbers
off it, fannkuch n=9: sonic 199,436,224 against gcc -O3 -march=native
75,208,916, a ratio of 2.65x in instructions retired.
---

## D60 -- perf is gone from the tree entirely, and the measurements got better

D58 established that perf cannot work rootless on this host and that no
container flag reaches it. D59 removed the AVX-512 instruction that was blocking
every simulator. This closes the loop: nothing in this tree opens a perf event
any more, and the three things perf used to do are each done by something with
no privilege requirement at all. Two of the three are now strictly better
measurements, which is not the outcome anyone expects from losing hardware
counters.

**Instruction counts** (`harness/count-instructions.sh`, and `measure.sh` which
was built entirely on them). callgrind counts by simulation, so the answer is
DETERMINISTIC: fannkuch at n=9 returned 199,436,224 three runs in a row,
exactly. `measure.sh` chose instructions in the first place *because* they are
deterministic, and this makes that exactly rather than nearly true; its `REPS`
knob now buys literally nothing and says so.

**The by-function profile** (`harness/profile-sonic.sh`). This is the one that
improved most, and the header of that script had already written the argument
for why. It described 7.2% of fannkuch's cycles landing on `flip-prefix`'s
PROLOGUE, reading as call overhead, and being branch-mispredict SKID -- the
sampled instruction pointer is not where the cost was incurred, and unpicking
that cost two wrong findings in one session. A simulator has no skid: cost is
attributed to the instruction that did the work. It is also exhaustive rather
than sampled, so a function that never caught a sample stops being invisible.
And `--branch-sim=yes` reports the mispredicts themselves, correctly attributed,
which is what that investigation actually wanted. First run on fannkuch n=9
immediately showed `loop%2.365.loop` at 12.2% of instructions but **29.5% of all
mispredicts** -- the kind of disproportion the old tool could only hint at.

What is genuinely lost is CYCLES. There is no pipeline model in callgrind, so a
divider chain and an add cost the same Ir. `measure-fannkuch.sh` therefore reads
wall clock instead, min-of-nine, which is what D57 already recommended for
independent reasons -- that argument never depended on which clock was read.
Cross-validation worth recording: the new wall-clock path puts fannkuch at
1.23x against gcc, and D57's standing from the perf era was "a little over
1.2x". Two unrelated instruments, same answer.

The profile output states in its own header that it is instructions and not
cycles, rather than leaving that to be discovered, because silently swapping the
metric under a script people already trust is how a wrong conclusion gets an
authoritative-looking table.

THE PARSER IS CROSS-CHECKED AGAINST CALLGRIND'S OWN ARITHMETIC. Reading that
format has two silent failure modes: positions use subposition compression
(`+n`/`-n`/`*` against the previous line) and decoding them as absolutes
attributes cost to invented addresses, while the cost line after `calls=` is a
call's INCLUSIVE cost and failing to skip it adds every callee to its caller
again. Both produce a plausible profile. So the parser sums each event and
compares against the file's `summary:` line, and refuses to print anything if
they disagree. Confirmed independently: its mispredict total for n=8 (229,284)
matches what cachegrind reports for the same binary.

Three pieces of scaffolding went with it. The `bench` compose service existed
solely to carry `seccomp:unconfined` for `perf_event_open`; nothing needs that
now, and a service kept for a tool nobody calls is a second way to run things
waiting for someone to pick it. `linux-perf` is out of the image for the same
reason -- shipping a binary that fails with a bare EPERM three layers from its
cause is worse than not shipping it. And `sonic_assert_perf` is gone.

Found while porting: **the documented knobs never crossed the container
boundary.** `N=11 REPS=9 harness/measure-fannkuch.sh` re-execs itself inside a
container, and neither `docker compose run` nor `podman compose run` forwards
the caller's environment, so the script read its own defaults and produced a run
that looked fine while ignoring what was asked for. `tools/container.sh` now
forwards an explicit list (`N REPS TOP NBODY`) -- explicit rather than
wholesale, so the container's environment stays a known quantity.

---

## D61 -- the container had quietly cut the oracle from 19 configurations to 9

Milestone 1's acceptance is "nbody compiles, runs, and passes all three oracle
checks", and check 2 is the eleven-way bit-exact cross-agreement that D24 calls
the strongest correctness evidence this project has. The argument for it is
specific: an unsound abstract domain deletes a check that was needed, and the
symptom is a value that is only SLIGHTLY wrong. Nothing else we run would catch
that; agreement across independent implementations of the same algorithm will.

Pinning the toolchain in a container (D30) silently reduced that check to the
nine configurations whose compilers happened to already be in the image --
`sonic`, two C builds and six Chez variants. `racket-1/2a/2b/4`, `sbcl-5`,
`ecl-9`, `clisp-9` and `ada-8-checked/named/all` could not run at all, because
racket, sbcl, ecl, clisp and gnat were never added to the Dockerfile. The SOURCES
were all still there in `bench/nbody`; only the compilers were missing, so
nothing looked broken. `harness/compile.sh` would have said `[FAIL]` for those
ten, and nothing was calling it.

That is the failure mode this whole container exercise keeps rediscovering: a
check that silently stops checking looks exactly like a check that passes. It is
the same shape as `deploy.resources.limits.memory` (D30), as
`timeout --signal=KILL` (the Dockerfile), as `command -v scheme` skipping the
smoke gate's compile and exiting green (D58), and as the harness knobs that never
crossed the container boundary (D60). Five instances now, all silent, all found
by going and looking rather than by anything failing.

All five toolchains are packaged in Ubuntu 25.10, so the fix was the Dockerfile
and nothing else. `gnat-15` is named EXPLICITLY rather than the `gnat`
metapackage, which pulls 14: `harness/configs.sh` calls `gnatmake-15` by version
on purpose, and unversioned `gnatmake` would build against whatever happened to
be installed -- exactly the drift the image exists to prevent. 15 also matches
the gcc the C configurations use.

Verified after the change: **19 of 19 configurations agree at nine decimals**,
-0.169075164 and -0.169087605 at N=1000. Every Scheme variant, ours included,
agrees bit-for-bit at 17 significant digits.

MILESTONE 1 IS MET, on all three checks and now on the whole matrix rather than
half of it. At the published N of 50,000,000 SonicScheme prints
-0.16907516382852447 and -0.16905990681396785 against METHOD.md's -0.169075164
and -0.169059907: exact at the nine decimals the oracle states. Energy drifts
1.5e-5 over fifty million steps and does not do so monotonically, which is the
conservation check. Run time 3.18s.

---

## D62 -- elemrange's escape walk read the extern list where it meant to read the program

Writing the first test elemrange.ss has ever had found a live soundness bug in
it, in the one direction the file's own header says matters.

`trackable-vectors` decides WHICH vectors may carry an element range. Its
soundness argument is entirely the escape rule: the fixpoint learns a range by
joining every `vector-set!` that names the vector, and that is a bound on the
contents only if there is no other way to write them. So a vector is tracked
only if EVERY occurrence of its name is the vector operand of `vector-ref`,
`vector-set!` or `vector-length`. The header is explicit about the stakes if
that fails -- "a wrong-answer bug of the worst kind: silent, and only on
programs whose vectors are shared".

The walk handled `top` and `letrec` in one case arm:

    ((top letrec)
     (for-each (lambda (b) (walk-value (binding-value b))) (cadr x))
     (walk-value (caddr x)))

`(letrec ([x e] ...) body)` keeps its body at `caddr`. `(top ([x e] ...)
(extern ...) body)` does NOT -- `caddr` is the EXTERN LIST and the body is at
`cadddr`. So the escape walk visited `(display)` and never the program. Every
escape occurring in the body -- which is where all the code is -- was invisible,
and the vector was tracked regardless.

Measured, the same allocation and the same escape moved between the two
positions:

    escape in the BODY            -> ((perm . 0))   tracked, escape missed
    the SAME escape in a BINDING  -> ()             correctly dropped
    (caddr top)                   -> (display)

Fixed by splitting the arm. The two forms do not have their body in the same
place and should never have shared a case.

WHAT IT COST TO FIX: nothing, which is worth recording because it was not the
expected answer. The fix makes the analysis strictly more conservative, so the
obvious risk was checks coming back and D42's fannkuch result regressing. It did
not happen: the suite is green, `nbody emits NO bounds check at all` and
`fannkuch-redux emits no bounds check either, once perm's contents are bounded`
both still pass, Milestone 2's assertion on the compiled inner loop still holds,
and the cross-agreement is unchanged. The vectors that actually carry element
ranges are local ones that never escaped; the bug was latent rather than active.

Latent is not harmless. It was one shared vector away from discharging a check
the program needed, and nothing in the tree would have caught it -- the answer
would simply have been slightly wrong, on a program nobody had written yet.

The general lesson is the one this month keeps producing, in a new place: five
passes in the shipping pipeline had no test file (cqs.19), and the first two
tests written against them found a stale acceptance criterion and this. Coverage
that looks complete -- 54 test files -- was not.

---

## D63 -- two instruction counters, and a measurement that cannot be quietly wrong

D60 replaced perf with callgrind because this host has no usable PMU. That was
right and it was not enough: callgrind cannot run four of the nineteen
configurations at all, and -- far worse -- it does not always say so.

**THE FAILURE MODE, WHICH IS THE POINT OF THIS ENTRY.** Three instruction
counts produced during one afternoon were confident, plausible, and wrong:

    117,666   callgrind on c-native. It prints "vex amd64->IR: unhandled
              instruction bytes: 0x62 ..." AND "I refs: 117,666" -- the total
              up to the failure. An earlier sweep of mine recorded that number
              as c-native's instruction count. It is not one.

    103,015   qemu on the same binary, summed up to "uncaught target signal 4
              (Illegal instruction)". `gcc -O3 -march=native` emits AVX-512 on
              this host; valgrind's VEX cannot decode it and QEMU's TCG does not
              implement it.

    115,154   qemu on clisp-9, which exits 0, prints the correct energies, and
              responds to N. Its qemu log is nevertheless byte-identical at
              N=50 and N=200 -- 34,578 lines, 22,542 traces -- because clisp
              re-executes itself and the child's log replaces the parent's. What
              was counted is a prologue.

Not one of them looked wrong. `measure.sh` printed a per-step of 0.00 for
c-native and nobody noticed, because a table of numbers with a zero in it reads
like a slow configuration rather than a broken instrument.

**WHAT CATCHES IT: THE COUNT MUST CHANGE WHEN THE WORK CHANGES.** A real count
varies with N; a crashed or truncated one does not. That single check found all
three, and nothing else did -- not exit status, not output correctness, not
plausibility.

So it is not a step anyone has to remember. `harness/count-slope.sh` asks for
instructions PER STEP, which cannot be computed from two equal counts, and
refuses instead of reporting zero. That is D30's argument about the container
limits -- a guarantee you have to remember to apply fails exactly when it
matters -- applied to a measurement rather than to memory.

**A SECOND COUNTER, AND WHY MIXING IS LABELLED.** `harness/qemu-count.sh` counts
by summing, over translated blocks, executions x instructions-in-block, from
`-d in_asm,exec,nochain`. `nochain` is load-bearing and its absence is silent:
QEMU chains blocks and then jumps between them without logging, and the first
version undercounted eight-fold (29,396 against callgrind's 243,031) while
looking entirely reasonable. Cross-validated against callgrind on binaries both
can run, the two converge as the run grows -- 0.9439 at N=200, 0.9965 at N=2000,
1.0071 at N=20000 -- because they account for process startup differently and
qemu counts a block entered but not completed as whole. They agree to under 1%
at scale and NOT exactly, which is why `measure.sh` now carries an instrument
column rather than presenting one number type.

**WHAT CAN BE COUNTED HERE, AS OF THIS ENTRY:**

    sonic, c-scalar, chez     callgrind
    sbcl-5                    qemu, validated by the two-N check
    racket-4, ecl-9           qemu answers a single count; the two-N check
                              cannot be run. Measured: neither completes a pair
                              at N=5 against N=20 inside 400 seconds per point,
                              because `nochain` disables translation-block
                              chaining and that is most of QEMU's speed. So
                              their counts are UNVALIDATED and must not be
                              quoted -- not because the numbers look wrong, but
                              because the one check that distinguishes a
                              measurement from a truncated log cannot be
                              afforded on them
    clisp-9                   NEITHER
    c-native                  NEITHER, and this one has consequences

c-native is Milestone 5's reference. Its instruction count is unobtainable on
this host by any instrument available, so a milestone worded around comparing
instructions against it cannot be satisfied as written -- that is bead qaq.10
and it is Nathan's to resolve. Milestone 3's instruction arm IS now obtainable:
sonic 664.13 instructions per step against sbcl-5's 2231.77, a factor of 3.36.

Recorded also because it is the fourth time this month a green-looking artifact
was measuring nothing -- after `deploy.resources.limits.memory`, `timeout
--signal=KILL`, and `command -v scheme` skipping the smoke gate's compile.

---

## D64 -- a virtual may never be spelled like a physical register, and compilation is idempotent

Two bugs with one cause, found by writing the first tests five pipeline passes
had ever had, and worth an entry because the rule they produce is not obvious
and the way they hid each other is instructive.

**THE COLLISION.** `fresh!` in `lower.ss` names quoted constants `k1`, `k2`,
`k3`, so the SEVENTH constant in a program came out `k7` -- which is an x86-64
opmask register. `mask-reg?` then classified that VIRTUAL as a mask register and
the encoder refused `movsd k7, [rip+%pool+8]`. Correct, and useless: the message
named neither the virtual nor the pass three stages upstream that made it, and
the program was an ordinary `flvector-set!` in a loop.

RV64 was armed the same way and worse. It has physical `t2`..`t6`, and `"t"` is
the most-used base in that file; nothing had reached the seventh `t` on that
target yet.

`fresh!` now SKIPS any name in the union of both targets' register sets.
Skipping rather than re-spelling, because every separator is already claimed and
both alternatives were tried and broke the suite: `.ddd` is essa's SSA suffix,
which `base-of` strips, so naming virtuals `k.7` made them look SSA-renamed and
miscompiled through it; `%` is the expander's, and a leading `%` is how the
runtime labels `%pool` and `%gcmeta` are written. The reserved set is built from
`regs.ss` rather than duplicated, so a register added there cannot drift out of
this check.

**THE ONE THAT HID IT.** `lower.ss`'s name counter was never reset, so a
compile's output depended on how many compiles preceded it in the process. The
same source CRASHED on compile #1 and SUCCEEDED on #2, because the second one's
names started wherever the first stopped and stepped over `k7`. It now resets,
and `run-x86-64-test.ss` asserts three compiles of one source produce
byte-identical images.

That test file already had a "same source compiles to the same bytes, twice
running" assertion, and it passed throughout -- because ITS program never reached
the collision. The new assertion uses the seven-constant program instead. An
idempotence check is only as good as whether its input can expose a difference.

**A MISATTRIBUTION WORTH RECORDING, because it cost two days.** Adding the
counter reset appeared to miscompile `(if #f 7 9)` to 7 against Chez's 9, and I
wrote that down as a SECOND, separate name-dependency to hunt before the reset
could land. It was not separate. It belonged to the abandoned `k.7` spelling
standing beside it at the time, and the reason that spelling was abandoned took
the miscompile with it. What settled it was dumping the emitted branch lowering
before and after the reset -- byte-for-byte the same `mov rbx,7 / cmp rbx,7 / je
L.else` -- rather than re-reasoning about the note I had written.

**THE GENERAL RULE.** Compiler-generated names and physical register names share
a namespace unless something makes them disjoint, and nothing did. The failure is
silent in the direction that matters: a name that happens not to collide today
collides the moment a program has one more constant, or a target gains a
register, or an unrelated pass shifts a counter.

---

## D65 -- 256-bit packing is reachable by padding and costs 60%, which is the argument for linearizing instead

`slp.ss` has carried a complete four-lane arm behind the `four-lane-packing?`
parameter since it was written, with a stated reason for being off: "until a
padded layout exists to point it at -- nbody stores bodies three-wide, so seeding
four adjacent stores finds nothing there." That layout has now been built and the
comment turns out to be half of the story.

**A PADDED LAYOUT ALONE DOES NOTHING.** `bench/nbody/config-sonic-pad4.sps` is
`config-sonic.sps` with a stride of 4 instead of 3 -- eight index expressions and
two allocations, with the body index in `(put! 3 ...)` left alone -- and its
energies are bit-identical, which is what says the layout moved and the
arithmetic did not. Four-lane packing on it: `ymm=0`, with the parameter on or
off. `store-at` seeds from four stores sharing a base AND an index vreg, and a
program that leaves slot 3 alone still emits three of them. Padding means not
writing it.

**WRITING THE PAD IS THE MISSING HALF.** With slot 3 stored -- `0 + dt*0` into a
slot nothing reads -- four-lane fires: `ymm=2`, `vmulpd` and `vaddpd` on ymm in
both halves of the unrolled position update. That is the first 256-bit packed
arithmetic this compiler has emitted into a binary.

**AND IT IS 1.60x SLOWER.** Measured at 40 reps, all three arms in one run:

    sonic         64.1756 ns/step  (baseline)
    sonic-pad4   102.787   ratio 1.6017  95% CI [1.5486, 1.6445]  real
    c-native      55.9111  ratio 0.8712  95% CI [0.7542, 0.9354]  real

**THE CONCLUSION IS NOT "256-BIT DOES NOT PAY HERE".** c-native is 256-bit and
1.15x faster than us. It is that THIS ROUTE to 256-bit adds work proportional to
what it saves: a quarter more stores and a third more memory traffic to buy two
packed operations. Widening the packer by padding the data is the wrong trade on
this shape.

Which is the argument FOR `vectorize.ss`'s approach rather than against it. Its
linearization needs no padding and no extra stores: the union over i of
{3i, 3i+1, 3i+2} for i in [0,5) is exactly [0,15), so four consecutive elements
already exist in the three-wide layout, crossing body boundaries. Same 256-bit
packing, none of the traffic that just cost 60%. The open work is therefore
making that linearization produce ordinary `raw-f64` vregs the way `slp.ss`
produces pairs -- so the allocator needs no special case -- rather than wiring in
emitters that hand back listings with their registers already chosen (D63's
neighbour, bead 1mp.4).

Kept as a configuration rather than deleted, like `sonic-u4` before it, so the
negative result stays measurable instead of becoming folklore. Two routes to
four lanes have now been tried and measured; the third is the one nobody has
built.

FOUND BY THE SAME RUN, and recorded because it invalidates any wall-clock number
taken while a binary was missing: `bench.sh` timed a command that does not exist.
After `make clean` removed `build/`, it reported c-native at **-0.04985 ns/step**
with a bootstrap CI of [-0.0027, 0.0045] and marked it "real" -- a negative
per-step time, from timing "No such file or directory" twice. It preflights now.
Placing that check took three attempts because `$?` inside the `$( ... )` that
captures timing is a subshell, and so is `slopes`; only the main loop is not.

---

## D66 -- the four-lane gap is an IR LEVEL, not a missing analysis, and two attempts proved it the hard way

D65 measured the first route to 256-bit packing and found it 1.60x slower. This
records the second, which does not work at all, and the diagnosis both failures
share -- because the diagnosis is the useful part and neither attempt found it by
reasoning.

**ATTEMPT TWO: OFFSET-TABLE ADJACENCY.** `slp.ss`'s `store-at` decides four
stores are adjacent by requiring them to name the SAME index vreg, differing only
in a literal offset. Across bodies that never holds -- body i uses `bi`, body i+1
uses `bj` -- so I taught it to resolve each index through a table mapping
`dst -> (root . constant)`, the same computation `addrfold.ss` does, gated behind
`four-lane-packing?` so nothing shipping could change. Gate off: suite
bit-identical. Gate on: `ymm=0`. With the unroll budget raised as well: still
`ymm=0`, identical to gate-off.

It cannot work, and the reason is arithmetic. An offset table relates indices
computed as root PLUS A LITERAL. Within one body that resolves `bi+1` and `bi+2`
to root `bi`, which `store-at` already had by vreg identity, so it buys nothing.
Bridging bodies means relating `bi = 3i` to `bj = 3(i+1) = 3i+3`, which is
reasoning through a MULTIPLY. `addrfold` does not do it and neither did my table.
REVERTED rather than left in: a shipping pass carrying a gated path that never
fires is the dead-code shape this project keeps finding.

**THE DIAGNOSIS BOTH FAILURES SHARE.** `slp.ss` imports only `(chezscheme)` and
`(sonic order)`. It runs on Lmach, AFTER lowering, where `3i` is a `mul` and every
connection to the loop's induction variable is gone. At that level there is
nothing left that says two index vregs are affine in one counter. Padding
sidesteps the problem by paying for a fourth store; an offset table cannot
recover it. **The gap is which facts survive to which IR level, not a missing
analysis.**

**AND THE FACTS DO EXIST, ONE LEVEL UP.** `vectorize.ss` imports `(sonic loops)`
and reads `iv-coeff` and `iv-offset` off an induction variable to build
`(base coeff offset)`. `loops.ss` exports the whole affine vocabulary --
`loop-ivs`, `iv-base`, `iv-coeff`, `iv-offset`, `iv-step`, `iv-span`,
`loop-iv-ref`. That is exactly what relating `3i` to `3i+3` requires, and it is
why that pass states its linearization as a FACT ABOUT THE LOOP rather than
searching for adjacency.

**AND THE TARGET IR EXISTS.** `lang.ss` has `p4add p4sub p4mul p4div p4splat`,
the `-c` contraction spellings, `p4fma`/`p4fnma`, and `p4load`/`p4store`;
`target-x86-64.ss` lowers all of them (`p4add` -> `v4addpd`, `p4mul` ->
`v4mulpd`). No pass emits one: the only producers today are `contract.ss` fusing
a pair and the selector table itself.

**SO THE REMAINING WORK IS AN EMISSION TARGET.** vectorize.ss has the premises,
Lmach has the operations, the selector has the rules, and the allocator already
handles packed values as ordinary `raw-f64` vregs because that is how pairs work.
What is missing is that `vec-x86-64.ss` and `vec-rv64.ss` hand back a LISTING with
physical registers already chosen -- unwireable for the reason bead 1mp.4 records
-- instead of vectorize.ss emitting Lmach `p4` ops. Keep those emitters: they
carry the RVV length-agnostic path D22 wants, and nothing in an Lmach route
serves RV64 until Lmach grows length-agnostic vector ops.

Three routes, and the state of each: padded layout WORKS and costs 1.60x;
offset-table adjacency DOES NOT FIRE; Lmach emission from vectorize.ss is
UNATTEMPTED and is the only one that pays for the width in neither stores nor
traffic. c-native is 256-bit and 1.15x faster than us, so the width is still
worth having.

---

## D67 -- correcting D66: the facts cannot reach the operations, because the names do not survive lowering

D66 concluded that the remaining four-lane work was "an emission target, not an
analysis" -- vectorize.ss has the affine premises, Lmach has the `p4` operations,
so the gap is that the emitters hand back listings. That is incomplete, and the
missing piece invalidates the plan rather than adding to it.

**THE KERNEL IS REAL AND SMALL.** Extracted from nbody's elided IR, the licensed
loop `loop%35.220` yields a five-vop kernel over 15 linearized elements with
coeff 3, arrays `(pos vel)`, index `i%36.222`, and `dt` as an invariant lane:

    (vload  0 (elt pos))    (vmul 3 2 1)    (vstore (elt pos) 4)
    (vload  1 (elt vel))    (vadd 4 0 3)

Every vop has a direct Lmach counterpart already declared in `lang.ss` and
already lowered by `target-x86-64.ss`: `p4load`, `p4splat`, `p4mul` -> `v4mulpd`,
`p4add` -> `v4addpd`, `p4store`. The translation is five lines of correspondence.

**BUT THE NAMES DO NOT SURVIVE.** Checked directly: of the kernel's names --
`t.189.230`, `t.190.231`, `t.191.232`, `t.192.233`, `i%36.222`, `dt` -- NOT ONE
appears anywhere in the finalized Lmach listings of the compiled program. repr,
lift, convert and lower rename everything between the level where the affine
facts exist and the level where the packed operations exist.

So there is no correspondence to emit against. A pass at Lmach holding a kernel
from SSA cannot say which vreg is lane 0.

**WHICH MEANS ONE OF THREE THINGS, none of them "just emit p4 ops":**

  (a) THREAD A CORRESPONDENCE through lowering, so each of repr/lift/convert/lower
      records what became what. Invasive, and it makes four passes carry a
      concern none of them has today.

  (b) MOVE THE OPERATIONS UP -- give the higher IR packed forms so vectorization
      happens where the induction variables are known, and let lowering carry
      them down. A language change, and lang.ss's `p4*` are Lmach mach-ops.

  (c) MOVE THE ANALYSIS DOWN -- give the Lmach packer enough induction-variable
      reasoning to recover adjacency itself, which is the affine route D66 set
      aside. `abcd.ss` already builds an inequality graph over induction
      variables at SSA level, so the question is whether its premises can be
      re-derived or carried to Lmach.

(c) is the architecturally coherent one: it puts the analysis where the operations
are, which is the property that makes `slp.ss` work at all -- its packed values
are ordinary `raw-f64` vregs precisely because it reasons in the same IR the
allocator sees.

**WHY THIS WAS NEVER DONE, finally.** vec-x86-64.ss and vec-rv64.ss emit listings
because they were fed HAND-WRITTEN FIXTURES, never real lowered IR -- their own
header says "nothing built a kernel from real IR, so the emitters had only
hand-written fixtures to consume". vectorize.ss then built the kernel and closed
that gap at SSA level. Nobody closed the second gap, from SSA names to Lmach
vregs, and it is the harder one.

Four routes to 256-bit now: padded layout WORKS at 1.60x slower (D65);
offset-table adjacency DOES NOT FIRE (D66); Lmach emission from an SSA kernel is
BLOCKED by name correspondence (here); affine analysis at Lmach is UNATTEMPTED
and is the coherent one. c-native is 256-bit and 1.15x faster, so the width is
still worth having.

## D68 — two instruction counters agree exactly on gcc's output and differ 6.17% on ours

`count-slope.sh`'s header claimed a callgrind figure and a qemu figure "agree to
within about 1% at scale". I wrote that sentence. Nobody had measured it, and it
is wrong.

Measured on identical binaries, by SLOPE between N=200 and N=400 so process
startup cancels and only loop body remains:

```
ref-scalar (gcc -O2)   callgrind 130781   qemu 130781   +0.0000%
sonic                  callgrind 132800   qemu 141000   +6.1747%   41 insns/step
```

Exact on gcc's output, 6% on ours. That asymmetry is the informative part: two
counters that agree to the instruction on one binary are not exhibiting
"instrument spread" on another, so one of them is specifically wrong about what
we emit.

**The obvious suspect is ruled out.** `qemu-count.sh` counts instructions per
basic block by feeding QEMU's logged `OBJD-T` bytes to `objdump -D -b binary`,
which has no boundary information — a block resynchronising differently there
than in the ELF would be miscounted on every execution, which is the right shape
for a fixed per-step offset. Checking it required going to the bytes, because
**our emitted ELF has no section headers at all** (`readelf`: "There are no
sections in this file", two LOAD program headers and nothing else), and
`objdump -d` disassembles only marked sections — so it returns zero instructions
and exits 0, which reads like an empty block rather than a tool that could not do
the job. Any inspection of our binaries needs `-D` with an explicit offset.

At the byte level, file offset = vaddr − 0x400000: for the ten hottest blocks,
QEMU's logged bytes are **identical** to the file's bytes. Same objdump, same
flags, a stream starting on a real instruction boundary. The block accounting is
sound, and the disagreement is in what the two tools count, not in how we parse.
Also excluded: uncounted blocks (the "no in_asm record" note fires on neither
binary), startup accounting (the slope cancels it), and retranslation
accumulation in the parser — that last was a genuine latent bug, `blocks[addr]`
appended across retranslations of one address instead of assigning; fixed as
hygiene, and the totals did not move, so it was not this.

**The consequence, and it is the part that matters.** qaq.10 exists because
callgrind cannot run racket, sbcl, ecl or clisp, so a milestone comparing sonic
against sbcl is a ratio between a callgrind number and a qemu number — carrying
an unbounded error, not a 1% one. But that framing was itself the mistake. The
fix is not to decide how much cross-instrument disagreement a milestone may
tolerate; it is to **force one instrument across both sides**, via
`SONIC_INSTRUMENT=qemu|callgrind`. Then whichever tool is right, both sides are
counted the same way and the RATIO is sound even where the absolute number is
still in question. Forcing an instrument that cannot run the program refuses
rather than falling back, because a fallback silently reintroduces the mix the
force exists to prevent.

**A second bug fell out, and it is the same shape as the counting bugs.** The
container's `working_dir` is `/work/sonic`, because that is where the suite runs,
but every caller — including `count-slope.sh`'s own documented usage example —
writes paths relative to the repo root. So `build/nbody/sonic` did not resolve,
and the refusal said *"no instrument could count this program"*: a path that was
never found, reported as a limitation of the instruments. It now resolves against
the repo root as well as the cwd, and a missing file gets a **different refusal
message** from an instrument declining. Third time this project has had a check
fail for a reason other than the one it named (D57's drift, D61's dropped
configs) — the pattern is that a diagnostic which cannot distinguish two causes
will be read as the more interesting one.

## D69 — the `vs-C` column was never vs C

`measure.sh` printed a ratio column headed `vs-C` and took its baseline from
whichever configuration was measured **first**:

```
base=""
...
[ -z "$base" ] && base="$per"
```

The default `CONFIGS` list begins with `sonic`. So every table this has ever
printed divided by sonic while claiming to divide by C. For a project whose
entire question is whether we beat C, that is the one column that must not lie.

What it looked like, and why it survived: sonic showed `1.00x` and c-scalar
`0.99x`, which reads as "we have drawn level with C". Corrected, with the
baseline actually being C:

```
sonic                664.00      1.02x    callgrind
c-scalar             654.00      1.00x    callgrind
```

We are at 1.02x C's instruction count, not level with it. The ratio was also
inverted relative to its own label — `0.99x` was `c-scalar/sonic`.

The baseline is now computed before the header is printed and the header is
built from it, so the label cannot drift from the arithmetic again: `BASELINE`
if set, else `c-scalar` when it is in the run, else the first config — the old
behaviour, now stated rather than implied. A baseline that fails to measure
prints `--` and a warning instead of silently falling back to the first
configuration that happened to work.

**A second bug fell out of the rewrite, and it is worth recording because the
mechanism is not obvious.** Buffering the per-config results to a file and
reading them back with `while IFS=$'\t' read -r c per ins why` loses empty
fields: **tab is IFS whitespace**, so `read` collapses runs of delimiters and
drops leading ones. A refused row written as `c-native\t\t\tmessage` came back
with the message sitting in the *per-step* field, which then tested non-empty
and was printed as though it were a measurement — the row rendered as a refusal
followed by a stray ratio column. The separator is now ASCII 0x1f, which is not
IFS whitespace, so empty fields survive.

That is the same failure shape as D68's path bug and D57's drift: the code did
something defensible, the output was wrong in a way that read as a different
problem entirely, and only an incoherent *number* — 0.93x against a baseline
that was supposedly itself — exposed it.

## D70 — the same baseline bug in `bench.sh`, where the confidence intervals live

D69 fixed `measure.sh`. `bench.sh` had it too, and worse: `BASELINE` was printed
in the header and **never used in the arithmetic**.

```
BASELINE=${BASELINE:-c-scalar}
...
printf 'slope of N=%s to N=%s, %s reps, baseline %s\n\n' ... "$BASELINE"
...
if [ -z "$base" ]; then base="$s"; ci="(baseline)"
```

`BASELINE` was a label. The divisor was whichever configuration measured first.
The default `CONFIGS` begins with `sonic` and `BASELINE` defaults to `c-scalar`,
so every wall-clock table — the headline numbers, with their bootstrap CIs —
divided by sonic while naming C.

**How it was caught**, and this is the useful part: `BASELINE=sbcl-5` produced

```
slope of N=1000000 to N=2000000, 40 reps, baseline sbcl-5
sonic               65.5925  (baseline)
sbcl-5              374.805  ratio 5.7142  95% CI [5.4236, 5.8631]  real
```

A row marked `(baseline)` that is not the row the header names. The ratio itself
was arithmetically fine — 5.71 really is sbcl/sonic — so nothing looked wrong
unless you read the two labels against each other. That is the same signature as
D69: defensible code, a number that is not false so much as *not the number the
column claims*, and only an internal inconsistency to give it away.

Corrected, `BASELINE=sbcl-5`:

```
sonic               96.1343  ratio 0.1715  95% CI [0.1654, 0.1821]  real
sbcl-5              560.399  (baseline)
```

A baseline that fails to measure now costs the ratio column and says so, rather
than falling back to another configuration — the fallback is what let the header
and the arithmetic disagree in the first place.

**The standing this exposes.** With the baseline actually being C:

```
sonic               98.2211  ratio 1.0507  95% CI [0.9926, 1.0979]  no detected difference
c-scalar            93.4793  (baseline)
```

Wall clock: statistically indistinguishable from scalar C, the interval
straddling 1.0. Instructions: 1.02x (D69). Those two agree, which is the first
time the two instruments have told a consistent story about where we actually
stand against C.

**Removed, not fixed:** the `[n rejected as parallel]` note. It read
`${REJECTED:-0}`, assigned inside `slopes()`, which is called as `$(slopes "$c")`
— a subshell, so it never reached the caller. Always 0, always empty. Filed as
qaq.12. That is the **fifth** subshell assignment to vanish in this harness
(measure.sh `COUNTER`, count-slope.sh `INSTRUMENT`, bench.sh `rc` and
`FAILED_WHY`, now `REJECTED`); in these scripts a value crossing a `$( )`
boundary travels in stdout, never in a variable.

## D71 — a rejection counter that could not be reported, and a threshold that could not be tested

D70 removed `bench.sh`'s `[n rejected as parallel]` note because it never
printed: `REJECTED` was assigned inside `slopes()`, which is called as
`$(slopes "$c")`, so the value lived and died in a subshell. This restores it
the way `count-slope.sh` already returns its instrument — **in stdout**. Two
lines: the count, then the samples, the samples staying on one line because
`bootstrap.awk` reads one configuration's samples per line.

It is not cosmetic. A sample is rejected when `cpu/elapsed` exceeds the
threshold, i.e. when something else was running on the box. **A median over 40
clean samples and a median over 2 survivors of 40 are different measurements**,
and the table could not previously tell you which one you were reading.

**The threshold is now injectable, and that is the more interesting half.**
`PARALLEL_MAX` defaults to the operating value of 1.3. It is a parameter because
a single-threaded nbody never reaches 1.3 — so the reject-and-report path could
not be exercised at all, which is precisely how the note that reports it stayed
broken without anyone noticing. A guard whose failure path cannot be reached is
not a guard; it is an assertion about the world that nothing checks.

Verified across all three regimes:

```
PARALLEL_MAX=0.80   sonic   refused: all 8 samples rejected as parallel
PARALLEL_MAX=0.86   sonic   94.9514  (baseline) [8/10 rejected as parallel]
PARALLEL_MAX=1.3    sonic   94.3208  (baseline)
```

Measured in passing, and worth knowing: this host's `cpu/elapsed` for a serial
nbody run sits between 0.80 and 0.90, not at 1.0. The gap is process startup and
I/O inside elapsed but outside CPU. The operating threshold of 1.3 therefore has
roughly 0.4 of headroom above the observed value rather than 0.3.

**Also measured, and a caution rather than a fix.** At `N1=200000 N2=400000` the
same configuration returned medians ranging from 63.2 to 99.3 ns/step across
repeated runs — a 35% swing with nothing changed. At the default
`N1=1000000 N2=2000000` it returns 62.9 stably. Small-N runs of this harness are
not trustworthy even though the slope cancels startup, so the defaults are
load-bearing and the `N1=... N2=...` knobs are for iteration, not for results.

## D72 — the 6.17% was our own counter, and gcc's output was the wrong place to validate it

D68 recorded that callgrind and `qemu-count.sh` agree to `+0.0000%` on gcc's
output and differ by 6.17% on ours, ruled out the block-decode suspect by
byte-comparison, and left it unexplained. It is explained, and the bug was ours.

**Localising it was the whole trick.** Two totals cannot say *where* they differ,
and every aggregate check had already come back clean. `harness/count-diff.sh`
(new) asks callgrind for `--dump-instr=yes`, expands QEMU's per-block accounting
to per-address, and diffs. On sonic at N=200:

```
addresses counted by both and agreeing : 954
addresses where they disagree          : 114
  qemu only (callgrind never saw them) : 114
  callgrind only (qemu never saw them) : 0
```

callgrind's address set was a strict **subset** of ours. That is the signature of
over-decoding — inventing instruction boundaries — not of two tools disagreeing
about what executed.

**The cause.** `objdump` wraps any instruction longer than 7 bytes onto a
continuation line, and that line carries an **address but no mnemonic**:

```
401a61:  48 8b 1c 25 68 00 60    mov    0x600068,%rbx
401a68:  00
```

One instruction, two lines, both matching `^\s+[0-9a-f]+:\t`. So every
instruction of 8 bytes or more was counted **twice, on every execution of its
block**. Requiring a mnemonic field — a second tab followed by non-space — fixes
it. After: 954 agree, 3 disagree, `+0.0022%`, and the slopes match to the
hundredth on both binaries:

```
sonic       callgrind 664.00   qemu 664.00
ref-scalar  callgrind 653.90   qemu 653.90
```

**Why it hid for so long, which is the part worth keeping.** We emit
absolute-addressed forms like `mov 0x600068,%rbx`; `gcc -O2` has none in its hot
blocks. The counter was cross-validated *against gcc's output* — and agreed
perfectly there, because gcc's binary does not contain the construct that
triggers the bug. **A cross-check run on a binary that does not exercise the
difference proves nothing**, and it is worse than no check, because it produces
documented confidence. The earlier claim that the two "converge to within 0.7% at
scale" came from exactly that validation and was cited on qaq.5 as grounds for
trusting a cross-instrument margin.

The general form, and it now has three instances in this ledger (D57's drift,
D61's dropped configs, this): **validate an instrument on the thing you intend to
measure, not on the thing that is convenient to measure.**

One consequence to note: the previously reported qemu figures were inflated in
proportion to how many long instructions a binary contains, which is not uniform
across configurations. Any qemu-sourced instruction number recorded before this
entry is wrong by an unknown amount and must be re-measured, not scaled.

**Re-measured under D72's correction**, single instrument, `N=1,000,000` to
`2,000,000`:

```
sonic       664.00 instructions/step     was 705.00    -5.8%
c-scalar    654.00                       was 654.00     0.0%
sbcl-5     1961.00                       was 2231.00   -12.1%
```

The inflation tracked how many long-instruction forms each binary contains, and
gcc's had none in its hot blocks — so the correction moved sbcl most and C not at
all. Milestone 3's instruction margin goes 3.4x → 3.16x → 2.95x across three
corrections, each removing an error rather than adding precision, and **every
correction worked against the claim**. M3 still passes on both arms; nothing
rested on the difference.

## D73 — four-lane packing on the stock layout emits nothing, and adjacency was never the shortage

D65 and D66 chased four ADJACENT elements — a padded layout that works and is
1.60x slower, an offset table that never fires. Both premises were wrong, and the
measurement that settles it is one flag:

```
sonic (stock, four-lane off)       xmm=484    ymm=0
sonic-v4-4  (four-lane, budget 4)  xmm=1012   ymm=0   results bit-identical
sonic-v4-16 (four-lane, budget 16) xmm=3027   ymm=0   results bit-identical
sonic-pad4  (padded layout)        xmm=455    ymm=18
```

Enabling `four-lane-packing?` over the stock benchmark emits **zero** 256-bit
instructions at any unroll budget. The xmm growth from 484 to 3027 is unrolling
alone. Results stay bit-identical, which is what a flag that changes no emitted
code must do.

**Adjacency is found already.** Instrumenting `slp.ss` shows four-lane packs
seeding on stock nbody — 7 at growth budget 4, 45 at budget 16 — because
unrolling folds body indices to literal offsets off a common base with `idx=#f`,
and `store-at` compares indices with `eq?`, so `#f` matches `#f`. They die later,
in `classify!`:

```
(cond ((adjacent-loads? ds) ... load)
      ((same-op? ds)        ... op)
      (else                 ... gather))
```

`same-op?` requires all four stored values to come from the *same* packable op.
The seeds sit on the velocity array in the force loop, where **Newton's third law
gives body i a `sub` and body j an `add` for the same pair**. Mixed ops, so the
pack is a `gather`, and `narrow!` refuses a four-wide gather because assembling
four scalars into a 256-bit register costs more than it saves. Both the
classification and the demotion are right given what they are handed.

So the fourth route — affine analysis at Lmach, the one left standing and called
"the architecturally coherent one" in D67 — **does not help either**. It exists to
prove more adjacency, and adjacency was never the shortage.

What the evidence actually leaves open on the stock layout: teaching
`classify!` and emission to treat a pack of MIXED add/sub as one operation — an
`addsubpd`-style form, or a negated-operand rewrite. That was never on the route
list. The alternative remains a layout change, which is route 1 and is measured
slower.

**Not added as a configuration**, deliberately, and the reasoning generalises:
`sonic-u4` and `sonic-pad4` are rows because each has distinct measured
behaviour. A `sonic-v4` row would be `sonic-u4` under a second name with a flag
that provably changes no emitted instruction — a duplicate measurement and one
more row on every benchmark run. Keeping a negative result measurable does not
mean keeping every negative result as a configuration; this one is two lines and
lives on the bead.

## D74 — two claims about what is measurable, both checked rather than assumed

**`vec-x86-64.ss` is partly live, and its header said otherwise.** The header
opened `NOTHING IN THE COMPILATION PIPELINE CALLS THIS`. That was true when
written and stopped being true with D59, which wired one predicate in without
updating it: `driver.ss:165` calls `listing-uses-three-lane?` on every compile to
decide whether the runtime prologue needs its `kmovw k1` setup. Changing that
predicate changes every emitted binary.

The emitters really are unwired — `driver.ss` does not import `(sonic vectorize)`
and never calls `vec-emit-loop*` — and `vectorize.ss` and `vec-rv64.ss` are
unwired outright, their headers accurate. Only this one file is mixed, and a
blanket "dead" label on it is the more dangerous error of the two: it invites
someone to change a shipping predicate believing nothing consumes it.

**Milestone 5's instruction arm is blocked for a sharper reason than "AVX-512".**
`c-native` is 570 instructions, of which 67 (11.8%) are EVEX-encoded. There are
**zero zmm registers and zero mask registers**, so searching for those finds
nothing and the binary reads as AVX2. What EVEX is buying is the upper sixteen
vector registers:

```
12df:  62 e1 ff 08 12 c1     vmovddup    %xmm1,%xmm16
1339:  62 c1 8d 08 59 c2     vmulpd      %xmm10,%xmm14,%xmm16
1650:  62 e1 ff 08 10 1d f6  vmovsd      0x29f6(%rip),%xmm19
```

`xmm16`–`xmm31` are addressable only through EVEX. These are 128-bit operations
using AVX-512VL purely for the extra registers, i.e. to cut spills.

Neither instrument can count it: valgrind 3.25.1's VEX decoder has no EVEX and
fails on `0x62 0xE1 0xFF 0x08 ...`; QEMU 10.1.0's TCG does not implement AVX-512
and takes SIGILL (rc=132). Note `qemu-x86_64 -cpu help` *does* list `avx512f` and
friends — that is the CPU model table, describing what a KVM guest could be told
it has, not what TCG emulates. Probing it is misleading and I nearly read it as
support. The binary runs fine natively; only counting is blocked, so M5's
wall-clock arm is unaffected.

And the obvious workaround fails on its own terms: `-mno-avx512f` would be
countable but is **not the same program**, because removing AVX-512 removes
`xmm16`–`xmm31` and therefore changes register allocation — which is precisely
what those 67 instructions exist to exploit. It would answer a question about a
different compilation.

## D75 — "tested on both targets" means the encoder, not the compiler

Checking whether Milestone 4 could be closed turned up a gap no bead tracked:
**there is no way to compile a Scheme program to RV64.** `driver.ss` exports two
entry points and neither takes a target —

```
(define (compile-sonic path externs))
(define (compile-sonic-to-file path externs out))
```

— and `'x86-64` is hardcoded inside them at every stage: `select-program`,
`finalize-program`, `runtime-listing`, `assemble-function`, `build-executable`,
`instruction-size`. The symbol `rv64` does not appear in `driver.ss` at all.

RV64 support is real and at a different level. `target-rv64.ss`, `regs.ss`,
`finalize.ss`, `object.ss` and `gcmeta.ss` all handle it; `rv64-test.ss` and the
RISC-V smoke gate exercise it, and the gate reads our own output back through
`riscv64-linux-gnu-objdump`, which is a genuine check. But it assembles a
**hand-written instruction body**:

```
(function-object-elf (assemble-function 'rv64 'sonic_nbody_inner body))
```

That drives the assembler directly. So RV64 is verified as an **encoder** and
never as a **compilation target**, and every claim of the form "tested on both
targets" means the back-end machinery is tested on both targets. This is not a
defect in the RV64 code, which looks sound — it is a gap between what the tests
establish and what the milestones read as. Filed as 1mp.6.

**Milestone 4's own acceptance criterion is worse.** It names "the E6-DISASM
packed-arithmetic assertion", and those assertions compile their fixtures *with
gcc* — `-O3 -march=x86-64-v4` and `riscv64-linux-gnu-gcc -O3 -march=rv64gcv`.
They validate `has-packed-arithmetic?`, the **analyser**, against a known-packed
and known-scalar control pair. They are green today and would remain green if
SonicScheme emitted nothing whatsoever. An acceptance criterion that passes
independently of the thing it accepts is the same shape as every other entry in
the failure catalogue — this time the *criterion* is the check that stopped
checking.

What is actually established on our own output: x86-64 carries packed arithmetic
in the compiled nbody inner loop, at 128 bits, asserted via `compiled-loop-of`
and passing. RV64 carries none, and cannot until 1mp.6 is addressed — separately
from that, `slp`'s packed ops have no RV64 lowering (`p2add`/`p2sub`/`p2mul`/
`p2div` are x86-64:1, rv64:0), so a driver target path alone would not suffice.

## D76 — the reason not to build an RV64 runtime expired when the container gained qemu

Sizing 1mp.6 found that most of an RV64 compilation path already exists:
`rv64-selector` is a full 588-line backend (`make-selector 'rv64 rv64-rules
arch-rv64`) with FMA rules, a call emitter, trap label and litpool, and
`finalize.ss`, `object.ss` and `regs.ss` all handle the target. Three things are
missing, and **both code-level gaps refuse loudly rather than silently**, which
is why none of it was a live hazard:

- `runtime.ss:858` — no RV64 entry listing (argv, output, exit; the syscall ABI)
- `elfexec.ss` — `build-executable/meta` refuses non-x86-64, and `e_machine` is
  hardcoded `EM_X86_64` (`0x3e`) where RV64 needs `EM_RISCV` (`0xf3`)
- `driver.ss` — takes no target argument, so neither refusal is even reachable

**The stated reason for not writing the runtime has expired.** It read: *"an RV64
one written blind would be validated by nothing."* True when written. The
container now has **qemu-riscv64 10.1.0** — verified end to end, cross-gcc builds
a static binary and qemu runs it — so an RV64 runtime can be validated exactly
the way the x86-64 one is: emit it, run it, compare energies against SPEC.md.
The same standard, not a weaker one.

The premise expired because the container gained qemu **for instruction
counting**, and nothing revisited a comment that depended on its absence. That is
the same shape as D74's header: a true statement falsified by an unrelated
change, with no mechanism to notice. Two in one session is enough to name the
pattern — **a justification that cites an absence needs re-checking whenever the
environment gains capability**, and neither of these had anything watching.

Both refusals corrected to say what is actually missing. They still refuse; they
no longer claim the work is unverifiable.

**Correction, same session.** This entry first called the remaining work
"bounded", having counted what EXISTS and inferred the rest was small without
measuring it. Measured: `x86-64-listing` is **689 lines, 289 emitted
instructions, 39 helper routines** — allocation (5 labels), boxing and tagging
(5), string conversion (7), integer division (3), the error trap, plus entry,
heap and gcmeta setup, the command-line walk and the exit path. Those helpers
are hand-written runtime, not compiler output, so an RV64 version must reproduce
behaviour rather than port encodings, against a different register convention,
different addressing modes and a different syscall ABI.

So it is a feature, not a tidy-up, and the "bounded" framing should not be used
to decide it. What does not change is the validation route: qemu-riscv64 makes it
checkable against SPEC.md exactly as x86-64 is. Estimating a remainder by sizing
the part already built is its own small lesson — the same error shape as
validating an instrument on the binary that cannot exercise it (D72).

## D77 — a Scheme program runs on RISC-V

D75 recorded that "tested on both targets" meant the back-end machinery, because
no Scheme program had ever been compiled to RV64. One can now:

```
0:  addi gp,zero,23         nil register = sonic-null
8:  addi t0,t0,1088 # 0x600440   heap-base-address
10: sd   t0,0(t2)   # 0x600000   heap-pointer-cell
18: sd   gp,16(t2)  # 0x600010   command-line = '()
1c: jal  ra,0x2c                 into the compiled function
28: ecall                        exit(0), a7=93
2c: addi sp,sp,-16               the compiled function's prologue
```

Four prerequisites had to land first, and **each was found by trying, not by
reading** — the sizing in D76 missed all but the first:

1. **`ecall` was absent from the encoder.** No syscall, so no exit and no output.
2. **`build-executable` refused non-x86-64**, and `e_machine` was hardcoded.
3. **The driver had no target argument**, so RV64 could not be requested at all.
4. **`slp.ss` packed unconditionally**, emitting `p2add`/`p2splat` that only
   x86-64 can lower — nbody died in selection until SLP was gated.

**The runtime is minimal and that is safe only because the gaps fail loudly.**
It establishes the nil register, heap pointer and an empty command line, calls
the entry point and exits. It provides none of the 39 helpers. Compiled code
calls those BY LABEL, so a program needing one fails at link time naming what it
wanted — `undefined label (%make-flvector)` for nbody. A partial runtime that
*linked* would be the dangerous version; one that refuses to link is merely
incomplete. Allocation is what pulls in `%gcmeta`, and allocation cannot link, so
the unpopulated cell is unreachable rather than wrong.

**Two bugs in my own work, both from defaults.** `listing-size` and
`label-offset` were given `'x86-64` defaults when the target was threaded
through; called without one on an RV64 listing they measured every instruction
with the x86 sizer, and the compile died in the x86 encoder with *"no encoding
for this mnemonic (addi)"* — a real RV64 mnemonic, reported by the wrong encoder,
which reads like a missing instruction rather than a missing argument. The
defaults are now errors. Separately, the runtime spelled its call target
`(label entry)`, which is the **x86** convention: `object.ss` rewrites that to
`(rel n)` for x86-64, while its RV64 arm looks for a bare SYMBOL in the last
operand of a branchy instruction. The x86 spelling reached the encoder intact
and was rejected as a bad displacement.

**Exit 0 is a weak claim and is not left alone.** The runtime exits `exit-ok`
unconditionally, so a program that never ran would also exit 0. Two things give
it teeth: corrupting the `jal` target makes the process die with SIGILL rather
than exiting quietly, and the paired assertion requires that a program needing a
helper *fails to link, naming it*. Together they show the pipeline discriminating
between what the runtime provides and what it does not.

The RV64 ladder now reads: bytes match binutils → objdump reads our output back →
the kernel runs our image → **the kernel runs our compiled program**. What
remains for a useful RV64 target is the helper set, and nbody names the first one
it wants.

## D78 — three acceptance criteria reworded, and the line that was not crossed

Nathan, 2026-08-18: *"make as many decisions on your own as possible since
creating this more performant scheme is all obvious optimizations and
capabilities we are adding."* That grants decision authority over acceptance
wording and route choice, which had been the standing blocker on six beads.

It does not grant authority to weaken a gate, and the distinction is the whole
content of this entry: **rewording a criterion to describe what is actually
verified is a decision; rewording it so a weaker check passes is weakening.**
Applied three times, and the three came out differently.

**E3 (`xei`) — reworded UP, closed.** The criterion named a hand-written Lcore
fixture. Measured, it cannot be written: nbody's whole-program Lcore is 2448
cons cells, its smallest whole lambda exceeds every existing fixture, and an
equality fixture pins the expander's gensym counter — `(i%7 x%8 y%5 z%6 …)` —
which any upstream pass shifts. `emit-nbody-test.ss` already learned this and
matches its loop BY PREFIX. What replaces it is strictly stronger: structural
assertions plus a bit-exact run against SPEC.md. An equality fixture proves one
shape; this proves the properties *and* the numbers.

**M5 (`qaq.7`) — instruction arm removed, milestone LEFT OPEN.** c-native is 570
instructions, 67 of them EVEX-encoded, with zero zmm and zero mask registers —
it reads as AVX2 until you look at prefix bytes. EVEX is buying `xmm16`–`xmm31`
to cut spills. valgrind 3.25.1 has no EVEX decoder; qemu 10.1.0's TCG takes
SIGILL. The tempting third option — add a `-mno-avx512f` row — was refused: it
would produce a number about a *different program*, since removing those
registers changes allocation, which is why they are used. **A measurable proxy
for an unmeasurable thing is worse than admitting the thing is unmeasurable,
because the proxy gets quoted.** M5 stays open at 1.14x behind.

**M4 (`qaq.6`) — SPLIT, x86-64 half closed.** Its criterion named the E6-DISASM
assertions, which compile their fixtures with **gcc** and validate
`has-packed-arithmetic?` — the analyser — against a control pair. They are green
and would remain green if SonicScheme emitted nothing. The criterion now points
at the Sonic-compiled assertion, which passes on the real binary. Two further
calls: packed means packed, and 128-bit xmm from `slp.ss` qualifies (reading it
as 256-bit would make M4 hostage to E5, which D73 showed is unreachable on the
stock layout); and RV64 is **split to qaq.13, not discarded**, because it needs a
packed lowering that does not exist on a target that cannot yet run nbody.
Closing one bead while quietly dropping half its scope is the dishonest version
of this, and splitting is what makes the reword survive scrutiny.

## D79 — the gap to Milestone 5 is fused multiply-add, not vectorization

LOOP.md has recorded, since D57, that "the whole remaining gap to Milestone 5 is
the vectorization gap — E5, not scalar tuning. Do not spend iterations shaving
scalar code to reach M5." That premise is measurably wrong, and it sent four
routes' worth of work at four-lane packing.

Counted from the emitted binaries:

```
sonic        scalar=161  packed=36  fma=0
ref-native   scalar=175  packed=25  fma=81
ref-scalar   scalar=62   packed=0   fma=0
```

**We already emit more packed arithmetic than `gcc -O3 -march=native` does** —
36 against 25 — and c-native uses no 256-bit at all: 748 `xmm`, zero `ymm`, zero
`zmm`. Its EVEX encodings buy `xmm16`–`xmm31` for spill relief, not width. So
the thing 1mp.5 has been trying to build is not the thing that is missing.

What c-native has and we had none of is **81 fused multiply-adds**.

**And the capability was already here.** `contract.ss` is written, wired into
`driver.ss` at `contract-program`, and carries 15 passing assertions. It emitted
nothing because D24 makes `fp-contract` a named, lexically-scoped permission
defaulting to OFF, and `bench/nbody/config-sonic.sps` never granted it — while
`gcc -O3` takes `-ffp-contract=fast` by default. **Milestone 5 has been comparing
a non-contracted build against a contracted one.**

This is the same shape as 1mp.4 and D75: a pass that is green in tests and
absent from the binary. The difference is that this one was absent by *policy*
rather than by not being called, which is why no test caught it — every test of
`contract.ss` grants the permission, because that is what the pass is for.

`sonic-fma` adds the permission around `advance!`, the inner loop. Emitted:

```
sonic        scalar=161  packed=36  fma=0
sonic-fma    scalar=134  packed=21  fma=42
```

**Correctness, and why this is allowed at all.** SPEC.md asks for energy to nine
decimal places, not bit-exactness. `sonic-fma`'s first energy is bit-identical
to stock and its second differs by 2 ULP — which is precisely the relationship
`c-native` (81 fma) has to `c-scalar` (0 fma), both of which publish
`-0.169087605`. A fused multiply-add rounds once where two instructions round
twice; that is what it is for. Anything tighter than the published oracle would
forbid the reference implementation from using its own default flags.

Added as a configuration beside `config-sonic.sps` rather than replacing it —
the sonic-u4 and sonic-pad4 precedent — so the standing number stays comparable
and the two can be measured in one run.

**MEASURED, 40 reps, slope N=1,000,000 to 2,000,000, baseline sonic:**

```
sonic               65.2011  (baseline)
sonic-fma           60.1649  ratio 0.9228  95% CI [0.8708, 0.9901]  real
c-native            57.1221  ratio 0.8761  95% CI [0.8302, 0.9249]  real
```

**7.7% faster, and the interval excludes 1.0.** Against `gcc -O3 -march=native`
the gap goes from **1.141x to 1.053x** — one permission, granted in one
procedure, closes more than half of it.

That is the entire content of the correction: four routes of vectorization work
were aimed at a gap that was never there, while the actual gap was a pass this
compiler already had, already tested, and was never allowed to run.

## D80 — SonicScheme permits contraction, as a configuration and not as a default

`harness/smoke-riscv.sh` has carried this since 2026-08-06:

> The oracle's nine decimals HIDE a real divergence. RISC-V gcc contracts to
> `fmadd.d` by default (one rounding, not two) while baseline x86-64 has no FMA
> to contract into, and vectorization reassociates the accumulation.
> Bit-exactness across ISAs holds ONLY with contraction and vectorization both
> off. See … **the open decision on whether SonicScheme permits contraction.**

D79 measured what that decision is worth: 7.7%, and more than half the gap to
`gcc -O3 -march=native`. This settles it.

**Both, and they are for different things.** The temptation is to read this as a
choice between a fast build and a correct one. It is not — it is two questions
that were being answered by one configuration.

- **`sonic`, contraction OFF, stays the default and the reference.** The 19-way
  bit-exact cross-agreement is the project's strongest correctness asset, and
  the smoke gate is explicit that it holds *only* with contraction off. A
  compiler whose output agrees to the bit with eighteen other implementations
  has proved something a nine-decimal match cannot. That is worth more than
  7.7%.
- **`sonic-fma`, contraction ON, is the performance configuration**, and it is
  what a comparison against `gcc -O3` should use, because gcc takes
  `-ffp-contract=fast` by default. Comparing our non-contracted build against
  its contracted one measured a policy difference and reported it as a
  performance gap.

**Milestone 5 therefore compares `sonic-fma` against `c-native`** — contracted
against contracted, like with like. Under the old asymmetric comparison the gap
read 1.141x; measured symmetrically it is **1.053x**. Nothing about the compiler
changed between those two numbers, which is precisely why the asymmetry was
worth finding.

**What this does NOT license.** Contraction is permitted *where the source asks
for it*, which is D24's mechanism working as designed — a named, lexically
scoped permission, default off. It is not a global flag and it is not on for the
reference build. Vectorization-driven reassociation, the other half of the smoke
gate's note, remains off and is a separate question: reassociation changes
results by a route no permission currently covers.

## D81 — nbody runs on RISC-V, bit-identical to x86-64

```
RISC-V energies:  -0.169075164  -0.169087605
SPEC.md:          -0.169075164  -0.169087605
```

and the raw output bytes are **bit-identical** to the x86-64 build's — the same
oracle the x86-64 target is held to, on the same 19-way cross-agreement standard.

D75 recorded that "tested on both targets" meant the back-end machinery, because
no Scheme program had ever been lowered to RV64. Closing that gap turned up
**ten** defects, each hidden behind the last, and nine of the ten share one root:
**an x86-64 assumption that does not survive a load/store target.**

| | |
|---|---|
| `ecall` absent from the encoder | no syscall, so no runtime at all |
| `build-executable` refused non-x86-64 | and hardcoded `e_machine` |
| driver had no target argument | RV64 could not be *requested* |
| `slp.ss` packed unconditionally | emitting ops only x86-64 can lower |
| `address-into` shifted a `#f` index | `#f` is how this tree spells "no index" |
| `r:const` waited for a linker | the static image applies no relocations |
| `frame-incoming-offset` | added a return-address word RV64 never pushes |
| `own-label?` | read `jal`'s destination register as its target |
| `jump-target` | same defect, one procedure away |
| `fold-reload` | matched only `mov`/`movsd`, so remat went via a scratch |

**The tenth is the ABI, and it is why the other nine could all be fixed and the
program still not run.** x86-64's `call` PUSHES the return address, so a callee
cannot destroy its caller's. RV64's `jal ra` writes a REGISTER — so any non-leaf
function overwrites its own return address, and `jalr zero ra 0` returns into its
own body just past the call. Measured: `outer%2.2` ran its prologue ONCE and its
epilogue TWICE, climbing a frame per pass until `[sp+0]` no longer named the slot
holding the loop bound.

Every earlier diagnosis chased that displaced load as "corruption". It was a
*correct* load from a stack pointer that had walked away.

Non-leaf RV64 functions now save `ra`, wrapped OUTSIDE the spill frame so no
existing displacement into it moves; only what a callee sees above it does, which
is why `frame-incoming-offset` accounts for the same word. Leaves pay nothing —
spending two instructions on every leaf would be a real cost on a target whose
convention is register-based.

**Three method notes, because they cost more than the bugs did.**

Three diagnoses on the last defect were wrong, and every one came from reading a
**filtered or partial artifact** — addresses without the listing, a `grep` of the
listing without its neighbouring lines, a PC histogram truncated by `head`. The
complete artifact was one command away each time and said something different.

The **guard** in `resolve-argcopy` refused three attempted fixes, each for a
different and correct reason, then validated the right one. It was the most
useful component in the subsystem, and reading what it *required* — one command —
pointed somewhere none of my guesses had.

And the arithmetic found what the reading could not: totalling every `sp`
adjustment over one run gave `-64 ×1, +64 ×2`, which names the bug outright.

## D82 — RISC-V gets fused multiply-add, which is where D79 said the gap was

The RV64 selector has emitted `fmadd.d` for as long as `contract.ss` has existed.
The **encoder did not know it**, so the first contracted RV64 build died with

```
no such rv64gc instruction (fmadd.d)
```

That is the same shape as the missing `ecall` (D77): a capability the compiler
believed it had, absent one level down, and invisible because nothing had ever
asked for it. `fp-contract` defaults off (D24) and no benchmark granted it until
D79.

The fused multiply-adds are **R4 format** — four register operands, with `rs3`
riding in the top five bits where every other format keeps `funct7`. That is why
they need their own encoder rather than a wider `funct` field, and why the field
order cannot be checked by reading: all four forms are now in the differential
listing, and **all 73 instructions encode byte-identically to binutils**.

The naming trap is worth recording because the manual invites it: RISC-V negates
the **product**, so `fnmadd.d` is `-(rs1*rs2) - rs3` and `fnmsub.d` is
`-(rs1*rs2) + rs3`. Getting that backwards is a sign error the oracle catches but
the mnemonic does not suggest.

Emitted, on `config-sonic-fma.sps`:

```
57 fmul.d   39 fmadd.d   26 fsub.d   19 fadd.d   18 fnmsub.d   17 fdiv.d   1 fnmadd.d
```

58 fused multiply-adds, and the energies are `-0.169075164 / -0.169087605` — the
published values. That the *negated* forms give correct answers is the check on
the sign convention above.

So both targets now reach the capability D79 identified as the whole remaining
gap to `gcc -O3 -march=native`, and on RISC-V it arrived by adding one
instruction format the encoder was missing rather than by writing a pass.

## D83 — RISC-V becomes measurable: argv, and the first cross-ISA figure

```
nbody-rv64   1386.00 instructions/step   qemu
sonic         664.00                     callgrind
sonic-fma     596.00                     callgrind
```

**RV64 needs 2.09x the instructions of x86-64** for the same program, computing
bit-identical answers at every N. That is the expected shape for a load/store ISA
whose addressing costs three instructions where x86 needs zero, with SLP gated
off because its packed operations have no RV64 lowering.

Getting there took two things, and the second was found by a guard.

**The instrument had to learn RISC-V.** `qemu-count.sh` picks emulator and
disassembler from the binary's own `e_machine` byte now, and handles two log
formats detected PER BLOCK — Ubuntu's qemu has a RISC-V disassembler linked and
not an x86 one, so the same flag yields one line per instruction on one target
and raw `OBJD-T:` hex on the other. The RV64 form needs no objdump at all.

**Then the two-N protocol refused the result**, and was right: identical counts at
N=200 and N=400, because the RV64 runtime never walked argv. `command-line`
returned nil, so nbody took its default N=1000 whatever it was passed. The count
was a real count of a real run — always the same run. Exactly the failure D63
built the check for, catching a program that ran correctly and was unmeasurable.

Walking argv needed `%rv-cons` and `%rv-cstr->string`, and those needed `lbu` and
`sb`, which the encoder did not have — the third instance this session of a
missing RV64 instruction (after `ecall` and the fused multiply-adds), and the
coverage guard again refused to let them go unverified. All 77 instructions
encode byte-identically to binutils.

It also brought a branch back to life. `cadr` and `string->number` TRAPPED, on the
honest grounds that an unreachable routine and one quietly returning garbage look
identical until the branch is taken. Walking argv took the branch, and the
program exited 101 — the trap doing precisely its job, which is why it was
written as a trap and not a stub.

**One bug in my own work, worth recording for its shape.** `string->number` read
its byte count at `+7`, the CDR offset, where a string's length sits at `-9`.
Both are valid displacements from a tagged pointer, so nothing faulted: the
program parsed a different number and silently simulated the wrong step count.
The named constant `heap-length-disp` exists for exactly this and is now used.
Caught only because explicit `N=1000` disagreed with the default, which is also
1000 — a comparison that costs nothing and should be the first check on any
argument-parsing path.

**With the target measurable, the FMA question could finally be asked of it:**

```
              instructions/step    with fp-contract
  rv64             1386.00              1291.00      -6.9%
  x86-64            664.00               596.00     -10.2%
```

Both targets gain, and x86-64 gains more. That asymmetry is not noise: on x86-64
a fused multiply-add replaces two PACKED operations, each doing two lanes, while
on RV64 it replaces two scalar ones — SLP is gated off there for want of a packed
lowering (qaq.13). So the contraction win compounds with packing on one target
and not the other, which is a concrete reason to want qaq.13 beyond milestone
completeness.

The ratio between targets is 2.09x uncontracted and 2.17x contracted.

## D84 — strength reduction is a wrong-code bug here, and the tree already knew

Profiling the nbody inner loop turned up four `imul rX, rY, 3` doing body-index
arithmetic. Multiplying by 3 is `lea dst, [src + src*2]` — one cycle instead of
three, same instruction count. I wrote the peephole, confirmed a clean 1:1
rewrite (`imul: 0  lea: 6  total: 83`), and the suite fell from 8572 checks to
1301 with four failures.

The failures were not stale pins. `target-x86-64.ss` documents the exact hazard
in its header, about `lea` for `add`:

> It does not set flags. An overflow `chk` reads the flags the preceding
> arithmetic left, so selecting `lea` here would silently make every overflow
> check downstream test stale flags.

`imul` sets OF/CF; `lea` sets nothing. Any overflow check after a strength-reduced
multiply reads whatever flags some earlier instruction left. That is a silent
wrong-code bug, and the four peephole tests caught it by pinning the `imul` form.
Reverted.

**Worth recording: the disassembly says the hot-loop multiplies are unchecked** —
no `jo` follows any of the 22 `imul`s in the binary. So the rewrite would have
been safe *there*. Proving it in general needs EFLAGS liveness the compiler does
not have, and the same analysis would unlock `add` → `lea` too. Measured payoff
for that: 6 collapsible `mov`+`add` pairs out of 56 adds, in a 1525-instruction
binary. Not the 5.3% M5 gap. Filed, not built.

**The instrument that was missing.** Two empirical M5 leads died against the same
wall: instruction counts are flat, so the gap is latency and port pressure, and
callgrind models no pipeline. perf cannot work rootless here (D60) and no flag
fixes it. But a pipeline model does not have to be a hardware counter —
`llvm-mca` is a static one. It reads assembly, needs no PMU, no privileges and no
sysctl, and reports latency, port occupancy and the critical path through a loop
body. Added to the image (LLVM 20.1.8), resolved and verified at build time so a
missing analyser fails the build instead of producing an empty report. Being
static it is deterministic, the same property that made callgrind the better
instrument in D60.

## D85 — the counters, by way of a second kernel; and M5 was misdiagnosed

D60 measured correctly and concluded wrongly. On the host kernel perf is
unusable and no flag reaches it — `kernel.perf_event_paranoid` is 4, and
CAP_PERFMON is tested against the INITIAL user namespace, so a rootless
container cannot hold it however it is started. From that I concluded the
hardware-counter route was closed for good. It does not follow.
`perf_event_paranoid` is a property of **a** kernel, not of this machine.

Boot a second kernel under KVM and you are root in *its* init namespace, where
the sysctl is yours to set. `/dev/kvm` carries an ACL granting the invoking user
rw, and `kvm.enable_pmu` is `Y`, so the guest's counters are the real hardware
counters underneath. Nothing on the host changes: no sudo, no group, no sysctl.

`harness/vm-perf.sh` is the entry point. virtme-ng boots THIS CONTAINER'S
filesystem as the guest root, so there is no second image to drift out of sync —
the guest is the container. Four things a minimal image lacks had to be added,
and each failed as `Attempted to kill init` rather than by name: busybox and
zstd (the initramfs build), `ip` and `poweroff` (without the latter init RETURNS,
which *is* the panic), and `linux-perf` — the standalone perf build, versioned to
the kernel, and the very package a comment in the Dockerfile forbade by name.
That comment was right about the host and wrong about the guest.

**And the first thing it measured overturned the diagnosis.** nbody at N=5e6:

```
                 cycles    instructions    IPC     branches
sonic-fma   888,081,464   2,981,677,267   3.36   300,284,364
ref-native  850,528,398   1,667,502,723   1.96    65,433,871
```

The cycle ratio is **1.0442**, which independently confirms the wall-clock
1.0414 from a different instrument entirely. But the rest says the gap is not
what D79 and every attempt since assumed. We execute **1.79x the instructions**
at **1.71x the IPC**. At 3.36 we are near the machine's issue width and are not
stalling — the extra work is already hidden behind superscalar width, and what
leaks through is the 4.4% that will not fit.

So M5 is an INSTRUCTION-COUNT problem wearing a latency problem's clothes, and
two sessions of scheduling-flavoured guesses (D84's strength reduction, the
`lea` liveness idea) were aimed at the wrong thing. The signal to follow is
**300M branches against C's 65M** — 235 million extra, mispredicted at 0.02%, so
cheap and perfectly predicted and still occupying issue slots. That is the shape
of bounds and type checks, and it is the same diagnosis fannkuch already carries
(2.51x instructions, 1.24x time), which two benchmarks now agree on.

**One defect found in the instrument itself, which is why it is worth recording:**
`compose run` does not carry the caller's environment, so `EVENTS=... vm-perf.sh`
arrived unset and perf measured its DEFAULT list while printing a perfectly
well-formed report. It is forwarded explicitly now. An instrument that quietly
answers a different question than the one put to it is exactly the failure this
harness exists to prevent.

## D86 — the standing, in one place, and what we have never measured

Scattered across a session's worth of tool output is not saved. The numbers
below are the current measured standing; anything not here was not measured.

**nbody** — slope N=1e6 to 2e6, 40 reps, bootstrap CI, baseline `c-native`:

```
config      ns/step   ratio vs c-native            verdict
c-native      57.66   (baseline)
sonic-fma     60.05   1.0414  [0.9645, 1.1062]     no detected difference
c-scalar      62.70   1.0874  [0.9953, 1.1649]     no detected difference
sonic         63.25   1.0969  [1.0217, 1.1721]     real
```

`sonic-fma`'s interval spans 1.0: against `gcc -O3 -march=native` it is a
statistical TIE, not a loss and not a win. Plain `sonic` is genuinely behind.
`sonic-fma` also sits ahead of plain `gcc -O3` on the point estimate, with the
same caveat that the intervals overlap.

**fannkuch** — n=11, answers checked against the oracle before timing:

```
c-native   2734.3 ms min   2758.0 median
sonic      3391.6 ms min   3409.2 median     1.24x
c-native   10,992,262,566 instructions
sonic      27,615,514,456 instructions       2.51x
```

2.51x the instructions for 1.24x the time — the same instruction-count story
D85's counters tell about nbody, arrived at independently.

**RISC-V** — nbody compiles, runs, and answers bit-identically to x86-64 at every
N, at 2.09x the instruction count (D83). No RVV lowering exists (`qaq.13`).

**WHAT WE HAVE NEVER MEASURED, stated so nobody infers otherwise.** There is no
Rust in this project — no config, no binary, rustc is not in the container, and
not one number has ever been taken. "Tied with `gcc -O3 -march=native` on nbody"
invites "so we beat Rust", which does not follow from anything measured here.
rustc is an LLVM front end and on a tight float loop idiomatic Rust lands near C,
so a Rust column would probably be close on nbody and ahead of us on fannkuch —
but that is an inference from a proxy and belongs nowhere near a results table.
Adding the config is cheap if the question ever needs an answer rather than a
guess.

Likewise: two benchmarks are not a language comparison. nbody is float-heavy and
latency-shaped; fannkuch is integer and instruction-shaped. They disagree about
where our cost is by a factor of two, which is the whole reason both are measured
rather than one of them generalised.

## D87 — top-level bindings are reloaded from memory, so no loop bound is ever a constant

Chasing D85's 235M excess branches into the disassembly found something larger
underneath them. The nbody inner loop, per iteration:

```
cmp    %rcx,%rdi          the loop bound, in a REGISTER
mov    0x600068,%rbx      reload the `pos` vector pointer
movsd  0x600048,%xmm3     reload a float constant
mov    0x600050,%r8       reload another global
```

`(define n-bodies 5)` is a top-level constant and the loop is `(fx< i n-bodies)`,
yet the emitted compare is register-to-register rather than `cmp $5`. Every
top-level `define` is treated as a mutable global and re-read from memory at each
use — **43 such load sites in the binary**, three of them inside the innermost
loop body.

**The bindings are provably immutable.** There is not one `set!` anywhere in the
nbody source; only vector CONTENTS mutate, which is a different thing. A binding
never assigned can have its value propagated even when the object it points at is
mutated freely — the pointer is constant, the payload is not.

Two costs follow, and the second is the larger:

1. The loads themselves. Three per inner iteration is ~150M instructions at
   N=5e6, against a 2981M total.
2. **No trip count is ever known**, so nothing can unroll. gcc knows the pair
   loop runs ten times and flattens it; we cannot, because `n-bodies` is a
   memory read. That is where the 4.6x branch gap comes from, and it explains
   why the branch count is identical between `sonic` and `sonic-fma` (300.30M vs
   300.29M) — FMA fuses arithmetic and never touches control flow.

**And it settles a negative result that was previously ambiguous.** `sonic-u4`
(specialize-growth-budget 4) was recorded as "not faster, ratio 1.0023, CI
[0.8708, 1.1030], no detected difference" — an interval so wide it could not have
detected anything. The counters are deterministic and say it is plainly WORSE:

```
             cycles          instructions      branches
sonic       944,578,011     3,321,777,221    300,300,659
sonic-u4    962,629,114     3,421,829,230    320,310,242
sonic-fma   888,938,247     2,981,705,377    300,288,952
ref-native  850,331,012     1,667,515,815     65,436,003
```

More cycles, 3.0% more instructions, 6.7% MORE branches. Growing the specializer
budget without a known trip count duplicates work rather than removing control
flow. The lesson is not "unrolling does not help here" but "unrolling cannot
happen until the bound is a constant", which is D87's actual subject.

**Method note.** The first version of this measurement reported branches three
orders of magnitude too low. `awk /branches/` matched the COMMENT on the
branch-misses line — `# 0.02% of all branches` — so the column silently carried
branch-misses instead. Match the event field, never the annotated text. This is
the third instrument defect in two sessions (D72's IFS, D85's unforwarded EVENTS)
and they share one shape: a parser that finds something plausible rather than
nothing.

## D88 — the constants land, and buy nothing; the loop pays for a dead register

`gconst.ss` implements D87's stage one: a top-level binding never `set!` and
bound to a literal is substituted at every use. It works, and the emitted code
changed exactly as predicted.

```
                       before    after
listing (instructions)   1525     1468
global load sites          43       37
register compares          24        7
immediate compares         31       45
```

Seventeen loop bounds stopped being memory reads. The nbody inner loop now opens
`cmp $0x5,%rsi` where it used to compare two registers.

**And the dynamic counters did not move at all.**

```
             cycles          instructions      branches
before      944,578,011     3,321,777,221    300,300,659
after       969,318,190     3,321,837,373    300,311,324
```

Instructions up 60k in 3.3 billion; branches up 11k in 300 million. That is
noise on a deterministic counter — the hot path is doing the same work it did.
The 57 instructions the listing lost were all in cold code.

**Why: the constant is materialised AND folded, and the materialisation is dead.**

```
401c07  mov    %rdx,%rsi
401c0a  mov    $0x5,%rdi      <- defines rdi
401c11  cmp    $0x5,%rsi      <- the fold DID happen; the immediate is here
401c15  jl     0x401c20
401c1b  jmp    0x401ddf
401c20  imul   $0x3,%rcx,%rdi <- redefines rdi without reading it
```

The exit block is `mov %r15,%r9 / mov %r9,%rax / add $0x10,%rsp / ret` and never
reads `rdi`, so the definition at 401c0a is dead on both paths. One wasted
instruction per iteration, ~50M at N=5e6. It is not NEW waste — before this pass
the same register was loaded from the global instead. The pass swapped a load for
a materialisation and the compare got its immediate for free.

So the honest accounting: **stage one is a static win and a dynamic no-op.** The
hypothesis it was built on — that a constant trip count would unblock unrolling —
is REFUTED. `unroll-program` and `unroll-fully` both run, the bound is now a
literal, and the branch count is unchanged to five significant figures. Whatever
stops the pair loop from unrolling is not the trip count.

Two things fall out, both filed rather than guessed at:

- the dead materialisation survives a pass whose whole job is removing it
  (`qaq.18`). peephole.ss has a rule for exactly this shape — its own tests say
  "a constant used TWICE folds into both, and the mov still goes" — so the
  interesting question is which of its conditions this loop fails.
- unrolling does not fire on a loop with a literal bound (`qaq.19`). unroll.ss
  says it needs no trip count at all, which makes the non-firing more surprising
  rather than less.

**Keep the pass.** It is correct, it is tested (17 checks, the shadowing and
`set!` cases included), and it removes a real memory dependence from the loop
header even though nothing downstream has yet cashed it in. But record the
result honestly: the measurement predicted a win and there is not one, and the
next agent should not re-derive the same expectation from the same reasoning.

## D89 — removing 40% of the branches makes it slower, and D85's diagnosis was half wrong

D88 left two questions: does unrolling fire, and why does it not help. The first
has a flat answer — `unroll-program/report` on nbody says **10 loops unrolled**,
`inner%24` among them. It fires. Unrolling by two halves loop CONTROL, and gcc's
advantage is not that it unrolls by two but that it deletes the loop.

The driver already says what that needs: "substituting a loop body at a call with
literal arguments makes the guard foldable, folding the guard makes the NEXT
call's argument a literal, and the loop disappears when the guard turns." The
guard is `(fx< j n-bodies)`. While `n-bodies` was a memory read that guard could
**never** fold, so `unroll-fully` could duplicate bodies and never resolve one.
Every measurement of the specializer before D88 was taken in that state,
including D87's finding that `sonic-u4` is worse.

With gconst in place the guard folds, and the specializer sweep says:

```
              cycles        instructions    branches      IPC
sonic       948,296,157   3,321,801,412  300,304,844    3.503
budget 4    957,294,301   3,131,836,644  250,310,731    3.272
budget 8    966,380,855   2,856,821,960  180,308,647    2.956
budget 16   966,073,633   2,856,811,139  180,306,767      "
budget 32   965,554,693   2,856,813,538  180,307,356      "
ref-native  851,321,999   1,667,521,452   65,435,919    1.959
```

It saturates at 8 — three budgets agree to five significant figures, so this is
the specializer's fixed point and not a budget that wants raising.

**Instructions fall 14%. Branches fall 40%. Cycles rise monotonically.** IPC goes
3.50 -> 3.27 -> 2.96 across the sweep. Every instruction removed was one the
machine was issuing for free, and the code growth that removed them costs more in
issue density than the instructions were worth.

**This corrects D85.** That entry concluded M5 is "an instruction-count problem
wearing a latency problem's clothes", from 1.79x the instructions at 1.71x the
IPC. The first half does not survive: instruction count is now measured, not
inferred, to be the wrong lever. We removed 465M instructions and 120M branches
and got 18M cycles SLOWER. What D85 got right is the other half — at IPC 3.50 we
are near issue width and not stalling — and the correct reading of the pair is
that our surplus instructions are nearly free, so neither adding nor removing
them moves the clock much. The 4.4% is somewhere else.

D87's own framing needs the same correction. The 4.6x branch gap is real and is
NOT the cost it looked like: at 0.02% mispredict those branches were already
approximately free, which is exactly what removing 120M of them just proved.

**What is now ruled out, by measurement rather than argument:** unrolling further
(saturated, and harmful), specializer budget (three values identical), loop
control generally, and instruction count as a proxy for time on this benchmark.
`qaq.19` closes on this. `sonic-u4` should NOT become the default — it is slower
— but the D87 note calling it "definitively worse" needs this qualifier: it was
worse because the guard could not fold, and with gconst it is better on two of
three counters and still loses on the one that matters.

**The remaining instrument.** llvm-mca went into the image in D84 and has never
been pointed at anything. It models ports and the critical path statically, which
is the one question left standing: what resource is the hot loop actually waiting
on, given that it is neither stalling nor instruction-bound.

## D90 — the pipeline model, first use: it is the dependency chain and the scalar divider

D84 put llvm-mca in the image and nothing ever pointed it at anything. Fed
nbody's inner loop body (89 instructions, control flow stripped, `-mcpu=znver5`):

```
Block RThroughput:  28.0
Throughput Bottlenecks:
  Resource Pressure       [ 48.30% ]
  - Zn4FP1 [ 30.26% ]  Zn4FP0 [ 16.64% ]  Zn4FPSt [ 14.06% ]  Zn4FP45 [ 11.67% ]
  Data Dependencies:      [ 85.65% ]
  - Register Dependencies [ 85.65% ]
```

**85.65% register dependencies.** After D89 ruled out instruction count and
branches by measurement, this is what is left standing and it is measured rather
than argued: the loop is limited by the serial chain through the float math,
subtract -> multiply -> add -> add -> sqrt -> divide -> multiply.

The single worst instruction is unambiguous:

```
 1      13    5.00      vdivsd  %xmm5, %xmm0, %xmm3
```

Latency 13 and **reciprocal throughput 5.00** — the divider is occupied five
cycles per divide and will not pipeline tighter. Two of them per unrolled body is
ten cycles of the block's twenty-eight, so divider occupancy alone is a third of
the throughput ceiling. That is D37's conclusion arrived at independently by a
static model rather than by a microbenchmark, which is worth something.

**Where this diverges from D37, and it matters.** That entry rejected a
`fp-reciprocal` permission — rsqrt plus Newton — on the measurement that at 256
bits it costs 2.371 cycles a lane against the exact form's 2.042. It loses, and
that measurement stands. But it was taken PACKED at 256 bits, where the divider
already costs about two cycles a lane. Our hot loop does not run there: it emits
`vdivsd` and `sqrtsd`, SCALAR, at five cycles of occupancy each.

So D37's number does not settle the scalar case, and the interesting lever is not
the one it rejected. The same loop already emits **packed** `vsubpd` for the
coordinate differences and then narrows to scalar for the divide. Packing the
divides — two pairs' worth in one `vdivpd` — would halve divider occupancy
without approximating anything, and needs no new permission because it changes no
result. Approximation trades accuracy for a win D37 measured as absent; packing
trades nothing.

Filed as `qaq.20`. Recorded here because the reasoning has a trap in it: D37's
headline reads as "reciprocal approximation is worthless, stop looking at the
divider", and the correct reading is "worthless AT 256 BITS, where the divider is
already cheap". The hot loop is not at 256 bits.

## D91 — gcc does not pack its divides either, and M5 is 0.75 cycles per interaction

D90 proposed packing the scalar divides and filed `qaq.20`. Checking what the
reference actually does refuted it before a line was written:

```
ref-native (gcc -O3 -march=native)     sonic
  46 vmulsd                             84 vmulsd
  44 vsubsd                             40 vaddsd
  17 vdivsd                             20 vsubsd
  14 vsqrtsd                            15 vmulpd
   8 vmulpd                             14 vdivsd
   4 vsubpd                             12 vsubpd
                                         9 vaddpd
                                         8 sqrtsd
```

**Zero `vdivpd`. Zero `vsqrtpd`.** gcc wins with scalar divides and scalar
square roots. And the packing comparison runs the other way from the assumption
in D90: we emit 36 packed operations to its 12. LOOP.md already said we emit more
packed arithmetic than c-native and it is still true; D90 reasoned from "our
divide is scalar, so packing is the missing thing" without checking whether the
thing we are chasing does it. It does not. `qaq.20` closed unbuilt.

**The gap, stated in the only unit that has been useful.** nbody at N=5e6 is
5x10^7 pair-interactions:

```
sonic-fma    17.779 cycles per pair-interaction
ref-native   17.026
gap           0.752
```

Milestone 5 is three quarters of one cycle per interaction. Everything measured
so far is consistent with both programs computing the same physics down the same
irreducible dependency chain — a subtract, three multiply-adds, a square root at
latency ~14 and a divide at latency 13, about 27 cycles of pure latency per
interaction, achieved in 17 by overlapping independent pairs. Both of us are
doing that overlap well; gcc is doing it slightly better.

**What this rules out and what it leaves.** It rules out every structural idea
tried since D85 — instruction count (D89), branch count (D89), unrolling (D89),
specializer budget (D89), packing the divide (here). It leaves the chain itself,
where the only known lever is arithmetic that changes results: contraction, which
D80 already took and which bought the 7.7% that got us here, and reciprocal
approximation, which D37 measured as a LOSS at 256 bits and D90 correctly noted
was never measured scalar.

**An honest word about the milestone.** "Beat gcc -O3 -march=native" was framed
when the gap read 1.141x. It now reads 1.0414x with a confidence interval
spanning 1.0 — a statistical tie — and the remaining distance is 0.75 cycles on a
27-cycle chain. That is not a milestone that falls to another optimisation pass;
it wants either an arithmetic permission the project has so far declined on
accuracy grounds, or the acceptance that a tie against the reference C compiler
is the result. Both are Nathan's call, not a compiler's, and the measurement is
now good enough that the question can actually be put to him.

## D92 — the reciprocal question, answered on the axis that binds us

D37 rejected reciprocal approximation and D90 noted the rejection was measured
somewhere nbody's loop does not run. Two things were wrong with reusing it here,
and the second is the more interesting.

It ran **packed at 256 bits**, where the divider costs about two cycles a lane;
the loop emits scalar `vdivsd` at five (D90). And it measured **throughput**,
deliberately, with four independent chains — but llvm-mca puts the loop at 85.65%
register dependencies, so the deciding quantity is LATENCY. A form can lose on
throughput and win on latency; rsqrt+Newton, trading one long divider op for
several short multiplies, is exactly that shape.

`bench/micro/rsqrt-scalar.c`, scalar, both axes, on the guest counters:

```
exact  sqrt+div    LATENCY     41.364 cyc/op    exact
rsqrt+1 Newton     LATENCY     30.262           worst rel err 2.98e-07
rsqrt+2 Newton     LATENCY     40.727           worst rel err 4.43e-14
rsqrt+3 Newton     LATENCY     51.185           worst rel err 8.59e-16
exact  sqrt+div    THROUGHPUT  14.303
rsqrt+3 Newton     THROUGHPUT  13.404
```

D37's verdict survives for the form it tested — three Newton steps, which is what
you need to get within an ulp, is 24% SLOWER on latency and its throughput win is
7%. But the blanket reading of that entry is wrong: at **two** Newton steps the
approximation is 1.5% faster on latency (40.727 against 41.364) with a worst
relative error of 4.4e-14, and at one step it is **27% faster** for 3e-7.

So the honest shape of it is a curve, not a verdict:

- 1 step: 27% latency, error 3e-7. Too coarse for physics; nbody's own answer
  would move in the fourth significant figure.
- 2 steps: 1.5% latency, error 4.4e-14. Real but small, and it BREAKS BIT-EXACT
  cross-agreement — D24's oracle compares eleven implementations bit for bit, and
  4.4e-14 is not bit-exact by any reading.
- 3 steps: slower. Rejected, as D37 said.

**Caveat on transferring these numbers.** The latency figure comes from a fully
serial chain at 41 cycles an operation. nbody achieves 17.8 cycles per
pair-interaction by overlapping independent pairs, so only the part of the chain
that is actually critical would benefit — the 0.64 cycles two-step buys on a
serial chain is an upper bound on what it buys in situ, not a prediction.

**This is where M5 stops being a compiler question.** Every structural lever is
now closed by measurement: instruction count, branches, unrolling, specializer
budget (D89), packing the divide (D91), and reciprocal approximation at any step
count that preserves accuracy (here). The gap is 0.752 cycles per interaction and
what remains on the table is an accuracy trade the project has twice declined on
principle — D24 forbids reassociation outright, D80 admitted contraction only as
a scoped, default-off permission and only because it is bit-reproducible.

A 4.4e-14 error is a different kind of thing from contraction: it is not a
different rounding of the same computation, it is a different computation. That
is a decision about what SonicScheme promises, not about what is fast, so it goes
to Nathan rather than getting taken by a compiler in a loop.

## D93 — hoisting the globals buys one cycle in 3847; and fannkuch is the other benchmark

**Stage two of `qaq.17` refuted before it was written.** The plan was to hoist
loop-invariant pointer-valued global loads out of the hot loop, on the theory
that a five-cycle load at the head of each iteration sits on the dependency chain
that D90 says binds us. Simulated by deleting those three loads from the
extracted loop body and re-running the static model:

```
             Total Cycles   Block RThroughput   Register Deps
base              3847            28.0             85.65%
hoisted           3846            28.0             88.12%
```

One cycle in 3847. They are loop-invariant with constant addresses that hit L1
and issue early, so they were never ON the chain — they sit beside it. `qaq.17`
closes: stage one shipped (`gconst.ss`, D88), stage two is measured worthless.
That is three plans now killed by cheap pre-verification rather than by a wasted
implementation — D84's strength reduction by the test suite, `qaq.20` by
`objdump`, this by llvm-mca.

**And a harness defect worth its own paragraph.** fannkuch came back from the
guest with no counters and no error, which reads exactly like a failed run. The
cause: sonic's runtime writes RAW DOUBLES to stdout, that stream shares the
guest's virtio serial console with perf's report, and the raw bytes garble the
channel. `vm-perf.sh` now discards the workload's stdout — perf writes to stderr,
and this harness is asked for counters, never for the program's answer. Fourth
instrument defect in three sessions, and the same shape as the others: it did not
fail, it answered wrong.

**fannkuch, measured on the counters for the first time (n=11):**

```
              cycles         instructions      branches       misses    IPC
fk (sonic)  9,871,805,287  27,632,610,299  5,704,172,840  143,656,453  2.80
fkref (gcc) 8,461,136,855  11,144,811,729  2,211,433,606  170,978,195  1.32
```

**This benchmark is not nbody and must not be reasoned about as if it were.**
D89 established that nbody's surplus instructions are free — we removed 465M and
got slower. Here the arithmetic runs the other way: at our own IPC of 2.80,
gcc's 11.1B instructions would take 3.97B cycles against its actual 8.46B. We
are 1.167x behind on cycles while carrying 2.48x the instructions, so on THIS
benchmark instruction count is the lever, and D89's conclusion does not transfer.

Note also that gcc takes MORE branch misses than we do — 171M against 144M, a
7.7% rate against our 2.5%. fannkuch's branches are genuinely unpredictable
(permutation reversal), and we are not losing on prediction.

**What the instructions are.** The specializer is not the answer here either: at
budget 4 and 8 it ADDS instructions (27.6B -> 29.7B -> 30.1B) and cycles with
them, because fannkuch's trip counts are data-dependent and no guard folds. The
static listing says where to look instead — 1103 instructions, of which:

```
  register-to-register moves   130
  reloads from the stack        20
  spills to the stack           11
  check traps referenced         3
```

Checks are already elided; spill traffic is modest. But **130 reg-to-reg moves,
11.8% of the listing**, is a coalescing gap — the C reference has one stack spill
in the whole program. Filed as `qaq.21`, and it is the first optimisation in
several entries whose payoff is not ruled out in advance: fannkuch converts
instructions to time, and this is the largest identified block of instructions
that does no arithmetic.

## D94 — the instrument's noise floor, a stale binary, and a fix that was a no-op

Three findings, and the first two are about the instrument rather than the
compiler.

**The counters are not equally trustworthy.** Five runs of the same fannkuch
binary through the guest:

```
cycles        9,918,635,300  9,895,814,550  10,090,014,065  9,954,541,701  9,931,530,148
instructions 27,847,016,850 27,846,949,133 27,847,440,580 27,847,026,529 27,846,970,094
```

Instruction counts vary by **0.002%** — deterministic for practical purposes.
Cycles vary by **1.96% peak to peak**. So a single-run cycle comparison at the
one or two percent level says nothing, and several numbers in D89 and D93 were
read more precisely than they deserved. Instruction counts remain sound for A/B
work; cycle claims need repetition or a difference large enough to clear 2%.
(D89's specializer conclusion survives — it rests on a monotonic trend across
three budgets plus deterministic instruction and branch counts, not on the cycle
figures alone.)

**A stale binary, in the harness written to avoid exactly that.**
`harness/disasm-sonic.sh` carries a header explaining that it COMPILES rather
than accepting a binary, because analysing a stale artifact against a fresh map
"produces addresses that look plausible and are not, and it cost two wrong
findings in one session". `vm-perf.sh` takes a command line, so it cannot
compile, and the trap is open there. D93's fannkuch instruction figure
(27,632,610,299) came from a binary on disk that predated `gconst`, while the
listing it was reasoned about came from a fresh compile. The corrected figure is
**27,847,0xx,xxx**, which moves the ratio against gcc from 2.479 to 2.499 and
changes no conclusion — but the two numbers were never comparable and I read a
difference between them as an effect. A warning now sits at the top of
`vm-perf.sh`.

**And the fix under test did nothing.** `finalize.ss` runs the clobber analysis
only for functions with no pinned parameters, and a function has pins exactly
when it has parameters — so the analysis applied to almost nothing. That is real
and is now fixed: `allocate-program/precolored` takes `destroys-of` and threads
it to `allocate-program/clobbers` instead of the constant-#f `allocate-program`.

It changes not one byte of fannkuch. The listings before and after are identical
under `diff`. The counter in `count-flips.loop` is still spilled — `mov
%r13,0x8(%rsp)` then `addq $0x1,0x8(%rsp)` — across a call to a LEAF that writes
neither r13 nor any other register it needed.

So the pins boundary was not the binding constraint; something upstream is
already answering "assume everything" for this callee. The candidate the code
names is the recursive-cycle rule: in this compiler a loop IS a letrec-bound
self-tail-calling procedure, so if the cycle test is computed over the IR call
graph rather than the emitted control flow, every loop is a cycle and every call
into one is unanalysable. That is `qaq.22`.

**The change stays.** It is correct, the suite is green at 8589/0/59 including
the bit-exact oracle, and it removes a genuine gap that will matter the moment
the upstream conservatism is relaxed. But it bought nothing today and the ledger
should not imply otherwise.

## D95 — no register is ever saved, so "callee-saved" is a word the codegen does not implement

D94 guessed that the clobber analysis answers "assume everything" for calls into
loops, because a loop here is a self-tail-calling letrec procedure and the cycle
rule would then fire on all of them. **That guess was wrong.** Building the call
graph from the emitted listing:

```
count-flips        -> loop%2.14@8.373, loop%2.14@8.435
loop%2.14@8.373    -> (nothing)
NO CYCLES: the call graph is a DAG
```

A self-tail-call is emitted as a `jmp`, so it never appears as a call edge, and
`callee-first` orders the whole program without ever hitting its cycle fallback.
The analysis had the callee's real clobber set all along. `qaq.22` closes on a
refutation of its own premise.

**What is actually happening is register pressure, and it is structural.** The
raw pool is eight registers, `(rcx rdx rsi rdi r10 r11 r13 r14)`. Both callees
write `rcx rdx rsi rdi r10` — five of the eight — so exactly `r11 r13 r14`
survive a call, before the call site's own argument and return registers are
subtracted. At most three raw values can stay in registers across any call in
this program, and `count-flips` has more than three live, so its flip counter
lands on the stack and is incremented there.

**And the reason there is no relief is one grep:**

```
push/pop instructions in the fannkuch binary:  0
push/pop instructions in the nbody binary:     0
```

`callconv.ss` defines `callee-saved?`, `callconv-callee-saved`, and a header
explaining that our callee-saved set is deliberately a subset of the host ABI's
so values survive a foreign call. **Nothing in codegen ever acts on it.** No
prologue saves a register, no epilogue restores one, and therefore no register
survives a call by convention — only by the callee happening not to write it.

This is not incoherent. A whole-program clobber analysis is strictly more precise
than a save/restore convention: it costs nothing at leaves and tells the truth
about what each callee really touches. It is what this compiler has, and D94's
fix made it reach the functions that have parameters, which is nearly all of
them.

But precision has a floor that convention does not. A caller can only keep a
value in a register the callee does not write, so as clobber sets union up the
call graph the survivors thin out — and there is no way to say "this one is mine,
whatever you do", which is exactly what a saved register is for. The two
mechanisms are complements, and we have only one of them.

Filed as `qaq.23`: implement the declared convention. A function that wants a
callee-saved register saves it in its prologue and restores it in its epilogue,
paying two instructions per call to guarantee survivors that the analysis can
never produce. The cost lands on functions that USE such a register; the benefit
lands on every caller above them, and it is largest exactly where we are worst —
fannkuch, whose hot loop spills a loop counter across a leaf call.

## D96 — two mutually tail-calling loop halves rebuild an identical frame every iteration

Sizing `qaq.23` before building it meant asking whether the leaf callees really
need the seven registers they write. Reading one of them found something else
first. `loop%2.14@8.373`, the reversal loop, ends every iteration:

```
40168f  add    $0x10,%rsp
401693  jmp    0x4015ba        -> loop%2.372, whose first instruction is:
4015ba  sub    $0x10,%rsp
```

The two functions are halves of one loop, tail-calling each other, and each tears
down a sixteen-byte frame the other immediately rebuilds. Two instructions per
iteration, in blocks that are **18.5% of the sampled profile** between them
(`loop%2.372.loop` 11.40%, `loop%2.14@8.373.loop` 7.12%).

**It is not an oversight in the plan; the plan is right and unread.**
`tail-plan-reuses-frame?` is `(zero? (tail-plan-frame-delta p))`, and with no
outgoing stack arguments the delta here is zero — the planner says reuse.
`finalize.ss` suppresses the epilogue before a tail jump only when the target is
this function (`self-jump?`) or a label inside it (`own-label?`). A tail call to
a DIFFERENT function always emits the teardown, whatever the plan said.

**The shape is common, not incidental:**

```
fannkuch:  35 frame teardowns, 13 immediately followed by a tail jmp
nbody:     26 frame teardowns,  8 immediately followed by a tail jmp

fannkuch frame sizes:  14 functions at 0x10, 2 at 0x20, 1 at 0x80, 1 at 0x30
```

Fourteen of eighteen functions have the SAME frame size, so most of those thirteen
tail calls are between frame-compatible functions and could jump straight into
the callee's body.

**Why the mechanism is already available.** Functions are finalized callee-first
so a caller sees its callees' real clobber sets (D94/D95). The same ordering makes
the callee's FRAME SIZE known at the caller's emission time, by the same table
trick — no new analysis and no fixpoint. When the sizes match, the caller skips
its epilogue and retargets the jump past the callee's prologue, which the listing
shows already has its own label (`loop%2.372` is one instruction, then
`loop%2.372.loop`).

Filed as `qaq.24`. The guards it needs are the interesting part and are stated on
the bead: equal frame size, a prologue that does nothing but the `sub` (rv64
non-leaf functions also save `ra` there, D81), and no reliance on the callee's
spill slots being distinct from ours — they overlay, which is sound only because
we are leaving.

**A note on how this was found**, since it is the third time in this session.
The plan was to size `qaq.23`; the evidence answered a question nobody asked. Both
of the last two entries came from reading emitted code rather than reasoning about
what the passes should produce, and both overturned the hypothesis that sent me
there. D95 refuted D94's cycle theory the same way.

## D97 — the frame reuse lands: fannkuch loses 2.78% of its instructions

D96's optimisation, implemented. `finalize.ss` now carries a `frames` table
alongside `clobbers` — function name to `(frame-bytes . ra-bytes)` — populated by
the same callee-first ordering, so a caller can ask what its tail-call target's
frame looks like without a fixpoint or a second pass. When the sizes match and
neither end saves `ra`, the caller skips its epilogue and retargets the jump to
the callee's `.loop` label, past the prologue.

```
                                      before        after
fannkuch instructions            27,847,0xx,xxx  27,073,9xx,xxx   -2.78%
fannkuch listing (instructions)           1,103           1,097
teardowns immediately before a tail jmp      13               7
nbody instructions                3,321,7xx,xxx   3,321,796,162   unchanged
```

Cycles, measured with repetition because D94 put the noise floor at 2%:

```
before (5 runs)  9,895.8  9,918.6  9,931.5  9,954.5  10,090.0   mean 9,957.6M
after  (4 runs)  9,798.0  9,798.6  9,815.9   9,822.8             mean 9,808.8M
```

The ranges do not overlap, so the ~1.5% is real rather than a reading of noise —
and the post-change runs cluster inside 0.25%, which is worth noting on its own:
some of the earlier variance was the frame churn itself.

**This is the first change this session that moved a benchmark.** Everything
between D84 and D96 either refuted a plan before implementation (three times) or
landed correct and measured at zero (`gconst`, the clobber threading). Worth
stating plainly because the ledger otherwise reads as a run of failures, and it
was not: the refutations are what made this one findable. D96 exists because
sizing `qaq.23` meant reading emitted code, and reading emitted code is what has
worked all session.

**Two things it did not do, recorded so nobody assumes otherwise.** nbody is
unchanged — it has eight teardown-then-jmp sites and none of them are hot, which
is consistent with D89: nbody's spare instructions are free. And only six of
fannkuch's thirteen sites qualified. The others fail one of the guards — a
mismatched frame size, or a jump to something with no `frames` entry, such as a
runtime routine. Whether the remaining seven are reachable by relaxing a guard is
not investigated and should not be assumed.

**The guards, since they are the part that could be wrong.** Equal frame bytes;
`ra-bytes` zero at BOTH ends, because on rv64 a non-leaf saves `ra` outside the
spill frame and a tail call must restore it before jumping or the callee returns
into the wrong place — that is precisely where the epilogue is load-bearing. On
x86-64 `non-leaf?` is always false, so the guard is free there. Overlaying the
callee's spill slots on ours is sound only because we are leaving and nothing of
ours is read after the jump. Suite green at 8589/0/59, including the eleven-way
bit-exact oracle and the RISC-V smoke gate, which share this code.

## D98 — the same trick for unequal frames, and it is worth 0.15%

D97 required the two frames to be equal. That is not the real precondition:
`add F_caller` followed by the callee's `sub F_callee` is `rsp += F_caller -
F_callee`, so ANY pair collapses to one instruction and an equal pair to none.
All seven sites D97 left behind were frame mismatches, so generalising reaches
every one of them.

It needs a guard D97 did not. A tail call passing arguments on the STACK writes
them into this frame at offsets the callee reads back from its own rsp; moving
rsp between the write and the read shifts all of them. With equal frames rsp does
not move and the question never arises. So the delta form applies only when
`tail-outgoing` is zero, and the equal-frame case keeps its unconditional path.

**Measured, and small:**

```
                              D97           D98
fannkuch instructions   27,073.9M     27,033.9M     -0.148%
cycles (3 runs, mean)      9,808.8M      9,799.1M     within noise
static listing                1,097         1,097     unchanged
```

The listing does not shrink because the saving is dynamic rather than static: the
callee's `sub` still exists for its other entrants, and what disappears is one
execution of it per tail call. 0.15% against D97's 2.78%, which is the expected
shape — D97 caught the two halves of fannkuch's hot loop, and these seven sites
are outer loops that run orders of magnitude less often.

**The current fannkuch standing**, answers verified against the SPEC.md oracle
(556355 / 51, agreeing with gcc):

```
c-native   2744.306 ms min   10,992,263,036 instructions
sonic      3340.933 ms min   27,016,993,258 instructions
ratio           1.2174x                2.458x
```

D93 recorded 1.24x and 2.51x. The wall-clock gap is now **1.2174x**, about 1.9%
better than when this session started looking at fannkuch, all of it from D97 and
D98.

**Kept despite the size.** It is strictly better than D97's version, costs no
extra complexity — the same table, the same lookup, one arithmetic result instead
of a boolean — and it removes a special case rather than adding one. But 0.15% is
not a result to build on, and the ledger should not let a later reader infer that
frame handling has more left in it. The remaining fannkuch gap is 2.46x the
instructions of C, and D93's census says the largest identified block doing no
arithmetic is still the 130 register-to-register moves (`qaq.21`).

## D99 — a latent wrong-code bug in constant folding, found by an optimisation that was then reverted

D93's census said fannkuch's largest block of instructions doing no arithmetic is
its 130 register-to-register moves. Characterising them found a specific shape:
**21 sites materialise a constant into one register and copy it to another**,

```
mov  rdi, 1
mov  rcx, rdi        <-- `mov rcx, 1` is the whole instruction
```

concentrated in blocks that are ~31% of the sampled profile. `peephole.ss`
already folds constants into arithmetic uses; `foldable-use?` simply requires the
consumer to be `imul` or one of `(add sub and or cmp)`. A plain copy has exactly
the right shape.

**Enabling it segfaulted nbody, and the reason was not the new rule.**

```
401594  mov  rax, 5
4015c0  call %make-flvector      ; RETURNS THE VECTOR IN RAX
4015c5  mov  rbx, rax            ; the call's RESULT, not the 5
```

Folding that copy gives `mov rbx, 5` and stores the integer 5 where a heap
pointer belongs. The fault is in the scan, not the rule: `redefines?` recognises
only `mov movsd movzx lea cvtsi2sd`, so a `call` never counts as writing anything
-- and `leaves-block?`, which exists three hundred lines above and whose header
says "a `call` is here because it reads argument registers that appear nowhere in
its operands", was never consulted by `fold-immediates`. A call both READS and
WRITES registers that appear in none of its operands, and the pass modelled
neither.

**This is a real latent bug and it is now fixed.** It needs a constant whose
register is also a call's return register and is read after the call. Nothing
among today's folded consumers happens to produce that, which is why the suite
was green; making a copy foldable produces it immediately. The run now stops at a
barrier in BOTH the scan and `fold-run` -- uses before it still fold, nothing
after it does, and the materialisation is kept. Costs nothing measurable:
fannkuch 27,034,212,993 instructions and nbody 3,321,767,924, unchanged.

**The optimisation itself is reverted, and I could not explain why.** On the
corrected base the copy fold still fails, now on fannkuch's oracle rather than
nbody's. Two candidate mechanisms were checked and BOTH refuted:

- `redefines?` is a whitelist, so `add`/`sub`/`imul` writing a register would go
  unnoticed and a later fold would use a stale constant. Searched for the shape
  -- a constant, then an unrecognised definition of that register, then a copy
  out of it -- and there are **zero** such sites in fannkuch.
- folding across a basic-block join would be unsound. `peephole-runs` already
  flushes the run at every label, so it cannot happen.

So the mechanism is a third thing I have not identified, and guessing a fourth
time is not the way to find it. The rule is out of the tree; `qaq.25` carries the
reproduction, the 21-site payoff estimate, and both refuted hypotheses so the
next attempt starts from what is already excluded rather than from scratch.

**Worth saying plainly:** the optimisation is not in and its value is unproven,
but the trip paid for itself. A wrong-code bug that survives in a compiler until
some unrelated change happens to reach it is exactly the kind this project's
oracles exist to catch, and this one was caught by making it reachable rather
than by reasoning about it.

## D100 — the second latent fold bug, found by bisection; the optimisation is worth nothing

D99 left `qaq.25` open with a failure it could not explain and two refuted
hypotheses. Bisecting found it, and one of those refutations was wrong.

**Method.** A parameter naming which destination registers a folded copy may
write, then partition. Every register ALONE passed fannkuch's oracle; all
thirteen together failed; the minimal failing pair was `(rdi r13)`. That is a
four-line diff to read instead of a program:

```
good:                          bad:
mov  $0x1,%r11                 mov  $0x1,%r11
mov  %r11,%r13                 mov  $0x1,%r13     fold 1, sound
sub  %rdx,%r13                 sub  %rdx,%r13     r13 is now 1 - rdx
mov  %r13,%rdi                 mov  $0x1,%rdi     WRONG
```

`sub r13, rdx` writes `r13`, and `redefines?` lists only `mov movsd movzx lea
cvtsi2sd`, so the run continued across an instruction that had just changed the
value it was propagating.

**D99 checked this hypothesis and got zero hits, and the search was wrong.** It
looked for the shape in the listing as compiled — a constant materialised into a
register, then an unrecognised definition of it, then a copy out. The constant
only ARRIVES in `r13` because of fold 1. The shape exists nowhere in the input
and only in code the pass itself produces, so searching the input could not find
it. A pass that rewrites its own scan window has to be reasoned about after the
rewrite, not before.

**Fixed.** `modifies?` — writes r as its destination, whether or not it also
reads it — now stops the run in both the scan and `fold-run`. It is deliberately
separate from `redefines?`, which answers the narrower "pure definition"
question that licenses DELETING the materialisation; two-address arithmetic reads
its destination and must not license that. `cmp` and `test` are excluded, writing
flags rather than their first operand.

This is the second latent wrong-code bug in this pass in one session, after D99's
"a call writes its return register". Both have the same root: `fold-immediates`
decides what a register holds from an opcode whitelist rather than from a def/use
model, and a whitelist is wrong by default for everything not on it. The two
fixes together make the run stop at any barrier and at any write.

**And the optimisation that found them is not worth having.**

```
                     without      with
fannkuch    27,034,212,993   27,033,942,394    -0.001%
nbody        3,321,767,924    3,321,777,529    +0.0003%
```

Both are noise. The materialisation almost always survives -- the source register
has another reader -- so the copy is REPLACED rather than removed and the count
does not move, while code size grows a 7-byte `mov r64, imm32` for a 3-byte
`mov r64, r64`. Reverted, with the measurement written into `peephole.ss` beside
the rule it explains, so the next reader who notices the missing clause finds out
why before spending a session on it.

**What the session actually bought here:** two wrong-code bugs fixed, an
optimisation correctly declined, and a note in the source that stops it being
re-attempted. `qaq.25` closes.

## D101 — fannkuch is dispatch-limited, and a quarter of its hottest block is nameable waste

The pipeline model, on fannkuch's three hottest blocks:

```
count-flips.loop     24 instructions   Block RThroughput 4.0
loop%2.372.loop      25                                  4.3
loop%2.14.434.loop   25                                  4.3
```

Roughly six instructions per cycle, which is the dispatch width, and llvm-mca
reports **no bottleneck at all** — no port pressure, no dependency chain. These
blocks are dispatch-limited, so the only lever is fewer instructions. That is the
opposite of nbody, where D90 found 85.65% register dependencies and D89 measured
instruction removal making things WORSE. Two benchmarks, opposite cost
structures; nothing learned on one transfers to the other.

**Where the measured time actually goes.** IPC is 2.76 against the model's ~6, so
reality is twice the model's throughput limit. Branch misprediction accounts for
most of the difference:

```
sonic  144M misses / 5.70B branches (2.52%)   18-29% of its 9.78B cycles
gcc    171M misses / 2.21B branches (7.73%)   24-41% of its 8.44B cycles
```

**gcc pays MORE in absolute mispredict cost than we do and is still faster.**
Its whole advantage is in the other component. Splitting at a 16-cycle penalty:
our non-mispredict work is 7.48B cycles against gcc's 5.70B — 1.31x — while we
execute 2.43x the instructions. Our instructions are individually cheaper; there
are just far too many.

**Itemised, from the 24 instructions of `count-flips.loop` (18.22% of profile):**

```
mov  %rcx,%r13            parameter shuffle
mov  $0x0,%rcx            constant into a RETURN register (see below)
mov  0x600050,%rbx        the array pointer, from memory
...
mov  %rdx,%r14            copy
mov  %r14,%rcx            copy of the copy -- argument setup
call 0x401649
mov  %r13,0x8(%rsp)       the flip counter, to the stack
addq $0x1,0x8(%rsp)       incremented THERE
jo   0x401514
mov  0x600050,%rbx        the SAME global, loaded again
```

Six of twenty-four instructions are waste with a name: a redundant copy in a
two-step chain, the same loop-invariant global loaded twice, two instructions
where `add $1,%r13` would do (D95: nothing survives a call, so the counter
spills), and the `je X / jmp Y` shape that pays a taken branch where an inverted
test would fall through.

**One of them is not what it looks like.** `mov $0x0,%rcx` reads as dead — `rcx`
is overwritten before the call and never read on the other path — but the
convention returns values in `(rax rcx rdx)`, so `rcx` is live at every `ret` and
no liveness-based pass may remove it. Whether a function returning ONE value
should keep two more return registers live is a real question and is not
answered here; filed as `qaq.26` rather than guessed at, since the last two
entries were both guesses that cost a session.

**What this settles for the open beads.** `qaq.21`'s 130 copies and `qaq.23`'s
callee-saved registers both target instruction count, which is the right lever
for THIS benchmark and measured to be the wrong one for nbody. Neither should be
justified by nbody numbers, and any measurement of them must be fannkuch's
deterministic instruction count rather than cycles, which carry 2% noise (D94)
and are a quarter mispredict recovery besides.

## D102 — a free register goes unused while a value spills, and D95's framing was imprecise

Sizing `qaq.23` — implement the callee-saved registers the convention declares —
found that it would not buy what D95 implied, and found something else.

**D95 said the flip counter is spilled ACROSS a call. Read the block again:**

```
mov  %rcx,%r13         r13 = the incoming counter
...
call 0x401649
mov  %rax,%rdx
mov  %r13,0x8(%rsp)    r13 SURVIVED the call, in a register
addq $0x1,0x8(%rsp)    and the INCREMENT's destination is the stack
```

The counter crosses the call in `r13` perfectly well. What lands on the stack is
the increment's RESULT, which is live across the *next* iteration's call. So the
spill is an allocation decision, not a failure to survive a call, and the
sentence in D95 should be read as the latter only if one stops before the fourth
instruction.

**That weakens `qaq.23`'s premise.** Callee-saved registers guarantee survivors
that the clobber analysis cannot produce. But here the analysis already produces
them: neither callee writes `r11`, `r13` or `r14`, so three raw registers survive
every call in this function without any convention at all. Declaring some of them
callee-saved adds nothing the caller did not already know.

**And then the actual finding.** The raw pool is
`(rcx rdx rsi rdi r10 r11 r13 r14)`. `count-flips` writes `r13 r14 rax rbx rcx
rdx`. It never touches **r11** — which is allocatable rather than scratch (regs.ss
keeps scratches outside every pool deliberately), is written by neither callee,
and is not filled by either call site's single argument nor by any return
register. It is free across the whole function, and a value spills to the stack
anyway.

Three explanations are available and none is established: the interval's `across`
set contains r11 for a reason not visible in the listing; linear scan's ordering
never offers it; or the spill decision happens before the register is known free.
Filed as `qaq.27` with all three stated so the next attempt starts by
distinguishing them rather than by picking one.

**Method note, since this is the third time.** The plan was to implement
`qaq.23`. Sizing it first cost twenty minutes and showed it would have bought
approximately nothing, which is the same outcome as D93 (hoisting globals, one
cycle in 3847) and D91 (packing divides, which gcc does not do). Three
implementations avoided by reading the artifact first; one implementation shipped
(D97) that was found the same way. The pattern is not that plans are usually
wrong — it is that a plan and its evidence cost about the same, so there is no
reason to spend the plan first.

## D103 — every spill in fannkuch comes from one missing table

`qaq.27` asked which of three explanations makes `count-flips` spill while `r11`
sits free. None of them. Instrumenting the allocator's two spill paths and
compiling fannkuch:

```
spills caused by bad=ALL:      21
spills from any other cause:    0
```

**Every spill in the program**, and each one reports a FULL pool with the whole
register file marked destroyed. So the pool was never the constraint and the
eviction asymmetry I was about to fix was not the problem either.

`across` answers with the whole file for an unknown callee, a runtime routine, or
a recursive cycle. A second probe named which:

```
20  caller=next          callee=display
16  caller=next          callee=newline
 6  caller=main.entry1   callee=%make-vector
```

Only runtime routines. `next` calls `display`, so every interval in `next` that
spans that call is told all twelve allocatable registers are gone, and four of
its five live variables -- `checksum`, `maxflips`, `sign`, `r` -- go to the stack.

**What those routines actually write:**

```
display        4 registers   (rax rdx rsi rdi)
newline        1 register    (rax)
%make-vector   3 registers   (rsi rdi rax)
```

`newline` writes ONE register and is charged with twelve. Even the crude union
over the ENTIRE runtime leaves `r10` and `r14` untouched in the raw pool, so
anything at all is better than what is there now.

**The information exists and nothing reads it.** `runtime-listing` is exported,
`listing-writes` already computes exactly this for compiled functions, and
`finalize-program*` seeds its `clobbers` table for every function it finalizes.
The runtime is simply never entered into that table, so `hashtable-ref` misses and
every caller falls back to "everything" -- the same shape as D94's discovery that
the analysis was skipped for functions with pins, and the same shape again as
D95's "callee-saved is declared and never implemented". Three times now the work
was done and the wiring was missing.

**Not implemented here, deliberately.** The routines are hand-written assembly
with internal branches, so a sound clobber set needs a reachability walk from the
entry label -- fallthrough and jump targets, stopping at `ret` -- and the failure
direction is asymmetric: an UNDER-approximation is a wrong-code bug that keeps a
value in a register the callee overwrites, and no oracle in this tree is
guaranteed to catch it. The walk must therefore fall back to "everything" on
anything it does not understand: an indirect jump, an unrecognised instruction
shape, a jump out of the routine. That is a careful hour, not a rushed one, and
this session has already put two latent wrong-code bugs into this compiler's
history (D99, D100) by moving fast in adjacent code. `qaq.28` carries the design.

**Sizing, since it decides the priority.** All 21 fannkuch spills, plus their
reloads, plus the register pressure they cause elsewhere. The spilled values in
`next` are loop variables of a function that is 4.30% of the sampled profile, and
fannkuch is dispatch-limited (D101), so removed instructions convert to time here
in a way they demonstrably do not on nbody.

## D104 — the missing table, filled in correctly, makes fannkuch slower

D103 diagnosed every fannkuch spill to one cause and filed `qaq.28`. It is
implemented, measured, and reverted.

**The analysis works.** `runtime-clobbers` walks a runtime routine from its entry
label as a worklist over instruction indices — following fallthrough and both
edges of every branch, resolving nested calls recursively, visiting each
instruction once so a loop terminates without a fixpoint — and refuses, returning
#f for "assume everything", on anything it does not positively understand.

```
display        (rdi rsi rdx r11 rcx rax)
newline        (rax)
%make-vector   (r11 rcx rdi rax rsi)
%cons          (rdi r11 rcx rsi rax)
cadr           (rax)
```

None writes `r10`, `r13`, `r14` or any of the value pool, so a runtime call goes
from destroying twelve registers to destroying five.

**Two hazards it caught that a simpler walk would not.** `syscall` writes `rax`
and also `rcx` and `r11`, which the CPU overwrites with rip and rflags; a first
version reading only destination operands reported `display` as writing four
registers and would have let a caller keep a value in `rcx` across a `write`.
And `%cons` branches to `sonic-heap-error`, which exits rather than returning, so
the walk falls out of the listing — treated as a terminating path, which
over-approximates and is the safe direction.

**And it makes things worse.**

```
                    before          after
fannkuch spills         11             10
next.loop stack refs    37             32
fannkuch instructions  27,033,942,394  27,034,2xx,xxx    unchanged
fannkuch cycles        9,798.7M mean   9,975.7M mean     +1.8%
nbody                  unchanged       unchanged
```

Four runs each, ranges not overlapping, so by D94's rule the regression is real
rather than noise. The spills it removed are real too — `next.loop` genuinely
lost five stack references — and the dynamic instruction count did not move at
all, which says that code is not hot.

**So a change whose only executed difference is nil costs 1.8% of cycles.** The
most likely explanation is code layout: the listing lost five instructions, which
shifts every later address and changes alignment and branch-predictor indexing
throughout. That is a real cost for this binary and an arbitrary one — the same
change on a different day's code might gain 1.8%. I cannot demonstrate it, and
the project's rule is that the measurement stands, so this is reverted rather
than argued with.

**What would settle it**, recorded on `qaq.28` rather than guessed at: measure
with the layout effect controlled, by padding the listing back to its original
length, or by measuring several unrelated benchmarks where a layout shift is
independent noise but a spill reduction is not. Until then the honest statement
is that filling the table is CORRECT, removes real spills, changes no executed
instruction, and measured slower once.

**A note on what this cost.** D103 sized this as the highest-value item open — all
21 spills, in the benchmark where instructions convert to time. The sizing was
right about the mechanism and wrong about the outcome, which no amount of reading
the artifact beforehand would have caught: the effect that dominated is one the
listing cannot show. Pre-verification has killed three bad plans this session
(D91, D93, D102) and could not have killed this one.

## D105 — fannkuch's cycle count moves 5% on code alignment alone

D104 reverted a correct change on a 1.8% cycle regression and guessed the cause
was code layout. The guess is testable: append unreachable instructions to the
end of the runtime, which sits before all user code, so every user instruction
shifts and nothing else changes at all.

```
             fannkuch cycles      instructions
pad 0        9,778,552,960        27,033,917,755
pad 1        9,853,025,913        27,034,063,656
pad 2        9,734,106,403        27,033,919,882
pad 3        9,900,108,989        27,034,211,547
pad 5        9,884,551,119        27,034,135,709
pad 8        9,430,695,223        27,033,296,643
```

**A 4.97% spread from alignment**, instruction counts constant to 0.003%. Eight
unreachable instructions make fannkuch 3.6% FASTER than none.

**nbody, the same sweep: 0.26%.** 942.2M, 944.7M, 944.4M, 942.3M. The difference
between the two is exactly their established cost structures — nbody is
dependency-bound (D90: 85.65% register dependencies), where front-end alignment
cannot matter, and fannkuch is dispatch-limited with a 2.5% mispredict rate
(D101), where alignment and branch-predictor indexing are most of what there is.

**This is a larger result than any optimisation in this session, and it
invalidates measurements in it.**

- D104's 1.8% "regression" is inside the layout band. That change -- real clobber
  sets for runtime routines -- was correct, removed real spills, changed no
  executed instruction, and was reverted on alignment luck. The revert was wrong.
- D97's fannkuch **cycle** claim (9,957.6M to 9,808.8M, ~1.5%) is also inside the
  band and should not have been stated as real. Its INSTRUCTION claim, -2.78% on
  a deterministic counter, stands untouched and is the reason to keep the change.
- D98's 0.15% cycle observation was already called noise and remains so.
- D89's nbody sweep is unaffected: nbody does not move on alignment, and that
  entry's conclusion rests on instruction and branch counts besides.

**The rule that follows.** A fannkuch cycle comparison between two builds is
meaningless below about five percent unless both are swept across several pad
values and the distributions compared. Comparing one build of each at pad 0
measures alignment luck. `layout-pad` is now a parameter in `runtime.ss` with
this table in its header, so the control is available rather than merely
described.

Instruction counts remain the sound currency for fannkuch: deterministic to
0.002% (D94), unmoved by alignment, and the thing a dispatch-limited benchmark
actually spends.

**And a process failure worth recording.** D104's implementation was reverted by
restoring backups and was never committed, so it is NOT in git history -- the
note I put on `qaq.28` saying it is, is false and is corrected there. Half an
hour of careful work on a walk that correctly handled `syscall`'s implicit `rcx`
and `r11` had to be reconstructed from the session transcript. A change measured
and rejected should be committed on a branch or its diff kept, because the
measurement that rejected it may itself be wrong -- as this one was.

## D106 — the clobber table, re-measured with layout controlled: no detected difference

D105 showed D104 rejected a correct change on alignment luck, so the change was
reconstructed — it had been reverted from backups and never committed, which cost
half an hour of rewriting a walk that had already been got right. Re-measured the
way D105 says fannkuch must be: both builds swept across six pad values,
distributions compared.

```
           mean       sd     min       max
without   9763.5M   175.0   9430.7   9900.1
with      9917.2M   133.2   9748.5  10108.2

difference +153.7M (+1.57%), SE 89.8, t = 1.71, ranges overlap
```

**No detected difference.** t = 1.71 on ten degrees of freedom is not
significance at any conventional threshold, and the ranges overlap heavily. So
D104's "1.8% regression" does not survive layout control — but neither does an
improvement appear, and the point estimate is still on the wrong side.

**Kept anyway, and the reasoning should be checkable.** The instruction count is
identical between the two builds on a counter deterministic to 0.002%. The only
difference in emitted code is that some values live in registers where they used
to live on the stack — `next.loop` loses five stack references, spills go 11 to
10. A change that removes memory traffic while executing the same instructions
cannot plausibly be slower; the +1.57% is layout residue that six samples per
arm cannot separate from zero, and buying significance here would cost many more
compiles for a number that is already known to be dominated by alignment.

That is a judgement, not a measurement, and it is recorded as one. What is
measured: correct, no instruction change, fewer spills, no detected cycle
difference.

**What it closes.** `newline` writes one register and was charged with twelve.
The table's emptiness was rediscovered three times in this session under three
different names — D94 found the analysis skipped for functions with pins, D95
found callee-saved declared and never implemented, D103 found every fannkuch
spill traced to this — and each time the machinery existed and the wiring did
not. `qaq.28` closes; the wart does not come back.

**And a correction to how this session measured.** Six of the eleven cycle
comparisons in D89-D104 were made between single fannkuch builds at pad 0. Those
are alignment luck at the one-to-two percent level. The ones that survive are
the instruction-count claims, which is why D97 keeps its result (-2.78%
instructions) and loses its gloss (~1.5% cycles). Anyone reading this run of
entries for a performance history should take the instruction counts and ignore
the fannkuch cycle figures below five percent.

## D107 — the copies are argument setup, and the allocator never sees where they go

`qaq.21` counted 130 register-to-register moves in fannkuch. Separating the
hand-written runtime from compiled code, and asking which could share a register
at all:

```
runtime  (allocator never sees it)   26 moves, 19 with a dying source
compiled (the allocator's output)   110 moves, 86 with a dying source
```

They cluster where it matters -- `count-flips.loop` spends **7 of its 24
instructions** on copies, `loop%2.372.loop` 6, `loop%2.14.434.loop` 6, in blocks
that are 39% of the sampled profile between them. And the shape is always the
same:

```
mov r14, rdx        the value lands wherever the scan had free
mov rcx, r14        because rcx is what the convention wants
call ...
```

Two copies for one value, because nothing asked the allocator to put it in `rcx`.

**The obvious fix does not work, and measuring why is the result.** `move-hints`
already maps a vreg to something it would like to share a register with, so
adding the reverse direction -- a vreg moved INTO a physical register wants that
register -- is a dozen lines. Implemented, suite green, and it changed nothing at
all: listing 1092 to 1092, moves 136 to 136, spills 10 to 10.

A counter says why: **zero physical hints were recorded.** The allocator never
sees a move into a physical register, because argument setup does not exist yet
when it runs. An Lmach call carries its arguments as OPERANDS -- `(call dst sc
callee arg ...)` -- and `finalize.ss` materialises the copies afterwards, from
the assignment the allocator already made. By then the choice is fixed and the
copies are the cost of it.

**So the fix is not a hint, it is a pre-colouring.** `parameter-pins` already
does exactly this for INCOMING parameters, pinning them to the registers the
convention delivers them in, and `allocate-program/precolored` is the entry point
that honours pins. Outgoing arguments want the same treatment: a call's operands
pinned to the registers that call will require, so the allocator places them
there and `finalize` emits no copy. That is a change to the allocation interface
rather than to a heuristic, and it interacts with everything pins already
constrain -- which is why it is scoped here rather than attempted at the end of a
long session.

Reverted, since a hint that never fires is maintenance with no behaviour.
`qaq.21` keeps the sizing and gains the mechanism.

## D108 — the pin mechanism cannot pre-colour outgoing arguments, and that is structural

D107 concluded `qaq.21` wants a pre-colouring rather than a hint, and named
`parameter-pins` as the model since it already pins INCOMING parameters to the
registers the convention delivers them in. Reading that mechanism before
mirroring it finds two reasons it does not transfer.

**It only fires when every call in the function is a tail call.**

```scheme
(define (parameter-pins target blocks params classes)
  (if (or (null? params) (not (every-call-is-tail? blocks)))
      '()
      ...))
```

The reason is sound and applies doubly to outgoing arguments: a non-tail call
destroys the argument registers, so a value pinned to one does not survive it.

**And a pin removes its register from the pool for the WHOLE function.**

```scheme
(taken (map pin-reg pins))
(reduced (make-arch (arch-name a)
                    (without (arch-value a) taken)
                    (without (arch-raw a) taken) ...))
```

That is right for parameters -- a handful, live from entry -- and catastrophic
for outgoing arguments. Pinning the six raw argument registers would leave two of
an eight-register pool allocatable everywhere in the function, to save two copies
at each call site. The cure would cost more than the disease by a wide margin.

**So the real shape of the fix is range-based pre-colouring**: a value constrained
to a specific register over PART of its live range, with the register free
elsewhere. Linear scan here has no such notion -- a pin is a property of the
function, not of an interval -- and adding one touches the same expiry and
eviction logic that D95 and D103 were both about.

`qaq.21` therefore is not a heuristic tweak, not a pin, and not small. It stays at
P1 because the prize is real -- 7 of `count-flips.loop`'s 24 instructions, in
blocks that are 39% of the profile -- but the bead now records what it actually
requires, so the next attempt does not spend a session rediscovering that
`move-hints` cannot reach (D107) and that pins cost the whole pool (here).

**Three consecutive entries have now ended without a change**, and that is worth
naming rather than hiding: D102 sized `qaq.23` and found it bought nothing, D107
implemented the hint and measured zero, D108 read the mechanism and found it
inapplicable. Each cost under an hour and removed a plausible-looking plan from
the board. The alternative -- implementing range-based pre-colouring on the guess
that the copies matter -- is the expensive mistake this sequence avoided.

## D109 — D101's explanation of the dead store was wrong, and there are three of them

D101 saw `mov $0x0,%rcx` in `count-flips.loop`, observed that the convention
returns values in `(rax rcx rdx)`, and concluded `rcx` must be live at every
`ret` so no liveness pass could remove it. That is refuted by four lines:

```scheme
(define (transfer-uses t)
  (case (car t)
    ((ret) (if (and (pair? (cdr t)) (symbol? (cadr t))) (list (cadr t)) '()))
    ...))
```

A `ret` marks exactly the ONE vreg it returns. Liveness there is already precise,
the convention's three-register ceiling never enters it, and `qaq.26` as filed
asked the wrong question.

**Reading the whole block instead of the part I quoted finds three, not one:**

```
mov  %rcx,%r13         reads the incoming counter
mov  $0x0,%rcx         overwritten on one path, unread on the other
...
mov  $0x1,%r14         overwritten by `mov %rdx,%r14` below
...
mov  $0x1,%r14         and again
```

Three of the block's twenty-four instructions, in the hottest block in fannkuch
(18.22% of the sampled profile), and every one is a constant written to a register
that is overwritten before any read.

**Two things ruled out while looking.** The loop's back edge is `jmp 0x4017ab`,
which is `count-flips.loop`'s first instruction and NOT the `sub $0x20,%rsp` at
`0x4017a7` -- so D97's self-jump retargeting is working and no prologue runs per
iteration. And `dce-program` runs at `driver.ss:155` on Lmach, before selection,
where it removes exactly `const` definitions nothing reads.

**Which leaves the real question, and it is not the one D101 asked.** DCE runs on
VREGS and these survived it, so each constant must have a use at that level --
but the emitted listing shows physical registers, where two vregs sharing `rcx`
are indistinguishable from one. The candidate is a loop-carried phi: a value that
is 0 on the entry edge and the counter on the back edge would make `const 0` a
genuine use at Lmach and a redundant store after the parallel copy is resolved.
That is a guess, and the last three guesses in this ledger were wrong, so it is
written on `qaq.26` as the thing to check rather than as the answer.

The way to check it is to print the Lmach definition and uses of the vreg that
receives `rcx`, not to read more assembly -- the information that would settle it
has been erased by the time the listing exists.

## D110 — the three dead stores, explained: two mechanisms, neither a liveness bug

D109 said the answer was in the Lmach and not in the assembly, and to go print
it. Printing `count-flips`:

```
BLOCK count-flips
  (const t.364 raw-word 0)
  (gref g.18 tagged %g-perm)
  (load-at k%7.365 raw-word 0 g.18 #f)
  (cmp-eq t.367 raw-word k%7.365 t.364)
  T (branch-if t.367 L.then27 L.else28)
BLOCK L.else28
  (const t.18.422 raw-word 0)
  (call t.423 raw-word loop%2.14@8.373 k%7.370)
  (const t.424 raw-word 1)
  (add-imm t.425 raw-word 1 f%6.363)
  (chk overflow-check checked 0 f%6.363 t.424 t.425)
  ...
  (cmp-eq t.21.429 raw-word k%7.427 t.18.422)
```

Every constant has a real use at this level, so DCE was right to keep all of
them, and the loop-carried-phi guess in D109 was wrong. The stores are dead in the
EMITTED code for two different reasons.

**One: `chk` names an operand the emitted check does not read.** `(chk
overflow-check checked 0 f%6.363 t.424 t.425)` carries the constant `1` as an
operand describing what was added. A checked add emits `add` then `jo`, and `jo`
reads the FLAGS -- it never touches the register holding 1. So `t.424` is live
through the IR and dead in the machine code, and both `mov $0x1,%r14` stores come
from this.

**Two: a folded constant at the end of a run keeps its materialisation.**
`t.364`'s only use is `cmp-eq`, which `fold-immediates` rewrites to `cmp
$0x0,%rdx` -- and the emitted code shows exactly that. The pass deletes the
materialisation only when a later REDEFINITION proves it dead, and `t.364` is
redefined in a different block. `peephole-runs` flushes its run at every label,
so the redefinition is never in view and the store stays. That is the
`mov $0x0,%rcx`.

**Nothing removes either, and the reason is pass order.** `dce-program` runs
before selection, where all three constants are genuinely used. `peephole` runs
after, and its only removal rule is `drop-dead-copies` -- copies, not constants.
So folding CREATES dead code that no later pass looks for. There is no liveness
bug here and no wrong answer anywhere; there is a gap between two correct passes.

**Two fixes, and they are not the same size.** The `chk` operand is a
representation question -- whether a check needs to name a value the emitted
instruction cannot read -- and touching it reaches D5's check vocabulary, which
the whole project rests on. The folded-constant case is a dead-store pass over the
finalized listing with liveness across blocks, which is the same machinery
`dce.ss` already has for Lmach, applied one stage later.

Worth 3 of 24 instructions in a block that is 18.22% of fannkuch's profile, on a
benchmark measured dispatch-limited (D101). Recorded on `qaq.26` with both
mechanisms named, so whoever takes it chooses between them knowingly.

## D111 — removing 863M instructions from the dispatch-limited benchmark made it slower

Selection emits a two-way branch as "jump to the taken side, then jump to the
other", and when the taken side is the very next block the first jump goes five
bytes forward:

```
je   L.then          ->    jne  L.else
jmp  L.else                L.then:
L.then:
```

27 such sites in fannkuch, two apiece in the three hottest blocks. Inverting the
test deletes the unconditional and turns the common path from a taken branch into
a fallthrough. Pure control flow -- no liveness, none of the hazards that
produced D99 and D100 -- and it must be a whole-listing pass, because the label
that decides it is exactly what `peephole-runs` flushes on.

**It worked, on every count that is not time:**

```
                       before           after
fannkuch listing        1,092            1,066
unconditional jmp          64               38
fannkuch instructions  27,036,0xx,xxx   26,172,700,864   -3.2%
fannkuch branches       5,704,1xx,xxx    4,842,760,211  -15.1%
nbody instructions      3,256,77x,xxx    3,221,789,171   -1.07%
nbody branches            300,3xx,xxx      255,302,691  -15.0%
```

Answers verified against the oracle (556355 / 51, agreeing with gcc), suite green
at 8589/0/59, callgrind independently confirming 26,155,573,605.

**And fannkuch got slower.** Cycles swept across four pad values as D105
requires: mean 9,961M against 9,711M before, +2.6%. Wall clock, min of three:
3459.1 ms against 3340.9 ms, +3.5%. nbody's cycles did not move at all, which is
D89 exactly -- its instructions were already free.

**Mispredicts explain about a quarter of it.** Misses went 143.7M to 147.9M, and
4.2M extra at sixteen cycles is 67M against a 250M regression. The rate rose from
2.52% to 3.05% because the denominator lost 861M well-predicted branches while
the numerator grew. The other three quarters are unexplained.

**This contradicts D101 and the contradiction is the result.** That entry measured
fannkuch's hot blocks at ~6 instructions per cycle -- the dispatch width, with
llvm-mca reporting no bottleneck -- and concluded instruction count is the lever
for this benchmark. Here is 3.2% of the instructions and 15% of the branches
removed, for 3.5% more wall clock. A static model that sees a block issuing at
width does not see what the front end does with 27 fewer branch targets, and
whatever that is, it costs more than the instructions were worth.

So the honest state of fannkuch is that **neither instruction count nor the
pipeline model predicts its time.** D89 established that for nbody by a different
route; this establishes it for fannkuch, which was supposed to be the benchmark
where instructions convert. Reverted.

**What I would tell the next attempt.** Do not open by removing instructions from
fannkuch and expecting time. Measure the front end first -- taken-branch density,
mispredict rate, and how they move -- because three separate optimisations in this
session (D97's frame reuse, D106's clobber sets, this) all removed real work and
none of them bought time on it.

## D112 — fannkuch is a quarter front-end stalled, and that is what D101 could not see

D111 removed 3.2% of fannkuch's instructions and 15% of its branches and made it
3.5% slower, leaving three quarters of the regression unexplained. The counter
that explains it:

```
              cycles       front-end stalled     L1-icache misses
fannkuch   9,917,359,629   2,502,761,867 (25.2%)          771,369
nbody        941,578,405       4,401,656 (0.5%)            67,363
```

**A quarter of fannkuch's cycles are spent with the front end unable to deliver
an instruction**, and it is not instruction-cache: 771K misses over 27 billion
instructions is nothing. It is branch prediction. 148M mispredicts at roughly
sixteen cycles of redirect is 2.4B, against 2.50B measured stalled -- the whole
of it, near enough.

**This corrects D101 properly.** That entry ran llvm-mca on the hot blocks, saw
them issuing at ~6 instructions per cycle with no bottleneck reported, and
concluded fannkuch is dispatch-limited so instruction count is the lever.
llvm-mca has no branch predictor. It modelled the quarter of the machine that was
not the problem, correctly, and said nothing about the quarter that was. D111 is
what that blind spot costs: a clean optimisation, correct on every static count,
that made the benchmark slower.

**Separating the two components changes what the target is:**

```
              total     stalled   executing   IPC while executing
fannkuch      9.92B      2.50B      7.41B           3.65
gcc           8.44B     ~2.74B      5.70B           1.95
```

gcc spends MORE absolute time on mispredicts than we do and is still faster,
because its executing portion is 5.70B against our 7.41B. We issue nearly twice
as densely -- 3.65 against 1.95 -- and carry 2.4x the instructions to do it.

**So the target is 23%.** To match gcc's executing cycles at our own issue
density needs 20.8B instructions where we have 27.0B. Not the 3.2% D111 removed,
and not anything a peephole reaches: 23% of a Scheme's instruction count against
C is a representation question -- tagging, checks, indirection -- not a
code-generation one.

**And the constraint that makes it hard.** Any change that trades instructions
for branches loses, because branches are where the 25% goes. D111 removed 861M
branches and gained 4.2M mispredicts, and the mispredicts cost more than the
branches saved. A fannkuch optimisation must cut instructions WITHOUT touching
control flow, or cut mispredicts directly.

**Three optimisations in this session removed real work from fannkuch and none
bought time**: D97's frame reuse, D106's clobber sets, D111's branch inversion.
D112 says why -- they were all aimed at the 75% that is not the bottleneck, and
one of them disturbed the 25% that is.

## D113 — where fannkuch's 2.4x actually is, and it is not the inner loop

D112 set the target at a 23% instruction cut and called it a representation
question. Making that concrete meant reading both inner loops rather than
theorising about tagging.

**Ours is near-optimal for what it is.** The reversal, unrolled by two:

```
mov  0x600050,%rbx           the array pointer, once per two swaps
mov  -0x1(%rbx,%rsi,8),%r10  load a[i]
mov  -0x1(%rbx,%rdi,8),%r11  load a[j]
mov  %r11,-0x1(%rbx,%rsi,8)  store
mov  %r10,-0x1(%rbx,%rdi,8)  store
lea  0x1(%rsi),%r10          i++
lea  -0x1(%rdi),%rsi         j--
cmp  %rsi,%r10
jge  ...
```

About eight instructions per swap: two loads, two stores, two index updates, a
compare and a branch. There is no tagging in it, no check, no boxing. It is what
a C compiler would emit for the same loop over 64-bit elements.

**And gcc's is scalar too.** Its `main` is 71 `mov`, 18 `lea`, 13 `cmp`, 12
`jle`, and **four** vector instructions. The 6.82% of its profile in
`__memmove_avx512_unaligned_erms` is libc's memcpy for the array copy, not the
flip. So the 2.4x is not vectorisation, and it is not the flip loop.

**Two differences are visible and neither is about Scheme.**

`ref.c` declares `static int perm[N]` -- **32-bit elements**. Our `(make-vector 7
0)` is a vector of tagged words, eight bytes each. Every load, store and address
computation in the flip moves twice the bytes, and 11 `movslq` in gcc's main are
the sign-extensions it pays instead. That is a data-representation choice the
benchmark makes, not an optimisation we are missing.

`gcc` emits six `push` and six `pop` in `main`: it uses callee-saved registers to
hold the array pointer and loop state across calls. We emit **zero** push or pop
in the entire binary (D95), so ours reloads `0x600050` inside the loop. D102
weakened that finding by showing the clobber analysis already identifies
survivors -- and it does, but only for callees it can see, and only as many as
happen to be untouched.

**What this closes.** "Where does 2.4x come from" has been an open assumption
since D93 and the answer is not the one the phrase "Scheme overhead" suggests.
The inner loop carries no interpretive cost at all. The gap is element width and
register discipline, and the first of those is not ours to change without
changing what the benchmark measures.

That makes `qaq.7`'s framing worth revisiting for fannkuch the way D80 revisited
it for nbody: comparing a 64-bit-word Scheme against a 32-bit-int C on an
array-shuffling benchmark measures the word size as much as the compiler. It is
not a reason to stop, and it IS a reason not to read 2.4x as a compiler deficit.

## D114 — word size is not the explanation; measured at 6%, not the gap

D113 read both inner loops, found ours carries no interpretive cost, and offered
two differences to account for the 2.4x: `ref.c` uses 32-bit `int` elements where
our vectors hold 8-byte words, and gcc uses callee-saved registers where we emit
none. The first is testable in one compile.

`ref.c` with `static int` changed to `static long`, same `-O3 -march=native`,
same n=11:

```
                 instructions      cycles        branch misses
gcc, int       11,144,630,228   8,466,183,422    169,248,120
gcc, long      11,833,618,817   8,402,466,365    175,707,646
sonic          26,172,768,077   9,925,579,252    148,202,349
```

**Doubling the element width costs gcc 6.2% of its instructions and none of its
cycles.** So word size accounts for about a sixteenth of the gap, and against a C
that carries the same 64-bit elements we are still at **2.21x** the instructions.

D113's explanation is therefore wrong in its emphasis. It remains true that our
flip loop has no tagging, no check and no boxing in it -- that was read directly
off the listing and is not in doubt. What does not follow, and what D113 implied,
is that the difference lies in how values are represented.

**Which sharpens the question rather than answering it.** If the inner loops are
near-parity and word size is 6%, the 2.2x is in the code around them: `next`,
`step`, `copy-perm`, `join`, `main`. The sampled profile puts `count-flips.loop`
at 18.22% and the two reversal halves at 11.40% and 9.66%, so roughly 60% of the
time is somewhere this session has never disassembled.

That is the next thing to read, and it is a different question from the one the
last four entries have been circling. `qaq.7`'s fannkuch arm should not be closed
or reframed on a word-size argument that measurement does not support.

**Method note.** D113 offered two explanations and this tested one of them the
same day. The other -- callee-saved registers -- is `qaq.23`, which D102
downgraded to P3 on nbody evidence; D114 gives no reason to raise it, since
nothing here isolates it either. Two plausible causes, one measured and refuted,
one still unmeasured, and the ledger should not let the unmeasured one inherit
the credibility of having been listed beside it.

## D115 — the reversal is 64% of fannkuch and it is spread over four functions

D114 said roughly 60% of fannkuch's time is in code this session has never
disassembled, and that was an artefact of a profile that captured 41 samples.
A fuller one attributes 73.3%:

```
  20.44%  count-flips.loop         7.18%  loop%2.14@8.435.loop
  14.76%  loop%2.372.loop          4.77%  next.loop
  11.82%  loop%2.14.434.loop       2.10%  copy-perm.loop
  10.00%  loop%2.14@8.373.loop     1.14%  join.240.loop
```

`count-flips` plus the four `loop%2.*` halves is **64.2%**, and that is exactly
the code D113 read and called near-optimal. So the claim to correct is D114's,
not D113's: the time is not somewhere unexamined, it is in the reversal.

**And the reversal is not one loop. It is four functions that tail-call each
other**, with eight `loop%2.*` labels in the binary altogether:

```
loop%2.372         30 instructions, 6 register copies, 1 tail jump
loop%2.14.434      30 instructions, 6 register copies, 1 tail jump
loop%2.14@8.373    17 instructions, 3 register copies, 1 tail jump
loop%2.14@8.435    17 instructions, 3 register copies, 1 tail jump
```

Eighteen register-to-register copies across the four, all of them the argument
setup D107 identified -- values moved into the registers the next half's
convention requires. A swap itself is eight instructions (D113); a swap plus the
transition machinery around it is a good deal more.

**Where the four came from.** `unroll-fully` and the specializer produce variants
-- `loop%2.14.434` and `loop%2.14@8.435` are specialised copies of `loop%2.372`
and `loop%2.14@8.373` -- and D89 measured that pass as a net loss on cycles at
every budget it was given. Its output is still here at the default budget, and
what it produced is a hot loop distributed over four call-connected pieces.

**This is a better-shaped question than the last four entries had.** It is not
"where does Scheme overhead come from" (D113: there is none in the flip), nor
word size (D114: 6%), nor instruction count in the abstract (D111: removing it
made things worse). It is: **a single reversal loop is compiled into four
mutually tail-calling functions, and the transitions between them are paid on
every iteration of the hottest code in the benchmark.**

Whether merging them is possible is not established here and should not be
assumed -- the specializer split them for a reason D89 partly documents, and
`qaq.21`'s pre-colouring would remove the copies without removing the
transitions. Filed as `qaq.29`, with the profile, the four listings and the copy
counts, so the next attempt starts from the shape rather than from a count.

## D116 — unrolling costs fannkuch 5.6%, and it is what makes bounds-check elision work

`qaq.29` asked whether the four reversal functions could be merged. Diffing them
answers a different question first: `loop%2.372` and `loop%2.14.434` are
**identical modulo label names**, as are `loop%2.14@8.373` and `loop%2.14@8.435`.
Two exact copies of each reversal half. `unroll-program` made them -- by-two
unrolling duplicates the body, unconditionally, with `unroll-size-budget` at
1000.

**Turning it off is a large win.** Both configurations swept across four
`layout-pad` values, per D105:

```
unroll OFF   9,261.4  9,426.3  9,624.7  9,162.0   mean 9,368.6M cycles
unroll ON    9,984.7  9,962.9  9,783.6  9,975.3   mean 9,926.6M
```

Ranges do not overlap. **5.6% faster with the pass off**, while executing 13.7%
MORE instructions -- 30.73B against 27.03B. nbody moves 0.17%, inside its noise,
while paying 6.7% more instructions.

That is exactly D112's picture: fannkuch spends 25.2% of its cycles front-end
stalled on mispredict redirects, and duplicating a hot loop doubles its branch
targets. What the predictor loses exceeds what the removed loop control saves.
Third time this session that fewer instructions meant more time on this
benchmark, and the first with a mechanism established rather than suspected.

**And it cannot simply be switched off, which the test suite caught and I would
not have.** With unrolling disabled:

```
FAIL nbody emits NO bounds check at all
FAIL fannkuch-redux emits no bounds check either, once perm's contents are bounded
```

**Unrolling is load-bearing for check elision.** The duplicated body is what gives
the interval and element-range analyses the second copy of the induction step
they need to prove the index in range. So the 13.7% extra instructions in the
"off" column are partly re-added bounds checks -- and it was still 5.6% faster
with them.

**So this is a trade, not an optimisation, and the trade is not mine to make.**
Five and a half percent on one benchmark against the check-elision property that
D5 and D24 are built on -- the thing this compiler is arguably *for*. Reverted,
and the suite is green at 8589/0/59.

Recorded on `qaq.29` and raised to Nathan alongside M5's accuracy question, since
both are decisions about what SonicScheme promises rather than about what is
fast. A third possibility exists and is untested: keep unrolling for the analysis
and UNDO it afterwards, once the checks are proven and before code generation.
That would need the elision facts to survive re-rolling, which nothing in the
tree currently does.

## D117 — correcting D116: the elision is not worth the transformation that enables it

D116 called the unrolling result "a trade -- 5.6% on one benchmark against the
check-elision property". That framing is wrong in a way that changes what is
being asked, and the numbers were already on the page.

```
                 instructions      cycles      bounds checks   binary
unroll ON       27,034,305,919   9,926.6M mean     none         7,898 bytes
unroll OFF      30,734,043,653   9,368.6M mean     present      6,828 bytes
```

Turning unrolling off does not buy speed at the cost of safety. It produces code
that **executes more instructions, carries the bounds checks, is 13% smaller, and
is 5.6% faster.** There is no axis on which the checks are the price.

**What is actually being paid for is the elision, and it costs 5.6%.** The checks
that unrolling removes were provably unnecessary -- that is what elision means --
so they were never going to fire, and a never-taken well-predicted branch is
nearly free. The transformation that proves them unnecessary duplicates the hot
loop, and on a benchmark spending 25.2% of its cycles on mispredict redirect
(D112) that duplication costs more than the checks ever did.

So the honest statement is not "5.6% versus safety". It is: **on fannkuch,
eliding provably-dead bounds checks is a net loss, because the analysis needs a
transformation whose cost exceeds the checks'.** The elided check was cheap; the
proof was expensive.

**This is a result about the project's central claim, and it is one benchmark.**
D5 and D24 rest on check elision being the contribution, and on nbody the same
configuration is neutral -- 0.17%, inside noise, paying 6.7% more instructions
for the checks it re-adds. So elision-via-unrolling is neutral on the
float-heavy, dependency-bound benchmark and harmful on the integer,
front-end-bound one. Two benchmarks, and they disagree, which is the same shape
D89 and D101 kept producing.

What Nathan is being asked is therefore narrower than D116 said: not whether to
give up checking, but whether the elision *machinery* earns its keep on a
front-end-bound target, and whether the re-roll idea on `qaq.29` is worth
building to get the proof without the duplication.

**And a note on how the correction happened.** D116's numbers were complete and
its conclusion was not. I read "checks come back when unrolling is off" as a cost
without noticing that the same column was already faster. Re-reading a table I
had written an hour earlier was the whole of it.

## D118 — the check counts, at last measured rather than inferred

D116 said turning unrolling off is a trade against check elision. D117 corrected
the framing and said the checks come back but cost nothing. Both were reasoning
from a test FAILING, which says only that some check appeared. Counting them:

```
                    nbody    fannkuch
unroll OFF            14         3      branches to sonic-bounds-error
unroll ON              0         6
```

**On fannkuch, unrolling DOUBLES the checks.** There are three the analysis cannot
discharge either way, and the duplicated body carries two copies of each. So for
that benchmark, disabling unrolling gives fewer checks, 13% smaller code, and
5.6% fewer cycles. There is no trade in it at all -- D116 and D117 both described
one because both assumed the failing test meant fannkuch had gained checks, and
it had lost them.

**On nbody, unrolling is what elision needs.** Fourteen bounds branches without
it, zero with. The comment on that test says why: the indices are `3i+k` against a
length proved at allocation, and the analysis gets there only with the duplicated
induction step in front of it. That elision is worth 6.7% of nbody's instructions
and **0.17% of its cycles** -- inside the noise, because D89 established nbody's
spare instructions are free.

**So the decision is one line.** Keeping `unroll-program` on by default buys
"nbody emits NO bounds check at all", which is worth 0.17% of nbody's time, and
costs 5.6% of fannkuch's. Everything else in D116 and D117 -- the safety framing,
the "checks are nearly free" argument, the claim that the elision is not worth its
transformation -- was reasoning toward this from incomplete counts.

**Three entries to get one table.** D116 measured the cycles and read a test
failure as a cost. D117 re-read the table and corrected the direction. D118
counted the checks and found the fannkuch half backwards in both. The measurement
that settled it -- compile twice, count branches to one label -- was available
throughout and takes under a minute. The lesson is not that the earlier entries
were careless with their numbers; their numbers were right. It is that all three
described a mechanism no one had counted, and a count would have replaced the
argument each time.

## D119 — session state after D84-D118

Thirty-five entries, contiguous, no gaps. The tree is green at 8589 checks / 0
failures / 59 suites and clean; 127 of 137 beads are closed.

**What shipped:** hardware counters through a KVM guest (D85), `gconst.ss` (D88),
tail-call frame reuse (D97, D98), two latent wrong-code bugs fixed in
`fold-immediates` (D99, D100), runtime clobber sets (D106), and a layout-pad
control (D105).

**What was measured and declined:** strength reduction (D84, unsound), packed
divides (D91, gcc does not), hoisted globals (D93, one cycle in 3847), the
copy fold (D100, 0.001%), argument-register hints (D107, never fire), branch
inversion (D111, 3.2% fewer instructions and 3.5% slower).

**What is waiting on Nathan:** M5's accuracy trade (`qaq.7`, flagged via
`bd human`), and now the unrolling decision -- 0.17% of nbody's time for 5.6% of
fannkuch's (`qaq.30`).

**The one thing to carry forward.** Four separate optimisations in this session
removed real work from fannkuch and made it slower or left it unchanged, and the
reason turned out to be the same each time: 25.2% of its cycles are front-end
stalled on branch mispredicts (D112), and every one of those changes moved code
or branches. nbody is the opposite -- 0.5% front-end stalled, 85.65%
dependency-bound (D90) -- and instruction counts predict nothing on either. The
methodology entries (D94's noise floor, D105's 4.97% alignment sensitivity) exist
because I measured wrongly first and had to correct the record; they are in
LOOP.md now so the next session starts where this one ended rather than where it
began.

## D120 — auditing the queue against the bottlenecks, and finding most of it aimed elsewhere

D112 established what each benchmark is limited by, and D111 established what
that implies. Applying both to the open queue rather than to one bead at a time:

```
fannkuch   25.2% of cycles front-end stalled on mispredicts (D112)
           removing 863M instructions and 861M branches cost 3.5% wall clock (D111)
nbody      85.65% register dependencies (D90)
           removing 465M instructions cost 18M cycles (D89)
```

**Instruction count does not convert to time on either benchmark.** Five open
beads had payoffs stated purely in instructions:

- `qaq.15` EFLAGS liveness, to make `lea` legal -- 6 collapsible pairs
- `qaq.18` a dead materialisation in nbody's loop header
- `qaq.21` 130 register-to-register moves, 86 coalescable
- `qaq.23` callee-saved registers, to reduce spills
- `qaq.26` three dead constant stores in fannkuch's hottest block

Each is real, each is correctly diagnosed, and none has a demonstrated path to
time. All five moved to P4 with the audit recorded on them, so a later session
reads the caveat before spending on the work rather than after.

**Two beads do target a measured bottleneck**, and it is worth being explicit
about why they are different in kind:

- `qaq.29` -- the four duplicated reversal functions. Merging them removes branch
  TARGETS, which is what the front end is stalling on, not just instructions.
- `qaq.30` -- unroll only where it discharges checks. The same mechanism, and it
  is not a prediction: 5.6% is measured, layout-swept, ranges non-overlapping.

**What nothing in the queue targets.** nbody's 85.65% is a dependency chain
through `sqrt` and `divide`; D92 measured the only known lever (reciprocal
approximation) as a loss on the latency axis at every Newton step count that
preserves accuracy. fannkuch's 25.2% is mispredict recovery on data-dependent
permutation branches. Neither has an open bead, because after D84-D118 neither
has a candidate that survives measurement.

That is the honest standing: **both benchmarks are at or near the limit of what
this compiler can reach without an accuracy trade (`qaq.7`) or a policy change
(`qaq.30`)**, and the remaining engineering work is worth doing for its own sake
rather than for a number. Saying so in the ledger is cheaper than a future
session rediscovering it one bead at a time, which is what D102, D107 and D108
each cost.
