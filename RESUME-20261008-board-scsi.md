# Resume prompt -- the board-only SCSI failure (2026-10-08)

**Resolved 2026-10-08 (build 9).** The cause was none of the leads below:
`sdram64` wrote a single doubleword as a BL8 burst with DQM = 11 on the
other four words, and on the board those words were written anyway, so
every DMA write's partner doubleword took a copy of it (seen with the
ROM's `peek` on the LIF header DMAed to 0x10000: dw0 = dw1, dw2 = dw3 ...;
the INQUIRY type byte at 0x3154 became 0x53). The CPU's line writes mask
nothing, so every memory test passed. Writes are now single-location (a
WRITE per 16-bit word); `search` lists `scsi.6.0 SEAGATE ST32550N` and
`boot scsi.6` runs ISL, the hpux loader and starts the kernel on the board
(STUBS S-019, system.md 10 build 9). Continue with
`RESUME-20261008-system-next.md`.

You are working on the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
This session has **one job**: find and fix why HP's boot ROM cannot use the
SCSI disk **on the real MiSTer**, while the same RTL works in Verilator.
When the board's `search` lists `scsi.6.0 SEAGATE ST32550N` and
`boot scsi.6` reaches ISL, stop and hand over to
`RESUME-20261008-system-next.md`.

## Read first

1. `CLAUDE.md` -- rules (binding: STUBS, never delete without asking, one
   Quartus flow at a time, commit often, Quartus 17 only, `rtl/cpu/` is the
   CPU stream's -- minimal fixes allowed while it is idle, logged in
   `docs/design/cpu-requests.md`, `tests/run-cputest.sh` before committing).
2. `docs/design/system.md` sections 3.3 (RAM port), 9 (MiSTer top, incl. the
   debug recorder), 10 (builds 1-5), 11 (simulation, incl. `ROMSIM_SDRAM=1`).
3. `docs/STUBS.md` S-019 (SDRAM capture), S-020/S-021 (SCSI);
   `docs/design/cpu-requests.md` #6.
4. `rtl/mister/sdram64.sv` (its header has the board measurements),
   `rtl/mioc.sv` (fill pipeline `f1_*`, `S_LRRAM`, the DMA/uncached RMW path),
   `rtl/cpu/pa_dcache.sv` (miss, fill, replay), `rtl/cpu/pa_biu.sv`.

## The board

The user's MiSTer at **192.168.99.92** is cleared for this work (user,
2026-10-08); ssh `root@192.168.99.92`, key login (never type a password).
`tools/mister/board.sh` wraps everything:

```bash
tools/mister/board.sh push output_files/HP9K715.rbf   # -> /media/fat/_Unstable/HP9K715.rbf, md5-checked
EEP=hp715_diag.eep tools/mister/board.sh setup 16 0    # 16 MB, SDRAM capture mode 0 (edge 3), disk + diag EEPROM
tools/mister/board.sh load                             # load_core
tools/mister/board.sh type 'search\r'                  # paced typing into the serial console
tools/mister/board.sh shot out.png                     # MiSTer screenshot (the on-screen console)
```

The core's RS-232 is the MiSTer's `/dev/ttyS1` (9600 8N1); only one reader
at a time. The pattern used all day (capture to a file on the MiSTer, wait
for a string):

```bash
ssh root@192.168.99.92 'stty -F /dev/ttyS1 9600 cs8 -parenb -cstopb raw -echo -crtscts clocal; \
  rm -f /tmp/c.raw; (nohup timeout 7200 cat /dev/ttyS1 > /tmp/c.raw &); sleep 1; \
  echo "load_core /media/fat/_Unstable/HP9K715.rbf" > /dev/MiSTer_cmd; \
  for i in $(seq 1 90); do sleep 1; grep -q "BOOT_ADMIN>" /tmp/c.raw && break; done'
```

Kill stray readers first (`ps | grep "cat /dev/ttyS1"`, busybox has no
pkill). `games/HP9K715/` on the card holds `boot.rom`, `hpux1020.img` (4 GiB,
md5 4a2d4b95...), `hp715.eep` (release: autoboot), `hp715_diag.eep`
(bootstrap: manufacturing mode, chassis codes on the console, straight to
BOOT_ADMIN), `hp715_diag_slow.eep` (same, fastboot off = the LFSR memory
test). The ROM drops a burst of typed characters: type slowly (board.sh does).

**Debug recorder** (build 7+): `rtl/hp715.sv` `dbg_ev` -> `rtl/mister/trace_ddr3.sv`
-> a 64K x 32-byte ring at DDR3 0x3200_0000. On the MiSTer:
`python3 /media/fat/hp715dbg/trace_dump.py clear` before the run, `dump`
after (copy the script there again if you change it). Records: SCRIPTS
instructions, SCSI bus bytes, interrupts, selections, DMA (address, byte
enables, data), the CPU's line requests (a line read repeating the previous
one is left out) and its uncached accesses to RAM and to the 53C710. The
simulator prints the same records with `--evtrace`;
`tools/mister/trace_dump.py decode LOG` turns them into the same text.

## What is known

Board runs 2026-10-08 (builds in the old session's scratchpad
`/tmp/claude-1000/-home-dani-repos-hp9000-715/e93fdf95-e3b8-4df7-a315-73282c2f658a/scratchpad/keep/builds/`, see its `keep/INDEX.md`):

