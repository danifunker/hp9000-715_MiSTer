# Resume prompt -- Artist runs HP-UX's CDE desktop on the board; build 20 (X fixes + timing split) waiting to be checked (2026-10-09, afternoon)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
This replaces `RESUME-20261009-x11.md`. **Do not change `rtl/cpu/` unless the
user asks for it specifically** (CPU bugs -> `docs/design/cpu-requests.md`
with evidence). **One simulation at a time, none beside a Quartus fit;
prefer the board when it can answer a question** (user, 2026-10-09). The
user asked to end the last session *without* deploying to the MiSTer: ask
before loading anything on the board.

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/artist.md` -- Artist as built (decode, VRAM, the row-span
   engine, BINC, font engine, lines, colour map, cursor, E_LAUNCH, tests).
3. `docs/review/09-hpux-x-artist.md` -- **how HP-UX 10.20's X server drives
   Artist** (disassembly of `cg.1`, `crxutils.1`, `ucrx.1`): sections 2
   (text), 3 (cursor), 4 (LUTs/attribute planes), 5 (fills/copies/lines),
   7 (what the RTL must do), 8 (discrepancy table).
4. `docs/review/08-artist-registers.md` (the ROM/STI side), `docs/STUBS.md`
   S-014, S-016, S-023, S-024, `docs/design/system.md` 10 (builds 16-20).

## Where things stand

### Build 20 -- check it first
* Started 14:15 by `quartus_sh --flow compile HP9K715` (setsid, log
  `scratch/build20.log`) on commit `8944cfe` + `8ba4ca4` (docs only); still
  fitting at 14:30, due ~14:50. **Until it finishes, `output_files/` holds
  build 19 (dated 14:04, failed timing) -- do not load that rbf.** When
  `scratch/build20.log` ends with "Quartus Prime Shell was successful" a
  second time and the files are dated after 14:15, look at
  `output_files/HP9K715.sta.rpt` (the
  "Setup Summary": the core clock is `emu|pll|...general[0]...divclk`, 64
  MHz = 15.625 ns), `output_files/HP9K715.fit.summary`, and copy the rbf
  (`output_files/HP9K715.rbf`) somewhere before the next build overwrites it.
* Record it in `docs/design/system.md` 10 (rows for 16-18 are there; 19
  and 20 are not -- 19: the first cursor version, **setup -1.291 ns, TNS
  -10.445**, 32,069 ALMs (77 %), 395 M10K (71 %), never loaded).
* **The timing fix is already in build 20.** Build 19 missed 64 MHz after
  the cursor went in. A standalone fit of `rtl/artist/artist.sv`
  (`scratch/artist_map/`, `quartus_sh --flow compile artist_map`, SDC
  15.625 ns, all pins virtual; `paths.tcl` there writes the 40 worst paths
  to `paths.txt` with `quartus_sta -t paths.tcl`) showed slack -2.9 ns:
  every worst path went `g_addr` (the latched GSC address) -> the register
  decode in G_DEC -> the operation set-up (clipping, coordinate adds) ->
  `e_y`/`e_xend`. Fixed in `8944cfe` by:
  1. **E_LAUNCH**: G_DEC only decides (`lp_*` flags) and captures the
     operands into `lq_*` registers (put/fill/move/font/line, data, byte
     enables, DSTXY/LENXY/SRCXY/TRANSFER_DATA/end point/font row) and sets
     `e_st <= E_LAUNCH`; the next cycle the launch blocks (`if (e_st ==
     E_LAUNCH && lq_*)`) do the set-up; the engine's case has `E_LAUNCH:
     e_st <= E_IDLE` so a rejected operation (clipped out, attribute
     planes) falls back to idle. E_LAUNCH counts as busy, so a following
     engine access waits;
  2. the cursor position (`c_x`, `c_y`, `c_yoff`, `c_want`) is registered,
     and its clipped rectangle (`g_x0/g_x1/g_y0/g_rows/g_cr/g_cxoff` from
     `gp_x/gp_y/gp_yoff`) is registered a cycle later; a show copies `g_*`
     into `cs_*` (the rectangle actually drawn) and the restore uses
     exactly `cs_*`; `c_moved` compares `gp_*` with the saved position;
  3. the sprite bits are no longer picked per lane by `i + e_cxoff` and a
     64:1 mux: at the row's first issue step (`wi == 0`) the row is loaded
     pre-aligned, `sr_img/sr_msk <= {c_img << e_cxoff, 8'd0} >> e_x0[2:0]`
     (72 bits so the last columns are not lost), lane j uses bit 71-j, and
     each pushed word shifts it left by 8;
  4. the nearest-colour search is three steps (entry -> distances
     `ns_df/ns_db` -> compare).
  Artist alone after this: **+1.83 ns** at the slow 100C corner, 4,237 ALMs,
  21 RAM blocks.
* **If build 20 still misses**: get the paths of the whole design with a
  script like `scratch/artist_map/paths.tcl` but `project_open HP9K715`
  and `report_timing -setup -npaths 40 -to_clock [get_clocks
  {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
  -detail summary -file paths20.txt` (only when no other flow runs). Likely
  next candidates inside Artist, in order: (a) the G_DEC **FB read (GET)
  set-up** still computes `g_src_xy` -> `x1` clip -> `rd_n`/`rd_base` in
  G_DEC -- move it into E_LAUNCH like the others; (b) the per-lane
  computation `c_word` (stage 1 of E_WR): `i = p1_d + j`, the 32:1 pattern
  mux `e_pat[31 - i[4:0]]` for K_BITS/K_SOLID, the byte-enable/mask
  checks, ROP + plane mask -> FIFO -- if it shows up, pre-compute per word
  (at issue time, registered with `p1_*`) the 8 lanes' pattern bits by a
  rotate of `e_pat` and the in-span flags, the same way the cursor bits are
  now pre-aligned; (c) E_LINE's Bresenham step (15-bit compares + adds) --
  register `e2` or split the step over two cycles; (d) the register-read
  mux `reg_rdata` (G_RD) -- it is registered into `rdata` already. Outside
  Artist the old near-critical paths are in the CPU (do not touch it) and
  `ddr3_port`. If the misses are small and outside Artist, try another
  fitter seed (`SEED` in `HP9K715.qsf`) before changing RTL.

### What build 20 should fix (verify on the board, after asking the user)
From review 09, all in `8944cfe` and covered by `make -C verilator tb_artist` (PASS):
* **Overlapping proportional text** (X login "Welcome to hpux", Help
  Manager): X writes glyph rows of large fonts with **`sth` to 0x100620**;
  our CPU drives a halfword store as `{2{halfword}}` with byte enables 1100,
  and K_BITS ignored the byte enables -> every narrow glyph drawn again 16
  px to the right. Now K_BITS writes pixel i only if `e_be[3 - i/8]`.
* **Missing small text** (window titles, menus): the **font engine**
  0x100AA0 (row counter := 0) / 0x1008A0: each word = rows n (bits 31:16)
  and n+1 (15:0), 16 px at DST.x, row DST.y+n, rows >= LEN h dropped;
  after the last row DST.x += LEN.w (X writes DST/LEN with `sth`; the BINC
  mask is ignored, review 09 2.3).
* **Fills**: colour = TRANSFER_DATA bit `31 - ((x - x0) mod 32)` ? FG : BG,
  0-bits transparent with IBO bit 1 or 28; 0x100A20 = TRANSFER_DATA + fill;
  DST.y += LEN.h after a fill for 0x100080 = 0x7D **or 0x08**.
* **Lines**: 0x100E44 (end pixel included) / 0x100E04 (excluded),
  Bresenham from DSTXY in FG (TRANSFER_DATA bit 31), DSTXY := end (X's
  polylines rely on it). One one-pixel span per pixel (state E_LINE).
* **CopyPlane**: an Otc32 source with BA J (bits 20:16) != 0 gives bit J of
  each pixel (CPU reads and recolouring moves); J = 0 keeps OR(pixel AND
  plane mask) for the ROM.
* **Cursor** (first time on the board in build 20): the sprite is drawn
  into the VRAM (no overlay after the MiSTer scaler) with a save-under
  (`su_ram` 1024 x 64, row {r, k}), taken out (K_RESTORE) before any GSC
  access to the engine registers or the window, drawn (K_CURSOR) after
  16,000 idle clocks; image buffer 6, mask buffer 7 (Otc32 writes, pixel x
  in bit 63-x of a row); colours from LUT blt type 2 (`0x80008004`: entries
  2 = background, 3 = foreground, staged by X through BINC 0x100600/0x1005C0)
  mapped to the nearest LUT0 entries; position **x = 4*POS[31:19] +
  POS[17:16] + 16 - 4*(reg19[23:16] + reg19[15:8] + 2)**, first row shown
  = vactive - 1 - POS[15:0], CTRL[5:0] = sprite rows cut off at the top,
  enable CTRL bit 7; mask 0 = transparent. Observed on build 18: X writes
  e.g. POS 0x07F801F7 / CTRL 0x80 on every mouse move.

### Board (MiSTer 192.168.99.92) -- state at the end of the session
* Loaded: **build 18** (`_Unstable/HP9K715.rbf`). HP-UX was shut down
  cleanly from a CDE terminal ("System has halted"); the screen shows the
  ITE's shutdown text.
* OSD config: 32 MB, EEPROM slot -> `games/HP9K715/hp715_gfx2.eep` (the
  graphics-console EEPROM; same file now committed as
  `tools/eeprom/hp715_gfx.eep`); the user's `hp715.eep` (RS-232 console)
  is untouched -- `tools/mister/board.sh setup 32` points back to it.
* **Backup**: `games/HP9K715/hpux1020.img.bak-20261009` = the disk image
  after the one unclean stop of build 17 (before build 18 booted).
* HP-UX logins: root / `password` (X login via `board.sh key 'root\r'`,
  then `'password\r'`). CDE comes up with Help Manager, File Manager and a
  terminal; click into the terminal with `board.sh mouse 0 0 l` (the pointer
  was over it) and type. `uname -a` worked. **Shut down from a terminal**
  (`board.sh key 'sync; shutdown -h -y 0\r'`) before loading a new core;
  inittab has no serial getty with the graphics console.
* Build 18 board results: X login and CDE render right in fixed fonts,
  windows, icons, colours; proportional text overlaps; window titles are
  blank; the login's HP logo is black (a second colour map, see below);
  keyboard (set 3) and mouse work.

### Board tools added this session
* `board.sh key TEXT` / `board.sh mouse DX DY [lrm]` -> `tools/mister/kbd.py`
  on the MiSTer: a uinput virtual keyboard/mouse that Main_MiSTer passes to
  the core's PS/2 ports (`\r \t \b \e` escapes, `{up}`, `{f1}`,
  `{ctrl-c}`; mouse moves in steps of 10, the core sees them amplified).
