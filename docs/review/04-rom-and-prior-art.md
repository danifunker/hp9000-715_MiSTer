# 04 — Boot ROM, prior art, OS support, QEMU status

Target: HP 9000 Model 715/64, 715/80, 715/100 ("Mirage Jr" / "Mirage" / "Mirage Sr"):
PA-7100LC (PCX-L), LASI core I/O, built-in Artist graphics. Researched 2026-10-07.

Labels used below: **[local]** = read from files on this machine or the NAS.
**[web]** = read from the cited URL. **[inference]** = my conclusion, not stated
directly by a source.

---

## 0. Recommendation (short)

**Option (c), both in stages:**

1. **Stage 1: bring-up and default firmware = SeaBIOS-hppa** (LGPL-3.0, Helge Deller et al.).
   It already models a real 715/64. Its `src/parisc/715_64.h` was generated on a real
   715/64 running Linux. It includes an NCR 53C710 boot driver and an Artist STI ROM.
   QEMU 11.1.1 `-M 715` runs the same firmware, so QEMU can act as a lock-step
   reference (golden model) for the core. We can also ship it with the MiSTer core,
   which we cannot do with HP code.
2. **Stage 2: the real HP PDC as an optional, user-supplied ROM.** Use PDC rev 1.6 from
   HP patch `PF_C7X50016` / `C7X50016.frm` (715/64/80/100 and 725/100). It gives the real
   Boot Console Handler, self-test LEDs and HP's own IODC/STI code, and it is the
   strongest test of hardware accuracy (HP-UX 9.x, NeXTSTEP 3.3). To run it, the core
   needs exact PCX-L DIAG/MIOC behaviour, LASI's flash/stable-storage path (AM29F010
   command set), and correct HPAs. Someone also has to extract the flash payload from
   the tape-image `.frm` file.

Option (a) alone is a bad first step. HP's ROM cannot be redistributed, nobody has
published a raw dump or an extraction of it, it is hard to debug, and it needs many
undocumented hardware details before the first boot. Option (b) alone never proves the
hardware is accurate, because SeaBIOS-hppa is written for QEMU (fw_cfg, `diag 0x100/0x101`,
QEMU address map).

Design consequence for both stages: expose a **1 MB writable window at 0xF000_0000–0xF00F_FFFF**
that the MiSTer HPS loads.
- SeaBIOS-hppa is an ELF image loaded there. Its RWE segment holds `.data` and `.bss`
  inside the window: file size 0x257B4 bytes, mem size 0x3135D bytes, entry 0xF000_0080.
- Real hardware decodes this space through LASI's 8-bit flash bus.
- The CPU reset vector is 0xF000_0004 in both cases.

---

## 1. The real firmware (PDC + IODC + BCH + STI)

### 1.1 What the boot ROM contains

| Component | Where it lives on 712/715-Mirage | Evidence |
|---|---|---|
| PDC (Processor Dependent Code, the PA-RISC "BIOS"), entry points, self test | System flash on LASI's 8-bit bus, decoded at 0xF000_0000 | LASI ERS §11 [local `Lasi_ers.txt`]. The real 715/64 reports `PDC_ENTRY_ORG 0xf0012870` [local `seabios-hppa/src/parisc/715_64.h`] |
| Boot Console Handler / "BOOT_ADMIN" (BCH UI: `boot`, `search`, `path`, `info`, `auto`, …) | Part of the PDC image | 715 Service Handbook ch.4 "Boot Administration Environment" [local] |
| IODC for the built-in LASI functions (SCSI, LAN, RS-232, Centronics, audio, floppy, PS/2) and for WAX/EISA | Inside the PDC image (fixed core I/O has no ROM of its own) and returned through `PDC_IODC`. SeaBIOS copies this design: a table of IODC records per HPA plus C implementations of ENTRY_IO etc. | [inference] from the LASI ERS, which lists only one flash device for the whole 712 I/O subsystem, and from `715_64.h` |
| Artist STI ROM (graphics init, text console, fonts) | **No separate STI ROM chip.** The STI code and fonts sit in the system flash. On these "older systems the PDC stores it in page0->proc_sti" | Linux `drivers/video/console/sticore.c`, comment above `sticore_pa_init()` [local]. The HP firmware-update text mentions a separate "font file rewriting" step after "1st rom done!!" [web: C7X50016.text] |
| Stable storage (boot paths, console path, autoboot flags, LAN station address) | Flash. 715/64-100 have no socketed config EEPROM. The 715/33/50/75 had one (UV17, kits 1818-5436/-5406/-5554) | Service Handbook FRU table and "System EEPROM" section: the EEPROM move applies only to non-64/80/100 boards [local]. LASI ERS: "permanent copy of the LAN Station Nodal Address is kept in Flash EPROM" |

