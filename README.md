# HP 9000 Model 715 for MiSTer

An FPGA recreation of the **HP 9000 Model 715/64** PA-RISC workstation for the
[MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki) platform: a
PA-7100LC CPU, the LASI I/O chip (SCSI, Ethernet, serial, parallel, PS/2,
audio) and the built-in 8-plane Artist graphics, with the aim of running
HP's own boot ROM and HP-UX.

**Status (build 65, 2026-10-18, alpha):** HP's boot ROM passes its self-tests, boots
from SCSI, and **HP-UX 10.20 boots to the CDE desktop on the MiSTer** with the
built-in Artist graphics at 1280x1024: the boot console, the X login and CDE
(windows, menus, proportional and terminal fonts, xclock, oclock, private
colour maps), PS/2 keyboard and mouse with the hardware cursor (tried at 32 and
64 MB). The RS-232 console is still there (on the MiSTer's screen when the OSD
"Display" says so). Design notes are in [`docs/design/`](docs/design/), the
build log in [`docs/design/system.md`](docs/design/system.md) section 10.

**Build 65 (2026-10-18)** over build 57:
- **A new OSD, laid out to the [standard](docs/osd-standard.md) for the
  computer cores.** The main screen holds the disks, Load ROM, Memory and
  Network interface; the rest is in the Machine, Video, Input and Advanced
  submenus. Settings now wait for **Apply and reset**, and a "Changes
  pending" line shows until you press it.
- **New rows:** Load ROM, to boot another ROM for one session (an MGL file
  can name it), and Input > Swap Alt/Win keys, for Mac keyboards.
- **Development rows gone:** SDRAM read capture (fixed at the edge that
  works) and EEPROM (no image) Blank.
- **Every clock meets timing**, the 64 MHz core with 0.31 ns to spare (build
  57 missed by 0.009 ns). The core is about 1,200 ALMs smaller (85 % full)
  from area trims in the keyboard/mouse model, the 82596, the SCSI targets,
  Artist and the MIOC. A CPU path from the branch-target adder into the
  I-cache address was cut, without costing cycles.
- On the board (a SuperStation One), from the MiSTer menu: HP's boot ROM
  passes its self-tests, and HP-UX 11.11 boots to the CDE desktop and runs
  it (terminal, editor, menus, dialogs, workspaces, help).

**Build 57 (2026-10-15)** over build 53: the faster CPU -- a D-cache miss
no longer replays the instruction, a predicted branch costs one bubble, not
two (the `tests/cpu` perf suite runs in 17 % fewer cycles; HP-UX 11.11 boots
to CDE in about 7 minutes). The core clock closes to within 0.01 ns of 64 MHz
on one path, which runs fine on the board at room temperature. An HP-UX 11i
install is not faster: it is bound by the SCSI/SD path, the next thing to
work on.

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
| `HP9K715_20261018.rbf` | `/media/fat/_Unstable/` (or `_Computer/`) | the core, Quartus build 65 (2026-10-18): 64 MHz |
| `boot0.rom` | `/media/fat/games/HP9K715/` | HP's PDC 1.6 boot ROM for the 715/64, 258,728 bytes ([`roms/README.md`](roms/README.md): HP firmware patch PF_C7X50016, image IMAGE1A's payload). Loaded by the framework at core start; the loader patches one word ([`docs/STUBS.md`](docs/STUBS.md) S-011) |
| `hp715.eep` | `/media/fat/games/HP9K715/` | the EEPROM image (8 KB, `tools/eeprom/mkrelease.sh`): manufacturing and chassis codes off, **console on the graphics** (monitor type 1, 1280x1024), PS/2 keyboard, primary path scsi.6, autoboot and autosearch on. **The same image is built into the core**, so nothing needs mounting to boot; mount it in the OSD's Advanced > "EEPROM image" slot only to keep the firmware's changes (boot paths, monitor type, `lanaddress`): it is written back, and mounting it resets the machine so the ROM reads it. For the RS-232 console instead: `CONSOLE=rs232 tools/eeprom/mkrelease.sh`, or `path console rs232` at `BOOT_ADMIN>` |

Also needed: a disk image in `/media/fat/games/HP9K715/`, mounted in the OSD's
"Pri. disk (ID 6)" slot. RAM: 32 MB by default (HP-UX 10.20 with CDE
runs in it); 64 MB is recommended for HP-UX 10.20, 128 MB for HP-UX 11i.

**The OSD** (F12; Enter opens a submenu or cycles a value, Left goes back;
the Right key jumps to MiSTer's System page, where "Save settings" keeps
the choices). It follows the [OSD standard](docs/osd-standard.md) for the
computer cores: **settings wait for the next reset**. Change them, then
press **Apply and reset**; "Changes pending" shows above it until you do.
Disks, Load ROM, Network interface, Input and the buttons act at once.

