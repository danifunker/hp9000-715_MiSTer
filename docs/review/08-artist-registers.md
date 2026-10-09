# Artist (built-in graphics of the HP 9000/715) — register-level specification for RTL

Review 08 (2026-10-09). The input for the Artist RTL (the next system-stream
block): written from HP's ROM, the HP-UX kernel, Linux and QEMU, with every
claim tagged by its evidence. Spot-checked on entry: the self_test signature
constants at f0026fc4-f0027058 (0xAC4FFDAC for 1280, 0x43A97116 for 1024).
Builds on `06c-hpux-graphics.md` and `docs/reference/rom/HARDWARE.md` 6.3.

Scope: what HP's PDC 1.6 ROM and its built-in STI image (0xF0024000) do to the
Artist at the register level, what HP-UX 10.20's kernel adds, what Linux
`stifb` uses, and what QEMU 11.1.1 `hw/display/artist.c` models. Written
2026-10-09 from `roms/hp715_pdc_rev1.6.bin` (disassembly `roms/disasm/rom.dis`,
STI part re-read instruction by instruction), `roms/hpux/vmunix.dis`,
QEMU 11.1.1, SeaBIOS-hppa `stirom.c`, Linux `drivers/video/fbdev/stifb.c` and
`drivers/video/console/sticore.c`.

Evidence tags used throughout:

* **[V]** verified in HP's ROM disassembly (address given; all register
  offsets below were recomputed from the instruction encodings; note that
  objdump prints `bb` bit numbers and all displacements/immediates in **hex**,
  `extrw/depw` positions in decimal);
* **[K]** verified in the HP-UX 10.20 kernel (`vmunix.dis`);
* **[L]** Linux `stifb.c` / `sticore.c`;
* **[Q]** QEMU `artist.c` (a model, not ground truth);
* **[I]** inference (reason given).

Offsets are from the HPA 0xF8000000 unless written as full addresses. The STI
code addresses its registers through `glob_cfg->region_ptrs[]`:
`R2 = region 2 = 0xF8100000` (control), `R3 = region 3 = 0xF8380000`
(sys-only page), `FB = region 1 = 0xF9000000`, `ROM = region 0 = 0xF0024000`.
Linux uses `mmio_start = region 2` (`stifb.c:1181`), so Linux `REG_x` offsets
are +0x100000 relative to the offsets used here.

---------------------------------------------------------------------------

## 0. Headline facts (read this first)

