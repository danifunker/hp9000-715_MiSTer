#!/usr/bin/env python3
"""Read HP SOM (System Object Model) executables -- HP-UX 9.x/10.x kernels
(/stand/vmunix), ISL and the hpux loader -- and disassemble them with symbols.

Layouts from the PA-RISC Run-time Architecture Document (SOM), in
docs/reference/txt/Pa-runtime-32-SOM.txt: header Fig. 3-9 (line 1813),
space record Fig. 3-11 (2274), subspace record (2498), symbol record
Fig. 3-13 (3677), symbol types Table 16 (3786), exec aux header Fig. 6-32
(5828). Everything is big-endian.

Symbol values of code symbols carry the privilege level in their low two
bits (3 = user); kernel code is PL0, but the bits are masked anyway.

usage:
    som.py FILE info                    header, aux header, spaces, subspaces
    som.py FILE syms [--all]            symbols sorted by address (code/data/entry)
    som.py FILE addr ADDR...            ADDR -> symbol+offset
    som.py FILE sym NAME...             NAME -> address
    som.py FILE dis [-o OUT]            whole loadable text, objdump + labels
    som.py FILE dis --func NAME [...]   one or more functions
    som.py FILE dis --range START END   an address range
    som.py FILE calls NAME [--args N]   every BL/B,L/BLE whose target is NAME
                                        (direct, via linker stubs, ldil/ble
                                        pairs); --args shows constant r26..
    som.py FILE image OUT               text+data as a flat image at exec_tmem

The disassembly runs hppa-linux-gnu-objdump on the text section as a raw
binary (-m hppa1.1), then puts a "<symbol>:" label before each symbol and
replaces absolute branch targets and ldil/ldo address pairs with names.
"""
import argparse
import bisect
import os
import re
import struct
import subprocess
import sys
import tempfile

OBJDUMP = os.environ.get("OBJDUMP", "hppa-linux-gnu-objdump")

SYM_TYPES = {0: "NULL", 1: "ABSOLUTE", 2: "DATA", 3: "CODE", 4: "PRI_PROG",
             5: "SEC_PROG", 6: "ENTRY", 7: "STORAGE", 8: "STUB", 9: "MODULE",
             10: "SYM_EXT", 11: "ARG_EXT", 12: "MILLICODE", 13: "PLABEL",
             14: "OCT_DIS", 15: "MILLI_EXT", 16: "TSTORAGE", 17: "COMDAT"}
SCOPES = {0: "UNSAT", 1: "EXTERNAL", 2: "LOCAL", 3: "UNIVERSAL"}
CODE_TYPES = {"CODE", "PRI_PROG", "SEC_PROG", "ENTRY", "MILLICODE", "STUB"}

HDR_FIELDS = ("system_id a_magic version_id clock_s clock_ns entry_space "
              "entry_subspace entry_offset aux_header_location aux_header_size "
              "som_length presumed_dp space_location space_total "
              "subspace_location subspace_total loader_fixup_location "
              "loader_fixup_total space_strings_location space_strings_size "
              "init_array_location init_array_total compiler_location "
              "compiler_total symbol_location symbol_total "
              "fixup_request_location fixup_request_total "
              "symbol_strings_location symbol_strings_size "
              "unloadable_sp_location unloadable_sp_size checksum").split()


