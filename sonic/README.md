# SonicScheme

An optimizing Scheme compiler. Phase 7 of the parent project.

## Why this exists, in one paragraph of measured fact

Phases 1, 3 and 4 measured what the Scheme standards actually cost. Holding storage
constant and flipping only Chez's check policy is a **4.77x** difference; unboxing with
checks on is **1.12x**. Predicate guards at `optimize-level 2` recover **nothing**, because
`cptypes` had already narrowed the types unaided. So the entire residual is **bounds
checking**, and bounds checking is exactly what Chez's `cptypes-lattice.ss` cannot reason
about: it is a level-1 lattice of categories in which `index`, `length` and `sub-index` all
collapse to `fixnum-pred`, so `i is in [0,35)` is not a representable fact.

That is not a configuration problem and no macro reaches it. It is why there is a compiler
here.

The target is **Ada's 1.13x scalar C**, reached with scoped, named check suppression, by
building the abstract domain that makes elision *provable* rather than asserted. Phase 4
established that Ada gets there while staying fully standard, and that named per-check
suppression costs exactly nothing against `Suppress (All_Checks)`.

## Status

| stage | what | state |
|---|---|---|
| 01-04 | reader, expander, surface-to-core, A-normalization | **working** |
| 04b-c | inlining, assignment conversion | **working** |
| 05-06 | interval domain, e-SSA, ABCD, check elision | **working** |
| 07-08 | loops and trip counts, representation selection | **working** |
| 09 | alias analysis, escape analysis | **working** |
| 10 | vectorization | legality in progress; emission not started |
| 11-13 | selection, allocation, encoding, ELF | **working**, both targets |
| runtime | numeric tower, primitives, allocator, collector, barrier | **working** |
| policy | lexical named check suppression, `fp-contract` | **working** |

**40 test suites, all green.** `make test` runs them.

### What actually runs, end to end

`bench/nbody/config-sonic.sps` — a real nbody in SonicScheme's surface syntax, verified
bit-exact against `config2a.sps` and against `SPEC.md` — goes through **eleven stages**:

```
read → expand → parse → policy → anf → assign → inline → essa → elide → repr → lower
```

and comes out as a 16-block `Lmach` CFG. On the way:

| measurement | value |
|---|---|
| checks **proved** by the analysis | **50** |
| checks kept | 177 |
| checks suppressed by policy | **0** |
| bindings unboxed as `raw-f64` | 152 |
| bindings unboxed as `raw-word` | 143 |
| bindings `tagged` | 27 |

Every one of the 50 is a *proof*, not a permission — `lower.ss` counts the two apart
precisely so that claim can be made honestly.

The back end emits real objects for both targets. SonicScheme's own RV64 output,
disassembled by `riscv64-linux-gnu-objdump`:

```
addi t0,zero,7 / mul a2,a1,t0 / add a3,a2,a4
slli t1,a3,0x3 / add t1,a0,t1 / fld fa0,0(t1) / jalr zero,0(ra)
```

63 x86-64 instructions and 68 RV64 instructions are verified **byte-identical against the
real assembler**, not against our own expectations.

### What does not work yet

A multi-argument call. `Lmach`'s `call` has no fixed arity and neither selector lowers it
into argument moves plus a jump, so the whole lowered program stops at selection. The
calling convention exists and precoloring exists; nothing joins them to the selector. That
is the last gap before milestone 1.

Tail calls currently lower to ordinary calls, which loses the one performance guarantee
R5RS made that ANSI CL never did. Tracked with the above.

## What the domain does

```
$ scheme -q --libdirs src --script test/interval-test.ss
soundness, exhaustive over [-4,4] x [-4,4]:
  add done
  sub done
  mul done

6101 checks, 0 failures
PASS
```

The test that matters is **soundness**, not the lattice laws. A domain can satisfy every
lattice law and still be wrong; what makes it a sound abstraction is Cousot's local
consistency condition, that the abstract operation over-approximates the concrete one:

```
for all x in gamma(a), y in gamma(b):  f(x,y) must be in gamma(f#(a,b))
```

