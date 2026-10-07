# Resume prompt -- the rest of the HP 9000/715 machine

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
Your job is **everything around the CPU**: the memory and I/O system, the
devices, graphics, storage, input, sound and the MiSTer integration --
first to boot HP's own boot ROM (PDC 1.6) to its `BOOT_ADMIN>` prompt in
Verilator, then HP-UX 10.20 from a SCSI disk image, then on the DE10-Nano.

## Read first

1. `CLAUDE.md` -- project state, decisions, layout, tools, rules (binding).
2. `docs/reference/rom/README.md`, then `BOOTFLOW.md` (reset and boot flow,
   chassis codes, **section 7: what makes the ROM fail early**),
   `HARDWARE.md` (every register the ROM touches; the reconstructed MIOC in
   section 1; **section 7: addresses that must bus-error; section 10: the
   read-back checklist**), `FIRMWARE.md` (PDC, IODC, STI, the EEPROM layout).
3. `docs/review/06-os-hpux-linux.md` and its sub-reports `06a` (Harmony),
   `06b` (PS/2, RS-232, parallel), `06c` (graphics/STI/Artist), `06d` (the
   53C710 / HP-UX c720 driver) -- each ends with "the FPGA must / may".
4. `docs/STUBS.md` -- planned stubs P-001..P-010 are yours (WAX, EISA,
   Harmony, floppy, 82596, ECC, memory blocks, UART clock, parallel DMA);
   the rule is: every stub goes there in the same change.
5. `docs/design/cpu.md` section 6.8 -- the CPU's ports (your interface) --
   and sections 3.4 (HPMC/TOC/bus errors) and 5.2/5.3 (CR16, EIR, TOC).
6. `docs/review/01-system-docs.md` (the machine: SIMMs, graphics modes,
   LEDs, boot console) and `03-qemu-seabios.md` (QEMU's 715 model -- a
   reference that is wrong in several places, see CLAUDE.md).
7. `docs/review/07-hpux-cpu-specifics.md` sections 0, 1.4 and 1.6 -- mostly
   CPU matters, but two touch your side: HP-UX and Linux poll the
   **soft-power button** (DR25 bit 0) and shut down cleanly when it reads 0,
   so give the OSD a "soft power off" item once the CPU has the input
   (`cpu-requests.md` #1); and the **CPU revision** question (0 or 0xC) is
   waiting on the user -- if they choose option B, the ROM loader patches
   one word (file offset 0xB810: 0x86802012 -> 0xE8000012) as it copies
   `boot.rom` into DDR3, and that patch gets a STUBS entry.

## Where things stand (2026-10-07)

- The **CPU** exists as `rtl/cpu/pa_core_seq.sv`, a sequential bring-up core
  that passes every integer test ROM (`tests/run-cputest.sh`). It speaks
  only the **uncached port** of cpu.md 6.8 (`io_req/io_we/io_addr/io_be/
  io_wdata/io_ifetch/io_rclr/io_ack/io_rdata/io_err`) plus `eir_set/eir_num`,
  `toc_req` and debug taps. It has **no caches, no TLB, no FPU** yet
  (STUBS S-005); a parallel CPU work stream is building the pipelined core
  with those (`RESUME-20261007-cpu-64mhz.md`).
- `verilator/cputest/cputest_top.sv` is a minimal system (ROM, RAM, UART)
  for the CPU tests -- a useful pattern, not the machine.
- The MiSTer side is the template: `HP9K715.sv` runs the template demo core
  (STUBS S-001); `verilator/` has the ImGui GUI simulator shell (`sim.v`
  already has the machine's port list: video, audio, PS/2, ioctl ROM
  download, a serial-console tap, CPU debug taps).
- HP's ROM: `roms/hp715_pdc_rev1.6.bin` (not committed; `roms/README.md`
  has the recipe and hashes). `tools/rom/` annotates it
  (`python3 tools/rom/annotate.py`, `firmware_map.py check`).

## Decisions already made (user)

- Target: 715/64 "Mirage Jr"; the board-ID word at **0xF00FFFFC** (bits 7:4:
  7 = 715/64, B = /80, F = /100) selects the model -- make it an OSD option.
