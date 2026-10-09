#!/usr/bin/env python3
"""Read the VxFS (HP "JFS") root filesystem of an HP-UX 10.x disk image.

Read-only; nothing is ever written to IMAGE. A port of the read path of
Linux's freevxfs driver (fs/freevxfs/), checked against the HP-UX 10.20
image disks/hpux1020.img, whose root logical volume is VxFS disk layout
version 3 with 1 KiB blocks. hpdisk.py finds the volume (the LIF LABEL
file's root area); this reads what is inside it.

On-disk layout, as found on the 10.20 image (all integers big-endian on
HP-UX; UnixWare's little-endian VxFS keeps its superblock at 1 KiB instead
of 8 KiB, which is how the byte order is told apart). Block numbers are in
filesystem blocks (vs_bsize) from the start of the volume.

1. Superblock at byte 8192: vs_magic 0xa501fcf5 @0, vs_version @4 (2..4
   readable), vs_bsize @32, vs_size @36 / vs_dsize @40 (blocks), vs_nindir
   @116 (entries per indirect address extent), vs_iaddrlen @164 (its length
   in blocks), vs_free @192, vs_clean @333 (0x5a = clean), vs_wtime @340,
   and from version 2 on vs_oltext[2] @368 (the object location table and
   its replica), vs_oltsize @376 (blocks), vs_dinosize @388 (inode size,
   256). Version 1's fixed allocation-unit fields (firstau, istart ...) are
   all zero: from version 2 everything is found through the OLT.

2. Object location table (OLT) at vs_oltext[0]: a header (magic 0xa504fcf5
   @0, olt_size @4 = header length, 56) then records {u32 type, u32 size,
   ...} to the end of the extent: 1 free, 2 FSHEAD {fsino[2]} = the fileset
   header inode and replica, 3 CUT {cutino}, 4 ILIST {iext[2]} = the block
   of the initial inode list and replica, 5 DEV {devino[2]}, 6 SB {sbino,
   -, logino[2], oltino[2]}. On the image: fileset header inode 3, initial
   inode list at block 16 (replica 2056), OLT at block 33.

3. Inodes are 256 bytes (struct vxfs_dinode): mode @0 (u32: the Unix
   S_IF* type and permission bits; types >= 0x10000000 are VxFS-internal --
   0x10000000 fileset header, 0x20000000 inode list, 0x30000000 IAU,
   0x40000000 current usage table, 0x12000000 OLT, 0x13000000 intent log,
   0x14000000 extent map, 0x17000000 device config), nlink @4, uid @8,
   gid @12, size @16 (u64), atime @24, mtime @32, ctime @40, orgtype @49
   (u8), ftarea @56 (directories: the ".." inode; devices: rdev, HP-UX
   major << 24 | minor), blocks @64, gen @68, then the 96-byte organisation
   area @80 and iattrino @176. The orgtype says how the data is found:
     1 ext4: spare @80, indsize @84, indir[2] @88, then 10 direct extents
       {u32 block, u32 length in blocks} @96. After the direct extents the
       file continues through indir[0], a single-indirect address extent of
       vs_iaddrlen blocks holding vs_nindir block numbers, each the start of
       a data extent of `indsize' blocks (0 = hole); indir[1] is double
       indirect (vs_nindir pointers to such address extents). (freevxfs
       reads only the first block of indir[0] and no double indirect.)
     2 immediate: the data itself is the 96-byte area (short directories,
       symlinks, small files).
     3 typed: 6 descriptors {u64 hdr = type << 56 | file offset in blocks,
       u32 block, u32 length}: type 2 data extent, type 1 an indirect
       extent of `length' blocks holding more 16-byte descriptors, types
       3/4 the 32-byte DEV4 forms (multi-device filesets; not supported,
       as in freevxfs). Offsets are absolute file block offsets (the extent
       map file, inode 10 of the initial list, shows 0, 8, 0x370 ...);
       freevxfs treats those inside an indirect extent as relative to it,
       which is the same thing for an indirect at offset 0 -- the only kind
       on the image -- and is rebased here should one ever show up.
   On the 10.20 image every regular file and big directory is ext4 with
   direct extents only, except 5 large files that are typed with one
   indirect extent at offset 0 (/usr/local/bin/nedit, a 7 MB patch kernel,
   three /var/adm/sw logs); no inode uses an ext4 indirect extent, so that
   path follows the VxFS description above but is untested. Holes (block 0
   or a gap between extents) read as zeroes; an inode's `blocks' count
   includes its indirect extents.
   The initial inode list is the first 32 inodes of the structural
   fileset: 3 fileset header, 4 IAU, 5 the structural inode list itself,
   6 CUT, 7 OLT, 8 device config, 9 intent log (1 MiB), 10 extent map;
   inodes 32 + n are their replicas.

4. Fileset header inode (type 0x10000000): one record per filesystem
   block, block 0 the structural fileset, block 1 the primary fileset (the
   files). struct vxfs_fsh: version @0, fsindex @4, ninodes @20, maxinode
   @40, iauino @44, ilistino[2] @48, lctino @56. The structural fileset's
   ilistino[0] is an inode of the initial list (5: its first 8 blocks are
   the initial list at block 16, then the replica's 8 at 2056, and so on);
   the primary fileset's ilistino[0] is an inode of that structural list
   (65 on the image; IAU 64, replicas at +32), and that file is the inode
   list of the files: inode n is the 256 bytes at n * 256 (36352 slots,
   typed extents). The root directory is inode 2.

5. Directories (vxfs_dir.h): every filesystem block of a directory starts
   with {u16 d_free, u16 d_nhash, u16 d_hash[d_nhash]} (the hash chains
   are only a lookup accelerator and ignored here), followed by entries
   {u32 ino, u16 reclen, u16 namelen, u16 hashnext, name}, padded to 4
   bytes; reclen 0 ends the block, ino 0 is a deleted entry. "." and ".."
   are not stored: ".." is the inode's ftarea. An immediate directory
   (orgtype 2) holds one such block in the inode's 96-byte area. (Checked
   on the image: for all 36104 inodes in use the link count equals the
   directory entries naming it, plus "." and the subdirectories' ".." for
   directories, and every subdirectory's ftarea names its parent.)

6. Symlinks: the target is the file data -- immediate (orgtype 2, up to
   96 bytes) or in blocks like a regular file.

usage:
    vxfs.py IMAGE info                    superblock, OLT and fileset summary
    vxfs.py IMAGE ls [PATH]               list a directory (or one entry)
    vxfs.py IMAGE cat PATH [-o OUT]       copy a file out (stdout without -o)
    vxfs.py IMAGE find PATTERN [PATH] [-l]   names matching an fnmatch PATTERN
    vxfs.py IMAGE get PATH -o DIR         copy a file or a directory tree out
                                          (symlinks recreated, devices skipped)
    vxfs.py IMAGE stat PATH               one inode in detail, with its extents

The volume is found from the LIF LABEL file (the root area, or the first
VxFS one), else by scanning; --offset BYTES gives it directly, --fs N picks
the LABEL area (0 boot, 1 root). Symlinks are followed in the middle of a
path, and at its end for cat/get/ls of a directory, not by find. IMAGE may be
raw or qcow2.
"""
import argparse
import bisect
import fnmatch
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qcow2 import open_image  # noqa: E402
import hpdisk  # noqa: E402

