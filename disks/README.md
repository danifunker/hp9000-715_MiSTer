# Disk images

Images for the SCSI targets (`rtl/scsi/scsi_targets.sv`): disk ID 6 =
hps_io slot 0 (`--disk0` in `verilator/romsim`), disk ID 5 = slot 2
(`--disk1`), CD-ROM ID 2 = slot 3 (`--cd`). Raw, 512-byte blocks. Not
committed (`.gitignore`).

## `hpux1020.img` -- HP-UX 10.20

From tenox's HP-UX 10.20 + applications QEMU image
(`hpux1020-apps-qemu.tar.lz` on the NAS; its `hpux.img` is qcow2, set up for
QEMU `-M B160L`, sha256 `1b8331261ed3c75bfe531a245a516b3ef4a04447cc93d5a913b0b6a796e2c902`).

```bash
qemu-img convert -f qcow2 -O raw hpux.img disks/hpux1020.img
```

| | |
|---|---|
| size | 4,294,967,296 bytes (4 GiB; sparse on Linux, ~1.3 GB used) |
| sha256 (as converted, before any boot) | `5d6c811331d9812e089a8de55aef8b87633c44ad5cf0c94dccda507ce84428cb` |
| layout (`tools/hpux/hpdisk.py disks/hpux1020.img layout`) | LIF boot area (ISL, AUTO, HPUX, LABEL); LVM: /stand HFS 48 MB at 0x2D8000, swap/dump 512 MB at 0x32D8000, root VxFS 3.45 GB at 0x232D8000 to the end of the disk |

**The LVM boot record must name the 715's disk** (2026-10-08). The image was
installed on QEMU's B160L, whose PCI SCSI disk is hardware path 8/0/0/0.6.0,
and HP-UX's kernel activates the root volume group from the boot data reserved
area (BDRA, LBA 256), which records that path: on the 715, where the disk is
2/0/1.6.0, the kernel halts with "LVM: Activation of root volume group failed
... Could not configure root VG" (what a real 715 does with a disk moved from
another machine; HP-UX's own repair is `hpux -lm` and `lvlnboot -R`). Rewrite
it offline, checksums included, before the first boot:

```bash
python3 tools/hpux/lvmbdra.py show disks/hpux1020.img            # PV 0: 8/0/0/0.6.0
python3 tools/hpux/lvmbdra.py setpath disks/hpux1020.img 2/0/1.6.0 --save bdra-orig.bin
```

(`sha256` after the rewrite: not recorded, the image is also written by HP-UX
itself when booted without `--snapshot`.) The copy on the MiSTer's card got
the same 8 KB block (`dd ... bs=512 seek=256 conv=notrunc`). With it HP-UX
10.20 boots to its start-up sequence on the board (system.md 10, build 12).

**The image expects QEMU's LAN** (2026-10-08). `/etc/rc.config.d/netconf`
configures `lan0` at 10.0.2.15 with a default route through 10.0.2.2, and
`/etc/hosts` maps the hostname `hpux` to that address. The 715 core has no LAN (and the kernel no driver for the
82596), so "Configure LAN interfaces" fails and the Software Distributor agent
(`swagentd`) cannot bind its RPC endpoint and keeps dying while the start-up
sequence waits for it. Fix it once from a single-user boot (`BOOT_ADMIN> boot
scsi.6 isl`, `ISL> hpux -is`):

```sh
cp /etc/rc.config.d/netconf /etc/rc.config.d/netconf.qemu
sed -e 's/=lan0$/=""/' -e 's/=10.0.2.15$/=""/' -e 's/^ROUTE_DESTINATION.0.=.*/ROUTE_DESTINATION[0]=""/' \
    -e 's/^ROUTE_GATEWAY.0.=.*/ROUTE_GATEWAY[0]=""/' /etc/rc.config.d/netconf.qemu > /etc/rc.config.d/netconf
cp /etc/hosts /etc/hosts.qemu
sed 's/^10.0.2.15/127.0.0.1/' /etc/hosts.qemu > /etc/hosts
sync; reboot
```

**root's password** (2026-10-09). The image's root password is tenox's and is
not published (the tarball holds only `hpux.img` and `run.sh`). On the
MiSTer's copy it was set to `password` from a single-user boot, with the
original file kept:

```sh
cp -p /etc/passwd /etc/passwd.tenox
passwd root
sync; reboot
```

**The LVM table names QEMU's device file** (2026-10-09). `/etc/lvmtab` lists
the root disk as `/dev/dsk/c0t6d0` (the B160L's SCSI bus was instance 0); on
the 715 the built-in SCSI is `ext_bus` instance 2 (`/etc/ioconfig` keeps the
B160L's numbers), so the disk is `/dev/dsk/c2t6d0` and `vgdisplay`/`lvlnboot`
warn "couldn't query physical volume". The kernel does not care (it activates
vg00 from the BDRA), the LVM commands do. Rebuild the table once, as root:

```sh
mv /etc/lvmtab /etc/lvmtab.qemu
vgscan -v          # writes /etc/lvmtab: /dev/vg00, /dev/dsk/c2t6d0
lvlnboot -v vg00   # Boot/Root/Swap/Dump on /dev/dsk/c2t6d0 (2/0/1.6.0)
```

Done on the MiSTer's copy; with both, root logs in multi-user and LVM is
clean (system.md 10, build 14).

The root volume runs to the last block, so the image cannot be trimmed: on
the MiSTer it needs 4 GiB on an **exFAT** SD card (FAT32's limit is 4 GiB - 1
byte). Use `--snapshot` in romsim to keep the image pristine (writes stay in
memory).

**HP-UX 11.11 (`hpux1111.img`, the TCOE 12/2004 install, 2026-10-14) moved
from SCSI ID 5 to ID 6** (2026-10-18), so it boots from the OSD's "Pri.
disk (ID 6)" slot with the shipped EEPROM: the LVM boot record rewritten
offline (`lvmbdra.py setpath IMG 2/0/1.6.0`; the original 8 KB kept next to
the image as `hpux1111.bdra-id5.bin`), then from a single-user boot at ID 6
`mv /etc/lvmtab /etc/lvmtab.id5; vgscan -v; lvlnboot -R /dev/vg00`
(`lvlnboot -v vg00`: boot, root, swap and dump on `/dev/dsk/c0t6d0`,
2/0/1.6.0). Also on that image: hostname `hp715mi` (`netconf`; DHCP from the
router gives the address but no name), `/etc/hosts` `192.168.99.151 hp715mi
mrss1`, and `/etc/nsswitch.conf` with `hosts: files dns` (without it the
router's DNS answered for the host's own name first and CDE's messaging
failed).
