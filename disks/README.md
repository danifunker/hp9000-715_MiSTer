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

The root volume runs to the last block, so the image cannot be trimmed: on
the MiSTer it needs 4 GiB on an **exFAT** SD card (FAT32's limit is 4 GiB - 1
byte). Use `--snapshot` in romsim to keep the image pristine (writes stay in
memory).
