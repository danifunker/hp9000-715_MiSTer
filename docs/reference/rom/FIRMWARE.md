# HP 9000/715 boot ROM, PDC revision 1.6: the ROM as firmware

What the 715/64/80/100 boot ROM contains and how its firmware interfaces work:
the layout, PDC, IODC, the STI image and fonts, and stable storage in the EEPROM.
Everything here comes from reading `roms/hp715_pdc_rev1.6.bin`, mapped at
0xF0000000. It is cross-checked against the PDC/IODC/STI specifications in
`docs/reference/txt/` and against a real 715/64's PDC answers
(`~/src/qemu-11.1.1/roms/seabios-hppa/src/parisc/715_64.h`, "715_64.h" below).

Companion documents:
- [BOOTFLOW.md](BOOTFLOW.md) covers reset, self-tests, the Boot Console Handler
  (BCH) and chassis codes.
- The hardware-register agent's notes cover the MIOC, LASI and Artist
  registers.

Bit numbers are LSB = 0 unless written as a mask. objdump prints PA (MSB = 0) positions, so convert before reading them here.

Labels below follow the confidence scale used elsewhere in the project:
**(fact)** means read directly from the code or data. **(inference)** means
the interpretation is likely but not proven. **(?)** means open.

## 0. Tools and reproducing this

| Tool | Purpose |
|---|---|
| `tools/rom/firmware_map.py` | Importable region map (`REGIONS`, `region_at()`, `is_code()`, `EEPROM_MAP`, `PDC_PROCS`) and parsers (`parse_iodc()`, `parse_sti()`). |
| `firmware_map.py [ROM] regions [--tsv F]` | Region table; the TSV copy is `roms/disasm/firmware/regions.tsv`. |
| `firmware_map.py iodc \| sti \| eeprom` | Directory and module headers with checksum checks; STI header, regions, monitors and font; EEPROM byte map. |
| `firmware_map.py pdc \| memmap` | Re-derive the PDC dispatch table and the PDC_MEM_MAP path→HPA table from the code. These need objdump. |
| `firmware_map.py check` | Verifies every IODC checksum, the STI CRC, the image word-sum and that the region table has no gaps. Passes on rev 1.6. |
| `tools/rom/firmware_calls.py pdc\|eeprom` | Every PDC call site with proc/option/ARG constants (86 sites), and every EEPROM accessor call with its offset. |
| `tools/rom/symbols/firmware.sym` | About 115 names: PDC procedures and helpers, stable storage, IODC and STI entry points. Addresses that `bootflow.sym` already names are left to it. |
| `roms/disasm/firmware/` | `annotate.py` output with all names loaded. |

**Other tools can use the region map.** `import firmware_map;
firmware_map.is_code(a)` tells code from data. It covers fonts, tables,
SCRIPTS, keymaps, IODC headers and the STI data that objdump disassembles as
junk instructions. For example, `annotate.py` could skip or print
non-code regions as data.

## 1. ROM layout map

The image is 258,728 bytes (0xF0000000–0xF003F2A7) in a 256 KB flash. The
region boundaries are exact: each was checked against code boundaries,
checksums or the zero fill. (fact)

| Range | Size | Kind | Contents |
|---|---:|---|---|
| F0000000–F000000F | 16 | header | +0 `b,l,n 0xF00026B0`: HPMC/TOC path, see BOOTFLOW. +4 reset vector, branches to 0xF0000010. **+8 = 0x00000016 = firmware revision "1.6"**: the high nibble is the major, the low nibble the minor; PDC_MODEL VERSIONS id 1 also returns 0x16. +C = 0. |
| F0000010–F0001CBF | 7.2 K | asm | reset entry, `early_init` (EEPROM first-boot defaults at 0xF0000338), `page0_init` 0xF0000B70, `boot_select` 0xF0000C34. See BOOTFLOW. |
| F0001CC0–F0001FFF | | zero | |
| F0002000–F00023FF | 1 K | IVA | main interruption vector table (CR14). |
| F0002400–F0003FFF | 7 K | asm/C | interruption handlers, HPMC/TOC code, early C. |
| F0004000–F0008907, F0009020–F000F16B | 42 K | asm | self-tests (CPU, cache, TLB, memory, FP), plus the PIM writer that saves registers into the EEPROM (0xF0004410…). The zero gap at F0008908–F000901F is padding. |
| F000F16C–F00116D3 | 9.6 K | C | device self-tests. |
| F00116D4–F00117FF | | zero | |
| **F0011800–F0011B3F** | 0x340 | IVA | **PDC probe IVA.** PDC_ADD_VALID and PDC_COPROC install it while they touch a possibly absent address or FPU. Vector 1 (HPMC) goes to 0xF0011B40, which reads MEM_HPA+0x84 and returns −1/−3. Vectors 14 and 22 skip the faulting instruction and set ret0 = −1. |
| **F0011B40–F001551F** | 14.8 K | asm | **PDC procedures.** PDCE_PROC is at **0xF0012870**, the jump table at 0xF00128AC, and the dispatcher for procedures ≥ 24 at 0xF0012978. |
| F0015520–F0016467 | 3.8 K | asm | PDC support routines. Register save/restore (0xF0015520/0xF0015600), EEPROM byte/word access (0xF0013208…0xF001335C are in the previous region), delay, `board_model` 0xF00158A8, `get_cpu_speed` 0xF0015E24, UART init and putc (0xF0015A98/0xF0015B78), cache flush, `load_rom_dp` 0xF00163DC. |
| F0016468–F0020333 | 40 K | C | BCH and boot code. It addresses its data through dp = 0xF0024000. |
| F0020334–F0020853 | 1.3 K | millicode | `$$divU`, `$$divI`, `$$mulI`, … |
| F0020858–F00233EB | 11.1 K | data | BCH strings, the command keyword table (0xF00231BC…), messages. All are dp-relative. |
| F00233EC–F0023FFF | 3 K | zero | |
| **F0024000–F00287E5** | 18.4 K | STI | **STI image** (§4). Header F0024000; monitor table F00242C0; 13 per-monitor timing records F0024328–F0024807; routines F0024808–F00277BF; region list F00277C0; **8×16 font** F00277D4–F00287E3; CRC F00287E4. |
| F00287E6–F00287FF | | zero | |
| **F0028800–F00288F7** | 0xF8 | IODC dir | 30 × {HPA, offset} + {0, 0}. The offset is relative to 0xF0028800 (§3). |
| F00288F8–F003F2A7 | 92 K | IODC | IODC headers and modules (§3). The image ends exactly at the end of the last module. |
| **F003F2A8–F003FFFF** | 3,416 | — | **Not in the image.** No ROM code refers to it (fact). It is erased flash on real hardware. **Stable storage is not here:** it lives in a separate EEPROM (§5). |

