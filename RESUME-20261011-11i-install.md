# Resume prompt -- HP-UX 11i's installer stalls on the board (2026-10-11)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`
as the **system stream** (everything outside `rtl/cpu/`). **Goal: install HP-UX
11i v1 from `hpux11i_oe_cd1.iso` onto the blank `hpux11i.img` (SCSI ID 5) on
the board, driven on the machine's own console (HDMI + PS/2 keyboard -- the
user's wish, not the serial console), boot it, and tell the user when it is
done: they want a copy of the image.** Today the installer runs, but stalls
at certain "Working..." steps that finish in seconds on QEMU. Find out why
and fix the core (or, if the cause is in `rtl/cpu/`, write it up in
`docs/design/cpu-requests.md` with the evidence -- no CPU changes, user rule).

## Read first

1. `CLAUDE.md` (rules: STUBS entry for every stub, never delete without asking,
   one Quartus flow / one simulation at a time, no `pkill -f`/`pgrep -f`
   patterns that match your own shell, commit often, Opus/Fable trailer).
2. `RESUME-20261011-floppy.md` "Status" (the floppy, builds 37-38: done).
3. `docs/design/system.md` 10, builds 37-39; `docs/STUBS.md` **S-027** (our
   82596: what it simplifies -- every multicast accepted, DUMP writes no dump
   area, NOP/MC setup/DIAGNOSE just complete, SCB counters never written).
4. `rtl/lasi/i82596.sv` (the LAN), `docs/review/10-hpux-fdc.md` (how the
   driver analysis was done for the floppy: same tools).

## What is on the board

Build 39 (`scratch/HP9K715-b39.rbf`, in `/media/fat/_Unstable/HP9K715.rbf`):
every clock meets timing; it adds **recorder event 15**: every HP-UX system
call (user-mode trap 7 at the gateway 0xC0000004 -- HP-UX takes all syscalls
through trap 7 at our CPU revision 2, review 07 1.3) with r22 = call number,
r26/r25 = first two arguments. `tools/mister/trace_dump.py dump --last N`
prints them as `sysc N r26 .. r25 ..`. 11i's syscall table:
`python3 tools/hpux/sysent.py roms/hpux11i/INSTALL` (from `sysent` at
0x9E2628 in the INSTALL kernel; 3 = read, 5 = open, 54 = ioctl, 93 = select,
269 = poll ...; `roms/hpux11i/INSTALL` comes from the CD with `hpdisk.py
disks/hpux11i_oe_cd1.iso lifget INSTALL roms/hpux11i/INSTALL`).

The user's slots are restored (`.s0` hpux1020.img, `.s1` hp715_gfx2.eep,
`.s3` hp715audio.cue, OSD Network eth0; backups `HP9K715.*.bak-*` in
`/media/fat/config`). **For installer runs: empty `.s0`** (write a NUL-padded
empty path) so the 10.20 disk cannot be overwritten, `.s3` =
`hpux11i_oe_cd1.iso`, `.s1` = `hp715_gfx2.eep` (HDMI) or `hp715_serial.eep`
(serial, greppable -- use it for diagnosis, HDMI for the real install).

## Tools (all committed)

* `tools/mister/inst11i_boot.sh`: reload the core, Escape through the PDC
  countdown, `boot scsi.2`, US English: ends at the installer's welcome screen
  on HDMI (graphics EEPROM).
* `tools/mister/hdmi_shot.sh OUT.png [scale]` (OBS, cropped to the core's
  picture), `hdmi_wait.sh BASE OUT [secs]` (wait for the screen to change).
* Serial: `LOG=... tools/mister/board.sh console 21600` in the background,
  `board.sh type`, `tools/mister/vt.py LOG` renders the last VT100 screen
  (curses redraws can still garble it).
* Keys on HDMI: `board.sh key` (`{f7}`, `\t`, `\r`, mnemonics: on the
  installer screens the underlined letter selects -- `i` Install, `o` OK,
  `n` Next, `a` Advanced Options / Advanced Installation; on screens with a
  text field use `\t` to Next, check with a screenshot).
* `tools/mister/dhcpsniff.py`, `macsniff.py MAC` (copy to the MiSTer's /tmp,
  run there: frames on eth0; the core's MAC is 08:00:09:71:5a:01).
* QEMU reference: `tools/qemu/q11i_b160l.sh` (`Q11I_DIR=<dir>`): the same CD on
  QEMU 11.1.1 `-M B160L` (binary in an earlier session's scratchpad, path in
  the script), serial console through `q11i_con.py` (`printf '2\\r' >
  $Q11I_DIR/in.fifo`). **Caveat: B160L's LAN is a PCI Tulip (HP-UX `btlan`),
  not LASI's 82596 -- QEMU never runs the lan2 driver.** QEMU `-M 715` (which
  has an 82596) prints nothing with the SIGP-experiment binary.

## The installer flow and the timings

welcome -> Install HP-UX -> "User Interface and Media Options" (Media only,
Guided) -> OK -> "Using client directory /var/opt/ignite/clients/0x080009715A01",
"Checking configuration for consistency", "Loading configuration user
interface" -> wizard: configuration -> environment ("HP-UX 11i Base OS-32bit",
the only one on CD 1) -> root disk (SEAGATE_ST32550N 2/0/1.5.0 8192 MB) ->
swap 256 -> LVM+VxFS -> 1 disk -> languages -> additional software ->
**pre-install checks** ("identify which disks will be overwritten") -> ...

