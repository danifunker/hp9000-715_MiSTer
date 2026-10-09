# HP9K715 for MiSTer -- release files (build 14, 2026-10-09)

| file | goes to | what |
|---|---|---|
| `HP9K715.rbf` | `/media/fat/_Unstable/` (or `_Computer/`) | the core, Quartus build 14 (`docs/design/system.md` 10): 64 MHz, HP-UX 10.20 boots to `Console Login:` |
| `boot0.rom` | `/media/fat/games/HP9K715/` | HP's PDC 1.6 boot ROM for the 715/64, 258,728 bytes (`roms/README.md`: HP firmware patch PF_C7X50016, image IMAGE1A's payload). Loaded by the framework at core start; the loader patches one word (STUBS S-011) |
| `hp715.eep` | `/media/fat/games/HP9K715/` | the EEPROM image (8 KB, `tools/eeprom/mkrelease.sh`): manufacturing and chassis codes off, RS-232 console, primary path scsi.6, autoboot and autosearch on. Mount it in the OSD's EEPROM slot (slot 1); it is written back |

Also needed on the card: a disk image in `/media/fat/games/HP9K715/`, mounted
in the OSD's disk slot (slot 0, SCSI ID 6). For tenox's HP-UX 10.20 image see
`disks/README.md`: convert the qcow2 to raw (4 GiB, so an exFAT card), rewrite
its LVM boot record to the 715's disk path (`tools/hpux/lvmbdra.py setpath IMG
2/0/1.6.0`), and from a single-user boot blank `lan0` in
`/etc/rc.config.d/netconf` (interface, address and the default route) and
point the hostname at 127.0.0.1 in `/etc/hosts`
(the 715 core has no LAN; the kernel has no driver for it either; the
Software Distributor agent needs an address to bind to). RAM: 16/32/64/128 MB in the
OSD; 64 MB recommended for HP-UX.

The MiSTer's own binary (Main_MiSTer) is the stock one: the core uses the
framework in `sys/` unchanged.
