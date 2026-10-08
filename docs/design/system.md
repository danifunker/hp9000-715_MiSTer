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
acknowledged with `io_err` (loads: precise HPMC; stores: HPMC at the next
boundary, STUBS S-006), MIOC_STATUS |= 0x02 (pioae) and MDERRADD = the
address (HW 1.3, 1.7, 7).

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
| F800_0000-F9FF_FFFF | Artist *(later)*: until it exists, BE (no graphics) | F800_0000 word: BE (no option ROM, STI is in the system ROM); F830_0004 answers; F900_0000 = framebuffer | registers / VRAM | HW 6.3 |
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
doubleword inside the RAM, 28 bits), `ram_line` (1 = 4 beats, wrapping from
`ram_addr[4:3]`; 0 = one doubleword), `ram_be[7:0]` (single writes),
`ram_wdata` + `ram_wready` (one per beat), `ram_rdata` + `ram_rvalid`.
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
| +0x4000 | Harmony audio | stub P-003 (`06a` sec. 9) | R06a |
| +0x5000 | RS-232 16550A (+0x800) | `lasi_uart.sv`: true 16550A, 16-byte FIFOs, IIR priorities, TEMT, scratch, loopback; 7.3728 MHz reference (P-009) | R06b 2; HW 4.3 |
| +0x6000 | 53C710 SCSI | stub until step 6: unit reset, register file that reads back what the ROM's IODC self-checks need, no SCRIPTS | R06d; HW 4.5 |
| +0x7000 | 82596 LAN | stub P-005 (writes ignored; the ROM never reads it) | HW 4.6 |
| +0x8000 | PS/2 keyboard (+0x000) and mouse (+0x100), mirrored every 0x200 | `lasi_ps2.sv`: ID, RESET, 4-deep RX FIFO, 1-deep TX, CONTROL (ENBL, LPBXR, DIAG), STATUS (RBNE, TBNE, CMPINTR), loopback; device side to a keyboard/mouse model | Lasi ERS 9; HW 4.7; R06b 1 |
| +0x9000 | RTC | 32-bit seconds counter, 1 Hz from the board clock, write clears the prescaler; set from the MiSTer RTC at power-up *(later)* | Lasi ERS 8 |
| +0xA000, +0xD000 | floppy and its DMA | absent: registers read 0 (P-004) | |
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
| RAM / DDR3 / video | on the board *(later)*: SDRAM at 2 x clk_sys with a synchronous bridge (the Quadra's `sdram.sv` + beat bridge pattern), DDR3 through the MiSTer `DDRAM_*` bridge at its own clock with a CDC FIFO (the Indy's `ddr3_mux.sv`), video from the MiSTer framebuffer (8-bit palette mode) reading VRAM in DDR3 |
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

## 9. Simulation

* `verilator/sim.v` (`emu`): hp715 + RAM, ROM and check-store arrays +
  the ROM loader; the GUI (`make && ./obj_dir/Vemu`) shows the serial
  console, the LEDs and the CPU taps.
* `verilator/romsim/`: the same `emu` with a headless driver (no SDL):
  loads the ROM and an EEPROM image, logs the serial console and every
  chassis code, can type into the serial port, and stops on a string.
* `tests/run-rom.sh`: boots the ROM headless and asserts milestones on the
  serial log and the chassis codes (BOOT 3.2).
