# Resume prompt: OSD boot helpers, graphics by default, a sensible RAM default

## Status (2026-10-14, end of the session that did it)

Done, in builds 49-50 (`docs/design/system.md` 10): the shipped EEPROM built
into the core (`rtl/mister/hp715_default.hex`, `hp_xbus` `EE_INIT`, S-016),
OSD "EEPROM (no image)" Built-in/Blank, a mounted image resets the machine
(`eeprom_save` `loaded`), Display default Graphics, RAM default 32 MB (the
values reordered; `board.sh setup` updated), "Boot mode (on reset)" O[17:15]
with `rtl/boot_seq.sv` (S-029: prompt detection by console polling, gated on
the ROM's chassis code; the LASI taps `con_*`, `ps2_dev` `inj_*`; romsim
`--boot N`). README updated. **Proven in romsim**: BOOT_ADMIN, ISL and
single-user on RS-232 (`scratch/hp715_rs232.eep`, made by
`CONSOLE=rs232 tools/eeprom/mkrelease.sh`), ISL on the graphics console.
**Open**: on the board (.92, build 50) "Boot mode = ISL" did not stop the
autoboot in one trial (the normal boot is fine). Also open: why "Auto" does
not follow X for the user (not reproduced; ask whether to drop it), the
Network mode's `boot lan` vs `boot lan install`, the 11.11-at-64-MB question,
and the OSD-driven board tests of every mode. The area work
(`docs/design/area-plan.md`) is shelved at build 50 (A1-A4, A8, B1 done).

You are picking up the HP9K715 core (HP 9000 Model 715/64 for MiSTer). Read
`CLAUDE.md` first: its rules apply. In particular: **no changes under
`rtl/cpu/`**, every stub or simplification goes in `docs/STUBS.md` in the
same change, one Quartus flow at a time (`pgrep -a quartus` first), one
romsim at a time, never `sys/`, never delete without asking, commit only when
the user asks.

## Why this task exists

On 2026-10-14 the user set the core up on two MiSTers (.92 and .143) and
found the first-run experience hard:

- **A fresh setup shows a black HDMI screen.** With no EEPROM image mounted
  in the OSD's "Mount EEPROM" slot, the EEPROM is blank (all 0xFF). The ROM
  then runs in **manufacturing mode** (EE 0x1694 = 0xB1), with its console on
  RS-232 only and no autoboot. The user thought the EEPROM option was broken.
- **A mounted EEPROM only takes effect after a reset.** `eeprom_save.sv` loads
  the image as soon as it is mounted, but the ROM reads it only at power-on.
- **OSD settings are lost unless saved.** RAM defaults to 16 MB (option index
  0) and is only kept after System page > "Save settings". .92 ran at 16 MB.
- **Getting to the boot menu is hard.** The user had to recover an HP-UX
  11.11 v1 install whose LVM root activation failed. The disk path had
  changed: the 715's boot disk is `2/0/1.6.0`. That meant catching the ROM's
  ESC window on the PS/2 keyboard, `boot pri isl`, then `ISL> hpux -lm`.
  They called it "pretty challenging".

## What the user asked for

1. **OSD menus that help with booting.** Getting to BOOT_ADMIN, ISL,
   single-user mode, LVM maintenance mode, a network boot and a CD/DVD boot
   should be possible from the OSD.
2. **Graphics by default.** A user who mounts nothing but a disk should get
   the HP boot screen and the OS on HDMI.
3. **A RAM default that is good enough to start with.**

## The user's decisions (2026-10-14)

These are settled. Do not reopen them.

- **Display defaults to "Graphics".** With "Auto", X does not appear on its
  own: the user has to open the OSD and pick "Graphics". Make "Graphics"
  index 0. Keep "Auto" only if you find and fix why it fails to follow X;
  otherwise ask the user whether to drop it.
- **RAM defaults to 32 MB.** It is proven for HP-UX 10.20 with CDE and is
  good enough to start with. Users pick more for HP-UX 11i.
- **Boot mode is sticky.** It applies at every reset until the user changes
  it. It is not a one-shot.
- **Boot mode values**, all in one option:

| value | what the core does after reset |
|---|---|
| Normal | nothing: the ROM follows the EEPROM (autoboot from the primary path) |
| BOOT_ADMIN | stops the autoboot; leaves the user at `BOOT_ADMIN>` |
| ISL | `boot pri isl`; leaves the user at `ISL>` |
| Single-user | `boot pri isl`, then `hpux -is` |
| LVM maintenance | `boot pri isl`, then `hpux -lm`. Offer it even though it may not work correctly on every image |
| Network | `boot lan` (check with the user whether `boot lan install` is wanted for install servers) |
| CD/DVD | `boot scsi.2`, the CD-ROM at SCSI ID 2 |

