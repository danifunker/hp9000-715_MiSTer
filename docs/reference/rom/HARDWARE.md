# HP 9000/715 PDC 1.6 — hardware registers as the boot ROM uses them

What the 715/64 boot ROM (`roms/hp715_pdc_rev1.6.bin`, PDC revision 1.6,
mapped at 0xF0000000) reads and writes in the memory and I/O controller (MIOC),
the CPU's HPA page, broadcast space, LASI and its units, the LASI 8-bit bus
(boot ROM, EEPROM, LED, system ID), WAX/EISA and Artist, plus the PA7100LC
diagnose and control registers it uses, and what it expects back. Written for
the MiSTer FPGA recreation: every "the ROM expects" line is something our
hardware has to return for HP's own firmware to boot unmodified.

Companion documents: `BOOTFLOW.md` (reset/boot flow, self-test order,
chassis codes — the boot-flow pass) and the PDC/IODC/STI/EEPROM pass. Names
of ROM routines below are the `tools/rom/symbols/*.sym` names
(`bootflow.sym`, `firmware.sym`, `hwmap.sym`); `F_xxxxxxxx` is an unnamed
routine.

Status: first pass, 2026-10-07. Confidence is marked: **(ROM)** = read
directly from the code; **(7300LC)** = taken from the PA7300LC ERS by analogy
and consistent with the code; **(guess)** = inference.

---

## 0. Conventions and tools

* Bit numbers are PA-RISC big-endian: bit 0 = MSB (value 0x80000000),
  bit 31 = LSB (value 1). Every bit is also given as a value, e.g.
  "bit 27 (0x10)".
* `tools/rom/hwmap_trace.py` — function-wide constant tracker (a register
  that holds the same constant at every definition in a function survives
  loops/branch targets, which `romlib.resolve()` forgets). Output:
  `roms/disasm/hwmap/hwaccess_ext.tsv` (354 device accesses with the
  containing function and the stored value when constant) and
  `callargs.tsv` (1230 calls with constant r26..r23 arguments).
* `tools/rom/hwmap_ecc.py` — finds a check-bit code that satisfies every ECC
  expectation in the ROM (§1.6). Prints a 64-entry column table.
* `tools/rom/symbols/hwmap.sym` — names given in this pass (only addresses
  the other passes had not named).
* `python3 tools/rom/annotate.py roms/hp715_pdc_rev1.6.bin roms/disasm/hwmap`
  regenerates the annotated listing with all names; `roms/disasm/hwmap/c.dis`
  is a compact copy (no hex words) used while reading.

---

## 1. MIOC — PA7100LC memory and I/O controller (HPA 0xFFFBF000)

We have no PA7100LC MIOC ERS. The PA7300LC ERS (ch. 11.6) describes its
successor; its §1.2.3 says the programming model "changed from the
PA7100LC… registers reorganized and several registers formerly in I/O space
are now diagnose registers" (M_WRT_CHK, M_ERR0/1, M_RD_CHK, M_ERR_BYTE). The
ROM confirms that the 7100LC keeps **the same register page layout for
MIOC_CONTROL (0x80), MIOC_STATUS (0x84), MTCV (0xC0), MDERRADD (0xE0),
MEMCOMP (0x100–0x13C) and MEMMASK (0x140–0x17C)**, and has the memory ECC
diagnostic registers at 0xC4–0xDC. Registers the 7300LC has but the ROM never
touches: 0xA0–0xB0 (L2 cache, not on the 7100LC), 0xCC REF (refresh lives in
MTCV on the 7100LC, §1.4), 0xE8 DMAERR, 0xEC DIOERR, 0xF0 GSC_TIMEOUT, 0xF4
HIDMAMEM, 0x180 MEMTEST, 0x1C0 OUTCHK, 0x7A0 GSC15X_CONFIG.

All accesses are word loads/stores (`ldw`/`stw`), usually preceded by `sync`.

### 1.1 Register table

| Off | Name (ours) | R/W | ROM sites | Values written / bits tested | Meaning | Ref |
|---|---|---|---|---|---|---|
| 0x080 | MIOC_CONTROL | R/W | reset f0000084; `st_gsc_parity` f000b538–b6ec; `mem_scrub_read` f000d1f0–d274; `mem_ecc_multibit` f000d300/d310, d838–d854; `mem_ecc_singlebit` d890/d8a0, dcb4/dcc4 | reset **0xCDFA8000** (constant 0xCDFB8000 with bit 15 cleared by `depwi`); RMW only afterwards: bit 17 (0x4000) and bit 18 (0x2000) one-shot fault injection, bit 19 (0x1000) cleared during ECC tests/scrub and set afterwards, bit 14 (0x20000) cleared if DR0 rev = 0 | §1.2 | 7300LC 11.6.3 (bits 17–19 match) |
| 0x084 | MIOC_STATUS | R, W = clear | `mioc_status_clear` f000270c (HPMC/TOC entry), `mioc_status_check_toc_en` f0002cc0, `st_hpmc_expected` f00093dc/93e8, f000b23c/b248/b3a0/b404/b49c, f000cba0, f000d15c–d350 (masked 0x7F), d8d4…dd20, `pdc_probe_hpmc` f0011b60, `lpmc_pim_save` f0014be8, HPMC PIM f0004930 | error bits 25–31 (mask 0x7F); cleared by writing the read value back | §1.3 | 7300LC 11.6.4, layout differs |
| 0x0C0 | MTCV | W | reset f00000b8; `mem_size_all` f000bf24; f000d14c; ECC tests f000d334…dd40 | per clock: **0x09F06974** (64 MHz), 0x09EC81B4 (80), 0x0DE79EFB (100); bit 5 (0x04000000) toggled = ECC generate/check on | §1.4 | 7300LC 11.6.10 (+ REF 11.6.11) |
| 0x0C4 | M_WRT_CHK | W | ECC tests f000d420…dd74; fill test f000cbd8/cc40 | check bytes, one per doubleword of the line, used for writes while MTCV bit 5 = 0 (0x55555555, 0x33333333, 0xCCCCCCCC, single/double/triple flips) | §1.6 | 7300LC DR2 M_WRT_CHK (moved) |
| 0x0D0 | M_ERR0 | R/W | `st_gsc_parity` f000b464/b468 (0xAAAAAAAA written, must read back), b564/b5f4 (0xBBBBBBBB with bad parity, must not land), b634; ECC tests f000d49c…dbfc; `lpmc_pim_save` f0014cd0 | MSW of the raw (uncorrected) doubleword that had the logged error | §1.6 | 7300LC DR3 M_ERR0 |
| 0x0D4 | M_ERR1 | R | ECC tests f000d4a8…dc08; f0014ce0 | LSW of the raw doubleword | §1.6 | 7300LC DR4 M_ERR1 |
| 0x0D8 | M_RD_CHK | R | f000dc24 (low byte compared), f0014cc0 (PIM) | bits 24–31 = raw check byte of the errored doubleword; upper bytes unknown | §1.6 | 7300LC DR5 M_RD_CHK (guess for upper bytes) |
| 0x0DC | (line check bytes) | R | ECC tests f000d3cc…dbc8; fill test f000cc3c/ccd0 | the 4 check bytes of the last line read from DRAM (byte 0 = doubleword 0) | §1.6 | undocumented |
| 0x0E0 | MDERRADD | R | ECC tests f000d4e0…dc4c (compared with bit 29 cleared); HPMC PIM f0004954/4974/4998; LPMC PIM f0014c50/4c64 | address of the logged error: doubleword address for memory errors; the faulting address for I/O / unconfigured-memory errors (reported as PIM "responder address") | §1.3, §1.6 | 7300LC 11.6.12 |
| 0x100+4n | MEMCOMP[n], n = 0..15 | W | `mem_probe_block` f000c21c (0), `mem_program_block` f000c5f8 (base) | base address of block n (bits 0–8 = address bits 0–8) | §1.5 | 7300LC 11.6.17 |
| 0x140+4n | MEMMASK[n] | W | `mem_disable_blocks` f000bebc–bef8 (0x00400000 ×16), probe f000c234 (0x1F800000), f000c304/c34c/c394/c3fc (tech 1–4), f000c444/c1a8 (0x00400000), final f000c658 | bits 0–2 dram_tech, 3–8 mask, 9 (0x00400000) emptyh | §1.5 | 7300LC 11.6.18, same layout |

Not touched: 0x000–0x07C (the generic HPA registers; PDC answers IODC/HPA
queries for the CPU and memory modules from tables in ROM, `pdc_iodc` /
`iodc_read_body` f0013d9c compare against 0xFFFBF000/0xFFFBE000), 0x088–0x0BC,
0x0C8–0x0CC, 0x0E4–0x0FC, 0x180+.

### 1.2 MIOC_CONTROL (0x080)

Reset value written by `reset_entry`: **0xCDFA8000** = bits 0,1,4,5,7–12,14,16.
The source constant is 0xCDFB8000; `depwi 0,15,1` clears bit 15 before the
store, and bit 15 is never set again. Everything after reset is
read-modify-write, so the register must read back what was written.

