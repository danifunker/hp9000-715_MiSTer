#!/usr/bin/env python3
"""Structure of the HP 9000/715 boot ROM (PDC revision 1.6) as *firmware*.

Importable (no objdump needed for the static parts):

    import firmware_map as fm
    fm.REGIONS                 # [(start, end, kind, name, note)], end exclusive
    fm.region_at(0xf0012870)   # -> the region tuple containing an address
    fm.is_code(addr)           # True for code kinds (asm/c/millicode/iodc-code/sti-code)
    fm.parse_iodc(data)        # IODC directory + module headers/entry points, checksums checked
    fm.parse_sti(data)         # STI header, region list, monitor table, timing records, font, CRC
    fm.EEPROM_MAP              # [(offset, size, name, note)] for the 8 KB EEPROM at 0xF00C0000
    fm.PDC_PROCS               # [(index, name, handler, options, note)]

Command line:

    firmware_map.py [ROM] regions          region table (also: --tsv FILE writes it as TSV)
    firmware_map.py [ROM] iodc             IODC directory and modules
    firmware_map.py [ROM] sti              STI image
    firmware_map.py [ROM] pdc              PDC dispatch, re-derived from the ROM (needs objdump)
    firmware_map.py [ROM] memmap           PDC_MEM_MAP path->HPA table, re-derived (needs objdump)
    firmware_map.py [ROM] eeprom           EEPROM byte map
    firmware_map.py [ROM] check            verify every checksum/CRC this module knows about

Everything here was established by reading the disassembly; the write-up is
docs/reference/rom/FIRMWARE.md.  Addresses are CPU (F-space) addresses.
"""
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import romlib  # noqa: E402

ROM_BASE = romlib.ROM_BASE
FLASH_END = 0xF0040000          # 256 KB flash; the image stops at IMAGE_END
IMAGE_END = 0xF003F2A8
IODC_DIR = 0xF0028800           # HPA/offset directory; offsets are relative to it
STI_BASE = 0xF0024000           # also the compiled code's dp ($global$)
PDC_ENTRY = 0xF0012870          # Page Zero MEM_PDC (written at 0xF0000B98)

