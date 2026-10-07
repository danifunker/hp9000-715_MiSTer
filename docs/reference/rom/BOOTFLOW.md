# HP 9000/715 PDC 1.6 — reset flow, boot flow and power-on self-tests

Analysis of `roms/hp715_pdc_rev1.6.bin` (258,728 bytes, mapped at 0xF0000000,
PA-RISC 1.1 big-endian) for the MiSTer recreation. Scope: what the ROM does
from the reset vector until it jumps into the IPL, every self-test it runs on
the way, how it reports progress (chassis/LED codes), how it times things, and
what the hardware must do so that an FPGA machine gets through it.

Companion documents (other agents, same directory): the hardware register map
(memory controller, diagnose registers, LASI/WAX details) and the PDC / IODC /
STI / EEPROM structures. Where this document touches their areas it says so
(**cross-over**).

Status: 2026-10-07, first pass. Addresses are ROM virtual = physical
addresses. Function names are in `tools/rom/symbols/bootflow.sym`; the
annotated listing with these names is `roms/disasm/bootflow/rom.dis`
(regenerate with `python3 tools/rom/annotate.py roms/hp715_pdc_rev1.6.bin
roms/disasm/bootflow`). The chassis-code table in §3.3 is produced by
`tools/rom/bootflow_chassis.py`.

**Status of this file:** first pass complete (2026-10-07), including the
per-test self-test analysis in §4 (merged from four instruction-level
analyses and spot-checked against the listing).

Key facts: 0xF0000000 is the HPMC **and TOC** entry; the ROM IVA
(0xF0002000) only traps unexpected interruptions (LED 0x21, halt); CPU speed
comes from a strap nibble at 0xF00FFFFC; LEDs are a byte latch at 0xF00EFFFF
written by one routine (0xF00122E0); device presence is probed by letting
reads of absent addresses raise HPMCs; a LASI PS/2-loopback interrupt must
reach EIRR bit 3 or the ROM halts silently after memory init.


---

## 0. Reading the listing

* objdump prints immediates and displacements in **hex without `0x`**
  (`ldi 66c,r26` = 0x66C, `stw r1,138(r0)` = offset 0x138). `bb` bit positions
  are printed in **hex** (`bb,< dp,19` tests PA bit 25), `extrw`/`depw`/`depwi`
  positions in decimal. PA bit numbering: bit 0 = MSB.
* Loads/stores with an explicit space register print with the 2-bit s field
  folded into the displacement: `ldw 2000(r6),r3` is `ldw 0(sr1,r6),r3`,
  `4000(rX)` is `0(sr2,rX)`. objdump also uses PA 2.0 names for some
  PA 1.1 conditions (`addib,*<=` = ADDIBT,OD, `addib,*>` = ADDIBF,EV,
  `addi,tsv` = ADDIO, `sub,tc,=` = SUBT,=), and cannot decode the BB words
  0xC482A12A / 0xC002A06A (§4.2, test 0x41086).
* objdump collapses runs of zero words, so e.g. 0xF0001CC0–0xF000201F
  (including IVA vector 0) are absent from the listing: they are zero.
* Calling conventions seen in the ROM:
  * C code (0xF0016000–0xF0020FFF, the "BCH"): `rp` link, args r26..r23,
    `dp` = 0xF0024000 (set by `load_rom_dp` f00163dc).
  * Assembly helpers use odd link registers: `r31` (UART, save/restore),
    `r22` (`chassis_code`, EEPROM access), `sp` (!) for the self-tests and
    `set_dr0`, `ret1` for `uart_spin_delay`. Self-tests are entered with
    `b,l TEST,sp` and return with `bv r0(sp)`.
* "SS x" = PDC stable storage offset x (PDC_STABLE); "EE x" = byte x of the
  EEPROM window at 0xF00C0000 (read directly by assembly code, or through the
  private PDC procedure 0x81 by C code). "page0 x" = physical address x.

---

## 1. Entry points and vector tables

| Address | What | Notes |
|---|---|---|
| 0xF0000000 | `b,l,n 0xF00026B0` → `hpmc_toc_entry` | The PA7100LC vectors **both HPMC and TOC** to 0xF0000000 in PDC space (PCX-L ERS §5.3.5). |
| 0xF0000004 | `b,l,n 0xF0000010` → `reset_entry` | CPU reset vector (PSW = M only). 0xF0000008/0C are `break` padding. |
| 0xF0000010 | `addi,tr 0,r0,r17` | Hard reset: r17 = 0 and the next insn is nullified. |
| 0xF0000014 | `ldi 1,r17` = `soft_reset_entry` | Soft boot (r17 = 1). Only jumped to from the TOC path when no OS TOC handler is valid (f00028d0). r17 ends up in page0 `IMM_SOFT_BOOT` (0x394). |
| 0xF0002000 | ROM IVA (set at f00000c4, again at f0000630, f00007a8, f0000b58, f0004f00…) | See below. |
| 0xF0009000 | Test-time IVA used by the self-tests and by bus-error probes | Vector *n* XORs `1<<(31−n)` (PA bit *n*) into `dp` (r27) and skips or re-executes the interrupted instruction; tests check `dp` to see which interruption happened. Handlers: §4.1. |
| 0xF0012870 | PDC entry point (`pdc_entry`) | Written to page0 `MEM_PDC` (0x388) by `page0_init`; the ROM itself calls PDC through 0x388 too. **Cross-over** (PDC agent). |

**ROM IVA at 0xF0002000.** Vector 0 is all zeros. Vectors 1–28 are each
`b f00023b0 ; ldi N,rp` (N = vector number). Vector 29 (0xF00023A0) is four
`nop`s that fall into the common code at 0xF00023B0 (with whatever `rp`
holds), vector 30 (0xF00023C0) is `b,l,n halt_forever`, vector 31 overlaps the
next function. The common code `iva_unexpected` does
`chassis_code(0x21000 + N)` and then `halt_forever` (f0001ae8: `sync; diag
TOC_EN; b .`). So **no ROM vector is "real"**: any interruption taken with the
ROM IVA installed is fatal and shows LED 0x21 with the vector number in the
low bits of the chassis code. HPMCs never use the IVA (they go to 0xF0000000),
so vector 1 is dead. The ROM runs with EIEM = 0 and only uses EIRR by polling.

---

## 2. Reset flow, step by step

### 2.1 Overview

```
reset_entry f0000010            CPU/DR init, LASI reset, clock-speed strap, MIOC timing
  (UART init if chassis codes on)
  early_init f0000338           EEPROM defaults, selftest1 (CPU+cache), I/O probes, PS/2 IRQ test setup
  mem_init   f0000ac0           memory sizing + RAM test, page zero, sp = 0x2120
  [EIRR bit 3 check]            the PS/2 loopback interrupt must have arrived
  LASI ICR=TOC, TOC_EN
  io_module_table_init f0004b68 HPA candidate table at page0 0x66C (PDC_ADD_VALID)
  ss_defaults_check f0004360    stable-storage defaults if EE 0x16D8 != 'G'
  console_init f001f1b8         console + keyboard, banner, monitor selection
  run_selftest2 f00006f0        selftest2 (cache/TLB/IRQ/memctl/FP), EISA config,
                                I/O self-test if fastboot off
  boot_select f0000c34          manufacturing mode / secure / autoboot / autosearch / BOOT_ADMIN
  eisa_boot_fixup f0003c3c
  ipl_launch f00019f0           "Booting", clear CRs, jump to IPL
any failure → halt_forever f0001ae8 (sync; TOC_EN; b .) with the LED showing the last code
```

### 2.2 `reset_entry` (0xF0000010–0xF0000334)

| Addr | Action | Hardware touched |
|---|---|---|
| f0000010 | r17 = 0 (hard) / 1 (soft, entry f0000014) | |
| f0000018 | EIEM = 0; EIRR = 0xFFFFFFFF (clear all) | CR15, CR23 |
| f0000024 | `set_dr0(0x03FF00D8)` (link `sp`) | DR0 (see below) |
| f0000030 | DR25 = 9 | HTLB_CNTL bits 28 and 31 = disable the hardware I- and D-TLB miss handlers |
| f0000048 | LASI.PCR (0xF010C000) = 1 | FLASH_LED: power LED blinks at 2 Hz during self-test |
| f0000054 | **store** 0 to WAX.HIL (0xF0201000) | unconditional — must not fault (§7) |
| f000005c | `get_cpu_speed` → r11 (1/2/3) | reads the strap word at **0xF00FFFFC** (§6) |
| f0000068 | DR24 = 0xE0 | HTLB base 0; DCACHE_SIZE bits 24–26 = 1 → 128 KB D-cache |
| f0000074 | MEM_HPA+0x80 = 0xCDFA8000 | memory controller config (**cross-over**, register agent) |
| f0000088 | MEM_HPA+0xC0 = 0x09F06974 (64 MHz) / 0x09EC81B4 (80) / 0x0DE79EFB (100) | memory timing per CPU clock (same table as `mem_timing_word` f0015860) |
| f00000bc | IVA = 0xF0002000; `set_psw(8)` (PSW = Q) | `set_psw` f0015ca0 loads PSW through IPSW + `rfi` |
| f00000d0 | LASI.IORESET = 0 (hold all LASI units in reset), IMR = 0, IPR = 0 (clear), read IRR | |
| f00000f4 | speed-dependent writes to LASI+0xB000/B004/B008/B00C (B000/B008 written twice, second time with bit 31 set) | r2=0x0C000000, r3=0, r7/r8 = 64 MHz 0x3231BC00/0x322F7C00, 80 MHz 0x222E4902/0x322E3202, 100 MHz 0x220F3E00/0x002C7900. Unit at LASI+0xB000 is not in the 712 LASI ERS — **cross-over** |
| f00001a4 | LASI.IORESET = 0x1FF (release all units), LASI.AMR = 2 | |
| f00001cc | if EE 0x16D9 != 'N' (EEPROM never initialised) **or** EE 0x1694 ∈ {0xB0, 0xB1} ("chassis codes on" / manufacturing mode): `uart_init_test` f0015a98 | LASI UART (§2.10) |
| f0000220 | `early_init` (hard: then r17 = 0; soft: keeps r17 = 1); failure → halt | |
| f0000248 | `mem_init`; ret0 < 0 → `cache_as_ram_init` f0002cf0, `mem_fail_report(sp=0x100, err)`, halt | |
| f0000270 | r18 = EIRR; IMR = 0; read IRR; EIRR = 0x10000000 (clear bit 3); **if r18 bit 3 was clear → halt** (ret0 = −1, no chassis code) | checks the PS/2 loopback interrupt set up at the end of `early_init` |
| f00002a0 | LASI.ICR = 2 (external interrupt line = TOC), IMR = 0x00200000 (GSC bit 21, external interrupt / TOC button); `sync; diag TOC_EN` | front-panel TOC now works |
| f00002cc | `io_module_table_init(0x66C)` | page0 0x66C… (§2.5) |
| f00002e8 | `ss_defaults_check` | EE 0x16D8 |
| f00002f0 | `console_init(0)`; ret ≠ 0 → `no_console_blink` f000328c (never returns) | |
| f0000300 | `run_selftest2`; ret ≠ 0 → halt | |
| f000030c | `boot_select(0x66C)`; ret < 0 → halt | |
| f0000318 | `eisa_boot_fixup`; ret < 0 → halt | |
| f0000324 | page0 byte 0x41 = 0xFF; `ipl_launch` | |

`set_dr0` (f0015cdc, link `sp`) writes r19 to DR0 after a revision fix-up
from DR0[0:5] (CPU revision): rev 0 → clear SOU_EN (bit 24), DUAL_DIS = 11
(single issue), clear ISTRM_EN (bit 20); rev 1 → clear ISTRM_EN; rev > 10 →
DUAL_DIS = 00. DR0 bit meanings are from the PCX-L ERS §8.2.2. The reset value
0x03FF00D8 means: clear every sticky cache-error flag (bits 6, 8, 10, 12–15,
write-one-to-clear), **mask** all cache HPMCs (7, 9, 11), leave STORE0/1 and
PF_MASK clear, I-stream off, dual issue on, SOU_EN + SHINT_EN + DHASH_EN +
IHASH_EN on, **L1 I-cache off** (bit 29 = 0). After `selftest1` the ROM
installs 0x02BF4AFC (+ fix-ups): HPMCs from the L2 caches unmasked, L1
I-cache and its prefetch enabled, PF_MASK set, DUAL_DIS = 01.

DR0 STORE[0] (bit 16) and STORE[1] (bit 18) are scratch bits the ERS
suggests for self-test bookkeeping; this ROM uses **bit 18 = "an HPMC is
expected"** (bus-error probes, §2.4) and **bit 16 = "already inside an HPMC /
OS handler entered"** (§2.11).

### 2.3 `early_init` (0xF0000338–0xF00006B0)

