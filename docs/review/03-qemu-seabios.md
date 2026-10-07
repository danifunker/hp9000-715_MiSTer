# 03 — QEMU 11.1.1 + SeaBIOS-hppa as reference model for the HP 9000/715/64 core

Status: review + practical boot test, 2026-10-07.
Sources: `/home/dani/src/qemu-11.1.1` (QEMU 11.1.1 release tree, **not modified**),
bundled `roms/seabios-hppa` (SeaBIOS-hppa v25, binary `pc-bios/hppa-firmware.img`,
`seabios-hppa-v25-0-g6d6a72c2`). All `file:line` citations are relative to the QEMU
tree unless prefixed with `seabios:` (= `roms/seabios-hppa/`).
Work/scratch dir (binaries, logs, traces):
`/tmp/claude-1000/-home-dani-repos-hp9000-715/c636bb42-9bcf-47e9-83f8-8ade60a40f61/scratchpad/qemu`
(abbreviated `$S` below).

---

## 0. TL;DR

* QEMU 11.1.1 has a real `-M 715` ("HP 715/64 workstation") machine: LASI at 0xF0100000,
  NCR 53C710 SCSI, i82596 LAN, 16550 UART, parallel, LASI PS/2, Artist graphics. No PCI, no Dino.
  The **distro binary (8.2.2) does not have it** (only B160L/C3700) and the 11.1.1 build in
  `~/src/qemu-11.1.1/build` is sparc-only, so I built `qemu-system-hppa` 11.1.1 out-of-tree in
  `$S/build-hppa` (copy of the source in `$S/qemu-src`; 220 s on 6 cores incl. TCG plugins).
* The CPU is modelled as **PA-7300LC** (PA-RISC 1.1), not PA-7100LC; the machine comment says the
  difference is "only" the on-chip D-cache (machine.c:914-919). In practice there are more
  differences that matter for us (TLB size, MAX-1 gating, PCX-L DIAG encodings, see §2).
* SeaBIOS-hppa boots on `-M 715` and identifies itself as `HP 715 (32-bit PA1.1)` with a device
  inventory captured from a real 715/64 ("Mirage Jr") (seabios:src/parisc/715_64.h).
* **HP-UX 10.20 does NOT boot on `-M 715`**: PDC → ISL → `hpux` → kernel loads and starts,
  then the HP-UX LASI-SCSI driver loops forever resetting the 53C710. First root cause found: the
  QEMU NCR710 model does not implement **ISTAT.SIGP** (abort of a SCRIPTS `WAIT RESELECT`), which
  the HP-UX driver relies on. A ~25-line SIGP fix in a scratch copy gets one step further, then
  HP-UX panics with "I/O hardware probe timed out at path 2/0/1.0 … I/O system hang" (another
  SCRIPTS incompatibility, §B.3). The same image boots to multi-user (HP VUE / login offered) on
  `-M B160L`, the machine its run.sh uses.
* SeaBIOS-hppa can realistically be the boot ROM of the FPGA core, but only after removing or
  re-implementing its QEMU-only hooks (fw_cfg, artificial halt/reset/shadow opcodes, DIAG 0x100
  BTLB and DIAG 0x101 console, QEMU RTC/debug ports, 250 MHz CR16 assumption, lenient NCR710
  driver). See §4.6.
* Golden-reference tracing works: `-d in_asm,cpu,exec,nochain,int`, the `execlog` TCG plugin
  (beware: opcode column is byte-swapped), and the gdbstub (RSP verified with a raw client; no
  hppa-capable gdb is installed). Plugin register tracing is **not** available for hppa (no gdb XML).

---

## Part A — Source review

### A.1 `hw/hppa/machine.c` and `hw/hppa/hppa_hardware.h`

#### Machine types

| Machine | init | CPU | default RAM | notes |
|---|---|---|---|---|
| `B160L` (default) | `machine_HP_B160L_init` machine.c:656 | pa-7300lc | 512 MiB | LASI @0xFFD00000 + Dino PCI |
| `C3700` | machine.c:748 | pa-8700 | 1 GiB | Astro/Elroy |
| `A400` | machine.c:787 | pa-8500 | 1 GiB | memsplit at 1 GiB |
| **`715`** | `machine_HP_715_init` machine.c:578-651 | **pa-7300lc** (only valid type, machine.c:907-920) | **256 MiB** (machine.c:924) | max 8 CPUs (machine.c:923), default NIC `lasi_82596` (machine.c:925) |

Common class: `block_default_type = IF_SCSI`, boot order `cd`, default NIC tulip (machine.c:841-855).

#### 715 device list, HPAs and IRQs

All addresses pass through `translate()` (identity for PA1.1, see below).

| Device | QEMU type / call | HPA (phys) | LASI IRQ bit | cite |
|---|---|---|---|---|
| CPU0 EIR (interrupt word) | `hppa_io_eir_ops` | 0xFFFB0000 (+0x1000 per CPU) | — | machine.c:315-325, CPU_HPA hppa_hardware.h:27 |
| QEMU "RTC" + DebugOutputPort | `hppa_io_helper_ops` | 0xFFFB0010 (RTC), 0xFFFB0018 (debug char out) | — | machine.c:119-173, 346-351 |
| ISA bus (i8259 only, "for PS/2") | `hppa_isa_bus` | 0xF9000000, 0x800 bytes | — | machine.c:100-117, 596 (**overlaps Artist FB at 0xF9000000**, Artist added later wins) |
| LASI core | `lasi-chip` | **0xF0100000** (`LASI_HPA_715`) size 1 MiB | (bit 14 = LASI itself) | machine.c:600-604, hppa_hardware.h:23 |
| 16550 UART (serial_hd(0)) | `serial_mm_init`, 7.272727 MHz/16 | 0xF0105800 | 5 | machine.c:606-609 |
| Parallel | `parallel_mm_init` | 0xF0102800 | 7 | machine.c:611-614 |
| PS/2 kbd / mouse | `lasips2` | 0xF0108000 / 0xF0108100 | 26 (shared) | machine.c:616-628 |
| 53C710 SCSI | `lasi_ncr710_init` | 0xF0106000 (core regs at +0x100) | 9 | machine.c:629-636 |
| i82596 LAN | `lasi_82596` (only if a NIC/backend exists) | 0xF0107000 | 8 | machine.c:638-647 |
| Artist regs / FB | `artist` | 0xF8000000 (4 MiB) / 0xF9000000 (8 MiB) | — | machine.c:410-423, hppa_hardware.h:25-26 |
| fw_cfg | `fw_cfg_init_mem_nodma` | 0xFFFA0000 | — | machine.c:215, 457, hppa_hardware.h:50 |
| Firmware RAM | `memory_region_init_ram("firmware")` | 0xF0000000-0xF00FFFFF (1 MiB, writable) | — | machine.c:497-501, hppa_hardware.h:7-8 |
| Soft power button word | — | FIRMWARE_END-0x10 = 0xF00FFFF0 | — | machine.c:53-74, 313 |

