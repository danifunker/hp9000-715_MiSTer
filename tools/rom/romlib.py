"""Shared helpers for analysing the HP 9000/715 boot ROM (PA-RISC 1.1, big-endian).

The ROM is mapped at ROM_BASE (0xF0000000); the CPU resets to 0xF0000004.
Disassembly comes from binutils (`hppa-linux-gnu-objdump`); this module parses
it and adds what objdump cannot know: absolute addresses formed by ldil/ldo
pairs, device register names, and PA7100LC diagnose instruction decodes.
"""
import os
import re
import struct
import subprocess
from collections import namedtuple

ROM_BASE = 0xF0000000
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
DEFAULT_ROM = os.path.join(REPO, "roms", "hp715_pdc_rev1.6.bin")
OBJDUMP = os.environ.get("HPPA_OBJDUMP", "hppa-linux-gnu-objdump")

Insn = namedtuple("Insn", "addr word mnem ops")

# The ROM's data pointer: compiled code addresses its strings and tables as
# dp-relative (addil L%x,dp + ldo y(r1)). Fitting every such reference to the
# ROM's string starts gives 0xF0024000 (157 of 210 ldo references land exactly
# on a string). Assumed wherever r27 has not been written locally.
ROM_DP = 0xF0024000

# ---------------------------------------------------------------------------
# Address map. Sources: docs/review/02 and 05 (LASI ERS, SeaBIOS 715_64.h
# inventory of a real 715/64), QEMU include/hw/misc/lasi.h and
# hw/display/artist.c. (base, size, name, {offset: register name})
# ---------------------------------------------------------------------------
LASI_REGS = {
    0x00000: "IRR", 0x00004: "IMR", 0x00008: "IPR", 0x0000C: "ICR", 0x00010: "IAR",
    0x0C000: "PCR", 0x0C004: "ERRLOG", 0x0C008: "VER", 0x0C00C: "IORESET",
    0x0C010: "AMR",
}
LASI_UNITS = [  # (offset, size, name)
    (0x02000, 0x1000, "LPT"), (0x04000, 0x1000, "AUDIO"), (0x05000, 0x1000, "UART"),
    (0x06000, 0x1000, "SCSI"), (0x07000, 0x1000, "LAN"), (0x08000, 0x1000, "PS2"),
    (0x09000, 0x1000, "RTC"), (0x0A000, 0x1000, "FDC"),
]
ARTIST_REGS = {
    0x1004A0: "VRAM_IDX", 0x1005A0: "VRAM_BITMASK", 0x100600: "VRAM_WRITE_INCR_X",
    0x100604: "VRAM_WRITE_INCR_X2", 0x100620: "VRAM_WRITE_INCR_Y", 0x100800: "VRAM_START",
    0x100804: "BLOCK_MOVE_SIZE", 0x100808: "BLOCK_MOVE_SOURCE", 0x100820: "TRANSFER_DATA",
    0x1008A0: "FONT_WRITE_INCR_Y", 0x100A00: "VRAM_START_TRIGGER",
    0x100A04: "VRAM_SIZE_TRIGGER", 0x100AA0: "FONT_WRITE_START",
    0x100B00: "BLOCK_MOVE_DEST_TRIGGER", 0x100B04: "BLOCK_MOVE_SIZE_TRIGGER",
    0x100CCC: "LINE_XY", 0x100ECC: "PATTERN_LINE_START", 0x100E04: "LINE_SIZE",
    0x100E44: "LINE_END", 0x118000: "DST_SRC_BM_ACCESS", 0x118004: "DST_BM_ACCESS",
    0x118008: "SRC_BM_ACCESS", 0x11800C: "CONTROL_PLANE", 0x118010: "FG_COLOR",
    0x118014: "BG_COLOR", 0x118018: "PLANE_MASK", 0x11801C: "IMAGE_BITMAP_OP",
    0x300100: "CURSOR_POS", 0x300104: "CURSOR_CTRL", 0x300218: "MISC_VIDEO",
    0x300308: "MISC_CTRL", 0x300200: "HORIZ_BACKPORCH", 0x300208: "ACTIVE_LINES_LOW",
    0x300008: "FIFO1", 0x380008: "FIFO2",
}
REGIONS = [
    (0xF0000000, 0x00040000, "ROM", {}),
    (0xF0100000, 0x00100000, "LASI", LASI_REGS),
    (0xF0200000, 0x00001000, "WAX", {}),
    (0xF0201000, 0x00001000, "WAX.HIL", {}),
    (0xF0202000, 0x00001000, "WAX.RS232_2", {}),
    (0xF0203000, 0x000FD000, "WAX+", {}),
    (0xF8000000, 0x01000000, "ARTIST", ARTIST_REGS),
    (0xFC000000, 0x02000000, "EISA", {}),
    (0xFFFBE000, 0x00001000, "CPU_HPA", {}),
    (0xFFFBF000, 0x00001000, "MEM_HPA", {}),     # memory module = MIOC registers
    (0xFFFC0000, 0x00040000, "BROADCAST", {}),
]


