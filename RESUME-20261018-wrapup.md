# Resume prompt: after the wrap-up release (2026-10-18)

You are picking up the HP9K715 core (HP 9000 Model 715/64 for MiSTer). Read
`CLAUDE.md` first: its rules apply (no `rtl/cpu/` changes unless the user asks,
every stub in `docs/STUBS.md`, never delete without asking, commit only when
asked, one Quartus flow and one romsim at a time).

**The build box is shared.** It has 14 GB of RAM, and other cores build on it.
A full HP9K715 fit takes about 4 GB. Before any fit, message the DSPPC603 /
Apple Pippin session and wait for its answer; it holds its own builds while a
fit runs. Never run Verilator builds or agents next to a fit, and at most two
build agents at once: on 2026-10-18 the machine ran out of memory and crashed.

## What was released

**Build 65** (2026-10-18, `release/HP9K715_20261018.rbf`), with notes in the
root README:
- the OSD laid out to `docs/osd-standard.md`;
- the area trims from `docs/design/area-plan.md` (A5, A6, A9, A10, A11);
- the fetch timing cut (`6453380`, `docs/design/cpu-timing.md`).

Every clock meets timing, and it uses 35,527 ALMs (85 %). Also in `release/`:
- `boot0.rom`: HP's PDC 1.6. The user chose to keep it in the public repo.
- `hp715.eep`: the same image as the core's built-in EEPROM.
- `MiSTer`: Main_MiSTer `hp9k-family` at `6d7ece1`, rebased onto upstream
  `88d2d10`. It has run on the board with build 65 (HP-UX 11.11, LAN, UTC
  clock) and with HP9K385. The user's Main PR has been approved; once it is
  upstream, the custom binary and the README's "needs the custom Main"
  paragraph can go.

Board check of build 65 on .92 (a SuperStation One), started from the MiSTer
menu:
- the new OSD, "Changes pending" holding a setting until reset;
- HP-UX 11.11 from "Pri. disk (ID 6)" to CDE;
- a 15-minute desktop session: terminal, editor, menus, dialogs,
  workspaces, help.

