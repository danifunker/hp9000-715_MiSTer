#!/usr/bin/env python3
"""Independent reference model of the PA-RISC 1.1 integer instructions that
the pacputest alu1, alu2 and shift suites exercise, and of the PA-7100LC's
MAX-1 halfword instructions (max1 suite) -- tests/cpu/README.md.

Source: "PA-RISC 1.1 Architecture and Instruction Set Reference Manual",
3rd edition (docs/reference/txt/Pa11_acd.txt), cited below as [ACD p.N]
with the manual's page numbers (chapter-page). Where the architecture leaves
a choice to the implementation, the PA-7100LC's ERS (docs/reference/txt/
PCXL_ers.txt) decides, cited as [PCXL ERS s.N]. MAX-1 comes from the
PA-RISC 2.0 manual [PA2 p.N] and the PA-7300LC ERS [PCXL2 ERS p.N] (see
its section below). Nothing here is taken from QEMU; QEMU_BUGS at the end
records where QEMU was found to be wrong.

Conventions
-----------
* Words are Python ints in 0..2**32-1. The manual numbers bits big-endian
  (bit 0 = most significant); the code uses ordinary shifts.
* PSW[C/B] is kept as an 8-bit int `cb` whose bit j is the carry out of the
  4-bit digit j counted from the RIGHT (bit 0 = carry out of bits 3..0).
  The manual's PSW[C/B]{i} counts digits from the left, so C/B{i} is
  bit 7-i of `cb`, and C/B{0} (the leftmost, used by ADDC/SUBB) is
  `cb >> 7` [ACD p.2-11, p.5-8].
* An expectation for one output word is one of
      int            exactly this value
      frozenset      any one of these values
      None           unpredictable: the architecture does not define it
      INHERIT        not changed by the vector: whatever the PSW held when
                     the group started (the same for every vector of it)
  `check(expect, value)` tests a value against one.

Entry point for the comparison tool: `predict(suite, group, inputs)` returns
a `Prediction` (three expectations plus explanatory notes) for one vector of
tests/cpu/build/gen_<suite>.json.
"""

M32 = 0xFFFFFFFF

# ---------------------------------------------------------------------------
# Expectations
# ---------------------------------------------------------------------------


class _Inherit:
    def __repr__(self):
        return "INHERIT"


INHERIT = _Inherit()


def check(expect, value):
    """True if `value` satisfies `expect` (INHERIT is checked per group by
    the caller, so on its own it accepts anything)."""
    if expect is None or expect is INHERIT:
        return True
    if isinstance(expect, frozenset):
        return value in expect
    return value == expect


def fmt_expect(expect):
    if expect is None:
        return "--------"
    if expect is INHERIT:
        return "(group)"
    if isinstance(expect, frozenset):
        return "|".join("%08x" % v for v in sorted(expect))
    return "%08x" % expect


class Prediction:
    """Expected output words of one vector: [GR t, executed flag, C/B map]."""

    def __init__(self, words, notes=()):
        self.words = list(words)
        self.notes = list(notes)

    def __repr__(self):
        return "Prediction(%s%s)" % (" ".join(fmt_expect(w) for w in self.words),
                                     "; " + "; ".join(self.notes) if self.notes else "")


class Outcome:
    """Architectural effect of one instruction.

    t     value written to the target register (int, frozenset or None)
    cond  cond_satisfied: True / False, or None when the architecture leaves
          it unpredictable (the following instruction is then nullified or not)
    cb    new PSW[C/B] (8-bit, see Conventions) or None if C/B is unchanged
    notes free text explaining relaxed expectations
    """

    def __init__(self, t, cond=False, cb=None, notes=()):
        self.t, self.cond, self.cb, self.notes = t, cond, cb, list(notes)

    def __repr__(self):
        return "Outcome(t=%s cond=%s cb=%s)" % (fmt_expect(self.t), self.cond,
                                               None if self.cb is None else "%02x" % self.cb)


# ---------------------------------------------------------------------------
# Small helpers [ACD p.5-8..5-10: sign_ext, low_sign_ext, zero_ext, cat]
# ---------------------------------------------------------------------------

def s32(x):
    """Two's complement value of a 32-bit word."""
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def sign_ext(x, n):
    """sign_ext(x, len) [ACD p.5-9]: the rightmost n bits of x, sign extended."""
    x &= (1 << n) - 1
    if x & (1 << (n - 1)):
        x -= 1 << n
    return x & M32


def mask(n):
    """n rightmost ones (n = 0..32)."""
    return (1 << n) - 1


def digit_carries(x, y, cin):
    """Carry out of each 4-bit digit of the 32-bit sum x + y + cin.

    This is the "carry_borrows" variable of the arithmetic instructions
    [ACD p.5-83 ADD, p.5-97 SUB] and the "eight 4-bit carries" of the unit
    conditions [ACD p.5-6]. Bit j of the result = carry out of digit j
    counted from the right; bit 7 is the carry out of the whole word."""
    cb = 0
    for j in range(8):
        w = 4 * (j + 1)
        if ((x & mask(w)) + (y & mask(w)) + cin) >> w:
            cb |= 1 << j
    return cb


def cb_map(cb):
    """The word IDCOR %r0,t produces from PSW[C/B] = cb: 0x6 in every digit
    whose C/B bit is 1 [ACD p.5-114 IDCOR]. 0 + 6 never carries between
    digits, so this is exact. The test ROM stores it as the third word."""
    w = 0
    for j in range(8):
        if cb >> j & 1:
            w |= 6 << (4 * j)
    return w


def cb_from_map(word):
    """Inverse of cb_map, or None if `word` is not a valid map."""
    cb = 0
    for j in range(8):
        d = word >> (4 * j) & 0xF
        if d == 6:
            cb |= 1 << j
        elif d != 0:
            return None
    return cb