Inside IODC modules (data that disassembles as junk):

| Range | Contents |
|---|---|
| F002ED7C, F0030A90, F003CA28, F003E6BC | `"QUANTUM LPS525S"`, a disk-quirk entry, one copy in each SCSI driver block. |
| F002ED90–F002EED7 / F0030AA4–F0030BEB | 53C710 SCRIPTS in the SCSI ENTRY_INIT and ENTRY_IO blocks, each followed by a patch-offset table up to F002EF3C / F0030C53 and 68 zero bytes. |
| F003CA3C–F003CB77 / F003E6D0–F003E80B | FW-SCSI SCRIPTS (53C720-class, uses `7c027f00`), with tables up to F003CBCF / F003E863. |
| F00390E0–F00392F3 | PS/2 scan-code set 2 → ASCII tables, plain and shifted, two copies. |
| F0039E30–F0039F03 | HIL key → ASCII tables, plain and shifted. |

**Checksums in and around the image** (fact, all verified by `firmware_map.py check`):

- **IODC.** Each header plus its entry table sums to 0 as 16-bit halfwords
  (`CHECK`). Each entry-point block sums to 0 over {check, length,
  4·length bytes}.
- **STI.** The Sti.txt §7.3 CRC over bytes 0..`last_addr` (0x47E5) is 0. The
  CRC bytes are 0xFF10 at +0x47E4.
- **Whole image.** There is no internal checksum word. The firmware tape's
  `IMAGE1A` header holds the 64-bit additive word sum of the image:
  0x5790_A8BB80FC, high word at header 0x3C and low word at 0x40.
  - Header 0x28 and 0x48 = the length, 0x2C = 1, 0x38 = 2.
  - The UPDATE program prints this as "64-bit additive checksum of %s".

**Other F-space the firmware uses** (all on LASI's 8-bit external bus unless
noted):

| Address | Use |
|---|---|
| **F00C0000–F00C1FFF** | **EEPROM, 8 KB** (§5). PDC_EEPROM limits offsets to < 0x2000. |
| F00EFFFF | LED latch. PDC_CHASSIS writes `~(code>>12)` here (0xF00122F0). |
| F00FFFFC | **Board-ID word.** Bits 7..4: 0x7 = 715/64, 0xB = 715/80, 0xF = 715/100, 0xE = 725/100. Anything else gives "Unrecognized system ID. Bad! Bad! Bad!". `get_cpu_speed` and `board_model` decode it, and so does every IODC module that needs the CPU MHz. |
| F041FFFF, F04xxxxx | The second LASI / personality-card bus. PDC_IODC tests bit 0 of F041FFFF. The factory "Dagger" card answers at F0400000 (§6). |

## 2. PDC

### 2.1 Entry and dispatch (fact)

- **PDCE_PROC = 0xF0012870**, in the ROM, matching 715_64.h's "PDC entry
  0xf0012870".
  - `page0_init` writes it to Page Zero **MEM_PDC (0x388)** at 0xF0000B98:
    `ldil L%0xF0012800; addi 0x70`.
  - **PDC runs from ROM.** It is never copied to RAM.
- The entry sequence:
  1. Return −10 if `sp & 7`.
  2. `stw rp,4(sp)`, then `pdc_save_regs` (0xF0015520). This saves r3–r26,
     dp, ret1, r31, CCR, SAR, IVA, EIEM, IPSW, TR0–TR7 and the PSW system
     mask into the caller's frame at sp+8…sp+0xA8.
  3. `sp += 0x100`.
- **Dispatch.**
  - If ARG0 (r26) < 24, unsigned, the code does `blr r26` into the 24-entry
    jump table at 0xF00128AC (8 bytes per entry).
  - Otherwise `pdc_dispatch_hv` (0xF0012978) compares r26 against 128, 137,
    129, 136, 138 and 130.
  - Every exit goes through 0xF0015510: restore registers, `sp −= 0x100`,
    return.
  - Stack arguments ARG4… are read as −0x34(sp−0x100)…
- **Scratch.**
  - PDC uses only the caller's stack: the 0x100-byte frame plus pushes.
  - It keeps **no private RAM** apart from two Page Zero locations: **0xE4**
    is the shadow of DR25 that PDC_TLB writes, and **0x1A0–0x1AC** holds the
    LPMC PIM, written by the LPMC path.
  - Everything persistent is in the EEPROM.
- Procedures that probe or touch the CPU swap CR14 (IVA) to the probe IVA.
  They use PCX-L diagnose registers DR0, DR8, DR24 and DR25.

### 2.2 Procedure table

Handler = first instruction. "−1"/"−2" = PDC_BAD_PROC/PDC_BAD_OPTION.

