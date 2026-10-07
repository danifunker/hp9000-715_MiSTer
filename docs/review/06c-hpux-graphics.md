# HP-UX 10.20 graphics stack (graph3, sti_*, framebuf, ite) on a 715/64 with Artist

From a disassembly of the HP-UX 10.20 kernel (`vmunix` from the QEMU disk
image; kernel virtual addresses) and HP's PDC 1.6 ROM. Part of the OS track
(`06-os-hpux-linux.md`).

**Bottom line:** HP-UX claims the Artist by IODC SVERSION alone; everything
else goes through STI routines copied from the boot ROM's STI image into
kernel RAM. Outside STI the kernel touches only five Artist registers, all in
`sti_sync_on` (0x1737d0). No graphics interrupt is registered. Block-TLB use
is optional.

Helper scripts (session scratchpad `drivers/graphics/`): `ext.py` (function
extraction), `crc.py` (HP-UX STI CRC check run on the real ROM), `ioctls.py`
(framebuf ioctl table), `findref.py` (function pointers in data).

## 1. Finding and claiming the Artist

- `graph3_link` (0x4fa30) saves `core_attach` (in 0x447430) and installs
  `graph3_attach` (pointer at 0x3febd8); `graph3_install` (0x4fa60) registers
  `DS$` (0x3fec48) as "graph3", class "graphics".
- `graph3_attach` (0x1824d0) accepts only id **0x77 or 0x85**
  (0x1824ec/0x1824f8); `fio_mod_init` (0x1893e8) applies the same test early
  in boot. HVERSION and the STI graphics ID are not used for the claim.
- **STI ROM address** (`graph3_init_grp` 0x1e2a58): for 0x85,
  `pa_next_reg_set(HPA)` (0x1dcfb0) = the first PDC_SYSTEM_MAP additional
  address from `fixed_mod_table` (+0x18, PDC 22 option 1); if 0,
  `load_real(PAGE0+0x604)` (0x1e2acc). `graph3_uses_pa_int` (0x1892f8) and
  `graph3_record_io_space` (0x189544) read 0x604 too. Register base =
  `isc->c0` = HPA 0xF8000000 (`g->1ac`). For 0x77 the ROM is at the HPA.
- HP's PDC writes **0xF0024000** to 0x604 (ROM f001f24c-f001f25c); the real
  715/64 inventory has 0 additional addresses for graphics, so the PAGE0 path
  is the one used.
- Identification reads: ROM byte 3 = 3 (word mode; 1 = byte mode); bytes 6-7
  revision 0x84/0x07 (>= 0x88 would allocate `sti_mem_req` and a
  `glob_cfg_ext`); word 0x08 graphics ID 0x2B4DED6D via `sti_get_gcid`
  (0x1733f8) -- quirks, `crt_id`, BTLB hints only; word 0x34 bus_support /
  ext_bus_support via `sti_get_bus_support` (0x2361f0) -- both 0.

**Real STI image at 0xF0024000:** type 03030303; 0x0D monitors; revision
0x84/0x07; graphics ID 2B4DED6D 40A00499; font start 0x37d4; state size 0x1b
words; last_addr 0x47e5; region list 0x37c0; monitor table 0x2c0; user data
0x328; routine offsets 0x808, 0x1fc4, 0x2248, 0x27d4, 0x2b20, 0x329c, 0x33a8,
0x362c, 0x37c0, 0.

## 2. STI ROM handling

- `sti_idrom_byte` (0x172f10): `ldw` of `rom + (off & ~3)`, low byte (byte
  4k+3, `Sti.txt` 1364-1560). Word-mode callers use plain `ldw` -- **the ROM
  must return correct 32-bit word reads.**
- **Region list** (`sti_read_region_list` 0x172ab8): up to 8 descriptors at
  `rom + word[0x1c]`, stop at "last". Layout: offset pages [31:18], sys_only
  17, cache 16, btlb 15, last 14, length pages [13:0]. Descriptors ->
  `inq+0x34[]`, physical addresses -> `inq+0x64[]` (= `glob_cfg.region_ptrs`).
  Region 0 relative to the ROM base, others to the HPA.