class Sum:
    """x + y + cin as the 32-bit ALU computes it.

    res    32-bit result
    carry  carry out of bit 0 (the leftmost bit)
    sv     signed overflow: the true sum of the signed operands (plus cin)
           is not representable in 32 bits [ACD Table 5-2, p.5-3]
    cb     the eight digit carries (carry_borrows)"""

    def __init__(self, x, y, cin):
        x &= M32
        y &= M32
        full = x + y + cin
        self.res = full & M32
        self.carry = full >> 32
        true = s32(x) + s32(y) + cin
        self.sv = not (-(1 << 31) <= true < (1 << 31))
        self.cb = digit_carries(x, y, cin)


# ---------------------------------------------------------------------------
# Condition completers -> (c, f) [ACD Tables 5-3..5-7, pp.5-5..5-7]
# ---------------------------------------------------------------------------

COND_ADD = {"": (0, 0), "=": (1, 0), "<": (2, 0), "<=": (3, 0), "nuv": (4, 0),
            "znv": (5, 0), "sv": (6, 0), "od": (7, 0),
            "tr": (0, 1), "<>": (1, 1), ">=": (2, 1), ">": (3, 1), "uv": (4, 1),
            "vnz": (5, 1), "nsv": (6, 1), "ev": (7, 1)}            # Table 5-4

COND_CMP = {"": (0, 0), "=": (1, 0), "<": (2, 0), "<=": (3, 0), "<<": (4, 0),
            "<<=": (5, 0), "sv": (6, 0), "od": (7, 0),
            "tr": (0, 1), "<>": (1, 1), ">=": (2, 1), ">": (3, 1), ">>=": (4, 1),
            ">>": (5, 1), "nsv": (6, 1), "ev": (7, 1)}             # Table 5-3

COND_LOG = {"": (0, 0), "=": (1, 0), "<": (2, 0), "<=": (3, 0), "od": (7, 0),
            "tr": (0, 1), "<>": (1, 1), ">=": (2, 1), ">": (3, 1),
            "ev": (7, 1)}                                           # Table 5-5

COND_UNIT = {"": (0, 0), "sbz": (2, 0), "shz": (3, 0), "sdc": (4, 0),
             "sbc": (6, 0), "shc": (7, 0),
             "tr": (0, 1), "nbz": (2, 1), "nhz": (3, 1), "ndc": (4, 1),
             "nbc": (6, 1), "nhc": (7, 1)}                          # Table 5-6

COND_SHIFT = {"": 0, "=": 1, "<": 2, "od": 3, "tr": 4, "<>": 5, ">=": 6,
              "ev": 7}                                              # Table 5-7


def _negate(r, f):
    return None if r is None else bool(r) ^ bool(f)


_SAME = object()


def arith_cond(c, f, res, uv, sv, sub, sv23=_SAME):
    """Arithmetic/logical conditions [ACD Table 5-1, p.5-3].

    res   32-bit result
    uv    unsigned overflow as Table 5-2 defines it (adds: carry == 1;
          subtracts/compares: borrow, i.e. carry == 0)
    sv    signed overflow (condition 6)
    sub   True for subtracts/compares: conditions 4 and 5 then test unsigned
          overflow instead of its absence
    sv23  the overflow XORed into conditions 2 and 3 when it differs from
          sv (SHIFT AND ADD, p.5-4); None means "not predictable"
    Returns True/False, or None when the condition depends on something
    the architecture leaves unpredictable."""
    if sv23 is _SAME:
        sv23 = sv
    z = res == 0
    neg = bool(res >> 31)
    if c == 0:
        r = False
    elif c == 1:
        r = z
    elif c == 2:
        r = None if sv23 is None else neg ^ sv23
    elif c == 3:
        r = True if z else (None if sv23 is None else neg ^ sv23)
    elif c == 4:
        r = uv if sub else (not uv)
    elif c == 5:
        r = z or (uv if sub else (not uv))
    elif c == 6:
        r = sv
    else:
        r = bool(res & 1)
    return _negate(r, f)


def logical_cond(c, f, res):
    """Logical conditions [ACD Table 5-5, p.5-6]; c = 4, 5, 6 are undefined."""
    if c in (4, 5, 6):
        return None
    return arith_cond(c, f, res, uv=False, sv=False, sub=False)


def unit_cond(c, f, res, cb):
    """Unit conditions [ACD Table 5-6, p.5-6]: computed from the 32-bit result
    and the eight digit carries `cb` (None = no carries defined)."""
    if c == 0:
        r = False
    elif c == 2:                                    # SBZ some byte zero
        r = any((res >> s) & 0xFF == 0 for s in (0, 8, 16, 24))
    elif c == 3:                                    # SHZ some halfword zero
        r = any((res >> s) & 0xFFFF == 0 for s in (0, 16))
    elif c in (4, 6, 7):
        if cb is None:
            return None
        sel = {4: 0xFF,                             # SDC any digit carry
               6: 0xAA,                             # SBC carry out of a byte
               7: 0x88}[c]                          # SHC carry out of a halfword
        r = bool(cb & sel)
    else:                                           # c = 1, 5: undefined
        return None
    return _negate(r, f)


def shift_cond(c, res):
    """Shift/extract/deposit conditions [ACD Table 5-7, p.5-7]."""
    return [False, res == 0, bool(res >> 31), bool(res & 1), True, res != 0,
            not res >> 31, not res & 1][c]


# ---------------------------------------------------------------------------
# Arithmetic: ADD, ADDL, ADDC, SHnADD(L), SUB, SUBB, COMCLR, ADDI, SUBI,
# COMICLR [ACD pp.5-83..5-104, 5-115..5-121]
# ---------------------------------------------------------------------------

# Which instructions write PSW[C/B] [ACD p.2-11, PSW C/B field; and each
# page's Operation section]. ADDL, SHnADDL, COMCLR, COMICLR, UADDCM(T),
# DCOR and IDCOR do not.
SETS_CB = {"add", "addc", "sh1add", "sh2add", "sh3add", "sub", "subb",
           "addi", "subi"}


