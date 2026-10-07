# The 715 boot ROM (PDC 1.6) -- analysis index

HP's boot ROM for the 715/64/80/100 and 725/100, revision 1.6
(`roms/hp715_pdc_rev1.6.bin`, 258,728 bytes at 0xF0000000; where it comes
from: `roms/README.md`). Three documents, written 2026-10-07 from the
disassembly, the PCX-L / PCX-L2 / LASI ERSs and the PDC specs; read them in
full before building anything the ROM depends on:

| document | covers |
|---|---|
| [BOOTFLOW.md](BOOTFLOW.md) | entry points and vector tables, the reset and boot flow step by step, chassis/LED codes, **all 38 power-on self-tests** (what each exercises, exact pass/fail values, chip internals used), timing, the early-failure list for the FPGA |
| [HARDWARE.md](HARDWARE.md) | every register the ROM touches: the **MIOC** memory controller (reconstructed -- no HP doc), CPU HPA, broadcast space, LASI and its units, the 8-bit external bus (ROM, EEPROM, LED, board ID), WAX/EISA/graphics, addresses that must bus-error, diagnose and control registers, a 23-item read-back checklist, what is still unknown |
| [FIRMWARE.md](FIRMWARE.md) | the ROM as firmware: layout map, PDC entry and procedure table, the IODC directory and modules (incl. 53C710 SCRIPTS), the STI image and font, stable storage in the EEPROM, the update tape |

What the OS does with all of this is in `docs/review/06*.md`.

## Layout at a glance

| address | contents |
|---|---|
| F0000000 | `b,l,n F00026B0` -- HPMC and TOC entry |
| F0000004 | reset vector |
| F0000008 | firmware revision word 0x16 |
| F0002000 | interruption vector table (all vectors halt with chassis code 0x21000+n) |
| F0004000-F000F16B | CPU/cache/TLB/FP/memory self-tests |
| F0011B40-F001551F | PDC (assembler); **PDCE_PROC = F0012870**, jump table F00128AC |
| F0016468-F0020333 | Boot Console Handler and boot code (C, data via dp = 0xF0024000) |
| F0020858-F00233EB | strings and the BOOT_ADMIN keyword table |
| F0024000-F00287E5 | STI image for the built-in Artist graphics (13 monitor records, 8x16 font, CRC) |
| F0028800-F003F2A7 | IODC directory and modules (RS-232, graphics, SCSI 53C710, LAN, PS/2, HIL, FW-SCSI) |

Other F-space the firmware relies on: **EEPROM 8 KB at F00C0000** (stable
storage, model identity, MAC addresses, PIM), **LED latch F00EFFFF**
(active low), **board-ID word F00FFFFC** (bits 7:4: 7 = 715/64, B = 715/80,
F = 715/100, E = 725/100), MIOC at FFFBF000, CPU HPA at FFFBE000, broadcast at
FFFC0000.

## What the ROM demands of the FPGA (the headline items)

Each is argued with addresses in the three documents.

- **CPU:** report revision 0 in DR0 (single-issue path, skips the
  cycle-exact dual-issue test); PCX-L diagnose instructions (MTCPU/MFCPU,
  cache data/tag read/write, SET_TAG, shadow registers, TOC enable);
  **128 KB I + 128 KB D off-chip caches, direct-mapped, 32-byte lines,
  diagnose-accessible** -- the ROM loads code into the I-cache with
  diagnose writes and runs it at address 0 with no RAM behind it; delayed
  FP traps; the two branch-on-bit encodings objdump cannot decode;
  8 block-TLB slots (via DR8) and the **hardware TLB-miss walker** (DR24/25),
  which PDC_TLB programs and HP-UX then depends on.
- **Memory (MIOC):** PA7300LC-like register layout; 16 compare/mask blocks
  of at most 128 MB with wrap-around aliasing; ECC behaviour the self-tests
  check (`tools/rom/hwmap_ecc.py`); unconfigured accesses -> HPMC with status
  0x02.
- **Bus errors:** reads of absent devices must HPMC (DR0 bit 18 marks it
  expected) -- the probes depend on it; certain stores (WAX, LASI+0xB000,
  broadcast) must not fault.
- **LASI:** IAR powers up 0xFFFBE003; PS/2 loopback 4 deep and raising EIRR
  bit 3 (else a silent halt); 16550 with FIFO (IIR 0xC1); a ticking RTC.
- **EEPROM:** byte-writable with read-back; a blank one boots into
  manufacturing mode, so ship a prepared image and save it to the SD card.
- **CR16** counts at exactly the board's clock (MEM_10MSEC = 640000 at 64 MHz).

## Tools

| tool | what |
|---|---|
| `tools/rom/annotate.py` | annotated listing + hwaccess/diag/ctl/strings/calls tables -> `roms/disasm/` |
| `tools/rom/romlib.py` | objdump parsing, ldil/ldo constant tracking, device names, diagnose decode, dp = 0xF0024000, symbol loading |
| `tools/rom/symbols/*.sym` | function names (bootflow, firmware, hwmap, reset) -- `ADDR NAME # comment` |
| `tools/rom/firmware_map.py` | region map + IODC/STI/PDC/EEPROM parsers; `firmware_map.py check` verifies every checksum |
| `tools/rom/firmware_calls.py` | PDC and EEPROM call sites |
| `tools/rom/bootflow_chassis.py` | every chassis-code call site and code |
| `tools/rom/hwmap_trace.py`, `hwmap_ecc.py` | function-wide constant tracing; an ECC code satisfying the ROM's checks |

```bash
python3 tools/rom/annotate.py                  # -> roms/disasm/rom.dis etc.
python3 tools/rom/firmware_map.py check
```
