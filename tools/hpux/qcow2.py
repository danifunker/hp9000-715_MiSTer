#!/usr/bin/env python3
"""Read-only random access to a qcow2 disk image, without qemu-nbd or root.

Only what reading an HP-UX install image needs: qcow2 v2/v3, no backing file,
no encryption, standard and zlib-compressed clusters, unallocated clusters
read as zeroes. The image file is opened read-only and never written.

    from qcow2 import open_image
    disk = open_image("hpux.img")      # also accepts a raw image
    data = disk.pread(offset, length)

Command line:
    qcow2.py IMAGE info
    qcow2.py IMAGE dump OFFSET LENGTH [-o OUT]   (hex numbers allowed)

Format (docs/interop/qcow2.txt in the QEMU tree): a big-endian header, then
guest offset -> L1 index (offset >> (cluster_bits + l2_bits)) -> L2 table ->
host cluster. L2 entry bit 62 set = compressed cluster: the low
x = 62 - (cluster_bits - 8) bits are the host byte offset, the bits above
are the number of additional 512-byte sectors holding the deflate stream.
"""
import struct
import sys
import zlib

QCOW_MAGIC = 0x514649FB
OFLAG_COPIED = 1 << 63
OFLAG_COMPRESSED = 1 << 62
OFFSET_MASK = 0x00FFFFFFFFFFFE00
L2E_ZERO = 1


class Qcow2:
    def __init__(self, path):
        self.f = open(path, "rb")
        h = self.f.read(112)
        (magic, version, backing_off, _bsize, cluster_bits, size,
         crypt, l1_size, l1_off) = struct.unpack(">IIQIIQIIQ", h[:48])
        if magic != QCOW_MAGIC:
            raise ValueError("%s: not qcow2" % path)
        if backing_off:
            raise ValueError("backing files are not supported")
        if crypt:
            raise ValueError("encrypted images are not supported")
        self.version = version
        self.size = size
        self.cluster_bits = cluster_bits
        self.cluster_size = 1 << cluster_bits
        self.l2_bits = cluster_bits - 3
        self.compression = 0
        if version >= 3:
            incompat, = struct.unpack(">Q", h[72:80])
            hdr_len, = struct.unpack(">I", h[100:104])
            if hdr_len > 104:
                self.compression = h[104]
            if incompat & ~0x3:           # bit 0 dirty, bit 1 corrupt are harmless
                raise ValueError("unsupported incompatible features %#x" % incompat)
            if self.compression != 0:
                raise ValueError("only zlib compression is supported")
        self.f.seek(l1_off)
        self.l1 = struct.unpack(">%dQ" % l1_size, self.f.read(8 * l1_size))
        self._l2cache = {}
        self._ccache = {}

    def _l2(self, off):
        t = self._l2cache.get(off)
        if t is None:
            self.f.seek(off)
            n = 1 << self.l2_bits
            t = struct.unpack(">%dQ" % n, self.f.read(8 * n))
            if len(self._l2cache) > 256:
                self._l2cache.clear()
            self._l2cache[off] = t
        return t

    def _cluster(self, idx):
        """Return the guest cluster `idx' as bytes (zeroes if unallocated)."""
        c = self._ccache.get(idx)
        if c is not None:
            return c
        cs = self.cluster_size
        l1i = idx >> self.l2_bits
        l2i = idx & ((1 << self.l2_bits) - 1)
        l1e = self.l1[l1i] if l1i < len(self.l1) else 0
        l2off = l1e & OFFSET_MASK
        if not l2off:
            c = bytes(cs)
        else:
            e = self._l2(l2off)[l2i]
            if e & OFLAG_COMPRESSED:
                x = 62 - (self.cluster_bits - 8)
                hoff = e & ((1 << x) - 1)
                nsec = ((e >> x) & ((1 << (62 - x)) - 1)) + 1
                self.f.seek(hoff)
                raw = self.f.read(nsec * 512 - (hoff & 511))
                c = zlib.decompressobj(-12).decompress(raw, cs)
                c = c.ljust(cs, b"\0")
            else:
                hoff = e & OFFSET_MASK
                if (e & L2E_ZERO) or not hoff:
                    c = bytes(cs)
                else:
                    self.f.seek(hoff)
                    c = self.f.read(cs)
        if len(self._ccache) > 64:
            self._ccache.clear()
        self._ccache[idx] = c
        return c

    def pread(self, off, n):
        out = bytearray()
        cs = self.cluster_size
        while n > 0:
            if off >= self.size:
                out += bytes(n)
                break
            idx, within = divmod(off, cs)
            take = min(n, cs - within)
            out += self._cluster(idx)[within:within + take]
            off += take
            n -= take
        return bytes(out)


class Raw:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.f.seek(0, 2)
        self.size = self.f.tell()

    def pread(self, off, n):
        self.f.seek(off)
        return self.f.read(n).ljust(n, b"\0")


def open_image(path):
    with open(path, "rb") as f:
        magic = f.read(4)
    if magic == b"QFI\xfb":
        return Qcow2(path)
    return Raw(path)


def _num(s):
    return int(s, 0)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    d = open_image(argv[1])
    if argv[2] == "info":
        print("size %d (%.1f MiB)" % (d.size, d.size / 2**20))
        if isinstance(d, Qcow2):
            print("qcow2 v%d, cluster %d, L1 %d entries, compression %d"
                  % (d.version, d.cluster_size, len(d.l1), d.compression))
        return 0
    if argv[2] == "dump":
        data = d.pread(_num(argv[3]), _num(argv[4]))
        if len(argv) > 6 and argv[5] == "-o":
            open(argv[6], "wb").write(data)
        else:
            sys.stdout.buffer.write(data)
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