| # | Name | Handler | Options | What it does | HW / table |
|---|---|---|---|---|---|
| 1 | POW_FAIL | — | | −1 | |
| 2 | CHASSIS | F00122B8 | 0, 0x200 | `chassis_code` (0xF00122E0): LED latch F00EFFFF ← ~code\[19:12\]. If EE 0x1694 ∈ {B0, B1} it also prints "0xNNNN" on the LASI UART. Option 0 first clears ARG2 bits 23..16; option 0x200 displays the value raw. Warnings (option 1) → −2. | HW |
| 3 | PIM | F0014EE0 | 0 HPMC, 1 size, 2 LPMC, 4 TOC; 3 → −2 | HPMC PIM from EE 0x1400 (0x164 bytes, at most 0x158 returned), counters EE 0x16A4/0x16A8. TOC PIM from EE 0x1564 (0x130 bytes), counters 0x16AC/0x16B0. LPMC from Page Zero 0x1A0 after a MIOC check (MEM_HPA+0x84). Size returns 0x164/0x158. | EEPROM |
| 4 | MODEL | F0014D00 | 0 info, 2 versions, 3 sysmodel, 4/5 enable/disable spec (key must be 0x72, else −20); 1, 6 (CPU_ID), 7 → −2 | **info** = 36 bytes from the EEPROM HV area (EE 0x1200), then hw_id = boot_id = 0, arch_rev = 4, pot_key = curr_key = 0x72. This matches 715_64.h exactly: 0x60a0, 0x481, 0, 0, sw_id, 0, 4, 0x72, 0x72. **versions** id 0 = DR0 >> 26 (the top 6 bits; 715_64.h has 0xC), id 1 = 0x16. **sysmodel** OS 1 (HP-UX) → 8 chars from EE 0x1230; OS 3 (OSF) → from EE 0x1238 ("9000/715"). | EEPROM + const |
| 5 | CACHE | F00120A0 | 0; 1 → −2 | `cache_size` 0xF00158E0 always returns 0x20000, so the table is fixed: I/D 128 KB, conf 0x61402000, line 0x20, ITLB/DTLB 64 entries, conf 0xD2000. Identical to 715_64.h. | table |
| 6 | HPA | F0013BC0 | 0 | 0xFFFBE000 | const |
| 7 | COPROC | F00123B8 | 0 | `fid` under the probe IVA with CCR = 0xC0. Returns ccr_functional/present 0xC0, and revision/model from the `fid` result. Also checks Page Zero byte 0x40. | HW |
| 8 | IODC | F0013BF8 | 0 read; 1, 2, 3, 4 → −2 | §3.2: directory lookup, presence probe, header patching, copying of entry blocks. | table + HW |
| 9 | TOD | F00153A8 | 0 read, 1 write, 2 calibrate | LASI RTC at F0109000: a read retries until two reads agree, and usec = 0. A write range-checks the values. Calibrate returns CPU MHz as an IEEE double (64.0/80.0/100.0) from the board ID. | HW |
| 10 | STABLE | F00129D0 | 0 read, 1 write, 2 size (=0x100), 3 verify, 4 init; **1000–1004** = the same on the HV area, only with ARG4 = −1000 | EEPROM 0xF00C1000 (§5). | EEPROM |
| 11 | NVOLATILE | — | | −1 | |
| 12 | ADD_VALID | F0011BA0 | 0 word, 1000 byte | Addresses ≥ 0xF0000000 in FFFB0000–FFFBDFFF → 1. Otherwise a **real probe load** under the probe IVA. Around the load, DR0 &= ~0x02AF0000 and DR0 \|= 0x2000. The result comes from the MIOC/DR0 state. | HW |
| 13–17 | | — | | −1, including DEBUG (14) and INSTR (15) | |
| 18 | BLOCK_TLB | F0011D38 | 0 info, 1 insert, 2 purge, 3 purge all | info: min 0x80 pages, max 0x4000 pages, fixed range = 8 combined slots, variable = 0. Insert/purge select the slot through DR8 and use `idtlba`/`pdtlbe`. | HW |
| 19 | TLB | F00151F0 | 0 info (min 0x1000, max 0x80000000), 1 setup | Programs the hardware TLB-miss walker: DR24 = table base + size code, DR25 = control. The DR25 shadow goes to Page Zero 0xE4. | HW |
| 20 | | — | | −1 | |
| 21 | PSW | F0015150 | 0 mask (=1), 1 get, 2 set | Default-endianness bit: DR0 & 0x100. | HW |
| 22 | SYSTEM_MAP | — | | **−1** (Linux then uses PDC_MEM_MAP) | |
| 23 | SOFT_POWER | F0013B00 | 0 info, 1 enable/disable | Writes LASI PCR 0xF010C000: ARG3 = 1 → PCR &= ~1; ARG3 = 0 → PCR \|= 1, or \|= 3 when DR25 bit 0 (PA numbering, the soft-power button) is 0. Returns 0 without doing anything if DR0 >> 26 = 0. | HW |
| 128 | MEM_MAP | F0013650 | 0 | device path → HPA plus "more pages"; table in §2.3. | table |
| 129 | EEPROM | F00134B8 | 0 rd word, 1 wr word, 2 rd byte, 3 wr byte | ARG2 = offset < 0x2000. Offsets 0x1000–0x13FF (stable storage) need ARG4 = −1000 (the `PDC_EEPROM_EEPROM_PASSWORD` in Linux `pdc.h`). The BCH uses this for every EE 0x16xx flag. | EEPROM |
| 130 | (EISA support) | F00124A0 | 0, 1, 2, 3, 5, 6 | 0 → 0xFC000000. 1/2 → write 0/1 to byte 0xFC010001. 3 → fill the EISA memory-window map registers at 0xFC100000 + 0x1000·n. 5 → 0xFC000000 + ARG. 6 → C routine 0xF0003DDC. **Not** `PDC_NVM`, which is what Linux numbers 130 on later machines. | HW |
| 136 | BROADCAST_RESET | F0012040 | 0 | LASI AMR = 3, read IRR, IMR = 0, then **write 5 (CMD_RESET) to 0xFFFC0030**, the broadcast IO_COMMAND, and spin. | HW |
| 137 | (137) | F0012990 | any | returns 0 (stub) | |
| 138 | LAN_STATION_ID | F0013580 | 0 | ARG3 = LAN HPA: 0xF0107000 → EE 0x16B4, 0xF0507000 → EE 0x16BA. 6 bytes returned as {word, 2 bytes}. Any other HPA → −4. | EEPROM |

### 2.3 PDC_MEM_MAP (from `firmware_map.py memmap`, fact)

ARG3 points to a device path. `flags`/bc0–2 must be FF FF FF. The halfword
{bc3, bc4} selects the bus and `mod` (or {bc5, mod}) picks the device. The
result is {HPA, more_pgs}. The `mod` numbers below are the ones the BCH and
HP-UX print as paths.

| Path | HPA | Path | HPA |
|---|---|---|---|
| mod 0 | F4000000 (GSC slot) | 2/0/1 | F0106000 SCSI |
| **mod 1** | **F8000000 Artist** | 2/0/2 | F0107000 LAN |
| **mod 2** | **F0100000 LASI** (1 page) | 2/0/4 | F0105000 RS-232 A |
| mod 3 | F6000000 | 2/0/6 | F0102000 parallel |
| mod 4 | FC000000 EISA (0x80 pages) | 2/0/8 | F0104000 audio |
| mod 5 | F0200000 WAX | 2/0/10 | F010A000 floppy |
| mod 6 | F0500000 LASI#2 | 2/0/11, 2/0/12 | F0108000, F0108100 PS/2 |
| mod 7 | FA000000 | 2/0/13, 14, 15 | F0104040, F0104060, F0104070 (audio-option RJ-16/ISDN) |
| **mod 8** | **FFFBE000 CPU** | 5/0/1, 5/0/2, 5/0/7 | F0201000 HIL, F0202000 RS-232 B, F0207000 |
| **mod 9** | **FFFBF000 memory** | 4/0/n (n = 1..15) | FC00n000 EISA slot (0x80 pages) |
| mod 10, 11, 12 | FFF88000, FFF8C000, FFF94000 (FW-SCSI) | 6/0/x | the same as 2/0/x at F05xxxxx; 6/0/9 → F04BE000 (2 pages) |
| mod 13 | F1000000 | | |