LASI IRQ numbers: include/hw/misc/lasi.h:56-63 (UART 5, LPT 7, LAN 8, SCSI 9, Audio 13, LASI 14,
PS/2 26) — identical to Linux `lasi_choose_irq()`.

Not created on 715 although listed in the real 715/64 inventory: Harmony audio (0xF0104000),
PC floppy (0xF010A000), WAX EISA BA (0xFC000000), WAX BA (0xF0200000), WAX HIL (0xF0201000),
WAX RS-232 (0xF0202000) — SeaBIOS hides them with `HPA_DISABLED_DEVICE`
(seabios:src/parisc/715_64.h:519-561).

Note: because `block_default_type = IF_SCSI` and the machine does not set `no_cdrom`, QEMU always
creates an empty SCSI CD-ROM (index 2), so `drive_get_max_bus(IF_SCSI) >= 0` and the NCR710 is
instantiated even with no `-drive` (machine.c:630). Observed in the no-disk boot (§B.1).

#### RAM sizing

* PA1.x CPUs: `ram_max = FIRMWARE_START` = **3.75 GiB** (machine.c:305-311, 354-357). Real
  715/64 supports 32-256 MB (715 Service Handbook, "Main Memory").
* `memsplit_addr` defaults to FIRMWARE_START (machine.c:360-363); a single alias `memory0`
  0..splitaddr is mapped (machine.c:366-370).
* `RAM_MAP_HIGH1` (0x01_0000_0000, RAM above 4 GiB) and `RAM_MAP_HIGH2` (0x40_4000_0000, RAM
  between split and 4 GiB) are used **only for PA2.0** (machine.c:371-388, hppa_hardware.h:11-12).
  Irrelevant for the 715.

#### Firmware load, reset contract, fw_cfg

* Firmware = ELF `hppa-firmware.img` (32-bit) loaded with `load_elf(..., translate, ...)`; it must
  lie inside 0xF0000000-0xF0100000 (machine.c:459-495). `-bios`/`machine->firmware` overrides.
* Reset (machine.c:796-830): every CPU PC = ELF entry (0xF0000080 observed), `PSW = Q`,
  `gr5 = CPU HPA`; CPU0 additionally `gr26 = RAM size`, `gr25 = kernel entry / interactive-menu
  flag`, `gr24 = boot device letter ('c'/'d') or cmdline ptr`, `gr23/gr22 = initrd`,
  `gr21 = #CPUs`, `gr19 = FW_CFG_IO_BASE`. CPU reset itself sets PC 0xF0000004 and PSW=M
  (target/hppa/cpu.c:207-229), then the machine overrides it.
* fw_cfg items (machine.c:204-262): `FW_CFG_NB_CPUS`, `MAX_CPUS`, `RAM_SIZE`, `BOOT_DEVICE`,
  files `/etc/firmware-min-version` (=22), `/etc/cpu/tlb_entries` (256-16=240),
  `/etc/cpu/btlb_entries` (16), `/etc/hppa/machine` ("715"), `/etc/hppa/memsplit-addr`,
  `/etc/hppa/power-button-addr`, `/etc/hppa/rtc-addr` (CPU_HPA+16),
  `/etc/hppa/DebugOutputPort` (CPU_HPA+24), `/etc/qemu-version`. User options such as
  `-fw_cfg opt/console,string=serial|graphics`, `opt/pdc_debug`, `opt/font`, `opt/hostid`,
  `opt/power-button-enable` are read by SeaBIOS (seabios:src/parisc/parisc.c:3939-3977).
* Direct `-kernel` Linux boot is supported (`linux_kernel_virt_to_phys` masks to 256 MB,
  machine.c:177-181, 503-560) — useful for running Linux test kernels without a disk.

#### HVERSION / model reported

QEMU itself does not define HVERSION; SeaBIOS does (from a real 715/64):
`PARISC_MODEL "9000/715"`, `PARISC_PDC_MODEL 0x60a0, 0x481, ...` (hversion 0x60A0 = CPU
"Mirage Jr (715/64)" hv 0x60A, sversion 0x481), CPU IODC hv 0x60a sv 0x4
(seabios:src/parisc/715_64.h:30-33, 427-451). `PDC_MODEL_CPU_ID` returns BAD_OPTION on the
"snake" (715) machine on purpose, so HP-UX derives the CPU type from hversion
(seabios:src/parisc/parisc.c:1694-1696, 3889-3893). Real 715 CPU HPA is 0xFFFBE000 / memory HPA
0xFFFBF000, but SeaBIOS reports QEMU's `CPU_HPA` 0xFFFB0000 and `MEMORY_HPA` 0xFFFFF000
(715_64.h:567-578).

#### `translate`

`translate_pa10()` → `hppa_abs_to_phys_pa1x(32, addr)` = `extract64(addr, 0, 32)` (machine.c:186-190,
target/hppa/mem_helper.c:34-37): identity for 32-bit absolute addresses. `translate_pa20` folds the
0xF0000000 I/O window into the 64-bit F-extended space (mem_helper.c:55-80); not used for 715.

### A.2 `target/hppa` — CPU fidelity for a PA-7100LC

CPU types: `pa-7300lc` (PA1.1, 32 phys bits), `pa-8500` (PA2.0, 40 bits), `pa-8700` (PA2.0, 44 bits)
(target/hppa/cpu-qom.h:30-32, cpu.c:322-356). There is **no pa-7100lc type**; the 715 uses
pa-7300lc. Translator: decodetree (`insns.decode`, 657 lines) + `translate.c` (4905 lines), TCG,
MTTCG supported, strong memory model for PA1.x (cpu.c:254-262).

