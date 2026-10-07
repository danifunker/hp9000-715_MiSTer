# 01 — HP 9000 Model 715: system-level documentation review

Scope: a read-only review of the documents in `docs/reference/` to support an FPGA (MiSTer, DE10-Nano, Cyclone V) recreation of the HP 9000 Model 715. There is no RTL here. Every fact has a citation. Anything I inferred is marked **(inference)**. Anything the documents do not answer is marked **GAP** and collected in §12.

---

## 0. Sources and citation keys

| Key | Document (file in `docs/reference/pdf/`) | Notes |
|---|---|---|
| **TD64** | `9000_715-64-80-100_TechData_5962-9555E_9pages_Apr94.pdf` | Scanned. Cited by PDF page. PDF p.3 is an HP Computer Museum insert. |
| **DS64** | `9000_715-64-80-100_5962-9553E_3pages_Apr94.pdf` | Scanned. The data is on PDF p.3. |
| **QRG** | `715_QuickReferenceGuide_5962-9710E_6pages_Jun94.pdf` | Scanned. PDF p.4 has the facts table and p.5 the configuration worksheet. |
| **OG94** | `715_OwnersGuide_A2084-90629_273pages_Apr94.pdf` (edition E0494, covers 715/33/50/75/64/80/100) | Scanned. Cited as printed page, with the PDF page in brackets. Offsets: 1‑n=PDF 17+n, 3‑n=61+n, 4‑n=73+n, 6‑n=105+n, B‑n=137+n, C‑n=211+n, D‑n=229+n. |
| **SH95** | `715_service-handbook.pdf` (A2600‑90039, Ed.4, Aug 95). The text is `txt/715_service-handbook.txt` | Byte-identical to `715_ServiceHandbook_A2600-90039_150pages_Aug95_OCR.pdf` and `lpv37699.pdf`. Cited by printed page. |
| **OG93** | `715_Model33-50_OwnersGuide_A2084-90613_287pages_Jan93.pdf` | Contrast only |
| **TD75** | `715-33-50-75_TechData_5091-9991E_Nov93.pdf` | Contrast only. Cited by PDF page. |
| **SP92** | `715Workstation_Specifications_5091-5814E_2pages_Oct92.pdf` | Contrast only |
| **SG93** | `HP-Apollo_715-725_SalesGuide_5091-8794E_18pages_Aug93.pdf` | 715/75 and 725/75, contrast only |
| **HIG** | `HardwareInstallationGuide-Model715-A2084-90012-73pages-Apr93.pdf` | HIL-era (715/33/50/75) installation guide |
| **TRM712** | `712_technical_manual.pdf` (Model 712 Technical Reference, Jan 94) | The text layer is badly garbled, so I read the PDF. |
| **SH712** | `712_service-handbook.pdf` (`txt/712_service-handbook.txt`) | |
| **LASI** | `Lasi_ers.pdf` ("712 I/O Subsystem ERS", A‑A2263‑66510‑31, rev 1.0/1.1, 1992–93) | |
| **WAX** | `WAX_ERS_V1.0_Redacted.pdf` (Wax I/O ASIC ERS, A‑1FT4‑0001‑31, May 1993) | Scanned |
| **VER** | `Ver_nums.pdf` (PA‑RISC 1.1 Firmware Architecture Ref. Spec v0.96, Appendix B "Version and Identification Numbers") | |
| **HCL** | `980723.pdf` (HP‑UX Workstation Hardware Compatibility List, Ed. 14, 23 Jul 1998) | `980723ng.pdf` is a variant |
| **PCXL** | `PCXL_ers.pdf` (PA7100LC ERS excerpt, chapters 8–9) | |
| **QEMU** | QEMU 11.1.1 source, `hw/hppa/hppa_hardware.h` and `hw/hppa/machine.c` | Cross-reference only. Not in `reference/`. |

---

## Executive summary

- **There are two different 715 families.**
  - **Scorpio**: 715/33, 715/50, 715/75 (and 715/C, 715s, 715t). PA‑7100 CPU with separate off-chip I and D caches, SGC graphics bus, HP‑HIL only, HP‑UX 9.0 up to 10.20 (final).
  - **Mirage**: 715/64, 715/80, 715/100, 715/100XC. PA‑7100LC CPU with a 256 KB external unified cache, GSC bus, the LASI core I/O ASIC plus the WAX ASIC, PS/2 and HIL through an external adapter, HP‑UX 9.05 up to 11.00 (32-bit) [SH95 1‑1…1‑3; HCL p.7; VER Table B‑1].
- **Mirage I/O.** VER lists for each Mirage model:
  - "Core" LASI functions: BA, SCSI, LAN, Centronics, Audio, PC floppy, PC keyboard, RS‑232.
  - "Wax" functions: Wax BA, Wax HIL, Wax RS‑232, Wax EISA BA.
  - A "GSC Builtin Graphics" function.

  So the EISA slot, HP‑HIL and the second serial port come from **WAX**. Everything else is in **LASI** [VER lines 689–1403].
- **Memory.** 8 × 72‑pin ECC SIMM slots in 4 pairs. Both SIMMs in a pair must be the same size. The range is 32–256 MB (8 × 32 MB). ECC is single-bit correct, double-bit detect. The memory controller (MIOC) is inside the PA‑7100LC [TD64 PDF p.6; OG94 B‑53; HCL p.21–22; LASI App. B].
- **Graphics.** The built-in graphics is 8‑plane with HP Color Recovery and is autoconfiguring. The monitor is chosen with the BCH `monitor` command, with modes from 640×480 to 1280×1024 at 60/70/72/75 Hz. The built-in graphics sits on GSC at path `1`. One shared EISA/GSC slot takes HCRX‑8/8Z/24/24Z. CRX‑48Z works on the 715/100 only [OG94 B‑60…B‑63; TD64 PDF p.2, 4, 5; QRG p.5].
- **Input.** On the Mirage models, a 10‑pin modular jack goes to a Keyboard Adapter Module with 2 × mini‑DIN (PS/2) and 1 × HP‑HIL. PS/2 and HIL are mutually exclusive [SH95 1‑9; HCL p.76].
- **SCSI.** An NCR 53C710 macrocell inside LASI drives one narrow, single-ended SCSI‑2 bus at 5 MB/s. There are two internal 3.5″ bays plus one removable bay. The CD‑ROM is the A2803A (Toshiba XM‑3301B, 2×, caddy) at ID 2. Its analog audio is cabled to the CPU board, so **CD audio can be routed into the codec** [SH95 3‑2, 3‑13, 5‑15; OG94 1‑6, B‑30; TRM712 1‑3].
- **Audio.** Crystal **CS4215** codec behind LASI's "Harmony" block. Sample rates 8, 11.025, 16, 22.05, 32, 44.1 and 48 kHz. Formats 16‑bit linear, µ‑law and A‑law [OG94 1‑6; HCL p.78; LASI ch.6].
- **Firmware.** HP‑UX's Boot Console Handler, with self-test LED codes, `BOOT_ADMIN>` and the commands documented below. The base boot ROM revision for all Mirage SPUs is **2.7** [HCL p.11, 14].
- **Recommended target: 715/64** ("Mirage Jr", CPU HVERSION 0x60A). Design the board so it can also report 715/80 or 715/100. See §11.

