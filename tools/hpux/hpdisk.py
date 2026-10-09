#!/usr/bin/env python3
"""Read an HP-UX (9.x/10.x/11.x, PA-RISC) boot disk image without root.

Handles the three layers between the disk and a file such as /stand/vmunix:

1. LIF volume at byte 0 (magic 0x8000): the boot area. Its directory holds
   ISL, HPUX (the secondary loader), AUTO, and on LVM disks LABEL.
   Header: 0 magic, 2 volume name, 8 directory start (256-byte sectors),
   16 directory length; 0xF0/0xF4/0xF8 IPL address/size/entry (bytes).
   Directory entries are 32 bytes: name[10], type u16, start u32, length u32
   (both in 256-byte sectors), date[6], ...; type 0xFFFF ends the directory.

2. Either LVM or a "whole disk" filesystem.
   LVM: "LVMREC01" at byte 8192 (the PV reserved area). Logical volumes
   are mapped through the VGDA, but the boot, root, swap and dump volumes
   must be contiguous, and the LIF file LABEL records where they are:
   16-byte records from byte 0x10, (0, start, length, 0), in 1 KiB units
   from the start of the disk -- boot (/stand), root, swap, dump. That is
   how the hpux loader finds /stand, and it is what we use too.
   Whole disk: no LVMREC01; the filesystem is found by scanning for an HFS
   superblock magic (--scan).

3. HFS, HP's 4.2BSD FFS. The superblock sits 8 KiB into the filesystem
   with the magic at byte 1372: 0x011954 (14-character names),
   0x095014 (long file names) or 0x195612 / 0x05231994 (later variants).
   Inodes and directories follow 4.3BSD (128-byte dinode: mode @0, size
   @8 as u64, 12 direct block pointers @40, 3 indirect @88; directory
   entries u32 ino, u16 reclen, u16 namlen, name). Block pointers are
   fragment numbers. The root filesystem on 10.20 is usually VxFS (magic
   0xa501fcf5 at 8 KiB), which this tool does not read (tools/hpux/vxfs.py
   does); /stand is HFS.

usage:
    hpdisk.py IMAGE lif                      list the LIF directory
    hpdisk.py IMAGE lifget NAME OUT          copy a LIF file out
    hpdisk.py IMAGE layout                   LVM record, LABEL areas, fs types
    hpdisk.py IMAGE ls  [PATH] [--fs N]      list an HFS directory
    hpdisk.py IMAGE cat PATH -o OUT [--fs N] copy an HFS file out
    hpdisk.py IMAGE ls ... --offset BYTES    use an HFS filesystem at BYTES
    hpdisk.py IMAGE scan                     look for HFS/VxFS superblocks

--fs selects the LABEL area (0 boot = /stand, the default; 1 root). IMAGE may
be qcow2 (read directly) or raw. Nothing is ever written to IMAGE.
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qcow2 import open_image  # noqa: E402

LIF_MAGIC = 0x8000
LIF_SECTOR = 256
HFS_MAGICS = {0x011954: "HFS", 0x095014: "HFS (long names)",
              0x195612: "HFS (FD)", 0x05231994: "HFS (B1)"}
VXFS_MAGIC = 0xA501FCF5
SBOFF = 8192
DINODE = 128
NDADDR, NIADDR = 12, 3
AREAS = ["boot", "root", "swap", "dump"]


def lif_dir(disk):
    h = disk.pread(0, 256)
    magic, = struct.unpack_from(">H", h, 0)
    if magic != LIF_MAGIC:
        return None, []
    dstart, = struct.unpack_from(">I", h, 8)
    dlen, = struct.unpack_from(">I", h, 16)
    ipl = struct.unpack_from(">III", h, 0xF0)
    ents = []
    d = disk.pread(dstart * LIF_SECTOR, dlen * LIF_SECTOR)
    for off in range(0, len(d), 32):
        name = d[off:off + 10].decode("ascii", "replace").rstrip()
        ftype, start, length = struct.unpack_from(">HII", d, off + 10)
        if ftype == 0xFFFF:
            break
        if ftype == 0:
            continue
        ents.append(dict(name=name, type=ftype, start=start * LIF_SECTOR,
                         size=length * LIF_SECTOR))
    vol = dict(name=h[2:8].decode("ascii", "replace").rstrip(),
               dir=dstart * LIF_SECTOR, ipl_addr=ipl[0], ipl_size=ipl[1],
               ipl_entry=ipl[2])
    return vol, ents


def lif_read(disk, name):
    _, ents = lif_dir(disk)
    for e in ents:
        if e["name"] == name:
            return disk.pread(e["start"], e["size"])
    raise SystemExit("LIF file %s not found" % name)


def label_areas(disk):
    """[(name, byte offset, byte length)] from the LIF LABEL file, or []."""
    _, ents = lif_dir(disk)
    if not any(e["name"] == "LABEL" for e in ents):
        return []
    d = lif_read(disk, "LABEL")
    out = []
    for i, n in enumerate(AREAS):
        start, length = struct.unpack_from(">II", d, 0x14 + 16 * i)
        out.append((n, start * 1024, length * 1024))
    return out


def fs_type(disk, off):
    sb = disk.pread(off + SBOFF, 2048)
    m, = struct.unpack_from(">I", sb, 1372)
    if m in HFS_MAGICS:
        return HFS_MAGICS[m]
    if struct.unpack_from(">I", sb, 0)[0] == VXFS_MAGIC:
        return "VxFS"
    return None


class HFS:
    def __init__(self, disk, base):
        self.d = disk
        self.base = base
        sb = disk.pread(base + SBOFF, 2048)
        magic, = struct.unpack_from(">I", sb, 1372)
        if magic not in HFS_MAGICS:
            raise SystemExit("no HFS superblock at byte %#x (magic %#x)"
                             % (base + SBOFF, magic))
        self.longnames = magic != 0x011954
        g = lambda o: struct.unpack_from(">i", sb, o)[0]
        self.iblkno = g(16)
        self.cgoffset, self.cgmask = g(24), g(28)
        self.size, self.ncg = g(36), g(44)
        self.bsize, self.fsize, self.frag = g(48), g(52), g(56)
        self.nindir, self.inopb = g(116), g(120)
        self.ipg, self.fpg = g(184), g(188)
        self.fsmnt = sb[212:212 + 512].split(b"\0")[0].decode("ascii", "replace")

    def _rd(self, fr, n):
        return self.d.pread(self.base + fr * self.fsize, n)

    def _cgstart(self, c):
        return self.fpg * c + self.cgoffset * (c & ~self.cgmask)

    def inode(self, ino):
        cg = ino // self.ipg
        fr = (self._cgstart(cg) + self.iblkno
              + ((ino % self.ipg) // self.inopb) * self.frag)
        raw = self._rd(fr, self.bsize)
        d = raw[(ino % self.inopb) * DINODE:][:DINODE]
        mode, nlink = struct.unpack_from(">Hh", d, 0)
        size, = struct.unpack_from(">Q", d, 8)
        mtime, = struct.unpack_from(">i", d, 24)
        return dict(ino=ino, mode=mode, nlink=nlink, size=size, mtime=mtime,
                    db=list(struct.unpack_from(">%di" % NDADDR, d, 40)),
                    ib=list(struct.unpack_from(">%di" % NIADDR, d, 88)))

    def _ind(self, fr):
        return struct.unpack(">%di" % self.nindir, self._rd(fr, self.bsize))

    def _blk(self, ino, i):
        if i < NDADDR:
            return ino["db"][i]
        i -= NDADDR
        n = self.nindir
        if i < n:
            return self._ind(ino["ib"][0])[i] if ino["ib"][0] else 0
        i -= n
        if i < n * n:
            if not ino["ib"][1]:
                return 0
            l1 = self._ind(ino["ib"][1])[i // n]
            return self._ind(l1)[i % n] if l1 else 0
        i -= n * n
        if not ino["ib"][2]:
            return 0
        l1 = self._ind(ino["ib"][2])[i // (n * n)]
        if not l1:
            return 0
        l2 = self._ind(l1)[(i // n) % n]
        return self._ind(l2)[i % n] if l2 else 0

    def read(self, ino):
        out = bytearray()
        n, i = ino["size"], 0
        if (ino["mode"] & 0o170000) == 0o120000 and n < 60 and not ino["db"][0]:
            return b""                    # fast symlink: not stored in blocks
        while len(out) < n:
            fr = self._blk(ino, i)
            want = min(self.bsize, n - len(out))
            out += self._rd(fr, want) if fr else bytes(want)
            i += 1
        return bytes(out[:n])

    def listdir(self, ino):
        d = self.read(ino)
        ents, off = [], 0
        while off + 8 <= len(d):
            i, reclen, namlen = struct.unpack_from(">IHH", d, off)
            if reclen < 8:
                break
            if i:
                ents.append((d[off + 8:off + 8 + namlen].decode("latin-1"), i))
            off += reclen
        return ents

    def lookup(self, path):
        cur = self.inode(2)
        for part in [p for p in path.split("/") if p]:
            if (cur["mode"] & 0o170000) != 0o040000:
                raise SystemExit("%s: not a directory" % part)
            for name, ino in self.listdir(cur):
                if name == part:
                    cur = self.inode(ino)
                    break
            else:
                raise SystemExit("%s: not found" % path)
        return cur


def pick_fs(disk, args):
    if args.offset is not None:
        return HFS(disk, args.offset)
    areas = label_areas(disk)
    if areas:
        return HFS(disk, areas[args.fs][1])
    for off in scan(disk, quiet=True):
        if fs_type(disk, off).startswith("HFS"):
            return HFS(disk, off)
    raise SystemExit("no HFS filesystem found")


def scan(disk, quiet=False, limit=512 << 20):
    found = []
    for off in range(0, min(disk.size, limit), 1024):
        t = fs_type(disk, off)
        if t:
            found.append(off)
            if not quiet:
                print("  %#012x  %s" % (off, t))
    return found


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image")
    ap.add_argument("cmd", choices=["lif", "lifget", "layout", "ls", "cat", "scan"])
    ap.add_argument("path", nargs="?", default="/")
    ap.add_argument("out", nargs="?")
    ap.add_argument("-o", "--output")
    ap.add_argument("--fs", type=int, default=0, help="LABEL area (0 boot, 1 root)")
    ap.add_argument("--offset", type=lambda s: int(s, 0), help="HFS byte offset")
    a = ap.parse_args(argv[1:])
    disk = open_image(a.image)

    if a.cmd == "lif":
        vol, ents = lif_dir(disk)
        if vol is None:
            raise SystemExit("no LIF volume at byte 0")
        print("LIF volume %r, directory at %#x, IPL addr %#x size %#x entry %#x"
              % (vol["name"], vol["dir"], vol["ipl_addr"], vol["ipl_size"],
                 vol["ipl_entry"]))
        for e in ents:
            print("  %-10s type %#06x  at %#010x  %8d bytes"
                  % (e["name"], e["type"], e["start"], e["size"]))
        return 0
    if a.cmd == "lifget":
        data = lif_read(disk, a.path)
        open(a.out or a.output, "wb").write(data)
        print("%s: %d bytes" % (a.path, len(data)), file=sys.stderr)
        return 0
    if a.cmd == "layout":
        lvm = disk.pread(8192, 64)
        print("LVM record: %s" % ("yes (LVMREC01 at 8 KiB)" if lvm[:8] == b"LVMREC01"
                                  else "no (whole-disk layout?)"))
        for n, off, ln in label_areas(disk):
            print("  %-4s at %#012x  %10d KiB  %s" % (n, off, ln // 1024,
                                                      fs_type(disk, off) or "-"))
        return 0
    if a.cmd == "scan":
        scan(disk)
        return 0

    fs = pick_fs(disk, a)
    ino = fs.lookup(a.path)
    if a.cmd == "ls":
        if (ino["mode"] & 0o170000) == 0o040000:
            for name, i in sorted(fs.listdir(ino)):
                s = fs.inode(i)
                kind = {0o040000: "d", 0o120000: "l"}.get(s["mode"] & 0o170000, "-")
                print("  %s%04o %10d %6d  %s" % (kind, s["mode"] & 0o7777,
                                                  s["size"], i, name))
        else:
            print("  -%04o %10d %6d  %s" % (ino["mode"] & 0o7777, ino["size"],
                                             ino["ino"], a.path))
        return 0
    data = fs.read(ino)
    out = a.output or a.out
    if out:
        open(out, "wb").write(data)
        print("%s: %d bytes -> %s" % (a.path, len(data), out), file=sys.stderr)
    else:
        sys.stdout.buffer.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
