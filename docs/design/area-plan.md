# Area plan: ALM headroom for the whole core (2026-10-14)

The design sits at 37,287 of 41,910 ALMs (89 %, build 47) and build 34
(+40 ALMs) did not route. Goal: 1,500-2,000 ALMs back from our own logic,
every clock still meeting timing, no framework feature switched off.

Numbers from `output_files/HP9K715.fit.rpt` (build 47, Fitter Resource
Utilization by Entity). Savings are estimates (Cyclone V: a 2:1 mux of n
bits is about n/2 ALMs, a k:1 mux about n * k/4, an n-bit equality compare
about n/5, a bare flop packs for free beside logic but every 4 unpacked
flops cost an ALM). They are to be measured one change at a time: a
per-module `quartus_map` + `quartus_fit` in a scratch project (as
`scratch/artist_map`; ~5 min) before the full compile (~35 min).

## Where the non-CPU ALMs are (build 47)

| entity | ALMs | regs | notes |
|---|---|---|---|
| pa_cpu | 13,793 | 15,958 | off limits (pa_tlb 5,021 / 7,015 regs; pa_core 2,861 own; pa_fpu engine 1,974) |
| artist (own) | 3,233 | 2,976 | + artist_video 431 / 981 |
| ncr53c710 | 2,171 | 1,903 | no RAM at all: the diagnostic FIFO is 576 flops |
| mioc | 2,102 | 3,309 | 32 x 32-bit comparator/mask registers = 1,024 flops, decoded twice |
| scsi_targets (own) | 1,401 | 876 | + cd_audio 505 / 530 |
| i82596 | 1,259 | 1,537 | 13 x 32-bit pointers, 3 copies of the DMA word |
| hp715 (own) | 978 | 1,529 | the debug recorder: 15 one-deep 112-bit slots and their 15:1 mux |
| harmony | 774 | 843 | G.711 decoder built twice |
| ps2_dev x 2 | 368 + 322 | 222 + 220 | a 16-byte queue with three write ports |
| lasi (own) | 373 | 486 | clkreg[4] in flops, the read mux |
| ddr3_port | 365 | 507 | |
| lasi_fdc | 247 | 313 | |
| sdram64 | 220 | 561 | |
| lasi_uart / trace_ddr3 / serial_term | 167 / 160 / 150 | | |

## Measured so far (per-module scratch fits, `scratch/mioc_map`, `scratch/artist_map`)

| change | module alone before -> after | registers |
|---|---|---|
| A1 (MIOC comparators, shared decoder) | 2,760 -> 2,298 ALMs (-462) | 3,085 -> 2,388 |
| A3 + A4 (Artist aligned CPU reads, launch captures) | 4,005 -> 3,831 ALMs (-174) | 3,640 -> 3,410 |
| A7 (Harmony: one G.711 decoder, time-shared) | 940 -> 971 ALMs (**+31**: Quartus already shared the two calls; dropped, `scratch/harmony_a7`) | 792 -> 826 |
| B1 (the recorder behind `HP9K715_DEBUG`, build 49) | `hp715` own 951 -> 28, `trace_ddr3` 160 -> 0, the 53C710/82596 debug outputs pruned | |

## Ranked list

Rank by expected saving per unit of risk. "Bench" = what proves the change
(`make -C verilator tb_xxx`; `tests/run-rom.sh` = HP's ROM to BOOT_ADMIN,
which runs the MIOC, SCSI and Artist self-tests; romsim = HP-UX boot).

### Tier A: large, low risk, bench-covered (about 1,700 ALMs)