---

## 1. Variants, CPU, clock, caches, FPU, I/O chip set

### 1.1 Variant table

| Model | Code name and CPU HVERSION [VER] | CPU | Clock | Cache | FPU | Core I/O | Gfx bus | Board P/N [SH95 5‑3] |
|---|---|---|---|---|---|---|---|---|
| 715/33 | Scorpio Jr, 0x311 | PA‑7100 | 33 MHz | 64 KB I + 64 KB D, off-chip, direct mapped [TD75 PDF p.2, p.6] | PA‑7100 FP (the LED table has an FP test) | "Scorpio Core" BA/SCSI/LAN/HIL/Centronics/RS‑232/Audio, plus "Scorpio EISA BA" [VER]. ASIC names not given (**GAP**). | SGC | A2084‑69511 |
| 715/50 | Scorpio, 0x310 | PA‑7100 | 50 MHz | 64 KB + 64 KB | same | same | SGC | A2084‑69510 |
| 715/75 | Scorpio Sr, 0x316 | PA‑7100 on a "PCX‑T module" (A2335‑69222) | 75 MHz | 256 KB I + 256 KB D [TD75 PDF p.2; SG93 p.2] | "75 MHz floating-point processor" [SG93 p.3] | same | SGC | A2084‑69014 |
| 715/C | not in VER | not documented (**GAP**) | — | — | — | grouped with the Scorpio LED tables [SH95 4‑3] | SGC | A2084‑69017 |
| **715/64** | **Mirage Jr, 0x60A** | **PA‑7100LC** (bi-endian, multimedia/"MPEG" instructions) [TD64 PDF p.1–2] | **64 MHz** | **256 KB external unified I/D, direct mapped, 64-bit bus** [TD64 PDF p.6; DS64; QRG p.4]. The 715/64 cell on TD64 PDF p.2 is blank. On-chip L1 I-cache is 1 KB [PCXL §8.3.7]. | On the PCX‑L chip. ODE `ldiag` tests "CPU, cache, TLB and floating point functions" of PCX‑L [SH712 4‑16]. | LASI + WAX [VER] | GSC | A4022‑69516 |
| 715/80 | Mirage 80, 0x619 | PA‑7100LC | 80 MHz | 256 KB | on-chip | LASI + WAX | GSC | A4022‑69518 |
| 715/100 | Mirage 100, 0x60B | PA‑7100LC | 100 MHz | 256 KB | on-chip | LASI + WAX | GSC | A4022‑69510 |
| 715/100XC | Mirage 100+, 0x60C. The name match is my **(inference)**: VER lists "Mirage 100+" and SH95 lists "715/100XC", but no document links them. | PA‑7100LC [HCL p.8] | not stated (**GAP**) | not stated (**GAP**) | — | LASI + WAX | GSC | A4022‑69515 |

VER labels the Scorpio IDs with 715 model numbers but gives the Mirage IDs (Jr, 80, 100, 100+) as code names only. The mapping used here (Jr = 715/64, 80 = 715/80, 100 = 715/100, 100+ = 715/100XC) comes from the Linux identification strings in the task brief and fits the naming. No document in the folder states it explicitly.

Other CPU IDs in VER that no other document explains:
- "Scorpio 100 (715/100)" 0x317, with its own Scorpio-core I/O IDs.
- "Scorpio‑L 80/100/120" 0x609/0x610/0x611.
- 715S/715T Strider/Trailways 0x312–0x315 (upgrades from 4xx/705/710).
- "715/132 L2 Upgrade" 0x50B and "715/160 L2 Upgrade" 0x50C.

All of these are **GAP**s. The 715/100 described by TD64, SH95 and HCL is the PA‑7100LC Mirage board.

Other CPU and bus figures:
- **715/64‑100 bus figures** [TD64 PDF p.6]:
  - Peak cache bus: 512 / 640 / 800 MB/s (8-byte load or store). This implies a 64-bit cache running at the CPU clock **(inference)**.
  - Peak main-memory bus: 170 MB/s on the 64 and 80, 267 MB/s on the 100 (64-byte burst).
  - TLB: 64 unified page entries plus 8 variable block entries, fully associative.
  - Virtual address: 48-bit.
- **Scorpio TLB** for contrast: 120 page entries plus 16 block entries [TD75 PDF p.6].
- **Block diagrams.**
  - Scorpio: separate 64-bit I and D caches, a 32-bit PBUS, memory and I/O controllers, the SGC bus and a "BMC" [SH95 Fig 6‑2, p.6‑3].
  - Mirage: CPU, memory control and I/O control in one shaded block. The memory path is 72 bits wide (64 data + 8 ECC). The I/O block hangs off the "GSC System" [SH95 Fig 6‑3, p.6‑4].
  - LASI's memory map puts "MIOC (PA7100LC Memory Control)" at 0xFFFBF000 [LASI App. B].

### 1.2 The Mirage I/O chip set (answers "ASP/Cutoff vs LASI, EISA via WAX")

VER Table B‑1 lists these module IDs for each Mirage model. The HVERSION differs per model and per function. The LASI "Core" functions use 028 (Jr), 029 (Mirage 100), 02B (80) and 02C (100+). The Wax and graphics functions use values in 010–013 or 028–02C, so look each one up in VER.

| Function | SVERSION type | Provider |
|---|---|---|
| Core BA | 0x81 | LASI |
| Core SCSI | 0x82 | LASI |
| Core PC Floppy | 0x83 | LASI |
| Core PC Keyboard | 0x84 | LASI |
| Core LAN | 0x8A | LASI |
| Core Centronics | 0x74 | LASI |
| Audio | 0x7B | LASI |
| Core RS‑232 | 0x8C | LASI |
| Wax BA | 0x8E | WAX |
| Wax HIL | 0x73 | WAX |
| Wax RS‑232 | 0x8C | WAX |
| Wax EISA BA | 0x90 | WAX |
| GSC Builtin Graphics | 0x85 | GSC graphics, same SVERSION as the 712's core graphics |

[VER lines 689–703, 756–760, 894–898, 966–970, 1007–1011, 1056–1060, 1099–1103, 1145–1148, 1225–1229, 1268–1295, 1358–1403]

What the chips contain:
- **LASI** contains the NCR 53C710 SCSI core, the 82596 LAN interface (using an external 82596CA), the parallel port, the Harmony audio/telephony TDM block, a 16550-class UART, PS/2 keyboard and mouse, the RTC, the PC floppy interface, the power control register and an 8-bit external bus for flash [LASI §1.2, ch.3, 4, 6, 8, 11, 12; TRM712 1‑3, 2‑3].
- **WAX** contains a GSC‑to‑EISA/ISA converter (using the TI TACT84500 EBCU/EPCU), RS‑232, HP‑HIL (an 8042 interface plus an HIL master link controller), HP‑IB, watchdog timers, real-time timers and an interrupt controller. Its EISA software interface is designed to match "Pace and Scorpio" [WAX §1.1, §2.1.2].
- **ASP, Cutoff and Mongoose** do not appear in any 715 document. LASI's ERS says "the ASP chip used in the 720/730/750" [LASI §3.11]. The names of the Scorpio I/O ASICs are a **GAP**.
- The built-in graphics chip is never called "Artist" in the 715 documents. **(inference)** It is the Artist family because:
  - its SVERSION 0x85 is shared with the 712 "GSC Core Graphics" and with "Anole Artist Builtin Graphics" [VER];
  - the 712 memory map calls the 712 chip "ARTIST" [LASI App. B];
  - QEMU's 715 maps an `artist` device at 0xF8000000 [QEMU].

