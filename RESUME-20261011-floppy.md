# Resume prompt -- the LASI PC floppy (WD37C65C) for HP-UX 11i (2026-10-11)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`
as the **system stream** (everything outside `rtl/cpu/`). The goal of this
stream: **HP-UX 11i v1's install CD boots past its floppy probe.** Build 36
(2026-10-11) got the CD's ISL and INSTALL kernel running (cpu-requests #9,
`1d17078`); the kernel now panics in its I/O probe:

```
2/0/10 fdc
System Panic: ... panic: fdc_cmd_exec: FIFO problem
PC-Offset Stack Trace: 0x0015b62c 0x0045a554 0x0045b154 0x0045b540 ...
```

(`docs/design/system.md` 10, build 36: the whole console log is in
`scratch/board-11i.log` if it is still there.) HP-UX 10.20 has no floppy
driver (ioscan: `2/0/10 fdc UNCLAIMED`); 11i binds one, and LASI page A reads
0 in our RTL (STUBS **S-015**, **P-004** "out of scope"), so its WD37C65C
never shows RQM and the driver panics instead of giving up. Do not touch
`rtl/cpu/` (user rule, 2026-10-09); CPU bugs go in
`docs/design/cpu-requests.md` with evidence.

## Status (2026-10-11, end of the floppy session)

**Done.** `rtl/lasi/lasi_fdc.sv` (`dd17162`; review `docs/review/10-hpux-fdc.md`,
STUBS S-028, P-004 superseded): the WD37C65C as a 765A with no drive, LASI's
FIFO/DMA, IRQ bit 20. Gates: `make -C verilator tb_fdc` PASS; `tests/run-rom.sh`
PASS; the ROM's floppy self-test passes with fastboot off **at the real CR16 rate**
(`--turbo` makes Audio, RTC and, through a late audio interrupt, Floppy fail --
system.md 11 has the checkpoint recipe); build 37 (seed 2) missed 64 MHz by
0.179 ns on CPU paths, **build 38 (seed 3, `HP9K715.qsf`) meets every clock**,
36,886 ALMs (88 %; the floppy is 248). Board: HP-UX 10.20 boots to CDE
(`2/0/10 UNCLAIMED Built-in Floppy Drive`); **11i's installer reaches its main
menu** (Ignite-UX B.4.2.108, `Floppies: 0`) on the serial console (recipe below)
and on HDMI: graphics EEPROM `hp715_gfx2.eep` in `.s1`, the ISO in `.s3`,
`board.sh load`, `board.sh key '\e'` every second until `BOOT_ADMIN>` shows
(OBS), `board.sh key 'boot scsi.2\r'`, `62\r`, `\r`. Nothing was installed yet;
`.s3` is back to `hp715audio.cue`.

