#!/usr/bin/env python3
"""Function-wide constant tracking for the hardware-map pass.

romlib.resolve() forgets every register at each branch target, so a base
address loaded once at the top of a function (ldil L%0xfffbf000,r3 ... loop:
ldw 0x84(r3)) is lost inside loops.  This pass works per function:

  * function starts = call targets (romlib) + names in symbols/*.sym
  * a register whose every definition inside the function produces the same
    known constant is a "function constant" and survives branch targets
  * iterate to a fixpoint (a function constant can make another definition
    resolvable)

Calls only clobber ret0/ret1/rp/r31 (compiled code never relies on other
caller-saved registers across a call).  Optimistic, so check by reading the
listing -- the output is a lead list, not proof.

usage: hwmap_trace.py [OUTDIR]   (default roms/disasm/hwmap)
writes OUTDIR/hwaccess_ext.tsv  every load/store whose EA is a device address
       OUTDIR/callargs.tsv      calls with constant arguments (r26..r23)
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import romlib  # noqa: E402
from romlib import reg_num, parse_imm, MEM_RE  # noqa: E402

DEV_LO = 0xF0040000


def insn_effect(ins, regs):
    """(dest, value_or_None, note) for one instruction given known regs."""
    mn = ins.mnem
    base = mn.split(",")[0]
    ops = [o.strip() for o in ins.ops.split(",")] if ins.ops else []
    note = {}
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
    elif base == "ldi" and len(ops) == 2:
        v = parse_imm(ops[0])
        dest, val = reg_num(ops[1]), (v & 0xFFFFFFFF) if v is not None else None
    elif base == "addi" and len(ops) == 3 and "," not in mn:
        v, s = parse_imm(ops[0]), reg_num(ops[1])
        dest = reg_num(ops[2])
        if v is not None and s in regs:
            val = (regs[s] + v) & 0xFFFFFFFF
    elif base == "copy" and len(ops) == 2:
        s = reg_num(ops[0])
        dest = reg_num(ops[1])
        val = regs.get(s)
    elif base in ("depwi", "depi") and len(ops) == 4 and "," not in mn:
        # depwi imm,pos,len,t : modifies t in place
        v, p, ln, t = parse_imm(ops[0]), parse_imm(ops[1]), parse_imm(ops[2]), reg_num(ops[3])
        dest = t
        if None not in (v, p, ln) and t in regs:
            p, ln = int(str(ops[1]), 10), int(str(ops[2]), 10)
            sh = 31 - p
            mask = ((1 << ln) - 1) << sh
            val = (regs[t] & ~mask | ((v << sh) & mask)) & 0xFFFFFFFF
    elif base[:2] in ("ld", "st") or base[:3] in ("fld", "fst"):
        m = MEM_RE.search(ins.ops)
        if m:
            d, b = parse_imm(m.group(1)), reg_num(m.group(3))
            if d is not None and b in regs:
                ea = (regs[b] + d) & 0xFFFFFFFF
                # ,mb pre-modifies; ,ma post-modifies: EA = base for ,ma
                if ",ma" in mn:
                    ea = regs[b]
                note["addr"] = ea
            note["kind"] = "store" if base[:2] == "st" or base[:3] == "fst" else "load"
            if note["kind"] == "store" and ops:
                note["src"] = reg_num(ops[0])
                if note["src"] in regs:
                    note["srcval"] = regs[note["src"]]
            if ",m" in mn and b is not None:
                # base update: unknown afterwards
                note["basemod"] = b
        if note.get("kind") == "load" and ops:
            dest = reg_num(ops[-1])
    elif base in ("be", "ble"):
        m = MEM_RE.search(ins.ops)
        if m:
            d, b = parse_imm(m.group(1)), reg_num(m.group(3))
            if d is not None and b in regs:
                note["addr"] = (regs[b] + d) & 0xFFFFFFFF
            note["kind"] = "call" if base == "ble" or ",l" in mn else "branch"
    if dest is None and ops and base not in ("diag", "mtctl", "mtsp", "nop", "sync", "syncdma") \
            and not base.startswith("st") and not base.startswith("fst") \
            and not base.startswith("f") and base not in ("b", "bv", "be", "ble", "bl",
                                                          "comb", "comib", "cmpb", "cmpib",
                                                          "combt", "combf", "comibt", "comibf",
                                                          "bb", "bvb", "movb", "movib",
                                                          "addib", "addb", "pdtlb", "pitlb",
                                                          "pdtlbe", "pitlbe", "fdc", "fic",
                                                          "pdc", "fdce", "fice", "idtlba",
                                                          "idtlbp", "iitlba", "iitlbp",
                                                          "probe", "prober", "probew",
                                                          "rsm", "ssm", "mtsm", "rfi",
                                                          "rfir", "break", "gate", "lpa", "lci"):
        r = reg_num(ops[-1])
        if r is not None:
            dest = r
    if base in ("addib", "addb", "movb", "movib") and len(ops) >= 2:
        dest = reg_num(ops[1])
        val = None
    if base in ("rsm", "ssm", "lpa", "lci", "probe", "prober", "probew") and ops:
        dest = reg_num(ops[-1])
    if note.get("basemod") is not None:
        note["extra_dest"] = note["basemod"]
    return dest, val, note


def is_call(ins):
    base = ins.mnem.split(",")[0]
    ops = [o.strip() for o in ins.ops.split(",")] if ins.ops else []
    link_r0 = bool(ops) and reg_num(ops[-1]) == 0
    return (base in ("b", "bl") and (",l" in ins.mnem or base == "bl") and not link_r0) \
        or base == "ble"


def link_reg(ins):
    ops = [o.strip() for o in ins.ops.split(",")] if ins.ops else []
    if ins.mnem.startswith("ble"):
        return 31
    return reg_num(ops[-1]) if ops else None


def function_starts(insns):
    starts = set(romlib.load_symbols().keys())
    for ins in insns:
        if is_call(ins):
            for t in romlib.branch_targets(ins):
                starts.add(t)
    return sorted(starts)


def analyse(insns):
    starts = function_starts(insns)
    leaders = set()
    for i in insns:
        leaders.update(romlib.branch_targets(i))
    by_addr = {i.addr: k for k, i in enumerate(insns)}
    # split into functions
    funcs = []
    sset = set(starts)
    cur = []
    cur_start = insns[0].addr
    for ins in insns:
        if ins.addr in sset and cur:
            funcs.append((cur_start, cur))
            cur, cur_start = [], ins.addr
        cur.append(ins)
    if cur:
        funcs.append((cur_start, cur))

    results = []      # (pc, func, kind, ea, srcval, insn)
    callargs = []     # (pc, func, target, {r: val})
    for fstart, body in funcs:
        fconst = {}
        for _ in range(6):
            defs = collections.defaultdict(set)
            regs = {0: 0, 27: romlib.ROM_DP}
            regs.update(fconst)
            pending_kill = 0
            killset = ()
            out = []
            for ins in body:
                if pending_kill:
                    pending_kill -= 1
                    if pending_kill == 0:
                        for r in killset:
                            regs.pop(r, None)
                            defs[r].add(None)
                if ins.addr in leaders:
                    regs = {0: 0, 27: romlib.ROM_DP}
                    regs.update(fconst)
                dest, val, note = insn_effect(ins, regs)
                if is_call(ins):
                    args = {r: regs[r] for r in (26, 25, 24, 23) if r in regs}
                    out.append(("call", ins, args))
                out.append(("mem", ins, note))
                if dest is not None and dest != 0:
                    defs[dest].add(val)
                    if val is None:
                        regs.pop(dest, None)
                    else:
                        regs[dest] = val
                if note.get("extra_dest") is not None:
                    defs[note["extra_dest"]].add(None)
                    regs.pop(note["extra_dest"], None)
                if is_call(ins):
                    pending_kill = 2
                    killset = (28, 29, 31, link_reg(ins) or 2)
            newf = {r: next(iter(v)) for r, v in defs.items()
                    if len(v) == 1 and None not in v and r != 0}
            if newf == fconst:
                break
            fconst = newf
        for kind, ins, x in out:
            if kind == "call":
                tg = romlib.branch_targets(ins)
                if x:
                    callargs.append((ins.addr, fstart, tg[0] if tg else None, x))
            else:
                ea = x.get("addr")
                if ea is not None and ea >= DEV_LO and x.get("kind") in ("load", "store"):
                    results.append((ins.addr, fstart, x["kind"], ea, x.get("srcval"),
                                    ins.mnem + " " + ins.ops))
    return results, callargs


def main(argv):
    outdir = argv[1] if len(argv) > 1 else os.path.join(romlib.REPO, "roms", "disasm", "hwmap")
    os.makedirs(outdir, exist_ok=True)
    insns = romlib.disassemble()
    results, callargs = analyse(insns)
    syms = romlib.load_symbols()
    with open(os.path.join(outdir, "hwaccess_ext.tsv"), "w") as f:
        f.write("pc\tfunc\tkind\taddress\tname\tvalue_if_const\tinsn\n")
        for pc, fs, kind, ea, sv, txt in results:
            f.write("%08x\t%s\t%s\t%08x\t%s\t%s\t%s\n" % (
                pc, syms.get(fs, "F_%08x" % fs), kind, ea, romlib.name_addr(ea) or "",
                ("%#x" % sv) if sv is not None else "", txt))
    with open(os.path.join(outdir, "callargs.tsv"), "w") as f:
        f.write("pc\tfunc\ttarget\targs\n")
        for pc, fs, tg, args in callargs:
            f.write("%08x\t%s\t%s\t%s\n" % (
                pc, syms.get(fs, "F_%08x" % fs), ("%08x" % tg) if tg else "?",
                " ".join("r%d=%#x" % (r, v) for r, v in sorted(args.items(), reverse=True))))
    print("%d device accesses, %d calls with constant args" % (len(results), len(callargs)))


if __name__ == "__main__":
    main(sys.argv)
