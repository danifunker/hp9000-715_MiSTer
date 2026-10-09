# Resume prompt -- HP-UX 10.20 runs on the board; what comes next (2026-10-08, evening)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
This replaces `RESUME-20261008-hpux-kernel.md` (done) and the HP-UX items of
`RESUME-20261008-system-next.md`. You may change `rtl/cpu/` and the rest of
the machine (the user, 2026-10-08: CPU changes go through this stream).

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/system.md` 10 (builds 11, 12) and 11 (romsim: `--memdump`,
   `--watch/--watchval/--pcwatch`, the D-cache and walker lines of `--wtrace`).
3. `docs/design/cpu-requests.md` #7 (reviewed), `docs/STUBS.md` S-020/S-021.
4. `disks/README.md` -- the LVM boot-record rewrite the image needs.

## What happened today (session 5ab4cb5c)

Three findings, all committed, each with its evidence in the commit message:

1. **CPU: the hardware walker's PDIR read returned stale data** (`665f2e8`).
   `pa_dcache.sv`'s `DC_RD2` missed over a dirty victim, wrote the victim back
   and then took the flush path (`S_INVAL`) instead of filling: no error, and
   `op_rd2` still held the previous walk's entry. The walker judged that entry,
   wrote CR28 = 0, HP-UX's DTLB-miss handler called it a page fault on a
   mapped kernel page (`lo_mibinit`'s bcopy of a string at 0x4250c), `vfault`
   found no page map and the panic's own printf faulted the same way. Found
   with `--wtrace` + `--memdump` (RAM held the right entry, the walker saw
   another). tlbx "walker" has two vectors for it (fail on the old RTL).
   cpu-requests #7 (the I-LAB) kept; the refresh now covers the D-form TLB
   instructions too (`45c4ad1`, ERS s.6.4 "identical").
2. **SCSI target: MODE SELECT never finished** (`c969097`). After the c720
   driver's deliberate 10-second post-reset wait (`c720_init` -> Ktimeout
   `c720_init_reset_wait_done` with `c720_slow_post_reset_ticks` = 1000 ticks;
   the "16 MB idle" was just this wait) HP-UX probes the disk and issues MODE
   SELECT(6) with 24 bytes; `scsi_targets.sv` kept requesting DATA_OUT (the
   write path's chunk counter wrapped) and the driver looped on 13k
   phase-mismatch interrupts.
3. **The disk image's LVM boot record names QEMU's disk** (`a289321`). The
   kernel activates the root VG from the BDRA (LBA 256): its PV path was
   8/0/0/0.6.0 (the B160L's PCI SCSI the image was installed on); the 715's
   disk is 2/0/1.6.0, so no PV attached, "Could not configure root VG".
   `tools/hpux/lvmbdra.py setpath IMG 2/0/1.6.0` rewrites it with both
   checksums (`disks/README.md`); the card's copy got the same block.

Result: **build 12 on the MiSTer (16 MB, release EEPROM) boots HP-UX 10.20
through its start-up sequence** -- file systems mounted, hostname set, syncer
started, "Configure LAN interfaces ... FAIL" (expected: no LAN), then "Start
Software Distributor agent daemon" was still running when this was written.
In romsim the same path works at 16 MB with `--turbo 15` over the kernel
(the 10 s wait is 640M cycles at 64 MHz); a fresh 32 MB boot was running.

Gates on the CPU change: `tests/run-cputest.sh` 12/12 (tlbx 127 vectors),
`tests/run-cosim.sh` 8/8 identical, `tests/run-rom.sh` PASS. Builds 11 and 12
meet 64 MHz (system.md 10).

## Where things stand

* Board: build 12 loaded, 16 MB, `hp715.eep`, the patched `hpux1020.img`.
  The on-screen serial terminal shows the console; `board.sh console`
  captured nothing today (the `/dev/ttyS1` reader got no bytes -- check the
  stty/`cat` path, the screen terminal works). `board.sh type` types.
* Scratch (this session's `keep/`, `INDEX.md` there): `ck_k16_fix.sav`
  (16 MB kernel start, restores into `verilator/obj_dir_rom_fix2`, built at
  `a289321` + the harness as committed), `ck_k32_fix.sav` (32 MB, same
  build line), `builds/HP9K715_build11.rbf`, `build12.rbf`, the Quartus logs,
  `hpux1020_bdra_orig.bin` (the image's original LVM boot block) and
  `hpux1020_bdra_715.bin` (the rewritten one), the trace logs.
* `pgrep -f` matches its own shell: kill sims with `ps -o pid= -C Vemu`.

## Next steps

1. **Login.** Watch the board to the `Console Login:` prompt (`board.sh shot`),
   log in (`board.sh type 'root\r'`), run `ioscan -f`, `vgdisplay`, `uname -a`,
   `bdf`. Expect LAN and audio missing (no 82596, no Harmony). Note anything
   HP-UX complains about (asio0, ps2, CentIf).
2. **The serial capture on the board** (`board.sh console`): make it work
   again so console logs can be kept (`tools/mister/board.sh` console case).
3. **The 32 MB boot in romsim** (`keep/logs` if it finished): the same path
   at 32 MB, and a checkpoint at the kernel start for later work.
4. **Then the system-next plan**: Artist graphics (STI console), the release
   EEPROM with the graphics console, 82596 LAN, Harmony, CD audio
   (`RESUME-20261008-system-next.md` steps 3-5).
5. CPU: the dual-issue self-test patch (STUBS S-011) and P-016 stall-on-use
   remain; nothing HP-UX needs is known to be missing.

## How to work

* romsim: `make -C verilator romsim ROMSIM_DIR=obj_dir_rom_fix2`;
  `+eeprom=HEX --ram-lg N --turbo 15 --turbo-until C --stamp --disk0
  disks/hpux1020.img --snapshot --type 'boot scsi.6\r' --traps --scsitrace
  --save-on 'start 0x18fe68' FILE`, `--restore FILE` (same build). A kernel
  run needs `--turbo 15 --turbo-after <kernel start>` to get past the c720's
  10 s wait in minutes. `--wtrace A B`, `--memdump CYCLE ADDR LEN FILE`,
  `--watch A B` (physical), `--watchval V`, `--pcwatch PC`, `--trace N
  --trace-from C`. `tools/sim/console_png.py LOG PNG` renders a console log
  (strip `^SCR` lines first when `--scsitrace` was on).
* Kernel symbols: `roms/hpux/vmunix.dis`, `.syms`; the function-transition
  listing used today is a 20-line python over the `--trace` output (PC ->
  symbol by bisect).
* Gates after `rtl/cpu` changes: `tests/run-cputest.sh`, `tests/run-cosim.sh`,
  `tests/run-rom.sh`. One Quartus flow at a time (`pgrep -a quartus`);
  `quartus_sh --flow compile HP9K715` from the project root, ~60-80 min.
* Board: `tools/mister/board.sh push|setup 16 0|load|shot|type`.
* Rules (CLAUDE.md, memory): commit often with explicit paths (never
  `git add -A`, never the `.qsf` stamp), every stub in `docs/STUBS.md` in the
  same change, never delete anything without asking (scratch included),
  show the user console screenshots as things move.
