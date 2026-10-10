#!/usr/bin/env python3
"""mktestcd.py -- a mixed-mode CUE/BIN test disc for the core's CD-ROM.

Track 1: MODE1/2352 data, an ISO 9660 image of a directory (genisoimage);
track 2: 10 s of 440 Hz left / 660 Hz right; track 3: 6 s of 880 Hz on both
channels at half level. Sectors of track 1 carry sync, header (BCD M:S:F,
mode 1) and the 2048 data bytes; EDC/ECC are left zero (Main_MiSTer's
translation takes the data at offset 16 and checks nothing).

  mktestcd.py DIR OUT_BASE        -> OUT_BASE.bin, OUT_BASE.cue
"""
import math, os, struct, subprocess, sys, tempfile


def bcd(v):
    return (v // 10) << 4 | v % 10


def data_track(iso):
    out = bytearray()
    for i in range(len(iso) // 2048):
        a = i + 150
        hdr = bytes([0] + [0xFF] * 10 + [0, bcd(a // 4500), bcd(a // 75 % 60), bcd(a % 75), 1])
        out += hdr + iso[i * 2048:(i + 1) * 2048] + bytes(288)
    return out


def tone(secs, fl, fr, amp):
    n = int(secs * 44100) // 588 * 588
    out = bytearray()
    for k in range(n):
        l = int(amp * 32767 * math.sin(2 * math.pi * fl * k / 44100))
        r = int(amp * 32767 * math.sin(2 * math.pi * fr * k / 44100))
        out += struct.pack('<hh', l, r)
    return out


def msf(f):
    return '%02d:%02d:%02d' % (f // 4500, f // 75 % 60, f % 75)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    src, base = sys.argv[1], sys.argv[2]
    with tempfile.NamedTemporaryFile(suffix='.iso') as t:
        subprocess.run(['genisoimage', '-quiet', '-o', t.name, '-V', 'HP715AUDIO', src], check=True)
        iso = open(t.name, 'rb').read()
    tracks = [data_track(iso), tone(10, 440, 660, 0.8), tone(6, 880, 880, 0.4)]
    name = os.path.basename(base) + '.bin'
    lines = ['FILE "%s" BINARY' % name]
    f = 0
    for i, tr in enumerate(tracks):
        lines.append('  TRACK %02d %s' % (i + 1, 'MODE1/2352' if i == 0 else 'AUDIO'))
        lines.append('    INDEX 01 %s' % msf(f))
        f += len(tr) // 2352
    with open(base + '.bin', 'wb') as o:
        for tr in tracks:
            o.write(tr)
    open(base + '.cue', 'w').write('\n'.join(lines) + '\n')
    print('%s.bin: %d frames; %s.cue:' % (base, f, base))
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
