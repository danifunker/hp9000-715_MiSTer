# HP-UX 10.20: what the c720 driver needs from the LASI 53C710

This is part of the OS track (`06-os-hpux-linux.md`). It comes from three sources:

- a disassembly of the HP-UX 10.20 kernel (`roms/hpux/vmunix`, kernel virtual addresses);
- a QEMU `-M 715` run on the SIGP-patched binary, with the RAM dumped so the SCRIPTS could be decoded *after* the driver had patched them;
- an exec trace of the c720 code interleaved with the ncr710 and LASI register traces.

The decoder, the script listings and the call flow are in the session scratchpad under `keep/hpux-analysis/c720/` (listed in `keep/INDEX.md`).

Register offsets are given as **LE name/offset (BE bus offset)**. The driver itself always uses the BE offsets.

## 0. Why QEMU `-M 715` fails

INT 0x0F is not an error. It is the normal "bus close" acknowledgement.

HP-UX rejects any SCRIPTS interrupt that arrives with DSTAT.DFE clear, and QEMU clears DFE when it raises SIR (`qemu-src/hw/scsi/ncr53c710.c:634-636`). So the close never completes, and 15 s later the driver reports "Third party detected bus hang" (§3).

On real hardware DFE is a pure status bit that reads 1 whenever the FIFO is empty (53C710 manual :2094-2105, default 1).

Together with the missing ISTAT.SIGP behaviour (review 03 §B.3), that is why HP-UX cannot get past the SCSI probe under QEMU.

## 1. Attach and probe

- **Driver hookup.** `c720_install`@0x4F7A8 chains `core_attach`, `pci_attach` and `eisa_attach`.
- **Chip selection.** `c720_core_attach(sversion, isc)`@0x18AB40 matches the IODC sversion and sets `lbp->flags` (+0x20). Code: 0x18AB54-0x18ABB8.

  | sversion | flags | chip |
  |---|---|---|
  | **0x82** | **0x400400** | LASI 53C710 (confirmed in RAM) |
  | 0x71 | 0x100100 | LASI/ASP 53C700 |
  | 0x89 | 0x801003 | other |
  | 0x7C | 0x800803 | other |

- **The sversion comes from PDC, not from the chip.** The path is `read16_pdc_iodc` → `extrw,u w1,23,20`@0x83460. So PDC/IODC must report sversion 0x082 at HPA 0xF0106000.
- **HP-UX never touches HPA+0x000..0x0FF.** Every access is at +0x100..+0x13F, as bytes or 32-bit words, never halfwords. The LASI "SCSI Reset" register (Lasi_ers.txt:594) is never written.
- **Register base** is HPA + 0x100 (or +0x800 if flags & 0x1000) (0x18ACA0-0x18ACBC).
- **IDs.** The initiator ID is 7 (`c720_initiator_id`@0x4434D4). Up to 8 targets are supported.
- **Chip family is decided only by the flags.** No 710 revision register is read.
  - flags < 0x800000: 700/710 register map.
  - 0x100000: 53C700. Only this selects the `*700` ISR variants and ABRT instead of SIGP.
  - 0x600000: 710 family. Selects LCRC for the reselect ID, SBCL SSCF writes, CTEST8 FIFO clear, and a 64-byte FIFO.
  - 0x400: LASI. Selects big-endian registers and the LASI minimum SDTR period.
- **Clock: 40 MHz** (`c720_init`@0x759CC-0x75A1C; 50 MHz only if flags & 0x200). `c720_cf(4)` = 0, so DCNTL.CF = 00 (SCLK/2), which matches Lasi_ers.txt:520.

## 2. Register access

- **Address computation.** `c720_Read/WriteByteReg`@0x1ECCF0/0x1ECDE8 use address = base + off. The offset is XORed with 3 only if (flags & 0x1C00) == 0, so there is **no XOR on LASI**.
- **32-bit access.** `c720_Read/Write4ByteReg`@0x1ECD78/0x1ECE68 swap bytes only in that same case, so there is **no swap on LASI**.
- **The chip must therefore be in BIG_LIT = 1 mode** (Lasi_ers.txt:524, 552, register table :562-587). The byte at BE offset *b* is LE register *b*^3. A 32-bit read at +0x100+4k returns the LE register value, with LE byte 0 in bits 7:0.

