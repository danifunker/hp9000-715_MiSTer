# HP 9000 Model 715 for MiSTer

An FPGA recreation of the **HP 9000 Model 715/64** PA-RISC workstation for the
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform: a
PA-7100LC CPU, the LASI I/O chip (SCSI, Ethernet, serial, parallel, PS/2,
audio) and the built-in 8-plane Artist graphics, with the aim of running
HP's own boot ROM and HP-UX.

**Status (build 23, 2026-10-09):** HP's boot ROM passes its self-tests, boots
from SCSI, and **HP-UX 10.20 boots to the CDE desktop on the MiSTer** with the
built-in Artist graphics at 1280x1024: the boot console, the X login and CDE
(windows, menus, proportional and terminal fonts, xclock, oclock, private
colour maps), PS/2 keyboard and mouse with the hardware cursor (tried at 32 and
64 MB). The RS-232 console is still there (on the MiSTer's screen when the OSD
"Display" says so). Design notes are in [`docs/design/`](docs/design/), the
build log in [`docs/design/system.md`](docs/design/system.md) section 10.

## Running it on a MiSTer

The files in [`release/`](release/):

| file | goes to | what |
|---|---|---|
| `HP9K715.rbf` | `/media/fat/_Unstable/` (or `_Computer/`) | the core, Quartus build 23: 64 MHz |
| `boot0.rom` | `/media/fat/games/HP9K715/` | HP's PDC 1.6 boot ROM for the 715/64, 258,728 bytes ([`roms/README.md`](roms/README.md): HP firmware patch PF_C7X50016, image IMAGE1A's payload). Loaded by the framework at core start; the loader patches one word ([`docs/STUBS.md`](docs/STUBS.md) S-011) |
| `hp715.eep` | `/media/fat/games/HP9K715/` | the EEPROM image (8 KB, `tools/eeprom/mkrelease.sh`): manufacturing and chassis codes off, **console on the graphics** (monitor type 1, 1280x1024), PS/2 keyboard, primary path scsi.6, autoboot and autosearch on. Mount it in the OSD's EEPROM slot (slot 1); it is written back. For the RS-232 console instead: `CONSOLE=rs232 tools/eeprom/mkrelease.sh`, or `path console rs232` at `BOOT_ADMIN>` |

Also needed: a disk image in `/media/fat/games/HP9K715/`, mounted in the OSD's
disk slot (slot 0, SCSI ID 6). RAM: 16/32/64/128 MB in the OSD; 64 MB is
recommended for HP-UX.

**Display.** Artist draws 1280x1024 (the PDC can switch to 1024x768 and other
modes), and the core sends that picture to the MiSTer's scaler itself. The
HDMI output mode is the MiSTer's own setting and a core cannot change it:
with a 1280x720 mode the 1024 lines are squeezed into 720 and small text
becomes unreadable, so give the core a 1080-line (or larger) mode in
`MiSTer.ini`:

    [HP9K715]
    video_mode=8

The OSD's "Scale" (default V-Integer) then shows the 1024 lines 1:1; "Aspect
ratio: Original" keeps the pixels square. OSD "Display": Auto shows Artist
while the machine has its video on and the RS-232 console otherwise.

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
(1280x1024 at 44.7 Hz, which most CRTs will not take); moving a window has
once left 4-pixel stubs of its old frame every 16th row (under
investigation); the full list is in [`docs/STUBS.md`](docs/STUBS.md).

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
