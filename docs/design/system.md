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
| +0x4000 | Harmony audio | stub P-003 (`06a` sec. 9) | R06a |
| +0x5000 | RS-232 16550A (+0x800) | `lasi_uart.sv`: true 16550A, 16-byte FIFOs, IIR priorities, TEMT, scratch, loopback; 7.3728 MHz reference (P-009) | R06b 2; HW 4.3 |
| +0x6000 | 53C710 SCSI | `rtl/scsi/ncr53c710.sv` (registers, SCRIPTS, DMA on the MIOC's `dma_*` port; S-021) and `rtl/scsi/scsi_targets.sv` (disks at IDs 6 and 5, CD-ROM at 2, on hps_io block devices; S-020); IRQ = IPR bit 9. The ROM boots ISL from it | R06d; HW 4.5 |
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
| Video | until Artist: the RS-232 console as 80 x 29 text with the LEDs and the power LED on a status line, 640x480 (`rtl/mister/serial_term.sv`, STUBS S-018); the MiSTer keyboard also types into the console (`rtl/mister/ps2_ascii.sv`) |
| SDRAM | `rtl/mister/sdram64.sv`, SDRAM_CLK = clk + 270 degrees; read capture an OSD option (O[9:8], default edge 3 after the READ; S-019) |
| Debug recorder | `rtl/mister/trace_ddr3.sv`: the machine's debug events (`hp715` `dbg_ev`: SCRIPTS instructions, SCSI bus bytes, interrupts, selections, DMA, the CPU's line requests -- a repeat of the previous line read is left out -- and its uncached accesses to RAM and the 53C710) as 32-byte records in a 64K ring at DDR3 0x3200_0000, lowest priority on `ddr3_port`; `tools/mister/trace_dump.py clear|dump` reads it on the MiSTer, `decode` turns romsim's `--evtrace` into the same text |
| LEDs | LED_USER = front-panel LED4 (the OS heartbeat), LED_DISK = LED3, LED_POWER = LASI's power LED |

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
| 14 | 2026-10-09 | + fr0 as a source operand reads +0 (`8d18d88`) | setup +0.254 ns, hold +0.251 ns | 28,601 (68 %) | 371 (67 %) | 37 | **HP-UX 10.20 completes its multi-user start-up on the MiSTer** (64 MB, the board's OSD setting: the kernel prints `Physical: 65536 Kbytes`): "Start Software Distributor agent daemon OK", the rest of the sequence (NCS broker FAIL, no network), "The X-server can not be started on display hpux:0" (no Artist yet), then `Console Login:` on the serial console. **2026-10-09: root logs in** (password set from a single-user boot, `disks/README.md`): `uname -a` = `HP-UX hpux B.10.20 U 9000/715`, `model` = `9000/715/D`; `ioscan -f` claims c720 (2/0/1) with the disk at 2/0/1.6.0, asio0 (2/0/4), CentIf (2/0/6), ps2 (2/0/11), processor (8), memory (9), and lists LAN (2/0/2), audio (2/0/8) and floppy (2/0/10) UNCLAIMED (no driver bound: for LAN and audio as `docs/review/06` predicts, the floppy not checked); `bdf` = / 3.6 GB VxFS 37 % used, /stand 48 MB HFS; 512 MB swap on lvol2. The clock reads 5 h behind UTC (S-022). `release/` = this build |

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
  rate).
* `tests/run-rom.sh`: boots the ROM headless and asserts milestones on the
  serial log and the chassis codes (BOOT 3.2).
