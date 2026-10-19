# HP 9000 Model 715 for MiSTer

An FPGA recreation of the **HP 9000 Model 715/64** PA-RISC workstation for
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki): a PA-7100LC CPU
with FPU, the LASI I/O chip (SCSI, Ethernet, serial, PS/2, audio) and the
built-in Artist graphics at 1280x1024. It runs HP's own boot ROM and HP-UX.

**Status: alpha.** HP-UX 10.20 and HP-UX 11i v1 (11.11) boot to the CDE
desktop, with the PS/2 keyboard and mouse, networking, audio and CD audio.
The HP-UX 11i installer runs from its CD/DVD.

## What you need

- A MiSTer with an SDRAM module: 32 MB is enough for HP-UX 10.20, 128 MB is
  recommended for HP-UX 11i.
- An exFAT SD card (HP-UX disk images are 4 GB and larger).
- An HP-UX disk image or install CD (see [Disk images](#disk-images)).

## Installing

Copy the files from [`release/`](release/):

| file | copy to |
|---|---|
| `HP9K715_20261018.rbf` | `/media/fat/_Unstable/` (or `_Computer/`) |
| `boot0.rom` | `/media/fat/games/HP9K715/` |
| `hp715.eep` | `/media/fat/games/HP9K715/` (optional, see below) |
| `MiSTer` | `/media/fat/MiSTer`, replacing the one there (optional, see below) |

Put your disk images in `/media/fat/games/HP9K715/`.

**Video.** The core shows 1280x1024. Give it a 1080-line HDMI mode in
`MiSTer.ini`, otherwise the picture is squeezed and small text is hard to
read:

    [HP9K715]
    video_mode=8

**MiSTer main binary.** Networking and the correct time of day need the
HP 9000 support in the MiSTer main program. Until it is part of the official
MiSTer release, use the `MiSTer` file from `release/`. With the stock one the
core still runs, but there is no network and HP-UX's clock is off by your
time-zone offset.

**EEPROM.** The 715 keeps its firmware settings (boot path, console, monitor
type, network address) in an EEPROM. The core has one built in, set up to
boot from the disk at SCSI ID 6 with the console on the screen, so nothing
needs to be mounted. Mount `hp715.eep` (OSD > Advanced > EEPROM image) only
if you want changes made at the firmware prompt to be saved.

## Using it

Start HP9K715 from the MiSTer menu, put a disk image in **Pri. disk (ID 6)**
and press **Apply and reset**. The boot ROM tests the machine (about a
minute), then boots the disk.

Open the menu with **F12**. Most settings take effect at the next reset:
change them, then choose **Apply and reset** ("Changes pending" is shown
until you do). Disks, the CD, Load ROM, the network and the keyboard
settings take effect at once.

| menu | option | values |
|---|---|---|
| main | Pri. disk (ID 6) | the disk the machine boots from |
| main | Disk (ID 5) | a second disk |
| main | CD-ROM (ID 2) | an ISO, or CUE/BIN with the custom main binary |
| main | Load ROM | boots another ROM file until the core is restarted |
| main | Memory | **32MB**, 64MB, 128MB, 16MB |
| main | Network interface | **eth0**, None, eth1, macvlan, tap0 |
| Machine | Model | **715/64**, 715/80, 715/100 |
| Machine | TOC (front panel) | the front-panel button: HP-UX dumps memory and reboots |
| Machine | Soft power off | the power button: HP-UX shuts down cleanly |
| Video | Display | **Graphics**, Auto, Serial console |
| Video | Aspect ratio, Scale | **Original**; **V-Integer** |
| Input | Swap Alt/Win keys | **No**, Yes (for Mac keyboards) |
| Advanced | Boot mode | **Normal**, BOOT_ADMIN, ISL, Single-user, LVM maint., Network, CD/DVD |
| Advanced | EEPROM image | an `.eep` file to keep firmware changes |

**Getting to the firmware prompt.** Press **Esc** while the boot ROM starts
up to stop the automatic boot and get the `BOOT_ADMIN>` prompt. From there,
for example, `boot scsi.2` boots the CD and `boot pri isl` stops at the
`ISL>` prompt, where `hpux -is` boots HP-UX single-user.

**Display options.** *Graphics* always shows the Artist screen. *Serial
console* shows the 715's RS-232 console instead (the MiSTer keyboard types
into it). *Auto* shows the serial console until HP-UX turns the graphics
on. A black screen in CDE is the screen saver: move the mouse.

## Disk images

The 715 boots from SCSI ID 6 by default. An HP-UX disk records the SCSI ID it
was installed at, so an image installed at another ID, or on another machine
or emulator, has to be adjusted once before it boots at ID 6.
[`disks/README.md`](disks/README.md) has the steps, including for an
HP-UX 10.20 image made for QEMU and for moving an installed 11.11 disk from
ID 5 to ID 6.

To install HP-UX 11i, put the install CD/DVD in the CD-ROM slot and an empty
image of at least 4 GB at ID 6, then type `boot scsi.2` at `BOOT_ADMIN>`.
Use the HP-UX installer's text interface on the graphics console. Expect the
installation to take several hours.

HP-UX 10.20's standard kernel has no driver for the built-in network chip;
HP-UX 11i's has.

## Known limitations

- The CPU runs one instruction per clock at 64 MHz. The real PA-7100LC can
  run two, so the core is somewhat slower than a real 715/64.
- Disk access is slow, so installing an operating system takes hours.
- The Advanced > Boot mode option does not work reliably yet. Use Esc at
  start-up and type the commands yourself.
- Only HP-UX 10.20 and 11i v1 have been tested. NeXTSTEP 3.3 does not run
  yet; Linux, NetBSD and OpenBSD have not been tried.
- The floppy controller has no drive, audio recording is silent, and memory
  is limited to 128 MB (a real 715 takes up to 256 MB).
- So far the core has been tested on one MiSTer (a SuperStation One).

## Changes

**2026-10-18 (build 65)**
- A new menu layout with submenus, Apply and reset, Load ROM and a
  Mac-keyboard option.
- More reliable timing; the core is a little smaller.
- An updated main binary in `release/`.

**2026-10-15 (build 57)**
- A faster CPU: about 17 % fewer clocks on the same work. HP-UX 11.11 boots
  to the desktop in about 7 minutes.

**2026-10-14 (build 53)**
- The HP-UX 11i installer works.
- Network, audio and CD audio.
- Menu options to boot the firmware prompt, ISL, single-user mode, the
  network or the CD.

## For developers

How the core is built and tested, and the design notes, are in
[`docs/`](docs/): [`docs/design/`](docs/design/) for the machine and the CPU,
[`docs/reference/rom/`](docs/reference/rom/) for the analysis of HP's boot
ROM, [`docs/STUBS.md`](docs/STUBS.md) for everything simplified or left out,
and [`docs/osd-standard.md`](docs/osd-standard.md) for the menu layout shared
with the other computer cores.

## Licence

GPL-2.0-or-later, as the MiSTer template (`LICENSE`).