# ---------------------------------------------------------------------------
# Region map.  kinds:
#   hdr        fixed header words          asm     hand-written assembler
#   c          compiled C (dp-relative)    milli   HP millicode ($$divI etc.)
#   iva        interruption vector table   data    tables / strings / constants
#   pad        zero fill                   sti-*   STI image parts
#   iodc-dir   IODC directory              iodc-hdr IODC 8/16-byte headers (+entry table)
#   iodc-code  IODC entry-point block      iodc-data data inside an IODC block
#   font       bitmap font                 unused  flash beyond the image
# "other agent" = covered in the reset/boot-flow notes, only outlined here.
# ---------------------------------------------------------------------------
REGIONS = [
    (0xF0000000, 0xF0000010, "hdr", "rom_header",
     "+0 b,l,n 0xF00026B0; +4 b to 0xF0000010 (CPU reset vector 0xF0000004); +8 0x00000016 = firmware revision 1.6; +C 0"),
    (0xF0000010, 0xF0001CC0, "asm", "reset_init",
     "reset entry, EEPROM first-boot init (0xF0000338), Page Zero init (0xF0000B70) -- other agent"),
    (0xF0001CC0, 0xF0002000, "pad", "pad_before_iva", "zero"),
    (0xF0002000, 0xF0002400, "iva", "iva_main", "main IVA (CR14) -- other agent"),
    (0xF0002400, 0xF0004000, "c", "early_c", "interruption handlers, PIM/console helpers, early C -- other agent"),
    (0xF0004000, 0xF0008908, "asm", "selftest_asm_1", "self-tests, PIM save to EEPROM (0xF0004410..) -- other agent"),
    (0xF0008908, 0xF0009020, "pad", "pad_selftest", "zero"),
    (0xF0009020, 0xF000F16C, "asm", "selftest_asm_2", "cache/TLB/memory/FP self-tests -- other agent"),
    (0xF000F16C, 0xF00116D4, "c", "selftest_c", "device self-tests in C -- other agent"),
    (0xF00116D4, 0xF0011800, "pad", "pad_before_probe_iva", "zero"),
    (0xF0011800, 0xF0011B40, "iva", "pdc_probe_iva",
     "IVA installed by PDC_ADD_VALID/PDC_COPROC while probing: vec 1 (HPMC)->0xF0011B40, vec 14 and 22 skip the faulting insn and return -1"),
    (0xF0011B40, 0xF0015520, "asm", "pdc",
     "PDC procedures; entry PDCE_PROC 0xF0012870, jump table 0xF00128AC, HV-dependent dispatch 0xF0012978"),
    (0xF0015520, 0xF0016468, "asm", "pdc_support",
     "register save/restore (0xF0015520/0xF0015600), EEPROM access, delays, board-ID decode, cache flush, console putc, get_dp"),
    (0xF0016468, 0xF0020334, "c", "bch_c", "Boot Console Handler, boot/search, IODC callers (dp=0xF0024000)"),
    (0xF0020334, 0xF0020854, "milli", "millicode", "$$divU/$$divI/$$mulI ..."),
    (0xF0020854, 0xF0020858, "pad", "pad_before_strings", "zero"),
    (0xF0020858, 0xF00233EC, "data", "strings", "BCH strings, keyword table, messages (dp-relative)"),
    (0xF00233EC, 0xF0024000, "pad", "pad_before_sti", "zero"),
    (0xF0024000, 0xF0024100, "sti-hdr", "sti_header", "STI ROM DD header, word mode (03030303), graphics_id 2B4DED6D 40A00499"),
    (0xF0024100, 0xF00242C0, "pad", "sti_reserved", "zero"),
    (0xF00242C0, 0xF0024328, "sti-data", "sti_monitor_table", "13 x 8-byte mon_tbl_desc"),
    (0xF0024328, 0xF0024808, "sti-data", "sti_monitor_timing", "13 x 96-byte per-monitor init/timing records (user data at +0x328)"),
    (0xF0024808, 0xF00277C0, "sti-code", "sti_routines", "INIT_GRAPH .. SET_CM_ENTRY (position independent)"),
    (0xF00277C0, 0xF00277D4, "sti-data", "sti_region_list", "4 regions + future ptr"),
    (0xF00277D4, 0xF00287E4, "font", "sti_font_8x16", "font header (16 B) + 256 glyphs x 16 B, type 1 (HP Roman-8)"),
    (0xF00287E4, 0xF00287E6, "sti-data", "sti_crc", "STI CRC (0xFF10): CRC over 0..last_addr = 0"),
    (0xF00287E6, 0xF0028800, "pad", "pad_before_iodc", "zero"),
    (0xF0028800, 0xF00288F8, "iodc-dir", "iodc_directory", "30 x {HPA, offset} + {0,0}; offset relative to 0xF0028800"),
    (0xF00288F8, 0xF0028930, "iodc-hdr", "iodc_hdrs_cpu_mem_lasi_lpt", "CPU, memory (8 B), LASI, LASI#2 (16 B), Centronics (8 B)"),
    (0xF0028930, 0xF0028948, "iodc-hdr", "iodc_rs232_hdr", "RS-232 (LASI UART, LASI#2 UART, WAX UART)"),
    (0xF0028948, 0xF0029CDC, "iodc-code", "iodc_rs232_init", "ENTRY_INIT"),
    (0xF0029CDC, 0xF002A1C8, "iodc-code", "iodc_rs232_io", "ENTRY_IO"),
    (0xF002A1C8, 0xF002A1E0, "iodc-hdr", "iodc_gfx_hdr", "graphics SVERSION 0x85 (built-in Artist + GSC slots)"),
    (0xF002A1E0, 0xF002B228, "iodc-code", "iodc_gfx_init",
     "ENTRY_INIT (declared length 0x1000 words runs to 0xF002E1E4; checksum still balances)"),
    (0xF002B228, 0xF002C870, "iodc-code", "iodc_gfx_io", "ENTRY_IO (declared length runs to 0xF002E894)"),
    (0xF002C870, 0xF002C888, "iodc-hdr", "iodc_scsi_hdr", "LASI 53C710 SCSI"),
    (0xF002C888, 0xF002ED7C, "iodc-code", "iodc_scsi_init", "ENTRY_INIT: 53C710 boot driver"),
    (0xF002ED7C, 0xF002ED90, "iodc-data", "iodc_scsi_init_quirk", "'QUANTUM LPS525S' + 1"),
    (0xF002ED90, 0xF002EED8, "iodc-data", "iodc_scsi_init_scripts", "53C710 SCRIPTS"),
    (0xF002EED8, 0xF002EF40, "iodc-data", "iodc_scsi_init_patch", "SCRIPTS patch-offset table"),
    (0xF002EF40, 0xF002F164, "iodc-code", "iodc_scsi_init_tail", "zero fill (0xF002EF40-84) then code"),
    (0xF002F164, 0xF0030A90, "iodc-code", "iodc_scsi_io", "ENTRY_IO"),
    (0xF0030A90, 0xF0030AA4, "iodc-data", "iodc_scsi_io_quirk", "'QUANTUM LPS525S' + 1"),
    (0xF0030AA4, 0xF0030BEC, "iodc-data", "iodc_scsi_io_scripts", "53C710 SCRIPTS (copy)"),
    (0xF0030BEC, 0xF0030C54, "iodc-data", "iodc_scsi_io_patch", "SCRIPTS patch-offset table"),
    (0xF0030C54, 0xF0030E78, "iodc-code", "iodc_scsi_io_tail", "zero fill (0xF0030C54-98) then code"),
    (0xF0030E78, 0xF0030E90, "iodc-hdr", "iodc_lan_hdr", "LASI i82596 LAN"),
    (0xF0030E90, 0xF0034DA8, "iodc-code", "iodc_lan_init", "ENTRY_INIT: network boot"),
    (0xF0034DA8, 0xF0037BC8, "iodc-code", "iodc_lan_io", "ENTRY_IO"),
    (0xF0037BC8, 0xF0037BE0, "iodc-hdr", "iodc_ps2_hdr", "LASI PS/2 (both ports)"),
    (0xF0037BE0, 0xF003884C, "iodc-code", "iodc_ps2_init", "ENTRY_INIT"),
    (0xF003884C, 0xF00390E0, "iodc-code", "iodc_ps2_io", "ENTRY_IO"),
    (0xF00390E0, 0xF00392F4, "iodc-data", "iodc_ps2_keymaps", "scan-code set 2 -> ASCII, plain and shifted (two copies)"),
    (0xF00392F4, 0xF0039324, "iodc-hdr", "iodc_hdrs_8byte",
     "8-byte headers: Harmony audio, RJ-16 x2, ISDN, floppy, X.25 (LASI#2 bus), WAX BA"),
    (0xF0039324, 0xF003933C, "iodc-hdr", "iodc_hil_hdr", "WAX HIL"),
    (0xF003933C, 0xF0039A80, "iodc-code", "iodc_hil_init", "ENTRY_INIT"),
    (0xF0039A80, 0xF0039E30, "iodc-code", "iodc_hil_io", "ENTRY_IO"),
    (0xF0039E30, 0xF0039F04, "iodc-data", "iodc_hil_keymaps", "HIL key -> ASCII, plain and shifted"),
    (0xF0039F04, 0xF0039F0C, "iodc-hdr", "iodc_eisa_hdr", "WAX EISA BA (8 B)"),
    (0xF0039F0C, 0xF0039F24, "iodc-hdr", "iodc_fwscsi_hdr", "FW-SCSI (Type-A DMA, SVERSION 0x89) at 0xFFF88000/8C000/94000"),
    (0xF0039F24, 0xF003CA28, "iodc-code", "iodc_fwscsi_init", "ENTRY_INIT: 53C720-class boot driver"),
    (0xF003CA28, 0xF003CA3C, "iodc-data", "iodc_fwscsi_init_quirk", "'QUANTUM LPS525S' + 1"),
    (0xF003CA3C, 0xF003CB78, "iodc-data", "iodc_fwscsi_init_scripts", "SCRIPTS"),
    (0xF003CB78, 0xF003CBD0, "iodc-data", "iodc_fwscsi_init_patch", "SCRIPTS patch-offset table"),
    (0xF003CBD0, 0xF003CDF0, "iodc-code", "iodc_fwscsi_init_tail", "zero fill (0xF003CBD0-0xF003CC10) then code"),
    (0xF003CDF0, 0xF003E6BC, "iodc-code", "iodc_fwscsi_io", "ENTRY_IO"),
    (0xF003E6BC, 0xF003E6D0, "iodc-data", "iodc_fwscsi_io_quirk", "'QUANTUM LPS525S' + 1"),
    (0xF003E6D0, 0xF003E80C, "iodc-data", "iodc_fwscsi_io_scripts", "SCRIPTS (copy)"),
    (0xF003E80C, 0xF003E864, "iodc-data", "iodc_fwscsi_io_patch", "SCRIPTS patch-offset table"),
    (0xF003E864, 0xF003F2A8, "iodc-code", "iodc_fwscsi_io_tail", "zero fill (0xF003E864-A4) then code incl. millicode copy"),
    (0xF003F2A8, 0xF0040000, "unused", "flash_unprogrammed", "3,416 bytes past the image; never referenced by the ROM"),
]

