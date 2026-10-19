# Resume prompt: after the wrap-up release (2026-10-18)

You are picking up the HP9K715 core (HP 9000 Model 715/64 for MiSTer). Read
`CLAUDE.md` first: its rules apply (no `rtl/cpu/` changes unless the user asks,
every stub in `docs/STUBS.md`, never delete without asking, commit only when
asked, one Quartus flow and one romsim at a time).

**Quartus is shared.** Other cores build on this box, and on 2026-10-18 the
user gave the DSPPC603 / Apple Pippin session priority. Before any fit, check
`pgrep -a quartus` and coordinate with that session. Queue behind its builds,
and never start a flow next to another one.

## What was released

On 2026-10-18 the core was wrapped up with **build 65** as the release
(the OSD standard, area trims, the fetch timing cut; every clock met; it
replaced build 57): `release/HP9K715_20261018.rbf`,
`boot0.rom` (HP's PDC 1.6; the user chose to keep it in the public repo),
`hp715.eep` and `MiSTer` (Main_MiSTer `hp9k-family` at `6d7ece1`, rebased onto upstream
`88d2d10`, built 2026-10-18; not yet run on a board). The release notes and known limitations are in the root README.
No new fit was made for the release.

## Open, roughly in order

1. **The second board (.143, hostname `MiSTerpi`, taken to be a MiSTer Pi):
   the core "wasn't working" there, and HP-UX 11.11 hung once (the user
   thinks it was on .143, around 2026-10-17).** Nothing about it was recorded
   on this box: no symptom, build, LED code or log. Every board tuning was
   done on .92 (`MiSTerss1`, a SuperStation One). When a board is free:
   - Get the symptom first: a black screen, a stop during the ROM's
     self-tests (chassis/LED code), or a stop in HP-UX.
   - On 2026-10-14 .143 had `hp715-11.11v1.img` in **slot 0 (SCSI ID 6)**.
     That 11.11 was installed at **ID 5**, so its LVM boot record names
     2/0/1.5.0. Mount it in the ID 5 slot, or run
     `tools/hpux/lvmbdra.py setpath IMG 2/0/1.6.0` (`disks/README.md`).
     The user hit "failing the LVM stuff" on that board on 10-14.
   - SDRAM: OSD "SDRAM read capture" (`status[9:8]`, `sdram64` `rd_mode`;
     build 57 has it, it leaves the OSD with the next build and is tied to Edge 3).
     On .92, Edge 3 and Edge 2.75 pass and Edge 2.5 and Edge 4 fail
     (STUBS S-019). Try Edge 2.75 on .143, and run the ROM's memory test
     with fastboot off (EEPROM) to see whether reads are right.
   - Timing: build 57 misses by 0.009 ns (slow 100 C corner). **Fix
     forward** (user, 2026-10-18): never go back to an earlier build to test
     or bisect; close the timing on the current RTL instead (item 2).
   - A hang in 11.11: before calling it a hang, check whether the mouse
     wakes X's screen saver (Artist goes black), whether the machine
     answers ping or telnet, and what the serial console shows.
2. **OSD Boot mode failed on the board with build 65** (2026-10-18; STUBS
   S-029): graphics console, valid primary path, Single-user applied, the
   ROM autobooted anyway. Trace it in romsim with the graphics-console
   EEPROM (as build 49 did); suspect the A6 ps2_dev rework first.
3. **Done in build 65** (the fetch cut, every clock met). Was: close build 57's last 0.009 ns (CPU stream, needs the user's
   go-ahead): `RESUME-20261015-dual-issue.md` step 1, `docs/design/cpu-timing.md`.
   Seeds 1-3 of the same RTL gave -0.357 / -0.357 / worse.
3. **Installs are I/O-bound** (the SCSI target / hps_io path; TCOE fileset
   353 of 977 at 2 h 02 m): the measurements are listed in
   `RESUME-20261015-dual-issue.md`.
4. **NeXTSTEP 3.3 does not run properly.** The user asked about it on
   2026-10-16; that session committed nothing. Start from scratch.
5. Linux, NetBSD and OpenBSD have not been tried.
6. `docs/design/cpu-requests.md`: items #3-#8 under "Open" are fixes the
   system stream made and that await the CPU stream's review. #9 and #10 are
   done; #10 is also in "Done", and #9 should move there.
7. The rest of the CPU plan (stall-on-use, one-cycle E redirects, dual issue)
   is in `RESUME-20261015-dual-issue.md`. RAM above 128 MB in DDR3, a floppy
   drive and audio input are not built (README "Hardware", STUBS).
8. Main_MiSTer `hp9k-family` is one commit, `6d7ece1` "HP 9000 family:
   HP9K715 and HP9K385 support (support/hp9k)", rebased onto upstream master
   `88d2d10` on 2026-10-18 and pushed; `release/MiSTer` is built from it (run
   on .92 with build 65: HP-UX 11.11 from ID 6 to CDE, LAN, UTC clock; and
   with HP9K385 on .143). Note: .92's MiSTer.ini `[MiSTer] main=` names a
   missing file, so a per-core Main (e.g. `[Pippin] main=MiSTer_pippin`)
   stays running for the next core until the MiSTer reboots. The HP9K385 core shares it, so coordinate changes.