| Feature | QEMU behaviour | cite | Relevance for 7100LC RTL |
|---|---|---|---|
| GRs/SRs/CRs | GR[32], SR[8] (stored `<<32` to form a 64-bit GVA), CR[32], IIA queue back regs, 7 shadow regs, DR[32] | cpu.h:204-276 | SID width not limited to 16 bits (PCX-L has 16-bit SIDs, PCXL_ers "VPN = cat(SID[0:15], ...)") |
| TLB | **one unified 256-entry TLB**, first 16 entries = BTLB (`PA10_BTLB_FIXED 16, VARIABLE 0`), interval tree lookup, round-robin replacement | cpu.h:184-202, 245-268; mem_helper.c:82-167 | PCX-L: 64 page entries + 8 block entries UTLB + 1-entry ILAB (PCXL_ers.txt:1902). SeaBIOS is told 240/16 via fw_cfg (machine.c:224-230) |
| PA1.1 insert | `IITLBA/IDTLBA/IITLBP/IDTLBP` (both go to the unified TLB) | insns.decode:160-163; mem_helper.c:491-541 | ok |
| PCX-L fast insert | `ixtlbxf` (PCXL/PCXL2 "Fast TLB Insert", incl. HP-UX 9 odd encoding) implemented | insns.decode:165-168; translate.c:2651-2695 | nice: this is a 7100LC-specific op |
| HW TLB miss handler (PCX-L hardware page-table walker) | **not modelled**; SeaBIOS `PDC_TLB` returns BAD_PROC, so HP-UX uses software miss handlers | seabios parisc.c:2100-2116 | must be optional/disabled in RTL too, or ship PDC_TLB=BAD_PROC |
| BTLB | Only via QEMU-specific `diag 0x100` that implements PDC_BLOCK_TLB INFO/INSERT/PURGE/PURGE_ALL in C | insns.decode:643; translate.c:4574-4583; mem_helper.c:716-810 | real PCX-L inserts BTLB entries via DIAG writes + IxTLB (PCXL_ers.txt:1983-) |
| Protection | access rights, PL1/PL2, PID check (4 PIDs, WD bit), T/D/B bits, page reference / dirty / data-break faults | mem_helper.c:209-347 | ok |
| Space registers | SR0-7, SR4-7 "same" optimisation flag, `mtsp` privileged for SR5-7 | translate.c:2224-2245; cpu.c:93-97 | ok |
| DIAG | Implemented: `diag 0x100` (BTLB, QEMU-only), `diag 0x101` (console putc, QEMU-only), PCX-L2 encodings of get/put shadow regs (0x14001A00/0x14001A40), `mfdiag/mtdiag` (low bits 0x0600/0x1600) — just a register file `dr[]`, no side effects except DR2 on PA2.0; everything else → `DIAG opcode ... ignored` (no trap) | insns.decode:640-657; translate.c:4574-4640 | PCX-L encodings (MTCPU/MFCPU_T/MFCPU_C/TOC_EN/DIS/SHDW_GR/GR_SHDW/RDD/WDD/... PCXL_ers.txt:254-287) mostly *not* recognised; HP-UX 10.20 executes `0x141c1a00` on the 715 and QEMU ignores it (logged twice per boot) |
| Artificial insns | `0xFFFDEAD0` halt, `0xFFFDEAD1` reset, `0xFFFDEAD2` getshadowregs (used by SeaBIOS) | insns.decode:137-141; translate.c:2447-2517 | must be implemented by the FPGA core or patched out of SeaBIOS |
| Interval timer CR16 | read = `QEMU_CLOCK_VIRTUAL ns >> 2` → **fixed 250 MHz**; compare via QEMUTimer, raises EIRR bit 0 | op_helper.c:350-362; sys_helper.c:29-49; int_helper.c:79-83; hppa_hardware.h:56 | real 715/64: CR16 counts CPU clocks (64 MHz). PSW.S (secure IT) ignored (translate.c:2197) |
| EIRR / EIEM | EIRR set by 4-byte writes to the CPU HPA (bit = 31-data), `mtctl eirr` clears bits, interrupt taken when `PSW.I && (EIRR & EIEM)` | int_helper.c:29-91, 292-313; translate.c:2284-2316 | matches architecture; LASI uses this via IAR |
| Interruptions | IVA vectoring, IIASQ/IIAOQ, IIR/ISR/IOR, shadow regs on PSW.Q, HPMC on bus error (unassigned I/O → HPMC), TOC (NMI) → PDC TOC at 0xF0000000 | int_helper.c:93-275; mem_helper.c:419-436 | ok |
| Traps never raised | recovery counter (PSW.R), taken-branch (PSW.T), higher/lower privilege transfer (PSW.H/L), assist-emulation (SPOP/COPR), performance monitor | int_helper.c:223-268 (names only); helper.c:82-92 | SPOP/COPR are simply not decoded → illegal instruction instead of assist-emulation trap |
| PSW.E (little endian), PSW.Y/Z | not implemented (masked as reserved) | translate.c:103-107; helper.c:89-91 | PCX-L supports LE data and LE instruction fetch (PCXL_ers.txt:3260-3262, 3402-3405) |
| Alignment | all accesses `MO_ALIGN` in system mode → precise unaligned-data-reference trap with IOR/ISR | translate.c:4657; cpu.c:163-175 | ok. LDCW only requires 4-byte alignment (QEMU comment: "hppa1.1 ... undefined unless aligned mod 16, real hw succeeds mod 4") translate.c:3351-3355 |
| MAX-1 multimedia (HADD/HADD,SS/US, HSUB, HAVG, HSHLADD, HSHRADD) | decoded, but **gated to PA2.0** (`if (!ctx->is_pa20) return false` → illegal instruction on pa-7300lc) | insns.decode:217-257; translate.c:3094-3200 | **bug for PA-7100LC/7300LC**: both implement MAX-1 (PCXL_ers.txt:3264-3270). MAX-2 ops (HSHL/HSHR/MIXH/MIXW/PERMH) are correctly PA2.0-only |
| PA2.0-only forms (`,*` conditions, 64-bit loads/stores, LDD/STD, etc.) | rejected on PA1.1 | translate.c:3303-3335, 3516-3952 | ok |
| Caches | not modelled: FDC/PDC/FDCE are NOPs, FIC/FICE just end the TB, `LCI` returns 0 | insns.decode:150-156; translate.c:2519-2524, 2747-2759 | RTL must handle real cache coherency itself; QEMU cannot catch missing flushes |
| FPU | all ops via **softfloat** (`fpu/softfloat.h`), rounding modes from FPSR.RM, D-bit → flush-to-zero; `fmpyadd/fmpysub` (PA1.1), `fmpyfadd` (PA2.0), `xmpyu`; exceptions: enabled IEEE exceptions **trap immediately** (EXCP_ASSIST on the faulting op) and only exception register #1 is filled; over/underflow both reported as overflow in fr1 | fpu_helper.c:23-80, 93-135; insns.decode:363-373, 460-638 | real PA1.1 FP traps are *delayed* (T-bit, signalled on the next FP op, exception queue fr0-fr7); 7100LC has no HW denormal support (unimplemented-exception trap to SW emulation) — QEMU computes denormals silently |
| Little extras | `swap_system_mask` allows Q 0→1 via SSM (HP-UX 10.20 needs it) | sys_helper.c:63-76 | note for RTL |

**Not modelled / stubbed PA-RISC 1.1 (PCX-L) features (summary):** caches and their DIAG
access, PCX-L DIAG instruction set (except a PCX-L2 subset), HW TLB walker, real TLB geometry
(64+8) and replacement, BTLB insertion via DIAG, recovery counter / taken-branch / privilege-
transfer traps, assist-emulation trap for SPOP/COPR, little-endian mode, delayed FP traps and
FP exception queue, unimplemented-exception (denormal) traps, MAX-1 on PA1.1, secure interval
timer (PSW.S), real CR16 frequency, TOC enable/disable DIAG, cache/TLB parity HPMCs, and any
timing (no pipeline/branch-delay timing; nullification and branch delay slots are functionally
correct).

### A.3 Devices