715_64.h's `mod_path` values agree: graphics 1, LASI 2, EISA 4, WAX 5,
CPU 8, LASI children 2/0/x. SeaBIOS's memory "mod 0x7 /* 0x9 */" should be
**9**.

### 2.4 Page Zero written by the ROM (fact; `page0_init` 0xF0000B70 unless noted)

| Offset | Value |
|---|---|
| 0x350/354/358 | MEM_CONT / PHSIZE / ADSIZE = memory size |
| 0x380 | MEM_FREE = 0x8000 |
| 0x384 | MEM_HPA = 0xFFFBE000 |
| **0x388** | **MEM_PDC = 0xF0012870** |
| 0x38C | MEM_10MSEC = 640000 / 800000 / 1000000 for codes 1/2/3 of `get_cpu_speed`, i.e. CR16 counts at the CPU clock |
| 0x390 | IMM hpa = 0xFFFBF000 |
| 0x394 | soft_boot = r17 |
| 0x398/39C | IMM spa_size / max_mem = memory size |
| 0x3A0, 0x400 | MEM_CONS and MEM_KBD paths preset to all FF. `console_init` (0xF001F1B8) fills MEM_CONS (hpa 0x3C0, iodc_io 0x3C8, class 0x3CC) and MEM_KBD (0x420…0x42C). |
| 0x3D0… | MEM_BOOT, filled by `boot_path_build` (BOOTFLOW) |
| 0x44 | 0x8000 |
| 0xE4 | 9 (the DR25 shadow, see PDC_TLB) |
| 0x614 | 0x700 |
| **0x604** | **0xF0024000 = STI image**, written at 0xF001F25C inside `console_init` |
| 0x608, 0x60C/0x610, 0xDC | used by the LAN and graphics IODC (0xF003165C, 0xF002A24C, 0xF00340C8) |

### 2.5 Cross-check with 715_64.h

Every PDC value in that header matches this ROM: entry, MODEL words, cache
info, IODC CHECK values, paths and "CPU_ID unsupported". The capabilities
value 2 is what Linux assumes when option 7 fails, which it does here. So
715_64.h was most likely taken on PDC 1.6 or a close revision. (inference)

## 3. IODC

### 3.1 Directory and modules (fact; `firmware_map.py iodc`)

- **The directory.** It sits at **0xF0028800** and holds {HPA, offset}
  pairs. The offset is relative to 0xF0028800. Several HPAs share one module.
- **The module headers.**
  - Each header follows Ch3: HVERSION(2), SPA, TYPE, SVERSION(4) and, if
    TYPE bit 7 (mr) is set, REV/DEP/FEATURES, CHECK, LENGTH and the entry
    table.
  - Each entry word is index(8) + word offset(24) from the header. It points
    at {CHECK(16), LENGTH(16) in words}, followed by position-independent
    code.
- **The values stored are the 715/100's** ("Mirage"): HVERSION CPU 0x60B,
  memory 0x04B, LASI parts 0x029, Artist/WAX 0x013. PDC_IODC rewrites them
  for the board it runs on (§3.2).

| HPA(s) | Device | Header at | HV / TYPE / SVERSION | Entry points (block start → declared end) |
|---|---|---|---|---|
| FFFBE000 | CPU | F00288F8 | 60B0 / 00 / 0x481 (8 B) | — |
| FFFBF000 | memory | F0028900 | 04B0, SPA 0x1A / 01 / 0x900 (8 B) | — |
| F0100000 | LASI BA | F0028908 | 0290 / 8B / 0x8100, CHECK FBE5, LENGTH 0 | — |
| F0500000 | LASI#2 BA ("Gecko Optional BA") | F0028918 | 0180 / 8B / 0x8100, CHECK FCF5 | — |
| F0102000 | Centronics | F0028928 | 0290 / 0A / 0x7400 (8 B) | — |
| F0105000, F0505000, F0202000 | RS-232 (LASI A, LASI#2, WAX B) | F0028930 | 0290 / 8A / 0x8C00, REV 1, CHECK E3F3 | INIT F0028948→F0029CDC, IO F0029CDC→F002A1C8 |
| F4000000, F6000000, **F8000000**, FA000000 | graphics (Artist and GSC slots) | F002A1C8 | 0130 / 8A / 0x8500, REV 1, CHECK ED26 | INIT F002A1E0 (code to F002B228; declared 0x1000 words → F002E1E4), IO F002B228 (code to F002C870; declared → F002E894) |
| F0106000, F0506000 | SCSI 53C710 | F002C870 | 0290 / 8A / 0x8200, REV 1, CHECK E8A1 | INIT F002C888→F002F164, IO F002F164→F0030E78 |
| F0107000, F0507000 | LAN i82596 | F0030E78 | 0290 / 8A / 0x8A00, **REV 2**, CHECK DA12 | INIT F0030E90→F0034DA8, IO F0034DA8→F0037BC8 |
| F0108000, F0108100 | PS/2 | F0037BC8 | 0290 / 8A / 0x8400, REV 1, CHECK EDBD | INIT F0037BE0→F003884C, IO F003884C→F00392F4 |
| F0104000 | Harmony audio | F00392F4 | 0290 / 0A / 0x7B00 (8 B) | — |
| F0104040, F0104060 | audio-option RJ-16 | F00392FC | 0150 / 0A / 0x8D00 (8 B) | — |
| F0104070 | audio-option ISDN | F0039304 | 0150 / 0A / 0x8700 (8 B) | — |
| F010A000 | floppy | F003930C | 0290 / 0A / 0x8300 (8 B) | — |
| F04BE000 | X.25 option, LASI#2 bus | F0039314 | 0250 / 0A / 0x2E00 (8 B) | — |
| F0200000 | WAX BA | F003931C | 0130, SPA 0x1A / 0B / 0x8E00 (8 B) | — |
| F0201000 | WAX HIL | F0039324 | 0130 / 8A / 0x7300, REV 1, CHECK 8167 | INIT F003933C→F0039A80, IO F0039A80→F0039F04 |
| FC000000 | WAX EISA BA | F0039F04 | 0290, SPA 0x1A / 0B / 0x9000 (8 B) | — |
| FFF88000, FFF8C000, FFF94000 | FW-SCSI (Type-A DMA) | F0039F0C | 0000 / 84 / 0x8980, REV 0x83, CHECK E03B | INIT F0039F24→F003CDF0, IO F003CDF0→F003F2A8 |

All 7 headers with entry tables, and all 14 entry blocks, sum to 0.

**Quirk: the graphics module's declared lengths are too long** (fact).
- The INIT block declares 0x1000 words and the IO block 0xD9A words, so both
  run on into the SCSI module, ending at F002E1E4 and F002E894.
- Their CHECK values were computed over those declared spans, so they still
  sum to 0.
- The real code ends at F002B228 and F002C870.
- An emulated PDC that copies blocks to RAM must copy the declared length.

Every module carries its own copy of HP millicode, for example at the end of
the FW-SCSI block, because IODC must be position independent.

### 3.2 PDC_IODC internals (fact)

`pdc_iodc` 0xF0013BF8 → `iodc_read` 0xF0013C44. ARG3 is the HPA (r23), ARG4
the index (0 = header, 3 = INIT, 4 = IO), ARG5/6 the buffer and its size.

1. **`iodc_probe_device` (0xF00141F8).** Before a module is reported, the
   device is checked for presence. Examples:
   - **Audio.** LASI audio+8 ← 0x29, poll, then read audio+0 and expect
     0x154000 (plain) or 0x158000 (ISDN option).
   - **Centronics.** Reads EE 0x169C.
   - **The rest** are handled by HPA class (EISA, GSC slots, LASI#2,
     F04BE000, WAX, F1000000, FW-SCSI).
   - SCSI returns a fixed word 0x2625A00 = **40,000,000** at ret+0x40: the 53C710 clock, 40 MHz.
2. **Directory lookup** (0xF0014818, base 0xF0028800). Unknown HPA → −1.
3. **`iodc_copy_header` (0xF0014964).** The first header word is patched by
   **`board_model`** (0xF00158A8, from the board-ID word F00FFFFC). This turns
   the stored 715/100 numbers into the right board's (fact, checked against
   Ver_nums and 715_64.h):

   | Board | Rule on the 12-bit HVERSION model | Results |
   |---|---|---|
   | 715/64 (ID 7) | clear bit 0 | 0x029→0x028, 0x013→0x012, 0x04B→0x04A, 0x60B→0x60A |
   | 715/80 (ID B) | nibble 9 → +2; 3 → 0; else +4 or +0xE | LASI 0x02B, Artist 0x010, memory 0x04F, CPU 0x619 |
   | 715/100 (ID F) | unchanged | |
   | 725/100 (ID E) | +1, or +2 for nibble B | LASI 0x02A, Artist 0x014, memory 0x04D, CPU 0x60D |