- **Memory placement** (user's standing preference): **SDRAM = system RAM**
  (32/64/128 MB = the module fitted; reuse `../MacQuadra800_MiSTer/rtl/sdram.sv`,
  the 128 MB open-page controller), **DDR3** (core window 0x30000000-0x3FFFFFFF)
  = video RAM and the boot ROM image (loaded by hps_io ioctl from
  `games/HP9K715/boot.rom`, as the SGI Indy core does -- see
  `../SGIIndy_MiSTer/rtl/mister/ddr3_mux.sv` and
  `docs/reference/mister-integration.md` there), optionally RAM above
  128 MB to reach the 715's 256 MB; **BRAM** = caches (the CPU's), line
  buffers, FIFOs. Core name **HP9K715** (OSD, rbf, `games/HP9K715/`).
- The 8 KB **EEPROM** at 0xF00C0000 (stable storage, MAC, model identity)
  is saved to the SD card and shipped **pre-initialised** -- a blank one
  boots the ROM into manufacturing mode (FIRMWARE.md section 5).
- WAX gets only a stub that accepts the ROM's reset-time writes (P-001);
  EISA absent (P-002).

## The task, in order

1. **System design note** `docs/design/system.md`: the address decoder for
   the whole F-space (ROM 0xF0000000, LASI 0xF0100000 and its units, WAX
   0xF0200000, EEPROM 0xF00C0000, LED latch 0xF00EFFFF, board ID 0xF00FFFFC,
   Artist 0xF8000000 / framebuffer 0xF9000000, EISA, CPU HPA 0xFFFBE000,
   MIOC 0xFFFBF000, broadcast 0xFFFC0000), what bus-errors (HARDWARE.md 7),
   clocks and crossings (CPU 50-64 MHz, SDRAM ~100 MHz, the DDR3 bridge,
   video), interrupt routing (LASI IAR -> CPU EIR; LASI IAR default
   0xFFFBE003), reset and broadcast reset (store 5 to 0xFFFC0030), TOC.
