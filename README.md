# HP 9000 Model 715 for MiSTer

An FPGA recreation of the **HP 9000 Model 715/64** PA-RISC workstation for the
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform: a
PA-7100LC CPU, the LASI I/O chip (SCSI, Ethernet, serial, parallel, PS/2,
audio) and the built-in 8-plane Artist graphics, with the aim of running
HP's own boot ROM and HP-UX.

**Status: early development -- nothing runs yet.** The documentation review
is in [`docs/review/`](docs/review/).

## Planned

| | |
|---|---|
| CPU | PA-7100LC (PA-RISC 1.1 with MAX-1), FPU, 64-entry TLB |
| Memory | 32-128 MB in the SDRAM module, optionally up to 256 MB using DDR3 |
| Graphics | built-in 8-plane colour graphics, up to 1280x1024 |
| Storage | NCR 53C710 SCSI: hard disk images and a CD-ROM with CD audio |
| Input | PS/2 keyboard and mouse |
| Sound | Harmony audio (CS4215 codec) |
| Firmware | HP's boot ROM, revision 1.6 (supplied by the user) |

## Licence

GPL-2.0-or-later, as the MiSTer template (`LICENSE`).
