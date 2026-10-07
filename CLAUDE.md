# HP 9000 Model 715 for MiSTer -- working notes for Claude

An FPGA recreation of the HP 9000 Model 715/64 workstation (PA-7100LC,
LASI, built-in Artist graphics) for the MiSTer (DE10-Nano, Cyclone V
5CSEBA6). All RTL is Verilog/SystemVerilog.

**State (2026-10-07):** documentation reviewed; HP's PDC 1.6 ROM obtained,
disassembled and analysed (`docs/reference/rom/`); HP-UX 10.20's kernel
extracted and its use of the hardware analysed (`docs/review/06*`); project
skeleton laid down from Template_MiSTer. **No RTL yet** --
`HP9K715.sv` still drives the template's demo core (`rtl/mycore.v`, `cos.sv`,
`lfsr.v`), which is placeholder and goes away when the machine goes in.

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
| CPU | PA-7100LC (PCX-L): PA-RISC 1.1 + MAX-1 halfword multimedia ops. **One CPU** -- the 7100LC and the 715 have no multiprocessor support. Keep it lightweight: single-issue first, iterative FP divide/sqrt, one shared multiplier; 2-way superscalar (OpenPA table 2.20 pairs) later. Budget ~8-10k ALMs (the Indy's R4600 is 9.4k). TLB 64 entries + 8 block entries, as the real chip. What HP's ROM and HP-UX require beyond the architecture (`docs/reference/rom/README.md`, `docs/review/06` section 3): DR0 reports revision 0 (single issue); PCX-L diagnose instructions incl. cache data/tag access; **128 KB I + 128 KB D direct-mapped caches with 32-byte lines** (the self-tests assume it; the ROM runs code planted in the I-cache by diagnose writes); the **hardware TLB-miss walker** (PDC_TLB enables it and HP-UX then depends on it); 8 block-TLB slots (HP-UX tells PCX-L from PCX-T by that count); exact shadow registers and RFIR; delayed FP traps; CR16 at exactly the board clock. |
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
| `rtl/` | the core (`pll*` from the template; demo files are placeholders) |
| `docs/review/01..05` | the 2026-10-07 reviews: system docs, chip docs, QEMU/SeaBIOS, ROM and prior art, firmware (PDC/IODC/STI) requirements |
| `docs/review/06*.md` | what HP-UX 10.20 and Linux need from the hardware: 06 by block, with sub-reports 06a audio, 06b PS/2/serial/parallel, 06c graphics/STI, 06d SCSI (c720 driver, SCRIPTS) |
| `docs/reference/rom/` | the ROM analysis: README (index + headline FPGA demands), BOOTFLOW, HARDWARE (incl. the reconstructed MIOC), FIRMWARE |
| `rtl/cpu/` | the PA-7100LC core, being built: `pa_alu.sv` (adds/compares/logical/unit/DCOR/DS + conditions), `pa_shift.sv` (shift/extract/deposit), `pa_max1.sv` (MAX-1) -- unit-tested against every suite vector, expectations from the model (`make -C verilator tb_alu tb_shift tb_max1`) |
| `tests/cpu/` | **pacputest**: bare-metal CPU test ROMs (gen_tests.py, 9 suites), QEMU reference logs (`ref/qemu`), the independent reference model (`model.py`) and `compare.py`; see its README |
| `verilator/` | the GUI simulator (`make && ./obj_dir/Vemu`) and unit benches (`tb/`, `make tb_alu` ...) |
| `tools/rom/` | ROM analysis tools (`annotate.py` -> `roms/disasm/`, `romlib.py`, `firmware_map.py check`, symbols in `tools/rom/symbols/*.sym`) |
| `tools/hpux/` | `qcow2.py` (read qcow2 without converting), `hpdisk.py` (LIF, LVM, HFS), `som.py` (SOM objects -> symbol-annotated disassembly) |
| `roms/disasm/`, `roms/hpux/` | generated listings, and HP-UX files pulled from the 10.20 image (`vmunix`, `system`, ISL ...) -- not committed |
| `docs/reference/` | PDFs and their text extracts (not committed; `README.md` there has the sources) |
| `roms/` | firmware (not committed; `README.md` there has the recipe and hashes) |
| `tools/hpfw/hpfw.py` | unpacks HP firmware tapes (LIF) and checks the image header checksum |
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
- It reports 16 block-TLB slots, so HP-UX on `-M 715` runs its **PCX-T**
  (PA-7100) code paths, not PCX-L ones (`docs/review/06` 3.1).
- SH1ADD/SH2ADD/SH3ADD(L) conditions NUV/ZNV/UV/VNZ are wrong: `do_add_uv()`
  (`translate.c:1140`) tests GR r1 bits 31-n..30 instead of the shifted-out
  bits 32-n..31 (Pa11_acd Table 5-2; found by the ALU unit bench and the
  reference model, `tests/cpu/model.py` `QEMU_BUGS`). DS conditions 4/5
  share the bug and also ignore PSW[V]'s subtract reading.
- Its 53C710 also clears DSTAT.DFE when raising an interrupt, which HP-UX
  treats as fatal (`06d`); its Artist MISC_VIDEO read overwrites bits HP's
  STI and HP-UX use as the monitor index (`06c`); its 82596 reads the PORT
  command from the wrong bits and its PS/2 loopback is 1 deep where the ROM
  needs 4 (`docs/reference/rom/HARDWARE.md`).

## Rules

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
