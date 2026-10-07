#!/usr/bin/env python3
"""List every chassis/LED code the 715 boot ROM emits.

The ROM's chassis-code routine is F_f00122e0 (chassis_code in
symbols/bootflow.sym); C code calls it through F_f0010bf8 (chassis, code in
r26, link rp). It is called with `b,l 0xf00122e0,r22` and takes the
code in r3 (built with ldil/ldo or ldil/addi, sometimes finished in the delay
slot). It writes ~((r3 >> 12) & 0xff) to the front-panel LED latch at
0xF00EFFFF and, if EEPROM byte 0x1694 is 0xB0/0xB1 ("chassis codes on"),
prints the low 24 bits of r3 on the RS-232 port as "0xHH.HHHH".

usage: bootflow_chassis.py [ROM [DIS]]  -> TSV on stdout: site, code, led, function
DIS is an annotate.py listing (default roms/disasm/bootflow/rom.dis) used only to
name the enclosing function.
"""
import bisect
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romlib  # noqa: E402

CHASSIS = 0xF00122E0      # asm entry: code in r3, link r22
CHASSIS_C = 0xF0010BF8    # C-callable wrapper: code in r26, link rp
WINDOW = 40


def sim_reg(seq, target):
    """Track constants through a straight-line window; return the value of
    register `target` at the end, or a string describing why it is unknown."""
    regs = {0: 0}
    why = {}
    for ins in seq:
        ops = [o.strip() for o in ins.ops.split(",")] if ins.ops else []
        b = ins.mnem.split(",")[0]
        if not ops or b.startswith("st") or b.startswith("b") or b in ("cmpb", "cmpib", "addib", "nop"):
            continue
        d = romlib.reg_num(ops[-1])
        if d is None or d == 0:
            continue
        v = None
        if b == "ldil":
            v = romlib.parse_imm(ops[0].replace("L%", ""))
        elif b == "ldo":
            m = romlib.MEM_RE.search(ins.ops)
            if m and romlib.reg_num(m.group(3)) in regs:
                v = regs[romlib.reg_num(m.group(3))] + romlib.parse_imm(m.group(1))
        elif b == "addi" and romlib.reg_num(ops[1]) in regs:
            v = regs[romlib.reg_num(ops[1])] + romlib.parse_imm(ops[0])
        elif b == "ldi":
            v = romlib.parse_imm(ops[0])
        elif b == "copy" and romlib.reg_num(ops[0]) in regs:
            v = regs[romlib.reg_num(ops[0])]
        if v is None:
            regs.pop(d, None)
            why[d] = "%s %s" % (ins.mnem, ins.ops)
        else:
            regs[d] = v & 0xFFFFFFFF
            why.pop(d, None)
    if target in regs:
        return regs[target]
    return why.get(target, "?")


def func_starts(dis):
    starts = {}
    if os.path.exists(dis):
        for line in open(dis):
            m = re.match(r"^(\S+):\s+; ([0-9a-f]{8})", line)
            if m:
                starts[int(m.group(2), 16)] = m.group(1)
    return starts


def main(argv):
    rom = argv[1] if len(argv) > 1 else romlib.DEFAULT_ROM
    dis = argv[2] if len(argv) > 2 else os.path.join(romlib.REPO, "roms", "disasm", "bootflow", "rom.dis")
    insns = romlib.disassemble(rom)
    starts = func_starts(dis)
    keys = sorted(starts)
    print("site\tcode\tled\tin_function")
    for i, ins in enumerate(insns):
        tgt = None
        if ins.mnem.startswith("b,l") and ("%08x" % CHASSIS) in ins.ops and ins.ops.endswith("r22"):
            tgt = 3
        elif ins.mnem.startswith("b,l") and ("%08x" % CHASSIS_C) in ins.ops:
            tgt = 26
        if tgt is not None:
            val = sim_reg(insns[max(0, i - WINDOW):i + 2], tgt)
            k = bisect.bisect_right(keys, ins.addr) - 1
            fn = starts[keys[k]] if k >= 0 else ""
            if isinstance(val, int):
                print("%08x\t%#07x\t%#04x\t%s" % (ins.addr, val, (val >> 12) & 0xFF, fn))
            else:
                print("%08x\t%s\t?\t%s" % (ins.addr, "r%d<-%s" % (tgt, val), fn))


if __name__ == "__main__":
    main(sys.argv)
