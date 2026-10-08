#!/usr/bin/env python3
"""Turn suite vectors + a reference log into port-level vectors for the RTL
unit benches (verilator/tb_alu.cpp, tb_shift.cpp).

usage: unit_vectors.py alu|shift REFLOG [REFLOG...] -o OUT
       unit_vectors.py fp REFLOG -o OUT | fpmodel -o OUT | max1 -o OUT | mem REFLOG -o OUT

The mapping from mnemonic+condition to the module's control inputs here is
a reference decoder for the unit tests only; the CPU's real decoder is
checked end to end by running the suite ROMs on the whole CPU.

Expected values come from tests/cpu/model.py (the reference model), which
also marks what the architecture leaves open; the QEMU log is only the
source of the vector list. check mask: bit 0 result, bit 1 cond, bit 2 C/B.

alu line:   a b cb_in a_shift logic_op lop inv_b cin_sel dcor cond_class
            cond_c cond_f cb_we check ds psw_v | exp_result exp_cond exp_cb exp_v
            (hex; check bit 3 = V)
shift line: r1 r2 t_old imm5 op sign zero_fill use_imm amount len cond_c check
            | exp_result exp_cond                                     (hex)
max1 line:  a b op sat sa | exp_result                                (hex)
fp line:    op sgl dsgl rm cond a_hi a_lo b_hi b_lo check | exp_hi exp_lo
            exp_flags exp_c exp_unimpl   (hex; check bit 0 64-bit result,
            bit 1 upper word only (single result), bit 2 flags V Z O U I,
            bit 3 compare, bit 4 the unimplemented exception)
            `fp REFLOG` takes QEMU's results (fp suite); `fpmodel` takes
            model.py's for the fp and fpedge suites' vectors
mem line:   base index disp use_index scale ea_is_base base_trunc size stbys
            st_src kind base_we | 16 window words before | exp_r5 exp_r3off
            | 16 window words after   (hex; kind 0 load, 1 store, 2 ldcw)
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
    t, executed, cbw = p.words[:3]
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
    v = 0
    if len(p.words) > 3 and isinstance(p.words[3], int):
        chk |= 8
        v = p.words[3]
    return chk, res, cond, cb, v

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
    "ds": (0, 0, 0, 0, 0, 0, 0, CMP, 1, 1, 0),      # the ds input does the rest
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
        name = g["group"]
        if name.startswith("ds") and name[-3:] in (".v0", ".v1"):
            name = name[:-3]
        mn, cond, _carry = split_name(name)
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
            mask, er, ec, ecb, ev = expectation(suite, g["group"], vin, cb_in)
            if mn in ("comclr", "comiclr"):
                mask &= ~1                          # writes 0: the CPU's job, not the ALU's
            out.append("%08x %08x %02x %x %x %x %x %x %x %x %x %x %x %x %x %x | %08x %x %02x %x  # %s" % (
                a, b, cb_in, a_sh, lo, lop, inv, cin, dc, cls, cc, cf, cbwe, mask,
                int(mn == "ds"), vin.get("v", 0), er, ec, ecb, ev, g["group"]))
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
            mask, er, ec, _, _ = expectation("shift", g["group"], vin, cb_in)
            out.append("%08x %08x %08x %02x %x %x %x %x %02x %02x %x %x | %08x %x  # %s" % (
                r1, r2, t_old, imm, op, sign, zf, use_imm, amount, ln, SHIFTC[cond],
                mask & 3, er, ec, g["group"]))
    return out


def max1_lines():
    """MAX-1 needs no log (QEMU traps them): the model is the reference."""
    js = json.load(open(os.path.join(HERE, "build", "gen_max1.json")))
    ops = {"hadd": 0, "hsub": 1, "havg": 2, "hshladd": 3, "hshradd": 4}
    out = []
    for g in js:
        for vin in g["inputs"]:
            op, x, _, _, _ = model.max1_decode(vin["word"])
            sat = {"ss": 1, "us": 2}.get(x, 0) if op in ("hadd", "hsub") else 0
            sa = x if op in ("hshladd", "hshradd") else 0
            p = model.predict("max1", g["group"], vin)
            out.append("%08x %08x %x %x %x | %08x  # %s" % (
                vin["a"], vin["b"], ops[op], sat, sa, p.words[0], g["group"]))
    return out


AREA = 0x00100000


def mem_window(seed):
    """gen_tests.py mem_fill: 16 words, w <- rotr(w, 25) + 0x5b each step."""
    w, out = seed & 0xFFFFFFFF, []
    for _ in range(16):
        out.append(w)
        w = (((w >> 25) | (w << 7)) & 0xFFFFFFFF)
        w = (w + 0x5B) & 0xFFFFFFFF
    return out


def mem_lines(groups):
    """Port vectors for rtl/cpu/pa_ldst.sv from the mem suite and its log
    (QEMU is the reference here: the model does not cover memory)."""
    js = json.load(open(os.path.join(HERE, "build", "gen_mem.json")))
    out = []
    for g in js:
        name = g["group"]
        mn, _, cmpl = name.partition(",")
        cmpl = "," + cmpl if cmpl else ""
        if mn.startswith("ldcw") or mn == "ldwax":
            size = 2
        elif mn == "stbys":
            size = 0
        else:
            size = {"w": 2, "h": 1, "b": 0}[mn[2]]
        kind = 2 if mn.startswith("ldcw") else (0 if mn.startswith("ld") else 1)
        stbys = 0
        use_index = int(mn in ("ldwx", "ldhx", "ldbx", "ldcwx", "ldwax"))
        scale = int("s" in cmpl.replace(",", ""))
        ea_is_base = base_we = base_trunc = 0
        if mn in ("ldwm", "stwm"):
            base_we = 1
        elif use_index and "m" in cmpl:
            ea_is_base = base_we = 1
        elif cmpl == ",ma":
            ea_is_base = base_we = 1
        elif cmpl == ",mb":
            base_we = 1
        elif mn == "stbys":
            stbys = 2 if "e" in cmpl else 1
            if ",m" in cmpl:
                base_we = base_trunc = 1
                ea_is_base = int(stbys == 1)
        if mn.startswith("ldcw"):
            size = 2
        for vin, res in zip(g["inputs"], groups[name]):
            base = AREA + vin["off"]
            disp = vin["disp"] & 0xFFFFFFFF
            eib = ea_is_base
            if mn in ("ldwm", "stwm"):
                eib = int(vin["disp"] >= 0)
            before = mem_window(vin["seed"])
            out.append("%08x %08x %08x %x %x %x %x %x %x %08x %x %x | %s | %08x %08x | %s  # %s" % (
                base, vin["index"] & 0xFFFFFFFF, disp, use_index, scale, eib, base_trunc,
                size, stbys, vin["val"], kind, base_we,
                " ".join("%08x" % w for w in before), res[0], res[1],
                " ".join("%08x" % w for w in res[2:18]), name))
    return out


# ---- fp: the engine alone (rtl/cpu/pa_fpu.sv) on the fp suite's vectors, with
# QEMU's results as the expectation. fmpyadd/fmpysub (two engine operations)
# are left to the whole-CPU run.
FP_OPS = {"fadd": 0, "fsub": 1, "fmpy": 2, "fdiv": 3, "fsqrt": 4, "fcpy": 5, "fabs": 6,
          "fcnvff": 7, "fcnvxf": 8, "fcnvfx": 9, "fcnvfxt": 10, "fcmp": 11, "xmpyu": 12,
          "frnd": 13}
FP_CONDS = ["false?", "false", "?", "!<=>", "=", "=t", "?=", "!<>", "!?>=", "<", "?<",
            "!>=", "!?>", "<=", "?<=", "!>", "!?<=", ">", "?>", "!<=", "!?<", ">=", "?>=",
            "!<", "!?=", "<>", "!=", "!=t", "!?", "<=>", "true?", "true"]
FP_RMS = {"rn": 0, "rz": 1, "rp": 2, "rm": 3}


def fp_lines(groups, suite="fp"):
    with open(os.path.join(HERE, "build", "gen_%s.json" % suite)) as f:
        gen = {g["group"]: g["inputs"] for g in json.load(f)}
    lines = []
    for name, rows in groups.items():
        if name.startswith("fmpy") and "," in name and name.split(",")[0] in ("fmpyadd", "fmpysub"):
            continue
        base, _, rmn = name.partition(".")
        parts = base.split(",")
        mn = parts[0]
        if mn not in FP_OPS:
            continue
        rm = FP_RMS.get(rmn, 0)
        cond = 0
        if mn == "fcmp":
            sgl = parts[1] == "sgl"; dsgl = sgl; cond = FP_CONDS.index(parts[2])
        elif mn == "xmpyu":
            sgl = True; dsgl = False
        elif mn.startswith("fcnv"):
            sgl = parts[1] == "sgl"; dsgl = parts[2] == "sgl"
        else:
            sgl = parts[1] == "sgl"; dsgl = sgl
        for vin, row in zip(gen[name], rows):
            a = vin["a"] << 32 if sgl else vin["a"]
            b = vin.get("b", 0)
            b = b << 32 if sgl else b
            status = row[2]
            flags, c = (status >> 27) & 0x1F, (status >> 26) & 1
            chk = 4
            if mn == "fcmp":
                chk |= 8
            else:
                chk |= 2 if dsgl else 1
            lines.append("%x %d %d %d %x %08x %08x %08x %08x %x | %08x %08x %x %d 0 # %s" % (
                FP_OPS[mn], sgl, dsgl, rm, cond, a >> 32, a & 0xFFFFFFFF, b >> 32, b & 0xFFFFFFFF,
                chk, row[0], row[1], flags, c, name))
    return lines


def fpmodel_lines(suites=("fp", "fpedge")):
    """Engine vectors for the fp and fpedge suites with model.py's
    expectations (ERS s.7.3), including whether the operation is
    unimplemented. The single-engine-op groups only."""
    lines = []
    for suite in suites:
        with open(os.path.join(HERE, "build", "gen_%s.json" % suite)) as f:
            gen = json.load(f)
        for g in gen:
            name = g["group"]
            mn = name.split(",")[0].split(".")[0]
            if mn not in FP_OPS or mn == "xmpyu":
                continue
            mn, sgl, dsgl, rm, cond = model.fp_parse_group(name)
            for vin in g["inputs"]:
                r = model.fp_operate(mn, sgl, dsgl, vin["a"], vin.get("b", 0), cond or 0, rm << 9)
                a = vin["a"] << 32 if sgl else vin["a"]
                b = vin.get("b", 0)
                b = b << 32 if sgl else b
                chk = 16
                eh = el = flags = c = 0
                if not r.unimpl:
                    chk |= 4
                    flags = sum(1 << {"V": 4, "Z": 3, "O": 2, "U": 1, "I": 0}[f] for f in r.flags)
                    if mn == "fcmp":
                        chk |= 8
                        c = r.cmp
                    elif r.single:
                        chk |= 2
                        eh = r.value
                    else:
                        chk |= 1
                        eh, el = r.value >> 32, r.value & 0xFFFFFFFF
                lines.append("%x %d %d %d %x %08x %08x %08x %08x %x | %08x %08x %x %d %d # %s" % (
                    FP_OPS[mn], sgl, dsgl, rm, cond or 0, a >> 32, a & 0xFFFFFFFF, b >> 32, b & 0xFFFFFFFF,
                    chk, eh, el, flags, c, int(r.unimpl), name))
    return lines


def main(argv):
    if len(argv) >= 5 and argv[1] == "fp" and "-o" in argv:
        o = argv.index("-o")
        groups, _ = read_log(argv[2])
        lines = fp_lines(groups)
        with open(argv[o + 1], "w") as f:
            f.write("\n".join(lines) + "\n")
        print("fp: %d vectors -> %s" % (len(lines), argv[o + 1]))
        return
    if len(argv) >= 4 and argv[1] == "fpmodel" and argv[2] == "-o":
        lines = fpmodel_lines()
        with open(argv[3], "w") as f:
            f.write("\n".join(lines) + "\n")
        print("fpmodel: %d vectors -> %s" % (len(lines), argv[3]))
        return
    if len(argv) >= 5 and argv[1] == "mem" and "-o" in argv:
        o = argv.index("-o")
        groups, _ = read_log(argv[2])
        lines = mem_lines(groups)
        with open(argv[o + 1], "w") as f:
            f.write("\n".join(lines) + "\n")
        print("mem: %d vectors -> %s" % (len(lines), argv[o + 1]))
        return
    if len(argv) >= 4 and argv[1] == "max1" and argv[2] == "-o":
        lines = max1_lines()
        with open(argv[3], "w") as f:
            f.write("\n".join(lines) + "\n")
        print("max1: %d vectors -> %s" % (len(lines), argv[3]))
        return
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
