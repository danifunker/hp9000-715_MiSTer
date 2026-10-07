# HP 9000 Model 715 for MiSTer -- working notes for Claude

An FPGA recreation of the HP 9000 Model 715/64 workstation (PA-7100LC,
LASI, built-in Artist graphics) for the MiSTer (DE10-Nano, Cyclone V
5CSEBA6). All RTL is Verilog/SystemVerilog.

**State (2026-10-07):** documentation reviewed, firmware obtained and
unpacked, project skeleton laid down from Template_MiSTer. **No RTL yet** --
`HP9K715.sv` still drives the template's demo core (`rtl/mycore.v`, `cos.sv`,
`lfsr.v`), which is placeholder and goes away when the machine goes in.

## The user's process

1. Gather documentation and review it -- done, `docs/review/01`..`05`.
2. Disassemble the ROM -- **next**. `roms/hp715_pdc_rev1.6.bin`.
3. CPU test bench -- from the ROM's self-tests where possible, plus a
   SingleStepTests-style corpus generated with QEMU as the reference.
4. Check against existing emulators -- QEMU 11.1.1 `-M 715` (see deviations below).
5. Test in Verilator.

## Decisions so far

| | |
|---|---|
| Machine | **715/64 "Mirage Jr"** (CPU HVERSION 0x60A), model ID configurable to 715/80 (0x619) or 715/100 (0x60B). Not the 715/100XC (firmware 1.2 only), not 715/33/50/75 (PA-7100, HIL only). |
| CPU | PA-7100LC (PCX-L): PA-RISC 1.1 + MAX-1 halfword multimedia ops. **One CPU** -- the 7100LC and the 715 have no multiprocessor support. Keep it lightweight: single-issue first, iterative FP divide/sqrt, one shared multiplier; 2-way superscalar (OpenPA table 2.20 pairs) later. Budget ~8-10k ALMs (the Indy's R4600 is 9.4k). TLB 64 entries + 8 block entries, as the real chip. |
| Memory | **SDRAM = system RAM** (32/64/128 MB, the module fitted). **DDR3** (core window 0x30000000-0x3FFFFFFF, 256 MB) = video RAM, the ROM image, and optionally RAM above 128 MB to reach the 715's 256 MB maximum. **BRAM** = caches, TLB, line buffers. (User's standing preference.) |
| Firmware | HP's own **PDC revision 1.6** (`roms/`) is the target. SeaBIOS-hppa (LGPLv3, in the QEMU tree) is the redistributable fallback and the only firmware QEMU runs, so it is what any QEMU side-by-side comparison uses. |
| I/O | LASI: NCR 53C710 SCSI (disks + CD-ROM at ID 2), i82596 LAN, 16550 UART, parallel, PS/2 keyboard + mouse, Harmony audio with CS4215 codec, RTC. Artist 8-plane graphics up to 1280x1024. CD audio mixed digitally (the real drive's analog out goes to the codec). WAX (HIL, second serial, EISA) not planned. |
| OSes | HP-UX 9.05-11.00, 11i v1 (32-bit), Linux, NetBSD, OpenBSD, NeXTSTEP 3.3 (PS/2 keyboard only). |

## Layout

| path | what |
|---|---|
| `HP9K715.{qpf,qsf,sdc,srf,sv}` | Quartus project (from Template_MiSTer). `HP9K715.sv` is the MiSTer `emu` top. The core name is **HP9K715** (user, 2026-10-07): it is the OSD name, the rbf name and the `games/HP9K715/` folder. |
| `files.qip` | RTL file list -- add new RTL here |
| `sys/` | MiSTer framework, copied as-is from `../Template_MiSTer` (2026-08-26, `3ea1134`). Do not edit. |
| `rtl/` | the core (`pll*` from the template; demo files are placeholders) |
| `docs/review/01..05` | the 2026-10-07 reviews: system docs, chip docs, QEMU/SeaBIOS, ROM and prior art, firmware (PDC/IODC/STI) requirements |
| `docs/reference/` | PDFs and their text extracts (not committed; `README.md` there has the sources) |
| `roms/` | firmware (not committed; `README.md` there has the recipe and hashes) |
| `tools/hpfw/hpfw.py` | unpacks HP firmware tapes (LIF) and checks the image header checksum |
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

## Rules

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
