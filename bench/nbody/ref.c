/* nbody reference implementation.
 *
 * Written from the problem specification, not ported from any existing entry.
 * Its job is to pin the constants, the expression order, and the expected
 * energies that every other variant in the matrix is written against.
 * See SPEC.md in this directory, and ../../docs/METHOD.md for the oracle.
 *
 * Build: gcc -O2 -fno-tree-vectorize -o ref ref.c -lm
 * Run:   ./ref <steps>
 */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#define NBODY 5
#define PI 3.141592653589793
#define SOLAR_MASS (4.0 * PI * PI)
#define DAYS_PER_YEAR 365.24
#define DT 0.01

struct body { double x, y, z, vx, vy, vz, mass; };

static struct body bodies[NBODY] = {
    /* Sun. Velocity is corrected by offset_momentum before the first step. */
    { 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS },
    /* Jupiter */
    {  4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
       1.66007664274403694e-03 * DAYS_PER_YEAR,
       7.69901118419740425e-03 * DAYS_PER_YEAR,
      -6.90460016972063023e-05 * DAYS_PER_YEAR,
       9.54791938424326609e-04 * SOLAR_MASS },
    /* Saturn */
    {  8.34336671824457987e+00,  4.12479856412430479e+00, -4.03523417114321381e-01,
      -2.76742510726862411e-03 * DAYS_PER_YEAR,
       4.99852801234917238e-03 * DAYS_PER_YEAR,
       2.30417297573763929e-05 * DAYS_PER_YEAR,
       2.85885980666130812e-04 * SOLAR_MASS },
    /* Uranus */
    {  1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
       2.96460137564761618e-03 * DAYS_PER_YEAR,
       2.37847173959480950e-03 * DAYS_PER_YEAR,
      -2.96589568540237556e-05 * DAYS_PER_YEAR,
       4.36624404335156298e-05 * SOLAR_MASS },
    /* Neptune */
    {  1.53796971148509165e+01, -2.59193146099879641e+01,  1.79258772950371181e-01,
       2.68067772490389322e-03 * DAYS_PER_YEAR,
       1.62824170038242295e-03 * DAYS_PER_YEAR,
      -9.51592254519715870e-05 * DAYS_PER_YEAR,
       5.15138902046611451e-05 * SOLAR_MASS }
};

/* Put the barycentre at rest, so total momentum is zero and the system does
   not drift. Without this the energy is still conserved but the reported
   value differs, so it is part of the specification. */
static void offset_momentum(void)
{
    double px = 0.0, py = 0.0, pz = 0.0;
    for (int i = 0; i < NBODY; i++) {
        px += bodies[i].vx * bodies[i].mass;
        py += bodies[i].vy * bodies[i].mass;
        pz += bodies[i].vz * bodies[i].mass;
    }
    bodies[0].vx = -px / SOLAR_MASS;
    bodies[0].vy = -py / SOLAR_MASS;
    bodies[0].vz = -pz / SOLAR_MASS;
}

/* Symplectic Euler: all velocities updated from the pairwise forces at the
   current positions, then all positions updated from the new velocities.
   First order, and symplectic, which is why energy drift stays bounded
   instead of accumulating. The two loops must not be fused. */
static void advance(double dt)
{
    for (int i = 0; i < NBODY; i++) {
        for (int j = i + 1; j < NBODY; j++) {
            double dx = bodies[i].x - bodies[j].x;
            double dy = bodies[i].y - bodies[j].y;
            double dz = bodies[i].z - bodies[j].z;

            double d2 = dx * dx + dy * dy + dz * dz;
            double mag = dt / (d2 * sqrt(d2));

            bodies[i].vx -= dx * bodies[j].mass * mag;
            bodies[i].vy -= dy * bodies[j].mass * mag;
            bodies[i].vz -= dz * bodies[j].mass * mag;

            bodies[j].vx += dx * bodies[i].mass * mag;
            bodies[j].vy += dy * bodies[i].mass * mag;
            bodies[j].vz += dz * bodies[i].mass * mag;
        }
    }
    for (int i = 0; i < NBODY; i++) {
        bodies[i].x += dt * bodies[i].vx;
        bodies[i].y += dt * bodies[i].vy;
        bodies[i].z += dt * bodies[i].vz;
    }
}

/* Total energy: kinetic summed over bodies, minus potential summed over
   unordered pairs. Accumulation order is part of the specification because
   floating-point addition is not associative. */
static double energy(void)
{
    double e = 0.0;
    for (int i = 0; i < NBODY; i++) {
        e += 0.5 * bodies[i].mass *
             (bodies[i].vx * bodies[i].vx +
              bodies[i].vy * bodies[i].vy +
              bodies[i].vz * bodies[i].vz);
        for (int j = i + 1; j < NBODY; j++) {
            double dx = bodies[i].x - bodies[j].x;
            double dy = bodies[i].y - bodies[j].y;
            double dz = bodies[i].z - bodies[j].z;
            e -= (bodies[i].mass * bodies[j].mass) / sqrt(dx * dx + dy * dy + dz * dz);
        }
    }
    return e;
}

int main(int argc, char **argv)
{
    long n = (argc > 1) ? atol(argv[1]) : 1000;

    offset_momentum();
    printf("%.9f\n", energy());
    for (long i = 0; i < n; i++)
        advance(DT);
    printf("%.9f\n", energy());
    return 0;
}