1. **The STI draws into bitmap buffer 2, not 1** [V]. Every BA ("bitmap
   access") value HP's code writes has buffer number 2 (`0x2ea02000`,
   `0x13602000`, `0x10a02000`, `0x28a02000`, `0x85000302`…); Linux and SeaBIOS
   use buffer 1. On the 8-plane Artist both must address the **same** 8-bit
   frame buffer [I: HP's LUT build XORs "text" and "non-text" colours of the
   same pixel (f0025a20-f0025a50), and Linux's console in buffer 1 replaces the
   ROM's text without clearing buffer 2 (`stifb.c:1045-1100`)]. QEMU backs only
   buffer 1 for CPU accesses, so HP's STI cannot run on QEMU.
2. **The STI keeps its private state in off-screen VRAM** [V]: 140 bytes at
   pixel (x=1536, y=776) — or (1536, 384) when `MISC_VIDEO[3:0] != 0` (the
   1280-wide modes) — read and written by the CPU through the frame-buffer
   window in byte mode (`ldb/stb/ldw/stw` at `FB | 0x184600` / `FB | 0x0C0600`,
   f0024fe0-f0025078). The VRAM must be 2048 x 1024 x 8 (2 MB), must keep its
   contents across PDC -> OS hand-off, and CPU **reads** of the frame buffer
   must work in mode `0x1360` (byte addressed, 4 pixels per word).
3. **A VRAM probe runs on the first init** [V] (f002508c-f00251c0): writes
   through mode `0x2ea0` (1 bit per pixel through FG/BG) to FB+0 and
   FB+0x400000 (y=512) and reads back a **32-pixel bitmap**; the low halves must
   read 0xF583 and 0xC7A0, else `init_graph` fails (errno 12) or falls back to
   1024x768. So CPU reads in mode `0x2ea0` return one bit per pixel.
4. **The palette is loaded indirectly** [V]: the CPU writes 256 RGB words to a
   staging line (mode `0x3ba0f000`, buffer 15, FB+4*i), then writes the source
   address (0x100480) and a LUT-load command to **0x300118** (`0x80000100`,
   then `0x81000100` for a second 256-entry LUT). QEMU ignores 0x300118 and
   displays staging entries 0x100-0x1FF directly — wrong for HP's ROM, which
   stages at entries 0-0xFF.
5. **The PDC runs STI `self_test` at boot** [V: console_init f001f98c-f001f9a0
   passes test=1 -> iodc F_f002a44c -> F_f002a708 -> self_test], and the test
   passes only if the **signature register 0x30023C** returns the constant for
   the current width (1280: 0xAC4FFDAC, 1024: 0x43A97116, 800: 0xDDF1D432,
   640: 0xEC9EB928; f0026fc4-f002705c). If it fails the graphics IODC init
   returns -4 and the console cannot come up on graphics.
6. **MISC_VIDEO (0x300218) is mostly software scratch** [V]: initialised flag
   (bit 23), "2 MB VRAM" flag (22), monitor index (bits 15:12 and 7:6),
   friendly-boot (5), probe-in-progress (4), plus hardware fields (video
   enables 27/25, active-size high bits 11:8 and 3:0). It must read back
   exactly what was written. QEMU corrupts bits 15:8 and 18 on read.
7. Busy/FIFO: every routine polls **0xF8300000 bit 24** (busy) with **no
   timeout** in the ROM's helper (F_f0025f08), escaping only if 0xF8380004 bit
   25 (bus error) is set. Busy must always clear.

---------------------------------------------------------------------------

## 1. Address map

### 1.1 Decode, probing and identification

| Range | Must | Evidence |
|---|---|---|
| 0xF8000000-0xF80FFFFF (incl. the HPA word 0xF8000000) | **bus error** on read | [V] F_f0004cfc (called from `io_module_table_init` and PDC_IODC f00144d4/f0014544): PDC_ADD_VALID(HPA) (word probe `add_valid_probe_word` f0011be0); if it answers, the HPA is taken as an STI ROM base and bytes 3, 0xB/6 are read from it as ROM header. HARDWARE.md 6.3 |
| 0xF8300004 | **answers** (word read) | [V] same routine: PDC_ADD_VALID(HPA+0x300004); success -> ROM base := 0xF0024000 (f0004d68), then reads ROM byte 3 (=3, word mode) |
| 0xF8100000-0xF837FFFF | answers (region 2, 0x280 pages, BTLB) | STI region list [V] (`F00277C0`: 0x04008280) |
| 0xF8380000-0xF8380FFF | answers (region 3, 1 page, sys_only) | region list 0x0E024001 [V] |
| 0xF9000000-0xF9FFFFFF | answers (region 1, frame buffer window, 16 MB) | region list 0x40009000 [V]; HP-UX maps 16 MB (06c 7) |
| 0xF8381000-0xF8FFFFFF | bus error (recommended) | [I] outside every region; QEMU answers 0xF8000000-0xF83FFFFF (artist.c:1351-1352) |
| slots 0xF4000000/0xF6000000/0xFA000000 (+0x300004) | bus error | [V] HARDWARE.md 6.3 / 7 |

No interrupt: Artist asserts neither GSC INTL nor a LASI line (06c 5) [K].
IODC for HPA 0xF8000000 (type 10, SVERSION 0x85) and the STI image come from
the system ROM, not from the device (FIRMWARE.md 3, 4).

Reset: LASI IORESET bit 8 (RST_ARTIST_L, `rtl/lasi/lasi.sv:77`
`artist_rst`) holds Artist in reset during early boot (f00000d8 writes 0,
f00001b4 writes 0x1FF). Required reset state [V-derived]: **MISC_VIDEO = 0**
(bit 23 clear makes the first `init_graph` take the cold path); busy = 0;
0xF8380004 bit 25 = 0. **Correction 2026-10-09** (romsim, `docs/design/artist.md`
1): MISC_VIDEO[3:0] must already be non-zero (0x301 = the 1280 x 1024 size
fields) at reset, or the cold path writes the STI state (freq_ref) at
(1536, 776) and the PDC's third `init_graph` divides by zero reading it from
(1536, 384).

### 1.2 Register window, region 2 (0xF8100000-0xF837FFFF)

All 32-bit, big-endian. "Users": R = HP ROM STI, K = HP-UX kernel outside
STI, L = Linux, Q = QEMU models it. Reset values are recommendations unless a
source is given (no real-hardware reset values are known).

#### 1.2.1 0x100000-0x1007FF — "BINC" / state block

| Off | W/R | Name (QEMU / Linux) | Users | Semantics |
|---|---|---|---|---|
| 0x100000, 004, 008, 00C, 020, 040, 044, 048, 04C, 060, 080, 084 | R/W | — / — (Q: 0x100080 `reg_100080`) | R (state_mgmt save f0026030-f0026090, restore f0026140-f00261a0) | Unknown function. STI saves and restores them verbatim, so they must at least be **readable storage**. [Q] treats 0x100080 == 0x7D as "auto-increment Y by the fill height" (artist.c:469-477) — presumably seen from HP-UX's X server. Reset 0. |
| 0x100088 | R/W | — | R: cold init writes **0x00010000** (f00250f0); state save/restore | Unknown; store. |
| 0x100118 | W | Linux REG_1 (LUT-load on CRX) | L (non-Artist only) | On CRX the LUT-load command lives here; Artist uses 0x300118 (`stifb.c:254-266`). Accept/ignore. |
| 0x100480 | W | Linux REG_2 `NGLE_BINC_SET_SRCADDR` | R (f0025b00, f0025b18, self_test f0026d14/f0026d28: **0**), L (0x400) | BINC **source address**, used as the colour-map **staging source** for the LUT load (0x300118). Encoding as an FB address (x = addr[12:2] in long mode); read back at 0x11802C [V: state_mgmt saves 0x11802C and restores it through 0x100480, f00260bc/f00261cc]. |
| 0x1004A0 | W | `VRAM_IDX` / REG_3 `NGLE_BINC_SET_DSTADDR` | R (font_unpmv f0026580/f0026698, self_test, restore), L, Q | BINC **destination address** (an FB-window offset, HP writes `0x01000000 \| y<<13 \| x<<2` — i.e. FB address minus HPA; bits above 23 ignored [I]). Resets the "row counter" used by 0x100620 [Q]. Read back at 0x118028 [V restore pairing]. |
| 0x1004C0 | W | — | R (restore only, f0026220) | Unknown; its value is read back at **0x1007C0** [V: save f0026028 / restore f0026220]. Store. |
| 0x100520 | W | — | R (restore only, f002620c) | Unknown; read back at 0x118034. Store. |
| 0x100580 | W | — | R (restore only, f00261a8) | Unknown; read back at 0x118020. Store. |
| 0x1005A0 | W | `VRAM_BITMASK` / REG_22 `NGLE_BINC_SET_DSTMASK` | R (font f002657c, f0026630, f002669c), L, Q | BINC **pixel mask** for 0x100600/0x100620 writes: bit 31-i enables pixel i of a 32-pixel (Otc32) word. Read back (and directly writable) at **0x118024**. |
| 0x1005C0 | W | REG_23 `NGLE_BINC_WRITE32` | L (CRX24 only) | BINC data write without increment [I from name]. Optional. |
| 0x100600 | W | `VRAM_WRITE_INCR_X` / REG_4 | R (font, glyph width > 32 only, f00265cc/f0026634), L (cmap words), Q | BINC **data write, then advance x** by the pixels-per-word of the DST mode (32 for Otc32, 4 for Otc04, 1 for Otc7/cmap) [I + HTML "the number of X pixels is added"; QEMU advances only 1 pixel in 0x2ea0 mode — bug]. |
| 0x100604 | W | `VRAM_WRITE_INCR_X2` | Q | Same as 0x100600 [Q]. |
| 0x100620 | W | `VRAM_WRITE_INCR_Y` ("byte mode FIFO" in the HTML) | R (font f00266f8, self_test f0026e0c/f0026e94), Q | BINC **data write, then advance y by 1** (x unchanged). The font path. |
| 0x1007C0 | R | — | R (save f0026028) | Read-back of 0x1004C0. |

#### 1.2.2 0x100800-0x100FFF — rectangle engine ("register + start" addresses)

Rough pattern [I]: offset bits [11:8] select an action (0x8 = load only,
0xA = load + start rectangle fill, 0xB = load + start block move, 0xC/0xE =
line variants; the font ports 0x8A0/0xAA0 do not fit it) and bits [7:0] the
register (0x00 DSTXY, 0x04 LENXY, 0x08 SRCXY, 0x20 TRANSFER_DATA). Decode the
listed addresses individually. Packed coordinates are `x<<16 | y` (16-bit
each), sizes `w<<16 | h`.

| Off | W | Name | Users | Semantics |
|---|---|---|---|---|
| 0x100800 | W | `VRAM_START` / REG_6 `NGLE_SET_DSTXY` | R (F_f0025e48 f0025ee0, block_move clear f0026a3c, self_test helper f0027178), L, Q | DST x,y |
| 0x100804 | W | `BLOCK_MOVE_SIZE` / REG_7 | R (block_move f0026acc, f00271e0), L, Q | width, height |
| 0x100808 | W | `BLOCK_MOVE_SOURCE` / REG_24 | R (block_move f0026abc, f00271c8), L, Q | SRC x,y |
| 0x100820 | W | `TRANSFER_DATA` / REG_8 `NGLE_SET_TRANSFERDATA` | R (**0xFFFFFFFF** before every fill: f0025e9c, f0026a2c, f0027160), L, Q (stored, unused) | 32-bit fill pattern expanded through FG/BG [I]. |
| 0x1008A0 | W | `FONT_WRITE_INCR_Y` | Q (X server [I]) | 2 x 16-bit glyph rows, see 2.6. |
| 0x100A00 | W | `VRAM_START_TRIGGER` | Q | DSTXY + start fill with LENXY. |
| 0x100A04 | W | `VRAM_SIZE_TRIGGER` / REG_9 `SET_LENXY_START_RECFILL` | R (f0025ee8, f0026a4c, f0027190), L, Q | LENXY + **start rectangle fill** at DSTXY. QEMU: a 16-bit write updates only one dimension (artist.c:963-981). |
| 0x100AA0 | W | `FONT_WRITE_START` | Q | first font word (resets row counter). |
| 0x100B00 | W | `BLOCK_MOVE_DEST_TRIGGER` / REG_25 | R (f0026adc, f00271f8), L, Q | DSTXY + **start block move** SRCXY -> DSTXY, LENXY. |
| 0x100B04 | W | `BLOCK_MOVE_SIZE_TRIGGER` | Q | LENXY + start block move to DSTXY. |
| 0x100CCC | W | `LINE_XY` | Q | line drawing (X server). |
| 0x100E04 | W | `LINE_SIZE` | Q | " |
| 0x100E44 | W | `LINE_END` | Q | " |
| 0x100ECC | W | `PATTERN_LINE_START` | Q | " |
| 0x101020, 0x101028 | W | `SETUP_RAMDAC` | L (Artist too, `elkSetupPlanes`, `stifb.c:269-275`, 0x04000000 / 0xFF000000) | CRX RAMDAC; on Artist accept and ignore [I]. |

#### 1.2.3 0x118000-0x11803F — the direct register file

| Off | R/W | Name (QEMU / Linux) | Users | Semantics |
|---|---|---|---|---|
| 0x118000 | W | `DST_SRC_BM_ACCESS` / REG_10 / SeaBIOS `ARTIST_CMAP_ACCESS` | R (0x2ea02000 f00250b4; 0x13602000 f0025200/f00252ac/f0025b6c/f0027788; 0x3ba0f000 f0025a9c, f0026cb8; 0x10602000 restore f00261bc), L (0x13601000, 0xBBE0F000, 0x13A01000), Q | Writes **both** DST_BM_ACCESS and SRC_BM_ACCESS. |
| 0x118004 | R/W | `DST_BM_ACCESS` / REG_11 | R, L, Q | BA word for writes (CPU FB writes, BINC, fills, move destination). See 2.1. |
| 0x118008 | R/W | `SRC_BM_ACCESS` | R (0x28a02000, 0x10a02000), Q | BA word for reads (CPU FB reads, move source). |
| 0x11800C | R/W | `CONTROL_PLANE` / REG_12 | R (restore only), L (attribute setup 0x102 / 0), Q | Non-zero = fills/moves go to the attribute/control planes, **image pixels untouched** (QEMU skips the operation, artist.c:394, 462). |
| 0x118010 | R/W | `FG_COLOR` / REG_35 | R, L, Q | foreground (8 bits used). |
| 0x118014 | R/W | `BG_COLOR` | R, Q | background. |
| 0x118018 | R/W | `PLANE_MASK` / REG_13 | R, L, Q | per-plane write enable, applied to **every** pixel write (CPU, BINC, fill, move, font). |
| 0x11801C | R/W | `IMAGE_BITMAP_OP` / REG_14 | R, L, Q | rop and options, see 2.3. |
| 0x118020 | R | — | R (save) | read-back of 0x100580. |
| 0x118024 | R/W | — | R (**written** 0xFFFFFFFF f00251e8, f0025290, f0025b5c, f0027774; saved) | the BINC mask register (= 0x1005A0). |
| 0x118028 | R | — | R (save) | read-back of BINC dst address (0x1004A0). |
| 0x11802C | R | — | R (save) | read-back of BINC src address (0x100480). |
| 0x118034 | R | — | R (save) | read-back of 0x100520. |

state_mgmt also writes 0x118000 = **0x10602000** before restoring
0x1004A0/0x100480, then restores DST/SRC (f00261b8-f00261e4) [V].

#### 1.2.4 0x200000-0x2FFFFF

| Off | R | Name | Users | Semantics |
|---|---|---|---|---|
| 0x211110 | R | (QEMU invention) | Q, SeaBIOS STI only | `width<<16 \| height` (bit 31 = depth 1). Not on real hardware; implement only if SeaBIOS fallback matters. |
| 0x21xxxx | — | HCRX registers (REG_32..45) | L (HCRX only) | not Artist. |

#### 1.2.5 0x300000-0x3003FF — status, video, cursor, LUT control

| Off | W/R | Name (QEMU / Linux / X11) | Users | Semantics |
|---|---|---|---|---|
| 0x300000 | R | status / REG_15 | R (busy polls everywhere), K, L (byte read, loops until **byte 0 == 0**, `SETUP_HW`), Q (returns 0) | **bit 24 = engine busy** (0x01000000). Bits 31:25 must read 0 (Linux loops on the whole top byte). |
| 0x300004..7 | R/W bytes | REG_16 (b1 = 0x300005, b3 = 0x300007) | R (**stb 0x300007 = monitor index**, f00256a8), K (polls **0xF8300004 bit 25**, sti_sync_on 0x1738e8-0x173914), L (writeb 0x300005 = 1 in `SETUP_FB`, = 0 in `SETUP_COPYAREA`; readb 0x300007 - 1 = ROM table index, Tomcat only), Q (reads 0) | Byte 7 = monitor index (also used by HP's own ROM "ROM table index" concept). Byte 5: Linux FB/copy mode switch, meaning unknown. Bits 31:24 read 0 [I: HP-UX's loop exits on bit 25 *or* busy clear; the ROM's equivalent loop uses 0xF8380004 bit 25 instead]. Also the PDC_ADD_VALID probe target (1.1). |
| 0x300008 | R | `FIFO1` / REG_34 (`GET_FIFO_SLOTS`) | R (F_f0025e48 f0025ea8 waits until **>= 6**), L, Q (0x10) | free FIFO slots. |
| 0x300100 | W | `CURSOR_POS` (reg17) | R (= 0, f0025634), Q | X11 format: x-high = bits 31:19, x-low = 18:16, y = 15:0 (screen origin bottom-left, interleave 4, pipeline delay 4, artist.c:316-362). |
| 0x300104 | R/W | `CURSOR_CTRL` (reg18) | R (clears **bit 7** = cursor enable, f0025638-f0025640; state save/restore), Q | bit 7 enable; QEMU uses bits 7:4 / 3:0 as hotspot offsets (contradicts bit 7 = enable; QEMU guess). |
| 0x300118 | W | REG_26 (Artist LUT control, `NgleLutBltCtl`) | R (0x80000100, 0x81000100: f0025b14, f0025b24, f0026d24, f0026d34), L (0x80000100) | **LUT load**: bit 31 start/enable, bit 30 wait-for-blank, [25:16] LUT offset (0 / 0x100), [15:14] LUT type, [9:0] length (0x100). Copies `length` staging entries from the address in 0x100480 into LUT[offset..]. See 3.1. Not in QEMU. |
| 0x300200 | R/W | `HORIZ_BACKPORCH` (reg19) | R (W = rec+0x30 f0025550; R in self_test f0026bd8), K (W, sti_sync_on), Q (**overrides writes**) | horizontal timing, see 3.4. |
| 0x300204 | W | — | R (rec+0x34, f0025558) | unknown timing word; store. |
| 0x300208 | R/W | `ACTIVE_LINES_LOW` (reg20) | R (W f0025560, R self_test f0026bdc), K (W) | vertical timing, see 3.4. |
| 0x300218 | R/W | `MISC_VIDEO` (reg21) / REG_21 | R (many), K (R/W), L (sets/clears 0x0A000000), Q | see 3.3 — **must read back as written**. |
| 0x300238 | R/W | — | R (self_test: W 0xFFFFFFFF f0026f4c; polls `& 0xC0000000` until 0, f0026f54-f0026f70) | signature analyser start / busy (bits 31:30). |
| 0x30023C | R/W | — (HTML: "signature testing result") | R (W 0 f0026f50, R f0026f78), Q (0xAC4FFDAC) | signature result; see 3.7. |
| 0x300300 | W | — | R (5 writes, f00254bc-f0025648) | pixel-clock synthesiser (M/N), see 3.5. Not in QEMU. |
| 0x300308 | R/W | `MISC_CTRL` (reg27) / REG_27 | R (W 0x001B0000\|swap<<18 f00250f8/f00251c0; RMW f00255bc; `&= ~3` f0025b38), L (bit 23 = display enable), Q | see 3.5. |

### 1.3 Region 3, 0xF8380000 (sys-only page)

| Off | W/R | Users | Semantics |
|---|---|---|---|
| 0x380000 | R | R (every routine's entry, e.g. f0024f24, f0025fe4, f0026378, f0026814), Q (0) | **bit 24 = busy** (same meaning as 0x300000 bit 24 [I: if set and `flags.wait`=0 the routine returns 1 "busy"; if wait=1 it then polls 0x300000 bit 24]). |
| 0x380004 | R/W | R (init_graph, excep_hdlr, every wait loop), Q (0x6DC20006 constant; SeaBIOS `artist_present()` requires exactly this) | **bit 8 (0x100)**: write 1 = reset the chip's engine, self-clearing; reads 1 while in progress (init_graph waits up to 0x0FFFFFFF polls, else errno 12, f0024ec8-f0024f14; excep_hdlr up to 0x07FFFFFF). **bit 24 (0x01000000)**: bus-error timer enable (R/W; set from `flags.enable_be_timer` f0025314-f002532c; the reset clears it — init_graph restores it when `no_chg_bet`, f0025d60-f0025d78). **bit 25 (0x02000000)**: bus error occurred (sticky, cleared by the reset; any routine finding it returns errno 11; every wait loop exits on it). Low byte (0x380007): see next row. |
| 0x380007 | R byte | R (inq_conf f00273b8) | **0x0C = greyscale variant** (device name "HPA208LCG1280"), otherwise colour. QEMU's 0x6DC20006 gives 0x06. |
| 0x380008 | R | Q (`FIFO2`, 0x10), HTML (0x20000000) | Not read by HP's 715 ROM [V]. |

Recommended read value of 0x380004: `0x6CC20006 | be_enable<<24 | be_error<<25 | reset_busy<<8`
with `be_enable` = 1 at reset, so that the power-on value is QEMU's/SeaBIOS's
0x6DC20006 (the other bits are an unexplained constant [Q]).

### 1.4 Frame-buffer window, region 1 (0xF9000000-0xF9FFFFFF)

CPU accesses here are interpreted through **DST_BM_ACCESS** (writes) and
**SRC_BM_ACCESS** (reads); see 2.1-2.2. Two address encodings:

* **long** (BA "A" field 5, and 7 [I]): `x = off[12:2]`, `y = off[23:13]` —
  8192 bytes per line, one word per pixel *position* (QEMU `ADDR_TO_X/Y` on
  `addr>>2`, artist.c:210-211, 802-811). HP-UX's view: pitch = total_x * 4
  (06c 3).
* **byte** (A = 3): `x = off[10:0]`, `y = off[20:11]` — 2048 bytes per line,
  one byte per pixel (Linux `line_length = total_x` = 2048, `stifb.c:1254`).

VRAM is 2048 x 1024 pixels x 8 planes (2 MB): monitor records say pitch
0x800 x 0x400 in all modes (rec+4/+8 [V]); `init_graph` reports
`total_x/y = 2048/1024` (f0025cf4-f0025cfc [V]); the probe touches y=512.
Accesses with y >= 1024: undefined; recommend ignore writes / read 0.

---------------------------------------------------------------------------

## 2. The drawing engine as used

### 2.1 BA (bitmap access) word: DST_BM_ACCESS / SRC_BM_ACCESS

Linux's field macro (`stifb.c:385`):
`BA(F,C,S,A,J,B,I) = F<<31 | C<<27 | S<<24 | A<<21 | J<<16 | B<<12 | I`,
with names Otc (C: pixels per transfer), Ots (S: pixel size/kind), A
(address mode), B (buffer number), I (index base).

| Value | F | C (Otc) | S (Ots) | A | B | Used by | Meaning (best reading) |
|---|---|---|---|---|---|---|---|
| 0x2EA02000 | 0 | 5 (32 px/word) | 6 (indirect: bit -> FG/BG) | 5 long | 2 | R: probe, font (DST), fill (DST), colour move (DST) | 1 bit per pixel, expanded through FG/BG |
| 0x2EA01000 | | | | | 1 | SeaBIOS, Q | same, buffer 1 |
| 0x13602000 | 0 | 2 (4 px/word) | 3 (8-bit) | 3 byte | 2 | R: STI state area (CPU ldb/stb/ldw/stw) | packed 8-bit pixels, byte addressing |
| 0x13601000 | | | | | 1 | L (`SETUP_FB`, CPU frame buffer) | same, buffer 1 |
| 0x10602000 | 0 | 2 | 0 | 3 | 2 | R: transient in state restore | (written before restoring BINC addresses) |
| 0x10A02000 | 0 | 2 | 0 | 5 long | 2 | R: plain block move SRC and DST | 4 px/word copy |
| 0x13A01000 | 0 | 2 | 3 | 5 | 1 | L: copyarea; Q: CPU writes 4 pixels at (addr>>2) | 4 x 8-bit pixels, long addressing |
| 0x28A02000 | 0 | 5 | 0 | 5 | 2 | R: SRC of the colour-change move | source read as 1 bit/pixel [I] |
| 0x28A0x000 | | | | | | Q: CPU writes, bit -> pixel value 1/0 (cursor bitmaps in buffers 6/7 [I]) | |
| 0x3BA0F000 | 0 | 7 | 3 | 5 | 15 | R: LUT staging writes (FB+4i) | one 24-bit colour per word, buffer 15 = colour-map staging |
| 0xBBE0F000 | 1 | 7 | 3 | 7 | 15 | L: cmap via BINC (0x1004A0 = (0x100+i)<<2, data to 0x100600) | same, through BINC |
| 0x2EA0D000 | 0 | 5 | 6 | 5 | 13 | L: attribute planes (`SETUP_ATTR_ACCESS`) | attribute buffer |

Buffer numbers (B, bits 15:12): 1 and 2 = the 8-bit image frame buffer
(aliases, see 0.1); 6, 7 = cursor bitmaps (64x64, [Q]); 13 = attribute
planes; 15 = colour-map staging line. Others: treat as image [I]. "I" (bits
11:0) is always 0.

### 2.2 CPU accesses to the frame-buffer window

Writes (by DST mode), each pixel then goes through ROP + PLANE_MASK (2.3):

* **Otc04/Ots08 byte mode** (0x1360): word store = pixels x..x+3, pixel x in
  bits 31:24; byte/halfword stores write only the addressed pixels (honour
  byte enables — QEMU always writes 4 pixels, artist.c:825-828, a bug).
* **Otc04/Ots08 long mode** (0x13A0): word store at the address of pixel x =
  pixels x..x+3 [Q: artist.c:830-834].
* **Otc32 indirect** (0x2EA0): word store at pixel x = pixels x..x+31; pixel
  i (bit 31-i) gets FG if the bit is 1, BG if 0 — unless the background is
  transparent (IBO bit 1 or bit 28, see 2.3); if IBO bit 29 is set, only
  pixels whose BINC-mask bit (0x118024) is 1 are written (QEMU
  `artist_vram_write32`, artist.c:779-800). Sub-word stores: QEMU narrows to
  8/16 pixels (`size*8`) — HP's code only uses word stores here.
* **Otc32, Ots0** (0x28A0): as above with FG := 1, BG := 0 [Q artist.c:842-846].
* **Otc7 cmap** (0x3BA0, buffer 15): word store at x writes staging[x] =
  data[23:0] (0x00RRGGBB) [V usage, Q].

Reads (by SRC mode):

* **byte mode** (0x1360): word = pixels x..x+3 (x in bits 31:24); byte loads
  return one pixel. **Required by HP's ROM** (state area f00252b8-f00252d0,
  f0025d48) — QEMU does not implement 0x1360 reads (returns ~0,
  artist.c:885-905).
* **long 4-pixel** (0x13A0 and QEMU's 0x3BA0): word = 4 pixels at x.
* **Otc32** (0x2EA0): **one bit per pixel**, bit 31-i for pixel x+i. Required
  by the VRAM probe (f0025120-f0025164: written 0x0A7CF583 must read back with
  low half 0xF583). Which function of the 8-bit pixel becomes the bit is not
  pinned down by the ROM (pixels are 0x00/0xFF there); recommend
  `bit = |(pixel & PLANE_MASK)` [I]. QEMU returns 4 pixels instead (bug).

### 2.3 IMAGE_BITMAP_OP (0x11801C)

Linux's field macro (`stifb.c:388`):
`IBOvals(R,M,X,S,D,L,B,F) = R<<8 | M<<16 | X<<24 | S<<29 | D<<28 | L<<31 | B<<1 | F`.

| Bits | Linux name | Effect to implement | Evidence |
|---|---|---|---|
| 11:8 | R = rop | X11 GX code (dst' from src s, dst d): 0 clear, 1 s&d, 2 s&~d, **3 copy**, 4 ~s&d, 5 d, 6 s^d, 7 s\|d, 8 ~(s\|d), 9 ~(s^d), 10 ~d, 11 s\|~d, 12 ~s, 13 ~s\|d, 14 ~(s&d), 15 set; applied within PLANE_MASK: `d' = (d & ~pm) \| (rop(s,d) & pm)` | HP uses only 3. QEMU implements 0/3/6/10/15 (artist.c:154-160, 274-314); the numbering matches X11 |
| 29 | S "StaticReg" | enable the BINC pixel mask (0x118024) for CPU/BINC Otc32 writes | [Q] artist.c:770, 789; HP sets 0x2000xxxx for font writes with mask 0xFF000000 |
| 28, 1 | D, B "BGx" | either set = **transparent background** (0-bits not written) | [Q] artist.c:793; HP probe uses 0x85000302 (needs transparent BG: BG is never set there) |
| 1 | B | QEMU also uses bit 1 to pick the **fill colour**: set -> FG, clear -> BG (artist.c:260-267) | HP's fills set FG (bit 1 set, FG = colour) or FG=BG=0 (bit 1 clear) — consistent with either "pattern bit 1 -> FG" or QEMU's rule; QEMU's rule was tuned on HP-UX X. Implement QEMU's rule [I] |
| 31 | L "MaskOtc" | none needed | used by HP/Linux for direct CPU-access set-ups (0x85000300, 0x83000300) |
| 26:24 | X "BitmapExtent" | none needed on an 8-plane device | 3 = 8 bits deep, 5 = 32 bits deep |
| 20:16 | M | none known | always 0 |

Values used: HP 0x85000302 (probe), 0x85000300 (state/CPU), 0x03000300
(clear helper), 0x00000300 (LUT staging), 0x20000300 (font, move, colour
move), 0x20000302 (fill/clear); Linux 0x83000300, 0x03000300, 0x23000300,
0x23000302; QEMU reset 0x23000300 (artist.c:1420).

### 2.4 Rectangle fill (0x100A04 / 0x100A00)

DST = DSTXY (0x100800), size = LENXY, colour per QEMU rule (2.3) or
equivalently TRANSFER_DATA bit -> FG/BG (TRANSFER_DATA is always 0xFFFFFFFF
in HP's code), through ROP and PLANE_MASK. Skipped when CONTROL_PLANE != 0 or
DST buffer = 13 (attribute planes) [Q/L]. Not clipped to the visible screen
(HP clears 1280x1024 / 1024x768 and the state area at x >= 1536 survives).
Optional QEMU quirk: 0x100080 == 0x7D -> after the fill, DST.y += height.

### 2.5 Block move (0x100B00 / 0x100B04)

Copy LENXY pixels from SRCXY to DSTXY through ROP and PLANE_MASK; must handle
overlap (scroll up and down) by choosing the copy direction (QEMU
artist.c:410-439). With SRC mode Otc32 (0x28A0) and DST mode indirect
(0x2EA0) the move **recolours**: each source pixel becomes 1 bit, written as
FG/BG (STI `block_move` with `flags.color`, f0026a58-f0026a84) [V usage; bit
function I: `|(src & PLANE_MASK)`]. QEMU ignores BA modes and does a plain
copy; skipped when CONTROL_PLANE != 0. The BINC mask (0x118024) does **not**
apply (it is 0xFF000000 after every glyph and HP scrolls right after) [I].

### 2.6 BINC data ports (0x100600, 0x100620) and QEMU's font/line engine

A write to 0x100620 performs the CPU-write semantics of 2.2 at the BINC
address (0x1004A0) + row counter, then increments the row counter
(QEMU artist.c:935-938). A write to 0x100600 writes at the BINC address and
advances it by the transfer width (2.1). HP's glyph loop is exactly:
VRAM_IDX = `0x01000000 | y<<13 | x<<2`, BITMASK = top-w bits, then per row
`[0x100620] = row_byte<<24` (f0026698-f0026704).

QEMU-only paths used by HP-UX X (inferred from QEMU's provenance, not from
HP code): FONT_WRITE_START/INCR_Y (two 16-bit rows per write, artist.c:689-733)
and Bresenham lines with patterns (artist.c:491-687, registers 0x100CCC,
0x100E04, 0x100E44, 0x100ECC; colour by IBO bit 1; pattern alternates FG/BG).

### 2.7 Busy, FIFO, ordering

* Every STI routine starts: `if [0xF8380004] & 0x02000000 -> errno 11`;
  `if [0xF8380000] & 0x01000000` (busy): `flags.wait=0 -> reent_lvl=1, return 1`,
  else poll `[0xF8300000] & 0x01000000` (exit also on 0xF8380004 bit 25), then
  re-check bit 25 (e.g. f0024f18-f0024f64, f0025fd4-f0026018).
* The helper `wait_idle` F_f0025f08 / F_f0027218 has **no timeout**;
  HP-UX's `sti_sync_on` gives up after 0x7FFFFF polls [K].
* font_unpmv polls busy before **every** row write (f00266ac-f00266c0).
* block_move does not wait after the trigger; the next routine's entry check
  does.
* F_f0025e48 waits for FIFO free >= 6 at 0x300008 before 6 register writes.

Recommended RTL contract: report busy honestly in 0x300000/0x380000 bit 24
while an operation runs; additionally **stall (do not ack)** any CPU access
to the engine registers (0x100400-0x100FFF, 0x118000-0x11803F, 0x300118) or
to the frame-buffer window while busy, so ordering holds even without polling;
never stall reads of 0x300000/4/8, 0x380000/4 or the video registers;
report a constant >= 16 in 0x300008. Busy must always clear in bounded time
(the ROM has no timeout) and 0xF8380004 bit 25 is never set.

---------------------------------------------------------------------------

## 3. Colour map, display, video timing, cursor

### 3.1 Colour map: staging line + LUT load

* Staging: buffer 15, addressed by x (0..2047, long encoding); each entry
  0x00RRGGBB. HP writes entries 0..255 at FB+4i in mode 0x3BA0F000 with
  PLANE_MASK=0xFF, IBO=0x300, in 16 groups of 16 with `wait_idle` between
  (f0025a88-f0025af8; self_test f0026cb0-f0026d10). Linux writes entries
  0x100+i through BINC (`stifb.c:237-252`).
* Load: `[0x100480] = src address` then `[0x300118] = ctl` copies
  `ctl[9:0]` entries from staging[src.x...] to LUT[ctl[25:16]...]. HP:
  src 0 -> LUT 0-255 (0x80000100) and src 0 -> LUT 256-511 (0x81000100)
  (f0025b00-f0025b24). Linux: src 0x400 (x = 0x100) -> LUT 0-255.
  Both LUTs receive the same data from HP's ROM, so the attribute planes
  (which select LUT0/LUT1 per pixel [I]) do not matter for the ROM.
* Display: `RGB = LUT0[pixel]` (QEMU uses one map, artist.c:1294-1312). Do
  the copy immediately (bit 30 "wait for blank" may be ignored); count it as
  busy.

### 3.2 "Text planes" and the LUT the ROM builds

There are no separate overlay planes and no double buffering in anything
the ROM, HP-UX's kernel or Linux does on Artist (Linux's CRX code selects
buffers/colour maps per pixel through the attribute planes, `stifb.c:452-494`;
for Artist it only writes `ARTIST_CMAP0` = 0x102 everywhere). "Text planes" are the low
`text_planes` bits (1..3, default 3; inptr checked 1..3, errno 3) of the
8-bit pixel; "non-text planes" are the rest (the ROM uses mask 0xF8 for them).
Text drawing uses PLANE_MASK = (1<<tp)-1 and colours 0..(1<<tp)-1; non-text
drawing uses PLANE_MASK 0xF8 and colour<<3 (font_unpmv f00264ec-f0026514,
f0026648-f0026678; block_move f002696c/f00269f8). Visibility is done entirely
in the LUT (f002598c-f0025a84), from a 2-bit display state (bit 1 text on,
bit 0 non-text on, kept in VRAM state word 2):

| state | LUT[0..7] | LUT[i], i = 8..255 |
|---|---|---|
| 0 | 0 | 0 (all black) |
| 1 (non-text) | text colours | `nontext[i>>3]` |
| 2 (text) | text colours | `text[i & mask]` |
| 3 (both) | text colours | `nontext[i>>3] ^ text[i & mask]` |

Text colours (f00258c0-f0025968): 0 black 000000, 1 white FFFFFF, 2 red
FF0000, 3 yellow FFFF00, 4 green 00FF00, 5 cyan 00FFFF, 6 blue 0000FF,
7 magenta FF00FF (same as SeaBIOS). Monitor 12 (greyscale): 0, FFFFFF,
4D4D4D, E3E3E3, 969696, B3B3B3, 1C1C1C, 696969 (f00257fc-f00258b4). Records
with byte +0x5D != 0 (monitor 4, flat panel): 080808, FFFFFF, FF0808, FFFF08,
08FF08, 08FFFF, 0808FF, FF08FF (f002574c-f00257ec). `nontext[0..31]` are
state words 3..34, cleared at cold init and set only by `set_cm_entry`
(entries 0..31, errno 4 otherwise) — `set_cm_entry` touches **no** LUT
hardware; it only stores into VRAM state (f002770c-f0027798).

### 3.3 MISC_VIDEO (0x300218)

| Bits | Meaning | Evidence |
|---|---|---|
| 31:29 | sync mode: 111 HP monitors, 110 VESA modes, 000 640x480@60 (record values) | [V values; meaning I — not polarity: VESA 640x480@75 (-/-) and 1280x1024@75 (+/+) both 110] |
| 27, 25 | **video enable** (both set = display on) | [L `stifb.c:328-341`, Q 1288-1292]; rec+0x2C (blank) / rec+0x4C (on) [V] |
| 26 | cleared with 27/25 by self_test (& ~0x0E000000, f0026c18); 0 in all records | [V] |
| 24 | 1 in all records | [V] |
| 23 | software: "Artist initialised" (also set by every record) | [V] f00251a8, f002507c |
| 22 | software: 2 MB VRAM present (probe result); gates 1280-wide modes (errno 20) and the default monitor (1 vs 4) | [V] f00251ac, f0025380-f0025394, f0025de4-f0025df4 |
| 21:16 | 0 in records; cleared by the cold path (`& 0xFF00FFEF`) | [V] f00251a4; QEMU toggles **bit 18** on every read as fake vblank (artist.c:1200) [Q] |
| 15:12 | software: monitor index bits 5:2 | [V] f00255ec, f0025d20; [K] sti_sync_on |
| 11:8 | hardware: (vactive-1) >> 8 | [V] self_test f0026bf0-f0026c10; records |
| 7:6 | software: monitor index bits 1:0 | [V] f00255fc, f0025d24 |
| 5 | software: friendly-boot flag | [V] f0024fac-f0024fdc, f00255cc |
| 4 | software: probe in progress | [V] f002509c, f00251a4 |
| 3:0 | hardware: (hactive/4-1) >> 8 | [V] self_test f0026bf8; records |

HP-UX `sti_sync_on` writes `(v & 0x00FFF0F0) | (rec[0x4C] & 0xFF000F0F)`
[K 0x17397c-0x1739a0]. Display gating: use only bits 27/25 (the ROM never sets
MISC_CTRL bit 23, yet its display works).

### 3.4 Timing registers and the 13 monitor records

Record i (monitor index i+1, at ROM 0x328 + 0x60*i): +0x02 x, +0x04 y,
+0x2C MISC_VIDEO while reprogramming (enables off), **+0x30 -> 0x300200**,
**+0x34 -> 0x300204**, **+0x38 -> 0x300208**, **+0x4C -> MISC_VIDEO**,
+0x54 pixel clock (Hz), +0x58 code (unused by STI), byte +0x5C -> MISC_CTRL
[23:16], byte +0x5D != 0 -> flat-panel palette.

Field layout (derived; exact for the four VESA 75 Hz modes, e.g. 1280x1024@75:
1688 x 1066 at 135 MHz):

* reg19 0x300200: [31:24] (hactive/4-1)&0xFF, [23:16] hbp/4-1, [15:8]
  hsync/4-1, [7:0] hfp/4-1 (units of 4 pixels).
* reg20 0x300208: [31:24] (vactive-1)&0xFF, [23:16] vbp-1, [15:8] vsync-1,
  [7:0] vfp-1.
* hactive = 4*((MISC_VIDEO[3:0]<<8 | reg19[31:24]) + 1);
  vactive = (MISC_VIDEO[11:8]<<8 | reg20[31:24]) + 1 (exactly how self_test
  computes them, f0026bcc-f0026c10).
* X11's cursor uses horizBackPorch = reg19[23:16] + reg19[15:8] + 2 (QEMU
  artist.c:335-338).
* 0x300204: [31:24], [23:16] small constants, [15:0] ~ hactive/4 + 17..65;
  meaning unknown (VRAM serial-transfer timing?) — store only.

| idx | mode | clock MHz | reg19 | 0x300204 | reg20 | MISC_VIDEO | MISC_CTRL b16 | htot x vtot | refresh |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 1280x1024 | 135.000 | 3F2F2F0F | 0F0F017F | FF3C0202 | EB800301 | 0 | 1728x1091 | 71.6 |
| 2 | 1024x768 | 84.587 | FF1F1F0F | 0707012F | FF3F0303 | EB800200 | 0 | 1344x840 | 74.9 |
| 3 | 1024x768 | 75.000 | FF232105 | 0D0D0129 | FF1C0502 | CB800200 | 1 | 1328x806 | 70.1 |
| 4 | 1024x768 flat | 84.000 | FF1F1F0F | 0707012F | FF3F0303 | EB800200 | 0 (b5D=1) | 1344x840 | 74.4 |
| 5 | 1280x1024 | 108.181 | 3F312D0A | 0F0F017F | FF190202 | EB800301 | 0 | 1708x1056 | 60.0 |
| 6 | 1024x768 | 64.109 | FF1F1F0F | 0707012F | FF130302 | EB800200 | 0 | 1344x795 | 60.0 |
| 7 | 640x480 | 25.175 | 9F0B1705 | 080800B1 | DF1F0109 | 0B800100 | 1 | 808x524 | 59.5 |
| 8 | 1280x1024 VESA | 135.000 | 3F3D2303 | 0F0F0181 | FF250200 | CB800301 | 0 | 1688x1066 | 75.0 |
| 9 | 1024x768 VESA | 78.750 | FF2B1703 | 0909012F | FF1B0200 | CB800200 | 1 | 1312x800 | 75.0 |
| 10 | 800x600 VESA | 49.500 | C7271303 | 070700F3 | 57140200 | CB800200 | 1 | 1056x625 | 75.0 |
| 11 | 640x480 VESA | 31.500 | 9F1D0F03 | 050500C1 | DF0F0200 | CB800100 | 1 | 840x500 | 75.0 |
| 12 | 1280x1024 grey | 135.000 | 3F2F2F0F | 0F0F017F | FF3C0202 | EB800301 | 0 | 1728x1091 | 71.6 |
| 13 | 1280x1024 | 110.000 | 3F27370F | 13130177 | FF89026B | EB800301 | 0 | 1728x1273 | 50.0 |

The constant words of every record (+0x08..+0x28, +0x3C..+0x48) are not
read by the STI code [V].

### 3.5 MISC_CTRL (0x300308) and the pixel-clock synthesiser (0x300300)

MISC_CTRL [V]: cold probe writes 0x001B0000 | swap<<18, where swap = 1 when
the probe read back the 16-bit halves exchanged (FB+0 read 0x0A7C instead of
0xF583) — so bit 18 is a VRAM data-lane configuration [I]; mode programming
writes `(old & 0x00E400FF) | 0x000A0100 | (freq_ref > 66 MHz)<<20 |
rec[0x5C]<<16`; after a LUT load `&= ~3`. Linux: bit 23 = display enable
(0x00800000). Meaning of the other bits unknown — store and read back.

0x300300 [V f002546c-f0025548, f0025644]: PLL `f = freq_ref * M / N`;
`[15:8] = M-1`, `[7:0] = N-1`; search N = 5..50, M = round(clk*N/ref),
cost = |error| + N*256 (N*32 for monitor 4), M >= 4. Write sequence: (M',N')
scaled up until the larger is >= 128 with bit 17 clear; delay 0xFFFFF loops;
same with bit 17 set; delay; (M,N)|0x20000; delay 0x3FFFF; (M,N)|0x60000; and
at the end of mode set (M,N)|0x70000. `freq_ref` comes from the caller's
`glob_cfg_ext->freq_ref` (PDC: page-zero 0x610) and is saved in VRAM state
word 1 [V]. For RTL: store; derive the actual output mode from the monitor
index or from hactive/vactive, not from this register.

### 3.6 Cursor

ROM: CURSOR_POS = 0, CURSOR_CTRL bit 7 cleared (cursor off) in every mode
set; CURSOR_CTRL saved/restored by state_mgmt [V]. Hardware cursor per [Q]:
up to 64x64, two 1-bit bitmaps in buffers 6 and 7 (written by the CPU through
the FB window, e.g. mode 0x28A06000), drawn black/white in QEMU; position as
in 1.2.5. Cursor colours on real hardware are probably LUT entries [I]. Not
needed for the ROM or the ITE; needed for X11 (unless X falls back to a
software cursor).

### 3.7 Signature analyser (self_test)

self_test (f0026bcc-f002705c) [V]: reads MISC_VIDEO/reg19/reg20 to compute
hactive/vactive, blanks video (MISC_VIDEO &= ~0x0E000000), loads a ramp LUT
(entry i = (i&F8)<<16 | ((i+0x60)&F8)<<8 | ((i+0xC0)&F8) for i >= 8, text
colours below), draws 'a'..'z' in text planes and 'A'..'Z' in non-text
planes, does fills and moves, reads FB+0, writes 0xFFFFFFFF to 0x300238 and 0
to 0x30023C, polls `0x300238 & 0xC0000000` until 0, reads 0x30023C, clears,
restores MISC_VIDEO, and passes only if:

| hactive | expected 0x30023C |
|---|---|
| 1280 | 0xAC4FFDAC |
| 1024 | 0x43A97116 |
| 800 | 0xDDF1D432 |
| 640 | 0xEC9EB928 |

The signature algorithm (presumably a CRC over one frame of video output) is
unknown. RTL: complete at once (bits 31:30 = 0) and return the constant for
the current hactive (a STUBS entry). QEMU returns the 1280 value always.

---------------------------------------------------------------------------

## 4. Walk-through of HP's STI routines (all [V])

Calling convention: `r26 flags, r25 in, r24 out, r23 glob_cfg`; returns 0 ok,
1 busy (`reent_lvl` = 1), -1 error with `out->errno`. Structures as in
SeaBIOS `sticore.h` (big-endian bit-fields: init flags byte 0 = wait, reset,
text, nontext, clear, cmap_blk, be_timer, be_int; byte 1 = no_chg_tx,
no_chg_ntx, no_chg_bet, no_chg_bei, init_cmap_tx, cmt_chg, retain_ie,
caller_bootrom). Millicode inside the image: $$divI F_f0024814, $$mulI
F_f00249e4.

### 4.1 init_graph (0xF0024808 -> body 0xF0024E18)

1. f0024e5c-f0024ea8: r4 = FB, R2, R3 from glob_cfg; read 0xF8380004, keep
   bit 24.
2. f0024eb4-f0024f14 (flags.reset): 0xF8380004 |= 0x100; poll until bit 8
   clears (<= 0x0FFFFFFF, else errno 12).
3. f0024f18-f0024f64: bus-error and busy entry checks (2.7).
4. f0024f68-f0025068: ext = glob_cfg->ext_ptr; if set, `sti_mem_addr` must be
   non-zero (errno 17); text_planes 1..3 (errno 3); glob_cfg->text_planes set.
5. f0024fa4: read MISC_VIDEO; with ext, copy `friendly_boot` into bit 5.
6. f0024fe0-f0025078: state area `r6 = FB | (MISC_VIDEO[3:0] ? 0x0C0600 : 0x184600)`.
7. f002507c: MISC_VIDEO bit 23 clear -> **cold path**:
   * wait_idle; MISC_VIDEO |= 0x10;
   * 0x118000 = 0x2EA02000; FG = 0; PLANE_MASK = 0xFF; IBO = 0x85000302;
   * [FB] = 0xFFFFFFFF; [FB+0x400000] = 0xFFFFFFFF; 0x100088 = 0x10000;
     MISC_CTRL = 0x1B0000; FG = 0xFF;
   * [FB] = 0x0A7CF583; wait_idle (store [FB+0x400000] = 0x385FC7A0 in its
     delay slot); wait_idle;
   * read [FB]: low half 0xF583 -> ok, 0x0A7C -> ok + swap, else errno 12;
     read [FB+0x400000]: 0xC7A0 (or 0x385F with swap) -> 2 MB flag, mixed ->
     2 MB flag + soft error (errno 21, still returns 0), else no 2 MB flag;
   * MISC_VIDEO = (v & 0xFF00FFEF) | 0x00800000 | 2MB<<22;
     MISC_CTRL = 0x1B0000 | swap<<18;
   * wait_idle; PLANE_MASK = 0xFF; 0x118024 = 0xFFFFFFFF; IBO = 0x85000300;
     0x118000 = 0x13602000;
   * VRAM state (CPU stores in byte mode): word 2 = 0, words 3..34 = 0, word 1
     = freq_ref, byte 0 = 5 (friendly-boot countdown).
   **Warm path** (f0025260): wait_idle; same four register writes; read state
   word 2 (display state), word 1 (freq_ref), byte 0 (countdown, decremented
   when there is no ext).
8. f0025308-f0025330: unless no_chg_bet: 0xF8380004 |= be_timer<<24.
9. f0025d80-f0025df4: monitor index: with ext and (cold or reset&cmt_chg):
   `in->ext->config_mon_type` (no in-ext -> errno 14); otherwise from
   MISC_VIDEO [15:12],[7:6]; reprogram if explicit, or if reset and the index
   differs from state byte 1. Index 0 -> 1 if 2 MB else 4.
10. f0025340-f00256a8 (reprogram): idx 1..13 else errno 20; x > 1024 without
    2 MB -> errno 20; wait_idle; MISC_VIDEO = rec+0x2C (video off); PLL search
    and the five 0x300300 writes with delay loops; 0x300200/204/208 =
    rec+0x30/34/38; MISC_CTRL RMW; MISC_VIDEO = rec+0x4C | friendly<<5 |
    2MB<<22 | (idx>>2)<<12 | (idx&3)<<6 (video on); recompute r6; CURSOR_POS =
    0; CURSOR_CTRL &= ~0x80; 0x300300 |= 0x70000; wait_idle; ext->curr_mon;
    delay 3000 loops; state byte 1 = idx; **byte [0xF8300007] = idx**.
11. f0025c80-f0025cfc: glob_cfg onscreen = record x,y; offscreen 0; total =
    2048 x 1024.
12. f00256b4-f0025720: display state from reset/cmap_blk, init_cmap_tx,
    text, nontext, no_chg_tx, no_chg_ntx.
13. f0025724-f0025b38 (if needed and countdown == 0): build and write the LUT
    (3.1, 3.2); MISC_CTRL &= ~3.
14. f0025b40-f0025b88: wait_idle; restore state-access set-up; state word 2 =
    display state.
15. f0025b8c-f0025bf8: cold -> F_f0025e48(plane mask 0xFFFFFFFF); else
    flags.clear -> F_f0025e48(plane mask (1<<tp)-1). F_f0025e48: wait_idle;
    0x100820 = ~0; wait 0x300008 >= 6; IBO = 0x03000300; DST = 0x2EA02000;
    FG = BG = 0; PLANE_MASK = arg; 0x100800 = 0; 0x100A04 = 1280x1024 if
    onscreen_x > 1024 else 1024x768; wait_idle.
16. f0025c00-f0025c34: out->text_planes; errno 0 (21 for the soft probe
    error); return 0.

### 4.2 state_mgmt (0xF0025FC4)

Entry checks; save (f0026028-f0026108) / restore (f002613c-f0026220) of 27
words (statesize 0x1B) — the register list of 1.2.1/1.2.3 plus CURSOR_CTRL;
restore writes the 0x1180xx read-backs through 0x1004A0/0x100480/0x1005A0/
0x100580/0x100520/0x1004C0 and sets 0x118000 = 0x10602000 first.

### 4.3 font_unpmv (0xF0026248 -> body 0xF0026320)

1. Entry checks (f0026354-f00263ac).
2. index within [first,last] (errno 4); dest_x+width <= total_x, dest_y+height
   <= total_y (errno 5); text: fg,bg < 1<<tp, non-text: <= 31 (errno 6).
3. glyph = font + 16 + (index-first)*bytes_per_char (F_f0026748).
4. VRAM_IDX value `0x01000000 | dest_y<<13 | dest_x<<2`; mask = top
   (width mod 32) bits.
5. Text: PLANE_MASK = (1<<tp)-1, FG = fg, BG = bg. Non-text: PLANE_MASK =
   0xF8, FG = fg<<3, BG = bg<<3. Then DST = 0x2EA02000, IBO = 0x20000300.
6. width <= 32 (the ROM font is 8x16): 0x1004A0 = addr, 0x1005A0 = mask; per
   row: wait busy, `[0x100620] = row bytes left-justified`.
   width > 32: per row 0x1005A0 = ~0, 0x1004A0 = addr, full words to
   0x100600, then 0x1005A0 = mask and the last partial word to 0x100600;
   addr += 0x2000.

### 4.4 block_move (0xF00267D4)

1. Entry checks; width or height 0 -> return 0.
2. Range checks (errno 9), colours (errno 6), src (7), dst (8).
3. PLANE_MASK = text (1<<tp)-1 or non-text 0xF8.
4. clear: IBO = 0x20000302, DST = 0x2EA02000, FG = bg (<<3 if non-text),
   0x100820 = ~0, 0x100800 = dest, 0x100A04 = size -> fill.
   color (text only, else errno 19): BG = bg, FG = fg, IBO = 0x20000300, SRC =
   0x28A02000, DST = 0x2EA02000, then the move registers.
   plain: IBO = 0x20000300, SRC = DST = 0x10A02000, then 0x100808 = src,
   0x100804 = size, 0x100B00 = dest -> move.

### 4.5 self_test (0xF0026B20), excep_hdlr (0xF002729C), inq_conf (0xF00273A8), set_cm_entry (0xF002762C)

* self_test: 3.7.
* excep_hdlr: entry checks; if a flag (byte 0 bit 2) and 0xF8380004 bit 25:
  reset (0x100, wait <= 0x07FFFFFF), then 0xF8380004 |= 0x01000000; out byte
  4 bit 7 = bus-error status; bit 8 still set -> errno 11.
* inq_conf: no hardware access except **byte 0xF8380007** (0x0C = greyscale);
  returns 8 bpp, 8 bits used, 8 planes, the glob_cfg sizes, name
  "HPA208LC" + "640"/"800"/"1024"/"1280" (or "G1280"), attributes 0x1836.
* set_cm_entry: entry 0..31 only; stores into VRAM state word 3+entry (and
  sti_mem); no LUT access.

### 4.6 Callers

* PDC graphics IODC (`iodc_gfx_init` F002A1E4): copies routines to RAM and
  calls init_graph (F_f002a828), self_test (F_f002a708, at boot), block_move
  (F_f002aaac), font_unpmv / block_move from `iodc_gfx_io` (F002B22C, be,l at
  F002C030/F002C1DC). Boot order: init_graph (cold) -> self_test ->
  init_graph -> clears -> text. Passes `glob_cfg_ext` at page-zero 0x60C
  (F002A240), i.e. the ext path.
* HP-UX: init_graph with flags 0xCF/0x02 and 0xEC/0x32 (no ext, rev 0x84),
  block_move, font_unpmv, state_mgmt, inq_conf, then **sti_sync_on** [K]:
  polls 0xF8300004 bit 25 / 0xF8300000 bit 24, rewrites 0x300200, 0x300208
  and MISC_VIDEO from the record selected by MISC_VIDEO's index bits.
* Linux sticore: init_graph (wait, reset, text, no_chg_bet/bei,
  init_cmap_tx, with ext), then stifb programs the chip itself (1.2, 2.1).

Consequence: HP-UX (no ext) relies on the warm path. If the reset bit
(0xF8380004 bit 8) cleared MISC_VIDEO bit 23, HP-UX would take the cold path,
which writes through an uninitialised `sti_mem` pointer (f00251c4-f00251cc)
[V]. So **the 0x100 reset must not clear MISC_VIDEO (nor VRAM)**; it clears
bit 24/25 of 0xF8380004 and the engine [I].

---------------------------------------------------------------------------

## 5. QEMU artist.c versus HP's ROM and HP-UX

| # | QEMU behaviour | Effect with HP's ROM / HP-UX |
|---|---|---|
| 1 | Register region 4 MiB from 0xF8000000 answers everything (1351-1352) | the HPA probe sees an "STI ROM" at 0xF8000000 (must bus-error) |
| 2 | FB window 8 MiB (1353-1354) | region list says 16 MB |
| 3 | CPU writes/reads use `vram_buffer[B]`; only B = 1, 6, 7, 13, 15 exist (1398-1404) | **all HP STI CPU accesses use B = 2 -> dropped / read 0**; init_graph fails the probe (errno 12) |
| 4 | Reads: only 0x3BA0, 0x13A0, 0x2EA0; 0x2EA0 returns 4 pixels (885-905) | probe needs a 32-pixel bitmap; state area needs 0x1360 reads (also breaks Linux fb reads) |
| 5 | 0x1360 writes ignore size (825-828); `write4` skips the data shift for masked bytes (770-774) | byte stores to the state area corrupt neighbours |
| 6 | Display = staging entries 0x100-0x1FF (1307); 0x300118 and 0x100480 not modelled | HP stages at 0..0xFF and loads via 0x300118 -> wrong/black palette |
| 7 | MISC_VIDEO read replaces bits 15:8 with `height & 0xFF00`, toggles bit 18 (1198-1205) | corrupts the monitor index (bits 15:12) used by init_graph and sti_sync_on; bits 11:8 should be (vactive-1)>>8 |
| 8 | 0x300200 writes forced to 0x00202000 (1064-1068) | self_test computes the wrong width -> errno 12; X cursor offset hack |
| 9 | 0x300208 read replaces [31:24] with `height & 0xFF` (1191-1196) | should be (vactive-1)&0xFF (off by one) |
| 10 | 0x30023C always 0xAC4FFDAC (1211) | only 1280-wide passes self_test |
| 11 | No 0x300300, 0x300204, 0x300118, 0x100088, 0x1004C0/0x100520/0x100580, 0x1007C0, 0x118020-0x118034, 0x118024; 0x100000-0x10008C read 0, writes logged | state_mgmt round trip lossy; init_graph register writes ignored |
| 12 | 0x380004 constant 0x6DC20006 (1215-1217) | reset completes instantly (fine); be_timer bit not writable |
| 13 | Block move ignores BA modes (no recolouring), plain byte copy (383-448) | STI `block_move` with `flags.color` draws the wrong colours |
| 14 | Fill colour = IBO bit 1 ? FG : BG; TRANSFER_DATA ignored (260-267, 450-489) | consistent with HP's use |
| 15 | INCR_X in 0x2EA0 advances 1 pixel (836-840) | wrong for glyphs wider than 32 |
| 16 | CONTROL_PLANE != 0 -> fill/move skipped (394, 462) | matches Linux's attribute set-up need |
| 17 | `case 300104:` decimal typo (1118) | harmless |
| 18 | Invented 0x211110 resolution register (1165-1170) | SeaBIOS only |
| 19 | realize enables video (0x0A000000) and MISC_CTRL 0x00800000, IBO 0x23000300, PLANE_MASK 0xFF (1418-1425) | real reset state is presumably 0 |
| 20 | Cursor 32x32 of 64x64 (106) | X cursor clipped |

Ambiguities and the evidence for each reading:

* **Buffer 1 vs 2** — single shared 8-bit buffer (0.1). Counter-reading:
  separate overlay; rejected because the ROM combines text and non-text
  colours of the same pixel in the LUT and Linux does not clear buffer 2.
* **Otc32 read bit function** — ROM only needs "0x00 -> 0, 0xFF -> 1";
  `|(pixel & PLANE_MASK)` is the cheapest consistent choice.
* **Fill colour** — QEMU's IBO-bit-1 rule vs. "TRANSFER_DATA bit -> FG/BG";
  identical for every HP call. QEMU's rule was tuned on HP-UX's X server;
  resolving it for X needs the X server binary (see 6.3).
* **0xF8300004 bit 25 (HP-UX) vs 0xF8380004 bit 25 (ROM)** — HP-UX's
  sti_sync_on uses region 2 + 0x200004 where the ROM uses region 3 + 4;
  reading 0 there is safe.
* **Reset scope of 0xF8380004 bit 8** — must preserve MISC_VIDEO and VRAM
  (4.6); clears bits 24, 25 (the ROM re-sets 24 itself).
* **MISC_CTRL bit 23** — Linux's display enable; HP's ROM never sets it ->
  do not gate the display on it.
* **artist_graphics_registers.html** — "0x380008 returns 0x20000000" and a
  colour map at "0x0118406C-0x011847FF": neither is used by the 715 ROM
  (perhaps the 712's STI or a misreading).

---------------------------------------------------------------------------

## 6. Implementation plan

### 6.1 Milestone 1: PDC 1.6 boot console on Artist

Address decode and bus behaviour:
* Answer 0xF8100000-0xF8380FFF and 0xF9000000-0xF9FFFFFF; bus-error
  0xF8000000-0xF80FFFFF (and, recommended, the rest of 0xF8000000-0xF8FFFFFF);
  byte-enable support on registers; MIOC `HAS_ARTIST` = 1.
* Reset from LASI IORESET bit 8: registers 0, MISC_VIDEO 0, busy 0, 0x380004 =
  0x6DC20006.

VRAM and CPU window:
* 2048 x 1024 x 8 VRAM (DDR3 per the project's memory placement), off-screen
  area preserved.
* CPU writes: modes 0x1360 (byte enables), 0x2EA0 (FG/BG, transparent BG,
  BINC-mask enable), 0x3BA0 cmap staging (buffer 15). Reads: 0x1360 (bytes and
  words), 0x2EA0 (32-pixel bitmap). Buffers 1 = 2.
* PLANE_MASK and ROP 3 (implement all 16 rops — cheap).

Engine:
* Registers 0x118000-0x11803F (with 0x118000 -> DST+SRC, read-backs
  0x118020-0x118034), BINC 0x100480/0x1004A0/0x1004C0/0x100520/0x100580/
  0x1005A0, data ports 0x100600 (+x) and 0x100620 (+y), 0x1007C0.
* Rect fill (0x100800 + 0x100A04, TRANSFER_DATA, colour rule of 2.3),
  block move (0x100808, 0x100804, 0x100B00) with overlap handling, plane mask,
  and the 0x28A0 -> 0x2EA0 recolouring variant.
* State words 0x100000-0x10008C as plain storage.
* Busy (0x300000/0x380000 bit 24), FIFO 0x300008 >= 16, stall-while-busy.

Video:
* MISC_VIDEO full 32-bit storage; video on = bits 27 and 25.
* 0x300200/204/208 storage; hactive/vactive from MISC_VIDEO + reg19/reg20;
  fixed output timing (e.g. let the MiSTer scaler take the native mode, or a
  fixed 1280x1024 raster with the active area placed inside) — the exact
  porches/pixel clock (0x300300) can be ignored at first.
* Staging line (>= 512 x 24 bit, x 0..511) + LUT RAM (512 x 24 bit, two
  LUTs) + the 0x300118 copy; display LUT0[pixel].
* 0x300300, 0x300308, 0x300100, 0x300104, byte 0x300004-7, 0x380004 bits,
  byte 0x380007 = 0x06.
* Signature: 0x300238 done at once, 0x30023C = constant per hactive (3.7).

Firmware side: EEPROM image with console path = graphics (S-016) and monitor
type 0 (default 1280x1024@72) or 5 (1280x1024@60).

Checks against the ROM (sim): `init_graph` returns 0 with errno 0 (not 21),
MISC_VIDEO = 0xEBC00341 after cold init with monitor 1 (0xEB800301 | 2MB |
idx 1 in bits 7:6), byte 0x300007 = 1, LUT0[0..7] = the eight text colours,
self_test returns 0, text appears with font_unpmv and scrolls with block_move.

### 6.2 HP-UX kernel console (ITE)

Nothing beyond 6.1 except: 0xF8300004 readable (bit 25 = 0), sti_sync_on's
MISC_VIDEO read-modify-write, state_mgmt save/restore, the warm path (reset
preserving MISC_VIDEO/VRAM), the colour-change block move if the ITE uses
it, and at least three init_graph calls per boot (06c 3), each running the
reset (0x100) and, if the index changed, a full timing reprogram.

### 6.3 What X11 additionally needs (largely from QEMU's model, unverified)

* Linux/X CPU modes 0x13601000 (byte) and 0x13A01000, BINC cmap writes in
  0xBBE0F000 (0x1004A0 + 0x100600), LUT loads from src 0x400.
* Attribute planes (buffer 13, CONTROL_PLANE) at least as no-ops that leave
  the image untouched; per-pixel LUT select if X uses LUT1.
* FONT_WRITE_START / FONT_WRITE_INCR_Y, line drawing (LINE_XY, LINE_SIZE,
  LINE_END, PATTERN_LINE_START), the 0x100080 = 0x7D auto-increment, the
  0x100A00 / 0x100B04 trigger variants, all ROPs.
* Hardware cursor: buffers 6/7 (64x64 x 2 bits), CURSOR_POS/CTRL, X11R6.6
  position maths (artist.c:316-362) using reg19's porches.
* Fake vblank (MISC_VIDEO bit 18 toggling) if X polls it [Q].
* The open questions here (fill colour rule, Otc32 read function, attribute
  semantics, which registers X really touches) can be settled by
  disassembling HP-UX 10.20's X server Artist/NGLE driver from
  `disks/hpux1020.img` with `tools/hpux/som.py`, or by tracing it on QEMU
  `-M B160L` with `-trace artist_*`.

### 6.4 STUBS entries this design implies

Signature constant at 0x30023C; PLL 0x300300 ignored (output timing not from
M/N); unknown registers stored without effect (0x100000-0x10008C,
0x1004C0/0x100520/0x100580, 0x300204, MISC_CTRL bits); 0x380004 bus-error
timer never fires; attribute planes and LUT1 not displayed; cursor (until X).
