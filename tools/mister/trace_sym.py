#!/usr/bin/env python3
"""Annotate a trace_dump.py dump with HP-UX kernel symbols and system-call names.

    trace_sym.py KERNEL DUMP [--sysc]   KERNEL = an HP-UX kernel (SOM, tools/hpux/som.py);
                                        --sysc keeps only system calls, traps, keys and LAN events

System-call numbers (event 15) get their names from the kernel's sysent
table (tools/hpux/sysent.py); kernel addresses in lineRI (I-cache fills),
traps and sysa (r2, when it is in the kernel) get `symbol+offset` -- the
HP-UX kernel is equivalently mapped, so a physical line address is its
virtual one.
"""
import bisect, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def load(kernel):
    syms = []
    for l in subprocess.run([sys.executable, os.path.join(HERE, '..', 'hpux', 'som.py'), kernel, 'syms'],
                            capture_output=True, text=True).stdout.splitlines():
        f = l.split()
        if len(f) >= 4 and f[1] == 'ENTRY':
            syms.append((int(f[0], 16), f[3]))
    syms.sort()
    names = {}
    for l in subprocess.run([sys.executable, os.path.join(HERE, '..', 'hpux', 'sysent.py'), kernel],
                            capture_output=True, text=True).stdout.splitlines():
        f = l.split()
        if len(f) >= 3 and f[0].isdigit():
            names[int(f[0])] = f[2]
    return syms, names


def sym(syms, a):
    i = bisect.bisect_right(syms, (a, '\xff')) - 1
    if i < 0 or a - syms[i][0] > 0x10000:
        return ''
    return '%s+0x%x' % (syms[i][1], a - syms[i][0])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    only = '--sysc' in sys.argv
    syms, names = load(args[0])
    hexa = re.compile(r'\b([0-9a-f]{8})\b')
    for line in open(args[1]):
        line = line.rstrip('\n')
        if only and not re.search(r'\b(sysc|sysa|sysr|trap|key|lan)\b', line):
            continue
        m = re.search(r'\bsysc\s+(\d+)', line)
        if m:
            line += '   %s' % names.get(int(m.group(1)), '?')
        else:
            m = re.search(r'\b(lineRI|trap .* at|sysa rp)\s+([0-9a-f]{8})', line)
            if m:
                s = sym(syms, int(m.group(2), 16))
                if s:
                    line += '   ' + s
        print(line)


if __name__ == '__main__':
    main()