| page | row | values | notes |
|---|---|---|---|
| main | Pri. disk (ID 6) | a disk image | the disk the 715 boots from by default (the EEPROM's primary path, `scsi.6`; a path set at `BOOT_ADMIN>` can point elsewhere) |
| main | Disk (ID 5), CD-ROM (ID 2) | disk image, ISO | |
| main | Load ROM | a .rom file | another boot ROM for this session only; a core start loads `boot0.rom`. An MGL can name one (`<file type="f" index="0" path="..."/>`) |
| main | Memory | **32MB**, 64MB, 128MB, 16MB | clipped to the SDRAM module |
| main | Network interface | **eth0**, None, eth1, macvlan, tap0 | the 82596's bridge (needs the custom Main); None leaves the built-in LAN without a cable |
| Machine | Model | **715/64**, 715/80, 715/100 | |
| Machine | TOC (front panel), Soft power off | buttons | TOC: HP-UX dumps and reboots; soft power off: the power button held 2 s, HP-UX shuts down |
| Video | Display | **Graphics**, Auto, Serial console | Graphics shows Artist's picture always; Auto shows the RS-232 console until Artist's video first comes on; Serial console shows the RS-232 console |
| Video | Aspect ratio, Scale | **Original**; **V-Integer** | |
| Input | Swap Alt/Win keys | **No**, Yes | Yes swaps the left and right Alt and Windows keys (for a Mac keyboard) |
| Advanced | Boot mode | **Normal**, BOOT_ADMIN, ISL, Single-user, LVM maint., Network, CD/DVD | what the core does after every reset until it is changed back: Normal lets the ROM autoboot; the others stop the autoboot (ESC) and, from `BOOT_ADMIN>`, type `boot pri isl` (then `hpux -is` / `hpux -lm` at `ISL>`), `boot lan` or `boot scsi.2` for you. It works on the graphics console and on RS-232 |
| Advanced | EEPROM image | an .eep file | the firmware's saved settings; empty: the built-in image (below) |

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
and for the LAN it needs a Main_MiSTer that sends this core UTC (HP-UX reads
the clock as UTC) and bridges the 82596's frames to the MiSTer's Ethernet:
branch `hp9k-family` of
[danifunker/Main_MiSTer](https://github.com/danifunker/Main_MiSTer); the
`release/MiSTer` binary is that Main built on 2026-10-14 from commit
`12b0f43` (replace
`/media/fat/MiSTer` with it). With a stock Main_MiSTer HP-UX's clock is off
by your zone offset (STUBS S-022) and there is no network.

Known limitations of this build:
- **Tested on one board** (a SuperStation One with its SDRAM). On a second
  board (a MiSTer Pi) the core did not work properly and HP-UX 11.11 hung
  once; the cause is not known. The SDRAM read timing was tuned on the first
  board only ([`docs/STUBS.md`](docs/STUBS.md) S-019) and could differ from
  board to board; build 65 meets timing on every clock.
- OSD "Boot mode" cannot stop an auto-search boot: with no disk at ID 6 the
  boot ROM boots another disk without the countdown the sequencer waits for
  (STUBS S-029).
- The CPU issues one instruction a clock (the real PA-7100LC can pair two),
  so it is somewhat slower than a 715/64.
- An HP-UX install from CD/DVD is slow (about 2 hours for a third of the
  TCOE filesets): it is bound by the SCSI/SD path, not the CPU.
- HP-UX 10.20 and 11i v1 (11.11) run; NeXTSTEP 3.3 does not run properly
  yet; Linux and the BSDs have not been tried.
- With a stock Main_MiSTer HP-UX's clock is off by your time-zone offset and
  there is no network (above); everything else needs no Main changes.

The full list of simplifications is in [`docs/STUBS.md`](docs/STUBS.md);
what is left to do is in
[`RESUME-20261018-wrapup.md`](RESUME-20261018-wrapup.md).

## Hardware

| | |
|---|---|
| CPU | PA-7100LC (PA-RISC 1.1 with MAX-1), FPU, 64-entry TLB + 8 block entries, 128 KB + 128 KB caches, the hardware TLB-miss walker -- built (single issue) |
| Memory | 16-128 MB in the SDRAM module -- built; up to 256 MB using DDR3 -- not built |
| Graphics | built-in 8-plane Artist graphics, up to 1280x1024 -- built (drawing engine, both colour maps, hardware cursor) |
| Storage | NCR 53C710 SCSI: two hard disk images and a CD-ROM with CD audio -- built; PC floppy controller with no drive |
| Network | Intel 82596 Ethernet -- built (needs the custom Main) |
| Input | PS/2 keyboard and mouse -- built; RS-232 console |
| Sound | Harmony audio (CS4215 codec), playback -- built |
| Firmware | HP's boot ROM, revision 1.6 |

## Licence

GPL-2.0-or-later, as the MiSTer template (`LICENSE`).