#### LASI core — `hw/misc/lasi.c`
Registers accepted (lasi.c:25-53): `IRR`(0x00, computed live as `IPR & IMR`, lasi.c:64-74),
`IMR`(0x04), `IPR`(0x08, read-to-clear / write-to-clear), `ICR`(0x0C, only bus-error bit readable),
`IAR`(0x10, default 0xFFFB0003 = CPU0 EIR, bit 3 → EIRR bit 28; lasi.c:260-268), sub-device
"reset" words at LPT/AUDIO/AUDIO+4/UART/LAN/LAN+12/RTC/FDC/SCSI..+0xFF (ignored),
`PCR`(0xC000, write 2 = power off), `ERRLOG`(0xC004), `VER`(0xC008, reads 0), `IORESET`(0xC00C,
no-op), `AMR`(0xC010). `LASI_RTC` (0x9000) is a QEMU invention: 32-bit seconds counter
(lasi.c:98-101, 177-179). Any other offset in the 1 MiB window → invalid access → HPMC.
Interrupt delivery (lasi.c:238-258): level-triggered input sets IPR; if unmasked and ICR bus-error
bit clear, LASI writes `IAR & 31` to physical `IAR & ~31` (GSC "interrupt transaction" to the
CPU EIR). TOC via ICR bit 1 is a TODO (lasi.c:150-153). No LASI version/config registers
(`LASI_IO_CONF` 0x7FFFE/0x7FFFF defined but not accepted, lasi.h:42-43).

#### Artist — `hw/display/artist.c` (1516 lines)
* Default 1280×1024×8 (props width/height/depth, artist.c:1483-1486); allowed 640×480 … 2048×2048
  (artist.c:1383-1393). Line stride is fixed 2048 bytes in the address decode
  (`ADDR_TO_X/Y`, artist.c:209-211).
* Memory: register window 4 MiB at 0xF8000000, VRAM window 8 MiB at 0xF9000000 (artist.c:1346-1357).
  Internal buffers: `cmap` 2048×4 bytes (palette at +0x400, 256 entries × 32-bit), `ap` (the
  visible 8-bit image plane, width×height), `cursor1`/`cursor2` 64×64, `attribute` 64×64
  (artist.c:106-115, 1398-1406). **No overlay planes** (ARTIST_BUFFER_OVERLAY is declared, never
  created), attribute plane not used for display, no double buffering, no 24-bit modes.
* Raster ops: only CLEAR(0), COPY(3), XOR(6), NOT_DST(10), SET(15); others logged as unsupported
  (artist.c:155-161, 274-313). Plane mask: low 8 bits (artist.c:287). FG/BG colour,
  `IMAGE_BITMAP_OP` bits (transparency 0x10000002 and bitmask enable 0x20000000).
* Operations: block move (`BLOCK_MOVE_*`, artist.c:383-448), window fill (`VRAM_SIZE_TRIGGER`,
  artist.c:450-489, with an unexplained `reg_100080 == 0x7d` Y auto-increment hack), Bresenham
  lines and pattern lines (artist.c:491-680), font write (`FONT_WRITE_*`, artist.c:690-735),
  colour-expand / byte writes through `DST_BM_ACCESS` modes 0x3ba0/0xbbe0/0x1360/0x13a0/0x2ea0/0x28a0
  (artist.c:813-859), reads via `SRC_BM_ACCESS` 0x3ba0/0x13a0/0x2ea0 (artist.c:871-907).
* `CONTROL_PLANE != 0` → block move / fill are **not performed** (artist.c:395-398, 463-466).
* FIFOs not emulated: FIFO1/FIFO2 always "ready" 0x10 (artist.c:1179-1185). V-blank simulated by
  toggling a bit on every read of MISC_VIDEO (artist.c:1199-1205). Screen size readable at
  0x211110 (artist.c:1165-1170). Magic ID 0x6DC20006 at 0x380004 is a QEMU/SeaBIOS convention for
  detection (artist.c:1214-1217; seabios parisc.c:628-633).
* Cursor: hardware supports 64×64, emulated 32×32 (artist.c:105-106); writes to HORIZ_BACKPORCH
  are overridden ("fix X cursor position", artist.c:1064-1068); position math taken from X11R6.6.
* Typo/bug: `case 300104:` (decimal) in the register write switch (artist.c:1118).
* No interrupts, no DMA, no STI ROM in the device (STI comes from SeaBIOS).

#### 53C710 SCSI — `hw/scsi/ncr53c710.c` (2473 lines) + `hw/scsi/lasi_ncr710.c`
* LASI wrapper (lasi_ncr710.c): id word at +0x000 = `(HPHW_FIO<<24) | 0x082` = 0x05000082,
  HVERSION 0x3D at +0x008, NCR registers at +0x100; **byte accesses are address-XOR-3**
  (big-endian bus to little-endian chip), multi-byte accesses split into bytes (lasi_ncr710.c:31-114).
  8 targets × 8 LUNs, TCQ (lasi_ncr710.c:138-146).
* Core: high-level SCRIPTS interpreter (block move, select/reselect, wait disconnect/reselect,
  set/clear, register R/W, memory move, jumps/calls/int), DMA directly into guest RAM, SCSI
  phases abstracted on top of QEMU's SCSI layer; FIFO/parity helpers; "low-level mode" not
  implemented (ncr53c710.c:1317-1720, comment at 1450-1454).
* **Missing: ISTAT.SIGP semantics.** SIGP (0x20) is defined (ncr53c710.c:68) but never acted on:
  the ISTAT write handler only stores it (ncr53c710.c:2135-2155) and `WAIT RESELECT`
  (ncr53c710.c:1483-1487) waits forever instead of jumping to its alternate address when SIGP is
  set; CTEST2.SIGP is not reflected/cleared on read (ncr53c710.c:1859-1862). This breaks HP-UX
  10.20 (§B.3).

#### LASI PS/2 — `hw/input/lasips2.c`
Two ports (kbd at +0x000, mouse at +0x100 of LASI+0x8000), registers ID(0)/RCVDATA(4)/CONTROL(8)/
STATUS(0xC) for read and RESET(0)/XMTDATA(4)/CONTROL(8) for write (lasips2.c:64-93); loopback and
"diag" (clock/data shadow) bits supported, CMPINTR combined status; data comes from QEMU's
generic PS/2 kbd/mouse (lasips2.c:150-250).

#### i82596 LAN — `hw/net/i82596.c` (2178 lines) + `hw/net/lasi_i82596.c`
LASI port interface: `+0 reset`, `+4 CPU PORT` (two 16-bit halves, low first), `+8 channel
attention`, `+12` = QEMU-only "write MAC to address" helper for PDC_LAN_STATION_ID (reads return
0xBEEFBABE) (lasi_i82596.c:25-79). Default MAC 08:00:09:EF:34:F6 (lasi_i82596.c:141-144).
Core supports SCB/CBL processing, commands NOP/IA-setup/Configure/TDR/Transmit/MC-setup/Dump/
Diagnose (i82596.c:1688-1710), linear/segmented modes from SYSBUS (i82596.c:1926-1931), simplified
and flexible RFD/TBD, CRC, statistics, bus throttle timer, loopback, promiscuous/monitor modes.
Only created if a NIC is configured (`qemu_create_nic_device(TYPE_LASI_82596, true, "lasi")`);
note this local build has **no slirp**, so `-net user` is unavailable.

#### Devices a real 715/64 has that QEMU does not model
* **Harmony audio** (LASI+0x4000, sv 0x7B): absent — `grep -ri harmony` only hits u-boot/edk2.
  LASI just swallows writes to AUDIO/AUDIO+4 (lasi.c:161-164).