**Next:** Install HP-UX onto `hpux11i.img` (ID 5) from that menu (hours; the
CD is one of several -- the OE may ask for CD 2), then boot it from scsi.5;
anything CPU-shaped goes in `docs/design/cpu-requests.md` (no `rtl/cpu/` changes
in this stream).

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/STUBS.md` S-015 (LASI pages not built, incl. A and D) and P-004.
3. LASI ERS chapter 10 "PC Floppy": `docs/reference/txt/Lasi_ers.txt` lines
   3339-3504 (register map below), chapter 14 interrupts (bit 20 = floppy),
   12.2.2 I/O reset register (bit 5 = "ext": FDC + LAN buffer).
4. `docs/reference/rom/HARDWARE.md` 4.9 -- what HP's ROM self-test does to the
   FDC with fastboot off (the second gate below).
5. `docs/design/system.md` 3 (the MIOC `dma_*` port, the arbiter in
   `rtl/hp715.sv` lines ~214-360 for the 53C710 / Harmony / 82596 masters)
   and 10 builds 31-36 (the design is at 87 % of the device).
6. `rtl/lasi/lasi.sv` -- the page decoder (page = addr[15:12]; pages 4, 6, 7
   are forwarded to Harmony / the 53C710 / the 82596 with `*_req`/`*_pend`,
   the pattern to copy for page A; page D holds the FDC DMA registers).

## What the hardware is (LASI ERS ch.10)

An external **WD37C65C** (a uPD765A/82077-class FDC with its own data
separator; no public data sheet in `docs/reference/`, but the 765 command set
is: SPECIFY, SENSE DRIVE STATUS, RECALIBRATE, SEEK, SENSE INTERRUPT STATUS,
READ ID, READ/WRITE DATA, FORMAT TRACK, VERSION, CONFIGURE, PERPENDICULAR ...;
QEMU's `~/src/qemu-11.1.1/hw/block/fdc.c` is a complete, readable 82077/765
model to crib semantics from -- command/result phases, MSR RQM/DIO/CB bits,
ST0-ST3) behind a LASI wrapper. Byte registers in the 4 KB block at
LASI+0xA000 (0xF010A000), DMA registers at LASI+0xD000:

| Offset | Register | R/W | Note |
|---|---|---|---|
| 0xA004 | FDC data register | R/W | command bytes in, result bytes out (765 "FIFO"/data) |
| 0xA008 | FDC master status register (MSR) | R | 765 MSR: bit 7 RQM, bit 6 DIO, bit 5 NDM, bit 4 CB, bits 3:0 drive busy |
| 0xA020 | FDC control register | R/W | WD37C65 "CCR"/DSR-class (data rate) |
| 0xA040 | FDC operations register (DOR) | W | bit 2 = !reset, bit 3 DMA enable, bits 5:4 motors, bits 1:0 drive select |
| 0xA014 | LASI FIFO data register | R/W | the 4-byte FIFO (slave access) |
| 0xA018 | LASI floppy control | R/W | bit 0 WE (mem -> FDC), 1 RE (FDC -> mem), 2 FDC_IE, 3 DMA_IE |
| 0xA01C | LASI floppy status | R | bit 0 FULL, 1 EMPTY, 2 DMA_IRQ |
| 0xD000 | FDMA address (FDAR) | R/W | 31:12 page, 11:2 word offset (increments per byte moved), 0 DMA_EN read-only |
| 0xD004 | FDMA enable | R/W | bit 0 DMA_EN; the rest read-only copies |

DMA: a one-page circular buffer of **unpacked bytes** (one byte per word, in
the most significant byte; word transactions on GSC), the FDAR the head
pointer; LASI keeps the FIFO full (WE) or empty (RE) with no count -- the FDC
ends the transfer and interrupts; a DMA interrupt when the offset reaches
0x3FF or 0x1FF (half/full page). Interrupt bit 20 in LASI's IRR/IMR is the
OR of the FDC's INT (if FDC_IE) and the DMA interrupt (if DMA_IE).

The ROM's I/O self-test (fastboot **off**, HARDWARE.md 4.9) writes DOR = 0
then 0x0C, expects **MSR = 0x80** (RQM, idle), uses the data register and the
LASI FIFO at +0x14/+0x18/+0x1C, programs 0xF010D000/0xF010D004 and expects
IRR bit 20 (0x100000) afterwards. Linux (`drivers/parisc/lasi.c:78`) only
writes 0xFFFFFFFF to +0xA000 at reset; it has no driver. QEMU has none
either (`hw/misc/lasi.c` returns 0 for `LASI_FDC`).

## Plan

### 1. Find out exactly what 11i's driver needs

Pull the INSTALL kernel from the CD's LIF and disassemble the driver -- the
panic names `fdc_cmd_exec`, and the probe path is `fdc_attach`/`fdc_init`
or similar:

```bash
python3 tools/hpux/hpdisk.py disks/hpux11i_oe_cd1.iso lif
```

shows `INSTALL` (17,282,048 bytes, type 0xcffe) -- a LIF file holding the
kernel (`lifget` it, then `tools/hpux/som.py FILE info` / its disassembly
mode; the loader printed `9686820 + 1122304 + 691616 start 0x14eae8`, so
the text may be a plain SOM or a LIF-wrapped one -- `tools/hpfw/hpfw.py`
unpacks LIF too). Find every register the probe touches (expect: DOR reset
pulse, MSR polls for RQM/DIO between command and result bytes, VERSION or
CONFIGURE, SPECIFY, SENSE INTERRUPT STATUS x4 after reset, RECALIBRATE +
SENSE INTERRUPT per drive, maybe READ ID with DMA), what "FIFO problem"
tests (most likely MSR never showing RQM = 1 within a timeout, or RQM with
the wrong DIO), and **what makes the driver conclude "no drive"** -- a
RECALIBRATE whose SENSE INTERRUPT returns ST0 with EC (equipment check) /
NR, or a timeout -- so the kernel continues without a floppy. Write it down
in a new `docs/review/10-hpux-fdc.md` (register trace, command sequence,
expected answers), as review 06d does for the c720 driver.

### 2. Build `rtl/lasi/lasi_fdc.sv`

Minimum that satisfies 1. and the ROM test (HARDWARE.md 4.9), with **no
drive attached** (every seek/recalibrate ends in ST0 = abnormal termination
with equipment check / not ready, reads fail with ST1 missing address mark
or ST0 NR -- whatever the driver's "absent" path expects):

* the 765 core: DOR (reset bit; a reset makes the FDC interrupt with
  "polling" status, SENSE INTERRUPT then returns ST0 = 0xC0 + drive, four
  times), MSR with RQM/DIO/CB, the data register's command/result phases
  for the commands the probe and the ROM use (invalid commands answer 0x80,
  as a 765 does), ST0-ST3, the step-rate/HUT bytes of SPECIFY accepted and
  ignored, VERSION = 0x90 (enhanced) or 0x80 -- check which the driver
  wants;
* the LASI wrapper: FIFO/control/status registers, FDAR/enable, DMA through
  the MIOC `dma_*` port as a fourth master in `hp715.sv`'s arbiter (one word
  per byte, byte in the top lane), the interrupt line into bit 20, I/O reset
  bit 5;
* `lasi.sv`: page A and the two words of page D forwarded to it like pages
  4/6/7; update the comment at the top and S-015.

Keep it small: the design is at 36,454 ALMs (87 %); a few hundred ALMs at
most (the 53C710 is 2,182, Harmony and the 82596 less). No image support in
this step -- a floppy image mounted through hps_io (a `SC4,IMG` slot, 1.44
MB raw) is a follow-on; file it as a planned stub.

STUBS: retire P-004 / narrow S-015 (pages A and D built), add an entry for
"no media / no drive" (what the real thing does: a 1.44 MB drive on J2,
`/dev/rfloppy/c20Ad1s0`; the risk: none for booting; what doing it properly
takes: the image slot, READ/WRITE DATA with the sector buffer, FORMAT).

### 3. Gates, in order

1. A unit bench `verilator/tb/tb_fdc*.sv` (`make -C verilator tb_fdc`): the
   reset/SENSE INTERRUPT sequence, a SPECIFY, a RECALIBRATE on a missing
   drive, the ROM's DOR/MSR/FIFO/DMA sequence from HARDWARE.md 4.9, one DMA
   transfer through a fake `dma_*` slave.
2. `tests/run-rom.sh` (fastboot on, ~10 min) must still PASS.
3. **The ROM's FDC self-test with fastboot off**: `python3
   tools/eeprom/mkeeprom.py bootstrap --fastboot 0 -o scratch/slow.eep --hex
   scratch/slow.hex`, then `verilator/obj_dir_rom/Vemu +eeprom=scratch/slow.hex
   --stamp --until 'BOOT_ADMIN>'` (slower: the long self-tests run; the
   I/O test's chassis codes and any FAIL line show on the console -- the
   test numbers are in `docs/reference/rom/BOOTFLOW.md` section 4; the
   parallel-port test in the same group may already fail, S-015/P-010, so
   judge the FDC part by its own codes).
4. Quartus 17.0.2 build 37: `setsid nohup
   ~/intelFPGA_lite/17.0/quartus/bin/quartus_sh --flow compile HP9K715 >
   scratch/build37.log 2>&1 < /dev/null &` (~35 min; `quartus_sh` is **not on
   PATH** from a tool call). One flow at a time (`pgrep -a quartus`), never
   edit `files.qip`/QSF/SDC during it, no simulation beside it; record it in
   `docs/design/system.md` 10 (ALMs, the four slacks from
   `output_files/HP9K715.sta.rpt` "Setup Summary"/"Hold Summary", lines
   ~153-185).
5. The board (MiSTer at 192.168.99.92; `tools/mister/board.sh`): **HP-UX
   10.20 still boots to CDE** (its probe must still say UNCLAIMED, not
   hang), then **the 11i CD**. The recipe that worked on 2026-10-11:

   ```bash
   tools/mister/board.sh push output_files/HP9K715.rbf
   ```
   point the OSD slots (back-end way, fine for iteration) at the serial-console
   EEPROM and the CD: on the board `/media/fat/config/HP9K715.s1` =
   `/media/fat/games/HP9K715/hp715_serial.eep` (the bootstrap image, already
   there; straight to `BOOT_ADMIN>` on the RS-232 console), `.s2` =
   `hpux11i.img` (the blank 8 GiB disk at ID 5, for the installer), `.s3` =
   `hpux11i_oe_cd1.iso` (NUL-padded to 1024 bytes; keep `.s0` =
   `hpux1020.img`); start `LOG=scratch/board-11i.log tools/mister/board.sh
   console 1500` in the background (setsid nohup), `board.sh load`, wait for
   `BOOT_ADMIN>` in the log, `board.sh type 'boot scsi.2\r'`, then read the
   log: ISL, `ISL booting hpux (;0):INSTALL`, the kernel's I/O list, and
   whatever comes after `2/0/10 fdc`. **Afterwards restore** `.s1` =
   `hp715_gfx2.eep` and `.s3` = `hp715audio.cue` (the user's setup; the
   `.bak-gfx2`/`.bak-audio` copies are there) and stop the logger by pid
   (`ps -o pid=,cmd= -C bash | grep "board.sh console"` -- **never `pkill
   -f`**, it kills the tool's own shell). Check the board is free first:
   `tools/mister/obs_shot.py scratch/now.png` shows the real HDMI; if HP-UX
   is up, shut it down over the LAN (`tools/mister/hpux.py run 'sync; (nohup
   /sbin/shutdown -h -y 0 > /dev/null 2>&1 &)'`) or ask.

   The graphics console works too (`hp715_gfx2.eep`, `board.sh key`, OBS),
   but the serial log is what makes the run unattended and greppable.

