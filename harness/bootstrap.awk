# Bootstrap confidence interval on the ratio of two medians.
#
# Implements the protocol in docs/METHOD.md, which exists because parametric
# tests are not licensed here: without layout re-randomization the samples are
# not normally distributed (Stabilizer, five of eighteen benchmarks fail a
# normality test), and we cannot run Stabilizer because it is an LLVM 3.1 pass
# while our matrix contains no LLVM. See LEDGER.md D13.
#
#   given samples A[1..n], B[1..n]
#   repeat 10000 times:
#       a* = resample A with replacement, n draws
#       b* = resample B with replacement, n draws
#       record ratio = median(b*) / median(a*)
#   report the 2.5th and 97.5th percentiles
#
# Input: two whitespace-separated lines of numbers, baseline first.
# Usage:  printf '%s\n%s\n' "$A" "$B" | awk -f bootstrap.awk
#
# awk rather than python or R: the harness is shell, this keeps it one language,
# and 10000 resamples of a handful of values is nothing.

function median(arr, n,   c, i, j, t) {
    for (i = 1; i <= n; i++) c[i] = arr[i]
    for (i = 1; i < n; i++)                       # insertion sort, n is tiny
        for (j = i + 1; j <= n; j++)
            if (c[j] < c[i]) { t = c[i]; c[i] = c[j]; c[j] = t }
    if (n % 2) return c[(n + 1) / 2]
    return (c[n / 2] + c[n / 2 + 1]) / 2.0
}

BEGIN { srand(SEED ? SEED : 20260806); REPS = REPS ? REPS : 10000 }

NR == 1 { na = NF; for (i = 1; i <= NF; i++) A[i] = $i }
NR == 2 { nb = NF; for (i = 1; i <= NF; i++) B[i] = $i }

END {
    if (na < 2 || nb < 2) { print "need at least 2 samples per group"; exit 1 }

    for (r = 1; r <= REPS; r++) {
        for (i = 1; i <= na; i++) as[i] = A[int(rand() * na) + 1]
        for (i = 1; i <= nb; i++) bs[i] = B[int(rand() * nb) + 1]
        ma = median(as, na)
        if (ma == 0) continue
        ratios[r] = median(bs, nb) / ma
    }

    n = 0
    for (r in ratios) sorted[++n] = ratios[r]
    for (i = 1; i < n; i++)
        for (j = i + 1; j <= n; j++)
            if (sorted[j] < sorted[i]) { t = sorted[i]; sorted[i] = sorted[j]; sorted[j] = t }

    lo = sorted[int(0.025 * n) + 1]
    hi = sorted[int(0.975 * n)]
    pt = median(B, nb) / median(A, na)

    # An interval spanning 1.0 is reported as NO DETECTED DIFFERENCE, never as a
    # small one. And an interval that excludes 1.0 but sits inside [0.95, 1.05]
    # is statistically real and practically uninteresting, which METHOD.md flags
    # as a distinct failure mode from significance.
    verdict = (lo <= 1.0 && hi >= 1.0) ? "no detected difference" \
            : ((lo > 0.95 && hi < 1.05) ? "detected but inside the 5% noise band" : "real")

    printf "ratio %.4f  95%% CI [%.4f, %.4f]  %s\n", pt, lo, hi, verdict
}