| # | change | where | est. ALMs | risk | bench |
|---|---|---|---|---|---|
| A1 | **MIOC comparators**: keep only the decoded bits in flops (`r_comp[31:23]`, `r_mask[28:22]`: 16 x 16 = 256 flops instead of 1,024), the full 32-bit words in a 32 x 32 MLAB for read-back (one extra cycle on a MIOC register read, S_IDEC already registers), and one shared `blk_decode` instead of two (S_LDEC / S_IDEC are exclusive) | `rtl/mioc.sv:112-153, 269, 351, 433, 480-481` | 400-500 | low-medium: the ROM's MIOC register test reads them back; HP-UX writes them at boot | run-rom.sh, romsim HP-UX |
| A2 | **53C710 diagnostic FIFO** as one 64 x 9 MLAB (`{lane, ptr}`), pointer-based counts, one read port | `rtl/scsi/ncr53c710.sv:90-92, 135, 288-295` | 150-250 | low: the ROM's SCSI INIT test pushes/pops all 4 lanes (HARDWARE.md 4.5) | run-rom.sh (no unit bench) |
| A3 | **Artist CPU reads**: align the words as they arrive (one 128->64 byte shifter on `{prev, cur}`) instead of `rw[5]` + a 320-bit barrel shifter | `rtl/artist/artist.sv:286, 414-426, 735` | 200-300 | low | tb_artist (long-mode 4-pixel read, bitmap read, probe reads) |
| A4 | **Artist launch captures**: drop `lq_wh/lq_sxy/lq_xfer/lq_end/lq_d/lq_be` (at E_LAUNCH they equal `lenxy/srcxy/xfer/dstxy/g_wdata/g_be`, which G_DEC updates in the same cycle); keep `lq_dxy` (the old DST of a vector) and a 1-bit "end is LEN" flag; `e_pat2` 32 -> 16 bits | `artist.sv:262-267, 865-870, 924-1015` | 100-150 (and 180 flops) | low | tb_artist (fills, moves, font, lines, dashes) |
| A5 | **Artist plain-storage registers** (`r4c0 r520 r580 r204 r238 r23c pll misc_ctrl r300004 ibo ctl_plane`) into a second small MLAB read like `st_q` (G_RD is already a cycle later); keep 2 flag bits of `ctl_plane` (== 0, bit 24), 2 of `r100080` (== 0x7D / 0x08) and the ibo bits the engine uses | `artist.sv:87-93, 440-473, 553-676` | 150-250 (and ~350 flops) | low-medium: the ROM self-test reads them back | tb_artist (register read-back), run-rom.sh |
| A6 | **ps2_dev queue**: a 3-byte staging register feeding a single-write-port FIFO (MLAB), so the 128 queue bits lose their 3 address compares + 6-way data mux each; BAT via the same path; `gap`/`bat` counted in BYTE_CLKS units | `rtl/lasi/ps2_dev.sv:35-47, 129-178` | 250-300 (both) | low-medium: bytes appear 1-2 clocks later behind a 1 ms gap; the mouse has no bench | tb_ps2dev (keyboard), romsim/board for the mouse |
| A7 | **Harmony G.711**: one decoder time-shared L then R (or a 512 x 16 ROM in one M10K feeding both) | `rtl/lasi/harmony.sv:101-120, 230-231` | 80-150 | low (A-law untested in the bench; tables from the same functions) | tb_harmony |
| A8 | **53C710 DMA staging**: `dma_wdata` straight from `wb_data` (never changes while a DMA is out), `d_*` as the `dma_*` registers, `d_rdata` 32 bits | `ncr53c710.sv:176-210, 359, 470` | 60-100 | low: the request starts a cycle earlier | run-rom.sh, romsim |
| A9 | **i82596 trims**: merge `n_wd`/`n_rd`; `m_wd`/`m_be` combinational; drop `iscp` (`m_base` still holds it), `sg_tag`, `port_lo`; `tick` 16 bits; the `m_a + 4` / `m_a + 2` adders through the shared one | `rtl/lasi/i82596.sv:109-152, 226-228, 296-297, 389, 472, 538-543` | 130-180 | low | tb_i82596 (82 checks) |
| A10 | **scsi_targets counters**: `d_idx`/`d_left` 16 -> 10 bits, `x_blocks` 32 -> 19, `ms_i` saturating 10; one `min(alloc, rl)`; one `sd_lba`/`sd_blk_cnt` for the three slots; frame numbers 24 -> 19 bits (also cd_audio); `toc_wd` staging dropped; `q_abs_lba` = `cur` | `rtl/scsi/scsi_targets.sv:58-59, 118-145, 491-552, 679`; `cd_audio.sv:39, 79-82, 102, 177, 199` | 120-200 | low | tb_cdaudio (CD paths), run-rom.sh + romsim for the disks |
| A11 | **MIOC small**: one `pt_find` (line fill stage 2 and the uncached read never coincide), one `ecc_of` with a muxed input, `rb`/`wbuf` as MLAB (they are flops because of the asynchronous reads) | `mioc.sv:188-193, 223-242, 308, 358, 532, 560` | 120-200 | low | run-rom.sh (ECC self-tests), romsim |

