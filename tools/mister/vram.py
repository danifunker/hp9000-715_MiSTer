#!/usr/bin/env python3
"""Render Artist's screen from a dump of its VRAM, LUT copy and attribute plane.

The dump (tools/mister/board.sh vram) is the 2 MB VRAM (DDR3 0x3300_0000,
pixel (x, y) at byte y * 2048 + x), the core's copy of the colour maps at
0x3320_0000 (HP9K715.sv): 256 doublewords of two 0x00RRGGBB entries
(little-endian, entry 2i in the low half; 0-255 LUT0, 256-511 LUT1) and a
doubleword {height, width, video on}, then the 256 KB attribute plane
(0x3340_0000: pixel (x, y) in bit x % 64 of doubleword y * 32 + x / 64, set =
LUT1). Older cores wrote 128 + 1 doublewords (LUT0 only) and no plane; without
any copy the size is 1280 x 1024 and the palette a guess (the ROM's eight
text colours). The hardware cursor is not in the VRAM, so not in the picture.

    vram.py DUMP OUT.png [--full]    (--full: the whole 2048 x 1024 VRAM)
"""
import struct, sys
from PIL import Image

d = open(sys.argv[1], 'rb').read()
vram, tail = d[:0x200000], d[0x200000:]
pal, w, h, on, attr = None, 1280, 1024, None, None


def geom(q):
    return q & 1, (q >> 1) & 0xFFF, (q >> 13) & 0xFFF


if len(tail) >= 257 * 8:
    words = struct.unpack('<257Q', tail[:257 * 8])
    g = geom(words[256])
    if g[0] in (0, 1) and 0 < g[1] <= 2048 and 0 < g[2] <= 1024 and words[256] >> 25 == 0:
        on, w, h = g
        pal = []
        for q in words[:256]:
            for e in (q & 0xFFFFFF, (q >> 32) & 0xFFFFFF):
                pal.append(((e >> 16) & 255, (e >> 8) & 255, e & 255))
        if len(tail) >= 257 * 8 + 0x40000:
            attr = tail[257 * 8:257 * 8 + 0x40000]
if pal is None and len(tail) >= 129 * 8:
    words = struct.unpack('<129Q', tail[:129 * 8])
    on, w, h = geom(words[128])
    pal = []
    for q in words[:128]:
        for e in (q & 0xFFFFFF, (q >> 32) & 0xFFFFFF):
            pal.append(((e >> 16) & 255, (e >> 8) & 255, e & 255))
    if not (0 < w <= 2048 and 0 < h <= 1024): w, h = 1280, 1024
if pal is None or not any(pal):
    text = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255), (0, 0, 255), (255, 0, 255)]
    pal = [text[i] if i < 8 else tuple(min(255, c // 2 + (i >> 3) * 8) for c in text[i & 7]) for i in range(256)]
if '--full' in sys.argv: w, h = 2048, 1024
if attr is None or len(pal) < 512 or not any(attr):
    im = Image.frombytes('P', (w, h), b''.join(vram[y * 2048:y * 2048 + w] for y in range(h)))
    im.putpalette([c for rgb in pal[:256] for c in rgb])
    im = im.convert('RGB')
else:
    out = bytearray(w * h * 3)
    for y in range(h):
        row = struct.unpack('<32Q', attr[y * 256:y * 256 + 256])
        for x in range(w):
            c = pal[(row[x >> 6] >> (x & 63) & 1) << 8 | vram[y * 2048 + x]]
            out[(y * w + x) * 3:(y * w + x) * 3 + 3] = bytes(c)
    im = Image.frombytes('RGB', (w, h), bytes(out))
im.save(sys.argv[2])
print('%s: %dx%d, video %s' % (sys.argv[2], w, h, {None: '?', 0: 'off', 1: 'on'}[on]))
