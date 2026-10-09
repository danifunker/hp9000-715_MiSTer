# Resume prompt -- Artist draws its own picture; build 23 released with CDE on HDMI (2026-10-09, evening)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
This replaces `RESUME-20261009-artist-x.md`. **Do not change `rtl/cpu/` unless
the user asks for it specifically** (CPU bugs -> `docs/design/cpu-requests.md`
with evidence). **One simulation at a time, none beside a Quartus fit; prefer
the board when it can answer a question.** **Ask before loading a core, editing
`MiSTer.ini` or typing into HP-UX while the user may be using it** (on
2026-10-09 the user was working in the hpterm and two of my typed commands
landed in the File Manager instead). Display problems are solved in the core,
not in the user's ini (memory `core-handles-video-not-ini`).

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/artist.md` -- Artist as built: decode, VRAM, the engine (3),
   vectors (the row "vector"), **4: colour maps, attribute plane, the display
   `artist_video.sv`, the cursor**, 5: tests.
3. `docs/review/09-hpux-x-artist.md` -- how HP-UX 10.20's X server drives
   Artist; **5.5** (traced this session): clipped vectors (LEN = signed dx/dy,
   SRC = |dy|-|dx| / error term, `sth` 0x100CCC = count), dashed vectors
   (0x100ECC; 0x10080C + 0x100EC4 per polyline vertex; 0x100CCC per dash),
   0x100C40 points, X's `ngleBiffVectorEmulator` = the stepping rule, the
   address pattern `0x100800 | op<<8 | f<<6 | reg<<2`.
4. `docs/STUBS.md` S-016, S-023, S-024; `docs/design/system.md` 10 (builds 20-23).

## Where things stand

* **Build 23 is released** (`release/HP9K715.rbf`, `release/hp715.eep` =
  the graphics-console EEPROM; root README = the release notes). Every clock
  meets timing (core +0.288 ns, HDMI +0.330 ns), 32,844 ALMs (78 %), 394 M10K.
* **On the board** (MiSTer .92, build 23, 32 MB, EEPROM slot = `hp715_gfx2.eep`,
  identical to `tools/eeprom/hp715_gfx.eep`): ROM boot screen, ISL, HP-UX
  start-up, X login and CDE on HDMI at 1:1 (confirmed by the user on the
  monitor): proportional text, titles, menus, hpterm, xclock (vectors), oclock,
  the HP logo in its private colour map (LUT1), the pointer drawn by the
  display. HP-UX may still be running when you start -- ask before shutting it
  down (`sync; shutdown -h -y 0` in a focused hpterm).
* **MiSTer.ini** has `[HP9K715]` `video_mode=8` only (backup
  `/media/fat/MiSTer.ini.bak-20261009-hp715`; the user's global mode is
  720p). The core's OSD "Scale" (default V-Integer, `sys/video_freak.sv`) and
  square-pixel ARX/ARY do the rest.

### What this session built (commits `d1dc3d5`..)
* Vectors (review 09 5.5): clipped, dashed (segments, double dash,
  polylines), points; all stepped as X's emulator (`E_LSET`, `E_LINE`).
* **The display** `rtl/artist/artist_video.sv`: Artist's own raster at 64 MHz
  (fixed blanking: 1280x1024 at 44.7 Hz), a line ahead from DDR3 through a new
  `ddr3_port` client (`rf_*`), LUT0/LUT1 (512 entries) by a **1-bit attribute
  plane** in DDR3 at 0x3340_0000 (written by fills with CONTROL_PLANE into
  buffer 13, `K_ATTR`; cleared at reset), the hardware cursor laid over (the
  cursor-in-VRAM save-under is gone). `HP9K715.sv` drives VGA_* from it
  (MISTER_FB off), OSD Display Auto/Graphics/Serial console, video_freak.
* Board tools: `tools/mister/obs_shot.py` (the real HDMI picture from the
  user's OBS, obs-websocket v5 at 192.168.99.82:4455, no auth; the capture
  device is 1920x1080 in a 3840x2160 canvas, so HDMI pixel (x, y) = canvas
  (2x, 2y); Artist's picture starts at about HDMI (335, 28)); `board.sh vram`
  now dumps the LUT copy (512 entries + geometry at word 256) and the
  attribute plane, `vram.py` renders through both LUTs (no cursor).
* `tools/eeprom/mkrelease.sh` makes the graphics-console image by default
  (`monitor graphics.1`, `path console graphics`; `CONSOLE=rs232` for the
  serial one).

## Open (priority order)

1. **Window-move stubs -- fixed in build 25** (`ca45ace`, to check on the
   board): X repaints a vacated backdrop strip as one 16-row band (BINC upload)
   replicated by block moves, the first of them 4 pixels wide; a move with a
   one-word source read that word from the line buffer in the same cycle as
   its last write and copied the previous row's word, so the stale row was
   replicated every 16 rows. `board.sh drag 5 -55` with the pointer on the
   hpterm's title bar reproduces it (recorder dump decoded in the session
   scratchpad `ring_regs_drag.txt`). Build 24 (Display Auto fix) was never
   loaded. If build 25 checks out, ask the user about releasing it (the
   README's known-limitations line mentions the stubs).
2. **Colours in the OBS capture** look more saturated than the LUT (greys
   exact) through both the old frame-buffer path and the new raster; the user
   says the monitor looks right -- the capture chain, not the core. Do not chase
   unless the user sees it on the monitor.
3. Picture starts ~15 px right of centre on HDMI (x 335 instead of 320): the
   raster's sync/blank placement vs. the scaler's auto-detection; cosmetic.
4. S-024: a pixel clock from the programmed timing (108 MHz PLL, real
   1280x1024 at 60 Hz) if the analog output or exact refresh matters.
5. From before: the ROM's 1024x768 modes without their grey panel
   backgrounds (romsim `--fbshot`), the font engine's BINC mask, LUT blt bit
   30, MISC_CTRL[1:0], Color Recovery (BA bit 31), buffer-13 moves/reads,
   vectors one VRAM write per pixel (slow for long lines).
6. LAN (82596) and audio (Harmony) remain unbuilt (HP-UX 10.20 has no driver
   for either, review 06); the next OS targets (Linux, NetBSD) may want them.

## How to work

* Gates: `make -C verilator tb_artist` (engine + display: whole frames
  compared against LUT[attribute][pixel] + cursor; mutation-check new tests),
  `tests/run-rom.sh` (ROM ratchet, ~11 min with the build). Board first for
  anything X does.
* Quartus: `setsid nohup quartus_sh --flow compile HP9K715 > scratch/buildNN.log`
  (~30 min); save the rbf/sta/log to the session scratchpad `keep/builds/`;
  record the build in `docs/design/system.md` 10.
* Board: `board.sh push|load|key|mouse|vram`; the pointer moves ~1.5x the
  `mouse` arguments; new windows take the keyboard focus (CDE), so click into
  the hpterm right before typing and check with `obs_shot.py`.
* Scratch from this session: `/tmp/claude-1000/-home-dani-repos-hp9000-715/91baee42-a0b0-4217-a974-1f33ef8b9062/scratchpad/`
  (`keep/INDEX.md`: builds 20-23; board/OBS captures; recorder dumps
  `ring_kill*.txt`). The X disassembly (`xan/`) is still in the previous
  session's scratchpad `f8be7774-.../scratchpad/`.