### Tier B: medium (about 500-900 ALMs more)

| # | change | where | est. ALMs | risk | bench |
|---|---|---|---|---|---|
| B1 | **Debug recorder**: a `DBG_EVENTS` parameter so a release build leaves the slots, the 15:1 x 112 mux, the trigger logic, `trace_ddr3` and the 53C710/82596 debug outputs out (debug builds keep them); or restructure (events whose data is a stable mirror -- 15, 16, 18 -- read it at output time instead of holding a slot) | `rtl/hp715.sv:440-586`, `HP9K715.sv:312`, `ncr53c710.sv:114`, `i82596.sv:62-65` | 400-700 (parameter) / 150-250 (restructure) | the user's call: the recorder is in daily use | board tools |
| B2 | **Artist pattern pre-rotation**: rotate `e_pat`/`e_mask` by `p1_d[4:0]` once in the pipeline register instead of eight 32:1 muxes per lane | `artist.sv:362-412, 805` | 80-120 | low-medium (a longer path into p1; artist is at +0.4 ns) | tb_artist |
| B3 | **53C710 register writes** through one byte-write port (host / RMW result / memory-move byte) | `ncr53c710.sv:268-322, 408-423, 632-637` | 50-100 | medium: a host write and an engine write in one cycle | romsim |
| B4 | **scsi_targets response templates** (INQUIRY strings, MODE SENSE pages) from an M10K with patch codes instead of the `syn` case logic | `scsi_targets.sv:182-358` | 150-250 | medium: INQUIRY / REQUEST SENSE / disk MODE SENSE have no bench | run-rom.sh, romsim |
| B5 | **cd_audio M:S:F** on demand with one converter | `cd_audio.sv:92-146`, `scsi_targets.sv:497-509` | 50-110 | medium | tb_cdaudio |
| B6 | **Harmony record path**: one masked DMA write per sample instead of the `rb_d`/`wq_d`/`dma_wdata` chain | `harmony.sv:236-262` | 60-80 | medium | tb_harmony (loopback) |
| B7 | **LASI**: `clkreg[4]` in an MLAB (values then survive a warm reset), `eir_addr/data` from `iar`, `rtc_pre` 26 bits; a shared millisecond tick for the `gap`/`bat`/`tcnt`/`ms_div` counters | `rtl/lasi/lasi.sv:91, 158-165, 224, 251, 280`; ps2_dev, lasi_ps2, lasi_fdc | 100-150 | low-medium (no LASI unit bench) | romsim, board |
| B8 | **53C710 ADDER / dbg_dsp**: drop the informative `dsa + dbc` adder if the ROM's register mask excludes it (check `f002e0a4`); export `dsp` raw to the recorder | `ncr53c710.sv:96, 114, 146` | 30-40 | low once checked | run-rom.sh |

### CPU-side ideas (not to be done without the user's approval)

- `pa_tlb` (5,021 ALMs, 7,015 flops): the 64 entries' payload ({rpn, ar,
  aid, t, d, b, u} = 46 bits) is in flops selected by the one-hot hit; in an
  MLAB indexed by the encoded hit it would be ~2,900 flops and a 64:1 x 46
  mux less (est. 600-900 ALMs), at the cost of an encode step on the hit
  path (cpu-timing.md 4.9 splits the lookup across E/M, so there may be
  room). The block entries' TRANS/mask compares stay.
- `pa_fpu` engine (1,974): the iterative divide/sqrt and the multiplier
  are already shared; the FR file is MLAB. Little to take.
- `pa_core` (2,861 own): the shadow registers and the walker's state.

## Order of work (proposed)

Each step: edit, unit bench, per-module scratch fit for the number, then
the full compile, logged in `docs/design/system.md` section 10 with the
entity's ALMs before/after; STUBS.md entries where a simplification is made.

1. A1 MIOC comparators (biggest single win, one file).
2. A3 + A4 Artist (tb_artist), then A5.
3. A2 + A8 53C710.
4. A6 ps2_dev, A7 Harmony, A9 82596.
5. A10, A11.
6. Tier B as the user picks.