* Fixed already: SDRAM reads came one 16-bit beat late (S-019; capture now
  at edge 3, `rd_mode` 0 -- edges 2.75 and 3 pass the LFSR test, 2.5, 3.5,
  4 fail); a cached load overtaking an older posted uncached store
  (cpu-requests #6, `pa_biu`; it broke the ROM's ECC test on the board and,
  once found, in the SDRAM-model simulation). Build 8 (`1ec4fe9`, setup
  +0.948 ns) passes every ROM self-test on the board and reaches BOOT_ADMIN.
* **Still broken on the board:** `search` lists `scsi.6.1` ... `scsi.6.7` with
  blank names and no `scsi.6.0`; `boot scsi.6` prints "ERROR: Cannot load
  IPL, error detected" (0x06.C5F2). 16 and 64 MB alike; capture modes 0 and 1
  alike.
* **Works in Verilator**, both on the ideal RAM and on the real controller
  (`make -C verilator romsim ROMSIM_DIR=obj_dir_roms ROMSIM_SDRAM=1`: sdram64 on
  `verilator/sim_sdram_chip.sv`, SDRAM_CLK in phase, `rd_mode` 3): `search`
  finds `scsi.6.0 SEAGATE ST32550N`, `boot scsi.6` runs ISL and the hpux
  loader, and (ideal RAM, 32 MB) HP-UX's kernel loads and starts.
* **The two event logs** (scratchpad `keep/board-scsi/sim_search_events.txt`
  and `board_search_events.txt`, same `search` at 16 MB) are **identical
  through LUN 0's INQUIRY**: the IODC init, the chip self-checks, SELECT,
  IDENTIFY 0x80, CDB `12 00 00 00 20 00`, the 36 data bytes, and the DMA
  writes of the data to 0x3150-0x3177 (`dmaW 3150 be=0f ...0202`, `dmaW
  3158 1f00001053454147`, ...). Then both fill **line 0x3140** from RAM
  (`lineR 3140`, after the DMA), and **the ROM takes a different branch on
  the board**: the simulator goes on to read line 0x3160 (the product
  string) and the register dump; the board skips 0x3160, re-patches the
  SCRIPTS (`lineW a9e0 ...`) and selects LUN 1 (IDENTIFY 0x81), then 2 ... 7.
  So the CPU sees different INQUIRY bytes in line 0x3140 on the board than
  in the simulator, or acts differently on the same bytes. The byte the ROM
  tests first is at 0x3154 (peripheral type) -- **doubleword 2 of its line**.

## Leads, most likely first

1. **Critical-word-first fills with a non-zero first doubleword have never
   been tested on the board.** Every ROM memory test reads lines from
   doubleword 0; this load misses on doubleword 2 (`sdram64` reads burst
   0x3150-0x315F first, then 0x3140-0x314F, `ram_rbeat` 2, 3, 0, 1). The
   board captures at edge 3 (`L = RD_LAT - 1`), the simulated chip at edge 4,
   so the board's beats arrive one cycle earlier than anything simulated.
   Check the fill path (`sdram64` second READ at rw 9, `rd_first`, the
   `k < 16` window and the done condition -- which still uses `RD_LAT`, not
   `L`; `mioc` `S_LRRAM` / `f1_*`; `pa_dcache` `S_FILLDATA`, `fill_got`,
   `S_FILLTAG`, the replay). Ways to see it: (a) give `sim_sdram_chip.sv` a
   parameter that returns read data one cycle earlier and run romsim with
   `rd_mode` 0 -- the board's timing in simulation; (b) add the fill beats
   (`mem_rdata`, `mem_rbeat`, address) for a chosen line to the recorder;
   (c) on the board, `poke` patterns at offsets 0x8/0x10/0x18 of a line and
   `peek` them back (BOOT_ADMIN `peek` reads one location; `peek 0xADDR`).
2. A D-cache miss/replay race that only the board's latencies expose (the
   M10K read-during-write note in `pa_dcache.sv`'s header).
3. The DDR3 side (ROM fetches, the ECC check store on every RAM write) only
   changes timing; it is not on the fill data path -- but it does change
   what the CPU executes when, so do not rule it out until 1 and 2 are.

QEMU cannot arbitrate this: its `-M 715` runs only SeaBIOS (not HP's ROM)
and the failure is a difference between our own simulation and our own
FPGA build. The simulator with the board's timing is the reference to
build.

## Working notes

* Builds: `~/intelFPGA_lite/17.0/quartus/bin/quartus_sh --flow compile HP9K715`
  (~35 min); check `ps -eo comm | grep -i quartus` first; record timing in
  system.md 10; keep each board rbf (e.g. in your scratchpad).
* A romsim checkpoint restores only into the build that made them; the
  16 MB SDRAM-model one at BOOT_ADMIN is `keep/board-scsi/ck_admin_sd16.sav`
  (needs `obj_dir_roms` built from `1ec4fe9`, i.e. before any RTL change).
  A 16 MB cold boot on the SDRAM model to BOOT_ADMIN takes ~15 min.
* Kill sims by PID, never by name (other runs share the binary name).
* The HP9K715.qsf diff (Quartus's version stamp) is noise; leave it out.
* When it works: record it (STUBS S-019/S-020, system.md 10, cpu-requests if
  `rtl/cpu` changed), commit, show the user a board screenshot of `search`.