CODE_KINDS = {"asm", "c", "milli", "iodc-code", "sti-code", "hdr"}


def region_at(addr):
    for r in REGIONS:
        if r[0] <= addr < r[1]:
            return r
    return None


def is_code(addr):
    r = region_at(addr)
    return bool(r) and r[2] in CODE_KINDS


# Other non-RAM F-space the firmware uses (not in the flash image).
OTHER_SPACES = [
    (0xF00C0000, 0xF00C2000, "EEPROM 8 KB (LASI 8-bit bus, chip select 2); byte writes, data-polled"),
    (0xF00EFFFF, 0xF00F0000, "LED latch (byte, written inverted by PDC_CHASSIS 0xF00122E0)"),
    (0xF00FFFFC, 0xF0100000, "board-ID word: bits 7..4 = 7 715/64, B 715/80, F 715/100, E 725/100"),
    (0xF041FFFF, 0xF0420000, "LASI#2 8-bit bus: presence/ID byte read by PDC_IODC (bit 0)"),
]

# ---------------------------------------------------------------------------
# PDC procedures (handler = first instruction of the procedure's code).
# ---------------------------------------------------------------------------
PDC_PROCS = [
    (1, "PDC_POW_FAIL", None, "", "-1 (not implemented)"),
    (2, "PDC_CHASSIS", 0xF00122B8, "0, 0x200", "LED latch 0xF00EFFFF (inverted); echoed to UART if EEPROM[0x1694] is 0xB0/0xB1"),
    (3, "PDC_PIM", 0xF0014EE0, "0 HPMC, 1 size, 2 LPMC, 4 TOC; 3 -> -2",
     "HPMC/TOC PIM from EEPROM 0x1400/0x1564; LPMC from Page Zero 0x1A0"),
    (4, "PDC_MODEL", 0xF0014D00, "0 info, 2 versions, 3 sysmodel, 4/5 key 0x72; 1 -> -2",
     "info = 36 B from EEPROM HV area 0xF00C1200 (+fixed hw_id/boot_id 0, arch_rev 4, keys 0x72)"),
    (5, "PDC_CACHE", 0xF00120A0, "0; 1 -> -2", "fixed table (128 KB I/D, 0x61402000, 64-entry TLB info)"),
    (6, "PDC_HPA", 0xF0013BC0, "0", "0xFFFBE000"),
    (7, "PDC_COPROC", 0xF00123B8, "0", "probes the FPU (fid under probe IVA); ccr 0xC0"),
    (8, "PDC_IODC", 0xF0013BF8, "0 read (2/4 -> -2)", "IODC directory 0xF0028800 + per-device probe/patching"),
    (9, "PDC_TOD", 0xF00153A8, "0 read, 1 write, 2 calibrate", "LASI RTC 0xF0109000; calibrate = CPU MHz as double"),
    (10, "PDC_STABLE", 0xF00129D0, "0-4; 1000-1004 with ARG4=-1000",
     "EEPROM 0xF00C1000: 256 B, two copies + checksum/count rings; 1000+: HV area 0xF00C1200"),
    (11, "PDC_NVOLATILE", None, "", "-1"),
    (12, "PDC_ADD_VALID", 0xF0011BA0, "0; 1000 (byte probe)", "real probe load under probe IVA; 0xFFFB0000-0xFFFBDFFF -> 1"),
    (13, "(13)", None, "", "-1"), (14, "PDC_DEBUG", None, "", "-1"), (15, "PDC_INSTR", None, "", "-1"),
    (16, "(16)", None, "", "-1"), (17, "(17)", None, "", "-1"),
    (18, "PDC_BLOCK_TLB", 0xF0011D38, "0 info, 1 insert, 2 purge, 3 purge all",
     "info min 0x80 pages, max 0x4000 pages, 8 combined; insert/purge via DR8 + idtlba"),
    (19, "PDC_TLB", 0xF00151F0, "0 info, 1 setup", "hardware TLB-miss walker: DR24/DR25, shadow in Page Zero 0xE4"),
    (20, "(20)", None, "", "-1"),
    (21, "PDC_PSW", 0xF0015150, "0 mask, 1 get, 2 set", "DR0 bit 23 (default endianness)"),
    (22, "PDC_SYSTEM_MAP", None, "", "-1"),
    (23, "PDC_SOFT_POWER", 0xF0013B00, "0 info, 1 enable", "LASI PCR 0xF010C000 bit 31; DR25 bit 0"),
    (128, "PDC_MEM_MAP", 0xF0013650, "0", "path -> HPA table (see memmap)"),
    (129, "PDC_EEPROM", 0xF00134B8, "0 rd word, 1 wr word, 2 rd byte, 3 wr byte",
     "offset < 0x2000; 0x1000-0x13FF needs ARG4 = -1000"),
    (130, "(130, EISA support)", 0xF00124A0, "0,1,2,3,5,6",
     "EISA base 0xFC000000, byte 0xFC010001, map window regs 0xFC100000+0x1000n, call 0xF0003DDC"),
    (136, "PDC_BROADCAST_RESET", 0xF0012040, "0", "LASI AMR=3, IMR=0, IO_COMMAND(0xFFFC0030)=5, spin"),
    (137, "(137)", None, "any", "returns 0 (stub)"),
    (138, "PDC_LAN_STATION_ID", 0xF0013580, "0", "ARG3=HPA: 0xF0107000 -> EEPROM 0x16B4, 0xF0507000 -> 0x16BA"),
]