| Bit (value) | ROM use | Meaning |
|---|---|---|
| 0–13 | constant | unknown on the 7100LC; 7300LC names bits 0–4 dwmode/drdw/idrdcntl/rpen and 12–13 dma_noecc/lpmc_en **(guess, layout probably differs)** |
| 14 (0x00020000) | cleared at the end of `mem_ecc_multibit` (f000d848) **only when DR0 rev = 0** | rev-0 erratum workaround; 7300LC calls bit 14 dma_nocache **(guess)** |
| 15 (0x00010000) | cleared at reset, never set | 7300LC fast_memory **(guess)** |
| 16 (0x00008000) | set (constant) | 7300LC lopowhilat **(guess)** |
| 17 (0x00004000) | `st_gsc_parity`: set, then one CPU I/O store must fail with HPMC, MIOC_STATUS = 0x02, target unchanged | **pgape**: bad address parity on the next CPU-mastered I/O cycle, self-clearing **(ROM + 7300LC)** |
| 18 (0x00002000) | `st_gsc_parity`: set, then one CPU I/O store must fail with HPMC, MIOC_STATUS = 0x08 | **pgdpe**: bad data parity on the next CPU I/O write, self-clearing **(ROM + 7300LC)** |
| 19 (0x00001000) | cleared while memory is tested/scrubbed, set afterwards; `mem_ecc_singlebit` sets it and then expects an **LPMC** (interruption 5) from a single-bit error | **slen**: signal LPMC on corrected single-bit errors **(ROM + 7300LC)** |
| 20–31 | 0 | — |

`st_gsc_parity` (f000b3f8, run from `selftest2`) checks four cases. Before
each it sets DR0 bit 18 (expect HPMC) and dp = 0x40000000; the test HPMC
handler at IVA+0x20 (`st_hpmc_expected` f00093c8) clears DR0 bit 18, flips dp,
copies MIOC_STATUS to tr7, writes it back (clear) and resumes after the
faulting instruction:

| Store | Expected MIOC_STATUS & 0x7F | Expected effect |
|---|---|---|
| pgape + `stw 0xBBBBBBBB → MEM_HPA+0xD0` | 0x02 | 0xD0 still reads 0xAAAAAAAA |
| pgdpe + `stw 0xBBBBBBBB → MEM_HPA+0xD0` | 0x08 | (not checked) |
| pgape + `stb 0x88 → LASI UART scratch 0xF0105807` | 0x02 | scratch still reads 0xAC |
| pgdpe + `stb 0x66 → 0xF0105807` | 0x08 | (not checked) |

So the FPGA's MIOC needs a one-shot "fail the next CPU I/O store" with two
error classes; the store must be dropped (at least for pgape).

### 1.3 MIOC_STATUS (0x084)

Seven error/event bits, all in bits 25–31. Code masks with 0x7F and clears
by writing the value it read back (the 7300LC calls these bits read/toggle;
write-one-to-clear behaves identically for every ROM use).

| Bit (value) | Name (ours) | Evidence | Signals |
|---|---|---|---|
| 31 (0x01) | dml / DMA error | `lpmc_pim_save` treats bit 31 as an LPMC source; 7300LC dml (DMA memory limit) | LPMC |
| 30 (0x02) | **pioae** — CPU I/O address error / timeout | expected after a load from 0xFFFBB000 (`st_hpmc_toc`), after pgape; `mem_scrub_read` treats it as "ran off the end of memory" (so **loads from physical memory not covered by any MEMCOMP block also give 0x02**); HPMC PIM: bus check 0x0031xxxx, responder = MDERRADD | HPMC |
| 29 (0x04) | pmae (guess) | only decoded by the HPMC handler / PIM (no address logged); 7300LC pmae = access to unconfigured memory, but see bit 30 | HPMC |
| 28 (0x08) | data parity (pmdp/dmdp) | expected after pgdpe; PIM logs MDERRADD | HPMC |
| 27 (0x10) | **toc** | expected after `stw 5 → CPU_HPA+0x30`; `hpmc_toc_entry` uses this bit to tell TOC from HPMC | TOC |
| 26 (0x20) | **dedc** — uncorrectable memory error | expected for double data-bit and 2/3 check-bit errors (`mem_ecc_multibit`); PIM bus check 0x0021xxxx | HPMC |
| 25 (0x40) | **sedc** — corrected single-bit error | expected for every single data/check-bit flip (`mem_ecc_singlebit`); masked out (0x7F & ~0x40) by `mem_scrub_read`; LPMC source | LPMC if MIOC_CONTROL bit 19 |
| 0–24 | ? | never tested; written back by the HPMC handler (must ignore) | — |

Compared with the 7300LC (sedc 0x80, dedc 0x40, toc 0x20, pmdp 0x10, dmdp
0x08, pmae 0x04, pioae 0x02, dml 0x01) the 7100LC has one data-parity bit
fewer, so sedc/dedc/toc sit one position lower **(ROM)**.

Delivery the ROM relies on **(ROM)**:
* HPMC and TOC both vector to **0xF0000000** (PCX-L ERS 5.3.5), which
  branches to `hpmc_toc_entry` f00026b0. With DR0 bit 18 set it forwards to
  IVA+0x20 after `diag SHDW_GR`, so the HPMC must leave IIAOQ/IIASQ pointing
  at (or just after) the faulting load/store with PSW Q = 1 and the GR
  shadows holding the pre-trap r1/r8/r9/r16/r17/r24/r25.
* LPMC vectors to IVA + 5×32 (`mem_ecc_singlebit` expects dp bit 5 to flip).
* External interrupt latency: `st_eir_eirr` (f000b130) stores 29 to the
  CPU's EIR with EIEM bit 29 and PSW I set, then allows only a five-iteration
  loop (~10–15 instructions) before checking that the interrupt was taken.

### 1.4 MTCV (0x0C0) — DRAM timing, refresh and ECC enable

Written at reset with one of three constants chosen by `get_cpu_speed`
(f0015e24, from the system ID at 0xF00FFFFC, §5.1); `mem_timing_word`
f0015860 returns the same table later. Never read back.

| | 64 MHz (ID 7) | 80 MHz (ID 0xB) | 100 MHz (other) |
|---|---|---|---|
| value | 0x09F06974 | 0x09EC81B4 | 0x0DE79EFB |
| bits 0–6 | 0000100 | 0000100 | 0000110 |
| bits 7–21, ones' complement | 997 | 1247 | 1560 |
| refresh period = that + 2 | 999 clk = 15.61 µs | 1249 clk = 15.61 µs | 1562 clk = 15.62 µs |
| bits 22–31 | 01 0111 0100 | 01 1011 0100 | 10 1111 1011 |

* **Bits 7–21 are the refresh interval** in CPU clocks, encoded exactly like
  the 7300LC REF.refresh field ("ones' complement of (period − 2)"): all three
  decode to the standard 15.6 µs (4096 rows / 64 ms) **(ROM arithmetic +
  7300LC)**. The 7100LC has no separate REF register.
* **Bit 5 (0x04000000) = ECC generate/check enable** **(ROM)**: cleared while
  memory is sized and while the ECC tests write lines with forced check bits
  (then writes take their check bytes from 0xC4), set for normal operation
  (f000d140, f000d328…). The reset value has it set only for 100 MHz.
* Bit 4 (0x08000000) is set in all three (memory enable / DRAM output
  enable?) **(guess)**. Bits 22–31 hold DRAM RAS/CAS timing that grows with
  the clock — plausibly five 2-bit cycle counts **(guess)**.

FPGA: store the register; only bit 5 changes behaviour (§1.6). Our SDRAM
controller does its own refresh.

### 1.5 MEMCOMP/MEMMASK and memory sizing

Sixteen address comparators ("blocks"). MEMCOMP[n] (0x100+4n) holds the
block's base in bits 0–8 (address bits 31..23, 8 MB granularity). MEMMASK[n]
(0x140+4n) has the 7300LC layout **(ROM)**:

| Bits | Field | Values the ROM uses |
|---|---|---|
| 0–2 | dram_tech (row/column mux) | 0 for 8/16/32 MB blocks, 1 = 64 MB, 2 = 128 MB, 3 = 256 MB, 4 = 512 MB |
| 3–8 | mask (1 = don't compare address bit 3..8) | 0x00 8 MB, 0x01 16 MB, 0x03 32 MB, 0x07 64 MB, 0x0F 128 MB, 0x1F 256 MB, 0x3F 512 MB |
| 9 (0x00400000) | emptyh (1 = comparator off) | 1 for unused blocks |

Final MEMMASK values (`mem_program_block` f000c5ec): 8 MB 0x00000000,
16 MB 0x00800000, 32 MB 0x01800000, 64 MB 0x23800000, 128 MB 0x47800000,
256 MB 0x6F800000, 512 MB 0x9F800000.

Sizing (`mem_size_all` f000bf10, called from `mem_init` via f000be30), with
MTCV bit 5 cleared and the caches used normally (writes are pushed out with
`fdc`, reads miss to DRAM):

1. All 16 MEMMASKs = 0x00400000 (`mem_disable_blocks`).
2. For each block n = 0..15 (`mem_probe_block` f000c210): MEMCOMP[n] = 0,
   MEMMASK[n] = 0x1F800000 (tech 0, all six mask bits set, enabled — the
   block now answers every address below 512 MB). Write 0xAAAAAAAA to the
   line at 0 and 0x123ABC78 to the line at 0x20; read words 0 and 4:
   * both ≠ 0xAAAAAAAA → **block empty** (returns 0). So an enabled block with
     no DRAM behind it must return data that is not the last pattern
     written — and must **not** raise an HPMC (no bus error is expected here).
   * one wrong → error −1/−2 (logged, "Memory card failed").
3. Then write 0x55555555 at increasing offsets and see whether it lands on
   address 0 (aliasing): 4 MB alias → −6 ("unsupported"); 8 MB → size 8 MB;
   16 MB → 16 MB; with tech 1: 32 MB (or 16 MB) alias → 32 MB; tech 2:
   64/32 MB → 64 MB; tech 3: 128/64/32 MB → 128 MB; tech 4: 128/64 MB alias →
   256 MB, none → 512 MB. Mixed results map to −3/−4/−5 via the table at
   f000c5bc. MEMMASK[n] = 0x00400000 again.
4. Blocks are recorded by size in bitmaps kept in **space registers sr0–sr6**
   (16 bits each, one per size; memory is not usable yet), errors in r20/r21.
5. Allocation, largest size first, contiguous from address 0: for each block
   of that size, MEMCOMP[n] = base, MEMMASK[n] = final value; base += size.
6. Total = end address; errors → `mem_report_errors` chassis codes.

Block → SIMM slot (`mem_block_to_slot` f000c65c, for the 715/64 system ID):
blocks 2 and 7 → the SIMM pair in slots 0/1, blocks 0 and 5 → slots 2/3,
blocks 10 and 15 → slots 4/5, blocks 8 and 13 → slots 6/7. Two blocks per
pair = two RAS banks (double-sided SIMMs) **(guess)**; which SIMM of the
pair is blamed comes from which 32-bit half of the doubleword failed (each
SIMM supplies one word). The other eight comparators have no slot on this
board (the mapping is different for system IDs where `board_model` returns 1).

What the FPGA must model:
* A block decodes when (addr[0:8] & ~mask) == (MEMCOMP[0:8] & ~mask) with
  address bits 0–2 always compared (7300LC rule).
* Aliasing: with the generous mask used for probing, the populated block must
  wrap at its real size: offset → offset mod size works for every case the
  ROM tests **except a 256 MB block**, which must alias at 128 MB when
  programmed with tech 4 (the real DRAMs drop a row/column bit). **Present the
  memory as blocks of at most 128 MB** (e.g. 128 MB SDRAM = one 128 MB block,
  or two 64 MB blocks; 256 MB = two 128 MB blocks) and modulo aliasing is
  enough.
* Put the memory behind comparators that have a slot on the 715/64 (e.g.
  block 2 = pair in slots 0/1, block 7 for a second bank); the ROM probes all
  16, so the choice only affects slot numbers in messages. Enabled blocks
  with nothing behind them return e.g. all-ones.
* Physical addresses below 0xF0000000 that hit no enabled block → HPMC with
  MIOC_STATUS = 0x02 and MDERRADD = address (see 1.3).

### 1.6 ECC: registers 0xC4–0xE0 and what the tests demand

One 8-bit check byte per 64-bit doubleword, four per 32-byte line.
`mem_ecc_singlebit` (f000d870) and `mem_ecc_multibit` (f000d2d0) run on the
line at physical 0 with MIOC_CONTROL bit 19 cleared:

1. MTCV bit 5 = 1, clear status, write the line with 0x01234567/0xFEDCBA98
   pairs, `fdc`, read back: data equal, status 0, **0xDC = 0x55555555** (so
   the hardware check byte for 0x01234567FEDCBA98 is 0x55).
2. For every bit of word 0 and of word 1 (64 cases): MTCV bit 5 = 0, write the
   pattern with that bit flipped and C4 = 0x55555555 (the good check bytes),
   `fdc`, MTCV bit 5 = 1, read: data must come back **corrected**, 0xDC =
   0x55555555, status = **0x40**, 0xD0/0xD4 = the raw (flipped) doubleword,
   MDERRADD = 0 (bit 29 ignored).
3. Same with the flip in each of the 8 words of the line in turn: MDERRADD =
   that doubleword's address.
4. For each check bit of byte 0 (C4 = 0x55555555 ^ (0x80000000 >> k)): data
   intact, status 0x40, 0xDC = the forced C4, **0xD8 low byte = the forced
   check byte**.
5. One single-bit error with MIOC_CONTROL bit 19 set, PSW I/Q set, EIEM 0:
   an **LPMC** must be taken; status then cleared and re-read as 0.
6. Uncorrectable (`mem_ecc_multibit`, DR0 bit 18 set so the HPMC is
   expected): data flip 0x01000400 in word 0 or 1 with good check bits;
   check-byte flips 0xD0 and 0x0D (three bits) and 0x88 (two bits) with good
   data → **HPMC**, status = **0x20**, 0xDC = what was stored, 0xD0/0xD4 = raw
   data, MDERRADD = 0.
7. Both tests finish by writing zeros with C4 = 0x33333333.

The full memory pattern test (code at 0xF000CB90–0xF000CE9C, which
`mem_size_all` runs from the I-cache, §8.3) writes all-ones lines with C4 =
0xCCCCCCCC and zero lines with C4 = 0x33333333 (MTCV bit 5 clear) and
compares 0xDC with those values after reading each line back. Together:

    ECC(0x0000000000000000) = 0x33
    ECC(0xFFFFFFFFFFFFFFFF) = 0xCC
    ECC(0x01234567FEDCBA98) = 0x55

HP's H-matrix is not known. Any SEC-DED code with those three values, odd-
weight columns, no data column equal to 0xD0 or 0x0D, and no three columns
of the triple flip 0x00000D00 in the upper word (`mem_ecc_multibit`
f000d4f8, which must HPMC) XORing to a fourth column passes all of the
above; `tools/rom/hwmap_ecc.py` finds one (prints 64 columns; ECC(d) = 0x33 ^
XOR of the columns of the set data bits). (Its first version missed the
triple flip; the RTL simulator caught it, 2026-10-07.)

**Cheap FPGA model (no check-bit storage):** compute ECC on the fly; keep a
small "poison" table (4 entries = one line is enough for the ROM) of
doublewords written while MTCV bit 5 = 0 whose C4 byte differs from ECC(data):
store the forced check byte. Any write with bit 5 = 1 removes the entry. On a
line read: 0xDC = the four check bytes (stored or computed); for a poisoned
doubleword compute the syndrome, correct a single-bit error (status 0x40,
LPMC if bit 19) or report dedc (status 0x20, HPMC), and latch 0xD0/0xD4 (raw
data), 0xD8 (raw check byte in bits 24–31) and MDERRADD. Writes with bit 5 = 0
whose C4 equals ECC(data) (the fill test) create no entries.

### 1.7 Other MIOC behaviour the ROM depends on

* I/O timeouts: any CPU load/store to an I/O address nobody answers must end
  with an HPMC, MIOC_STATUS bit 30 and MDERRADD = the address. Addresses the
  ROM probes expecting a bus error on a 715/64 are listed in §7. Stores to
  absent devices before the HPMC handler can cope are fatal (BOOTFLOW §7).
* 0xFFFBB000 ("reserved for 712 PDC, accesses must always cause bus errors",
  LASI ERS app. B) is read by `st_hpmc_toc` and must bus-error.
* The MIOC pages answer only at 0xFFFBE000/0xFFFBF000 (FLEXID, §3).

---

## 2. CPU HPA page (0xFFFBE000)

| Off | Name | R/W | ROM sites | Values | Expected behaviour | Ref |
|---|---|---|---|---|---|---|
| 0x000 | IO_EIR | W | `st_eir_eirr` f000b174/b194/b1e0, `st_eir_itimer` f000618c; LASI IAR = 0xFFFBE003 (LASI sends 3), second LASI IAR = 0xFFFBE007 (f000099c) | n = 0..31 | sets EIRR bit n (value 1 << (31−n)); idempotent; with EIEM = 0 nothing is taken; must be visible in EIRR about ten instructions after the store (`st_eir_itimer` f000618c→f00061b8, `st_eir_eirr` loop of five iterations) | 7300LC 11.6.1 |
| 0x030 | IO_COMMAND | W | `st_hpmc_toc` f000b314 (5), f000b378 (0xFFFFFFFF) | 5 = TOC; other values ignored | 5 → TOC (if enabled by TOC_EN) through 0xF0000000, MIOC_STATUS bit 27 set; 0xFFFFFFFF must do nothing | 7300LC 11.6.2 |

No other CPU-HPA register is accessed. The 7100LC has no I/O-mapped cache
diagnose registers (those are diagnose instructions, §8).

---

## 3. Broadcast space

| Address | Name | ROM sites | Value | Meaning |
|---|---|---|---|---|
| 0xFFFC0020 | FLEXID (local) | `io_module_table_init` f0004b94, `iodc_probe_device` f00144b8 (before probing 0xFFF94000) | **0xFFF81001** | busid = bits 4–13 = 0x3FE → CPU/MIOC stay at 0xFFFBE000/0xFFFBF000; bit 31 (and bit 19) set = bus-master enable per the GSC flex register convention **(7300LC + guess)**. FPGA: accept and ignore (or require busid 0x3FE). Must not bus-error. |
| 0xFFFC0030 | COMMAND_LOCAL | `do_broadcast_reset` f0012088 | 5 | full machine reset (after LASI.AMR = 3, IRR read, IMR = 0); the code then spins. Used by `reset`/`DefaultSS` and PDC_BROADCAST_RESET. |

EIR_LOCAL (0xFFFC0000) and the global copies (0xFFFE0000/0xFFFE0030, which
Linux uses for reboot) are not used by the ROM. The `BROADCAST+0x3exxx`
"accesses" in `hwaccess.tsv` (f00242d8…f00247d0, f00391f8) are data — the
STI image header at 0xF0024000 and the HIL keymap tables — decoded as code.

## 4. LASI (HPA 0xF0100000)

Sections 4 and 6 come from two focused passes over the listing (one on the
LASI units, one on WAX/EISA/graphics); key sites were re-checked against
`c.dis`. LASI ERS section numbers refer to `docs/reference/txt/Lasi_ers.txt`
(712 I/O subsystem ERS). Offsets are from 0xF0100000.

General rules the ROM relies on:
* Loads into r0 must still perform the read: IRR is cleared with
  `ldw/ldb …,r0`. IRR is also read with **`ldb`** (f0000288).
* Word reads of byte-wide devices (EEPROM, system ID) return four
  consecutive bytes, big-endian.
* Every LASI store at reset happens before an HPMC can be survived.

### 4.1 LASI core

| Reg | R/W | ROM sites | Values / checks | Ref |
|---|---|---|---|---|
| IRR +0x0 | R (read clears) | f00000f0, f0000288 (`ldb`), f0000660, f0012070, f000fc30, f001084c | audio test needs IRR == 0x2000; FDC test needs 0 before and 0x100000 after its DMA | ERS 14.2 |
| IMR +0x4 | R/W | f00000e0, f000027c, f0000684, f00002c0, f001207c, f000fbe0, f0010760, f0038670, f002df1c–28, f0032f40 | 0 at reset; 0x04000000 for the PS/2 boot test; 0x00200000 after ICR = 2; 0x2000 audio; 0x100000 FDC; RMW clears 0x200 (SCSI, must read back 0) and 0x100 (LAN); saved/zeroed/restored | ERS table 21 |
| IPR +0x8 | R/W | f00000e8, f000f340, f000f8f0, f000fbc0, f0010740; SCSI driver f002e7f0, f002ea80–9c, f0030504, f0030794–b0 | written 0 to clear; the SCSI driver clears 0x200 by RMW and polls IPR & 0x200 **with IMR masked** (30 µs period) → IPR must latch while masked | ERS 14.2 |
| ICR +0xC | W | f00002ac | 2 (TOC remap), then IMR = 0x200000 and TOC_EN | ERS table 20 |
| IAR +0x10 | — | **never written** for the primary LASI | power-up value **0xFFFBE003** must be in place: LASI interrupts set EIRR bit 3 | ERS table 19 (default 0xfffbe003) |
| clocks +0xB000–B00C | W | f000016c–f00001a0 | see 4.2 | ERS 17 |
| PCR +0xC000 | R/W | f0000048 (=1, first I/O store after reset), f00006c0/d8, `soft_power_enable` f0013b58–98 | bit 0 FLASH_LED, bit 1 PWR_ON_L. The selftest1-failure loop writes 0 and 2 alternately every 375 ms (LED blink, **not** a power-off on the 715); PDC_SOFT_POWER: arg 1 clears bit 0, arg 0 sets bit 0 (+ bit 1 if DR25 bit 0 = 0) | ERS 12.3 table 15 |
| ERRLOG +0xC004, VER +0xC008 | — | never accessed | — | ERS 13.3/13.4 |
| IORESET +0xC00C | W | f00000d8 (0), f00001b4 (0x1FF) | all units held in reset while the clocks are programmed, then released; bit 8 = RST_ARTIST_L | ERS table 14 |
| AMR +0xC010 | R/W | f00001c8, f0000a3c, f0003334–44, f000b834/848, f0012064; LAN f00340c0/d0, f00342e8/f8, f0036edc/eec, f0037104/114 | 2 at reset (ERM: expansion masked); 0 only if 0xF041FFFE, 0xF0200000 or 0xF1000000 answers; RMW clears 0x2 before EISA init; saved/restored around `st_gsc_parity`; 3 before broadcast reset; LAN code writes **0xFFFFFFFF** and restores — must store and read back all bits | ERS 16.2 |

### 4.2 LASI clock registers (+0xB000)

| Reg | 715/64 (ID 7) | ID 0xB | other IDs | Meaning (ERS 17) |
|---|---|---|---|---|
| +0xB000 clk_40 | 0x0C000000 then 0x8C000000 | same | same | source = clkio (external 40 MHz), PLL40 reset released |
| +0xB004 clk_20 | 0 | 0 | 0 | clk_20 = clk_40 / 2 |
| +0xB008 clk_aud0 | 0x3231BC00 then 0xB231BC00 | 0x222E4902 | 0x220F3E00 | n = 49, m1 = 188, div = 3, PLL enabled → 64 MHz × 50 / 189 = 16.93 MHz |
| +0xB00C clk_aud1 | 0x322F7C00 | 0x322E3202 | 0x002C7900 | n = 47, m1 = 124, m2 = 0 → 24.576 MHz |

The ERS table gives div = 2 for 64 MHz; the ROM writes 3. For the "other"
column the numbers only work out if LASI's clksys is 66.7 MHz (GSC clock of a
100 MHz CPU). FPGA: make the four registers plain read/write storage and
generate the audio clocks directly.