def arith(op, cond, r1, r2, cb_in):
    """Three-register adds/subtracts/compares (operands GR r1, GR r2 in
    assembler order) and the 11-bit immediate forms ADDI/SUBI/COMICLR
    (operands i, GR r: pass r1 = i, r2 = GR r).

    Returns an Outcome."""
    notes = []
    cin_cb = cb_in >> 7 & 1 if cb_in is not None else None
    if op in ("add", "addl", "addi"):
        # ADD p.5-83, ADDL p.5-84: GR[t] <- GR[r1] + GR[r2]
        # ADDI p.5-115: GR[t] <- low_sign_ext(im11,11) + GR[r]
        s = Sum(r1, r2, 0)
        sub, uv, sv, sv23, res = False, bool(s.carry), s.sv, _SAME, s.res
    elif op == "addc":
        # ADDC p.5-86: GR[t] <- GR[r1] + GR[r2] + PSW[C/B]{0}
        s = Sum(r1, r2, cin_cb)
        sub, uv, sv, sv23, res = False, bool(s.carry), s.sv, _SAME, s.res
    elif op[:2] == "sh" and op[3:6] == "add":
        # SH1ADD p.5-88 .. SH3ADDL p.5-95: GR[t] <- lshift(GR[r1],n) + GR[r2].
        # Signed overflow (condition 6) = a bit shifted out differs from the
        # leftmost bit after the shift, or the add overflows; unsigned
        # overflow = a bit shifted out is 1, or the add carries.
        # Conditions 2/3 must XOR the add's overflow and may also include the
        # pre-shift's; if the pre-shift overflowed (signed) their result "is
        # not predictable" [p.5-3/5-4].
        n = int(op[2])
        sh = (r1 << n) & M32
        out = r1 >> (32 - n)                          # the bits shifted out
        top = r1 >> (31 - n)                          # those + new leftmost bit
        shift_sv = top not in (0, mask(n + 1))
        shift_uv = out != 0
        s = Sum(sh, r2, 0)
        sub, res = False, s.res
        uv = shift_uv or bool(s.carry)
        sv = shift_sv or s.sv
        sv23 = None if shift_sv else s.sv
        if shift_sv and cond in ("<", "<=", ">=", ">"):
            notes.append("signed overflow in the pre-shift: condition 2/3 "
                         "not predictable [ACD p.5-4]")
    elif op in ("sub", "comclr", "subi", "comiclr"):
        # SUB p.5-97: GR[t] <- GR[r1] + ~GR[r2] + 1
        # COMCLR p.5-104 / COMICLR p.5-121: the same sum, GR[t] <- 0
        # SUBI p.5-119: GR[t] <- low_sign_ext(im11,11) + ~GR[r] + 1
        s = Sum(r1, ~r2, 1)
        sub, uv, sv, sv23, res = True, not s.carry, s.sv, _SAME, s.res
    elif op == "subb":
        # SUBB p.5-99: GR[t] <- GR[r1] + ~GR[r2] + PSW[C/B]{0}
        s = Sum(r1, ~r2, cin_cb)
        sub, uv, sv, sv23, res = True, not s.carry, s.sv, _SAME, s.res
    else:
        raise ValueError(op)

    table = COND_CMP if sub else COND_ADD
    c, f = table[cond]
    cs = arith_cond(c, f, res, uv, sv, sub, sv23)
    if op in ("comclr", "comiclr"):
        res = 0
    return Outcome(res, cs, s.cb if op in SETS_CB else None, notes)



# ---------------------------------------------------------------------------
# DIVIDE STEP [ACD p.5-102/5-103]
#   if PSW[V]: GR[t] <- cat(lshift(GR[r1],1), PSW[C/B]{0}) + ~GR[r2] + 1
#   else:      GR[t] <- cat(lshift(GR[r1],1), PSW[C/B]{0}) + GR[r2]
#   PSW[C/B] <- carry_borrows ; PSW[V] <- xor(carry_borrows{0}, GR[r2]{0})
# Conditions: the compare/subtract table (5-3), read as the subtract or add
# interpretation of Table 5-1 depending on PSW[V] [p.5-5]. Overflow
# includes the shift: signed = the bit shifted out differs from the new
# leftmost bit, or the add/sub overflows; unsigned = the bit shifted out is
# 1, or the add carries / the subtract borrows [p.5-103].
# ---------------------------------------------------------------------------

def ds(cond, r1, r2, cb_in, v):
    """Returns (Outcome, new V)."""
    r1 &= M32
    r2 &= M32
    shifted = ((r1 << 1) | (cb_in >> 7 & 1)) & M32
    out = r1 >> 31                                    # the bit shifted out
    shift_sv = out != (r1 >> 30 & 1)
    s = Sum(shifted, ~r2, 1) if v else Sum(shifted, r2, 0)
    if v:                                             # subtract interpretation
        uv = bool(out) or not s.carry                 # "unsigned overflow" = borrow
    else:
        uv = bool(out) or bool(s.carry)
    sv = shift_sv or s.sv
    c, f = COND_CMP[cond]
    notes = []
    sv23 = None if shift_sv else s.sv
    if shift_sv and cond in ("<", "<=", ">=", ">"):
        notes.append("signed overflow in the pre-shift: condition 2/3 not predictable [ACD p.5-5]")
    cs = arith_cond(c, f, s.res, uv, sv, bool(v), sv23)
    v_new = (s.carry ^ (r2 >> 31)) & 1
    return Outcome(s.res, cs, s.cb, notes), v_new

# ---------------------------------------------------------------------------
# Logical: AND, ANDCM, OR, XOR [ACD pp.5-105..5-108]
# ---------------------------------------------------------------------------

def logical(op, cond, r1, r2):
    res = {"and": r1 & r2,                          # p.5-107
           "andcm": r1 & ~r2 & M32,                 # p.5-108
           "or": r1 | r2,                           # p.5-105
           "xor": r1 ^ r2}[op]                      # p.5-106
    c, f = COND_LOG[cond]
    return Outcome(res, logical_cond(c, f, res))


# ---------------------------------------------------------------------------
# Unit: UXOR, UADDCM, UADDCMT, DCOR, IDCOR [ACD pp.5-109..5-114]
# ---------------------------------------------------------------------------

