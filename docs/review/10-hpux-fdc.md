# HP-UX 11i and HP's ROM: what they need from LASI's PC floppy

This is part of the OS track (`06-os-hpux-linux.md`). It comes from two sources:

- a disassembly of HP-UX 11i v1's INSTALL kernel, the one its install CD boots
  (`hpux11i_oe_cd1.iso`, LIF file `INSTALL`, a plain SOM with symbols;
  `python3 tools/hpux/hpdisk.py disks/hpux11i_oe_cd1.iso lifget INSTALL
  roms/hpux11i/INSTALL`, then `tools/hpux/som.py roms/hpux11i/INSTALL dis
  --range 0x455f48 0x45c970`): the `pc_fdc` driver (`fdc_*`, source
  `/ux/core/kern/common/wsio/pc_fdc.c`) and the `pc_floppy` driver on top of
  it (`pflop_*`, `fdd_*`);
- HP's PDC 1.6 floppy self-test (`roms/disasm/rom.dis` 0xF000F854 ..
  0xF001031C), which runs with fastboot off.

The result is `rtl/lasi/lasi_fdc.sv` (STUBS S-028): the LASI wrapper and a
765A with **no drive**. HP-UX 10.20 has no floppy driver (ioscan:
`2/0/10 fdc UNCLAIMED`), Linux has none, QEMU models none.

## 1. Why build 36's 11i boot panicked

```
2/0/10 fdc
panic: fdc_cmd_exec: FIFO problem
PC-Offset Stack Trace: 0x0015b62c 0x0045a554 0x0045b154 0x0045b540 ...
```

The stack is `panic` < `fdc_cmd_exec` < `fdc_state` < `fdc_start` <
`fdc_enqueue` < `fdc_action` < `fdc_cmd` < `fdd_recal` < `fdd_open` <
`pflop_open` < `pflop_probe` < `wsio_probe`. Every command starts in
`fdc_cmd_exec` state 0, which checks that LASI's FIFO is empty: it reads the
floppy status (+0x1C) and wants bit 1 (EMPTY); otherwise it reads the FIFO
(+0x14) up to four times and panics. Page A read 0 (no EMPTY), so the first
command panicked.

## 2. Attach