| Register (LE/BE) | Driver use |
|---|---|
| ISTAT 21/22 | R in `c720_isr`@0x100558 (ignored if SIP\|DIP == 0), `c720_timer` (CON). W 0x40, `busywait(100)`, then 0x00 (`reset_chip`@0x167D54). W 0x20 = SIGP (`c720_start`@0xFE758). W 0x00 (`isrDeactivate`, `chip_hang`). |
| DCNTL 3B/38 | W 0x01: CF = 00, COM = 1 (IDs go to LCRC only) |
| SCNTL0 00/03 | W 0xCC: full arbitration, EPC, EPG. The script clears START (`&0xDF`) |
| CTEST0 14/17 | W 0x50: BTD + EAN |
| DMODE 38/3B | W 0xC0: burst 8, MAN = 0, so a DSP write starts SCRIPTS |
| CTEST5 / CTEST8 | W 0 at reset. CTEST8 ← 0x04 CLF on STO and M/A. CTEST8 ← 0x08 FLF then 0 for the stall workaround |
| SCRATCH 34-37 | W 0xFF000000 at reset. Byte writes of the target/lun/tag index. SCRATCH2 bit 7 = "interrupt on disconnect". 32-bit read in the ISR |
| SBCL 0B/08 | W SSCF per target (0 at init, on every select/reselect). R for REQ/phase |
| SXFER 05/06 | W per-target byte on every select/reselect and after SDTR |
| SCID 04/07 | W 0x80 |
| SCNTL1 01/02 | W 0x20 ESR. Bus reset: 0x08 RST, then 0x00 after 63 µs |
| DIEN 39/3A | W 0x7F (0 when disabled) |
| SIEN 03/00 | W 0xAF: M/A, STO, SGE, UDC, RST, PAR (FCMP and SEL off) |
| SSTAT0 0D/0E | R only if SIP, then `busywait(1 µs)`, then DSTAT |
| DSTAT 0C/0F | R. **DFE must be valid** |
| DSPS 30 | 32-bit R |
| LCRC 23/20 | R: reselection ID bits |
| DFIFO, SSTAT1, SSTAT2, DBC/DCMD, DSP | R in `isrMA`@0x11D7B0 for the residual: `(DFIFO−DBC)&0x7F` + OLF/ORF. Escape if ILF is set, or if DFE is clear on input |
| SBDL 0A/09 | R: peek a pending MSG_IN byte |
| DCMD | byte R in `c720_timer` (stall test: DCMD == 0x09) |
| CTEST4, CTEST7, DWT, DSA | never written by the host (DWT = 0, watchdog off) |

**Timing:**
- Chip reset holds ISTAT.RST for 100 µs.
- SCSI bus reset holds RST for 63 µs.
- `busywait(n)`@0x131168 spins on CR16.
- Post-reset waits come from Ktimeout ticks.

**Synchronous negotiation:**
- The first message-out is `C0 01 03 01 32 08`: IDENTIFY with disconnect allowed, then **SDTR 200 ns / offset 8** (`c720_lasi_min_sdtr_period` = 0x32).
- No WDTR is sent.

## 3. SCRIPTS

**Where the script comes from:**
- The template is `c720_script`@0x3FF030 (0x4A0 bytes, written for the 720).
- `c720_init_script`@0x115D90 runs on every bus open. It:
  - copies the template;
  - relocates the 25 label patches;
  - applies the chip-specific patches;
  - builds a 256-entry jump table at script+0x800;
  - flushes it with `fdc`.
- Runtime patches go through `WriteLong`/`Write2Longs`/`WriteByteN`, each followed by `fdc`.
- At run time the script is at physical 0x01772000. Per-command data scripts live at 0x01773000+.

**Patched 710 flow:**
- **Idle (+0x0F8):** `MOVE 0 TO SCRATCH1`, then `WAIT RESELECT alt +0x01C`.
  - On reselection: +0x108 `INT 0xB` (wait for valid phase).
  - On SIGP: +0x01C `MEMORY MOVE 4`, then the select slot at +0x028.