### 4. After the floppy

The 11i kernel's next stop is unknown: more of the I/O probe (it already
claimed graph3, c720 and its targets, lan2, asio0, CentIf, audio), then the
install's RAM file system (`INSTALLFS`), then the installer's UI on the
console. Anything CPU-shaped (an illegal instruction, a PA 2.0-ism, a 7100LC
detail -- `docs/review/07-hpux-cpu-specifics.md`) goes in
`docs/design/cpu-requests.md` as a new row with the evidence (the debug
recorder: `tools/mister/trace_dump.py`; the ROM's PIM after a crash: `pim
hpmc`); anything LASI/MIOC-shaped is this stream's. The system stream's wider
list is `RESUME-20261010-features.md`.

## Rules

* Every stub/simplification in `docs/STUBS.md` in the same change; never
  delete without asking; no git worktrees; never edit `sys/`; small, frequent
  commits (`Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`);
  release notes live in the root README (never `release/README.md`).
* One Quartus flow and one simulation at a time on this box; other cores
  build here (`pgrep -a quartus`, never kill a flow that is not ours).
* `grep` is a shell function here: use `/usr/bin/grep` or awk; `pgrep -f` /
  `pkill -f` match the tool call's own shell.
* Show console screenshots / OBS captures as progress is made
  (`tools/sim/console_png.py` for romsim logs, `obs_shot.py` for the board).