| # | descriptor | address | size | flags |
|---|---|---|---|---|
| 0 | 0x00008006 | 0xF0024000 (ROM) | 6 pages | btlb |
| 1 | 0x40009000 | 0xF9000000 (frame buffer) | 16 MB | btlb |
| 2 | 0x04008280 | 0xF8100000 (control) | 0x280 pages | btlb |
| 3 | 0x0E024001 | 0xF8380000 | 1 page | sys_only, last |

  SeaBIOS uses the same list (`stirom.c:41`).
- **CRC** (`sti_check_crc` 0x1728d8; skipped only if `sti_no_crc` 0x44401c,
  default 0): big-endian 16-bit units from offset 0 through the word holding
  `last_addr` (`word[0x18] & ~3`); per unit `x = unit ^ crc`, 16 times:
  `x & 0x8000 ? ((x<<1)|1) ^ 0x8408 : x<<1`; result must be 0 (it is for the
  real ROM; SeaBIOS `update_crc` is the same). For a custom ROM: `last_addr`
  odd, CRC at `last_addr-1`, zeros after it to the end of the word. A failure
  in `sti_unpack_routines` fails the attach; `sti_pwr_reset` re-checks
  (0x186adc) and **panics** ("CRC check of STI rom failed").
- **Copying routines** (`sti_unpack_routines` 0x172f60): 14 offsets (word
  mode 0x40-0x74, low 2 bits masked; byte mode 0x100+16i). For i = 0..12:
  `off[i]==0` -> "Null pointer in STI rom"; `off[i+1]==0` -> routines i..12
  become `sti_null_routine` (0x235e80, returns -1); else kmalloc
  `off[i+1]-off[i]` (+0xc8 for init_graph), copy words, `inq[i]` = copy;
  `sti_patch_init` (0x237278) only patches byte-mode ROMs; flush I/D cache.
  The 715 ROM gives routines 0-7; 8-12 null. **Routines must be contiguous,
  in table order, position-independent and self-contained** (SeaBIOS notes
  this at `stirom.c:30`).
- **Fonts** (`sti_get_fontdata` 0x172d18, `ite1_get_fontrom` 0x1725e0):
  walk from `rom + word[0x10]` via `next_font`; ITE needs `glob_cfg`
  onscreen x/y (inq+0x58/0x5a) and total x/y (+0x60/+0x62) non-zero (init_graph
  fills them); matches the monitor-table entry (x [31:20], y [19:8],
  hz*2+vesa [7:0], byte 7 font hint) and needs a type-1 font. The real ROM
  has one 8x16 font, 256 characters, 16 bytes each.

## 3. STI calls

`sti_call_routine` (0x14bb48): `inq[idx](flags, in, out, &glob_cfg)` with
`glob_cfg = inq+0x54`, via `be,l 0(sr4,...)` -- virtual mode, kernel space,
RAM copy; `region_ptrs` are physical I/O addresses mapped V=P. idx 2/3 first
call `sti_device_wait` (no-op for Artist). **Every init_graph is followed by
`sti_sync_on`**; `ite_sti_call_routine` (0x2312f0) wraps the same.

| routine | callers (flags) |
|---|---|
| init_graph (0) | `g3_init_display` 0x175644 **0xCF,0x02** (wait, reset, clear, cmap_blk, be_timer, be_int, retain_ie; text_planes=3) -- failure: claimed but dead (state 4), no ITE; `crt1_init` 0x180134 **0xEC,0x32** -- -1 => **panic "STI routine failure"**; `sti_reset` 0x501f4 **0xA0,0x78**; `sti_pwr_reset` 0x186be8 **0xFC,0x32**; `sti_set_state`, `g3_reset` |
| state_mgmt (1) | `sti_restore`, `sti_save_restore`, `framebuf_save/restore_state` (0x6c bytes) |
| font_unpmv (2) | `sti_write_rom` 0x14bdf0 |
| block_move (3) | `sti_clear` 0x143ef8, `sti_scroll` 0x14b844, `sti_write_rom` |
| excep_hdlr (5) | `graph3_isr`, `sti_int_control`, `sti_set_eim`, `sti_save_restore` (inactive on a 715) |
| inq_conf (6) | `g3_describe_data` 0x186e50 |
| self_test (4), set_cm_entry (7) | not called by the kernel |
| 8-12 | ioctl wrappers only; null with the 715 ROM |

