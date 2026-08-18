# The plan the loop follows

Read this at the start of every autonomous iteration, then `bd ready`. It exists
because a loop that re-derives its priorities each time it wakes will drift, and
because the ordering below is not obvious from the bead graph alone.

Nathan set this running and is not watching each iteration. That is the whole
reason for the boundaries in the last section: the cost of a wrong call is not a
wasted hour, it is a wrong number in the ledger that later work is built on.

---

## Where the project actually stands

Slope of N=1,000,000 to 2,000,000, **40 reps**, bootstrap CI, baseline sonic:

| config | ns/step | ratio vs sonic | verdict |
|---|---|---|---|
| **sonic** | **65.03** | — | baseline |
| c-native (`gcc -O3 -march=native`) | 56.88 | 0.8746, CI [0.8288, 0.9464] | **real** |
| c-scalar | 62.77 | 0.9653, CI [0.8932, 1.0352] | no detected difference |
| sbcl-5 | 374.95 | 0.1709, CI [0.1552, 0.1843] | **real** (sonic 5.85x ahead) |

REP COUNT IS LOAD-BEARING AND 15 IS NOT ENOUGH. The same c-native comparison at
15 reps gave CI [0.8011, 1.0024] — an interval containing 1.0, i.e. no detected
difference. At 40 it is [0.8288, 0.9464] and real. Any claim about the gap to C
needs 40; a table of min-of-N wall clock at one N, which is what this section
used to hold, is not a result at all.

This table names its own baseline, which the script that produced it did not:
`bench.sh` printed `BASELINE` in the header and divided by whichever config
measured first (D70), and `measure.sh` had the same bug under a `vs-C` heading
(D69). Both compute the label from the divisor now. When re-measuring, check that
the row marked `(baseline)` is the row the header names — that mismatch is the
only thing that gave either bug away.

**Instructions, and they now agree with wall clock.** sonic retires 664.00
instructions/step against c-scalar's 654.00 — **1.02x**, not the parity-or-better
the mislabelled column implied. Wall clock says the same thing: ratio 1.0507, CI
[0.9926, 1.0979], no detected difference. Two instruments telling one story about
where we stand against C is new as of D69/D70.

Two things fall out and they set the order of everything below. **Milestone 3 is
MET AND CLOSED**, both arms: 5.95x on wall clock (CI [0.1630, 0.1829]) and 3.16x
fewer instructions, the latter with both sides forced onto qemu so the comparison
is single-instrument (D68). And sonic is at PARITY with
scalar C while 1.14x behind `gcc -O3 -march=native`.

**THE GAP TO M5 IS FMA, NOT VECTORIZATION — this section said the opposite for a
long time and sent four routes' worth of work the wrong way (D79).** Counted from
the emitted binaries:

```
sonic        scalar=161  packed=36  fma=0
ref-native   scalar=175  packed=25  fma=81
```

We already emit MORE packed arithmetic than c-native does, and c-native uses no
256-bit at all — 748 xmm, zero ymm, zero zmm; its EVEX encodings buy xmm16-31
for spills, not width. What it has and stock sonic has none of is 81 fused
multiply-adds. `contract.ss` can produce them and is wired in; `fp-contract` is
a permission defaulting to OFF (D24) that the benchmark never granted, while
gcc -O3 takes `-ffp-contract=fast` by default. See the `sonic-fma` configuration.

That is not idle advice: raising the unroller's growth budget was tried and
measured, unrolls hard (902 instructions to 1734, packed functions 5 to 17), and
is NOT faster — ratio 1.0023, CI [0.8708, 1.1030]. It is kept as the `sonic-u4`
configuration so the negative result stays measurable.

fannkuch stands at roughly 1.2x behind gcc (D57), and instructions retired are
2.51x at n=11 (D60). That gap is instructions, not scheduling, which is the
opposite of nbody's diagnosis (D37).

---

## The queue, in dependency order

107 of 115 closed. **Everything that remains needs a decision from Nathan.**
E1, E2, E4, E6-M3 and E7 are closed; every pass in the tree has a test; the
audit below has been run to exhaustion.

All six decision beads carry the `human` label, so `bd human list` shows them
directly rather than requiring a dig through notes. Each one is posed with its
evidence gathered and its cost sized — none is waiting on more measurement.