1. `mtctl rp,tr0` (return address kept in TR0 — there is no stack yet).
2. **EEPROM bring-up.** If EE 0x16D9 ≠ 'N' (0x4E) the EEPROM is
   uninitialised and defaults are written with `ee_write_word`/`ee_write_byte`
   (f0013220/f0013320: byte-wise program, poll read-back, 10 ms timeout per
   byte via `timeout_us`): words 0x16B0, 0x16AC, 0x16A8, 0x16A4 = 0; bytes
   0x1694 = **0xB1** (manufacturing mode + chassis codes), 0x1699 = 1
   (diagnostic boot), 0x1695 = 0 (fastboot off), 0x1696 = 0 (secure off),
   0x16B4–0x16B9 = 08 00 09 EE EE EE and 0x16BA–0x16BF = 08 00 09 FF FF FF (LAN
   station address templates), 0x16D9 = 'N'. Then (also when 0x16D9 = 'N' but
   0x16DA ≠ 'Y') 0x16DA = 'Y', word 0x1E0C = 1, words 0x1E04, 0x400, 0x404,
   0x408 = 0xFFFFFFFF. Any write failure → `chassis_code(0x23003)`, return −1
   → halt. On a hard boot, word EE 0x16B0 is made equal to EE 0x16AC.
   (EEPROM layout: **cross-over**, PDC/EEPROM agent.)
