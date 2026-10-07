#!/usr/bin/env python3
"""Find an example SEC-DED check-bit code that satisfies everything the 715
boot ROM's memory self-tests demand of the PA7100LC MIOC (F_f000cb90,
F_f000d2d0, F_f000d870 -- see docs/reference/rom/HARDWARE.md, "MIOC ECC").

HP's real H-matrix is not documented anywhere we have.  The ROM only pins it
down through these observations (one check byte per 64-bit doubleword):

  ECC(0x0000000000000000) == 0x33   (fill/scrub writes zeros with C4=0x33333333)
  ECC(0xFFFFFFFFFFFFFFFF) == 0xCC   (fill writes ones with C4=0xCCCCCCCC)
  ECC(0x01234567FEDCBA98) == 0x55   (ECC test reads DC back as 0x55555555)
  every single data-bit flip (64) and check-bit flip (8) is corrected (sedc)
  data double flip 0x01000400 (in either word)           -> uncorrectable (dedc)
  check-byte flips 0xD0, 0x0D (3 bits) and 0x88 (2 bits) -> uncorrectable (dedc)

so ECC(x) = H.x xor 0x33 with H.1 = 0xFF and H.(0x01234567FEDCBA98) = 0x66.
This script searches for odd-weight (Hsiao-style) columns meeting all of that
and prints them as a Verilog-friendly table.  Any code that passes the checks
at the bottom is good enough for the ROM.

usage: hwmap_ecc.py [seed]
"""
import random
import sys

CONST = 0x33
PATTERN = 0x01234567FEDCBA98
FORBIDDEN = {0xD0, 0x0D}          # 3-bit check flips the ROM expects to be fatal


def popcount(x):
    return bin(x).count("1")


def ecc(cols, d):
    c = CONST
    for j in range(64):
        if (d >> (63 - j)) & 1:   # j = 0 is the MSB (PA bit 0) of the doubleword
            c ^= cols[j]
    return c


def classify(cols, syndrome):
    """'ok', ('data', j), ('check', k) or 'dedc'."""
    if syndrome == 0:
        return "ok"
    if popcount(syndrome) == 1:
        return ("check", 7 - syndrome.bit_length() + 1)
    if syndrome in cols:
        return ("data", cols.index(syndrome))
    return "dedc"


def search(seed):
    rnd = random.Random(seed)
    allowed = [c for c in range(256) if popcount(c) in (3, 5) and c not in FORBIDDEN]
    dbits = [(PATTERN >> (63 - j)) & 1 for j in range(64)]
    for _ in range(200000):
        cols = rnd.sample(allowed, 64)
        # fix H.d = 0x66 with one swap at a d=1 position, then H.1 = 0xFF at a d=0 position
        for want, sel in ((0x55 ^ CONST, 1), (0xCC ^ CONST, 0)):   # H.d = 0x66, H.1 = 0xFF
            if sel == 1:
                cur = ecc(cols, PATTERN) ^ CONST
            else:
                cur = 0
                for c in cols:
                    cur ^= c
            delta = cur ^ want
            if delta == 0:
                continue
            done = False
            for j in rnd.sample(range(64), 64):
                if dbits[j] != sel:
                    continue
                nb = cols[j] ^ delta
                if nb in allowed and nb not in cols:
                    cols[j] = nb
                    done = True
                    break
            if not done:
                break
        if verify(cols, quiet=True):
            return cols
    return None


def verify(cols, quiet=False):
    ok = True

    def check(cond, msg):
        nonlocal ok
        if not cond:
            ok = False
            if not quiet:
                print("FAIL:", msg)

    check(len(set(cols)) == 64, "columns distinct")
    check(ecc(cols, 0) == 0x33, "ECC(0)=0x33")
    check(ecc(cols, (1 << 64) - 1) == 0xCC, "ECC(~0)=0xCC")
    check(ecc(cols, PATTERN) == 0x55, "ECC(pattern)=0x55")
    for j in range(64):
        s = ecc(cols, PATTERN ^ (1 << (63 - j))) ^ 0x55
        check(classify(cols, s) == ("data", j), "single data bit %d corrected" % j)
    for k in range(8):
        check(classify(cols, 0x80 >> k) == ("check", k), "single check bit %d" % k)
    for flip in (0x01000400 << 32, 0x01000400):
        s = ecc(cols, PATTERN ^ flip) ^ 0x55
        check(classify(cols, s) == "dedc", "double data flip %#x fatal" % flip)
    for s in (0xD0, 0x0D, 0x88):
        check(classify(cols, s) == "dedc", "check flip %#x fatal" % s)
    return ok


def main(argv):
    seed = int(argv[1]) if len(argv) > 1 else 715
    cols = search(seed)
    if not cols:
        print("no code found; try another seed")
        return 1
    verify(cols)
    print("// ECC(d) = 8'h33 ^ XOR of col[j] for every set bit j of d (j=0 is the MSB of the doubleword)")
    for j in range(0, 64, 8):
        print("// " + " ".join("%02x" % c for c in cols[j:j + 8]))
    print("// all ROM constraints satisfied (seed %d)" % seed)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
