# Resume prompt -- the missing features: VGA timing, Harmony, CD audio, LAN (2026-10-10)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
This replaces `RESUME-20261009-artist-raster.md`. **Do not change `rtl/cpu/` unless
the user asks for it specifically** (CPU bugs -> `docs/design/cpu-requests.md`
with evidence). **One simulation at a time, none beside a Quartus fit; never
edit `files.qip`, the QSF or the SDC while a fit runs** (it crashed Quartus and
rewrote the QSF on 2026-10-09). Prefer the board when it can answer a question.
Ask before loading a core or typing into HP-UX while the user may be using it.

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/STUBS.md` S-024 (the display), S-025 (Harmony), S-026 (CD audio),
   S-027 (the 82596 LAN).
3. `docs/design/system.md` 10 (builds 26-31) and the LASI table (pages 4, 6, 7).
4. `docs/design/cpu-requests.md` #9 (PA 2.0 `bve (rp)` in HP-UX 11i's ISL).

## Where things stand

The user's list (2026-10-10): VGA timing (256 MB RAM dropped for now),
Harmony audio, the CD-ROM + CD boot, CD audio after Harmony, LAN (82596).

* **VGA timing** -- done (builds 26-28): Artist's raster at the programmed
  timing on its own reconfigurable pixel clock (`rtl/pll_video.v`, capped at
  108.181 MHz: every 1280x1024 record shown at record 5's 60 Hz),
  `MISTER_DISABLE_YC`, `MISTER_DOWNSCALE_NN`; every clock meets timing.
* **Harmony** -- done (`rtl/lasi/harmony.sv`): heard on the board at 32
  and 128 MB (build 32/33, 2026-10-10 afternoon). HP-UX's kernel has `audio`
  and `lan2` (`/stand/vmunix`; `/stand/vmunix.audio` = audio only,
  `/stand/vmunix.noaudio` = the image's original). Play a .au file with
  `/tmp/auplay FILE` (typed in the hpterm: sets rate/channels/format by
  ioctl); a raw `dd` to `/dev/audioEU` plays at 8 kHz and sounds slow/low.
  The morning's "HDMI silence" was never the MiSTer: 22 kHz files dd'd at
  8 kHz, and the stock Main (no CD track table). `Aserver` still needs DCE
  `rpcd`, which may run now that there is a network.
* **CD-ROM** -- works (HP-UX mounts cdfs, checksums right). Booting HP-UX
  11i's install CD stops in its ISL on `bve (rp)` = cpu-requests #9 -- **done
  2026-10-11 (build 36)**: the INSTALL kernel now boots and panics in
  `fdc_cmd_exec: FIFO problem`, the floppy stub (S-015/P-004; system.md 10,
  build 36) -- the next 11i step is a WD37C65 model that satisfies it. A blank 8 GiB `disks/hpux11i.img` is ready for the
  installer.
* **CD audio** -- works on the board with Main `hp9k715-enhancements`
  (`~/repos/Main_MiSTer`, `support/hp9k`, commits `16072b0`, `0103118`; not
  pushed): `/tmp/cdplay /dev/rdsk/c2t2d0 toc|play 2 3|status|sense|stop`
  (`tools/cd/hpux/cdplay.c`), -2 dBFS in OBS with the test disc
  `hp715audio.cue`.
* **LAN** -- `rtl/lasi/i82596.sv` + Main's `sun_enet` bridge (OSD Network,
  default eth0). On the board (build 33): HP-UX's `lan2` claims it as
  **lan1** (2/0/2, 08:00:09:71:5A:01), `ifconfig lan1 192.168.99.215 netmask
  255.255.255.0 up` (not yet in `/etc/rc.config.d/netconf`; the edited copy
  is the scratchpad's `netconf.new`), pings both ways, telnet works:
  **`tools/mister/hpux.py run 'cmd' ...`** (root/password), `type LOCAL
  REMOTE` (a text file through telnet), `put`/`get` (ftp). Fixed on the way:
  source address insertion (lan2 leaves it to the chip), the mailbox ring
  pointers zeroed at start-up (Main expects it), the RBD list read at RU start
  (lan2's RFDs have a ~200-byte data area; frames larger than that were lost
  until build 34). The ROM's LAN analysis: scratchpad `rom_lan.md`; HP-UX
  lan2's (subagent, may still be running): `hpux_lan2.md`.
* Builds: 31 did not route (the first 82596, 1,848 ALMs); 32 the compact
  82596 (1,113 ALMs, 87 %); 33 source insertion; 34 the RBD fix (fitting at
  the time of writing). All in the scratchpad's `keep/builds/`.

## Board

* MiSTer .92; core in `/media/fat/_Unstable/HP9K715.rbf`. **`/media/fat/MiSTer`
  is now the branch Main** (`0103118`, md5 33994ddf...; also kept as
  `MiSTer.hp9k715-0103118`); the user's previous one is
  `MiSTer.bak-20261010-hp9000715` (md5 1631b1f9...). Swapping Main: copy to a
  temp file, `mv -f` over it; the next `load_core` reboots the MiSTer (twice
  now), then load again. Ask the user before swapping back or pushing.
* The Ethernet mailbox can be read on the MiSTer through `/dev/mem` at
  0x1FF00000 (python mmap; magic HPETH001, then GEN, TXW, TXR, RXW, RXR, MAC).
* Mounts: s0 `hpux1020.img`, s1 `hp715_gfx2.eep`, s3 a CD (`hp715audio.cue`
  for audio tests). RAM 128 MB works.
* HP-UX is at CDE with an hpterm; its serial port is `/dev/tty2p0`: in the
  hpterm `exec 4</dev/tty2p0 5>/dev/tty2p0; stty 9600 cs8 -parenb clocal <&4`
  once, then `(...) >&5 2>&1` sends output to `board.sh console`'s log.

## Open (priority order)

1. LAN: load build 34, check large frames (`ping -s 1472`, ftp `put`),
   install `netconf.new`, default route 192.168.99.1; then rpcd/Aserver,
   NFS/ftp to and from the workstation (192.168.99.153).
2. Read `hpux_lan2.md` when the subagent reports; fix what lan2 needs.
3. cpu-requests #9 if the user approves; then the HP-UX 11i install.
4. Release: root README notes, `release/` (ask first), push Main's branch (ask).
5. Smaller: OSD soft power-off didn't shut HP-UX down; Artist leftovers
   (`RESUME-20261009-artist-raster.md` Open 2-5); the 780 MB MDF in the
   scratchpad's `cd/` (ask before deleting).

## How to work

* Gates: `make -C verilator tb_i82596 tb_harmony tb_cdaudio tb_ps2dev
  tb_artist`, `tests/run-rom.sh` (~10 min).
* Quartus: `setsid nohup quartus_sh --flow compile HP9K715 >
  scratch/buildNN.log` (~30 min); wait on the log's "Full Compilation was"
  line plus `pgrep -x quartus_sh` (never `pgrep -f` in a loop: it matches
  itself); save rbf/sta/log to the scratchpad's `keep/builds/`; record the
  build in `docs/design/system.md` 10.
* Main: `PATH=~/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin:$PATH
  make -j4` in `~/repos/Main_MiSTer`.
* Scratch: `/tmp/claude-1000/-home-dani-repos-hp9000-715/64c25f4d-10c7-4f12-b9c2-cba076464c05/scratchpad/`
  (`keep/builds/` 26-31, board/OBS captures, `cd/` the 11i CD work).
