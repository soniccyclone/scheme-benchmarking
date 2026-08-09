/* fannkuch-redux, the reference. Written against SPEC.md in this directory.
 *
 * Output is two raw binary64 values -- checksum then maxflips -- to match every
 * other variant in the matrix, so the oracle is a byte comparison. See
 * bench/nbody/ref.c for the same convention and the reason for it. */

#include <stdio.h>
#include <unistd.h>

#define N 7

static int perm[N];
static int perm1[N];
static int cnt[N];

/* Reverse perm[0..k] in place. */
static void flip_prefix(int k) {
    int i = 0, j = k;
    while (i < j) {
        int t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
        i++;
        j--;
    }
}

/* Flip until the head is 0, counting. Destroys perm. */
static int count_flips(void) {
    int f = 0, k;
    while ((k = perm[0]) != 0) {
        flip_prefix(k);
        f++;
    }
    return f;
}

static void emit(double x) {
    /* Raw bytes, not a formatted number: the oracle compares bit patterns. */
    ssize_t ignored = write(1, &x, sizeof x);
    (void)ignored;
}

int main(void) {
    int r = N, maxflips = 0, checksum = 0, sign = 0;

    for (int i = 0; i < N; i++) perm1[i] = i;

    for (;;) {
        while (r != 1) { cnt[r - 1] = r; r--; }

        for (int i = 0; i < N; i++) perm[i] = perm1[i];
        int f = count_flips();
        if (f > maxflips) maxflips = f;
        checksum += sign == 0 ? f : -f;
        sign = 1 - sign;

        for (;;) {
            if (r == N) {
                emit((double)checksum);
                emit((double)maxflips);
                return 0;
            }
            int p0 = perm1[0];
            for (int i = 0; i < r; i++) perm1[i] = perm1[i + 1];
            perm1[r] = p0;
            cnt[r] -= 1;
            if (cnt[r] > 0) break;
            r++;
        }
    }
}
