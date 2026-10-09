# Artist -- the built-in graphics as built

The 715's Artist (8 planes, 1280x1024, HPA 0xF8000000) as `rtl/artist/artist.sv`.
What the hardware must do is argued in `docs/review/08-artist-registers.md`
("08"): this note says how we do it and what is left out. Every
simplification is in `docs/STUBS.md` (S-023 Artist, S-024 the video path).

Status: milestone 1 (08 6.1, HP's PDC 1.6 boot console) built 2026-10-09.

## 1. Where it sits

```
 MIOC --gsc (dev 3)--> artist.sv --vr_* (64-bit bursts)--> ddr3_port (board) / sim.v array (simulator)
                           |  \--pal_* (LUT0 writes)----> MiSTer scaler palette (FB_PAL_*)
                           \--gfx_on, width, height ----> FB_EN / FB_WIDTH / FB_HEIGHT
                     the scaler reads the VRAM from DDR3 0x3300_0000 itself (MISTER_FB)
```

* GSC decode (08 1.1): region 2 0xF8100000-0xF837FFFF and region 3
  0xF8380000-0xF8380FFF are registers, 0xF9000000-0xF9FFFFFF the frame-buffer
  window; the HPA page 0xF8000000-0xF80FFFFF (so PDC_ADD_VALID of the HPA
  fails and the ROM takes its STI from 0xF0024000) and the rest of
  0xF8000000-0xF8FFFFFF bus-error. `mioc.sv` sends 0xF8000000-0xF9FFFFFF to
  device 3 when `HAS_ARTIST` (on in the simulator and on the board).
* Reset: the machine reset or LASI IORESET bit 8 clear (`artist_rst`)
  clears every register except MISC_VIDEO, which comes out of reset as
  **0x00000301**; the VRAM is not cleared. The 0x380004 bit 8 reset clears
  only the bus-error timer enable (08 4.6: HP-UX's warm path needs
  MISC_VIDEO and the VRAM to survive it).
* **Why MISC_VIDEO resets to 0x301** (found 2026-10-09 in romsim; 08 1.1
  said 0, from bit 23 alone): the STI keeps its private state at (1536, 384)
  when MISC_VIDEO[3:0] != 0 (a 1280-wide mode) and at (1536, 776) otherwise
  (f0024fe0, recomputed after a mode set at f002560c). Its cold path writes
  the state -- word 1 = `freq_ref` from page zero 0x610, byte 0 = the
  friendly-boot countdown, the non-text colours -- *before* the first mode
  set, at the address the reset value of MISC_VIDEO selects; the mode set
  then rewrites only byte 1 (monitor index) and word 2 at the new place. The
  PDC's third `init_graph` call (after `self_test`; reset + ext, so it
  reprograms the mode explicitly) takes the warm path, reads `freq_ref` from
  (1540, 384) and divides by `freq_ref >> 8` in the PLL search (`$$divI` at
  f00253e0). With MISC_VIDEO = 0 at reset that word was never written: the
  divide trapped (conditional trap 13, chassis 0x2100D, `halt_forever`).
  A real 2 MB board must therefore leave reset with the size fields of its
  default 1280-wide mode, 0x301 (bits 11:8 = (1024-1)>>8, 3:0 =
  (1280/4-1)>>8; bit 23 clear so the first call still takes the cold path).
* **The state area is kept in both rows** (STUBS S-023). The reset value
  only fixes the default case: every mode change between a 1280-wide and a
  narrower mode moves the state, and the next call reads word 1 (and the
  countdown byte) where nothing wrote them. It happens at once on a first
  boot -- with the monitor type unset (EE 0x16CA = 0xFF) and no keyboard
  the ROM cycles through the monitor types (1280x1024, then 1024x768 ...),
  seen 2026-10-09 in romsim and on the board (build 16: trap 13 at 0x517c,
  LEDs 0x21; the board's DDR3 VRAM held the state at y = 384 intact and a
  second copy at y = 776 with monitor index 2 and word 1 = 0) -- and on
  every boot with a 1024-wide monitor type chosen. A real Artist's VRAM
  powers up with random contents, so there `freq_ref` would merely be
  garbage (a wrong PLL setting until the next cold path); ours holds 0 and
  the divide traps. So a CPU store in the STI's state-access mode
  (DST_BM_ACCESS = 0x13602000) to x 1536..1679 of row 384 or 776 is
  written to both rows: whichever copy a mode change selects is the one the
  cold path wrote.

