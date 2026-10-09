# Resume prompt -- HP-UX 10.20 runs multi-user on the MiSTer; next: Artist graphics (2026-10-09, morning)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
This replaces `RESUME-20261009-hpux-login.md` (its steps 1 and 3 are done).
You may change `rtl/cpu/` and the rest of the machine (as the last resume
said); record CPU changes in `docs/design/cpu-requests.md` for the CPU
stream's review, as #3-#8 were.

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/system.md` 10 (builds 14, 15) and 7 (the debug recorder).
3. `docs/review/08-artist-registers.md` -- **the Artist at the register
   level**: what HP's STI routines (in the system ROM at 0xF0024000), HP-UX
   and Linux use, QEMU's 20 deviations, and a first-milestone plan (6.1).
   Also `docs/review/06c-hpux-graphics.md` and `docs/reference/rom/HARDWARE.md` 6.3.

## What happened (session 22f75121, 2026-10-09 05:30-08:30)

* **Root logs in on the board.** root's password on tenox's image is not
  published; at the user's request it was set to `password` from a
  single-user boot (original kept as `/etc/passwd.tenox` on the board's
  image). `/etc/lvmtab` named QEMU's `c0t6d0`; rebuilt with `vgscan`
  (`c2t6d0`, the 715's SCSI is ext_bus 2). `disks/README.md`, root README.
* **The board's build-14 boot was at 64 MB**, not 16 (the OSD's setting);
  32 MB also boots multi-user on the board, and in romsim single-user
  (`uname`, `bdf`): the old 32 MB "endless trap 7" is gone.
* **Stale text SIGILL, fixed (CPU, `68ec0f6`, cpu-requests #8).** At 32 MB
  `which` (csh) and a start-up grep died of SIGILL; their cores' save_state
  had IIR = stale data (a stack address, ASCII) at the first instruction of
  a just-paged-in page and IOR = the page base. HP-UX reads text in by DMA
  under an in-transit mapping without execute rights and never FICs the
  frame; a process jumping into a read-ahead page in transit takes trap 6,
  then trap 7, and sleeps -- and our fetch had filled the I-cache line on
  the trapping fetch. A no-execute fetch is now a NOP that fills nothing.
  New tlbx vector (`vfetch` #7) fails on the old core. Build 15 ran 40
  passes of an evict-and-re-page loop at 32 MB (31 min) with no crash.
* **Recorder** (`86be259`): new event types 11 (interruption + instruction
  word) and 12 (FDC/PDC/FIC with VA and physical line), an I-fill flag on
  line reads, and a freeze 1024 events after a user-mode trap 8/10/11.
  `tools/mister/trace_dump.py dump` on the MiSTer (`/media/fat/hp715dbg/`).
* `board.sh console` logs prompts (`ISL>`, `# `, `Console Login:`); `type`
  passes quotes. HP-UX's clock is 5 h behind (Main_MiSTer sends local
  standard time except to NeXT; STUBS S-022: add `HP9K715` to
  `rtc_is_utc()` in the user's Main_MiSTer fork -- the user's call).
* `release/` = build 15; the release notes are in the **root README**
  (user: no README inside `release/`).

## Where things stand

* Board: build 15 loaded, 32 MB OSD setting, HP-UX multi-user, logged in as
  root on the console (`board.sh console 0` logging to this session's
  scratchpad `keep/board_console.log`, PID in `ps`).
* Gates on `68ec0f6`: `tests/run-cputest.sh` 12/12, `tests/run-cosim.sh`
  8/8 identical, `tests/run-rom.sh` PASS.

## Next steps

1. **Artist, milestone 1** (review 08 6.1): the PDC 1.6 boot console on
   Artist. Address decode (MIOC `HAS_ARTIST`; 0xF8000000 word read must
   bus-error, 0xF8300004 must answer), VRAM 2048x1024x8 in DDR3 (memory
   placement rule), the CPU frame-buffer window modes 0x1360/0x2EA0/0x3BA0,
   the 0x118000 register file and BINC block, rect fill / block move, busy,
   the LUT staging + 0x300118 load, MISC_VIDEO storage, the self_test
   signature constant, video out through the MiSTer framework (palette
   mode). Check against the ROM in romsim first (review 08 6.1's list), then
   a Verilator unit bench, then the board. STUBS entries per 08 6.4.
2. The release EEPROM with the graphics console (S-016), then HP-UX's ITE
   (08 6.2), then X (08 6.3: disassemble the X server's Artist driver from
   the image).
3. Later: 82596 LAN, Harmony, CD audio; CPU: dual-issue self-test patch
   (S-011), P-016.

## How to work

* romsim: `make -C verilator romsim ROMSIM_DIR=obj_dir_rom_<name>` (a new
  dir per RTL state; checkpoints restore only into the build that made
  them); a 32 MB single-user boot reaches the shell at ~1.34G cycles
  (~85 min); `--evtrace` prints the recorder's events (decode with
  `tools/mister/trace_dump.py decode`).
* Board: `tools/mister/board.sh push|load|console|type|shot|setup`; HP-UX
  login root / `password`; single-user: Escape at "Press <ESCAPE>",
  `boot scsi.6 isl`, `hpux -is`.
* Gates after `rtl/cpu` changes: `tests/run-cputest.sh`, `tests/run-cosim.sh`,
  `tests/run-rom.sh`. Quartus: `quartus_sh --flow compile HP9K715` with
  `setsid nohup`, ~30 min, one flow at a time (`pgrep -a quartus`).
* Rules (CLAUDE.md, memory): commit often with explicit paths, every stub in
  `docs/STUBS.md`, never delete anything without asking, show the user
  screenshots as things move, release notes in the root README.