3. **`selftest1`** f0004e50 (CPU + cache power-on tests, §4). Non-zero →
   `selftest_fail_blink` f00006b4: LASI.PCR alternates 0 and 2 every 375 ms
   forever (`delay_us(0x5B8D8)`), i.e. the CPU-test failure is signalled only
   by the LEDs (the failing test's code stays latched) and the power LED.
4. `probe_io2` f0000850 and `probe_eisa` f00007e4 — bus-error probes (§2.4).
5. Store 0 to WAX.HIL+0xC00 (0xF0201C00), IVA = 0xF0002000, PSW = Q.
6. **PS/2 interrupt self-test set-up:** LASI.PS2 port 0 reset (write
   0xF0108000), control = 3 (ENBL + LPBXR loopback), read IRR, EIRR bit 3
   cleared, EIEM = 0, LASI.IMR = 0x04000000 (GSC bit 26 = keyboard/mouse),
   write 0 to the transmit register (0xF0108004). In loopback mode the byte
   comes straight back, the port raises its interrupt, LASI writes the low
   bits of its IAR (power-up value **0xFFFBE003**) to the CPU's IO_EIR at
   0xFFFBE000, and EIRR bit 3 becomes set. The result is checked only after
   memory init (f0000298). EIEM stays 0, so no interruption is taken.
7. Return 0.

### 2.4 Bus-error probing (DR0 STORE[1] + test IVA)

`probe_io2`, `probe_eisa` and many later probes use the same idiom:

```
f0000850  ldil  L%-fff7000,r1 ; mtctl r1,iva      IVA = 0xF0009000 (test IVA)
f000085c  diag  MFCPU_C DR0 -> r3 ; depwi 1,18,1,r3 ; diag MTCPU r3 -> DR0   STORE[1] = "HPMC expected"
f0000868  depwi,z 1,1,1,dp                        dp = 0x40000000
f0000880  ldb   0(r3),r4      ; r3 = 0xF041FFFE   probe read
f0000890  cmpib,=,n 0,dp,...                      dp == 0  ->  the read bus-errored: device absent
```

A read of a non-existent GSC address makes the MIOC raise an HPMC, which
vectors to 0xF0000000 → `hpmc_toc_entry` (f00026b0) → `set_psw(M)` →
`hpmc_probe_forward` (f00028d8): if DR0 bit 18 is set, `diag SHDW_GR`
(restore the shadowed GRs) and branch to **IVA+0x20**, i.e. the test IVA's
HPMC vector at 0xF0009020, which does `dp ^= 0x40000000` and resumes after
the faulting load. So **an FPGA machine must turn reads of unmapped I/O
space into HPMCs**; if it returns data instead, the ROM "finds" every probed
device (see §7).

What is probed during reset:

| Probe | Present → | Absent → |
|---|---|---|
| byte 0xF041FFFE (second LASI's config register) | program a second LASI at 0xF0500000: IORESET, IAR = 0xFFFBE007 (EIR bit 7), speed-dependent 0xF050B000–B00C, IORESET = 0x1FF, AMR = 2; LASI.AMR = 0 | probe WAX |
| byte 0xF0200000 (WAX) | LASI.AMR = 0 | probe byte 0xF1000000; present → LASI.AMR = 0 |
| byte 0xFC000C80 (EISA slot-0 ID, `probe_eisa`) | toggle bit 0 of 0xFC000461 (set, read twice, clear) | nothing |

A real 715/64 has WAX and no second LASI. Later, `io_module_table_init` and
the boot search probe more HPAs through PDC_ADD_VALID (PDC proc 12), which
uses the same mechanism (**cross-over**, PDC agent).

### 2.5 `mem_init` (0xF0000AC0–0xF0000B6C) and page zero

* FASTSIZE: EE 0x105F = *n* → test limit 2^(18+*n*) bytes, *n* ≥ 14 → 0xEFFFFFFF
  (all). **Note:** the PDC_STABLE view of this byte is the PDC agent's.
* Soft boot (r17 = 1): `chassis_code(0x6C202)`, `mem_soft_check` f000be78
  (chassis 0x4707E) with the previous `MEM_PHSIZE` (page0 0x354); success →
  skip the test; failure → treat as hard boot (r17 = 0).
* Hard boot: `chassis_code(0x6C201)`; dp = (EE 0x1695 == 1) i.e. fastboot
  **on**; `mem_size_and_test` f000bdf8 (§4.6).
* Then IVA = 0xF0002000, **sp = 0x2120** (first use of RAM), `page0_init`
  f0000b70 with ret1 = memory size:

| page0 | Value | PDC meaning |
|---|---|---|
| 0x350, 0x354, 0x358 | memory size | MEMC_CONT, MEMC_PHSIZE, MEMC_ADSIZE |
| 0x380 | 0x8000 | MEM_FREE |
| 0x384 | 0xFFFBE000 | MEM_HPA (CPU HPA) |
| 0x388 | 0xF0012870 | MEM_PDC (PDC entry) |
| 0x38C | 640000 / 800000 / 1000000 | MEM_10MSEC for 64 / 80 / 100 MHz (from the strap) |
| 0x390 | 0xFFFBF000 | IMM_HPA (memory controller) |
| 0x394 | r17 | IMM_SOFT_BOOT |
| 0x398, 0x39C | memory size | IMM_SPA_SIZE, IMM_MAX_MEM |
| 0x3A0/0x3A4, 0x400/0x404 | 0x00FFFFFF, 0xFFFFFFFF | MEM_CONS / MEM_KBD device paths = "none" (`console_key_is` and `boot_admin` test 0x404 == −1 as "no keyboard") |
| 0x44 | 0x8000 | ROM-private: allocation pointer for IODC code copied into RAM |
| 0xE4 | 9 | ROM-private: DR25 value |
| 0x614 | 0x700 | ROM-private |

### 2.6 After memory: interrupts, I/O table, console

* **EIRR bit 3 check** (f0000270): see 2.2/2.3. Silent halt if the PS/2
  loopback interrupt did not arrive.
* **`io_module_table_init(0x66C)`** (f0004b68): stores 0xFFF81001 to the
  broadcast register 0xFFFC0020, then builds the candidate HPA table at page0
  0x66C: [0] LASI 0xF0100000, [1] 0xF0500000, [2] WAX 0xF0200000,
  [3..18] 0xFC000000 + n·0x1000 (EISA slots), [19..21] FW-SCSI slot HPAs,
  [22..25] graphics slots 0xF8000000 (built-in Artist), 0xF4000000,
  0xF6000000, 0xFA000000. Every entry is checked with PDC_ADD_VALID (proc 12)
  and zeroed if it does not respond. The boot search (§2.8) walks this table.
* **`ss_defaults_check`** (f0004360): if EE 0x16D8 ≠ 'G' (0x47), write the
  customer defaults (f00202d0; 'U' selects a variant). `DefaultSS` clears EE
  0x16D8 and resets the machine, which lands here.
* **`console_init`** (f001f1b8, C, ~800 instructions; details belong to the
  IODC/STI agent): reads the console path (SS 0x60) and keyboard path (SS
  0xA0) with PDC_STABLE, resolves paths to HPAs with private PDC proc 0x80,
  accepts the serial ports (LASI UART 0xF0105000, WAX RS232_2 0xF0202000,
  second-LASI UART 0xF0505000) and the four graphics HPAs; loads the console
  and keyboard IODC through PDC_IODC (proc 8) into RAM at the page0 0x44
  allocation pointer, tries PS/2 (LASI 0xF0108000 / 0xF0108100) or HIL (WAX
  0xF0201000) for the keyboard, reads the per-slot graphics monitor type from
  EE 0x16CA (built-in), 0x16D4, 0x16D5, 0x16D6, fills page0 MEM_CONS
  (0x3A0…) and MEM_KBD (0x400…, HPA at 0x420, IODC entry at 0x428/0x42C),
  prints the banner (`console_banner` f001dbf0: "(c) Copyright 1990-1994…",
  "BootRom Version", "Memory Size", "Press <ESCAPE> to stop boot sequence.")
  and implements the **Tab** key monitor-type cycling ("Press <y> to save this
  monitor type", Enter = 0x0D, Tab = 0x09). A non-zero return makes the
  reset code call `no_console_blink`: chassis(−1) → LED byte 0x00 (all on),
  chassis(0) → 0xFF (all off), three times 125 ms each, then a 375 ms pause,
  forever.

### 2.7 `run_selftest2` (f00006f0)

1. `selftest2` f000b750 (§4) with TR0 holding sp. Failure →
   `selftest_fail_report` f00031e8 (prints the "following items failed
   selftest" table and "SYSTEM HALTED") and return non-zero → halt.
2. `eisa_config(0x66C)` f00032ec: chassis 0x6C2EA; EISA present → configure
   (chassis 0x6C2EB…0x6C2F0, "Warning: One or more EISA cards could not be
   configured"); chassis 0x6C2E0 at the end.
3. If EE 0x1695 == 0 (**fastboot off**): resolve the primary boot path,
   call private PDC 0x80, then **`io_selftest`** f0010c4c: chassis 0x48300,
   IODC-based tests of the LASI devices (f0010e94 ×5, f00114cc), an **RTC
   check** (read the LASI RTC at 0xF0109000, wait 1 s with `delay_us`, read
   again: unchanged → failure), chassis 0x48301, 0x284xx per failed item and
   0x48410 at the end; failures are listed by f0002d50. **Cross-over**: the
   IODC entry points used belong to the IODC agent.
4. IVA = 0xF0002000, PSW = Q.

### 2.8 Boot selection: `boot_select` (f0000c34)

Everything below prints through the console IODC (`puts` f0017b44) and
emits chassis codes through `chassis` f0010bf8.

1. `chassis(0x4300C)`; read EE 0x1694 with private PDC 0x81 (key
   0xB00B0079 passed as an extra argument). Failure → chassis 0x2300A, wait
   for ESC (`boot_failed_wait_esc`), return.
2. **Manufacturing mode** (EE 0x1694 == 0xB1, the default of a fresh
   EEPROM): go straight to `interactive_boot` (BOOT_ADMIN), no autoboot.
3. Otherwise `boot_admin(0x400, 0x3A0, 1)`, which in non-manufacturing mode
   only runs `lan_addr_check_prompt` (if EE 0x16B7–0x16B9 are still 0xEE it
   asks for the two LAN station addresses) and returns.
4. `chassis(0x4300C)`; read **secure** flag EE 0x1696. Secure → autoboot =
   autosearch = 1 and ESC is ignored. Otherwise `chassis(0x4300B)`,
   PDC_STABLE read of SS 0 (4 bytes): bit 0 (MSB of the primary path's flags
   byte) = **autoboot**, bit 1 = **autosearch**. Read failure → "Warning: Read
   from stable storage failed.", chassis 0x23001.
5. page0 0x600 = autoboot, 0x601 = autosearch, 0x602 = 0/1 (interactive).
   Neither flag → `interactive_boot`. Not secure and **ESC** (0x1B) waiting
   on the console (`console_key_is(0x1B)`) → `interactive_boot`.
6. Autoboot: "Starting Auto boot", chassis 0x6C500 (with only autosearch on:
   "Starting Auto search", 0x6C501), then `try_boot_device(kind 0 = primary
   path, opt 5)` in both cases. Return −1 (aborted) → chassis 0x6C507 if
   autoboot was on, wait for ESC → BOOT_ADMIN. Return 1 (not bootable) →
   "Warning: Auto boot failed. Auto boot path is not valid." and, if
   autosearch is off, "Auto boot failed and Auto search is off." + wait for
   ESC → BOOT_ADMIN.
7. Autosearch ("Starting Auto search", chassis 0x6C501), in this order, each
   a `try_boot_device(kind, option)` call that returns 0 = IPL loaded, 1 =
   not bootable (continue), −1 = abort:
   kind 1 (alternate path), "Trying SCSI.6" (0x6C502, kind 2 opt 6), "Trying
   LAN" (0x6C503, kind 3), "Searching SCSI devices" (kind 2 opt 5),
   "Searching LAN" (kind 3), "Searching Fast Wide SCSI devices" (0x6C504,
   kinds 4–6 for the FW-SCSI HPAs present in the 0x66C table), "Searching EISA
   devices" (0x6C505, kinds 7–21 for present EISA slots), then 0x6C506 and
   "Warning: Auto search failed. cannot find a device…" → wait for ESC →
   BOOT_ADMIN. (The handbook's "Searching for a system to boot" text is not
   in this ROM; these strings replace it.)
8. `try_boot_device` (f00011e8): ESC check (unless secure) → interactive;
   `boot_path_build` f000141c (kind 0 = SS 0x00 primary, 1 = SS 0x80
   alternate, 2..0x16 = built-in templates) into page0 MEM_BOOT (0x3D0);
   SCSI paths are range-checked (target 0..15, page0 0x678 table);
   `boot_iodc_init` f0001af8 (PDC 0x80 for the HPA, PDC_IODC read of
   ENTRY_INIT into **RAM at 0x4000**, called there; then ENTRY_IO copied to
   the page0 0x44 allocation pointer); `ipl_load` (below).

### 2.9 BOOT_ADMIN (`boot_admin` f0016468) and `interactive_boot` (f00015a0)

`interactive_boot` loops: `boot_admin(0x400, 0x3A0, 0)`; a negative return →
chassis 0x69009 (LED 0x69 "console initialisation error") and retry; a
successful `boot` command → page0 0x602 = ISL-interactive flag (bit 15 of the
return value), 0x600 = 1, chassis 0x6C740, "Attempting to boot.",
`boot_iodc_init`, "Loading Initial Program Loader", `ipl_load`, "IPL
successfully loaded" → return 0; failure → "ERROR: Cannot load IPL, error
detected", chassis 0x6C5F0/0x6C7F0, "Boot process failed. press <ESCAPE> to
Continue.", back to the prompt.

`boot_admin`:
* page0 0x404 == −1 (no keyboard path) → "Failed to initialize a keyboard",
  "SYSTEM HALTED", chassis 0x6B009, `b .` (f0016510).
* PDC_COPROC (proc 7) returns −3 → "WARNING: Floating Point Coprocessor is
  present but not functioning".
* Prints the help table — one of two texts, chosen by the strap register:
  (0xF00FFFFC & 0xF0) == 0xE0 selects the variant with FW-SCSI and graphics
  slots 2–4 (another Mirage model), otherwise the 715/64-80-100 text.
* Loop: prompt `BOOT_ADMIN> ` (f00167a4), `read_cmd_line` f001794c,
  `cmd_lookup` f001916c against an allowed-code list built on the stack,
  `blr` jump table at f00167e0 (entry = code + 2; −2 = empty line, −1 =
  "Unknown command"). Keyword strings: pointer table at **0xF00230B0** indexed
  by code; matching is case-insensitive prefix (`kw_match` f00190d0).

| Code | Keyword | Handler | Notes |
|---|---|---|---|
| 0x02 | auto | `cmd_auto` f00170a8 | autoboot/autosearch in SS 0 flags |
| 0x03 | boot | `cmd_boot` f00172c0 | pri/alt/scsi/lan/eisa/Pn [isl]; return value leaves the loop |
| 0x05 | chassis | `cmd_chassis` f001b494 | EE 0x1694: on = 0xB0 (codes on RS-232), off |
| 0x3E | defaultss | f0016b74 | EE 0x16D8 = 0 then broadcast reset |
| 0x0B | diagnostic_boot | `cmd_onoff_flag(0x1699)` | at launch selects the console boot-message mode |
| 0x0A | fastboot | `cmd_onoff_flag(0x1695)` | on = 1 |
| 0x0E | help | f0016a64 | |
| 0x07 | information | `cmd_information` f001b77c | model, CPU revision (DR0[0:5]), cache sizes (PDC_CACHE), FPU (PDC_COPROC) |
| 0x12 / 0x2F | lanaddress / lan_addr | `cmd_lanaddress` f0017e0c | |
| 0x17 | monitor | `cmd_monitor` f001d384 | |
| 0x1F | path | `cmd_path` f00193f4 | pri/alt/console/keyboard |
| 0x21 | pim_info | `cmd_pim_info` f001ced0 | PIM from EEPROM (§2.11) |
| 0x26 | search | `cmd_search` f001c238 | |
| 0x27 | secure | `cmd_onoff_flag(0x1696)` | |
| 0x15 | reset | f0016b08 | `stw 5 → 0xFFFC0030`: broadcast CMD_RESET |
| *manufacturing mode only:* |||
| 0x2B | date | `cmd_date` f001bbec | PDC_TOD |
| 0x3F | manufactureoff | `cmd_manufactureoff` f0017650 | |
| 0x20 / 0x22 | peek / poke | f0018230 / f001846c | |
| 0x30 | serial_num | `cmd_serial_num` f001da68 | |

Other keywords in the table are argument words (on, off, pri, alt, scsi,
lan, eisa, graphics_1…4, rs232, rs232_2, ps2, hil, fwscsi_2…4, isl, ipl,
hpmc, toc, lpmc, …); `install` and `!*debug` are listed but unreachable from
the command level.

### 2.10 IPL load and launch

`ipl_load` (f0001778, three attempts): requires a boot-device IODC entry
(page0 0x3F0/0x3F8) and class 1, 2 or 0x1002 at 0x3FC. Reads the LIF volume
header through ENTRY_IO to **0x10000**; IPL address = [0x100F0], size =
[0x100F4] (→ page0 0x4C), entry offset = [0x100F8] (→ page0 0x50 =
0x10000 + offset). Reads the IPL in device-sized blocks to 0x10000
(chassis 0x6C580 before each), then **the 32-bit word sum of the IPL must be
0**. Errors → chassis 0x68007 (−1), 0x6C5F2 (−2), 0x6C5F1 (−3, no retry),
0x6C5F3 (−4), 0x6C5F4 (−5), 0x6C5F8 (−6 checksum), 0x68008 (−7 no IODC).

`ipl_launch` (f00019f0): "Booting", PSW = Q, RCTR = PID1–4 = CCR = SAR =
EIEM = 0, CR16 compare = 0, EIRR cleared, SR0–SR7 = 0; EE 0x1699 (diagnostic boot)
selects `f001fcbc(0, 0xFFFFC000)` or the graphics banner `f001de30` ("Press
<Ctrl><Insert> to toggle console boot messages"); chassis 0x6C7FF (or 0x6C5FF
when page0 0x600 == 0x0E); `flush_caches` (fice + fdce over 128 KB in 32-byte
steps); **jump to [page0 0x50]** with r26 = page0 0x602 (interactive flag)
and r25 = (page0 0x4C + 0x10000 + 7) & ~7 (first free byte after the IPL).

### 2.11 HPMC and TOC (entry 0xF0000000 → f00026b0)

```
f00026b0  save rp,r26,ret0,ret1,r31; set_psw(M)        mask further HPMCs
f00026e0  hpmc_probe_forward: DR0 bit 18 set -> SHDW_GR, jump IVA+0x20 (expected HPMC)
f00026e8  sync; diag TOC_DIS
f00026f4  mioc_status_clear: r25 = MEM_HPA+0x84, written back (clears)
f0002700  r25 bit 27 set -> TOC path (f000284c), else HPMC path (f0002724)
```

* **HPMC**: DR0 bit 16 set (nested: HPMC inside PDC's HPMC handling or after
  the OS handler was entered) → chassis 0x2CBFF, classify, **halt**:
  DR0 bits 8/6/10 (L2D/L2I/L1I cache error) → 0x22040, MIOC status bits
  30/28/29 → 0x2503F (bus error), else 0x27000 (memory). Otherwise
  `pim_save_eeprom` (GRs, CRs, SRs, IIA queues… into EE 0x1400…), chassis
  0x2CBF0 (0x23002 if saving failed), classify again (0x22043/0x22044/
  0x22045 per cache, 0x2503F, 0x27000), dump the PIM on the RS-232 port in
  raw form ("GRs", "CRs", "SRs", "OTHER" + hex words, `pim_dump_uart`),
  then `hpmc_call_os`: if IVA < 0xF0000000 and the OS HPMC vector is valid
  (word sum of IVA+0x20…0x3F plus the handler at [IVA+0x38], length
  [IVA+0x3C], must be 0) → chassis 0x2CBFB, clear DR0 error bits, set DR0
  bit 16, **jump to IVA+0x24**. Else halt.
* **TOC** (MIOC status bit 27): clear DR0 error bits, set bit 16, PSW = 0,
  `pim_save_eeprom` (TOC area EE 0x1564…), chassis 0x6CB00 (0x23002 on
  failure), `toc_call_os`: PSW = Q, `st41090_tlb_init` (TLB re-initialisation), f0011fa0,
  `flush_caches`; if page0 VEC_TOC (0x08) is set, word-aligned, and the word
  sum of the handler (length page0 0x0C) is 0 → chassis 0x6CB0B, clear DR0
  bit 16, jump to VEC_TOC with r26 = MEM_PDC. Otherwise **soft reset**
  (`b f0000014`).

### 2.12 Code that runs from RAM (or cache)

The ROM does copy code out of itself and execute it elsewhere:

1. **IODC entry points** (console, keyboard, boot device): PDC_IODC reads
   the device's IODC (for built-in LASI devices this comes from the PDC ROM
   image itself — **cross-over**) into RAM — ENTRY_INIT at 0x4000
   (temporary), ENTRY_IO/ENTRY_CONS at the page0 0x44 allocation pointer
   (starts at 0x8000) — and calls it there (`blr` + `bv r0(r1)`).
2. **The IPL** (LIF ISL) is loaded to 0x10000 and entered at
   0x10000 + entry offset.
3. **The memory test and several CPU/cache/TLB tests run code at physical
   address 0 that lives only in the instruction cache.** `l2ic_load`
   (f000786c) writes ROM words into the off-chip I-cache with diagnose
   WI2D + SET_TAG/WI2T (tag = page of the destination), and the caller
   jumps there in real mode; RAM is never written. `mem_size_and_test` does
   `b,l f000c160,r31 ; bv,n r0(r0)` after loading 0xF000C800–0xF000CB8B
   (fastboot off, LFSR test) or 0xF000CB90–0xF000CE9B (fastboot on,
   ones/zeros test). Details in §4.5.

---

## 3. Chassis / LED codes

### 3.1 Mechanism

`chassis_code` (f00122e0, code in r3, link r22) is the only writer:

```
f00122e0  ldil  L%-ff10800,r1 ; ldo 7ff(r1),r1      r1 = 0xF00EFFFF (LED latch on LASI's 8-bit bus)
f00122e8  extrw,u r3,19,8,ret1                      ret1 = (code >> 12) & 0xFF
f00122ec  subi  -1,ret1,ret0 ; stb ret0,0(r1)       latch <- ~LED byte   (LEDs are active low)
f00122f4  ... ldb EE 0x1694 ... == 0xB1, or (& ~1) == 0xB0 ?
f0012344  print "0x" d d "." d d d d "\r\n" on the LASI UART (uart_putc_raw, honours XON/XOFF)
```

* **Format.** A chassis code is a 24-bit number; bits 12–19 are the
  **front-panel LED byte** (LED8 = bit 7 … LED1 = bit 0, matching the
  service handbook table), bits 0–11 a sub-code that only appears in the
  RS-232 dump. Printed form is `0x` + 6 hex digits with a dot after the first
  two: code 0x6C201 prints as `0x06.C201`.
* **RS-232 copy** only when EE 0x1694 is 0xB0 or 0xB1 (`chassis on`, or
  manufacturing mode — the default for a blank EEPROM). The UART is then
  initialised early by `reset_entry` (9600 baud, 8N1; §6).
* C code calls `chassis` (f0010bf8, code in r26). The ROM never writes the LED
  latch any other way; PDC_CHASSIS from the OS also ends up in
  `chassis_code` (f00122ac → f00122d0) — **cross-over** (PDC agent).
* There is no LCD; LASI.PCR bit 0 (FLASH_LED) only blinks the power LED.

### 3.2 Normal power-on sequence (715/64, hard boot, EEPROM initialised)

| Phase | Codes (LED byte in bold) |
|---|---|
| `reset_entry`, `early_init` | none until the first self-test (LED latch content undefined) |
| `selftest1` CPU tests | **41**081, 41080, 41082, 41086, 41087, 4108A, 4108B, 4108C, 41083, 410D1, 410D2 |
| `selftest1` cache tests | **42**090, 42091, 4209F, 42096, 42094, 42095 |
| `mem_init` | **6C**201 (6C202 + **47**07E on soft boot) → **41**0DA (fastboot on) / 410DB (fastboot off) → (errors only: 0x271xx) → 410D7, 410D8 |
| `selftest2` | **42**097, 42098, 42099, 4209A, 4209B → **41**091, 41092, 41093, 41094, 41095, 41096, 41090, (4108D), 410D4, 410D9 → **44**080, 44081, 44082 |
| `eisa_config` | **6C**2EA (… 6C2EB–6C2F0 with EISA) 6C2E0 |
| `io_selftest` (fastboot off) | **48**300, 48301, (**28**4xx per failure), 48410 |
| `boot_select` | **43**00C, 4300C, 4300B, then **6C**500 (autoboot) or 6C501 (autosearch) / 6C502–6C507 |
| `ipl_load` | **6C**580 per block |
| `ipl_launch` | **6C**7FF (normally) / 6C5FF |
| interactive | 6C740 ("Attempting to boot") |

### 3.3 All codes found in the ROM

`tools/rom/bootflow_chassis.py` lists every call site with the code it
passes (113 sites; output in `roms/disasm/bootflow/chassis.tsv`). Codes it
cannot resolve statically are computed at run time: `iva_unexpected`
(0x21000 + vector), `f0007934` (cache-test failure dump from r10–r21),
`mem_report_errors` f000c6e8 (0x271xx with slot/bank fields), the I/O test
(0x284xx), and PDC_CHASSIS from the OS (f00122ac). By LED byte:
**41** CPU self-tests (0x410xx), **42** cache tests, **44** FP tests,
**47** soft-boot memory check (0x4707E), **48** IODC/I/O tests,
**43** boot-select progress (0x4300B/C), **6C** boot progress (memory init
0x6C20x, EISA 0x6C2Ex, boot 0x6C5xx/0x6C7xx, TOC 0x6CBxx), **68** IPL load
errors, **69** console error (0x69009), **6B** no keyboard (0x6B009),
**21** unexpected interruption / RAM test, **22/25/27/2C** HPMC
(cache/bus/memory/generic), **23** fatal (EEPROM/stable-storage failures),
**28** I/O device failed. Matches the service-handbook LED table for
0x41/0x42/0x44/0x48/0x23/0x2C/0x22/0x25/0x27/0x69/0x6C; the handbook's 0x2A,
0x6A, 0x66, 0x24 were not found as constants in the ROM code, and 0x43
("ROM checksum") is used here only as a boot-select progress code (no ROM
checksum loop was found).

---

## 4. Self-tests

Sources: my own reading of the reset path and dispatchers plus four
instruction-level analyses (CPU core, cache, TLB + FP, memory), merged here;
key claims were re-checked against the listing (test entry codes, the IVA
handlers, `l2ic_load`, the BB encodings, 0x410D2, 0x4209B, 0x42096, 0x41096,
the FP result byte, the memory alias and MEMMASK tables).

Unless stated otherwise a failing test leaves **its own chassis code** on
the LEDs (LED byte 0x41 CPU, 0x42 cache, 0x44 FP) and returns ret0 = −1.

### 4.0 Index in run order

| # | Code | Entry | Name | One line | FPGA risk |
|---|---|---|---|---|---|
| **selftest1** f0004e50 (from `early_init`, before memory exists) ||||||
| 1 | 0x41081 | f0005040 | st41081_gr_tr_basic | r0, GR ripple/sum, branch in delay slot, TR4–7 | med |
| 2 | 0x41080 | f0004fb0 | st41080_dr0_rw | DR0 write/read, mask 0x0150EFFC | low |
| 3 | 0x41082 | f0005360 | st41082_alu_branch | ALU identities, B,L link in delay slot, BLR, ADDB, MOVB | med |
| 4 | 0x41086 | f0005670 | st41086_shift_extract_bb | SHRPW, extract/deposit, SAR, BB/BVB (incl. odd encodings) | med |
| 5 | 0x41087 | f00059b8 | st41087_cond_nullify | every condition/nullify case, DCOR | med |
| 6 | 0x4108A | f0005d98 | st4108a_carry_imm_traps | carry/borrow, LDO/ADDIL, COMCLR, overflow + conditional traps | med |
| 7 | 0x4108B | f0005f10 | st4108b_cr_rctr_iiaq_rfi | CCR/RCTR/IVA/IPSW, exact RCTR count, BREAK/IIR, RFI with N | med–high |
| 8 | 0x4108C | f0006128 | st4108c_eir_itimer | EIR at the CPU HPA, EIRR/EIEM, DR1 + CR16 timer | med–high |
| 9 | 0x41083 | f0006328 | st41083_shadow_regs | shadow GRs, RFIR, GR_SHDW/SHDW_GR | med |
| 10 | 0x410D1 | f000b118 | st410d1_eir_eirr_eiem | all 32 EIRR bits via EIR | med |
| 11 | 0x410D2 | f000b218 | st410d2_hpmc_toc | HPMC on I/O timeout, TOC via own COMMAND | high |
| 12 | 0x42090 | f0007af0 | st42090_cache_datapath_walk | walking bit through L2-D tag/data, L1 | med |
| 13 | 0x42091 | f00066d0 | st42091_cache_addr_lines | cache address lines, I/D separation | med |
| 14 | 0x4209F | f0006de0 | st4209f_cache_ram_patterns | pattern fill of all cache RAMs, runs from I-cache | high |
| 15 | 0x42096 | f0007ef8 | st42096_cache_init | invalidate all caches (tag 0xF0000400) | low |
| 16 | 0x42094 | f00084c0 | st42094_cache_hit_compare | real load/fetch hits per RPN bit, L1 over L2 | high |
| 17 | 0x42095 | f0008080 | st42095_cache_parity_detect | parity error injection and detection | high |
| **mem_size_and_test** f000bdf8 (from `mem_init`) ||||||
| 18 | 0x410DA / 0x410DB | f000bdf8 | mem_size_and_test | bank sizing + RAM test (fastboot on / off) | high |
| 19 | 0x410D7 | f000d870 | mem_ecc_singlebit | ECC single-bit correction, LPMC | high |
| 20 | 0x410D8 | f000d2d0 | mem_ecc_multibit | ECC multi-bit detection → HPMC | high |
| **selftest2** f000b750 (from `run_selftest2`, after console init) ||||||
| 21 | 0x42097 | f000b940 | st42097_icache_smc_flush | self-modifying code with fdc/fic | med |
| 22 | 0x42098 | f000ba28 | st42098_dcache_partial_store | STH/STB/STBY merges | low |
| 23 | 0x42099 | f000bbc0 | st42099_icache_fill_tag | I-miss fill visible to RI2T/RI2D | med |
| 24 | 0x4209A | f000bc50 | st4209a_dcache_writeback | dirty bit, write-back on eviction | med |
| 25 | 0x4209B | f000bdb0 | st4209b_cache_enable_flush | final DR0, fice/fdce all | low |
| 26 | 0x41091 | f000a0d8 | st41091_tlb_lpa | LPA through page and block entries | med |
| 27 | 0x41092 | f000a690 | st41092_tlb_patterns | TLB RAM/CAM bit patterns, runs from I-cache | med |
| 28 | 0x41093 | f000a918 | st41093_tlb_replace_lock | replacement, lock-in/out, dropped inserts | high |
| 29 | 0x41094 | f000a388 | st41094_tlb_probe | PROBE R/W vs access rights, PID; runs from I-cache | med |
| 30 | 0x41095 | f00095c0 | st41095_htlb_walker | hardware TLB-miss handler, CR28, PDIR | high |
| 31 | 0x41096 | f000aed8 | st41096_tlb_tdb_traps | T/D/B bits → traps 21/20/19 | med |
| 32 | 0x41090 | f0009548 | st41090_tlb_init | TLB re-initialisation (never fails) | low |
| 33 | 0x4108D | f0006540 | st4108d_dual_issue_timing | cycle-exact dual issue; only if CPU rev ≠ 0 | high (skip) |
| 34 | 0x410D4 | f000b868 | st410d4_ldcw_coherence | LDCW/LDCWS vs D-cache states | med |
| 35 | 0x410D9 | f000b3e0 | st410d9_dio_parity_hpmc | injected I/O parity errors → HPMC | high |
| 36 | 0x44080 | f000e448 | st44080_fp_regfile | FP register file, identity ops | low |
| 37 | 0x44081 | f000de50 | st44081_fp_ops | FP arithmetic, dbl + sgl, exact | low–med |
| 38 | 0x44082 | f000ed40 | st44082_fp_exceptions | FP flags, delayed traps | med–high |

No ROM-checksum test exists. The "~63 `b,l .+8` / `bv,n`" idioms seen near
0xF0004FC0 are the chassis-call idiom (§4.1) plus fail sentinels, not
separate tests.

### 4.1 Conventions shared by all tests

* **Chassis call idiom.** `X: b,l X+8,r22 ; X+4: bv,n r0(r19|r21)` — the `bv`
  executes in the delay slot of the `b,l`, so control goes to
  `chassis_code` with r22 = X+8 (the ROM has 37 of these). The many
  `b,l,n FAIL,r0` words that follow conditional instructions are *fail
  sentinels*: the preceding condition must nullify them.
* **Result.** ret0 = 0 pass, −1 fail. The failing test's chassis code stays on
  the LEDs. `selftest1` failure → `selftest_fail_blink` (LASI.PCR toggling
  forever); `selftest2` failure → "The following items failed selftest. /
  Processor Board / SYSTEM HALTED".
* **Expected-interruption mask.** Before provoking interruption *k* a test
  sets PA bit *k* of `dp` (r27), i.e. `1<<(31−k)`; every vector of the test
  IVA XORs its own bit into `dp`, so pass requires `dp == 0` afterwards —
  exactly the expected interruption and no other.
* **Expected HPMC/TOC.** DR0 bit 18 (STORE[1]) set; the HPMC/TOC entry at
  0xF0000000 then does `SHDW_GR` and branches to IVA+0x20 (§2.4).
* **Code run from the I-cache** (`l2ic_load` f000786c): see §4.5.
* **Error dump** (`cache_err_dump` f0007934, cache tests only): emits up to 12
  chassis codes (r10…r21, count in r9 = 8/10/12) 0.75 s apart: r10 = test
  code | 0xE0000, r11 = sub-code, r12… = 16-bit halves of address /
  expected / actual. Sub-code: first nibble D = data, F = tag; second
  nibble 1 = L1, 2 = L2-I, D = L2-D. Formatters f0007a3c, f0007e68, f0006d5c.

**Test interruption vector table, IVA = 0xF0009000** (8 words per vector;
prologue saves r1/rp/r3 in TR7/TR6/TR5 and XORs the vector's bit into dp):

| Vec | Handler | Effect |
|---|---|---|
| 1 HPMC (only via 0xF0000000 with DR0[18]) | f00093c8 | clears DR0[18], reads MEM_HPA+0x84 and writes it back (clear), **TR7 = that status**, skip instruction |
| 2 power fail, 4 external, 5 LPMC | f0009414 | clear IPSW.I, re-execute (EIRR not cleared) |
| 3 recovery counter | f00094a8 | RCTR = 0x7FFFFFFF, re-execute |
| 6 ITLB miss | f00094b8 | if TR3 == 0x0900DEEE: resume at r31 with PSW = Q, TR3 = 0 (escape used by TLB tests); else skip |
| 9 BREAK | f0009428 | im5 = 1: IPSW ← r25, skip; im5 = 2: r26 ← IIR, skip; im5 = 3: XOR r1/8/9/16/17/24/25 with −1, skip, `rfi,r` (RFIR); other im5: `bv` to IIR value (crash) |
| 14 assist exception | f00094f4 | `fstd fr0` to r19+0x18, reload fr0–fr3 from [r19], FP status := 0x1F, re-execute (r19 must point at a buffer) |
| 23–25 privilege transfer, taken branch | | restore, `rfi` |
| 7, 8, 10–13, 15–22, 26–28 | f00093a0 | skip: IIAOQ ← {front+4, front+8}, restore, `rfi` |

"Skip" relies on CR18 (IIAOQ) behaving as a 2-deep queue under Q = 0:
`mfctl` reads the front, each `mtctl` advances the queue and loads the back.

### 4.2 `selftest1` CPU tests (in run order)

Before the first test DR0 |= 0x03FF0000 (mask L1I/L2I/L2D HPMCs, clear all
sticky error flags).

**0x41081 — f0005040 `st41081_gr_tr_basic`.**
*Exercises:* before the chassis call (so a failure leaves the previous LED
code): `b,l,n` nullifying its delay slot, and a branch in the delay slot of a
branch (f000505c/f0005060: 505c, 5060, [5064 nullified], 5068). Then r0
stays 0 after being targeted; `extrw,s` sign; `cmpiclr`; LDIL+ADDI building
0xAAAAAAAA / 0x55555555; a ripple of rp/r3 through every GR r1–r29
(f000513c) for 0, −1, 0x55555555, 0xAAAAAAAA; r2..r29 = 2..29, 1024-pass
loop, sum must be **0x1B2**; TR4–TR7 (CR28–31) write/read 0x55555555 and
0xAAAAAAAA.
*Pass:* every compare equal. *Internals:* none (TRs must be 32 bits).

**0x41080 — f0004fb0 `st41080_dr0_rw`.**
*Exercises:* MTCPU/MFCPU_C on DR0 with the patterns at f000502c
(0xABFAAAAA, 0x55555555, 0x01500000, 0xFFFFFFFF), 3 `sync`s between write
and read; DR0 restored.
*Pass:* (pattern & 0x0150EFFC) == (readback & 0x0150EFFC), i.e. bits 7, 9,
11, 16–18, 20–29 read back as written. *Internals:* **DR0 bit semantics**
(rev [0:5] read-only, 6/8/10/12–15 write-1-to-clear, 19 read-only, 30/31
read-only). The patterns toggle dual-issue, hashing, L1 enable and ENDIAN
while running; treating those as plain storage is fine.

**0x41082 — f0005360 `st41082_alu_branch`.**
*Exercises:* with r4 = 0x55555555, r5 = 0xAAAAAAAA, r6 = −1: ADD, SUB, ADDI
carrying across bit 11 (→ 0x555557FF, 0xAAAAA7FF), SUBI (→ 0x555552AB,
0xAAAAAD55), AND/OR/XOR/UXOR identities, SH1/2/3ADD (r4: −1,
0xAAAAAAA9, −3; r5: 0xFFFFFFFE, 0x55555552, −6), UADDCM, ANDCM. Then (PSW Q
via `ssm 8`): `b,l` with a `b,l` in its delay slot — the first target runs
once (r6 = 10), r4 = 0xF000554C, **r5 = 0xF0005554 (IAOQ_Back + 4)**; BLR,n
with index +1 and **−3** (targets/links checked); five nested `b,l,n`
unwound by `bv,n`; CMPB, ADDB, MOVB taken/not-taken.
*Internals:* none; exact link = IAOQ_Back+4 and BLR = IAOQ_Front+8+8x.

**0x41086 — f0005670 `st41086_shift_extract_bb`.**
*Exercises:* SHRPW of 0x12345678:0x02468ACE by 1, 2, 4, 8, 16, 31 →
0x01234567, 0x0091A2B3, 0x802468AC, 0x7802468A, 0x56780246, 0x2468ACF0;
SAR write/read (low 5 bits); fixed and SAR-variable EXTRU/EXTRS, DEP,
DEPI, ZDEP on 0xE630C199 (1, −1, 9, −15, 33, −63, 0x99, rebuilt by
deposits); BB/BVB on 0xF7DFFFFF counting taken branches (must be 8 for the
fixed and for the variable form).
*Note:* two BB words, **0xC482A12A** (fixed, bit 4) and **0xC002A06A**
(variable), have c = 101 (bit 16 = 1, 17 = 0, 18 = 1), which PA 1.1 calls
undefined and objdump cannot decode. They **must be taken** (bit 4 is 0), so
decode the BB condition from bit 16 only (or apply the generic `<>`
condition to the shifted value — both pass). They must not trap as illegal
instructions (QEMU's decoder would).

**0x41087 — f00059b8 `st41087_cond_nullify`.**
*Exercises:* ~56 condition/nullify cases, each followed by a fail sentinel:
ADDIB (TR, never, UV/NUV, OD/EV), ADDI,UV/NUV/EV/OD, UXOR SBZ/NBZ/SHZ, SHRPW
OD/EV/=/</<>/>=, MOVB EV/OD, ADD </<=/ZNV/SV (signed conditions on the
infinite-precision result, also with target r0), SUB/SUBI </<=/SV,
UADDCM SDC/SBC/SHC (per-digit, per-byte, per-halfword carries on
0x88888888 and 0x80808080), EXTRU never/TR, and **DCOR**: rp = −1, for k = 1..8
`addi 1` sets the C/B bits of the low k digits, `dcor` must give
0x9999999F … 0xFFFFFFFF.
*Internals:* full PA 1.1 condition tables; **PSW C/B (8 digit carries)**
must be set by ADDI and consumed by the next DCOR; instructions targeting r0
still set conditions and C/B.

**0x4108A — f0005d98 `st4108a_carry_imm_traps`.**
*Exercises:* ADDC/SUBB after ADD/SUB into r0 (0, 0, 1, −1); LDIL + DEPWI,Z +
LDO 0x1555, ADDIL (target r1) building 0x55555555/0xAAAAAAAA; COMCLR. With
the test IVA, DR0 |= 6–15 (left set) and PSW I+Q: **ADDIO** 0x7FFFFFFF+1 →
overflow trap 12, **SUBT,=** equal operands → conditional trap 13; each
must leave dp = 0.
*Internals:* precise traps (no GR write, IIAOQ front = trapping insn).

**0x4108B — f0005f10 `st4108b_cr_rctr_iiaq_rfi`.**
*Exercises:* CCR (CR10) low 8 bits 0x55/0xAA; RCTR (CR0) and **IVA (CR14)**
full 32-bit write/read 0x55555555/0xAAAAAAAA; recovery counter: 28 rounds of
`mtctl rctr; ssm R; nop ×3; mtsm`; the immediate `mfctl rctr` must be
**start − 4**; CR18 queue rotate/consistency; `break 2,0x1555` → vector 9,
**r26 must be 0x02AAA002** (IIR = whole instruction word); IPSW (CR22)
write/read 0x01555515 and 0x02AAAA0A; RFI with IPSW = 0x00210008 (N | M |
Q): the first instruction at the return address (a fail sentinel) must be
**nullified by PSW.N**, the next sets r5 = −14 (checked).
*Internals:* exact RCTR decrement rule, IIR, IPSW bit storage (bits 6–23,
27–31), RFI restoring N; `mtsm` may set Q.

**0x4108C — f0006128 `st4108c_eir_itimer`.**
*Exercises:* for n = 1..31: `stw n` to the CPU's **EIR register
0xFFFBE000**; no interruption while EIEM = 0, none with PSW.I = 0; with EIEM
= −1 and `ssm I`, the external interrupt must be taken within 3 `nop`s and
EIRR must equal exactly `0x80000000 >> n` (cleared by writing it back).
Interval timer: MTCPU **DR1** loads the CR16 counter, CR16 write = compare;
DR1 = compare − 0x100 for compare 0x55555555 and 0xAAAAAAAA, spin until the
timer interrupt (EIRR == 0x80000000, **no timeout**); compare = CR16 + 0xC00
polled; DR1 = 0xFFFFFF00 with compare 0 (wrap).
*Internals:* EIR at the CPU HPA, DR1, compare match only when the counter
reaches the compare value (a spurious match from the setup writes makes the
test hang with 0x4108C on the LEDs), ≤ 3-instruction interrupt latency.

**0x41083 — f0006328 `st41083_shadow_regs`.**
*Exercises:* r1/r8/r9/r16/r17/r24/r25 loaded with 0, −1, 0xAAAAAAAA,
0x55555555 (table f0006524), then 0x11111111…0x77777777; `break 3,0` —
the handler inverts those seven GRs and returns with **RFIR**, which must
restore the originals. Then 0x12345678 in all seven, **diag GR_SHDW**,
load 0x89ABCDEF, **diag SHDW_GR**: all must read 0x12345678.
*Internals:* shadow registers captured on every interruption (also HPMC/TOC,
used by §2.4), RFIR, GR_SHDW/SHDW_GR diagnose.

**0x410D1 — f000b118 `st410d1_eir_eirr_eiem`.**
*Exercises:* compare = CR16 − 1 (no timer match); EIRR = −1 must read back 0;
`stw n` to EIR for n = 31 down to 0: EIRR must accumulate 1, 3, 7, …,
0xFFFFFFFF; clear bit by bit with `mtctl` (remaining mask checked); EIEM =
bit 29, `ssm I`, `stw 29` to EIR → interrupt within ~13 instructions.
*Internals:* EIR, all 32 EIRR bits set/clear.

**0x410D2 — f000b218 `st410d2_hpmc_toc`.**
*Exercises:* MEM_HPA+0x84 cleared (read, write back); RFI into the body.
(1) DR0[18] = 1, dp = bit 1, `ldw 0xFFFBB000` (nothing there) → **HPMC** →
0xF0000000 → test vector 1; pass if dp = 0 and **TR7 & 0x7F == 0x02**.
(2) `diag TOC_EN`, `stw 5` to the CPU's own COMMAND register **CPU_HPA+0x30**
→ **TOC** (same path); pass if TR7 & 0x7F == **0x10**. (3) `stw −1` there →
no interruption and MEM_HPA+0x84 & 0x7F == 0.
*Internals:* **high** — HPMC on I/O read timeout with status 0x02, TOC from
CMD_RESET to the own HPA with status 0x10 (bit 27), TOC mask cleared by
TOC_EN, fixed vector, shadow capture.

Then `set_psw(0)`, `set_dr0(0x03FF00D8)` and the cache tests (§4.3).

### 4.3 `selftest1` cache tests

The ROM hard-wires the geometry (`cache_size` f00158e0 = 0x20000): L2-I and
L2-D 128 KB each, direct-mapped, 32-byte lines (4096), line index PA[15:26],
20-bit RPN tag; L1 I-cache 1 KB (128 doubleword entries, read/written
through DR27/DR28/DR29 + RI1/WI1). A 32 KB variant exists (f00158e8,
f00152d8 DR24 0xF8, PDC_CACHE); the single word at f00158e4 selects it. Tag
word (SET_TAG / RDT / RI2T): bits 0–19 RPN, 20 dirty, 21 dirty parity (odd,
= ~dirty), 22 tag parity, 23/24 data parity of even/odd word, 25 Arb enable
(parity taken from the GR instead of generated). "Invalid" is tag
0xF0000400 (RPN 0xF0000), which **must never hit** — accesses to F-space
must bypass the caches.

**0x42090 — f0007af0 `st42090_cache_datapath_walk`.** Walking 0 in ones and
walking 1 in zeros through: the L2-D tag (bits 24..0, with Arb) via
WDD/SET_TAG/WDT at 0 and the complement at 0xFF0, checked with
`RDT & 0xFFFFFF80`; L2-D data (even and odd word, RDD); L1 tag (DR29) and
data (DR27/DR28) via WI1/RI1, complement at 0x3F8. Fail → dump with
sub-codes 0xED01F/0xED02F/0xED03F (tag), 0xED00D (data), 0xE100F/0xE100D
(L1). *Internals:* **all** — every tag/parity bit must be stored as
written; RI1's address is the value just written to CR18 (the queue's back
element); the L1 FPTAG/FPDATA parity bits read back as
XOR(written bits) ⊕ written parity bit.

**0x42091 — f00066d0 `st42091_cache_addr_lines`.** Address-line/alias
tests with exact expected values: L2-D data (clear 128 KB, write
power-of-two addresses 0x8…0x10000 with A|0xFFF00000, read all back),
L2-D tags (power-of-two lines), L2-I walking-address (bits 28..15) with
RI2D/RI2T, L1 128 entries (power-of-two), L1 walking address, and I/D
separation (D = −1, I = 0 at 0 and 0x1FFF8). Fail → 0x2DD05, 0x2DF05,
0x22D00/0x22F00, 0x21D05/0x21F05, 0x21D00/0x21F00, 0x2A00D/F, 0x2A01D/F.
*Internals:* exact geometry, L2-I and L2-D separate RAMs.

**0x4209F — f0006de0 `st4209f_cache_ram_patterns`** (failures report
**0x42092** I side / **0x42093** D side). 11-pattern rotating fill of every
L2 tag (tables f0007458 and complement f0007484) and data RAM (f00074b0 /
f0007508), then an L1 test with a Galois LFSR (seed 0x33DCF, taps
0x0076B553, software-computed parity). The bulk of it runs **from the
I-cache at address 0** (blocks f0007100–f000744F and f0007560–f000782B
loaded by `l2ic_load`). In manufacturing mode with fastboot off it waits 1 s
after each write phase (retention). *Internals:* **high** — diagnose
access to every RAM bit and execution from diagnose-loaded I-lines (no
refill, no next-line prefetch from memory; there is no memory yet).

**0x42096 — f0007ef8 `st42096_cache_init`.** Writes data 0 and tag
**0xF0000400** to every L2-I and L2-D line (WI2D/WDD ×8 + SET_TAG +
WI2T/WDT), L1 entries DR27 = DR28 = 0, DR29 = 0x18BC0000; clears DR0
flags. Always passes. This is the ROM's **cache initialisation**.

**0x42094 — f00084c0 `st42094_cache_hit_compare`.** For each RPN bit
(A = 0x1000 … 0x80000000): fill line A with 0x01234567/0x89ABCDEF and tag
A|0x400; a **real `ldw 0(A)`** must return 0x01234567 (cache hit, no
memory behind it) and `RDD A` must set DR0 HIT (bit 30); after rewriting
the tag with bit 0xF0000000 the RDD must miss. I side: line A filled with
`ldi −1,r19` (0xB41307FF), `bv r0(A)` with a branch back in its delay slot
executes exactly one instruction there (r19 = −1). L1 over L2: L1 entry =
`ldi −1`, L2 line = `ldi 1` (0xB4130002); with L1 enabled (DR0 bit 29 set,
taking effect for the next fetch) r19 = −1, after invalidating the L1 entry
r19 = 1. *Internals:* **high** — real loads/fetches satisfied purely by
tag match on all 20 RPN bits, DR0 HIT bit, L1/L2 interplay.

**0x42095 — f0008080 `st42095_cache_parity_detect`.** With HPMCs masked:
clean `ldw` must not flag; then every data bit (both words) and every tag
bit is written flipped while keeping the old parity (Arb): the diagnose
read must set **DR0 bit 8 (L2D) / bit 6 (L2I) and PARERR (bit 31)**; HIT
(30) stays 1 except when an RPN bit was flipped. Flags cleared between
steps. *Internals:* **high** — parity generation (even data per word, even
tag over RPN, odd dirty) and checking on diagnose reads, sticky W1C flags.

Then `set_psw(Q)` and DR0 = 0x02BF4AFC (+ revision fix-ups): L2 HPMCs
unmasked, L1 I-cache, prefetch and I-stream on, DUAL_DIS = 01, PF_MASK on.

### 4.4 `selftest2` tests

Entry: `set_dr0(0x03FF00FC)` (as at reset plus IPREF and L1 I-cache on).

**0x42097 — f000b940 `st42097_icache_smc_flush`.** `stw` the instruction
`ldi −1,r10` to RAM 0x640, `fdc`, `fic`, execute one instruction there (r10
= −1); repeat with `ldi 1,r10` (r10 = 1: the stale copy was invalidated in
L1 and L2); then 0xFEDCBA98 / 0x01234567 store/load/fdc checks.
*Internals:* FDC writes back + invalidates, FIC invalidates L2-I and L1,
effective two instructions later.

**0x42098 — f000ba28 `st42098_dcache_partial_store`.** Base 0x12345678 at
0x620, r7 = 0x0FEDCBA9: STH @0/@2 → 0x0FED5678 / 0x12340FED; STB @0..3 →
0xA9345678, 0x12A95678, 0x1234A978, 0x123456A9; STBY,B @0..3 → 0x0FEDCBA9,
0x12EDCBA9, 0x1234CBA9, 0x123456A9; STBY,E @0..3 → 0x12345678, 0x0F345678,
0x0FED5678, 0x0FEDCB78. *Internals:* none.

**0x42099 — f000bbc0 `st42099_icache_fill_tag`.** Store `ldi −1,r4` at 0x620,
`fic`, `fdc`, execute; `RI2T 0x620` must show RPN 0 with HIT = 1, PARERR = 0,
DR0 bit 6 = 0; `RI2D 0x620` == 0xB40407FF. *Internals:* I-miss fill writes
tag and data with correct parity, visible to diagnose reads.

**0x4209A — f000bc50 `st4209a_dcache_writeback`.** `stw 0x55555555 → 0x620`:
`RDT` must show RPN 0, **dirty = 1**, HIT, no parity error; `RDD` ==
0x55555555; after `fdc` + `ldw` the line is clean; if MEMC_CONT (page0
0x350) ≥ 0x20620, store 0xAAAAAAAA, load 0x20620 (same index) to force an
eviction, then 0x620 must read 0xAAAAAAAA. *Internals:* write-allocate,
dirty bit visible to RDT, copy-back on eviction.

**0x4209B — f000bdb0 `st4209b_cache_enable_flush`.** `set_dr0(0x00104AFC)`
then `fice` and `fdce` over all 4096 lines (`flush_icache`,
`flush_dcache`). Always passes.

After the cache tests: DR25 = page0[0xE4] | 9 = 9 (both hardware TLB-miss
walkers off, so TLB misses trap), then the TLB tests. They use DR8 (UTLB
diagnose register) to address TLB entries directly: diagnostic insert into
page entry n = `0x40 | n<<7` (+0x4000 lock-in, +0xC000 lock-out + lock-in),
block entry n = `0x2041 | n<<1 | lock<<14`, normal operation 0x2000 / 0x3780
/ 0x3F80. Helpers: `tlb_fill_all` f000ad88 (64 page entries VA (0x1000+n,
off | n<<24) → PA r26), `btlb_insert` f000adc8 (block entry, mask 0x7F = 512
KB), `expected_access` f000ae10 (PA 1.1 Table 3-1 as code), `tlb_reset`
f0011fa0 (`btlb_purge_all` in firmware.sym; link r22; all page entries invalid, block entries locked out, DR8 =
0x3780). Listing trap: loads/stores with an explicit space register print
with the s field folded into the displacement (`ldw 2000(r6)` is `ldw
0(sr1,r6)`, `4000(rX)` is `0(sr2,rX)`). None of the TLB tests checks ISR,
IOR or IIR.

**0x41091 — f000a0d8 `st41091_tlb_lpa`.** All 64 page entries map VA
(0x1000+n, n<<24) → PA 0x80000000; `lpa` of each must return 0x80000000
with no trap; each entry in turn is re-inserted (DR8 pointer) as VA (…,
0xFFFFF000) → PA 0xFFFFF000 and must translate, the others unchanged. Same
for the 8 block entries (PA 0x80000000, then 0xFFF80000).
*Internals:* DR8 pointer insert; 20-bit PPN per entry; LPA searching page
and block entries; the block size mask must not appear in the PA.

**0x41092 — f000a690 `st41092_tlb_patterns`** (body f000a710–f000a913 runs
from the I-cache at physical 0). PPN 0x55555 / 0xAAAAA in all page entries,
TRANS 0x55500000 / 0xAAA80000 in all blocks (checked by `lpa`); then a
walking-1 over every VPN bit — 20 offset bits and 16 space bits per page
entry, 13 + 16 per block entry — each re-inserted with PPN 0xCCCCC /
0xCCC80000 and checked by `lpa`. *Internals:* every TLB CAM and RAM bit.

**0x41093 — f000a918 `st41093_tlb_replace_lock`.** Normal (replacement)
inserts versus DR8-pointer inserts: `idtlba` also writes the entry whose VPN
matches and leaves the entry invalid until `idtlbp`; VPN match takes priority
over the replacement pointer; lock-out (DR8[16:17] = 11) forces a mismatch;
with every entry locked a normal insert is **dropped**; unlocking one entry
makes it the only replacement candidate; locked-in entries are only
replaced on a VPN match. Block entries: locked out → `lpa` misses (vector
17). *Internals:* **high** — PA7100LC TLB lock/replacement rules.

**0x41094 — f000a388 `st41094_tlb_probe`** (body f000a408–f000a68b from the
I-cache). For PL 0..3 × access rights 0..0x7F × 64 page entries (65,536
probes) and × 8 block entries: `probe,r` and `probe,w` results must equal
Table 3-1 (`expected_access`). Then PIDR1–4 = a walking bit, entry access
ID = the same, PSW.P = 1: `probei,r` must return 1.
*Internals:* exact access-rights table; PID check (15-bit access ID) only
with P = 1.

**0x41095 — f00095c0 `st41095_htlb_walker`.** Tests the **hardware TLB-miss
handler**: DR24 = PDIR base | 0xE0, DR25 = mask and control. (1) DR25 = 0,
DR24 base 0x55555000/0xAAAAA000, a zeroed line planted in the **D-cache by
diagnose writes** at the hashed address (no memory there): a data access
must take a DTLB-miss trap (vector 15) with **CR28 == the hashed PDIR
address**. (2) 56 VAs (single offset bits, single space bits, pairs): CR28
must equal the hash `base | ((off>>12)<<4 ^ space<<9) & (mask|0xFFF)` for
DTLB and also for an **ITLB** miss (vector 6, escaped via TR3 =
0x0900DEEE). (3)–(4) PDIR entries at 0x4000 with V/R/tag-mismatch/U/N
combinations: trap with CR28 = entry address, or (U = 1, N = 0) the entry's
next pointer 0xAAAAAAAA. (5) 98 VAs (table at 0xF0009DC0) with valid PDIR
entries → the walker inserts silently and `ldw` returns 0xC2239ABC from a
blob copied to PA 0x1000 (f0009D78). (6) the same for an instruction fetch.
*Internals:* **highest risk** — DR24/DR25, exact hash, PDIR format, CR28
rules (also on ITLB failure, which the ERS does not mention), walker reading
the PDIR through the D-cache.

**0x41096 — f000aed8 `st41096_tlb_tdb_traps`.** PA 0x1000 = 0xABCDEFAB; for
each page entry (and then each block entry): with D = 1, `lpa` and a
virtual `ldw` return 0xABCDEFAB; then `stw −1` with protection B=1 →
**vector 19** (data memory break), D=0 → **vector 20** (TLB dirty), T=1 →
**vector 21** (page reference, also for `ldw`, target register unchanged);
memory must never change. *Internals:* T/D/B bits from IDTLBP, trap
priority, store suppression.

**0x41090 — f0009548 `st41090_tlb_init`.** 64 diagnostic inserts (VA
(0x1000+n, 0) → PA 0, protection 0x02C00000) to clear power-on lock-out and
give every entry a unique VPN, then `pdtlbe`, DR8 = 0x3F80. Never fails;
also called by the TOC path (f0002c24).


**0x4108D — f0006540 `st4108d_dual_issue_timing`** (only if DR0[0:5] ≠ 0).
DUAL_DIS is stepped through 11, 10, 01, 00; a 10-instruction kernel at
physical 0xB4 (copy of f0006694, run from the I-cache) is timed with CR16:
the deltas must be **11, 9, 7, 6** (FAST_MODE = 0) or 19, 15, 13, 12
(FAST_MODE = 1). *Internals:* **high** — CR16 = one tick per CPU cycle and
the exact PA7100LC dual-issue pairing rules. **Bypass: report CPU revision
0** in DR0[0:5]; the test is then skipped and `set_dr0` forces single issue,
SOU off and I-stream off. (Rev 0 also changes MIOC control bit 14 at
f000d840 and PDC return values at f0013b00 and f0014dec — **cross-over**.)

**0x410D4 — f000b868 `st410d4_ldcw_coherence`** (needs RAM). At 0x620 and
0x630 with A = 0x12345678, B = 0x89ABCDEF: dirty line (`stw A`, `fdc`, `stw
B`×2) → LDCW returns B, then the word is 0; clean line → LDCW returns A, then
0; line absent → B, then 0; same with the short form LDCWS.
*Internals:* LDCW atomic and coherent with the D-cache in all three states.

**0x410D9 — f000b3e0 `st410d9_dio_parity_hpmc`** (LASI.AMR saved/restored
around it). Writes 0xAAAAAAAA to MEM_HPA+0xD0 and 0xAC to the LASI UART
scratch register (0xF0105807), reads both back; then, from code loaded into
the I-cache at 0 (f000b520–f000b74F), sets MIOC control (MEM_HPA+0x80)
bit 17 (bad address parity on the next I/O access) or bit 18 (bad data
parity) with DR0[18] = 1 and stores to MEM_HPA+0xD0 or the UART scratch
register: each store must cause an **HPMC** with status code **0x02**
(address) / **0x08** (data), and the stored value must **not** land.
*Internals:* **high** — needs MIOC parity-error injection modelled
(drop the write, set status, raise HPMC), a R/W register at MEM_HPA+0xD0,
the 16550 scratch register, and execution from the I-cache.

**FP tests — dispatcher f000dda0** (link r22; CCR = 0xC0 while running, old
CCR restored). Runs 0x44080, 0x44081, 0x44082 (first failure stops). Result
goes to **page0 byte 0x40** (3 = pass, 2 = fail); **an FP failure is not
fatal**: PDC_COPROC (f00123d8, `pdc_coproc_cfg`) then reports the FPU as present but not
functional (−3), and BOOT_ADMIN prints "WARNING: Floating Point Coprocessor
is present but not functioning". All operands are inline constants (no
tables). Scratch buffer at r19 = (sp + 0x20) & ~0xF, ~0x210 bytes of RAM.

**0x44080 — f000e448 `st44080_fp_regfile`.** `fldd`/`fstd` of fr0–fr31
(including exception registers fr0R–fr3) with 0, 0xFFEFFFFF, 0xAAAAAAAA,
0x55555555, walking 1 and walking 0; identity arithmetic on fr4–fr30: x +
0.0 and 0.0 + x, x × 1.0 and 1.0 × x must return x bit-exactly (including
NaN/denormal bit patterns). The status word compare is masked out (vacuous).
*Internals:* none beyond bit-exact storage; a non-zero exception register
must not trap while T = 0.

**0x44081 — f000de50 `st44081_fp_ops`.** Double then single precision:
2.0×2.0 = 4.0, 4.0+4.0 = 8.0, 8.0/2.0 = 4.0, sqrt 4.0 = 2.0, 4.0−2.0 = 2.0,
fcpy, fabs(−2.0), fcnvfx 16.0 → 0x00000000_00000010 (sgl 0x10), fcnvxf 16 →
0x40300000_00000000 (sgl 0x41800000), fmpyadd (4.0, 8.0), fmpysub (8.0, 8.0)
→ 0x40200000_00000000, fcnvff dbl→sgl 0x41000000 and sgl→dbl. After every
op the status flags V/Z/O/U/I must be 0; every `fcmp,=` must set C and the
following `ftest` must nullify a fail branch.

**0x44082 — f000ed40 `st44082_fp_exceptions`** (test IVA). (A) traps
disabled: 4.0/0.0 → +inf and flag Z; 10.0/3.0 → flag I; DBL_MAX² → flag O;
same in single precision (0x7F7FFFFF). (B) all trap enables on (status
0x1F): each of the six operations, immediately followed by a store of its
destination, must produce a **delayed assist-exception trap (vector 14) on
the store**; the handler (f00094f4) reloads status 0x1F and returns to the
store without skipping, and the store must then write **0** — the
excepting operation's result was suppressed. *Internals:* **delayed** FP
traps (T bit, trap on the next FP instruction, IIAOQ at that instruction),
result suppression; an immediate trap at the FP operation would loop
forever (QEMU traps immediately, so it is not a reference here). Denormals,
rounding modes and NaN arithmetic are not exercised.

### 4.5 Code run from the I-cache (`l2ic_load` f000786c) — settled

**It places code in the off-chip (L2) instruction cache through diagnose
writes, not in RAM.** Contract: r26 = source start, r25 = source end
(exclusive), r24 = destination physical address, link r31.

```
f0007870  b,l,n cache_size,rp            ; ret0 = 0x20000 (unused here)
f00078a8  b f00078c0 ; ldw,ma 4(r26),r19 ; first ROM word
f00078c0  extrw,u r24,19,20,r1 ; depw,z r1,19,20,r1 ; depwi 1,21,1,r1
                                         ; r1 = (r24 & ~0xFFF) | 0x400 = tag: RPN = page of r24,
                                         ;      dirty 0, dirty parity 1, Arb 0 (hardware parity)
f00078cc  sync ; diag WI2D r24 <- r19    ; write the word into L2-I data at index r24
f00078d4  cmpb,<,n r26,r25,f00078b0 ; ldw,ma 4(r26),r19
f00078b0  sync ; diag SET_TAG r1 ; diag WI2T r24 ; addi 4,r24,r24
f00078dc  sync ; SET_TAG r1 ; WI2T r24 ; bv,n r0(r31)
```

Every word gets its own WI2D + SET_TAG/WI2T, which is the sequence the
PCX-L ERS §8.3.5 prescribes. The caller then jumps to the destination in
real mode — `b,l RET,r31 ; bv,n r0(r0)` (branch in the delay slot, so the
instruction at RET is skipped and control goes to physical 0) — and the
fetches **hit the planted lines**; RAM is never read or written for the
code. Afterwards `l2ic_purge` (f0007894, same arguments) runs `fice` over
the destination lines (`flush_icache` f0015938 after the memory test).

Callers (destination 0 unless stated): 0x4209F (f0007100–f000744F and
f0007560–f000782B), 0x4108D (f00065e0–f00066CF), 0x41094
(f000a408–f000a68B), 0x41092 (f000a710–f000a913), 0x410D9
(f000b520–f000b74F), the memory test (f000c800–f000cb8B or
f000cb90–f000ce9B), the soft-boot scan (f000d1d8–f000d2C7), and
`mem_fail_report` via the byte-lane variant `l2ic_load_bytes` f0007a8c
(destination 0x10000, source read as one byte per word). Why: the memory
test writes all of RAM including address 0 through the D-cache, and the
I-cache is not coherent with data stores, so the code survives; selftest1's
cache tests run before memory is even sized.

Related: test 0x41095 plants zero lines in the **D-cache** with
WDD/SET_TAG/WDT (f0009cf4) so that the hardware TLB walker reads a PDIR at
addresses with no RAM, and `cache_as_ram_init` (f0002cf0) makes 16 KB of
D-cache lines valid at physical 0 so `mem_fail_report` can run with a stack
at 0x100 when RAM failed.

**FPGA consequence:** the soft CPU needs real, separate L2-I and L2-D tag +
data RAMs that the diagnose instructions can write and read, whose lines
then serve real fetches/loads purely by tag match (no refill while the tag
matches, no next-line prefetch from memory, I-side not snooped by data
stores), and F-space (≥ 0xF0000000) accesses that bypass the caches so the
"invalid" tag 0xF0000400 never hits. A cheaper emulation (a small
diagnose-loaded instruction RAM at physical 0 that shadows fetches until the
next `fice`) would cover the code-placement uses but not the cache tests.

### 4.6 Memory sizing and RAM test (`mem_size_and_test` f000bdf8)

Called from `mem_init` (§2.5) with r26 = FASTSIZE limit and dp = fastboot
(EE 0x1695 == 1). Chassis **0x410DA** when fastboot is **on**, **0x410DB**
when it is off. Register names below are the memory-controller (MIOC)
offsets from MEM_HPA = 0xFFFBF000; the layout matches the PA7300LC
MEMCOMP/MEMMASK scheme (**cross-over**, register agent).

1. **Reset the banks** (`mem_disable_blocks` f000bea8): MEMMASK[0..15]
   (MEM_HPA+0x140…0x17C) = 0x00400000 (bank empty); MEM_HPA+0xC0 =
   `mem_timing_word()` with bit 0x04000000 cleared (**ECC off**); SR0–SR7,
   r17–r21 = 0.
2. **Probe each bank b = 0..15** (`mem_probe_block` f000c210):
   MEMCOMP[b] (MEM_HPA+0x100+4b) = 0, MEMMASK[b] = 0x1F800000 (512 MB window
   at 0); write a line of 0xAAAAAAAA at 0 and 0x123ABC78 at 0x20 (so a
   floating bus does not read back 0xAA…), `fdc`; read words 0 and 4: both
   0xAAAAAAAA = present, both wrong = empty, one wrong = SIMM error (−1 even
   word, −2 odd word). Then write 0x55555555 at test addresses and re-read
   words 0/4 to detect aliasing (classification table at 0xF000C5BC):

   | MEMMASK (tech) | test address | aliased → |
   |---|---|---|
   | 0x1F800000 (0) | 4 MB / 8 MB / 16 MB | error −6 / 8 MB / 16 MB |
   | 0x3F800000 (1) | 32, 16 MB | 32 MB |
   | 0x5F800000 (2) | 64, 32 MB | 64 MB |
   | 0x7F800000 (3) | 128, 64, 32 MB | 128 MB |
   | 0x9F800000 (4) | 128, 64 MB | 256 MB; none aliased → 512 MB |

   Sizes are kept as bitmaps in **space registers** (bit 15−b: SR0 = 8 MB,
   SR1 = 16, … SR6 = 512 MB); error codes in r20/r21 (2 bits per bank). The
   bank is left disabled (MEMMASK = 0x00400000). The aliasing writes must
   evict the cached line 0, which requires a direct-mapped D-cache whose size
   divides 4 MB.
3. **Load the test body into the I-cache at 0** (`l2ic_load`): fastboot off →
   0xF000C800–0xF000CB8B (LFSR test), fastboot on → 0xF000CB90–0xF000CE9B
   (ones/zeros test).
4. **Allocate and test**, size class 512 MB down to 8 MB, banks 0..15 within
   a class, until the limit is reached: MEMCOMP[b] = base, MEMMASK[b] = final
   value (8 MB 0x00000000, 16 MB 0x00800000, 32 MB 0x01800000, 64 MB
   0x23800000, 128 MB 0x47800000, 256 MB 0x6F800000, 512 MB 0x9F800000);
   `b,l f000c160,r31 ; bv,n r0(r0)` runs the body from the I-cache over
   [base, min(base + size, limit)). Pass → SR7 bit set; fail (r25 = −1 even /
   −2 odd SIMM) → bank disabled and the base rewound. The result is a
   contiguous map in descending size order.
   * **LFSR test** (f000c800, fastboot off): Galois LFSR (seed 0x00033DCF,
     taps 0x0076B553), 9 values per 32-byte line. Pass 1: MEM_HPA+0xC4
     (check-byte source) = x, line = next 8 values, `fdce`. Pass 2: read the
     line; MEM_HPA+0xDC (check bytes of the last line read) must equal x and
     each word its value; rewrite complemented. Pass 3: check the complements.
     Pass 4: C4 = 0x33333333, line = 0. ~146 instructions per line.
   * **Ones/zeros test** (f000cb90, fastboot on): C4 = 0xCCCCCCCC, line =
     0xFFFFFFFF; read back (DC == 0xCCCCCCCC); C4 = 0x33333333, line = 0;
     read back (DC == 0x33333333). ~66 instructions per line.
   * Both leave RAM zeroed with check bytes 0x33.
5. **Errors** (`mem_report_errors` f000c6e8): chassis sequence 0x271ss
   (ss = SIMM slot), bank, check-bit flag, address byte, expected and actual
   halves, 0x271ss again; then one 0x271ss per other failing SIMM. No memory
   at all → **0x2707D** (ret0 = −5). `mem_fail_report` then prints "Memory
   card failed or missing" (−1), "Mismatched memory cards" (−2),
   "Unsupported memory card" (−3), "Processor Board" (−4) or "No memory
   found" (−5) and "SYSTEM HALTED" (running with a cache-as-RAM stack).
   Bank → slot mapping for the 715/64 (strap nibble 7): banks {0,5} → slot
   2, {2,7} → 0, {8,13} → 6, {10,15} → 4, +1 for the odd word.
6. **0x410D7 — f000d870 `mem_ecc_singlebit`.** With ECC on, baseline
   (0x01234567, 0xFEDCBA98)×4 must read back clean with MEM_HPA+0x84 & 0x7F
   == 0 and DC == 0x55555555. Then every single data bit of words 0 and 4,
   one bit in each word 0..7, and each check-byte bit 0..7 are injected
   (written with ECC off, C4 supplying the check byte) and read with ECC on:
   data must come back **corrected**, status 0x40, MEM_HPA+0xD0/0xD4 = raw
   data, +0xD8 = raw check byte, +0xE0 = doubleword address. Finally an
   **LPMC** (vector 5, MIOC control bit 0x1000) must be delivered. Fail →
   chassis **0x210D7**, ret0 = −4.
7. **0x410D8 — f000d2d0 `mem_ecc_multibit`.** Double-bit and some
   triple-bit data / check-byte errors (0x01000400 in word 0 and 4,
   0x00000D00, check XOR 0xD0 / 0x0D / 0x88) must raise an **HPMC**
   (expected via DR0[18]) with status 0x20 and the raw-data registers set.
   Fail → ret0 = −4 (no extra chassis code).
8. `mem_slot_table` f000cea0 writes the per-SIMM table at page0 0x54–0xD3.

**Soft boot** (`mem_softboot_check` f000be78, chassis 0x4707E → f000d0f8):
loads 0xF000D1D8–0xF000D2C7 into the I-cache, ECC on, reads one word per
32 bytes up to the previous size with DR0[18] set: no HPMC and status & 0x3F
== 0 → keep the old map (MEMCOMP/MEMMASK and RAM are **not** reprogrammed);
otherwise fall back to the full path.

**FPGA notes for memory.** *Internals:* **high** — the sizing depends on the
MEMCOMP/MEMMASK decode and aliasing (an empty but enabled bank must read a
constant other than 0xAAAAAAAA without faulting; a bank of size S aliases
modulo S; a 256 MB bank under tech 4 must alias at 128 MB), on a
direct-mapped D-cache, and the RAM tests on **ECC check-byte storage** (8
bits per doubleword, MEM_HPA+0xC4/0xDC) with an ECC code for which
ECC(0) = 0x33 and ECC(0x01234567FEDCBA98) = 0x55, single-error correction
over 72 bits, multi-bit detection, and the error registers at
+0x84/+0xD0/+0xD4/+0xD8/+0xE0. Options: model the ECC; or run with
fastboot on and synthesise DC from the data (still needs ECC(~0) = 0xCC);
or patch the two ECC tests and the DC compares out of the ROM. Suggested
fitting: 64 or 128 MB as bank 0; 256 MB as 2 × 128 MB (banks 0 and 2),
never one 256 MB bank. FASTSIZE (EE 0x105F) must be ≥ 0x0E or the reported
size is clipped. Time per MB at 50 MHz: LFSR ≈ 0.2 s, ones/zeros ≈ 0.12 s
(≈ 12 s / 8 s for 64 MB, estimates).

### 4.7 What this means for the FPGA CPU and test bench

* **Architected behaviour exercised** (good seed for the CPU test bench,
  every value above is exact): branch-in-delay-slot, B,L link =
  IAOQ_Back+4, BLR with negative index, every PA 1.1 condition including
  digit/byte/halfword carries and DCOR, PSW C/B, traps from ADDIO/SUBT/
  BREAK, RCTR decrement count, CR18 queue semantics, RFI/RFIR with PSW.N,
  shadow registers, EIR/EIRR/EIEM/CR16, LDCW, partial stores, fdc/fic
  self-modifying code, TLB insert/purge/LPA/PROBE/protection traps, FP
  arithmetic and delayed FP traps.
* **Chip internals the ROM depends on** (must be emulated or bypassed):
  DR0 (bit semantics, STORE bits, FAST_MODE, HIT/PARERR, sticky cache error
  flags), DR1 (timer load), DR8 (TLB pointer/lock), DR24/DR25 (hardware TLB
  walker, cache size), DR27–29 (L1 I-cache), GR_SHDW/SHDW_GR, the L2 cache
  diagnose instructions (RDD/RDT/RI2D/RI2T/WDD/WDT/WI2D/WI2T/SET_TAG) with
  real tag/parity storage, TOC_EN, the MIOC status/control/ECC registers,
  and the hardware TLB-miss walker.
* **Cheapest path through:** report CPU revision 0 in DR0[0:5] (skips
  0x4108D and selects single issue); run with fastboot on; implement the
  caches with the PCX-L geometry and diagnose access (the cache, TLB and
  memory tests cannot be passed otherwise); model the MIOC ECC and parity
  injection behaviourally, or patch the four MIOC-dependent tests
  (0x410D2 parts, 0x410D9, 0x410D7, 0x410D8). FP test failures are not
  fatal (FPU reported "present but not functioning").
* **Open questions:** BB/BVB with c = 101 (decode bit 16 or the generic
  `<>` condition — both pass); the real 715/64's CPU revision; the 7100LC
  MIOC status bit map (ROM implies 0x02 I/O timeout / address parity, 0x08
  data parity, 0x10 TOC, 0x20 multi-bit, 0x40 single-bit); whether CR28 is
  written on an ITLB walker failure (the ROM requires it, the ERS says DTLB
  only); TOC masking/vectoring details on the 7100LC (inferred from the
  7300LC ERS); the real ECC H-matrix.

---

## 5. Timing

* **CPU clock** is not measured; it is read from a board strap:
  `get_cpu_speed` (f0015e24): `ldw 0xF00FFFFC`, field `(w >> 4) & 0xF`:
  0x7 → 1 (64 MHz), 0xB → 2 (80 MHz), anything else → 3 (100 MHz). The same
  nibble is decoded elsewhere: 0xE selects the FW-SCSI/4-graphics-slot model
  variant (help text f001669c, f00034a4, f0013fac), 0xF has its own case in
  f00158a8 (memory code). The word lives at the top of LASI's 8-bit external
  bus space (third chip select, 0xF00C0000–0xF00FFFFF, which also holds the
  EEPROM at 0xF00C0000 and the LED latch at 0xF00EFFFF) — **cross-over**
  (register agent). For a 715/64 the low byte must read 0x7x.
* **CR16** is the only time base. Helpers:
  * `delay_us` (f0015dc0): r26 µs × 64 / 80 / **96** (the 100 MHz case
    computes 64+32, a ROM bug) CR16 ticks, wrap-safe busy loop.
  * `timeout_us` (f00157a4): deadline check, ×64/×80/×100 ticks per µs; used
    for the 10 ms EEPROM byte-program timeout.
  * `elapsed_10ms` (f0015e50): (start, n ≤ 1000) → 1 when n × 640000 /
    800000 / 1000000 ticks have elapsed.
  * `uart_spin_delay` (f0015c5c): a CR16-free spin of 976 iterations
    (≈ 1,000,000 >> 10), used in UART polling (201 spins ≈ timeout).
* No calibration against the RTC. The RTC (LASI 0xF0109000) is only read by
  PDC_TOD and by the fastboot-off check that it advances during a 1 s
  `delay_us`.
* Page0 MEM_10MSEC (0x38C) tells the OS 640000/800000/1000000 ticks per
  10 ms, so **CR16 must really advance at the strap's frequency** (64 MHz for
  a 715/64) or HP-UX/Linux time-keeping will be off. ROM delays only scale.
* `ipl_launch` writes CR16 = 0 before entering the IPL.

---

## 6. UART used for chassis codes / PIM dumps

`uart_init_test` (f0015a98) programs the LASI 16550 through the register
window at **0xF0105800** (LASI UART base + 0x800): IER = 0, MCR = 4, FCR = 1
then 7, and requires **IIR == 0xC1** (FIFOs enabled, no interrupt); LCR =
0x83, DLL = 0x2F (47 → 9600 baud from a 7.3728 MHz clock), DLM = 0, both
read back and compared; LCR = 0x03; waits for LSR.TEMT (bit 6) and sets MCR =
7. Any mismatch → −1 (chassis codes then go only to the LEDs). `uart_putc_raw`
(f0015b78) polls LSR bit 0 for an incoming XOFF (0x13) and waits for XON
(0x11), then waits for TEMT before writing THR.

---

## 7. What the hardware must provide (early-failure list for the FPGA)

Ordered roughly by how early the ROM would stop. "Silent" means the LEDs
keep the last code and nothing is printed.

| # | Requirement | Where | Failure mode |
|---|---|---|---|
| 1 | Reset fetch from 0xF0000004 with PSW = M; HPMC **and TOC** vector to 0xF0000000 (not IVA+0x20). | 1, 2.11 | — |
| 2 | **Strap word at 0xF00FFFFC**: bits 4–7 = 0x7 for a 715/64 (0xB = 80 MHz, other = 100 MHz; 0xE/0xF select other models). | 5 | wrong speed constants, wrong model behaviour |
| 3 | Stores to WAX (0xF0201000, 0xF0201C00), LASI+0xB000…B00C, MEM_HPA+0x80/0xC0, LASI.PCR/IORESET/AMR, the LED latch 0xF00EFFFF and the broadcast register 0xFFFC0020 must complete without an HPMC. They happen before any HPMC can be tolerated. | 2.2, 2.6 | HPMC with DR0 bit 18 clear → 0x2CBxx codes, halt |
| 4 | DR0 (diag MTCPU/MFCPU 0) with the PCX-L bit semantics the ROM relies on: rev field [0:5] read-only, error flags write-one-to-clear, STORE[0]/STORE[1] (bits 16, 18) read/write; DR24, DR25 writable. See §4 for the self-test details. | 2.2 | self-test 0x41080 and others fail; probes break |
| 5 | **Reads of unmapped I/O addresses must raise an HPMC** (MIOC bus error), recorded in MEM_HPA+0x84 (status & 0x7F: 0x02 I/O timeout or address parity, 0x08 data parity, 0x10 TOC, 0x20 multi-bit ECC, 0x40 single-bit ECC; cleared by writing the value back) and with the HPMC resumable (IIA queues valid, Q = 1, `diag SHDW_GR` restoring GR1/8/9/16/17/24/25 shadows). Probed addresses: 0xF041FFFE, 0xF0200000, 0xF1000000, 0xFC000C80 at reset; every HPA of the page0 0x66C table and anything PDC_ADD_VALID is asked about later. | 2.4 | if reads return data: phantom second LASI at 0xF0500000, phantom EISA/FW-SCSI/graphics slots, wrong console/boot search |
| 6 | **EEPROM** at 0xF00C0000: byte reads, byte writes that read back the new value within 10 ms, word reads; ≥ 8 KB (offsets up to 0x1E0F used). Contents must persist. A blank EEPROM is accepted but puts the machine in manufacturing mode (BOOT_ADMIN, chassis codes on RS-232, LAN-address prompt) — ship a pre-initialised image instead (EE 0x16D9 = 'N', 0x16DA = 'Y', 0x16D8 = 'G', 0x1694 ≠ 0xB0/0xB1, programmed LAN address). | 2.3 | write timeout → 0x23003, silent halt |
| 7 | **CPU, cache, TLB self-tests** (§4, summary §4.7): exact architected behaviour (conditions, nullification, branch in delay slot, traps, RCTR, CR18 queue, RFI/RFIR, shadow GRs, EIR/EIRR/CR16), DR0/DR1/DR8/DR24/DR25/DR27–29 diagnose registers, L2 cache diagnose read/write with real tag/parity RAMs, execution of diagnose-planted I-cache lines, PCX-L TLB lock/replacement rules and hardware TLB walker, HPMC on I/O timeout and TOC via the CPU's own COMMAND register. Report CPU revision 0 to skip the cycle-exact dual-issue test. FP failures are not fatal. | 4 | LED 0x41/0x42 + PCR blink (selftest1) or "failed selftest" table + halt (selftest2) |
| 8 | **Memory controller** MEMCOMP/MEMMASK decode with the aliasing the sizing expects, ECC check-byte storage and ECC error reporting/injection (MEM_HPA+0x84/0xC4/0xD0–0xE0), LPMC/HPMC on ECC errors (§4.6). | 4.6 | 0x6C2xx/0x27xxx codes, `mem_fail_report`, halt |
| 9 | **LASI interrupt path**: IAR power-up value 0xFFFBE003; PS/2 port 0 loopback (control bit LPBXR) must receive the transmitted byte and raise IRR bit 26; LASI must then write to the CPU's IO_EIR (0xFFFBE000) so that EIRR bit 3 is set (with EIEM = 0). | 2.3, f0000298 | **silent halt** right after memory init |
| 10 | CR16 counting at the strap frequency (64 MHz); `mtctl` to CR16 writes the compare register, not the counter. | 5 | delays scaled; OS clock wrong |
| 11 | A console: either the LASI UART (16550 with FIFOs — IIR must read 0xC1 after FCR = 7) or Artist graphics + STI ROM and a PS/2 keyboard. | 2.6 | LED blink pattern forever (`no_console_blink`); "Failed to initialize a keyboard" + 0x6B009 if BOOT_ADMIN is entered without one |
| 12 | Broadcast CMD_RESET (store 5 to 0xFFFC0030) must reset the machine (`reset`, `DefaultSS`, presumably PDC_BROADCAST_RESET). | 2.9 | command hangs |
| 13 | LASI.PCR: the CPU-selftest failure loop writes 0 and 2 alternately; on a 712 bit 1 (PWR_ON_L) powers the machine off. Decide what the FPGA does with it (ignore, or drive the power LED). | 2.3 | — |
| 14 | LASI RTC (0xF0109000) must advance within 1 s — only checked with fastboot off. | 2.7 | 0x284xx code, "Real Time Clock" in the failed-items list |
| 15 | A boot device whose IODC ENTRY_IO can read a LIF volume; IPL word-sum must be 0. | 2.10 | 0x6C5Fx codes |


---

## 8. Cross-overs for the other analyses

* **Register map agent:** strap word 0xF00FFFFC (bits 4–7), LED latch
  0xF00EFFFF (active low, byte), EEPROM window 0xF00C0000, the unknown LASI
  unit at +0xB000–0xB00C (speed-dependent values, bit 31 = enable/latch?),
  MEM_HPA+0x80 (0xCDFA8000 at reset), +0x84 (status & 0x7F: 0x02 I/O timeout / address parity, 0x08 data parity, 0x10 TOC, 0x20 multi-bit, 0x40 single-bit ECC; write back to clear), +0xC0 (timing), +0x100+4n and
  +0x140+4n (per-slot config, §4.6), broadcast 0xFFFC0020 (0xFFF81001 written
  by `io_module_table_init`) and 0xFFFC0030 (CMD_RESET = 5), LASI.AMR, the
  second LASI at 0xF0500000 (config byte at 0xF041FFFE), the 0xF1000000
  probe, EISA 0xFC000C80/0xFC000461, DR0/DR24/DR25 values;
  from the self-tests: MIOC control (+0x80) bit 0x1000 = LPMC enable on
  single-bit ECC, bits 17/18 = inject bad address/data parity on the next
  I/O access, bit 14 cleared for CPU rev 0 (f000d840); +0xC0 bit 0x04000000
  = ECC on; +0xC4 check-byte source for writes with ECC off; +0xDC raw check
  bytes of the last line read; +0xD0/+0xD4/+0xD8/+0xE0 error data/check
  byte/address; +0xD0 also a plain R/W register (test 0x410D9); MEMMASK
  encodings in §4.6; the CPU's own COMMAND register CPU_HPA+0x30 (5 → TOC)
  and EIR CPU_HPA+0 (n → EIRR bit n).
* **PDC/IODC/STI/EEPROM agent:** PDC entry 0xF0012870 and the dispatcher;
  private PDC procs **0x80** (device path → HPA/IODC lookup) and **0x81**
  (EEPROM byte access: option 2 = read, 3 = write, extra argument key
  0xB00B0079); PDC_ADD_VALID's own IVA at 0xF0011800 (same HPMC-forwarding
  trick); PIM save areas EE 0x1400 (HPMC) / 0x1564 (TOC) written by
  `pim_save_eeprom` f00043c8; page0 fields in §2.5; IODC images copied to
  RAM at 0x4000 / page0[0x44]; EEPROM bytes used by the boot flow: 0x105F
  FASTSIZE, 0x1694 chassis/manufacturing (0xB0 on, 0xB1 manufacturing, 0xFF
  off), 0x1695 fastboot (1 = on), 0x1696 secure, 0x1699 diagnostic boot,
  0x16A4–0x16B0 words, 0x16B4–0x16BF LAN station addresses (0xEE = not
  programmed), 0x16CA/0x16D4/0x16D5/0x16D6 monitor type per graphics slot,
  0x16D8 'G' (customer defaults written), 0x16D9 'N' / 0x16DA 'Y' (EEPROM
  initialised), 0x1E04/0x1E0C, 0x400–0x408; stable-storage offsets 0x00
  (primary path, flags byte: bit 7 autoboot, bit 6 autosearch), 0x60
  console, 0x80 alternate, 0xA0 keyboard; the BOOT_ADMIN keyword table at
  0xF00230B0; page0 byte 0x40 = FP self-test result
  (3 pass / 2 fail) consumed by PDC_COPROC (f00123d8, `pdc_coproc_cfg`).