* **PC floppy** (LASI+0xA000): absent (only a reset word).
* **WAX** (EISA bridge 0xFC000000, WAX BA 0xF0200000, HIL 0xF0201000, 2nd RS-232 0xF0202000): absent.
* **Stable storage / EEPROM** (System EEPROM UV17 in the 715 service handbook): not modelled;
  SeaBIOS keeps 512 bytes stable + 512 bytes non-volatile storage in RAM (lost on power-off)
  (seabios parisc.c:1458-1467, 1934-1998).
* **TOD clock / calendar battery**: no real RTC chip; QEMU-only 32-bit seconds counters at
  CPU_HPA+16 and LASI+0x9000.
* **LEDs / LCD / chassis codes**: PDC_CHASSIS only prints to console (seabios parisc.c:1540-1590).
* ISDN/telephone LASI functions, LASI version/config registers, GSC bus arbitration/error
  registers (beyond ERRLOG/AMR storage), 24-plane/HCRX graphics options.

### A.4 SeaBIOS-hppa (`roms/seabios-hppa`, v25)

* **715 support**: machine table built from auto-generated headers (`715_64.h` from a real
  715/64 via Linux `PARISC_QEMU_MACHINE_HEADER`), compiled only into the 32-bit image
  (seabios parisc.c:404-424). Selection by fw_cfg `/etc/hppa/machine == "715"` sets `is_snake=1`,
  no PCI, `lasi_hpa = LASI_HPA_715`, console = LASI UART, keyboard via LASI PS/2, boot = LASI SCSI
  (seabios parisc.c:3889-3906). PDC_MODEL / PDC_CACHE_INFO / device inventory (incl. real IODC
  bytes, module paths) come from the header (715_64.h:30-49, 480-578). PDC_SYSTEM_MAP is refused
  for "snake" machines like on real hardware (parisc.c:2219-2223).
* **PDC procedures handled** (`parisc_pdc_entry`, parisc.c:2970-3168): POW_FAIL (nop), CHASSIS
  (DISP/DISPWARN/WARN/RETURN_INFO), PIM (HPMC/RETURN_SIZE/LPMC/SOFT_BOOT/TOC), MODEL (INFO/
  VERSIONS/SYSMODEL/ENSPEC/DISPEC/CPU_ID/CAPABILITIES/GET_INSTALL_KERNEL/GET_PLATFORM_INFO), CACHE
  (INFO/RET_SPID), HPA (PROCESSOR/MODULES), COPROC (CFG), IODC (READ/NINIT/DINIT/MEMERR), TOD
  (READ/WRITE/CALIBRATE), STABLE (READ/WRITE/RETURN_SIZE/VERIFY/INITIALIZE), NVOLATILE (same),
  ADD_VALID, PROC, BLOCK_TLB (via QEMU diag 0x100), TLB (→BAD_PROC), MEM (64-bit only), PSW,
  SYSTEM_MAP (FIND_MODULE/FIND_ADDRESS/TRANSLATE_PATH), SOFT_POWER, CRASH_PREP (nop), MEM_MAP,
  NVM, IO (READ_AND_CLEAR_ERRORS/RESET/RESET_DEVICES), BROADCAST_RESET, LAN_STATION_ID, SYSTEM_INFO,
  PCI_INDEX, RELOCATE, INITIATOR, plus PAT_* for 64-bit PAT machines. INSTR, CONFIG, SCSI_PARMS →
  BAD_PROC. Unknown procs print a warning.
* **IODC**: not read from devices. `PDC_IODC_READ` returns the static `struct pdc_iodc` bytes
  from the machine header for index 0, and for ENTRY_* indices copies a generic 512-byte
  `iodc_entry` trampoline that calls back into firmware C code `parisc_iodc_ENTRY_IO/INIT/SPA/
  CONFIG/TEST/TLB` (parisc.c:1203-1445, 1853-1890). ENTRY_IO implements COUT/CIN (serial or STI),
  BOOTIN/BBLOCK_IN/BOOTOUT (via SeaBIOS block layer), CLOSE.
* **STI / text console for Artist**: SeaBIOS ships its own STI ROM image (`stirom.c`, 3679 lines):
  graphics_id 0x2B4DED6D40A00499 (Artist), monitor table 1280×1024/1024×768/768×600/640×480
  @72 Hz, functions `init_graph, state_mgmt, font_unpmv, block_move, self_test, excep_hdlr,
  inq_conf, set_cm_entry, dma_ctrl` (seabios stirom.c:3264-3550); fonts 8×16, 6×13, 10×20 and
  Terminus 16×32 (stirom.c:48-1212). `sti.c` drives it for the firmware console
  (region pointers 0xF9000000/0xF8100000/0xF8380000, sti.c:35-37). The STI code is written for
  QEMU's Artist register subset (bitmap op 0x03000300, BM access 0x2ea01000, etc.,
  stirom.c:3303-3330).
* **Boot devices**: SeaBIOS block layer; for the 715 a new GSoC-2025 `hw/ncr710-scsi.c` driver
  (LGPLv3) probes LASI+0x6000 id 0x05000082 (seabios src/hw/ncr710-scsi.c:313-324). It is a
  minimal polling SCRIPTS driver: SELECT without ATN (no IDENTIFY message), always sends a
  **16-byte CDB**, assumes a fixed DATA→STATUS→MSG-IN sequence, polls ISTAT/DSTAT/SSTAT
  (ncr710-scsi.c:84-180). Works with QEMU's lenient target emulation; would not work unmodified
  against real SCSI devices (6/10-byte CDB groups, phase changes).
* **Memory reported**: `ram_size` from fw_cfg, clipped at 3.75 GB; PAGE0 `memc_cont/phsize/adsize`,
  `imm_max_mem`, `imm_spa_size` (parisc.c:3911-3925, 4005-4029). Banner prints "Available memory"
  and "Good memory required: 16 MB" (parisc.c:4134-4145).
* **Build**: `make parisc` → `Makefile.parisc` with `CROSS_PREFIX=hppa-linux-gnu-` (32-bit) and
  `hppa64-linux-gnu-` (64-bit) (seabios Makefile:105-117, Makefile.parisc). Needs a hppa cross
  gcc/binutils (Debian/Ubuntu `gcc-hppa-linux-gnu`, `binutils-hppa64-linux-gnu`) — **not installed
  on this machine** (no `hppa-linux-gnu-gcc` in PATH). Output is an ELF (`out/hppa-firmware.img`,
  634 KB in pc-bios).
* **Licence**: SeaBIOS is LGPLv3 (source headers "distributed under the terms of the GNU LGPLv3
  license"; `COPYING` = GPLv3, `COPYING.LESSER` = LGPLv3). The STI fonts include Terminus (from
  Linux, OFL/GPL-compatible). Shipping it as a separately loaded ROM file with an FPGA core is
  unproblematic; linking it into a GPLv2-only artefact would not be.

#### A.4.1 Could SeaBIOS-hppa be the FPGA boot ROM? — Assessment

