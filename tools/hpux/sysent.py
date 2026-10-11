#!/usr/bin/env python3
"""sysent.py KERNEL -- list an HP-UX kernel's system calls: number, argument count, handler.

Reads the SOM kernel's `sysent` table (12-byte entries: nargs, handler, ...)
and `nsysent` through tools/hpux/som.py, e.g. for the 11i INSTALL kernel:
    python3 tools/hpux/sysent.py roms/hpux11i/INSTALL > scratch/sysent11i.txt
"""
import os, struct, subprocess, sys, tempfile
k = sys.argv[1]; som = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'som.py')
syms, data = {}, {}
for l in subprocess.run([sys.executable, som, k, 'syms'], capture_output=True, text=True).stdout.splitlines():
    p = l.split()
    if len(p) >= 4:
        if p[1] in ('ENTRY', 'CODE'): syms.setdefault(int(p[0], 16), p[3])
        elif p[1] == 'DATA': data[p[3]] = int(p[0], 16)
with tempfile.NamedTemporaryFile(suffix='.img') as t:
    subprocess.run([sys.executable, som, k, 'image', t.name], capture_output=True, check=True)
    img = open(t.name, 'rb').read()
base = 0x20000
w = lambda a: struct.unpack('>I', img[a - base:a - base + 4])[0]
for n in range(w(data['nsysent'])):
    a = data['sysent'] + 12 * n
    print(n, w(a), syms.get(w(a + 4), hex(w(a + 4))))