### Waiting on Nathan — do not decide these autonomously

**`1mp.5` / `1mp.4` — how four lanes become reachable. ALL FOUR ROUTES ARE NOW
CHARACTERISED; the decision is which of two NEW options to take, or neither.**

Measured (D73): enabling the existing `four-lane-packing?` arm on the stock
layout emits **zero** 256-bit instructions at any unroll budget.

```
sonic (stock, four-lane off)       xmm=484    ymm=0
sonic-v4-16 (four-lane, budget 16) xmm=3027   ymm=0   results bit-identical
sonic-pad4  (padded layout)        xmm=455    ymm=18
```

Adjacency was never the shortage — four-lane packs DO seed (7 at budget 4, 45 at
16), and die in `classify!`, where `same-op?` needs all four values from one
packable op. The force loop mixes `sub` and `add` for the same pair by Newton's
third law, so the pack is a `gather` and `narrow!` correctly refuses it four
wide. Both the classification and the demotion are right.

| route | status |
|---|---|
| 1. padded layout | BUILT, emits 18 ymm, **1.60x slower** |
| 2. offset-table adjacency | BUILT, never fires, reverted — solved a non-problem |
| 3. Lmach from an SSA kernel | BLOCKED on name correspondence |
| 4. affine analysis at Lmach | shown by D73 to be aimed at the wrong gap |

Route 4 was the one D67 left standing as "architecturally coherent". It proves
more adjacency, and adjacency is already found, so it does not help.

**What the evidence leaves open**, and neither is on the original route list:
  (a) teach `classify!` and emission to treat a MIXED add/sub pack as one
      operation — an `addsubpd`-style form, or a negated-operand rewrite;
  (b) accept the layout change, which is route 1 and is measured slower.

(a) is the only path to 256-bit on the unmodified benchmark. It is a real change
to a shipping pass and its payoff is unknown, so it is Nathan's call, not the
loop's.

**`1mp.6` — the driver has no RV64 target path.** Filed this session while
checking whether M4 could close. `compile-sonic` hardcodes `'x86-64` at every
stage and takes no target argument, so **no Scheme program has ever been compiled
to RV64**. What exists is an ENCODER target: `rv64-selector` is a full 588-line
backend, and `regs`/`finalize`/`object` all handle rv64, exercised by
`rv64-test.ss` and a smoke gate that reads our own output back through
`riscv64-linux-gnu-objdump` — but on a HAND-WRITTEN body passed to
`assemble-function`. So every "tested on both targets" claim means the back-end
machinery is tested on both targets.

Missing: the runtime entry listing, an `EM_RISCV` image in `elfexec.ss`
(`e_machine` is hardcoded `0x3e`), and a driver target argument. Both code-level
gaps refuse LOUDLY, which is why this was never a live hazard. D76: the old
justification — "an RV64 runtime written blind would be validated by nothing" —
expired when the container gained qemu-riscv64 for instruction counting.

**`xei` (E3) — the acceptance names an artifact that does not exist**, a
hand-written core fixture. parse-test.ss does something stronger and passes.
Reword or add the fixture.

**`qaq.6` (M4) / `qaq.7` (M5) — the gates.** M4 must NOT close on
vectorize-test.ss passing: that assertion runs on a kernel that never ships. M5's
instruction comparison needs a reword regardless, because c-native emits AVX-512
and NEITHER instrument can count it — callgrind cannot decode it and QEMU's TCG
does not implement it.

### Actionable without a decision

**Nothing.** This was worked to exhaustion over eight loop iterations. What that
consumed, so it is not re-run:

- every open bead audited individually (that is what found `qaq.6`'s criterion
  testing gcc rather than us, and `1mp.6` as an untracked gap)
- the instrument disagreement chased to root cause (D68→D72)
- both baseline bugs found and fixed (D69, D70)
- the four-lane route table completed by measurement (D73)
- a sweep for EXPIRED PREMISES — claims true when written and falsified by an
  unrelated change. Three found and fixed: D74, D76, and `analyze.ss`'s "there
  is no reader". Everything else checked out.
- a sweep of every doc for stale standing numbers after D69/D70 changed them.
  Clean — no user-facing doc carried a wrong claim.

