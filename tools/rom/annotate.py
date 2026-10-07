#!/usr/bin/env python3
"""Annotated disassembly of the 715 boot ROM, plus cross-reference tables.

usage: annotate.py [ROM] [OUTDIR]     (defaults: roms/hp715_pdc_rev1.6.bin, roms/disasm)

Writes to OUTDIR:
  rom.dis        the listing: call targets get a label line with their callers,
                 branch targets get L_ labels, strings are shown as strings, and
                 each insn is annotated with what romlib could resolve (device
                 register names, ROM string references, diagnose decodes)
  hwaccess.tsv   every load/store/external branch to a known device address
  diag.tsv       every diagnose instruction
  ctl.tsv        every mtctl/mfctl/mtsp/mfsp (control and space registers)
  strings.tsv    strings with the code addresses that form their address
  calls.tsv      call targets with caller count and callers

Function names come from tools/rom/symbols/*.sym ('ADDR NAME [# comment]').
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romlib  # noqa: E402


def main(argv):
    rom = argv[1] if len(argv) > 1 else romlib.DEFAULT_ROM
    outdir = argv[2] if len(argv) > 2 else os.path.join(romlib.REPO, "roms", "disasm")
    os.makedirs(outdir, exist_ok=True)
    data = romlib.load(rom)
    insns = romlib.disassemble(rom)
    rom_end = romlib.ROM_BASE + len(data)

    strings = [(a, s) for a, s in romlib.find_strings(data, minlen=5)]
    str_at = {a: s for a, s in strings}
    str_ranges = sorted((a, a + len(s)) for a, s in strings if len(s) >= 8)

    def in_string(addr):
        import bisect
        i = bisect.bisect_right(str_ranges, (addr, 1 << 40)) - 1
        return i >= 0 and str_ranges[i][0] <= addr < str_ranges[i][1]

    resolved = list(romlib.resolve(insns))
    syms = romlib.load_symbols()

    def label(a):
        return syms.get(a, "F_%08x" % a)

    callers = collections.defaultdict(list)
    branch_tgts = set()
    for ins, note in resolved:
        for t in romlib.branch_targets(ins):
            if note.get("kind") == "call":
                callers[t].append(ins.addr)
            else:
                branch_tgts.add(t)
        if note.get("kind") == "call" and "addr" in note and \
                romlib.ROM_BASE <= note["addr"] < rom_end:
            callers[note["addr"]].append(ins.addr)

    str_xref = collections.defaultdict(list)
    hw, diags, ctls = [], [], []
    lines = []
    for ins, note in resolved:
        a = ins.addr
        if in_string(a):
            if a in str_at:
                lines.append("%08x:  .string %r" % (a, str_at[a]))
            continue
        if a in callers:
            cs = callers[a]
            lines.append("")
            lines.append("%s:    ; %08x, called from %d site(s): %s%s" % (
                label(a), a, len(cs), " ".join("%08x" % c for c in cs[:8]),
                " ..." if len(cs) > 8 else ""))
        elif a in syms:
            lines.append("")
            lines.append("%s:    ; %08x" % (syms[a], a))
        elif a in branch_tgts:
            lines.append("L_%08x:" % a)
        ann = []
        if "diag" in note:
            ann.append(note["diag"])
            diags.append((a, note["diag"]))
        if "addr" in note:
            ea = note["addr"]
            nm = romlib.name_addr(ea)
            if nm:
                ann.append("%s %s" % (note.get("kind", "?"), nm))
                hw.append((a, note.get("kind", "?"), ea, nm, ins.mnem + " " + ins.ops))
            elif romlib.ROM_BASE <= ea < rom_end:
                ann.append("%s ROM %08x" % (note.get("kind", "?"), ea))
            else:
                ann.append("%s %08x" % (note.get("kind", "?"), ea))
        if "const" in note:
            c = note["const"]
            if c in str_at:
                ann.append("-> %r" % str_at[c][:60])
                str_xref[c].append(a)
            elif ins.mnem.split(",")[0] in ("ldo", "addi", "addil") and \
                    romlib.name_addr(c):
                ann.append("= %s" % romlib.name_addr(c))
        if note.get("kind") == "call":
            for t in romlib.branch_targets(ins) or ([note["addr"]] if "addr" in note else []):
                if t in syms:
                    ann.append("call " + syms[t])
        base = ins.mnem.split(",")[0]
        if base in ("mtctl", "mfctl", "mtsp", "mfsp"):
            ctls.append((a, ins.mnem, ins.ops))
        lines.append("%08x:  %08x  %-10s %-28s%s" % (
            a, ins.word, ins.mnem, ins.ops, ("; " + "; ".join(ann)) if ann else ""))

    with open(os.path.join(outdir, "rom.dis"), "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(os.path.join(outdir, "hwaccess.tsv"), "w") as f:
        f.write("pc\tkind\taddress\tname\tinsn\n")
        for r in hw:
            f.write("%08x\t%s\t%08x\t%s\t%s\n" % r)
    with open(os.path.join(outdir, "diag.tsv"), "w") as f:
        f.write("pc\tdecode\n")
        for r in diags:
            f.write("%08x\t%s\n" % r)
    with open(os.path.join(outdir, "ctl.tsv"), "w") as f:
        f.write("pc\tmnem\toperands\n")
        for r in ctls:
            f.write("%08x\t%s\t%s\n" % r)
    with open(os.path.join(outdir, "strings.tsv"), "w") as f:
        f.write("address\txrefs\ttext\n")
        for a, s in strings:
            f.write("%08x\t%s\t%r\n" % (a, " ".join("%08x" % x for x in str_xref.get(a, [])), s))
    with open(os.path.join(outdir, "calls.tsv"), "w") as f:
        f.write("target\tcount\tcallers\n")
        for t in sorted(callers, key=lambda t: -len(callers[t])):
            f.write("%08x\t%d\t%s\n" % (t, len(callers[t]), " ".join("%08x" % c for c in callers[t])))
    print("%d insns, %d call targets, %d hw accesses, %d diag, %d ctl, %d strings (%d referenced)" % (
        len(insns), len(callers), len(hw), len(diags), len(ctls), len(strings), len(str_xref)))


if __name__ == "__main__":
    main(sys.argv)
