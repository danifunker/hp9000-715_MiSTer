# 06 -- What HP-UX 10.20 and Linux need from the 715 hardware and firmware

Status: review, 2026-10-07. Evidence comes from the real OS binaries (the HP-UX 10.20
kernel taken out of the tenox disk image and disassembled with its symbol table),
from HP-UX booting under QEMU with every PDC call logged, from the Linux 5.15
source, and from the HP architecture documents.

> **Correction (review 07, 2026-10-07):** the PDC_SOFT_POWER advice in s.0 item 8,
> s.2.2 row 23, s.3.1, s.3.7 and the summary tables ("make SOFT_POWER fail", "no
> DIAG on a PCX-L") is out of date. HP's PDC 1.6 never fails that call, so HP-UX
> always polls DR25 bit 0 with MFCPU_T (0x1720141C) at 4 Hz, and so does Linux at
> CPU revision != 0. See `07-hpux-cpu-specifics.md` s.1.4 and s.5.

**How to read the citations**

| Prefix | Meaning |
|---|---|
| `sym`@0xADDR | HP-UX 10.20 `/stand/vmunix` (B.10.20 #1, Jun 9 1996): the symbol, and the address of the instruction or data. Reproduce with `tools/hpux/som.py roms/hpux/vmunix dis --func sym`. |
| **obs** `file` | QEMU 11.1.1 run logs in the session scratchpad, `keep/qemu/logs-os/` (listed in `keep/INDEX.md`) |
| L `path:line` | Linux 5.15.1, `~/repos/Linux-Kernel_MiSTer` |
| `Doc:line` | `docs/reference/txt/`. Short names: **P11** `Pdc11-v0.96-Ch1-procs.txt`, **IODC** `Pdc11-v0.96-Ch3-IODC.txt`, **PDCE** `Pdc20-v1.1-Ch3-pdce.txt`, **OSI** `Pdc20-v1.1-Ch6-os_interface.txt`, **FMT** `pdc20-v1.1-Ch8-data_formats.txt`, **OVW** `pdc20-v1.1-Ch2-overview.txt`, **ACD** `Pa11_acd.txt`, **LASI** `Lasi_ers.txt`, **SOM** `Pa-runtime-32-SOM.txt`, **MMWP** `199704_5965-4641_HP-UX_Memory_Management_White_Paper_Version_1.3.txt`, **PERIPH** `199501_B2355-90053_HP-UX_10.0_Configuring_HP-UX_for_Peripherals.txt` |
| **PCXL** | PA7100LC ERS. That PDF is in reverse page order, so lines are cited in the forward-ordered copy `keep/doc-review-text/pcxl_fwd.txt` with the ERS section number. |
| `715_64.h` | `qemu-src/roms/seabios-hppa/src/parisc/715_64.h`: PDC data dumped from a real 715/64 by Linux |

---

## 0. The short version

These are the things the two kernels depend on that the FPGA must get exactly right. Each
one is backed by evidence in the sections below.

1. **CPU identity comes from PDC, and the PDC values decide the code path.**
   - On a 715, PDC_MODEL `CPU_ID` fails, as it does on the real machine (`715_64.h:36`).
   - HP-UX then classifies the CPU by the number of fixed block-TLB slots that PDC_BLOCK_TLB returns: **8 means PCX-L**, 16 means PCX-T (`set_machine_parameters`@0x179658).
   - QEMU reports 16, so on `-M 715` HP-UX runs its **PCX-T** code paths. That is why QEMU logs the PCX-T diagnose `0x141c1a00`.
   - Linux identifies the CPU from PDC_MODEL `hversion` (0x60A → pcxl), and panics if the bus-id field is not one it knows.
2. **Shadow registers and `RFI,R` must be exact.** Both kernels' TLB miss handlers use only GR1/8/9/16/17/24/25 and never save them, so `RFIR` must restore them (§3.2).
3. **TLB miss handling.**
   - HP-UX keeps a hashed page directory whose 16-byte entry format is the one the **PCX-L hardware walker** reads.
   - If PDC_TLB returns OK, HP-UX enables the walker with `cr28` mode 2 and patches its DTLB-miss vector to read CR28. From then on the walker, and its CR28 contract, are mandatory.
   - If PDC_TLB fails, HP-UX falls back to software handlers. Linux never uses the walker.
   - Choose one: PDC_TLB = -1 and no walker, or a walker exactly as PCXL §6.7 describes.
4. **PDC_CACHE drives everything that flushes.** HP-UX and Linux both run the architected FDCE/FICE loops and PDTLBE/PITLBE loops from its numbers. With the real 715's numbers (1 × PxTLBE, 4096 × 32-byte cache lines), **one PDTLBE must purge the whole TLB**.
5. **Interval timer.** CR16 must count at exactly `PAGE0 MEM_10MSEC × 100` Hz. Writing CR16 sets the compare value, and a match sets EIRR bit 0. Both kernels take HZ=100 from MEM_10MSEC (§3.6).
6. **Interrupt transactions.**
   - A 32-bit write of data *n* to the CPU HPA sets EIRR bit *n*, in big-endian numbering.
   - HP-UX gives LASI EIRR bit 3 (it writes LASI IAR = HPA|3). Linux gives it bit 1 or 2.
   - HP-UX treats an **unclaimed LASI "external interrupt" (GSC bit 21) as the TOC button**: it writes CMD_RESET (5) to the CPU's IO_COMMAND (HPA+0x30), which should act as a TOC. Never raise that bit spuriously; Artist must not interrupt (§4.1, §4.6).
7. **Firmware interfaces HP-UX uses beyond the basics:**
   - PDC_MEM_MAP (128) for every module.
   - PDC_IODC options 3 and 4, which copy console and boot ENTRY_INIT/ENTRY_IO into RAM; HP-UX later calls them for panic messages and crash dumps.
   - PDC_INITIATOR (163) for the SCSI ID.
   - PDC_MODEL `ENSPEC`. HP-UX warns if it fails.
   - PDC_PSW set-defaults.
   - PDC_ADD_VALID.
   - MEM_TOC registration with TOC_LEN = 0.
8. **Not needed by either kernel:** MAX-1 halfword instructions, PCX-L fast TLB inserts (IxTLBAF/PF), SPOP, little-endian mode, and any PA 2.0 instruction. HP-UX 10.20 executes **no DIAG** on a PCX-L, unless PDC_SOFT_POWER reports a "Gecko" switch; Linux has the same exception. Linux otherwise executes exactly one pair, `mfdiag/mtdiag dr0`, to clear space-ID hashing.
9. **I/O devices.** The device sections (§4) list the exact register behaviour each driver relies on. The biggest items:
   - 53C710 SCRIPTS completeness: SIGP / WAIT RESELECT, register read/write, memory move, LCRC, and a live DSTAT.DFE. QEMU's missing DFE is the second reason HP-UX fails on `-M 715` (§4.2, 06d).
   - LASI IRR read-to-clear and IAR re-signalling.
   - Harmony's self-clearing CNTL.C bit (for Linux and audio-enabled HP-UX kernels).
   - An Artist STI image with a **valid CRC** (HP-UX checks it), and the NGLE registers stifb touches.

The kernel on this disk was generated for a B160L. Its `/stand/system` lists graph3, GSCtoPCI, c720, sdisk, sctl, asio0, CentIf, ps2, btlan3 and so on, with no `lan2`. So it has **no i82596 LAN driver**. The other 715 drivers (lasi, wsio/core, c720, asio0, CentIf, ps2, graph3/sti/framebuf/ite) are installed. `audio` and `hil` are linked in but **not installed** (§4.0). A 715-specific kernel would add `lan2` from `/usr/conf/lib` on the VxFS root, which `tools/hpux` cannot read yet (§7).

---

## 1. Getting the HP-UX kernel out of the image

No root, no loop mounts, and the image is never written. The readers are in `tools/hpux/`:

| Tool | What it does |
|---|---|
| `qcow2.py` | Random read access to qcow2 (v2/v3, zlib clusters, unallocated reads as zeroes) or raw images. No conversion; nothing was copied to a raw file. |
| `hpdisk.py` | LIF volume directory; LVM boot disk (`LVMREC01` at 8 KiB plus the LIF `LABEL` file, which gives start/length of boot, root, swap and dump in KiB); HFS (4.2BSD FFS with HP magics 0x011954/0x095014) `ls` and `cat`. |
| `som.py` | SOM header, aux header, spaces/subspaces, symbol table; symbol-annotated objdump disassembly (resolves linker long-branch stubs, `addil`/`ldil`+`ldo` data references and strings); call-site finder with constant-argument recovery (`calls NAME --args N`). |

**What the image looks like** (`hpdisk.py IMAGE lif` / `layout`):
- LIF volume "ISL10" with ISL (IPL entry 0xAE28), AUTO ("hpux"), HPUX, PAD and LABEL.
- LVM physical volume; the LABEL file gives the areas:

  | Area | Disk offset | Size | Filesystem |
  |---|---|---|---|
  | boot (/stand) | 0x2D8000 | 48 MiB | HFS, long names |
  | root | 0x232D8000 | 3.4 GiB | **VxFS** (magic 0xA501FCF5) |
  | swap and dump | 0x32D8000 | 512 MiB | -- |

**Extracted to `roms/hpux/`** (now in `.gitignore`):
- `vmunix` (10,046,568 B) and `vmunix.prev`
- `system` and `system.prev`
- `ioconfig`, `bootconf`, `kernrel`, `rootconf`
- `lif-{ISL,HPUX,AUTO,LABEL}`
- `vmunix.syms`: all 15,402 symbols
- `vmunix.dis`: annotated disassembly of all text, 64 MB

**The kernel** (`som.py info`):
- SOM `EXEC_MAGIC`, system_id 0x20B.
- Text 0x11000-0x3D720C (3,957,260 B); data 0x3D8000 (450,560 B); bss 593,184 B. These match the loader's "3957260 + 450560 + 593184".
- Entry `rdb_bootstrap`@0x18FE68; dp = `$global$` = 0x4450A0.
- Text subspaces: `$GATEWAY$` (0x14000), `$MILLICODE$`, `$TLB$` (0x18000, IVA tables and miss handlers), `$TRAP$`, `$CODE$`.
- Carries full symbolic debug info (`$GNTT$` 3.6 MB).

---

## 2. Firmware interface (PDC, IODC, Page Zero)

### 2.1 Handoff to the kernel

**State at kernel entry**, captured with `-d int` on `-M 715` (`keep/qemu/logs/hpux-715-inasm-int.trace.gz`, first RFI):
- The `hpux` loader enters the kernel by RFI with **PSW = Q only** (real mode, I=0) at space 0, offset 0x18FE68.
- GR26 = 1, GR25 = argv, GR24 = envp, all physical; CR7 = 0xFFFB0000 (QEMU's CPU HPA).
- This matches the architected IPL/OS state: PL0, Q=1, everything else 0, TLB invalid, HW miss handler off (PDCE:1254-1356).

**What the kernel does first** (`rdb_bootstrap`@0x18FE68 → `$locore`@0x18FFEC → `realmain`@0x158CE0):
1. `rsm` I and finds dp position-independently.
2. EIRR ← 0xFFFFFFFF (clears all pending).
3. IVA ← `mp_iva0`.
4. CR24 ← `mpproc_info`; SR4 ← 0.
5. Clears bss.
6. Records `boot_flags`.
7. Takes **`pdc_entry` = PAGE0 MEM_PDC (0x388)** (@0x18FF48).
8. CR10 (CCR) ← 0; EIRR cleared again; `ssm` I (EIEM is still 0).
9. Calls `realmain`.

`realmain` immediately (@0x158D20-0x158D8C):
- Writes **MEM_TOC (0x008) = `TOC_Vector`@0x25E930 and MEM_TOC_LEN (0x00C) = 0**. A length of 0 is legal (FMT:195-198).
- Derives the clock from **MEM_10MSEC (0x38C)**: `iticks_per_10_msec` = MEM_10MSEC, `itick_per_usec` = MEM_10MSEC/10000, `itick_per_tick` = MEM_10MSEC (HZ=100).

**Linux** (L `arch/parisc/kernel/head.S:44-292`):
- Expects real mode, with the kernel loaded at physical 0x100000 (linked at 0x10100000).
- r26..r23 = free-mem / cmdline / initrd. If r26 < 64, Linux assumes the HP-UX loader.
- The PA1.1/2.0 test is `mtctl 32,%cr11; mfctl,w %cr11`, which must read back 0 (L `head.S:250-258`). So the PCX-L must decode the `mfctl,w` form as `mfctl` and have a **5-bit SAR**.
- Linux reads PAGE0 MEM_PDC, MEM_10MSEC, `imm_max_mem` (0x39C, its **only** memory-size source), MEM_CONS/MEM_KBD, MEM_FREE and `proc_sti` (0x604).
- It treats `"SeaBIOS"` at 0x40 as "running on QEMU" (L `setup.c:387`), which changes TLB flushing and other behaviour. Real firmware must not put that string there.

### 2.2 PDC procedures: what each OS calls

**How HP-UX makes the call:**
- The wrapper `pdc_call(proc, option, ...)`@0x137EA8 enters real mode through `os_pdce_proc`@0x25D170: it saves CR24/CR25, does an RFI-based mode switch, and BE,L to `pdc_entry`.
- Two more wrappers exist:
  - `hversion_pdc_call`@0x158328, for HVERSION-dependent procedures ≥ 128.
  - `dump_pdc_call`@0x24E920, used by the IODC console, crash-dump and reboot code.
- Call sites with constant arguments were recovered with `som.py calls … --args 2`.

**Observed calls.** The "obs" columns come from **obs** `hpux-715-pdcdebug.log` (`-M 715`, up to the SCSI panic) and `hpux-B160L-pdcdebug.log` (B160L, up to the login prompt). The ISL/loader phase (before "start 0x18fe68") calls CHASSIS 0, IODC 0, MODEL 0, STABLE 0, NVOLATILE 0/1, TOD 0, CACHE 0 and ADD_VALID 0.

| # / opt | Name | HP-UX caller (static) | obs 715 | obs B160L | Linux (5.15, 32-bit) | Requirement |
|---|---|---|---|---|---|---|
| 1 | POW_FAIL | -- | -- | -- | -- | not used |
| 2/0 | CHASSIS display | `put_chassis`@0x164CDC, `iodc_put_chassis`@0x1FD84C | yes | yes | compiled out | OK; drive the LEDs (§4.1) |
| 2/1 | CHASSIS warnings | `getcpuinfo`@0x137D2C (polls `pdc_warnings`) | -- | yes | `pdc_chassis.c:258` | return 0 warnings |
| 2/128 | CHASSIS info | `display_init`@0x26F1C4 | -- | yes | `led.c:705` | may fail; Linux then uses the LASI LED register |
| 3/1, 3/2 | PIM size / LPMC | `lpmc_init`@0x16D5BC, `lpmc`@0x25CB6C | 3/1 | 3/1 | HPMC path only | implement 0 (HPMC), 1, 2, 4 (TOC). The 715 is category A, so option 3 returns -2 (P11:2263) |
| 4/0 | MODEL info | `processor_init`@0x65F88, `getcputype`@0x173F68, `pa_get_cpu_iodc`@0x7CB7C | yes | yes | **fatal if bad**: bus_id = (hversion>>11)&0x1F must be 0xC (L `inventory.c:104-123`) | real values: hversion 0x60A0, sversion 0x481, sw_id 2004000715, arch_rev 4, keys 0x72 (`715_64.h:32`) |
| 4/2, 4/3 | VERSIONS, SYSMODEL | `getcputype`@0x174364/0x17437C (OS_ID 1 = HP-UX) | yes | yes | printed | "9000/715" |
| 4/4 | **ENSPEC** | `processor_init`@0x66004, if arch_rev = 4 and an FPU is present; passes `potential_key`, prints "WARNING: can't enable implementation specific instructions" on failure | yes | yes | -- | return OK. What the real PDC enables (MAX-1?) is for the ROM analysis to find |
| 4/6 | CPU_ID | `set_machine_parameters`@0x1794DC | yes | yes | printed | **must fail** on a 715. Its failure selects the BTLB-count path (§3.1) |
| 5/0 | CACHE info | `monarch_init`@0x172404, `iodc_initialize_cache_parameters`@0x4F704 | yes | yes | **panic** if it fails | the real 715 values (§3.4) |
| 5/2 | CACHE SPID bits | -- | -- | -- | `cache.c:294-299`; must return 0 or -2 | 0 bits |
| 6/0 | HPA | `monarch_init`@0x172394 → `processor_hpa` | yes | yes | not called | **0xFFFBE000** on a real 715. HP-UX sends interrupt transactions and CMD_RESET there |
| 7/0 | COPROC | `processor_init`@0x65EC0 → CR10 = ccr_functional & 0xC0 (`|0x20` if PerfMonitor) | yes | yes | **panic** without an FPU | ccr_functional 0xC0 |
| 8/0 | IODC read, index 0 | `read16_pdc_iodc`@0x1588F4, discovery, `c720_init`@0x759B8 | ×63 | yes | `drivers.c:506` | real IODC headers (`715_64.h`) |
| 8/0 | IODC read, index 3/4 | `iodc_allocate_a_buffer`@0x18EE6C/0x18EEAC, `iodc_console_init`, `iodc_open` (dump) | yes | yes | -- | **copyable, position-independent ENTRY_INIT/ENTRY_IO** for the console and boot device |
| 8/2, 8/4, 8/5 | IODC memory | `pa_configure_memory`@0x4E770, `pa_log_module_status`@0x1DCEF8, `pa_init_memory_mod`@0x5C194 | -- | -- | -- | the 715's memory is processor-dependent (SVERSION 9): option 2 non-destructive init (max_spa/max_mem), 4 return-and-clear errors, 5 identify primary (P11:1562-1600) |
| 9/0,1,2 | TOD read/set/calibrate | `read_tod`@0x50400, `set_tod`@0x206A78, `processor_init`@0x66090 | yes | yes | read and set (`time.c:212`) | real RTC |
| 10/0,1,2 | STABLE | `getcpuinfo`, `read_boot_path`@0x22FA90, `write_boot_path`@0x22FB74, `write_dumpss`@0x24BFA4 | yes | yes | writes OS_ID; driver needs size ≥96 | persistent 96+ bytes |
| 11/0,1,2 | NVOLATILE | `getcpuinfo`@0x137DD0/0x137E40, `put_panic`@0x26EFC8 | yes | yes | -- | NVM area |
| 12/0 | ADD_VALID | `iodc_console_init`@0x1FCDD4…, `audio2_probe`@0x2445F4 | ×6 | -- | `lasi.c:72`, `sticore.c:860`, `parport_gsc.c:362` | OK for every real device and the STI ROM address |
| 15/0 | INSTR | (IVA+32 set-up) | yes | yes | `traps.c:822` | the PCX-L vectors HPMC to 0xF0000000, so IVA+32 holds a null instruction (P11:474-475) |
| 18/0 | BLOCK_TLB info | `set_machine_parameters`@0x1795E4, `btlb_map_init`@0x185BA8 | ×4 | yes | /proc only | **fixed_range_info = 8** (num_comb). min/max as the PCX-L implements them |
| 18/1 | BLOCK_TLB insert | `btlb_insert_entries`@0x168B6C | 12 | 12 | never | §3.3 |
| 18/3 | purge all | `stop_hppa`@0x247FF8 | -- | -- | -- | implement |
| 19/0, 19/1 | TLB info/setup | `set_machine_parameters`@0x179680, `enable_hw_tlb_miss`@0x1FF120 | 19/0 | 19/0 | never | either -1, or the full walker (§3.3) |
| 20/0,3,5 | MEM (PDT) | `pdt_read`@0x185EE0, `pdt_setbad`@0x185904 | yes | yes | `pdt.c:150` | PDC 2.0 only: return -1 |
| 21/2 | PSW set defaults (state 0) | `processor_init`@0x65F78 | yes | yes | not on 32-bit | OK. The default-endian bit stays big-endian (PCX-L DR0[23]) |
| 22/0 | SYSTEM_MAP | `pa_build_fixed_mod_table`@0x161A8C | yes | ×10 | `inventory.c:62` | **must fail on a 715**. That selects the Snake/MEM_MAP path in both kernels |
| 23/0,1 | SOFT_POWER | `pfail_enable_power_switch`@0x5313C | -- | yes | `power.c:208` | fail. The 715 has no soft power; both kernels would otherwise poll DR25 with a DIAG |
| 128/0 | MEM_MAP | `pa_find_snake_functions`@0x15F12C, `pa_build_fixed_mod_table`@0x161B80 | ×32/boot | -- | `inventory.c:477` | HPA for each module path |
| 129 | EEPROM | `graph_montype`@0x1EB170 (framebuf ioctl, other models only) | -- | -- | -- | may fail |
| 135/0,1,2 | IO | `pa_module_init`@0x17CF38, `crash_dump`@0x202600 | 1, 2 (0 at panic) | 1, 2 | HPMC only | OK |
| 136/0 | BROADCAST_RESET | `Reset_Machine`@0x201EE4 | at panic | -- | `process.c:87` | reboot |
| 138/0 | LAN_STATION_ID | `lan_station_address`@0x52514 | -- | -- | `lasi_82596.c:170` | 6-byte MAC |
| 163/0 | INITIATOR | `c720_init`@0x75ACC/0x76114 | ×2 | ×2 | -- | SCSI initiator ID and limits |

**Procedures HP-UX can use but not on a 715:** 139 CHECK_RANGES and 147 PCI_INDEX (bus converters, PCI/Dino). They are only reached on such machines.

### 2.3 IODC

**HP-UX:**
- HP-UX keeps its own IODC-driven console and dump path. `iodc_printf`, `iodc_cputchar`, `iodc_dump` and `iodc_read/write`@0x24AAB0-0x24B180 are used for panics, early messages and crash dumps.
- To do this it copies the console's and boot device's ENTRY_INIT (index 3) and ENTRY_IO (index 4) into kernel buffers with PDC_IODC (**obs**: `PDC_IODC … ARG4=0x3/0x4` for the LASI UART and SCSI right after kernel start).
- It calls them later in real mode. So the boot ROM's IODC must be **relocatable code that runs from RAM**, as the architecture requires (IODC:424-460, 672-676).
- SeaBIOS satisfies this with a trampoline that calls back into PDC.

**Linux:**
- Uses ENTRY_IO COUT/CIN only through PAGE0 MEM_CONS/MEM_KBD `iodc_io`, and only for the decompressor and die/HPMC messages, because `PDC_CONSOLE` is n (L `firmware.c:1231-1293`).

### 2.4 OS handlers registered with firmware

**HPMC:**
- HP-UX: `hpmc_enb`@0x206FE8 writes the architected checksum. It sums IVA+0x20..0x30, 0x38, 0x3C and LENGTH bytes at ADDRESS, and stores the negation at IVA+0x34 (PDCE:403-411, 746-749).
- Linux does the same (L `traps.c:799-846`).
- PCX-L vectors HPMC and TOC to **0xF0000000 (PDC)** regardless of IVA (PCXL ERS §8, cited by the docs agent as PCXL_ers.txt:2497-2498). PDC then validates the OS_HPMC checksum and enters it.

**TOC:**
- HP-UX: MEM_TOC = `TOC_Vector`, MEM_TOC_LEN = 0 (above).
- Linux 5.15: no TOC handler.
- PDC must check "MEM_TOC ≠ 0, first word ≠ 0, sum of 0 bytes = 0" (PDCE:371-373). The TOC source is the front TOC button, or LASI ICR bit 1 (LASI:3904-3912).

**LPMC:** HP-UX calls PDC_PIM(3,1) at init and PDC_PIM(3,2) in `lpmc`@0x25CB6C.

**Power fail:** `pfail_*` uses PDC_SOFT_POWER. It is not on a 715, so fail it.

### 2.5 Page Zero fields the kernels read or write

| Offset | Field | HP-UX | Linux |
|---|---|---|---|
| 0x008/0x00C | MEM_TOC / TOC_LEN | writes TOC_Vector / 0 | -- |
| 0x010 | MEM_RENDEZ | -- | SMP kernel writes it |
| 0x040 | processor-dependent | -- | "SeaBIOS" test |
| 0x380 | MEM_FREE | -- | reserves 0..MEM_FREE+32K |
| 0x388 | MEM_PDC | `rdb_bootstrap`@0x18FF48, `Load_MEM_PDC`@0x28502C | every call |
| 0x38C | MEM_10MSEC | `realmain`@0x158D4C | CR16 rate |
| 0x390 | IMM HPA… | `m_itmr_sync_read`@0x25FD30 | `imm_max_mem` (0x39C) = RAM size |
| 0x3A0/0x400 | MEM_CONS / MEM_KBD | via the IODC console code | early console |
| 0x604 | STI ROM pointer | (see §4.6) | third STI search location |

---

## 3. CPU core (PA-7100LC)

### 3.1 How each OS identifies the CPU, and why it matters

**HP-UX** (`set_machine_parameters`@0x179488):
1. Calls PDC_MODEL CPU_ID. If it succeeds, the model field (bits 21:26) selects the CPU type:

   | Model | Type |
   |---|---|
   | 0xB | PCX-T' |
   | 0xD | **PCX-L** |
   | 0xE | PCX-U |
   | 0xF | PCX-L2 |
   | 0x10 | PCX-U+ |
   | 0x11 | PCX-W |

2. If CPU_ID fails, it calls PDC_BLOCK_TLB info and keys on `fixed_range_info & 0xFFFFFF`:

   | Value | Meaning |
   |---|---|
   | 0x040400 | PCX-S |
   | 0x10 | PCX-T. Also sets `cpu_has_hw_tlb_assist`. |
   | **0x08** | **PCX-L**. Also sets `cpu_has_hw_tlb_assist`. |
   | anything else | panic "cannot determine CPU type" |

3. Calls PDC_TLB info. `cpu_has_hw_tlb_assist` and `cpu_updates_cr28_on_dtlb_miss` stay 1 only if it returns OK with a nonzero min or max size. `cpu_updates_cr28_on_itlb_miss` is always 0, which matches the post-silicon CR28 ITLB bug (PCXL ERS §2.1.6, pcxl_fwd.txt:290-293).
4. Every identified type sets `cpu_has_shadow_registers`.

The real 715/64 fails CPU_ID (`715_64.h:36`, value 0). So a faithful PDC must return **8 combined fixed BTLB slots** for HP-UX to take the PCX-L paths.

**Observed:** on QEMU `-M 715` the BTLB info reports 16 slots (`target/hppa/mem_helper.c` diag 0x100 handler), and HP-UX sets **`cpu_is_a_PCXT` = 1** (**obs** `hpux-715-gdbvars.txt`: gdbstub read of 0x4437E4).
- Because of this, it runs the PCX-T errata code: `getCPU0`@0x1BC80 and `stalloff`@0x18EBD0 with **diag 0x141C1A00 / 0x141A1600** (PCX-T DR0 read/write).
- QEMU logs those as "DIAG opcode 0x1c1a00 ignored". This corrects review 03 §B.2, which took them for PCX-L diagnoses.

**On a real PCX-L**, the PCX-L paths would be taken: `getCPU0_PCXL`@0x1BD00 = `diag 0x141C0600` (MFCPU DR0→r28) and `setCPU0_PCXL`@0x1BE80 = `diag 0x141A0240` (MTCPU r26→DR0). But no code path reaches them on PCX-L:
- `stalloff`, `hintson` and the rest are only called for PCX-T (`realmain`@0x158F20-0x15902C).
- `disable_TCU_lookaside`@0xCFDD4 is only for cputype 0x81.

**HP-UX 10.20 therefore executes no DIAG on a PCX-L**, with one exception:
- `pfail_power_switch_status`@0x25D700 polls the power-switch bit with `getCPU25_PCXL`@0x1BC5C = `diag 0x1720141C` (MFCPU_T DR25, bit 0). It does this only if PDC_SOFT_POWER returned a status-register address of 0 (`soft_power_status_reg`).
- Linux does the same (L `power.c:61-75, 145`).
- **Making PDC_SOFT_POWER fail** (the 715 has no soft power) avoids it in both.

Everything else HP-UX needs in the diagnose registers goes through PDC: PDC_TLB → DR24/DR25; PDC_PSW → the default-endian bit.

**Linux** identifies pcxl from `hversion>>4` in 0x600-0x61F (L `hardware.c:1303`). It executes `mfdiag dr0` = **0x141C0600**, clears DR0 bits 27/28 (DHASH_EN/IHASH_EN), then `mtdiag` = **0x141C0240** (L `pacache.S:1314-1321`).
- This is the same MTCPU/MFCPU encoding HP-UX has, with r28 as the source.
- `disable_sr_hashing` also requires PDC_CACHE option 2 to report 0 space bits or -2 (L `cache.c:294-299`).

### 3.2 Interruptions, shadow registers, IVA

**HP-UX:**
- Has four IVA tables: `PA89_iva`@0x18000 (PA 1.1 with shadow registers), `PA83_iva`@0x18800, `shadow_iva`@0x19000 and `PA2_0_iva`@0x1C000.
- With `cpu_has_shadow_registers` it installs PA89 (`realmain`@0x159F98 → `PA89_init`).
- The PA89 TLB handlers (`$dtlbmss_89`@0x1A7E0 etc.) use only r1, r8, r9, r16, r17 and r24 plus SR1, and end in **`rfi,r`** (e.g. @0x1A818). They never save the GRs.
  - **So shadow-register capture on interruption with PSW.Q = 1, and exact restore by RFIR, are mandatory** (ACD:3089-3124).
- Vector code reads CR16 into a temporary at external-interrupt entry (`$i_ext_in_89`@0x1808C) for timing.

**Linux** has the same dependency (L `entry.S:1137-1143`; every TLB handler exits with `rfir`).

**Interruption types seen during the HP-UX boot on `-M 715`** (count of `INT` lines in `hpux-715-inasm-int.trace.gz`):

| Interruption | Count |
|---|---|
| external | 9319 |
| data TLB miss | 712 |
| TLB dirty bit | 706 |
| non-access data TLB miss | 104 |
| instruction TLB miss | 85 |
| **page reference** (T-bit) | 4 |

HP-UX has handlers for the T bit (`tbitmss_*`, `$t_vioref_trap`), so the **TLB T bit and the page reference trap** are needed.

**LDCW:**
- `patch_ldcw_instructions_with_cache_hint`@0x18E938 runs unconditionally and sets the cache-hint field of a list of LDCW instructions. **LDCW (and loads/stores) with a nonzero cache-hint field must execute normally.** Hints may be ignored (ACD).
- Lock words are 16-byte aligned in both kernels.

### 3.3 TLB, page tables, block TLB

**HP-UX hashed page directory.** Read from `$dtlbmss_89`@0x1A7E0 and `$itlbmss_89`@0x1A720 (MMWP:812-869, 2457-2528 describes the same structure):
- **Hash:** `index = ((offset>>12) XOR (space<<5)) & mask`; entry = `htbl + index*16`. `pdir_base_patch_*` and `pdir_mask_patch_*` are patched at boot by `patch_base_and_mask_of_tlb_handlers`@0x17BB08.
- **Entry, 16 bytes:**

  | Word | Contents |
  |---|---|
  | 0 | tag: bit 0 valid, bits 1-15 offset[0:14], bits 16-31 space |
  | 1 | protection word for IDTLBP: R(ef) at bit 0, D at bit 3, … |
  | 2 | RPN word for IDTLBA |
  | 3 | physical address of the next entry, 0 at the end |

- **Software handler:** compare word 0 with the missing tag; on a hit, set R (and D for the dirty trap), store word 1 back, `idtlba` word 2, `idtlbp` word 1, `rfi,r`. On a mismatch, follow word 3; if word 3 is 0, it is a page fault.
- This is **exactly the PCX-L hardware-visible table** of PCXL ERS §6.7.3 (pcxl_fwd.txt:1811-1874). The ERS hash `(vpn<<4) ^ (space<<9)` is HP-UX's hash × 16 (§6.7.2, :1778-1808). Words 0-3 match field for field.
- Observed on QEMU (**obs** `hpux-715-gdbvars.txt`): `htbl` = 0x00800000, `nhtbl` = 0x40000 entries (a 4 MiB table at 4 MiB alignment for 256 MB of RAM). That is within the walker's 4 KiB-32 MiB limit.

**Hardware walker enable** (`realmain`@0x159FAC → `enable_hw_tlb_miss`@0x1FF0E0):
- The call is `PDC_TLB(1, R, base=htbl, size=nhtbl<<4, set_state=5)`, i.e. `en=1`, `cr28 field = 2` (P11:3434-3515).
- Mode 2 means "CR28 = next-pointer field of the current entry". In ERS terms DR25 U=1, N=0, D=0, I=0, with DR24 = base and DR25 mask = size (pcxl_fwd.txt:1875-1950).
- If PDC_TLB info succeeded but setup then fails, HP-UX **panics** ("Failed to enable HW-TLB miss handler").
- When the assist is on, `patch_PA89_iva_for_HV_options`@0x18EF08 overwrites `dtlb_mfcr28_patch` with `0x038008A1` = `mfctl cr28,r1`. The DTLB miss handler then *starts from the CR28 value* (`dtlb_got_next_ptr_PCXT`).
- **FPGA rule:** if PDC reports PDC_TLB, the CPU must:
  - walk the table on I and D misses;
  - check V, tag and R exactly;
  - insert words 1 and 2;
  - on failure, trap with CR28 per the ERS table: current entry if V or R is 0; next pointer if the tag mismatched and U=1.

  Otherwise PDC_TLB returns -1, HP-UX uses the software handlers (as it does under QEMU), and the walker can be left out. Either way the TLB-miss traps (6, 15, 16, 17, 20) and the T and D bits are needed.

**Linux:**
- Never calls PDC_TLB and never inserts a BTLB entry. It uses a 2-level page table and its own handlers (L `entry.S:359-580`). The PTE→IDTLBP conversion makes PA1.1 access-rights type/PL1/PL2 semantics and the U bit load-bearing (L `entry.S:566-580`; NO_CACHE → U bit, needed for its uncached DMA window, L `pci-dma.c:401-418`).
- Firmware must hand over with **no stale BTLB entries** and the walker disabled (PDCE:1300).

**Block TLB:**
- HP-UX maps kernel text and data with BTLB entries through PDC_BLOCK_TLB insert (`btlb_insert_entries`). Observed on QEMU, 12 entries, all space 0, VA = PA, power-of-two sizes:

  | Use | Entries | entry_info |
  |---|---|---|
  | data | 0x800000/8 MB, 0x400000/4 MB, 0x3E0000/128 KB, 0x3D8000/32 KB, 0x1000000/4 MB | 0x11000000 |
  | text | 0x100000/1 MB, 0x200000/1 MB, 0x300000/512 KB, 0x380000/256 KB, 0x3C0000/64 KB, 0x3D0000/32 KB, 0x80000/512 KB | 0x02000000 |

  QEMU offers 1-page minimum and 16 slots. On a PCX-L (8 slots; ERS gives 128-16K pages, docs-agent citation PCXL_ers.txt:2187-2203) HP-UX will choose fewer, larger blocks from the info returned.
- The graphics driver tries up to two 16 MB BTLB entries for Artist and falls back to page mappings (`graph3_alloc_btlb`, §4.6).
- PDC must implement insert, purge and purge-all on the real PCX-L BTLB through DR8 (docs agent: PCXL_ers.txt:1983-2005). The CPU must honour BTLB translations including their access rights.

**Purges:**
- HP-UX `purge_all_tlbs`@0x18F590 and Linux `flush_tlb_all_local` (L `pacache.S:34-176`) both loop PITLBE/PDTLBE over PDC_CACHE `it_*`/`dt_*` sp/off base/stride/count/loop.
- With the real 715 values (count 1, stride 0) that is **one PITLBE + one PDTLBE**. On the PCX-L a PxTLBE purges all page entries but not block entries (docs agent: PCXL_ers.txt:2155-2156). The FPGA must do the same.
- Single-entry purges are broadcast `pdtlb`/`pitlb` (`ftlb_patch1_end`@0x206ED4; Linux `cache.c:483-506`). The HP-UX MP variant takes `spi_bug_lock`.

### 3.4 Caches

**HP-UX:**
- `monarch_init`@0x172404 copies PDC_CACHE into `cache_tlb_parms`. It derives `dcache_line_size`/`icache_line_size` from the conf "line" field and the block sizes from "block".
- `cafl_init`@0x206AC0 decodes f-sel / wt.
- **`fcacheall`@0x206C74 runs exactly the architected loop**: `fice`/`fice,m` with ic_base/stride/count/loop, then `fdcacheall`@0x206CCC with `fdce`/`fdce,m`, then `sync`. Range flushes (`fdcache`, `ficache`, `pdcache`@0x207084…) use `fdc`/`fic`/`pdc` stepping by the line size. `fcacheline`/`pcacheline`@0x206C2C use `fdc`/`pdc` + `fic` with SR2.
- Linux is the same pattern (L `pacache.S:190-309`; stride = `cc_line << (3+cc_block+cc_shift)` = 32, L `cache.c:244-247`).

**Real 715/64 PDC_CACHE** (`715_64.h:42-47`):
- I and D both size 0x20000, conf 0x61402000 (alias 6 = 128 KB, block 1, line 2 = 32 bytes, wt 0 = write-back, f-sel 00 = flush both, cst 1), base 0, stride 32, count 4096, loop 1.
- ITLB/DTLB size 64, conf 0xD2000 (unified), counts 1, loop 1.

**FPGA consequences:**
- FDCE/FICE must invalidate (and for D write back) the line indexed by the address, so 4096 strided calls clear the whole cache. Report numbers that match the FPGA cache. A PIPT cache is fine for both kernels; Linux assumes aliasing ≤ 4 MB.
- **The 715 is not I/O-coherent.** Both kernels flush before and after DMA:
  - HP-UX: `purge_after_inbound_dma` is set only for PCX-T'/U/W (`realmain`@0x15902C).
  - Linux: `fdc` in both directions, and an uncached window for coherent allocations on pcxl (L `pci-dma.c:401-456`).
  
  So DMA must not snoop in ways that break these assumptions, and the TLB **U (uncacheable) bit must be honoured**.
- `pdc` (purge) may be implemented as flush+invalidate.

### 3.5 External interrupts

**HP-UX:**
- Assigns EIRR bits through `pa_get_interrupt`@0x1DB518 / `pa_get_eim` and programs each interrupting chip with "processor HPA | bit". **obs** (review 03 trace): LASI IAR ← `0xFFFB0003`, i.e. **EIRR bit 3**.
- The dispatcher `up_ext_interrupt`@0xB0298 reads EIRR, takes the most-significant set bit (`ms_bit_position`), dispatches through `eirr_switch`, clears the bit by `mtctl eirr` (write-1-to-clear), and rewrites EIEM.
- Bit 0 is the interval timer.
- **HP-UX also interrupts itself through the same register.** `setsoftnet`@0x114480 posts the network software interrupt by storing 25 to `processor_hpa`+0. So CPU self-writes to its own IO_EIR must work.

**Linux:** EIRR bit 0 is the timer; devices get the next free bit (1 on UP, 2 with SMP+IPI). IAR = CPU HPA | bit (L `irq.c:29, 314-365`; `lasi.c:162-214`).

**FPGA:**
- A word write of *n* (0-31) to the CPU HPA (0xFFFBE000 on a real 715) sets EIRR bit *n* (PA numbering, MSB = 0).
- EIRR is write-1-to-clear.
- An interrupt is taken when PSW.I and (EIRR & EIEM) are both set (ACD:1446-1450).
- Reset value of LASI IAR is 0xFFFBE003 (LASI:3880-3883).

### 3.6 Interval timer (CR16)

**HP-UX:**
- `set_it`@0xE6570 (the clock interrupt) adds `itick_per_tick` (= MEM_10MSEC) to the last compare value, writes CR16 (**sets the compare**), clears EIRR bit 0, then re-reads CR16 to catch up on missed ticks ("Clock_int: tick arrived early" if CR16 is behind).
- `init_itimer`@0x25FD74 arms it the same way.
- 268 `mfctl cr16` sites read it for timing.

**Linux:** the same scheme (L `time.c:45-118, 236-285`). udelay and the clocksource are CR16 at MEM_10MSEC × 100 Hz.

**FPGA:**
- CR16 is a free-running 32-bit up-counter.
- MTCTL writes a separate compare register; counter == compare sets EIRR bit 0 (ACD:1361-1375).
- The rate must equal MEM_10MSEC × 100. QEMU fixes it at 250 MHz; the real 715/64 counts at the CPU clock. On PCX-L, DR1 is the counter itself (writable through MTCPU; docs agent: PCXL_ers.txt:928-930).

### 3.7 Implementation-specific and unusual instructions

| Feature | HP-UX 10.20 | Linux | Requirement |
|---|---|---|---|
| DIAG | none on PCX-L (PCX-T-only paths above). `enable_hw_tlb_miss_ll`@0x1BB94 is unreferenced. `getCPU25` (DR25) only if SOFT_POWER reports a Gecko switch. | MFCPU/MTCPU DR0 (0x141C0600/0x141C0240). DR25 read `0x1720141C` only if SOFT_POWER succeeds. | MFCPU/MTCPU DR0 must work; make SOFT_POWER fail |
| MAX-1 (HADD…) | not used (scan of all code subspaces) | not used | optional for the kernels. Implement anyway for user code |
| PA2.0 / MAX-2 | present only in PA2.0 paths (`init_io_pdir_entry`@0x4613C) | -- | not reached on PA1.1 |
| Fast TLB insert (IxTLBAF/PF) | **none** in 10.20 (QEMU's "HP-UX 9 encoding" note refers to 9.x) | none | not needed for 10.20/Linux. Check HP-UX 9.05 |
| SPOP | none | none | assist-emulation trap only |
| COPR uid≠0/1 | `pa_arm`/`pa_disarm`@0xD1108 (performance monitor, only with the PerfMonitor CCR bit) | none | trap if CCR bit clear |
| `mfctl,w %cr11` | -- | yes, must read SAR as 5 bits | decode as MFCTL |
| B,GATE / BLR / BE / BLE | gateway page (§3.8) | gateway page | exact privilege rules |
| LDCW with cache hint | yes (patched) | plain | ignore the hint |
| Branch in delay slot | -- | flush loops (L `pacache.S:74-75`) | architected semantics |
| FP | PDC_COPROC → CCR; `fprinit`. User code uses the FPU. | math-emu catches assist traps | delayed traps / unimplemented → assist exception (14) |

### 3.8 Space registers, protection IDs, gateway page

**HP-UX gateway page:**
- `$GATEWAY$`@0x14000 is the gateway page, reached by user code at **0xC0000000 in SR7's space** (`ldil L%0xC0000000; ble 4(sr7,r1)`; SOM:7555-7590).
- At +4: `subi,>>= 0xFD,r22` bounds-checks the syscall number. +0xC/+0x10: `blr` dispatches into 16-byte stubs `syscallbase`@0x14018, each of which is `b,gate .+8` / `ldil` / `be syscallinit(sr7,r1)` / `depwi 3,31,2,r31`.
- So the page's translation must have gateway access rights promoting to PL0. **B,GATE privilege promotion, BLR and inter-space BE through SR7 must be exact** (ACD:6006-6040).

**HP-UX space and protection IDs:**
- 16-bit space IDs in the PDIR tag. User text through SR4 (Q0), data SR5, shared SR6/SR7 (SOM:138-179).
- All four PID registers are written (`mtctl pidr1..4`: 7/8/12/13 sites).

**Linux:**
- Gateway page at virtual 0 of space 0 (LWS entry 0xB0, TLS 0xE0, syscall 0x100).
- SR4-7 = user space when in user mode; kernel space 0; SR3 = user space in the kernel.
- 15-bit space IDs; CR8 = space<<1, other PIDs 0.
- Access ID 0 must mean "public" (L `mmu_context.h:35-48`, `entry.S:566-574`).

**FPGA:**
- 16-bit SIDs (PCX-L level 1, 48-bit VA).
- 4 PIDs × 15 bits + WD (docs agent: PCXL_ers.txt:2145, 2235).
- Exact PA1.1 access-rights checks.

---

## 4. LASI and the I/O devices

**Sources for this section:**
- HP-UX driver analyses done for this review. Four are separate files: **[06a](06a-hpux-harmony-audio.md)** (Harmony audio), **[06b](06b-hpux-lasi-peripherals.md)** (PS/2, RS-232, parallel), **[06c](06c-hpux-graphics.md)** (graph3/STI/framebuf/ite) and **[06d](06d-hpux-c720-scsi.md)** (c720 SCSI).
- The LASI core and discovery findings were checked against the disassembly.
- Linux material is from the Linux review (file:line as given).

### 4.0 Which HP-UX drivers this kernel actually runs on a 715

`driver_install`@0x3E26B8 is the boot-time install list. Its I/O entries are asio0, graph3, framebuf, ite, beep, ps2, lasi, asp, sctl, sdisk, c720, CharDrv, CentIf and btlan3.

**audio and hil have code in the kernel but are not installed.** `audio_link`@0x4FB98 and `hil_link`@0x4FA08 have no callers. So this kernel never touches Harmony (0xF0104000) and has no HIL; the beep pseudo-driver falls back silently.

The sversion → driver table comes from `lasi_function_info`@0x3FCF78 and `wax_function_info`@0x3FCEB0. HP-UX takes the interrupt bit from this table, not from hardware:

| Unit | sversion | LASI IRQ (GSC bit) | HP-UX driver | Linux driver |
|---|---|---|---|---|
| LASI core (BA) | 0x81 | 14 (bus error), 21 (external) | lasi/core | `lasi.c` |
| SCSI 53C710 | 0x82 | 9 | c720 | `lasi700.c` + `53c700.c` |
| LAN 82596 | 0x8A | 8 | **none here** (`lan2` not configured) | `lasi_82596.c` |
| RS-232 16550 | 0x8C | 5 | asio0 | `8250_gsc.c` |
| Parallel | 0x74 | 7 | CentIf | `parport_gsc.c` |
| Audio (Harmony) | 0x7B | 13 | audio (not installed) | `harmony.c` |
| PS/2 kbd + mouse | 0x84 (two modules) | 26 | ps2 | `gscps2.c` |
| Floppy | 0x83 | 20 | none | none |
| Artist (top level) | 0x85 | -- | graph3 / sti / framebuf | `stifb.c` / `sticore.c` |
| WAX BA / EISA / HIL / RS-232 | 0x8E / 0x90 / 0x73 / 0x8C | WAX's own controller | core / -- / -- / asio0 | `wax.c`, `eisa.c`, `hp_sdc` |

**How HP-UX discovers modules on a 715:**
1. `pa_build_fixed_mod_table`@0x161A20 tries PDC_SYSTEM_MAP. The 715 returns -1.
2. It then walks PDC_MEM_MAP over mod 0..15. For each bus adapter it calls `pa_find_snake_functions`@0x15F090 with bc = {FF,FF,FF,FF,mod,0} and func 0..15.
3. For each module it reads the **first 16 IODC bytes** (`read16_pdc_iodc`). sversion = `(be32(bytes 4..7) >> 8) & 0xFFFFF`; type = `byte3 & 0x1F`.

Consequences:
- **A module PDC does not report does not exist.** Leaving out WAX, EISA, HIL, floppy or LAN is safe.
- A module PDC does report must have readable IODC. If WAX is reported, its IMR/IPR/IRR/IAR at 0xF0200000 must decode, because `lasi_init` also runs for WAX.
- `pa_module_init`@0x17D02C stores 0xFFF80001 to **0xFFFC0020** (local-broadcast IO_FLEX). That store must complete without an HPMC. QEMU logs an HPMC for it (**obs** `.qemu` logs) and HP-UX survives.
- Report the CPU (type 0) and memory (type 1) modules through MEM_MAP. That sets `disable_central_bus_walk`; otherwise HP-UX probes the central bus at 0xFFF80000.

Linux uses the same Snake path: `snake_inventory` PDC_MEM_MAP + PDC_IODC, matching on sversion with hversion 0x028 and hw_type 10 (L `inventory.c:477-501`, `drivers.c:506-522`).

### 4.1 LASI core (HPA 0xF0100000)

**Interrupt controller** (LASI:3850-3949; `lasi_init`@0x1DD478, `lasi_interrupt`@0x1DD710):
- **Init:** IMR ← 0; IPR ← 0 (any write clears all of IPR); read IRR and discard it; **IAR ← processor_hpa | EIRR bit** (bit chosen at runtime, 3 under QEMU); then enable GSC bits 14 and 21. ICR is never written.
- **Dispatch:** one IRR read. **That read is the only acknowledge** and clears IRR and the unmasked IPR bits. HP-UX then services bits from the highest GSC number down (PS/2 26 first, RS-232 5 last) without re-reading IRR.
- **Linux:** IMR = 0, read IRR, IAR = HPA|bit; demux reads IRR once and never writes it (L `lasi.c:162-214`, `gsc.c:71-136`).
- **FPGA must:**
  - IPR edge-latches.
  - IRR = IPR & IMR, read-to-clear.
  - Whenever an unmasked bit is or becomes pending, write IAR[4:0] to IAR[31:5]. That includes a request arriving after the IRR read and a mask being opened on a pending bit.
  - IMR/IAR read/write; ICR bit 8 bus_error blocks transactions.
- Power-up IAR is 0xFFFBE003.

**GSC bit 21 "external interrupt":**
- HP-UX enables it with no handler. If it fires on CPU family 0x600 (hversion 0x60A>>4 & 0xF80), `lasi_interrupt` **writes 5 (CMD_RESET) to processor_hpa+0x30**@0x1DD864.
- `pfail_poll_switch`@0x25D3F4 does the same after printing "User initiated TOC, please wait.".
- So on a 715 this line behaves as a TOC button. **CPU HPA+0x30 ← 5 should act as TOC** (PDCE:105-113: a directed CMD_RESET runs PDCE_TOC). Never assert bit 21 otherwise.

**Bus error (GSC 14):** `lasi_error_handler`@0x1DD990 reads ERRLOG (+0xC004). If it is non-zero it prints "Core I/O error log" and panics; if it is 0 it ignores the interrupt.

**+0xC000 block** (mapped only for sversion 0x81 on family 0x600):
- HP-UX reads ERRLOG (+0xC004) and read-modify-writes AMR (+0xC010) bit 0 through `lasi_arb_enable/disable`@0x1DD950. It never touches PCR, VER or IORESET.
- **Firmware must leave AMR = 0**, or LASI DMA masters are blocked (LASI:4076-4101).
- Linux reads VER (+0xC008)&0xF and powers off by writing 0x02 to +0xC000 (L `lasi.c:28, 151-177`).

**Front LEDs:**
- HP-UX (`lasi_init_led_handler`@0x1DD9F8, model 0x60A/B/C/D/E or 0x619) writes one byte to **0xF00E0000** (= LASI − 0x20000) in `core_led_method`@0x1DDDD0: the active-low, bit-reversed activity byte. That gives heartbeat on LED4, disk on LED3, LAN on LED2/1.
- Linux uses the same address for 0x60A (L `lasi.c:124-130`), writes `~leds` without the bit reversal, and only does so if PDC_CHASSIS 128 fails.
- **FPGA:** an 8-bit write latch at 0xF00E0000 mapped to the board LEDs / OSD.

### 4.2 SCSI -- NCR 53C710 (LASI+0x6000, core registers at +0x100)

The full analysis is in **[06d](06d-hpux-c720-scsi.md)**: driver flow, the decoded and runtime-patched SCRIPTS, the register table and the INT dispatch.

**HP-UX c720 on LASI** (`c720_core_attach`@0x18AB40: sversion 0x82 → flags 0x400400):
- **Registers.**
  - Core at HPA+0x100 in **big-endian mode** (byte = LE register ^ 3, 32-bit words native). Nothing below +0x100 is touched.
  - 40 MHz assumed (DCNTL.CF = 00, COM = 1). Init writes SCNTL0 0xCC, CTEST0 0x50, DMODE 0xC0, SCID 0x80, SCNTL1 0x20, DIEN 0x7F, SIEN 0xAF.
  - Sync negotiation offers **SDTR 200 ns / offset 8**. Initiator ID 7.
- **SCRIPTS.**
  - The script is a 720-era template patched at run time.
  - It idles in `WAIT RESELECT`, and **the host kicks it with ISTAT.SIGP**, which must divert WAIT RESELECT to its alternate address.
  - It uses SELECT ATN, WAIT DISCONNECT, all three register read/write forms (SCRATCH, TEMP, SFBR, CTEST2, SDID, SCNTL0), CALL/RETURN through a TEMP rewritten by register moves (a computed jump), and 4- and 16-byte memory-to-memory moves.
  - Reading CTEST2 clears SIGP. LCRC gives the reselecting ID.
- **ISR.**
  - Reads ISTAT → SSTAT0 → 1 µs → DSTAT → DSPS → SCRATCH.
  - Dispatches on the exact cause combination. Stacked causes must come one at a time.
  - **A SCRIPTS INT with DSTAT.DFE clear is treated as a fatal escape.**
- **Interrupt line:** LASI GSC bit 9. Interrupt-on-the-fly (bit 21) and snoop (bit 19) are not used.
- **DMA:** non-coherent, with `fdc`+`sync` around everything, and arbitrary byte counts and alignments (bounce fragments).

**Why QEMU `-M 715` fails** (finishing review 03 §B.3):
- `INT 0x0F` is the driver's normal "bus close" acknowledgement, not an error.
- QEMU clears DSTAT.DFE when it raises SIR (`ncr53c710.c:634-636`), so HP-UX escapes, resets the bus, and 15 s later reports "Third party detected bus hang".
- The next QEMU gaps are LCRC (only set on selection; a write stores instead of clearing) and DFIFO always reading 0.

**Linux** (L `lasi700.c:68-110`, `53c700.c:648-783`):
- Same base, BE register access and 40 MHz.
- SCRIPTS: block MOVE, SELECT ATN, WAIT DISCONNECT/RESELECT, SET/CLEAR, JUMP/CALL/RETURN, INT. **No** SIGP, memory move or register read/write.
- So HP-UX is the stricter client.

**FPGA (must be exact):**
- DFE live.
- SIGP / WAIT RESELECT / CTEST2 semantics.
- LCRC.
- CALL → TEMP → RETURN.
- Register read/write opcodes.
- Memory-to-memory move.
- One-cause-at-a-time interrupt stacking.
- Phase-mismatch residual registers (DBC, DFIFO, SSTAT1/2).
- STO at about 250 ms.

**Can approximate:** transfer timing, burst sizes, DWT, target mode, table-indirect and carry.

### 4.3 LAN -- Intel 82596 (LASI+0x7000)

**HP-UX 10.20 (this kernel):**
- No driver. `lan_station_address`@0x524D0 asks PDC_LAN_STATION_ID (138). On -1 it reads **0xF0810000** (ASP, which bus-errors on a 715), so return the MAC instead. Only the kernel debugger uses it.
- The debugger's own 82596 code (`rdb_lan2_*`@0x281E60) shows the LASI convention HP's `lan2` would use:
  - PORT at HPA+4, written low 16 bits then high 16 bits;
  - CA at HPA+8;
  - `flush_dcache` around the shared structures.

**Linux:**
- +0 reset; +4 PORT as two `gsc_writel` (low half, then high half, with 1 µs between); +8 CA (L `lasi_82596.c:93-139`).
- SYSBUS 0x6C; 32-bit pointers halfword-swapped.
- Non-coherent buffers flushed by hand. MAC from PDC 138, falling back to 0xF0810000.

**FPGA:**
- The 82596 command/receive-unit model (flexible mode).
- PORT assembled from two 16-bit halves.
- Big-endian halfword-swapped pointers.
- MAC through PDC_LAN_STATION_ID.

### 4.4 Serial, parallel, PS/2

See **[06b](06b-hpux-lasi-peripherals.md)**. The essentials:

**RS-232:**
- A true 16550A at LASI+0x5800, byte stride.
- After FCR=1, IIR must read **0xC1**.
- **LSR.TEMT must be 1 when idle**; `asio0_hw_init` spins on it with no timeout.
- Linux assumes uartclk 7,272,727 Hz (L `8250_gsc.c:48-64`).

**PS/2:**
- Two ports at LASI+0x8000/+0x8100 with ID 0/1. The 4 KB block mirrors, so +0x200 must not read ID 2.
- **TBNE stays 1 forever with no device**; that is how "absent" is detected.
- CMPINTR is the OR of both ports, visible in port 0 STATUS.
- Device emulation must answer the set-3 keyboard command list.

**Parallel:**
- HP-UX CentIf is DMA-only through LASI's parallel DMA (+0x2000/+0x2800).
- Linux uses SPP/PS2 only (L `parport_gsc.c`).

### 4.5 Audio -- Harmony (LASI+0x4000)

See **[06a](06a-hpux-harmony-audio.md)**.
- This HP-UX kernel never attaches it.
- An audio-enabled HP-UX kernel and Linux (L `harmony.c:107-110`) both need **CNTL.C to self-clear**: Linux spins with no timeout; HP-UX expects it within about 2 ms.
- PNXTADD/RNXTADD writes acknowledge PN/RN.
- 4 KB DMA pages.
- Interrupt = IE & (PN|RN).
- A minimal stub (RESET reads back, C self-clears, no IRQ) is enough to boot both.

### 4.6 Graphics -- Artist and its STI ROM

The full HP-UX analysis is in **[06c](06c-hpux-graphics.md)**. Summary:

**HP-UX** (graph3 / sti / framebuf / ite):
- **Discovery.** The Artist is claimed by IODC sversion **0x85** alone (`graph3_attach`@0x1824D0). The STI ROM base comes from **PAGE0+0x604**: 0xF0024000 with HP's ROM.
- **The ROM image is CRC-checked.** `sti_unpack_routines`@0x172F60 first calls `sti_check_crc`@0x1728D8, a CRC-16 with constant 0x8408 over the image up to `last_addr`.
  - On failure it prints "unpack_routines(): CRC check of STI rom failed" and the display is dead.
  - `sti_pwr_reset` re-checks the CRC later and panics, so **the ROM must never change**.
  - HP's PDC 1.6 holds a word-mode Artist STI image at ROM offset 0x24000 (header `03030303 000d8407 2b4ded6d 40a00499 …`, last_addr 0x47E4, bus_support 0). HP-UX's algorithm gives 0 over it (`keep/hpux-analysis/sti_crc.py`).
  - **Our STI image must carry a valid CRC**, and it must be word-readable, with contiguous, position-independent routines 0-7.
- **STI calls.**
  - Routines are copied into RAM, the caches are flushed, and they are called in **virtual mode** (`sti_call_routine`@0x14BB48, `be,l 0(sr4,…)`), with region pointers mapped V=P. Linux instead calls them in real mode.
  - Called: init_graph (several flag sets; failure in `crt1_init` is a **panic "STI routine failure"**), state_mgmt, font_unpmv, block_move, inq_conf and excep_hdlr. Not called: self_test, set_cm_entry. Routines 8-12 are ioctl-only.
  - **Every init_graph is followed by `sti_sync_on`@0x1737D0.** That function is the only direct Artist register access in the kernel:
    - polls 0xF8300004 bit 25 / 0xF8300000 bit 24 (busy);
    - reads MISC_VIDEO 0xF8300218 to index the ROM's per-monitor user-data records;
    - writes 0xF8300200, 0xF8300208 and MISC_VIDEO.
  - So MISC_VIDEO must read back as stored. QEMU's model corrupts it (06c §6).
- **Mapping.** `graph3_map_io_space` → `graph3_alloc_btlb`@0x5AAD0 tries up to 2 × 16 MB block-TLB entries through PDC_BLOCK_TLB, then falls back to page mappings. **The BTLB is optional here.**
  - Frame buffer 0xF9000000: 16 MB, 4 bytes per pixel in the aperture, 8192-byte line stride.
  - Control 0xF8100000-0xF837FFFF.
- **No graphics interrupt on a 715.** `graph3_init`@0x16A930 hooks interrupts only for STI `bus_support` GSCINTL/PCI bits. The 715 ROM has bus_support 0, so nothing is registered. **Artist must not interrupt**, because an unclaimed LASI bit 21 means TOC (§4.1).
- `graph_montype`@0x1EAD98 (PDC 147/129) is reachable only from a framebuf ioctl, for other models. On a 715 it just fails.

**Linux** (L `drivers/video/console/sticore.c:860-976`, `drivers/video/fbdev/stifb.c:1144-1256`):
- Searches `dev->addr[0]`, then HPA, then PAGE0 0x604 (each after PDC_ADD_VALID). Byte mode if the first byte is 0x01, word mode if 0x0303.
- Copies to RAM, no CRC check. Calls init_graph, inq_conf, font_unpmv and block_move in real mode.
- stifb pokes NGLE registers directly: busy at +0x200000; LUT at 0x4A0/0x600/0x480/0x200118; blanking at 0x200218/0x200308; blit at 0x808/0x804/0xB00; and more.

**FPGA:**
- An STI image with a valid CRC, routines that return 0, and init_graph/inq_conf outputs filled in.
- The Artist registers that both the STI code and stifb use.
- MISC_VIDEO read-back.
- Prompt busy clear.
- Decoding of 0xF8000000-0xF83FFFFF and 0xF9000000 (16 MB).
- No interrupts.

### 4.7 WAX, EISA, HIL, floppy

None of these is needed by either OS if PDC does not report them:
- HP-UX has no `hil`/`eisa` here.
- Linux matches only what the inventory reports.

The 715/64's real inventory does include WAX/HIL/EISA (`715_64.h:18-21`). Leaving them out is a deliberate deviation, as CLAUDE.md already plans.

---

## 5. B160L versus 715 under QEMU

- **CPU identity.**
  - B160L: PDC reports a PA7300LC/B160L, HP-UX finds **PCX-L2** paths, and `lasi_ext_int_func` is used.
  - `-M 715`: CPU_ID fails and BTLB = 16 → **PCX-T** paths (§3.1).
  - Neither exercises the PCX-L code a real 715 runs. The safest QEMU-side improvement is for `-M 715` to report 8 BTLB slots (`PA10_BTLB_FIXED`), which would put HP-UX on its PCX-L path.
- **Discovery.**
  - B160L: PDC_SYSTEM_MAP succeeds (×10). Devices sit behind Dino/PCI; the boot disk is on an LSI 53C895A (c720 PCI path `8/0/0/0.6.0`); 4 CPUs in the image's own `run.sh`.
  - 715: SYSTEM_MAP fails, PDC_MEM_MAP is called 32 times, LASI path `2/0/1.6.0`.
- **SCSI.** On B160L, c720 drives a 53C895A through PCI. On the 715 it drives the LASI 53C710, which is where QEMU's model fails (review 03 §B.3; §4.2).
- **PDC calls only on the 715:** MEM_MAP 128, ADD_VALID 12 (IODC console), BROADCAST_RESET 136 and IO 135/0 at the panic. **Only on B160L:** PCI_INDEX 147, SOFT_POWER 23, CHASSIS 1/128, SYSTEM_MAP 22/1 (**obs** logs).
- **Timer.** Both run CR16 at QEMU's fixed 250 MHz (`iticks_per_10_msec` = 2,500,000). A real 715/64 runs at 64 MHz and its PDC must say so in MEM_10MSEC.
- **Kernel configuration.** The same B160L kernel runs on both. On a real 715 it would lack LAN; audio and HIL are not installed either way.

---

## 6. What the documents say about the OS/hardware contract

These sources were collected for this review; line numbers are in the files named in the header.

**Boot handoff:**
- PDCE_RESET → memory, console, boot device → IPL (LIF magic 0x8000, IPL_ADDR/SIZE/ENTRY at 0xF0/0xF4/0xF8, word sum 0, ≤256 KB) → ISL → OS (PDCE:910-937, 2491-2531).
- OS entry state: PL0, PSW Q=1 otherwise 0, CR14 = PDC's IVT, the listed CRs 0, cache clean, TLB invalid, **HW TLB miss off**. ISL → OS registers: GR26 = PDCE_PROC, GR25 = boot command, GR24 = utility entry (PDCE:1254-1356).
- OS_BOOT must call PDC_COPROC and PDC_PIM(3); category A returns -2 for option 3 (OSI:87-144, P11:2263).

**OS handlers PDC calls into:**
- OS_HPMC at IVA+32 with a checksum over IVA+32..63 plus ADDRESS/LENGTH (PDCE:403-411, 746-749).
- OS_TOC at MEM_TOC/TOC_LEN, entered with the TLB invalidated (PDCE:336-374).
- OS_PFR at MEM_POW_FAIL (PDCE:1175-1229).
- OS_LPMC at IVA+160 (PDCE:412).
- PCX-L vectors HPMC and TOC to 0xF0000000 regardless of IVA (PCXL ERS §8, PCXL_ers.txt:2497-2498).

**PDC calling convention:**
- Single entry PDCE_PROC; ARG0..3 in GR26..23, the rest at SP-52 downward; status in GR28; R_addr is 32 words.
- PL0, Q=1, C=D=I=0; up to 7 KB of stack above SP.
- CR16 is never written. SR3-7, GR3-18, GR27 and GR30 are preserved (P11:44-48, 86-140, 201-311).

**IODC:** real mode; relocatable code images; IODC-generated interrupts go to EIR{3}; not re-entrant (IODC:424-460, 476-626, 672-676).

**I/O architecture:**
- HPA register set: IO_EIR at +0, IO_DC_ADDRESS/DATA +8, IO_COMMAND +0x30, IO_STATUS +0x34.
- Local/global broadcast IO_COMMAND at BPA+0x30; IO_FLEX at LBPA+0x20.
- Central-bus block 0xFFF80000-0xFFFBFFFF, so CPU at 0xFFFBE000 (path 62) and memory controller at 0xFFFBF000 (path 63) (OVW:117-153, 1105-1132; PERIPH:8098-8099).
- Interrupt transactions are a 5-bit group number written to IO_EIR (OSI:243-258).

**Architecture (ACD):**
- Interruption entry: IPSW ← PSW, PSW ← 0, queues frozen, IIR/ISR/IOR, shadow GR1/8/9/16/17/24/25 (ACD:3089-3124).
- CR16 compare sets EIRR bit 0 (1361-1375).
- MTCTL CR23 clears bits (1451-1453).
- B,GATE promotion (6006-6040).
- SR selection by the top two offset bits (1561-1570).
- LDCW 16-byte alignment (2145-2146).
- FDCE/FICE implementation-defined and not broadcast (10133-10210).
- I/O pages need the U bit (2134-2135).

**PCX-L (PCXL ERS):**
- 64 + 8 entry TLB with ILAB; PxTLBE purges all page entries (§6).
- **Hardware TLB walker**: DR24 base, DR25 mask/U/N/I/D, table format, CR28 table (§6.7, pcxl_fwd.txt:1744-1960).
- DR0 hashing bits 27/28 and default-endian bit 23.
- MTCPU/MFCPU/TOC_EN/TOC_DIS/SHDW_GR/GR_SHDW diagnose list.
- MAX-1 (§2.1.4).
- Off-chip combined write-back cache with 32-byte lines (docs agent citations PCXL_ers.txt:3328-3366).

**Runtime (SOM/RAD):**
- Quadrants: SR4 text, SR5 data, SR6/SR7 shared; gateway page at the start of quadrant 3.
- System call: `ldil L%0xC0000004,r1; ble R%0xC0000004(sr7,r1); ldo N,r22`.
- At exec PSW C, D, P, Q = 1 (SOM:138-179, 1636-1662, 7555-7590).

**HP-UX internals (MMWP, PERIPH):**
- HTBL with a next pointer, aligned to its size; the hardware walker is used where present.
- The block TLB maps kernel text/data and graphics (MMWP:812-869, 940-948, 1209-1219, 2457-2528).
- Series 700 driver names (c700, c720, lan2, asio0, CentIf, ps2, hil, audio, graph3, eisa), `/stand/system` + `mk_kernel` (PERIPH:698-711, 837-846).

---

## 7. Open questions and next steps

1. **SCSI.** §4.2 / 06d is the input for the 53C710 RTL. QEMU's model needs DFE, SIGP, LCRC and DFIFO fixes before HP-UX can boot on `-M 715`; they are worth trying in the scratch QEMU next.
2. **lan2.** Getting HP's 82596 driver means reading `/usr/conf/lib/*.a` from the VxFS root. Either write a VxFS reader (layout version 2/3), or boot the B160L image under QEMU in single-user mode (`hpux -is`, no password needed) and `tar` `/usr/conf` onto a second, scratch raw disk. The same route can build a 715 kernel with `lan2`/`audio`.
3. **Graphics.** SeaBIOS's STI image (`stirom.c`) has to be checked against HP-UX's needs (06c §9): CRC, MISC_VIDEO monitor index, user-data records, routine order. If it fails them, use HP's STI image from the PDC 1.6 ROM for HP-UX.
4. **ROM side.** What the real PDC 1.6 does for:
   - PDC_TLB: which DR25 bits and mask;
   - BTLB info: min/max size, fixed count 8?;
   - PDC_MODEL ENSPEC: which DR0 bit;
   - PDC_PSW: DR0[23];
   - PDC_INITIATOR return format;
   - MEM_10MSEC for 64/80/100 MHz.

   The ROM disassembly track should confirm each.
5. **QEMU as a reference.**
   - Report 8 BTLB slots on `-M 715` to exercise HP-UX's PCX-L paths.
   - Fix SIGP (review 03).
   - Consider making CR16's rate follow `-M 715`'s nominal 64 MHz.
6. **HP-UX 9.05 / 11.00.** Repeat this analysis for them, especially 9.x's fast-insert TLB handlers (QEMU notes an odd encoding) and 11.00's PDC needs. `tools/hpux` works on any SOM kernel.

---

## 8. FPGA requirement summary

| Block | Must be exact | Can approximate / omit |
|---|---|---|
| PDC data | MODEL info (hversion 0x60A0, sversion 0x481, arch_rev 4); CPU_ID fails; BTLB info fixed = 8; CACHE info consistent with the cache and TLB; HPA 0xFFFBE000; SYSTEM_MAP fails; MEM_MAP + 16-byte IODC for every reported module; MEM_10MSEC = CR16 rate/100; IMM size at 0x39C | PDC_TLB (may be -1); SOFT_POWER (fail); EEPROM 129 (fail); CHASSIS 128 (fail → Linux uses LASI LEDs) |
| IODC | relocatable ENTRY_INIT/ENTRY_IO for the console and boot device, callable from RAM in real mode | -- |
| Shadow regs / RFIR | capture on every interruption with Q=1; exact restore | -- |
| TLB | PA1.1 inserts, access rights, PIDs (4 × 15 bit + WD), T/D/B/U bits, traps 6/15/16/17/20/22/26/27; PxTLBE purges all page entries; BTLB insert via PDC | HW walker (only if PDC_TLB is offered) |
| Caches | FDCE/FICE loops per PDC_CACHE; FDC/FIC/PDC; U bit = uncached | geometry (report what you build); PIPT is fine |
| Timer | CR16 count/compare/EIRR0 at MEM_10MSEC×100 Hz | -- |
| Interrupts | EIRR/EIEM, write-1-clear, IO_EIR at CPU HPA; LASI IRR read-clear and IAR re-signal; never raise GSC 21; CPU HPA+0x30 ← 5 = TOC | LASI ICR TOC remap, RT mode |
| DIAG | MFCPU/MTCPU DR0 (Linux); diagnose regs PDC uses | DR25 power bit |
| Instruction set | B,GATE, BLR, BE/BLE inter-space, LDCW (ignore cc hint), branch in delay slot, `mfctl,w` = mfctl, 5-bit SAR | MAX-1 (user code only), fast inserts, LE mode, SPOP |
| LASI misc | LED latch 0xF00E0000; ERRLOG = 0; AMR = 0; VER readable; harmless store to 0xFFFC0020 | PCR power-off; floppy, ISDN, telephony |
| Devices | 53C710 SCRIPTS incl. SIGP/WAIT RESELECT, live DFE, LCRC, memory move (§4.2, 06d); 16550A (IIR 0xC1, TEMT); PS/2 (TBNE, CMPINTR, set 3); STI with a valid CRC + the Artist registers stifb uses | Harmony as a stub; LAN if not needed; WAX/EISA/HIL omitted |