The 11.11 image (`hpux1111.img`, hostname `hp715mi`, moved to ID 6 by
`disks/README.md`'s recipe) is zipped on .92's card as
`games/HP9K715/hpux1111_hp715mi_id6_20261018.zip` (1.11 GB, md5
`4e12271e1426eeed86d458f1d5140d09`, with the matching `.eep`).

## Open, roughly in order

1. **OSD "Boot mode" is not reliable** (STUBS S-029), and the ROM shows why
   (ROM analysis 2026-10-18; addresses are `roms/disasm` `rom.dis` lines,
   docs `BOOTFLOW.md` 296-413, `FIRMWARE.md` 449-545):

   **Why the current approach fails:**
   - **PDC 1.6 has no countdown.** "Press <ESCAPE> to stop boot sequence"
     is just a banner line. ESC is checked by single non-blocking polls
     (`console_key_is` f0000a6c), once in `boot_select` (f0000e98) and at
     the start of each `try_boot_device` (f0001208). Any other key read
     there is thrown away.
   - `rtl/boot_seq.sv` waits for "32 idle polls" at LED 0x43, but the ROM
     polls only once at 0x43 before autobooting. The prompt detector
     cannot fire, which explains both board failures (inferred: build 49's
     romsim test passed, so reconcile that first).
   - The waits that do last forever are BOOT_ADMIN's `read_cmd_line`, the
     failure waits (`boot_failed_wait_esc` f0001738), and ISL's `ISL>`.

   **The deterministic fix: make the ROM stop at BOOT_ADMIN.**
   - `boot_select` reads AUTOBOOT and AUTOSEARCH from stable-storage byte
     0, bits 7 and 6. That is EE 0x1000 (copy A) and EE 0x1100 (copy B),
     read through PDC_STABLE at f0000dd8, flags extracted at f0000e38/e3c.
   - With both flags 0 it calls `interactive_boot` and waits at
     `BOOT_ADMIN>`.
   - **Every stable-storage read is checksummed** (`ss_check_copy`
     f0012cd0): the 64 words + 0x357 + the checksum word must sum to 0.
     The checksum word is the first word of the active {checksum, count}
     record at EE 0x1300+8k (copy A) and 0x1350+8k (copy B), k = 0..9.
     If both copies are bad the ROM stops at chassis 0x23001.
   - So, while a Boot mode is selected, the EEPROM read path
     (`rtl/hp_xbus.sv`) returns `EE[0x1000] & ~0xC0` and adds the cleared
     bits back into the top byte of each checksum word (0x1300+8k), and the
     same for 0x1100 / 0x1350+8k. Words are big-endian and no carry crosses
     bit 31.
   - **Stop masking at the first EEPROM write** (the ROM would otherwise
     store a checksum computed from the masked bytes), and once the LED
     leaves 0x43.
   - The sequencer then types at prompts that wait: `boot pri isl` (or
     `boot lan`, `boot scsi.2`) at `BOOT_ADMIN>`, then `hpux -is` or
     `hpux -lm` at `ISL>` (LED 0x0C).

   **Other levers:**
   - **The ISL "interact" flag is GR26**, from page 0 byte 0x602 (stored
     1 by `interactive_boot`, 0 by autoboot at f0000e94, loaded at
     f0001ac0). With 1, ISL stops at `ISL>` instead of running its AUTO
     file. A store intercept is hard: the store is cached.
   - **The disk's AUTO file holds `hpux\n`.** Serving `hpux -is` for that
     block on SCSI reads would boot single-user without any keys
     (inferred).
   - **Manufacturing mode** (EE 0x1694 = 0xB1) also goes straight to
     BOOT_ADMIN, with no checksum, but it forces the RS-232 console and
     prints chassis codes.
   - There is no hardware strap or override pin.

   **LED codes** (latch F00EFFFF = ~code[19:12]): 0x43 `boot_select` and
   BOOT_ADMIN; 0x6C autoboot, autosearch and launch (indistinguishable);
   0x0C ISL, both its autoboot and `ISL>`; 0x23 stable-storage failure.
2. **Installs are I/O-bound** (the SCSI target and hps_io path): TCOE fileset
   353 of 977 at 2 h 02 m. The measurements to make are in
   `RESUME-20261015-dual-issue.md`.
3. **NeXTSTEP 3.3 does not run properly.** The user asked about it on
   2026-10-16; that session committed nothing. Start from scratch.
4. Linux, NetBSD and OpenBSD have not been tried.
5. The CPU speed plan (stall-on-use, one-cycle E redirects, dual issue) is in
   `RESUME-20261015-dual-issue.md`; its step 1 (timing) was done in build 65.
   CPU work needs the user's go-ahead. `docs/design/cpu-requests.md` has no
   open requests.
6. Not built (README "Hardware", STUBS): RAM above 128 MB in DDR3, a floppy
   drive, audio input.
7. The rest of the area plan (B1-B8, the CPU TLB payload in MLAB) is in
   `docs/design/area-plan.md`, if room is needed again.

## Notes

- **MiSTer.ini on .92:** `[MiSTer] main=` names
  `ConsoleMode/MiSTer_ConsoleMode`, which is not on the card. After a core
  with its own Main (`[Pippin] main=MiSTer_pippin`), the next core keeps
  running on that Main until the MiSTer reboots.
- **Main_MiSTer `hp9k-family`** is one commit, `6d7ece1`, shared with the
  HP9K385 core: coordinate any change with that work.
- **Driving the board:** `misterkvms-cli` for screenshots and keys. HP-UX's
  mouse is accelerated, so move it in steps of 4 units or less. The OSD's
  Soft power off makes HP-UX halt and the machine restart, so stop the core
  (load the menu) if the disk must stay untouched.