### 1.2 Physical ROM / flash

- The LASI ERS documents this for the **712 (Gecko)** ([local] `Lasi_ers.txt` §11, Dwg A-A2263-66510-31):
  - Half of LASI's address space (1 MB) maps to an 8-bit external bus that holds "processor
    dependent code and the stable-store".
  - It uses **two un-socketed AMD Am29F010 flash parts (2 × 128 KB = 256 KB)**. Older
    machines used two socketed EPROMs plus an EEPROM.
  - The address map is not contiguous: 0x00000–0x1FFFF (CS0) and 0x80000–0x9FFFF (CS1),
    each in 16 KB sectors. A third chip select at 0xC0000 is unused on the 712.
  - Reads (byte, word or doubleword) are slow, about 75 GSC cycles per doubleword. Writes
    must be byte writes using the Am29F010 command sequences, and software controls
    sector erase and programming.
- **715/64/80/100 (Mirage):** I found no separate document. The Mirage uses the same LASI
  and needs no EEPROM swap, and its update process writes a "1st rom" followed by fonts.
  The same 2 × Am29F010 layout is therefore very likely [inference]. Check this with a
  board photo or a real machine before committing.
- Part numbers: the Service Handbook lists FRUs only. Processor boards are A4022-69516
  (715/64), A4022-69518 (/80), A4022-69510 (/100) and A4022-69515 (/100XC). There is no
  separate ROM part number for these boards [local].

### 1.3 Address space facts relevant to the ROM

- PCX-L reset: "The CPU begins fetching instructions from address F0000004". The HPMC
  handler starts at F0000000. Block-TLB insertion "is accomplished by pdc using a
  combination of diagnose write functionality". Source: [local] `PCXL_ers.txt` ~l.2595,
  l.119, l.1984, plus the matching text in `Pcxl2_ers.txt`.
- Real 715/64 inventory, as seen by Linux and captured in [local] `seabios-hppa/src/parisc/715_64.h`:

| Module | HPA | hv / sv |
|---|---|---|
| Mirage Jr GSC Builtin Graphics (Artist) | 0xF800_0000 | 0x12 / 0x85 |
| Mirage Jr Core BA (LASI) | 0xF010_0000 | 0x28 / 0x81 |
| LASI SCSI (53C710) | 0xF010_6000 | sv 0x82 |
| LASI LAN (82596) | 0xF010_7000 | sv 0x8a |
| LASI RS-232 | 0xF010_5000 | sv 0x8c |
| LASI Centronics | 0xF010_2000 | sv 0x74 |
| LASI Audio (Harmony) | 0xF010_4000 | sv 0x7b |
| LASI PC floppy | 0xF010_A000 | sv 0x83 |
| LASI PS/2 ×2 | 0xF010_8000 / 0xF010_8100 | sv 0x84 |
| WAX EISA BA | 0xFC00_0000 | sv 0x90 |
| WAX BA (HIL, 2nd RS-232) | 0xF020_0000 | sv 0x8e |
| CPU "Mirage Jr (715/64)" | 0xFFFB_E000 | hv 0x60a |
| Memory | 0xFFFB_F000 | hv 0x4a |

  - `PARISC_MODEL "9000/715"`, `PDC_VERSION 0x000c`, `PDC_ENTRY_ORG 0xf0012870`.
  - CPU hversions in Linux `arch/parisc/kernel/hardware.c` [local]: 0x60A "Mirage Jr (715/64)",
    0x619 "Mirage 80", 0x60B "Mirage 100", 0x60C "Mirage 100+".