That is 7 values, which fits in 3 status bits.

## Facts you will need

**OSD and status bits.** All of this is in `HP9K715.sv` `CONF_STR`:

| status bits | use |
|---|---|
| 0 | Reset (T[0]/R[0]) |
| 2:1 | Model 715/64, 715/80, 715/100 |
| 5:3 | RAM 16, 32, 64, 128 MB (latched at reset, clipped to the SDRAM module) |
| 6, 7 | TOC, soft power off |
| 9:8 | SDRAM read capture |
| 11:10 | Display: Auto, Graphics, Serial console |
| 14:12 | Network |
| 15..63 | **free** |
| 64..113 | the debug recorder's trigger (`tools/mister/board.sh trig`) |
| 121..125 | aspect ratio, scale |

A saved `HP9K715.CFG` holds the raw status word. If you reorder an option's
values, existing saved configs change meaning. Also update `board.sh setup`,
which encodes RAM as `r << 3`. The OSD's Right key jumps to the System page;
Enter cycles a value. Users trip on this, so the README should say it.

**EEPROM.** `rtl/hp_xbus.sv` holds an 8 KB BRAM. It is blank at
configuration and preloaded only under `SIMULATION`. `rtl/mister/eeprom_save.sv`
loads it from slot 1 (`SC1,EEP`) before reset is released, with a 3 s
backstop, and saves it back 2 s after the firmware's last write. The shipped
image is `tools/eeprom/hp715_default.eep`, the same file as `release/hp715.eep`
(STUBS S-016). It has manufacturing off, the console on graphics, monitor
type 1, a PS/2 keyboard, primary path scsi.6, and autoboot and autosearch on.

**The ROM's boot decision.** See `docs/reference/rom/BOOTFLOW.md` around line
300 and the stable-storage table in `FIRMWARE.md` around line 530:

- Manufacturing mode goes straight to BOOT_ADMIN.
- Otherwise the ROM reads the secure flag at EE 0x1696.
- It then reads stable storage offset 0x00, the primary path. In its flags
  byte, bit 7 is autoboot and bit 6 is autosearch.
- An ESC (0x1B) waiting on the console when the ROM checks
  (`console_key_is(0x1B)`) aborts to BOOT_ADMIN. The ROM also honours ESC
  during the "Press <ESCAPE> to stop boot sequence" countdown.
- Stable storage offset 0x60 is the console path; module 1 means built-in
  graphics.
- **Work out how stable-storage offsets map to EEPROM byte addresses** before
  patching anything. The PDC_STABLE implementation in the ROM listing has it.

**Keyboard and serial input.** `rtl/lasi/ps2_dev.sv` turns hps_io `ps2_key`
codes into scan-code set 3 (Esc is 0x08 in set 3). `rtl/lasi/lasi_uart.sv` is
the 16550. A keystroke injector can feed either one: the console can be
graphics with a PS/2 keyboard, or RS-232.

**RAM evidence.**

| setting | evidence |
|---|---|
| 16 MB | early kernel bring-up only; CDE never tried |
| 32 MB | HP-UX 10.20 multi-user login and the full CDE desktop on the board (`docs/design/system.md` 10, build 21) |
| 64 MB | 10.20 multi-user; the README's recommendation |
| 128 MB | HP-UX 11i installer runs on the board (builds 36-38) |