Checked by exhaustive concretization over every interval pair in [-4,4]², which for this
domain is a proof over the tested range rather than a sample.

And the query the whole file exists to answer, on nbody's real access pattern
`b[i*7 + k]` with `i` in [0,4], `k` in [0,6], against an `flvector` of length 35:

```scheme
(let* ((i (iv-range 0 4))
       (k (iv-range 0 6))
       (off (iv-add (iv-mul i (iv-const 7)) k)))
  (iv-within? off (iv-const 35)))     ;; => #t, the check is dead
```

It refuses correctly too: an unknown index, an index that can go negative, an index that
can reach `len`, and an index checked against an unknown length are all non-eliminable.

## What the analyzer does

`src/sonic/analyze.ss` runs the domain over a core-language program to a fixpoint with
widening, and reports one verdict per vector reference.

```
$ make test
bounds check elision:
  ok   loop 0..34 over length-35 vector  -> (#t)
  ok   loop 0..35 over length-35 vector is NOT safe  -> (#f)
  ok   unknown vector length  -> (#f)
  ok   loop -1..34 is NOT safe  -> (#f)
  ok   nbody b[i*7+k], nested loops  -> (#f)
  ok   nbody b[i*7+k] with the stride bound  -> (#t)
  ok   guarded by (< i n) and (>= i 0)  -> (#t)
  ok   guarded by (< i n) only  -> (#f)
  ok   mixed: first safe, second not  -> (#t #f)
  ok   index derived through two primops, still provable  -> (#t)
  ok   derived index that overruns is refused  -> (#f)

11 cases, 0 failures
```

Nested loops with a strided index, which is nbody's real access pattern, prove out:
`b[i*7+k]` with `i` in [0,5) and `k` in [0,7) against a length-35 vector gives [0,34] and
the check is deleted. **That is the exact access Chez cannot prove**, because its lattice
collapses `index`, `length` and `sub-index` into one category.

The refusals matter as much. An analysis that says yes to everything is not an analysis,
and the "mixed" case exists specifically to catch one that collapses all references into a
single verdict.

**Known gap: widening termination is not exercised at program level.** The core language is
pure and has no loop-carried state, so no program in it can produce a divergent fixpoint.
`interval-test.ss` tests the widening operator directly, including a termination loop, but
the program-level test has to wait for mutable variables. One test case in
`analyze-test.ss` was originally written expecting a refusal on that theory and the
analyzer was right; the comment there records it.

## Notes for whoever touches this next

**Chez does not promise an application order for `map`, or an evaluation order for
`let` bindings.** A stateful counter threaded through either is order-dependent, and this
tree is full of `(map fresh-name x*)`. The symptom is not a wrong program — the names are
fresh either way — it is that the same input compiles to differently-named IR between runs,
which makes name-asserting tests flaky and breaks the differential harness that diffs two
builds of one program. `essa.ss` defines `map/lr` for this and uses it wherever the mapped
function has an effect. Reach for it rather than `map` when the function mutates anything.

**`iv-widen` takes `(old new)`.** Applying it backwards yields a sequence that looks
convergent whenever the iterates increase monotonically, and is unsound in general. That is
the bug printed in Figure 3 of the Pentagons paper, in both halves, and it is masked by
precisely the naive monotone test suite a reader would write. There are explicit
direction-pinning tests.

**Bounds are exact integers or the symbols `neginf` / `posinf`.** Not `-inf` and `+inf`,
which are not legal R6RS symbols: the reader treats a leading sign as a number prefix and
rejects them in `#!r6rs` mode. Exact integers rather than flonums because an index domain
that cannot represent a bound exactly is not sound, and Scheme gives us bignums free.

**`iv-mul` computes all four corner products.** Taking `lo*lo` and `hi*hi` is the classic
interval-multiply bug and the exhaustive soundness test catches it immediately.

**Pentagon, not Octagon**, when the relational layer lands. See `LEDGER.md` D6: closure
made Pentagons *less* precise on three of four .NET assemblies while tripling analysis
time, and Pentagon's `Sub` has no closure so Miné's infinite-chain widening hazard cannot
arise.
