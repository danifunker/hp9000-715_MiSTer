#!/usr/bin/env python3
"""Compare a pacputest log against the reference model or another log.

usage: compare.py SUITE LOG --model              [options]
       compare.py SUITE LOG --model --known-qemu [options]
       compare.py SUITE LOG --ref REFLOG         [options]
       compare.py SUITE LOG --ref REFLOG --model [options]

  --model         check every vector against model.py's prediction for the
                  inputs in build/gen_SUITE.json (suites: model.SUITES =
                  alu1, alu2, shift, max1)
  --ref REFLOG    check every vector word for word against the same vector
                  of REFLOG (any suite)
  both            the project policy (README.md): LOG is judged by the model
                  (where REFLOG is right it equals every exact expectation;
                  where the model leaves a word open REFLOG is not binding);
                  REFLOG vectors that fail the model are counted as
                  "ref-bad", and any not explained by a known QEMU bug
                  (model.QEMU_BUGS) fail the group: adjudicate them
  --json PATH     input sidecar (default: build/gen_SUITE.json next to this
                  script); used for --model and to show inputs
  --known-qemu    with --model: a vector that fails the model exactly the way
                  a documented QEMU bug (model.QEMU_BUGS) predicts is counted
                  as "qemubug", not FAIL -- for checking QEMU's own logs
  -n N            print at most N mismatching vectors per group (default 5,
                  0 = all)
  --group REGEX   only groups whose name matches REGEX (re.search)
  --brief         summary lines only for groups that fail
  --quiet         no per-group lines at all, only mismatches and totals

Log format (src/main.c):
    pacputest <suite>
    == <group> <count, hex>
    <index, hex> <word0> <word1> ...       (8 hex digits per word)
    -- <group> crc <crc32 of the words> traps <interruptions taken, hex>
    ...
    == end
A line starting "!! " means the ROM took an HPMC/TOC and stopped. Older
logs have no " traps" field; it is then not compared. A trap count that
differs from the reference (or is non-zero, against the model) fails the
group. Without --model any suite can be compared (word for word); the
JSON sidecar, when present, only labels mismatches with their inputs.

Exit status: 0 all vectors pass, 1 any mismatch or a damaged/incomplete
log, 2 usage error.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True      # no __pycache__ in the source tree
import model  # noqa: E402

# Display labels for the words of each suite's vectors (gen_tests.py);
# used only when a vector has exactly that many words, else w0, w1, ...
WORD_NAMES = {s: ["t", "exec", "cbmap"] for s in model.SUITES}
WORD_NAMES.update({
    "mem": ["r5", "base"] + ["m%d" % i for i in range(16)],
    "branch": ["path", "r3", "r4"],
    "trap": ["r5", "exec", "trapno", "iir", "isr", "ior", "ipsw", "iiaoq"],
    "fp": ["fhi", "flo", "status", "pad"],
    "fpedge": ["fhi", "flo", "status", "pad"],
})


# ---------------------------------------------------------------------------
# Log parsing
# ---------------------------------------------------------------------------

def crc32_words(words):
    """The CRC main.c prints: MSB-first CRC-32 (poly 0x04C11DB7), init ~0,
    fed 32-bit words, final complement."""
    crc = 0xFFFFFFFF
    for w in words:
        for b in range(32):
            bit = ((w >> (31 - b)) ^ (crc >> 31)) & 1
            crc = ((crc << 1) & 0xFFFFFFFF) ^ (0x04C11DB7 if bit else 0)
    return ~crc & 0xFFFFFFFF


class Group:
    def __init__(self, name, count, line):
        self.name = name
        self.count = count          # vectors announced in the header
        self.line = line            # header line number
        self.vectors = []           # list of [word, ...]
        self.crc = None             # printed crc
        self.traps = None           # interruptions taken (None: old format)
        self.problems = []

    @property
    def crc_ok(self):
        if self.crc is None:
            return False
        return crc32_words([w for v in self.vectors for w in v]) == self.crc


class Log:
    def __init__(self, path):
        self.path = path
        self.suite = None
        self.groups = []            # in log order
        self.by_name = {}
        self.complete = False
        self.hpmc = None
        self.problems = []          # log-level damage
        self.unparsed = []          # (line number, text) not understood
        self._parse()

    def _parse(self):
        try:
            with open(self.path, "rb") as f:
                text = f.read().decode("latin-1")
        except OSError as e:
            self.problems.append("cannot read: %s" % e)
            return
        cur = None
        for no, raw in enumerate(text.replace("\r", "").split("\n"), 1):
            line = raw.strip()
            if not line:
                continue
            if line.startswith("pacputest "):
                self.suite = line.split(None, 1)[1].strip()
                continue
            if line == "== end":
                if cur is not None:
                    cur.problems.append("no crc line")
                    cur = None
                self.complete = True
                continue
            if line.startswith("!! "):
                self.hpmc = "line %d: %s" % (no, line)
                continue
            if line.startswith("== "):
                if cur is not None:
                    cur.problems.append("no crc line")
                m = re.match(r"== (.+) ([0-9a-fA-F]{4})$", line)
                if not m:
                    self.problems.append("line %d: bad group header %r" % (no, line))
                    cur = None
                    continue
                cur = Group(m.group(1), int(m.group(2), 16), no)
                if cur.name in self.by_name:
                    self.problems.append("line %d: group %r repeated" % (no, cur.name))
                self.groups.append(cur)
                self.by_name.setdefault(cur.name, cur)
                continue
            if line.startswith("-- "):
                m = re.match(r"-- (.+) crc ([0-9a-fA-F]{8})(?: traps ([0-9a-fA-F]{4}))?$",
                             line)
                if not m or cur is None or m.group(1) != cur.name:
                    self.problems.append("line %d: unexpected crc line %r" % (no, line))
                    continue
                cur.crc = int(m.group(2), 16)
                if m.group(3) is not None:
                    cur.traps = int(m.group(3), 16)
                cur = None
                continue
            m = re.match(r"([0-9a-fA-F]{4})((?: [0-9a-fA-F]{8})+)$", line)
            if m and cur is not None:
                idx = int(m.group(1), 16)
                if idx != len(cur.vectors):
                    cur.problems.append("line %d: vector index %04x, expected %04x"
                                        % (no, idx, len(cur.vectors)))
                cur.vectors.append([int(w, 16) for w in m.group(2).split()])
                continue
            self.unparsed.append((no, line[:60]))
        if cur is not None:
            cur.problems.append("no crc line (log ends inside the group)")
        for g in self.groups:
            if len(g.vectors) != g.count:
                g.problems.append("%d vectors, header says %d" % (len(g.vectors), g.count))
            if g.vectors and len({len(v) for v in g.vectors}) != 1:
                g.problems.append("vectors have different word counts")
            if g.crc is not None and not g.crc_ok:
                g.problems.append("crc mismatch (printed %08x, words give %08x)"
                                  % (g.crc, crc32_words([w for v in g.vectors for w in v])))
        if self.unparsed:
            no, txt = self.unparsed[0]
            self.problems.append("%d unparsed line(s), first at line %d: %r"
                                 % (len(self.unparsed), no, txt))
        if not self.complete:
            self.problems.append("incomplete: no '== end' line")
        if self.hpmc:
            self.problems.append("ROM stopped: " + self.hpmc)


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

FIRST_KEYS = ("a", "b", "carry", "imm", "pos", "len", "sar", "vlen")
HEX_KEYS = {"a", "b", "seed", "val", "insn", "word", "addr"}


def fmt_inputs(v):
    """One vector's JSON inputs: words in hex, small numbers in decimal."""
    if v is None:
        return "(inputs unknown)"
    if not v:
        return "(no inputs)"
    out = []
    for k in [k for k in FIRST_KEYS if k in v] + sorted(set(v) - set(FIRST_KEYS)):
        x = v[k]
        if isinstance(x, bool) or not isinstance(x, int):
            out.append("%s=%s" % (k, x))
        elif k in HEX_KEYS or abs(x) > 0xFFFF:
            out.append("%s=%08x" % (k, x & 0xFFFFFFFF))
        else:
            out.append("%s=%d" % (k, x))
    return " ".join(out)