# ---------------------------------------------------------------------------
# EEPROM (0xF00C0000, 8 KB).  Offsets relative to 0xF00C0000.
# ---------------------------------------------------------------------------
EEPROM_MAP = [
    (0x0400, 12, "init_ffff", "written 0xFFFFFFFF x3 at first-boot init (0xF00005A0)"),
    (0x1000, 0x100, "stable_A", "PDC_STABLE copy A (architected 256-byte layout)"),
    (0x1100, 0x100, "stable_B", "PDC_STABLE copy B"),
    (0x1200, 0x100, "hv_area", "PDC_STABLE options 1000-1004 (password -1000): PDC_MODEL words, model strings"),
    (0x1300, 0x50, "ring_A", "10 x {checksum, write count} for copy A; moves on at the count threshold"),
    (0x1350, 0x50, "ring_B", "same for copy B"),
    (0x13A0, 0x50, "ring_HV", "same for the HV area"),
    (0x1400, 0x164, "pim_hpmc", "HPMC PIM (PDC_PIM 0), written by the HPMC path (0xF0004410..)"),
    (0x1564, 0x130, "pim_toc", "TOC PIM (PDC_PIM 4)"),
    (0x1694, 1, "chassis_mfg", "0xB0 chassis codes on; bit 0 = manufacturing mode; 0xFF off. First-boot value 0xB1"),
    (0x1695, 1, "fastboot", "BCH 'fastboot' (1 = on: short memory test, no I/O self-test); 0 at first boot"),
    (0x1696, 1, "secure", "BCH 'secure': no ESC interrupt of autoboot, no 'Press <ESCAPE>' banner; 0 at first boot"),
    (0x1699, 1, "diagnostic_boot", "BCH 'diagnostic_boot'; 1 at first boot; read at reset 0xF0001A64 and at launch"),
    (0x169C, 4, "lpt_cfg?", "word written with the identity (0xF002028C); read by PDC_IODC for 0xF0102000"),
    (0x16A4, 8, "pim_hpmc_ctr", "HPMC PIM sequence counters"),
    (0x16AC, 8, "pim_toc_ctr", "TOC PIM sequence counters"),
    (0x16B4, 6, "lan_addr_1", "LASI LAN station address; first-boot 08:00:09:EE:EE:EE"),
    (0x16BA, 6, "lan_addr_2", "LASI#2 LAN station address; first-boot 08:00:09:FF:FF:FF"),
    (0x16C0, 10, "serial_num", "board serial number (BCH 'serial_num')"),
    (0x16CA, 1, "monitor_gfx1", "monitor type for built-in graphics (path mod 1)"),
    (0x16D0, 1, "system_type", "read by the identity builder 0xF00202D0"),
    (0x16D4, 1, "monitor_gfx0", "monitor type, GSC slot 0xF4000000 (mod 0)"),
    (0x16D5, 1, "monitor_gfx3", "monitor type, GSC slot 0xF6000000 (mod 3)"),
    (0x16D6, 1, "monitor_gfx7", "monitor type, GSC slot 0xFA000000 (mod 7)"),
    (0x16D8, 1, "identity_valid", "'G' (0x47) once the HV area is built; 'U' = rebuild without re-initialising stable storage"),
    (0x16D9, 1, "eeprom_valid", "'N' (0x4E) once first-boot defaults are written; anything else -> re-init (0xF0000338)"),
    (0x16DA, 1, "eeprom_valid2", "'Y' (0x59)"),
    (0x1E04, 4, "init_1e04", "0xFFFFFFFF at first boot"),
    (0x1E0C, 4, "init_1e0c", "1 at first boot"),
]