* `board.sh vram OUT.png` -> dumps DDR3 0x3300_0000 (VRAM, 2048 x 1024 x 8)
  and 0x3320_0000 (the core's copy of LUT0: 128 doublewords of two
  0x00RRGGBB entries + {height, width, video on}, written by `HP9K715.sv`
  4096 clocks after each palette change) and renders the screen with the
  real palette (`tools/mister/vram.py`). **`board.sh shot` (the MiSTer
  screenshot) does not capture the frame-buffer mode** -- it shows the
  core's own 640x480 serial-console picture.
* The recorder (`trace_dump.py dump` on the MiSTer, `/media/fat/hp715dbg/`)
  now also logs CPU accesses to Artist (types 8/9, `ioR/ioW f8...`), PS/2
  bytes (13: `ps2 kbd/mouse >/<`) and hps_io key events (14). The CPU's
  line events flood the 64K ring within seconds, so dump right after the
  action; a filter (an OSD/debug mask of event types) would help.

### Still missing (priority order)
1. **What does the HDMI output show?** Never confirmed by the user: the
   core sets FB_EN (OSD "Display": Auto = while MISC_VIDEO bits 27/25 are
   set; Graphics; Serial console), FB_FORMAT 8-bit palette, FB_BASE
   0x3300_0000, stride 2048, LUT0 into the scaler palette (`FB_PAL_*`).