---

## 2. Memory

| Item | Value | Source |
|---|---|---|
| Slots | 8 slots in 4 pairs (Pair 0–3, slots A and B). The Scorpio 715/33 has 3 pairs. | OG94 B‑53/B‑54 Fig B‑42; SH95 Fig 3‑15; HCL p.21–22 |
| SIMM type | 72‑pin ECC SIMMs, 70 ns, 4 and 16 Mbit DRAMs | TD64 PDF p.6; HCL p.23 |
| ECC | Single-bit correct, double-bit detect. The service text still says "multi-bit memory parity error" for the HPMC case. | TD64 PDF p.6; SH95 4‑25; PCXL §9 (MIOC corrects single-bit errors) |
| Installation rule | "Memory boards must be installed in pairs of the same memory capacity… up to four pairs… install in the lowest numbered empty connector pair first" | OG94 B‑53. The SH95 rule text on p.3‑16 is corrupted in both the text and the PDF render. |
| Address mapping | Memory is mapped "starting at Pair 3, if it exists… through to Pair 0". The SH95 example mixes 32/16/32/8 MB pairs, so pairs need not match each other. | SH95 4‑26…4‑28 |
| Max RAM | "Model 715 can only use up to 256 MB. Any address 0x10000000–0xEFFFFFFF is invalid." | SH95 4‑24 note 3 |
| 715/64 | 32–256 MB [TD64 PDF p.6; SH95 1‑2; HCL p.22]. OG94 1‑3 says **16**–256 MB, which conflicts. | |
| 715/80, /100, /100XC | 32–256 MB | SH95 1‑2; HCL |
| 715/33, /50, /75 | 8–192 MB (8 MB diskless only), 16–256 MB, 32–256 MB | TD75 PDF p.2; SH95 1‑2 |
| Factory configurations | Base SPU ships with 32 MB. Options: ANN = 64 MB as 8×8 MB, UFT = 64 MB as 2×32 MB, ANY = 128 MB as 4×32 MB, UFN = 256 MB as 8×32 MB. **(inference)** The base 32 MB is 4×8 MB. | QRG p.5 |
| Upgrade kits (pairs) | A2577A 8 MB (2×4 MB), A2578A 16 MB (2×8 MB), A2829A 32 MB (2×16 MB; the HCL misprints it as "2 MB"), A2827A 64 MB (2×32 MB). No 64 MB SIMM is listed for the 715. | QRG p.5; HCL p.22–23; TRM712 1‑2 |
| SIMM FRUs | 98236‑66520 (2 MB), 98236‑69522 (4 MB), 98236‑69524 (8 MB), A2576‑69001 (16 MB), A2575‑69001 (32 MB) | SH95 5‑3 |
| Memory controller | Inside the PA‑7100LC ("MIOC") | SH95 Fig 6‑3; LASI App. B; PCXL §9 |
| Memory test | Self-test does a quick memory test while `fastboot` is on (the default). `FASTSIZE` sets how much memory is initialized. `fastboot off` makes the test destructive and exhaustive. | OG94 D‑17; SH95 4‑15, 4‑28 |
| OS minimums | HP‑UX 10.20 needs ≥16 MB and 11.0 needs ≥32 MB | HCL p.22 |

---

## 3. Graphics

### 3.1 Built-in graphics

The built-in graphics is 8‑plane with HP Color Recovery ("approximately 8 million simultaneous colors… using 1/3 the VRAM of the 24-bit system"). It is integrated on the CPU board [TD64 PDF p.1–2; QRG p.2].

- The Mirage models are **autoconfiguring**: there are no graphics configuration switches, unlike the 715/33/50/75 [SH95 1‑8, 3‑17; OG94 1‑13, B‑57].
- You set the monitor type with `BOOT_ADMIN> monitor [type]`. If the monitor is unknown at power-on, press **Tab** after the keyboard LEDs flash. The firmware then cycles through the types and you confirm with `y` [OG94 B‑60…B‑63]. On the 712 the choice is "retained in stable storage" [SH712 1‑2].
- Monitor type table for the 715/64/80/100 [OG94 B‑61]:

  | Type | Mode |
  |---|---|
  | 1 | 1280×1024 at 72 Hz |
  | 2 | 1024×768 at 75 Hz |
  | 3 | 1024×768 at 70 Hz |
  | 4 | 1024×768 at 75 Hz (flat panel) |
  | 5 | 1280×1024 at 60 Hz |
  | 6 | 1024×768 at 60 Hz |
  | 7 | 640×480 at 60 Hz |
  | 8 | 1280×1024 at 75 Hz (VESA) |
  | 9 | 1024×768 at 75 Hz (VESA) |
  | 10 | 800×600 at 75 Hz (VESA) |
  | 11 | 640×480 at 75 Hz (VESA) |

  The 712 adds 12 = 1280×1024 at 72 Hz greyscale and 13 = 1280×1024 at 50 Hz [SH712 3‑16].
- **1280×1024 at 72 Hz timing** for HP A2094A/A2088A monitors [SH95 8‑3…8‑5]:
  - Pixel clock 135.00 MHz.
  - Horizontal: 78.125 kHz, 1280 visible, front porch 0.474 µs, sync 1.422 µs, back porch 1.422 µs (1728 clocks total).
  - Vertical: 72.005 Hz, 1024 visible, front porch 3 lines, sync 3 lines, back porch 55 lines (1085 lines total).
  - Video is RGB with sync on green per RS‑343A.
- Sales monitors are a 17″ and a 20″ multisync (50–150 Hz) at 1280×1024 [TD64 PDF p.2, 8–9; QRG p.5 options AQ5 and AQ7]. SH95 1‑2 lists 19/20″ and 17″ 1280×1024 color monitors.
- **VRAM size: GAP.** No 715 document states it. SH95 Fig 6‑3 draws "VRAM" plus "Optional 1280x1024 VRAM", which looks copied from the 712: the 712 needs the A4025A VRAM board for 1280×1024 [TRM712 1‑2, 2‑4]. TD64 lists 1280×1024 as standard on every 715/64‑100.
- The 712 graphics ASIC is "NGLE compatible" and supports VESA 1280×1024, 1024×768, 800×600 and 640×480 at 75 Hz [TRM712 2‑4]. **(inference)** The same applies to the 715/64.
- HW path is **`1.0.0`** with driver `grap3` (HP‑UX 9.05 ioscan on a 715/64) [OG94 3‑5].

### 3.2 Optional graphics (one shared EISA/GSC slot)

| Option | Bus | Supported on | Source |
|---|---|---|---|
| HCRX‑8 (A4070A), 8/8 plane, Color Recovery | GSC | 715/64/80/100/100XC | QRG p.5 (AQF); HCL p.64 |
| HCRX‑24 (A4071A), 24 plane + 8 overlay | GSC | same | QRG AQG; HCL p.64 |
| HCRX‑8Z and HCRX‑24Z (A4072A Z‑buffer/accelerator daughter card) | GSC | same | QRG AQH, AQJ; HCL p.64 |
| CRX‑48Z (A4073A/B GSC interface + external processor) | GSC to SGC‑ext | **715/100 only** | QRG AQK; HCL p.64; TD64 PDF p.5 |
| A4077A/B "CR 2D color video" second head | GSC | 715/64, /100 | HCL p.64 |