# ---------------------------------------------------------------------------
# Parsers
# ---------------------------------------------------------------------------


def _w(data, a):
    o = a - ROM_BASE
    return struct.unpack(">I", data[o:o + 4])[0]


def _h(data, a):
    o = a - ROM_BASE
    return struct.unpack(">H", data[o:o + 2])[0]


def hsum(data, a, b):
    """16-bit sum of big-endian halfwords over [a, b)."""
    blk = data[a - ROM_BASE:b - ROM_BASE]
    return sum(struct.unpack(">%dH" % (len(blk) // 2), blk)) & 0xFFFF


IODC_ENTRY_NAMES = {3: "ENTRY_INIT", 4: "ENTRY_IO", 5: "ENTRY_SPA", 6: "ENTRY_CONFIG", 8: "ENTRY_TEST", 9: "ENTRY_TLB"}
IODC_DEVICE_NAMES = {
    0xFFFBE000: "CPU (PA-7100LC)", 0xFFFBF000: "memory (MIOC)", 0xF0100000: "LASI core BA",
    0xF0500000: "LASI#2 BA (optional, HV 0x018)", 0xF0102000: "LASI Centronics", 0xF0105000: "LASI RS-232 (port A)",
    0xF0505000: "LASI#2 RS-232", 0xF0202000: "WAX RS-232 (port B)", 0xF4000000: "GSC graphics slot (mod 0)",
    0xF6000000: "GSC graphics slot (mod 3)", 0xF8000000: "built-in Artist", 0xFA000000: "GSC graphics slot (mod 7)",
    0xF0106000: "LASI SCSI 53C710", 0xF0506000: "LASI#2 SCSI", 0xF0107000: "LASI LAN i82596",
    0xF0507000: "LASI#2 LAN", 0xF0108000: "LASI PS/2 port 0 (keyboard)", 0xF0108100: "LASI PS/2 port 1 (mouse)",
    0xF0104000: "LASI Harmony audio", 0xF0104040: "audio-option RJ-16", 0xF0104060: "audio-option RJ-16",
    0xF0104070: "audio-option ISDN", 0xF010A000: "LASI floppy", 0xF04BE000: "X.25 option on LASI#2 bus",
    0xF0200000: "WAX BA", 0xF0201000: "WAX HIL", 0xFC000000: "WAX EISA BA", 0xFFF88000: "FW-SCSI slot",
    0xFFF8C000: "FW-SCSI slot", 0xFFF94000: "FW-SCSI slot",
}


def parse_iodc(data, base=IODC_DIR):
    """Return (directory, modules).  directory: [(hpa, offset, module_addr)].
    modules: {module_addr: dict(hpas, hversion, spa, type, sversion, rev, dep, features, check, length,
    header_ok, entries=[dict(word, index, name, addr, check, length, end, ok)])}"""
    directory = []
    a = base
    while True:
        hpa, off = _w(data, a), _w(data, a + 4)
        if hpa == 0 and off == 0:
            break
        directory.append((hpa, off, base + off))
        a += 8
    mods = {}
    for hpa, off, m in directory:
        d = mods.setdefault(m, {"hpas": []})
        d["hpas"].append(hpa)
    for m, d in mods.items():
        d.update(hversion=_h(data, m), spa=data[m - ROM_BASE + 2], type=data[m - ROM_BASE + 3],
                 sversion=_w(data, m + 4), entries=[])
        d["more"] = bool(d["type"] & 0x80)
        d["size"] = 8
        if d["more"]:
            rev, dep, feat = data[m - ROM_BASE + 8:m - ROM_BASE + 11]
            d.update(rev=rev, dep=dep, features=feat, check=_h(data, m + 12), length=_h(data, m + 14))
            d["size"] = 16 + 4 * d["length"]
            d["header_ok"] = hsum(data, m, m + d["size"]) == 0
            for i in range(d["length"]):
                e = _w(data, m + 16 + 4 * i)
                ea = m + 4 * (e & 0xFFFFFF)
                ln = _h(data, ea + 2)
                end = ea + 4 + 4 * ln
                d["entries"].append(dict(word=e, index=e >> 24, name=IODC_ENTRY_NAMES.get(e >> 24, "?"),
                                         addr=ea, check=_h(data, ea), length=ln, end=end,
                                         ok=hsum(data, ea, end) == 0))
    return directory, mods


MON_FLAGS = [(31 - 0, "vesa"), (31 - 1, "grey"), (31 - 2, "dbl"), (31 - 3, "user"), (31 - 4, "stereo"), (31 - 5, "sam")]
STI_ROUTINES = ["INIT_GRAPH", "STATE_MGMT", "FONT_UNPMV", "BLOCK_MOVE", "SELF_TEST", "EXCEP_HDLR", "INQ_CONF",
                "SET_CM_ENTRY", "DMA_CTRL", "FLOW_CTRL", "USER_TIMING", "PROCESS_MGR", "STI_UTIL", "END"]


def sti_crc(bs):
    """CRC from Sti.txt section 7.3 (poly 0x8408, rotate-left variant); 0 = good."""
    accum = code = 0
    for j, c in enumerate(bs):
        accum = ((accum << 8) | c) & 0xFFFF
        if j & 1:
            accum ^= code
            for _ in range(16):
                if accum & 0x8000:
                    accum = (((accum << 1) | 1) & 0xFFFF) ^ 0x8408
                else:
                    accum = (accum << 1) & 0xFFFF
            code = accum
    return code


def parse_sti(data, base=STI_BASE):
    o = base - ROM_BASE
    s = dict(base=base, type=data[o:o + 4].hex(), num_mons=data[o + 5], revno=(data[o + 6], data[o + 7]),
             graphics_id=(_w(data, base + 8), _w(data, base + 12)),
             font_start=_w(data, base + 0x10), statesize=_w(data, base + 0x14), last_addr=_w(data, base + 0x18),
             region_list=_w(data, base + 0x1C), reentsize=_h(data, base + 0x20), maxtime=_h(data, base + 0x22),
             mon_tbl_addr=_w(data, base + 0x24), user_data_addr=_w(data, base + 0x28),
             sti_mem_req=_w(data, base + 0x2C), user_data_size=_w(data, base + 0x30), power=_h(data, base + 0x34),
             bus_support=data[o + 0x36], ext_bus_support=data[o + 0x37], alt_code_type=data[o + 0x38],
             cfb_addr=_w(data, base + 0x3C))
    s["routines"] = [(n, _w(data, base + 0x40 + 4 * i)) for i, n in enumerate(STI_ROUTINES)]
    s["routine_addrs_c0"] = [_w(data, base + 0xC0 + 4 * i) for i in range(16)]
    regions = []
    a = base + s["region_list"]
    for i in range(8):
        v = _w(data, a + 4 * i)
        regions.append(dict(raw=v, offset=(v >> 18) << 12, sys_only=(v >> 17) & 1, cache=(v >> 16) & 1,
                            btlb=(v >> 15) & 1, last=(v >> 14) & 1, length=(v & 0x3FFF) << 12))
        if v & (1 << 14):
            s["region_future_ptr"] = _w(data, a + 4 * (i + 1))
            break
    s["regions"] = regions
    mons = []
    for i in range(s["num_mons"]):
        w0, w1 = _w(data, base + s["mon_tbl_addr"] + 8 * i), _w(data, base + s["mon_tbl_addr"] + 8 * i + 4)
        flags = [n for b, n in MON_FLAGS if w1 & (1 << b)]
        if w0 & 1:
            flags.insert(0, "flat")
        rec = base + 0x328 + 0x60 * i
        mons.append(dict(x=w0 >> 20, y=(w0 >> 8) & 0xFFF, hz=(w0 >> 1) & 0x7F, flags=flags, index=w1 & 0xFF,
                         record=rec, pixclk=_w(data, rec + 0x54), clksel=_w(data, rec + 0x58),
                         timing=data[rec - ROM_BASE + 0x30:rec - ROM_BASE + 0x3C].hex()))
    s["monitors"] = mons
    f = base + s["font_start"]
    first, last = _h(data, f), _h(data, f + 2)
    fo = f - ROM_BASE
    s["font"] = dict(addr=f, first=first, last=last, width=data[fo + 4], height=data[fo + 5], type=data[fo + 6],
                     bytes_per_char=data[fo + 7], next=_w(data, f + 8), ul_height=data[fo + 12],
                     ul_offset=data[fo + 13], glyphs=f + 16)
    s["crc_ok"] = sti_crc(data[o:o + s["last_addr"] + 1]) == 0
    s["crc"] = _h(data, base + s["last_addr"] - 1)
    return s


# ---------------------------------------------------------------------------
# Re-derivations from code (need objdump through romlib)
# ---------------------------------------------------------------------------


def bl_target(pc, insn):
    """Target of a PA-RISC B,L (opcode 0x3A) with a 17-bit displacement."""
    w1, w2, w = (insn >> 16) & 0x1F, (insn >> 2) & 0x7FF, insn & 1
    disp = (w << 16) | (w1 << 11) | ((w2 & 1) << 10) | (w2 >> 1)
    if w:
        disp -= 1 << 17
    return (pc + 8 + (disp << 2)) & 0xFFFFFFFF


def derive_pdc_table(data):
    """Jump table 0xF00128AC (indices 0..23, 8 bytes each) and the >=24 compare chain."""
    table = []
    jt = 0xF00128AC
    for i in range(24):
        insn = _w(data, jt + 8 * i)
        tgt = bl_target(jt + 8 * i, insn)
        bad = tgt == 0xF0015510   # common exit: the delay slot loads -1
        table.append((i, None if bad else tgt))
    ext = []
    insns = [x for x in romlib.disassemble() if 0xF0012978 <= x.addr < 0xF00129D0]
    last = None
    for ins in insns:
        m = ins.mnem.split(",")[0]
        if m == "ldi" and ins.ops.endswith("ret0"):
            last = int(ins.ops.split(",")[0], 16)
        elif m == "cmpb" and "ret0,r26" in ins.ops and last is not None:
            eq = ins.mnem.startswith("cmpb,=")
            # cmpb,= branches to the handler; cmpb,<> falls through into it (after the delay slot)
            tgt = romlib.branch_targets(ins)[0] if eq else ins.addr + 8
            ext.append((last, tgt, eq))
    return table, ext


def derive_mem_map():
    """PDC_MEM_MAP: decode 0xF0013680..0xF0013AF0 into [(path_class, key, hpa, more_pgs)]."""
    insns = [x for x in romlib.disassemble() if 0xF0013680 <= x.addr < 0xF0013AF0]
    resolved = list(romlib.resolve(insns))
    # class dispatch: ldh 4(r23) compared with constants (halfword bc3,bc4)
    classes = {}
    pending = None
    for ins, note in resolved:
        if ins.mnem == "ldo" and ins.ops.endswith("r31") and "const" in note and 0xF800 <= note["const"] <= 0xFFFF:
            pending = note["const"]
        elif ins.mnem.startswith("cmpb,=") and "r31,ret1" in ins.ops and pending is not None:
            classes[romlib.branch_targets(ins)[0]] = {0xFFFF: "native (bc all FF)", 0xFF02: "bc ..FF/2 (LASI)",
                                                      0xFF06: "bc ..FF/6 (LASI#2)", 0xFF05: "bc ..FF/5 (WAX)",
                                                      0xFF04: "bc ..FF/4 (EISA slot)"}.get(pending, hex(pending))
            pending = None
    out = []
    cur = None
    key = None
    hpa = None
    starts = sorted(classes)
    for ins, note in resolved:
        for s in starts:
            if ins.addr == s:
                cur = classes[s]
        m = ins.mnem.split(",")[0]
        if m == "cmpib" and "ret1" in ins.ops:
            key = int(ins.ops.split(",")[0], 16)
            hpa = None
        elif m == "addi" and ins.ops.endswith("r31") and "const" in note:
            key = note["const"]
        elif (m in ("ldil", "ldo")) and ins.ops.endswith("r31") and "const" in note:
            hpa = note["const"]
        elif m == "depw" and "ret1,19,4,r31" in ins.ops:
            hpa = "0xFC00n000 (n = mod 1..15)"
        elif m == "ldo" and ins.ops.endswith("ret1") and "(ret1)" in ins.ops and hpa is not None:
            more = int(ins.ops.split("(")[0], 16)
            if key is not None:
                out.append((cur, key, hpa, more))
            hpa = None
    return out


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------


def report_regions(tsv=None):
    rows = []
    for a, b, k, n, note in REGIONS:
        rows.append("%08x\t%08x\t%6d\t%-9s\t%-28s\t%s" % (a, b, b - a, k, n, note))
    if tsv:
        with open(tsv, "w") as f:
            f.write("start\tend\tsize\tkind\tname\tnote\n")
            for a, b, k, n, note in REGIONS:
                f.write("%08x\t%08x\t%d\t%s\t%s\t%s\n" % (a, b, b - a, k, n, note))
    print("\n".join(rows))


def report_iodc(data):
    directory, mods = parse_iodc(data)
    print("IODC directory at %08x: %d entries" % (IODC_DIR, len(directory)))
    for hpa, off, m in directory:
        print("  %08x  +%05x -> %08x  %s" % (hpa, off, m, IODC_DEVICE_NAMES.get(hpa, "?")))
    for m in sorted(mods):
        d = mods[m]
        sv = d["sversion"]
        print("module %08x HV %#06x (model %#05x) SPA %#04x TYPE %#04x (%s type %d) SVERSION %#010x (model %#x opt %#x)"
              % (m, d["hversion"], d["hversion"] >> 4, d["spa"], d["type"], "16+B" if d["more"] else "8 B",
                 d["type"] & 0x1F, sv, (sv >> 8) & 0xFFFFF, sv & 0xFF))
        if d["more"]:
            print("    REV %#x DEP %#x FEATURES %#x CHECK %#06x LENGTH %d  header+table sum %s"
                  % (d["rev"], d["dep"], d["features"], d["check"], d["length"], "ok" if d["header_ok"] else "BAD"))
        for e in d["entries"]:
            print("    %-10s word %08x -> %08x  check %#06x len %#x words, declared end %08x  sum %s"
                  % (e["name"], e["word"], e["addr"], e["check"], e["length"], e["end"], "ok" if e["ok"] else "BAD"))


def report_sti(data):
    s = parse_sti(data)
    print("STI image at %08x: type %s, %d monitors, rev %d.%d, graphics_id %08x %08x"
          % (s["base"], s["type"], s["num_mons"], s["revno"][0], s["revno"][1], *s["graphics_id"]))
    for k in ("font_start", "statesize", "last_addr", "region_list", "reentsize", "maxtime", "mon_tbl_addr",
              "user_data_addr", "sti_mem_req", "user_data_size", "power", "bus_support", "alt_code_type", "cfb_addr"):
        print("  %-15s %#x" % (k, s[k]))
    print("  CRC %#06x at +%#x -> %s" % (s["crc"], s["last_addr"] - 1, "ok" if s["crc_ok"] else "BAD"))
    for n, v in s["routines"]:
        if v:
            print("  %-12s +%#06x  %08x" % (n, v, s["base"] + v))
    for i, r in enumerate(s["regions"]):
        print("  region %d raw %08x: HPA+%#09x len %#09x sys_only %d cache %d btlb %d last %d"
              % (i, r["raw"], r["offset"], r["length"], r["sys_only"], r["cache"], r["btlb"], r["last"]))
    for i, m in enumerate(s["monitors"]):
        print("  monitor %2d (BCH type %2d): %4dx%-4d %3d Hz %-10s rec %08x pixclk %11d Hz clksel %#x timing %s"
              % (i, i + 1, m["x"], m["y"], m["hz"], ",".join(m["flags"]) or "-", m["record"], m["pixclk"],
                 m["clksel"], m["timing"]))
    f = s["font"]
    print("  font at %08x: chars %d-%d, %dx%d, type %d, %d bytes/char, next %#x, underline %d at %d, glyphs %08x"
          % (f["addr"], f["first"], f["last"], f["width"], f["height"], f["type"], f["bytes_per_char"], f["next"],
             f["ul_height"], f["ul_offset"], f["glyphs"]))


def report_pdc(data):
    table, ext = derive_pdc_table(data)
    names = {p[0]: p for p in PDC_PROCS}
    print("PDC entry %08x; jump table 0xF00128AC" % PDC_ENTRY)
    for i, t in table:
        p = names.get(i)
        print("  %3d %-20s %s" % (i, p[1] if p else "-", ("%08x" % t) if t else "-1"))
    for k, t, eq in ext:
        p = names.get(k)
        print("  %3d %-20s %08x" % (k, p[1] if p else "?", t))
    for p in PDC_PROCS:
        if p[2] is None:
            continue
        ok = any(t == p[2] for _, t in table) or any(t == p[2] for _, t, _ in ext)
        if not ok:
            print("  !! static table disagrees for", p[1])


def report_memmap():
    for cls, key, hpa, more in derive_mem_map():
        h = ("%08x" % hpa) if isinstance(hpa, int) else hpa
        print("  %-24s key %#4x -> %s  more_pgs %#x" % (cls, key, h, more))


def report_eeprom():
    for off, size, name, note in EEPROM_MAP:
        print("  %08x %#06x %5d  %-16s %s" % (0xF00C0000 + off, off, size, name, note))


def check(data):
    ok = True
    _, mods = parse_iodc(data)
    for m, d in mods.items():
        if d["more"] and not d["header_ok"]:
            print("IODC header sum BAD at %08x" % m)
            ok = False
        for e in d["entries"]:
            if not e["ok"]:
                print("IODC entry sum BAD at %08x" % e["addr"])
                ok = False
    s = parse_sti(data)
    if not s["crc_ok"]:
        print("STI CRC BAD")
        ok = False
    n = len(data) // 4
    total = sum(struct.unpack(">%dI" % n, data[:n * 4]))
    print("image 64-bit additive word sum %#x (IMAGE1A header 0x3C/0x40 = 0x5790 / 0xA8BB80FC)" % total)
    prev = ROM_BASE
    for a, b, *_ in REGIONS:
        if a != prev:
            print("region gap/overlap at %08x" % a)
            ok = False
        prev = b
    print("all checks passed" if ok else "CHECK FAILED")
    return ok


def main(argv):
    args = argv[1:]
    rom = romlib.DEFAULT_ROM
    if args and os.path.isfile(args[0]):
        rom = args.pop(0)
    data = romlib.load(rom)
    cmd = args[0] if args else "regions"
    if cmd == "regions":
        tsv = args[args.index("--tsv") + 1] if "--tsv" in args else None
        report_regions(tsv)
    elif cmd == "iodc":
        report_iodc(data)
    elif cmd == "sti":
        report_sti(data)
    elif cmd == "pdc":
        report_pdc(data)
    elif cmd == "memmap":
        report_memmap()
    elif cmd == "eeprom":
        report_eeprom()
    elif cmd == "check":
        sys.exit(0 if check(data) else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
