# Firmware review: PDC, IODC and STI for the 715/64-100

What a boot ROM (real HP or a SeaBIOS-hppa derivative) must provide for HP-UX
10.20 and Linux, from the PDC 1.1 / 2.0 specs, Linux and SeaBIOS-hppa.

The PDC 1.1 set we have lacks Ch2 (PDC entry points) and Appendix C (Page
Zero); the PDC 2.0 v0.36 equivalents stand in for them.

**Short names** (docs in `docs/reference/txt/`):

- **Ch1** = `Pdc11-v0.96-Ch1-procs.txt` ("PA-RISC 1.1 Firmware Architecture
  Reference Specification" v0.96, 1999-03-08, chapter 1 "PDC Procedures").
- **Ch3** = `Pdc11-v0.96-Ch3-IODC.txt` ("PA-RISC 1.1 I/O Firmware
  Architecture" v0.96, 1999-03-07).
- **E** = `Pdc20-v0.36-Ch1-entry.txt`, **C** = `Pdc20-v0.36-ChC-datafmt.txt`,
  **OS** = `pdc20-v0.36-Ch4-OS.txt`.
- **L** = `/home/dani/repos/Linux-Kernel_MiSTer`.
- **S** = `/home/dani/src/qemu-11.1.1/roms/seabios-hppa/src/parisc`.

## Calling convention (PDC 1.1)

- One entry point, PDCE_PROC, whose address is Page Zero MEM_PDC (Ch1:44-49).
- Called at PL0, PSW Q=1, C/D/I and trap enables 0 -- real mode, interrupts
  off (Ch1:86-140). Linux uses `real32_call` (L `arch/parisc/kernel/firmware.c`).
- GR26-23 = ARG0-3, ARG4+ on the stack from SP-52 down; GR28 = status;
  GR30 = SP; 7 KB above SP is scratch (Ch1:226-300).
- ARG0 = procedure index, ARG1 = option, ARG2 = R_addr, a 32-word return
  buffer (Ch1:302-325).
- Status: 3 warning, 0 OK, -1 no such procedure, -2 no such option,
  -3 error, -10 invalid argument, -12 powerfail (Ch1:339-360).
- Index table: Ch1:440-476.

## (a) PDC procedures

A = required by the architecture, HV = processor-dependent.

| Idx | Name | Options | 1.1 | Linux on a 715 (32-bit "Snake" path) | HP-UX 10.20 | Cite |
|---|---|---|---|---|---|---|
| 1 | PDC_POW_FAIL | 0 | HV | not called | stub | Ch1:3025 |
| 2 | PDC_CHASSIS | 0 display, 1 warn, 2 both | A | optional (`pdc_chassis.c`) | likely (LED codes) | Ch1:1248 |
| 3 | PDC_PIM | 0 HPMC, 1 size, 4 TOC; 2 LPMC opt; 3 cat-B only | A | HPMC/TOC paths only | OS_HPMC/OS_TOC call 0/4 (OS:175-200) | Ch1:2256 |
| 4 | PDC_MODEL | 0 info, 3 sysmodel; 1,2 opt; 6 CPU_ID; 7 caps | A | **required**: option 0, bus_id must be 0xC (`inventory.c`) | 0 and 3; CPU_ID **must fail** on Snake (S `parisc.c:1694`) | Ch1:1772 |
| 5 | PDC_CACHE | 0 info, 1 coherence, 2 space-ID bits | A | **required** option 0 (panics otherwise, `cache.c`); option 2 returns 0 bits or -2 | yes | Ch1:731 |
| 6 | PDC_HPA | 0 processor HPA | A | not called | likely | Ch1:1454 |
| 7 | PDC_COPROC | 0 | A | **required** (panics with no FPU, `setup.c`) | OS_BOOT must call it (OS:140) | Ch1:1344 |
| 8 | PDC_IODC | 0 entry/header; 2, 4 for proc-dependent memory; 5 interleave | A | **required** option 0 / index 0 for every device (`drivers.c`) | yes; 715 memory is proc-dependent (SVERSION 9) so option 4 likely | Ch1:1562 |
| 9 | PDC_TOD | 0 read, 1 set, 2 calibrate | A | read, set (`time.c`) | yes | Ch1:3521 |
| 10 | PDC_STABLE | 0-4 | A | writes OS_ID at 0x40, failure ignored | yes: boot/console/kbd paths, OS_ID=1, fast-size | Ch1:3127, layout 3257-3430 |
| 11 | PDC_NVOLATILE | 0-4 | HV | no | optional | Ch1:2086 |
| 12 | PDC_ADD_VALID | 0 | A | `sticore.c`, `lasi.c`, `parport_gsc.c` | yes | Ch1:485 |
| 14 | PDC_DEBUG | 0 | HV | no | no | Ch1:1401 |
| 15 | PDC_INSTR | 0 | HV | optional (`traps.c`) | maybe | Ch1:1506 |
| 18 | PDC_BLOCK_TLB | 0 info, 1 insert, 2 purge, 3 purge all | HV, needed with a BTLB -- PCX-L has 8 entries (`PCXL_ers.txt:1902,1983`) | info only, optional | likely | Ch1:567 |
| 19 | PDC_TLB | 0 params, 1 setup | HV, needed with a HW miss handler -- PCX-L has one (`PCXL_ers.txt:1773`, DR24 :755) | no | used if present; -1 falls back | Ch1:3434 |
| 21 | PDC_PSW | 0 mask, 1 get, 2 set | page exists, not in 1.1 index | no | probably not | Ch1:3071 |
| 22 | PDC_SYSTEM_MAP | -- | PDC 2.0 only | **must return non-OK** or Linux takes the System-Map path | n/a | `Pdc20-v1.1-Ch4-pdc.txt:4382` |
| 128 | PDC_MEM_MAP | 0 HPA from path | HV; not in our docs | **required**: Linux finds devices this way on Snake (`inventory.c`, `firmware.c`) | likely ("S700 mechanism") | -- |
| 136 | PDC_BROADCAST_RESET | 0 | HV | optional; falls back to CMD_RESET broadcast | -- | -- |
| 138 | PDC_LAN_STATION_ID | 0 | HV | optional; falls back to EEPROM at 0xF0810000 (`lasi_82596.c`) | likely | -- |

## (b) IODC entry points (Ch3 Table 3-2, Ch3:837-854)

| Idx | Name | Options | Notes | Cite |
|---|---|---|---|---|
| 0 | 16-byte header | -- | returned by PDC_IODC ARG1=0, ARG4=0 | Ch1:1626-1640 |
| 3 | ENTRY_INIT | 2/3 search first/next; 4 init module+device, 5 device, 6 module (4-6 required); 9 message | boot and console modules; 16 KB max | Ch3:1129-1170 |
| 4 | ENTRY_IO | 0 boot in; 1 boot out; 2 console in / 3 console out; 4 close; 9 message; 16/17 block in/out | Linux uses 3 and 2; ISL/boot loader use 0 or 16 (inferred) | Ch3:1638-1685 |
| 5 | ENTRY_SPA | 0 | only for multi-SPA or non-power-of-2 SPA | Ch3:2458 |
| 6 | ENTRY_CONFIG | 0,1,2 | SVERSION-dependent | Ch3:855 |
| 8 | ENTRY_TEST | 0,1 required; 2,9 opt | bus converters | Ch3:2553 |
| 9 | ENTRY_TLB | 0 | translating bus converters only; not relevant | Ch3:3210 |

**Header layout** (Ch3:64-83, fields Ch3:218-410): bytes 0-1 HVERSION;
2 SPA; 3 TYPE (0 native proc, 1 memory, 10 FIO, 11 BA); 4-7 SVERSION; 8 REV;
9 DEP; 10 FEATURES (bit 7 block I/O); 12-13 CHECK (16-bit sum to 0);
14-15 LENGTH. Each entry word = index(8) + word address(24) pointing at
{CHECK, LENGTH, position-independent code} (Ch3:424-460).

**Rules:** IODC uses the PDC convention with ARG0=HPA, ARG1=option,
ARG2=SPA, ARG3=ID_addr, ARG4=R_addr (Ch3:461-560); real mode only (Ch3:674);
MEM_PDC and MEM_10MSEC valid before any call (Ch3:713-717). Classes:
CL_RANDOM 1, CL_SEQU 2, CL_DUPLEX 7, CL_KEYBD 8, CL_DISPL 9. Fixed-config
systems may emulate IODC inside PDC (Ch3:47-53).

**HPA registers** (`pdc20-v1.1-Ch2-overview.txt:1100-1132`): IO_DC_ADDRESS/DATA
+0x8 (optional when hard-wired), IO_COMMAND +0x30, IO_STATUS +0x34, IO_FLEX
at local broadcast +0x20. PCXL ERS has no processor-HPA chapter; the nearest
is PA7300LC (`Pcxl2_ers.txt:6576-6595`).

## Page Zero (C:100-171; Linux `uapi/asm/pdc.h`)

| Offset | Contents |
|---|---|
| 0x000 | vectors: 0, MEM_POW_FAIL, MEM_TOC, TOC_LEN, MEM_RENDEZ, PF_LEN |
| 0x040 | processor-dependent |
| 0x350/354/358 | MEM_CONT / PHSIZE / ADSIZE |
| 0x35C | MEM_PDC high |
| 0x360 | MEM_ERR[8] |
| 0x380 | MEM_FREE |
| 0x384 | MEM_HPA |
| 0x388 | MEM_PDC |
| 0x38C | MEM_10MSEC |
| 0x390 | initial memory module: hpa, soft_boot, spa_size, max_mem |
| 0x3A0/0x3D0/0x400 | MEM_CONS / MEM_BOOT / MEM_KBD (48 B each: path, layers, HPA, SPA, IODC_IO, CLASS) |
| 0x604 | pointer to the STI image (`Sti.txt:1178-1186`) |

On Snake, Linux takes memory size only from `imm_max_mem` and CPU speed from
`mem_10msec`.

## PDC 2.0 vs 1.1, and the OS handoff

PDC 2.0 adds PDC_PROC(16), CONFIG(17), MEM(20), SYSTEM_MAP(22),
SOFT_POWER(23), ALLOC(24), CRASH_PREP(25), SCSI_PARMS(26), ACPI(27) and wide
64-bit calls. None apply to the 715. PDCE_RESET/CHECK/TOC apply conceptually.

Handoff to the OS (E:1254-1376): PL0, Q=1, all else 0; caches clean; TLB
invalid; HW miss handling off; initial memory at SPA 0, tested; Page Zero
filled; console/keyboard/boot ENTRY_IO loaded with connections open.
GR26 = interactive flag, GR25 = end of IPL; ISL -> OS passes GR26 = PDCE_PROC,
GR25 = boot command, GR24 = entry. IPL format: LIF magic 0x8000,
IPL_ADDR/SIZE/ENTRY at 0xF0/0xF4/0xF8, checksum 0, max 256 KB (E:2480-2550).
On HP-UX the IPL is ISL. OS_BOOT calls PDC_COPROC and PDC_PIM(3); the 715 is
category A (SVERSION opt 0x81), so PIM(3) returns -2.

## (c) Version numbers (`Ver_nums.txt` Table B-1)

| Component | TYPE | SVERSION | HVERSION (715/64 / 100 / 80 / 100XC) |
|---|---|---|---|
| CPU (Mirage) | NPROC | 00004 opt 81 | 60A / 60B / 619 / 60C |
| Memory (proc-dependent) | MEMORY | 00009 | 04A / 04B / 04F / 04C |
| LASI core BA | BA | 00081 | 028 / 029 / 02B / 02C |
| LASI SCSI / LAN / RS-232 | FIO | 00082 / 0008A / 0008C | 028... |
| LASI parallel / floppy / PS/2 | FIO | 00074 / 00083 / 00084 | 028... |
| Harmony audio | FIO | 0007B | 028... |
| Artist | FIO | 00085 | 012 / 013 / 010 / 011 |
| WAX BA / WAX EISA BA | BA | 0008E / 00090 | 012... / 028... |
| WAX HIL / WAX RS-232 | FIO | 00073 / 0008C | 012... |

PCX-L CPU ID model 0xD, FPU model 0xD (Ver_nums:1604,1655). GSC bus ID 12 =
top 5 bits of 0x60A; Linux checks this exactly.

`S/715_64.h:8-49` is a dump from a real 715/64: Artist 0xf8000000, LASI
0xf0100000, WAX 0xf0200000, EISA 0xfc000000, CPU 0xfffbe000, memory
0xfffbf000; PDC_MODEL HVERSION 0x60a0, SVERSION 0x481; CPUID unsupported;
capabilities 2; PDC entry 0xf0012870 (runs from ROM).

## (d) STI ROM

- Built-in Artist has no physical STI ROM; the STI image sits in the system
  boot ROM and Page Zero 0x604 points at it (`Sti.txt:790-800, 1178-1186`).
  Linux tries `addr[0]`, the HPA, then `PAGE0->proc_sti`, after
  PDC_ADD_VALID -- so ADD_VALID must accept the ROM address.
- Byte mode (low byte of each word valid, first byte 0x01) vs word mode
  (0x0303). In our own ROM use word mode, as SeaBIOS does.
- Header: type, monitor count, revision, **graphics_id 0x2B4DED6D (Artist)**,
  font_start, state size, last_addr (CRC at the end), region_list, timeouts,
  monitor table, user data, sti_mem_req, bus support, alt_code_type, then
  pointers to INIT_GRAPH, STATE_MGMT, FONT_UNPMV, BLOCK_MOVE, SELF_TEST,
  EXCEP_HDLR, INQ_CONF, SET_CM_ENTRY, DMA_CTRL, FLOW_CTRL, USER_TIMING,
  PROCESS_MGR, STI_UTIL, END. Unused = 0 (`Sti.txt:707-713, 1195-1590`).
- Region list: up to 8; 0 = ROM, 1 = framebuffer, 2 = control
  (`Sti.txt:1691-1760`; SeaBIOS Artist regions `stirom.c:41-46`).
- Routines are C-callable (flags, in, out, glob_cfg) and touch hardware only
  through `glob_cfg->region_ptrs`. Boot ROM uses init_graph, self_test,
  inq_conf, block_move, font_unpmv, set_cm_entry; HP-UX uses every routine
  but self_test and copies them in a fixed order, so order in the image
  matters (`S/stirom.c:28-31`).
- Artist registers the STI code drives (relative to region 2): VRAM_IDX
  0x4a0, BITMASK 0x5a0, FG/BG 0x18010/0x18014, BITMAP_OP 0x1801c, CMAP
  0x18000, fill/blockmove triggers 0xa04/0xb00 (`stirom.c:7-23`). SeaBIOS
  init_graph also reads ctrl+0x111110, which exists only in QEMU
  (`hw/display/artist.c:1165`) -- implement it or hard-code 1280x1024.

## (e) SeaBIOS-hppa as the base

Usable. LGPLv3 (`pdc.h` GPL-2.0 WITH Linux-syscall-note; `stirom.c` has no
header). It has a 715 machine definition (`parisc.c:413-417, 3893-3906`),
PDC_MEM_MAP, PDC_SYSTEM_MAP -1 on Snake, CPU_ID -2, PDC_TOD on the LASI RTC
(+0x9000, matches `Lasi_ers.txt:3133-3152`), stable storage with fast-size
0xF, IODC ENTRY_INIT/IO with the NCR710 driver and the Artist STI image.

**QEMU dependencies to replace for real hardware:**

1. The "SeaBIOS" marker in Page Zero (`parisc.c:4018-4022`): Linux then sets
   `running_on_qemu` and flushes the TLB with a single `pdtlbe` -- wrong on
   real hardware.
2. fw_cfg (`parisc.c:3820-3990`) and the hard-coded RAM size; no real memory
   controller init, no PDCE_RESET.
3. Block TLB via QEMU-only `diag 0x100` (`parisc.c:2074-2093`); rewrite with
   PCX-L diagnose registers (`PCXL_ers.txt:1983-2000`).
4. `diag 0x101` console output (`hppa.h:226`) and the `0xfffdead2`
   shadow-register opcode in the TOC handler (`head.S:420`).
5. CPU HPA in cr7, default PSW in cr6 (`head.S:210-214`).
6. CPU_HPA 0xfffb0000 / MEMORY_HPA 0xfffff000 are QEMU's; real are 0xfffbe000
   / 0xfffbf000.
7. CPU_CLOCK_MHZ fixed at 250; MEM_10MSEC must match the real clock.
8. PDC_LAN_STATION_ID uses a QEMU magic write (`parisc.c:2349-2366`).
9. Device probes use QEMU magic values (`parisc.c:887-893`).
10. Stable storage is RAM-only; back it with LASI flash
    (`Lasi_ers.txt:3505-3560`) or a MiSTer-saved NVRAM file.

## What HP-UX 10.20 calls (inferred, not documented)

ENTRY_IO via Page Zero for ISL and the boot loader; PDC_STABLE (paths, OS_ID,
fast-size); PDC_MODEL info (SW_ID for licensing) and sysmodel ("9000/715");
CPU_ID failing; PDC_CACHE, COPROC, PIM, TOD, CHASSIS; PDC_BLOCK_TLB (likely),
PDC_TLB optional; PDC_MEM_MAP and PDC_IODC for discovery; the STI image via
Page Zero 0x604.
