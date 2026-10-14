#!/usr/bin/env python3
"""ring_link.py RING.txt [ADDR...]: cpu-requests #10 -- around every visit of yylook's prologue (flow to 0x2ee1a0),
print the events that matter: the b,l's flow, the memS/memL events at 0x2ee1a0 / 0x2ee738 (the link stored and
reloaded), W-hold events, traps. Default addresses: 0x2ee1a0 (stw rp), 0x2ee738 (ldw rp)."""
import re, sys
addrs = {int(a, 0) for a in sys.argv[2:]} or {0x2ee1a0, 0x2ee738, 0x2ee1a4}
ev = [l.rstrip() for l in open(sys.argv[1]) if l.startswith('EV ')]
def at(l):
    m = re.search(r' at ([0-9a-f]{8})', l)
    return int(m.group(1), 16) & ~3 if m else None
keep = []
for i, l in enumerate(ev):
    a = at(l)
    if ('mem' in l or 'whold' in l or 'trap' in l) and a in addrs: keep.append(i)
    if 'flow' in l and ('-> 002ee1a3' in l or '-> 002ee1a7' in l or '002ee77f ->' in l): keep.append(i)
last = -10
for i in sorted(set(keep)):
    if i - last > 1: print('...')
    print(ev[i]); last = i