def word_name(suite, i, width=None):
    names = WORD_NAMES.get(suite)
    if names and (width is None or width == len(names)) and i < len(names):
        return names[i]
    return "w%d" % i


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------

class Result:
    def __init__(self):
        self.vectors = 0
        self.fail = 0
        self.relaxed = 0            # passed only thanks to an unpredictable word
        self.known = 0              # fail the model exactly as a known QEMU bug
        self.refbad = 0             # reference vectors that fail the model ...
        self.refknown = 0           # ... of which explained by a known QEMU bug
        self.details = []           # lines per printed mismatch
        self.problems = []          # group-level failures
        self.warnings = []          # group-level notes that do not fail


def compare_group(suite, name, got, ref, inputs, use_model, nmax, known_qemu):
    """Check one group. got/ref: Group or None; inputs: the group's input
    dicts from the JSON sidecar, or None."""
    r = Result()
    if got is None:
        r.problems.append("missing from log")
        return r
    r.problems += got.problems
    # Interruption count: the model's suites never trap; a reference log's
    # count must be matched exactly.
    refbug = model.qemu_ref_bug_for(suite, name) if (known_qemu and not use_model) else None
    skip = set()
    if refbug is not None and inputs is not None:
        skip = {i for i, v in enumerate(inputs) if refbug["vector"](v)}
    if ref is not None and ref.traps is not None:
        want = ref.traps + len(skip) * (refbug["traps_delta"] if refbug else 0)
        if got.traps is None:
            r.problems.append("no trap count (reference: %d)" % ref.traps)
        elif got.traps != want:
            r.problems.append("took %d traps, reference %d" % (got.traps, want))
        elif skip:
            r.warnings.append("trap count adjusted for known QEMU bug %s" % refbug["id"])
    bug = model.qemu_bug_for(suite, name) if use_model else None
    whole_bug = bug is not None and bug["predict"] is None
    want_traps = model.expected_traps(suite, name, len(got.vectors)) if use_model else 0
    if use_model and got.traps is not None and got.traps != want_traps:
        msg = "took %d traps, the model expects %d" % (got.traps, want_traps)
        if known_qemu and whole_bug:
            r.warnings.append(msg + " (known QEMU bug %s)" % bug["id"])
        else:
            r.problems.append(msg)
    n = len(got.vectors)
    if ref is not None:
        if len(ref.vectors) != n:
            r.problems.append("%d vectors, reference has %d" % (n, len(ref.vectors)))
        n = min(n, len(ref.vectors))
    if inputs is not None and len(inputs) != len(got.vectors):
        msg = "%d vectors, json has %d" % (len(got.vectors), len(inputs))
        if use_model:
            r.problems.append(msg)
            n = min(n, len(inputs))
        else:
            r.warnings.append(msg + " (stale build/? inputs shown may be wrong)")
    preds = []
    if use_model:
        if inputs is None:
            r.problems.append("no inputs in the json sidecar")
            use_model = False
        else:
            try:
                preds = [model.predict(suite, name, inputs[i]) for i in range(n)]
            except (KeyError, ValueError) as e:
                r.problems.append("model: %s" % e)
                use_model = False
    def matches_bug(i, words):
        if bug is None:
            return False
        if bug["predict"] is None:
            return True
        q = bug["predict"](name, inputs[i])
        return len(words) == len(q.words) and all(
            model.check(e, x) for e, x in zip(q.words, words))

    # INHERIT words (C/B not preset by the vector, not written by the
    # instruction): must hold one value for the whole group, a valid C/B map
    inherit_bad = set()
    if use_model:
        for w in range(3):
            idx = [i for i in range(n) if preds[i].words[w] is model.INHERIT
                   and w < len(got.vectors[i])]
            vals = {got.vectors[i][w] for i in idx}
            if len(vals) > 1:
                r.problems.append("%s should be the same in every vector (the "
                                  "instruction leaves C/B alone) but takes %d values"
                                  % (word_name(suite, w), len(vals)))
                inherit_bad.update((i, w) for i in idx)
            for i in idx:
                if model.cb_from_map(got.vectors[i][w]) is None:
                    inherit_bad.add((i, w))

    for i in range(n):
        g = got.vectors[i]
        rv = ref.vectors[i] if ref is not None else None
        p = preds[i] if use_model else None
        bad_words, relaxed = [], False
        width = max(len(g), len(rv) if rv is not None else 0,
                    len(p.words) if p is not None else 0)
        for w in range(width):
            gw = g[w] if w < len(g) else None
            rw = rv[w] if rv is not None and w < len(rv) else None
            if p is not None and w < len(p.words):
                # With the model, the model decides: wherever a reference
                # value is right it equals an exact expectation, and where
                # the model leaves a word open the reference is not binding.
                e = p.words[w]
                ok = gw is not None and (i, w) not in inherit_bad and model.check(e, gw)
                if ok and (e is None or isinstance(e, frozenset)):
                    relaxed = True
            else:
                ok = rv is not None and gw is not None and gw == rw
            if not ok:
                bad_words.append(w)
        r.vectors += 1
        if p is not None and rv is not None and not all(
                model.check(e, x) for e, x in zip(p.words, rv)):
            r.refbad += 1
            if matches_bug(i, rv):
                r.refknown += 1
        if bad_words and i in skip:
            r.known += 1
            continue
        if bad_words and known_qemu and matches_bug(i, g):
            r.known += 1
            continue
        if bad_words:
            r.fail += 1
            if nmax == 0 or len(r.details) < nmax:
                r.details.append(_detail(suite, i, g, rv, p,
                                         inputs[i] if inputs and i < len(inputs) else None,
                                         bad_words, bug))
        elif relaxed:
            r.relaxed += 1
    return r