### 4.3 UART (16550 at 0xF0105800, byte registers; unit reset at 0xF0105000)

| Reg | Sites | Behaviour the ROM needs |
|---|---|---|
| +0x000 (0xF0105000) | f0015aa0 | write 0 = unit reset |
| IER 0x801 | f0015ab0 | 0 |
| MCR 0x804 | f0015ab8, f0015b64 | 4, then 7 |
| FCR/IIR 0x802 | f0015ac0–cc | FCR = 1 then 7; **IIR must read 0xC1** (FIFOs enabled), else init returns −1 |
| LCR 0x803 | f0015ae4, f0015b10/18 | 0x83, later RMW to 0x03 |
| DLL/DLM 0x800/0x801 | f0015aec–b08 | 0x2F / 0x00, each must read back (9600 baud with Linux's 7.2727 MHz uartclk) |
| LSR 0x805 | init, `uart_putc_raw` f0015b78, getc f0015c78 | TEMT (0x40) polled before and after each byte (≈6 ms timeout, result ignored); DR (0x01) |
| THR/RBR 0x800 | putc/getc | putc drains RX: 0x13 waits for 0x11 (XON/XOFF), other bytes dropped |
| SCR 0x807 | `st_gsc_parity` f000b480–b73c | plain latch: 0xAC written and read back; pgape/pgdpe stores of 0x88/0x66 must trap and leave 0xAC (§1.2) |

UART init runs at reset only if EEPROM[0x16D9] ≠ 'N' or EEPROM[0x1694] is
0xB0/0xB1 (chassis codes to RS-232), and again when the console path is the
UART.

### 4.4 RTC (0xF0109000, word)

| Access | Sites | Behaviour |
|---|---|---|
| read | f0015418/1c, f00154e4/e8 (PDC_TOD), `rtc_read` f0011694 | read until two successive values match (≤ 65 tries → −3, or 7 → −1) |
| write | f00154c8 | seconds only; rejects > 0xBC19137F or µs ≥ 10⁶ |
| selftest | `io_selftest` F_f0010c4c | value must change across a 1 s delay, else chassis 0x28400 and "Real Time Clock" in the failed list (boot continues) |

### 4.5 SCSI 53C710 (0xF0106000)

Driver images: ENTRY_INIT at f002c870, ENTRY_IO at f002f168 (copied to RAM
and run there). F_f0039dfc/F_f003a1b8/F_f003a560 are the Zalon (53C720, GSC
FW-SCSI) IODC, not LASI; their only LASI access is debug writes to
0xF0106134. Byte lanes: register = HPA + 0x100 + (little-endian offset XOR 3)
(ISTAT = +0x122, DSP = +0x12C–F with +0x12C written last to start SCRIPTS,
DMODE = +0x13B).

* Init: +0 = 0 (byte, unit reset), 10 ms; SCNTL1 |= 0x08 (SCSI bus reset) for
  30 µs, then 1 s; ISTAT = 0x40 then 0; DMODE = 0xC0; DCNTL = 0; SCNTL0 |=
  0x0C; SCID = 0x80; CTEST7 &= ~0x10; CTEST0 |= 0x40; SIEN |= 0xAD and DIEN
  |= 0x05, both read back.
* Self-checks: register R/W test with per-byte masks (table at f002e0a4,
  error 0x1000 + offset); DMA FIFO 16 × 4 lanes via CTEST6 with CTEST1 =
  0xF0/0x0F and CTEST2.DFP; BBCK decrementing DBC 0 → 0xFFFFFF; ADCK
  incrementing DNAD 0xEFFFFFFF → 0xF0000000; SODL → SBDL loopback with
  SSTAT0.PAR latching; a SCRIPTS fetch of 0x98080000/0xBABAFACE from RAM
  that must end with ISTAT.DIP, DSTAT.SIR and DSPS = 0xBABAFACE. Failures
  return −4 from INIT (no chassis code).
* `F_f001fdf8` writes 0xBBBBBBBB and a speed code (0x60A0 on the 715/64) to
  SCRATCH (+0x134) as debug tags; never read back.

### 4.6 LAN i82596 (0xF0107000, word stores only)

* +0x0 = 1 (reset), 20 µs; +0x4 PORT written twice (low halfword first,
  value in bits 15–0 of each) with self-test (1) and alt-SCP 0x17A2;
  +0x8 = 1 (channel attention). The ROM never reads 0xF0107xxx.
* Memory side: SCP at 0x17A0 with sysbus byte (+3) = 0x6C, ISCP 0x17B4, SCB
  0x17BC; the self-test result word must go 0xFFFFFFFF → 0; ISCP BUSY must
  clear; SCB status high nibble exactly 0xA and the command field back to 0;
  internal and external loopback must return a 60-byte frame. MAC from EEPROM
  0x16B4. Failures return −4/−5/−13 (no chassis code).
* QEMU's i82596 takes the PORT command from bits 7–0; the ROM needs bits 3–0
  = command and 31–4 = address (0x17A2 = alt-SCP at 0x17A0).

### 4.7 PS/2 (keyboard 0xF0108000, mouse 0xF0108100, bytes)

| Reg | Use |
|---|---|
| +0x0 | write 0 = reset; the ID register is never read |
| +0x8 CONTROL | R/W test 0x00/0xE3/0xA2/0x41 under mask 0xE3 (→ 0x104); also 3, 1, 0x20 written |
| +0x4 DATA | TX/RX |
| +0xC STATUS | RBNE 0x01, TBNE 0x02, TERR 0x04, PERR 0x08, CMPINTR 0x10 |

* Loopback test: send 0x00, 0xFF, 0xAA, 0x55 — STATUS & 0xF must be 1 after
  each (→ 0x204); a fifth byte 0xDE → STATUS = 3; then read the **4-deep RX
  FIFO** back in order (→ 0x304); CMPINTR test (→ 0x404). QEMU's one-byte
  loopback buffer fails this.
* Keyboard init: F5, F2 → FA AB 83/86, FF → FA AA, then ED and F4.
* **Boot-critical** (`early_init` F_f0000338 / f0000270): CONTROL = 3, IMR =
  0x04000000, DATA = 0; the looped-back byte must raise IRR bit 26 and LASI
  must write IO_EIR so that **EIRR bit 3** is set; otherwise the ROM jumps to
  `halt_forever` (silent).

### 4.8 Audio (Harmony, 0xF0104000, words)

* ID: (ID & 0x140000) == 0x140000; RESET +0x4; CNTL +0x8: bit 31 must read 0,
  walking ones read back in the low 18 bits (written without waiting for C);
  GAINCTL +0xC: 28 bits exact; PCURADD/RCURADD (+0x14/+0x1C) must be
  writable and read back; DSTATUS +0x20 idle: (DS & 0x202) == 0x202.
* DMA test: status must reach 0x80000303 then 0x80000202, IRR == 0x2000, the
  record buffer must equal the play buffer.
* PDC_IODC (F_f00141f8) on the sub-HPAs +0x40/+0x60/+0x70: writes CNTL = 0x29
  and needs ID == 0x00154000 or 0x00158000, else the module is absent.

### 4.9 FDC (0xF010A000) and parallel port (0xF0102000)

* FDC: DOR +0x40 (0 then 0x0C), MSR +0x8 must equal 0x80, data +0x4, FIFO
  +0x14/+0x18/+0x1C; DMA registers at **0xF010D000/0xF010D004** (`stw`,
  reached as HPA + 0x4000 − 0xFFC; the ERS appendix marks the page
  unassigned but its FDC chapter documents them); IRR must become 0x100000.
* LPT: 0xF0102000 (reset), registers 0xF0102800–807, DMA page 0xF0101000,
  DMA reset 0xF0103000; ModeCtl read-back and address/count/TC checks. The
  IRQ sub-test (IMR = 0x80) is unreachable (compares with 0xF0102000 but is
  passed 0xF0101000).

### 4.10 Second LASI (0xF0500000) — other models only

Probed with a byte read of **0xF041FFFE** (its I/O configuration byte: the
ERS documents offset 0x7FFFE from the LASI base 0xF0400000; the ROM uses
offset 0x1FFFE, presumably an alias). If that answers:
IORESET 0 then 0x1FF, IRR read, IMR = 0, clocks, **IAR = 0xFFFBE007** (EIRR
bit 7), AMR = 2, and the configuration bits (0xF041FFFE 0x80/40/20/10,
0xF041FFFF 08/04/02/01) select which of its units exist. On a 715/64 the read
must bus-error.

## 5. LASI external 8-bit bus: boot ROM, EEPROM, LED, system ID

LASI's "ROM space" (0xF0000000–0xF00FFFFF, LASI ERS app. A/B) holds four
things on the 715/64 **(ROM)**:

| Address | Device | Access by the ROM | Notes |
|---|---|---|---|
| 0xF0000000–0xF003F2A7 | boot ROM (this image, 258,728 bytes) | instruction fetch, `ldw`/`ldb` of tables and strings (dp = 0xF0024000) | executes in place; HPMC/TOC vector at 0xF0000000, reset at 0xF0000004 |
| 0xF00C0000–0xF00C1FFF | **EEPROM** (8 KB, byte wide) | `eeprom_rd_byte` f0013314 (`ldb`), `ee_read_word` f0013208 (`ldw`, offset must be 4-aligned), `eeprom_wr_byte` f0013320 / `ee_write_word` f0013220 / `eeprom_wr_word_abs` f001335c | writes are byte stores followed by **data polling**: re-read the byte until it equals the value written, giving up after `timeout_us(10000)` (10 ms) → error −3. A word write is four byte writes, MSB first. Highest offset used ≈ 0x1E0F. Layout: PDC/EEPROM pass and BOOTFLOW §8. |
| 0xF00E0000–0xF00EFFFF | **front-panel LED latch** (8 LEDs) | `chassis_code` f00122e0: `stb` to **0xF00EFFFF** of `~(code >> 12) & 0xFF` (active low) | Linux writes the same latch at LASI_HPA − 0x20000 = 0xF00E0000 for HVERSION 0x60A–0x60E, so the whole 64 KB page decodes. Write-only. |
| 0xF00FFFFC | **system ID / speed strap** | `ldw`; only bits 24–27 (value `(w >> 4) & 0xF`) are used, sometimes as `w & 0xF0` of the low byte | see 5.1 |

### 5.1 System ID word at 0xF00FFFFC

| (w >> 4) & 0xF | Model | `get_cpu_speed` f0015e24 | `board_model` f00158a8 | Other uses |
|---|---|---|---|---|
| **0x7** | **715/64** | 1 → 64 MHz: MTCV 0x09F06974, delay ×64 ticks/µs, page0 MEM_10MSEC (0x38C) = 640000 | 3 | SCSI IODC clock constant 64.0 (f0020044) |
| 0xB | 715/80 | 2 → 80 MHz, 800000 | 4 | 80.0 |
| 0xF | 715/100 | 3 → 100 MHz (delay ×96), 1000000 | 2 | 100.0 |
| 0xE | 715/100XC-class (FW-SCSI/graphics-slot variant) | 3 | 1 (other memory-slot map) | help text with `fwscsi_<4|3|2>`, `graphics_<4|3|2>` (`boot_admin` f00166b0); model byte 0x10 at c83 (f00034ac) |
| other | — | 3 | 1 | SCSI IODC returns −1 (no clock constant) |

FPGA: return **0x00000070** (any word whose bits 24–27 are 0x7) for a 715/64;
0xB0/0xF0 select 80/100 MHz. The value also fixes how fast CR16 must count
(§9).

## 6. WAX, EISA and graphics

### 6.1 WAX (0xF0200000)

The ROM never programs WAX's own registers (interrupt block 0xF0200000,
watchdog, HP-IB, timers, ID at 0xF0207000). 0xF0200000 is only probed. The
only traffic is HIL and the second RS-232 — and **none of it is protected
against an HPMC**.

