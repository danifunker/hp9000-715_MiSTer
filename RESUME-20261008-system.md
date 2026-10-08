# Resume prompt -- the rest of the HP 9000/715 machine (2026-10-08)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
Your job is **everything around the CPU** (the system stream): memory and
I/O, the devices, graphics, storage, input, sound and the MiSTer
integration. This replaces `RESUME-20261007-system.md` (still worth reading
for the original plan and the decisions).

## Read first

1. `CLAUDE.md` -- state, decisions, layout, tools, rules (binding).
2. `docs/design/system.md` -- **the system design**: address map, MIOC
   (memory blocks, ECC model, registers, error reporting), LASI, the 8-bit
   bus, clocks/reset/TOC, the ROM loader, the MiSTer top, builds,
   simulation.
3. `docs/STUBS.md` -- S-014..S-021 are this stream's (PS/2 byte level, LASI
   units, bootstrap EEPROM, ECC check store, video placeholder, SDRAM clock
   phase, SCSI bus/targets, 53C710).
4. `docs/design/cpu-requests.md` -- rows 3-5 are CPU fixes **made by the
   system stream** (exact load byte enables; `,m` flushes use the old base;
   the walker's `W_WALK_RD3` hold) waiting for the CPU stream's review.
5. `docs/reference/rom/README.md`, `BOOTFLOW.md`, `HARDWARE.md`,
   `FIRMWARE.md`; `docs/review/06d-hpux-c720-scsi.md` for the SCSI work.

## Where things stand

- **HP's PDC 1.6 boots clean to `BOOT_ADMIN>` in Verilator**: every
  power-on self-test passes (CPU, caches incl. code planted in the I-cache,
  TLB, the hardware walker, ECC single/multi-bit, injected I/O parity, FP),
  banner "BootRom Version 1.6 / Memory Size: 8 MB", manufacturing mode,
  serial console. `tests/run-rom.sh` asserts the milestones (~92M cycles,
  ~6 min at ~300k cycles/s).
- **The MiSTer top builds and meets 64 MHz** (system.md 10, build 1:
  25,041 ALMs, 358 M10K, setup +0.78 ns) -- built *before* the SCSI code;
  never run on a board yet. SDRAM (`rtl/mister/sdram64.sv`, unit bench
  `make -C verilator tb_sdram64` passes), DDR3 for the ROM and the ECC check
  store (`ddr3_port.sv`), the EEPROM on hps_io slot 1 (`eeprom_save.sv`),
  RTC from hps_io TIMESTAMP, UART on the MiSTer UART pins, a LED-squares
  placeholder screen.
- **SCSI is written but untested**: `rtl/scsi/ncr53c710.sv` (registers in
  LASI's BE layout, SCRIPTS processor, DMA through the MIOC's new `dma_*`
  port, interrupt stacking, the diagnostic DMA FIFO) and
  `rtl/scsi/scsi_targets.sv` (disks at IDs 6/5, CD-ROM at 2, byte-level bus,
  sector buffer on hps_io block devices; never disconnects). Wired into
  `hp715.sv`, LASI page 6 (IRQ bit 9), `HP9K715.sv` (hps_io slots 0 disk ID
  6, 1 EEPROM, 2 disk ID 5, 3 CD) and the simulator (`--disk0/--disk1/--cd`
  in `verilator/romsim/tb_rom.cpp`, an hps_io-style block device). It lints,
  synthesises in Quartus and the ROM still boots with it in (check the last
  commit message for the run-rom result).

## The next steps, in order

1. **SCSI bring-up against the ROM.** Make a raw disk image from the HP-UX
   10.20 qcow2 (`tools/hpux/qcow2.py`; the image is in the old session's
   scratchpad `.../c636bb42-.../scratchpad/keep/qemu/hpux1020/hpux.img`,
   see its `keep/INDEX.md`; ask before copying multi-GB files around --
   disk space is ~50 GB free). Then in romsim: `--disk0 disk.img --type
   "search\r"` (typed after `BOOT_ADMIN>`), then `boot scsi.6`. The ROM's
   SCSI IODC (ENTRY_INIT f002c888, ENTRY_IO f002f168) first runs the chip
   self-checks of HW 4.5 (register R/W masks, DMA FIFO lanes, BBCK/ADCK,
   SODL->SBDL loopback, a SCRIPTS INT returning DSPS 0xBABAFACE) -- any
   failure returns -4. Then ISL loads (LIF at block 0, IPL checksum).
2. **The default EEPROM**: boot with `tools/eeprom/mkeeprom.py bootstrap`,
   type `manufactureoff`, set `path console rs232` (until Artist), dump
   with `+eeprom_out=`; script it (`tools/eeprom/`), document the release
   image (STUBS S-016).
3. **HP-UX 10.20 from the disk** (R06d's 53C710 requirements: SIGP vs WAIT
   RESELECT, live DFE, LCRC, stacked interrupts one cause at a time).
4. **Artist graphics** (system plan step 5; R06c, HW 6.3): VRAM in DDR3,
   the MiSTer framebuffer in palette mode, STI console.
5. Board bring-up of the MiSTer build -- **ask the user first** (anything on
   the real MiSTer). SDRAM phase (S-019) is the first risk.
6. Later: Harmony (P-003), 82596 (P-005), parallel (P-010), CD audio.

## How to work (tools learned this session)

- `make -C verilator romsim` -> `verilator/obj_dir_rom/Vemu`: `+eeprom=HEX`
  `--ram-lg 3` (8 MB is fastest; the ROM tests all RAM) `--turbo 15` (CR16
  15x faster after cycle 30M: the ROM's delays are CR16 loops; selftest1's
  timer test needs the real rate) `--stamp` `--until STR` `--type STR`
  `--type-after STR` `--leds --buserr --traps --trace N --trace-from C
  --sample N`, `--gsctrace` / `--l1trace` (+ `--flags-from C`), `--save-at C
  FILE` / `--restore FILE`. **Checkpoints only restore into the exact build
  that made them** (any RTL change invalidates them; trace switches are an
  input port, so they work after a restore).
- `tests/run-rom.sh` (the milestone ratchet), `tests/run-cputest.sh` (CPU
  gate; rerun after any `rtl/cpu` change), `make -C verilator tb_sdram64`.
- The GUI sim: `make -C verilator && verilator/obj_dir/Vemu` (loads the ROM
  through the ioctl path; serial console with an input box).
- Quartus 17 pitfalls met: no `$countones`, no `inside`, no `string`
  indexing; a byte-enabled true dual-port RAM must follow Quartus's template
  (packed byte array, plain `always`, explicit byte writes, `ramstyle =
  "M10K, no_rw_check"`). Check for a running flow with `ps -eo comm | grep
  -i quartus` (`pgrep -f quartus_...` matches itself).
- Verilator `--timing` benches: drive and sample on the falling edge
  (sampling right after the rising edge races the DUT's updates).

## Rules (from the user; also in CLAUDE.md and memory)

- The CPU stream owns `rtl/cpu/`; file needs in `cpu-requests.md`. Make a
  minimal CPU fix yourself only when the CPU stream is idle, say so in the
  row, and run `tests/run-cputest.sh` before committing it.
- Commit often (small, tested steps), explicit paths, never `git add -A`;
  end messages with the session's `Co-Authored-By` line.
- One Quartus flow at a time on this box; never kill another project's.
- Every stub in `docs/STUBS.md` in the same change.
- Never delete anything without asking (scratch included). This session's
  scratchpad `/tmp/claude-1000/-home-dani-repos-hp9000-715/ed82d3ff-.../scratchpad`
  holds ~300 MB of stale checkpoints (`ck_*.sav`) and logs -- ask the user
  before removing them. `rtl/mycore.v`, `cos.sv`, `lfsr.v`,
  `verilator/sim_lfsr.v` (the template demo) are no longer used, and
  `verilator/obj_dir_romt/` is a leftover multi-threaded build (slower than
  single-threaded) -- ask before deleting any of them.
- Ask before anything on the real MiSTer hardware or anything outward-facing.