| step | QEMU B160L | board, network on | board, OSD Network Off |
|---|---|---|---|
| configuration list, DHCP on (default) | ~45 s, even with no DHCP server | **hangs** (>15 min) | **hangs** |
| configuration list, DHCP off (Advanced Options, `n`) | -- | seconds | seconds |
| environment -> root disk | 5 s | **~12 min** | < 30 s |
| pre-install disk list | seconds | **hangs** (> 50 min) | **hangs** (> 25 min) |

Twice the machine **rebooted** (PDC autosearch, then the CD again) right
after the guided install started (once network on/DHCP on, once network
off/DHCP off); the cause was not captured -- on HDMI a panic message would
only flash. Not reproduced on the serial console so far.

## Evidence so far

1. **Configuration hang (DHCP on)**: no frame leaves the core (macsniff), and
   on QEMU no frame is sent either -- the wizard does not use the network at
   this point. Build 39's syscall events: **every syscall is `read(7,
   0x4029f960, ...)`, ~80,000 per sample, returning at once** (EOF), and
   nothing else runs (kernel lines: `ufs_rdwr`, `ilock_reader`,
   `iunlock_reader` -- the RAM disk is HFS). So `itool` (the UI,
   `/opt/ignite/bin/itool -m wiz`) polls fd 7 for output of a helper that is
   blocked or dead. The helper with DHCP on is probably
   `/sbin/net_cfg_prep` / `/usr/lbin/dhcpclient` (INSTALLFS; strings:
   "Searching the network for a DHCP server ... up to 30 seconds", `Running
   DHCP cmd: %s`, `DISABLE_DHCP=`); it never transmits. In the **recovery
   shell** ("Run a Recovery Shell", "startup networking? y") DHCP works end
   to end (DISCOVER, OFFER 192.168.99.151 from 192.168.99.1, REQUEST, ACK).
2. **Environment step slow with the network on**: the loop shows `lan2_isr`,
   `lan2_int_fr_rnr`, `lan2_process_packet` (the user's LAN is chatty: SSDP,
   DHCP of other hosts; our 82596 accepts every multicast, S-027),
   `lan2_ctl_req`, `lan2_hw_req`, `lan6_hw_req`, `wait_iocack`, `getmsg`,
   `putctl1`, `pse_open`, `token2_ext_clearmib`; with the network off it is
   fast.
3. **Pre-install hang (network on or off)**: the same driver-query loop
   (`lan2_ctl_req`, `lan2_hw_req`, `wait_iocack`, `getmsg`, `putctl1`,
   `internal_pdc_call`/`read_ss_nvm` also seen), **no LAN DMA at all** -- the
   queries never reach the chip; ~14,000 syscalls per sample.
4. lan2 facts (INSTALL kernel `roms/hpux11i/INSTALL`, symbols): `lan2_hw_req`
   refuses transmit requests (type 9) unless the driver state at softc+0x1DC
   == 6; `lan2_do_selftest*` (PORT self-test: waits for result != -1, checks
   result bits 0x340000, sets state 10 meanwhile) accepts our model's
   result 0; `lan2_cmd_dump` / `lan2_port_dump` exist (our DUMP writes
   nothing; the driver does not look for 0xA006); `lan2_get_stats` reads the
   SCB counters from memory. `uname -i` (Show System Info) is 4294967295.

## Next steps (suggested order)

1. **See the syscalls leading into each hang.** The ring holds ~0.2 s at full
   event rate, so the start of a stall is always overwritten. Add a recorder
   filter (a hidden OSD bit in `HP9K715.sv`'s CONF_STR -> `hp715` `dbg_ctl`
   or a new input) that keeps only event 15 (syscalls), interruptions other
   than 4/6/7/15, LAN/SCSI interrupts and the 82596's CB starts (add an event
   in `rtl/lasi/i82596.sv`: CB address + command). Then the ring covers
   minutes: you get the `open`/`pipe`/`fork`/`execve`/`ioctl` sequence (ioctl
   request codes in r25 decode the DLPI/LAN query) and which process stops.
   Also consider recording r24 (3rd argument) and the process id.
2. With that, decide between: (a) an 82596 behaviour the 11i lan2 driver
   relies on (state stuck != 6? a command it waits for? RNR handling under
   load?), (b) something else the helper waits on (a pipe whose writer died --
   look for an `exit`/signal; a timer that never fires -- `select`/`alarm`
   timeouts), (c) a CPU issue (then cpu-requests.md).
3. Check whether the helper dies: a user process killed by a signal shows as
   a trap (15/18/... at PL 3) before `exit`; the recorder freezes only on
   traps 8/10/11.
4. Once the stalls are understood or worked around (DHCP off avoids the
   first; network Off makes the environment step fast), run the install on
   HDMI to completion, boot `scsi.5`, and report to the user. Record builds
   and findings in `docs/design/system.md` 10 and STUBS (S-027) as usual.

## Board notes

* MiSTer at 192.168.99.92 (ssh root, key). `board.sh push/load/menu`. OBS at
  192.168.99.82:4455 shows HDMI. One Quartus flow at a time (`pgrep -a
  quartus`), ~28 min a build, seed 3 in the QSF (build 37 with seed 2 missed
  64 MHz by 0.18 ns on CPU paths).
* The PDC with the graphics EEPROM autoboots in ~30 s; `inst11i_boot.sh`
  sends Escape every second from 8 to 50 s (a leftover Escape can prefix the
  next line -- it presses Return first).
* With the core's network on, HP-UX 10.20 boots to CDE and `lanscan` /
  `lanadmin` statistics answer at once (its own, older lan2).