| Register | R/W | Sites | Values / checks | Ref |
|---|---|---|---|---|
| 0xF0200000 | R | f00009dc (dp-probe), protected word reads via f0004bf8 / f00144d4 | value ignored — presence only | WAX ERS table 25 |
| 0xF0201000 | W word | **f0000054** (reset_entry, before any HPMC handling), f003965c | 0 = HIL assert reset | WAX ERS table 4 |
| 0xF0201C00 | W word | **f0000624** (`early_init`), f0039670 | 0 = HIL negate reset | idem |
| 0xF0201801 | W/R byte | f0039630 (W), f0039504/540/568, f00398d0, f0039b54 (R) | 8042 commands 5F, E0, F0, EB, 11, A2, A0, A6, 12, 5E; status: IBF (0x02) must clear within the timeout (else 0x401), OBF 0x01, replies need (st & 0xF0) = 0x40, keys (st & 0xC0) = 0x80 | WAX ERS 5.2.3 |
| 0xF0201800 | W/R byte | f00395e0 (W), f00398dc, f0039b7c (R) | data: AA/55 echo (else 0x405); keyboard-config reply bit 5 = 1 (0x403), KNP bit 4 = 0 (0x404); language code | WAX ERS 5.6 |
| 0xF0202000 | W byte | f00289b0 / f0028a94 | 0 = RS-232 #2 reset | WAX ERS table 1 |
| 0xF0202800–807 | R/W byte | same routine as the LASI UART test (image at f0028930) | scratch pattern 00, FF, AA, 55, 01…80; MCR \|= 0x14 loopback; IER patterns | 16550 |