4. **Per-HPA overrides** (0xF0013D8C…):
   - **Memory.** The SPA byte becomes log2 of MEM_ADSIZE, from Page Zero
     0x358. 715_64.h shows 0x1C.
   - **CPU.** HVERSION is taken from **EE HV area word 0**.
   - **LASI#2 children.** HVERSION 0x0180.
   - **WAX RS-232.** HVERSION = LASI model − 0x16. 715_64.h shows 0x12.
   - **FW-SCSI slots.** The header is read from the card itself through
     `iodc_read_card_byte` (0xF0014B64, IO_DC_ADDRESS/DATA style). F00FFFFC
     is consulted too.
   - **F0207000.** The IODC is read from EISA I/O at FC001000…: signature
     "PA00", then header bytes at +0x10.
   - **GSC graphics slots** (F4/F6/FA000000). The card's own STI/IODC is
     probed through `gfx_slot_iodc_probe` (0xF001581C).
5. **Entry blocks.** For index ≥ 3 the code walks the entry table and checks
   the block sum: a bad sum returns −18 (−0x12). It then copies LENGTH words
   to the caller's buffer with `fdc`/`fic` (0xF0014A9C) and returns the
   length in bytes. A buffer that is too small returns −6.
6. **Bytewise IODC.** HPAs in 0xF1xxxxxx and 0xFCxxxxxx have bytewise IODC
   (`iodc_fetch_word` 0xF00148EC).

### 3.3 What the IODC modules drive

These are real drivers that show how the firmware runs each chip. The
details are not decoded yet.

- **RS-232** (LASI 16550 at F0105800, WAX UART). Console in and out (ENTRY_IO
  options 2/3).
- **Graphics.** A thin layer over **STI**.
  - ENTRY_INIT keeps its state at a fixed RAM area (base 0x2000) and in Page
    Zero 0x60C/0x610.
  - The console text calls STI routines with the STI calling convention
    (flags, in, out, glob_cfg = r3+0x48) through a function pointer: `be,l
    0(sr4,r4)` at F002A7C4, F002A9DC, F002ABB4, F002C030 and F002C1DC.
  - The built-in Artist uses the STI image at 0xF0024000. GSC cards use their
    own STI ROM.
- **SCSI** (LASI 53C710). Contains **SCRIPTS** (SELECT ATN, MOVE, JUMP, INT,
  WAIT DISCONNECT) with a relocation table. Boot-device reads are ENTRY_IO
  options 0/16 (inference). It has a "QUANTUM LPS525S" disk quirk.
- **LAN** (i82596). Network boot over **IP/ARP, BOOTP (UDP 67/68) and TFTP
  (69)**: the constants 0x800/0x806/0x43/0x44/0x45 appear in the block. This
  is the "boot across a gateway" that the 1.4 patch notes mention. The
  station address comes from PDC_LAN_STATION_ID or the EEPROM.
- **PS/2** (LASI, both ports). Keyboard with set-2 scan-code tables.
- **HIL** (WAX). HIL keyboard with keymaps.
- **FW-SCSI** (Type-A DMA cards at FFF88000/8C000/94000, SVERSION 0x89,
  53C720-class SCRIPTS).
- **No IODC at all** for audio, floppy, Centronics, the LASI BA and EISA.
  They have 8- or 16-byte headers only.

## 4. STI image (fact; `firmware_map.py sti`)

The image sits at **0xF0024000**, which is also the compiled code's `dp`.
Page Zero 0x604 points at it (§2.4).

**Header (word mode):**
- `type` 03 03 03 03; `num_mons` 13; `revno` 0x84, 0x07; **graphics_id
  0x2B4DED6D 0x40A00499**.
- Pointers: font_start +0x37D4, state size 0x1B, **last_addr +0x47E5**,
  region_list +0x37C0, mon_tbl +0x2C0, user_data +0x328, user_data_size
  0x138.
- Other fields: reentsize 0, maxtime 0xFA, sti_mem_req 0x100, power 0,
  bus_support 0, alt_code_type 0, cfb 0.
