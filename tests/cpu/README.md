# pacputest -- PA-RISC CPU test ROMs

Bare-metal test ROMs for the PA-7100LC core. Each ROM runs thousands of
instruction vectors and prints every result over the serial port. The same
binary runs on QEMU `-M 715`, on the Verilator simulation and on the board,
and the logs are compared on the host.

## Files

| file | what |
|---|---|
| `Makefile` | `make` builds every suite ROM; `make qemu` makes the QEMU reference logs |
| `gen_tests.py` | generates the assembly for a suite, plus its vector inputs |
| `src/crt0.S` | reset entry, stack, `.data` copy, `.bss` clear, `main()`; HPMC/TOC catch |
| `src/ivt.S` | interruption vector table and trap handler (writes the trap log) |
| `src/main.c` | runs every group, prints the log, computes the CRCs and trap counts |
| `src/uart.c` | LASI 16550 at 0xF0105800 |
| `src/link.ld` | memory map (below) |
| `run_qemu.py` | runs one ROM on QEMU and captures the log |
| `model.py` | independent reference model (alu1, alu2, shift, max1; the FPU edge cases of fpedge) |
| `compare.py` | checks a log against the model or against another log |
| `build/` | generated: `gen_<suite>.{S,c,json}`, `<suite>.elf`, `<suite>.bin` |
| `ref/qemu/<suite>.log` | QEMU 11.1.1 `-M 715` logs |

## Building the ROMs

    make -C tests/cpu              # every suite -> build/<suite>.elf and .bin
    make -C tests/cpu build/alu1.bin

`gen_tests.py SUITE build` writes three files:

- `gen_SUITE.S`: one routine per *group*. A group is one instruction with
  one completer, run on many vectors.
- `gen_SUITE.c`: the group table (`name`, routine, vector count, words per
  vector) that `main.c` walks.
- `gen_SUITE.json`: every vector's inputs, in the same group order. The
  model and `compare.py` read it.

Each suite has a fixed random seed, so the vectors are the same on every
build. Before generating, gen_tests.py runs each (mnemonic, completer)
through GNU `as` and drops the ones it rejects, so its condition tables can
list every completer. MAX-1 instructions are assembled at `.level 2.0` and
put into the PA 1.1 ROM as `.word`.

The cross compiler is `hppa-linux-gnu-gcc` (`-mpa-risc-1-1
-mschedule=7100LC`, freestanding). `link.ld` sets the memory map:

| address | what |
|---|---|
| 0xF0000000 | `.vectors`: HPMC/TOC entry; 0xF0000004 is the reset vector |
| next 2 KB boundary | `.ivt` (IVA), then code and rodata (ROM, 256 KB) |
| 0x00010000 | `.data` (copied from ROM by crt0), then `.bss` |
| 0x00080000 | stack (grows up) |
| 0x000F0000 | trap log (`src/ivt.S`) |
| 0x00100000 | scratch RAM for the mem suite |

The ELF boots QEMU (`-bios`), and the `.bin` is the boot ROM image for the
simulator and the board.

### Vectors of the alu1, alu2, shift and max1 suites

Registers: r3 = `a`, r4 = `b`, r5 = target. Each vector:

    ldil/ldo  a -> r3, b -> r4          (shift: also b -> r5, sar -> r10, mtsar r10)
    add r0,r0,r0  or  sub r0,r0,r0      carry preset: every PSW C/B bit 0 / 1
    ldi 0,r6
    <instruction under test>            -> r5
    ldi 1,r6                            nullified if the instruction nullifies
    idcor r0,r7                         0x6 in every digit whose C/B bit is 1
    stw r5, r6, r7

So each vector stores three words:

| word | name in compare.py | meaning |
|---|---|---|
| 0 | `t` | the target register |
| 1 | `exec` | 1 if the next instruction ran, 0 if it was nullified |
| 2 | `cbmap` | PSW[C/B] after the instruction, as a digit map (`model.cb_map`) |

The carry preset depends on the group:

- Groups ending `.c0` or `.c1` (addc, subb, dcor, idcor) run with every C/B
  bit cleared or set. Their JSON entries have `"carry": 0/1`.
- The other alu groups clear C/B.
- The shift groups, `ldil`, `addil`, `ldo` and `mtsar/mfctl` do not touch
  C/B. Their `cbmap` is whatever the C code left, the same in every vector
  of the group. The model calls this `INHERIT`.
- max1 clears C/B, but its JSON has no `carry` key.

Group names are `<mnemonic>[,<completer>][.c0|.c1]`, e.g. `addc,<=.c1`,
`hshladd,2`, `mtsar/mfctl`.

