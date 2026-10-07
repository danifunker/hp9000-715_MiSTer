#!/usr/bin/env python3
"""Call-site lists for the firmware interfaces of the 715 boot ROM.

usage: firmware_calls.py [ROM] pdc       every PDC call (direct to 0xF0012870, through Page Zero
                                         MEM_PDC, or through the C wrapper pdc_call 0xF001B178)
                                         with the procedure/option/ARG2/ARG3 constants loaded before it
       firmware_calls.py [ROM] eeprom    every call of the EEPROM accessors 0xF0013208/20/0xF0013314/20/
                                         0xF001335C with r20 (base), r4 (offset), r5 (data) after the
                                         delay slot

Constants come from romlib.resolve(); '?' means the value is not a simple constant
(computed, loaded from memory, or set outside the scanned window).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romlib  # noqa: E402

PDC_ENTRY = 0xF0012870
PDC_WRAPPER = 0xF001B178
PROC_NAMES = {2: "CHASSIS", 3: "PIM", 4: "MODEL", 5: "CACHE", 6: "HPA", 7: "COPROC", 8: "IODC", 9: "TOD",
              10: "STABLE", 12: "ADD_VALID", 18: "BLOCK_TLB", 19: "TLB", 21: "PSW", 23: "SOFT_POWER",
              128: "MEM_MAP", 129: "EEPROM", 130: "EISA(130)", 136: "BCAST_RESET", 138: "LAN_STATION_ID"}
EE_ACCESSORS = {0xF0013208: "rd_word", 0xF0013220: "wr_word", 0xF0013314: "rd_byte",
                0xF0013320: "wr_byte", 0xF001335C: "wr_word@F00C0000"}


def pdc_calls(insns, consts):
    out = []
    for k, ins in enumerate(insns):
        m = ins.mnem.split(",")[0]
        tg = romlib.branch_targets(ins)
        if PDC_ENTRY in tg:
            how = "direct"
        elif PDC_WRAPPER in tg:
            how = "pdc_call"
        elif (m == "be" and ",l" in ins.mnem) or m == "ble":
            if not any("388" in insns[j].ops or consts.get(insns[j].addr) == 0x388
                       for j in range(max(0, k - 40), k)):
                continue
            how = "MEM_PDC"
        else:
            continue
        got, stack = {}, {}
        for j in range(min(k + 1, len(insns) - 1), max(0, k - 40), -1):
            i2 = insns[j]
            if j < k - 1 and romlib.branch_targets(i2):
                break                       # stop at the previous call/branch
            ops = [o.strip() for o in i2.ops.split(",")] if i2.ops else []
            if not ops:
                continue
            r = romlib.reg_num(ops[-1])
            if r in (26, 25, 24, 23) and r not in got and not i2.mnem.startswith("st"):
                got[r] = ("%#x" % consts[i2.addr]) if i2.addr in consts else "?"
            mm = re.match(r"stw (\w+),(-3[4c8]|-40)\(sp\)", i2.mnem + " " + i2.ops)
            if mm and mm.group(2) not in stack:
                stack[mm.group(2)] = mm.group(1)
        proc = got.get(26, "?")
        try:
            pname = PROC_NAMES.get(int(proc, 16), "")
        except ValueError:
            pname = ""
        out.append((ins.addr, how, proc, pname, got.get(25, "?"), got.get(24, "?"), got.get(23, "?"), stack))
    return out


def eeprom_calls(resolved):
    regs, pending, out = {}, None, []
    for ins, note in resolved:
        ops = [o.strip() for o in ins.ops.split(",")] if ins.ops else []
        if "const" in note and ops:
            r = romlib.reg_num(ops[-1])
            if r is not None:
                regs[r] = note["const"]
        elif ops and not ins.mnem.startswith(("st", "b", "cmp")):
            r = romlib.reg_num(ops[-1])
            if r is not None:
                regs.pop(r, None)
        if pending:
            a, what = pending
            pending = None
            out.append((a, what, regs.get(20), regs.get(4), regs.get(5)))
        for t in romlib.branch_targets(ins):
            if t in EE_ACCESSORS:
                pending = (ins.addr, EE_ACCESSORS[t])
    return out


def main(argv):
    args = argv[1:]
    rom = romlib.DEFAULT_ROM
    if args and os.path.isfile(args[0]):
        rom = args.pop(0)
    what = args[0] if args else "pdc"
    insns = romlib.disassemble(rom)
    resolved = list(romlib.resolve(insns))
    consts = {i.addr: n["const"] for i, n in resolved if "const" in n}
    if what == "pdc":
        for a, how, proc, pname, opt, a2, a3, stack in pdc_calls(insns, consts):
            print("%08x %-8s proc=%-5s %-14s opt=%-6s a2=%-11s a3=%-11s stack=%s"
                  % (a, how, proc, pname, opt, a2, a3,
                     " ".join("%s:%s" % kv for kv in sorted(stack.items()))))
    elif what == "eeprom":
        h = lambda v: "?" if v is None else "%#x" % v  # noqa: E731
        for a, w, base, off, val in eeprom_calls(resolved):
            ea = "%08x" % (base + off) if base is not None and off is not None and w != "wr_word@F00C0000" \
                else ("%08x" % (0xF00C0000 + off) if off is not None and w == "wr_word@F00C0000" else "?")
            print("%08x %-17s base=%-11s off=%-7s -> %s  data=%s" % (a, w, h(base), h(off), ea, h(val)))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