2. **LUT1 + attribute planes** (review 09 4.2): X installs non-default
   colormaps in LUT1 (LUT blt offset 0x100) and paints windows' attribute
   values (0x01000102 = LUT1, 0x102 = LUT0) with CONTROL_PLANE fills into
   buffer 13. We keep neither, so private-colormap clients (the login's
   logo) show wrong colours. The MiSTer scaler shows one 8-bit palette, so
   this needs a 24/32-bit display buffer kept by the engine (FB_FORMAT
   32bpp; re-render on LUT changes) or a core-generated raster (S-024).
3. **Lines, the rest** (review 09 5.4): the parametric clipped form
   (0x100800 start, 0x100804/0x100808 Bresenham terms, `sth` 0x100CCC =
   pixel count) and dashed lines (0x100ECC) -- not decoded yet.
4. The release: `release/` is still build 15; the root README holds the
   release notes (no README in `release/`). Decide with the user whether the
   shipped EEPROM (S-016) becomes the graphics console.
5. Small: the ROM's 1024x768 modes draw the boot panels without their
   grey backgrounds (romsim `--fbshot`, not investigated); the font
   engine's BINC-mask meaning (review 09 2.3, open question); LUT blt bit 30
   (wait for blank) and MISC_CTRL[1:0] ignored; Color Recovery (BA bit 31).
6. `RESUME`/CLAUDE.md upkeep; `release/` + root README when a build is
   released.

## Technical reference (this session's findings)

* **STI state area** (review 08 0.2; `artist.md` 1): 140 bytes at (1536,
  384) when MISC_VIDEO[3:0] != 0 (1280-wide modes), else (1536, 776).
  MISC_VIDEO resets to **0x301** and stores in mode 0x13602000 to x
  1536..1679 of rows 384/776 are written to **both rows** -- otherwise the
  PDC's third `init_graph` (and every mode change between width classes,
  e.g. the first-boot monitor cycling) read freq_ref = 0 and `$$divI`
  trapped (trap 13 at 0x517c in RAM / chassis 0x2100D, LEDs 0x21).
