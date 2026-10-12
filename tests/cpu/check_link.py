#!/usr/bin/env python3
"""check_link.py LOG: the link suite (gen_tests.py gen_link). Every slot must hold the sentinel, the link, or
(the interrupt skipped the b,l in this harness) the rp from before."""
import re, sys
SENT = 0xDEADBEEF
vecs = []
for l in open(sys.argv[1]):
    m = re.match(r'\s*[0-9a-fA-F]{4}((?:\s+[0-9a-fA-F]{8}){8})\s*$', l)
    if m: vecs.append([int(x, 16) for x in m.group(1).split()])
bad = 0; irq = 0; skipped = 0
for v, w in enumerate(vecs):
    L, s, traps, k, rp0 = w[0], w[1:5], w[5], w[6], w[7]
    irq += traps != 0
    if all(x == rp0 for x in s): skipped += 1; continue
    for i, x in enumerate(s):
        if x != SENT and x != L:
            bad += 1; print('vector %d (k=%d, traps %d): slot %d = %08x, link %08x (%+d)' % (v, k, traps, i, x, L, x - L))
print('%d vectors, %d with an interrupt, %d with the b,l skipped, %d bad slots' % (len(vecs), irq, skipped, bad))
sys.exit(1 if bad else 0)
