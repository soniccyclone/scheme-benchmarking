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