## 2. VRAM

2048 x 1024 x 8 bits = 2 MB, outside the module on the `vr_*` port: 64-bit
words, word address `{y[9:0], x[10:3]}`, pixel x in byte lane `x[2:0]`
(little-endian lanes), i.e. pixel (x, y) at byte `y * 2048 + x`. On the
board it is DDR3 0x3300_0000 (memory placement rule: VRAM in DDR3), where
the MiSTer scaler reads it directly as an 8-bit indexed frame buffer with a
2048-byte stride (the scaler byte-swaps the bridge's 64-bit words, so byte
address order is pixel order). Buffers 1 and 2 (and every buffer number
but 6, 7, 13, 15) are this one image (08 0.1).

Port protocol: a read is `vr_req`, `vr_we` = 0, `vr_addr`, `vr_len`
(1..64) held until `vr_ack`, then `vr_len` beats of `vr_rvalid`. A write is
raised with beat 0 already valid (`vr_wvalid`, `vr_wdata`, `vr_be`);
`vr_ack` comes with beat 0's `vr_wready`, then one `vr_wready` per beat.
`ddr3_port.sv` turns these into DDRAM bursts (a beat's write strobe drops
if the next one is not ready); `sim.v` serves them from an array with an
8-cycle read latency; `tb_artist` serves them with random latency, gaps and
acceptance delays.

## 3. The drawing engine

One operation at a time; busy (0x300000 and 0x380000 bit 24) while it runs.
Every write is a **row span** `[x0, xend)` on row `y`, repeated over rows:

| Operation | Trigger | Source of each pixel |
|---|---|---|
| rectangle fill | 0x100A04 (LENXY + go), 0x100A00 (DSTXY + go), 0x100A20 (TRANSFER_DATA + go) | TRANSFER_DATA bit 31 - ((x - x0) mod 32) ? FG : BG (review 09 5.1) |
| block move | 0x100B00 (DSTXY + go), 0x100B04 (LENXY + go) | the source pixel; with DST Ots = 6 (indirect) recoloured: bit = OR(pixel AND plane mask) -> FG/BG (08 2.5) |
| CPU store to the window | DST_BM_ACCESS (0x118004) | Otc 5: 32 pixels, bit 31-i -> FG/BG (Ots 6) or 1/0, 8 pixels per enabled byte lane (X writes glyph rows with `sth`); otherwise 4 bytes, honouring the byte enables |
| BINC data | 0x1005C0/0x100600/0x100604 (+x), 0x100620 (+y), 0x100640 (-y), 0x100660 (-x), 0x100680 (+x+y), 0x1006A0 (-x+y), 0x1006C0 (+x-y), 0x1006E0 (-x-y) | as a CPU store at the BINC destination address (0x1004A0), which then moves by the pixels a word carries (32, 4 or 1) and/or a line (NGLE manual 4) |
| font engine | 0x100AA0 (row counter := 0), 0x1008A0 | two 16-pixel rows a word (bits 31:16 row n, 15:0 row n+1) at DST + n, rows >= LEN h dropped; after the last row DST x += LEN w (review 09 2.3) |
| vector | 0x100E44 (end included), 0x100E04 (end excluded): from DST to the written point, DST := it; 0x100C40: the written point alone (DST := it); 0x100CCC (`sth`, count in bits 31:16) outside a dashed vector: count pixels from DST with the terms in LEN (signed dx, dy) and SRC (bits 31:16 = \|dy\| - \|dx\|, its sign the major axis; 15:0 = the error term), X's clipped lines; dashed: 0x100ECC (first dash count) from DST to LEN, 0x10080C (count) + 0x100EC4 (vertex, DST := it) for polylines, then one 0x100CCC per further dash until a DST write | one one-pixel span per pixel (`E_LSET` the terms, `E_LINE` the pixels), stepped as X's `ngleBiffVectorEmulator` (09 5.4): plot; if e >= 0 the minor axis moves and e -= dec, else e += inc; the major axis moves. To an end point e = 2*minor - major, inc = 2*minor, dec = 2*(major - minor); from the terms e = SRC[15:0], dec = 2\|SRC[31:16]\|; e less 1 when the minor axis steps forward (x-major: dy >= 0, y-major: dx >= 0). Colour bit TRANSFER_DATA[31] at the start, flipped by each further dash -> FG/BG |

