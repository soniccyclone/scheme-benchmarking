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
| 06 | interval abstract domain | **working, 6101 checks passing** |
| 01-05 | reader, expander, core language, A-normalization, CFG | not started |
| 07-09 | e-SSA, ABCD, check elision | not started |
| 10 | vectorization | not started |
| 11-13 | instruction selection, register allocation, x86-64 emission | not started |

Nothing here compiles a program yet. `src/sonic/interval.ss` is the analysis core, built
first because it is the part the measurements proved is load-bearing and the part no
existing Scheme has.

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

## Notes for whoever touches this next

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