**`1mp.6` — the RV64 driver gap** (filed this session) is the one bead that is
*work* rather than a wording call, and it is still not the loop's to take:
writing an entry sequence and ELF writer for a second architecture is a feature,
and which target this project spends time on is a priorities question. It is
well-posed now — see D76: the hard parts (selection, allocation, encoding,
object emission) all exist, only the runtime listing, an `EM_RISCV` image, and a
driver target argument are missing, and the container's qemu-riscv64 means the
result can be validated by running it.

## Definition of done, per kind of bead

An **assertion milestone** (M2, M4, M6) is done when the assertion lives in the
suite and fails if the property regresses. Prove it can fail — `differential-test.ss`
spends most of its length proving its own oracle can fail, and that is the
standard here. An assertion that cannot fail proves nothing.

A **performance milestone** (M3, M5) is done when the bootstrap CI excludes 1.0
and the numbers are in the ledger with the N, the repetition count, and which
instrument produced them. Wall clock and instructions retired are different
claims; never let one stand in for the other.

An **implementation bead** is done when the suite, the smoke gate and the
containment gate are all green and the change has a ledger entry if it involved
a decision.

---

## Measuring anything

**Do not edit a script while a long measurement is running it.** The container
mounts the repo live and every harness script re-execs into it, so a script is
read from disk as the job runs. Editing `measure.sh`'s header mid-run killed a
20-minute sbcl-under-qemu measurement with `unexpected EOF while looking for
matching quote` — a syntax error in a file that was syntactically fine both
before and after. Queue the edit, or let the run finish.


Three instruments, and which one you may use is not a free choice.

**Wall clock** — `harness/bench.sh`. Slope between two N, bootstrap CI. USE 40
REPS, not 15: the c-native comparison at 15 gives an interval containing 1.0 and
at 40 gives [0.8288, 0.9464]. A min-of-N at a single N is not a result and D57 is
the entry about why.

**Instructions per step** — `harness/measure.sh`, which drives
`harness/count-slope.sh`. It picks callgrind first (every instruction figure in
the ledger came from it), falls back to `harness/qemu-count.sh` for the
managed-runtime Lisps callgrind crashes on, reports WHICH instrument answered,
and refuses rather than printing a number for a broken run.

**Never quote a single instruction count.** Ask for a slope. Two equal counts
have zero slope, and that is the only check that has ever caught a broken
measurement here — callgrind prints a total alongside "unhandled instruction",
QEMU sums a log up to an "uncaught target signal", and clisp's log stops early
because it re-executes itself. Three plausible wrong numbers, all found by the
count not changing when the work changed, none by anything else. D63.

What cannot be counted on this host at all: **c-native** (`-march=native` emits
AVX-512; neither valgrind's VEX nor QEMU's TCG decodes it) and **clisp-9**.
racket and ecl produce a count but cannot be validated — the two-N check does not
finish. c-native being uncountable is why Milestone 5's instruction comparison
needs rewording rather than an instrument.

---

## Before closing ANYTHING

```
make -C sonic test        # the suite
make smoke                # the RISC-V gate
make containment          # the limits still hold
```

All three, every time a bead closes. The image and the harness both changed
underneath this project twice this month; the gates are what noticed.

---

## Filing new beads

Expect to file more than you close for a while — optimization runs produce
findings, and a finding recorded is worth more than a finding acted on
immediately and forgotten.

- A finding that is not the bead you are on becomes a NEW bead. Do not widen
  scope to absorb it.
- Put the measurement in the bead. "count-flips is 22.7% of fannkuch" is a bead;
  "count-flips looks slow" is not.
- Convert relative dates to absolute, and name the instrument (callgrind Ir,
  wall clock min-of-N) so a later reader knows what the number means.
- If a finding contradicts a ratified decision, file it and STOP. Do not
  re-litigate a D-numbered decision autonomously.

## Ledger discipline

Every decision gets a D-numbered entry in `docs/LEDGER.md`, newest last, next
number after the highest present (D61 as of writing). Record what was decided,
what was measured, and what was rejected and why. Entries that record a REJECTED
approach have paid for themselves repeatedly this month — three of the perf
entries exist only to stop the next agent re-testing the same dead flags.

