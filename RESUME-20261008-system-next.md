# Resume prompt -- the machine after board SCSI works (2026-10-08)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`
on the **system stream** (everything around the CPU). This replaces
`RESUME-20261008-system.md`. It assumes the board-only SCSI failure of
`RESUME-20261008-board-scsi.md` is fixed (the MiSTer's `search` lists
`scsi.6.0 SEAGATE ST32550N` and `boot scsi.6` reaches ISL); if it is not,
do that first.

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/system.md` -- the system design; section 9 (MiSTer top),
   10 (the build log), 11 (simulation).
3. `docs/STUBS.md` (S-016 EEPROM images, S-018 video/on-screen console,
   S-019 SDRAM capture, S-020/S-021 SCSI); `docs/design/cpu-requests.md`
   (#3-#6 were made by this stream and await the CPU stream's review).
4. `docs/review/06-os-hpux-linux.md` (what HP-UX needs; sections 2-4),
   `06d-hpux-c720-scsi.md` (the 53C710 requirements, section 7),
   `07-hpux-cpu-specifics.md`.

## Where things stand (2026-10-08)

* **Simulation**: HP's PDC 1.6 boots to BOOT_ADMIN; `search` finds the disk;
  `boot scsi.6` runs ISL A.00.38 and the hpux loader, which loads
  `/stand/vmunix` (`3957260 + 450560 + 593184 start 0x18fe68`, ~873M cycles
  at 32 MB; the loader needs more than 8 MB) and **HP-UX's kernel starts**.
  It clears memory (`bz_words`), then from ~960M cycles sits on the `rfi` at
  `skip_int_restore2_0` (0x20f3c) -- an interruption loop -- without
  printing anything.
* **Board** (MiSTer at 192.168.99.92, cleared by the user 2026-10-08): the
  core meets 64 MHz (build 8: setup +0.948 ns, 67 % ALMs); the ROM's
  self-tests pass and it reaches BOOT_ADMIN (SDRAM capture fixed, S-019;
  CPU ordering fixed, cpu-requests #6); the MiSTer screen shows the serial
  console and the MiSTer keyboard types into it; a debug event recorder
  writes the machine's SCSI/DMA/CPU-line events into DDR3 for
  `tools/mister/trace_dump.py`.
* **EEPROM**: `tools/eeprom/hp715_default.eep` (made by `mkrelease.sh`):
  manufacturing and chassis codes off, console RS-232, primary path scsi.6,
  autoboot and autosearch on (S-016). On the card as `hp715.eep`.
* **Disk**: `disks/hpux1020.img` (4 GiB raw, `disks/README.md`), on the card
  as `games/HP9K715/hpux1020.img`.

## Next steps, in order

1. **HP-UX's interruption loop in the simulator.** First rule out the
   simulator: `--turbo 15` makes CR16 15x fast, so HP-UX's 100 Hz clock
   interrupt would fire every ~43k cycles instead of 640k. The run that
   answers it was started 2026-10-08: scratchpad
   `/tmp/claude-1000/-home-dani-repos-hp9000-715/e93fdf95-e3b8-4df7-a315-73282c2f658a/scratchpad/kern2.log`
   (ideal-RAM romsim, 32 MB, turbo off from 870M cycles, PC sampled every
   10M, checkpoint `ck_kernel2.sav` at 885M taken with the disk idle --
   valid only for the `verilator/obj_dir_rom` build of `1ec4fe9`). If the
   loop remains: `--restore` that checkpoint with `--traps` (and
   `--trace N --trace-from C`) to name the interruption and its source;
   EIRR/LASI IRR/IMR/IAR (system.md 5, R06 3.5, 4.1), the CR16 compare,
   PDC calls (the ROM is real, so PDC is right unless our hardware answers
   wrongly). Symbols: `roms/hpux/vmunix.dis` (`tools/hpux/som.py`).
   QEMU helps here: the same image boots on `-M B160L` (old scratchpad
   `.../c636bb42-.../scratchpad/keep/qemu/`, see its `keep/INDEX.md`:
   `run-715-hpux.sh`, `hpux-boot-trace.py`, the PDC-call logs in
   `logs-os/`), so HP-UX's expected PDC sequence and early console output
   are known.
2. **HP-UX on the board**: release EEPROM (`board.sh setup 64 0`, default
   `EEP=hp715.eep`) autoboots scsi.6; watch the on-screen console
   (`board.sh shot`) or `/dev/ttyS1`; use the recorder for SCSI (R06d:
   SIGP vs WAIT RESELECT, live DFE, LCRC, stacked interrupts).
3. **Artist graphics** (the old plan's step 4; R06c, HW 6.3): VRAM in DDR3,
   the MiSTer framebuffer in palette mode, STI console; then
   `mkrelease.sh` with the graphics console (S-016) and the on-screen serial
   terminal becomes an OSD choice.
4. **Board hygiene**: the SDRAM read window's exact edges (S-019: only
   2.5 < window < 3.5 edges is known) and I/O constraints for the SDRAM pins;
   rerun `tests/run-rom.sh` and `tests/run-cputest.sh` after RTL changes.
5. Later: Harmony (P-003), 82596 (P-005), parallel (P-010), CD audio.

## How to work

* **romsim** (`make -C verilator romsim` -> `obj_dir_rom/Vemu`; `ROMSIM_DIR=`
  for a second copy, `ROMSIM_SDRAM=1` for the real SDRAM controller):
  `+eeprom=HEX --ram-lg N --turbo 15 [--turbo-until C] --stamp`,
  `--disk0 disks/hpux1020.img --snapshot` (writes stay in memory),
  `--type TEXT [--type-after STR] --then AFTER TEXT ...` (console input;
  `--type-after ""` types at once after a restore), `--until STR` (looked
  for after the last typed text), `--save-at C FILE`, `--save-on STR FILE`
  (both wait for an idle block device), `--restore FILE`, traces
  `--scsitrace --miotrace --evtrace --gsctrace --sdtrace --traps --trace N
  --trace-from C --sample N --leds --flags-from C`. Checkpoints restore only
  into the exact build that made them. A 32 MB boot to BOOT_ADMIN takes
  ~15 min, to the kernel ~1 h (the loader reads ~10 MB through the IODC).
* `tools/sim/console_png.py LOG OUT.png` renders a console log (romsim or
  board) as a screenshot -- the user likes to see them (SendUserFile).
* Board: `tools/mister/board.sh setup|push|load|console|type|shot|menu`,
  `sdram_sweep.sh`, `trace_dump.py` (see `RESUME-20261008-board-scsi.md`
  for the serial capture pattern). Kill sims and readers by PID.
* Gates: `tests/run-rom.sh` (8 MB ROM ratchet), `tests/run-cputest.sh`
  (after any `rtl/cpu` change), `make -C verilator tb_sdram64 tb_term`.
* Quartus 17 pitfalls met: no `"\\"` string escapes, no chained part-selects
  (`e[a -: 32][b:0]`), no hierarchical references in synthesised code,
  `cell` is a reserved word; `$readmemh` paths are relative to the project.

## Rules (from the user; also CLAUDE.md and memory)

* Commit often (small steps, explicit paths, never `git add -A`), with the
  session's `Co-Authored-By` line; never commit the `.qsf` version-stamp
  noise.
* Every stub in `docs/STUBS.md` in the same change.
* Never delete anything without asking -- including scratch, old builds, old
  RESUME files (`RESUME-20261008-system.md` is superseded by this file;
  `verilator/obj_dir_rom2`, `obj_dir_roms`, `obj_dir_term` are build
  output, ignored by git).
* One Quartus flow on this box at a time; never kill another project's.
* The MiSTer at .92 may be used for this core; ask before anything else
  outward-facing.