* **PS/2 keyboard** (`rtl/lasi/ps2_dev.sv`): `F0 00` -> FA + the set
  number (the ROM's keyboard init sends F5, F2, FF, F0 02, F0 00, F4);
  after `F0 03` (HP-UX) keys go out in **set 3** (`set3()`: IBM 101-key
  codes from Linux atkbd's tables; backslash 5C, Windows 8B/8C/8D, Pause
  62); every key sends make + break.
* **BINC data ports** (NGLE manual 4): 0x5C0/0x600/0x604 +x, 0x620 +y,
  0x640 -y, 0x660 -x, 0x680 +x+y, 0x6A0 -x+y, 0x6C0 +x-y, 0x6E0 -x-y; the
  destination moves in place (x by 32/4/1 pixels per Otc, y by 8192 bytes
  long-addressed, 2048 byte-addressed).
* **LUT blt 0x300118**: ctl[31] go, [30] wait-for-blank (ignored),
  [25:16] offset, [15:14] type (0 colour map -> LUT0 entries < 256 go to
  the display; 2 cursor colours; 1/3 dropped), [9:0] count (0 = 512).
* **Sources**: the unofficial NGLE manual (NetBSD
  `src/sys/arch/hppa/doc/ngle_manual.txt`, a copy in the old scratchpad
  below), HP's X server modules (Cg broker; drawing code in `crxutils.1`
  and `ucrx.1`), QEMU 11.1.1 `hw/display/artist.c` (not ground truth).
* **HP-UX root file system**: `tools/hpux/vxfs.py IMAGE ls|cat|get|find|info|stat`
  reads the VxFS root (offset 0x232d8000 in `disks/hpux1020.img`); the X
  server is `/usr/bin/X11/X`, modules under
  `/usr/lib/X11/Xserver/modules/screens/hp/`, HP's notes in
  `/usr/lib/X11/Xserver/info/screens/hp`.
* **Files from this session** (session scratchpad, kept until the box
  reboots: `/tmp/claude-1000/-home-dani-repos-hp9000-715/f8be7774-198c-48ad-8176-43171a995ffd/scratchpad/`):
  `art/HP9K715_b16..b19.rbf` (build 20's is still in `output_files/`),
  `art/hp715_gfx.eep` (graphics console, monitor unset) and
  `hp715_gfx2.eep` (monitor 1), board/sim screenshots (`b18_login.png`
  CDE, `b18_term.png` uname, `C-140.png`/`D-140.png`/`E-170.png` PDC on
  Artist in romsim); `hpux/` the extracted X server tree; `netbsd/` the
  NGLE manual + NetBSD sti/ngle sources; `xan/` the X disassembly
  (`shsom.py`, `*.dis`). Copy anything worth keeping into a durable place
  (or the new session's scratchpad `keep/`) -- ask before deleting.

## How to work

* Gates: `make -C verilator tb_artist` (Artist's unit bench, reference
  model + VRAM with random latency: probe, byte mode, fills, moves, BINC 8
  directions, glyphs incl. `sth` rows, font engine, lines, J planes, LUT
  types, cursor), `tests/run-rom.sh` (passes with Artist present; last run
  on `ccfa6a3`). CPU gates only after a CPU change the user asked for.
* romsim: `make -C verilator romsim ROMSIM_DIR=obj_dir_rom_<name>`; a
  graphics boot needs `+eeprom=` a graphics-console hex
  (`python3 tools/eeprom/mkeeprom.py tohex tools/eeprom/hp715_gfx.eep X.hex`);
  `--fbshot CYCLE FILE` / `--fbshot-end FILE` (PPM), `--arttrace`, `--ps2`
  (typing on the PS/2 keyboard), `--then @CYCLE TEXT`. The PDC's boot
  screen appears at ~140M cycles with `--ram-lg 3 --turbo 15`.
* Quartus: `quartus_sh --flow compile HP9K715` with `setsid nohup`,
  ~33 min; one flow at a time. **Never `pkill -f`/`pgrep -f` with a pattern
  that also matches your own shell** (it killed the tool's shell twice this
  session) -- use `pgrep -x quartus_sh` and kill by PID.
* Board: `tools/mister/board.sh push|load|setup|key|mouse|vram|console|menu`;
  shut HP-UX down before loading a core.
* Rules (CLAUDE.md, memory): commit often with explicit paths, every stub in
  `docs/STUBS.md`, never delete anything without asking, show the user
  screenshots as things move, release notes in the root README.
