# 02 — Chip-level documentation coverage review (HP 9000/715/64, /80, /100 "Mirage")

Status: research review, no RTL. Date: 2026-10-07.
Target: MiSTer / DE10-Nano (Cyclone V), Quartus 17.0, SystemVerilog.
Scope: for every block we must implement in RTL, is there enough register-level documentation, and what is missing.

Reference corpus: `docs/reference/txt/*.txt` (`pdftotext -layout` extracts), originals in `docs/reference/pdf/` (+ `pdf/arch/`, `pdf/chips/`).
Fallback sources checked: QEMU 11.1.1 (`/home/dani/src/qemu-11.1.1`, including `roms/seabios-hppa`) and Linux (`/home/dani/repos/Linux-Kernel_MiSTer`).

Citation conventions:

* `PCXL §6.3.1 p42` = PA7100LC ERS section and printed page. **The PCXL PDF and its txt are in reverse page order**: printed page N is PDF page `100 − N` (PDF p1 = printed p99, PDF p104 = cover). Line numbers into `PCXL_ers.txt` are therefore not useful; use printed pages.
* `PCXL2 p13-9 (PDF p195)` = PA7300LC ERS printed page and PDF page.
* `LASI §14.2 (txt L3845, PDF p97)` = LASI ERS section, line in `Lasi_ers.txt`, PDF page. The LASI txt garbles every bit-field diagram (register boxes come out as mojibake); always read those from the PDF.
* `PA11 p2-17` = PA-RISC 1.1 Architecture and Instruction Set Reference Manual, 3rd ed.

---

## 1. Executive summary

| Block | Verdict | One-line reason |
|---|---|---|
| PA7100LC integer core, PSW, CRs, space regs, interruptions, TLB/protection semantics | **Good** | PA-RISC 1.1 3rd edition (Feb 1994) is the exact architecture level the PA7100LC implements. |
| PA7100LC implementation specifics (TLB 64+8 BTLB, HW TLB miss handler, diagnose regs DR0/1/8/24/25/27-29, diag instruction encodings, shadow regs, FP trap rules, reset vector) | **Good** | PCXL ERS ch.5-9 gives register-level detail. |
| PA7100LC implementation-specific *instructions* (MAX-1 halfword ops, fast TLB inserts, endian-override LDW/STW) | **Partial → Good with PCXL2** | PCXL ERS refers to an "Appendix" that is **missing from the public version**; PCXL2 ERS ch.13 documents the same instructions with encodings and pseudo-code; PA 2.0 manual has HADD/HSUB/HAVG/HSHLADD/HSHRADD. QEMU decodes all of them. |
| PA7100LC MIOC (memory controller, I/O controller, CPU/MIOC HPA registers, error registers, GSC timeout) | **Missing** | PCXL ERS repeatedly says "see the MIOC ERS" — not in the corpus. PCXL2 ERS ch.7/8/11 documents the *PA7300LC* MIOC, which HP explicitly says has a changed programming model. Only usable as a template. |
| GSC bus protocol | **Partial** | No GSC spec. PCXL2 ch.8 and LASI ch.15 describe signals, cycle types, arbitration, reset and error behaviour well enough for an internal bus; exact timing/XQL/split rules missing. |
| LASI glue (interrupt controller, IAR/ICR, AMR, error log, version, I/O reset, power/LED, clocks, address decode, config) | **Good** | LASI ERS ch.12-18 + appendices. |
| LASI parallel port + its EISA-style DMA | **Good** | Full register map and behaviour. |
| LASI RS-232 (16550A) | **Good** | Register table + deltas from NS16550A; 16550 behaviour is public knowledge. |
| LASI PS/2 ×2 | **Good** | Complete. |
| LASI RTC | **Good** | Single 32-bit seconds counter. |
| LASI Harmony audio (+TTY/ISDN telephony) | **Good** (audio) / Partial (telephony) | Register-level spec present; CS4215 codec data sheet missing but not needed if we emulate the codec behind Harmony's register semantics. |
| LASI 53C710 SCSI core | **Wrapper only** | LASI gives offsets and wrapper; the 53C710 register semantics and SCRIPTS processor need the **NCR 53C710 Data Manual (missing)**. QEMU `ncr53c710.c` is a complete fallback. |
| LASI 82596CA LAN core | **Good** | LASI wrapper + full 82596CA data sheet (SCP/ISCP/SCB/commands/RFD/RBD). Intel 82596 User's Manual missing but not essential. |
| LASI floppy (WD37C65C) | **Partial** | LASI FIFO/DMA wrapper documented; FDC is an external chip, data sheet missing (public 765/82077-class knowledge suffices). Low priority. |
| LASI flash/PDC ROM bus | **Good** (decode) | Address map and AM29F010 usage documented; flash command set is public. |
| Mirage board-specific registers (LED at 0xF00E_0000, EISA config EEPROM at 0xF00C_0400, stable storage, straps) | **Missing** | LASI ERS is 712 (Gecko)-centric. Only Linux `lasi.c` / `eisa.c` reveal these addresses. |
| WAX (HIL, second RS-232, EISA bridge) — present on all 715/64-100 | **Good** (ASIC) / Partial (HIL 8042 firmware, EISA chipset) | WAX ERS rev 1.0 is a scanned PDF but complete (no redaction found); the HIL controller's internal 8042 firmware and the external TI EISA chips are undocumented. |
| Artist 8-plane graphics | **Poor** | Only a 30-line reverse-engineered register list. QEMU `artist.c` + Linux `stifb.c` (NGLE register set) are the real sources; timing/RAMDAC/VRAM organisation are reverse-engineered, not documented. |
| STI ROM for Artist | **Spec good, content missing** | STI spec present; HP's Artist STI ROM image is not in the corpus. SeaBIOS-hppa has an LGPL STI implementation for Artist. |
| PDC / IODC firmware interface | see §7 | |

Bottom line: the CPU core and LASI are implementable from the corpus. The three serious holes are **(1) the PA7100LC MIOC register map**, **(2) the NCR 53C710 data manual**, and **(3) any real Artist documentation**. (2) and (3) are covered by QEMU models; (1) only matters if we must run HP's original PDC ROM — with a replacement firmware (SeaBIOS-hppa-derived) we define the MIOC model ourselves.

---

## 2. System context: what is on a 715/64-100

From the auto-generated inventory of a real 715/64 in `qemu-11.1.1/roms/seabios-hppa/src/parisc/715_64.h` (header comment lists the PDC device walk), cross-checked with LASI Appendix A/B (txt L4319-4596, PDF p111-117) and Linux `arch/parisc/kernel/hardware.c`:

| # | Module | HPA | hversion / sversion | Notes |
|---|---|---|---|---|
| 1 | Mirage Jr GSC Builtin Graphics (Artist) | 0xF800_0000 | hv 0x12 / sv 0x85 | Artist register space 0xF810_0000+, framebuffer 0xF900_0000 (QEMU `hppa_hardware.h`: `LASI_GFX_HPA`, `ARTIST_FB_ADDR`) |
| 2 | Mirage Jr Core BA (LASI) | 0xF010_0000 | hv 0x28 / sv 0x81 | LASI 2 MB window starts at 0xF000_0000 (ROM half) |
| 3 | Core SCSI (53C710) | 0xF010_6000 | sv 0x82 | |
| 4 | Core LAN (82596) | 0xF010_7000 | sv 0x8A | |
| 5 | Core RS-232 | 0xF010_5000 | sv 0x8C | |
| 6 | Core Centronics | 0xF010_2000 | sv 0x74 | |
| 7 | Audio (Harmony) | 0xF010_4000 | sv 0x7B | |
| 8 | Core PC Floppy | 0xF010_A000 | sv 0x83 | optional drive |
| 9-10 | PS/2 kbd / mouse | 0xF010_8000 / 0xF010_8100 | sv 0x84 | |
| 11 | Wax EISA BA | 0xFC00_0000 | hv 0x28 / sv 0x90 | EISA slot bridge |
| 12 | Wax BA | 0xF020_0000 | hv 0x12 / sv 0x8E | |
| 13 | Wax HIL | 0xF020_1000 | sv 0x73 | |
| 14 | Wax RS-232 (port B) | 0xF020_2000 | sv 0x8C | |
| 15 | CPU "Mirage Jr (715/64)" | 0xFFFB_E000 | hv 0x60A / sv 0x4 | PA7100LC processor HPA (EIR at +0x000, COMMAND at +0x030) |
| 16 | Memory | 0xFFFB_F000 | hv 0x4A / sv 0x9 | PA7100LC MIOC HPA |

