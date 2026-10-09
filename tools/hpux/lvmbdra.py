#!/usr/bin/env python3
"""HP-UX 10.x LVM boot data reserved area (BDRA): show or rewrite the root
physical volume's hardware path.

The kernel activates the root volume group from the BDRA at LBA 256 of the
boot disk (8 KB, "HPLVMBDR"): `extract_bdra_info` checks the magic, a
checksum of the first 0x368 bytes (stored at +0x7FC) and a checksum of the
physical-volume path table at +0x800 (length at +0x1C4, checksum at +0x1D0);
`lv_pvlist` reads each PV's path from that table as 32-bit words -- the number
of elements, then the elements -- and `lv_hwpath_to_dev` looks the path up in
the I/O tree. A disk installed on another machine therefore fails with
"LVM: Activation of root volume group failed ... Could not configure root VG"
until the path is rewritten (HP-UX's own way is `hpux -lm` and `lvlnboot -R`).
tenox's HP-UX 10.20 image was installed on QEMU's B160L, whose PCI SCSI disk
is 8/0/0/0.6.0; the 715's LASI SCSI disk is 2/0/1.6.0.

    lvmbdra.py show IMG
    lvmbdra.py setpath IMG 2/0/1.6.0 [--save ORIGINAL.bin]

The checksum is the one `lv_checksum` computes: the byte sum folded twice into
16 bits.
"""
import argparse
import struct
import sys

BDRA_LBA = 256
BDRA_LEN = 8192
MAGIC = b"HPLVMBDR"
HDR_CKS_LEN = 0x368
HDR_CKS_AT = 0x7FC
PV_TABLE = 0x800
PV_LEN_AT = 0x1C4
PV_CKS_AT = 0x1D0


def checksum(buf):
    s = sum(buf) & 0xFFFFFFFF
    s = ((s >> 16) + (s & 0xFFFF)) & 0xFFFFFFFF
    s = ((s >> 16) + (s & 0xFFFF)) & 0xFFFFFFFF
    return s


def read_bdra(f):
    f.seek(BDRA_LBA * 512)
    b = bytearray(f.read(BDRA_LEN))
    if b[:8] != MAGIC:
        sys.exit("no BDRA at LBA %d (magic %r)" % (BDRA_LBA, bytes(b[:8])))
    return b


def pv_paths(b):
    """[(count, [elements])...] as lv_pvlist reads them, until a 0 count."""
    n = struct.unpack(">I", b[PV_LEN_AT:PV_LEN_AT + 4])[0]
    words = list(struct.unpack(">%dI" % (n // 4), b[PV_TABLE:PV_TABLE + n]))
    out, i = [], 0
    while i < len(words) and words[i]:
        c = words[i]
        out.append(words[i + 1:i + 1 + c])
        i += 1 + c
    return out


def fmt_path(p):
    return "/".join(str(x) for x in p[:-2]) + ".%d.%d" % tuple(p[-2:]) if len(p) >= 3 else "/".join(map(str, p))


def show(b):
    hc = struct.unpack(">I", b[HDR_CKS_AT:HDR_CKS_AT + 4])[0]
    pl = struct.unpack(">I", b[PV_LEN_AT:PV_LEN_AT + 4])[0]
    pc = struct.unpack(">I", b[PV_CKS_AT:PV_CKS_AT + 4])[0]
    print("header checksum %#x (computed %#x); PV table %d bytes, checksum %#x (computed %#x)" % (
        hc, checksum(b[:HDR_CKS_LEN]), pl, pc, checksum(b[PV_TABLE:PV_TABLE + pl])))
    for k, p in enumerate(pv_paths(b)):
        print("PV %d: %s  (words %s)" % (k, fmt_path(p), list(p)))


def setpath(b, path):
    el = [int(x) for x in path.replace(".", "/").split("/")]
    paths = pv_paths(b)
    if len(paths) != 1:
        sys.exit("expected one PV in the table, found %d" % len(paths))
    words = [len(el)] + el + [0]
    n = 4 * len(words)
    if n > 0x100:
        sys.exit("path too long")
    b[PV_TABLE:PV_TABLE + 0x100] = b"\0" * 0x100
    b[PV_TABLE:PV_TABLE + n] = struct.pack(">%dI" % len(words), *words)
    b[PV_LEN_AT:PV_LEN_AT + 4] = struct.pack(">I", n)
    b[PV_CKS_AT:PV_CKS_AT + 4] = struct.pack(">I", checksum(b[PV_TABLE:PV_TABLE + n]))
    b[HDR_CKS_AT:HDR_CKS_AT + 4] = struct.pack(">I", checksum(b[:HDR_CKS_LEN]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["show", "setpath"])
    ap.add_argument("image")
    ap.add_argument("path", nargs="?")
    ap.add_argument("--save", help="setpath: write the original 8 KB block here first")
    a = ap.parse_args()
    with open(a.image, "rb" if a.cmd == "show" else "r+b") as f:
        b = read_bdra(f)
        if a.cmd == "show":
            show(b)
            return
        if not a.path:
            sys.exit("setpath needs a path such as 2/0/1.6.0")
        if a.save:
            with open(a.save, "wb") as s:
                s.write(bytes(b))
        print("before:"); show(b)
        setpath(b, a.path)
        f.seek(BDRA_LBA * 512)
        f.write(bytes(b))
        print("after:"); show(b)


if __name__ == "__main__":
    main()
