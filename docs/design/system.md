# System design -- everything around the CPU

The HP 9000/715/64 as built here: the memory and I/O controller (MIOC), the
address decoder for the whole F-space, LASI and its units, the 8-bit bus
(boot ROM, EEPROM, LEDs, board ID), the WAX stub, Artist, clocks, reset,
interrupts and TOC. The CPU is `docs/design/cpu.md`; its ports (cpu.md 6.8)
are this side's interface. What the ROM and the OSes demand is argued in
`docs/reference/rom/HARDWARE.md` (HW), `BOOTFLOW.md` (BOOT), `FIRMWARE.md`
(FW) and `docs/review/06*.md` (R06); this note says how we meet it. Every
simplification is in `docs/STUBS.md`.

Status: 2026-10-07, written before the RTL; sections marked *(later)* are
the plan for steps that have not been built.

## 1. Block diagram

```
                       +-------------------- hp715.sv (one clock, clk_sys) -----------------------+
 cfg (model, RAM) ---> |  pa_cpu --mem_* (line port)--+                                          |
 soft power, TOC  ---> |    ^  \--io_*  (uncached)----+--> mioc.sv --ram_*--> system RAM (SDRAM)  |
                       |    |                         |     | |     \-rom_*--> boot ROM (DDR3)    |
                       |    +-- eir/toc/hpmc/lpmc ----+     | +-------chk_*--> ECC check store    |
                       |                                    |                                     |
                       |                       gsc_* (32-bit I/O bus, one master + LASI's EIR)    |
                       |           +-------------+----------+-----------+------------+            |
                       |        lasi.sv       hp_xbus.sv  wax_stub.sv  artist.sv (later)          |
                       |  core, uart, ps2 x2,  EEPROM,     P-001        regs + VRAM (DDR3)        |
                       |  rtc, clocks, misc,   LED latch,                                          |
                       |  scsi/lan/audio/lpt   board ID                                            |
                       |  stubs (later: real)                                                      |
                       +-------------------------------------------------------------------------+
```

`rtl/hp715.sv` is the machine; it has no MiSTer-specific logic. Its memory
ports are simple request/acknowledge ports that `HP9K715.sv` connects to
SDRAM and the DDR3 bridge on the board, and `verilator/sim.v` to
behavioural arrays in the simulator.

## 2. Physical address map (the MIOC's decoder)

Every CPU access goes through the MIOC. Cacheable accesses come on the line
port (cpu.md 6.8) and can only be memory; uncached ones (I/O space, U-bit
pages, LDCW read-and-clear, instruction fetches from the ROM) come on the
uncached port and are decoded as below. "BE" = bus error: the access is
reported as MIOC_STATUS |= 0x02 (pioae), MDERRADD = the address and the
`hpmc_req` level (HW 1.3, 1.7, 7); a load is also acknowledged with
`io_err` (a precise HPMC on the load, PSW.M then masks the level), a store
is not (the write is posted: its HPMC comes from the level at the next
instruction boundary; with `io_err` as well the core would take a second
HPMC once the handler returns -- ROM test 0x410D9).

| Range | Target | Reads | Writes | Ref |
|---|---|---|---|---|
| 0000_0000-EFFF_FFFF | memory blocks (sec. 3) | block hit: RAM; enabled block with no DRAM: all ones, no error; no block: BE | same; empty block: dropped | HW 1.5 |
| F000_0000-F003_FFFF | boot ROM (256 KB flash) | ROM image (bursts for code) | dropped (flash programming not modelled) | FW 1 |
| F004_0000-F00B_FFFF | LASI 8-bit bus, nothing fitted | 0xFF bytes | dropped | Lasi ERS app. A ("undefined") |
| F00C_0000-F00D_FFFF | EEPROM, 8 KB, mirrored every 8 KB | bytes / words (4 bytes BE) | byte writes, read back at once | FW 5.1 |
| F00E_0000-F00E_FFFF | front-panel LED latch (active low) | the latch | latch <- byte | HW 5; R06 4.1 |
| F00F_0000-F00F_FFFF | board ID / speed strap | word 0x0000_00M0 (M = 7/B/F) everywhere in the page | dropped | HW 5.1 |
| F010_0000-F01F_FFFF | LASI (sec. 5) | per unit; unassigned pages read 0 | per unit | Lasi ERS app. A: LASI answers its whole space |
| F020_0000-F020_7FFF | WAX stub (P-001) | **F020_0000 word/byte: BE** (no WAX, so `probe_io2` leaves AMR = 2); 0xF020_1801 (8042 status) = 0x00 (IBF = 0); else 0 | dropped (incl. the reset-time HIL writes at F020_1000/1C00) | HW 6.1, 7 |
| F020_8000-F7FF_FFFF | nothing (second LASI F040_0000, 0xF041_FFFE, F050_0000, 0xF100_0000, slot graphics F400/F600_0000) | BE | BE | HW 7 |
| F800_0000-F9FF_FFFF | Artist (`rtl/artist/artist.sv`, `docs/design/artist.md`) | F800_0000-F80F_FFFF and F838_1000-F8FF_FFFF: BE (no option ROM, STI is in the system ROM); region 2 F810_0000-F837_FFFF and region 3 F838_0000-F838_0FFF registers; F900_0000 = frame-buffer window | registers / VRAM | HW 6.3, R08 |
| FA00_0000-FFFA_FFFF | slot graphics FA00_0000, EISA FC00_0000-FFBF_FFFF, ... | BE | BE | HW 6.2, 7; P-002 |
| FFFB_0000-FFFB_DFFF | unused central-bus modules incl. **FFFB_B000** (must BE, `st_hpmc_toc`) | BE | BE | Lasi ERS app. B |
| FFFB_E000-FFFB_EFFF | CPU HPA | 0 (PDC_ADD_VALID probes HPAs) | +0x00 IO_EIR: `eir_set`, eir_num = data[4:0]; +0x30 IO_COMMAND: 5 = TOC, else ignored | HW 2; cpu.md 5.3 |
| FFFB_F000-FFFB_FFFF | MIOC registers (sec. 4) | registers, 0 elsewhere | registers | HW 1 |
| FFFC_0000-FFFD_FFFF | local broadcast | 0 | +0x00 EIR (as IO_EIR), +0x20 FLEXID (stored, ignored), +0x30 COMMAND: 5 = broadcast reset | HW 3 |
| FFFE_0000-FFFF_FFFF | global broadcast | 0 | same as local (Linux reboots through FFFE_0030) | HW 3 |

Byte lanes on the uncached port are big-endian over the aligned doubleword
(cpu.md 6.8). The MIOC turns an access into one or two 32-bit GSC
transactions (two only for an 8-byte FLDD/FSTD to I/O space) and returns
the device's word in both halves of `io_rdata`.

Instruction fetches from the ROM are 4-beat bursts (`io_burst`). The MIOC
keeps the last ROM line it read in a one-line buffer, so data loads from the
ROM (strings, tables, `dp`-relative data at 0xF002_4000) that hit the same
line cost one cycle; a larger ROM cache in front of DDR3 is a step-4
question.

## 3. Memory (MIOC blocks, RAM, ECC)

### 3.1 Blocks

Sixteen comparators, MEMCOMP[n] (0x100+4n) and MEMMASK[n] (0x140+4n) with
the layout of HW 1.5. Comparator n hits when it is enabled (MEMMASK bit 9 =
0) and `(A[31:23] & ~m) == (MEMCOMP[31:23] & ~m)` with
`m = {3'b000, MEMMASK[28:23]}` (address bits 0-2 always compared); the
lowest-numbered hit wins.

The installed memory is a set of **physical banks** fixed by the
configuration (OSD "RAM size"), each tied to one comparator and never larger
than 128 MB (HW 1.5: a 256 MB block would have to alias at 128 MB under
tech 4, STUBS P-007):

| RAM | Bank on comparator 2 (SIMM slots 0/1) | Bank on comparator 7 (second RAS bank of slots 0/1) |
|---|---|---|
| 16 / 32 / 64 / 128 MB | that size, RAM offset 0 | -- |
| 256 MB *(later)* | 128 MB, offset 0 (SDRAM) | 128 MB, offset 128 MB (DDR3) |

An access that hits comparator n with a bank of size S goes to RAM offset
`bank_base + (A & (S - 1))`. Because the probe mask (0x1F80_0000) makes the
comparator answer the whole of 0-512 MB, this gives exactly the
modulo-S aliasing `mem_probe_block` measures (BOOT 4.6). A hit on a
comparator with no bank behind it reads all ones and drops writes, without
an error -- `mem_probe_block` expects neither 0xAAAAAAAA nor an HPMC there.
No hit -> bus error (status 0x02 + MDERRADD) on both ports; on the line port
it is `mem_rerr` with the fill.

16 MB is the simulator's default: the ROM sizes and tests every byte it
finds (FASTSIZE cannot help, it also clips the reported size).

### 3.2 ECC (STUBS P-006)

