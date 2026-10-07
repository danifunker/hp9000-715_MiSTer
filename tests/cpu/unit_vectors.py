#!/usr/bin/env python3
"""Turn suite vectors + a reference log into port-level vectors for the RTL
unit benches (verilator/tb_alu.cpp, tb_shift.cpp).

usage: unit_vectors.py alu|shift REFLOG [REFLOG...] -o OUT

The mapping from mnemonic+condition to the module's control inputs here is
a reference decoder for the unit tests only; the CPU's real decoder is
checked end to end by running the suite ROMs on the whole CPU.

Expected values come from tests/cpu/model.py (the reference model), which
also marks what the architecture leaves open; the QEMU log is only the
source of the vector list. check mask: bit 0 result, bit 1 cond, bit 2 C/B.

alu line:   a b cb_in a_shift logic_op lop inv_b cin_sel dcor cond_class
            cond_c cond_f cb_we check | exp_result exp_cond exp_cb   (hex)
shift line: r1 r2 t_old imm5 op sign zero_fill use_imm amount len cond_c check
            | exp_result exp_cond                                     (hex)
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import model  # noqa: E402


def expectation(suite, group, vin, cb_in):
    """(check mask, result, cond, cb) from the model's prediction."""
    p = model.predict(suite, group, vin)
    t, executed, cbw = p.words
    chk = 0
    res = cond = cb = 0
    if isinstance(t, int):
        chk |= 1
        res = t
    if isinstance(executed, int):
        chk |= 2
        cond = 0 if executed else 1
    if cbw is model.INHERIT:
        chk |= 4
        cb = cb_in
    elif isinstance(cbw, int):
        chk |= 4
        cb = cb_from_idcor(cbw)
    return chk, res, cond, cb

ARITH = {"": (0, 0), "=": (1, 0), "<": (2, 0), "<=": (3, 0), "nuv": (4, 0), "znv": (5, 0),
         "sv": (6, 0), "od": (7, 0), "tr": (0, 1), "<>": (1, 1), ">=": (2, 1), ">": (3, 1),
         "uv": (4, 1), "vnz": (5, 1), "nsv": (6, 1), "ev": (7, 1)}
CMP = {"": (0, 0), "=": (1, 0), "<": (2, 0), "<=": (3, 0), "<<": (4, 0), "<<=": (5, 0),
       "sv": (6, 0), "od": (7, 0), "tr": (0, 1), "<>": (1, 1), ">=": (2, 1), ">": (3, 1),
       ">>=": (4, 1), ">>": (5, 1), "nsv": (6, 1), "ev": (7, 1)}
LOG = {"": (0, 0), "=": (1, 0), "<": (2, 0), "<=": (3, 0), "od": (7, 0), "tr": (0, 1),
       "<>": (1, 1), ">=": (2, 1), ">": (3, 1), "ev": (7, 1)}
UNIT = {"": (0, 0), "sbz": (2, 0), "shz": (3, 0), "sdc": (4, 0), "sbc": (6, 0), "shc": (7, 0),
        "tr": (0, 1), "nbz": (2, 1), "nhz": (3, 1), "ndc": (4, 1), "nbc": (6, 1), "nhc": (7, 1)}
SHIFTC = {"": 0, "=": 1, "<": 2, "od": 3, "tr": 4, "<>": 5, ">=": 6, "ev": 7}

# mnemonic -> (a_shift, logic_op, lop, inv_b, cin_sel, dcor, class, table, cb_we, check_result, imm)
ALU = {
    "add": (0, 0, 0, 0, 0, 0, 0, ARITH, 1, 1, 0), "addl": (0, 0, 0, 0, 0, 0, 0, ARITH, 0, 1, 0),
    "addc": (0, 0, 0, 0, 2, 0, 0, ARITH, 1, 1, 0),
    "sh1add": (1, 0, 0, 0, 0, 0, 0, ARITH, 1, 1, 0), "sh2add": (2, 0, 0, 0, 0, 0, 0, ARITH, 1, 1, 0),
    "sh3add": (3, 0, 0, 0, 0, 0, 0, ARITH, 1, 1, 0), "sh1addl": (1, 0, 0, 0, 0, 0, 0, ARITH, 0, 1, 0),
    "sh2addl": (2, 0, 0, 0, 0, 0, 0, ARITH, 0, 1, 0), "sh3addl": (3, 0, 0, 0, 0, 0, 0, ARITH, 0, 1, 0),
    "sub": (0, 0, 0, 1, 1, 0, 0, CMP, 1, 1, 0), "subb": (0, 0, 0, 1, 2, 0, 0, CMP, 1, 1, 0),
    "comclr": (0, 0, 0, 1, 1, 0, 0, CMP, 0, 0, 0),
    "and": (0, 1, 0, 0, 0, 0, 1, LOG, 0, 1, 0), "andcm": (0, 1, 1, 0, 0, 0, 1, LOG, 0, 1, 0),
    "or": (0, 1, 2, 0, 0, 0, 1, LOG, 0, 1, 0), "xor": (0, 1, 3, 0, 0, 0, 1, LOG, 0, 1, 0),
    "uxor": (0, 1, 3, 0, 0, 0, 2, UNIT, 0, 1, 0),
    "uaddcm": (0, 0, 0, 1, 0, 0, 2, UNIT, 0, 1, 0), "uaddcmt": (0, 0, 0, 1, 0, 0, 2, UNIT, 0, 1, 0),
    "dcor": (0, 0, 0, 0, 0, 1, 2, UNIT, 0, 1, 0), "idcor": (0, 0, 0, 0, 0, 2, 2, UNIT, 0, 1, 0),
    "addi": (0, 0, 0, 0, 0, 0, 0, ARITH, 1, 1, 1), "subi": (0, 0, 0, 1, 1, 0, 0, CMP, 1, 1, 1),
    "comiclr": (0, 0, 0, 1, 1, 0, 0, CMP, 0, 0, 1),
}