- These are EISA-form-factor GSC cards with a D‑sub connector, attached to the CPU board by a **flex cable** [SH95 1‑11, 5‑35].
- A GSC graphics card and an EISA card cannot both be fitted: "If you have an optional CRX or HCRX graphics board installed… you may not install an EISA option board" [OG94 B‑64; HCL p.126 notes 130/131 and Appendix A p.168].
- GSC slot: 1 slot, 32-bit address. Peak 114 / 142 / 118 MB/s for the 64 / 80 / 100 (32-byte block move out) [TD64 PDF p.7].
- **Standard vs most capable.** The standard option is the integrated 8‑plane Color Recovery graphics, which every SPU ships with [QRG p.5 "SPU with integrated graphics"]. The most capable option is the CRX‑48Z on the 715/100 ("fastest graphics accelerator for the Model 715", 24/24-plane double-buffered, Z-buffered) [QRG p.4; TD64 PDF p.5]. On the 715/64 and 715/80 the most capable is the HCRX‑24Z.
- Console on an add-in card: `path console graphics_2` [SH95 3‑20, 3‑23, for the older CRX procedure].

---

## 4. Keyboard and mouse

| Models | Interface | Source |
|---|---|---|
| 715/33, /50, /75, /C, s, t | HP‑HIL only (AMP SMD connector, 1.0 A, 7 devices per loop). No PS/2. | SH95 1‑3, 1‑9; TD75 PDF p.5; HCL p.76 |
| **715/64, /80, /100, /100XC** | A **10‑pin modular jack** ("SMD‑10") on the rear goes over cable A4022‑62003 to the **Keyboard Adapter Module A4022‑62005**. The module has **2 × mini‑DIN (PS/2 keyboard and mouse) and 1 × HP‑HIL**. HCL: "PS/2: Yes, if HIL not used. HP‑HIL: Full, if PS/2 not used." | SH95 1‑3, 1‑9, 5‑4; OG94 1‑3 footnote, 1‑11; HCL p.76, p.79 |

- PS/2 electrical spec: IBM PS/2 compatible, mini‑DIN pair, "2.5K 11‑bit samples/sec", 4 A fused [TD64 PDF p.7].
- Keyboards: ITF A1099C (HIL), PC‑101 HIL C1429A/B, AT/PS/2 A4030A/B. Mice: A2839A (PS/2) and 46060 (HIL). There is a PC/AT‑to‑ITF key-equivalence table [SH95 1‑14…1‑16; OG94 1‑18…1‑20].
- BCH keyboard paths: `hil` for the 715/33/50/75 and **`ps2`** for the 715/64/80/100 [OG94 D‑12 Table D‑2].
- PS/2 implementation:
  - On the 712, LASI has two "simple serial ports… 6 one-byte registers for each port" [TRM712 2‑5].
  - HP‑UX 9.05 ioscan on a 715/64 shows `2.0.11 ps2` and `2.0.12 ps2` [OG94 3‑5].
  - HIL on Mirage comes from WAX ("Mirage … Wax HIL") [VER].

---

## 5. SCSI and mass storage

| Item | Value | Source |
|---|---|---|
| Controller | NCR 53C710 macrocell inside LASI (the "I/O ASIC"). Fast/wide differential is only possible with an EISA card (25525B). | TRM712 1‑3; LASI ch.3; QRG p.5; OG94 C‑4 |
| Bus | One **8-bit (narrow) single-ended SCSI‑2** bus, internal and external. 5 MB/s synchronous, 1.5 MB/s asynchronous. 7 devices. External connector is ALT‑1 50‑pin high density. | TD64 PDF p.7; SH95 1‑3 |
| HW path | `2.0.1` (driver `c700`). Devices are `2.0.1.<id>.0`. BCH notation is `scsi.<id>.<lun>` or `2/0/1.<id>.<lun>`. | OG94 3‑5, 4‑9; SH95 4‑16 |
| Internal bays | Two 3.5″ hard disks plus one removable bay (3.5″ floppy, or 5.25″ CD‑ROM or DDS). Max internal 4 GB [TD64 PDF p.2] or 2 GB [TD64 PDF p.7], which conflict. Total with external storage is 84 GB. | SH95 1‑1; OG94 1‑2 |
| Default IDs | Disk 1 = 6, disk 2 = 5, CD‑ROM = 2, DDS = 3, host = 7. On the 715/64‑100 the floppy is **PC-style (non‑SCSI)**. Remove terminators from internal drives. | SH95 3‑1, 3‑2; OG94 B‑24 |
| Disks | 525 MB (Quantum LPS525S, Seagate), 1 GB (Micropolis, DMD, DEC, Seagate, HP, Quantum), 2 GB (DEC, Seagate, Quantum, HP) | SH95 1‑2, Figs 3‑2…3‑10 |
| HP‑UX limits on this bus | Up to 7 disks, but only 1 floppy, **1 CD‑ROM**, 2 DDS and 1 MO | OG94 C‑4/C‑5 Table C‑1 |
| **CD‑ROM** | Internal **A2803A** ("internal 1× or 2×", minimum boot ROM "IODC 1.1") [HCL p.43]. FRU A1658‑69001/‑69002 [SH95 5‑3]. Shows up in the boot search as "TOSHIBA CD‑ROM DRIVE:XM" [SH95 4‑13; OG94 D‑4]. The SH95 jumper figure is the **Toshiba XM‑3301B** [SH95 Fig 3‑12, p.3‑13]. Caddy-loading drive with a front headphone jack and volume control ("supported through applications only") [OG94 4‑2/4‑3]. 600 MB, "2X", 180 ms average access [TD64 PDF p.2, 8]. Later internal options: A4325A/A4326A 4×, A4489A 12× [HCL p.43]. | |
| CD‑ROM caveat | "Drives which identify as XM3201B do not function correctly on … 712, 715/64, 715/80, 715/100, 715/100XC… XM3301B do not function correctly on these models if another CD‑ROM drive is present on the same bus" | HCL p.45 note 45 |
| Boot from CD | Supported. CD‑ROM at `scsi.2.0` appears in the BCH boot search. "SCSI devices are bootable when connected to the SCSI port on the System card". SH95 suggests "connecting an external CD‑ROM drive" as a recovery boot method. The HCL "Min. Boot ROM" column gives the PDC revision needed to boot an install system from each device. | SH95 4‑13, 4‑14, 4‑16; OG94 D‑4; HCL p.43, p.52; TRM712 1‑5 |
| CD device file (HP‑UX 9.x) | `/dev/dsk/c201d2s0`, ISO 9660 and High Sierra | OG94 4‑2, 4‑10 |
| DDS | C1503 (2 GB), C1504 (4–8 GB) | SH95 5‑3 |
| Floppy (715/64‑100) | PC-style 1.44 MB (A4180A, FRU 0950‑2377) on board connector J2 [SH95 5‑3, Fig 5‑47]. Path `2.0.10`, drive `2.0.10.1.0`, device `/dev/rfloppy/c20Ad1s0` [OG94 3‑5, 3‑6]. MFM/FM 1.44 MB and 720 KB [TD64 PDF p.8]. | |