The other suites store different words. mem stores r5, the base minus
AREA, and 16 memory words. branch stores a path bitmap, r3 and r4. trap
stores r5, exec, and the trap log's number, IIR, ISR, IOR, IPSW and IIAOQ.
fp stores the double result, the status register and a pad word. fpedge
stores 8 words: the status (with FPSR.T if the operation was unimplemented;
`fstds %fr0` goes first because it is the one FP instruction that does not
trap with T set, and it clears T), fr0R, the double result (a single
result lands in the first word, the second keeps the sentinel's low half),
exception register 2 (fr1L: `{code, instruction bits 6:31}` after an
unimplemented exception, else the `{status, 0}` loaded before the
operation), fr1R and two pads. Its JSON carries the instruction word(s)
under `"insn"`. See the comments in `gen_tests.py` and `model.py`.

## Log format

`src/main.c` prints at 9600 8N1:

    pacputest <suite>
    == <group> <vector count, 4 hex digits>
    <index, 4 hex> <word0> <word1> ...           one line per vector, 8 hex digits per word
    -- <group> crc <crc32> traps <n, 4 hex>
    ...
    == end

- `crc` is an MSB-first CRC-32 over the group's words: poly 0x04C11DB7,
  initial value ~0, complemented at the end (`compare.crc32_words`).
- `traps` is the number of interruptions the group took, counted by
  `ivt.S`. The handler resumes after the faulting instruction, so an
  unexpected trap would otherwise show up only as odd data.
- A `!! HPMC/TOC taken -- no handler` line means the ROM stopped.

## QEMU reference logs

    make -C tests/cpu qemu           # every suite -> ref/qemu/<suite>.log
    python3 tests/cpu/run_qemu.py build/alu1.elf ref/qemu/alu1.log [--timeout S]

`ref/qemu/fpedge.log` is kept for reference only: QEMU disagrees with the
PCX-L model on 477 of its 1,344 vectors (it traps immediately where the
PCX-L sets T, implements FRND, and does not advance the compare queue), so
fpedge is judged by the model.

`run_qemu.py` runs `qemu-system-hppa -M 715 -m 64 -bios ROM.elf -serial
stdio -nodefaults` until the ROM prints `== end` or `!! `. It looks for
QEMU in this order: `$QEMU_HPPA`, then the session build named in
`CLAUDE.md`, then `~/src/qemu-11.1.1/build-hppa`, then `PATH`. The distro's
QEMU 8.2 has no `-M 715`.

## The reference model (`model.py`)

The model is an independent Python model of every instruction the alu1,
alu2, shift and max1 suites use. It was written from these sources, not
from QEMU:

- PA-RISC 1.1 manual, 3rd edition (`docs/reference/txt/Pa11_acd.txt`),
  cited `[ACD p.N]`.
- PA-7100LC ERS (`PCXL_ers.txt`), cited `[PCXL ERS s.N]`, where the
  architecture lets the implementation choose.
- For MAX-1: the PA-RISC 2.0 manual (`parisc2.0.txt`; `Parisc2.0.txt` and
  the PDF lose the HSHRADD page), cited `[PA2 p.N]`, and the PA-7300LC ERS
  chapter 13 (`Pcxl2_ers.txt`), cited `[PCXL2 ERS p.N]`.

The model has one function per instruction family: `arith` (add, sub,
shift-and-add, compare-and-clear, immediates), `logical`, `unit` (uxor,
uaddcm, dcor, idcor), `ldil`/`addil`/`ldo`, `shift_op` (shd, extract,
deposit, fixed and variable), `mtsar_mfctl` and `max1`. The condition
evaluators are `arith_cond` (Table 5-1, including the add/subtract
interpretations), `logical_cond`, `unit_cond` and `shift_cond`.
`predict(suite, group, inputs)` returns the three expected words.

For the fpedge suite the model is `fp_operate` (one PA-7100LC floating-point
operation: ERS s.7.2-7.4 decide which cases raise the unimplemented
exception, ACD Table 6-20 gives the IEEE default results and flags, the
arithmetic is exact with `fractions.Fraction` and rounded once to the
destination format) and `predict_fpedge` (the eight stored words and the
interruptions the vector takes). `unit_vectors.py fpmodel` turns the fp and
fpedge vectors with the model's expectations into engine-level vectors for
`verilator/tb/tb_fpu.cpp`.

An expected word can be one of four things:

- an exact value;
- a set of acceptable values;
- `None`, where the architecture makes it unpredictable;
- `INHERIT`, which must not change across the group and must be a valid
  digit map.

`python3 model.py` runs a self test. It checks the model against the
examples in the manuals: SUBI -1 as NOT setting all C/B bits, the BCD
DCOR/IDCOR sequence, COMCLR, SHD rotate, VEXTRS as an arithmetic shift,
ZVDEP as a left shift, hand-checked MAX-1 saturation and rounding cases,
and floating-point cases with known answers (signed zeroes, inf - inf,
1/0, overflow in every rounding mode, 1/3 and sqrt(2) correctly rounded,
tiny results with and without the D bit, compares with NaNs and
infinities, the integer conversion boundaries).

### Where the model leaves a result open, and why

| case | model | reason |
|---|---|---|
| SHnADD(L) conditions `<` `<=` `>=` `>` (c = 2, 3) when the pre-shift overflows (signed) | exec unpredictable | ACD p.5-3/5-4: the overflow XORed into conditions 2 and 3 "may optionally include" the pre-shift overflow, and the result "is not predictable". QEMU includes it. |
| DCOR/IDCOR carry conditions (SDC, SBC, SHC and negations) | exact where both readings agree, else unpredictable | ACD p.5-6: unit conditions use "the eight 4-bit carries". For DCOR/IDCOR the manual does not say which carries. They could be the digit carries of the correcting add/subtract, or the PSW C/B bits the correction came from. QEMU uses the adder's carries, which is also the more natural reading and the suggested choice for the RTL. |
| `mfctl %sar` upper 27 bits | 0 (exact) | ACD p.2-13/2-15: these are "nonexistent bits", which may read as zeros or as what was written (p.2-7). PCXL ERS s.5.4 says the PA-7100LC returns zeros. |

The fpedge model follows the PCX-L ERS wherever it speaks; where it is
silent the model takes the IEEE result (docs/STUBS.md, retired S-013,
lists the three such readings: FDIV's trivial denormal cases with D = 0,
FCMP of denormals in D mode, tininess after rounding).

### Interpretations worth knowing

These all come from the manuals. QEMU agrees on all of them except MAX-1, which it does not run.

- **C/B updates** (ACD p.2-11): only ADD, ADDC, SHnADD, SUB, SUBB, ADDI,
  SUBI (and the trap/overflow forms and DS) write C/B. ADDL, SHnADDL,
  COMCLR, COMICLR, UADDCM(T), DCOR, IDCOR and MAX-1 do not. For a
  subtract, a C/B bit is 1 when there was no borrow, i.e. the digit carry
  of `r1 + ~r2 + 1`.
- **SHnADD overflow** (ACD p.5-88..5-95, Table 5-2):
  - Unsigned overflow (conditions NUV/ZNV/UV/VNZ) means a shifted-out bit
    is 1 or the add carries.
  - Signed overflow (SV/NSV) means a shifted-out bit differs from the new
    sign bit, or the add overflows.
  - C/B holds the digit carries of the add only.
- **DCOR/IDCOR** (ACD p.5-112/5-114) are whole-word subtract/add of the
  0x6 digit pattern. Borrows and carries cross digits for non-BCD input.
- **MAX-1**:
  - No conditions: the cf field must be 0, and the next instruction always
    runs.
  - C/B is not written. No Operation section assigns it, and PCXL ERS s.3.4
    leaves every MAX-1 encoding out of its list of encodings that "might
    set carry/borrow".
  - The `,us` forms treat the GR r1 halfword as unsigned and the GR r2
    halfword as signed, and clamp to [0, 0xFFFF].
  - HAVG gives `(sum >> 1) | (sum & 1)`: its LSB is the OR of the two
    lowest bits of the 17-bit sum.
  - HSHLADD saturates by the sign of the GR r1 halfword whenever the
    pre-shift overflows, and that takes precedence over the add (PA2 Table
    6-3, PCXL2 ERS p.13-8). The PA2 p.7-61 text says "If GR r2 was
    negative", which is a typo for r1.
  - HSHRADD shifts arithmetically, then adds with signed saturation.

## compare.py

    compare.py SUITE LOG --model [--known-qemu]    # LOG vs the model
    compare.py SUITE LOG --ref REFLOG              # LOG vs another log, any suite
    compare.py SUITE LOG --ref REFLOG --model      # the reference policy, below
      options: -n N (mismatches shown per group, 0 = all), --group REGEX,
               --brief (failing groups only), --quiet, --json PATH

The script parses and checks the log itself:

- the suite name;
- group headers against the vector lines;
- vector index sequence;
- the CRC of every group;
- the trap count;
- the `== end` marker and any `!!` line.

Then it prints one line per group (vectors, pass, FAIL, relaxed, ...). For
the first N mismatching vectors of each group it prints the inputs and the
expected and actual words. A sample:

    sh1add,znv                  10       8       2       0  FAIL
      #0001  a=99999999 b=55555555 carry=0
             word   model             actual
             t      88888887          88888887
             exec   00000001          00000000  <--
             cbmap  00000000          00000000
             note: group affected by known QEMU bug shadd-uv

How each part is judged:

- **Trap counts** must equal the reference log's. Against the model they
  must be 0, because none of the model's instructions trap.
- **`relaxed`** counts vectors that passed only because the model leaves a
  word open.
- **`--known-qemu`** counts a vector that fails exactly as a documented
  QEMU bug predicts (`model.QEMU_BUGS`) as `qemubug`, not FAIL. It is for
  checking QEMU's own logs.

Exit status: 0 = all pass, 1 = any mismatch or a damaged/incomplete log,
2 = usage error.

## Reference policy

QEMU is not ground truth (`CLAUDE.md`). For the alu1, alu2 and shift
suites, every vector QEMU gets right agrees with the model. QEMU is the
reference there, and the model is the reference where QEMU is known to be
wrong.

`compare.py --model` applies that policy directly. Where QEMU is right,
its value equals every exact expectation. Where the model leaves a word
open, QEMU's value is not binding. `--ref ref/qemu/X.log --model` also
shows which QEMU vectors fail the model, and it fails any group with a
QEMU disagreement that no `QEMU_BUGS` entry explains. That catches new
QEMU or model bugs when the reference logs are regenerated.

For max1, the model is the only reference. Suites without a model (mem,
branch, trap, fp, fpedge) are compared to the QEMU logs with `--ref`, with
QEMU's known deviations in mind.

To check that the model and QEMU still agree:

    for s in alu1 alu2 shift max1; do
        python3 tests/cpu/compare.py $s tests/cpu/ref/qemu/$s.log --model --known-qemu --brief
    done

State on 2026-10-07:

| suite | vectors | agree | known QEMU bug |
|---|---|---|---|
| alu1 | 3230 | 3192 | 38 (shadd-uv) |
| alu2 | 1520 | 1520 | 0 |
| shift | 1580 | 1580 | 0 |
| max1 | 312 | 0 | 312 (max1-illegal) |

## QEMU bugs found by these suites

Both are recorded in `model.QEMU_BUGS`, each with a function that
reproduces QEMU's wrong output.

- **shadd-uv**:
  - **Symptom:** SH1ADD/SH2ADD/SH3ADD and the L forms, conditions
    NUV/ZNV/UV/VNZ. The unsigned overflow from the pre-shift tests GR r1
    bits 31-n..30, not the bits shifted out (32-n..31).
  - **Cause:** QEMU 11.1.1 `target/hppa/translate.c`, `do_add_uv()`:
    `tcg_gen_extract_i64(tmp, in1, (d ? 63 : 31) - shift, shift)` is one
    bit too low. The 64-bit path has the same off-by-one.
  - **Manual:** ACD p.5-88..5-95 says "Unsigned overflow means that ...
    the bits shifted out is 1"; Table 5-2 p.5-3 agrees.
  - **Evidence:** A model of the bug reproduces QEMU's nullification on
    all 240 such vectors. 38 of them differ from the architecture; the
    other 202 agree by chance.
- **max1-illegal**: QEMU takes an illegal-instruction trap on every MAX-1
  instruction on a PA 1.1 CPU (already in `CLAUDE.md`). The PA-7100LC
  implements them (PCXL ERS s.2.1.4). Every max1 group in QEMU's log shows
  24 traps, so the model is the only reference for that suite.

## Coverage notes

These are gaps in the vectors, not in the model:

- Instructions that must leave C/B alone are tested only with C/B = 0:
  ADDL, SHnADDL, COMCLR, COMICLR, logicals, UXOR, UADDCM(T), the
  shift/extract/deposit and long-immediate groups, and MAX-1. The
  inherited C/B in the shift and long-immediate groups is also 0 in
  practice. So an implementation that clears C/B on them would pass.
  Presetting C/B to all ones (`sub r0,r0,r0`) for those groups would close
  this.
- UADDCMT runs only unconditionally here. Its conditional form traps, so
  it belongs to the trap suite.
- The DCOR/IDCOR presets give only C/B all-0 or all-1. Mixed C/B patterns,
  the normal BCD case, are not exercised.