def unit(op, cond, r1, r2, cb_in):
    """UXOR/UADDCM/UADDCMT take GR r1, GR r2; DCOR/IDCOR take GR r (r1)."""
    c, f = COND_UNIT[cond]
    notes = []
    if op == "uxor":
        # p.5-109: GR[t] <- xor(GR[r1],GR[r2]); only the conditions not
        # involving carries are defined, so there are no carries.
        res = r1 ^ r2
        return Outcome(res, unit_cond(c, f, res, None))
    if op in ("uaddcm", "uaddcmt"):
        # p.5-110: GR[t] <- GR[r1] + ~GR[r2] (no +1); C/B not updated.
        # p.5-111 UADDCMT: same sum; a satisfied condition traps instead of
        # writing GR t. The suite only runs it with no condition.
        s = Sum(r1, ~r2, 0)
        cs = unit_cond(c, f, s.res, s.cb)
        if op == "uaddcmt" and cs:
            raise ValueError("uaddcmt with a satisfied condition traps")
        return Outcome(s.res, cs)
    if op in ("dcor", "idcor"):
        # DCOR p.5-112: GR[t] <- GR[r] - cat(0x6*(1-PSW[C/B]{i}) ...)
        # IDCOR p.5-114: GR[t] <- GR[r] + cat(0x6*PSW[C/B]{i} ...)
        # Both are whole-word operations (borrows/carries cross digits), and
        # neither writes PSW[C/B].
        if op == "dcor":
            x = cb_map(~cb_in & 0xFF)
            s = Sum(r1, ~x, 1)                      # GR[r] - x
        else:
            x = cb_map(cb_in)
            s = Sum(r1, x, 0)
        res = s.res
        # The unit conditions use "the eight 4-bit carries" [p.5-6], which
        # the manual does not define for DCOR/IDCOR: they could be the
        # digit carries of the correcting add/subtract, or the PSW C/B bits
        # the correction was computed from. The carry conditions (SDC, SBC,
        # SHC and negations) are exact only where both readings agree.
        cs_adder = unit_cond(c, f, res, s.cb)
        cs_psw = unit_cond(c, f, res, cb_in)
        if cs_adder == cs_psw:
            cs = cs_adder
        else:
            cs = None
            notes.append("DCOR/IDCOR carry condition: manual does not say "
                         "which carries (adder: %s, PSW C/B: %s)" % (cs_adder, cs_psw))
        return Outcome(res, cs, None, notes)
    raise ValueError(op)


# ---------------------------------------------------------------------------
# Long immediates: LDIL, ADDIL, LDO [ACD pp.5-55..5-57]
# ---------------------------------------------------------------------------

def ldil(value):
    """LDIL L%value,t: GR[t] <- lshift(assemble_21(im21),11) [p.5-56]. The
    assembler's L% field selector puts value{0..20} into im21, so the result
    is the value with its rightmost 11 bits cleared."""
    return Outcome(value & 0xFFFFF800)


def addil(value, r):
    """ADDIL L%value,r: GR[1] <- lshift(assemble_21(im21),11) + GR[r];
    overflow ignored, C/B unchanged [p.5-57]."""
    return Outcome(((value & 0xFFFFF800) + r) & M32)


def ldo(disp, b):
    """LDO d(b),t: GR[t] <- GR[b] + low_sign_ext(im14,14) [p.5-55]."""
    return Outcome((b + disp) & M32)


# ---------------------------------------------------------------------------
# Shift double, extract, deposit [ACD pp.5-122..5-135]
# ---------------------------------------------------------------------------

def shd(r1, r2, p):
    """SHD r1,r2,p,t / VSHD (p = CR[11]) [p.5-122/5-123]:
    rshift(cat(GR[r1]{1..31},GR[r2]),p){32..63} -- the low word of the
    64-bit r1:r2 shifted right p (0..31) places; GR[r1]{0} never reaches it."""
    return (((r1 << 32) | r2) >> p) & M32


def extract(r, p, ln, signed):
    """EXTRU/EXTRS r,p,len,t and VEXTRU/VEXTRS (p = CR[11]) [p.5-124..5-127]:
    tmp <- lshift(zero/sign_ext_64(GR[r],32), 1+p){0..31};
    GR[t] <- zero/sign_ext(tmp{32-len..31}, len).
    The field ends at bit p (big-endian) and runs len bits to the left; for
    the variable forms it may run past bit 0, where it is filled with zeros
    (VEXTRU) or the sign of GR r (VEXTRS)."""
    v = s32(r) if signed else r
    tmp = (v >> (31 - p)) & M32
    return sign_ext(tmp, ln) if signed else tmp & mask(ln)


def deposit(src, p, ln, old):
    """DEP/ZDEP/DEPI/ZDEPI r|i,p,len,t and their variable forms (p = CR[11])
    [p.5-128..5-135]: GR[t]{p-len+1..p} <- src{32-len..31}; the field is
    truncated where it would run past bit 0 (variable forms). `old` is the
    previous GR t for the merging forms, 0 for the Z forms."""
    sh = 31 - p
    m = (mask(ln) << sh) & M32
    return (old & ~m & M32) | ((src << sh) & m)


def shift_op(op, cond, a, b, sar, p=None, ln=None, imm=None):
    """One instruction of the shift suite. a = GR r (r1), b = GR r2 for
    SHD/VSHD and the old GR t for the merging deposits, sar = CR[11],
    p/ln the fixed position/length (the variable forms' len in ln),
    imm the 5-bit immediate (already a signed int)."""
    notes = []
    c = COND_SHIFT[cond]
    fixed = op in ("extru", "extrs", "zdep", "dep", "depi", "zdepi")
    if fixed and not p >= ln - 1:
        # p.5-126 .. 5-135: "Doing so is an undefined operation."
        return Outcome(None, None, None, ["field runs past bit 0: undefined"])
    if op == "shd":
        res = shd(a, b, p)
    elif op == "vshd":
        res = shd(a, b, sar)
    elif op in ("extru", "extrs"):
        res = extract(a, p, ln, op == "extrs")
    elif op in ("vextru", "vextrs"):
        res = extract(a, sar, ln, op == "vextrs")
    else:
        pos = p if fixed else sar
        src = (imm & M32) if op.endswith("i") else a        # low_sign_ext(im5,5)
        old = 0 if op.startswith("z") else b
        res = deposit(src, pos, ln, old)
    return Outcome(res, shift_cond(c, res), None, notes)