- The "_addr" copies at +0xC0 hold init_graph only.

**Routines** (offsets from the image; each routine runs up to the next one):

| Routine | Offset → address |
|---|---|
| INIT_GRAPH | +0x0808 → F0024808 |
| STATE_MGMT | +0x1FC4 → F0025FC4 |
| FONT_UNPMV | +0x2248 → F0026248 |
| BLOCK_MOVE | +0x27D4 → F00267D4 |
| SELF_TEST | +0x2B20 → F0026B20 |
| EXCEP_HDLR | +0x329C → F002729C |
| INQ_CONF | +0x33A8 → F00273A8 |
| SET_CM_ENTRY | +0x362C → F002762C |

- **DMA_CTRL = +0x37C0** is not a routine. It is the end-of-code marker (the
  region list starts there), which callers that copy routines use as the end
  of SET_CM_ENTRY.
- FLOW_CTRL and the later pointers are 0. There is no alternate (64-bit)
  code.

**Region list** (offsets from the graphics HPA 0xF8000000):

| # | Offset | Length | Flags |
|---|---|---|---|
| 0 | +0 (ROM) | 6 pages | btlb |
| 1 | **+0x1000000 = 0xF9000000 framebuffer** | 16 MB | btlb |
| 2 | **+0x100000 = 0xF8100000 control** | 0x280000 (to 0xF8380000) | btlb |
| 3 | +0x380000 | 1 page | sys_only, last |

The future pointer is 0.

**Monitor table** (mon_tbl_desc x:12 y:12 hz:7 flat:1 | vesa, grey…) and the
per-monitor records at 0xF0024328 + 0x60·i. `monitor N` in the BCH is entry
N−1.

| BCH type | Mode | Pixel clock (record +0x54) |
|---|---|---|
| 1 | 1280×1024 72 Hz | 135.000 MHz |
| 2 | 1024×768 75 Hz | 84.587 |
| 3 | 1024×768 70 Hz | 75.000 |
| 4 | 1024×768 75 Hz flat panel | 84.000 |
| 5 | 1280×1024 60 Hz | 108.181 |
| 6 | 1024×768 60 Hz | 64.1088 |
| 7 | 640×480 60 Hz | 25.175 |
| 8 | 1280×1024 75 Hz VESA | 135.000 |
| 9 | 1024×768 75 Hz VESA | 78.750 |
| 10 | 800×600 75 Hz VESA | 49.500 |
| 11 | 640×480 75 Hz VESA | 31.500 |
| 12 | 1280×1024 72 Hz greyscale | 135.000 |
| 13 | 1280×1024 50 Hz | 110.000 |

- Each 96-byte record holds:
  - +0: record size 0x60 and the x/y resolution.
  - +4: the **VRAM pitch 0x800 × 0x400**: 2048 × 1024 pixels in all modes.
  - A block of constant engine set-up words.
  - +0x30…+0x3B: 12 bytes that differ per mode — the video timing values.
  - +0x54: the pixel clock in Hz.
  - +0x58: a clock-select code (0xE–0x13).
- The 715 owner's guide lists types 1–11. 12 and 13 are the 712 types. All
  13 are in this ROM.

**Font.**
- Font header at F00277D4: chars 0–255, **8×16**, type 1 (HP Roman-8), 16
  bytes per char, next = 0 (one font only), underline 1 pixel at row 15.
- The glyphs (F00277E4–F00287E3) are plain bitmaps, one byte per row, MSB on
  the left.
- Glyphs 0–31 are control-picture glyphs ("NU", …).
- No other font exists in the ROM: it was searched for the glyph patterns.

**Compared with SeaBIOS's `stirom.c`:**
- The same: revno 0x84/0x07, graphics_id and all four regions. SeaBIOS
  copied these from this image.
- Different in SeaBIOS:
  - 4 monitors, all 72 Hz.
  - Four fonts (8×16, 6×13, 10×20, 16×32).
  - init_graph reads the QEMU-only ctrl+0x111110 to get the resolution,
    while HP's code uses the 13 timing records.
  - A two-page ROM region that is resized at run time.