- So the flash or PDC window is LASI's lower 1 MB at 0xF000_0000, directly below LASI's
  register HPA at 0xF010_0000. QEMU uses the same window: `FIRMWARE_START 0xf0000000`,
  `FIRMWARE_END 0xf0100000` [local `hw/hppa/hppa_hardware.h`].

### 1.4 Known firmware revisions and how HP shipped them

From HP's patch catalogue, mirrored by the parisc-linux project ([web] https://paco.parisc-linux.org/firmware/hp_patches.txt):

| Patch | Rev | Date | Models | Notes |
|---|---|---|---|---|
| PF_C7X50014 | 715:725:1.4 | created 95/02/13 | 715/64/80/100, 725/100 only | HP-UX 10.0 gateway boot, VESA fix, 2 GB ISL boot, autoboot delay |
| **PF_C7X50016** | **715:725:1.6** | created 95/09/29, pub. 95/10/11 | 715/64/80/100, 725/100 only | LAN boot reliability. Supersedes 1.4 |
| (none) | 1.2 | — | **715/100XC** | Must stay on 1.2: "C7X50016.frm is *NOT* for 715/100XC models! 715/100XC uses version 1.2 *only*" ([web] https://paco.parisc-linux.org/firmware/715/README) |
| PF_C7120016/20/22/23 | 712: 1.6 / 2.0 / 2.2 / 2.3 | 1994–96 | 712 | 2.3 = latest ([web] C7120023.text) |

How the update is delivered and installed:
- The update is a bootable tape image `C7X50016.frm` (`sum` = 48275 1446). You write it
  with `dd if=C7X50016.frm of=/dev/rmt/0m bs=2k`, then boot it from BOOT_ADMIN using
  `search` / `boot`.
- The process takes about 2 minutes and must not be interrupted.
  Source: [web] https://paco.parisc-linux.org/firmware/715/C7X50016.text
- On the 712, the ODE "update" module also "updates the system's Processor Dependent Code
  (PDC) firmware on the FEPROM" ([local] `712_service-handbook.txt` ch.4).
- I scanned the user's HP-UX 11i Support Plus and QPK (March 2003) images for `PF_C7*` /
  `C7X50*`. Neither contains them [local].

### 1.5 Public dumps

- **Firmware patch files are public**, mirrored by the parisc-linux project at
  https://paco.parisc-linux.org/firmware/. **I did not download them**:
  - `715/C7X50016.frm` (723 KB), `C7X50016.text`, `README`
  - `712/C7120023.frm` (693 KB), `PF_C7120023` (568 KB)
  - B/C/J-class images `PDC_BCJ31`, `PDC_BCJ35`, `PDC_BCJ50`, plus directories for
    b180, c3000, c360, C8000, A180, etc.

  The `.frm` file is a tape boot image: an updater plus the flash payload(s). I found no
  public tool or write-up that extracts a raw flash image from it [inference + absence
  of results].
- **Raw dumps of 712/715 flash:** none found (bitsavers, archive.org, parisc-linux,
  vintage-forum searches).
- **Separate Artist STI ROM dump:** none exists as a separate item, because Artist's STI
  code lives in the system flash (§1.1). The register-level notes on Artist were
  reverse-engineered "by looking at the memory write from the Bootrom/STI code"
  ([web] https://parisc.docs.kernel.org/en/latest/artist_graphics_registers.html,
  also [local] `artist_graphics_registers.html`).
- Licensing: HP-copyrighted. HP distributed it freely as a patch, but it cannot be
  bundled with a MiSTer core. Users would have to supply it.

### 1.6 Does any emulator run the real ROM?

- **QEMU: no.** `hw/hppa/machine.c` loads the firmware only as an ELF file. The comment
  says "Given that this is not 'real' firmware, but one explicitly written for the
  emulation, we might as well load it directly from an ELF image" [local, QEMU 11.1.1].
- **MAME: no.** MAME has no PA-RISC CPU core (`src/devices/cpu` has no hppa/parisc
  directory). Its HP 9000 drivers cover the 68k 200/300 series
  ([web] https://github.com/mamedev/mame/tree/master/src/devices/cpu).
- **Charon-PAR:** proprietary. It targets servers and HP 3000/MPE. Its firmware approach
  is not public.

### 1.7 openpa.net model summaries

Sources: [web] https://www.openpa.net/systems/hp-9000_715.html,
https://www.openpa.net/systems/hp-9000_712.html,
https://www.openpa.net/pa-risc_processor_pa-7100lc.html. Codenames are from
https://parisc.docs.kernel.org/en/latest/overview_hp9000_workstation_and_servers.html.

| Model | Codename | CPU | Cache (on-chip / off-chip) | RAM max | Graphics | Intro / list price |
|---|---|---|---|---|---|---|
| 715/64 | Mirage Jr | PA-7100LC 64 MHz | 1 KB I / 64 KB | 256 MB (8×32 MB 72-pin ECC SIMM) | Artist 8-bit, 1 (or 2) MB VRAM, up to 1280×1024; 1 GSC slot for CRX/HCRX | 1994, $9,995 |
| 715/80 | Mirage | PA-7100LC 80 MHz | 1 KB / 256 KB | 256 MB | same | 1994, $13,600 |
| 715/100 | Mirage Sr | PA-7100LC 100 MHz | 1 KB / 256 KB | 256 MB | same | 1994, $19,005 |
| 715/100XC | Turnip | PA-7100LC 100 MHz | 1 KB / 1 MB | 256 MB | same | 1995, $21,100 (PDC 1.2 only) |
| 712/60, /80, /100 | Gecko / King Gecko | PA-7100LC 60/80/100 | 64 KB or 256 KB off-chip | 128 MB (192 MB on /100) | Artist | 1994, firmware 2.3 latest |

- Shared I/O: LASI (53C710 SE narrow SCSI-2, i82596CA 10 Mbit AUI, Harmony 16-bit audio,
  RS-232, parallel, PS/2, floppy), plus WAX (EISA bridge and HIL, one EISA slot on 715).
- PA-7100LC: PA-RISC 1.1, 2-way superscalar, about 900k transistors, on-chip MIOC,
  MAX-1, 64-entry TLB plus 8-entry BTLB, bi-endian.
- OS support listed on openpa: HP-UX 9.05/9.07, 10.x, 11.00, **11i v1 32-bit (TCOE/MTOE)**,
  NeXTSTEP 3.3, Linux, OpenBSD, NetBSD.

---

## 2. Local search results

The NAS (`smb-share:server=daninas.local,share=software`) was searched with bounded
`find -maxdepth 4` in these folders: FPGA_Dev, MiSTer_Images, Dev-Stuff, Downloaded,
Old Hardware Stuff, Operating Systems, VM Images, MisterBackup, VintageSystemBackups,
BlueSCSI Images, NeXT and HP9000.

**No HP 712/715 PDC, IODC or STI ROM dump was found anywhere.**

Relevant hits:

| Path | Size | What |
|---|---|---|
| NAS `HP9000/HP9000/*.pdf` (and `HP9000.zip`, 147.8 MB, same content) | — | Docs. Text copies are already in `docs/reference/txt`: LASI ERS, PCX-L/PCX-L2 ERS, PDC 1.1/2.0 specs, STI spec, WAX ERS, 712/715 service and owner's manuals, Artist registers HTML |
| NAS `HP9000/hpux1020-apps-qemu.tar.lz` | 284,159,721 B | QEMU HP-UX 10.20 image (not unpacked) |
| NAS `HP9000/hpux11v1-qemu.tar.lz` | 735,193,833 B | QEMU HP-UX 11i v1 image (not unpacked) |
| NAS `HP9000/HP-UX11i/*.zip` (also in `~/Downloads`) | 50 MB – 1.23 GB | HP-UX 11i OE March 2003 (2 CD), ACE March 2001, QPK/Support Plus March 2003, Software Pack Dec 2002, Instant Information. MDF/MDS disc images. No PDC firmware patches inside Support Plus or QPK |
| NAS `NeXT/NeXTStep 3.3/NeXTSTEP 3.3 User (SPARC, PARISC).iso` | 369,573,888 B | NeXTSTEP 3.3 for PA-RISC |
| `~/src/qemu-11.1.1/pc-bios/hppa-firmware.img` | 633,992 B | SeaBIOS-hppa **v25** (32-bit), built ELF |
| `~/src/qemu-11.1.1/pc-bios/hppa-firmware64.img` | 666,392 B | SeaBIOS-hppa 64-bit |
| `~/src/qemu-11.1.1/roms/seabios-hppa/` | — | **Full SeaBIOS-hppa source**: `src/parisc/715_64.h`, `stirom.c` (Artist STI), `hw/ncr710-scsi.c` |
| `~/nextstep-test/qemu-src/` | — | Second copy of the QEMU tree (same files) |
| `~/repos/Linux-Kernel_MiSTer/arch/parisc`, `drivers/parisc` | — | Linux 5.15 parisc code (hardware IDs, sticore) |

All other NAS hits were false positives: MiSTer cheat files and screenshots containing
"712"/"715" in CRCs or timestamps, Mac OS X combo updates, and a "Silhouette Mirage" CHD.

---

## 3. Prior art

### 3.1 PA-RISC in HDL / FPGA

- **I found no public PA-RISC soft-core, PA-7100(LC) clone or HP 9000 FPGA
  reimplementation.** Searches covered GitHub, OpenCores, academic papers and MiSTer or
  retro forums. This project appears to be the first of its kind.
- Historical non-HP **silicon** (ASIC, not HDL), all PA-RISC 1.1
  ([web] https://www.openpa.net/pa-risc_processor_other.html,
  https://www.openpa.net/pa-risc_processor_winbond.html):
  - Hitachi PA/50L (1993)
  - Hitachi HARP-1 (1994)
  - Winbond W89K (1994): embedded, 486-bus-compatible, no FPU

### 3.2 Emulators

| Project | Scope | Licence |
|---|---|---|
| **QEMU** `target/hppa` + `hw/hppa`. CPU by Richard Henderson; machines and firmware by Helge Deller; Artist, LASI and fixes by Sven Schnelle; NCR710 and 82596 by Soumyajyotii Ssarkar (GSoC 2025) | Machines B160L, **715 (64)**, C3700, A400. Also linux-user | GPL-2.0-or-later ([local] file headers) |
| **SeaBIOS-hppa** (https://github.com/hdeller/seabios-hppa) | Open PDC/IODC/BCH-like firmware with a built-in Artist STI ROM (`stirom.c`). An STI ROM for ATI/VGA cards is still listed as future work in the parisc docs | LGPL-3.0 ([local] `parisc.c` header, `COPYING.LESSER`) |
| Stromasys **Charon-PAR** | Commercial PA-RISC virtualisation for HP 3000/MPE and HP 9000 servers (A400/A500, rp-series, N4000). No 7xx workstations or graphics publicly listed | Proprietary, HASP-licensed ([web] https://www.stromasys.com/solution/charon-par/) |
| HPPAQEMU (SourceForge, QEMU 0.9.1 era) | Early, incomplete attempt at an HPPA target and host for QEMU. Author had a 715/100 | Not stated ([web] https://hppaqemu.sourceforge.net/) |
| dmulder/pa-risc-vm (2016) | Toy PA 1.1 instruction-set interpreter (C++) | LGPL-3.0 ([web] GitHub API) |
| MAME | **No** PA-RISC CPU | — |

Useful for this project:
- QEMU `hw/display/artist.c`, `hw/misc/lasi.c`, `hw/scsi/{ncr53c710,lasi_ncr710}.c`,
  `hw/net/lasi_i82596.c` and `hw/input/lasips2.c` are behavioural references.
- They are GPL, so read them for understanding but do not copy code into HDL unless the
  core's licence is compatible.

---

## 4. OS support for 715/64, /80, /100

| OS | Supported? | Notes / source |
|---|---|---|
| HP-UX 9.03 | 712 only | openpa [web] https://www.openpa.net/hp-ux_9.html |
| **HP-UX 9.05** | **yes, first release for the 715 PA-7100LC models** | "primarily a hardware release that added support for 32-bit PA-7100LC [715]" (openpa) |
| HP-UX 9.07 | yes | openpa 715 page |
| HP-UX 10.00 / **10.01** | yes (10.0 needs PDC ≥ 1.4 for "gateway boot", per PF_C7X50014) | openpa https://www.openpa.net/hp-ux_10_20.html, hp_patches.txt |
| HP-UX 10.10 | probably (openpa: hardware list "unclear but probably the same as 10.00") | openpa |
| **HP-UX 10.20** | yes | openpa |
| **HP-UX 11.00** | yes, **32-bit kernel only** (PA 1.1). 11.00 needs at least PA-7100LC on workstations; PA-7000/7100 boxes (705/710/720/730/750/735/755, 715/33-75) are excluded | https://www.openpa.net/hp-ux_1100.html |
| **HP-UX 11i v1 (11.11)** | **yes, 32-bit, TCOE/MTOE releases Dec 2000 – Dec 2004.** openpa notes that from "September 2005" PA-7100LC (and PA-7200/8000/8200) workstation support was dropped. **The user's March 2003 OE media falls inside the supported window** | https://www.openpa.net/hp-ux_11i.html, 715 page. Confirm against the "Supported systems" chapter of the 11i v1 Installation & Update Guide on the user's Instant Information CD |
| HP-UX 11i v2 / v3 | no (v2 is PA only on servers, v3 is very limited) | openpa |
| Linux (parisc) | yes. Kconfig `PA7100LC`: "712, 715/64, 715/80, 715/100, 715/100XC, 725/100…" | [local] `arch/parisc/Kconfig` |
| NetBSD/hppa | yes (osiop, ie, sti, harmony, lasi) | https://wiki.netbsd.org/ports/hppa/ |
| OpenBSD/hppa | yes ("PA7100LC-based: 712, 715/64, 715/80, 715/100, 715/100XC") | https://www.openbsd.org/hppa.html |
| **NeXTSTEP 3.3 (PA-RISC)** | yes: 712, 715, 725, 735, 755. On 712 and 715/64/80/100 only PS/2 keyboards work (no HIL). Onboard graphics and CRX supported; HCRX after patches | https://www.openpa.net/nextstep_pa-risc.html |
| OPENSTEP 4.x | **no PA-RISC release.** The PA-RISC port stopped at NeXTSTEP 3.3 | same |
| MPE/iX | no (HP 3000 servers only) | — |

---

## 5. HP-UX on QEMU (B160L and 715)

Version history:
- **QEMU 2.12** (2018): first hppa system emulation.
- **8.2**: added the 64-bit C3700.
- **10.2.0 (Dec 2025)**: added the **HP 715 machine and LASI 53C710 SCSI**. This was
  Helge Deller's series "HP-PARISC 715 machine with NCR710 SCSI chip" (pull
  2025-10-27). Network support followed in later patches. The series required
  **SeaBIOS-hppa v19**.
- **11.0** (Apr 2026): more 64-bit work.
- Local 11.1.1 ships **SeaBIOS-hppa v25**.

Sources: https://www.openpa.net/qemu_pa-risc_emulation.html,
https://patchew.org/QEMU/20251025161901.32710-1-deller@kernel.org,
https://patchew.org/QEMU/20251027211603.7141-1-deller@kernel.org

What the QEMU "715" really is ([local] QEMU 11.1.1 `hw/hppa/machine.c`):
- desc "HP 715/64 workstation", default 256 MB, up to 8 CPUs.
- The CPU is modelled as a **PA-7300LC** ("Although the 715 workstation should use a
  7100LC, it can be safely modeled as a 7300LC…").
- LASI is at 0xF010_0000, Artist at 0xF800_0000, the framebuffer at 0xF900_0000, and
  there is an ISA bus for PS/2.
- **It differs from real hardware**: CPU HPA is 0xFFFB_0000 (real: 0xFFFB_E000) and
  fw_cfg sits at 0xFFFA_0000.
- SeaBIOS-hppa relies on QEMU-only features:
  - the fw_cfg device
  - boot arguments in GR26/25/24/23/22/21/19 at reset
  - `diag 0x100` (QEMU performs the BTLB insert)
  - `diag 0x101` (console character output)
  - `cr7` used as a "CPU already initialised" flag

  An FPGA core must implement these, or SeaBIOS must be patched.

Status reports:
- parisc.docs.kernel.org ([web] https://parisc.docs.kernel.org/en/latest/qemu.html):
  - B160L "supports HP-UX 10.20 up to HP-UX 11v1".
  - 715 "supports HP-UX 9 up to HP-UX 11v1" and "is the only QEMU emulated machine,
    which should be able to run HP-UX 9".
  - Warning for the 715: "**SCSI and network emulation is not yet stable on this machine**".
  - HP-UX needs Artist at exactly 1280×1024.
- openpa: with QEMU 9.2, HP-UX 10.20 installs on B160L with working X11/CDE; 11.00
  installs with spotty X11; 11.11 hung on B160L. NeXTSTEP 3.3 boots but its installer
  crashes.
- VirtuallyFun (Oct 2025): HP-UX 11i v1 (2006 MCOE ISOs) installed on **QEMU 10.1 B160L**
  with some config fixes
  ([web] https://virtuallyfun.com/2025/10/26/installing-hp-ux-11i-v1-11-11-32bit-pa1-1-on-qemu-10-1/).
- **NCR 53C710 rewrite** by Keith Monahan, posted 2026-07-01, v2 with 4 patches
  ([web] https://patchew.org/QEMU/20260701213359.1855870-1-keith@techtravels.org/):
  - The GSoC model was "connected-only" and ran SCRIPTS synchronously. HP-UX needs
    disconnect/reselect and asynchronous completion.
  - With the rewrite on `-M 715`: HP-UX 10.20 installs and boots, including Ignite/16700A
    media. Debian Linux and NetBSD 9.4/10.1 boot as well.
  - **Not in the local 11.1.1 tree**: `ncr53c710.c` still carries the GSoC 2025 header.
    It is probably queued for 11.2 [inference].
- The user's QEMU 11i v1 image (`hpux11v1-qemu.tar.lz`) was most likely built on B160L.
  HP-UX 11.11 on `-M 715` has no independent report beyond the docs' "9 up to 11v1"
  claim.

---

## 6. Why staged (c), in detail

Stage 1: SeaBIOS-hppa
- (+) Source is available and licensed LGPL-3.0, so it can ship with the core.
- (+) It already has the real 715/64 PDC_MODEL, cache info and IODC tables, an Artist
  STI ROM (`stirom.c`), a 53C710 boot driver, LAN and PS/2 support.
- (+) It is the same firmware QEMU `-M 715` runs, so instruction or bus traces can be
  diffed against QEMU.
- (+) The loaded image is about 197 KB, so it fits the 1 MB window with room to spare.
- (−) It is written for QEMU. The core needs to supply:
  - a small fw_cfg-compatible MMIO block, fed by the HPS (or patch `parisc.c` to read a
    simple config register block);
  - `diag 0x100` / `diag 0x101` handling (or patch it to do PCX-L BTLB DIAG writes and
    LASI UART output);
  - the right reset-time GR values;
  - an HPA layout consistent with whichever map we choose. Recommendation: the real one
    from `715_64.h`, patching SeaBIOS where QEMU differs.
- (−) Known gaps: HP-UX 9 and NeXTSTEP are unproven, and there is no real self-test or
  LED behaviour.

Stage 2: real PDC 1.6 (user-supplied)
- (+) Authentic BCH and HP's own IODC/STI.
- (+) It is the definitive accuracy test. The PDC exercises PCX-L DIAG registers,
  MIOC/memory sizing, cache/TLB self-test, flash command sequences, stable storage,
  RTC, LEDs and Artist init.
- (−) It needs flash images extracted from `C7X50016.frm` (unknown format, RE needed).
- (−) It needs PCX-L DIAG/MIOC details. These are partly documented in
  `PCXL_ers.txt` / `Pcxl2_ers.txt`, which are available locally.
- (−) It cannot be redistributed. The MiSTer convention of a user-provided `boot.rom`
  applies.
- (−) 715/100XC would need rev 1.2, which has not been found.

Next actions:
1. Fetch `C7X50016.frm` (723 KB) once the user agrees, and analyse it: LIF header, then
   look for two 128 KB payloads and the font block.
2. Decide the HPA map (real vs QEMU) before writing the bus decoder.
3. Prototype SeaBIOS-hppa with a fw_cfg shim in simulation, comparing against
   `qemu-system-hppa -M 715 -d in_asm,cpu`.