class SOM:
    def __init__(self, path):
        self.path = path
        self.data = open(path, "rb").read()
        d = self.data
        v = struct.unpack_from(">hhI" + "I" * 30, d, 0)
        self.hdr = dict(zip(HDR_FIELDS, v))
        h = self.hdr
        if h["system_id"] not in (0x20B, 0x210, 0x214):
            raise SystemExit("%s: not a PA-RISC SOM (system_id %#x)"
                             % (path, h["system_id"]))
        self.aux = None
        loc, end = h["aux_header_location"], h["aux_header_location"] + h["aux_header_size"]
        while loc + 8 <= end:
            aid, alen = struct.unpack_from(">II", d, loc)
            if aid & 0xFFFF == 4:                     # exec auxiliary header
                f = struct.unpack_from(">10I", d, loc + 8)
                self.aux = dict(zip("tsize tmem tfile dsize dmem dfile bsize "
                                    "entry flags bfill".split(), f))
            loc += 8 + alen
        sstr = h["space_strings_location"]
        name = lambda off: d[sstr + off:d.index(b"\0", sstr + off)].decode("latin-1")
        self.spaces = []
        for i in range(h["space_total"]):
            o = h["space_location"] + 36 * i
            n, flags, num, ssi, ssq = struct.unpack_from(">IIiiI", d, o)
            self.spaces.append(dict(name=name(n), loadable=bool(flags >> 31),
                                    number=num, sub_index=ssi, sub_count=ssq))
        self.subspaces = []
        for i in range(h["subspace_total"]):
            o = h["subspace_location"] + 40 * i
            sp, flags, floc, ilen, start, length, align, n = \
                struct.unpack_from(">iIiIIIII", d, o)
            self.subspaces.append(dict(space=sp, name=name(n), file_loc=floc,
                                       init_len=ilen, start=start, length=length,
                                       access=(flags >> 25) & 0x7F,
                                       code_only=bool((flags >> 18) & 1),
                                       quadrant=(flags >> 21) & 3))
        self._symbols()

    def _symbols(self):
        d, h = self.data, self.hdr
        sstr = h["symbol_strings_location"]
        self.syms = []
        for i in range(h["symbol_total"]):
            o = h["symbol_location"] + 20 * i
            w0, nm, _q, w3, val = struct.unpack_from(">IIIII", d, o)
            st = SYM_TYPES.get((w0 >> 24) & 0x3F, str((w0 >> 24) & 0x3F))
            scope = SCOPES.get((w0 >> 20) & 0xF, "?")
            if st in ("NULL", "SYM_EXT", "ARG_EXT"):
                continue
            # names are preceded by their 32-bit length
            try:
                n = d[sstr + nm:d.index(b"\0", sstr + nm)].decode("latin-1")
            except ValueError:
                n = "?"
            if st in CODE_TYPES:
                val &= ~3
            self.syms.append(dict(name=n, type=st, scope=scope, value=val,
                                  info=w3 & 0xFFFFFF))
        # address -> name index for code and data; prefer ENTRY/PRI_PROG names
        rank = {"ENTRY": 0, "PRI_PROG": 0, "SEC_PROG": 1, "MILLICODE": 1,
                "DATA": 2, "STORAGE": 2, "CODE": 3, "STUB": 4, "ABSOLUTE": 9}
        best = {}
        for s in self.syms:
            if s["type"] in ("MODULE", "ABSOLUTE", "PLABEL"):
                continue
            a = s["value"]
            r = rank.get(s["type"], 5)
            if a not in best or r < best[a][0]:
                best[a] = (r, s["name"])
        self.by_addr = sorted((a, n) for a, (r, n) in best.items())
        self._addrs = [a for a, _ in self.by_addr]
        self.by_name = {}
        for s in self.syms:
            self.by_name.setdefault(s["name"], s)

    def lookup(self, addr):
        i = bisect.bisect_right(self._addrs, addr) - 1
        if i < 0:
            return None, 0
        a, n = self.by_addr[i]
        return n, addr - a

    def fmt(self, addr):
        n, off = self.lookup(addr)
        if n is None:
            return "%#x" % addr
        return n if off == 0 else "%s+%#x" % (n, off)

    def func_end(self, addr):
        i = bisect.bisect_right(self._addrs, addr)
        while i < len(self._addrs):
            a = self._addrs[i]
            n = self.by_addr[i][1]
            s = self.by_name.get(n)
            # C functions are ENTRY symbols; assembly routines are often
            # plain CODE labels, so a UNIVERSAL CODE label also ends one.
            if s and (s["type"] in ("ENTRY", "PRI_PROG", "SEC_PROG", "MILLICODE")
                      or (s["type"] == "CODE" and s["scope"] == "UNIVERSAL")):
                return a
            i += 1
        return self.aux["tmem"] + self.aux["tsize"]

    def text(self):
        a = self.aux
        return a["tmem"], self.data[a["tfile"]:a["tfile"] + a["tsize"]]

    def read(self, addr, n):
        a = self.aux
        if a["tmem"] <= addr < a["tmem"] + a["tsize"]:
            o = a["tfile"] + addr - a["tmem"]
        elif a["dmem"] <= addr < a["dmem"] + a["dsize"]:
            o = a["dfile"] + addr - a["dmem"]
        else:
            return None
        return self.data[o:o + n]

    def word(self, addr):
        b = self.read(addr, 4)
        return struct.unpack(">I", b)[0] if b and len(b) == 4 else None

    def string_at(self, addr, minlen=3):
        """A printable NUL-terminated string at addr, or None."""
        b = self.read(addr, 120)
        if not b or b"\0" not in b:
            return None
        s = b.split(b"\0")[0]
        if len(s) < minlen or any(c < 0x20 and c not in (9, 10) or c > 0x7E for c in s):
            return None
        return s.decode("ascii").replace("\n", "\\n")

    def cstr(self, addr, maxlen=200):
        b = self.read(addr, maxlen)
        if not b:
            return None
        b = b.split(b"\0")[0]
        return b.decode("latin-1")


