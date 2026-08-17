# The plan the loop follows

Read this at the start of every autonomous iteration, then `bd ready`. It exists
because a loop that re-derives its priorities each time it wakes will drift, and
because the ordering below is not obvious from the bead graph alone.

Nathan set this running and is not watching each iteration. That is the whole
reason for the boundaries in the last section: the cost of a wrong call is not a
wasted hour, it is a wrong number in the ledger that later work is built on.

---

## Where the project actually stands

Measured 2026-08-17, nbody at N=5,000,000, min of three, in the container:

| config | time | against sonic |
|---|---|---|
| c-native (`gcc -O3 -march=native`) | 301 ms | sonic **1.11x behind** |
| c-scalar | 328 ms | sonic **1.02x** — parity |
| **sonic** | **335 ms** | — |
| chez-4 | 757 ms | sonic 2.26x ahead |
| sbcl-5 | 1903 ms | sonic **5.68x ahead** |
| ecl-9 | 56196 ms | — |

Two things fall out and they set the order of everything below. **Milestone 3
looks already met** and needs a bootstrap CI rather than any optimization work.
And sonic is at parity with SCALAR C while 11% behind vectorized C, which means
**the whole remaining gap to Milestone 5 is the vectorization gap** — E5, not
scalar tuning. Do not spend iterations shaving scalar code to reach M5; the
measurement says it is not there.

fannkuch stands at roughly 1.2x behind gcc (D57), and instructions retired are
2.51x at n=11 (D60). That gap is instructions, not scheduling, which is the
opposite of nbody's diagnosis (D37).

---

## The queue, in dependency order

Seven items are open: five milestones, one back-end bead, and epic hygiene.

### 1. `qaq.4` — Milestone 2: no bounds-check branch in the inner loop  (P1, READY)

Acceptance: *disassembly assertion passes*. A gate on Milestone 4, not a result.
`harness/disasm-sonic.sh` works and is the tool. The check-elision pass
(`cqs.3`) is closed, so the machinery is in place; this is verification, not
implementation. If the assertion fails, the finding is a bead against E4, not a
reason to weaken the assertion.

Assert it in the SUITE, not only by eye — a disassembly checked once by a human
is a check that stops checking the moment the code moves. `sonic/test/disasm-test.ss`
is where it belongs.

### 2. `qaq.5` — Milestone 3: beat tuned scalar SBCL  (P1)

Acceptance: *`harness/measure.sh` and `harness/bench.sh` both show SonicScheme
ahead of sbcl-5, with a bootstrap CI excluding 1.0.* The table above says the
margin is 5.68x, so the work is producing the CI properly, not finding speed.
`harness/bench.sh` drives `bootstrap.awk` for this. Run it, record the interval,
close it. If the CI does not exclude 1.0 at a 5.68x margin, distrust the harness
before believing the result.

Note `measure.sh` now counts INSTRUCTIONS via callgrind (D60), so its comparison
against sbcl-5 is instructions-per-step and deterministic; `bench.sh` is the
wall-clock arm. Both are required by the acceptance and they answer different
questions. Say which is which when recording the result.

### 3. `1mp` — E5: Vectorization  (P2, epic, HAS NO CHILDREN)

**This is the real work, and it is not decomposed yet.** The epic says two beads
sharing one legality analysis, not one bead with a flag, because AVX-512 is
fixed width while RVV is length-agnostic with the vector length a runtime value
the loop adapts to. Decompose it before implementing: file the legality
analysis, the x86-64 lowering, and the RV64 lowering as separate beads with the
dependency stated.

Much of this may already exist — `vectorize.ss`, `veclegal.ss`, `slp.ss`,
`vec-x86-64.ss` and `vec-rv64.ss` are all in the tree with passing tests, and
nbody already emits four-lane unmasked packed code (D59 found it does not even
use the three-lane path). So the first iteration on E5 is an AUDIT: establish
what exists against what the epic asks for, and file beads for the difference.
Do not assume the epic is untouched because it has no children.

### 4. `qaq.6` — Milestone 4: packed arithmetic in the inner loop  (P2)

Acceptance: *E6-DISASM packed-arithmetic assertion passes on x86-64 AND RV64.*
Both targets — that is D22's first-class-RISC-V claim being cashed, and the RV64
half is the one that will actually be missing. Depends on E5.

### 5. `qaq.7` — Milestone 5: beat gcc -O3 -march=native  (P2)

Acceptance: *`bench.sh` shows SonicScheme at or ahead of c-native with a
bootstrap CI excluding 1.0.* 11% away, and per the standing table that 11% is
vectorization. Depends on M4 in practice even where the bead graph does not say
so.

### 6. `qaq.8` — Milestone 6: Pentagon and loops carry fannkuchredux  (P3)

Acceptance: *fannkuchredux passes its oracle and its bounds checks are elided.*
The oracle arm already passes (`answers AGREE` at n=8, 9 and 11). The elision arm
is the open half. `pentagon-test.ss` and `loops-test.ss` are green, so this is
the same shape as M2: verify, assert in the suite, and file findings as beads.

### 7. `6gk.24` — tail call with stack arguments needs the frame layout pass  (P2)

Independent of the milestone chain; pick it up when the chain is blocked on
something that needs Nathan.

### Epic hygiene, do this first and it is cheap

`xei` (E3) and `cqs` (E4) have **no open children** and are still open. E1 was in
exactly that state and was blocking four epics for nothing. Check each one's
acceptance against the code the way E1's was checked — `fixtures.ss` and a test
importing only the contract, not the ledger's word for it — and close it if met.
`6cm` (E7) has no children at all and, like E5, needs decomposing or closing.

**Do not close an epic because its children are closed.** Verify the acceptance
criterion itself. That is how E1 was closed and it is the standard.

---

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

So: when a gate passes, occasionally ask what it would take for it to fail, and
check that that is still possible. When adding a gate, make it fail once on
purpose before trusting it. This is the single highest-value habit on this
project and it has paid out five times in one month.

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

**Stop and ask.** Anything that changes what a number MEANS: the oracle, the
measurement methodology, the benchmark set, the reported N. Reversing a
D-numbered decision. Suppressing a check to gain speed — that needs a named,
lexically-scoped permission per D5 and D24, and adding a new permission is
Nathan's call. Any change to `bench/*/SPEC.md` or `docs/METHOD.md`.

**When the ready queue is empty**, do not invent work. Do the epic-hygiene audit
above, then the E5 decomposition audit, then report that the queue is dry and
what would unblock it. A loop that manufactures tasks to look busy is worse than
one that idles.
