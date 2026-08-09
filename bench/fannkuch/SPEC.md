# fannkuch-redux specification

Every variant is written **against this document**, not ported from another variant. That
rule exists in `bench/nbody/SPEC.md` because floating-point addition is not associative and a
reordered accumulation breaks cross-agreement. It matters here for a different reason: this
program's answer depends on the ORDER permutations are generated in, so a variant that
enumerates them differently gets a different checksum while looking correct.

`ref.c` in this directory is the executable form of this specification.

## Why this program is in the matrix

nbody is floating point in flat arrays with a loop nest whose trip counts are known. It says
nothing about the two things this one is here to measure:

- **Bounds checks on a computed index.** Every access here is `v[i]` where `i` came from
  arithmetic or from another element, which is the case an interval domain has to actually
  work on. nbody's indices are `3i+k` off a proven-length vector and elide trivially.
- **Integer work.** nbody's integer instructions are loop control. Here they are the program.

## The algorithm

For `n`, enumerate every permutation of `0 .. n-1` in the order given below. For each one,
count its **flips**: while the first element `k` is not `0`, reverse the first `k+1`
elements, counting one flip each time. Report:

- `maxflips`, the largest flip count over all permutations
- `checksum`, the sum over permutations of `+flips` for even-numbered permutations and
  `-flips` for odd-numbered ones, numbering from zero

**The enumeration order is part of the specification**, because the checksum depends on
which permutation is numbered even. It is the rotating order the reference uses, not
lexicographic:

```
r := n
loop:
    while r != 1:  count[r-1] := r;  r := r - 1
    take the current permutation, count its flips, accumulate
    repeat:
        if r == n: stop
        rotate perm1[0..r] left by one   -- perm1[0] moves to perm1[r]
        count[r] := count[r] - 1
        if count[r] > 0: break
        r := r + 1
```

`perm1` starts as the identity `0, 1, ... n-1`. The permutation whose flips are counted is a
COPY of `perm1`; the flipping is destructive and `perm1` must survive it.

## The oracle

| n | checksum | maxflips |
|---|---:|---:|
| 7 | 228 | 16 |
| 8 | 1616 | 22 |

`n = 7` is the size the variants run, small enough that the whole matrix finishes quickly
and large enough that the flip loop is the hot code.

## Output

Two values, `checksum` then `maxflips`, in that order.

Every variant writes them as **raw IEEE binary64 bytes**, eight per value, exactly as
`bench/nbody`'s variants write energies -- see `sonic/src/sonic/runtime.ss` on why that is
the right thing for an oracle. They are integers mathematically and are converted for
output; both fit binary64 exactly, so nothing is lost and the comparison stays bit-for-bit.
