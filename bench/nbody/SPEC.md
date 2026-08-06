# nbody specification

Every variant in the experiment matrix is written **against this document**, not ported
from another variant. Porting is how expression order silently diverges, and floating-point
addition is not associative, so a reordered accumulation changes the low digits and breaks
cross-agreement for reasons that have nothing to do with the compiler under test.

`ref.c` in this directory is the executable form of this specification. It is the reference,
not a competitor; configuration 6 is built from it with the two flag sets.

## The system

Five bodies: the Sun, Jupiter, Saturn, Uranus, Neptune. Units are AU, solar masses, and
days. Two derived constants:

```
PI            = 3.141592653589793
SOLAR_MASS    = 4 * PI * PI
DAYS_PER_YEAR = 365.24
DT            = 0.01
```

Initial state. Velocities as given are per day and **must be multiplied by
`DAYS_PER_YEAR`**; masses as given are in solar masses and **must be multiplied by
`SOLAR_MASS`**. The Sun starts at the origin at rest.

| body | x | y | z |
|---|---|---|---|
| Sun | 0.0 | 0.0 | 0.0 |
| Jupiter | 4.84143144246472090e+00 | -1.16032004402742839e+00 | -1.03622044471123109e-01 |
| Saturn | 8.34336671824457987e+00 | 4.12479856412430479e+00 | -4.03523417114321381e-01 |
| Uranus | 1.28943695621391310e+01 | -1.51111514016986312e+01 | -2.23307578892655734e-01 |
| Neptune | 1.53796971148509165e+01 | -2.59193146099879641e+01 | 1.79258772950371181e-01 |

| body | vx | vy | vz | mass |
|---|---|---|---|---|
| Sun | 0.0 | 0.0 | 0.0 | 1.0 |
| Jupiter | 1.66007664274403694e-03 | 7.69901118419740425e-03 | -6.90460016972063023e-05 | 9.54791938424326609e-04 |
| Saturn | -2.76742510726862411e-03 | 4.99852801234917238e-03 | 2.30417297573763929e-05 | 2.85885980666130812e-04 |
| Uranus | 2.96460137564761618e-03 | 2.37847173959480950e-03 | -2.96589568540237556e-05 | 4.36624404335156298e-05 |
| Neptune | 2.68067772490389322e-03 | 1.62824170038242295e-03 | -9.51592254519715870e-05 | 5.15138902046611451e-05 |

## Procedure

**1. Offset momentum, once, before anything else.** Sum `v * mass` over all five bodies
componentwise, then set the Sun's velocity to the negated sum divided by `SOLAR_MASS`.
This puts the barycentre at rest. Skipping it still conserves energy but reports a
different value, so it is part of the specification rather than an optimization.

**2. Print the total energy** to nine decimal places.

**3. Advance N times** by `DT`.

**4. Print the total energy** again, to nine decimal places.

## `advance`, and why the two loops must not be fused

```
for i in 0..4:
    for j in i+1..4:
        dx, dy, dz  =  p[i] - p[j]              componentwise
        d2          =  dx*dx + dy*dy + dz*dz
        mag         =  dt / (d2 * sqrt(d2))
        v[i]       -=  d * mass[j] * mag        componentwise
        v[j]       +=  d * mass[i] * mag        componentwise

for i in 0..4:
    p[i] += dt * v[i]                           componentwise
```

This is **symplectic Euler**: every velocity is updated from the pairwise forces at the
*current* positions, and only then does any position move. First order, and symplectic.

Fusing the position update into the pair loop would make it a non-symplectic scheme whose
energy error accumulates monotonically instead of oscillating. That is the single most
likely way a variant passes a casual eyeball check and fails the oracle, so it gets called
out here rather than left to reviewers.

Ten unordered pairs, evaluated in the order (0,1) (0,2) (0,3) (0,4) (1,2) (1,3) (1,4)
(2,3) (2,4) (3,4).

## `energy`

```
e = 0
for i in 0..4:
    e += 0.5 * mass[i] * (vx[i]^2 + vy[i]^2 + vz[i]^2)
    for j in i+1..4:
        e -= (mass[i] * mass[j]) / sqrt(dx^2 + dy^2 + dz^2)
return e
```

The kinetic term for body `i` is added **before** the potential terms for that body's
pairs. This interleaving is load-bearing for bit-exact agreement; accumulating all kinetic
energy first and all potential energy second gives a different last digit.

## Expected output

Verified by running `ref.c`, and matching the published values for these initial
conditions.

| N | energy after N steps |
|---|---|
| 0 | `-0.169075164` |
| 1,000 | `-0.169087605` |
| 100,000 | `-0.169079859` |
| 1,000,000 | `-0.169086185` |
| 10,000,000 | `-0.169077842` |
| 50,000,000 | `-0.169059907` |

Step 0 is `-0.169075164` for every N, which is the cheapest possible smoke test.

**The drift is bounded and oscillating, not monotonic**, which is the signature of a
symplectic integrator and is oracle check 1 in `../../docs/METHOD.md`. A variant whose
energy walks steadily away from `-0.16907` has fused the loops or reordered the update.

## Reference instruction counts

`gcc -O2 -fno-tree-vectorize`, measured with `perf stat -e instructions:u`:

| N | instructions | delta | per step |
|---|---|---|---|
| 1,000,000 | 654,127,755 | | |
| 2,000,000 | 1,308,127,776 | 654,000,021 | 654.000021 |
| 4,000,000 | 2,616,127,877 | 1,308,000,101 | 654.000050 |
| 8,000,000 | 5,232,128,075 | 2,616,000,198 | 654.000050 |

**654 instructions per step** with about 127,700 of constant startup. Deterministic to five
significant figures across an 8x range, which is why `LEDGER.md` D17 makes retired
instructions the primary instrument for check elision rather than wall time. Every other
configuration's per-step count is directly comparable to this one, and a removed bounds
check is a removed compare-and-branch.

## Dev sizes

N = 1,000,000 and 2,000,000, per `../../docs/METHOD.md`. Two sizes so the slope cancels
process startup, which ranges from about 1 ms to about 200 ms across the runtimes in the
matrix and would otherwise dominate at dev scale. The C baseline at N = 1,000,000 is about
37 ms, so a full sweep is seconds.

## Variants that cannot match exactly

Recorded here as they appear, with the reason:

- **Stalin** targets R4RS. The port loses `define-record-type` and bytevectors, so the
  body representation changes. Expression order must still be preserved.
- **Ada** has its own `Float` semantics and aggregate handling to check against this.