**inq_conf outputs used** (`graph3_set_inquiry_parms` 0x1886e8): onscreen x/y
(out+4/+6), total x/y (+0xc/+0xe), pitch = total_x*4 (4 bytes per pixel in
the aperture, 8192-byte line stride -- QEMU: x = (addr>>2)&0x7ff,
y = addr>>13), bpp (+0x10), bits used (+0x14), planes (+0x18), name (+0x1c),
attributes (+0x3c). SeaBIOS returns 2048 wide, 8 bpp, attributes 0x1836; the
real ROM's user data also has 0x1836.

## 4. Block TLB and I/O mapping

1. `graph3_record_io_space` (from `fio_mod_init`) fills `graf_pdirmem_info[]`
   (0x2b8 bytes, up to 6 entries: ROM, HPA, region list).
2. `graph3_update_btlb_hints` (0x189620) builds `graf_btlb_hints`: one entry
   per HPA-relative 16 MB chunk touched by a btlb region.
3. `graph3_map_io_space` (0x69a90, via pointer 0x3fcc54):
   `graph3_mark_btlb_entries` (limit `graf_max_btlb_entries` = **2**), the
   rest page-mapped with `map_io_space`.
4. `graph3_alloc_btlb` (0x5aad0) -> `btlb_alloc_graphics(0, HPA+chunk, 16 MB)`
   (0x18c680): needs `btlb_graphics_enable`, VA >= 0xF0000000 4 KB aligned,
   power-of-two size within `btlb_minsz..btlb_maxsz` from PDC_BLOCK_TLB (18)
   option 0 (`btlb_map_init` 0x185ba4); inserted with PDC 18 option 1
   (`btlb_insert_entries` 0x168b40).
5. On failure the 16 MB chunk is page-mapped (0x5af04) -- **PDC_BLOCK_TLB is
   optional.** Expected (not traced end to end): two 16 MB entries,
   0xF8000000 and 0xF9000000.

## 5. Interrupts

`graph3_init` (0x16a930) decides from `bus_support`: GSCINTL (0x01) on
PA-7300LC -> `lasi_ext_isc` / `graph3_lasi_ext_isr`; GSCINTL on other CPUs ->
`isrlink(graph3_isr, -1)` + `graph3_connect_IntL` (EIRR bit from
`pa_apply_for_interrupt` only if `graph3_uses_pa_int`; `get_GSC_eim_regaddr`
needs a 0x580/0x581 parent, so it fails on a 715); 0x08 Summit; 0x80 PCI;
none + SVERSION 0x77 -> `isrlink(..., 0x13/0x14)`. **With the 715 ROM
(bus_support 0, SVERSION 0x85) nothing is registered.** `graph3_isr` only
calls excep_hdlr. `graph_vertblank_wait` needs bus_support 0x10 (else
EINVAL); the kernel never waits for vblank and never calls set_cm_entry --
colormap updates are user space through the mapped registers. (Attach-time
init_graph passes `enable_be_int`, but nothing services it.)

## 6. Direct Artist register access (only `sti_sync_on` 0x1737d0, ID 0x2B4DED6D; regs = region 2 = 0xF8100000)

| R/W | address | use |
|---|---|---|
| R | 0xF8300004 | poll; exit when bit 25 (0x02000000) set |
| R | 0xF8300000 | poll; exit when bit 24 (busy) clear; timeout 0x7FFFFF iterations, no clock, continues after timeout (same loop in the ROM at f0024f48) |
| R | 0xF8300218 (MISC_VIDEO, reg21) | `idx = ((v>>12)&0xF)<<2 \| ((v>>6)&3)` |
| R | ROM word 0x28 (user data) | `rec = rom + userdata + (idx-1)*0x60` |
| W | 0xF8300200 (reg19) | `rec[0x30]` |
| W | 0xF8300208 (reg20) | `rec[0x38]` |
| W | 0xF8300218 | `(v & 0x00FFF0F0) \| (rec[0x4c] & 0xFF000F0F)` -- restores video-enable bits 0x0A000000 and sync bits |

- 13 records at ROM 0x328-0x807, one per monitor (the header's
  user_data_size 0x138 understates this). Index 1 (1280x1024 @ 72 Hz):
  reg19 = 0x3f2f2f0f, reg20 = 0xff3c0202, MISC_VIDEO top/low = 0xEB000301.
