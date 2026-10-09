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

The root volume runs to the last block, so the image cannot be trimmed: on
the MiSTer it needs 4 GiB on an **exFAT** SD card (FAT32's limit is 4 GiB - 1
byte). Use `--snapshot` in romsim to keep the image pristine (writes stay in
memory).