HIL delays after assert/negate: 0x7D0 and 0xC350 (≈ 2 ms and 50 ms).

`io_selftest` (F_f0010c4c, run when EEPROM 0x1695 = 0, i.e. fastboot off)
always runs the built-in HIL (option 6 on 0xF0201000) and RS-232
(option 1000 on 0xF0202000) tests from ROM tables, without asking whether WAX
exists. HIL is also tried when PS/2 keyboard init fails or the stored keyboard
path is HIL.

### 6.2 EISA (WAX EISA space, I/O port n at 0xFC000000 + n)

Everything is gated by protected probes (reads of 0xFC000C80 and
0xFC100000); when they bus-error the ROM shows chassis 0x6C2EA then 0x6C2EF
and skips EISA cleanly (no message). Exception: with system-ID nibble 0xE
the self-test lists "EISA" as failed.

| Register | R/W | Sites | Values | Meaning |
|---|---|---|---|---|
| 0xC80 | R | f0000814 (dp-probe), f00033c8, PDC_IODC f0014344 | presence | system board ID |
| 0xC80–C83 | W then R | W f0003480–34c4, R f0010ac8–b6c | 0x22, 0xF0, 0xC0, then 0x10 (nibble E) or 0x00; must read back | ID latch ("HWP C0") |
| 0x461 | R/W | f0000830–848 | read, set bit 0, write, 2 reads, clear, write | EISA bus reset (RESDRV) pulse |
| chipset ports | W | F_f00033ec (f0003404–3598) | halfwords 0x26 ← 0x2008, 0x24 ← 0x0470/0x0480, 0x822 ← 0x0100, 0x824 ← 0x6F00, 0x830 ← 0x0090, 0x832/834 ← 0x0010, 0x826 ← 0x0002, 0x82E ← 0xF0E0, 0x820 ← 0x0400; bytes to 0x8F, 0x43, 0x4B, 0x70, 0x61, 8259 pair 0x20/0x21/0xA0/0xA1, 0x0D, 0xDA | WAX/82C350-class setup + standard PIC/PIT/NMI/DMA |
| nC80–nC83 (slot n = 1..15) | W 0xFF, then R | f0003b70–3c1c | 0xFF or bit 7 = empty; 0x7x = not ready (poll ≤ 10 ms) | slot ID |
| nC84 | W | f00126d0 (1), f00141ac (0) | board enable around the option-ROM scan | — |
| 0x40B, 0x4D6, 0x4D0/1, others from EEPROM config | W | F_f0003730 | only for slots configured in EEPROM | DMA ext. mode, ELCR |
| 0xFC010001 | W | f001255c / f0012574 | 0 / 1 (PDC proc 0x82, OS calls only) | lock control |
| 0xFC100000 + i·0x1000 (i < 0x400) | R/W | protected read f00033a0; `io_selftest` F_f00109f0 writes 0x676B, i, ~i & 0xFFFFF; PDC 0x82 option 3 | 20-bit entries | address-map RAM |
| 0xFC0C0000–0xFC0EF800 step 0x800 | R byte | F_f0012750 | 'p','a','0','0' + 4-byte ID | option-ROM scan, only for occupied slots |

### 6.3 Graphics (Artist at 0xF8000000; slots 0xF4000000, 0xF6000000, 0xFA000000)

**The built-in Artist has no option ROM: its STI image is inside the system
ROM at 0xF0024000.** F_f0004cfc (from `io_module_table_init`, and again in
PDC_IODC f00144d4/f0014544) does PDC_ADD_VALID on the HPA; if that word read
bus-errors it tries HPA | 0x300004 and, if that answers, uses 0xF0024000 as
the ROM base, then checks ROM byte 3 (1 or 3) and byte 0xB or 6. So on our
hardware a **word read of 0xF8000000 must bus-error and 0xF8300004 must
answer**; the slot addresses (0xF4/F6/FA000000 and +0x300004) must all
bus-error.

Registers the built-in STI code touches (offsets from 0xF8000000, from a
linear trace of the STI image; a few may be false positives): R/W
0x100000–0x10000C, 0x100020, 0x100040–0x10004C, 0x100060, 0x100080–88
(state save/restore); R 0x1007C0; W 0x100480, 0x1004A0, 0x1004C0, 0x100520,
0x100580, 0x1005A0, 0x100600, 0x100620, 0x100800/804/808/820, 0x100A04,
0x100B00; W 0x118000, R/W 0x118004–0x11801C, R 0x118020–34; R 0x300000
(poll until bit 0x01000000 clears = FIFO/busy), R/W 0x300104, W 0x300118, R
0x300200/208, R/W 0x300218, 0x300238/23C, W 0x300308; R 0x380000, R/W
0x380004 (tests 0x02000000; writes 0x100 and waits for it to self-clear, then
sets 0x01000000), R byte 0x380007; framebuffer at 0xF9000000 (16 MB). Names:
`artist_graphics_registers.html`, QEMU `hw/display/artist.c`. The STI
structure itself is the PDC/STI pass's subject.

## 7. Probed addresses that must bus-error on our 715/64

| Address (access) | Prober | If it answers |
|---|---|---|
| 0xF041FFFE (`ldb`) | `probe_io2` f0000880 | treated as a second LASI at 0xF0500000 and programmed; WAX probe skipped |
| 0xF0500000, 0xFFF88030, 0xFFF8C030, 0xFFF94030 (words) | `io_module_table_init` F_f0004b68 (table at RAM 0x66C) | phantom modules |
| 0xF1000000 (`ldb`) | `probe_io2` f0000a14 (only if WAX is absent) | LASI AMR := 0 |
| 0xF0200000 | `probe_io2` f00009dc | — (it should answer on a real 715/64; see 6.1) |
| 0xFC000C80, 0xFC100000, 0xFC001000 | `probe_eisa` f0000814, `eisa_config` F_f0003380, PDC_IODC | EISA bring-up (6.2) |
| 0xF8000000 (word), 0xF4000000/0xF6000000/0xFA000000 and +0x300004 | F_f0004cfc, PDC_IODC | slot treated as having an STI ROM |
| 0xFFFBB000 (word) | `st_hpmc_toc` f000b2b0 | **self-test failure** |
| 0xFFF8x008 (after FLEXID write) | `iodc_probe_device` | phantom FW-SCSI-class module |
| any address PDC_ADD_VALID is asked about | `pdc_add_valid` (IVA 0xF0011800) | OS sees a device |

Not real addresses (constants that look like them): 0xF7DFFFFF (CPU bit-test
pattern, F_f000588c), 0xF8000000 at f000de5c (FP status mask), 0xFC3FFE1F at
f000ea0c (FP register test mask).

**WAX decision for the FPGA.** WAX is not planned, but the ROM writes
0xF0201000 and 0xF0201C00 unconditionally (the first in `reset_entry`), and
`io_selftest` drives the HIL 8042 and RS-232 #2 unprotected. Options:
(a) decode 0xF0200000–0xF0207FFF as a stub that accepts writes, makes reads
of 0xF0200000 bus-error (so `probe_io2` sees no WAX and leaves AMR = 2) and
returns an idle 8042 status (IBF = 0) at 0xF0201801 — the self-test then
reports "HIL / RS232 2 failed" and waits for y/n unless fastboot is on
(EEPROM 0x1695 ≠ 0) or manufacturing mode (0x1694 = 0xB1); or (b) a minimal
8042 + 16550 model that passes (see the 8042 replies in 6.1). Without either,
the reset-time store HPMCs and the machine halts.

## 8. PA7100LC diagnose registers and instructions

Counts are over the code part of the ROM (the "diag" hits inside the font
data at 0xF0027000–0xF0028800 are data). Encodings: PCX-L ERS 8.3.9
(`romlib.DIAG_CODES`). Only MFCPU_C is used for DR0/DR8, MFCPU_T for DR25/27–29,
as the ERS requires.

### 8.1 Diagnose registers