# ---------------------------------------------------------------------------
# MTSAR / MFCTL %sar [ACD pp.5-148, 5-151; p.2-13, 2-15]
# ---------------------------------------------------------------------------

def mtsar_mfctl(a):
    """MTCTL r,%sar: CR[11] <- GR[r]{27..31} [p.5-148]. The other 27 bits of
    CR 11 are "nonexistent bits" [p.2-13, 2-15]: a read "may return zeros or
    what was last written" [p.2-7]. The PA-7100LC returns zeros
    [PCXL ERS s.5.4: "SAR[0:26]: NonExistent Bits; Read always returns
    zeroes."], so MFCTL %sar gives GR[r] & 31."""
    return Outcome(a & 31, False, None,
                   [] if a == a & 31 else
                   ["SAR{0..26} nonexistent: PA 1.1 allows 0 or the written "
                    "bits; PCX-L returns 0"])


# ---------------------------------------------------------------------------
# MAX-1 halfword multimedia instructions (PA-7100LC implementation-dependent)
#
# Not in the PA 1.1 manual. Sources: the PA-RISC 2.0 manual
# (docs/reference/txt/parisc2.0.txt -- the complete copy; Parisc2.0.txt and
# the PDF lose the HSHRADD page), cited [PA2 p.N], whose MAX-1 instructions
# work on the four halfwords of a 64-bit register, and the PA-7300LC ERS
# chapter 13 (docs/reference/txt/Pcxl2_ers.txt), cited [PCXL2 ERS p.13-N],
# which describes the same instructions on the two halfwords of a 32-bit
# register as "first implemented on the PA7100LC" [PCXL2 ERS s.1.1.1]. The
# PA-7100LC ERS defers them to an appendix the public copy lacks [PCXL ERS
# s.2.1.4]. Here they act on the two halfwords of the 32-bit register.
#
# * No conditions: "Software must put zeros in the 'cf' field. A non-zero
#   encoding of the 'cf' field is undefined." [PCXL2 ERS p.13-2..13-8]; the
#   PA 2.0 formats have no c/f either. So the next insn always executes.
# * PSW[C/B] is not written: no Operation section assigns it [PA2 p.7-58..
#   7-64, PCXL2 ERS p.13-3..13-8], and the PA-7100LC's own list of encodings
#   that "might set carry/borrow" (major op 02 with ext bit 21 = 1 and bit 23
#   = 0 or bits 24..25 = 0) [PCXL ERS s.3.4] excludes every MAX-1 encoding.
# ---------------------------------------------------------------------------

# ext6 = instruction bits 20..25 (big-endian), i.e. (word >> 6) & 0x3F
# [PA2 p.7-58..7-64 formats; PA2 opcode table "HADD 02 00 1111 0F" ...;
# PCXL2 ERS minor opcodes 1E/1A/18, 0E/0A/08, 16, 2A/2C/2E, 3A/3C/3E are the
# same bits with bit 26 = 0 appended]
MAX1_EXT = {0x0F: ("hadd", ""), 0x0D: ("hadd", "ss"), 0x0C: ("hadd", "us"),
            0x07: ("hsub", ""), 0x05: ("hsub", "ss"), 0x04: ("hsub", "us"),
            0x0B: ("havg", ""),
            0x1D: ("hshladd", 1), 0x1E: ("hshladd", 2), 0x1F: ("hshladd", 3),
            0x15: ("hshradd", 1), 0x16: ("hshradd", 2), 0x17: ("hshradd", 3)}


def max1_decode(word):
    """(op, completer-or-sa, r1, r2, t) of a MAX-1 instruction word; raises
    ValueError for anything else or for a non-zero cf field / bit 26."""
    if word >> 26 != 0x02:
        raise ValueError("not major opcode 02: %08x" % word)
    ext = (word >> 6) & 0x3F
    if ext not in MAX1_EXT or word & 0x20 or (word >> 12) & 0xF:
        raise ValueError("not a MAX-1 encoding with cf = 0: %08x" % word)
    op, x = MAX1_EXT[ext]
    return op, x, (word >> 16) & 0x1F, (word >> 21) & 0x1F, word & 0x1F


