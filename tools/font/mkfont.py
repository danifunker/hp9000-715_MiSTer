#!/usr/bin/env python3
"""Make the on-screen terminal's 8x16 font ROM (rtl/mister/font8x16.hex) from
a PSF console font: the 128 ASCII code points, 16 bytes each (top row
first, bit 7 = leftmost pixel), looked up through the font's Unicode table.

    mkfont.py [/usr/share/consolefonts/Lat15-VGA16.psf.gz] [OUT.hex]

The default font is u_vga16 by Dmitry Bolkhovityanov (MIT licence, see
/usr/share/doc/console-setup/copyright.fonts.gz); the notice goes into the
output's header.
"""
import gzip, struct, sys

NOTICE = """// 8x16 ASCII font for rtl/mister/serial_term.sv, made by tools/font/mkfont.py
// from u_vga16.bdf (Lat15-VGA16.psf):
// Copyright (C) 2000, 2001 by Dmitry Bolkhovityanov.  All Rights Reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// 128 glyphs x 16 rows, one byte per line, bit 7 = leftmost pixel
"""


def load_psf(path):
    data = gzip.open(path).read() if path.endswith('.gz') else open(path, 'rb').read()
    if data[:2] == b'\x36\x04':                       # PSF1
        mode, h = data[2], data[3]
        n = 512 if mode & 1 else 256
        glyphs = [data[4 + i * h: 4 + (i + 1) * h] for i in range(n)]
        uni = {}
        if mode & 2:
            p = 4 + n * h
            for g in range(n):
                while True:
                    (u,) = struct.unpack('<H', data[p:p + 2]); p += 2
                    if u == 0xFFFF: break
                    if u != 0xFFFE: uni.setdefault(u, g)
        return h, 8, glyphs, uni
    magic, ver, hdr, flags, n, cb, h, w = struct.unpack('<8I', data[:32])
    assert magic == 0x864AB572, 'not a PSF font'
    glyphs = [data[hdr + i * cb: hdr + (i + 1) * cb] for i in range(n)]
    uni = {}
    if flags & 1:
        p, g = hdr + n * cb, 0
        while g < n:
            b = data[p]
            if b == 0xFF: g += 1; p += 1; continue
            if b == 0xFE: p += 1; continue
            l = 1 if b < 0x80 else 2 if b < 0xE0 else 3 if b < 0xF0 else 4
            uni.setdefault(ord(data[p:p + l].decode('utf-8')), g); p += l
    return h, w, glyphs, uni


def main(argv):
    src = argv[0] if argv else '/usr/share/consolefonts/Lat15-VGA16.psf.gz'
    out = argv[1] if len(argv) > 1 else 'rtl/mister/font8x16.hex'
    h, w, glyphs, uni = load_psf(src)
    assert (h, w) == (16, 8), (h, w)
    lines = [NOTICE.rstrip("\n")]
    for c in range(128):
        g = uni.get(c, c if c >= 0x20 and not uni else None)
        rows = glyphs[g] if g is not None else bytes(16)
        lines.append(' '.join('%02x' % b for b in rows) + '   // %s' % (
            repr(chr(c)) if 0x20 <= c < 0x7F else '0x%02x' % c))
    open(out, 'w').write('\n'.join(lines) + '\n')
    print(out, 'written')


if __name__ == '__main__':
    main(sys.argv[1:])