def _detail(suite, i, g, rv, p, vin, bad, bug):
    lines = ["  #%04x  %s" % (i, fmt_inputs(vin))]
    width = max(len(g), len(rv) if rv is not None else 0)

    def hx(vec, w):
        return "%08x" % vec[w] if vec is not None and w < len(vec) else "--------"

    if p is not None and rv is not None:
        lines.append("         %-6s %-17s %-9s %s" % ("word", "model", "actual", "ref"))
    elif p is not None:
        lines.append("         %-6s %-17s %s" % ("word", "model", "actual"))
    else:
        lines.append("         %-6s %-9s %s" % ("word", "ref", "actual"))
    for w in range(width):
        mark = "  <--" if w in bad else ""
        if p is not None:
            e = model.fmt_expect(p.words[w]) if w < len(p.words) else "(none)"
            row = "         %-6s %-17s %s" % (word_name(suite, w, width), e, hx(g, w))
            if rv is not None:
                row += "  %s" % hx(rv, w)
        else:
            row = "         %-6s %-9s %s" % (word_name(suite, w, width), hx(rv, w), hx(g, w))
        lines.append(row + mark)
    if p is not None:
        for n in p.notes:
            lines.append("         note: " + n)
    if bug is not None:
        lines.append("         note: group affected by known QEMU bug %s" % bug["id"])
    return lines