| DR | Access (sites) | Values / bits | Meaning (PCX-L ERS 8.2) | FPGA |
|---|---|---|---|---|
| DR0 | MFCPU_C 83, MTCPU 66 | see 8.2 | CPU control/status: rev, cache-error flags (W1C), HPMC masks, STORE[0]/[1] scratch, PF_MASK, feature enables, ENDIAN, HIT/PARERR | **must**: rev field, W1C flags, STORE bits, ENDIAN (PDC_PSW), HIT/PARERR after diag cache reads; feature bits may be stored and ignored |
| DR1 | MTCPU 4 (`st_eir_itimer` f00061f0, f0006224, f0006264, f00062f8) | 0; compare − 0x100; −0x100 | writes the CR16 **counter** (`mtctl cr16` writes the compare) | **must** (interval-timer test) |
| DR8 | MTCPU 47 (TLB tests f000a0f0–f000b0fc, f0009580/95a4; `pdc_block_tlb` f0011f1c…f0012030) | normal 0x2000 / 0x3F80 (bit 18 = force-insert disabled); page pointer (bits 19–24) + LRU disable (25) for targeted inserts; lock-in/out (16, 17); block entry: 0x37C1 \| n<<1 insert, 0xBFC1 \| n<<1 delete (lock-out), bit 31 + bits 28–30 | UTLB diagnose control (ERS 6.3.1). Never read. | **must** for PDC_BLOCK_TLB (OSes use it) and the TLB self-tests; bit 26 must stay 0 |
| DR24 | MTCPU 3: reset f0000070 (0xE0), `dr24_set_htlb` f0009cc0, `pdc_tlb_setup` f0015310 | HTLB_BASE (bits 0–19) \| DCACHE_SIZE (bits 24–31) = 0xE0 (0xF8 if `cache_size` were 32 KB) | hardware TLB-miss table base; D-cache size config (0xE0 = 128 KB) | **must** if the HW TLB walker is implemented (HP-UX enables it through PDC_TLB); DCACHE_SIZE can be ignored |
| DR25 | MTCPU 11, MFCPU_T 1 (`soft_power_enable` f0013b74 reads bit 0) | reset **9** (ihtlb_dis + dhtlb_dis); shadow copy kept at **physical 0xE4** (page0_init writes 9); HTLB self-test f00095d8 clears bits 28/31, sets HTLB_MASK (7–19) and HTLB_CNTL 29–30; PDC_TLB_SETUP builds it from the OS's size/flags | bit 0 POWFAIL (r, 0 = power failing), 7–19 HTLB_MASK, 24–26 FP_DELAY (left 0 although the ERS asks for 001), 28 ihtlb_dis, 29 upd_cr28, 30 next_wd3, 31 dhtlb_dis | **must** (HW TLB walker control); bit 0 should read 1 |
| DR26 | — | — | debug | stub |
| DR27/28/29 | MTCPU 12 each, MFCPU_T 5 each (cache tests f00066e8, f000742c, f0007b08, f0007fe0, f00084d8) | even/odd instruction word, tag/steer/parity | L1 (on-chip, 1 KB) I-cache diagnose latches for RI1/WI1 | needed by the L1 I-cache self-test |

### 8.2 DR0 values

| When (site) | Value written | Decoded |
|---|---|---|
| reset `set_dr0` (f0000028), selftest1 start (f0004f10) | 0x03FF00D8 then per-rev edits | clear error flags 6/8/10/12–15, mask L2I/L2D/L1I HPMCs (7/9/11), SOU_EN, SHINT_EN, DHASH_EN, IHASH_EN; L1 I-cache, I-prefetch, I-streaming off, dual issue on |
| selftest2 start (f000b75c) | 0x03FF00FC | + IPREF_EN (26), L1ICACHE_EN (29) |
| normal operation (f0004f98, f000bdd0) | **0x00104AFC** | L1IHPMC_DIS (11), PF_MASK (17), ISTRM_EN (20), DUAL_DIS = 01 (no ldw/ldw, stw/stw pairs), SOU, SHINT, IPREF, DHASH, IHASH, L1ICACHE_EN; L2 cache HPMCs enabled |
| `set_dr0` per-rev edits (f0015cdc) | rev 0: SOU off, DUAL_DIS = 11 (single issue), ISTRM off; rev 1: ISTRM off; rev 2–10: as given; rev ≥ 11: DUAL_DIS = 00 | errata handling |
| dual-issue test f0006558 | DUAL_DIS = 3, 2, 1, 0 | skipped entirely when rev = 0 (f000b808) |
| expected-HPMC idiom (~25 sites) | bit 18 set before, cleared by the handler | STORE[1] |
| HPMC/TOC entry (f0002860, f0002bf0 / f0002ca4) | bit 16 set / cleared | STORE[0] = "PDC is inside its HPMC/TOC handler"; a second HPMC with it set is fatal (f0002728) |
| PDC_PSW f00151a8/f00151bc | bit 23 read/written | default endianness for traps |

The revision field (bits 0–5) is also returned to the OS by
PDC_MODEL_VERSIONS (`pdc_model_versions` f0014dfc). Choosing rev 0 for a
single-issue FPGA CPU makes the ROM force single issue, skip the dual-issue
self-test and clear MIOC_CONTROL bit 14; whether HP-UX treats rev 0 7100LCs
specially is not known.

### 8.3 Other diagnose instructions

| Instruction | Count | Where | Purpose | FPGA |
|---|---|---|---|---|
| TOC_EN / TOC_DIS | 6 / 1 | TOC_EN: reset f00002c8, `halt_forever` f0001aec, `mioc_status_check_toc_en` f0002ce0, `st_hpmc_toc` f000b2e8/b34c; TOC_DIS: `hpmc_toc_entry` f00026ec | mask/unmask TOC (a taken TOC or broadcast reset sets the mask) | must (TOC test, §2) |
| SHDW_GR / GR_SHDW | 3 / 1 | `hpmc_probe_forward` f00028e0, f00045dc, shadow test f0006340 | restore/save GR1,8,9,16,17,24,25 shadows | must (every expected-HPMC forward uses SHDW_GR) |
| WDD/RDD, WDT/RDT, SET_TAG | 54/17, 40/10, 77 | `cache_as_ram_init` f0002cf0 (tags RPN 0 for 16 KB of D-cache before memory works), D-cache tests f00066e8, f0006df8–f0007214, f0007b08, f0008098, f00084d8, f0009cf4, f000bc68 | off-chip D-cache data/tag RAM access by real address | needed to pass the cache self-tests (see below) |
| WI2D/RI2D, WI2T/RI2T | 42/13, 37/8 | I-cache tests (same functions), f000bbd8 | off-chip I-cache data/tag RAM | idem |
| WI1/RI1 (+DR27–29) | 12/7 | f00066e8, f000742c, f0007b08, f0007fe0, f00084d8 | on-chip 1 KB L1 I-cache | idem |
| RDTLB | 0 | — | — | not needed |

What the cache self-tests assume **(ROM)**: `cache_size` (f00158e0) is a
constant **0x20000**: a 128 KB direct-mapped off-chip I-cache and a 128 KB
direct-mapped D-cache (DR24 = 0xE0 agrees), 32-byte lines, tags = 20-bit RPN
(bits 0–19) + dirty (20) + parity bits (21–24) in the RDT/RI2T format of PCX-L
ERS fig. 8.5. The tests walk every doubleword of each array with
address-in-data and walking-one patterns, check that a store leaves the line
tagged with the right RPN and dirty, that `fdc` cleans it, that DR0 HIT
(bit 30) is set and PARERR (bit 31) clear after a diagnose read, and that
loading the same index + 0x20000 evicts the line (f000bc68). An FPGA
cache that is smaller, set-associative or without diagnose access fails
selftest1/selftest2 (see BOOTFLOW §4/§7).

**Code is executed straight out of the I-cache.** `F_f000786c` → `f00078a8`
copies a ROM range word by word into the off-chip I-cache with `WI2D` +
`SET_TAG` + `WI2T` at real address r24 (0 in every caller), the tag being
the RPN of that address with bit 21 (dirty parity) set; the caller then
branches to address 0 (`bv r0(r0)`). The memory sizer (`mem_size_all`:
0xF000C800–0xF000CB8C or 0xF000CB90–0xF000CE9C), the scrub loop
(0xF000D1D8–0xF000D2C8), `st_gsc_parity`'s tail (0xF000B520–0xF000B750) and
several CPU tests run this way, before or while main memory is unusable.
`f0007894` → `f00078ec` removes the lines afterwards. So diagnose-written
I-cache lines must hit for instruction fetch exactly like lines filled from
memory, with no memory access behind them (answers BOOTFLOW §2.12's open
question).

## 9. Control and space registers

| Register | Use in the ROM | Implementation-specific points |
|---|---|---|
| CR16 (`itmr`) | 100 `mfctl` (delays: `delay_us` f0015dc0 = r26 × 64/80/96 ticks; `timeout_us` f00157a4; `elapsed_10ms` f0015e50; EEPROM polling), 8 `mtctl` (compare) | must count at the **system-ID clock** (64 MHz for ID 7) — page0 MEM_10MSEC (0x38C) = 640000/800000/1000000 is handed to the OS; `mtctl` writes the compare, DR1 writes the counter; compare match sets EIRR bit 0 (`st_eir_itimer`) |
| CR15 EIEM, CR23 EIRR | reset: EIEM = 0, EIRR = all ones written (clear); tests write single bits | EIRR written with 1s clears those bits; IO_EIR sets bits; LASI uses bit 3 (IAR 0xFFFBE003), second LASI bit 7 |
| CR14 IVA | 63 `mtctl`: 0xF0002000 (reset/boot), 0xF0009000 (self-test vectors: entry n flips dp bit n, entry 1 = expected HPMC), 0xF0011800 (PDC_ADD_VALID probes) | — |
| CR17/18 IIASQ/IIAOQ, CR22 IPSW | `rfi` used 19× to switch PSW (Q/I/D/P) and to enter virtual mode in TLB/HTLB tests; the expected-HPMC handler advances IIAOQ by 4 to skip the faulting instruction | the queues must be valid after HPMC (PSW Q was set) |
| CR19 IIR, CR20 ISR, CR21 IOR | read in trap handlers / PIM | — |
| CR10 CCR | 0xC0 written to enable the FPU (f000ddb4, `pdc_coproc_cfg` f00123f4), 0 at IPL launch (f0001a18) | bits 24–25 must gate the FP unit |
| CR0 RCTR | zeroed at IPL launch; recovery-counter trap test | — |
| CR8/9/12/13 PIDR1–4 | zeroed at IPL launch; PIDR1 set in the HTLB test | protection-ID checking in TLB tests |
| CR24–31 TR0–7 | heavy scratch use: tr0 saved stack, tr3–tr7 in self-tests, **tr7 = MIOC_STATUS copy** from the expected-HPMC handler | plain registers |
| SR0–SR7 | `mem_size_all` keeps per-size block bitmaps in **sr0–sr7** (16 bits, read back with `mfsp` and shifted) because RAM is not usable yet; sr1 used for virtual-mode tests | space registers must hold at least 16 bits and read back exactly |
| PSW | `ssm`/`rsm` 1 (I), 2 (D), 4 (P), 8 (Q), 0x1F; `mtsm 9` | — |

