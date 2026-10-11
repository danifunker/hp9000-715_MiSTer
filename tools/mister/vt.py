#!/usr/bin/env python3
# vt.py LOG [FROM_BYTE] -- replay a board.sh console log (timestamped) through a
# minimal VT100 (CUP, ED, EL, cursor moves, scroll) and print the final 80x24 screen.
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('latin1')
start = int(sys.argv[2]) if len(sys.argv) > 2 else max(0, len(raw) - 60000)
s = re.sub(r'\n\[\d\d:\d\d:\d\d\] ', '\n', raw[start:])
W, H = 80, 24
scr = [[' '] * W for _ in range(H)]; r = c = 0; k = 0
def scroll():
    scr.pop(0); scr.append([' '] * W)
while k < len(s):
    ch = s[k]
    if ch == '\x1b':
        m = re.match(r'\x1b\[([?\d;]*)([A-Za-z@])', s[k:])
        if m:
            a, cmd = m.group(1), m.group(2)
            n = [int(x) for x in a.replace('?', '').split(';') if x]
            if cmd in 'Hf': r = (n[0] - 1 if n else 0); c = (n[1] - 1 if len(n) > 1 else 0)
            elif cmd == 'J':
                if (n[0] if n else 0) == 2 or (not n and r == 0 and c == 0): scr = [[' '] * W for _ in range(H)]
                else:
                    scr[r][c:] = [' '] * (W - c)
                    for i in range(r + 1, H): scr[i] = [' '] * W
            elif cmd == 'K': scr[r][c:] = [' '] * (W - c)
            elif cmd == 'C': c += n[0] if n else 1
            elif cmd == 'D': c -= n[0] if n else 1
            elif cmd == 'A': r -= n[0] if n else 1
            elif cmd == 'B': r += n[0] if n else 1
            r = max(0, min(H - 1, r)); c = max(0, min(W - 1, c))
            k += len(m.group(0)); continue
        m = re.match(r'\x1b[()][0B]|\x1b.?', s[k:]); k += len(m.group(0)); continue
    if ch == '\r': c = 0
    elif ch == '\n':
        r += 1
        if r >= H: scroll(); r = H - 1
    elif ch == '\b': c = max(0, c - 1)
    elif ' ' <= ch < '\x7f':
        if c >= W: c = 0; r += 1
        if r >= H: scroll(); r = H - 1
        scr[r][c] = ch; c += 1
    k += 1
print('\n'.join(''.join(l).rstrip() for l in scr))