The ROM's memory tests need SEC-DED ECC with one check byte per doubleword
(HW 1.6): ECC(0) = 0x33, ECC(~0) = 0xCC, ECC(0x01234567FEDCBA98) = 0x55,
odd-weight columns, no data column equal to 0xD0 or 0x0D, and the triple
data error 0x00000D00 in the upper word detected rather than miscorrected.
We use the code `tools/rom/hwmap_ecc.py` finds (seed 715): ECC(d) = 0x33 ^
XOR of col[j] over the set bits j of d (`rtl/mioc_ecc.sv`).

| Piece | What it does |
|---|---|
| **Check store** (`chk_*` port: one 32-bit word per 32-byte line, byte k = doubleword k) | written on every line write and every uncached RAM write: with MTCV bit 5 = 1 the computed ECC, with bit 5 = 0 the forced byte from M_WRT_CHK (0xC4, byte k for doubleword k). Read only when software reads 0xDC (the check bytes of the last line filled from RAM) |
| **Poison table** (8 doublewords) | doublewords whose last write stored a check byte different from ECC(data). On a line fill with MTCV bit 5 = 1, a poisoned doubleword is checked: syndrome = stored ^ ECC(raw); weight 1 -> check-bit error (data intact), equal to a data column -> that bit corrected, else uncorrectable. Removed when the doubleword is written again; when full, the oldest entry is dropped |
| Error logging | corrected: status 0x40 (sedc), LPMC request while MIOC_CONTROL bit 19 (slen); uncorrectable: status 0x20 (dedc) and `mem_rerr` with the fill (HPMC). M_ERR0/M_ERR1 (0xD0/0xD4) = the raw doubleword, M_RD_CHK (0xD8) bits 24-31 = its stored check byte, MDERRADD = its address. A later error overwrites the log unless the logged one is more severe |

This satisfies `mem_ecc_singlebit`, `mem_ecc_multibit` (one line at
physical 0), both RAM test bodies (fastboot on: ones/zeros with true check
bytes; fastboot off: the LFSR test, which forces an arbitrary check word per
line over all of memory and reads 0xDC back -- hence the full-size check
store) and the PIM's error logging. What it does not do: report an error on
an ECC-on read of a doubleword that was forced more than eight forced writes
ago (the LFSR test rewrites every line with good check bytes before ECC goes
back on).

The check store is 1/8 of the RAM: in the simulator an array, on the board
*(later)* a DDR3 region (32 MB for 256 MB). Writing it costs one posted
DDR3 word per line write-back; it is never on the fill path.

### 3.3 RAM port

`ram_req` held until `ram_ack`, `ram_we`, `ram_addr` (byte address of a
doubleword inside the RAM, 28 bits), `ram_line` (1 = 4 beats; 0 = one
doubleword), `ram_be[7:0]` (single writes), `ram_wdata` + `ram_wready` (one
per beat, writes always in order from doubleword 0), `ram_rdata` +
`ram_rvalid` + `ram_rbeat` (each read beat names its doubleword: a line
starts with the one at `ram_addr[4:3]`, in whatever order the memory
delivers -- the SDRAM's is c, c^1, c^2, c^3 -- except that a line read from
doubleword 0 comes in order 0..3, which uncached bursts rely on).
Line writes are collected in the MIOC first and sent as one burst; fills
stream through the ECC check (one register stage) to the CPU's `mem_r*`.
Uncached writes to RAM are read-modify-write in the MIOC (the check byte
covers the whole doubleword); LDCW's `io_rclr` reads the doubleword and
writes it back with the word cleared.

DMA masters (53C710, 82596, Harmony, parallel) get a second RAM client
port on the MIOC *(later)*, arbitrated with the CPU per line; the 715 is not
coherent (HP-UX flushes before and purges after DMA, R06 3.4), so DMA never
looks into the CPU's caches.

## 4. MIOC registers (FFFB_F000)

HW 1.1-1.7 with these choices:

| Off | Register | Ours |
|---|---|---|
| 0x080 | MIOC_CONTROL | 32-bit storage (reset value whatever the ROM writes); bit 17 pgape / bit 18 pgdpe arm a one-shot fault of the **next CPU uncached store to I/O space** (A >= F000_0000): the store is dropped, status 0x02 / 0x08, MDERRADD = A, `io_err`; the bit then clears. Bit 19 slen enables the LPMC for corrected errors |
| 0x084 | MIOC_STATUS | bits 25-31 as HW 1.3 (0x01 dml, 0x02 pioae, 0x04 pmae, 0x08 data parity, 0x10 TOC, 0x20 dedc, 0x40 sedc); a write clears the bits written as 1 (write-back of the read value clears, as the ROM does it); bits 0-24 read 0. `hpmc_req` = status & 0x2E != 0, `lpmc_req` = (status & 0x40 and slen) or status & 0x01 |
| 0x0C0 | MTCV | storage; bit 5 (0x0400_0000) = ECC generate/check on |
| 0x0C4 | M_WRT_CHK | storage: check bytes for writes while MTCV bit 5 = 0 |
| 0x0D0, 0x0D4 | M_ERR0 / M_ERR1 | error log; 0xD0 is also plain read/write (`st_gsc_parity` writes 0xAAAAAAAA and reads it back) |
| 0x0D8 | M_RD_CHK | bits 24-31 = check byte of the logged doubleword, others 0 |
| 0x0DC | line check bytes | the check-store word of the last line filled from RAM |
| 0x0E0 | MDERRADD | address of the logged error |
| 0x100-0x13C, 0x140-0x17C | MEMCOMP / MEMMASK | storage + the decoder of sec. 3.1; MEMMASK resets to 0x0040_0000 (all off) |
| others | -- | read 0, writes ignored |

The MIOC has no I/O timeout: devices that exist always answer, and the
decoder knows which addresses have none (sec. 2).

## 5. LASI (F010_0000)

`rtl/lasi/lasi.sv`: the interrupt controller and the misc registers, and the
units at 4 KB steps. Unit registers are byte-wide at the offsets of the
LASI ERS appendix A; an 8-bit device answers a word read with its byte
replicated on the lanes it was asked for (HP-UX uses lane 3, Linux lane 0
for PS/2, R06b).