## 10. Read-back checklist — what our hardware must return

Things the ROM compares against, roughly in boot order. Items marked
**fatal** stop the boot or fail a self-test; the rest change behaviour.

| # | Where | Must return / do | If not |
|---|---|---|---|
| 1 | 0xF00FFFFC | bits 24–27 = 0x7 (715/64) | wrong MTCV/LASI clock constants, delays, model (§5.1) |
| 2 | stores at reset (MEM_HPA+0x80/0xC0, LASI regs, WAX HIL, LED, 0xFFFC0020) | complete without HPMC — even WAX stores when WAX is not built (drop them) | **fatal**: HPMC before the handler is usable |
| 3 | absent I/O (0xF041FFFE, 0xF0200000 if no WAX, 0xF1000000, 0xFC000C80, 0xFFFBB000, every HPA in the probe table) | **HPMC**, MIOC_STATUS = 0x02, resumable | phantom devices; **fatal** in `st_hpmc_toc` |
| 4 | MIOC_STATUS & 0x7F | 0 when idle; exact codes 0x02/0x08/0x10/0x20/0x40 per §1.2–1.6; clear on write-back | self-test / memory test failures |
| 5 | MIOC_CONTROL | reads back; pgape/pgdpe one-shot errors | `st_gsc_parity` fails |
| 6 | MEM_HPA+0xD0 | read/write (0xAAAAAAAA) | `st_gsc_parity` fails |
| 7 | IO_EIR → EIRR | exact bit, interrupt within ~10 instructions when enabled | `st_eir_eirr`, `st_eir_itimer` fail |
| 8 | IO_COMMAND = 5 | TOC through 0xF0000000 with status 0x10; other values ignored | `st_hpmc_toc` fails |
| 9 | CR16 / compare / DR1 | count at 64 MHz, EIRR bit 0 on match, DR1 sets the counter | timer test fails; OS clock wrong |
| 10 | DR0 | rev field, W1C error flags, STORE bits, HIT/PARERR after cache diag reads | probes and cache tests break |
| 11 | cache diagnose ops | 128 KB I + 128 KB D direct-mapped arrays, 32-byte lines, executable diag-written I-cache lines | **fatal** (self-tests; code-in-cache routines) |
| 12 | memory blocks | alias at their size; empty enabled block ≠ pattern, no HPMC; unconfigured address → HPMC 0x02 | wrong size, "memory card failed", memory test |
| 13 | ECC registers 0xC4–0xE0 | §1.6 behaviour | memory ECC tests fail |
| 14 | EEPROM | byte read-back equal to the value written within 10 ms | **fatal** (0x23003) |
| 15 | sr0–sr7 | keep ≥ 16 bits | memory sizing wrong |
| 16 | LASI IAR | power-up 0xFFFBE003; the PS/2 loopback byte must raise IRR bit 26 and EIRR bit 3 by f0000270 | **fatal, silent** (`halt_forever`) |
| 17 | LASI IMR/AMR/IPR | IMR and AMR read back all written bits; IPR latches while masked | SCSI/LAN init errors |
| 18 | LASI UART | IIR = 0xC1 after FCR = 7; DLL/DLM read back; TEMT within ~6 ms; SCR latch | no serial console |
| 19 | LASI RTC | changes within 1 s | "Real Time Clock" failed (fastboot off) |
| 20 | PS/2 | CONTROL R/W under mask 0xE3, 4-deep loopback FIFO, STATUS codes (4.7) | keyboard port fails self-test |
| 21 | SCSI/LAN/audio/FDC | read-backs in 4.5–4.9 | device unusable for boot |
| 22 | WAX | writes to 0xF0201000/0xF0201C00 absorbed; HIL/RS-232 #2 per 6.1 or fastboot | **fatal** HPMC at reset; y/n prompt in self-test |
| 23 | graphics | word read of 0xF8000000 bus-errors, 0xF8300004 answers, slot HPAs bus-error | no graphics console / phantom slots |

## 11. What is still unknown about the MIOC

1. **MIOC_CONTROL bits 0–13, 15, 16.** Only the reset constant 0xCDFA8000
   is known (bit 14 is an errata switch for rev-0 CPUs, 15 is deliberately
   cleared). The 7300LC names in that range (dwmode, drdw, rpen, dma_noecc,
   lpmc_en, dma_nocache, fast_memory, lopowhilat) may or may not apply.
2. **MTCV fields other than refresh and bit 5.** Bit 4 is always 1; bits 0–3
   and 6 are 0 in all three constants; bits 22–31 are DRAM timing (likely five
   2-bit counts) whose split and meaning are unknown. Bit 5 is "ECC
   generate/check"; whether it controls generation, checking or both
   separately is not distinguishable from the ROM.
3. **MIOC_STATUS**: exact meaning of bit 29 (0x04, "pmae" by analogy, but
   unconfigured-memory accesses report bit 30) and of bits 0–24 (the 7300LC
   keeps gscdiv/ponstat there; a power-on-vs-broadcast-reset bit would be
   useful but the ROM never reads one). Whether writing 1 to a clear bit sets
   it (7300LC "toggle") is untested by the ROM.
4. **ECC details**: HP's check-bit matrix (only ECC(0) = 0x33, ECC(~0) = 0xCC,
   ECC(0x01234567FEDCBA98) = 0x55 and the error classes in §1.6 are known);
   what MDERRADD bit 29 means; the upper three bytes of 0xD8; the byte order of
   0xDC for doublewords 1–3; logging priority when several errors occur (the
   7300LC keeps the "least recent, most severe"); whether 0xD0/0xD4 also latch
   on DMA reads.
5. **Unused offsets**: whether anything lives at 0x000–0x07C, 0x088–0x0BC,
   0x0C8–0x0CC, 0x0E4–0x0FC or ≥ 0x180 (the 7300LC has DMA/DIO error address,
   GSC timeout, a DMA memory limit (HIDMAMEM) and comparator test registers
   there). The ROM never programs a DMA limit or a GSC timeout, so the 7100LC
   either has none or fixed ones; the I/O timeout length is unknown.
6. **dram_tech encodings** in terms of DRAM row/column bits, and exactly which
   address bit a 256 MB block drops under tech 4 (the ROM only shows that it
   aliases at 128 MB or 64 MB).
7. **Readback** of MEMCOMP/MEMMASK/MTCV/0xC4 (never read by the ROM).
8. **Enabled comparator with no DRAM**: real hardware returns whatever the
   floating bus holds without an error; we assume "anything but the last
   pattern, no HPMC".
9. **DMA side**: coherence, buffering and error reporting for LASI/WAX bus
   masters (status bit 31 is an LPMC source, probably the DMA error) — nothing
   in the ROM exercises it.
10. **TOC from the front-panel/TOC pin**, power-fail (DR25 bit 0) interplay and
    FLEXID bits 19 and 31.

## 12. Notes on the tools

* `romlib.resolve()` forgets registers at every branch target; a
  function-wide pass (as in `hwmap_trace.py`) resolves base registers that
  live across loops. It also computes `,ma` (post-modify) stores as base + disp
  (the 16 MEMMASK writes show up as `MEM_HPA+0x144` ×16); `,ma` should use the
  unmodified base. `depwi` on a known constant (the reset MIOC_CONTROL value)
  is not folded.
* Data inside the code range produces phantom hits: the font at
  0xF0027000–0xF0028800 (fake `diag`), the STI header at 0xF0024000 and the
  keymaps near 0xF00390D0 (fake `BROADCAST+0x3exxx`), small tables like
  f000c5bc. A data-range list in romlib would clean `diag.tsv`/`hwaccess.tsv`.
* Register names worth adding to `romlib.REGIONS`: MEM_HPA 0x80 MIOC_CONTROL,
  0x84 MIOC_STATUS, 0xC0 MTCV, 0xC4 M_WRT_CHK, 0xD0 M_ERR0, 0xD4 M_ERR1,
  0xD8 M_RD_CHK, 0xDC M_LINE_CHK, 0xE0 MDERRADD, 0x100+ MEMCOMP, 0x140+
  MEMMASK; CPU_HPA 0x0 IO_EIR, 0x30 IO_COMMAND; BROADCAST 0x20 FLEXID, 0x30
  COMMAND; LASI 0xB000–0xB00C CLK_40/CLK_20/CLK_AUD0/CLK_AUD1; regions
  EEPROM 0xF00C0000 (8 KB), LED 0xF00E0000 (64 KB), SYSID 0xF00FFFFC, LASI2
  0xF0500000 and its config bytes 0xF041FFFE/F.