Yes, it is the most practical open PDC we have: it already knows the 715/64 inventory, and on
QEMU it loads ISL and the HP-UX kernel on the 715 (the remaining HP-UX failure is in QEMU's
53C710 model, not in SeaBIOS, §B.3) and boots HP-UX fully on the B160L. Required changes (or
matching FPGA features):

1. **fw_cfg** (0xFFFA0000, selector/data at +0/+4): either implement a tiny fw_cfg-compatible ROM
   block in the FPGA (simplest: a BRAM table with the ~12 items listed in §A.1, filled by the
   MiSTer HPS), or patch `parisc.c` to hard-code machine "715", RAM size (from a strap register),
   1 CPU, TLB counts. Without `/etc/hppa/machine` the 32-bit firmware defaults to **B160L**
   (parisc.c:3838-3843).
2. **Entry register contract** (machine.c:817-823: gr26 RAM size, gr25, gr24 boot dev, gr21 CPUs,
   gr19 fw_cfg, gr5 CPU HPA): a 5-instruction shim at the reset vector or a SeaBIOS patch.
3. **QEMU-only instructions**: `0xFFFDEAD0/1/2` (halt/reset/getshadowregs) and `diag 0x100`
   (whole PDC_BLOCK_TLB in C inside QEMU) / `diag 0x101` (console char). Options: implement them
   as custom ops in the core (cheap; BTLB insert = write one of 8 BTLB entries), or replace them in
   SeaBIOS with the real PCX-L sequences (BTLB insert via DIAG + IxTLB, PCXL_ers.txt:1983-2040;
   GR_SHDW/SHDW_GR DIAG 0xd2/0xd0; reset via CPU HPA command or LASI; halt via LASI PCR=2).
   Note `sr_hashing_enabled` already uses the real PCX-L `mfdiag %dr0` encoding 0x141C0600.
4. **RTC and debug port**: QEMU-only words at CPU_HPA+16/+24 (or LASI+0x9000). Implement a
   32-bit seconds counter (fed from the MiSTer RTC) — trivial — or drop.
5. **CR16 frequency**: `CPU_CLOCK_MHZ 250` is hard-coded (hppa_hardware.h:56) and used for
   PDC_TOD calibrate, PAGE0 `mem_10msec` and delays (parisc.c:1925, 4012). Must be set to the real
   core clock.
6. **CPU/memory HPAs**: SeaBIOS uses QEMU's 0xFFFB0000/0xFFFFF000 instead of the real
   0xFFFBE000/0xFFFBF000. Either decode both in the FPGA or change `CPU_HPA`/`MEMORY_HPA`.
7. **NCR710 driver**: harden (IDENTIFY message, correct CDB length, phase-driven script) if the
   FPGA 53C710 talks to real/emulated SCSI targets with real phase behaviour.
8. **Artist/STI**: the STI ROM assumes QEMU's Artist subset; the FPGA Artist must implement at
   least those registers (BM access modes, bitmap op, block move, window fill, font colour-expand,
   cmap). A dummy at 0xF8380004 returning 0x6DC20006 is how SeaBIOS detects it.
9. **Stable storage**: back the 512-byte stable/NV arrays with real EEPROM/SD storage if boot
   path/autoboot must persist.
10. **Build**: needs hppa-linux-gnu cross toolchain; produce a flat image for 0xF0000000 with
    objcopy; the 1 MiB firmware window must be RAM (SeaBIOS writes its data there).

Alternative: a real HP PDC image (e.g. the 712 firmware update "C7120023.frm" used by QEMU's
own `tests/functional/hppa/test_cdboot.py` asset) would exercise the hardware more faithfully, but
needs full device fidelity (caches, DIAG, EEPROM, real IODC ROMs) — SeaBIOS is the right first step.

### A.5 Tests usable as a CPU test bench

* `tests/tcg/hppa/`: only `stby.c` (STBY,B/E store-bytes semantics, linux-user) and a
  Makefile that disables `signals` (tests/tcg/hppa/Makefile.target). Multiarch linux-user tests
  (`tests/tcg/multiarch/`: sha1/sha512/float_convs/float_madds/fnmsub/...) can run on
  `qemu-hppa` with an hppa cross compiler, but there is **no hppa system-mode TCG test harness**
  (no `tests/tcg/hppa/system/` boot stub).
* `tests/functional/hppa/test_seabios.py`: checks SeaBIOS banner for B160L/A400 only (not 715).
  `test_cdboot.py`: boots HP's 712 firmware-update CD (`C7120023.frm`) on B160L.
* `tests/qtest`: only generic filter/VGA tests for hppa (tests/qtest/meson.build:152-154).
* Conclusion: QEMU provides no ready PA-RISC ISA conformance suite. Use QEMU as a lock-step
  golden model instead (§B.4): run the same bare-metal test ROMs / SeaBIOS / Linux kernel in QEMU
  and in the RTL simulator and diff the retired-instruction streams.

---

## Part B — Practical test boot

### B.0 Which binary

| binary | version | `-machine help` |
|---|---|---|
| `/usr/bin/qemu-system-hppa` (Ubuntu) | 8.2.2 | B160L, C3700 only — **no 715** |
| `~/.local/qemu-11.1.1/bin` | — | no hppa binary installed (only tools) |
| `~/src/qemu-11.1.1/build` | 11.1.1 | configured `--target-list=sparc-softmmu` only |
| **`$S/build-hppa/qemu-system-hppa`** (built by me) | 11.1.1 | 715, A400, B160L (default), C3700; CPUs pa-7300lc, pa-8500, pa-8700 |

Build recipe (source copied to `$S/qemu-src` with rsync so the original tree is untouched):
`$S/qemu-src/configure --target-list=hppa-softmmu --enable-plugins --disable-docs --disable-werror --disable-gtk --disable-sdl --disable-opengl --disable-spice && ninja -j6`
→ **220 s wall on 6 cores**, includes all `contrib/plugins/*.so` (TCG plugins are on by default).
An incremental rebuild after touching one device file took 3.5 s. Rust disabled, **slirp not
available** (no `-net user`). Copies: `$S/qemu-system-hppa-11.1.1-unpatched` (pristine) and
`$S/qemu-system-hppa-11.1.1-sigp-experiment` (§B.3); copies need `-L $S/qemu-src/pc-bios`.

### B.1 `-M 715`, no disk, serial console

`timeout 60 qemu-system-hppa -M 715 -nographic` (identical output with `-serial mon:stdio`),
log `$S/logs/boot-715-nodisk-nographic.log`:

```
SeaBIOS PA-RISC 32-bit Firmware Version 25 (QEMU 11.1.1)
Duplex Console IO Dependent Code (IODC) revision 25
------------------------------------------------------------------------------
  (c) Copyright 2017-2026 Helge Deller <deller@gmx.de> and SeaBIOS developers.
------------------------------------------------------------------------------
  Processor   Speed            State           Coprocessor State  Cache Size
  ---------  --------   ---------------------  -----------------  ----------
      0      250 MHz    Active                 Functional            0 KB

  Emulated machine:     HP 715 (32-bit PA1.1), 32-bit PDC, OS32
  Available memory:     256 MB
  Good memory required: 16 MB

  Primary boot path:    FWSCSI.0.0
  Alternate boot path:  SCSI.2.0
  Console path:         SERIAL_1.9600.8.none
  Keyboard path:        SERIAL_1.9600.8.none

  Available boot devices:
  FWSCSI.2.0 : DVD/CD [ncr710 2:0 QEMU QEMU CD-ROM 2.5+]

Booting from FWSCSI.2.0 ...
(hangs on the empty default CD-ROM until the timeout)
```