- The ROM's init_graph stores the monitor index in MISC_VIDEO [15:12] and
  [7:6] (`sti_code.dis` f00255c4-f0025608) and uses the same record formula
  (f0025340).
- **QEMU conflict:** QEMU's MISC_VIDEO read (`artist.c:1198`) overwrites bits
  15:8 with the screen height and toggles bit 18 -- with HP's ROM that
  corrupts `idx`. QEMU also returns 0 for 0x300000/0x300004.
- **SeaBIOS risk (unchecked):** SeaBIOS's STI never writes the index, so
  `idx` = 0 and HP-UX reads a "record" at user_data - 0x60 -- garbage in the
  MISC_VIDEO top byte could blank the display.

## 7. framebuf

- Ioctl table 0x29dd0, 47 'G' commands, `blr` dispatch at 0x14a644.
- **GCDESCRIBE** (0x40704715, handler 0x149f14) copies `g+0x1d4` (0x70
  bytes): crt_id 0x2B4DED6D; map_size = region 1 = 16 MB; x, y, total x/y;
  pitch total_x*4; bpp/bits_used/planes; x*y; name[32], attributes;
  frame_base 0xF9000000; control_base 0xF8100000; region[] = {0xF0024000}
  (filled by `graph3_set_region_values` 0x18e060).
- **GCMAP** ('G' 5): `ioblk_grant(frame_base)` on the block from
  `graph_ioblk_init` (0x17f4d8): {0xF0024000, 0x6000}, {0xF9000000,
  0x1000000}, {0xF8100000, 0x280000}. The sys_only page 0xF8380000 is never
  mapped to user space.
- Monitor-type ioctls ('G' 51/52) -> `graph_montype`: PDC 0x93, a model-string
  table without the 715, then PDC 0x81; on a 715 they return 0xdf (not fatal).

## 8. ITE (console)

`graph3_init` -> `ite1_graph_init` (0x17ea40; Artist sets `ite->1b58 = 1`)
-> `ite1_init` (0x17b5e0) -> `crt1_init` (init_graph, STI ITE procedure
table 0x3fd6b0, `sti_dd_alloc`, `ite1_get_fontrom`, `ite1_calc_screen`). The
Artist is always initialised and drawn on, even with a serial console.
`ite1_cons_dev_init` (0x17c2d0) only when `cons_mux_dev` (from `kdt_modify`)
has major 0xE5 and this select code. `ite_beep` -> `kbd_beep` (0x18da78)
does not touch the Artist (see `06a-hpux-harmony-audio.md`).

## 9. FPGA requirements

**Must:**
1. IODC module at HPA 0xF8000000, type 10, SVERSION **0x85**.
2. PDC_SYSTEM_MAP reports 0 additional addresses for graphics (or the first
   is the STI ROM base); **PAGE0+0x604 = STI ROM base** (0xF0024000 with HP's ROM).
3. Word-readable, word-mode STI ROM with: valid CRC per section 2;
   contiguous, position-independent routines 0-7; the region list above;
   bus_support 0 and revision < 0x88; graphics ID 0x2B4DED6D/0x40A00499; a
   type-1 font; a monitor table and the 13 user-data records. **The ROM must
   never change** (CRC re-check panics in `sti_pwr_reset`).
4. STI routines return 0 on success (-1 from init_graph in `crt1_init`
   panics); init_graph fills glob_cfg onscreen/total; inq_conf fills its
   output.
5. MISC_VIDEO (0xF8300218) reads back as plain storage (at least bits 31:24,
   15:12, 7:6, low nibbles); 0xF8300200/0xF8300208 writable.
6. Busy (0xF8300000 bit 24) clears promptly, or 0xF8300004 bit 25 is set --
   else each init_graph (>= 3 in a boot) spins up to 8M I/O reads.
7. Decode the frame buffer 0xF9000000 (16 MB, 4 bytes per pixel) and control
   0xF8100000-0xF837FFFF, and respond on the 0xF8380000 page.
8. Artist asserts no interrupt (neither GSC INTL nor LASI external bit 10).

**May:** leave out PDC_BLOCK_TLB (page-table fallback; if implemented,
accept 16 MB entries); null STI routines 8-12; leave out PDC 0x93/0x81; no
vblank interrupt; skip self_test and set_cm_entry as far as the kernel goes
(the X server is a separate question).
