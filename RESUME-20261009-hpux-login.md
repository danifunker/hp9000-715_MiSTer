# Resume prompt -- HP-UX 10.20's user-mode FP bugs found; the login (2026-10-09, early morning)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
This replaces `RESUME-20261008-hpux-login.md` (its step 0 is done). You may
change `rtl/cpu/` and the rest of the machine.

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/system.md` 10 (builds 13, 14) and 11 (romsim: `--fptrace`).
3. `docs/design/cpu.md` 1.1 (fr0 as an operand), the trap table row 22.

## What happened (session 9348ed10, 2026-10-08 23:00 - 2026-10-09)

The user-mode double compare that stopped HP-UX's start-up at "Start
Software Distributor agent daemon" (awk's `for` loop never ended) had two
causes, both in the CPU, both found in romsim and fixed with tests:

1. **Trap 22 (assist emulation) carried no ISR/IOR** (`e8c2024`). The ACD
   (p.4-25) sets them to the data address of a coprocessor load/store and
   HP-UX's `$emulation_trap` emulates FP loads/stores from them when the FPU
   is disabled. The core set them only for the data traps. Fixed in both
   cores; the trap suite's `fpdis-*`/`asst-*` groups (QEMU has no CCR, so
   they carry their own expectations, `compare.py` "expect" + `model.py`
   QEMU_REF_BUGS no-ccr/copr-uid) fail on the old RTL. **Build 13** (64 MHz
   met) on the board: still stopped at swagentd -- a `--traps` run showed
   HP-UX 10.20 takes *no* trap 22 at all in a single-user session (the FPU
   stays enabled for user processes), so this was right but not the cause.
2. **fr0 as a source operand read the status register** (this commit).
   ACD p.6-4: in a non-load/store instruction fr0 "encodes a floating-point
   +0 or a fixed-point 0" as a source. awk compares against fr0
   (`fcmp,dbl,< fr4,fr0` = "x < 0?"); with the status word (flag/queue bits)
   as the operand, "0.0 < fr0" was true and awk's truth test of a false
   relational result said true: `(1==1)+0` printed 0 on the board, every
   `for` loop ran forever. Found with the new romsim `--fptrace` (the FP
   unit's issues/operands/results/loads/stores; user-mode PCs end in 3).
   Fixed in `pa_fpunit.sv` (the operand ports; the store port still reads the
   status). The fp suite's `fr0-source` group (status word 0xF8000000, so the
   wrong operand is a huge negative number) fails 25/32 on the old unit.
   Also new: `fldd-cached` (cached doubleword FP accesses after integer
   stores, after FDC, read back by LDW: the other fp groups' operands live
   in the ROM, which is uncached) -- passes on both.

Other: `tools/mister/board.sh console` streams again (`tr` block-buffered
into the pipe, `1f613a4`); `build 13` row in system.md 10; `--fptrace` in
system.md 11.

## Where things stand

* **Build 14 (= both fixes) reaches `Console Login:` on the board** (16 MB;
  setup +0.254 ns, hold +0.251 ns, 28,601 ALMs; system.md 10): the whole
  start-up sequence runs, VUE fails to start its X server (no graphics yet)
  and offers the console login. `root` asks for a password: the image's
  original root password is not recorded anywhere here, so the login is
  the user's to do (or, if the user wants, blank it from a single-user boot).
  `release/` holds build 14.
* romsim: `obj_dir_rom_fix4` = both fixes; `ck_su16_fix4.sav` (scratch
  `keep/`, session 9348ed10's INDEX.md) at "INIT: SINGLE USER MODE", 16 MB,
  if the boot got there; a single-user boot with the awk test ran on it.
* Board: 16 MB, `hp715.eep` (autoboot), the patched `hpux1020.img` with
  lan0 blanked (last session). `board.sh console 0` in the background logs
  to `$LOG`.
* The 32 MB romsim boot's "endless trap 7 at a user PC" (last resume) is
  most likely the fr0 bug too (every user-space compare against zero was
  wrong); re-check at 32 MB.
* Note: HP-UX's kernel zeroes and copies pages with FP stores
  (`bz_doubles`, `pgcopy_doubles`) and saves/restores the user's FP state on
  every interrupt (`inttr_fp_rstr_83`): the FPU is busy in the kernel too.

## Next steps

1. **Login** (the user, with the root password; `board.sh type` types it
   only if the user asks): then `uname -a`, `ioscan -f`, `vgdisplay`, `bdf`.
   Note what HP-UX complains about (`vxfs fsck: sanity check failed: cannot
   stat #` appeared in the rc output; `lvlnboot: couldn't query physical
   volume /dev/dsk/c0t6d0` in single-user: the device file naming after the
   BDRA rewrite, `disks/README.md`).
3. The 32 MB boot in romsim (`--ram-lg 5`) and a kernel-start checkpoint.
4. Then `RESUME-20261008-system-next.md` steps 3-5: Artist graphics (STI
   console), the release EEPROM with the graphics console, 82596 LAN,
   Harmony, CD audio.
5. CPU: dual-issue self-test patch (S-011), P-016 stall-on-use.

## How to work

* romsim: `make -C verilator romsim ROMSIM_DIR=obj_dir_rom_fix4`; a
  single-user boot: `+eeprom=HEX --ram-lg 4 --turbo 15 --stamp --disk0
  disks/hpux1020.img --snapshot --type 'boot scsi.6 isl\r' --then 'ISL>'
  'hpux -is\r' --save-on 'SINGLE USER' FILE --then '# ' "CMD\r" --until STR`
  (~40 min to the shell); from a checkpoint: `--restore FILE --type "CMD\r"
  --type-after '# '` plus `--traps`, `--fptrace --fptrace-from C`, `--sample
  N`, `--trace N --trace-from C`, `--wtrace A B`. The EEPROM hex:
  `tools/eeprom/mkeeprom.py bootstrap --hex FILE`.
* Kernel symbols: `roms/hpux/vmunix.syms` (bisect PC -> symbol); user-mode
  PCs have PL 3 in the low bits.
* Gates after `rtl/cpu` changes: `tests/run-cputest.sh`, `tests/run-cosim.sh`,
  `tests/run-rom.sh`. Quartus: `quartus_sh --flow compile HP9K715`, ~70 min,
  one flow at a time (`pgrep -a quartus`).
* Board: `tools/mister/board.sh push|load|console|type|shot`.
* Rules (CLAUDE.md, memory): commit often with explicit paths, every stub in
  `docs/STUBS.md`, never delete anything without asking, show the user
  console screenshots as things move.