`-d unimp,guest_errors` shows only the firmware probing for Artist (absent with `-nographic`):
`HPMC at ...:f00105f8 while accessing I/O at 0xf8380004` (×2).
With `-boot menu=on` the PDC-style menu appears (`$S/logs/boot-715-nodisk-menu.log`): commands
are only `BOot [PRI|ALT|<path>]`, `HElp`, `RESET`, `EXIT` — far smaller than a real HP PDC
boot console (no SEArch/PAth/COnfig/INformation/SErvice menus).

### B.2 HP-UX 10.20 image

Extracted to `$S/hpux1020/` (`hpux.img` = qcow2 v3, 4 GiB virtual / 1.39 GB on disk; extraction
48 s). `run.sh` of the image author:

```
qemu-system-hppa -machine B160L -accel tcg,thread=multi -smp cpus=4 -boot c -boot menu=off \
  -drive if=scsi,bus=0,index=6,file=hpux.img,format=qcow2 -m 512 -d nochain \
  -net nic,model=tulip -net user,tftp=/tmp
```

i.e. it was installed on a **B160L** (LSI 53C895A on Dino PCI, tulip NIC, 4 CPUs, 512 MB). On the
715, `lasi_ncr710_handle_legacy_cmdline()` (hw/scsi/lasi_ncr710.c:199-225) picks up
`-drive if=scsi,bus=0,index=6` as target 6 on the LASI 53C710, so the same `-drive` option works.
All runs used `-snapshot` (image never modified), `-nographic`, `-boot c -boot menu=off`.
Script: `$S/run-715-hpux.sh`.

#### B.2.1 `-M 715 -m 256` (stock QEMU 11.1.1) — fails after kernel start

Log `$S/logs/hpux-715-m256.log` (420 s timeout):

```
  Emulated machine:     HP 715 (32-bit PA1.1), 32-bit PDC, OS32
  Available memory:     256 MB
  Primary boot path:    SCSI.6.0
  Alternate boot path:  SCSI.2.0
  Available boot devices:
  FWSCSI.6.0 : DISK [ncr710 6:0 QEMU QEMU HARDDISK 2.5+]
  FWSCSI.2.0 : DVD/CD [ncr710 2:0 QEMU QEMU CD-ROM 2.5+]
Booting from FWSCSI.6.0 ...
Booting...
Boot IO Dependent Code (IODC) revision 25
HARD Booted.
ISL Revision A.00.38  OCT 26, 1994
ISL booting  hpux
Boot
: disk(2/0/1.6.0.0.0.0.0;0)/stand/vmunix
3957260 + 450560 + 593184 start 0x18fe68
<no further output for 6+ minutes, CPU 100 %>
```

So PDC → ISL (from LIF, via SeaBIOS NCR710 driver) → `hpux` secondary loader → kernel load all
work on the 715. `-d unimp,guest_errors` during the kernel phase:

```
DIAG opcode 0x1c1a00 ignored          (x2; insn 0x141c1a00 at kernel 0x1bcc8/0x1bccc)
HPMC at 0000000000000000:000000000017d038 while accessing I/O at 0xfffc0020   (benign probe, also on B160L)
```

`0x141c1a00` is a PCX-L diagnose (`mfcpu`-style read of a CPU diag register into r28, issued
twice after `sync`, at kernel 0x1bcc8); QEMU only matches the PCX-L2 encodings and ignores it.
It is not what hangs the boot. An `-d in_asm,int` trace (`$S/logs/hpux-715-inasm-int.trace.gz`)
shows the kernel alive (interval-timer interrupts, TLB misses) spinning in a CR16-based delay loop
at 0xd27ac. A `-trace lasi_chip_* -trace ncr710_*` run (`$S/logs/hpux-715-ncr-regs.trace`) shows
the HP-UX 53C710 driver doing, in a loop every ~10 s:

```
lasi IAR <- 0xfffb0003, IMR <- 0x00204200          (SCSI irq 9 enabled)
ISTAT<-40 (chip reset), DCNTL<-01, SCNTL0<-cc, CTEST0<-50, DMODE<-c0, ... SCID<-80, SIEN<-af, DIEN<-7f
DSP <- 0x017720f8                                   (start SCRIPTS: first insn is WAIT RESELECT, DCMD=0x50)
ISTAT <- 0x20                                       (SIGP: "new command queued")
read DCMD=0x50, SBCL=0x00, ISTAT=0x20               (script still sitting in WAIT RESELECT)
SCNTL1<-08 (SCSI bus reset) ... chip reset ... retry
```

### B.3 Root cause and a scratch-only experiment

The HP-UX 10.20 LASI/53C710 driver idles the SCRIPTS processor in `WAIT RESELECT` and kicks it
with **ISTAT.SIGP**; on a real 53C710 SIGP makes `WAIT RESELECT` branch to its alternate
address. QEMU's model never implements this (see §A.3: ncr53c710.c:68, 1483-1487, 1859-1862,
2135-2155), so the script never leaves `WAIT RESELECT` and the driver times out forever.

To confirm, I patched **only the scratch copy** (`$S/qemu-src`, patch `$S/ncr710-sigp-experiment.patch`,
~25 lines: SIGP during/at `WAIT RESELECT` → jump to `DNAD` and continue SCRIPTS; CTEST2.SIGP
mirrors and clears ISTAT.SIGP). With that binary (`$S/logs/hpux-715-sigp-run2.log`,
`$S/logs/hpux-715-sigp-ncr.trace`) the driver gets further: the target-0 selection times out
correctly and the interrupt is delivered through LASI (IRR=0x200), but the next script run ends
in a SCRIPTS `INT 0x0F` (DSTAT 0x04, DSPS 0x0000000F) that the driver treats as a hang; after
repeated resets HP-UX panics and reboots, and the message buffer printed at the next boot tells
the story:

```
SCSI: Third party detected bus hang -- lbolt: 23109, bus: 2
        lbp->uPhysScript: 1772000
    From most recent interrupt:
        ISTAT: 21, SIST0: 00, SIST1: 00, DSTAT: 04, DSPS: 0000000f
SCSI: Resetting SCSI -- lbolt: 23409, bus: 2
I/O hardware probe timed out at path 2/0/1.0

System Panic:
   B2352B HP-UX (B.10.20) #1: Sun Jun  9 08:03:38 PDT 1996
panic: (display==0xbc00, flags==0x0) I/O system hang
PC-Offset Stack Trace (read across, most recent is 1st):
  0x0022487c  0x001df1e8  0x00125250  0x001252d8  0x00202dbc  0x000b0394
  0x00208d98  0x000d27ac  0x000d0e70
...
SeaBIOS wants SYSTEM RESET.
```