VXFS_MAGIC = 0xA501FCF5
OLT_MAGIC = 0xA504FCF5
ROOT_INO = 2
NDADDR = 10

# struct vxfs_sb, version 1 read-only part: 48 u32 fields from byte 0
SB_V1 = ("magic version ctime cutime - - old_logstart old_logend bsize size "
         "dsize old_ninode old_nau - old_defiextsize old_ilbsize immedlen "
         "ndaddr firstau emap imap iextop istart bstart femap fimap fiextop "
         "fistart fbstart nindir aulen auimlen auemlen auilen aupad aublocks "
         "maxtier inopb old_inopau old_inopilb old_ndiripau iaddrlen bshift "
         "inoshift bmask boffmask old_inomask checksum").split()

# OLT record types
OLT_FREE, OLT_FSHEAD, OLT_CUT, OLT_ILIST, OLT_DEV, OLT_SB = 1, 2, 3, 4, 5, 6

# file types: the Unix ones (mode & 0xf000) and the VxFS-internal ones
TYPE_MASK = 0xFFFFF000
IFIFO, IFCHR, IFDIR, IFNAM, IFBLK = 0x1000, 0x2000, 0x4000, 0x5000, 0x6000
IFREG, IFNWK, IFLNK, IFSOC = 0x8000, 0x9000, 0xA000, 0xC000
IFFSH, IFILT = 0x10000000, 0x20000000
TYPE_CHAR = {IFIFO: "p", IFCHR: "c", IFDIR: "d", IFNAM: "n", IFBLK: "b",
             IFREG: "-", IFNWK: "n", IFLNK: "l", IFSOC: "s"}