Board hversions (Linux `hardware.c` L237-251): 0x60A Mirage Jr (715/64), 0x619 Mirage 80 (715/80), 0x60B Mirage 100 (715/100), 0x60C Mirage 100+ (715/100XC). Linux maps CPU hversion range 0x600-0x61F to `pcxl` (PA7100LC) (`hardware.c` L1303).

System address map (LASI Appendix B, txt L4550-4596, PDF p117): memory 0x0000_0000-0xEFFF_FFFF; LASI ROM 0xF000_0000-0xF00F_FFFF; LASI I/O 0xF010_0000-0xF01F_FFFF; WAX I/O 0xF020_0000; second LASI 0xF040_0000; IODC search space 0xF100_0000-0xF3FF_FFFF; second Artist 0xF400_0000; Artist 0xF800_0000-0xF9FF_FFFF; WAX EISA 0xFC00_0000-0xFFBF_FFFF; reserved-must-bus-error page 0xFFFB_B000; CPU 0xFFFB_E000; MIOC 0xFFFB_F000; local/global broadcast 0xFFFC_0000-0xFFFF_FFFF.

**Mirage-specific detail not in any HP doc we have:** Linux `drivers/parisc/lasi.c` L124-130 puts the front-panel LED shift register for 0x60A/0x60B/0x60C at `lasi_hpa − 0x20000` (= 0xF00E_0000, i.e. on LASI's external 8-bit bus), unlike Gecko which uses the LASI power-control register (+0xC000). Protocol (data bit 0, strobe bit 1) in `drivers/parisc/led.c` L274-299. Linux `drivers/parisc/eisa.c` L52 also places the Mirage EISA-configuration EEPROM at 0xF00C_0400 (8-bit bus). Where PDC stable storage lives on Mirage (flash sector vs. that EEPROM) is undocumented.

Memory (715 Service Handbook): 72-pin ECC SIMMs, 70 ns, 32-256 MB in 8 slots = 4 pairs (A/B), equal sizes per pair, Pair 3 mapped first at address 0 (txt L476-484, L2852-2907). PIM address-assignment table (L2757-2800): F000_0000-F7FF_FFFF motherboard, F800_0000-FBFF_FFFF graphics, FC00_0000-FFBF_DFFF EISA, FFFB_E000 CPU, FFFB_F000+ motherboard.

---

## 3. CPU: PA7100LC (PCX-L)

### 3.1 Document identification

| Doc | Identity | Use |
|---|---|---|
| `PCXL_ers.txt` / `pdf/PCXL_ers.pdf` | "PA7100LC ERS", **Public version 1.00, March 30 1999**, 104 PDF pages: cover + iv + 99 printed pages, chapters 1-9 | Primary PCX-L implementation spec. Public version strips the Appendix (instruction formats for MAX-1, fast TLB inserts, endian-override loads/stores, U-bit), the "Start-Up Strategy" section, the debug chapter (DR26), and the separate MIOC ERS. |
| `Pcxl2_ers.txt` | "PA7300LC ERS Version 1.0", March 18 1996 (some chapters dated Aug 1995 / Mar 1996), 206 PDF pages | Successor chip. Ch.1.2 lists differences from PA7100LC; ch.13 documents the implementation-specific instructions shared with PA7100LC; ch.7/8/11 document the PA7300LC MIOC/GSC (template for PCX-L). |
| `Pa11_acd.txt` | "PA-RISC 1.1 Architecture and Instruction Set Reference Manual", HP P/N 09740-90039, **Third Edition, February 1994** | Full ISA: integer, FP coprocessor (ch.6), system control, interruptions (ch.4), virtual addressing/TLB/protection (ch.3), PSW/CRs (ch.2), opcode maps (App. C/D). PCX-L ERS §1.1 states the CPU implements "PA-RISC1.1 Edition 3" — this is the exact edition. Does **not** contain MAX-1 (`grep HADD` = 0 hits) and does not define the I/O architecture register set beyond EIRR/IO_EIR. |
| `parisc2.0.txt` | PA-RISC 2.0 Architecture | Contains HADD/HSUB/HAVG/HSHLADD/HSHRADD (L6913-7118, opcode table L14362+), i.e. MAX-1 as a subset of MAX-2. Opcode 3E instructions (PERMH, MIXH, MIXW, HSHL, HSHR) are MAX-2 only and must **not** be implemented. |

### 3.2 Coverage table (CPU sub-blocks)

| Block | Primary doc | Register-level coverage | Gaps | Fallback reference |
|---|---|---|---|---|
| Integer ISA, PSW, CR0-31, SR0-7, nullification, branches, interruptions (groups 1-4, priorities, IIAQ/IPSW/ISR/IOR/IIR) | PA11 ch.2, 4, 5, App. C/D | **Yes** | PCX-L reserved/non-existent bits: PCXL §5.4 p37 (SAR[0:26], CCR[0:23], IPSW[0:4,24:26], IVA[22:31], PID[0:15], SR1-7[0:15] read as zero; ISR[0:15] zero → 16-bit space IDs, "Level 1, 48-bit virtual address", PCXL §1.3 p3). | QEMU `target/hppa/translate.c`, `insns.decode` |
| Trap numbering on PCX-L | PCXL §2.2.8 p7 | Yes | Trap 18 replaced by 26/27/28 (per PA11 2nd ed). | Linux `arch/parisc/kernel/traps.c` L677-703 |
| Superscalar bundling (2-way) | PCXL ch.3 p11-14 | Yes (classes/rules) | Performance-only; functionally transparent. An RTL can start single-issue (DR0.DUAL_DIS exists as an architected-visible knob). | — |
| Pipeline (F/I/B/A/R, freezes, penalties) | PCXL ch.5 p23-37 | Yes (behavioural) | Detailed pipeline diagram "included as an appendix" — missing. Not needed for a re-implementation. | — |
| On-chip L1 I-cache (1 KB, direct mapped, 2-word lines, VA[22:31] index, predecoded steering bits) | PCXL §4.5 p16, §8.2.7-8.2.9 p79-81, §8.3.7 p89 | Yes, incl. diag access via DR27/28/29 + RI1/WI1 | Must be emulated only to the extent PDC/HP-UX self-test use RI1/WI1. Replacement firmware need not touch it. | — |
| Off-chip combined cache controller (8 KB-2 MB, direct mapped, 32-B lines, copy-back, virtual index with SID hash) | PCXL §1.3 p3, §4.5-4.6 p16-18 (hash functions), §8.3.4-8.3.6 p84-88 (RDD/RDT/WDD/WDT/RI2D/RI2T/WI2D/WI2T/SET_TAG), §9.3-9.4 | Yes for software-visible behaviour (hash, diag tag format Fig 8.5 p85, parity) | SRAM interface timing irrelevant for FPGA. Cache *size* reported to OS via PDC_CACHE; the hashing (DR0.IHASH_EN/DHASH_EN) affects which lines alias — Linux explicitly disables hashing on PCX-L (`pacache.S` L1314-1321). | Linux `pacache.S`, `cache.c` L280 |
| TLB: 64-entry fully-assoc unified, 4 KB pages, 8 block entries (128-16 K pages), 1-entry ITLB LAB, U-bit, lock-in/lock-out, NUR replacement | PCXL ch.6 p39-55 | **Yes** — DR8 layout p42-43, BTLB insertion recipe and mask table p44-46, replacement algorithm §6.2 p41, power-on "all entries locked out" §6.3.3/6.5 p43/48 | None significant. Note BTLB is only reachable through DR8 + architected inserts (PDC_BLOCK_TLB implements this). | QEMU `mem_helper.c` (QEMU models PA7300LC BTLB via `diag_btlb` firmware hook, not the DR8 mechanism) |
| Hardware TLB miss handler (PDIR hash walk, CR28 hint) | PCXL §6.7 p49-54 | Yes: hash pseudo-code p50, hw-visible table format p51, DR24/DR25 p52-53, CR28 table p52 | ITLB CR28 unreliable (post-silicon bug, §2.1.6 p6). DR25.I/D (disable bits) are *not* set by reset — PDC must set them. An RTL may implement the handler as disabled-only if OS never enables it (Linux does not; HP-UX 10.20 **may** — unverified). | — |
| Fast TLB inserts IITLBAF/IITLBPF/IDTLBAF/IDTLBPF | PCXL §6.8 p55 (names, penalties) → formats in missing Appendix | **Via PCXL2** p13-9 (PDF p195): major 01, minor 0x10/0x11/0x50/0x51, restrictions | Encodings assumed identical on PA7100LC (PCXL2 says "PA7300LC also implements several fast TLB insertion instructions"; QEMU comment "pcxl and pcxl2 Fast TLB Insert"). QEMU also accepts a non-standard HP-UX 9 encoding (b=01001). | QEMU `insns.decode` L165-168 |
| Shadow registers GR1,8,9,16,17,24,25 + RFIR | PCXL §2.2.2 p7, §5.3.5 p30, §8.3.3 p83 (SHDW_GR/GR_SHDW diag codes 0xD0/0xD2) | Yes | Shadow registers and RFIR are architected in PA11 itself (§"Shadow Registers" txt L1020, RFIR p5-140 txt L8883, usage note p4-17); PCX-L adds only the diag move instructions. | QEMU `rfi_r`, `getshadowregs` |
| Interruptions: HPMC/TOC vector 0xF000_0000, LPMC → IVA+5*32, group-4 "taken before", TOC mask bit set by TOC/broadcast reset, TOC_EN/TOC_DIS diag codes 0x50/0x52 | PCXL §5.3.5 p29-31, §8.3.3 p83, ch.9 p95-99 | Yes | PIM layout requirements ch.9.8 p98-99 refer to "MIOC ERS" for bus check words. | — |
| External interrupts EIRR (CR23)/EIEM (CR15), IO_EIR | PA11 p2-17 (CR23 EIRR, IO_EIR), p2-15 (CR15 EIEM, CR16 interval timer), ch.4 "Interruptions" p4-13ff | Yes architecturally | Physical location: processor HPA 0xFFFB_E000 (`EIR` at +0, from PCXL2 Table 5 p11-5 and LASI IAR power-up value 0xFFFBE003, LASI §14.2). PCX-L-specific write semantics (full-word only) only documented for PCXL2 §8.9 p8-19. | QEMU `hw/hppa/machine.c` (CPU HPA emulated at 0xFFFB_0000, not 0xFFFB_E000!) |
| Interval timer CR16 | PA11 p2-15 ("Interval Timer") | Yes architecturally | Count rate not stated in PCXL ERS; OS uses PAGE0 `mem_10msec` from PDC. DR1 writes the counter (PCXL §8.2.1 p74). | Linux `arch/parisc/kernel/time.c` |
| FPU (PA1.1 FP coprocessor, 32×64-bit regs) | PA11 ch.6; PCXL ch.7 p57-71 | Yes. PCXL lists all cases that raise the *unimplemented* trap (p59-63) — the FPU traps to software emulation for NaNs, denormals (unless D-bit), quad, FRND, etc. | Big RTL simplification: hardware need only handle normal operands; HP-UX and Linux (`arch/parisc/math-emu`) emulate the rest. FP model 0x0D, revision 0x01 (PCXL §7.1 p57). DR25.FP_DELAY must be 001 before CCR enable (PCXL §8.2.5 p78). | Linux `arch/parisc/math-emu/` |
| PCX-L FP extensions: FMPYCFXT, graphics clip-test FTEST completers + compare queue (FPSR[10:20]), hardware underflow D-bit | PCXL §7.4 p64-66 | Yes (encodings in text) | — | — |
| FP load/store to I/O space (defined on PCX-L) | PCXL §2.1.5 p6 | Yes | Must be supported (graphics drivers use FSTD to Artist). | — |
| MAX-1 multimedia (HADD{,ss,us}, HSUB{,ss,us}, HAVE/HAVG, HSL{1,2,3}ADD, HSR{1,2,3}ADD) | PCXL §2.1.4 p6 (description only) | **Via PCXL2** ch.13 p13-1…13-8 (PDF p187-194): major 02, 7-bit minor at bits 20:26 (HADD 1E/1A/18, HSUB 0E/0A/08, HAVE 16, HSRxADD 2A/2C/2E, HSLxADD 3A/3C/3E) with saturation pseudo-code; also PA2.0 L6913-7118 | PCXL2 HSUB table mislabels the rows as "HADD" (typo, L8565-8567). PCXL2 L433: PA7100LC does **not** trap on undefined minor opcodes (behaviour undefined), so decode can be permissive. | QEMU `insns.decode` L217-257 (encodings cross-checked to PCXL2: match) |
| Little-endian mode (PSW-E, DR0.ENDIAN default on trap, 9 endian-override LDWxX/LDWxS/STWxS) | PCXL §2.1.3 p6, DR0 p75 | **Via PCXL2** p13-10…13-12 (PDF p196-198): major 03, z field = 00 complement / 10 big / 11 little | LE instruction fetch added in PCX-L rev 2.0. | QEMU (PSW E-bit supported) |
| Diagnose registers DR0, DR1, DR8, DR24, DR25, DR26, DR27-29 | PCXL §8.2 p73-81 | **Yes** except DR26 (debug, chapter not public) | DR0 power-up: [0:5]=rev, [6:15] undefined, [16:31]=0 except [22]=1 (p75). | Linux `pacache.S` L1314-1321 uses MFCPU_C 0x141c0600 / MTCPU 0x141c0240 on DR0 |
| Diagnose instruction encodings (MTCPU 0x12, MFCPU_T 0xA0, MFCPU_C 0x30, TOC_EN/DIS, SHDW, RDD/RDT/RDTLB/RI2D/RI2T/RI1, WDD/WDT/WI2D/WI2T/WI1, SET_TAG) | PCXL §8.3.9 p91 | **Yes** (opcode 05, ext bits 19:26) | **QEMU decodes only MFCPU_C (…0600) and a PCX-T-style MTDIAG (…1600); the PCX-L MTCPU encoding (…0240) used by Linux falls into `diag_unimp` and is ignored.** Don't use QEMU as the reference for diag encodings. | — |
| Software constraints for diagnose | PCXL §8.4 p92-93 | Yes | — | — |
| Reset / power-on state | PCXL §5.3.1 p28 | Yes: all state machines reset, PSW cleared except M=1, fetch from 0xF000_0004 | "Start-Up Strategy" section referenced but absent. PCXL2 §8.2/§8.5 p8-3…8-7 describe the analogous PA7300LC sequence (RESETL ≥1 ms after PON, first fetch ≥4 GSC states after RESETL, broadcast reset via write 0x05 to LOCAL/GLOBAL COMMAND 0xFFFC_0030/0xFFFE_0030). On PA7100LC systems **LASI** drives RESETL (PCXL2 §8.1.2 p8-2; LASI §12.2 txt L3597). | — |
| Fault tolerance / HPMC / LPMC / PIM | PCXL ch.9 p95-99 | Yes for CPU side | Memory/GSC error status lives in MIOC (missing). | — |
| CPU identification | PCXL DR0[0:5] rev; FPU id 0x0D/0x01; board hversion via PDC_MODEL | Yes | HVERSION is a board property returned by PDC (0x60A etc.), not a CPU register. | `715_64.h` `PARISC_PDC_MODEL 0x60a0, 0x481, …` |
| **MIOC: memory controller (DRAM/SIMM config, refresh, ECC), I/O controller (GSC master/slave, DMA, timeout), MIOC status/error registers, CPU/MIOC HPA module registers** | "MIOC ERS" (referenced in PCXL §9.1, 9.5-9.8 p95-99) | **No** | Entire software-visible MIOC register set for PA7100LC is undocumented. PCXL2 Table 5 p11-5 (PDF p113) gives the PA7300LC set: EIR 0xF###E000, COMMAND +E030, MIOC_CONTROL +F080, MIOC_STATUS +F084, MTCV +F0C0, REF +F0CC, MDERRADD +F0E0, DMAERR +F0E8, DIOERR +F0EC, GSC_TIMEOUT +F0F0, HIDMAMEM +F0F4, MEMCOMP/MEMMASK[0:15] +F100/+F140, EIR_LOCAL 0xFFFC0000, FLEXID 0xFFFC0020, COMMAND_LOCAL 0xFFFC0030, EIR_GLOBAL 0xFFFE0000, COMMAND_GLOBAL 0xFFFE0030 (### defaults to FFB → CPU HPA 0xFFFB_E000, MIOC HPA 0xFFFB_F000 — same as on PA7100LC). PCXL2 §1.2.3 p1-3 warns the PA7100LC MIOC programming model differs ("registers reorganized, some moved from I/O space to diagnose registers"); §8.1.2 p8-2 lists I/O-side differences (GSC_TIMEOUT split out of MIOC_CONTROL, ponstat moved, etc.). | None in QEMU/SeaBIOS (QEMU emulates no MIOC; SeaBIOS never touches it). Only an original 715 PDC ROM dump (disassembly) would reveal it. |
| GSC bus interface | (GSC spec — missing) | Partial: PCXL2 ch.8 p8-1…8-21 (signals IODATA/PARITY/TYPE[0:3]/ADDVL/READYL/ERRORL/LSL/CREQUESTL/CGRANTL/RESETL, Read/Write 1-8 words, split cycles, arbitration, register-access timing); LASI ch.15-16 (txt L3967-4126) | TYPE[0:3] encoding table, exact timing, XQL semantics. PA7100LC supports CPU:GSC ratio 2 or 3 only (PCXL2 p8-2). For an FPGA SoC an internal bus with GSC *semantics* (word/byte enables, split avoidance, ERRORL→HPMC) is sufficient. | — |

### 3.3 PA7100LC specifics an RTL implementer needs (with citations)

1. **Architecture level.** PA-RISC 1.1 3rd ed., Level 1 (16-bit space IDs, 48-bit VA), 32-bit physical (up to 4 GB), 4 KB pages, 15-bit PIDs (PCXL §1.1 p1, §1.3 p3, §5.4 p37). I/O space = 0xF000_0000-0xFFFF_FFFF (PA11 Fig 2-2; LASI App. B).
2. **Reset.** PSW ← 0 except M=1; first fetch at 0xF000_0004; HPMC and TOC vector to 0xF000_0000 (PCXL §5.3.1 p28, §5.3.5 p29-30). DR0 power-up value (p75). All 64+8 TLB entries are locked out at power-on; PDC must clear lock-out by diagnostic insertion of unique VPNs, clear lock-in bits and PxTLBE (PCXL §6.3.3 p43, §6.5 p48). HW TLB handler disable bits DR25[28],[31] are *not* reset (§6.7.4 p53).
3. **Interruption entry.** Push PSW→IPSW, clear PSW (M set only for HPMC), copy GR1,8,9,16,17,24,25 to shadows, vector IVA+32×n (PCXL §5.3.5 p30-31). Group-4 traps (transfer/taken-branch/…) are "taken before" and outrank HPMC.
4. **TOC masking.** TOC is not M-bit-qualified; a separate HVERSION-dependent mask bit set by TOC, broadcast reset or TOC_DIS; cleared by TOC_EN (PCXL §5.3.5 p30, §8.3.3 p83).
5. **TLB.** 64 page entries + 8 block entries + 1-entry I-LAB; VPN = SID[0:15]‖offset[0:19]; insert target selection = VPN match → lowest invalid → NUR (§6.1-6.2 p39-41); DR8 control (p42-43); BTLB insert/purge procedure and mask table (p44-46); PITLBE/PDTLBE purge all page entries but never block entries (p45). U-bit implemented (§2.1.2 p5); PA7100LC does not require U=1 on I/O pages (PCXL2 §1.2.2 p1-3).
6. **HW TLB miss handler.** Optional to implement as long as DR25.I/D read back and the OS never clears them; specification in §6.7 p49-54 if needed.
7. **Diagnose.** Opcode 05; encodings table §8.3.9 p91; DR set §8.2 p73-81; HPMC flag bits in DR0 are write-1-to-clear (§8.3.1 p82). PDC/OS minimal set: MTCPU/MFCPU_C on DR0 (hash/cache enables), DR8 (TLB init, BTLB), DR24/DR25 (HTLB, FP_DELAY), TOC_EN/TOC_DIS, SHDW_GR/GR_SHDW.
8. **Implementation-specific instructions.** MAX-1 (op 02), fast TLB inserts (op 01), endian-override LDW/STW (op 03), FMPYCFXT and FTEST clip variants (op 0C/0E): PCXL2 ch.13 + PCXL §7.4. No Venom/graphics-flush instructions (illegal-instruction trap, PCXL §2.2.12 p9). No LCI/SYNCDMA, no performance monitor, no debug SFU (PCXL2 §1.1.6 p1-2, by inheritance).
9. **FPU.** Implement PA1.1 FP with unimplemented-trap fallbacks exactly as tabulated (PCXL §7.2-7.3 p58-63); integer multiply via XMPYU (FP unit). Latencies (p57) are informative only.
10. **Endian.** PSW-E, DR0.ENDIAN default on trap, HTLB walks honour DR0.ENDIAN (PCXL §2.1.3 p6, §6.7.1 p49).
11. **I/O semantics.** FP loads/stores to I/O space must work (§2.1.5 p6); ldw/ldw and stw/stw pairs may be bundled to I/O but are not merged (§4.12 p21). Interrupt delivery = GSC write of a 5-bit value to IO_EIR at 0xFFFB_E000 (PA11 p2-17; LASI §14.1 txt L3836).
12. **What a boot ROM must initialise on the CPU side** (assembled from PCXL §5.3.1, §6.5, §8.2, §8.4, §9.7; PCXL2 §8.2 for the I/O analogue): DR0 (L1 I-cache enable, I/D hash enable or disable, SOU_EN, SHINT_EN, IPREF_EN, ISTRM_EN, DUAL_DIS=00, ENDIAN=0, PF_MASK); DR25.FP_DELAY=001 then CCR (CR10) to enable FPU; DR24.DCACHE_SIZE to match the off-chip cache size; DR25 HTLB disable bits; TLB lock-out clearing; invalidate L1/L2 caches (diag writes or FIC/FDC loops); TOC mask handling (leave masked until OS IPL); MIOC memory configuration/refresh/ECC enable and GSC timeout (**undocumented**); HIDMAMEM-equivalent; LASI AMR clear, LASI IAR/IMR set-up, LASI I/O reset register release; Artist reset release (LASI I/O reset bit 8).

---

## 4. LASI (712 I/O Subsystem ERS)

Document: `Lasi_ers.txt` — "712 I/O Subsystem ERS", Dwg No. A-A2263-66510-31, Rev 1.1 12 Feb 1993 (chapters variously dated June 1992 – Feb 1994; public reprint May 1999). The chip is the Gecko (712) I/O ASIC; the 715/64-100 uses the same LASI with SPACE[1:0]=00 (base 0xF000_0000, registers at +0x10_0000).

The body chapter numbers differ from the TOC numbers (e.g. TOC "14 Interrupts" = body "14", but TOC "5 SCSI" = body "3"). Section numbers below are body numbers.

### 4.1 Functional units

Offsets are relative to the LASI 2 MB window base 0xF000_0000 (so register offset 0x10_6000 = 0xF010_6000). IRQ bit = bit position in LASI IRR/IMR/IPR, LSB-0 numbering (confirmed by QEMU `include/hw/misc/lasi.h` `LASI_BIT(x)=1<<x` and Linux `gsc_asic_intr` `__ffs(irr)`).

| Block | Primary doc (LASI) | Offset (size) | IRQ bit | Register-level coverage | Gaps | Fallback reference |
|---|---|---|---|---|---|---|
| Interrupt controller: IRR (RO), IMR, IPR, ICR, IAR | §14.1-14.5, txt L3836-3960, PDF p97-98 | 0x10_0000-0x10_0010 | — | **Yes.** IAR = EIR address [31:5] + data [4:0], power-up 0xFFFB_E003; reading IRR clears IRR and unmasked IPR bits; edge-triggered IPR; ICR bit1 TOC re-map, bit8 bus_error (disables further interrupts); "RT mode broken". | Conflict: §3.10 (txt L538) says 53C710 SC[1] interrupt-on-the-fly → IPR[21], Table 21 says bit 19 = "SCSI Snoop", bit 21 = "External Interrupt". Table 21 is the authoritative-looking one and matches QEMU's `LASI_IRQ_BITS`. | QEMU `hw/misc/lasi.c`; Linux `drivers/parisc/gsc.c`, `lasi.c` |
| IRQ assignments | Table 21 (txt L3941, PDF p98) | — | 5 RS-232, 7 parallel, 8 LAN, 9 SCSI, 13 audio, 14 LASI bus error, 16/17 telephone 0/1, 18 ISDN, 19 SCSI snoop, 20 floppy, 21 external, 26 PS/2 (kbd+mouse shared) | Yes | — | Linux `lasi.c` `lasi_choose_irq` L33-50 (same mapping keyed by sversion) |
| Parallel port slave (WD16C522/PS2-compatible, modes 0/1/2/4, CP300) | §5.1-5.7, txt L928-1305, PDF p31-38 | 0x10_2000 (+0x800..0x807 regs, +0x000 reset) | 7 | **Yes** | — | Linux `drivers/parport/parport_gsc.c`; QEMU `parallel_mm_init` (generic, no DMA) |
| Parallel port DMA (8237/EISA-like, single channel, read-only from memory) + DMA reset page | §5.8-5.16, txt L1306-1714, PDF p38-46 | 0x10_1000, reset 0x10_3000 | 7 (dmaInt via IECtlStat) | **Yes** | — | none (no QEMU/Linux DMA use) |
| Harmony audio: ID, RESET, CNTL, GAINCTL, PNXTADD/PCURADD, RNXTADD/RCURADD, DSTATUS, OV, PIO, DIAG | §6.3-6.4.8, txt L1999-2517, PDF p54-64 | 0x10_4000-0x10_403C | 13 | **Yes** (bit diagrams only legible in PDF p56-62) | CS4215 codec (and alternative AD1849) data sheet missing: only needed for CHI-bus-accurate modelling. FPGA can map CNTL (rate XS/SR table p57, format DF, stereo ST) straight to an audio DAC path. | Linux `sound/parisc/harmony.{c,h}`; QEMU: **no Harmony model** |
| Harmony telephony TTY0/TTY1 (WD16552-like) and ISDN DMA | §6.5-6.6, txt L2518-3029, PDF p65-74 | 0x10_4040-0x10_4066, ISDN regs in same page | 16, 17, 18 | Yes | Requires the Teleshare option card (not on 715). Implement as absent/idle (ID register reports 0x0014_0000 = no Teleshare, §6.4.2). | — |
| RS-232 (NS16550A clone, 16-byte FIFOs, 7.2727 MHz ref = 40 MHz/5.5) | §7.1-7.4, txt L3031-3129, PDF p75-76 | 0x10_5000 (reset), regs 0x10_5800-0x10_5807 | 5 | **Yes** (+ public 16550 knowledge) | — | QEMU `hw/char/serial.c` (clock 7272727); Linux `8250_gsc.c` |
| 53C710 SCSI (NCR 53C710 rev D macrocell, rev field = 2, BS_L=0 (68040 bus), big-endian, 40 MHz SCLK, 5 MB/s SE) | §3.1-3.11, txt L456-625, PDF p17-21 | 0x10_6000 reset; NCR regs 0x10_6100-0x10_613C | 9 (+19 snoop) | **Wrapper and byte-lane map only** (Table 1 p20). "See NCR 53C710 Data Manual" for every register field and SCRIPTS. | **NCR/Symbios 53C710 SCSI I/O Processor Data Manual missing** (registers, SCRIPTS instruction set, DMA/interrupt semantics). | QEMU `hw/scsi/ncr53c710.c` (2473 lines, full SCRIPTS interpreter) + `lasi_ncr710.c`; Linux `drivers/scsi/53c700.{c,h}`, `53c700.scr`, `lasi700.c` |
| 82596CA LAN megacell (CA mode, big-endian, linear mode, 32-bit) | §4.1-4.10, txt L626-920, PDF p22-30 | 0x10_7000 (+0 reset, +4 PORT (two 16-bit writes), +8 CA) | 8 | **Yes** with `82596CA.txt` | Intel 82596 User's Manual (296443) missing; data sheet covers SCP/ISCP/SCB, all action commands incl. Configure byte map, TDR, Dump, RFD/RBD, sysbus byte. LAN station address lives in flash (PDC_LAN_STATION_ID). 82C503 transceiver irrelevant for FPGA. | QEMU `hw/net/i82596.c` + `lasi_i82596.c`; Linux `lasi_82596.c`, `lib82596.c` |
| PS/2 keyboard + mouse (two 256-byte blocks, 4-char RX FIFO, 1-char TX) | §9, txt L3170-3338, PDF p79-82 | 0x10_8000 (kbd), 0x10_8100 (mouse) | 26 (shared, edge on composite) | **Yes** | — | QEMU `hw/input/lasips2.c`; Linux `drivers/input/serio/gscps2.c` |
| RTC (32-bit seconds counter, 32.768 kHz battery) | §8, txt L3130-3162, PDF p77 | 0x10_9000 | none | **Yes** | Battery-backed persistence must be emulated (MiSTer RTC). | QEMU `lasi.c` (`LASI_RTC`) |
| PC floppy: external WD37C65C FDC regs + LASI 4-byte FIFO + circular-buffer DMA | §10, txt L3339-3504, PDF p83-86 | 0x10_A000 (FDC + FIFO regs), DMA regs 0x10_D000/0x10_D004 | 20 | LASI side **yes**; FDC side "see WD37C65C spec" | WD37C65C data sheet missing (µPD765/82077 class, public). Note Appendix A lists floppy DMA at 0x10_D000 inside the "Unassigned" range — cross-check with HP-UX driver behaviour. | QEMU `hw/block/fdc.c` (generic FDC, no LASI wrapper); Linux has no LASI floppy driver |
| Flash EPROM / external 8-bit bus (1 MB, three chip selects, AM29F010 16 KB sectors; I/O config regs at 0x7FFFE/0x7FFFF) | §11, §13.1-13.2, txt L3505-3585, L3717-3781, PDF p87-88, 93-94 | 0x00_0000-0x0F_FFFF | — | **Yes** for decode | AM29F010 command set (public). Mirage board's own use of the 8-bit bus (LED at 0x0E_0000, any EEPROM/stable-store) undocumented. | QEMU `hw/block/pflash_cfi02.c` (AMD command set) |
| Power control register (PWR_ON_L soft power-off, FLASH_LED) | §12.3-12.4, txt L3650-3709, PDF p90-91 | 0x10_C000 | power-fail warning goes to CPU directly (PFW) | Yes | On Mirage the LED is elsewhere (see §2). | Linux `lasi.c` `lasi_power_off` (writes 0x02 to +0xC000) |
| Error logging register (which internal master saw a GSC error) | §13.3, txt L3782-3813, PDF p94 | 0x10_C004 | 14 | Yes | — | QEMU `lasi.c` |
| LASI version register (4-bit, 0 for first silicon) | §13.4, txt L3814-3828, PDF p95 | 0x10_C008 | — | Yes | Actual value in 715/64 LASI revisions unknown (QEMU returns 0). | QEMU `lasi.c` |
| I/O reset register (bits: 0 SCSI, 1 LAN, 2 parallel, 3 audio, 4 interrupt, 5 ext (FDC/LAN buf), 6 RS-232, 7 kbd, **8 Artist**; active-low, cleared by RESETL) | §12.2.2, txt L3615-3649, PDF p89 | 0x10_C00C | — | Yes | — | QEMU `lasi.c` (stores only) |
| Arbitration mask register AMR (IRM internal mask, ERM expansion slot mask; power-up masked; IRM set on bus error) | §16, txt L4054-4126, PDF p103-104 | 0x10_C010 | — | Yes | Arbitration is round-robin equal priority, CPU gets default grant. | QEMU `lasi.c` (stores only) |
| Clock synthesiser (clk_40, clk_20, clk_aud0/1 PLLs) | §17, txt L4127-4318, PDF p105-108 | 0x10_B000-0x10_B00C | — | Yes | Physical PLLs irrelevant on FPGA; registers must read back; audio rate selection must follow XS bit (Harmony CNTL). | — |
| GSC interface (slave/master, 2-word slave read buffer, no LSL split use, ERRORL handling) | §15, txt L3967-4053, PDF p101-102 | — | — | Behavioural | GSC spec missing (see §3.2). | — |
| Reset/PON → RESETL generation, RST_SLAVE/ARB_SLAVE/SPACE straps | §12.2, §2.2.1, §18 Table 27 | — | — | Yes | — | — |
| DMA behaviour summary | SCSI: 53C710 bus master (bursts); LAN: 82596 4-channel DMA, holds bus <5 ms, throttle off (§4.8.4.2); parallel: 1 word per tenure, read-only (§5.10); audio: synchronous play/record page-chained DMA, 4 KB pages, interrupts when both PN/RN set (§6.4.4); ISDN: 1 KB interrupts; floppy: 1 KB-in-4 KB circular buffer, interrupts at offsets 0x1FF/0x3FF (§10.2). All DMA is physical-address, non-coherent (software flushes). | | | Yes | No IOMMU; no coherency — matches PA7100LC (no LCI/SYNCDMA). | — |

### 4.2 LASI items explicitly asked about

* **ISDN**: yes, Harmony ISDN DMA channel (§6.6), only useful with the 712 telephony card. **Timer**: LASI has no programmable timer (CR16 is the system timer). **EEPROM/NVRAM**: none in LASI; stable storage on 712 lives in flash on the 8-bit bus (§11.1). **"amr"**: Arbitration Mask Register, 0x10_C010 (§16.2).
* LASI internal registers inventory: IRR/IMR/IPR/ICR/IAR (0x10_0000-0x10_0010), clock regs (0x10_B000-0x10_B00C), PCR/ERRLOG/VERSION/IORESET/AMR (0x10_C000-0x10_C010), I/O config (0x0_7FFFE/0x0_7FFFF, second LASI only).

---

## 5. Artist built-in graphics

| Block | Primary doc | Register-level coverage | Gaps | Fallback reference |
|---|---|---|---|---|
| Artist register map | `artist_graphics_registers.html` (parisc-linux wiki page, reverse-engineered from the 712 boot-ROM/STI code) | **Poor**: ~12 registers — VRAM write index 0x1004A0, bitmask 0x1005A0, word/byte write FIFOs 0x100600/0x100620, block-move source 0x100800 and size 0x100A04, FG/BG 0x118010/0x118014, status 0x380000/0x380008, selftest signature 0x30023C, colormap window 0x0118_406C-0x0118_47FF | No official Artist/NGLE ERS. Missing: full BINC (block-increment) engine semantics, ROP encoding (IMAGE_BITMAP_OP), bitmap-access (DST/SRC_BM_ACCESS) formats, plane masks, overlay/attribute/cursor buffers, line drawing, interrupts/vblank, CRT timing, RAMDAC/LUT path, VRAM organisation (1280×1024×8 + overlay?), monitor ID/sense, reset. | **QEMU `hw/display/artist.c`** (1516 lines): adds DST_SRC_BM_ACCESS 0x118000, DST_BM_ACCESS 0x118004, SRC_BM_ACCESS 0x118008, CONTROL_PLANE 0x11800C, PLANE_MASK 0x118018, IMAGE_BITMAP_OP 0x11801C, VRAM_START 0x100800, BLOCK_MOVE_SIZE/SOURCE 0x100804/0x100808, TRANSFER_DATA 0x100820, triggers 0x100A00/0x100A04/0x100B00/0x100B04, line regs 0x100CCC/0x100E04/0x100E44/0x100ECC, font regs 0x1008A0/0x100AA0, cursor 0x300100/0x300104, timing 0x300200/0x300208, MISC_VIDEO 0x300218, MISC_CTRL 0x300308, FIFO status 0x300008/0x380008, buffer IDs (AP=1, overlay=2, cursor 6/7, attribute 13, CMAP 15), ROPs. **Linux `drivers/video/fbdev/stifb.c`** L120-154: NGLE register set REG_1…REG_45 (offsets relative to +0x100000), Artist-specific colormap/enable code (L208-260, L328, L458-586). |
| Bitmap ops / ROP / plane masks / fill / block move | none | No | ROP field layout and pixel-pipeline semantics are inferred from driver usage only. | QEMU `artist.c` (`artist_rop8`, `block_move`, `vram_bit_write`); SeaBIOS `stirom.c` L3285-3400 (values like 0x23000300, 0x2EA01000 written by STI) |
| Cursor | none | No | Sprite size up to 64×64 per QEMU comment; format inferred. | QEMU `artist.c` |
| Colormap / RAMDAC | html (window only) | No | Whether Artist integrates the LUT/DAC or uses an external RAMDAC is not documented. | QEMU (`ARTIST_BUFFER_CMAP`), Linux stifb `ARTIST_CMAP0`, lut BLT control |
| VRAM layout / timing | none | No | Need monitor modes the 715 STI/HP-UX expect (1280×1024@72/75 Hz, 1024×768). | QEMU `artist.c` (`artist_get_cursor_pos`, `horiz_backporch`, `active_lines_low` decode) |
| LASI dependencies | LASI §12.2.2 (I/O reset bit 8 = RST_ARTIST_L), §17 (clkartist 20 MHz) | Yes | — | — |
| HCRX-8/24 (optional GSC card) | none | No | Out of scope for built-in Artist; Linux stifb supports HCRX. | Linux `stifb.c` |

Recommendation: obtain the HP-authored NGLE headers that shipped in XFree86 3.3.x (`xc/programs/Xserver/hw/hp/ngle/*.h`, HP-contributed) — they are the closest thing to an Artist/HCRX register document and are what `stifb.c` was derived from. Without them, the RTL must be validated against HP-UX's X server and the original STI ROM by trace comparison (QEMU tracing hooks exist: `artist_reg_name`).

---

## 6. WAX (HIL, RS-232 B, EISA)

**Verdict: the 715/64, /80 and /100 do have WAX.** Evidence:

* Real-machine inventory (`seabios-hppa/src/parisc/715_64.h` L18-21): Wax EISA BA at 0xFC00_0000 (sv 0x90), Wax BA at 0xF020_0000 (sv 0x8E), Wax HIL at 0xF020_1000 (sv 0x73), Wax RS-232 at 0xF020_2000 (sv 0x8C).
* Linux `hardware.c` L478-486 / L506-510 list "Mirage … Wax BA" / "Mirage … Wax EISA BA" for every Mirage variant; `drivers/parisc/wax.c` L115 "On 715-class machines, Wax EISA is a sibling of Wax, not a child".
* 715 Service Handbook A2600-90039 (Aug 95): two RS-232 ports (txt L511, L721-728), one shared EISA-or-GSC slot (L768-789; EISA interface board FRU A2084-66002), keyboard adapter module A4022-62005 giving 2× PS/2 **plus HP-HIL** (L711-719). HP-UX HCL `980723.txt` L4135 says that module is "Required on 715/64, /80, /100". (Handbook Fig 6-3 "715/64-100 block diagram", PDF p140, is actually the 712 diagram — ignore it.)
* The 712 has no on-board WAX (only an optional "Gecko Optional Wax BA" personality card).

Document: `pdf/WAX_ERS_V1.0_Redacted.pdf` — "External Reference Specification for the Wax I/O ASIC", rev 1.0, 3 May 1993, Dwg A-1FT4-0001-31, 102-page scan (txt is empty; read the PDF). Despite the file name, no redaction was found on the sampled pages (TOC, EISA, RS-232, HIL, interrupts, ID, TAP, address map, pinout); doc page 1 is missing.

| Block | Primary doc | Register-level coverage | Gaps | Fallback reference |
|---|---|---|---|---|
| WAX address map (GSC mode) | WAX ERS §12 Table 25, p88 (PDF p87) — verified | Yes: IRQ ctl 0xF020_0000, HIL 0xF020_1000, RS-232 0xF020_2000, watchdog 0xF020_3000, HPIB 0xF020_5000, real-time timers 0xF020_6000, ID register 0xF020_7000, i486/EISA bus control 0xFC00_0000-0xFFCF_FFFF | — | — |
| WAX interrupt controller (IRR/IMR/IPR/ICR/IAR at +0/4/8/C/10, same model as LASI) | WAX ERS Table 20 (PDF p82) | Yes. Bits: 0 EISA NMI, 1/2 8042 (general/high-priority), 6 RS-232, 10 EISA, 13 "Woody audio", 28-30 timers, 31 HPIB | — | Linux `wax.c` L25-44 (`wax_choose_irq`), `gsc.c` |
| WAX RS-232 (NS16550A-compatible) | WAX ERS (PDF p40) | Yes | — | QEMU `serial.c`; Linux `8250_gsc.c` (sv 0x8C) |
| WAX HP-HIL (emulated UPI-42 8042 "SDC" + HIL MLC) | WAX ERS (PDF p47) | Register interface yes (data +0x800, status +0x801; "PS-2 8042" pair at +0x808/+0x809) | **The 8042 internal firmware (HP 1820-4784) is not documented** — its command set must be re-implemented from driver behaviour or a ROM dump. HIL device protocol is public (Linux `hil.h`). | Linux `drivers/input/serio/hp_sdc.c` (binds sv 0x73, L934-948), `hp_sdc_mlc.c`, `hil_mlc.c`, `drivers/input/keyboard/hilkbd.c`; QEMU: **none** |
| WAX EISA bridge (GSC-to-i486 converter driving external TI EBCU/EPCU EISA chipset, address-map RAM, FIFO; CSRs at 0xFC01_0001/0xFC01_1001/0xFC01_2001/0xFC01_E001) | WAX ERS (PDF p9-13, 24) | Partial: WAX side yes; external EISA chipset (TI EBCU/EPCU) data sheets missing | Physical EISA slot is out of scope for MiSTer; recommend implementing WAX EISA as an "empty bus" (IODC present, no cards) or omitting it from the inventory. EISA config EEPROM for Mirage at 0xF00C_0400 (Linux `drivers/parisc/eisa.c` L52) — on LASI's 8-bit bus. | Linux `drivers/parisc/eisa.c`, `eisa_enumerator.c`, `eisa_eeprom.c` |
| WAX HPIB, watchdog, real-time timers, JTAG | WAX ERS | Yes | Not wired/used on the 715 as far as known (no HPIB connector) — confirm against HP-UX probing. | — |
| WAX ID register (reads 0x5661_7800) | WAX ERS | Yes | — | — |

---

## 7. Firmware interfaces: PDC, IODC, STI

(A deeper PDC/IODC/STI pass was started in parallel but had not finished when this report was written. This section covers what was verified directly. Extend it when that pass is done.)

| Doc | Identity | Relevance |
|---|---|---|
| `Pdc11-v0.96-Ch1-procs.txt` | "PA-RISC 1.1 Firmware Architecture Reference Specification" v0.96, 8 Mar 1999, ch.1 PDC procedures | **Primary** for a 1.1 machine (715). |
| `Pdc11-v0.96-Ch3-IODC.txt` | "PA-RISC 1.1 I/O Firmware Architecture Reference Specification" v0.96, 7 Mar 1999 | **Primary** for IODC entry points. |
| `pdc20-*` (v0.36, v1.0, v1.1 chapters) | PDC 2.0 (64-bit PA2.0, PDC_PAT, PDCE) | Secondary. Their "OS interface" chapters (Page Zero, IPL handoff) are useful cross-references, but PAT/64-bit content does not apply to the 715. |
| `Ver_nums.txt` | PA-RISC 1.1 Firmware Architecture Reference Spec, version-number tables (12 Mar 1999) | **Yes.** Mirage Jr NPROC sv 0x4 / rev 0x81 / hv 0x60A (L247), Mirage 100 0x60B (L248), Mirage 100+ 0x60C (L249), Mirage 80 0x619 (L261); memory hv 0x4A/4B/4C/4F (L349-354); Mirage Wax HIL hv 0x012/0x013/0x02B/0x02C (L689-703). |
| `Sti.txt` | "Standard Text Interface for Graphics Devices", Revision 8.13, 1 Mar 2000 | **Yes**, for the Artist STI ROM. |

PDC 1.1 procedure set (Ch1 §1.2, txt L440-476). A = architecturally required. HV = depends on HVERSION.

| Index | Procedure | Class | Note for the 715/64 (PA7100LC) |
|---|---|---|---|
| 1 | PDC_POW_FAIL | HV | LASI power-fail / soft-power support |
| 2 | PDC_CHASSIS | A | LED / chassis codes. Mirage LED register is at 0xF00E_0000 |
| 3 | PDC_PIM | A | HPMC/TOC/LPMC PIM. Bus check words need MIOC state (undocumented) |
| 4 | PDC_MODEL | A | Real 715/64: `0x60a0, 0x481, …`, capabilities 0x2, CPUID option unsupported (`715_64.h` L32-41) |
| 5 | PDC_CACHE | A | Real 715/64: I = D = 0x20000, 64-entry I/D TLB (`715_64.h` L42-48) |
| 6 | PDC_HPA | A | Processor HPA 0xFFFB_E000 |
| 7 | PDC_COPROC | A | FPU present |
| 8 | PDC_IODC | A | Reads module IODC / entry points |
| 9 | PDC_TOD | A | Backed by LASI RTC |
| 10 | PDC_STABLE | A | Stable storage. Mirage location undocumented (flash or 8-bit-bus EEPROM) |
| 11 | PDC_NVOLATILE | HV1 | Only if NVM exists |
| 12 | PDC_ADD_VALID | A | Linux probes the Harmony address with it (`lasi.c` L72) |
| 14 | PDC_DEBUG | HV | |
| 15 | PDC_INSTR | HV3 | |
| 18 | PDC_BLOCK_TLB | HV2 | **Required:** PA7100LC has 8 BTLB entries (DR8 procedure, PCXL §6.3.5) |
| 19 | PDC_TLB | HV4 | **Required:** PA7100LC has a HW TLB miss handler (PCXL §6.7) |
| 21 | PDC_PSW | HV | Default PSW E/W bits |
| 128-511 | HVERSION-dependent | HV | e.g. PDC_SYSTEM_MAP, PDC_MEM_MAP, PDC_SOFT_POWER, PDC_LAN_STATION_ID as used by Linux/SeaBIOS |

The calling convention (real mode, ARG0 = index, ARG1 = option, return status codes) is in Ch1 L300-420.

IODC entry points (Ch3) include ENTRY_INIT, ENTRY_IO, ENTRY_SPA, ENTRY_CONFIG, ENTRY_TEST and ENTRY_TLB. Boot, console and keyboard paths use ENTRY_INIT and ENTRY_IO. A replacement firmware must supply IODC data and code for:
* LASI SCSI (boot)
* LAN (network boot)
* Artist (console, via STI)
* PS/2 or HIL keyboard
* RS-232 (serial console)

**Consumers.**
* Linux on this machine calls: `pdc_model_info`, cache info, `pdc_iodc_read`, `pdc_system_map_find_mods`/`_addrs`, `pdc_tod_read`/`set`, `pdc_stable_*`, `pdc_add_valid`, chassis (`pdc_chassis_*`), soft power (`pdc_soft_power_*`), `pdc_console_*` (PDC/IODC console during early boot), and `pdc_sti_call` (sticore). These were grepped across `arch/parisc/kernel/*` and `drivers/parisc/*`.
* HP-UX 10.20 is assumed to need, in addition, PDC_BLOCK_TLB, PDC_TLB and PDC_PIM, plus the IODC ENTRY_IO boot path. This is **inferred**, not documented in the corpus.

**Fallback.** SeaBIOS-hppa (`roms/seabios-hppa/src/parisc/parisc.c`, LGPLv3):
* It implements essentially the whole PDC 1.1 set plus the PDC 2.0 options.
* It has a real-715/64 machine profile (`715_64.h`) and an LGPL STI ROM for Artist (`sti.c`, `stirom.c`).
* It does not model the MIOC.
* It disables the WAX, HIL, EISA, Harmony and floppy HPAs (`HPA_DISABLED_DEVICE`).
* It expects QEMU's CPU HPA 0xFFFB_0000 rather than the real 0xFFFB_E000.

It is the obvious starting point for our boot ROM. Those deviations must be reconciled with real hardware addresses.

**STI.** The STI spec defines:
* the ROM header and region list
* the font
* the entry points INIT_GRAPH, STATE_MGMT, FONT_UNPMV, BLOCK_MOVE, SELF_TEST, EXCEP_HDLR, INQ_CONF, SET_CM_ENTRY and DMA_CTRL. These are PA-RISC machine code that pokes the device registers.
* byte-mode vs word-mode ROM access

Because HP's Artist STI image is not in the corpus, we must either dump it from a real 715 or use SeaBIOS's `stirom.c`. In the latter case, the Artist RTL only needs to honour the registers that STI code and the OS drivers actually touch.

---

## 8. Other documents in the corpus: identity and relevance

| File | Identity | Relevant to 715/64-100? | Notes |
|---|---|---|---|
| `A3725-96022.txt` | *HP 9000 V-Class Server Architecture*, 2nd ed., A3725-96022, Mar 1998 | No | PA-8200 crossbar server. **Not a graphics manual.** |
| `AD1819.txt` | Analog Devices AD1819B AC'97 SoundPort codec data sheet | No | Codec of later PCI B/C/J machines. Not the Harmony codec (Harmony uses CS4215, alt. AD1849). |
| `AD1889.txt` | AD1889 PCI SoundMAX controller, rev 3/22/99 | No | Same later machines. |
| `feb96a6.txt` | HP Journal Feb 1996, "Hardware Cache Coherent I/O" (J/K-class, Runway) | No | |
| `PC87415.txt` | NatSemi PC87415 PCI-IDE controller (prelim., Mar 1996) | No | IDE in SuperIO of Elroy/Dino-era machines. |
| `92432-90012.txt` | HP Assembler Reference Manual, 9th ed., Jun 1998 | Partial | Assembler syntax for writing test ROMs; no hardware content. |
| `Emr_na-c01865801-1.txt` | rp24xx (A400/A500) hardware manual, Aug 2002 | No | |
| `980723.txt` / `980723ng.txt` | HP-UX Workstation Hardware Compatibility List, Ed. 14, 23 Jul 1998 | Partial | Confirms 715 memory (8 slots / 4 pairs), CS4215 audio, HCRX options, HIL adapter requirement, slot rules. |
| `712_technical_manual.txt` | Technical Reference Manual, Model 712, Rev 1.0, Jan 1994 | Partial | No address map / register content. Useful: GSC expansion-slot pinout (txt L1039-1066: GSC[31:0], TYPE[3:0], PARITY, ADDV_L, READY_L, ERROR_L, LS_L, INTERRUPT_L, EREQUEST_L/EGRANT_L, SYNC4H/L, EXP_RESET_L), Teleshare/codec serial pinout (L1077-1087), audio specs (L448-466), boot-ROM self-test screens. Much of the txt is font-garbled; use the PDF. |
| `715_ServiceHandbook_A2600-90039…OCR.txt` (= `715_service-handbook.txt` = `lpv37699.txt`, byte-identical) | Model 715 Service Handbook, A2600-90039, Aug 1995 | **Yes (system level)** | Memory: ECC 72-pin SIMMs, 32-256 MB, 8 slots as 4 pairs, Pair 3 mapped first (L2852-2907); PIM address assignment table (L2757-2800); two RS-232, HIL via adapter, EISA/GSC slot, floppy, LED error codes (L2258-2315, legible only in PDF p65-66). Fig 6-3 is wrong (712 diagram). |
| `9000_715-64-80-100_TechData_5962-9555E` (PDF only) | 715/64/80/100 Technical Data, Apr 1994 | Yes | PA7100LC 64/80/100 MHz; 256 KB external combined I/D cache per TechData (real 715/64 PDC_CACHE reports 128 KB I + 128 KB D, `715_64.h` L42 — treat as unresolved); 1280×1024@72 Hz 8-plane integrated graphics with Color Recovery; memory bus 170/267 MB/s. |
| `E-class_hpjournal.txt` | HP Journal Apr 1995, low-cost E-class server (PA7100LC + GSC + LASI) | Partial | PDF Fig 1 shows Flash (PDC) and EEPROM (stable storage) on LASI. Cites Apr 1995 HP Journal articles on the 712, PA7100LC and LASI — **worth obtaining**. |
| `Pa7300lc_{config,design,on_chip}.txt` | HP Journal Jun 1997, PA7300LC articles | Background | Successor chip; MIOC timing vector, GSC ratios. |
| `GSP_User_Guide.txt`, `Four_way_superscalar.txt`, `Isscc*.txt`, `Mako_mpf_2001.txt` | GSP guide; PA-8000/8200; PA-8500/8700 ISSCC; Mako | No | |
| `Hardball_ers.txt` (+ `pdf/chips/hardball_ers.*`) | Hardball I/O Subsystem ERS v1.1, Sep 1991 (735/755, "Cutoff"/Asp2 on SGC) | No (lineage) | txt is a stub; PDF is a 55-page scan. |
| `Dino_ers.txt` (+ errata) | Dino ERS rev 3.1, Sep 1997 — GSC-to-PCI bridge (B132L/B160L/C1xx) | No | |
| `WAX_ERS_V1.0_Redacted.pdf` | WAX I/O ASIC ERS rev 1.0, May 1993 | **Yes** | See §6. |
| `Elroy_ers.txt`, `Astro_*.txt` | Ropes-to-PCI bridge; Runway memory/I/O controller (C3000/J5000/A500 era) | No | |
| `Zx1-ioa-mercury_ers.txt`, `Zx1-mio.txt` | Itanium-2 zx1 chipset ERS | No | |
| `Ver_nums.txt` | PA-RISC 1.1 Firmware Architecture Reference Spec — version numbers (hversion/sversion tables) | **Yes** | See §7. |
| `Sti.txt` | Standard Text Interface spec | **Yes** | See §7. |

Answers to the specific questions: none of the listed files is the CS4215 codec doc, the NCR 53C710 data sheet, a 16550 data sheet, or an Artist/HCRX document. Harmony is documented only inside the LASI ERS (body §6); the 53C710 only as LASI wrapper (§3); the 16550 only as LASI §7 / WAX deltas.

---

## 9. Documents we do not have but need

| Missing document | Needed for | Severity | Can QEMU / Linux fill the gap? |
|---|---|---|---|
| **PA7100LC MIOC ERS** (memory & I/O controller, CPU/MIOC HPA register set, error/status regs) | Running HP's original 715 PDC ROM; HP-UX HPMC/LPMC logging; faithful memory sizing | High if we run HP PDC; Low with replacement firmware | **No.** QEMU and SeaBIOS emulate/use no MIOC. PCXL2 ERS ch.7/8/11 (PA7300LC MIOC) is the best template. Only a disassembly of a real 715/64 PDC ROM would recover the exact layout. |
| **PA7100LC ERS Appendix** (instruction formats for MAX-1, fast inserts, endian loads/stores, U-bit details, pipeline diagram) | ISA completeness | Low | Yes: PCXL2 ch.13 + QEMU `insns.decode` (encodings cross-checked, match). |
| **NCR/Symbios 53C710 SCSI I/O Processor Data Manual** (registers + SCRIPTS) | LASI SCSI core | High | **Yes:** QEMU `hw/scsi/ncr53c710.c` (full SCRIPTS engine, register semantics) + `lasi_ncr710.c`; Linux `53c700.{c,h}` + `53c700.scr` show real driver usage. The data manual itself is widely archived (bitsavers) and should still be fetched for corner cases (CTEST regs, DFIFO, snoop pins). |
| **Crystal CS4215 data sheet** (Harmony's codec; AD1849 alternate) | Exact CHI control-frame semantics | Low | Linux `sound/parisc/harmony.c` exercises the register interface fully; codec can be abstracted. QEMU has no Harmony model. |
| **NS16550A data sheet** | RS-232 (LASI, WAX) | Low | Public knowledge; QEMU `hw/char/serial.c`. |
| **Intel 82596 User's Manual** (296443) | LAN corner cases (dump format, self-test, errata) | Low | Data sheet in corpus is sufficient; QEMU `i82596.c`. |
| **WD37C65C FDC data sheet** | Floppy | Low | QEMU `hw/block/fdc.c` (82077/765). |
| **AMD Am29F010 data sheet** | Flash programming (PDC_STABLE, firmware update) | Low | Public; QEMU `pflash_cfi02.c`. |
| **GSC bus specification** | Bus timing/types if we expose a real GSC (expansion slot) | Medium (only for physical GSC) | No. PCXL2 ch.8 + LASI ch.15-16 sufficient for internal bus. |
| **Artist ASIC ERS / NGLE programming docs** | Graphics core | High | Partially: QEMU `artist.c`, Linux `stifb.c`, SeaBIOS `stirom.c`. Obtain XFree86 3.3 HP NGLE headers. |
| **HCRX / HP Visualize docs** | Optional graphics cards | Out of scope | Linux `stifb.c` only. |
| **Original 715/64-100 PDC/IODC/STI ROM image** | Bit-exact firmware behaviour, HP-UX boot, Artist STI | High (for HP-UX fidelity) | SeaBIOS-hppa replacement exists (LGPLv3) with a 715/64 machine profile and Artist STI. |
| **PA-RISC 1.1 I/O Architecture** (architected module registers: IO_EIM, IO_EIR, IO_COMMAND, IO_STATUS, FLEX, SPA) | CPU/MIOC/LASI HPA register semantics, broadcast | Medium | Partially: PCXL2 Table 5 / §11.6, PDC IODC chapter (see §7), LASI §14. |
| **Mirage (715/64-100) system board ERS / schematics** | Board glue: LED register, straps, EEPROM/stable-store location, EISA/WAX wiring | Medium | Linux `lasi.c` (LED), `eisa.c` (EEPROM addr), SeaBIOS `715_64.h` (inventory). |
| **WAX HIL 8042 firmware** (HP 1820-4784) | HIL keyboard/mouse via WAX | Medium (HP-UX console on HIL) / Low (PS/2 suffices) | Linux `hp_sdc.c`/`hp_sdc_mlc.c` show the command set used; a ROM dump would be needed for exactness. |
| **TI EBCU/EPCU EISA chipset data sheets** | Real EISA slot | Out of scope | Linux `drivers/parisc/eisa.c`. |
| **HP Journal April 1995** (articles on the 712, PA7100LC, LASI) | Background, design rationale, possibly block diagrams | Low | Cited by `E-class_hpjournal.txt`; publicly archived. |

---

## 10. Recommendations

1. Treat **PA11 3rd ed. + PCXL ERS + PCXL2 ch.13** as the normative CPU spec. Build the decode table from PA11 App. C/D, add PCXL2 ch.13 opcodes, and the PCXL §8.3.9 diagnose table. Do **not** copy QEMU's diag decoding (it misses PCX-L MTCPU).
2. Plan on **replacement firmware** (SeaBIOS-hppa `715_64.h` profile) so the undocumented MIOC can be modelled as a minimal, self-defined register block at 0xFFFB_F000 (plus EIR/COMMAND at 0xFFFB_E000), using PCXL2 Table 5 as the naming template. Keep the door open for HP's PDC by logging all accesses to 0xFFFB_E000-0xFFFB_FFFF in simulation.
3. For LASI, the ERS is sufficient for: interrupt controller, AMR/IORESET/ERRLOG/VERSION/PCR, clocks, RTC, PS/2, UART, parallel+DMA, Harmony. Use QEMU `ncr53c710.c` as the behavioural reference for SCSI and fetch the NCR data manual. Use the 82596CA data sheet + QEMU `i82596.c` for LAN.
4. Artist is the highest-risk block for documentation; budget for trace-driven reverse engineering against QEMU + HP-UX X server + STI ROM.
5. Re-extract the LASI and PCXL2 bit-field diagrams from the PDFs (they are clean vector PDFs) — the txt versions are unusable for register boxes.