def read_log(path):
    groups, order, cur = {}, [], None
    for line in open(path):
        m = re.match(r"== (\S+) ([0-9a-f]+)$", line.strip())
        if m:
            cur = m.group(1)
            groups[cur] = []
            order.append(cur)
            continue
        m = re.match(r"([0-9a-f]{4}) (.*)$", line.strip())
        if m and cur is not None:
            groups[cur].append([int(x, 16) for x in m.group(2).split()])
    return groups, order


def split_name(g):
    """'add,<=.c1' -> ('add', '<=', 1)"""
    carry = None
    m = re.match(r"(.*)\.c([01])$", g)
    if m:
        g, carry = m.group(1), int(m.group(2))
    mn, _, cond = g.partition(",")
    return mn, cond, carry


def cb_from_idcor(w):
    return sum(1 << i for i in range(8) if ((w >> (4 * i)) & 0xF) == 6)


def alu_lines(suite, groups):
    js = json.load(open(os.path.join(HERE, "build", "gen_%s.json" % suite)))
    out = []
    for g in js:
        mn, cond, _carry = split_name(g["group"])
        if mn not in ALU:
            continue
        a_sh, lo, lop, inv, cin, dc, cls, table, cbwe, chk, imm = ALU[mn]
        if cond not in table:
            continue
        cc, cf = table[cond]
        for vin, res in zip(g["inputs"], groups[g["group"]]):
            if imm:
                a, b = vin["imm"] & 0xFFFFFFFF, vin["a"]
            elif dc:
                a, b = 0, vin["a"]
            else:
                a, b = vin["a"], vin["b"]
            cb_in = 0xFF if vin.get("carry") else 0x00
            mask, er, ec, ecb = expectation(suite, g["group"], vin, cb_in)
            if mn in ("comclr", "comiclr"):
                mask &= ~1                          # writes 0: the CPU's job, not the ALU's
            out.append("%08x %08x %02x %x %x %x %x %x %x %x %x %x %x %x | %08x %x %02x  # %s" % (
                a, b, cb_in, a_sh, lo, lop, inv, cin, dc, cls, cc, cf, cbwe, mask,
                er, ec, ecb, g["group"]))
    return out


def shift_lines(groups):
    js = json.load(open(os.path.join(HERE, "build", "gen_shift.json")))
    out = []
    for g in js:
        mn, cond, _ = split_name(g["group"])
        if cond not in SHIFTC or "/" in mn:
            continue
        for vin, res in zip(g["inputs"], groups[g["group"]]):
            r1, r2, t_old = vin["a"], vin["b"], vin["b"]
            imm = vin["imm"] & 0x1F
            sign = zf = use_imm = 0
            variable = mn in ("vshd", "vextru", "vextrs", "zvdep", "vdep", "vdepi", "zvdepi")
            amount = vin["sar"] if (variable or mn == "shd") else vin["pos"]
            ln = vin["vlen"] if variable else vin["len"]
            if mn in ("shd", "vshd"):
                op = 0
            elif mn in ("extru", "extrs", "vextru", "vextrs"):
                op, sign = 1, int(mn.endswith("s"))
            else:
                op = 2
                zf = int(mn.startswith("z"))
                use_imm = int(mn.endswith("i"))
            cb_in = 0xFF if vin.get("carry") else 0x00
            mask, er, ec, _ = expectation("shift", g["group"], vin, cb_in)
            out.append("%08x %08x %08x %02x %x %x %x %x %02x %02x %x %x | %08x %x  # %s" % (
                r1, r2, t_old, imm, op, sign, zf, use_imm, amount, ln, SHIFTC[cond],
                mask & 3, er, ec, g["group"]))
    return out


def main(argv):
    if len(argv) < 5 or argv[1] not in ("alu", "shift") or "-o" not in argv:
        sys.exit(__doc__)
    kind = argv[1]
    o = argv.index("-o")
    logs, outp = argv[2:o], argv[o + 1]
    lines = []
    for lp in logs:
        groups, _ = read_log(lp)
        suite = os.path.basename(lp).split(".")[0]
        lines += alu_lines(suite, groups) if kind == "alu" else shift_lines(groups)
    with open(outp, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("%s: %d vectors -> %s" % (kind, len(lines), outp))


if __name__ == "__main__":
    main(sys.argv)