Nothing has tested HP-UX 11i below 128 MB. The default is 32 MB by the
user's decision. If time allows, find out whether 11.11 runs at 64 MB on .143
(the user's recovered 11.11 v1 disk), so the README can say what 11i needs.

## Suggested design (refine it, and ask the user where the choice is theirs)

1. **Built-in default EEPROM.** When slot 1 has no image, load the shipped
   image instead of leaving the BRAM blank. Synthesis can preload it, for
   example a `$readmemh` / MIF init outside `SIMULATION`, generated from
   `hp715_default.eep`. Nothing is saved without a mounted image, so the user
   gets graphics with no setup.
   - Consider an OSD option "EEPROM (no image): Built-in / Blank
     (manufacturing)" so the factory path stays reachable.
   - Update S-016 in `docs/STUBS.md`.
2. **Defaults by option order.** Index 0 is the default, so make it the
   wanted value.
   - Display: "Graphics" first.
   - RAM: 32 MB first. Remap the decode so the hardware encoding is
     unchanged, for example list "32MB,64MB,128MB,16MB" and decode
     `(idx + 1) & 3`.
   - Saved configs change meaning. Note it in the release notes and update
     `board.sh setup`.
   - **Find out why "Auto" does not follow X.** The README says Auto stays on
     Artist once its video has been on since reset. The user sees otherwise.
3. **"Boot mode (on reset)" OSD option** in the free bits, for example
   O[17:15], with the seven values above, Normal at index 0. It is sticky:
   the core runs the chosen sequence after every reset.
   - **BOOT_ADMIN:** inject ESC on both console inputs from reset until the
     ROM consumes one. Do not patch the autoboot bit: that would dirty the
     EEPROM and be saved back to the user's file.
   - **The other modes:** a small keystroke sequencer stops the autoboot the
     same way, then types the commands from the table at `BOOT_ADMIN>` and
     at `ISL>`.
   - **Prompt detection is the hard part.** Text on the graphics console goes
     through STI to VRAM, so the core cannot see it.
   - One idea: treat "the firmware is polling the console input with nothing
     to read" as "waiting at a prompt". That is a run of PS/2 or UART status
     reads with no data. On RS-232 the UART's TX stream can also be matched
     for `BOOT_ADMIN>` and `ISL>`.
   - Avoid fixed delays if you can. Boot times vary with fastboot, RAM size
     and disk.
   - The sequencer must stop typing once the kernel starts, and must never
     type into a running OS.

Put every simplification in STUBS, for example "the sequencer assumes the
ROM's English prompts" or "ESC injection stops after N s".

## How to prove it

- **romsim** (`verilator/romsim/`, `--type` and `--then` exist) for the
  injector and sequencer. Run each boot mode to its prompt on HP's ROM:
  BOOT_ADMIN, ISL, a single-user `#`. Save checkpoints to keep the runs short.
- **Quartus fit:** check `docs/design/cpu-timing.md` and `system.md` 10 for
  the last numbers. The design is about 88 % full, so keep the logic small.
- **On the board, driven through the OSD like a user**
  (memory: osd-driven-release-tests). Start HP9K715 from the menu, set options
  with mrext keys (`curl -X POST
  http://<board>:8182/api/controls/keyboard-raw/<keycode>`), and read the HDMI
  output with `tools/mister/obs_shot.py`. OBS watches **.92**. .143 has no
  capture, so use its serial console (`MISTER=root@192.168.99.143
  tools/mister/board.sh console`) and `board.sh shot`.
- **Test a fresh config.** Move `config/HP9K715.CFG` and `.s1` aside: ask the
  user before deleting anything. Then confirm a disk-only setup reaches the
  OS on HDMI at the default RAM.
- Each boot mode reaches its prompt on .92 (10.20) and .143 (11.11). For
  Network, a ROM that reaches "Trying LAN" or the LAN boot prompt is enough
  unless the user has a boot server. For CD/DVD, use the 11i install CD.
- After a reset with a sticky mode set, check the mode runs again.
- **Release:** `release/` and the root README's release notes (never a
  `release/README.md`). The README should cover the new options, what changed
  in saved configs, and the custom Main binary.

## Board state on 2026-10-14

| | .92 (`MiSTerss1`, OBS) | .143 (`MiSTerpi`) |
|---|---|---|
| core | `_Unstable/HP9K715.rbf` = build of 2026-10-11 (md5 05d6f774...) | same |
| Main | `release/MiSTer` (hp9k715-enhancements, md5 33994ddf...); stock kept as `/media/fat/MiSTer.stock-20261014` | same |
| ROM | `games/HP9K715/boot.rom` (legacy name, Main loads it) | `boot0.rom` |
| EEPROM | `hp715_release.eep` mounted (slot 1); the older `hp715.eep` and diag/serial/gfx variants also there | `hp715.eep` (release image), mounted by the user |
| disk | `hpux1020.img` in slot 0: boots to HP-UX start-up on HDMI | `hp715-11.11v1.img` (LVM recovered by the user) |
| RAM | 64 MB, saved | user's choice |

A MiSTer updater (update_all/downloader) may put the stock Main back. .92's
Main had been replaced on 2026-10-13. The stock Main lacks `support/hp9k`:
no LAN bridge, no RTC, no CD track table.