INTERNAL = {0x10000000: "fileset header", 0x20000000: "inode list",
            0x30000000: "IAU", 0x40000000: "current usage table",
            0x50000000: "attribute", 0x60000000: "link count table",
            0x70000000: "indirect attribute", 0x80000000: "extent map reorg",
            0x90000000: "quota", 0xA0000000: "pass-through",
            0x11000000: "device label", 0x12000000: "OLT",
            0x13000000: "intent log", 0x14000000: "extent map",
            0x15000000: "extent AU", 0x16000000: "extent AU summary",
            0x17000000: "device config"}

ORG_NONE, ORG_EXT4, ORG_IMMED, ORG_TYPED = 0, 1, 2, 3
ORG_NAMES = {0: "none", 1: "ext4", 2: "immediate", 3: "typed"}
TYPED_INDIRECT, TYPED_DATA = 1, 2
TYPED_OFFMASK = (1 << 56) - 1


class VxFSError(Exception):
    pass


class Inode:
    """One decoded struct vxfs_dinode."""

    def __init__(self, fs, ino, raw):
        e = fs.e
        self.ino = ino
        (self.mode, self.nlink, self.uid, self.gid, self.size,
         self.atime, _, self.mtime, _, self.ctime, _) = \
            struct.unpack_from(e + "IIIIQ6I", raw, 0)
        self.aflags, self.orgtype = raw[48], raw[49]
        self.ftarea, = struct.unpack_from(e + "I", raw, 56)
        self.blocks, self.gen = struct.unpack_from(e + "II", raw, 64)
        self.org = raw[80:176]

    @property
    def type(self):
        return self.mode & TYPE_MASK

    def isdir(self):
        return self.type == IFDIR

    def islnk(self):
        return self.type == IFLNK

    def isreg(self):
        return self.type == IFREG

    def isdev(self):
        return self.type in (IFCHR, IFBLK)

    def modestr(self):
        m = self.mode
        s = TYPE_CHAR.get(self.type, "?")
        for i, (r, w, x, spec, sc) in enumerate(
                ((0o400, 0o200, 0o100, 0o4000, "s"),
                 (0o040, 0o020, 0o010, 0o2000, "s"),
                 (0o004, 0o002, 0o001, 0o1000, "t"))):
            s += "r" if m & r else "-"
            s += "w" if m & w else "-"
            if m & spec:
                s += sc if m & x else sc.upper()
            else:
                s += "x" if m & x else "-"
        return s


