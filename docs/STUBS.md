# Stub register

**A living list of everything in this core that is stubbed, simplified,
faked or left out**, so nothing is forgotten. Every stub that goes into the
RTL, the simulator, the firmware path or the tooling gets an entry here in the
same change, and the entry is updated when the stub is replaced (move it to
"Retired" with the commit that did it). `CLAUDE.md` makes this a rule.

Each entry says: what is stubbed and where (file/module), what the stub does,
what the real thing does (with the document that says so), what could break
because of the stub and how we would notice, and what it takes to do it
properly.

Status values: **planned** (decided, not built yet), **active** (in the
tree now), **retired** (replaced by the real thing).

## Active

| ID | Block | Stub | Where | Real behaviour / reference | Risk, and how we'd notice | To do it properly | Since |
|---|---|---|---|---|---|---|---|
| S-001 | MiSTer top | `HP9K715.sv` still instantiates the template demo core (`rtl/mycore.v`, `cos.sv`, `lfsr.v`): colour pattern, no machine | `HP9K715.sv`, `files.qip`, `verilator/sim.v` | the 715 machine | none (placeholder) | replace with the machine top when the CPU and memory path exist | 2026-10-07 |
| S-002 | Verilator sim | no block devices: the framework's `sim_blkdevice` was not copied (the Quadra's depends on its CD window); `sim.v` has no `sd_*` ports | `verilator/` | disk and CD images served to the SCSI targets the way hps_io does | no SCSI in the sim yet, so nothing until the 53C710 exists | bring in a generic `sim_blkdevice` (the SGI Indy's or MacLC's) when SCSI lands | 2026-10-07 |
| S-003 | CPU tests | `tests/cpu` max1 suite: QEMU cannot be its reference (it traps MAX-1 on PA 1.1), so expectations come from `tests/cpu/model.py` alone | `tests/cpu/` | expectations checked against a real PA7100LC | a model bug would pass the RTL wrongly; nothing to cross-check with | run the suite on real hardware, or a second independent model | 2026-10-07 |

## Planned

Decided stubs and simplifications that will go in as the machine is built.
Sources: `docs/reference/rom/README.md`, `HARDWARE.md` section 7/10/11,
`docs/review/06*.md` section 8.

| ID | Block | Stub | Real behaviour / reference | Risk, and how we'd notice | To do it properly |
|---|---|---|---|---|---|
| P-001 | WAX (0xF0200000) | accept and discard the ROM's reset-time writes (0xF0201000, 0xF0201C00); reads return what makes the HIL and RS-232_2 probes report "absent" | WAX ERS (scanned PDF); `HARDWARE.md` 6 | the ROM's self-test drives HIL and the second serial port; a wrong read-back could halt it or make it log a failure | real WAX: HIL controller (Linux `hp_sdc.c` shows its commands), second 16550, EISA bridge |
| P-002 | EISA (0xFC000000) | no EISA bus; probes must bus-error as on a machine with an empty slot | `HARDWARE.md` 6-7 | the ROM's EISA configuration step | out of scope unless an EISA card is wanted |
| P-003 | Harmony audio (LASI+0x4000) | first version: the "minimal stub" from `06a` section 9 -- RESET reads back, CNTL.C self-clears, DIAG = 1, IE stored, no DMA, IRQ never asserted, PC/RC read 0 | `06a-hpux-harmony-audio.md`; LASI ERS 2094-2509 | the stock HP-UX 10.20 kernel never attaches audio, so nothing until an audio-enabled kernel or Linux plays sound -- then silence | real Harmony DMA engine + CS4215 model to the MiSTer audio output |
| P-004 | Floppy (LASI+0xA000, WD37C65C) | absent | LASI ERS (wrapper only) | ROM/OS floppy probes | out of scope |
| P-005 | i82596 LAN (LASI+0x7000) | first version: enough of the PORT/CA/SCB protocol for the ROM's LAN self-test and IODC probe, no packets | 82596CA data sheet; `HARDWARE.md` 4 | the HP-UX 10.20 kernel has no `lan2` driver, so nothing for HP-UX; Linux and network boot would see a dead NIC | full 82596 + a MiSTer network path (the Quadra's SONIC used the Main fork) |
| P-006 | MIOC ECC | no stored check bits: an ECC model that satisfies the ROM's single/multi-bit tests without check-bit RAM | `HARDWARE.md` 1 (ECC), `tools/rom/hwmap_ecc.py`, `BOOTFLOW.md` 4.6 | a guest writing check bits through diagnostics and reading them back expecting arbitrary values | check-bit storage in RAM or BRAM |
| P-007 | MIOC memory blocks | at most 128 MB per block, wrap-around aliasing; a 256 MB block is not presented | `HARDWARE.md` 1 | only matters for a 256 MB configuration that the ROM sizes as one block | model the real SIMM-pair geometry |
| P-008 | CPU dual issue | DR0 reports revision 0, so the ROM selects single issue and skips the cycle-exact dual-issue test 0x4108D | `BOOTFLOW.md` 4.0/4.7, `HARDWARE.md` 8 | the dual-issue test, and any guest reading DR0's revision | 2-way superscalar pipeline (OpenPA table 2.20) and a matching revision |
| P-009 | LASI RS-232 clock | the UART reference clock may be 7.3728 MHz (exact baud rates) instead of LASI's 7.2727 MHz | LASI ERS 3106-3108; `06b` section 2 | 1.4 % baud-rate difference against a real 715 on the other end | use 7.2727 MHz |
| P-010 | Parallel port | first version: PIO registers only, no LASI parallel DMA engine | `06b` section 3 (HP-UX prints only through DMA) | HP-UX printing does not work | the 8237-style DMA and the handshake modes from `06b` |

## Retired

None yet.