def main(argv):
    ap = argparse.ArgumentParser(
        usage="compare.py SUITE LOG [--model] [--ref REFLOG] [options]",
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("\n", 1)[1])
    ap.add_argument("suite")
    ap.add_argument("log")
    ap.add_argument("--model", action="store_true")
    ap.add_argument("--ref")
    ap.add_argument("--json")
    ap.add_argument("--known-qemu", action="store_true")
    ap.add_argument("-n", type=int, default=5)
    ap.add_argument("--group")
    ap.add_argument("--brief", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv[1:])
    if not a.model and not a.ref:
        ap.error("give --model, --ref REFLOG, or both")
    if a.model and a.suite not in model.SUITES:
        ap.error("the model covers suites %s, not %r" % (", ".join(model.SUITES), a.suite))
    # --known-qemu with --model: QEMU_BUGS; with --ref alone: QEMU_REF_BUGS

    log = Log(a.log)
    ref = Log(a.ref) if a.ref else None
    jpath = a.json or os.path.join(HERE, "build", "gen_%s.json" % a.suite)
    inputs = None
    if os.path.exists(jpath):
        with open(jpath) as f:
            inputs = {g["group"]: g["inputs"] for g in json.load(f)}
        order = list(inputs)
        if ref is not None:
            order += [g.name for g in ref.groups if g.name not in inputs]
    elif a.model:
        print("error: %s not found (run make -C %s)" % (jpath, HERE))
        return 2
    else:
        order = [g.name for g in ref.groups]

    what = []
    if a.model:
        what.append("model (%s)" % os.path.relpath(jpath))
    if ref:
        what.append("ref %s" % a.ref)
    print("compare %s: %s vs %s" % (a.suite, a.log, " + ".join(what)))

    status = 0
    for L, label in ((log, "log"), (ref, "ref")):
        if L is None:
            continue
        if L.suite is not None and L.suite != a.suite:
            print("%s: suite is %r, not %r" % (label, L.suite, a.suite))
            status = 1
        for pr in L.problems:
            print("%s: %s" % (label, pr))
            status = 1
    known = set(order)
    extra = [g.name for g in log.groups if g.name not in known]
    if extra:
        print("log has groups the reference does not: %s" % " ".join(extra))
        status = 1

    both = ref is not None and a.model
    cols = ["vecs", "pass", "FAIL"] + (["relaxed"] if a.model else [])
    if a.known_qemu:
        cols.append("qemubug")
    if both:
        cols += ["ref-bad", "of-known"]
    if not a.quiet:
        print("%-22s" % "group" + "".join(" %7s" % c for c in cols))
    tot = dict(groups=0, gfail=0, vectors=0, fail=0, relaxed=0, known=0,
               refbad=0, refknown=0)
    for name in order:
        if a.group and not re.search(a.group, name):
            continue
        g = log.by_name.get(name)
        rg = ref.by_name.get(name) if ref else None
        if ref is not None and rg is None:
            print("%-22s missing from the reference log  FAIL" % name)
            tot["gfail"] += 1
            status = 1
            continue
        ins = inputs.get(name) if inputs else None
        r = compare_group(a.suite, name, g, rg, ins, a.model, a.n, a.known_qemu)
        for k in ("vectors", "fail", "relaxed", "known", "refbad", "refknown"):
            tot[k] += getattr(r, k)
        tot["groups"] += 1
        unexplained = r.refbad - r.refknown
        bad = r.fail or r.problems or unexplained
        if bad:
            tot["gfail"] += 1
            status = 1
        if not a.quiet and (bad or not a.brief):
            vals = [r.vectors, r.vectors - r.fail - r.known, r.fail]
            if a.model:
                vals.append(r.relaxed)
            if a.known_qemu:
                vals.append(r.known)
            if both:
                vals += [r.refbad, r.refknown]
            print("%-22s" % name + "".join(" %7d" % v for v in vals)
                  + ("  FAIL" if bad else ""))
        for pr in r.problems:
            print("  ! %s" % pr)
        if not a.quiet and not a.brief:
            for pr in r.warnings:
                print("  ? %s" % pr)
        if unexplained:
            print("  ! %d reference vectors disagree with the model and no known "
                  "QEMU bug explains them: adjudicate (README.md)" % unexplained)
        for lines in r.details:
            print("\n".join(lines))
        if r.fail > len(r.details):
            print("  ... %d more failing vectors (-n 0 shows all)" % (r.fail - len(r.details)))
    msg = "total: %d groups (%d failing), %d vectors: %d pass, %d FAIL" % (
        tot["groups"], tot["gfail"], tot["vectors"],
        tot["vectors"] - tot["fail"] - tot["known"], tot["fail"])
    if a.known_qemu:
        msg += ", %d known QEMU bug" % tot["known"]
    if a.model:
        msg += "; %d passed only via words the model leaves open" % tot["relaxed"]
    if both:
        msg += "; %d reference vectors fail the model (%d explained by known QEMU bugs)" % (
            tot["refbad"], tot["refknown"])
    print(msg)
    if a.known_qemu or both:
        ids = sorted({b["id"] for b in model.QEMU_BUGS if b["suite"] == a.suite})
        for b in model.QEMU_BUGS:
            if b["id"] in ids:
                print("known QEMU bug %s: %s [%s]" % (b["id"], b["summary"], b["manual"]))
    print("result: %s" % ("PASS" if status == 0 else "FAIL"))
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