def region_of(addr):
    for base, size, name, regs in REGIONS:
        if base <= addr < base + size:
            return base, name, regs
    return None


def name_addr(addr):
    """Symbolic name for an absolute address, or None if it is not a known device."""
    r = region_of(addr)
    if not r:
        if addr >= 0xF0000000:
            return "F-space:%08x" % addr
        return None
    base, name, regs = r
    off = addr - base
    if name == "ROM":
        return None
    if off in regs:
        return "%s.%s" % (name, regs[off])
    if name == "LASI":
        for uoff, usize, uname in LASI_UNITS:
            if uoff <= off < uoff + usize:
                return "LASI.%s+%#x" % (uname, off - uoff)
    return "%s+%#x" % (name, off)


# ---------------------------------------------------------------------------
# PA7100LC diagnose instructions (PCXL ERS 8.3, table 8.3.9). Fields in PA bit
# numbering: 6-10 t/r, 11-15 x/t_ch, 19-26 code, 27-31 t_th.
# ---------------------------------------------------------------------------
DIAG_CODES = {
    0x12: "MTCPU", 0xA0: "MFCPU_T", 0x30: "MFCPU_C", 0x50: "TOC_EN", 0x52: "TOC_DIS",
    0xD0: "SHDW_GR", 0xD2: "GR_SHDW", 0xE2: "RDD", 0xE6: "RDTLB", 0xEA: "RDT",
    0x62: "RI2D", 0x6A: "RI2T", 0x40: "RI1", 0xF2: "WDD", 0xFA: "WDT", 0x72: "WI2D",
    0x7A: "WI2T", 0x70: "WI1", 0x42: "SET_TAG",
}


def decode_diag(word):
    f610 = (word >> 21) & 0x1F
    f1115 = (word >> 16) & 0x1F
    code = (word >> 5) & 0xFF
    tth = word & 0x1F
    name = DIAG_CODES.get(code)
    if name == "MTCPU":
        return "MTCPU r%d -> DR%d" % (f1115, f610)
    if name == "MFCPU_C":
        return "MFCPU_C DR%d -> r%d" % (f610, f1115)
    if name == "MFCPU_T":
        return "MFCPU_T DR%d -> r%d" % (f610, tth)
    if name:
        return "%s (fields %d,%d,%d)" % (name, f610, f1115, tth)
    return "DIAG code %#x (fields %d,%d,%d) -- not in PCX-L table" % (code, f610, f1115, tth)


# ---------------------------------------------------------------------------
# objdump parsing
# ---------------------------------------------------------------------------
REG_ALIASES = {"rp": 2, "dp": 27, "ret0": 28, "ret1": 29, "sp": 30}
LINE_RE = re.compile(r"^\s*([0-9a-f]+):\s+((?:[0-9a-f]{2} ){4})\s*(\S+)?\s*(.*)$")