2. **Machine top** `rtl/hp715.sv` with `pa_core_seq` on the uncached port,
   the MIOC block (registers per HARDWARE.md 1; ECC model per
   `tools/rom/hwmap_ecc.py`, STUBS P-006/P-007; HPMC status 0x02 for
   unconfigured memory), system RAM, the ROM image, LASI core
   (IRR/IMR/IPR/ICR/IAR, PCR, IORESET, VER, AMR), the 16550 UART with FIFOs
   (IIR reads 0xC1 after FCR=1; TEMT when idle -- 06b), PS/2 with the
   4-deep loopback that raises EIRR bit 3 (else the ROM halts silently),
   the RTC, the EEPROM, LED latch, board ID, WAX stub. Wire it into
   `verilator/sim.v` so the GUI sim runs the real ROM (serial console
   window), and add a headless ROM test `tests/run-rom.sh` (pattern: the
   Indy's `tests/run-prom.sh`) that asserts milestones on the serial log and
   chassis codes.
3. **Run the ROM and walk it forward.** Expect it to stop where it needs
   CPU features: the memory test runs code planted in the I-cache through
   diagnose writes; selftest2 needs the TLB; PDC_TLB programs the walker.
   File each need in **`docs/design/cpu-requests.md`** (what, why, doc ref)
   rather than editing `rtl/cpu/` -- the CPU work stream owns it. If the
   CPU stream is not active (no recent `rtl/cpu` commits; ask the user),
   you may make the minimal `pa_core_seq` change needed, say so in the
   request row and in STUBS. Fastboot (EEPROM byte 0x1694 area, BOOTFLOW
   section 2/4) skips many tests -- use it to get further while the CPU
   catches up, and record that as a stub.
4. **MiSTer integration**: `HP9K715.sv` (hps_io, CONF_STR: model, RAM size,
   disk/CD mounts, boot.rom, EEPROM save), SDRAM, DDR3 arbitration (ROM,
   framebuffer), clocks, a Quartus build of the whole core (the CPU stream
   also runs Quartus: one flow at a time).
5. **Artist graphics** (06c, HARDWARE.md 6, QEMU `hw/display/artist.c` and
   the register list in `docs/reference/pdf/artist_graphics_registers.html`):
   the drawing engine the STI code and HP-UX's X server use, MISC_VIDEO as
   plain storage, busy bits that clear promptly, no interrupt; framebuffer
   in DDR3 with 8-bit indexed colour (the MiSTer framebuffer has a palette
   mode) and the hardware cursor; 1280x1024 is the mode HP-UX expects.
6. **SCSI**: the NCR 53C710 with its SCRIPTS processor (data manual in
   `docs/reference/pdf/bitsavers/`, 06d for what HP-UX's c720 driver does
   and where QEMU's model fails), disk targets and a CD-ROM at ID 2 served
   from the SD card (bring in a generic `sim_blkdevice` for the sim, STUBS
   S-002), **CD audio** (reuse `../MacQuadra800_MiSTer/rtl/cd_audio.sv`).
7. Then Harmony (P-003 minimal first), the 82596 (P-005), parallel (P-010).
8. Boot HP-UX 10.20: the QEMU image (`hpux1020-apps-qemu.tar.lz` on the NAS,
   `smb://daninas.local/software/HP9000`; qcow2 -> raw with `tools/hpux/`).

## Gates

- `tests/run-cputest.sh` stays green (it does not depend on your files, but
  do not break shared ones).
- Each device lands with a unit bench (`verilator/tb/`, the CPU units' pattern)
  or a ROM milestone in `tests/run-rom.sh`.

## Rules for this session (from the user; also in CLAUDE.md and memory)

- **The CPU work stream owns `rtl/cpu/`**; you own the rest of `rtl/`,
  `HP9K715.sv`, `verilator/sim*`, the system docs and tests. Both streams
  share this checkout (no git worktrees -- the user finds them confusing).
- Commit with explicit paths, never `git add -A`; small targeted edits to
  shared files (`CLAUDE.md`, `docs/STUBS.md`, `verilator/Makefile`,
  `files.qip`), re-read just before editing. CLAUDE.md says commit only
  when the user asks; for this work the user said "commit it and keep
  going" (2026-10-07), so commit finished, tested steps -- unless the user
  tells you otherwise in your session. End commit messages with the
  session's `Co-Authored-By` line.
- **One Quartus flow on this box at a time**: `pgrep -a quartus` first; never
  kill a flow that is not yours. Quartus 17.0.2: `~/intelFPGA_lite/17.0/quartus/bin`.
- Every stub goes in `docs/STUBS.md` in the same change.
- **Never delete anything without asking** (scratch included); reusable
  scratch in the session scratchpad's `keep/` with an `INDEX.md`; clean
  temporary output when done (disk space is limited).
- Do not edit `sys/`. Ask before anything on the real MiSTer hardware or
  anything outward-facing (downloads beyond the documented sources, posts).

## Useful facts

- QEMU 11.1.1 `-M 715` models the same address map but is wrong in places
  (CLAUDE.md: 53C710 SIGP/DFE, Artist MISC_VIDEO, 82596 PORT, PS/2 loopback
  depth, CPU details). A built hppa QEMU may still be in the previous
  session's scratchpad
  `/tmp/claude-1000/-home-dani-repos-hp9000-715/c636bb42-9bcf-47e9-83f8-8ade60a40f61/scratchpad/keep/`
  (with the unpacked HP-UX 10.20 image and analysis helpers, see its
  `INDEX.md`); if gone, rebuild from `~/src/qemu-11.1.1`
  (`configure --target-list=hppa-softmmu`, ~4 min).
- Sibling cores to borrow from: `../MacQuadra800_MiSTer` (SDRAM, SCSI
  targets, CD audio, Ethernet via the Main fork), `../SGIIndy_MiSTer` (DDR3
  mux, framebuffer line cache, MiSTer integration notes, ROM in DDR3,
  NVRAM save), `../Sun-2_MiSTer`.
- HP-UX extraction tools: `tools/hpux/` (qcow2, LIF/LVM/HFS, SOM);
  extracted files in `roms/hpux/` (not committed).
