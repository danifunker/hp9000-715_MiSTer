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
| S-005 | CPU (bring-up) | the CPU is real-mode only: no TLB/walker/PROBE/LPA (major 01 decodes as illegal), no caches or cache-diagnose ops (illegal), no FPU (every FP instruction takes assist emulation, trap 22), no explicit-endian loads/stores (03/3, 03/B illegal), GATE always drops to PL 0, fetch and data both uncached (the pipelined `pa_cpu` fetches I/O-space code through its one-line UIB and issues every data access on the uncached port; its cacheable line port is tied off). `pa_core_seq` (the sequential reference core) additionally lacks the recovery counter, group 4 traps and CR16's fractional rate, which `pa_cpu` has | `rtl/cpu/pa_cpu.sv`, `pa_core.sv`, `pa_fetch.sv`, `pa_core_seq.sv`, `pa_decode.sv` | `docs/design/cpu.md` sections 2, 3, 5, 6 | anything virtual, cached or FP; the fp/fpedge suites fail; HP's ROM cannot boot | caches with diagnose access, TLB + walker, FPU (cpu.md 8.5 steps 5-7); entries retire one by one as units land | 2026-10-07 |
| S-006 | CPU uncached stores | a bus error on a **posted** uncached store (`io_err` with the store buffer's ack) raises the HPMC at the next instruction boundary, so IIAOQ names the instruction after the store, not the store; `pa_core_seq` takes it precisely on the store | `rtl/cpu/pa_biu.sv` (sb_err), `pa_core.sv` (hpmc_pend) | cpu.md 3.4: precise if the system acks with `io_err`, otherwise via `hpmc_req` at a later boundary -- the real chip's store buffer behaves the same way (ERS s.9.6) | HP's ROM only probes with loads (`ld; sync; sync; sync`); a probe-by-store would have the handler skip the wrong instruction. Lockstep co-simulation shows it as a diverging trap IIAOQ | make W wait for the store's ack when the system can report errors (a `cfg` bit), at ~2 cycles per uncached store | 2026-10-07 |
| S-004 | CPU load/store | PSW[E] (little-endian data references) is ignored: `pa_ldst` always formats big-endian, and STBYS takes the E=0 byte choice | `rtl/cpu/pa_ldst.sv` | with E=1 loads/stores byte-swap and STBYS picks the opposite bytes (Pa11_acd STBYS and "Little Endian Loads", Figure 2-5); the PA7100LC implements E (OpenPA: "bi-endian load/store") | only software that sets PSW[E]: none of HP-UX, Linux or the ROM is known to; a guest that does would read swapped data | byte-swap the word lanes when E=1 and mirror the STBYS selection; instruction fetch is unaffected by E on PA 1.1 | 2026-10-07 |

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
| P-011 | CPU little-endian mode (`rtl/cpu/pa_csr`, `pa_dcache`, `pa_hwalk`) | PSW.E/IPSW.E and DR0.ENDIAN (bit 23) are stored and copied as the ERS says, but have no effect: every data access and every hardware-walker PDIR read is big-endian. The explicit-endian word ops (LDWCX/BX/LX, LDWCS/BS/LS, STWCS/BS/LS) are implemented | PCX-L ERS 2.1.3 (E bit, 9 override load/stores), 6.7.1 (PDIR in LE when DR0.ENDIAN); ACD p.2-10 (E optional); `docs/design/cpu.md` 1.2 | HP-UX 10.20 and Linux never set E (`06` section 0 item 8); a guest that does would read byte-swapped data or walk a garbage PDIR -- visible as wrong data, not as a trap | byte reversal on the load/store path when PSW.E = 1 with the ACD 2-3/2-4 sub-word rules, and in the walker when DR0.ENDIAN = 1 |
| P-012 | CPU L1 I-cache predecode (`pa_icache`) | hardware L1 fills write a constant STEER field (DR29 bits 2:9); only WI1-written entries carry software's value; the single-issue decoder ignores STEER | PCX-L ERS 8.2.9 (STEER = predecoded steering for the dual-issue buses) | only a diagnostic RI1 after a hardware fill would see the difference; the ROM's L1 tests write before they read | compute the steering bits from the ERS 3.2 class table (needed anyway for dual issue, P-008) |
| P-013 | CPU performance/characterisation fields (`pa_diag`) | DR0 ISTRM_EN, DUAL_DIS, SOU_EN, SHINT_EN, IPREF_EN, PF_MASK stored and read back, FAST_MODE reads 0; DR24 DCACHE_SIZE and DR25 FP_DELAY stored; none has an effect (cache size is a build parameter, store hints ignored) | PCX-L ERS 8.2.2, 8.2.4, 8.2.5 | none functional; a DCACHE_SIZE that disagrees with the built cache size goes unnoticed | n/a (they tune silicon that does not exist here) |
| P-014 | CPU power-fail (`pa_diag`, `pa_core`) | DR25.POWFAIL reads 1, interruption 2 is never raised | PCX-L ERS 8.2.5; ACD p.4-18 | none; HP-UX polls DR25 bit 0 as a power switch only if PDC_SOFT_POWER reports no status register (`06` 3.1) and then sees "on" | route a MiSTer soft power-off to `powerfail` |
| P-015 | CPU debug features (`pa_diag`) | DR26 (debug-mode configuration) writes ignored, reads 0; no JTAG/scan, single-step or N-step hardware | PCX-L ERS 1.3, 8.2.6 (debug chapter not in our ERS copy) | none expected (no OS or ROM use found) | find the debug chapter |
| P-016 | CPU timing (`rtl/cpu/*`) | not cycle-exact: single issue (P-008), replay on D-cache miss instead of stall-on-use, multi-cycle unpipelined FPU (FADD 3, FMPY dbl ~4, FDIV dbl ~57 cycles vs 2/3/15), HPMC on a bus error taken precisely on the faulting access, CR16 stepping 1-2 ticks per CPU clock (exact long-term rate) | PCX-L ERS ch. 5, 7.1, 7.5, 8.4; `docs/design/cpu.md` 5.2, 6 | timing-calibrated guest code (none known; the ROM scales delays from CR16's rate and skips 0x4108D at rev 0); throughput below a real 715/64 | cycle-accurate pipeline, dual issue, stall-on-use |
| P-017 | CPU LCI (`pa_core`) | LCI returns 0 | ACD p.3-17, LCI only meaningful with coherent I/O; the 715 is not coherent | an OS expecting a real coherence index (none on a 715) | n/a |
| P-018 | CPU diagnose corner cases (`pa_diag`, `pa_dcache`, `pa_icache`) | MFCPU_C and MFCPU_T both read any DR, and DR1/DR24/DR26 (unreadable on the chip) return their stored value; WDD/WI2D write the cache RAM immediately instead of holding the last word in the store buffer until SET_TAG/WxT | PCX-L ERS 8.3.2, 8.3.4-8.3.5 ("a WDD-RDD sequence may not work as expected") | software relying on the undefined results (none known; the ROM always uses WxD, SET_TAG, WxT) | model the store-buffer holding and the unreadable registers |

## Retired

None yet.