---

## THE FAILURE MODE THIS PROJECT KEEPS PRODUCING

A check that silently stops checking looks exactly like a check that passes.
Five instances, all found by going and looking, none by anything failing:

| | |
|---|---|
| `deploy.resources.limits.memory` | parses, validates, ignored outside Swarm (D30) |
| `timeout --signal=KILL` | uutils accepts it and never delivers the signal |
| `command -v scheme` | smoke gate skipped its compile and exited GREEN (D58) |
| `N=11 REPS=9` | never crossed the container boundary; defaults used silently (D60) |
| ten nbody configs | toolchains absent, oracle quietly ran on 9 of 19 (D61) |
| `[n rejected as parallel]` | `REJECTED` set in a subshell; note always empty (D71) |
| `vs-C` / `baseline %s` | header named one config, arithmetic used another (D69, D70) |

So: when a gate passes, occasionally ask what it would take for it to fail, and
check that that is still possible. When adding a gate, make it fail once on
purpose before trusting it. This is the single highest-value habit on this
project and it has paid out seven times now.

**A guard whose failure path cannot be reached is not a guard.** `bench.sh`'s
serial-only threshold was hard-coded at 1.3, which a single-threaded nbody never
reaches — so the reject-and-report path could not be exercised at all, and that
is exactly why the broken note above survived. It is a parameter now
(`PARALLEL_MAX`) *so that it can be made to fail*. Prefer a threshold you can
inject over one you have to trust.

**A label and its arithmetic drift apart unless one is computed from the other.**
Both baseline bugs had the same shape: a name printed in a header, and a divisor
picked independently by the code. Neither number was wrong — they just were not
the numbers the columns claimed. Compute the label FROM the thing it labels, and
refuse rather than fall back when the named thing is missing; a fallback is what
lets the two disagree quietly.

### Values crossing a `$( )` boundary travel in stdout, never in a variable

Six occurrences now: `measure.sh` COUNTER, `count-slope.sh` INSTRUMENT,
`bench.sh` rc, FAILED_WHY, and REJECTED, plus two preflight checks that had to
move to the main shell. A function invoked as `x=$(f)` runs in a subshell, so
every assignment it makes is discarded the moment it returns — silently, with the
caller reading a default that looks plausible. In these scripts, if the caller
needs it, **print it**; `count-slope.sh` returning `count<TAB>instrument` is the
pattern to copy.

---

## Autonomy boundaries

**Do freely.** Read anything. Run the suite, the gates, the harnesses, the
benchmarks. Implement beads that are ready. File beads. Write ledger entries.
Commit straight to `main` — Nathan asked for that explicitly, no branch, no PR.

**Never.** Push, PR, or send anything to a remote Nathan does not own — the hard
rule in `CLAUDE.md`, and `sonic/vendor/nanopass` is somebody else's project.
Run anything outside the container. Add a second way to run things. Use sudo.
Weaken, delete or loosen a test, an assertion or an oracle to make something
pass.

**DECIDE, as of 2026-08-18.** Nathan's instruction: "make as many decisions on
your own as possible since creating this more performant scheme is all obvious
optimizations and capabilities we are adding." That supersedes the
waiting-on-Nathan set below for ACCEPTANCE WORDING and ROUTE CHOICE. Record the
decision and its reasoning in the ledger, and make it reversible.

It does NOT supersede the two rules under **Never**, and the distinction is the
one that matters: rewording an acceptance to describe what is ACTUALLY VERIFIED
is a decision; rewording it so a weaker check passes is weakening a gate. If a
reword would lower the bar, the honest move is to say the milestone is unmet.

**Stop and ask.** Anything that changes what a number MEANS: the oracle, the
measurement methodology, the benchmark set, the reported N. Reversing a
D-numbered decision. Suppressing a check to gain speed — that needs a named,
lexically-scoped permission per D5 and D24, and adding a new permission is
Nathan's call. Any change to `bench/*/SPEC.md` or `docs/METHOD.md`.

**When the ready queue is empty**, do not invent work. Do the epic-hygiene audit
above, then the E5 decomposition audit, then report that the queue is dry and
what would unblock it. A loop that manufactures tasks to look busy is worse than
one that idles.