---

## 6. Audio

| Item | Value | Source |
|---|---|---|
| Codec | **Crystal CS4215** (the scan reads "OS4215"). HCL lists "CS4215(S)" for the 715/64/80/100/100XC, and also for the 715/33/50/75. | OG94 1‑6; HCL p.78 |
| Controller | LASI **"Harmony"** TDM audio/telephony block. It talks to the codec over a modified Concentration Highway (CHI) bus. It supports the CS4215 or the AD1849 and is software compatible with "the audio circuitry of early 715s". | LASI ch.6 §6.1; VER "Mirage Audio" (0x7B) |
| Path | `2.0.8 audio` | OG94 3‑5 |
| Rates | 8, 16, 32, 48, 11.025, 22.05 and 44.1 kHz [OG94 1‑6]. TD64 says "many rates between 4K & 48KHz" [TD64 PDF p.7]. | |
| Formats and gain | 16‑bit linear, 8‑bit µ‑law, A‑law. Output attenuation 0–96 dB in 1.5 dB steps. Input gain 0–22.5 dB in 1.5 dB steps. Input monitoring. | OG94 1‑6 |
| Inputs | **Front**: mono microphone with 1.5 V bias on the ring. **Rear**: stereo line in. **Internal**: "CDROM audio (if internal CDROM is installed)". HCL: Line‑In "Rear, Int.". | OG94 1‑5, 1‑6; SH95 1‑4; HCL p.78 |
| Outputs | **Front**: stereo headphone (or line out). **Rear**: stereo line out. **Internal**: mono speaker. | OG94 1‑5, 1‑6, 1‑16 |
| CD audio routing | **Yes, analog.** A 3‑pin CD audio cable (A2084‑62020) runs from the drive's rear audio connector to the CPU board: "connector P5" [OG94 B‑30 Fig B‑22], labelled "CD‑ROM Audio Board Connector (10)" on the 715/64‑100 board figure [SH95 Fig 5‑47; Fig 5‑13]. Whether CD audio is *summed* with rear line‑in or *switched* against it is not documented (**GAP**). There is no CS4215 datasheet in the folder (**GAP**). | |
| Tone generator | "Three independent time generators controllable over 30db frequency range — 81.46Hz to 83.3KHz. Speaker is built in" [TD64 PDF p.7; same in TD75]. **(inference)** This is the HP‑HIL keyboard sound generator: WAX §5.5 is "Sound Generator communication" through the HIL 8042 interface. | |
| Board connectors (715/64‑100) | Rear audio board P15, front audio board P12, speaker P13 | SH95 Fig 5‑47 |
| Diagnostics | `tdiag` audio loopback, test cable 46081‑61601 | SH95 4‑19 |

---

## 7. Other I/O

| Item | Value | Source |
|---|---|---|
| Serial | Two 9‑pin male DTE RS‑232 ports, full modem pin-out (Table 1‑2). "Both ports operate at up to 19.2K baud" [SH95 1‑9]. "To 460.8 Kbps" [TD64 PDF p.7], which conflicts. The 712's port is a 16550 [TRM712 1‑3]. **(inference)** On Mirage, port A is in LASI ("Core RS‑232", path `2.0.4 asio0`) and port B is in WAX ("Wax RS‑232") [VER; OG94 3‑5]. BCH names them `rs232_a` and `rs232_b` [OG94 D‑12]. | |
| Parallel | 25‑pin female "HP Parallel" (Centronics with BUSY handshake). 300+ KB/s with DMA, 200 KB/s sustained. Path `2.0.6`. LASI emulates the WD16C522 for 720/730 driver compatibility. | TD64 PDF p.7; OG94 3‑5; LASI §5.2 |
| LAN | IEEE 802.3, 10 Mb/s, **15‑pin AUI only** on the 715. 10BASE2, 10BASE5 or 10BASE‑T need an external transceiver (ThinLAN 28641B, EtherTwist 28685B). Path `2.0.2` (BCH `lan.` or `2/0/2.`). Controller is an Intel 82596CA through LASI [TRM712 2‑3; LASI ch.4]. LAN station address is in stable storage [SH95 4‑15]. On the 712 it is in flash [LASI §4]. | TD64 PDF p.7; SH95 1‑2, 4‑16; OG94 3‑5 |
| ISDN | Not built in on the 715. Available as an EISA card, "ISDN BRI ISA/EISA Adaptor J2460A" [QRG p.5]. Harmony has ISDN capability (712 "Core ISDN" exists in VER) but no Mirage ISDN entry. | |
| Floppy | See §5 | |
| EISA | **One** slot through the WAX EISA BA and an adapter board (A2084‑66002, EISA kit A2804A). 32‑bit address and data, 33 MB/s sequential memory write. It shares its bulkhead with the GSC graphics slot. Cards: 25525B FW‑diff SCSI, A2679A SE SCSI, 25560A HP‑IB, 25567B LAN, J2165A 802.5, J2159A X.25, A2544A Apollo Token Ring, J2460A ISDN. | TD64 PDF p.7; SH95 5‑5 Table 5‑2; QRG p.5; HCL p.125 |
| Expansion summary | 1 × (EISA **or** GSC graphics). No other slots. | HCL p.125–126 note 131; Appendix A p.168 |
| Front panel | Power and TOC switches. The Mirage models have **soft power-down** (the OS shuts the file system down when power is switched off) [SH95 1‑4; OG94 1‑5]. **(inference)** This maps to LASI's power-fail interrupt and power control register PCR at 0xF010C000 (`PWR_ON_L`, `FLASH_LED`) [LASI §12.3/12.4]. | |
| LEDs | 8 amber status LEDs (8…1, left to right) plus a green power LED. In normal running, LED4 is the OS heartbeat, LED3 disk access, LED2 LAN receive and LED1 LAN transmit [OG94 1‑8 Table 1‑1; SH95 1‑6]. Error codes are in §8.4. **How software drives the 8 LEDs (register or address) is a GAP**: the 712 has only a power LED. | |
| RTC | Battery-backed "Calendar Battery" BR‑2325 3 V lithium at location B1 [SH95 5‑51]. In LASI, the RTC is a 32‑bit seconds counter clocked from 32.768 kHz [LASI ch.8]. The BCH **`date` command is not implemented on the 715/64/80/100** [OG94 D‑14; SH95 4‑14]. | |
| Stable storage / NVRAM | "Non-volatile memory associated with each PA‑RISC processor module". It holds device paths, boot flags, HPMC PIM data and OS initialization data [SH95 4‑15]. Byte layout from ISL: primary path bytes 0–31, console path 96–127, alternate path 128–159, keyboard/mouse path 160–191. `readss` reads words 0–255 [SH95 4‑19]. | |
| EEPROM | The 715/C, 33, 50 and 75 have a socketed **EEPROM at UV17** that holds I/O configuration and the software licence. It moves to the replacement board, **except** for the 715/64/80/100/100XC, which have no EEPROM FRU [SH95 5‑3, 5‑45, 5‑50]. On LASI systems, PDC and stable store are in **two un-socketed flash EPROMs** (256 KB, AM29F010) on LASI's 8‑bit bus, replacing "two EPROMs with sockets and an EEPROM" [LASI §11.1–11.2]. **(inference)** The 715/64 is the same. The 715 documents do not say so explicitly (**GAP**). | |
| Telephony | SH95 Fig 6‑3 shows "TeleShare", "Audio & TeleShare interface" and "Twisted Pair" LAN. These appear to be **copied from the 712 diagram**. No 715 FRU, option or connector exists for them [SH95 5‑3…5‑5; TD64]. | |
| Power | 143 W output: +5 V 22 A, +12 V 3 A, −12 V 0.1 A, −5 V 0.1 A, +12 V HIL 1 A, 5 V SCSI 1 A. Remote on/off and +5 V aux [TD64 PDF p.8; SH95 6‑1/6‑2]. | |

