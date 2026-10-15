#!/usr/bin/env python3
"""perf_report.py LOG: the perf suite's kernels (gen_tests.py gen_perf): CR16 ticks per run and per iteration."""
import re, sys, json, os
names = [k["kernel"] for k in json.load(open(os.path.join(os.path.dirname(sys.argv[0]), "build", "gen_perf.json")))[0]["inputs"]] \
    if os.path.exists(os.path.join(os.path.dirname(sys.argv[0]), "build", "gen_perf.json")) else []
vecs = []
for l in open(sys.argv[1]):
    m = re.match(r'\s*[0-9a-fA-F]{4}((?:\s+[0-9a-fA-F]{8}){8})\s*$', l)
    if m: vecs.append([int(x, 16) for x in m.group(1).split()])
print("%-14s %10s %10s %8s %8s" % ("kernel", "run1", "run2", "/iter1", "/iter2"))
for i, w in enumerate(vecs):
    n = names[i] if i < len(names) else "k%d" % i
    print("%-14s %10d %10d %8.2f %8.2f" % (n, w[0], w[1], w[0] / w[2], w[1] / w[2]))
