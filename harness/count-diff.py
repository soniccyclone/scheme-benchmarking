#!/usr/bin/env python3
"""Per-address diff of callgrind's Ir against qemu-count's block accounting.

Driven by harness/count-diff.sh, which produces both inputs in one directory.
See that script's header for why this comparison is the one worth making.
"""
import sys, re, os, subprocess, collections

W = sys.argv[1]

# --- callgrind: address -> Ir ----------------------------------------------
# Format with `positions: instr`: a cost line is a position followed by counts.
# The position is either absolute (0x...), or RELATIVE to the previous one
# (+n / -n), or `*` meaning unchanged. Getting the relative forms wrong does not
# error -- it silently attributes costs to the wrong addresses, which is exactly
# the kind of quiet wrongness this whole investigation is about.
#
# THE COST LINE AFTER `calls=` IS NOT AN INSTRUCTION COUNT. It is the INCLUSIVE
# cost of the call made at that address -- everything the callee did. Summing it
# alongside self costs inflates the total enormously and non-uniformly: doing so
# here reported 627,171 Ir for a run that count-instructions.sh puts at 134,865,
# with single addresses credited 134,536. A caller's inclusive cost is most of
# the program, so this is not a subtle error, but it produces a plausible-looking
# per-address table rather than an obvious failure.
cg = collections.Counter()
pos = None
after_calls = False
for line in open(os.path.join(W, "cg.out"), errors="replace"):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    if line.startswith("calls="):
        after_calls = True
        continue
    # A new function context: the next position is absolute. Do not carry a
    # relative base across it.
    if line.startswith(("fn=", "fl=", "fi=", "fe=", "cfn=", "cfi=", "cfl=", "ob=", "cob=")):
        if not line.startswith(("cfn=", "cfi=", "cfl=", "cob=")):
            pos = None
        continue
    m = re.match(r"^(0x[0-9a-f]+|\+\d+|-\d+|\*)\s+(\d+)\s*$", line)
    if not m:
        continue
    p, cost = m.group(1), int(m.group(2))
    if p.startswith("0x"):
        pos = int(p, 16)
    elif pos is None:
        continue          # relative position with no base; cannot place it
    elif p == "*":
        pass
    elif p.startswith("+"):
        pos += int(p[1:])
    else:
        pos -= int(p[1:])
    if after_calls:
        after_calls = False   # inclusive call cost: position advances, cost is not ours
        continue
    if pos is not None:
        cg[pos] += cost

# --- qemu: address -> executions -------------------------------------------
blocks, execs = {}, collections.Counter()
addr, cur = None, []
for line in open(os.path.join(W, "q.log"), errors="replace"):
    if line.startswith("OBJD-T:"):
        if addr is not None:
            cur.append(line.split(":", 1)[1].strip())
    elif line.startswith("0x") and line.rstrip().endswith(":"):
        if addr is not None and cur:
            blocks[addr] = "".join(cur)
        addr, cur = int(line.split(":")[0], 16), []
    elif line.startswith("Trace "):
        m = re.search(r"\[[0-9a-f]+/([0-9a-f]+)/", line)
        if m:
            execs[int(m.group(1), 16)] += 1
    elif line.startswith("IN:"):
        if addr is not None and cur:
            blocks[addr] = "".join(cur)
        addr, cur = None, []
if addr is not None and cur:
    blocks[addr] = "".join(cur)

_off_cache = {}
def offsets(a):
    if a in _off_cache:
        return _off_cache[a]
    raw = bytes.fromhex(blocks[a])
    p = os.path.join(W, "blk.bin")
    open(p, "wb").write(raw)
    out = subprocess.run(
        ["objdump", "-D", "-b", "binary", "-m", "i386:x86-64", p],
        capture_output=True, text=True).stdout
    r = [int(m.group(1), 16) for l in out.splitlines()
         for m in [re.match(r"^\s+([0-9a-f]+):\t[^\t]*\t\s*\S", l)] if m]
    _off_cache[a] = r
    return r

qm = collections.Counter()
missing = 0
for a, n in execs.items():
    if a not in blocks:
        missing += n
        continue
    for off in offsets(a):
        qm[a + off] += n

tc, tq = sum(cg.values()), sum(qm.values())
print("callgrind total Ir  = %d" % tc)
print("qemu      total     = %d" % tq)
print("difference          = %+d  (%+.4f%%)" % (tq - tc, 100.0 * (tq - tc) / tc))
if missing:
    print("NOTE: %d block executions had no in_asm record and are not counted" % missing)
print()

diffs = [(qm[a] - cg.get(a, 0), a) for a in set(qm) | set(cg) if qm[a] != cg.get(a, 0)]
diffs.sort(key=lambda t: -abs(t[0]))
pos_sum = sum(d for d, _ in diffs if d > 0)
neg_sum = sum(d for d, _ in diffs if d < 0)

print("addresses counted by both and agreeing : %d"
      % len([a for a in set(qm) & set(cg) if qm[a] == cg[a]]))
print("addresses where they disagree          : %d" % len(diffs))
print("  qemu only (callgrind never saw them) : %d"
      % len([a for _, a in diffs if a not in cg]))
print("  callgrind only (qemu never saw them) : %d"
      % len([a for _, a in diffs if a not in qm]))
print()
print("%-12s %12s %12s %12s" % ("addr", "callgrind", "qemu", "qemu-cg"))
for d, a in diffs[:20]:
    print("0x%-10x %12d %12d %+12d" % (a, cg.get(a, 0), qm[a], d))
print()
print("sum of positive disagreements: %+d" % pos_sum)
print("sum of negative disagreements: %+d" % neg_sum)
print("net                          : %+d" % (pos_sum + neg_sum))