| Page | Unit | First version | Ref |
|---|---|---|---|
| +0x0000 | interrupt registers IRR/IMR/IPR/ICR/IAR | full (below) | Lasi ERS 14; R06 4.1 |
| +0x1000, +0x2000, +0x3000 | parallel DMA, parallel port, DMA reset | stub: registers store, no DMA (P-010) | R06b 3 |
| +0x4000 | Harmony audio | `rtl/lasi/harmony.sv` (2026-10-09, S-025): the registers, the page-chained playback/record DMA on the MIOC's `dma_*` port (ahead of the 53C710 in `hp715.sv`'s arbiter), the 14 sample rates (a phase accumulator from the CS4215's two crystals), 16-bit / u-law / A-law / 8-bit, the LO/RO attenuation, the codec's loopback (the ROM's test); IRQ = IPR bit 13; the output on the MiSTer's AUDIO_L/R. No input (records silence); `make -C verilator tb_harmony` | R06a; Lasi ERS 6.4; HW 4.8 |
| +0x5000 | RS-232 16550A (+0x800) | `lasi_uart.sv`: true 16550A, 16-byte FIFOs, IIR priorities, TEMT, scratch, loopback; 7.3728 MHz reference (P-009) | R06b 2; HW 4.3 |
| +0x6000 | 53C710 SCSI | `rtl/scsi/ncr53c710.sv` (registers, SCRIPTS, DMA on the MIOC's `dma_*` port; S-021) and `rtl/scsi/scsi_targets.sv` (disks at IDs 6 and 5, CD-ROM at 2, on hps_io block devices; S-020); IRQ = IPR bit 9. The ROM boots ISL from it | R06d; HW 4.5 |
| +0x7000 | 82596 LAN | `rtl/lasi/i82596.sv` (2026-10-10, S-027): reset, PORT, CA; the SCB, the command unit (IA setup, configure, transmit with TBD chains, TDR ...) and the receive unit (simplified and flexible RFDs, RBD lists) as DMA on the MIOC's `dma_*` port (after Harmony and the 53C710 in `hp715.sv`'s arbiter); frames to Main_MiSTer's Ethernet bridge (the DDR3 mailbox at 0x1FF0_0000, `ddr3_port.sv` `nb_*`; OSD Network) or, in loopback, straight back; IRQ = IPR bit 8, IORESET bit 1. `make -C verilator tb_i82596` | HW 4.6; Lasi ERS 4; R06 4.3 |
| +0x8000 | PS/2 keyboard (+0x000) and mouse (+0x100), mirrored every 0x200 | `lasi_ps2.sv`: ID, RESET, 4-deep RX FIFO, 1-deep TX, CONTROL (ENBL, LPBXR, DIAG), STATUS (RBNE, TBNE, CMPINTR), loopback; device side to a keyboard/mouse model | Lasi ERS 9; HW 4.7; R06b 1 |
| +0x9000 | RTC | 32-bit seconds counter, 1 Hz from the board clock, write clears the prescaler; set from the MiSTer RTC at power-up *(later)* | Lasi ERS 8 |
| +0xA000, +0xD000 | floppy (WD37C65C) and its DMA | `rtl/lasi/lasi_fdc.sv` (2026-10-11, S-028): LASI's 4-byte FIFO, control/status, FDAR and DMA enable, the DMA in both directions (one word per byte, top lane) on the MIOC's `dma_*` port (after Harmony in `hp715.sv`'s arbiter), DMA_IRQ at offsets 0x1FF/0x3FF; a 765A command layer **with no drive** (RECALIBRATE ends in equipment check, reads/writes end at once with missing address mark; no data phase), QEMU's 82077 INT rules; IRQ = IPR bit 20, IORESET bit 5, unit reset at +0x000. HP-UX 11i's pflop probe finds no drive; `make -C verilator tb_fdc` | Lasi ERS 10; HW 4.9; review 10 |
| +0xB000 | clock registers | four words of storage | HW 4.2 |
| +0xC000 | PCR, ERRLOG (0), VER (0), IORESET, AMR | storage; IORESET bits hold their units in reset; PCR bit 1 does nothing on a 715 (BOOT 7 item 13) | HW 4.1 |
| +0xE000-0xFFFFF | unassigned | read 0, writes ignored | Lasi ERS app. A |

**Interrupt controller** (Lasi ERS 14.3; R06 4.1). Each unit drives a
level; a rising edge sets its IPR bit (GSC numbering, bit 26 = 1 << 26:
PS/2 26, FDC 20, external 21, audio 13, bus error 14, SCSI 9, LAN 8,
parallel 7, RS-232 5). IPR latches while masked. Every cycle the bits
`IPR & IMR & ~IRR` are added to IRR, and if there are any LASI masters a
write of IAR[4:0] to IAR[31:5] (power-up IAR = 0xFFFB_E003) -- unless ICR
bit 8 (bus error) is set. A read of IRR returns it and, on the next cycle,
clears IRR and the unmasked IPR bits (a new edge in that cycle survives). A
write to IPR clears it. ICR bit 1 remaps the external interrupt (bit 21)
to TOC; the OSD's TOC button drives that line.

**The interrupt write.** LASI masters a GSC write; the MIOC services it as
it would a CPU store: to the CPU HPA's IO_EIR or a broadcast EIR it becomes
`eir_set` with `eir_num` = data[4:0] (one cycle); to anything else it is a
bus error, which sets ICR bit 8 and stops further interrupts, as on the
real chip (Lasi ERS 14.5).

## 6. The 8-bit bus: EEPROM, LEDs, board ID

`rtl/hp_xbus.sv`. The **EEPROM** is an 8 KB dual-port BRAM (2048 x 32 with
byte enables): port A for the CPU (byte writes read back at once, so the
ROM's data polling succeeds on the first read, FW 5.1), port B for the host
(load at start-up, save to the SD card *(later)*; a dirty flag says when a
save is due). The default image is the ROM's own first-boot result with the
manufacturing flag cleared (`tools/eeprom/`, *later*); a blank (all 0xFF)
EEPROM boots into manufacturing mode with the console on RS-232 (FW 5.6),
which is how the simulator starts until that image exists.

The **LED latch** keeps the last byte written (active low: LED n lit =
bit n-1 clear); it goes to the GUI and, on the board, to the OSD/LED
outputs. The ROM's chassis codes are the byte `(code >> 12) & 0xFF`
(BOOT 3.1). The **board ID** reads 0x0000_0070 / 0xB0 / 0xF0 for the
715/64 / 80 / 100 (OSD "model"); it also selects the CPU's CR16 rate.

## 7. Clocks, reset, TOC, power

| Item | Choice |
|---|---|
| clk_sys | one clock for the CPU, the MIOC and all devices. The CPU closes 64 MHz on its own (cpu-timing.md fit 9); the board build decides the final number. CR16 always counts at the strap's rate whatever clk_sys is: the MIOC derives `cfg_tq/tr/td` from the model and the clk_sys frequency (cpu.md 5.2). In the simulator clk_sys is "64 MHz" (TQ = 1, TR = 0, TD = 1 for the 715/64) |
| RAM / DDR3 / video | on the board, all on clk_sys (64 MHz, `HP9K715.sv`): `rtl/mister/sdram64.sv`, a closed-page SDRAM controller (BL8 reads, CAS 2, two bursts per line; single-location writes, a WRITE per 16-bit word, because the board wrote a write burst's DQM-masked words anyway, S-019; ~25 cycles per line fill; unit bench `make -C verilator tb_sdram64`) with SDRAM_CLK from a second PLL output 270 degrees late (11.7 ns; chosen on paper for the 64 MHz read window, to be confirmed on the board); `rtl/mister/ddr3_port.sv` on the `DDRAM_*` bridge with DDRAM_CLK = clk_sys: boot ROM at DDR3 0x3000_0000, check store at 0x3100_0000; *(later)* VRAM in DDR3 for Artist, shown by the MiSTer framebuffer (8-bit palette mode), and the RAM above 128 MB. A faster SDRAM clock (2 x clk_sys) is the obvious memory-latency improvement once the machine works on the board |
| UART / RTC / PS/2 time bases | fractional dividers from clk_sys: 7.3728 MHz x16 baud reference, 1 Hz RTC tick, PS/2 bit timing for the device model |
| Power-on reset | `reset` input (MiSTer reset, ROM download) resets everything; RAM contents survive, the EEPROM is never cleared |
| Broadcast reset | a store of 5 to FFFC_0030 / FFFE_0030 asserts the machine reset for 16 cycles after the store is acknowledged: CPU, MIOC registers, LASI and its units (the same as power-on except memory and the EEPROM) |
| TOC | IO_COMMAND = 5 (CPU HPA+0x30) or the LASI external interrupt with ICR bit 1 (the OSD's TOC button): `toc_req` pulse and MIOC_STATUS bit 27 (0x10, so `hpmc_toc_entry` takes the TOC path, HW 1.3). The CPU masks it until TOC_EN |
| Soft power | the OSD "soft power off" drives `soft_pwr_n` = 0 (DR25 bit 0, cpu-requests #1): HP-UX and Linux poll it and shut down; LASI PCR does not power anything off |
| powerfail | tied 0 (P-014) |

## 8. The boot ROM image

The ROM is loaded by hps_io from `games/HP9K715/boot.rom` (ioctl index 0,
16 bits per write) through `rtl/rom_loader.sv`, which assembles 64-bit
words, writes them to the ROM store (DDR3 on the board, an array in the
simulator) and **applies the one-word patch of STUBS S-011** (file offset
0xB810: 0x86802012 -> 0xE8000012) as it goes, so the SD-card file stays
HP's. The machine is held in reset while a download runs. The simulator
loads the same file through the same loader (`verilator/sim.v`).

## 9. The MiSTer top (`HP9K715.sv`)

| Item | |
|---|---|
| OSD | model (715/64/80/100) and RAM (16-128 MB, clipped to the SDRAM module) latched at reset; `SC1,EEP` = the EEPROM image; TOC button; soft power off (DR25 bit 0 held "pressed" for 2 s); reset |
| EEPROM | `rtl/mister/eeprom_save.sv`: the mounted image is read into the EEPROM before the machine leaves reset (or a 3 s backstop); saved when the OSD opens or 2 s after the firmware's last write. No image = a blank EEPROM = manufacturing mode |
| Boot ROM | `games/HP9K715/boot.rom`, sent by the MiSTer at core start (ioctl index 0) through `rom_loader` (S-011 patch) into DDR3; the machine waits in reset until it has arrived; `ioctl_wait` paces the download |
| RTC | hps_io's TIMESTAMP (seconds since 1970) is loaded into the LASI RTC whenever it is sent |
| Serial | LASI RS-232 on the MiSTer UART (UART_TXD/RXD), which the framework wires to the HPS UART: `/dev/ttyS1` on the MiSTer's Linux (`tools/mister/board.sh console`, or `picocom -b 9600 /dev/ttyS1`); CONF_STR offers 9600-115200 to the Main |
| Video | Artist's own picture (`rtl/artist/artist_video.sv`, artist.md 4.1) at the timing the firmware programs, on its own pixel clock: `rtl/pll_video.v`, reconfigured through `sys/pll_cfg/pll_cfg_hdmi.v` to the frequency of the ROM's monitor record (`pix_mode`; 108.181 MHz static = 1280x1024 at 60 Hz -- the 72/75/50 Hz records are shown at that timing -- and the console), CLK_VIDEO = that clock; LUT0/LUT1 by the attribute plane, the cursor laid over, the line fetch a DDR3 client on clk_sys; while its video is on (OSD "Display": Auto / Graphics / Serial console), square-pixel aspect; otherwise the RS-232 console as text (`serial_term.sv`: 640x480 at 27.05 MHz, 858 x 525, its text kept on clk_sys). `MISTER_DISABLE_YC`: no composite/S-video output. Both the scaler (OSD "Scale", `sys/video_freak.sv`) and the analog VGA carry it (S-024) |
| SDRAM | `rtl/mister/sdram64.sv`, SDRAM_CLK = clk + 270 degrees; read capture an OSD option (O[9:8], default edge 3 after the READ; S-019) |
| Debug recorder | `rtl/mister/trace_ddr3.sv`: the machine's debug events (`hp715` `dbg_ev`: SCRIPTS instructions, SCSI bus bytes, interrupts, selections, DMA, the CPU's line requests -- a repeat of the previous line read is left out, I-cache fills are flagged -- its uncached accesses to RAM and the 53C710, interruptions with the instruction word, and cache maintenance (FDC/PDC/FIC with VA and physical line; of a whole-cache FDCE/FICE loop only the first)) as 32-byte records in a 64K ring at DDR3 0x3200_0000, lowest priority on `ddr3_port`; `tools/mister/trace_dump.py clear|dump` reads it on the MiSTer, `decode` turns romsim's `--evtrace` into the same text. It **freezes** 1024 events after a user-mode trap 8, 10 or 11 (until reset), so after a SIGILL the ring ends with what led to it. Since build 40 (2026-10-11): event 15/16 = an HP-UX system call (r22, r26, r25; r2, r24, r23), 17 = the 82596's PORT/CA/CB/status/RX/TX/reset, and a **one-shot filtered capture** (system calls, the non-routine interruptions, SCSI interrupts, keys, the LAN; armed by Pause on the keyboard or `board.sh trig` through the status word's bits 127:64): with no trigger the first 65536 events after arming, with one (the K-th system call N, optionally with r26 = M) everything up to 8192 events after it -- what led to a stall. `tools/mister/trace_get.sh` dumps it, `trace_sym.py` adds the kernel's symbols and the system-call names |
| LEDs | LED_USER = front-panel LED4 (the OS heartbeat), LED_DISK = LED3, LED_POWER = LASI's power LED |
| Audio | Harmony's codec output (`rtl/lasi/harmony.sv`) on AUDIO_L/R, signed, held between samples (S-025) |

## 10. Builds (whole core, Quartus 17.0.2)

| # | Date | Tree | Core clock (64 MHz) | ALMs | M10K | DSP | Notes |
|---|---|---|---|---|---|---|---|
| 1 | 2026-10-08 | the machine before SCSI (fix #4 in, #5 not) | setup +0.781 ns, hold +0.249 ns | 25,041 (60 %) | 358 (65 %) | 37 | first full build; every clock meets timing; `output_files/HP9K715.rbf` (not committed). SDRAM I/O unconstrained (S-019) |
| 2 | 2026-10-08 | + SCSI (53C710, targets; `1f4d438`) | setup +0.380 ns, hold +0.241 ns | 28,075 (67 %) | 360 (65 %) | 37 | **first run on a board** (MiSTer at .92): ROM loaded into DDR3 intact, CPU/cache/TLB self-tests pass, serial console on `/dev/ttyS1`; SDRAM reads one beat late (S-019) -> ECC test 0x210D7 halts |
| 3 | 2026-10-08 | + `sdram64` rd_mode (capture edge 4 / 3.5 / 3 / 2.5) | setup -0.850 ns (the falling-edge capture into the read assembly, modes 1 and 3 only) | 28,039 | 360 | 37 | the sweep: edges 3 and 2.5 pass the LFSR test, 3.5 and 4 do not; with edge 3 the ROM reaches BOOT_ADMIN at 64 MB. `search` lists scsi.6.1-7 with blank names, `boot scsi.6`: "Cannot load IPL" (the sim finds scsi.6.0 and boots ISL) |
| 4 | 2026-10-08 | capture by clk_sdram (2.75), the falling-edge one pipelined | setup +0.666 ns, hold +0.252 ns | 27,912 | 360 | 37 | 2.75 and 3 pass, 2.5 (clean now), 4 fail; SCSI as build 3 |
| 5-8 | 2026-10-08 | 5: the serial console on the MiSTer screen (`serial_term`); 6: cpu-requests #6 (a line transaction waits for an older posted store); 7: the DDR3 debug recorder (`trace_ddr3`); 8: repeated line reads left out of it (`1ec4fe9`) | 8: setup +0.948 ns | -- | -- | -- | 6 passes every ROM self-test on the board (the ECC test had failed) and reaches BOOT_ADMIN at 16 and 64 MB; 7-8 recorded the `search` that failed: identical to the simulator's through the INQUIRY DMA, then the ROM branched on the data it read back (S-019: the write burst's masked words) |
| 9 | 2026-10-08 | `sdram64` single-location writes (a WRITE per 16-bit word, mode A9 = 1; S-019) | setup +0.843 ns, hold +0.251 ns | 28,715 (69 %) | -- | 37 | **the board boots from SCSI**: `search` lists `scsi.6.0 SEAGATE ST32550N`, `boot scsi.6` loads IPL, ISL runs the hpux loader, HP-UX 10.20's kernel starts (16 MB, diag EEPROM) and panics `Data page fault` (interrupt 15, pcoq 0x8b368, ior 0x2ecd8) -- the system-next stream's. Same RTL in romsim on the SDRAM model: search, ISL, the hpux loader |
| 10 | 2026-10-08 | cpu-requests #7 (the I-LAB survives D-side TLB inserts; `fd7d435`) | setup +0.615 ns, hold +0.249 ns | 28,669 (68 %) | -- | -- | not yet run on a board. In romsim HP-UX gets past the 0xCEF2 livelock: at 32 MB it panics (`Data page fault` in `hdl_vfault`), at 16 MB it idles (`RESUME-20261008-hpux-kernel.md`) |
| 11 | 2026-10-08 | the walker's PDIR read fills after a dirty victim (`665f2e8`) + the I-LAB refresh on D-form TLB ops (`45c4ad1`) | setup +0.859 ns, hold +0.164 ns | 28,709 (69 %) | 371 (67 %) | 37 | **the board gets past the `Data page fault` panic** (16 MB): `vuseg=`, `inet_clts:ok inet_cots:ok nfs_init3 ...` on the screen, then it waits in the c720 driver's 10 s post-reset delay and stalls in the MODE SELECT phase-mismatch loop (S-020) |
| 12 | 2026-10-08 | + the SCSI target's MODE SELECT completion (S-020) | setup +0.716 ns, hold +0.250 ns | 28,769 (69 %) | -- | -- | **the board matches romsim**: HP-UX probes the I/O tree (c720, tgt, sdisk, sctl, asio0, CentIf, ps2, processor, memory), prints "System Console is on the Built-In Serial Interface", then panics `LVM: Configuration failure` -- the disk image's boot record named QEMU's disk path (`disks/README.md`, `tools/hpux/lvmbdra.py`); with it rewritten **HP-UX 10.20 boots on the MiSTer**: file systems mounted, hostname, syncer, "Configure LAN interfaces FAIL" (no LAN), the start-up sequence continues (`RESUME-20261008-hpux-login.md`) |
| 13 | 2026-10-09 | + trap 22 with ISR/IOR for coprocessor loads/stores (`e8c2024`) | setup +0.793 ns, hold +0.207 ns | 28,661 (68 %) | 371 (67 %) | 37 | the ISR/IOR fix is right (ACD p.4-25) but was not awk's bug: HP-UX 10.20 keeps the FPU enabled for user processes (no trap 22 in a whole single-user run, `--traps`), so the board still stops at "Start Software Distributor agent daemon". The real bug, found with the new `--fptrace`: fr0 as an operand read the status (cpu.md 1.1) |
| 14 | 2026-10-09 | + fr0 as a source operand reads +0 (`8d18d88`) | setup +0.254 ns, hold +0.251 ns | 28,601 (68 %) | 371 (67 %) | 37 | **HP-UX 10.20 completes its multi-user start-up on the MiSTer** (64 MB, the board's OSD setting: the kernel prints `Physical: 65536 Kbytes`): "Start Software Distributor agent daemon OK", the rest of the sequence (NCS broker FAIL, no network), "The X-server can not be started on display hpux:0" (no Artist yet), then `Console Login:` on the serial console. **2026-10-09: root logs in** (password set from a single-user boot, `disks/README.md`): `uname -a` = `HP-UX hpux B.10.20 U 9000/715`, `model` = `9000/715/D`; `ioscan -f` claims c720 (2/0/1) with the disk at 2/0/1.6.0, asio0 (2/0/4), CentIf (2/0/6), ps2 (2/0/11), processor (8), memory (9), and lists LAN (2/0/2), audio (2/0/8) and floppy (2/0/10) UNCLAIMED (no driver bound: for LAN and audio as `docs/review/06` predicts, the floppy not checked); `bdf` = / 3.6 GB VxFS 37 % used, /stand 48 MB HFS; 512 MB swap on lvol2. The clock read 5 h behind UTC (S-022, fixed in Main_MiSTer). Was `release/` until build 15 |
| 15 | 2026-10-09 | + a fetch without execute rights fills no I-cache line (`68ec0f6`, cpu-requests #8) + the recorder's interruption / cache-maintenance / I-fill events and freeze-on-SIGILL (`86be259`) | setup +0.639 ns, hold +0.244 ns | 28,859 (69 %) | -- | 37 | build 14 at 32 MB: `which` (csh) and a start-up script's grep died of SIGILL (core files: IIR = stale data at the first instruction of a just-paged-in text page, IOR = the page base): HP-UX reads text in by DMA under a no-execute in-transit mapping and never FICs the frame, and our trapping fetch had filled the line first. Build 15 at 32 MB: no core from the boot, and 40 passes of a loop that evicts (an awk array) and re-pages text (`which`, csh, grep, sort, od, sed, ls, ps ...) ran 31 minutes with no crash and no recorder freeze. `release/` = this build |
| 16 | 2026-10-09 | + **Artist** (`rtl/artist/artist.sv`, `7ecd44d`): VRAM in DDR3 at 0x3300_0000, the MiSTer frame buffer (MISTER_FB, 8-bit palette, OSD Display) | setup +0.375 ns, hold +0.256 ns | 31,456 (75 %) | 381 (69 %) | 37 | graphics-console EEPROM (`path console graphics`, monitor type unset): the ROM drew its boot screen, then its first-boot monitor cycling (no keyboard: the PS/2 model did not answer F0 00) moved from 1280x1024 to 1024x768 and the next `init_graph` divided by zero (trap 13 at 0x517c, LEDs 0x21): the STI state at (1536, 776) had never been written. The DDR3 VRAM itself was right (read over /dev/mem: the state at (1536, 384) intact) |
| 17 | 2026-10-09 | + the keyboard's F0 00 reply, the STI state area kept in both rows (`ccfa6a3`) | setup +0.623 ns, hold +0.246 ns | 31,313 (75 %) | -- | -- | EEPROM with monitor type 1 saved (romsim, Enter + y on the PS/2 keyboard): the ROM autobooted from scsi.6 and **HP-UX 10.20 came up to its X11 login screen on Artist** (VRAM read over /dev/mem and rendered: the HP logo, "Welcome to hpux", the login fields). `board.sh shot` still showed the core's own 640x480 video: the MiSTer screenshot does not seem to capture the scaler's frame-buffer mode |
| 18 | 2026-10-09 | + the keyboard in scan-code set 3, the LUT0 copy in DDR3, PS/2 / key / Artist events in the recorder (`a24382f` minus the cursor) | setup +0.228 ns, hold +0.247 ns | 31,530 (75 %) | 383 (69 %) | -- | after an unclean stop (disk image backed up first as `hpux1020.img.bak-20261009` on the SD card) HP-UX came back to the X login; **typing through `board.sh key` (uinput) logged root in and CDE came up** (front panel, Help Manager, File Manager, a terminal), rendered from the VRAM with the real palette (`board.sh vram`). Fixed-width text is right; proportional fonts overlap; the login's HP logo is black (a second colour map?). The mouse works: X writes CURSOR_POS/CTRL on every move (e.g. 0x07F801F7 / 0x80) |
| 19 | 2026-10-09 | + the hardware cursor (first version), BINC in 8 directions, LUT blt types (`a24382f`) | **setup -1.291 ns** (TNS -10.445), hold +0.251 ns | 32,069 (77 %) | 395 (71 %) | 37 | missed 64 MHz, never loaded. Artist alone (`scratch/artist_map`) had -2.9 ns: the GSC decode in G_DEC feeding the operation set-up in the same cycle; fixed for build 20 (`8944cfe`: E_LAUNCH, registered cursor geometry, pre-aligned sprite bits, pipelined colour search; Artist alone +1.83 ns) |
| 20 | 2026-10-09 | + review 09's X fixes (sub-word Otc32 stores, font engine, TRANSFER_DATA fills, lines, J planes, cursor formula) and the timing split (`8944cfe`) | setup +0.265 ns, hold +0.253 ns; **the HDMI clock (sys/, 148.5 MHz) -0.171 ns** (TNS -1.489) | 33,051 (79 %) | 395 (71 %) | 37 | the core clock meets 64 MHz again (build 19: -1.291). The HDMI domain is the framework's scaler output with the frame-buffer palette (`MISTER_FB_PALETTE`); its slack moves from fit to fit (build 17's worst slack, +0.032 ns, was below the core clock's +0.623, so probably this domain) and this fit misses it at the slow 100 C corner. Not yet loaded; rbf kept in the session scratchpad (`keep/builds/HP9K715_build20.rbf`) |
| 21 | 2026-10-09 | + X's clipped and dashed vectors, 0x100C40 points, all vectors stepped as X's `ngleBiffVectorEmulator` (`d1dc3d5`, review 09 5.5) | setup +0.581 ns, hold +0.252 ns; HDMI clock +0.407 ns | 33,179 (79 %) | 395 (71 %) | 37 | every clock meets timing (the HDMI domain's miss in 20 was placement). **On the board (32 MB, graphics EEPROM)**: the X login's proportional "Welcome to hpux" no longer overlaps, labels and buttons have their text; after root's login CDE draws window titles, menus, the Help Manager's text, the workspace names and the date; hpterm, oclock (shaped window) and xclock (tick marks as vectors) right; the cursor drawn. The VRAM was right, but **the HDMI output was not** (seen through the user's OBS): with the global video_mode=0 (720p) the frame-buffer path showed ~914 of the 1280 columns, and with a new `[HP9K715]` ini section (video_mode=8, vscale_mode=1) 1280 columns but 1024 lines squeezed into 960 -- Main sizes the window from the core's own raster (the 640 x 480 console, integer scale 2) -- and colours differing from LUT0; so the core makes its own picture from build 22 on. rbf in the session scratchpad (`keep/builds/HP9K715_build21.rbf`) |
| 22 | 2026-10-09 | + Artist's own picture (`artist_video.sv`: LUT0/LUT1 by the attribute plane, the cursor laid over, the core's video at 64 MHz; no MiSTer frame buffer; `7a1200a`) | setup +1.084 ns, hold +0.222 ns; HDMI clock +0.365 ns | 32,622 (78 %) | 394 (71 %) | 37 | **the HDMI output is right** (seen through OBS and confirmed by the user on the monitor): 1280 x 1024 at 1:1 on 1080p (ini `[HP9K715]` video_mode=8), crisp, the PDC/ITE text with its 1-pixel strokes intact, the X login's HP logo in its own colours (LUT1 by the attribute plane; black before), CDE, the pointer drawn by the display and smooth. OBS's capture shows colours more saturated than LUT (greys exact) through both the old and the new path: the capture chain. rbf `keep/builds/HP9K715_build22.rbf` |
| 23 | 2026-10-09 | + OSD "Scale" (default V-Integer) through `sys/video_freak.sv` (`76bc434`) | setup +0.288 ns, hold +0.222 ns; HDMI clock +0.330 ns | 32,844 (78 %) | 394 (71 %) | 37 | with the ini section reduced to `video_mode=8` the core's own integer scaling shows 1024 lines 1:1 on 1080p (the login dialog 799.5 px wide on HDMI, 800 in the VRAM); boot, X login, CDE as build 22. **Released** (`release/`, with the graphics-console EEPROM). Started from the MiSTer menu through the OSD (F12, Right = System, Core, `_Unstable/HP9K715`): boot ROM, disk and EEPROM picked up by the framework, ISL, HP-UX, the X login. X's screen saver blanks Artist (MISC_VIDEO bits 27/25), and "Display: Auto" then showed the serial-console view -- fixed for build 24 (Auto stays on Artist once its video has been on since reset). Open: moving an hpterm with the mouse (the user, build 22) left 4-pixel stubs of its old left frame every 16th row (VRAM x 212-215, y 752-816); not reproduced by unmapping an xclock (that repaint is clean); a recorder capture of a window drag is next |
| 24 | 2026-10-09 | + Display Auto stays on Artist once its video has been on since reset (`fbe22ca`) | setup +0.459 ns; HDMI clock +0.521 ns | 33,031 (79 %) | -- | 37 | not loaded (superseded by 25). The window-move stubs found meanwhile: the board recorder caught X repainting the vacated backdrop as one 16-row band uploaded through BINC and replicated by block moves, the first a 4 x 16 move SRC (228,752) -> DST (212,752); a move whose source is one word read that word from the line buffer in the same cycle as its last write, so each row got the previous row's word (`tb_artist` replay: 101 pixels) |
| 25 | 2026-10-09 | + the one-word block-move fix (`ca45ace`) | setup +0.374 ns; HDMI clock +0.023 ns | 32,891 (78 %) | -- | 37 | started from the MiSTer menu through the OSD, boots to CDE; the hpterm drag that left stubs on 23 leaves the vacated strip clean; `xset s activate` blanks HDMI to black (no console view) and the mouse brings CDE back. **Released** (alpha) |
| 26 | 2026-10-09 | + Artist at the programmed timing on its own pixel clock (`rtl/pll_video.v` reconfigured, static 135 MHz), the console on it; Harmony audio (`rtl/lasi/harmony.sv`) and the LASI DMA arbiter | **pixel clock setup -2.439 ns** (TNS -195.952), hold -1.069 ns; HDMI clock -0.033 ns; core +0.404 ns | 34,310 (82 %) | 400 (72 %) | 39 | never loaded. At 135 MHz the framework's video input misses: the composite encoder (`yc_out`), the scaler's downscale line buffer (`ascal` `i_mem` -> `i_pix`) and bilinear filter, and the direct-video hold through the HDMI clock select; plus our line announcements (three chained compare/increments). (A first attempt died after the fit: `files.qip` had been edited during it, Quartus rewrote the QSF) |
| 27 | 2026-10-10 | + the pixel clock capped at 108.181 MHz (every 1280x1024 record shown at record 5's 60 Hz timing), the announcements pipelined, `MISTER_DISABLE_YC` | pixel clock setup **-0.451 ns** (TNS -3.373: only `ascal`'s bilinear filter and its line-buffer read), hold met; HDMI +0.084, core +0.553 / hold met | 34,301 (82 %) | 399 (72 %) | 37 | **on the board** (32 MB, graphics EEPROM): ROM, HP-UX boot and CDE on HDMI at 1280x1024 60 Hz; with the kernel rebuilt with `audio` (`/stand/vmunix`, the old one `/stand/vmunix.noaudio`): `ioscan` lists `audio 0 2/0/8 CLAIMED Built-in Audio`, insf made `/dev/audio*`; `dd` of `/opt/audio/sounds/welcome.au` to `/dev/audioEU` plays (HDMI audio through OBS: -79 dBFS idle, -9 dBFS peak) and the terminal bell beeps through Harmony (-17 dBFS). HP's `Aserver` initialises the device (type 2, 7 rates) but its DCE process exits: `rpcd` fails without a network interface |
| 28 | 2026-10-10 | + `MISTER_DOWNSCALE_NN` (the scaler's downscaling nearest-neighbour: its bilinear filter is gone from the pixel clock) | **every clock meets timing**: pixel clock +1.186 ns, HDMI +0.016 ns, core +0.411 ns; holds +0.218 or more | 34,404 (82 %) | 399 (72 %) | 31 | not yet loaded (RTL as build 27, which ran on the board) |
| 29 | 2026-10-10 | + the PS/2 device drops its queued bytes on a host command (`rtl/lasi/ps2_dev.sv`, `tb_ps2dev`) | setup: core +0.069 ns, pixel +0.799 ns, HDMI +0.032 ns; holds met | 34,560 (82 %) | 399 (72 %) | -- | not loaded (superseded by 30). Board, build 28 meanwhile: **128 MB** works (HP-UX: `Physical: 131072 Kbytes`); HP-UX mounts the CD (`2/0/1.2.0 sdisk TOSHIBA CD-ROM XM-3301TA`, `mount -F cdfs`), checksums of four files right; booting HP-UX 11i's install CD stops in its ISL on `bve (rp)` (cpu-requests #9); keys typed while HP-UX's X server started made it fail ("The X-server can not be started"), the bug this build fixes |
| 30 | 2026-10-10 | + CD audio (`rtl/scsi/cd_audio.sv`, S-026: READ TOC, PLAY AUDIO, READ SUB-CHANNEL, MODE page 0x0E, the track table and frames from Main_MiSTer's windows) mixed after Harmony | setup: core +0.271 ns, pixel +0.912 ns, HDMI +0.265 ns; holds met | 35,713 (85 %) | 410 (74 %) | 35 | **on the board** with Main_MiSTer `hp9k715-enhancements` (`support/hp9k`): HP-UX reads the audio CD's table (`cdplay` from `tools/cd/hpux/cdplay.c`: 3 tracks at the cue sheet's positions) and the drive reports PLAY / position through READ SUB-CHANNEL; the sound itself not yet confirmed -- since the MiSTer's first reboot that day the HDMI capture in OBS reads silence for every source, Harmony's too (build 27 heard before; to recheck with the monitor) |
| 31 | 2026-10-10 | + the 82596 LAN (`rtl/lasi/i82596.sv`, S-027) on LASI page 7, the three-way LASI DMA arbiter, the mailbox client in `ddr3_port.sv` | -- | 37,326 (89 %) | 412 (75 %) | 35 | **did not route** ("Can't fit design in device": the router gave up on congestion); the 82596 alone 1,848 ALMs |
| 32 | 2026-10-10 | the 82596 restructured (one address adder, fields read at the address, bytes shifted in and out, 32-bit ring counters: 1,113 ALMs) and corrected from the ROM's LAN analysis (CRC-in-memory sense, SCB status before the command clears, RBD list from the first RFD at RU start, padding) | setup: core +0.040 ns, HDMI +0.118 ns, pixel +0.741 ns; holds met | 36,656 (87 %) | 412 (75 %) | 35 | **on the board** with Main `0103118`: Harmony plays at 32 and 128 MB (HP-UX `/tmp/auplay` -- an .au player setting rate/channels/format by ioctl -- `welcome.au` at 22,050 Hz, -10 dBFS in OBS, the user heard it; the morning's "silence" was a 22 kHz file `dd`'d to an 8 kHz device and, for the CD, the stock Main without the track table); HP-UX with a `lan2` kernel: `Configure LAN interfaces ... OK`, `lan1` (2/0/2, `0x080009715A01`) receives, but its frames went out without a source address (fixed in 33). CD audio: see build 33 |
| 33 | 2026-10-10 | + the 82596's source address insertion (configure byte 3 bit 3 = 0, what HP-UX's lan2 uses) and the mailbox ring pointers zeroed at start-up | setup: HDMI +0.141 ns, pixel +0.418 ns, core +0.436 ns; holds +0.257 ns | 36,717 (88 %) | -- | -- | **on the board**: HP-UX's `lan1` (192.168.99.215) answers pings from the workstation (2-3 ms) and takes telnet logins (`tools/mister/hpux.py`), but frames larger than a lan2 RFD's own data area (~202 bytes) were lost -- the RBD list read at the wrong time (fixed in 34). **CD audio heard**: `cdplay play 2 3` (over telnet) -2.2 dBFS in OBS, volume page 255/255 -- it had worked in 30-32 too: the morning's tests ran the stock Main (no track table), the afternoon's measuring window closed before the slowly typed command started |
| 34 | 2026-10-10 | + the 82596 reads the RBD list at RU start; an RFD's EOF only when the frame ends in it | -- | 36,757 (88 %) | -- | -- | **did not route** (seed 1), 40 ALMs above build 33 -- the design is at the router's limit (a framework-feature trade was tried and reverted: the user wants optimisations instead) |
| 35 | 2026-10-10 | build 34's RTL, fitter seed 2 | setup: HDMI +0.038 ns, core +0.669 ns, pixel +1.650 ns; holds +0.202 ns | 36,581 (87 %) | -- | -- | **on the board: the LAN works** -- pings of every size to 1472 bytes (full 1514-byte frames) both ways, the router at 192.168.99.1 answers, telnet and ftp (a 2 MB random file up and back identical, HP-UX's cksum matching; 558 KB/s up, 1,094 KB/s down, near 10 Mbit/s); lan1 now in `/etc/rc.config.d/netconf` (192.168.99.215, gateway .1; the original kept as `netconf.orig`) |
| 36 | 2026-10-11 | + BLR/BV ignore their reserved bits (`1d17078`, cpu-requests #9; the CPU stream) | setup: HDMI +0.221 ns, core +0.389 ns, pixel +1.579 ns; holds +0.244 ns | 36,454 (87 %), `pa_cpu` 13,771 | -- | -- | **HP-UX 11i v1's install CD gets past its ISL**: `boot scsi.2` on the serial console (bootstrap EEPROM, 128 MB; the blank `hpux11i.img` at ID 5): ISL A.00.43 boots `hpux (;0):INSTALL`, `9686820 + 1122304 + 691616 start 0x14eae8`, the kernel (vmunix CUPI80_BL2000_1108, Dec 2002) probes the I/O tree -- graph3, c720 with sdisk at .2 (the CD), .5, .6 and sctl .7, lan2, asio0, CentIf, audio, **fdc** -- then `panic: fdc_cmd_exec: FIFO problem` (PC 0x15b62c; "crashed before I/O and dump configuration was complete") and the ROM restarts. 11i's kernel binds a driver to the floppy controller (10.20 leaves it UNCLAIMED): LASI page A reads 0 (S-015, P-004), so the WD37C65's command FIFO never answers. **For the system stream**: a floppy controller model that satisfies `fdc_cmd_exec` (or makes the driver find no controller) is the next step for 11i |
| 37 | 2026-10-11 | + the LASI floppy (`rtl/lasi/lasi_fdc.sv`, S-028: pages A/D, a 765A with no drive, LASI's FIFO and DMA as the fourth DMA master; `dd17162`), seed 2 | **core setup -0.179 ns** (TNS -0.479: CPU paths only, `pa_core` -> `pa_tlb` `pg_hit` and a D-cache bypass into the ALU), HDMI +0.071 ns, pixel +1.256 ns; holds +0.256 ns | 36,912 (88 %), `lasi_fdc` 248 | -- | 35 | not recorded as a release; loaded once for a functional check (the copy `scratch/HP9K715-b37.rbf`): **HP-UX 11i's install CD boots past its floppy probe** (serial console, 128 MB): the INSTALL kernel finds no floppy, mounts its RAM file system, Ignite-UX B.4.2.108 scans the I/O (2 disks, 1 CD, 1 LAN, graphics 1), asks the keyboard language and the terminal type and shows its main menu -- `Floppies: 0` |
| 38 | 2026-10-11 | build 37's RTL, fitter seed 3 | setup: core +0.149 ns, HDMI +0.153 ns, pixel +1.311 ns; holds +0.211 ns | 36,886 (88 %) | -- | -- | **on the board** (128 MB, the graphics EEPROM): HP-UX 10.20 boots to its CDE login, `ioscan` lists `2/0/10 UNCLAIMED Built-in Floppy Drive`; then Escape at the PDC, `boot scsi.2` on the PS/2 keyboard: **HP-UX 11i's installer runs on the HDMI console** (the ITE) to its main menu, `Floppies: 0`. In romsim the ROM's floppy self-test passes with fastboot off (section 11) |
| 57b | 2026-10-15 | build 57, the TCOE install again on a fresh 8 GB image (`hpux1111b.img`, ID 5; the wizard driven with `misterkvms-cli`) | | | | | **fileset 353/977 at 2 h 02 m after Finish vs build 53's 356**: the install is I/O-bound (the SCSI target / hps_io path, swinstall's disk traffic), not CPU-bound; `RESUME-20261015-dual-issue.md` has the measurements to make next. Abandoned at the user's request after the checkpoint |
| 57 | 2026-10-15 | **the performance core** (`2d5e327`, `372bb69`; cpu-timing.md 5-8): D-cache misses complete in W (no replay), a D-predicted branch target looked up in the redirect cycle (from the F2 adder's register), the TLB operation request/tag registered, the FPU's store select from the decoded size; seed 4 | **core -0.009 ns** (one path, the next +0.01), HDMI +, pixel + | 36,434 (87 %) | -- | -- | **on the board** (the user's call: "try 57 as a test"): HP-UX 11.11 (the new TCOE install at ID 5, `hpux1111.img`) boots to `Console Login:` and the CDE login in about 7 minutes from the core load, the whole multi-user start-up (Apache, Tomcat, Samba, VxVM, SAM ...) with no fault. perf suite -17 % cycles over fit 15 (a missed load 33 -> 25 cycles, a taken loop branch 2 -> 1 bubble) |
| 54-56, 58-60 | 2026-10-15 | fits of the same stream: 54 = fits 16-17 as is, core **-0.440** (the D adder into the I-cache address, the TLB chain); 55 = + the F2 adder, -0.036; 56 = + the registered TLB operation, -0.105 (the FP store -> load forward -> bypass -> ALU path); 58/59/60 = build 57's RTL at seeds 1/2/3: -0.357 / -0.357 / (see the next row) | | 36.2-36.6k | -- | -- | not loaded |
| 53 | 2026-10-14 | **release**: build 52's RTL without `HP9K715_DEBUG` (`release/HP9K715.rbf` = `HP9K715_20261014.rbf`); seed 4 | setup +0.317 ns, hold +0.248 ns | 35,688 (85 %) | -- | -- | release notes in the root README |
| 52 | 2026-10-14 | **cpu-requests #10 fixed** (`5cda517`: `pa_fetch` keeps only the oldest instruction at a redirect's delay-slot address -- an `rfi` into a nullified `b,l,n` whose IIAOQ back is its own target fetched the target twice, the second copy ran as the first's delay slot and `b,l` linked to target + 4); the recorder still on (`HP9K715_DEBUG`), event 20 only for rp; seed 4 | setup +0.224 ns, hold +0.241 ns | 37,162 (89 %) | -- | -- | **on the board** (serial console, 128 MB, the 2003 OE CD, a scratch 2 GB disk at ID 5): the installer's configuration step -- stalled 5/5 on builds 39-44 -- passes; `trig flow 0x2ee1a4` froze the ring at the environment step on a *legitimate* flow into 0x2ee1a4 (the kernel's return from an ITLB miss there), every link store/reload in the ring correct (`scratch/ring52a.txt`); the wizard then walked on by hand |
| 51 | 2026-10-14 | debug build for cpu-requests #10: the recorder on (`HP9K715_DEBUG`), new CPU taps `dbg_ea`/`dbg_stdata`/`dbg_wev` and events 20 (user-mode sp-based loads/stores: EA and datum) and 21 (W holds: D-cache miss, walk, replay) in `rtl/hp715.sv`, `trace_dump.py`; seed 4 | setup +0.331 ns | 37,052 (88 %) | -- | -- | **on the board**: the installer stalled at its first step on the first run (`tools/mister/inst11i_repro_flow.sh 51a`, `scratch/ring51a.txt`): the onset shows the interrupt taken on the *nullified* `b,l,n` at 0x2ed400 (the slot of 0x2ed3fc's), the `rfi` back into it, then 0x2ee0dc (the `b,l`) **retiring twice**, the `stw rp` storing 0x2ee1a4 and retiring twice too -- the mechanism (cpu-requests #10, cpu.md 6.2). The unrestricted event 20 lost the burst's events (one sent per cycle): restricted to rp in build 52 |
| 50 | 2026-10-14 | + **A2/A8** (the 53C710's diagnostic DMA FIFO in one 64 x 9 MLAB, no staging copies between its engine and the `dma_*` port; run-rom.sh passes) and the boot-mode sequencer finished (steps gated on the ROM's chassis code 0x43 / ISL's 0x0C, the millisecond scaled with the CR16 speed-up in romsim) | setup: core +0.119 ns, HDMI +0.328 ns, pixel +1.449 ns; hold +0.269 ns (**every clock met**) | **35,925 (86 %)**: `ncr53c710` 2,167 (was 2,193), `artist` 3,558, `mioc` 1,845, `boot_seq` 114; regs 43,229 | -- | 35 | romsim: ISL mode works on **both** consoles (RS-232 and the graphics console with the PS/2 keyboard: ESC at the 0x43 window, `boot pri isl` at `BOOT_ADMIN>`, `ISL>` reached); single-user mode on RS-232 starts the kernel. **On the board** (.92, the user's mounted graphics EEPROM, 64 MB): a normal boot reaches the X login; with "Boot mode = ISL" written into `HP9K715.CFG` (status[17:15] = 2) the ROM **still autobooted** to multi-user in the one trial -- not understood yet (the sim passes the same path); next: a board-side look (the recorder's PS/2 events with `HP9K715_DEBUG`, or the serial EEPROM `scratch/hp715_rs232.eep` to test the UART path on the board) |
| 49 | 2026-10-14 | + **A3/A4** (Artist: CPU reads aligned as the words arrive, no 5-word buffer and 320-bit shifter; the launch captures that duplicated registers), **the debug recorder behind `HP9K715_DEBUG`** (`hp715` `DBG_RECORDER`, off in release builds: the slots, their 15:1 mux, `trace_ddr3` and the blocks' debug outputs go; a commented `VERILOG_MACRO` line in the QSF turns it on), and **the OSD boot work** (`RESUME-20261014-osd-boot.md`): the shipped EEPROM built into the core (`rtl/mister/hp715_default.hex`, S-016), "EEPROM (no image)" Built-in / Blank, a mounted image resets the machine, Display default Graphics, RAM default 32 MB (values reordered: saved configs change meaning), **"Boot mode (on reset)"** O[17:15] with the keystroke sequencer `rtl/boot_seq.sv` (S-029; the LASI taps `con_*`, `ps2_dev` `inj_*`); seed 4 | setup: core +0.713 ns, **HDMI -0.054 ns** (the framework's scaler path, as builds 20/41/42: placement), pixel +1.085 ns; hold +0.250 ns | **35,817 (85 %)**: `hp715` own 28 (was 951), `artist` 3,502 (was 3,664), `mioc` 1,816, regs 43,576 | -- | 35 | run-rom.sh passes; tb_artist passes; romsim: BOOT_ADMIN, ISL and single-user modes work on the RS-232 console (the sequencer types ESC, `boot pri isl`, `hpux -is`; the kernel starts: `Boot: disk(2/0/1.6.0.0.0.0.0;0)/stand/vmunix`); on the board (.92, the user's mounted EEPROM): HP-UX 10.20 to the X login. The keyboard path of the sequencer (graphics console) does not stop the autoboot yet (the ROM reads the ESC's set-2 code 0x76 and ignores it; under study) |
| 48 | 2026-10-14 | **A1 of the area plan** (`docs/design/area-plan.md`): the MIOC's 16 comparator/mask pairs keep only their decoded bits in flops (comparator 31:23, mask 28:22), the whole words in a 32 x 32 MLAB for read-back (one more cycle, S_ICREG; unwritten entries read their reset value), one block decoder shared by the line and uncached ports. MIOC alone (`scratch/mioc_map`): 2,760 -> 2,298 ALMs, 3,085 -> 2,388 registers | setup: **core -0.280 ns** (TNS -0.348: `pa_core` -> `pa_tlb` `pg_hit` and `w_trap` -> ALU, the CPU paths of build 37; placement), HDMI +0.412 ns, pixel +1.774 ns; holds +0.132 ns | **36,965 (88 %)**, `mioc` 1,746 (was 2,102), regs 45,834 (was 46,819) | -- | 35 | run-rom.sh passes; on the board (.92, 64 MB, the release EEPROM, the user's Main of 05:07): HP-UX 10.20 boots to its X login on HDMI (the MiSTer's screenshot; OBS no longer shows this board). Build 49 gets another fitter seed |
| 47 | 2026-10-11 | + the recorder's flow-trigger mode (`2949497`: `board.sh trig flow ADDR` -- itool's user-mode control flow from the start, freeze 20000 events after the first branch to ADDR) | setup: core +0.417 ns, HDMI +0.214 ns, pixel +1.141 ns | -- | -- | -- | **the stall's cause**: with the trigger at 0x2ee1a4 the ring holds the onset -- `yylex`'s `b,l 0x2ee1a0,rp`, the `stw rp,-14(sp)` retiring, **an external interrupt taken at 0x2ee1a4**, the kernel's return there, and the scanner's final `bv r0(rp)` returning to 0x2ee1a4: the link register held the branch target + 4 (the delay slot's `e_seq`) instead of the branch's own link. **cpu-requests #10** (`50e7cba`); captures in the scratchpad's `keep/bl-link-interrupt/` |
| 46 | 2026-10-11 | (not built: replaced by 47 during its synthesis) | -- | -- | -- | -- | -- |
| 45 | 2026-10-11 | + recorder event 19, user-mode control-flow discontinuities after the trigger (`10f924b`) | setup: core +0.078 ns, HDMI +0.151 ns, pixel +0.985 ns | 37,126 (89 %) | -- | -- | on the board: **the configuration step passed twice** (builds 39-44: 0 of 5) and the same loop then struck at the root-group-disks step -- placement-dependent, so a cycle-exact race. The flow trace of the loop: `yylook` reaches EOF correctly and its `bv r0(rp)` returns into itself at 0x2ee1a4 (the instruction after its `stw rp,-14(sp)`), forever |
| 44 | 2026-10-11 | + event 18 at the first user-mode instruction after the call (HP-UX returns by a privilege-lowering branch, not RFI; `ac18efa`) | setup: core +0.570 ns, HDMI +0.133 ns, pixel +1.388 ns | -- | -- | -- | on the board: the stalled scanner's file (53,455 bytes) is read as 6 x 8192 + 0x10cf bytes, then every `read` returns 0 -- the kernel is right, the loop is in user space |
| 43 | 2026-10-11 | + recorder event 18, a system call's return value (r28/r22 at its RFI; `fee4325`) | setup: core -1.175 ns (a diagnostic build) | 37,224 (89 %) | -- | -- | the first RFI after a call is not HP-UX's return path (`open` showed 0x77): event 18 redefined in 44 |
| 42 | 2026-10-11 | + the recorder's freeze and one-shot state survive the broadcast reset (HP-UX's reboot); user-mode external interrupts kept in the filtered mode as PC samples (`99bf605`) | setup: core +0.402 ns, HDMI -0.522 ns (the framework's HDMI path; a diagnostic build), pixel +1.500 ns | 37,321 (89 %) | -- | -- | on the board: the configuration stall is **`itool`'s lex scanner** (text 0x2ee180-0x2ee780: `yylook` with the inlined `getc`, `__filbuf`, `read(7, buf, 0x2000)`) spinning at the end of a file it opened after parsing two config files alternately -- a scanner only does that inside an unterminated construct or with a `yywrap` that keeps saying "more". Run to run it varies: one run (build 41) instead printed `run_cmd: Process: 42 (net_cfg_prep): killed by signal: 4` (SIGILL) and rebooted -- the resume prompt's unexplained reboots. HP's `cpp` on `itool.ui` in the recovery shell gives a sane 178,167-byte, 8,629-line file; memory is as on QEMU (available 88,484 KB vs 89,756) |
| 41 | 2026-10-11 | + the recorder's pre-trigger one-shot (`dbg_shot` = status[127:64]: armed from reset, freeze 8192 events after the K-th system call N with r26 M; `board.sh trig`), cache maintenance and trap 26 dropped from the filter (`0b801c8`) | setup: core +0.269 ns, HDMI -0.109 ns, pixel +1.459 ns | 37,122 (89 %) | -- | -- | on the board, trigger = the 100th `read` of fd 7: the ring holds the wizard's start-up -- `itool` forks a child that runs `/usr/ccs/lbin/cpp` on `/opt/ignite/ui/itool.ui` (9,387 writes to fd 5), parses its output (fd 6, the heap growing a page at a time), parses two config files alternately through fd 7, then spins reading fd 7 |
| 40 | 2026-10-11 | + recorder events 16 (a system call's r2/r24/r23) and 17 (82596 events), the one-shot filtered capture armed by Pause (`bd5298c`, `ff25f74`) | setup: core +0.232 ns, HDMI +0.033 ns, pixel +1.354 ns; holds +0.242 ns | 37,145 (89 %) | -- | -- | on the board (serial console, 11i's installer, guided, DHCP on, network on): the capture confirmed the configuration hang is `itool` alone calling `read(7, buf, 0x2000)` (32,763 of the 32,763 system calls in a 64K-event window; the only other events two received multicast frames and their ACK) -- no other process makes a system call, so the helper it waits for sleeps in the kernel. Cache maintenance leaked through the filter (fixed in 41) |
| 39 | 2026-10-11 | + recorder event 15, the HP-UX system call (r22, r26, r25 at each user-mode gateway trap 7; a mirror of the CPU's register-write taps in `hp715.sv`, nothing in `rtl/cpu/`), seed 3 | setup: core +0.126 ns, HDMI +0.380 ns, pixel +1.307 ns; holds +0.137 ns | 37,156 (89 %) | -- | -- | **on the board** (the core in `_Unstable` now): HP-UX 11i's installer, guided, DHCP on, network on: the configuration step hangs at "Working..." with `itool` calling `read(7, 0x4029f960, ...)` ~80,000 times per sample at EOF and nothing else running (`RESUME-20261011-11i-install.md`) |

## 11. Simulation

* `verilator/sim.v` (`emu`): hp715 + RAM, ROM and check-store arrays +
  the ROM loader; the GUI (`make && ./obj_dir/Vemu`) shows the serial
  console, the LEDs and the CPU taps.
* `verilator/romsim/`: the same `emu` with a headless driver (no SDL):
  loads the ROM and an EEPROM image, logs the serial console and every
  chassis code, can type into the serial port (`--type`, then any number
  of `--then AFTER TEXT`), and stops on a string (`--until`, looked for
  after the last typed text). SCSI images on the hps_io-style block
  devices (`--disk0` ID 6, `--disk1` ID 5, `--cd` ID 2; `--snapshot` keeps
  writes in memory; `disks/README.md` has the HP-UX 10.20 image), and a
  SCSI trace (`--scsitrace`: SCRIPTS instructions, selections, interrupts,
  bus bytes), the MIOC's transactions (`--miotrace`) and the board
  recorder's events (`--evtrace`, the same records `tools/mister/trace_dump.py`
  reads from a board). `--traps` lists every interruption; `--memdump CYCLE ADDR LEN FILE`
  writes LEN bytes of the ideal RAM from physical ADDR at CYCLE (it showed
  HP-UX's PDIR entry intact while the walker read stale data); `--fptrace [--fptrace-from C]` prints the FP unit's events: every operation
  issued at W commit with the FPSR before it, the operands the engine starts
  from, its result and the FPSR after, every FP load's data and FP store's
  data (user-mode PCs end in 3, the privilege level; it found the fr0 operand
  bug, cpu.md 1.1). `--wtrace A B`
  prints the core's W and M stages, the TLB and the D-cache engine every
  cycle from A to B (and, while the walker runs, the PDIR words it read and
  the CR28 it will write) and dumps all 64 + 8 TLB entries at both ends (it reads the model's internal
  signals; it found the I-LAB livelock, cpu-requests #7).
* `ROMSIM_SDRAM=1` (`make -C verilator romsim ROMSIM_DIR=obj_dir_roms
  ROMSIM_SDRAM=1`): system RAM is `rtl/mister/sdram64.sv` on a chip model
  (`verilator/sim_sdram_chip.sv`) instead of the ideal array -- slower, but
  it has the board's latency, refresh stalls and burst order (it found
  cpu-requests #6).
  Whole-model checkpoints (`--save-at CYCLE`, `--save-on STR`, `--restore`; valid only for the
  build that made them), trace switches through an input port so they work
  after a restore (`--gsctrace`, `--l1trace`, `--flags-from`), and a
  simulator-only CR16 speed-up (`--turbo N`, default after 30M cycles: the
  ROM's long delays are CR16 loops; selftest1's timer test needs the real
  rate). **The I/O self-test (fastboot off) also needs the real rate**: with
  `--turbo` the ROM's waits are too short for the RTC to tick and for
  Harmony's loopback samples, so "Audio" and "Real Time Clock" fail, and the
  audio interrupt that arrives late sits in IRR and fails the floppy test's
  first check (IRR == 0) -- "Floppy" too. Recipe (2026-10-11): an EEPROM
  with fastboot off (`mkeeprom.py bootstrap --fastboot 0 -o scratch/slow.eep
  --hex scratch/slow.hex`), `--turbo 15 --save-on '0x06.C2EF' FILE` (the
  checkpoint just before `io_selftest`, ~15 min), then `--restore FILE`
  without `--turbo` to `BOOT_ADMIN>` (~140M cycles): only HIL and RS-232 2
  (WAX, P-001) and Parallel (P-010) fail.
* `tests/run-rom.sh`: boots the ROM headless and asserts milestones on the
  serial log and the chassis codes (BOOT 3.2).
