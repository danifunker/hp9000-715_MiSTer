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
* **Harmony** -- done (`rtl/lasi/harmony.sv`, build 27): heard through OBS
  on HDMI with HP-UX's `audio` driver (the board's kernel was rebuilt with it;
  `/stand/vmunix.noaudio` is the old one). `Aserver` needs DCE `rpcd`, which
  needs a network -- the LAN may fix it.
* **CD-ROM** -- works (HP-UX mounts cdfs, checksums right). Booting HP-UX
  11i's install CD stops in its ISL on `bve (rp)` = cpu-requests #9, waiting
  for the user's go-ahead. A blank 8 GiB `disks/hpux11i.img` is ready for the
  installer.
* **CD audio** -- built (`rtl/scsi/cd_audio.sv`, build 30) with Main_MiSTer's
  windows (branch `hp9k715-enhancements` in `~/repos/Main_MiSTer`, folder
  `support/hp9k`, reusing `support/sun/sun_cdrom` and `sun_enet`; not pushed;
  the user asked for minimal comments and a per-machine folder). TOC and
  play status verified on the board with `tools/cd/hpux/cdplay.c`
  (`/tmp/cdplay` on the board's HP-UX). **Not heard yet**: since the MiSTer's
  first reboot on 2026-10-10 the OBS capture reads silence for every source
  (Harmony too); the user was asked whether the monitor has sound.
* **LAN** -- built (`rtl/lasi/i82596.sv`, `tb_i82596`, commit `9dc9d7d`; build
  31): frames go through the DDR3 mailbox at 0x1FF0_0000 that Main's
  `sun_enet.cpp` serves (magic HPETH001; Main commit `0103118` adds the hooks;
  OSD Network = eth0/Off/eth1/macvlan/tap0). The board's HP-UX has a kernel
  with `lan2` built and waiting in `/stand/build/vmunix_test`
  (`/stand/system.prelan` = the config before). Station address from the
  EEPROM: 08:00:09:71:5A:01. Plan: build 31 + the new Main on the board,
  install the kernel (`cp /stand/vmunix /stand/vmunix.audio`, then
  `cp /stand/build/vmunix_test /stand/vmunix`), reboot, `ioscan` for lan2,
  `ifconfig lan0 192.168.99.215 netmask 255.255.255.0 up` (.215 was free;
  this workstation is .153, gateway .1), ping both ways, then `netconf`.
  ROM and HP-UX lan2 analyses (subagents) in the session scratchpad
  `rom_lan.md` / `hpux_lan2.md`.

## Board

* MiSTer .92; core in `/media/fat/_Unstable/HP9K715.rbf`; Main binaries:
  `/media/fat/MiSTer` (stock, md5 1631b1f9...) and the branch build copied as
  `/media/fat/MiSTer.hp9k715-enhancements` -- swapping the running Main: copy
  to a temp file, `mv -f` over it, then load the core from the menu (a
  `load_core` right after the swap rebooted the MiSTer once).
* Mounts: s0 `hpux1020.img`, s1 `hp715_gfx2.eep`, s3 a CD (`hp715audio.cue`
  for audio tests). RAM 128 MB works.
* HP-UX is at CDE with an hpterm; its serial port is `/dev/tty2p0`: in the
  hpterm `exec 4</dev/tty2p0 5>/dev/tty2p0; stty 9600 cs8 -parenb clocal <&4`
  once, then `(...) >&5 2>&1` sends output to `board.sh console`'s log.

## Open (priority order)

1. LAN on the board (above); fix the model for whatever lan2 needs (the
   AL-LOC=0 layout is not supported -- check `hpux_lan2.md`).
2. HDMI audio confirmation (user's ears / OBS after a capture-card reset).
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
