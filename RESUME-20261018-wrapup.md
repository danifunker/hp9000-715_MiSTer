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

1. **OSD "Boot mode" is not reliable** (STUBS S-029). `rtl/boot_seq.sv` waits
   for the ROM to poll the console during its "Press ESC" countdown, then
   types ESC and the boot commands. Two ways this fails:
   - With no bootable disk on the primary path, the ROM goes straight to
     auto-search with no countdown, and the sequencer never gets its window.
   - On build 65 it missed even with the countdown present: graphics
     console, valid primary path, Single-user selected, and the ROM
     autobooted. Not traced.

   **Replace the timing race with something deterministic.** For example,
   have the core clear the AUTOBOOT/AUTOSEARCH flags the ROM reads from the
   EEPROM while a Boot mode is selected, so the ROM stops at `BOOT_ADMIN>`
   and waits. That prompt and `ISL>` both wait for input indefinitely, so
   typing at them is safe. Check the stable-storage layout, any checksum,
   and the ROM's reads in `docs/reference/rom/` first. Also check the A6
   `ps2_dev` rework, through which the sequencer's keys go.
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