- **Select slot (+0x028):** either a runtime `SELECT ATN <1<<tgt>, alt +0x288`, or `INT 0x0F` (bus close).
- **After selection:**
  1. `INT 0xA`
  2. `MOVE 6 WHEN MSG_OUT`
  3. `INT 6 IF WHEN MSG_IN`
  4. `MOVE n WHEN CMD`
  5. `MOVE CTEST2|0 TO SFBR`, which **clears SIGP**
  6. `INT 1`
- **Data phase:** `CALL +0x190 IF WHEN DATA_IN/OUT`. That builds TEMP0..3 from SCRATCH0/1 and does a `RETURN`, i.e. a computed jump into the jump table. The jump table leads to the per-command block-move list, which ends with a `MEMORY MOVE` and a JUMP back.
- Then STATUS/MSG_IN, `INT 0x10`, the disconnect path, and a phase dispatcher at +0x370.

**Instruction types the 710 actually executes:**
- Initiator block MOVE, direct addressing only.
- `SELECT ATN` with an absolute ID and an alternate address.
- `WAIT RESELECT` and `WAIT DISCONNECT`.
- `SET/CLEAR ATN`, `CLEAR ACK`.
- All three register read/write opcodes, on SCRATCH, TEMP, SFBR, SDID, SCNTL0, CTEST2 and CTEST7, including move-to/from SFBR with AND/OR.
- JUMP/CALL, absolute and relative.
- `RETURN` to TEMP, as rewritten by the register moves.
- INT with these conditions: always, `IF [NOT] WHEN phase`, data compare, and wait-for-valid-phase.
- NOP.
- **Memory-to-memory MOVE** of 4 and 16 bytes, RAM to RAM.

**Not used:**
- Table-indirect and indirect moves.
- Carry tests.
- LOAD/STORE. The leftover 720 STOREs at +0x070, +0x0E0 and +0x0E8 are unreachable.
- Interrupt-on-the-fly.

**INT code dispatch** (`isrGuts` jump table @0x100040, DSPS 1..0x10):

| DSPS | Handler |
|---|---|
| 1 | CmdSent |
| 2 | CmdComp |
| 3 | Sdp |
| 4 | Disc |
| 5 | PutMsgOut |
| 6 | MsgOutIn |
| 7 | GetMsgIn |
| 8 | ReselectId (LCRC) |
| 9 | MsgIn |
| 0xA | Select |
| 0xB | Reselected |
| 0xC | DataDone |
| 0xD | DiscDone |
| 0xE | UntaggedReselect |
| **0xF** | **BusClose** |
| 0x10 | CmdComp |

Anything else is "Unhandled script interrupt", which leads to a reset.

**SIGP rules:**
- The driver sets SIGP after queuing work and clears it by writing ISTAT = 0. The script clears it by reading CTEST2.
- **WAIT RESELECT must take its alternate address if SIGP is already set when it starts, or becomes set while it waits** (manual :3509-3511, :2718-2740).
- Reading CTEST2 clears ISTAT.SIGP (:2382-2388).
- The host writes SCRATCH1 while the script is sitting in WAIT RESELECT.

**Other QEMU deviations that will bite next:**
- LCRC is set only on selection, and a write stores the value instead of clearing (ncr53c710.c:929, 2193).
- DFIFO always reads 0 (:1900-1902), which breaks the `isrMA` residual.

## 4. Interrupts

- **Line.** LASI IRR/IPR **bit 9**. IMR becomes 0x204200 during `c720_init`. SC[1] interrupt-on-the-fly (IPR 21) and the snoop bit (19) are not used.
- **ISR read order:**
  1. ISTAT.
  2. If ABRT is set, write ISTAT with ABRT clear.
  3. If SIP: SSTAT0, wait 1 µs, then DSTAT. If only DIP: DSTAT.
  4. DSPS (32-bit), then SCRATCH (32-bit).
- **Dispatch on the exact cause combination:**
  - SIR+DFE → the DSPS table.
  - IID, M/A alone, UDC, PAR, RST → their own handlers.
  - STO or STO|UDC → isrSTO.
  - Anything else (SGE, BF, WTD, ABRT, or two causes at once) → "Unhandled interrupt" → reset.
- **So stacked interrupts must be delivered one cause at a time**, and IRQ must drop once SSTAT0 and DSTAT have been read.

