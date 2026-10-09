#!/usr/bin/env python3
"""Render Artist's screen from a dump of its VRAM and the LUT0 copy.

The dump (tools/mister/board.sh vram) is the 2 MB VRAM (DDR3 0x3300_0000,
pixel (x, y) at byte y * 2048 + x) followed by the core's copy of LUT0 at
0x3320_0000 (HP9K715.sv): 128 doublewords of two 0x00RRGGBB entries
(little-endian, entry 2i in the low half) and a doubleword {height, width,
video on}. Without the copy (an older core) the size is 1280 x 1024 and the
palette a guess (the ROM's eight text colours).

    vram.py DUMP OUT.png [--full]    (--full: the whole 2048 x 1024 VRAM)
"""
import struct, sys
from PIL import Image

d = open(sys.argv[1], 'rb').read()
vram, tail = d[:0x200000], d[0x200000:]
pal, w, h, on = None, 1280, 1024, None
if len(tail) >= 129 * 8:
    words = struct.unpack('<129Q', tail[:129 * 8])
    geom = words[128]
    on, w, h = geom & 1, (geom >> 1) & 0xFFF, (geom >> 13) & 0xFFF
    pal = []
    for q in words[:128]:
        for e in (q & 0xFFFFFF, (q >> 32) & 0xFFFFFF):
            pal.append(((e >> 16) & 255, (e >> 8) & 255, e & 255))
    if not (0 < w <= 2048 and 0 < h <= 1024): w, h = 1280, 1024
if pal is None or not any(pal):
    text = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255), (0, 0, 255), (255, 0, 255)]
    pal = [text[i] if i < 8 else tuple(min(255, c // 2 + (i >> 3) * 8) for c in text[i & 7]) for i in range(256)]
if '--full' in sys.argv: w, h = 2048, 1024
im = Image.frombytes('P', (w, h), b''.join(vram[y * 2048:y * 2048 + w] for y in range(h)))
im.putpalette([c for rgb in pal for c in rgb])
im.convert('RGB').save(sys.argv[2])
print('%s: %dx%d, video %s' % (sys.argv[2], w, h, {None: '?', 0: 'off', 1: 'on'}[on]))
