# HP 9000 Model 715 for MiSTer

An FPGA recreation of the **HP 9000 Model 715/64** PA-RISC workstation for the
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform: a
PA-7100LC CPU, the LASI I/O chip (SCSI, Ethernet, serial, parallel, PS/2,
audio) and the built-in 8-plane Artist graphics, with the aim of running
HP's own boot ROM and HP-UX.

**Status (build 53, 2026-10-14, alpha):** HP's boot ROM passes its self-tests, boots
from SCSI, and **HP-UX 10.20 boots to the CDE desktop on the MiSTer** with the
built-in Artist graphics at 1280x1024: the boot console, the X login and CDE
(windows, menus, proportional and terminal fonts, xclock, oclock, private
colour maps), PS/2 keyboard and mouse with the hardware cursor (tried at 32 and
64 MB). The RS-232 console is still there (on the MiSTer's screen when the OSD
"Display" says so). Design notes are in [`docs/design/`](docs/design/), the
build log in [`docs/design/system.md`](docs/design/system.md) section 10.

**Build 53 (2026-10-14)** over build 25: Artist at the monitor's own timing,
Harmony audio and CD audio, the 82596 LAN (HP-UX's `lan`), the LASI floppy
controller (no drive), BLR/BV reserved bits, and the CPU fix for HP-UX 11i's
installer stalls (a redirect into a nullified branch fetched its target twice,
`docs/design/cpu-requests.md` #10): **HP-UX 11i v1's install media boots and
its installer runs.** OSD: "Boot mode (on reset)" (BOOT_ADMIN, ISL,
single-user, LVM maintenance, LAN, CD), "EEPROM (no image)" Built-in / Blank,
graphics console by default, RAM default 32 MB.

## Running it on a MiSTer

The files in [`release/`](release/):

| file | goes to | what |
|---|---|---|
| `HP9K715.rbf` | `/media/fat/_Unstable/` (or `_Computer/`) | the core, Quartus build 53 (2026-10-14; `HP9K715_20261014.rbf` is the same file, `HP9K715_20261011.rbf` build 36): 64 MHz |
| `boot0.rom` | `/media/fat/games/HP9K715/` | HP's PDC 1.6 boot ROM for the 715/64, 258,728 bytes ([`roms/README.md`](roms/README.md): HP firmware patch PF_C7X50016, image IMAGE1A's payload). Loaded by the framework at core start; the loader patches one word ([`docs/STUBS.md`](docs/STUBS.md) S-011) |
| `hp715.eep` | `/media/fat/games/HP9K715/` | the EEPROM image (8 KB, `tools/eeprom/mkrelease.sh`): manufacturing and chassis codes off, **console on the graphics** (monitor type 1, 1280x1024), PS/2 keyboard, primary path scsi.6, autoboot and autosearch on. **The same image is built into the core**, so nothing needs mounting to boot; mount it in the OSD's "Mount EEPROM" slot only to keep the firmware's changes (boot paths, monitor type, `lanaddress`): it is written back, and mounting it resets the machine so the ROM reads it. For the RS-232 console instead: `CONSOLE=rs232 tools/eeprom/mkrelease.sh`, or `path console rs232` at `BOOT_ADMIN>` |

Also needed: a disk image in `/media/fat/games/HP9K715/`, mounted in the OSD's
disk slot (slot 0, SCSI ID 6). RAM: 32 MB by default (HP-UX 10.20 with CDE
runs in it); 64 MB is recommended for HP-UX 10.20, 128 MB for HP-UX 11i.

**The OSD** (F12; the Right key jumps to the System page, Enter cycles a
value; "Save settings" on the System page keeps the choices):

| option | values | notes |
|---|---|---|
| Boot mode (on reset) | **Normal**, BOOT_ADMIN, ISL, Single-user, LVM maintenance, Network, CD/DVD | what the core does after every reset until it is changed back: Normal lets the ROM autoboot; the others stop the autoboot (ESC) and, from `BOOT_ADMIN>`, type `boot pri isl` (then `hpux -is` / `hpux -lm` at `ISL>`), `boot lan` or `boot scsi.2` for you. It works on the graphics console and on RS-232 |
| Model, RAM | 715/64; **32MB**, 64MB, 128MB, 16MB | on reset; the RAM is clipped to the SDRAM module |
| Display | **Graphics**, Auto, Serial console | Graphics shows Artist's picture always; Auto shows the RS-232 console until Artist's video first comes on; Serial console shows the RS-232 console |
| EEPROM (no image) | **Built-in**, Blank | with no image mounted: the shipped image, or a blank part (the ROM's manufacturing mode: console on RS-232, `BOOT_ADMIN>` at once) |
| Network | eth0, Off, eth1, macvlan, tap0 | the 82596's bridge (needs the custom Main) |

Saved configs from before 2026-10-14 (build 49) read differently: the RAM
and Display values moved so the defaults come first (the old 16 MB is now
32 MB, the old Auto is now Graphics).

**Display.** Artist draws 1280x1024 (the PDC can switch to 1024x768 and other
modes), and the core sends that picture to the MiSTer's scaler itself. The
HDMI output mode is the MiSTer's own setting and a core cannot change it:
with a 1280x720 mode the 1024 lines are squeezed into 720 and small text
becomes unreadable, so give the core a 1080-line (or larger) mode in
`MiSTer.ini`:

    [HP9K715]
    video_mode=8

The OSD's "Scale" (default V-Integer) then shows the 1024 lines 1:1; "Aspect
ratio: Original" keeps the pixels square. OSD "Display" is Graphics by
default; Auto shows the RS-232 console until the machine first turns Artist's
video on, then Artist (black while X's screen saver blanks it).

For tenox's HP-UX 10.20 image, [`disks/README.md`](disks/README.md) has the
details:
1. Convert the qcow2 to raw. It is 4 GiB, so the card must be exFAT.
2. Rewrite its LVM boot record to the 715's disk path (`tools/hpux/lvmbdra.py
   setpath IMG 2/0/1.6.0`).
3. From a single-user boot (`BOOT_ADMIN> boot scsi.6 isl`, `ISL> hpux -is`):
   - blank `lan0` in `/etc/rc.config.d/netconf` (interface, address and the
     default route) and point the hostname at 127.0.0.1 in `/etc/hosts`. The
     core has no LAN and the kernel has no driver for it, and the Software
     Distributor agent needs an address to bind to;
   - set root's password (`passwd root`): the image's own is not published;
   - rebuild `/etc/lvmtab` with `vgscan`: the disk is `c2t6d0` on the 715.

The core uses the framework in `sys/` unchanged. For the right time of day
it needs a Main_MiSTer that sends this core UTC (HP-UX reads the clock as
UTC): branch `hp9000715` of
[danifunker/Main_MiSTer](https://github.com/danifunker/Main_MiSTer). With a
stock Main_MiSTer HP-UX's clock is off by your zone offset (STUBS S-022).

Known limitations of this build: no LAN, audio or floppy (HP-UX lists them
UNCLAIMED); the analog VGA output carries Artist's picture at 64 MHz pixels
(1280x1024 at 44.7 Hz, which most CRTs will not take); the CPU issues one
instruction a clock (the real PA-7100LC can pair two), so it is somewhat
slower than a 715/64; only HP-UX 10.20 has been tried so far. The full list
is in [`docs/STUBS.md`](docs/STUBS.md). The core needs no Main_MiSTer
changes, except that HP-UX's clock is off by your time-zone offset with a
stock Main (above).

## Planned

| | |
|---|---|
| CPU | PA-7100LC (PA-RISC 1.1 with MAX-1), FPU, 64-entry TLB -- built |
| Memory | 32-128 MB in the SDRAM module, optionally up to 256 MB using DDR3 |
| Graphics | built-in 8-plane colour graphics, up to 1280x1024 -- built (Artist: drawing engine, both colour maps, hardware cursor) |
| Storage | NCR 53C710 SCSI: hard disk images (built) and a CD-ROM with CD audio |
| Input | PS/2 keyboard and mouse |
| Sound | Harmony audio (CS4215 codec) |
| Firmware | HP's boot ROM, revision 1.6 |

## Licence

GPL-2.0-or-later, as the MiSTer template (`LICENSE`).
