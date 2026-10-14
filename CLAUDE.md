# HP 9000 Model 715 for MiSTer -- working notes for Claude

An FPGA recreation of the HP 9000 Model 715/64 workstation (PA-7100LC,
LASI, built-in Artist graphics) for the MiSTer (DE10-Nano, Cyclone V
5CSEBA6). All RTL is Verilog/SystemVerilog.

**State (2026-10-09, evening):** documentation reviewed; HP's PDC 1.6 ROM
obtained, disassembled and analysed (`docs/reference/rom/`); HP-UX 10.20's
kernel extracted and its use of the hardware analysed (`docs/review/06*`).
**The PA-7100LC core is built** (`rtl/cpu/`, `docs/design/cpu.md`): pipeline,
caches with diagnose access, TLB with the hardware walker, the FPU; it passes
the 12 pacputest suites, the lockstep co-simulation and boots HP's PDC 1.6 to
`BOOT_ADMIN>` on the machine top (`rtl/hp715.sv`, Verilator); **fit 15: 70.2
MHz, 14.7k ALMs with the FPU** (`docs/design/cpu-timing.md`). `HP9K715.sv` is
the whole machine on the MiSTer top at 64 MHz and **runs on the board** (MiSTer
at 192.168.99.92): the ROM's self-tests pass, it boots from SCSI and **HP-UX
10.20 boots to `Console Login:` on the board** (build 14, 2026-10-09,
`docs/design/system.md` 10): the kernel's `Data page fault` panic was a CPU
bug (the walker's PDIR read over a dirty D-cache victim, `665f2e8`), the stall
after it the SCSI target's MODE SELECT (`c969097`), the LVM halt the disk
image's boot record naming QEMU's disk path (`tools/hpux/lvmbdra.py`,
`disks/README.md`), the start-up's stop at swagentd two CPU bugs in user-mode
FP: trap 22 without ISR/IOR (`e8c2024`) and fr0 as an operand reading the
status instead of +0 (`8d18d88`, cpu.md 1.1). **Build 15 (2026-10-09):
root logs in multi-user at 32 and 64 MB** (root password and lvmtab set up
single-user, `disks/README.md`); user processes no longer die of SIGILL on
freshly paged-in text (a no-execute fetch filled the I-cache, `68ec0f6`,
cpu-requests #8); `release/` = build 15, release notes in the root README.
**Artist is built** (`rtl/artist/artist.sv`, `docs/design/artist.md`):
VRAM in DDR3 at 0x3300_0000; the PDC draws its boot console on it, and with
a graphics-console EEPROM (`tools/eeprom/hp715_gfx.eep`) **HP-UX 10.20 boots
on the board to CDE** (root logs in through `board.sh key`; keyboard in
scan-code set 3, mouse). HP-UX's X server analysed in `docs/review/09`;
**build 21 (2026-10-09) draws CDE right on the board**: proportional text,
window titles, menus (font engine), clipped/dashed vectors, xclock, oclock.
The MiSTer frame buffer showed it wrongly on HDMI (1024 lines squeezed into
the console's 960, colours off), so **Artist now makes its own picture**
(`rtl/artist/artist_video.sv`, user's choice 2026-10-09: a core-generated
raster at 64 MHz with LUT0/LUT1 by a 1-bit attribute plane and the cursor
laid over, no more cursor in the VRAM); MiSTer.ini has `[HP9K715]`
video_mode=8, vscale_mode=1. The real HDMI output can be seen through the
user's OBS (`tools/mister/obs_shot.py`). **Build 25 is the released alpha** (graphics
console by default; core-side integer scaling, OSD "Scale"). **2026-10-10:**
Artist at the programmed timing (own pixel clock), Harmony audio, CD audio and
the **82596 LAN** (HP-UX's lan2 on the user's network, build 35); Main_MiSTer
branch `hp9k715-enhancements` (`support/hp9k`). **Build 36 (2026-10-11)**: BLR/BV ignore reserved bits (cpu-requests #9); HP-UX
11i's install CD boots its ISL and kernel, which panics on the floppy stub.
**Build 38 (2026-10-11)**: the LASI floppy (`rtl/lasi/lasi_fdc.sv`, a 765A with
no drive, review 10, STUBS S-028): **HP-UX 11i's installer reaches its main menu**
on the serial and the HDMI console (`Floppies: 0`); the ROM's floppy self-test
passes. **Build 39**: recorder event 15 (HP-UX syscalls). **Builds 40-47 (2026-10-11)**: the
recorder's one-shot/trigger/flow captures found the 11i installer's stalls:
**cpu-requests #10**, `b,l`'s link register corrupted when an external
interrupt lands two instructions after the branch (`itool`'s scanner returns
into itself). **Fixed 2026-10-14 (`5cda517`, build 52)**: not the interrupt but the kernel's `rfi` into a *nullified* `b,l,n` whose IIAOQ back is its own target -- the target was fetched twice and the second copy ran as the first's delay slot (`pa_fetch` keeps only the oldest instruction at the slot's address; the `link` suite's RAM groups reproduce it; cputest 13/13, cosim 8/8); the 11i installer passes its first step on the board. **Next: `RESUME-20261011-bl-link.md`** (the user asked for the CPU
fix: the bug, the evidence, the half-built reproduction, the recorder tools,
then the TCOE 12/2004 install), then `RESUME-20261010-features.md`.

## The user's process

1. Gather documentation and review it -- done, `docs/review/01`..`06`.
2. Disassemble the ROM -- done, `docs/reference/rom/` (start at its README).
3. CPU test bench -- **next**. Seeds: the ROM's 38 self-tests
   (`BOOTFLOW.md` section 4) plus a SingleStepTests-style corpus generated
   with QEMU as the reference, corrected for QEMU's deviations below.
4. Check against existing emulators -- QEMU 11.1.1 `-M 715` (see deviations below).
5. Test in Verilator.

## Decisions so far

| | |
|---|---|
| Machine | **715/64 "Mirage Jr"** (CPU HVERSION 0x60A), model ID configurable to 715/80 (0x619) or 715/100 (0x60B). Not the 715/100XC (firmware 1.2 only), not 715/33/50/75 (PA-7100, HIL only). |
| CPU | PA-7100LC (PCX-L): PA-RISC 1.1 + MAX-1 halfword multimedia ops. **One CPU** -- the 7100LC and the 715 have no multiprocessor support. Keep it lightweight: single-issue first, iterative FP divide/sqrt, one shared multiplier; 2-way superscalar (OpenPA table 2.20 pairs) later. Budget ~8-10k ALMs (the Indy's R4600 is 9.4k). TLB 64 entries + 8 block entries, as the real chip. What HP's ROM and HP-UX require beyond the architecture (`docs/reference/rom/README.md`, `docs/review/06` section 3): DR0 reports **revision 2** (user, 2026-10-07: any of 1..0xB; not 0, which leaves Linux a stale PDC_SOFT_POWER pointer; not 0xC yet). At rev != 0 the ROM runs the cycle-exact dual-issue self-test, so the system patches one ROM word when loading the image (STUBS S-011) until dual issue is implemented -- a later task; HP-UX 10.20 stays on its trap-7 gateway path below 0xC; PCX-L diagnose instructions incl. cache data/tag access; **128 KB I + 128 KB D direct-mapped caches with 32-byte lines** (the self-tests assume it; the ROM runs code planted in the I-cache by diagnose writes); the **hardware TLB-miss walker** (PDC_TLB enables it and HP-UX then depends on it); 8 block-TLB slots (HP-UX tells PCX-L from PCX-T by that count); exact shadow registers and RFIR; delayed FP traps; CR16 at exactly the board clock. |
| Memory | **SDRAM = system RAM** (32/64/128 MB, the module fitted). **DDR3** (core window 0x30000000-0x3FFFFFFF, 256 MB) = video RAM, the ROM image, and optionally RAM above 128 MB to reach the 715's 256 MB maximum. **BRAM** = caches, TLB, line buffers. (User's standing preference.) |
| Firmware | HP's own **PDC revision 1.6** (`roms/`) is the target. SeaBIOS-hppa (LGPLv3, in the QEMU tree) is the redistributable fallback and the only firmware QEMU runs, so it is what any QEMU side-by-side comparison uses. |
| I/O | LASI: NCR 53C710 SCSI (disks + CD-ROM at ID 2), i82596 LAN, 16550 UART, parallel, PS/2 keyboard + mouse, Harmony audio with CS4215 codec, RTC. Artist 8-plane graphics up to 1280x1024. CD audio mixed digitally (the real drive's analog out goes to the codec). WAX (HIL, second serial, EISA): only a stub that accepts the ROM's reset-time writes. EEPROM (8 KB at 0xF00C0000) saved to the SD card, shipped pre-initialised (a blank one boots into manufacturing mode). Board-ID word 0xF00FFFFC selects 715/64/80/100. HP-UX 10.20's kernel has no 82596 (`lan2`) driver and never attaches audio, so LAN and Harmony are lower priority. |
| OSes | HP-UX 9.05-11.00, 11i v1 (32-bit), Linux, NetBSD, OpenBSD, NeXTSTEP 3.3 (PS/2 keyboard only). |

## Layout

| path | what |
|---|---|
| `HP9K715.{qpf,qsf,sdc,srf,sv}` | Quartus project (from Template_MiSTer). `HP9K715.sv` is the MiSTer `emu` top. The core name is **HP9K715** (user, 2026-10-07): it is the OSD name, the rbf name and the `games/HP9K715/` folder. |
| `files.qip` | RTL file list -- add new RTL here |
| `sys/` | MiSTer framework, copied as-is from `../Template_MiSTer` (2026-08-26, `3ea1134`). Do not edit. |
| `rtl/` | the core (`pll*` from the template) |
| `docs/review/01..05` | the 2026-10-07 reviews: system docs, chip docs, QEMU/SeaBIOS, ROM and prior art, firmware (PDC/IODC/STI) requirements |
| `docs/review/06*.md` | what HP-UX 10.20 and Linux need from the hardware: 06 by block, with sub-reports 06a audio, 06b PS/2/serial/parallel, 06c graphics/STI, 06d SCSI (c720 driver, SCRIPTS) |
| `docs/review/09-hpux-x-artist.md` | **HP-UX 10.20's X server on Artist** (disassembly of `cg.1`/`crxutils.1`/`ucrx.1`): glyphs, font engine, cursor, LUTs and attribute planes, fills, lines; what the RTL must do |
| `docs/review/08-artist-registers.md` | **the Artist at the register level**: what HP's STI routines (system ROM 0xF0024000), HP-UX and Linux use, QEMU's deviations, the first-milestone plan |
| `docs/review/07-hpux-cpu-specifics.md` | HP-UX 10.20 / Linux versus PCX-L details: CPU revision (cpu.md Q3), walker CR28 (Q4), DIAG and implementation-specific opcodes (Q7, Q8), DR25 soft-power poll |
| `RESUME-20261007-*.md` | resume prompts: `cpu-64mhz` (pipelined CPU at 64 MHz, owns `rtl/cpu/`; done, 65.1 MHz), `fpu` (the FPU, done to the fp suite), `fpu-finish` (done 2026-10-08: fits 10-15, fpedge model, S-012 measured and left) and `system` (the rest of the machine; superseded by `RESUME-20261008-system.md`) |
| `RESUME-20261008-*.md` | `system` (superseded), `board-scsi` (the board-only SCSI failure; fixed by `20afb91`), **`system-next`** (the system stream after that: HP-UX in simulation, HP-UX on the board, Artist) and `hpux-kernel` (for Fable: the CPU's I-LAB livelock HP-UX hit, fixed in `5cec6d8`, and the two failures after it -- done: the walker/D-cache bug `665f2e8`, the SCSI MODE SELECT `c969097`, the LVM boot record `a289321`); `hpux-login` (superseded) |
| `RESUME-20261009-hpux-login.md` | superseded: the two user-mode FP bugs (trap 22 ISR/IOR, fr0 = +0) found and fixed, build 14 reaches `Console Login:` |
| `RESUME-20261009-artist.md` | superseded: root login, the stale-text SIGILL fix (build 15); the Artist plan |
| `RESUME-20261009-x11.md` | superseded: Artist built (builds 16-17), the PDC console and HP-UX's X login on it |
| `RESUME-20261010-features.md` | **current, system stream**: VGA timing, Harmony, CD audio, the 82596 LAN, Main's `support/hp9k`; what is left |
| `RESUME-20261011-bl-link.md` | **current, next**: cpu-requests #10 (`b,l`'s link corrupted by an external interrupt two instructions later -- the 11i installer's stalls): the evidence, the `tests/cpu` `link` suite so far, the recorder's capture modes, then the TCOE install |
| `RESUME-20261011-11i-install.md` | superseded (its "Status" has how the stalls were traced): HP-UX 11i's installer stalls on the board (configuration with DHCP on, environment step with the network on, pre-install disk check) -- timings vs QEMU, the syscall/lan2 evidence, build 39's recorder event 15, the tools, next steps |
| `RESUME-20261011-floppy.md` | done, system stream: the LASI PC floppy for HP-UX 11i -- done in builds 37-38 (its "Status" section); the board recipes for the 11i CD (serial and HDMI) and what is next (the install itself) |
| `RESUME-20261010-cpu.md` | **current, CPU stream**: cpu-requests #9 (BV reserved bits, blocks HP-UX 11i media), the area limit, dual issue later |
| `RESUME-20261009-artist-raster.md` | superseded: build 23 released (Artist's own picture, LUT1/attribute plane, vectors, OBS tool), the window-move stubs to chase, what is left |
| `RESUME-20261009-artist-x.md` | superseded: CDE on the board (build 18), review 09's X fixes + the timing split in build 20 (to check), the board tools (key/mouse/vram), what is still missing (HDMI check, LUT1/attribute planes, parametric/dashed lines, release) |
| `docs/design/cpu-requests.md` | system -> CPU requests between those streams |
| `docs/reference/rom/` | the ROM analysis: README (index + headline FPGA demands), BOOTFLOW, HARDWARE (incl. the reconstructed MIOC), FIRMWARE |
| `rtl/cpu/` | the PA-7100LC core, being built: `pa_pkg.sv` (control word), `pa_decode.sv`, the units `pa_alu.sv` (adds/compares/logical/unit/DCOR/DS + conditions), `pa_shift.sv` (shift/extract/deposit), `pa_max1.sv` (MAX-1), `pa_ldst.sv` (address generation, store byte lanes, load extraction) -- unit-tested against every suite vector (`make -C verilator tb_alu tb_shift tb_max1 tb_ldst`); **`pa_cpu.sv` = the pipelined core** (cpu.md 6.8 ports; `pa_fetch.sv` F1/F2 + UIB, `pa_core.sv` D/E/M/W, `pa_regfile.sv` 2R2W MLAB GRs + shadows, `pa_icache.sv` L2-I + L1-I, `pa_dcache.sv` L2-D, `pa_cache_ram.sv`, `pa_tlb.sv` UTLB + block entries, `pa_biu.sv` line + uncached ports, `pa_cr16.sv`; the hardware walker and the I-LAB live in `pa_core`/`pa_fetch`), caches with full diagnose access, virtual mode; **`pa_fpunit.sv` + `pa_fpu.sv` = the FPU** (FR file, FPSR/compare queue/exception registers, the multi-cycle engine; one operation at a time, STUBS S-012; `make -C verilator tb_fpu` is its unit bench); `pa_core_seq.sv` is the sequential **reference** core it is co-simulated against |
| `rtl/hp715.sv` | **the machine** (`docs/design/system.md`): `pa_cpu` + `mioc.sv` (address decoder, memory blocks, ECC with `mioc_ecc.sv`, MIOC registers, CPU HPA, broadcast), `lasi/` (interrupt controller, misc registers, `lasi_uart.sv` 16550A, `lasi_ps2.sv` ports, `ps2_dev.sv` keyboard/mouse models), `hp_xbus.sv` (EEPROM, LED latch, board ID), `wax_stub.sv`, `rom_loader.sv` (ioctl ROM download + the S-011 patch). RAM, check store and ROM store are ports |
| `rtl/artist/` | `artist.sv`: the built-in graphics (`docs/design/artist.md`; reviews 08, 09): registers, the row-span drawing engine on the `vr_*` VRAM port (and the attribute plane), vectors, the font engine, the LUT load; `artist_video.sv`: the display (a line ahead from DDR3 on `rf_*`, LUT0/LUT1, the cursor, the core's video); unit bench `make -C verilator tb_artist` |
| `rtl/scsi/` | `ncr53c710.sv` (the 53C710 in LASI page 6: SCRIPTS, DMA via the MIOC `dma_*` port) and `scsi_targets.sv` (disks ID 6/5, CD-ROM ID 2 on hps_io block devices) -- written 2026-10-08, not yet exercised (STUBS S-020/S-021) |
| `rtl/mister/` | board side, all on the 64 MHz clock: `sdram64.sv` (system RAM; `make -C verilator tb_sdram64`), `ddr3_port.sv` (boot ROM + ECC check store in DDR3), `eeprom_save.sv` (EEPROM image on hps_io slot 1). `HP9K715.sv` is the MiSTer top (system.md 9); whole-core builds in system.md 10 |
| `tests/run-rom.sh` | **the ROM milestone ratchet**: HP's PDC 1.6 on the whole machine to `BOOT_ADMIN>` (~6 min) |
| `verilator/romsim/` | headless whole-machine run on HP's ROM: `make -C verilator romsim`, then `verilator/obj_dir_rom/Vemu +eeprom=<hex> --stamp --until 'BOOT_ADMIN>'`; `--save-at`/`--save-on`/`--restore` checkpoints, `--type`/`--then` console input, `--disk0 disks/hpux1020.img --snapshot`, `--gsctrace`, `--scsitrace`, `--trace` |
| `tools/eeprom/mkeeprom.py` | EEPROM images (`bootstrap`: initialised, fastboot on, manufacturing mode = RS-232 console) |
| `docs/design/cpu-timing.md` | **the timing/area log**: every Quartus fit of the CPU (`scratch/cpu_fmax/`, `run.sh <revision>`), the pipeline decisions and their bubble costs |
| `tests/cpu/` | **pacputest**: bare-metal CPU test ROMs (gen_tests.py, 12 suites incl. `sys`, `cache`, `tlbx` and `fpedge`), QEMU reference logs (`ref/qemu`), the independent reference model (`model.py`: integer, MAX-1 and the PCX-L FPU rules) and `compare.py`; see its README |
| `verilator/` | the GUI simulator (`make && ./obj_dir/Vemu`), unit benches (`tb/`, `make tb_alu` ...), the CPU test harness (`cputest/`: core + ROM/RAM/UART, runs a suite ROM; `PIPE` parameter picks the core) and the lockstep co-simulation (`cosim/`) |
| `tests/run-cputest.sh` | **CPU regression**: every suite ROM (12, incl. `fp` against QEMU and `fpedge` against the PCX-L model in `model.py`) on the RTL core (`CORE=pipe` default, `CORE=seq`), checked against the model or QEMU (known QEMU bugs excused); `tests/run-cosim.sh` runs both cores in lockstep (`verilator/cosim/`) and diffs every retired instruction and the GR/PSW state |
| `tools/rom/` | ROM analysis tools (`annotate.py` -> `roms/disasm/`, `romlib.py`, `firmware_map.py check`, symbols in `tools/rom/symbols/*.sym`) |
| `tools/hpux/` | `qcow2.py` (read qcow2 without converting), `hpdisk.py` (LIF, LVM, HFS), `vxfs.py` (the VxFS root: ls, cat, get, find), `som.py` (SOM objects -> symbol-annotated disassembly) |
| `roms/disasm/`, `roms/hpux/` | generated listings, and HP-UX files pulled from the 10.20 image (`vmunix`, `system`, ISL ...) -- not committed |
| `docs/reference/` | PDFs and their text extracts (not committed; `README.md` there has the sources) |
| `roms/` | firmware (not committed; `README.md` there has the recipe and hashes) |
| `disks/` | SCSI disk/CD images (not committed; `README.md` there has the recipe): `hpux1020.img`, HP-UX 10.20 from tenox's qcow2, 4 GiB raw |
| `tools/eeprom/` | `mkeeprom.py` (bootstrap image for the sim), `mkrelease.sh` -> `hp715_default.eep`, the image the core ships with (STUBS S-016) |
| `tools/mister/` | `obs_shot.py`: the real HDMI output through the user's OBS (obs-websocket v5, 192.168.99.82:4455, no auth); the board over ssh (MiSTer at 192.168.99.92, key login): `board.sh` `setup` (RAM, SDRAM capture, remembered mounts), `push`, `load`, `console` (the core's UART is the MiSTer's `/dev/ttyS1`), `type`, `shot`, `menu`; `sdram_sweep.sh` (S-019); `trace_dump.py` (the debug event ring in DDR3, copied to `/media/fat/hp715dbg/`) |
| `tools/sim/console_png.py` | renders a romsim `--stamp` console log as a terminal screenshot (the machine's only screen until Artist) |
| `tools/hpfw/hpfw.py` | unpacks HP firmware tapes (LIF) and checks the image header checksum |
| `docs/design/cpu.md` | **the CPU specification** (PA-7100LC): state, VM/TLB/walker, interruptions, every instruction, PCX-L specifics, pipeline, interfaces, module plan and budget |
| `docs/STUBS.md` | **the stub register**: every stub/simplification, active or planned |
| `scratch/` | scratch Quartus projects / experiments (ignored) |

## Tools on this box

- Quartus **17.0.2** Lite: `~/intelFPGA_lite/17.0/quartus/bin`
- Verilator 5.028, iverilog: `~/.local/bin`
- PA-RISC cross tools: `binutils-hppa-linux-gnu`, `gcc-hppa-linux-gnu` (apt) --
  `hppa-linux-gnu-objdump -D -b binary -m hppa1.1 -EB --adjust-vma=0xf0000000 roms/hp715_pdc_rev1.6.bin`
- `gdb-multiarch` (talks to QEMU's hppa gdbstub)
- QEMU: the distro's is 8.2.2 and has **no `-M 715`**. A QEMU 11.1.1 hppa build
  lives in the session scratchpad's `keep/qemu/` (see `keep/INDEX.md`); it is
  session-local, so rebuild from `~/src/qemu-11.1.1` with
  `configure --target-list=hppa-softmmu` (~4 min) if it is gone.

## Reference sources

- QEMU 11.1.1: `~/src/qemu-11.1.1` -- `hw/hppa/machine.c` (`machine_HP_715_init`),
  `hw/hppa/hppa_hardware.h`, `target/hppa/`, `hw/misc/lasi.c`,
  `hw/display/artist.c`, `hw/scsi/ncr53c710.c` + `lasi_ncr710.c`,
  `hw/input/lasips2.c`, `hw/net/i82596.c`, `roms/seabios-hppa/src/parisc/`
  (`parisc.c`, `715_64.h` = a real 715/64's inventory, `stirom.c`).
- Linux: `~/repos/Linux-Kernel_MiSTer` -- `arch/parisc/`, `drivers/parisc/`,
  `drivers/video/fbdev/stifb.c` + `sticore.c`, `sound/parisc/harmony.c`,
  `drivers/scsi/53c700.c` + `lasi700.c`, `drivers/input/serio/gscps2.c`.
- Sibling cores worth reusing from: `../MacQuadra800_MiSTer` (128 MB SDRAM
  controller `rtl/sdram.sv`, SCSI target + `rtl/cd_audio.sv` CD audio),
  `../SGIIndy_MiSTer` (`rtl/mister/ddr3_mux.sv`, `fb_linecache.sv`,
  `docs/reference/mister-integration.md`, `reports/` area numbers).

## QEMU is not ground truth

Checked in the 11.1.1 source on 2026-10-07:
- `-M 715` models a **PA-7300LC** (`machine.c:919`), 256-entry TLB with 16
  block entries (`cpu.h:249-251`) instead of 64 + 8.
- MAX-1 (HADD/HSUB/HAVG/HSHLADD/HSHRADD) is refused unless PA 2.0
  (`translate.c:3099`) -- wrong for the 7100LC.
- Unknown DIAG encodings are logged and ignored, not trapped
  (`translate.c:4635`); the PCX-L diagnose encodings Linux and HP-UX use are
  not decoded.
- CR16 always counts at 250 MHz (`op_helper.c`); FP traps are immediate.
- The CPU sits at QEMU's 0xFFFB0000; a real 715 has it at 0xFFFBE000 and
  memory at 0xFFFBF000 (`seabios-hppa/src/parisc/715_64.h:22-23`).
- The 53C710 model never acts on ISTAT.SIGP (`ncr53c710.c:68` is its only
  use), so **HP-UX 10.20 hangs at SCSI on `-M 715`**; with that fixed it
  still panics in the I/O probe. The same image boots on `-M B160L`.
- No Harmony audio, WAX, floppy or real TOD/EEPROM model.
- Major opcodes 0x16, 0x17, 0x1E, 0x1F, 0x2E and the bit-30 forms of 0x14/0x1C
  decode as PA 2.0 instructions instead of illegal-instruction traps on a
  PA 1.1 CPU (`docs/design/cpu.md` 8.3). More CPU deviations (recovery
  counter, traps 23-25, shadow capture only when Q=1, TOC clobbering
  GR24/25, PROBE privilege rule, the ROM's odd BB/BVB words): cpu.md 7.3.
- It reports 16 block-TLB slots, so HP-UX on `-M 715` runs its **PCX-T**
  (PA-7100) code paths, not PCX-L ones (`docs/review/06` 3.1).
- SH1ADD/SH2ADD/SH3ADD(L) conditions NUV/ZNV/UV/VNZ are wrong: `do_add_uv()`
  (`translate.c:1140`) tests GR r1 bits 31-n..30 instead of the shifted-out
  bits 32-n..31 (Pa11_acd Table 5-2; found by the ALU unit bench and the
  reference model, `tests/cpu/model.py` `QEMU_BUGS`). DS conditions 4/5
  share the bug and also ignore PSW[V]'s subtract reading.
- **No CCR**: an FP instruction with the FPU disabled executes instead of
  taking trap 22, so QEMU never sets ISR/IOR for a coprocessor load/store
  (HP-UX 10.20 emulates FP loads/stores from them, lazy FP switch; found
  2026-10-08, `tests/cpu` trap `fpdis-*`).
- Its 53C710 also clears DSTAT.DFE when raising an interrupt, which HP-UX
  treats as fatal (`06d`); its Artist MISC_VIDEO read overwrites bits HP's
  STI and HP-UX use as the monitor index (`06c`); its 82596 reads the PORT
  command from the wrong bits and its PS/2 loopback is 1 deep where the ROM
  needs 4 (`docs/reference/rom/HARDWARE.md`).

## Rules

- **No CPU fixes unless the user asks for them specifically** (user,
  2026-10-09): `rtl/cpu/` bugs found from the system side go into
  `docs/design/cpu-requests.md` with the evidence, and the user decides.
- **Every stub goes in `docs/STUBS.md`** (user, 2026-10-07): anything
  stubbed, simplified, faked or left out -- RTL, simulator, firmware path,
  tools -- gets an entry in the same change (what, where, what the real
  thing does, the risk, what doing it properly takes), and the entry moves
  to "Retired" when the real thing replaces it.
- **Never delete anything without asking** -- project files or scratch.
  Reusable scratch goes in the session scratchpad's `keep/`, listed in
  `keep/INDEX.md`. Clean up temporary output when done (disk space is
  limited).
- **No git worktrees** (user, 2026-09-18, sibling projects).
- **One Quartus flow on this box at a time** -- other cores build here;
  check `pgrep -a quartus` first and never kill a flow that is not this
  project's (user rule from the sibling cores).
- Quartus 17.0.x only; never edit `sys/`.
- Commit only when the user asks.