def _sat(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def _s16(h):
    return h - 0x10000 if h & 0x8000 else h


def max1_half(op, x, h1, h2):
    """One 16-bit lane: h1 from GR r1, h2 from GR r2 (both 0..0xFFFF)."""
    if op in ("hadd", "hsub"):
        sign = 1 if op == "hadd" else -1
        if x == "ss":
            # signed saturation: both operands signed, clamp [-2^15, 2^15-1]
            # [PA2 p.7-58/7-64 and Table 6-3; PCXL2 ERS p.13-3/13-5]
            return _sat(_s16(h1) + sign * _s16(h2), -0x8000, 0x7FFF) & 0xFFFF
        if x == "us":
            # unsigned saturation: GR r1 operand UNSIGNED, GR r2 operand
            # SIGNED, result unsigned, clamp [0, 2^16-1] [PA2 p.7-58/7-64
            # and Table 6-4; PCXL2 ERS: zero_ext(r1) +/- sign_ext(r2)]
            return _sat(h1 + sign * _s16(h2), 0, 0xFFFF)
        # modular [PA2: GR[r1] + GR[r2], GR[r1] + ~GR[r2] + 1]
        return (h1 + sign * h2) & 0xFFFF
    if op == "havg":
        # [PA2 p.7-59]: sum <- h1 + h2 (carry = its 17th bit);
        # t <- cat(carry, sum{0..13}, sum{14} | sum{15}): the 17-bit sum
        # shifted right one, its new LSB ORed with the bit shifted out
        # ("unbiased rounding", PCXL2 ERS p.13-6 table: 00->0, 01/10/11->1)
        s = h1 + h2
        return (s >> 1) | (s & 1)
    if op == "hshladd":
        # [PA2 p.7-61, Table 6-3; PCXL2 ERS p.13-8 HSLxADD]: if h1 << x is
        # not representable in 16 bits the lane saturates by the sign of the
        # GR r1 halfword (pre-shift overflow takes precedence), else the add
        # saturates as HADD,SS. (The PA2 p.7-61 text "If GR r2 was negative,
        # minimum saturation occurs" contradicts its own Table 6-3 and the
        # PCXL2 ERS, which both use the first operand's sign.)
        sh = _s16(h1) << x
        if sh > 0x7FFF:
            return 0x7FFF
        if sh < -0x8000:
            return 0x8000
        return _sat(sh + _s16(h2), -0x8000, 0x7FFF) & 0xFFFF
    if op == "hshradd":
        # [PA2 p.7-63; PCXL2 ERS p.13-7 HSRxADD]: arithmetic right shift
        # (sign_ext_16(rshift(h1,sa),16-sa)), add, signed saturation
        return _sat((_s16(h1) >> x) + _s16(h2), -0x8000, 0x7FFF) & 0xFFFF
    raise ValueError(op)


def max1(word, r1, r2):
    """Execute MAX-1 instruction `word` with GR r1 = r1, GR r2 = r2.
    Returns an Outcome (never nullifies, C/B unchanged)."""
    op, x, _, _, _ = max1_decode(word)
    hi = max1_half(op, x, r1 >> 16, r2 >> 16)
    lo = max1_half(op, x, r1 & 0xFFFF, r2 & 0xFFFF)
    return Outcome((hi << 16) | lo, False, None)


# ---------------------------------------------------------------------------
# Test-ROM glue: map a generated group + vector inputs to expectations
# ---------------------------------------------------------------------------

ARITH = {"add", "addl", "addc", "sh1add", "sh2add", "sh3add", "sh1addl",
         "sh2addl", "sh3addl", "sub", "subb", "comclr"}
ARITH_IMM = {"addi", "subi", "comiclr"}
LOGICAL = {"and", "andcm", "or", "xor"}
UNIT = {"uxor", "uaddcm", "uaddcmt", "dcor", "idcor"}
SHIFT = {"shd", "vshd", "extru", "extrs", "vextru", "vextrs", "zdep", "dep",
         "zvdep", "vdep", "depi", "zdepi", "vdepi", "zvdepi"}
LONGIMM = {"ldil", "addil", "ldo"}
MAX1 = {"hadd", "hsub", "havg", "hshladd", "hshradd"}

SUITES = ("alu1", "alu2", "shift", "max1")


def parse_group(name):
    """'addc,<=.c1' -> ('addc', '<=', 1); 'shd' -> ('shd', '', None);
    'ds,<<.v1' -> ('ds', '<<', None) (the V preset is in the vector)."""
    carry = None
    if name.startswith("ds") and (name.endswith(".v0") or name.endswith(".v1")):
        name = name[:-3]
    if name.endswith(".c0") or name.endswith(".c1"):
        carry = int(name[-1])
        name = name[:-3]
    m, _, c = name.partition(",")
    return m, c, carry


def execute(group, v):
    """Run the instruction a group tests on the inputs `v` of one vector
    (gen_tests.py's JSON) with the PSW C/B bits the vector preset.
    Returns (Outcome, cb_before) where cb_before is the preset C/B or None
    when the vector does not preset it."""
    m, c, _ = parse_group(group)
    # Carry preset [gen_tests.py CARRY_CLEAR / CARRY_SET]: ADD 0,0,0 leaves
    # every digit carry 0; SUB 0,0,0 = 0 + ~0 + 1 carries out of every digit.
    cb = None
    if "carry" in v:
        cb = Sum(0, 0, 0).cb if v["carry"] == 0 else Sum(0, ~0, 1).cb
    a, b = v.get("a"), v.get("b")
    if m in ARITH:
        return arith(m, c, a, b, cb), cb                  # op r3(a), r4(b), r5
    if m in ARITH_IMM:
        return arith(m, c, v["imm"] & M32, a, cb), cb     # op imm, r3(a), r5
    if m in LOGICAL:
        return logical(m, c, a, b), cb
    if m in UNIT:
        return unit(m, c, a, b, cb), cb                   # dcor/idcor: r3(a)
    if m == "ldil":
        return ldil(v["imm"]), cb
    if m == "addil":
        return addil(v["imm"], a), cb
    if m == "ldo":
        return ldo(v["imm"], a), cb
    if m in SHIFT:
        # shd uses the vector's "sar" as its fixed count p (gen_tests.py)
        if m == "shd":
            return shift_op(m, c, a, b, v["sar"], p=v["sar"]), cb
        if m in ("extru", "extrs", "zdep", "dep", "depi", "zdepi"):
            return shift_op(m, c, a, b, v["sar"], p=v["pos"], ln=v["len"],
                            imm=v["imm"]), cb
        return shift_op(m, c, a, b, v["sar"], ln=v.get("vlen"), imm=v["imm"]), cb
    if m == "ds":
        # alu2 ds groups: V forced by a preceding DS (gen_tests.py gen_ds),
        # then C/B preset; the fourth word is the V bit after the DS
        o, v_new = ds(c, a, b, cb, v["v"])
        o.v = v_new
        return o, cb
    if group == "mtsar/mfctl":
        return mtsar_mfctl(a), cb
    if m in MAX1:
        # max1 suite: the instruction word is in the JSON (GNU as encodes it
        # at .level 2.0); every vector clears C/B first [gen_tests.py
        # gen_max1: CARRY_CLEAR], though its JSON has no "carry" key.
        if cb is None:
            cb = Sum(0, 0, 0).cb
        op, x, r1, r2, t = max1_decode(v["word"])
        if (op, str(x)) != (m, c) or (r1, r2, t) != (3, 4, 5):
            raise ValueError("group %r but word %08x decodes as %s,%s %%r%d,%%r%d,%%r%d"
                             % (group, v["word"], op, x, r1, r2, t))
        return max1(v["word"], a, b), cb
    raise KeyError("model does not know group %r" % group)


def predict(suite, group, v):
    """Expected [GR r5, executed flag, C/B map] for one vector.

    The ROM's vector tail [gen_tests.py vec_tail] is
        <insn> ; ldi 1,%r6 ; idcor %r0,%r7 ; stw r5, r6, r7
    with r6 = 0 beforehand, so word 1 is 0 when <insn> nullified its
    successor and 1 otherwise, and word 2 is cb_map(PSW[C/B])."""
    if suite not in SUITES:
        raise KeyError("model does not cover suite %r" % suite)
    o, cb_before = execute(group, v)
    executed = None if o.cond is None else (0 if o.cond else 1)
    if o.cb is not None:
        cbw = cb_map(o.cb)
    elif cb_before is not None:
        cbw = cb_map(cb_before)
    else:
        cbw = INHERIT       # no preset in this group: C/B from the C code
    words = [o.t, executed, cbw]
    if hasattr(o, "v"):
        words.append(o.v)       # divide step: PSW[V] afterwards
    return Prediction(words, o.notes)


# ---------------------------------------------------------------------------
# Known QEMU deviations (QEMU 11.1.1 -M 715, adjudicated against the manual)
#
# Each entry names the groups it affects and reproduces QEMU's wrong
# behaviour, so `compare.py ... --model --known-qemu` can tell a known QEMU
# bug from a new disagreement. These are QEMU bugs: the model above, not
# these functions, is the reference (README.md, "Reference policy").
# ---------------------------------------------------------------------------

def _qemu_shadd_uv(group, v):
    """QEMU's SHnADD(L) unsigned overflow tests the wrong bits.

    [ACD p.5-88..5-95, Table 5-2 p.5-3]: for SHIFT AND ADD, unsigned
    overflow is "one or more of the bits shifted out is 1" or the add
    carries. QEMU's do_add_uv (target/hppa/translate.c) takes
    extract(in1, 31 - shift, shift) -- bits 31-n..30 of GR r1 (the n bits
    BELOW the shifted-out ones, i.e. including the new sign bit) -- instead
    of bits 32-n..31. Affects conditions 4/5: NUV, ZNV, UV, VNZ."""
    m, c, _ = parse_group(group)
    n = int(m[2])
    a, b = v["a"], v["b"]
    s = Sum((a << n) & M32, b, 0)
    uv = bool((a >> (31 - n)) & mask(n)) or bool(s.carry)
    cc, f = COND_ADD[c]
    cs = arith_cond(cc, f, s.res, uv, False, False)
    p = predict("alu1", group, v)
    return Prediction([p.words[0], 0 if cs else 1, p.words[2]],
                      ["QEMU bug shadd-uv"])


def _qemu_ds_uv(group, v):
    """QEMU's DIVIDE STEP conditions 4/5 use the same do_add_uv(in1, 1):
    the bit tested as 'shifted out' is GR r1{1} (bit 30) instead of
    GR r1{0}, and the condition is always read the add way (no unsigned
    overflow), whatever PSW[V] says [ACD p.5-102/5-103, Table 5-1]."""
    m, c, _ = parse_group(group)
    a, b = v["a"] & M32, v["b"] & M32
    cb = Sum(0, 0, 0).cb if v.get("carry", 0) == 0 else Sum(0, ~0, 1).cb
    shifted = ((a << 1) | (cb >> 7 & 1)) & M32
    s = Sum(shifted, ~b, 1) if v["v"] else Sum(shifted, b, 0)
    uv = bool(a >> 30 & 1) or bool(s.carry)
    cc, f = COND_CMP[c]
    cs = arith_cond(cc, f, s.res, uv, False, False)
    p = predict("alu2", group, v)
    return Prediction([p.words[0], 0 if cs else 1] + p.words[2:], ["QEMU bug ds-uv"])


def expected_traps(suite, group, vectors):
    """Interruptions a group takes by design: the alu2 divide-step groups
    read PSW[V] through the IPSW of one BREAK per vector."""
    if suite == "alu2" and group.startswith("ds"):
        return vectors
    return 0


QEMU_BUGS = [
    {"id": "ds-uv",
     "suite": "alu2",
     "groups": r"^ds,(<<|<<=|>>=|>>)\.v[01]$",
     "summary": "DS conditions 4/5 (<<, <<=, >>=, >>): QEMU tests GR r1 bit 30 as "
                "the shifted-out bit (same do_add_uv off-by-one as shadd-uv) and "
                "reads the condition as an add whatever PSW[V] is",
     "manual": "ACD p.5-102/5-103 (DS: 'Unsigned overflow means that the bit "
               "shifted out is 1 or ...'), Table 5-1 p.5-3",
     "qemu": "target/hppa/translate.c trans_ds(): do_add_uv(ctx, cpu_psw_cb, NULL, in1, 1, false)",
     "predict": _qemu_ds_uv},
    {"id": "shadd-uv",
     "suite": "alu1",
     "groups": r"^sh[123]addl?,(nuv|znv|uv|vnz)$",
     "summary": "SH1ADD/SH2ADD/SH3ADD(L) conditions NUV/ZNV/UV/VNZ: unsigned "
                "overflow from the pre-shift tests GR r1 bits 31-n..30 "
                "instead of the shifted-out bits 32-n..31",
     "manual": "ACD p.5-88..5-95 (SHnADD, SHnADDL: 'Unsigned overflow means "
               "that ... the bits shifted out is 1'), Table 5-2 p.5-3",
     "qemu": "target/hppa/translate.c do_add_uv(): "
             "tcg_gen_extract_i64(tmp, in1, (d ? 63 : 31) - shift, shift)",
     "predict": _qemu_shadd_uv},
    {"id": "max1-illegal",
     "suite": "max1",
     "groups": r"^(hadd|hsub|havg|hshladd|hshradd)\b",
     "summary": "MAX-1 (HADD/HSUB/HAVG/HSHLADD/HSHRADD) takes an illegal "
                "instruction trap on a PA 1.1 CPU; the PA-7100LC implements "
                "them, so QEMU gives no reference for the max1 suite",
     "manual": "PCXL ERS s.2.1.4; PA2 p.7-58..7-64; PCXL2 ERS ch.13",
     "qemu": "target/hppa/translate.c (MAX-1 decode requires PA 2.0)",
     # the whole group is unusable: any output, any trap count
     "predict": None},
]


def qemu_bug_for(suite, group):
    """The QEMU_BUGS entry covering this group, or None. An entry whose
    "predict" is None makes QEMU's whole group meaningless (any output and
    trap count); otherwise "predict"(group, inputs) gives QEMU's output."""
    import re
    for bug in QEMU_BUGS:
        if bug["suite"] == suite and re.search(bug["groups"], group):
            return bug
    return None


# ---------------------------------------------------------------------------
# Self test: the manual's own examples
# ---------------------------------------------------------------------------

def _selftest():
    # SUBI -1,r,t: "GR[t] <- ~GR[r], all PSW[C/B] are set to ones" [p.5-119]
    for r in (0, 1, 0x12345678, M32, 0x80000000):
        o = arith("subi", "", M32, r, 0)
        assert o.t == ~r & M32 and o.cb == 0xFF, (r, o)
    # UADDCM 0,r,t is a NOT [p.5-110]
    assert unit("uaddcm", "", 0, 0x0F0F1234, 0).t == 0xF0F0EDCB
    # BCD sum sequence of the DCOR programming note [p.5-113]
    def bcd(n):
        return int(str(n), 16)
    nines = 0x99999999
    for x, y, z in ((12345678, 11111111, 1), (99999, 1, 0), (5000000, 4999999, 1)):
        t = unit("uaddcm", "", bcd(x), nines, 0).t         # pre-bias
        s = Sum(t, bcd(y), 0)
        t, cb = s.res, s.cb
        t = unit("idcor", "", t, 0, cb).t
        s = Sum(t, bcd(z), 0)
        t, cb = s.res, s.cb
        t = unit("dcor", "", t, 0, cb).t
        assert t == bcd(x + y + z), (x, y, z, hex(t))
    # COMCLR,<> rb,rc,ra ; LDO 1(0),ra  -> ra = (rb == rc) [p.5-104]
    assert arith("comclr", "<>", 5, 5, 0).cond is False
    assert arith("comclr", "<>", 5, 6, 0).cond is True
    # SHD ra,ra,8,ra rotates right by 8 [p.5-123]
    assert shd(0x12345678, 0x12345678, 8) == 0x78123456
    # VEXTRU r,10,t with SAR = 24 extracts bits 15..24 [p.5-124 figure]
    assert extract(0xFFFFFFFF, 24, 10, False) == 0x3FF
    assert extract(1 << (31 - 24), 24, 10, False) == 1
    assert extract(1 << (31 - 15), 24, 10, False) == 0x200
    # DEP r,24,10,t fills bits 15..24 [p.5-129 figure]
    assert deposit(0x3FF, 24, 10, 0) == mask(10) << 7
    # ZVDEP ra,32,rt with SAR = 31-count is a left shift [p.5-132 note]
    for cnt in (0, 1, 7, 31):
        assert deposit(0x89ABCDEF, 31 - cnt, 32, 0) == (0x89ABCDEF << cnt) & M32
    # VEXTRS r,32,t with SAR = 31-p is an arithmetic right shift [p.5-125]
    for p in (0, 1, 13, 31):
        assert extract(0x80000010, 31 - p, 32, True) == (s32(0x80000010) >> p) & M32
    # idcor map
    assert cb_map(0xFF) == 0x66666666 and cb_from_map(0x60000006) == 0x81
    # MAX-1 [PA2 p.7-58..7-64, Tables 6-3/6-4; PCXL2 ERS ch.13]
    w = {k: (0x08000000 | (4 << 21) | (3 << 16) | (e << 6) | 5)
         for e, k in MAX1_EXT.items()}
    def mx(op, x, a, b):
        return max1(w[(op, x)], a, b).t
    assert mx("hadd", "", 0x7FFFFFFF, 0x00010001) == 0x80000000       # modular
    assert mx("hadd", "ss", 0x7FFF8000, 0x0001FFFF) == 0x7FFF8000     # clamps
    assert mx("hadd", "us", 0xFFFF0001, 0x0001FFFE) == 0xFFFF0000     # r2 signed
    assert mx("hadd", "us", 0x8000FFFF, 0x80000001) == 0x0000FFFF     # 8000+-8000
    assert mx("hsub", "", 0x00000001, 0x00010002) == 0xFFFFFFFF
    assert mx("hsub", "ss", 0x80007FFF, 0x0001FFFF) == 0x80007FFF
    assert mx("hsub", "us", 0x0000FFFF, 0x0001FFFF) == 0x0000FFFF     # FFFF - (-1)
    assert mx("hsub", "us", 0x00050005, 0x0006FFFB) == 0x0000000A
    assert mx("havg", "", 0x00010003, 0x00000000) == 0x00010001       # 1/2->1, 3/2->1
    assert mx("havg", "", 0xFFFF0002, 0xFFFF0004) == 0xFFFF0003       # carry kept
    assert mx("havg", "", 0x00040005, 0x00000000) == 0x00020003       # 4/2, 5/2->3
    assert mx("hshladd", 1, 0x40000001, 0x80000001) == 0x7FFF0003     # shift ov wins
    assert mx("hshladd", 2, 0xE0001000, 0x00007000) == 0x80007FFF
    assert mx("hshradd", 1, 0xFFFF8000, 0x00008000) == 0xFFFF8000     # -1>>1 = -1
    assert mx("hshradd", 3, 0x7FFF0010, 0x7FFF0001) == 0x7FFF0003
    print("model self test passed")


if __name__ == "__main__":
    _selftest()
