# HP-UX 10.20's X server on Artist — register-level use

Review 09 (2026-10-09). What HP-UX 10.20's X server (X11R6, build of
1999-09-12, `/usr/lib/X11/Xserver`) does to the 715's built-in Artist, read
from the server's screen modules, and what that means for
`rtl/artist/artist.sv`. Builds on `08-artist-registers.md` ("08"), whose
section 6.3 listed what X was expected to need (partly guessed from QEMU).
Prompted by the X login on our model drawing its proportional italic text
with overlapping glyphs.

Sources: the modules extracted from `disks/hpux1020.img` into the session
scratchpad (`hpux/Xserver/modules/screens/hp/{cg,crxutils,ucrx,crx,utils,advutils}.1`,
brokers in `hpux/Xserver/brokers/screens/`), HP's driver notes
(`hpux/Xserver/info/screens/hp`, section 5), the unofficial NGLE manual
(NetBSD `ngle_manual.txt`), QEMU 11.1.1 `hw/display/artist.c`.

Method: `tools/hpux/som.py` reads these SOM shared libraries unchanged; a
small wrapper in the scratchpad (`xan/shsom.py`) drops the UNSAT and
placeholder (0xfffffffc) symbols from the label index, so that labels inside
functions are real, and names import stubs `stub:NAME`. Whole-module
listings are in the scratchpad (`xan/*.dis`).

Evidence tags:

* **[X]** verified in the X server's code, `module:address` (the shared
  library's own text addresses, as `som.py` prints them). objdump prints
  `bb` bit numbers and all displacements/immediates in hex, `extrw/depw`
  positions in decimal (as in 08);
* **[Xd]** a table in the module's data, dumped;
* **[Q]** QEMU; **[M]** NGLE manual; **[R]** our RTL; **[I]** inference.