## 5. DMA and memory

- The 715 is treated as non-coherent. Everything is `fdc` + `sync`:
  - script patches;
  - message, command and status buffers;
  - `fdc` before the CPU reads chip-written data;
  - data buffers.
- Partial cache lines are bounced. For example, a 0x80-byte INQUIRY became byte moves of 0x38 + 0x40 + 0x08 at three physical addresses. **The DMA engine must handle any byte count and alignment.**
- All addresses are 32-bit physical. DMODE asks for 8-transfer bursts.

## 6. Timeouts and robustness

- **`c720_timer`** runs every second.
  - CON = 1 with an expired request → "First party detected bus hang".
  - Otherwise, after 15 s of grace → "Third party detected bus hang".
  - It also contains a 710 erratum workaround, "Stalled Phase Mismatch": DCMD == 0x09, REQ set, phase not DATA_IN → set CTEST8.FLF and fake an M/A.
- **Selection timeout** is only the chip's STO, about 250 ms.
- Disconnect/reselect and simple queue tags (0x20 on reselection) are used.
- Escapes end in a chip reset, a bus reset and a requeue.

## 7. FPGA 53C710 requirements for HP-UX 10.20

**Must be exact:**
1. **Register map.** BE register map at HPA+0x100 (byte address = LE^3, 32-bit words native). A DSP write starts SCRIPTS (MAN = 0).
2. **DSTAT.DFE is live**: set whenever the DMA FIFO is empty, including on SIR and on M/A during input.
3. **Status and interrupts.** DSTAT and SSTAT0 clear on read. Interrupts are stacked and delivered one cause at a time. IRQ goes to LASI IPR bit 9.
4. **ISTAT.**
   - Writing 0 clears SIGP/ABRT/RST, but never SIP/DIP/CON.
   - RST is a level-held reset.
   - **SIGP aborts WAIT RESELECT to its alternate address**, whether set before or during the wait.
   - Reading CTEST2, from the host or from SCRIPTS, clears SIGP.
   - CON is accurate.
5. **LCRC.** With COM = 1 it is loaded with own|target ID bits on reselection and XOR-accumulates the bytes moved. A write clears it.
6. **CALL/RETURN.** CALL saves the next DSP in TEMP. Register moves may rewrite TEMP bytes, and RETURN jumps to the full TEMP.
7. **Register moves.** All register R/W opcodes and operators work on SCRATCH, TEMP, SFBR, SDID, SCNTL0 and CTEST2/7. SFBR receives message and status bytes.
8. **Phase and INT.** Wait-for-valid-phase; phase compare on the REQ-latched phase; INT with a 32-bit DSPS; the NOP encoding.
9. **Bus operations.** SELECT ATN with the ID mask, 250 ms STO and the reselect alternate; WAIT DISCONNECT; SET/CLEAR ATN/ACK.
10. **Phase-mismatch state** consistent with the residual formula: DBC, `(DFIFO−DBC)&0x7F`, SSTAT1 OLF/ORF, ILF = 0, SSTAT2. SBDL and SBCL must reflect the live bus.
11. **Memory-to-memory move** between RAM addresses of the same alignment.
12. **SSTAT0.RST** fires once per RST edge, including our own.

**Can approximate:**
- Timing (TP/SSCF, active negation, EAN/BTD), as long as async and sync at 200 ns / offset 8 both work.
- Burst sizes.
- DWT, single-step, low-level mode, target mode, table-indirect, carry, the adder, CTEST4/5/6, snoop pins, FLF (only used by the stall workaround).
- DSA/TEMP clobbering by memory moves.
- Revision nibble (return 0x20).
- The LASI "SCSI Reset" register at +0x000.

## 8. Linux, for comparison

From the Linux review:
- `lasi700.c` puts the core at HPA+0x100 and assumes 40 MHz, BE registers and burst 8.
- `53c700.c` init writes SCNTL0 0xCE, DMODE 0xE0, DCNTL 0x01, SIEN 0xBF, DIEN 0x15, SCID 0x80.
- It uses WAIT RESELECT but not SIGP, memory-move, register R/M/W, DSA or SCRATCH.

So HP-UX is the stricter client: an FPGA 53C710 that satisfies §7 also covers Linux.