### 7.1 HP‑UX 9.05 hardware path map, 715/64/80/100 [OG94 3‑5]

```
1.0.0      grap3     (built-in GSC graphics)
2.0.1      c700      (LASI SCSI)        2.0.1.6.0  disk
2.0.2      unknown   (LAN; BCH "2/0/2")
2.0.4      asio0     (RS-232)
2.0.6      parallel
2.0.8      audio
2.0.10     floppy    2.0.10.1.0 disk
2.0.11     ps2       2.0.12     ps2
```

For contrast, Scorpio examples show `0.0.0 graphics` and `2.0.1 scsi` [OG94 4‑9; SH95 4‑22].

### 7.2 Physical address map (nearest documented equivalent)

The 715 documents give no register-level map (**GAP**). The closest are below.

**712 system memory map** [LASI App. B, p.105]:

| Range | Use |
|---|---|
| 0000 0000–EFFF FFFF | Memory |
| F000 0000–F00F FFFF | LASI ROM space (flash PDC) |
| F010 0000–F01F FFFF | LASI I/O |
| F020 0000–F020 7FFF | WAX I/O |
| F040 0000–F05F FFFF | Second LASI |
| F100 0000–F3FF FFFF | "PDC will look here for IODC" |
| F400 0000–F5FF FFFF | Second ARTIST |
| F800 0000–F9FF FFFF | ARTIST |
| FC00 0000–FFBF FFFF | WAX EISA space |
| FFFB E000 | CPU |
| FFFB F000 | MIOC |
| FFFC 0000–FFFF FFFF | Local/Global broadcast |

**LASI internal offsets.** The LASI ERS (App. A) lists the I/O map, for example the RTC at +0x9000. QEMU uses LPT +0x2000, AUDIO +0x4000, UART +0x5000, SCSI +0x6000, LAN +0x7000, PS2 +0x8000, RTC +0x9000, FDC +0xA000, PCR +0xC000.

**715 SH PIM decode table** [SH95 4‑24]:

| Range | Action |
|---|---|
| F000 0000–F7FF FFFF | Motherboard |
| F800 0000–FBFF FFFF | Optional graphics |
| FC00 0000–FFBF DFFF | EISA controller |
| FFFB E000–FFFB EFFF | CPU (replace motherboard, or the PCX‑T module on a 715/75) |
| FFFB F000–FFFF FFFF | Motherboard |

This table is compatible with the 712 map. The 712 version is in SH712 4‑5.

**QEMU 715** cross-check: firmware at 0xF0000000–0xF00FFFFF, LASI at 0xF0100000, Artist registers at 0xF8000000 and framebuffer at 0xF9000000. **No WAX, EISA, HIL, floppy, second UART or Harmony audio device is instantiated** [QEMU `hppa_hardware.h`, `machine_HP_715_init`].

---

## 8. Firmware: boot ROM, PDC and the Boot Console Handler

### 8.1 Revisions and storage
- **Base boot ROM revision** for the 715/64, /80, /100 and /100XC SPUs (A4090A, A4093A, A4091A, A2060A‑A2063A) is **2.7**. A4340A (715/100XC SPU) lists "Any". The 715/33 and /50 list 1.1 and the 715/75 lists 1.2 [HCL p.11–14].
- Some peripherals need a minimum boot ROM. For example, the Freedom graphics cards need 2.7 and the A2803A CD needs "IODC 1.1" [HCL p.43, 65].
- ISL banner example: "ISL Revision A.00.24 Oct. 7, 1992" [SH95 4‑18].
- **ROM size and location: not stated for the 715 (GAP).** On LASI systems PDC sits in 256 KB of flash on LASI's 8‑bit bus at "LASI ROM space" 0xF0000000. Reads take about 75 GSC cycles. The flash is software-erasable. ODE `update` "updates the system's PDC firmware on the FEPROM" [LASI §11; SH712 4‑16]. **(inference)** The 715/64 is the same.
- The self-test screen shows "BootRom Version xxx.x / Memory Size: xx MB / Press <ESCAPE> to stop boot sequence" [TRM712 2‑1; SH712 4‑10].

### 8.2 Power-on flow and how paths are chosen
1. "POWER‑ON > SELFTEST > CONSOLE PATH > BOOT ADMIN MODE > BOOT PATH > ISL MODE > HP‑UX MODE" [SH95 4‑23].
2. Console:
   - The console path comes from stable storage. It can be graphics, `rs232_a.<baud>.<bits>.<parity>` or `rs232_b…`. The keyboard path is `ps2` or `hil`.
   - Example: `path console rs232_a.4800.7.even` [OG94 D‑11…D‑13].
   - If console initialization fails, LED codes 0x69 or 0x2A are shown (§8.4).
   - The Tab key at power-on triggers automatic monitor selection [OG94 B‑62].
3. Boot path selection:
   - With **Autoselect on** (the default), the firmware boots the primary path. Holding **ESC** at "Selecting a system to boot…" interrupts this.
   - The firmware then searches in the order built-in SCSI, built-in LAN, EISA, and labels hits P0…P9, then P* [SH95 4‑13; OG94 D‑3, D‑8, D‑9].
   - The interactive menu offers b) Boot, s) Search, a) Boot Administration, x) Exit, ?) Help [SH95 4‑14].
4. `boot <dev> isl` stops at the `ISL>` prompt. `hpux boot disc(;0)/hp-ux` loads the kernel [SH95 4‑18; OG94 D‑7].

### 8.3 BCH (`BOOT_ADMIN>`) commands [SH95 4‑14, 4‑15; OG94 Appendix D, B‑60]

| Command | Function |
|---|---|
| `auto`, `autoselect on/off` | Autoboot flag, stored in non-volatile memory |
| `boot [pri\|alt\|scsi.x.y\|lan.…\|Pn\|path] [isl]` | Boot a device |
| `date` | **Not on the 715/64/80/100** |
| `exit` | Return to the menu |
| `fastboot on/off` | Quick or extensive memory test |
| `fastsize` | Amount of memory initialized |
| `help` / `h` / `?` | Help |
| `info` | Model, version numbers, jumpers |
| `lan_addr` | Show the station address. It is set with `ss_config`. |
| `monitor [type]` | Graphics mode (Mirage) |
| `os` | Choose the OS |
| `path [pri\|alt\|con\|key] [value]` | Show or set paths |
| `pim_info` | Last HPMC/LPMC/TOC PIM data. The 712 uses `pim`. |
| `reset` | Reset |
| `search [scsi\|lan\|eisa]` | Find bootable media |
| `secure on/off` | Secure boot |
| `show` | **Not on the 715/64/80/100** |