# ---------------------------------------------------------------------------
# disassembly

def _objdump(blob, vma):
    with tempfile.NamedTemporaryFile(suffix=".bin") as t:
        t.write(blob)
        t.flush()
        out = subprocess.run([OBJDUMP, "-D", "-b", "binary", "-m", "hppa1.1",
                              "-EB", "--adjust-vma=%#x" % vma, t.name],
                             capture_output=True, text=True, check=True).stdout
    return out


LINE = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} ){4})\s*(.*)$")


def _sign(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def ldil_value(w):
    """The immediate of LDIL/ADDIL, already shifted left 11 (assemble_21)."""
    x = w & 0x1FFFFF
    v = (((x & 1) << 20) | (((x >> 1) & 0x7FF) << 9) | (((x >> 14) & 3) << 7)
         | (((x >> 16) & 0x1F) << 2) | ((x >> 12) & 3))
    return (v << 11) & 0xFFFFFFFF


def low_sign_ext(v, bits):
    """PA-RISC low_sign_ext: the sign is the least significant bit."""
    return (v >> 1) - (1 << (bits - 1)) if v & 1 else v >> 1


def br17(w):
    """The 17-bit word displacement of BL/BE/BLE, in bytes (sign-extended)."""
    w1 = (w >> 16) & 0x1F
    w2 = (w >> 2) & 0x7FF
    disp = (((w & 1) << 16) | (w1 << 11) | ((w2 & 1) << 10) | (w2 >> 1)) << 2
    return _sign(disp, 19)


def stub_target(som, addr):
    """If addr is a linker long-branch stub (LDIL r1 ; BE[,n] x(sr4,r1)),
    return its final target, else None."""
    w0, w1 = som.word(addr), som.word(addr + 4)
    if w0 is None or w1 is None:
        return None
    if (w0 >> 26) == 0x08 and (w1 >> 26) == 0x38 and \
            ((w0 >> 21) & 0x1F) == ((w1 >> 21) & 0x1F):
        return (ldil_value(w0) + br17(w1)) & 0xFFFFFFFF
    return None


LOADSTORE = {0x0D, 0x10, 0x11, 0x12, 0x13, 0x18, 0x19, 0x1A, 0x1B}


def disasm(som, start, end, out):
    tmem, text = som.text()
    a0 = max(start, tmem) & ~3
    a1 = min(end, tmem + len(text))
    if a1 <= a0:
        return
    lines = _objdump(text[a0 - tmem:a1 - tmem], a0).splitlines()
    dp = som.hdr["presumed_dp"]
    known = {}                     # reg -> (value, insn index) from LDIL/ADDIL
    idx = 0
    for ln in lines:
        m = LINE.match(ln)
        if not m:
            continue
        idx += 1
        addr = int(m.group(1), 16)
        w = int(m.group(2).replace(" ", ""), 16)
        ins = m.group(3).strip()
        n, off = som.lookup(addr)
        if n is not None and off == 0:
            out.write("\n%08x <%s>:\n" % (addr, n))
            known = {}
        note = ""
        op = w >> 26
        b = (w >> 21) & 0x1F
        live = {r: v for r, (v, i) in known.items() if idx - i < 16}
        if op == 0x3A:                                   # BL, B,GATE, BLR, BV
            if ((w >> 13) & 7) in (0, 1, 4, 5):
                tgt = (addr + 8 + br17(w)) & 0xFFFFFFFF
                st = stub_target(som, tgt)
                note = "-> " + som.fmt(st if st is not None else tgt)
        elif op in (0x38, 0x39) and b in live:          # BE / BLE off(sr,b)
            note = "-> " + som.fmt((live[b] + br17(w)) & 0xFFFFFFFF)
        elif op == 0x08:                                  # LDIL
            known[b] = (ldil_value(w), idx)
        elif op == 0x0A:                                  # ADDIL -> r1
            base = 0 if b == 0 else dp if b == 27 else live.get(b)
            if base is not None:
                v = (base + ldil_value(w)) & 0xFFFFFFFF
                known[1] = (v, idx)
        elif op in LOADSTORE and (b in live or b == 27):
            base = live[b] if b in live else dp
            v = (base + low_sign_ext(w & 0x3FFF, 14)) & 0xFFFFFFFF
            nm, o = som.lookup(v)
            note = "= " + (som.fmt(v) if nm is not None and o < 0x10000 else "%#x" % v)
            if op == 0x0D:
                s = som.string_at(v)
                if s:
                    note += ' "%s"' % s
            t = (w >> 16) & 0x1F
            if op == 0x0D and t:
                known[t] = (v, idx)
            elif op in (0x10, 0x11, 0x12, 0x13) and t in known:
                del known[t]
        elif op in (0x02, 0x34, 0x35, 0x2C, 0x2D, 0x25, 0x24):
            # common ALU forms: drop a stale tracked target register
            t = (w & 0x1F) if op == 0x02 else (w >> 16) & 0x1F
            known.pop(t, None)
        out.write("%08x:  %08x  %-40s%s\n" % (addr, w, ins,
                                             ("  ; " + note) if note else ""))


def calls_to(som, name, outf, nargs=0):
    """Direct calls (BL, possibly through a long-branch stub) and
    LDIL/BE[L] pairs whose target is the symbol `name'."""
    s = som.by_name.get(name)
    if not s:
        raise SystemExit("%s: no such symbol" % name)
    target = s["value"]
    tmem, text = som.text()
    n = len(text) // 4
    words = struct.unpack(">%dI" % n, text[:4 * n])
    targets = {target}
    for i in range(n - 1):                    # stubs that lead to the target
        w0, w1 = words[i], words[i + 1]
        if (w0 >> 26) == 0x08 and (w1 >> 26) == 0x38 and \
                ((w0 >> 21) & 0x1F) == ((w1 >> 21) & 0x1F) and \
                (ldil_value(w0) + br17(w1)) & 0xFFFFFFFF == target:
            targets.add(tmem + 4 * i)
    hits, last = [], {}
    for i, w in enumerate(words):
        addr = tmem + 4 * i
        op = w >> 26
        if op == 0x3A and ((w >> 13) & 7) in (0, 1, 4, 5):
            if (addr + 8 + br17(w)) & 0xFFFFFFFF in targets:
                hits.append(addr)
        elif op == 0x08:
            last[(w >> 21) & 0x1F] = (ldil_value(w), i)
        elif op == 0x39:                       # BLE (calls); BE is a jump
            b = (w >> 21) & 0x1F
            if b in last and i - last[b][1] < 8 and \
                    (last[b][0] + br17(w)) & 0xFFFFFFFF == target:
                hits.append(addr)
    hits = [a for a in hits if a not in targets]
    for a in hits:
        args = const_args(som, a, nargs)
        outf.write("%08x  %-40s%s\n" % (a, som.fmt(a), "  args " + " ".join(
            "?" if v is None else "%d" % v for v in args) if nargs else ""))
    return hits


def _target_reg(w):
    """The register an instruction writes, for the common formats, or None."""
    op = w >> 26
    if op in (0x0D, 0x10, 0x11, 0x12, 0x13, 0x25, 0x2C, 0x2D, 0x34):
        return (w >> 16) & 0x1F
    if op in (0x08, 0x35, 0x3A):
        return (w >> 21) & 0x1F
    if op == 0x0A:
        return 1
    if op in (0x02, 0x03):
        return w & 0x1F
    return None


def const_args(som, addr, nargs=4, back=40):
    """Constant values of arg0..arg3 (r26..r23) at the call at addr, found by
    scanning back (within the function) for LDI/LDO imm(r0) and COPY rX;
    None where the value is not a simple constant. The delay slot counts."""
    regs = (26, 25, 24, 23)[:nargs]
    _, off = som.lookup(addr)
    vals = {}
    for a in range(max(addr - off, addr - 4 * back), addr + 8, 4):
        w = som.word(a)
        t = _target_reg(w)
        if t is None:
            continue
        v = None
        op = w >> 26
        if op == 0x0D and ((w >> 21) & 0x1F) == 0:          # ldo imm(r0) = ldi
            v = low_sign_ext(w & 0x3FFF, 14)
        elif op == 0x02 and ((w >> 6) & 0x3F) == 0x09 and ((w >> 16) & 0x1F) == 0:
            src = (w >> 21) & 0x1F                           # copy src,t
            v = 0 if src == 0 else vals.get(src)
        vals[t] = v
    return [vals.get(r) for r in regs]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file")
    ap.add_argument("cmd", choices=["info", "syms", "addr", "sym", "dis", "calls", "image"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--args", dest="nargs", type=int, default=0,
                    help="calls: also show constant arg0..argN-1 (r26..)")
    ap.add_argument("--func", action="append")
    ap.add_argument("--range", nargs=2)
    ap.add_argument("-o", "--output")
    a = ap.parse_args(argv[1:])
    som = SOM(a.file)
    out = open(a.output, "w") if a.output else sys.stdout

    if a.cmd == "info":
        h = som.hdr
        for k in HDR_FIELDS:
            out.write("  %-26s %#x\n" % (k, h[k]))
        if som.aux:
            out.write("exec aux: " + " ".join("%s=%#x" % kv for kv in som.aux.items()) + "\n")
        for i, s in enumerate(som.spaces):
            out.write("space %d %-12s loadable=%d subspaces %d..%d\n"
                      % (i, s["name"], s["loadable"], s["sub_index"],
                         s["sub_index"] + s["sub_count"] - 1))
        for i, s in enumerate(som.subspaces):
            out.write("  sub %2d %-16s sp %d start %#010x len %#09x file %#09x "
                      "init %#08x acc %#x\n"
                      % (i, s["name"], s["space"], s["start"], s["length"],
                         s["file_loc"], s["init_len"], s["access"]))
        out.write("%d symbols\n" % len(som.syms))
        return 0
    if a.cmd == "syms":
        for s in sorted(som.syms, key=lambda s: (s["value"], s["name"])):
            if not a.all and s["type"] in ("MODULE", "ABSOLUTE", "STUB", "PLABEL"):
                continue
            out.write("%08x %-9s %-9s %s\n" % (s["value"], s["type"], s["scope"], s["name"]))
        return 0
    if a.cmd == "addr":
        for x in a.args:
            out.write("%s  %s\n" % (x, som.fmt(int(x, 16))))
        return 0
    if a.cmd == "sym":
        for x in a.args:
            s = som.by_name.get(x)
            out.write("%s  %s\n" % (x, ("%#x %s %s" % (s["value"], s["type"], s["scope"]))
                                    if s else "not found"))
        return 0
    if a.cmd == "calls":
        for x in a.args:
            out.write("# callers of %s\n" % x)
            calls_to(som, x, out, a.nargs)
        return 0
    if a.cmd == "image":
        aux = som.aux
        img = bytearray(aux["dmem"] + aux["dsize"] - aux["tmem"])
        _, t = som.text()
        img[0:len(t)] = t
        dd = som.data[aux["dfile"]:aux["dfile"] + aux["dsize"]]
        img[aux["dmem"] - aux["tmem"]:aux["dmem"] - aux["tmem"] + len(dd)] = dd
        open(a.args[0], "wb").write(img)
        print("image at %#x, %d bytes" % (aux["tmem"], len(img)), file=sys.stderr)
        return 0
    if a.cmd == "dis":
        if a.func:
            for fn in a.func:
                s = som.by_name.get(fn)
                if not s:
                    raise SystemExit("%s: no such symbol" % fn)
                disasm(som, s["value"], som.func_end(s["value"]), out)
        elif a.range:
            disasm(som, int(a.range[0], 16), int(a.range[1], 16), out)
        else:
            tmem, text = som.text()
            step = 0x40000
            for s0 in range(tmem, tmem + len(text), step):
                disasm(som, s0, s0 + step, out)
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