def reg_num(tok):
    tok = tok.strip()
    if tok in REG_ALIASES:
        return REG_ALIASES[tok]
    m = re.fullmatch(r"r(\d+)", tok)
    return int(m.group(1)) if m else None


def parse_imm(tok):
    """objdump prints immediates as bare hex, optionally negative."""
    tok = tok.strip()
    neg = tok.startswith("-")
    if neg:
        tok = tok[1:]
    if tok.startswith("0x"):
        tok = tok[2:]
    try:
        v = int(tok, 16)
    except ValueError:
        return None
    return -v if neg else v


def disassemble(rom=DEFAULT_ROM, base=ROM_BASE):
    out = subprocess.run(
        [OBJDUMP, "-D", "-b", "binary", "-m", "hppa1.1", "-EB",
         "--adjust-vma=%#x" % base, rom],
        check=True, capture_output=True, text=True).stdout
    insns = []
    for line in out.splitlines():
        m = LINE_RE.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        word = int(m.group(2).replace(" ", ""), 16)
        insns.append(Insn(addr, word, m.group(3) or "", m.group(4).strip()))
    return insns


SYMDIR = os.path.join(HERE, "symbols")


def load_symbols(symdir=SYMDIR):
    """Names from tools/rom/symbols/*.sym: one 'ADDR NAME [# comment]' per line."""
    syms = {}
    if not os.path.isdir(symdir):
        return syms
    for fn in sorted(os.listdir(symdir)):
        if not fn.endswith(".sym"):
            continue
        for line in open(os.path.join(symdir, fn)):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2:
                syms[int(parts[0], 16)] = parts[1]
    return syms


def load(rom=DEFAULT_ROM):
    return open(rom, "rb").read()


def word_at(data, addr, base=ROM_BASE):
    off = addr - base
    return struct.unpack(">I", data[off:off + 4])[0]


def find_strings(data, base=ROM_BASE, minlen=4):
    """(address, text) for every run of printable ASCII ending in NUL or newline."""
    res = []
    for m in re.finditer(rb"[\x20-\x7e\t\r\n]{%d,}" % minlen, data):
        s = m.group(0)
        if len(s.strip()) >= minlen:
            res.append((base + m.start(), s.decode("ascii")))
    return res


# ---------------------------------------------------------------------------
# Constant tracking: enough to resolve ldil/ldo (addil/ldo) address pairs and
# the base register of loads, stores and external branches.
# ---------------------------------------------------------------------------
MEM_RE = re.compile(r"(-?[0-9a-f]+)\((?:sr(\d),)?(\w+)\)")
BRANCH_TARGET_RE = re.compile(r"\b(?:0x)?(f[0-9a-f]{7})\b")


def branch_targets(insn):
    """Absolute targets objdump printed for a PC-relative branch."""
    m = insn.mnem.split(",")[0]
    if m in ("b", "bl", "comb", "comib", "combt", "combf", "comibt", "comibf",
             "cmpb", "cmpib", "addb", "addib", "addbt", "addbf", "addibt", "addibf",
             "movb", "movib", "bb", "bvb", "cmpclr"):
        return [int(t, 16) for t in BRANCH_TARGET_RE.findall(insn.ops)]
    return []


VOLATILE = [1, 2, 19, 20, 21, 22, 23, 24, 25, 26, 28, 29, 31]