Conclusion: **HP-UX 10.20 cannot currently boot on QEMU 11.1.1 `-M 715`**; the 53C710 SCRIPTS
emulation (written for Linux' `53c700` driver and SeaBIOS) lacks at least SIGP plus one more
SCRIPTS behaviour the HP-UX driver depends on. For our project this is a useful warning: the
FPGA 53C710 must implement the full SCRIPTS semantics (SIGP, WAIT RESELECT alternate jump, the
SCRIPTS interrupt/phase behaviour HP-UX expects); QEMU's model is not a sufficient reference for
that block. (This is also worth reporting upstream to Helge Deller / the GSoC-2025 NCR710 author.)

### B.4 Same image on `-M B160L` (run.sh machine) — boots to multi-user

`qemu-system-hppa -M B160L -m 512 -accel tcg,thread=multi -smp cpus=4 -nographic -snapshot ...`
(no NIC because no slirp; a delayed `n` answered the DHCP prompt). Log
`$S/logs/hpux-B160L-login-run2.log`:

```
  Emulated machine:     HP B160L (32-bit PA1.1), 32-bit PDC, OS32
  Available memory:     512 MB
  FWSCSI.6.0 : DISK [lsi 00:00.0 6:0 QEMU QEMU HARDDISK 2.5+]
ISL Revision A.00.38  OCT 26, 1994
ISL booting  hpux
Unknown NIO card type 0x0
: (8/0/0/0.6.0.0.0.0.0;0)/stand/vmunix
3957260 + 450560 + 593184 start 0x18fe68
vuseg=201f000
    System Console is on the Built-In Serial Interface
Logical volume 64, 0x3 configured as ROOT
Checking root file system.
    B2352B HP-UX (B.10.20) #1: Sun Jun  9 08:03:38 PDT 1996
    Physical: 524288 Kbytes, lockable: 399888 Kbytes, available: 461540 Kbytes
/sbin/bcheckrc: ... vxfs fsck: sanity check: root file system OK
/sbin/auto_parms, checking network for DHCP server
 ... Do you wish to halt the system now? [y/n default 'y'] ? n
     HP-UX Start-up in progress
     Mount file systems ........................................ OK
     ... (≈50 rc steps, all OK/N/A) ...
*  The X-server can not be started on display hpux:0 ...
*  Suspending HP VUE...
*  Press [Return] for a login prompt.
```

i.e. kernel → rc → HP VUE → serial login offered, in ≈5 min wall time. Differences vs 715: Dino PCI
+ LSI 53C895A ("c720" driver path `8/0/0/0.6.0`) instead of LASI 53C710 (`2/0/1.6.0`), CPU
reported as PA-7300LC/B160L (hversion of B160L) instead of PCX-L "Mirage Jr", 4 CPUs. The B160L
run also touches `0xfffc0020` and `0xfffff000` (MEMORY_HPA) with harmless HPMC probes.

### B.5 Golden-reference tracing, gdbstub

| Mechanism | Works for hppa? | Notes |
|---|---|---|
| `-d in_asm` | yes | big-endian opcode bytes + disassembly per translated TB |
| `-d cpu,exec,nochain` | yes | full GR/CR/SR/PSW dump before every TB; 3 s of firmware boot = 150 MB |
| `-accel tcg,one-insn-per-tb=on -d cpu,nochain` | yes | **per-instruction architectural state**; 5 s of firmware = 312 729 dumps / 361 MB (sample `$S/logs/one-insn.sample.log`) |
| `-d int` | yes | every interruption with full state + `RFI` dumps |
| `-d mmu`, `-trace lasi_*/ncr710_*/artist_*/i82596_*` | yes | device-level traces |
| TCG plugin `execlog` | yes (built with the default build) | `-plugin .../contrib/plugins/libexeclog.so -d plugin -D file` → `cpu, pc, opcode, "disasm"` + memory accesses. **Opcode column is printed in host (LE) byte order** (e.g. `0x600e0100` for `rsm 1,r0` = 0x00010E60) — byte-swap before comparing. 8 s firmware = 312 869 lines. |
| plugin register logging (`execlog,reg=...`) | **no** | hppa has no gdb XML description (cpu.c:318 `gdb_num_core_regs = 128`, no `gdb_core_xml_file`), so `qemu_plugin_get_registers()` returns nothing (gdbstub/gdbstub.c:593-613, plugins/api.c:464-470). Would need a QEMU change (gdb-xml for hppa). |
| other plugins | `liblockstep.so` (lock-step two QEMUs), `libcache.so` (cache model sim), `libhotblocks`, `libhowvec` (insn class histogram), `libbbv`, `libdrcov`, `libtraps` | lockstep could be adapted to diff QEMU vs. an RTL-sim co-simulation over a socket |
| gdbstub (`-s -S` / `-gdb tcp::PORT`) | **yes** (verified with a raw RSP client, `$S/rsp_test.py`, `$S/logs/gdbstub-rsp-test.log`): `qSupported`, `?`, `g` (128 × 32-bit regs), single-step `s`, memory read `m f0000080,8` → `00010e6000080d60` | the installed `/usr/bin/gdb` has no hppa target and `gdb-multiarch` is not installed; a hppa-capable gdb (gdb-multiarch package) would be needed for interactive use |

A rebuild is only needed if we want plugin register access (add gdb-xml) or a fixed NCR710: with
the existing `$S/build-hppa` tree that is seconds; a from-scratch hppa-only build is ~4 min on
this 6-core machine.

Suggested golden-model flow for the RTL: run bare-metal test programs (or SeaBIOS, or a Linux
kernel via `-kernel`) under `-M 715 -accel tcg,one-insn-per-tb=on -d cpu,nochain` or `execlog`,
convert to a canonical `(pc, insn, gr-writes, mem-writes)` stream, and diff against the Verilator
trace of the core. Keep in mind QEMU differences listed in §A.2 (TLB size, CR16 rate, delayed FP
traps, MAX-1, DIAG), which must be masked or patched for a clean diff.

### B.6 Files

* Logs: `$S/logs/` — `boot-715-nodisk-*.log`, `hpux-715-m256.log(+.qemu-unimp)`,
  `hpux-715-inasm-int.trace.gz`, `hpux-715-lasi-ncr.trace`, `hpux-715-ncr-regs.trace`,
  `hpux-715-sigp-run2.log`, `hpux-715-sigp-ncr.trace`, `hpux-B160L-m512-smp4.log`,
  `hpux-B160L-login-run2.log`, `execlog-715-firmware.log.gz`, `gdbstub-rsp-test.log`,
  `one-insn.sample.log`, `dlog-cpu.sample.log`.
* Binaries: `$S/build-hppa/` (full build incl. plugins), `$S/qemu-system-hppa-11.1.1-unpatched`,
  `$S/qemu-system-hppa-11.1.1-sigp-experiment`; patch `$S/ncr710-sigp-experiment.patch`.
* HP-UX image: `$S/hpux1020/{hpux.img,run.sh}`; boot script `$S/run-715-hpux.sh`.