**What the STI code needs from Artist** (detail is the hardware agent's):
- All register access goes through region pointers.
- Region 2 (0xF8100000) with `addil L%0x18000` (16 sites) is the bitmap
  engine: FG/BG, BITMAP_OP, plane mask, CMAP at +0x18000…
- Region 2 with `addil L%0x200000` (24 sites) is 0xF8300000…: video timing,
  cursor and the misc/RAMDAC registers that the timing records program.
- Region 1 is the 2048×1024 framebuffer.
- Region 3 (0xF8380000, sys-only) is the second FIFO/control page.

## 5. Stable storage and EEPROM

### 5.1 Device and access (fact)

- **The EEPROM:**
  - It is an **8 KB byte-wide part at 0xF00C0000–0xF00C1FFF**, on LASI's
    8-bit bus. It is probably under the third chip select (0xC0000–0xFFFFF of
    LASI ROM space), going by the 712 LASI ERS chip-select map. (inference)
  - It is **not the flash**: it lies outside the flash's
    0xF0000000–0xF003FFFF, and it is written with plain byte stores and no
    flash command sequence.
  - Neither is it the WAX EISA EEPROM.
- **Reading.** Plain byte loads. `eeprom_rd_word` assembles 4 bytes.
- **Writing:**
  - One byte at a time: store, then poll by reading back until the byte
    reads equal.
  - Timeout ≈ 10 ms. `eeprom_wr_word_abs` waits 1,000,000 CR16 ticks; the
    other writers call the timeout check at 0xF00157A4 with 0x2710 (10000).
  - This is **28C64-style data polling**: no unlock sequence and no page
    buffer.
  - Routines: `ee_write_word` 0xF0013220, `eeprom_wr_byte` 0xF0013320,
    `eeprom_wr_word_abs` 0xF001335C.
- **FPGA model:** 8 KB of byte RAM that reads back the written value at
  once, saved to a MiSTer file.
- This matches "the 715/64/80/100 have no EEPROM FRU" in the docs: the part
  is soldered, not absent.

### 5.2 EEPROM map (offsets from 0xF00C0000)

| Offset | Size | Contents |
|---|---|---|
| 0x0400 | 12 | 0xFFFFFFFF ×3 at first-boot init |
| **0x1000** | 256 | **PDC_STABLE copy A** (architected layout, §5.4) |
| **0x1100** | 256 | **PDC_STABLE copy B** |
| **0x1200** | 256 | **HV area** (PDC_STABLE 1000–1004, password −1000): PDC_MODEL identity (§5.5) |
| 0x1300 / 0x1350 / 0x13A0 | 3 × 0x50 | per-block rings of 10 × {checksum, write count} (§5.3) |
| 0x1400 | 0x164 | HPMC PIM |
| 0x1564 | 0x130 | TOC PIM |
| 0x1694 | 1 | **chassis/manufacturing flag**: 0xB0 = chassis codes to RS-232 A, bit 0 = **manufacturing mode**, 0xFF = off. First boot writes **0xB1**. `manufactureoff` clears bit 0. |
| 0x1695 | 1 | fastboot (1 = on) |
| 0x1696 | 1 | secure |
| 0x1699 | 1 | diagnostic_boot (1 at first boot) |
| 0x169C | 4 | word written with the identity; PDC_IODC reads it for the Centronics port (?) |
| 0x16A4/0x16A8, 0x16AC/0x16B0 | 4 each | HPMC / TOC PIM sequence counters |
| **0x16B4** | 6 | **LAN station address 1** (LASI LAN). First boot: 08:00:09:EE:EE:EE |
| 0x16BA | 6 | LAN station address 2 (LASI#2). First boot: 08:00:09:FF:FF:FF |
| 0x16C0 | 10 | board serial number (`serial_num`) |
| **0x16CA** | 1 | **monitor type for the built-in graphics** (path mod 1) |
| 0x16D0 | 1 | system-type byte read by the identity builder |
| 0x16D4 / 0x16D5 / 0x16D6 | 1 each | monitor type for GSC slots mod 0 / 3 / 7 |
| **0x16D8** | 1 | identity valid: **'G'**. 'U' = rebuild the identity only. Anything else = defaults plus identity. |
| **0x16D9** | 1 | EEPROM initialised: **'N'**. Anything else runs the first-boot defaults (0xF0000338). |
| 0x16DA | 1 | 'Y' |
| 0x1E04 / 0x1E0C | 4 each | 0xFFFFFFFF / 1 at first boot |

BOOTFLOW.md §2.3/§2.9 has the BCH side of the 0x169x flags.

### 5.3 PDC_STABLE implementation (fact)

- **Size.** `ss_setup` (0xF0012A54): r19 = **0x100**, which option 2 returns;
  base r20 = 0xF00C1000.
- **Two copies.** A write updates copy A, then copy B. Each copy carries a
  32-bit checksum: Σ words + 0x357 + checksum = 0.
- **Verify.** `ss_verify` (0xF0012BA0) checks both copies.
  - If one is bad, it is rewritten from the good one, and the call returns
    status 1.
  - If both are bad, the call returns −5.
- **Where the checksum lives.** It is not inside the block. It sits in a ring
  of 10 {checksum, count} records per block at 0x1300/0x1350/0x13A0.
  - `ss_ring_select` (0xF0012E3C) uses the first record whose count is below
    a threshold.
  - The threshold starts at 9500 and rises by 500 per lap.
  - At the threshold the checksum moves to the next record.
- **Why the ring:** it is wear-levelling against the ~10k write endurance of
  the EEPROM's checksum words. (inference)
- **Read/write arguments.** Word-aligned offset and length inside 0x100;
  otherwise −10.
- **Options 1000–1004** do the same for the HV area, with ARG4 = −1000.
- **Option 4** (initialise) writes zeros and fresh checksums.

### 5.4 Stable-storage layout and the ROM's defaults (fact: `build_default_ss_identity` 0xF001FDF8)

The layout is the PDC 1.1 one (Ch1:3257). Default values are written when EE
0x16D8 ≠ 'G'/'U', and by BCH `defaultss`:

| SS offset | Field | Default |
|---|---|---|
| 0x00 | primary boot path | flags **0xC0** (autoboot + autosearch, timer 0), bc FF FF FF FF **2 0**, mod **1**, layer0 = **6** → **2/0/1.6** (LASI SCSI ID 6) |
| 0x40 | OS_ID / OS area | byte 0x40 = 0x01 |
| 0x5F | fast-size | **0x0F** (all memory) |
| 0x60 | console path | flags 0, bc all FF, mod **1** → **built-in graphics** |
| 0x80 | alternate boot path | bc …2 0, mod **2** → **2/0/2** (LAN) |
| 0xA0 | keyboard path | bc …2 0, mod **11** → **2/0/11** (PS/2 port 0) |

The rest is 0. Linux writes OS_ID at 0x40. HP-UX keeps its paths and
fast-size here.

**The LAN station address is in the EEPROM, not in stable storage.**
- PDC_LAN_STATION_ID returns it, and the BCH `lan_addr` command shows it.
- The hidden `lanaddress` command ("Enter the two LAN Station Addresses")
  sets it.
- Linux's fallback, the EEPROM at 0xF0810000 in `lasi_82596.c`, does not
  apply here.

### 5.5 HV area: the PDC_MODEL identity (fact, partly decoded)

`identity_init` (0xF00202D0, run at reset if EE 0x16D8 ≠ 'G') works like
this:

1. Read the HV area (option 1000).
2. Decode the board ID at F00FFFFC, and fill in the fields below.
3. Write the area back (option 1001), then EE 0x169C, then EE 0x16D8 = 'G'.

| HV offset | Contents |
|---|---|
| +0x00 | HVERSION word: 0x60A0 (715/64) / 0x6190 (715/80) / 0x60B0 (715/100) / 0x60D0 (725/100) |
| +0x04 | SVERSION 0x481 |
| +0x08…+0x23 | the rest of the PDC_MODEL info words. sw_id and sw_cap are kept from the old contents (factory-programmed); hw_id, boot_id, arch_rev and the keys are overridden by PDC_MODEL itself. |
| +0x24 | CPU Hz / 100 (via `$$divU`) |
| +0x28 | CPU MHz as an IEEE double, high word: 0x40500000 = 64.0, 0x40540000 = 80.0, 0x40590000 = 100.0 |
| +0x30 | "9000" "/715" (or "/725"): the PDC_MODEL sysmodel string for HP-UX |
| +0x38 | the OSF string |

The same routine also writes 0xBBBBBBBB and then HVERSION to
**0xF0106134** (LASI SCSI unit + 0x134). That is a cross-over item (§7).

### 5.6 Consequences for the MiSTer core

- **The EEPROM must exist and be writable.** Without it, `PDC_STABLE`,
  `PDC_MODEL`, `PDC_LAN_STATION_ID` and PIM all fail, and the BCH prints
  "Read from EEPROM failed".
- **A blank EEPROM (all 0xFF) works.** The ROM writes its first-boot defaults
  (0x16D9), then the identity and default stable storage (0x16D8). But it
  then comes up in **manufacturing mode**:
  - EE 0x1694 = 0xB1, so console and keyboard are forced to RS-232 port A.
  - Autoboot is ignored.
  - MAC = 08:00:09:EE:EE:EE.
  - Getting out of it takes `manufactureoff`, `lanaddress` and `serial_num`
    in BOOT_ADMIN.
- **The alternative is to ship an EEPROM image prepared once that way.**
  - Patching four bytes is enough: 0x1694 = 0xB0 or 0xFF, the MAC at
    0x16B4, then leave the 0x16D8/0x16D9 markers alone.
  - The PDC_MODEL `sw_id` (HV +0x10) is factory data. The real 715/64 had
    2004000715. A blank part leaves it 0xFFFFFFFF, which HP-UX licensing may
    care about. (?)
- **The board-ID word at 0xF00FFFFC decides the model, the MHz and every
  HVERSION.** The core must supply it: 0x7x for a 715/64, 0xBx for a 715/80,
  0xFx for a 715/100.

## 6. The update tape: UPDATE, DAGGER, IMAGE1A/1B

- **`AUTO`** is `ODE UPDATE ; stable off ; RUN`. ISL starts ODE, which runs
  the UPDATE test module with stable-storage updating **off**.
- **`UPDATE`** is a SOM ODE module: "PDC UPDATER", "@(#)UPDATE Revision Code
  A.00.19, January 20, 1995".
  - It supports wright_bros, kittyhawk, piranha, gecko (712) and **mirage /
    electra** (715/725), plus Dagger cards.
  - It identifies **Am29F010** parts with the AMD autoselect sequence: AA →
    base+0x5555, 55 → base+0x2AAA, 90, then expects manufacturer 01 and
    device 20.
  - It also knows Am28F020/A, Am29F040, Intel 28F004BX and Samsung KM29C010.
    The Samsung parts get page writes ("samsung write").
  - Each chip is erased (AA/55/80/AA/55/10 or 30), programmed (AA/55/A0 +
    byte), and verified: "1st rom done!!", "2nd rom".
  - So the 256 KB image is **two 128 KB Am29F010s**, the first and second
    halves. Each chip has eight 16 KB sectors.
  - "duplicating nvm/ss area", "spec_sector" and "2nd rom partial erase"
    belong to the **Gecko** path. On the 712, stable storage sits in the
    second flash's last sector (0xF009C000…, from UPDATE's constants).
  - On Mirage, stable storage is in the EEPROM, so nothing in the flash
    needs preserving. (inference)
  - **After the update, UPDATE writes 0 to EE 0x16D8** (routine at file
    offset 0x74C4). It does this on 715/64, 715/100 and 725 board IDs
    (0x7x, 0xFx, 0xEx), but not on 715/80. The next boot therefore rebuilds
    the identity **and resets stable storage to the ROM defaults**.
  - The tape's `stable off` only stops UPDATE writing stable storage itself.
  - The checksum it checks is the 64-bit word sum in the image header (§1).
- **`DAGGER`** is identified: a raw PA-RISC image, "DAGGER – FEPROM Update
  Utility, 14 March 1994".
  - It runs from the factory **Dagger** card, a ROM card on the
    personality/second-LASI connector.
  - Its menu: "Download from Dagger source at F0080000 to System target at
    F0400000", Upload, Compare. "Contiguous (Mirage/Electra)" vs "Split
    (Gecko)" address space.
  - It "Saving LAN addresses", "EEPROM: Clearing valid byte…".
  - UPDATE reflashes it only with `dagger on` (IMAGE2, three ROMs).
  - Not needed for the core. The BCH text "use a Dagger card or SSCONFIG"
    re-enables manufacturing mode.
- **`IMAGE1B`** (payload "1\n") is the "second PDC image" slot of the
  updater. On Mirage it is a placeholder. (inference)

## 7. Cross-overs for the other agents

| Item | For |
|---|---|
| **Board-ID word 0xF00FFFFC** (bits 7..4), LED latch 0xF00EFFFF, EEPROM 0xF00C0000 (8 KB, data-polled), and the LASI#2/Dagger probe at 0xF041FFFF | hardware map |
| `identity_init` writes 0xBBBBBBBB then HVERSION to **0xF0106134**. This is LASI SCSI + 0x134, outside the 53C710's 0x00–0x3F registers. Possibly a LASI scratch or ID register. | hardware map |
| The probe IVA HPMC handler reads **MIOC +0x84** (error status). PDC_PIM LPMC also checks MEM_HPA+0x84 & 0x41. PDC_ADD_VALID sets DR0 \|= 0x2000 and clears 0x02AF0000 around the probe. | hardware map / CPU |
| PDC_BROADCAST_RESET writes 5 to 0xFFFC0030. PDC_SOFT_POWER uses LASI PCR bits 1:0 and DR25 bit 0. PDC_TLB uses DR24/DR25. PDC_BLOCK_TLB uses DR8 + `idtlba`. | CPU (PCX-L diagnose model) |
| Artist registers that STI uses: region 2 + 0x18000 and + 0x200000; the 13 timing records (§4) say what the video timing generator must accept. | hardware map (Artist) |
| `bootflow.sym` and `firmware.sym` are complementary; the shared addresses were left in bootflow.sym. | all |

## 8. Open questions

1. **The meaning of the 12 timing bytes per monitor** (+0x30…+0x3B) and the
   clock-select codes. This needs the Artist register map (or QEMU
   `artist.c`) and a trace of INIT_GRAPH.
2. **HV area layout beyond +0x08 and +0x38.** In particular, where sw_id
   (+0x10) gets its factory value, and what HP-UX does if it is all FF. The
   `serial_num`/`install` BCH commands may write it.
3. **EE 0x169C and 0x16D0**: the exact meaning. **F0207000**: what the
   EISA-hosted IODC device ("PA00" signature) is. **F1000000** (MEM_MAP mod
   13): what device is there.
4. **SCSI/LAN/PS/2 IODC decoding.** The ENTRY_IO options, register sequences
   and SCRIPTS semantics are not decoded yet. They are the best reference for
   how firmware drives the 53C710, the i82596 and LASI PS/2.
5. **EEPROM write timing** (≤ 10 ms poll window). A RAM-backed model with
   instant completion should be safe, but this has not been tested.
6. **Is the 0xF003F2A8–0xF003FFFF tail really erased (0xFF) on hardware?**
   Nothing reads it, so the value does not matter to the core.