- `fdc_attach` (0x45C830) takes sversion **0x83** (the LASI floppy; 0x0F is
  Gecko's): `isc+0x3C` = the HPA (0xF010A000, the FDC registers),
  `isc+0x08` = HPA − 0xA000 + 0xD000 (**0xF010D000**, the DMA registers),
  both mapped, prints "PC Floppy Disk Controller Interface".
- `fdc_open` (0x45BAC4), on the first open: allocates and maps a 4 KB DMA page,
  then `fdc_reset`.
- `fdc_reset` (0x45964C), byte stores: **+0x000 = 0** (the unit's reset
  register; Linux writes 0xFFFFFFFF there), **+0x018 = 4** (FDC_IE),
  **DOR +0x040 = 0**, wait, **DOR = 0x0C** (out of reset, DMA/INT gate on),
  wait. It never drains the reset's SENSE INTERRUPT statuses.

## 3. The command engine (`fdc_cmd_exec`, 0x45A3E8)

A table-driven state machine (jump table at 0x891E40); "wait" = return to
the caller with a timeout armed; an interrupt (`fdc_isr` → `fdc_state(INT)`)
or the timeout re-enters it.

| state | does |
|---|---|
| 0 | DMA enable (0xF010D004) = 0, control = 0; status bit 1 (EMPTY) or drain/panic (§1); CCR (+0x020) = the data rate; SPECIFY (3 bytes) when the drive's step/head times changed; DOR = 0x0C \| drive \| motor bit; wait `fdd_motor_start` (500) if the motor was off |
| 1 | `fdc_check_media`: status bit 3 (high-density sense) and DIR (+0x020 read) bit 7 (disk change); with data: FDAR (0xF010D000) = the buffer, DMA enable = 1, control = 0x0E (RE\|FDC_IE\|DMA_IE) or 0x0D (WE\|...); without: control = 4 (FDC_IE) |
| 2, 13 | one command byte per pass through `fdc_cmd_out` |
| 8 | polled commands go to 10, the rest wait for the interrupt |
| 9 | after the interrupt: for SEEK (0x0F) and RECALIBRATE (0x07) send SENSE INTERRUPT STATUS (0x08) |
| 10, 14 | one result byte per pass through `fdc_results_in`, at most 16; a SEEK/RECALIBRATE whose sense answered 2 bytes with **ST0 & 0xC0 = 0xC0** goes back to 9 and waits for another interrupt |
| 11, 12 | errors and the end: DMA off, control = 0, FIFO drained (panic again if it will not empty), `fdc_reset` on some errors |

- `fdc_cmd_out` (0x459BE0): up to `fdc_cmd_wait` (50) polls of **MSR (+0x008)
  & 0xC0 == 0x80** with a 1 us busywait, then the byte to **data (+0x004)**.
- `fdc_results_in` (0x459CD4): up to `fdc_res_wait` (50) polls for **RQM**;
  then **DIO** set → read a byte from +0x004; DIO clear → the result phase is
  over.

## 4. The probe and what "no drive" must look like

`pflop_probe` (0x45917C) opens each drive (`pflop_open` → `fdd_open`); an open
that returns 0 or EBUSY binds `pc_floppy` ("HP_PC_FDC_FLOPPY"), anything else
means no drive. `fdd_open` calls `fdd_type` (drive parameters) and
`fdd_recal` (0x456144): RECALIBRATE (`07 drive`) through `fdc_cmd` with
`fdd_seek_timeout` (5000), then `fdc_wait(fdd_head_settle)`; it succeeds only
if `fdd_done` set the drive's "recalibrated" flag (0x40), which it does when
the command ended without error. `fdd_error` judges the result bytes with
`fdc_res_check` against **`fdd_error_cond`** (0x9FC5F8, 14 entries:
command mask, result byte, mask, value, errno, message). For RECALIBRATE the
first match is entry 9:

| entry | commands | test | errno | message |
|---|---|---|---|---|
| 9 | RECALIBRATE | ST0 & 0x10 == 0x10 | 6 (ENXIO) | "Equipment check (no track zero indication)" |
| 10 | 7, 0x0F | ST0 & 0x20 == 0 | 5 | "Seek failed to complete" |
| 11 | most | ST0 & 0xC0 == 0xC0 | 5 | "Unexpected ready status change" |
| 12 | most | ST0 & 0xC0 == 0x80 | 5 | "Invalid command attempted" |

A real 765A with no drive steps 77 times, never sees TRK0 and ends the
RECALIBRATE with **ST0 = 0x70 | drive** (abnormal termination, seek end,
equipment check), PCN 0: entry 9, ENXIO, no floppy attached -- the clean
outcome. The sequence on the first open, with LASI's edge-triggered IPR
(ERS 14.2):

1. `fdc_reset`: the DOR release raises INT with four pending "ready changed"
   statuses; with FDC_IE the edge reaches IRR bit 20; no command is active,
   so `fdc_isr` ignores it.
2. State 0 clears the control register (the interrupt line falls), checks
   EMPTY, writes the CCR, sends SPECIFY, turns the motor on, waits 500.
3. State 1 sets FDC_IE: INT is still high from the reset, so the line rises
   again and an interrupt is latched (delivered after the spl5 section).
4. RECALIBRATE goes out; state 9 waits; the early interrupt makes it send
   SENSE INTERRUPT STATUS → **0xC0, PCN** (the first reset status); INT
   drops; ST0 & 0xC0 = 0xC0 → back to state 9 to wait.
5. 77 steps later the RECALIBRATE ends: INT rises (the remaining reset
   statuses are discarded, as QEMU's 82077 model does), the sense answers
   **0x70, 0** → ENXIO.

So the FDC must drop INT on each SENSE INTERRUPT STATUS and raise it again
when the seek ends; a controller that kept INT high through all four reset
statuses would leave step 5 without an edge and the driver on its 5 s timeout
(then its timeout path, which also sends the sense).

## 5. HP's ROM self-test (fastboot off; `HARDWARE.md` 4.9)

`0xF000F854` runs seven sub-tests on the HPA it is given (0xF010A000); a
failure code is `(sub-test result << 8) + step`.

| sub-test | what it does and needs |
|---|---|
| 0xF000F904 | control = 0, DMA enable = 0, DOR = 0, 5 us, DOR = 0x0C; **MSR == 0x80** within 20 ms |
| 0xF000F9B0 | drain: read the FIFO until status EMPTY (20 ms) |
| 0xF000FA24 | control = 1 (WE: slave writes allowed); FIFO writes 0xFF, 0x00, 0xAA, 0x55 with status & 7 == 0 after the first three and status & 6 == 0 after the fourth; reads back 0xFF, 0x00, 0xAA, 0x55 with status & 7 == 0 between and status & 5 == 0 at the end; control = 0 |
| 0xF000FB68 | IMR = 0x100000; memory bytes (top lane of each word) 0x47F8 = 0xFF, 0x47FC = 0, 0x4800 = 0xAA, 0x4804 = 0x55, 0x4808 = 1; **IRR == 0**; control = 9 (WE\|DMA_IE); FDAR = 0x47F8, enable = 1; within 1 s **status bit 2 (DMA_IRQ)**, **IRR == 0x100000**, EIRR bit 3 (LASI's), status bit 0 (FULL); FIFO reads 0xFF, 0, 0xAA, 0x55 and then **1** (refilled from 0x4808); enable = 0, drain, control = 1; again from FDAR = 0x4FF8 (offset 0x3FE) with 1, 0x55 and, wrapped to the page start, 0xAA, 0, 0xFF |
| 0xF000FF4C | control = 1, FIFO = 0xFF, 0, 0xAA, 0x55; control = 0xA (RE\|DMA_IE); **DMA_IRQ still 0**; FDAR = 0x47F8, enable = 1; DMA_IRQ and EMPTY within 10 ms; the four bytes in the top lanes of 0x47F8..0x4804; the same at 0x4FF8 wrapping to 0x4000 |
| 0xF0010200 | MSR == 0x80; data = 0x08 (SENSE INTERRUPT STATUS); within 100 ms MSR bits 7 and 6; one byte read (the reset status 0xC0) |

With fastboot on (the shipped EEPROMs) the ROM does not touch the floppy.

## 6. The register map as built

Page A (0xF010A000), byte registers, the same byte in every lane:

| offset | R | W |
|---|---|---|
| +0x000 | 0 | unit reset (FDC and wrapper) |
| +0x004 | 765 result byte | 765 command byte |
| +0x008 | MSR: 7 RQM, 6 DIO, 5 NDM (0), 4 CB, 3:0 seeking drive | -- |
| +0x014 | FIFO (pop) | FIFO (push, needs WE) |
| +0x018 | control | control: 0 WE, 1 RE, 2 FDC_IE, 3 DMA_IE |
| +0x01C | status: 0 FULL, 1 EMPTY, 2 DMA_IRQ, 3 density sense (0) | -- |
| +0x020 | DIR: bit 7 disk changed (1, no disk) | CCR (ignored) |
| +0x040 | DOR | DOR: 1:0 drive, 2 !reset, 3 DMA/INT gate, 7:4 motors |

Page D (0xF010D000): +0x000 FDAR (31:12 page, 11:2 word offset, 0 DMA_EN
read-only), +0x004 DMA enable (bit 0; the rest FDAR's, read-only). The
interrupt (LASI bit 20) is (INT and FDC_IE) or (DMA_IRQ and DMA_IE); IORESET
bit 5 holds the unit in reset.
