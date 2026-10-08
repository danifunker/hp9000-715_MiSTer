#!/usr/bin/env python3
"""Render a romsim serial-console log as a terminal screenshot (PNG).

The machine has no graphics console yet (STUBS S-018), so the serial port is
its screen. This takes the output of `verilator/obj_dir_rom/Vemu --stamp`
(console text, each line stamped with the cycle count) or of
`tools/mister/board.sh console` (the board's, stamped with the time), drops the
simulator's own lines (romsim:, LED, SCR, gsc traces), and draws the rest as
an 80-column terminal, with the machine time of each line (cycles at 64 MHz)
in a dim gutter.

    console_png.py LOG OUT.png [--from REGEX] [--to REGEX] [--last N]
                   [--title TEXT] [--no-time]

--from/--to pick the window (first line matching --from, through the first
match of --to after it); --last keeps only the last N lines of it.
"""
import argparse
import re
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
CLK_HZ = 64_000_000
STAMP = re.compile(r"^\[\s*(\d+)\]\s?(.*)$")
BOARD = re.compile(r"^\[\d\d:\d\d:\d\d\] (.*)$")
NOISE = re.compile(r"^(romsim:|LED [0-9A-F]{2}$|SCR |gsc |IC |L1 |IF |\s*\d+ [0-9a-f]{8} )")

BG, FG, DIM, BAR, BAR_FG = (12, 16, 14), (190, 235, 190), (85, 110, 90), (52, 56, 60), (220, 220, 220)


def read_lines(path):
    """(cycle or None, text) per console line, simulator noise removed."""
    out, last = [], None
    with open(path, errors="replace") as f:
        for raw in f:
            raw = raw.rstrip("\n").replace("\r", "")
            mb = BOARD.match(raw)                 # tools/mister/board.sh console
            if mb:
                raw = mb.group(1)
            m = STAMP.match(raw)
            cyc, text = (int(m.group(1)), m.group(2)) if m else (None, raw)
            if NOISE.match(text) or NOISE.match(raw):
                continue
            # a stderr line spliced into a console line ("BOOT_ADMIN>romsim: ..."),
            # a stamp in the middle of one (older romsim builds, after typing)
            text = re.sub(r"romsim: .*$", "", text)
            text = re.sub(r"\[\s*\d+\]\s?", "", text)
            if cyc is None:
                cyc = last
            last = cyc
            out.append((cyc, text.expandtabs(8)))
    return out


def window(lines, start, end, last):
    i0 = 0
    if start:
        i0 = next((i for i, (_, t) in enumerate(lines) if re.search(start, t)), 0)
    i1 = len(lines)
    if end:
        i1 = next((i + 1 for i in range(i0, len(lines)) if re.search(end, lines[i][1])), len(lines))
    sel = lines[i0:i1]
    # collapse runs of blank lines to one
    tidy = []
    for c, t in sel:
        if t.strip() == "" and tidy and tidy[-1][1].strip() == "":
            continue
        tidy.append((c, t))
    return tidy[-last:] if last else tidy


def render(lines, out, title, show_time):
    font = ImageFont.truetype(FONT, 15)
    small = ImageFont.truetype(FONT, 12)
    cw = font.getbbox("M")[2]
    lh = 19
    gutter = 13 * small.getbbox("0")[2] if show_time else 0
    cols = max(80, max((len(t) for _, t in lines), default=0))
    pad, bar = 14, 30
    w = pad * 2 + gutter + cols * cw
    h = bar + pad * 2 + max(1, len(lines)) * lh
    img = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w, bar], fill=BAR)
    for k, col in enumerate([(237, 106, 94), (245, 191, 79), (98, 197, 84)]):
        d.ellipse([12 + 20 * k, 9, 24 + 20 * k, 21], fill=col)
    d.text((80, 7), title, font=small, fill=BAR_FG)
    y = bar + pad
    prev = None
    for cyc, text in lines:
        if show_time and cyc is not None and cyc != prev and text.strip():
            d.text((pad, y + 3), "%9.3f s" % (cyc / CLK_HZ), font=small, fill=DIM)
            prev = cyc
        d.text((pad + gutter, y), text, font=font, fill=FG)
        y += lh
    img.save(out)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("log")
    ap.add_argument("out")
    ap.add_argument("--from", dest="start")
    ap.add_argument("--to", dest="end")
    ap.add_argument("--last", type=int)
    ap.add_argument("--title", default="HP 9000/715 -- serial console (Verilator)")
    ap.add_argument("--no-time", action="store_true")
    a = ap.parse_args(argv)
    lines = window(read_lines(a.log), a.start, a.end, a.last)
    render(lines, a.out, a.title, not a.no_time)
    print("%s: %d lines" % (a.out, len(lines)))


if __name__ == "__main__":
    main(sys.argv[1:])