ISL commands: `display`, `primpath`, `altpath`, `conspath`, `lsautofl`, `support`, `readss`, and the utilities `tdiag`, `eisadiag` and `iomap` [SH95 4‑19/4‑20]. The 712 also has ODE: `lasidiag`, `ldiag`, `memtest`, `update`, `mapper` [SH712 4‑16].

### 8.4 LED error codes, 715/64/80/100/100XC

Source: SH95 Table 4‑5 (p.4‑11/4‑12) and OG94 Table 6‑9 (p.6‑13/6‑14). I decoded the bit patterns visually at 300 dpi. In the hex column bit 7 is LED8 and bit 0 is LED1.

| Status | LEDs 8…1 | Hex |
|---|---|---|
| CPU Error | 0100 0001 | 0x41 |
| Fatal Error | 0010 0011 | 0x23 |
| RAM Test Error | 0010 0001 | 0x21 |
| Cache Error | 0100 0010 | 0x42 |
| FP Co-processor Error | 0100 0100 | 0x44 |
| Fatal FP Co-processor Error | 0010 0100 | 0x24 |
| I/O Device Error | 0100 1000 | 0x48 |
| ROM Checksum Error | 0100 0011 | 0x43 |
| HPMC Error | 0010 1100 | 0x2C |
| HPMC due to Cache Error | 0010 0010 | 0x22 |
| HPMC due to Bus Error | 0010 0101 | 0x25 |
| HPMC due to Memory Error | 0010 0111 | 0x27 |
| Console Initialization Error | 0110 1001 | 0x69 |
| No working console found, unable to boot | 0010 1010 | 0x2A |
| No bootable device found | 0110 1010 | 0x6A |
| Memory Error | 0110 1100 | 0x6C |
| Initialization Error | 0110 0110 (SH95). OG94 prints 0110 1100, the same as Memory Error, which is probably a misprint. | 0x66 |

- Other patterns: LEDs 8 and 4 lit (0x88) while self-test checks CRX/HCRX graphics [SH95 4‑30].
- The Scorpio models have much richer tables: per-SIMM-slot memory codes, PDC, ISL and kernel progress codes [SH95 Tables 4‑1…4‑4].
- HPMC triage uses PIM words: Check Type, Cache Check, Bus Check and System Responder Address [SH95 4‑23…4‑29].

### 8.5 What the ROM expects of the hardware (documented hints only)
- Memory in identical pairs, up to 256 MB. Responder addresses at or above 0x10000000 are invalid [SH95 4‑24…4‑28].
- Non-volatile stable storage of at least 256 bytes, with the layout in §7 [SH95 4‑19].
- A console reachable through IODC: graphics, RS‑232 or PS/2/HIL.
- The station address in stable storage.
- An RTC.
- A soft-power interface.
- A graphics card that can be autodetected and switched by `monitor`.

Everything else (PDC entry points, IODC per device, PDC_MODEL/HVERSION/SVERSION values, CPU-speed sensing) is **not in the system documents (GAP)**. Use `Pdc11-v0.96-Ch1-procs`, `Pdc11-v0.96-Ch3-IODC`, `Ver_nums` (the IDs in §1), `Sti` (graphics ROM), LASI/WAX ERS and QEMU/SeaBIOS‑hppa.

---

## 9. Operating-system support

| Model | HP‑UX | Source |
|---|---|---|
| 715/64, /80, /100 | "9.05 or later" [SH95 1‑1; OG94 1‑21; TD64 PDF p.6]. HCL standalone: **9.05–11.0/32** (HP‑UX 11.00 32‑bit only). Diskless server and client: 9.05–9.07, then a gap, then 10.01–10.20 (final). | HCL p.7–8 |
| 715/100XC | 9.05 or later [SH95]. HCL: 9.05–11.0/32 (A2063A TCO). The A4340A SPU entry says "9.05–9.07, gap, 10.10–11.0/32", so 10.01 is **not** supported. | HCL p.8, 11, 14 |
| 715/33, /50 | 9.0 [HCL] or 9.01 [SH95/OG94] up to 10.20 (final) | |
| 715/75 | 9.0 [HCL] or 9.03 [SH95/OG94] up to 10.20 (final) | |

- HP‑UX 10.0 has no diskless support. 10.20 needs ≥16 MB and 11.0 needs ≥32 MB [HCL p.9, p.22].
- **HP‑UX 11i: GAP.** The HCL edition is July 1998, before 11i.
- **Other operating systems: GAP.**
  - The documents mention "DOS emulation" (SoftPC) and "bi-endian switching for current and future operating systems" [SH95 1‑1; TD64 PDF p.1].
  - No Linux, BSD or NeXTSTEP information appears. The only Linux material is the HTML page `artist_graphics_registers.html` from the Linux‑on‑PA‑RISC documentation.

---

## 10. Document relevance