**Offsets.** The server keeps two pointers per screen: `pScreenPriv+0xBF4`
= the register window = **region 2 (0xF8100000)**, `+0xBF8` = the
frame-buffer window (0xF9000000) [X `ucrx:0xb8c8` writes the cursor at
`bf4+0x200100`, `cg:0x9380` reads MISC_VIDEO at `bf4+0x200218`]. So every
displacement in X's code is the NGLE-manual/Linux offset; **this document
gives our HPA-relative offsets** (X's `0x620` = our 0x100620, X's `0x18004`
= our 0x118004, X's `0x200100` = our 0x300100). Region 3 (0xF8380000) is
never touched [X: no `addil 0x280000` in any module].

---------------------------------------------------------------------------

## 0. Headline facts

1. **The Artist is driven by the "Color Graphics" broker, `cg.1`, not
   `crx.1`.** `CgGetScreenBid` bids on STI id 0x2B4DED6D (Artist)
   [X `Cg.1:0x1ae0-0x1b0c`]; `CrxGetScreenBid` bids on Tomcat, Timber,
   0x26D1488C and CRX only [X `Crx.1:0x1acc-0x1af0`]. Cg's module list is
   `mi.1 mfb.1 advutils.1 utils.1 crxutils.1 ucrx.1 cg.1` (`cgScreenInit`);
   all drawing is in `crxutils.1` (ngle*) and `ucrx.1` (ucrx*). The HP notes
   call it "Integrated Color Graphics" (section 5: PseudoColor and TrueColor
   depth-8 visuals, two hardware LUTs, Color Recovery).
2. **Small text uses a font engine, not BINC.** `cgInitMiscConfig` sets the
   device flags to 0x804 or 0x884 [X `cg:0x8b40/0x8b54`]; bit 2 makes
   `PolyText`/`ImageText` send every font whose ink box is at most 16 wide
   and 32 tall through **FONT_WRITE_START 0x100AA0 / FONT_WRITE_INCR_Y
   0x1008A0** (two 16-pixel rows per word, hardware x advance). Our RTL does
   not decode these ports: such text is not drawn at all.
3. **Larger text uses BINC with halfword stores.** `ngleDrawVisibleGlyphs`
   writes glyph columns of at most 16 pixels with **`sth` to 0x100620**
   [X `crxutils:0x1fe68`, `0x1f3f0`]. The CPU puts a halfword on both bus
   halves (`rtl/cpu/pa_ldst.sv:71-73`, `pa_core.sv:795`) with byte enables
   1100, and our Otc32 write path ignores the byte enables
   (`artist.sv:311-315`), so every such strip is drawn a second time
   16 pixels to the right. **This is the overlapping-glyph bug** (section 2.5).
4. The BINC destination of a glyph is **pixel-exact**: `0x30000000 |
   (y - ascent) << 13 | (x + lsb) << 2` (AddrLong; bits above 23 ignored);
   the glyph row is **left-aligned at bit 31** (no shift by x mod 32); the
   unclipped paths do **not** use the BINC mask (IBO 0x13000302: bit 29
   clear, background transparent) [X `crxutils:0x1fab0-0x1fac4`,
   `0x1fdd0-0x1fe48`].
5. **Cursor**: CURSOR_CTRL 0x300104 = `0x80 | yoff` (bit 7 enable, bits 5:0
   = rows clipped off the top, 0..63), CURSOR_POS 0x300100 = `xhi<<19 |
   xlo<<16 | (vactive-1-y)`; bitmaps through BINC into buffers 7 (mask) and
   6 (image); colours by a LUT blt of type 2 (0x80008004), entry 2 =
   background, 3 = foreground. QEMU's (and our) reading of CTRL bits 7:4 /
   3:0 as hotspot offsets is wrong; ours is one pixel left and one row low
   (section 3).
6. **Fills take their colour from TRANSFER_DATA**: the server clears the
   screen with IBO 0x03000300, FG = 0 and BG never written
   [X `crxutils:0x1daa4-0x1db54`], and draws opaque stipples with IBO bit 1
   clear, FG and BG set and a per-row pattern in TRANSFER_DATA through
   **0x100A20** (TRANSFER_DATA + start fill). QEMU's "IBO bit 1 ? FG : BG"
   rule (ours) is wrong for both. 0x100080 = 0x7D *and* 0x08 make a fill
   advance DST y (section 5.1).
7. **Lines** use 0x100E44 (to an end point, inclusive), 0x100E04 (exclusive,
   polyline vertices; DST becomes the end point) and the parametric form
   0x100804/0x100808 + `sth` 0x100CCC; none is decoded by our RTL.
8. **LUT1 and the attribute planes are used**: the default colormap lives
   in LUT0 and the attribute planes are reset to 0x102 (= LUT0); every other
   installed colormap goes to LUT1 (LUT offset 0x100) and its windows get
   attribute 0x01000102 painted into buffer 13 [X `cg:0x53b4-0x53e8`,
   `crxutils:0xa818-0xa96c`]. Our RTL drops both.
9. The server never polls vertical blank on Artist (the MISC_VIDEO bit 18
   loops are in the non-Artist branches only) and checks **0x300004 bit 25**
   (byte read of 0x300004, bit 1) as a FIFO-overflow flag
   [X `crxutils:0x1e544-0x1e564`] — it must read 0.

---------------------------------------------------------------------------

## 1. Driver structure

### 1.1 Device flags (`pScreenPriv+0xE28`)

Zeroed by `ngleScreenInit` [X `crxutils:0x1cb8c`], then set by the
device's misc-config callback: Artist 0x804, or 0x884 when no gamma table is
configured [X `cg:0x8b40`, `0x8b54`]. Bits tested on the paths that matter:

| Bit | Test | Meaning (from its uses) | Artist |
|---|---|---|---|
| 2 (0x4) | `bb ...,1d` | font engine present: small fonts go to FONT_WRITE [X `crxutils:0x3b304`] | 1 |
| 3 (0x8) | `bb ...,1c` | HCRX: LUT blt at 0x210020, 2 cursor colours [X `crxutils:0x1081c`, `0x10980`] | 0 |
| 4 (0x10) | `bb ...,1b` | HCRX fast fill 0x100944 for attribute fills [X `crxutils:0xa838`] | 0 |
| 0 | `cmpb,ev` | extra state on lock regain [X `crxutils:0x1e238`] | 0 |

### 1.2 Precomputed BA / IBO tables

`ucrxSetupPrecomputedRegisters` [X `ucrx:0x7880-0x7bd8`] builds six tables
of ten (DBA, IBO) pairs, indexed by a drawable's buffer index, and stores
them at `pScreenPriv+0xDE0..0xDF4`. Each drawing routine ORs the raster op
into IBO bits 11:8. Entries 0, 1, 6, 7 (the 8-bit buffers 0, 1, 2) are:

| Table | Used for | DBA (buffer b) | IBO |
|---|---|---|---|
| A `+0xDE0` | opaque bitmap expansion (CopyPlane, opaque stipple) | 0x2EA0b000 (Otc32, indirect, AddrLong) | 0x23000000 |
| B `+0xDE4` | solid fills, transparent stipple, ImageText background, font engine | 0x2EA0b000 | 0x23000002 |
| C `+0xDE8` | (not traced) | 0x06A0b000 | 0x03000000 |
| D `+0xDEC` | (not traced) | 0x06A0b000 | 0x03000002 |
| E `+0xDF0` | copies, pixmap uploads, reads | 0x13A0b000 (Otc04, Ots08, AddrLong) | 0x23000000 |
| F `+0xDF4` | direct CPU access | 0x1360b000 (byte addressed) | 0x83000000 |

Entries 2-5, 8, 9 are 24-bit/overlay buffers 8-0xB (some with BA bit 31,
FractDcd) and BitmapExtent 4/5 — other NGLE boards. On Artist all image
buffer numbers alias one 8-bit frame buffer (08 0.1); the screen clear uses
buffer 0 [X `crxutils:0x1db48`].

---------------------------------------------------------------------------

## 2. Text and glyphs

### 2.1 Which routine draws a string

`ngleSolidNoBitclip_PolyText` and `..._ImageText` choose per call
[X `crxutils:0x3b288-0x3b49c` (PolyText), `0x3a8e8-0x3ab74` (ImageText)].
The font tests use FontInfo `maxbounds` (+0x14) and `minbounds` (+0x20):

| Condition | Routine | Hardware path |
|---|---|---|
| terminal font, glyph width ≤ 16 | `ngleDrawVisibleTerminalGlyphs` | BINC: several glyphs packed into one **word** per row, `stw` 0x100620 [X `crxutils:0x22c74`, `0x22d60`] |
| flags bit 2, box ≤ 16 x 32, min width ≥ 0, constant metrics | `ngleDrawFastVisibleConstantSmallGlyphs` | font engine |
| flags bit 2, box ≤ 16 x 32, min width ≥ 0 | `ngleDrawFastVisibleSmallGlyphs` | font engine |
| flags bit 2 clear, box ≤ 16 x 32 | `ngleDrawVisibleSmallGlyphs` | BINC, `sth` 0x100620 — **never on Artist** |
| otherwise (box > 16 wide or > 32 tall) | `ngleDrawVisibleGlyphs` | BINC, `sth`/`stw` 0x100620 |
| clipped (not wholly visible) | `ngleDrawClippedGlyphs`, `ngleDrawClippedTerminalGlyphs` | BINC + BINC mask, `sth`/`stw` |

("box" = `maxbounds.rsb - minbounds.lsb` by `maxbounds.ascent +
maxbounds.descent`.) The X login's large italic greeting is in the
`ngleDrawVisibleGlyphs` class; its smaller labels in the font-engine class.

Glyph bitmaps (the font's `CharInfo.bits`) are MSB-first, left-aligned,
rows padded to **2 bytes** when the ink width is ≤ 16 and to 4 bytes when
it is 17..32 [X `crxutils:0x1fe70` `ldo 2(r3)`, `0x1fee0` `ldo 4(r3)`].

### 2.2 `ngleDrawVisibleGlyphs` (BINC) [X `crxutils:0x1f308-0x1ff50`]

Set-up, once per call:

* wait for idle (word read of 0x300000 until bit 24 clear,
  [X `0x1fdb4-0x1fdc4`]), FIFO slots (0x300008 ≥ 5);
* IBO 0x11801C = `0x13000002 | rop << 8` — **0x13000302** for GXcopy:
  bit 28 and bit 1 (background transparent), bit 29 clear (no BINC mask),
  BitmapExtent 3 [X `0x1faac-0x1fac4`];
* DBA 0x118004 = `0x2EA0b000` (Otc32, indirect, AddrLong, the window's
  buffer) [X `0x1fd00`, `0x1fce8`];
* FG 0x118010 = GC foreground, PLANE_MASK 0x118018 = GC plane mask.

ImageText first fills the background box: table B DBA, IBO `0x23000002 |
0x300` = 0x23000302, FG = GC background, TRANSFER_DATA 0x100820 =
0xFFFFFFFF, DSTXY 0x100800 = `x1<<16 | y1`, 0x100A04 = `w<<16 | h`
[X `0x1f648-0x1f96c`].

Per glyph [X `0x1fdd4-0x1fef0`], with `w = rsb - lsb`, `h = ascent +
descent`, baseline (x, y):

* BINC_DST 0x1004A0 = `0x30000000 + ((y - ascent) << 13 | (x + lsb) << 2)`
  [X `0x1fdd0` (`depwi,z 3,3,2` = 0x30000000), `0x1fe2c-0x1fe48`]. x is not
  aligned to anything;
* `w ≤ 16`: per row `ldh` from the glyph, **`sth` to 0x100620** (bits 31:16
  of the bus word, byte enables 1100) [X `0x1fe60-0x1fe70`];
* `16 < w ≤ 32`: per row a full word, `stw` to 0x100620 (two `ldh` merged
  when the bitmap is only 2-byte aligned) [X `0x1fed0-0x1fed8`,
  `0x1ff2c-0x1ff40`];
* `w > 32`: in 16-pixel columns: BINC_DST as above, then `+0x40` (16 pixels
  in AddrLong) per column; per row `sth` to 0x100620
  [X `0x1f37c-0x1f3fc`].

x advances by `characterWidth` in software. No write to 0x1005A0; the
pixels beyond the ink width are zero bits of the bitmap, left undrawn by
the transparent background.

### 2.3 The font engine [X `crxutils:0x21cbc-0x223f8`; constant-metrics variant `0x22414-0x22aa4`]

Set-up: DBA and IBO from table B (`0x2EA0b000`, `0x23000002 | rop<<8` =
0x23000302: bit 29 set, background transparent) [X `0x22098-0x220c4`], FG,
PLANE_MASK, **0x100080 = 0** [X `0x2218c`, `0x22198`].

Per glyph (`w = rsb - lsb` ≤ 16, `h = ascent + descent`):

| Write | When | Value |
|---|---|---|
| `sth` 0x100800 (DST x) | lsb or width differs from the previous glyph, or the previous glyph had h = 0 | `x + lsb` [X `0x221f4`] |
| `sth` 0x100804 (LEN w) | same | **characterWidth** (the advance) [X `0x22200`] |
| `sth` 0x100802 (DST y) | ascent or descent changed | `y - ascent` [X `0x22248`] |
| `sth` 0x100806 (LEN h) | same | `h` [X `0x22260`] |
| 0x1005A0 (BINC mask) | w changed | `0xFFFF0000 >> (16 - w)` [X `0x222a0-0x222b4`] |
| 0x100AA0 | always | first data word = rows 0 (bits 31:16) and 1 (bits 15:0) [X `0x222e0`] |
| 0x1008A0 | `ceil(h/2) - 1` times | rows 2k, 2k+1 [X `0x22304-0x223b4`, a jump table on h] |

Glyphs with h ≤ 0 or characterWidth ≤ 0 write nothing [X `0x222b8`,
`0x222bc`]. What the hardware must therefore do (agrees with QEMU's
`font_write`, `artist.c:689-733`):

* 0x100AA0 resets a row counter, then each of 0x100AA0/0x1008A0 draws
  bits 31:16 as row `n` and bits 15:0 as row `n+1` at `DST.x .. DST.x+15`,
  `DST.y + n`; pixel i = bit 15-i of the half; 1-bits in FG, 0-bits not
  drawn when IBO bit 1/28 is set (always, in X);
* rows at or beyond LEN h are dropped (for odd h the last word carries the
  next glyph's data);
* after the last row **DST.x += LEN w**; DST.y is unchanged. The software
  relies on both: it rewrites DST x only when lsb changes, and DST y only
  when the metrics change.
* The BINC mask value is `0xFFFF0000 >> (16 - w)`, e.g. 0x00FFFF00 for an
  8-wide glyph: as a "bit 31-i enables pixel i" mask it would cut the left
  half of the glyph, so either the font engine ignores the mask or it uses
  it in a way not visible here. QEMU ignores it. **Recommendation: do not
  apply the BINC mask to font-engine rows** (with transparent backgrounds,
  the only kind X uses here, the result is exact). Open question.

`ngleSolid_PolyArc` also draws small arcs through this engine, with the
mask = top w bits [X `crxutils:0x2fd00-0x2ff1c`].

### 2.4 Clipped and terminal glyphs

* `ngleDrawClippedGlyphs` [X `crxutils:0x1ff6c-0x20fb8`]: IBO from table
  B (bit 29 set), BINC mask 0x1005A0 = `0xFFFFFFFF >> leftclip` ANDed with
  `~0 << rightclip`, relative to the glyph's x (mask bit 31-i = pixel i)
  [X `0x20c84-0x20cf8`]; rows by `sth` (w ≤ 16) or `stw` 0x100620
  [X `0x20d18`, `0x20dcc`].
* Terminal fonts: glyphs shifted and ORed into one word per row and written
  with `stw` 0x100620, BINC_DST per group [X `crxutils:0x22c60-0x22d60`].

### 2.5 What the hardware must do, and the overlapping-glyph bug

1. **A sub-word store to a BINC data port (or to the window) in an Otc32
   mode carries 8 pixels per enabled byte lane**: pixel i (0..31) is written
   only if byte enable `be[3 - i/8]` is set. A halfword store at 0x100620
   is a 16-pixel transfer; the row still advances. (QEMU narrows the
   transfer to `size*8` pixels, `artist.c:779-800`.)
2. BINC_DST x is pixel-exact; pixel i of the data word = bit 31-i.
3. 0-bits are left alone when IBO bit 1 or 28 is set.

Our RTL does 2 and 3 but not 1: `K_BITS` takes all 32 bits of `wdata`
(`artist.sv:311-315`; STUBS S-023 lists it: "sub-word stores in the bitmap
modes act as word stores"). Our CPU drives a halfword store as
`{2{halfword}}` on the bus (`pa_ldst.sv:71-73`, uncached path
`pa_core.sv:795`), so each `sth` of a glyph row draws the row at x and
again at x+16. In `ngleDrawVisibleGlyphs` that gives a ghost copy of every
glyph narrower than 17 pixels 16 pixels to its right, and smears each
16-pixel column of glyphs wider than 32 onto the next column — overlapping
letters in exactly the large proportional fonts the X login uses. Glyphs
17..32 wide (`stw`) come out right, which matches a "some letters doubled"
look. The same `sth` 0x100620 pattern is in the clipped-glyph path and in
the arc code (`cg:cgSolid_PolyFillArc`, `crxutils:ngleSolid_PolyFillArc`),
so arcs get ghosts too.

---------------------------------------------------------------------------

## 3. Hardware cursor (`ucrx.1`)

### 3.1 Constants

`ucrxGetDeviceRomData` hard-codes, for Artist, **cursor pipeline delay 4
and video interleave 4** [X `ucrx:0x13f0c-0x13f28`] (other NGLE boards read
them from the STI ROM's NGLE data). `ucrxInitSprite` reads [X
`ucrx:0xa7a4-0xa810`], as **byte loads**:

* `hbp = (int8)[0x300201] + (int8)[0x300202] + 2` (reg19 bits 23:16 +
  15:8 + 2; non-Artist boards use bits 23:16 alone);
* `vtop = ([0x30021A] & 0xF) << 8 | [0x300208]` = MISC_VIDEO[11:8]:reg20[31:24]
  = **vactive - 1**.

### 3.2 Initialisation [X `ucrx:0xa834-0xa8d8`]

PLANE_MASK = 0xFFFFFFFF, IBO = 0x300; for buffer 7 then 6: DBA =
`0x28A00000 | b<<12` (Otc32, Ots 0, AddrLong), BINC_DST = 0, 64 times
{0x100600 = 0, 0x1006A0 = 0} — the 64 x 64 bitmaps cleared, two words a row
(0x600: x += 32; 0x6A0: x -= 32, y += 1).

### 3.3 Loading a cursor (`ucrxDisplayCursor`, [X `ucrx:0xab98-0xb4ec`])

1. If shown, disable (3.5).
2. Unless the same cursor is already loaded: IBO 0x300, PLANE_MASK ~0,
   then buffer **7 = mask** (`CursorBits.mask`), buffer **6 = source**
   [X `0xaf90-0xafb8`]: DBA `0x28A07000` / `0x28A06000`, BINC_DST 0, and per
   row:
   * width ≤ 32 (previous cursor also ≤ 32): one word to **0x100620**
     (y += 1), masked to the top w bits [X `0xb050-0xb078`];
   * width > 32 (or previous > 32): left word to **0x100600**, right word
     (masked to the top w-32 bits) to **0x1006A0** [X `0xad90-0xadbc`];
   * then `64 - h` zero rows. Bitmap rows are 4 bytes (w ≤ 32) or 8 bytes.
3. Colours (`ngleLoadCursorColormap`, [X `crxutils:0x107c0-0x10aec`]): FIFO
   ≥ 3; BA (0x118000) = **0xBBE0F000** (FractDcd, Otc01, Ots08, Addr24,
   buffer 15), IBO = 0x03000300, PLANE_MASK = ~0; BINC_DST = 0;
   0x100600 = 0 twice (entries 0, 1 — skipped on HCRX); **0x100600 =
   background** RGB (entry 2), **0x1005C0 = foreground** RGB (entry 3);
   each `0x00RRGGBB` from the 16-bit X colour's high bytes (or a grey
   from 0.3R+0.59G+0.11B on greyscale, or through a gamma table);
   BINC_SRC 0x100480 = 0; **0x300118 = 0x80008004** (enable, type 2 =
   cursor, offset 0, length 4; no wait-for-blank).
4. Position and enable as in 3.4/3.5 [X `ucrx:0xb304-0xb348`].

### 3.4 Position (`ucrxMoveSprite`, [X `ucrx:0xb7f0-0xb8e0`])

```
x' = x - xhot,  y' = y - yhot          (sprite's top-left on the screen)
yoff = 0;  if (y' < 0) { yoff = -y'; y' = 0; }
t    = x' + hbp * 4                     (unsigned)
xhi  = t / 4 - 4                        (pipeline delay)
xlo  = t % 4
CURSOR_POS  0x300100 = xhi << 19 | xlo << 16 | (vtop - y')
CURSOR_CTRL 0x300104 = 0x80 | yoff
```

FIFO ≥ 2 before the two writes; no vblank wait on Artist (the
`HPGCRX_MOVE_CURSOR_ON_VBLANK` loop on MISC_VIDEO bit 18 is in the
non-Artist branch only, [X `0xb8ec-0xb944`]). The inverse the display
needs:

```
x' = 4 * xhi + xlo + 16 - 4 * hbp
top row on screen = (vactive - 1) - POS[15:0]; sprite row r is at that + r - CTRL[5:0]
```

e.g. 1280x1024 at 72 Hz (reg19 0x3F2F2F0F): hbp = 96, `x' = 4*xhi + xlo -
368`. Negative x needs no special case (the position counts from the
horizontal back porch); only the top edge uses CTRL. QEMU
(`artist.c:316-362`) computes `x' - 1` (its `+ 8 - 1` and subtraction of
CTRL bits 7:4, which are 8 when enabled) and `y' + 1 - (CTRL & 0xF)`.

### 3.5 Enable / disable

* **Enable = CURSOR_CTRL bit 7.** Disable writes CURSOR_CTRL = `(saved
  position) & 0x3F` — any value with bit 7 clear [X `ucrx:0xaa44-0xaa70`].
  CURSOR_POS bit 31 is not an enable on Artist (it is on EG/HCRX, [M]).
* Non-Artist boards write 0x100420 = 0 twice and wait for idle before
  touching the cursor; Artist does not.
* Optional `HP_CURSOR_POSITION_TRACKING`: the position words are also
  written to the frame buffer at (1536, 1000) / (1568, 1000) with DBA
  0x28A72000 [X `ucrx:0xb9ac-0xb9f0`] — off by default.

Pixel rule (X11, [I]): mask 0 = transparent, mask 1 = source ? entry 3
(foreground) : entry 2 (background).

---------------------------------------------------------------------------

## 4. Colour maps and attribute planes

### 4.1 Loading a LUT

`ucrxInstallColormap` [X `ucrx:0x85fc-0x8800`] and `ucrxStoreColors`
[X `ucrx:0x9688-0x98a8`]:

1. busy wait, then BA (0x118000) = **0xBBE0F000**, IBO = 0x03000300,
   PLANE_MASK = ~0;
2. BINC_DST = `(stagingBase + first) << 2`, then one 0x100600 write per
   entry (`0x00RRGGBB`) — 256 for an install, 1 for a single StoreColors;
   staging bases seen: 0 and 0x100 [X `ucrx:0x8058`];
3. BINC_SRC 0x100480 = the same staging address;
4. `ucrxSetLutBltCtl` [X `ucrx:0xa4ac-0xa4f0`] builds, for Artist,
   **`0xC0000000 | ((lut * 256 + first) & 0x7FF) << 16 | count`** — enable,
   **wait-for-blank (bit 30)**, type 0;
5. MISC_CTRL 0x300308 bit `lut` set or cleared (set for colormaps flagged
   for Color Recovery [I]) [X `ucrx:0x80b8-0x80d4`, written `0x8210`];
6. byte **0x100089 = 1** (unless the map is the read-only 0xFF one and a
   flag is clear) [X `ucrx:0x8248`, `0x984c`];
7. **0x300118 = ctl** [X `ucrx:0x87f8-0x8800`, `0x98a8`].

### 4.2 Which LUT is displayed

* `cgResetPlanes` → `ngleResetAttrPlanes(0x102)`: the attribute planes of
  the whole screen get **0x102 = LUT0** [X `cg:0x9538`,
  `crxutils:0x1de0c-0x1de34`].
* `cgGetAttributePlaneControlValue` returns **0x00000102** for a window
  whose colormap is in LUT0 and **0x01000102** for LUT1 [X
  `cg:0x53b4-0x53e8`, `0x5430-0x5454`].
* `nglePolyPaintAttr` [X `crxutils:0xa818-0xa96c`]: DBA = **0x2EA0D000**
  (buffer 13 = attributes), **CONTROL_PLANE 0x11800C = value**,
  TRANSFER_DATA = ~0, IBO 0x23000302, then per box 0x100800 + 0x100A04
  fills, then CONTROL_PLANE = 0.
* HP's note: two LUTs, one dedicated to the default colormap, the other
  loaded with whichever other colormap was installed last.

So a pixel's LUT = attribute bit 24 of the value painted under it. With
only the default colormap (the login screen, a plain desktop) everything
is LUT0; any client with its own colormap (or the TrueColor/Color Recovery
visual) is shown through LUT1.

### 4.3 Reading back

`ucrxGieGetLutContents` / `ngleDebugReadHWColormap` set 0x100480 and SBA and
write 0x300118 to read LUT contents back (GIE extension, debugging) — not
traced further.

---------------------------------------------------------------------------

## 5. Fills, copies, pixmap uploads, lines

### 5.1 Rectangle fills

| Routine | 0x100080 | Writes | Relies on |
|---|---|---|---|
| `ucrxSolid_PolyFillRect` [X `ucrx:0x1070c-0x10878`] | 0x7F | table B, FG, PM, TRANSFER ~0; per box 0x100800 + 0x100A04 | — |
| `ucrxSolid_FillSpans` | 0x7F | 0x100800 + `sth` 0x100806 (h = 1) + `sth` 0x100A04 (w) | — |
| `cgSolid_FillPolygon` [X `cg:0x5ea0-0x5eb4`, `0x5840-0x5874`] | **0x7D** | LEN h = 1; per span `sth` 0x100800 (x), `sth` 0x100A04 (w); y written only after an empty span | **DST.y += LEN.h after each fill** |
| `nglePatternIn32_PolyFillRect` [X `crxutils:0x16184-0x16190`, `0x163c4`, `0x16400-0x16468`] | **0x08** | LEN h = 1; per box 0x100800, `sth` 0x100804; per row **0x100A20 = pattern word** | **y += 1 per row**, TRANSFER_DATA as pattern |
| `ngleDepth8_ClearImagePlanes` [X `crxutils:0x1daa4-0x1db54`] | 0x30003 | TRANSFER ~0, **FG = 0, BG not written, IBO 0x03000300**, DBA 0x2EA00000, 0x100800 = 0, 0x100A04 = screen size | colour = FG |
| `ucrxSolid_PolyRectangle` | 0x7F | 0x100A00 (DST + fill), `sth` 0x100A00/0x100A02 | — |
| `cg/ngleSolid_PolyFillArc` | 0x7F / 0x7D | fills + BINC `sth` 0x100620 | as above |

* **0x100A20** = TRANSFER_DATA + start a fill (address pattern 0xA00 |
  register 0x20).
* Pattern fills: the 32-bit pattern is pre-rotated so that bit 31 is the
  first pixel of the rectangle (rotation `(x - patOrg.x) mod patWidth`,
  [X `crxutils:0x16304-0x16398`, `0x163f8-0x16448`]); FillStippled uses
  table B (0-bits transparent), FillOpaqueStippled table A with FG and BG
  [X `crxutils:0x15c98-0x15cbc`].
* So: **pixel colour = TRANSFER_DATA bit `31 - ((px - DST.x) mod 32)` ?
  FG : BG**, 0-bits skipped when IBO bit 1 or 28 is set ([M]: "Set FG for
  plain fills, BG if using a mask in TRANSFER_DATA, set the B bit to make
  the background transparent").
* 0x100080 values: 0x7F, 0x7D, 0x08, 0x00 (fonts, dashed lines, single
  fills), 0x30000 (lines), 0x30003 (clear). Increment observed as needed
  for 0x7D and 0x08; every 0x7F/0x00/0x3000x user rewrites DST before each
  operation. Consistent rule [I]: **after a fill, DST.y += LEN.h when
  0x100080 bit 1 is clear**; safe minimum: for 0x7D and 0x08.

### 5.2 Screen-to-screen copies

`nglePolyBlt` (CopyWindow, CopyArea) [X `crxutils:0x2a2e0-0x2a3ec`]: SBA
0x118008 and DBA from table E (`0x13A0b000`), IBO `0x23000000 | rop<<8`,
PLANE_MASK 0x00FFFFFF; per box DST 0x100800, SRC 0x100808, **0x100B04 =
LENXY + start**; boxes ordered for overlap by the server. Also 0x100808,
0x100804, **0x100B00** (DST + start) in `ngleDepth8_CopyAreaFromToScreen`.

`ngleExpand_CopyOpaquePlaneFromToScreen` (CopyPlane on screen) [X
`crxutils:0x37b1c-0x37b34`]: **SBA = `0x28A00000 | plane << 16 | buf <<
12`** — the BA J field (bits 20:16) names the source bit plane — DBA
indirect (table A or B), then the move. CPU reads of one plane use
BA_both = the same form [X `crxutils:0x35720-0x35738`]. So an Otc32 source
yields **bit J of each pixel**.

### 5.3 Pixmap uploads and reads

* `ucrxDepth8_CopyAreaToScreen` (8-bit pixmap → window, PutImage)
  [X `ucrx:0xd01c-0xd130`]: DBA/IBO from table E (IBO bit 29 set), BINC_DST
  x = `dstx - (srcx & 3)` (any alignment), 4 pixels per word to 0x100600,
  BINC mask 0x1005A0 = `{0, 0x10000000, 0x30000000, 0x70000000}[k]` for a
  first word with k valid pixels and `{0, 0x80000000, 0xC0000000,
  0xE0000000}[k]` for a last word [Xd `ucrx` `DS$ucrxBlt8` +0x10, +0x20;
  the table is reached through a DLT slot, so which data object is an
  inference, but its contents fit the code exactly]:
  **mask bit 31-i = pixel i of the 4** (as QEMU, `vram_bitmask >> 28`).
* `ngleExpand_CopyOpaque/TranBgPlaneToScreen` (depth-1 → window): Otc32
  BINC 0x100600 with edge masks, table A (opaque) or B.
* Reads (`ucrxDepth8_CopyAreaFromScreen`, GetImage) [X `ucrx:0xc22c-0xc23c`]:
  SBA `0x13A0b000`, write 0x100420 twice, wait for idle, word loads from
  the window at `y<<13 | x<<2` = 4 pixels, pixel x in bits 31:24.
* `ngleHpCr24to8Hw` (Color Recovery PutImage) writes 0x118034 and uses DBA
  `0xBBA0b000` (**FractDcd**, Otc01): one 0x00RRGGBB per word, presumably
  dithered to 8 bits by the hardware [X `crxutils:0xe02c-0xe130`] [I].

### 5.4 Lines

`ucrxSolid_PolySegment` [X `ucrx:0xdff0-0xe7a0`], `ucrxSolid_Polylines`
[X `ucrx:0xeb10-0xec94`]: 0x100080 = 0x30000, TRANSFER_DATA = ~0, table B,
FG; then

* unclipped, cap style not CapNotLast: DST 0x100800 = start, **0x100E44 =
  end** (inclusive) [X `ucrx:0xe1dc-0xe1e4`];
* CapNotLast: **0x100E04 = end** (end pixel not drawn) [X `ucrx:0xe57c-0xe584`];
* polylines: DST written once, then **0x100E04 per vertex** with no DST
  write in between [X `ucrx:0xeb10`, `0xeb8c`, `0xec94`] — the hardware
  must leave **DST = the end point** after a line (QEMU's
  `update_start`); the last point by 0x100800 + 0x100E44 to itself
  [X `ucrx:0xf330-0xf334`];
* clipped lines (after `duClipVector`): 0x100800 = clipped start, 0x100804
  and 0x100808 = Bresenham terms (packed deltas and error term), **`sth`
  0x100CCC = pixel count** in bits 31:16 [X `ucrx:0xe3d0-0xe3e4`];
  hard cases fall back to `ngleBiffVectorEmulator` (software).
* Dashed lines (`ngleSolidDashed_*`): 0x100080 = 0, `sth` 0x100CCC and
  0x100ECC (PATTERN_LINE_START), BINC 0x1004A0 — see 5.5.

### 5.5 The vector terms, clipped and dashed lines (traced 2026-10-09, second session)

**Clipped segments** [X `ucrx:0xdcb4-0xdd08`, `0xe240-0xe3e4`]. With
dx = x2 - x1, dy = y2 - y1 (signed), adx/ady their magnitudes, the server
writes:

* 0x100800 = the first pixel inside the clip box `(x << 16) | y`;
* **0x100804 = `(dx << 16) | (dy & 0xFFFF)`** — the signed deltas of the whole
  segment (r12/r13, kept across the call to `duClipVector`);
* **0x100808 = `((ady - adx) << 16) | (e & 0xFFFF)`** — the high half's
  sign gives the major axis (`< 0` x-major; `ady >= adx` is y-major, ties
  included), the low half the error term at the first pixel shown;
* `sth` 0x100CCC = the pixel count.

Both halves are range-checked to ±16383 [X `0xe2bc-0xe2d0`, `0xe30c-0xe320`;
r7 = 0xFFFFC000, r8 = 0x3FFF]; out of range, the same seven values go to
`ngleBiffVectorEmulator` [X `crxutils:0x29394-0x29620`] in a struct
{regs, 0x30000, -1, 1, x, y, dx, dy, ady - adx, e, fifo} with the count —
**the emulator draws what the hardware would**, one point at a time through
**0x100C40** (`stw (x << 16) | y`, after 0x100804 = 0x100808 = 0 and
0x100080 = 0x3003C). Its loop, x-major (y-major mirrored):

```
e  = SRC.lo - (dy >= 0)              y-major: - (dx >= 0)
inc = 2*ady, dec = 2*(adx - ady)     = 2*|SRC.hi|   (y-major: inc = 2*adx)
repeat count:                        (at most adx, then the end point if flag 0xC)
    plot (x, y)
    if e >= 0: y += sy; e -= dec
    else:      e += inc
    x += sx
```

For an unclipped segment the server's value is `e = 2*minor - major`
(`-f8(sp)` = major + bias before the clipper, the bias taken off after it,
then `2*minor - e`), so the hardware's own vectors (0x100E04/E44) are
assumed to start the same way: e = 2*minor - major, less one when the minor
axis steps forward — X11's zero-width-line tie rule for those octants.

**Dashed segments** [X `crxutils:ngleSolidDashed_PolySegment` 0x25778,
`0x26490-0x26930`]: the dash list is walked in software; a two-node ring
{~0, 0} holds the on/off state of the current dash; per segment 0x1004A0 = 0,
**TRANSFER_DATA = ~0 or 0** (the dash the segment starts in), 0x100800 =
start, **0x100804 = the end point**, then **`sth` 0x100ECC = the first
(possibly partial) dash's length** and **one `sth` 0x100CCC per further dash**,
the last cut to what is left of the segment (the server sums the lengths to
the segment's pixel count: `max(adx, ady)` plus one unless CapNotLast). So:
0x100ECC starts a vector from DST to LEN and draws that many pixels with
colour bit TRANSFER_DATA[31]; each 0x100CCC draws the next dash where the
last one stopped with the colour bit flipped (0 -> BG, or nothing with a
transparent IBO: on-off vs double dash). QEMU (`draw_line_pattern_*`)
models the same: its pattern mode is set by 0x100ECC and cleared by a
DST write — which tells it apart from the clipped form above.

**Dashed polylines** [X `ngleSolidDashed_Polylines` 0x27250,
`0x286b4-0x28820`]: per vertex **`sth` 0x10080C = the first dash's length,
then 0x100EC4 = the vertex**, then 0x100CCC per further dash; between
vertices TRANSFER_DATA is rewritten when the next vertex starts in another
dash. 0x100EC4 must leave DST at the vertex (no DST write between vertices).

**The address pattern**, as far as these ports go [I]: `0x100800 | op << 8 |
f << 6 | reg << 2` with reg 0 DST, 1 LEN, 2 SRC, 3 the count (0x10080C),
op 2 fill, 3 move, 4 a vector from the current terms (0xC40, 0xCCC),
6 a vector to an end point (0xE04, 0xE44, 0xEC4, 0xECC), f = 1 the end pixel
included (0x44, 0x40), f = 3 dashed / counted (0xC4, 0xCC).

`render_vector`/`ucrxRendCursor` in `ucrx` (software cursors of other
boards) use 0x100E44 and 0x100CCC too; `ucrxInitSprite`'s 0xCC0-0xCCC
stores go to the screen private (r3 there is `pScreenPriv`), not to Artist.

---------------------------------------------------------------------------

## 6. Everything else the server touches

| What | Where | Detail |
|---|---|---|
| busy | byte load 0x300000 until 0 (cursor, LUT, init paths), or word load until bit 24 clear (glyphs) | e.g. [X `cg:0x9368`, `crxutils:0x1fdc0`]. Bits 31:25 must read 0 |
| FIFO slots 0x300008 | everywhere | waits for ≥ 1..8 |
| **0x300004 byte, bit 1 (bit 25)** | `ngleBlockHandler` [X `crxutils:0x1e544-0x1e564`] | set → `ngleFifoOverflowHandler`; must read 0 |
| 0x100420 = 0, twice | before cursor/LUT/init/blank on all NGLE; Artist: `cgInitMiscHardware`, blank, install, CopyAreaFromScreen | HCRX "video bus" (08/[M]); ignore |
| init | `cgInitMiscHardware` [X `cg:0x9340-0x9408`] | reads MISC_VIDEO and MISC_CTRL; index = MISC_VIDEO[15:12]:[7:6]; writes **0x300200, 0x300208** from the server's own 13-entry timing table [Xd `cg` 0x40001f74 + 12·idx] — the same reg19/reg20 values as the ROM's records (08 3.4; MISC_VIDEO bit 29 differs in entries 8 and 9), so the active size we derive does not change; **MISC_VIDEO = (old & 0x00FFF0F0) \| (table & 0xFF000F0F) \| 0x01000000**, bit 28 clear; **byte 0x100088 = 0x35**; **MISC_CTRL &= ~3** |
| blank / DPMS | `cgBlankOrUnblankScreen` [X `cg:0x96e0-0x9a74`, `0x9870-0x9bac`] | blank: cursor off, MISC_VIDEO &= ~0x0A000000, **MISC_CTRL &= ~0x00800000**; standby/suspend/off also overwrite bytes of 0x300200/0x300208 (0xFF, 0x45, ...) to stop the syncs; unblank restores MISC_VIDEO bits 27/25, MISC_CTRL bit 23 and the saved timing bytes |
| MISC_CTRL bits 1:0 | LUT install | per-LUT flag (Color Recovery [I]) |
| byte 0x100089 = 1 | before every LUT blt | unknown; ROM's 0x100088 = 0x00010000 sets the same byte |
| vertical blank | never polled on Artist | MISC_VIDEO bit 18 loops only for CRX-type boards |
| 0x118044, 0x100944, 0x210xxx | other boards only | — |

---------------------------------------------------------------------------

## 7. What the RTL must do (priority order)

1. **Honour byte enables in Otc32 writes** (window and every BINC data
   port): pixel i only if `be[3 - i/8]`. Fixes the doubled glyphs (2.5).
   Retire that part of STUBS S-023.
2. **Font engine**: 0x100AA0 (counter := 0, two rows), 0x1008A0 (two
   rows), 16 pixels a row at DST.x, rows ≥ LEN h dropped, then DST.x +=
   LEN w; FG for 1-bits, 0-bits per the IBO transparency; ignore the BINC
   mask (2.3). Without it all small-font text (labels, menus, terminals'
   non-terminal fonts) is missing.
3. **Fill colour from TRANSFER_DATA** (bit `31 - ((px - DST.x) mod 32)` →
   FG/BG, BG transparent with IBO bit 1/28), **0x100A20** (TRANSFER_DATA +
   start fill), and the DST.y advance for 0x100080 = 0x08 as well as 0x7D
   (5.1).
4. **Lines**: 0x100E44 (inclusive) and 0x100E04 (exclusive), Bresenham
   from DST in FG through ROP/plane mask, then DST := end; the 0x100CCC
   parametric form, dashed lines (0x100ECC, 0x10080C + 0x100EC4, 0x100CCC)
   and 0x100C40 points (5.5).
5. **Cursor position/enable**: `x = 4*POS[31:19] + POS[17:16] + 16 - 4*hbp`,
   `y = vactive - 1 - POS[15:0] - CTRL[5:0]`, shown while CTRL[7]; mask 0 =
   transparent (3.4, 3.5).
6. **Otc32 source = bit J** (SBA bits 20:16) of each pixel, for CPU reads
   and for the recolouring move (5.2).
7. **LUT1 and the attribute planes**: keep LUT1 (the 0x300118 copy for
   offsets 0x100..0x1FF), keep a per-pixel LUT-select bit written by fills
   with DBA buffer 13 and CONTROL_PLANE bit 24, and look the pixel up in
   LUT0 or LUT1 (4.2). Needed as soon as a client installs its own
   colormap.
8. Keep: 0x300004 bit 25 = 0; byte reads of 0x300000/0x300201/0x300202/
   0x300208/0x30021A; register storage of 0x300200/0x300208/MISC_VIDEO/
   MISC_CTRL (the server reads them back); 0x100088/0x100089 storage.
9. Optional: FractDcd (BA bit 31) writes as Color Recovery dither,
   MISC_CTRL[1:0] decode — only the HP-COLOR-RECOVERY extension and the
   TrueColor visual use them.

---------------------------------------------------------------------------

## 8. Discrepancies with `docs/design/artist.md`, `rtl/artist/artist.sv` and review 08

| # | Ours | The X server | Effect |
|---|---|---|---|
| 1 | Otc32 window/BINC writes use all 32 bits regardless of byte enables (`artist.sv:311-315`; artist.md 3 table "CPU store"/"BINC data"; S-023) | glyph rows by `sth` 0x100620 = 16-pixel transfers (2.2) | **ghost glyphs 16 px right — the overlapping text** |
| 2 | 0x1008A0 / 0x100AA0 not decoded (`artist.sv:475-558`; S-023; 08 2.6 "QEMU-only") | the font engine for every font with a ≤ 16 x 32 box (2.3) | small text missing |
| 3 | fill colour = IBO bit 1 ? FG : BG, TRANSFER_DATA unused (`artist.sv:737`; artist.md 3; 08 2.3/2.4) | colour from TRANSFER_DATA bits; screen clear with IBO bit 1 clear and only FG set; opaque stipples (5.1) | clear uses the stale BG; stipples wrong |
| 4 | 0x100A20 not decoded | stipple/tile fills, one row per write (5.1) | stippled fills missing |
| 5 | DST.y advance only for 0x100080 = 0x7D (`artist.sv:798`) | also 0x08 (5.1) | pattern rows drawn on one line |
| 6 | 0x100E04, 0x100E44, 0x100CCC, 0x100ECC not decoded | all line drawing (5.4, 5.5) | lines missing (all built since: `8944cfe` E04/E44, then 5.5's forms) |
| 7 | cursor `x = 4*xhi + 23 - 4*hbp + xlo - CTRL[7:4]`, `y = vactive - POS.y - CTRL[3:0]` (`artist.sv:254-257`, QEMU's formula; 08 1.2.5/3.6 "bits 7:4 / 3:0 hotspot offsets") | CTRL = 0x80 \| yoff (bits 5:0); `x = 4*xhi + xlo + 16 - 4*hbp`, `y = vactive - 1 - POS.y - yoff` (3.4) | pointer 1 px left, 1 row low; 1..3 px further left and wrong rows when it is clipped ≥ 16 rows at the top |
| 8 | cursor pixel = image ? colour 3 : colour 2 where image or mask (`artist.sv:332-333`) | mask 0 = transparent (3.5) | source bits outside the mask shown |
| 9 | Otc32 read bit = OR(pixel AND plane mask) (`artist.sv:348`, recolouring move `:323`; S-023; 08 2.2) | SBA J field selects the plane (5.2) | CopyPlane / XYPixmap GetImage of planes ≠ 0 wrong. The ROM uses J = 0 (probe: pixels 0x00/0xFF, unaffected; colour block_move: text colours with bit 0 clear would read as 0 — check against the ROM before changing) |
| 10 | LUT1 and attribute planes dropped (`artist.sv:670`, `:779`; artist.md 4; S-023) | LUT1 for non-default colormaps, attribute 0x01000102 (4.2) | technicolor in clients with their own colormap (built since: LUT1, a 1-bit attribute plane in DDR3 and the display `artist_video.sv`, 2026-10-09) |
| 11 | 0x300118 bit 30 ignored | X sets it on every colormap load (4.1) | none (copy at once is fine) |
| 12 | FractDcd / Otc01 image writes treated as 4 bytes | Color Recovery PutImage (5.3) | garbage, extension only |
| 13 | artist.md has no cursor section, lists BINC as 0x620/0x600/0x604/0x5C0 only | the RTL (a24382f) has the cursor, 8 BINC directions, LUT blt types | doc behind the RTL |
| 14 | 08 1.2.1: 0x100080 "== 0x7D auto-increment" only | values 0x7F, 0x7D, 0x08, 0x00, 0x30000, 0x30003 (5.1) | — |
| 15 | 08 1.2.5: 0x300004 "byte 5: Linux FB/copy mode" | X reads byte 0x300004 bit 1 (bit 25) as FIFO overflow (6) | must stay 0 (it does) |

Confirmed as built: pixel-exact BINC destinations with bits above 23
ignored, the 0x6A0/0x620/0x600 directions, the BINC mask for Otc04
(bits 31:28) and Otc32 (bit 31-i) with IBO bit 29, transparency on IBO bit
1 or 28, LUT blt type 2 into cursor colours 2/3, 0x100B04/0x100A00
triggers, halfword writes to 0x100800/0x100804/0x100A04, CONTROL_PLANE
fills not touching the image, MISC_VIDEO as plain storage.