def resolve(insns):
    """Yield (insn, note_dict) with resolved constants; notes may hold
    'addr' (absolute effective address of a load/store/external branch),
    'kind' ('load'|'store'|'branch'|'call'), 'diag', 'const' (value now in
    the destination register)."""
    leaders = set()
    for i in insns:
        leaders.update(branch_targets(i))
    regs = {0: 0, 27: ROM_DP}
    reset_in = 0          # >0: reset the register file after this many insns
    kill_in = 0           # >0: drop caller-saved registers after this many insns
    for ins in insns:
        if reset_in:
            reset_in -= 1
            if reset_in == 0:
                regs = {0: 0, 27: ROM_DP}
        if kill_in:
            kill_in -= 1
            if kill_in == 0:
                for r in VOLATILE:
                    regs.pop(r, None)
        if ins.addr in leaders:
            regs = {0: 0, 27: ROM_DP}
        note = {}
        mn = ins.mnem
        base = mn.split(",")[0]
        ops = [o.strip() for o in ins.ops.split(",")] if ins.ops else []
        dest, val = None, None
        if base == "ldil" and len(ops) == 2:
            v = parse_imm(ops[0].replace("L%", ""))
            dest, val = reg_num(ops[1]), (v & 0xFFFFFFFF) if v is not None else None
        elif base == "addil" and len(ops) >= 2:
            v = parse_imm(ops[0].replace("L%", ""))
            s = reg_num(ops[1])
            dest = 1
            if v is not None and s in regs:
                val = (regs[s] + v) & 0xFFFFFFFF
        elif base == "ldo":
            m = MEM_RE.search(ins.ops)
            if m and len(ops) >= 2:
                d, s = parse_imm(m.group(1)), reg_num(m.group(3))
                dest = reg_num(ops[-1])
                if d is not None and s in regs:
                    val = (regs[s] + d) & 0xFFFFFFFF
        elif base in ("ldi",) and len(ops) == 2:
            v = parse_imm(ops[0])
            dest, val = reg_num(ops[1]), (v & 0xFFFFFFFF) if v is not None else None
        elif base == "addi" and len(ops) == 3:
            v, s = parse_imm(ops[0]), reg_num(ops[1])
            dest = reg_num(ops[2])
            if v is not None and s in regs:
                val = (regs[s] + v) & 0xFFFFFFFF
        elif base == "copy" and len(ops) == 2:
            s = reg_num(ops[0])
            dest = reg_num(ops[1])
            val = regs.get(s)
        elif base == "diag":
            note["diag"] = decode_diag(ins.word)
        elif base[:2] in ("ld", "st") or base[:3] in ("fld", "fst"):
            m = MEM_RE.search(ins.ops)
            if m:
                d, b = parse_imm(m.group(1)), reg_num(m.group(3))
                if d is not None and b in regs:
                    note["addr"] = (regs[b] + d) & 0xFFFFFFFF
                note["kind"] = "store" if base[:2] == "st" or base[:3] == "fst" else "load"
            if note.get("kind") == "load" and ops:
                dest = reg_num(ops[-1])
        elif base in ("be", "ble"):
            m = MEM_RE.search(ins.ops)
            if m:
                d, b = parse_imm(m.group(1)), reg_num(m.group(3))
                if d is not None and b in regs:
                    note["addr"] = (regs[b] + d) & 0xFFFFFFFF
                note["kind"] = "call" if base == "ble" or ",l" in mn else "branch"
        # write back
        if dest is not None and dest != 0:
            if val is None:
                regs.pop(dest, None)
            else:
                regs[dest] = val
                note["const"] = val
        # anything else that writes a GR we cannot model: drop the last operand
        elif dest is None and ops and base not in ("diag",) and not base.startswith("st") \
                and not base.startswith("fst") and base not in ("mtctl", "mtsp", "nop"):
            r = reg_num(ops[-1])
            if r is not None and r != 0:
                regs.pop(r, None)
        # A call (b,l / bl / ble with a real link register) returns to the
        # insn after its delay slot with the caller-saved registers clobbered.
        # An unconditional jump (b,l ...,r0 / bv / be) does not return: the
        # register file is unknown after its delay slot.
        link_is_r0 = bool(ops) and reg_num(ops[-1]) == 0
        is_call = (base in ("b", "bl") and (",l" in mn or base == "bl") and not link_is_r0) \
            or base == "ble"
        is_jump = (base == "b" and link_is_r0) or base in ("bv", "be", "bve")
        if is_call:
            note["kind"] = note.get("kind", "call")
        if base == "ble":
            regs.pop(31, None)
        yield ins, note
        # the delay slot still sees the caller's registers
        if is_call:
            kill_in = 2
        if is_jump:
            reset_in = 2