| Relevance | Documents |
|---|---|
| **Primary: 715/64‑100 system** | TD64, DS64, QRG, OG94, SH95 (three identical copies: `715_service-handbook`, `715_ServiceHandbook_…_OCR`, `lpv37699`), HCL `980723` and `980723ng` |
| **Primary: chips and firmware IDs for Mirage** | `Lasi_ers` (and `chips/lasi_ers.*`), `WAX_ERS_V1.0_Redacted`, `Ver_nums` (and `arch/ver_nums`), `PCXL_ers` (PA‑7100LC), `82596CA` (LAN), `artist_graphics_registers.html` (Artist registers, 712), `Sti` (STI graphics/console ROM), `Pdc11-v0.96-Ch1-procs` and `Pdc11-v0.96-Ch3-IODC` (PDC for PA 1.1), `Pa11_acd` (PA‑RISC 1.1 architecture). These were not reviewed in depth here beyond the citations above. |
| **High: sister machine (same LASI/7100LC/GSC platform)** | `712_technical_manual`, `712_service-handbook` |
| **Medium: older 715 (contrast) and Series 700 siblings** | TD75, `715-33-50_TechData_5091-5779E`, SP92, OG93, HIG (HIL era), SG93, `735_service`, `720-730_owners-guide`, `750_owners-guide` (BCH semantics), `Hardball_ers` (735/755 core I/O), `Pcxl2_ers` and `Pa7300lc_*` (PA‑7300LC, the CPU QEMU uses for its 715) |
| **Low: software/toolchain (useful later for HP‑UX binaries)** | `Pa-runtime-32-SOM`, `Unwind`, `symtab32_h`, `elf-pa*`, `92432-90012` (HP Assembler), `Rad_11_0_32`, `PA_PerfGuide_vs2` |
| **Irrelevant: other machines, PA 2.0/64-bit, Itanium** | `A180`, `A180-user`, `Users_Manual_HP_9000_Model_A-180`, `B1xx-*`, `C100_110-owners`, `C160*`, `Cxxx-service`, `HP_C8000_Manual`, `J280_owners`, `Emr_na-c01865801-1` (rp24xx), `Lpv00338_rx2600_zx6000`, `Astro_*`, `Elroy_ers`, `Dino_ers` and `Dino_3_1_Errata` (GSC‑PCI, B/C/J class), `Zx1-*`, `Mako_mpf_2001`, `PA-8700wp`, `Isscc*`, `Four_way_superscalar`, `Pa7200_design`, `Pa8000-compiler_opt`, `Pa2c96`, `Parisc2.0`, `Pa64rt`, `pa64supp`, `elf-64-*`, `Pdc20-*` (PDC 2.0; concepts only), `E-class_hpjournal`, `feb96a6`, `GSP_User_Guide`, `A3725-96022` (V‑Class), `PC87415` (PCI IDE), `AD1819` and `AD1889` (AC'97; the 715 uses a CS4215). `Pa-arch.zip` and `Pa-chips.zip` are archives I did not open. |

---

## 11. Recommendation: which 715 to recreate

**Target the HP 9000 Model 715/64 (Mirage Jr, CPU HVERSION 0x60A).** Build the board so the CPU ID and PDC model data can also present a 715/80 (0x619) or 715/100 (0x60B).

Reasons:

1. **Every requirement is met by all Mirage models in the same way, and by no Scorpio model.**
   - The 715/64, 80 and 100 share one platform: 8‑slot ECC memory up to 256 MB, LASI+WAX I/O, built-in 8‑plane Color Recovery graphics plus one GSC/EISA slot, a narrow SE SCSI‑2 bus with internal CD‑ROM audio cabling, the CS4215 codec, and the PS/2 Keyboard Adapter Module [SH95 1‑2/1‑3, Figs 5‑47 and 6‑3; TD64 PDF p.6–7; HCL p.21–22, 76, 78].
   - They differ only in CPU clock, memory-bus peak (170 vs 267 MB/s) and CRX‑48Z eligibility on the 715/100.
   - The Scorpio models (33/50/75) have **no PS/2**, use SGC rather than GSC, and stop at HP‑UX 10.20 [HCL p.7, 76].
2. **QEMU's "715" machine is explicitly an "HP 715/64 workstation".** Its addresses (LASI at 0xF0100000, firmware at 0xF0000000, Artist at 0xF8000000) match the documented LASI map [QEMU; LASI App. B]. Targeting the same model keeps PDC/IODC identities, the HW path map (`1.0.0`, `2.0.x`) and the HP‑UX kernel configuration directly comparable during bring-up. Using the same model also makes it straightforward to compare traces and ROM behaviour between QEMU and the FPGA.
3. **Clock realism.** A soft PA‑7100LC on a Cyclone V will run well below 100 MHz **(inference)**. Advertising the slowest model (64 MHz) keeps the model identity closest to the achievable speed. Whatever the real clock, PDC must report the true interval-timer rate. The system documents do not describe how PDC senses or reports this (**GAP**).
4. **OS coverage.** The 715/64, 80 and 100 support HP‑UX 9.05 through 11.00 (32-bit), with no gaps in standalone support [HCL p.7–8].
5. **Avoid the 715/100XC**: its cache size is undocumented, it has a 10.01 support gap, and it is barely documented. **Avoid the 715/100 as primary target**: its only extra is CRX‑48Z support, which would require an external graphics processor and is irrelevant to the FPGA. It also brings a faster memory bus and a 100 MHz identity that the FPGA will not match.

Implications for the FPGA, derived from the documents (not RTL):
- 256 MB of RAM must live in the DE10‑Nano DDR3 (HPS side). A MiSTer SDRAM module is too small. ECC can be modelled as never failing.
- Built-in graphics at 1280×1024×8 needs at least 1.25 MB of framebuffer. The native 72 Hz mode needs a 135 MHz pixel clock [SH95 8‑3], so a scaler or a lower monitor type (for example type 2, 1024×768 at 75 Hz [OG94 B‑61]) is worth planning for. Monitor-type selection is a firmware feature.
- CD audio needs (a) an emulated SCSI CD-ROM that returns an HP-qualified identity (the XM‑3301B family is documented; avoid XM‑3201B per HCL note 45) and implements SCSI audio-play commands, and (b) an analog-equivalent mix of CD‑DA into the CS4215 line-in path.
- Supporting PS/2 means implementing the LASI PS/2 ports. HIL, the second serial port and EISA are on WAX, and QEMU does not implement WAX, so WAX can be deferred.

---

## 12. Gaps, contradictions and unverified items

**Not answered by the documents**
1. Built-in graphics VRAM size, and whether the 715/64 needs a VRAM option for 1280×1024. SH95 Fig 6‑3 says "Optional 1280x1024 VRAM" but TD64 says 1280×1024 is standard.
2. The name "Artist" never appears in the 715 documents; it is inferred (§1.2). No 715-specific register map exists. The nearest are LASI App. A/B (712) and `artist_graphics_registers.html`.
3. Register and address map for the 715/64. Only the 712 LASI map, the SH95 PIM ranges and QEMU are available.
4. PDC/boot ROM size, location and technology on the 715/64 (flash vs EPROM), and where stable storage physically lives. Inferred from the 712.
5. Where the 8 front-panel status LEDs are wired (register or address).
6. 715/100XC cache size and clock. More generally, no document maps the Mirage code names to 715 model numbers. That Mirage Jr is the 715/64 and Mirage 100+ is the 715/100XC comes from the Linux strings in the brief.
7. Meaning of the VER IDs "Scorpio 100 (715/100)" 0x317, "Scorpio‑L 80/100/120" and "715/132, 715/160 L2 upgrade". Also the 715/C CPU.
8. The ASIC names for the Scorpio 715s (ASP, Cutoff, Mongoose are not mentioned for the 715).
9. Whether CD audio is mixed with or switched against line-in. No CS4215 datasheet is in the folder.
10. PDC internals: entry points, IODC per device, CPU-speed and interval-timer reporting, HVERSION/SVERSION values the OS checks beyond the VER table.
11. HP‑UX 11i support, and any non-HP-UX OS.
12. The GSC bus clock and the relationship between the CPU clock and the GSC and memory clocks.

**Contradictions between documents**

| # | Topic | Values and sources |
|---|---|---|
| 1 | 715/64 minimum RAM | 16 MB [OG94 1‑3] vs 32 MB [TD64, SH95, HCL] |
| 2 | 715/64 cache | Blank cell [TD64 PDF p.2] vs 256 KB [TD64 PDF p.6, DS64, QRG] |
| 3 | Serial speed | 19.2 Kbaud [SH95 1‑9; OG94 1‑12] vs 460.8 Kbps [TD64 PDF p.7] |
| 4 | Max internal storage | 4 GB [TD64 PDF p.2] vs 2 GB [TD64 PDF p.7] |
| 5 | "Initialization Error" LED code | 0x66 [SH95] vs 0x6C, a duplicate of Memory Error [OG94] |
| 6 | HIL models | OG94 1‑3 lists "715/33, 715/50 and 715/100" with HP‑HIL ports. It should read 715/75 (typo). |
| 7 | SH95 Fig 6‑3 | Shows TeleShare and twisted-pair LAN, which no 715 option or connector supports (712 copy) |
| 8 | Memory rules in SH95 p.3‑16 | The text is corrupted (font encoding). OG94 B‑53 gives the rules instead. |

**Verify before relying on these**
- The LED hex values were decoded by eye from scans.
- The VER Mirage→LASI/WAX mapping is from a 1999 firmware-architecture appendix. It agrees with the hardware (HIL, a second serial port and EISA exist on the 715/64 but not in LASI).