class VxFS:
    def __init__(self, disk, base):
        self.d = disk
        self.base = base
        raw = disk.pread(base + 8192, 1024)
        if struct.unpack_from(">I", raw, 0)[0] == VXFS_MAGIC:
            self.e, self.sboff = ">", 8192          # HP-UX, PA-RISC
        else:
            raw = disk.pread(base + 1024, 1024)
            if struct.unpack_from("<I", raw, 0)[0] != VXFS_MAGIC:
                raise VxFSError("no VxFS superblock at byte %#x (+8 KiB BE, "
                                "+1 KiB LE)" % base)
            self.e, self.sboff = "<", 1024          # UnixWare, x86
        self.sb = self._parse_sb(raw)
        sb = self.sb
        if not 2 <= sb["version"] <= 4:
            raise VxFSError("VxFS version %d: only 2..4 have an OLT"
                            % sb["version"])
        self.bsize = sb["bsize"]
        self.isize = sb["dinosize"] or 256
        self.nindir = sb["nindir"] or self.bsize // 4
        self._read_olt()
        self._read_fileset_headers()

    # -- low level -------------------------------------------------------

    def _u32(self, b, off, n=1):
        v = struct.unpack_from("%s%dI" % (self.e, n), b, off)
        return v if n > 1 else v[0]

    def rblk(self, blk, n=1):
        return self.d.pread(self.base + blk * self.bsize, n * self.bsize)

    def _parse_sb(self, raw):
        e = self.e
        sb = {n: v for n, v in zip(SB_V1, struct.unpack_from(e + "48I", raw, 0))
              if n != "-"}
        sb["free"], sb["ifree"] = struct.unpack_from(e + "II", raw, 192)
        sb["efree"] = struct.unpack_from(e + "32I", raw, 200)
        sb["flags"], = struct.unpack_from(e + "I", raw, 328)
        sb["mod"], sb["clean"] = raw[332], raw[333]
        sb["firstlogid"], sb["wtime"], sb["wutime"] = \
            struct.unpack_from(e + "III", raw, 336)
        sb["fname"] = raw[348:354].split(b"\0")[0].decode("latin-1")
        sb["fpack"] = raw[354:360].split(b"\0")[0].decode("latin-1")
        sb["logversion"], = struct.unpack_from(e + "I", raw, 360)
        (o0, o1, sb["oltsize"], sb["iauimlen"], sb["iausize"],
         sb["dinosize"], sb["old_dniaddr"], sb["checksum2"]) = \
            struct.unpack_from(e + "8I", raw, 368)
        sb["oltext"] = (o0, o1)
        return sb

    # -- OLT, fileset headers --------------------------------------------

    def _read_olt(self):
        self.olt = []
        blk, size, seen = self.sb["oltext"][0], self.sb["oltsize"], set()
        self.fshino = self.iext = None
        while blk and blk not in seen:
            seen.add(blk)
            b = self.rblk(blk, max(size, 1))
            if self._u32(b, 0) != OLT_MAGIC:
                raise VxFSError("bad OLT magic at block %d" % blk)
            hlen = self._u32(b, 4)
            nxt, nsize = self._u32(b, 40), self._u32(b, 48)
            off = hlen
            while off + 8 <= len(b):
                t, rlen = self._u32(b, off, 2)
                if rlen < 8:
                    break
                rec = b[off:off + rlen]
                self.olt.append((t, rec))
                if t == OLT_FSHEAD and self.fshino is None:
                    self.fshino = self._u32(rec, 8)
                elif t == OLT_ILIST and self.iext is None:
                    self.iext = self._u32(rec, 8)
                off += rlen
            blk, size = nxt, nsize
        if not self.fshino or not self.iext:
            raise VxFSError("OLT has no fileset header or initial inode list")

    def _blkiget(self, ino):
        """An inode of the initial inode list (fixed place, block iext)."""
        off = self.iext * self.bsize + ino * self.isize
        return Inode(self, ino, self.d.pread(self.base + off, self.isize))

    def _fsh(self, raw):
        e = self.e
        v = struct.unpack_from(e + "15I", raw, 0)
        return dict(version=v[0], fsindex=v[1], time=v[2], extop=v[4],
                    ninodes=v[5], nau=v[6], dflags=v[8], quota=v[9],
                    maxinode=v[10], iauino=v[11], ilistino=(v[12], v[13]),
                    lctino=v[14])

    def _read_fileset_headers(self):
        self.fship = self._blkiget(self.fshino)
        if self.fship.type != IFFSH:
            raise VxFSError("fileset header inode %d has type %#x"
                            % (self.fshino, self.fship.type))
        self.fsh_struct = self._fsh(self.read(self.fship, 0, self.bsize))
        self.fsh_primary = self._fsh(self.read(self.fship, self.bsize,
                                               self.bsize))
        self.stilist = self._blkiget(self.fsh_struct["ilistino"][0])
        if self.stilist.type != IFILT:
            raise VxFSError("structural inode list inode %d has type %#x"
                            % (self.stilist.ino, self.stilist.type))
        self._stilist_map = self._map(self.stilist)
        self.ilist = self._iget_from(self._stilist_map,
                                     self.fsh_primary["ilistino"][0])
        if self.ilist.type != IFILT:
            raise VxFSError("inode list inode %d has type %#x"
                            % (self.ilist.ino, self.ilist.type))
        self._ilist_map = self._map(self.ilist)

    def _iget_from(self, listmap, ino):
        raw = self._read_mapped(listmap, ino * self.isize, self.isize)
        return Inode(self, ino, raw)

    def iget(self, ino):
        """An inode of the primary fileset (the files)."""
        if ino * self.isize >= self.ilist.size:
            raise VxFSError("inode %d beyond the inode list" % ino)
        return self._iget_from(self._ilist_map, ino)

    # -- block mapping ---------------------------------------------------

    def extents(self, ip):
        """[(file block, disk block, nblocks)] for ext4/typed inodes."""
        if ip.orgtype == ORG_EXT4:
            out = self._ext4(ip)
        elif ip.orgtype == ORG_TYPED:
            out = []
            self._typed(ip.org, out, 0)
        else:
            return []
        out.sort()
        return out

    def _ext4(self, ip):
        org = ip.org
        indsize = self._u32(org, 4)
        indir = self._u32(org, 8, 2)
        need = (ip.size + self.bsize - 1) // self.bsize
        out, fb = [], 0
        for i in range(NDADDR):
            blk, n = self._u32(org, 16 + 8 * i, 2)
            if n:
                if blk:
                    out.append((fb, blk, n))
                fb += n
        if fb >= need or not indsize:
            return out
        n = self.nindir
        alen = self.sb["iaddrlen"] or (n * 4 + self.bsize - 1) // self.bsize

        def single(ablk, fb):
            ents = self._u32(self.rblk(ablk, alen), 0, n)
            for e in ents:
                if fb >= need:
                    break
                if e:
                    out.append((fb, e, indsize))
                fb += indsize
            return fb

        if indir[0]:
            fb = single(indir[0], fb)
        else:
            fb += n * indsize
        if fb < need and indir[1]:
            for a in self._u32(self.rblk(indir[1], alen), 0, n):
                if fb >= need:
                    break
                if a:
                    fb = single(a, fb)
                else:
                    fb += n * indsize
        return out

    def _typed(self, descs, out, depth):
        if depth > 8:
            raise VxFSError("typed extents nested too deep")
        for off in range(0, len(descs) - 15, 16):
            hdr, = struct.unpack_from(self.e + "Q", descs, off)
            blk, n = self._u32(descs, off + 8, 2)
            t, foff = hdr >> 56, hdr & TYPED_OFFMASK
            if t == 0:
                continue                      # unused slot
            if t == TYPED_DATA:
                out.append((foff, blk, n))
            elif t == TYPED_INDIRECT:
                sub = []
                self._typed(self.rblk(blk, n), sub, depth + 1)
                # Children carry absolute file offsets; should a VxFS ever
                # store them relative to the indirect extent (as freevxfs's
                # vxfs_bmap_indir assumes), rebase them.
                if sub and foff and min(s[0] for s in sub) < foff:
                    sub = [(s[0] + foff, s[1], s[2]) for s in sub]
                out.extend(sub)
            else:
                raise VxFSError("typed extent type %d (DEV4) not supported" % t)

    def _map(self, ip):
        ext = self.extents(ip)
        return (ip, ext, [x[0] for x in ext])

    def _read_mapped(self, m, off, n):
        ip, ext, starts = m
        if ip.orgtype == ORG_IMMED:
            return ip.org[off:off + n].ljust(n, b"\0")
        bs = self.bsize
        out = bytearray()
        end = off + n
        i = max(bisect.bisect_right(starts, off // bs) - 1, 0)
        pos = off
        while pos < end:
            while i < len(ext) and (ext[i][0] + ext[i][2]) * bs <= pos:
                i += 1
            if i >= len(ext) or ext[i][0] * bs > pos:
                # hole up to the next extent (or the end)
                nxt = ext[i][0] * bs if i < len(ext) else end
                take = min(nxt, end) - pos
                out += bytes(take)
            else:
                fb, db, cnt = ext[i]
                take = min((fb + cnt) * bs, end) - pos
                out += self.d.pread(self.base + db * bs + (pos - fb * bs), take)
            pos += take
        return bytes(out)

    def read(self, ip, off=0, n=None):
        if n is None:
            n = max(ip.size - off, 0)
        if ip.orgtype not in (ORG_EXT4, ORG_IMMED, ORG_TYPED):
            if ip.size == 0:
                return b""
            raise VxFSError("inode %d: organisation type %d not readable"
                            % (ip.ino, ip.orgtype))
        return self._read_mapped(self._map(ip), off, n)

    # -- directories, symlinks, paths ------------------------------------

    def listdir(self, ip):
        """[(name, ino)] of a directory, without "." and ".."."""
        if not ip.isdir():
            raise VxFSError("inode %d is not a directory" % ip.ino)
        data = self.read(ip)
        limit = min((ip.size + 3) & ~3, len(data))
        bs = self.bsize
        ents, pos = [], 0
        while pos < limit:
            if pos % bs == 0:                 # block header + hash chains
                nhash, = struct.unpack_from(self.e + "H", data, pos + 2)
                pos += 4 + 2 * nhash
            if pos + 10 > limit:
                break
            ino, = struct.unpack_from(self.e + "I", data, pos)
            reclen, namelen = struct.unpack_from(self.e + "HH", data, pos + 4)
            if reclen == 0:
                pos = (pos // bs + 1) * bs     # rest of the block is empty
                continue
            if reclen < 10 or pos % bs + reclen > bs:
                raise VxFSError("inode %d: bad directory entry at %d"
                                % (ip.ino, pos))
            if ino:
                ents.append((data[pos + 10:pos + 10 + namelen]
                             .decode("latin-1"), ino))
            pos += reclen
        return ents

    def readlink(self, ip):
        return self.read(ip).split(b"\0")[0].decode("latin-1")

    def lookup(self, path, follow=True, _depth=0):
        """Resolve PATH to (inode, canonical path). Symlinks in the middle
        are always followed, the last component only if `follow'."""
        parts = [p for p in path.split("/") if p]
        cur, curpath = self.iget(ROOT_INO), []
        hops = 0
        while parts:
            part = parts.pop(0)
            if part == ".":
                continue
            if part == "..":
                cur = self.iget(cur.ftarea or ROOT_INO)
                curpath = curpath[:-1]
                continue
            if not cur.isdir():
                raise VxFSError("/%s: not a directory" % "/".join(curpath))
            for name, ino in self.listdir(cur):
                if name == part:
                    nxt = self.iget(ino)
                    break
            else:
                raise VxFSError("/%s: not found"
                                % "/".join(curpath + [part]))
            if nxt.islnk() and (parts or follow):
                hops += 1
                if hops > 40:
                    raise VxFSError("%s: too many symlinks" % path)
                target = self.readlink(nxt)
                parts = [p for p in target.split("/") if p] + parts
                if target.startswith("/"):
                    cur, curpath = self.iget(ROOT_INO), []
                continue
            cur = nxt
            curpath.append(part)
        return cur, "/" + "/".join(curpath)

    def walk(self, ip, path):
        """Yield (path, name, inode) below directory `ip', depth first,
        not following symlinks."""
        stack, seen = [(ip, path)], {ip.ino}
        while stack:
            d, dpath = stack.pop()
            subdirs = []
            for name, ino in sorted(self.listdir(d)):
                c = self.iget(ino)
                p = dpath.rstrip("/") + "/" + name
                yield p, name, c
                if c.isdir() and ino not in seen:
                    seen.add(ino)
                    subdirs.append((c, p))
            stack.extend(reversed(subdirs))


# -- volume selection ----------------------------------------------------

def find_volume(disk, offset=None, area=None):
    if offset is not None:
        return offset
    areas = hpdisk.label_areas(disk)
    if areas:
        if area is not None:
            return areas[area][1]
        for name, off, _ in areas:
            if hpdisk.fs_type(disk, off) == "VxFS":
                return off
    for off in hpdisk.scan(disk, quiet=True):
        if hpdisk.fs_type(disk, off) == "VxFS":
            return off
    raise SystemExit("no VxFS filesystem found (give --offset)")


# -- command line --------------------------------------------------------

def _date(t):
    return time.strftime("%Y-%m-%d %H:%M", time.gmtime(t))


def longline(fs, ip, name):
    if ip.isdev():
        size = "%3d,%#08x" % (ip.ftarea >> 24, ip.ftarea & 0xFFFFFF)
    else:
        size = "%12d" % ip.size
    line = "%s %3d %5d %5d %s %s %7d  %s" % (ip.modestr(), ip.nlink, ip.uid,
                                             ip.gid, size, _date(ip.mtime),
                                             ip.ino, name)
    if ip.islnk():
        line += " -> " + fs.readlink(ip)
    return line


def cmd_info(fs, a):
    sb = fs.sb
    print("VxFS at byte %#x: version %d, %s-endian, superblock at +%d"
          % (fs.base, sb["version"], "big" if fs.e == ">" else "little",
             fs.sboff))
    print("  block size %d, %d blocks (%d data, %d free) = %.1f MiB, "
          "%.1f MiB free"
          % (fs.bsize, sb["size"], sb["dsize"], sb["free"],
             sb["size"] * fs.bsize / 2**20, sb["free"] * fs.bsize / 2**20))
    print("  created %s, last written %s, %s (vs_clean %#x), log version %d"
          % (_date(sb["ctime"]), _date(sb["wtime"]),
             "clean" if sb["clean"] == 0x5A else "NOT clean", sb["clean"],
             sb["logversion"]))
    print("  AU %d blocks, inode size %d, immediate area %d, indirect address "
          "extent %d blocks = %d entries"
          % (sb["aulen"], fs.isize, sb["immedlen"], sb["iaddrlen"], fs.nindir))
    print("  OLT at block %d (replica %d), %d block(s)"
          % (sb["oltext"][0], sb["oltext"][1], sb["oltsize"]))
    names = {OLT_FREE: "free", OLT_FSHEAD: "fileset header", OLT_CUT: "CUT",
             OLT_ILIST: "initial inode list", OLT_DEV: "device config",
             OLT_SB: "superblock/log/OLT"}
    for t, rec in fs.olt:
        if t == OLT_FREE:
            continue
        vals = fs._u32(rec, 8, (len(rec) - 8) // 4) if len(rec) > 12 else \
            (fs._u32(rec, 8),)
        print("    OLT %-20s %s" % (names.get(t, "type %d" % t),
                                    " ".join(str(v) for v in vals)))
    for what, h in (("structural", fs.fsh_struct), ("primary", fs.fsh_primary)):
        print("  %s fileset: index %d, %d inodes (max %d), ilist inode %d "
              "(replica %d), IAU inode %d, LCT inode %d"
              % (what, h["fsindex"], h["ninodes"], h["maxinode"],
                 h["ilistino"][0], h["ilistino"][1], h["iauino"], h["lctino"]))
    print("  primary inode list: %d bytes = %d inodes, %s"
          % (fs.ilist.size, fs.ilist.size // fs.isize,
             ORG_NAMES.get(fs.ilist.orgtype, "?")))
    return 0


def cmd_ls(fs, a):
    path = a.args[0] if a.args else "/"
    ip, canon = fs.lookup(path, follow=False)
    if ip.islnk():
        try:
            tip, _ = fs.lookup(path, follow=True)
            if tip.isdir():
                ip = tip
        except VxFSError:
            pass
    if not ip.isdir():
        print(longline(fs, ip, canon))
        return 0
    print(longline(fs, ip, "."))
    print(longline(fs, fs.iget(ip.ftarea or ROOT_INO), ".."))
    for name, ino in sorted(fs.listdir(ip)):
        print(longline(fs, fs.iget(ino), name))
    return 0


def cmd_cat(fs, a):
    if not a.args:
        raise SystemExit("cat needs a PATH")
    ip, canon = fs.lookup(a.args[0])
    if not ip.isreg():
        raise SystemExit("%s: not a regular file (%s)"
                         % (canon, ip.modestr()[0]))
    data = fs.read(ip)
    if a.output:
        with open(a.output, "wb") as f:
            f.write(data)
        print("%s: %d bytes -> %s" % (canon, len(data), a.output),
              file=sys.stderr)
    else:
        sys.stdout.buffer.write(data)
    return 0


def cmd_find(fs, a):
    if not a.args:
        raise SystemExit("find needs a PATTERN")
    pat = a.args[0]
    path = a.args[1] if len(a.args) > 1 else "/"
    ip, canon = fs.lookup(path)
    if not ip.isdir():
        raise SystemExit("%s: not a directory" % canon)
    for p, name, c in fs.walk(ip, path if path.startswith("/") else canon):
        if fnmatch.fnmatchcase(name, pat):
            print(longline(fs, c, p) if a.long else p)
    return 0


def _get(fs, ip, dest, path, stats):
    if ip.isdir():
        os.makedirs(dest, exist_ok=True)
        for name, ino in sorted(fs.listdir(ip)):
            _get(fs, fs.iget(ino), os.path.join(dest, name),
                 path.rstrip("/") + "/" + name, stats)
    elif ip.islnk():
        t = fs.readlink(ip)
        if os.path.lexists(dest):
            os.unlink(dest)
        os.symlink(t, dest)
        print("  %s -> %s" % (path, t), file=sys.stderr)
        stats[1] += 1
    elif ip.isreg():
        data = fs.read(ip)
        with open(dest, "wb") as f:
            f.write(data)
        os.chmod(dest, (ip.mode & 0o777) | 0o600)
        print("  %s  %d bytes" % (path, len(data)), file=sys.stderr)
        stats[0] += 1
        stats[2] += len(data)
    else:
        print("  %s  skipped (%s)" % (path, ip.modestr()), file=sys.stderr)


def cmd_get(fs, a):
    if not a.args or not a.output:
        raise SystemExit("get needs PATH and -o DIR")
    ip, canon = fs.lookup(a.args[0])
    dest = a.output
    if ip.isdir():
        os.makedirs(dest, exist_ok=True)
    elif os.path.isdir(dest):
        dest = os.path.join(dest, os.path.basename(canon))
    stats = [0, 0, 0]
    _get(fs, ip, dest, canon, stats)
    print("%d files (%d bytes), %d symlinks -> %s"
          % (stats[0], stats[2], stats[1], dest), file=sys.stderr)
    return 0


def cmd_stat(fs, a):
    path = a.args[0] if a.args else "/"
    ip, canon = fs.lookup(path, follow=False)
    print(longline(fs, ip, canon))
    t = INTERNAL.get(ip.type & 0xFF000000) if ip.type >= 0x10000000 else None
    print("  inode %d, mode %#x%s, nlink %d, uid %d, gid %d, size %d, "
          "blocks %d, gen %d" % (ip.ino, ip.mode, " (%s)" % t if t else "",
                                 ip.nlink, ip.uid, ip.gid, ip.size, ip.blocks,
                                 ip.gen))
    print("  atime %s  mtime %s  ctime %s" % (_date(ip.atime), _date(ip.mtime),
                                              _date(ip.ctime)))
    print("  org %s, ftarea %#x" % (ORG_NAMES.get(ip.orgtype, ip.orgtype),
                                     ip.ftarea))
    if ip.orgtype == ORG_EXT4:
        print("  indsize %d, indir %d %d" % ((fs._u32(ip.org, 4),)
                                             + fs._u32(ip.org, 8, 2)))
    if ip.orgtype == ORG_IMMED:
        print("  immediate: %s" % ip.org[:min(ip.size, 96)])
    for fb, db, n in fs.extents(ip):
        print("  file block %8d  disk block %8d  %6d blocks" % (fb, db, n))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(
        description=__doc__.split("\n")[0],
        epilog="See the module docstring for the on-disk layout.")
    ap.add_argument("image")
    ap.add_argument("cmd", choices=["info", "ls", "cat", "find", "get", "stat"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("-o", "--output")
    ap.add_argument("-l", "--long", action="store_true", help="find: ls -l lines")
    ap.add_argument("--offset", type=lambda s: int(s, 0),
                    help="byte offset of the VxFS volume in IMAGE")
    ap.add_argument("--fs", type=int, help="LIF LABEL area (0 boot, 1 root)")
    a = ap.parse_args(argv[1:])
    disk = open_image(a.image)
    try:
        fs = VxFS(disk, find_volume(disk, a.offset, a.fs))
        return {"info": cmd_info, "ls": cmd_ls, "cat": cmd_cat,
                "find": cmd_find, "get": cmd_get, "stat": cmd_stat}[a.cmd](fs, a)
    except VxFSError as ex:
        raise SystemExit("vxfs: %s" % ex)
    except BrokenPipeError:
        sys.stderr.close()
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
