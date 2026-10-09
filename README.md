# HP 9000 Model 715 for MiSTer

An FPGA recreation of the **HP 9000 Model 715/64** PA-RISC workstation for the
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform: a
PA-7100LC CPU, the LASI I/O chip (SCSI, Ethernet, serial, parallel, PS/2,
audio) and the built-in 8-plane Artist graphics, with the aim of running
HP's own boot ROM and HP-UX.

**Status (build 15, 2026-10-09):** HP's boot ROM passes its self-tests, boots
from SCSI, and **HP-UX 10.20 boots multi-user on the MiSTer**; root logs in on
the serial console (tried at 32 and 64 MB). There is no graphics yet: the
console is the RS-232 port, which the core also shows on the MiSTer's screen
and types into from the MiSTer's keyboard. Design notes are in
[`docs/design/`](docs/design/), the build log in
[`docs/design/system.md`](docs/design/system.md) section 10.

## Running it on a MiSTer

The files in [`release/`](release/):

| file | goes to | what |
|---|---|---|
| `HP9K715.rbf` | `/media/fat/_Unstable/` (or `_Computer/`) | the core, Quartus build 15: 64 MHz |
| `boot0.rom` | `/media/fat/games/HP9K715/` | HP's PDC 1.6 boot ROM for the 715/64, 258,728 bytes ([`roms/README.md`](roms/README.md): HP firmware patch PF_C7X50016, image IMAGE1A's payload). Loaded by the framework at core start; the loader patches one word ([`docs/STUBS.md`](docs/STUBS.md) S-011) |
| `hp715.eep` | `/media/fat/games/HP9K715/` | the EEPROM image (8 KB, `tools/eeprom/mkrelease.sh`): manufacturing and chassis codes off, RS-232 console, primary path scsi.6, autoboot and autosearch on. Mount it in the OSD's EEPROM slot (slot 1); it is written back |

Also needed: a disk image in `/media/fat/games/HP9K715/`, mounted in the OSD's
disk slot (slot 0, SCSI ID 6). RAM: 16/32/64/128 MB in the OSD; 64 MB is
recommended for HP-UX.

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

The MiSTer's own binary (Main_MiSTer) is the stock one: the core uses the
framework in `sys/` unchanged.

Known issue: Main_MiSTer sends this core local standard time, but HP-UX reads
the clock as UTC, so HP-UX's time is off by your zone offset (STUBS S-022).

## Planned

| | |
|---|---|
| CPU | PA-7100LC (PA-RISC 1.1 with MAX-1), FPU, 64-entry TLB -- built |
| Memory | 32-128 MB in the SDRAM module, optionally up to 256 MB using DDR3 |
| Graphics | built-in 8-plane colour graphics, up to 1280x1024 -- next |
| Storage | NCR 53C710 SCSI: hard disk images (built) and a CD-ROM with CD audio |
| Input | PS/2 keyboard and mouse |
| Sound | Harmony audio (CS4215 codec) |
| Firmware | HP's boot ROM, revision 1.6 |

## Licence

GPL-2.0-or-later, as the MiSTer template (`LICENSE`).