and every pixel then goes through: enable (in the span; BINC mask 0x118024
when IBO bit 29, for the CPU/BINC kinds; not a 0-bit when the background is
transparent, IBO bit 28 or 1), the raster op (IBO[11:8], all 16 X11 codes:
`out = rop[{~s, ~d}]`) and the plane mask (`d' = d & ~pm | out & pm`).

Per row: if the operation needs the destination (plane mask not 0xFF, or a
raster op that reads it) the row's words are read into line buffer DB; a
block move first reads the source row's words into SB; then a pipeline
reads DB[k] and SB[k + (s >= 0)] (keeping the previous SB word, so each
destination word sees a source word pair shifted by `s = (sx - dx) mod 8`
bytes), computes the destination word and its byte enables, pushes it into
an 8-deep FIFO, and the FIFO drains into write bursts of up to 64 words.
Whole rows are buffered, so a move within the same rows works in either
direction; a move down goes bottom-up. Spans and rectangles are clipped to
the 2048 x 1024 VRAM.

CPU loads from the window (SRC_BM_ACCESS, 0x118008) read the words under
pixels x..x+3 (or x..x+31) into registers and return 4 bytes (pixel x in
bits 31:24) or, in the bitmap modes, 32 bits `OR(pixel AND plane mask)`
(the ROM's VRAM probe, 08 0.3) -- or, when SRC_BM_ACCESS's J field (bits
20:16) is non-zero, bit J of each pixel (X's CopyPlane, 09 5.2; the same
rule recolours block moves). Buffer 15 reads return the staging entry.

Timing: G_DEC only decides and captures an operation's operands; its
set-up (clipping, coordinates) happens the next cycle in `E_LAUNCH`.

Address decode in the window (08 1.4): BA field A = 3 is byte addressing
(`x = off[10:2] << 2`, `y = off[20:11]`; the GSC address is word-aligned
and the byte enables select the pixels), every other A one word per pixel
position (`x = off[12:2]`, `y = off[23:13]`).

Ordering (08 2.7): a GSC access to the window, a write to 0x100400-0x100FFF,
0x118000-0x11803F or 0x300118 waits while an operation runs (the MIOC's GSC
timeout is 4M cycles for Artist, 1023 for everything else); register reads
and the status/video registers are never held. A write is acknowledged when
its operation starts, a read when its data is there.

A fill moves DSTXY's y down by the fill's height while 0x100080 holds
0x7D (QEMU's rule from HP-UX's X server; the NGLE manual says HCRX and the
PCI EG always do).

## 4. Colour maps, attribute plane and display

Writes through BA buffer 15 (CPU: `FB + 4i` in mode 0x3BA0F000; BINC: Linux's
0xBBE0F000) store 0x00RRGGBB into a 512-entry staging line at x; a write to
0x300118 with bit 31 copies `ctl[9:0]` entries (0 = 512) from staging x =
BINC source (0x100480) bits 12:2 to LUT entries from `ctl[25:16]` on (08 3.1):
entries 0-255 are LUT0, 256-511 LUT1. Both are kept by the display
(`artist_video`) and go out on `pal_*` (9-bit address) for the board tools'
copy (`HP9K715.sv`, DDR3 0x3320_0000) and romsim's `--fbshot`.

The LUT blt's type field (ctl[15:14], NGLE manual 5): 0 = the colour maps,
2 = the cursor colours (four entries; 3 colours image pixels, 2 mask-only
ones), 1 and 3 are dropped. Bit 30 (wait for vertical blank) is ignored:
the copy is done at once.

**Attribute plane** (buffer 13; review 09 4.2): one bit a pixel, LUT0 or
LUT1, in DDR3 beside the VRAM (`vr_addr[18]` = 1: doubleword {y, x[10:6]},
pixel x in bit x[5:0]; 0x3340_0000 on the board). Written only by
rectangle fills with CONTROL_PLANE != 0 and DST buffer 13 -- X's
`nglePolyPaintAttr` (0x01000102 = LUT1, 0x102 = LUT0), Linux's
`SETUP_ATTR_ACCESS` (0x102 everywhere): the pixels' bit := CONTROL_PLANE bit
24 (`K_ATTR`: 64 pixels a word, edge words read first). Cleared to LUT0
after every reset (DDR3 holds junk at power-up; the ROM loads both LUTs
alike and never paints it). Moves, CPU reads and writes of buffer 13 are
not done (S-023).

### 4.1 The display (`rtl/artist/artist_video.sv`)

Artist makes the picture, as the 715's RAMDAC does, and it is the core's
video (`HP9K715.sv` VGA_*, CE_PIXEL = 1 on clk_sys; the OSD "Display"
picks it or the serial console): one pixel a clock at 64 MHz, the active
size from the timing registers (`hactive` = 4 * ((MISC_VIDEO[3:0] << 8 |
0x300200[31:24]) + 1), `vactive` = (MISC_VIDEO[11:8] << 8 |
0x300208[31:24]) + 1, at most 2048 x 1024, taken at a frame's start), fixed
blanking of 16 + 32 + 48 clocks and 3 + 4 + 9 lines: 1280 x 1024 at 44.7 Hz,
1024 x 768 at 72.9 Hz. The MiSTer scaler converts that to the HDMI mode
(the ini section `[HP9K715]` video_mode=8, vscale_mode=1 shows 1024 lines
1:1 on 1080p). `video_on` = MISC_VIDEO bits 27 and 25 (black while clear).

While line n is shown, line n + 1's VRAM words (hactive / 8) and attribute
words (hactive / 64) are fetched into the other half of two line buffers
(`rf_*`: bursts of up to 64, one at a time, a separate client of the DDR3
port, above the engine's VRAM bursts); a line not complete when its turn
comes sets the sticky `vid_underrun`. Pixel pipeline: line-buffer reads ->
the pixel byte and its attribute bit address the 512-entry LUT -> the
cursor's bit overrides it -> outputs (3 clocks).

**The hardware cursor**: a 64 x 64 sprite, the image in buffer 6, the mask
in buffer 7, written through the window or BINC in an Otc32 mode, 32 pixels
per word (x 0 or 32 of a row; pixel x in bit 63-x of the row). Enabled by
CURSOR_CTRL (0x300104) bit 7 while the video is on; the position as HP-UX's
X server computes it (review 09 3.4): x = 4 * POS[31:19] + POS[17:16] + 16
- 4 * (0x300200[23:16] + 0x300200[15:8] + 2), the first screen row shown =
vactive - 1 - POS[15:0], showing sprite row CTRL[5:0] (the rows cut off at
the top). Mask 0 = transparent, else image ? cursor colour 3 : colour 2
(RGB straight from the LUT blt type 2). The display reads the sprite row a
line ahead (`c_row` -> `c_img`/`c_msk`, Artist's bitmap RAMs); nothing of
it is ever in the VRAM.

Video registers are storage that reads back exactly (MISC_VIDEO, 08 3.3).
The self_test signature 0x30023C returns the constant for the current width
(S-023); 0x300238's busy bits read 0.

## 5. Tests

* `make -C verilator tb_artist` (`verilator/tb/tb_artist.cpp`): the module
  alone against a C++ reference model of section 3, the VRAM compared after
  every operation: decode and bus errors, 0x380004's reset, MISC_VIDEO,
  the signature, byte merges, the ROM's VRAM probe, byte-mode stores and
  loads, fills (full screen, plane mask 7, xor, clipped, CONTROL_PLANE),
  moves in every overlap direction incl. a 1280 x 1008 scroll in the text
  planes, an xor move, the colour-change move, BINC glyphs (narrow and
  wide), transparent bitmaps, both CPU read kinds, both LUT-load styles,
  `sth` glyph rows, the font engine, vectors (whole, clipped -- each must
  draw the tail of the whole line --, dashed segments, a double dash, a
  dashed polyline, points), J-plane moves, the attribute plane (cleared
  after reset from junk, LUT1 and LUT0 paints incl. a 1-pixel-wide one).
  The display is served by its own fetch model (random latency and gaps)
  and checked a whole frame at a time from its video outputs against
  LUT[attribute][pixel] with the cursor laid over: without a cursor, at
  100,200, over a fill drawn under it (the VRAM never sees the cursor), off
  the left edge, clipped right and below, 10 rows cut off at the top,
  switched off; no underruns.
* romsim (`verilator/romsim`): `--arttrace` prints every operation,
  `--fbshot CYCLE FILE` / `--fbshot-end FILE` write the screen (active area
  through LUT0/LUT1 by the attribute plane, no cursor) as a PPM; sim.v
  serves the display's fetch port from its VRAM and attribute arrays.
* Board: `tools/mister/board.sh vram` renders DDR3's VRAM, LUT copy and
  attribute plane; `tools/mister/obs_shot.py` takes the real HDMI output
  through the user's OBS (obs-websocket v5, 192.168.99.82:4455).
