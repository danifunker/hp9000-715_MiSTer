# 07 -- HP-UX 10.20 and Linux versus PA-7100LC implementation details (cpu.md Q3, Q4, Q7, Q8)

Status: review, 2026-10-07. Answers the open questions Q3, Q4, Q7 and Q8 of
`docs/design/cpu.md` section 8.4 from the HP-UX 10.20 kernel binary, HP's PDC 1.6
ROM and the Linux 5.15 source. Nothing in `cpu.md` has been changed; every finding
ends with an **Impact on cpu.md** line for the spec owner.

**Evidence and citations** -- as in `06-os-hpux-linux.md`:

| Prefix | Meaning |
|---|---|
| `sym`@0xADDR | HP-UX 10.20 `/stand/vmunix` (`roms/hpux/vmunix`, B.10.20 base of Jun 9 1996 with PHKL patches up to late 1999). Listing `roms/hpux/vmunix.dis` (tools/hpux/som.py). |
| ROM F00xxxxx | HP PDC 1.6, `roms/disasm/rom.dis` |
| L `path:line` | Linux 5.15, `~/repos/Linux-Kernel_MiSTer` |
| ERS s.n / ERS `n` | PA7100LC ERS, forward copy `keep/doc-review-text/pcxl_fwd.txt` (line `n`) |
| R06 s.n, BOOT, FW, HW | `docs/review/06-os-hpux-linux.md`; `docs/reference/rom/BOOTFLOW.md`, `FIRMWARE.md`, `HARDWARE.md` |

New helper scripts (session scratchpad `keep/hpux-analysis/`, listed in
`keep/INDEX.md`): `implscan.py` classifies every implementation-specific or unusual
opcode in the code subspaces of the listing, with the containing function;
`datascan.py` looks for instruction templates in the data subspaces.

---

## 0. The short version

| Q | Finding | Recommendation |
|---|---|---|
| **Q3** revision | HP-UX 10.20 has **one** PCX-L revision check: `realmain`@0x159D0C sets `normal_gate = 0` when the revision is **< 0xC**. It then maps the syscall gateway page without gateway rights and emulates every `B,GATE` in the trap-7 handler, the path early 7100LC steppings needed. All the other revision checks are PCX-T/PCX-T' only. The revision also changes **PDC_SOFT_POWER** in HP's ROM: at rev 0 it returns OK without writing its result. HP-UX survives this, because its `pdc_call` zeroes a bounce buffer. **Linux does not**: it takes the stale `pdc_result[0]` as a soft-power register address and polls it every second (risk of a spurious shutdown, or an HPMC). Linux uses the revision only in a `printk`. | **Report 0xC to the OS.** Best: DR0[0:5] = **0xC**, as on a real 715/64, plus **one ROM word** (file offset 0xB810: 0x86802012 -> 0xE8000012, `b,l,n 0xf000b820`) so that the ROM skips the cycle-exact dual-issue test exactly as it does at rev 0. Fallback: keep DR0 = 0 and patch two words (PDC_MODEL versions -> 0xC, and the SOFT_POWER rev-0 early-out). Rev 0 with an unpatched ROM is **not safe for Linux**. |
| **Q4** walker / CR28 | Only the **DTLB-miss (15)** handler reads CR28. When PDC_TLB works, its vector becomes `mfctl cr28,r1; b dtlb_got_next_ptr_PCXT`: it does not compute the hash, starts the chain walk at CR28 and treats CR28 = 0 as a page fault. The ITLB (6), non-access (16, 17), dirty (20), T-bit (21) and imem-protection (7) handlers all recompute the hash from ISR/IOR or IIASQ/IIAOQ and ignore CR28. TR4 (= CR28) is scratch only in real-mode trap code, and the FP emulation saves and restores it around its virtual accesses. HP-UX's set_state 5 makes the ROM enable **both** walkers with U = 1, N = 0. | Trap 15: CR28 exactly as in the ERS table (with U = 1, N = 0: the current entry if !(V and R), else the entry's own next word, word3 or word7, which may be 0). Trap 6: the same rules (the ROM needs them; HP-UX ignores them). Trap 17: writing with the same rules is harmless (cpu.md default, keep). Trap 16: never raised. **New rule: never write CR28 when that side's walker is disabled** (DR25 I/D = 1). Linux can keep a live value in CR28. |
| **Q7** undefined DIAG | On a correctly identified PCX-L, neither OS executes an undefined DIAG. The PCX-T DIAGs in HP-UX are reachable only if HP-UX takes the CPU for a PCX-T (PDC reports 16 BTLB slots). There `setCPU0`'s 0x141A1600 is undefined on PCX-L (trap 8 catches the mistake), but `getCPU0`'s 0x141C1A00 decodes as **SHDW_GR** and silently overwrites seven GRs. | Keep **trap 8** for undefined DIAG, and have the simulator log every DIAG executed outside the ROM. |
| **Q8** impl.-specific opcodes | The only DIAG HP-UX 10.20 executes on a PCX-L is **MFCPU_T DR25** (0x1720141C, `getCPU25_PCXL`@0x1BC5C): it polls the soft-power bit 4 times a second, because HP's ROM always answers PDC_SOFT_POWER. This corrects R06 s.0 item 8 and s.3.1, which assumed SOFT_POWER could be made to fail. There are **no** fast TLB inserts, MAX-1, FMPYCFXT, clip-test FTEST, multi-endian word ops, SPOP or reachable COPR uid >= 2. Two things the spec must still handle: (a) about 30 **nullified** PA 2.0 LDD/STD words (majors 0x14/0x1C) in generic PA 1.1 paths, and (b) **FSTQS** (major 0x0F, Venom quad store) in the `fp_method2` copy routines, which HP-UX enables only if PDC_MODEL `current_key` bit 31 is set (the 715 returns 0x72, so it stays off). Linux on PCX-L executes MFCPU_C/MTCPU DR0 once and, at rev != 0, MFCPU_T DR25 once a second. | No decode change needed. Add tests: nullified undefined opcodes must not trap; DR25 bit 0 must read 1 through MFCPU_T. Keep IxTLBxF and MAX-1 (user code, HP-UX 9). HP-UX 11i media exist in `~/Downloads` for a follow-up scan; there is no 9.05 image. |

---

## 1. Q3 -- CPU revision

### 1.1 Where the revision comes from

The CPU has no revision register except DR0[0:5]. HP's ROM reads that field at five places (ROM `MFCPU_C DR0` followed by `extrw,u ...,5,6`):

| ROM site | What the revision changes | rev 0 | rev 0xC (real 715/64) |
|---|---|---|---|
| `set_dr0` F0015CDC | DR0 fix-ups (HW s.8.2) | SOU off, DUAL_DIS = 11, ISTRM off | DUAL_DIS = 00 (rev > 10) |
| F000B808-F000B81C (selftest2) | runs test 0x4108D `st4108d_dual_issue_timing` | skipped | **runs; needs cycle-exact dual issue** |
| F000D83C | MIOC control (MEM_HPA+0x80) bit 14 | cleared | left set |
| `pdc_soft_power` F0013B00 | PDC_SOFT_POWER | returns 0 at F0013B0C **without writing the return buffer or LASI PCR** | option 0: `pdc_clear_ret_buffer` -> status-register address 0 ("Gecko" style); option 1: LASI PCR bit 31 cleared (ARG3 = 1) or set (ARG3 = 0), plus bit 30 when DR25 bit 0 = 0 |
| `pdc_model_versions` F0014DEC | PDC_MODEL option 2, c_index 0 | 0 | 0xC (`715_64.h:34` `PARISC_PDC_VERSION 0x000c`) |

The ROM's ENSPEC/DISSPEC (F0014EB0/F0014EC8) only compare the key with 0x72. They touch no hardware, so MAX-1 and the other PCX-L instructions are always enabled.

**Impact on cpu.md:** sec. 5.1 DR0 row and P-008 should list all five consumers, not only the dual-issue test.

### 1.2 HP-UX 10.20: every read and use of the revision

The only source is `getcputype`@0x173F28. It calls PDC_MODEL(4, 2, c_index 0) at 0x174364, stores word 0 into **`cpu_revision_number`**@0x443748 (address set up at 0x17435C) and ignores the return status. `cpu_version`@0x443774 is the architecture code: 0x210 for arch_rev 4 (0x17432C-0x174350), 0x20B for 1.0, 0x214 for 2.0. It is not a revision. `_CPU_REVISION`@0x447B4C is never referenced. HP-UX never reads DR0 on a PCX-L (s.3.2). Every reader of `cpu_revision_number`, found with `findref2.py`:

| Site | Condition | Effect | On PCX-L? |
|---|---|---|---|
| `realmain`@0x158F20-0x158F84 | PCX-T and rev < 0x11 | `getCPU0` / `stalloff` (PCX-T DIAG). If also rev < 9 and HW assist: `patch_to_nop(patch_exception_trap)`, which enables the PCX-T DIAG errata code at 0x217B8 | no |
| `realmain`@0x158F88-0x158FD8 | unless (PCX-T and rev < 9 and HW assist) | `patch_to_nop` of `itlbmss_fault_check_PCXT`@0x1A9CC, `imem_fault_check_PCXT`@0x1ACCC and their `_mp` twins (switches off a PCX-T IIR-inspection erratum path) | always patched (the fast path) |
| `realmain`@0x158FDC-0x159028 | S700 and PCX-T and rev >= 0x11 | `hintson` (PCX-T DR0 writes) | no |
| `realmain`@0x15965C | PCX-T' and rev >= 7 | `optimize_UP_purge_tlb` | no |
| **`realmain`@0x159D0C-0x159D70** | **PCX-L and rev < 0xC** (`cmpib,>>,n 0xc,r23`) | **`normal_gate = 0`**. Also 0 for any PCX-T, and for PCX-T' rev < 9. `force_normal_gate`@0x4437C8 (initially 0) can override it | **yes** |
| `set_machine_parameters`@0x1796D0 | PCX-T' and rev < 8 | no CR28 use at all | no |
| `enable_hw_tlb_miss`@0x1FF0F4 | PCX-T' and rev < 8 | walker not enabled | no |
| `$emulation_trap`@0x21C18 | rev < 0x200 (with a per-CPU flag) | FP-emulation opcode decode | same for 0 and 0xC |
| `get_pepsi_rev`@0x1FEE48 | cputype 0x183 only | own PDC_MODEL(4, 2) call | no |

Processor naming does not depend on the revision. `getcputype` builds `utsname.machine` from PDC_MODEL(4, 3) ("9000/715"); its fallback table and the kernel debugger's `rdb_cpu_lookup_table`@0x401388 are keyed by `cputype` = (HVERSION >> 4) & 0xFFF = 0x60A. HP-UX prints no CPU name or revision. sysconf exports `cpu_version`, not the revision.

### 1.3 `normal_gate` -- what rev < 0xC really does

`realmain`@0x159E0C-0x159E64:

- **normal_gate = 1** (rev >= 0xC): `kvinit(0xC0000, gateway page, prot 0x4C, 1)` at 0x159E28. The gateway page appears at VA 0xC0000000 with access rights 0x4C, which `pdapage1_1`@0x628E4 deposits at IDTLBP bits 5:11: type 4 (gateway, promote to PL 0), PL1 = 3. User code enters the kernel through the `b,gate` stubs at `syscallbase`@0x14018 (R06 s.3.8).
- **normal_gate = 0** (rev < 0xC): it NOPs `imem_not_normal_gate_patch_PCXT`@0x1AC64 and `..._mp`@0x1B484, and maps the page with prot **0x20** (type 2 read/execute, PL1 = PL2 = 0) at 0x159E60. Every user branch to 0xC0000000 then takes **trap 7**. `$i_imem_prot_89`@0x180E0 leads to `imem_protection_tlb_miss_PCXT`@0x1AC60. That handler checks IIASQ = 0 and an IIAOQ inside the gateway page (0xC0000000, 0xC0000004, or a `b,gate` slot at offset 8 mod 16 of 0xC0000018-0xC0000FF7). `imem_gateway_PCXT`@0x1AD7C then loads IIAOQ = {addr & ~3, +4} (privilege 0) and IIASQ = {0, 0} and does `rfi,r`. `imem_gate_priv0_PCXT`@0x1ADA0 handles a fault that is already at PL 0 with `iitlba r0,(sr1,0xC0000004)` alone, which on PCX-L invalidates the matching entry (E = 0), then `rfi,r`.

The software path is architecturally clean: trap 7 on execute rights, CR17/CR18 queue writes, RFIR with privilege taken from the IIAOQ. It works on a correct core. But it is a pre-production-stepping path, adds a trap to every system call, and leaves native `B,GATE` promotion untested under HP-UX.

**Impact on cpu.md:** sec. 8.4 Q3 and sec. 5.6: HP-UX 10.20 needs **rev >= 0xC** for the normal gateway path. The trap-suite should cover both paths, native B,GATE with AR type 4 and trap-7 emulation with an RFIR to PL 0.

### 1.4 PDC_SOFT_POWER -- the hidden revision dependency (both OSes)

**HP-UX:**
- `pfail_enable_power_switch`@0x53120, called from `main`@0x84FAC after the root mount, calls PDC_SOFT_POWER(23, 0). If that returns OK, it stores result word 0 into `soft_power_status_reg`@0x444328 (initially -1), then calls (23, 1, ARG3 = 1).
- `pdc_call`@0x137EA8 looks up a descriptor table at 0x403B90 (+84 × proc + 12 × option); (23, 0) is listed as returning 3 words. It **zeroes the bounce area `pdc_rtn_area` (0x80 bytes, 0x137FD4)** before the call and copies it back afterwards, whatever the status (0x137FF4-0x13800C).
- So at rev 0, where the ROM writes nothing, HP-UX still reads 0, exactly as with a rev-0xC ROM that clears the buffer.
- With a register address of 0, `pfail_poll_switch`@0x25D260 re-arms itself every 25 ticks (`Ktimeout` 0x53188, 0x25D294). It calls `pfail_power_switch_status`@0x25D700, then `getCPU25`@0x1BC40, then **`getCPU25_PCXL`@0x1BC5C = `diag 0x1720141C`** (MFCPU_T DR25 -> r28), and tests bit 0 (0x80000000).
- Bit 0 = 0 means "switch off". Depending on `power_off_action`@0x44432C, HP-UX then TOCs itself (writes 5 to `processor_hpa`+0x30 at 0x25D2B8), calls `turn_off_power`, or syncs and shuts down (0x25D2A0-0x25D344). `sysconf`@0xADF70 and `turn_off_power`@0x25D690 also read it.

**Linux:**
- `pdc_soft_power_info` (L `arch/parisc/kernel/firmware.c:1142-1155`) reads `pdc_result[0]` when the call returns OK, and `pdc_result` is *not* cleared first.
- At rev 0 that is the first word of whichever PDC call ran last. `power_init` is an `arch_initcall` (L `drivers/parisc/power.c:197-249`) that runs after `parisc_init`'s inventory and PDC_COPROC calls.
- So `soft_power_reg` can be any value. If it is not 0 or -1, Linux prints "Soft power switch at 0x... enabled".
- `kpowerswd` then does `gsc_readl(soft_power_reg) & 1` once a second (L `power.c:115-136`). An unmapped address gives a bus-error HPMC. A RAM word with bit 31 = 0 counts as "button pressed", and after 2 s Linux sends SIGINT to init (`kill_cad_pid`, L `power.c:83-98`).
- At rev != 0, `soft_power_reg` = 0: "Gecko-style soft power switch enabled", and Linux polls `__getDIAG(25) & 0x80000000` (MFCPU_T DR25 = 0x1720141C) once a second (L `power.c:61-75, 145`). The comment there names the 715 as a Gecko-style machine.

**Impact on cpu.md:**
- sec. 5.1 DR25 bit 0 is not "power good, read by nobody". Both OSes poll it as the **soft-power button (1 = not pressed)** through MFCPU_T, at 4 Hz (HP-UX) and 1 Hz (Linux). It must read 1 at reset, and is worth wiring to an OSD "soft power off" input: holding it at 0 for at least 2 polls gives a clean shutdown in both OSes.
- The Q3 text "OSes may poll DR25 bit 0" should read: "HP-UX always polls; Linux polls at rev != 0 and reads a stale pointer at rev 0".

### 1.5 Linux

- `pdc_model_versions` is called once (L `arch/parisc/kernel/processor.c:251-256`). Linux only prints the result ("vers %08lx"), feeds it to `add_device_randomness`, and echoes it in the debug dump (L `kernel/drivers.c:937`).
- The CPU type comes from HVERSION alone (0x600-0x61F -> pcxl, L `kernel/hardware.c:1303`), and the name "PA7100LC (PCX-L)" comes from the table that follows it.
- `setup.c`, `cache.c` and `processor.c` contain no revision-dependent code.
- The only revision effect is the PDC_SOFT_POWER behaviour of s.1.4.

### 1.6 Options and recommendation

| Option | ROM | HP-UX 10.20 | Linux | Faithfulness |
|---|---|---|---|---|
| **A** DR0 = 0, unpatched ROM (current plan) | skips 0x4108D | software gateway (trap 7 per syscall); Gecko soft-power poll | **stale soft-power pointer: unsafe** | versions 0, MIOC bit 14 cleared, SOFT_POWER inert |
| **B** DR0 = **0xC**, patch 1 word: ROM offset 0xB810 0x86802012 (`cmpib,=,n 0,r20,0xf000b820`) -> **0xE8000012** (`b,l,n 0xf000b820,r0`, encoding checked with `hppa-linux-gnu-objdump`) | identical flow to rev 0 at that point (ret0 = DR0 there in both cases); `set_dr0` writes DUAL_DIS = 00, stored with no effect | native gateway; Gecko poll | Gecko poll | **identical to a real 715/64 for both OSes** |
| **C** DR0 = 0, patch 2 words: F0014E00 `extrw,u r1,5,6,r1` -> `ldi 12,r1` (0x34010018); F0013B0C `cmpb,= r21,r20,...` -> `nop` (0x08000240) | as A | as B | as B | MIOC bit 14 still cleared (system-side only) |
| **D** report any value >= 0xC | dual-issue test runs | as B | as B | needs 0x4108D passed or patched anyway |

**Recommendation: B.** It gives the OSes exactly what a real 715/64 gives (revision 0xC, real SOFT_POWER behaviour, MIOC init), at the cost of one ROM word and a `docs/STUBS.md` entry. If the user rules out every ROM patch, option A is acceptable for HP-UX 10.20 only, and Linux needs its power driver disabled (e.g. `CONFIG_` or a module blacklist). No other specific revision value is needed: HP-UX's only threshold is 0xC, the ROM's are 0, 1 and > 10. A BOOT_ADMIN "information" display shows whatever DR0 holds.

**Impact on cpu.md:** sec. 0 "Issue" row, sec. 5.1 DR0 reset value (0x00000200 -> 0x30000200 for rev 0xC), sec. 5.6, sec. 8.4 Q3, P-008; a new STUBS entry for the ROM word. With option B, the "DR0 reports revision 0" sentence in CLAUDE.md "Decisions" changes too.

---

## 2. Q4 -- hardware walker and CR28

### 2.1 Set-up and vector patching (walker configuration)

1. `set_machine_parameters`@0x179488: with 8 combined BTLB slots, sets `cpu_is_a_PCXL`, `cpu_has_hw_tlb_assist`, `cpu_has_shadow_registers` (0x179658-0x179664). If PDC_TLB info (0x179680) returns OK with min or max != 0, it sets **`cpu_updates_cr28_on_dtlb_miss` = 1 and `cpu_updates_cr28_on_itlb_miss` = 0** (0x1796B0-0x1796B8) for every CPU type. `force_PCXT_off` clears all three.
2. `realmain`@0x159ECC -> `patch_PA89_iva_for_HV_options`@0x18EF08:
   - writes **0x038008A1 = `mfctl cr28,r1`** over `dtlb_mfcr28_patch`@0x181EC (0x18EF40-0x18EF58), because the DTLB flag is set;
   - leaves `itlb_mfcr28_patch`@0x180CC unpatched, because the ITLB flag is 0;
   - calls `do_PCXT_UP_tlb_handling`@0x18F028 (UP), which retargets every PA89 vector's `bl` to the `*_PCXT` handlers, and `dtlb_bl_patch_89`@0x181F8 to **`dtlb_got_next_ptr_PCXT`**@0x1AB50 (0x18F108-0x18F114).
   PCX-L therefore uses the PA-7100 ("PCXT") handler family.
3. `realmain`@0x159F98 installs `PA89_iva`. `realmain`@0x159FAC then calls `enable_hw_tlb_miss`@0x1FF0E0, which makes PDC_TLB(1, base = `htbl`, size = `nhtbl`<<4, **state 5**) (0x1FF120) and panics on failure (0x1FF16C).
4. ROM `pdc_tlb_setup`@F0015248 turns state 5 into **DR25 U = 1, N = 0, I = 0, D = 0**, i.e. **both walkers on** (F0015318-F0015380), with DR24 = base | 0xE0. The shadow copy goes to page zero 0xE4.

### 2.2 The handlers, per trap

| Trap | Vector -> handler | What it reads on entry | Uses CR28? | What it assumes |
|---|---|---|---|---|
| **15** DTLB miss | `$i_dtlb_miss_89`@0x181E0: `mfctl isr,r8; mfctl ior,r9; depw,z r8,26,16,r17;` **`mfctl cr28,r1`**`; extrw,u r9,14,15,r24; depw r24,15,15,r8; b,l dtlb_got_next_ptr_PCXT; depwi 1,0,1,r8` | ISR, IOR, **CR28** | **yes, mandatory** | `dtlb_got_next_ptr_PCXT`@0x1AB50: **CR28 = 0 -> page fault** (`$pre_dpageflt_PCXT`@0x1B894). Otherwise it loads word0 at CR28 (real mode) and compares it with {V = 1, offset[0:14], space}. On a match (`$dloop_PCXT`@0x1AB10): `idtlba` word2, `idtlbp` word1 with SR1 = ISR, sets word1 bits 0, 1 and 31 (`make_nop_if_split_TLB_2`@0x1AB34), stores word1 back, `rfi,r`. On a mismatch it follows word3 (`$d_target_miss_PCXT`@0x1AB4C). **It never recomputes the hash**, so CR28 must be a real address of a PDIR entry, or 0 |
| **6** ITLB miss | `$i_itlb_miss_89`@0x180C0 -> `itlbmss_PCXT`@0x1A9C0 | IIASQ/IIAOQ front (`mfctl pcsq/pcoq`) | no | Recomputes `htbl + ((vpn ^ space<<5) & mask) << 4` (`pdir_mask_patch_T`/`pdir_base_patch_T`). `itlbmss_fault_check_PCXT` is NOPed on PCX-L (s.1.2). `itlb_got_next_ptr_PCXT`@0x1AA14 exists but is never patched in |
| **17** non-access DTLB miss | `$i_nadtlb_miss_89`@0x18220 -> `dnatlbmss_PCXT`@0x1AB60 | ISR, IOR | no | Recomputes the hash. On a match (`$dnaloop_PCXT`@0x1AB70) it inserts **without** setting reference bits. If word1 bit 0 or 1 is clear it sets T (bit 2); if bit 31 is clear it clears AR bit 6, and sets AR = 0x73 when bit 5 is set. No PDIR write-back. Slow path `$pre_dnapageflt_PCXT`@0x1B958 (PROBE emulation, fault) uses **TR4 as scratch** (`mtctl r22,tr4`, `mtctl r16,tr4`) in real mode |
| **16** non-access ITLB miss | `$i_naitlb_miss_89`@0x18200 -> `inatlbmss_PCXT`@0x1AA80 | ISR, IOR | no | never raised on PCX-L (FIC -> 17, ERS `1036`) |
| 20 dirty, 21 T-bit, 7 imem prot | `dirupd_PCXT`@0x1ABE0, `tbitmss_PCXT`@0x1ADC0, `imem_protection_tlb_miss_PCXT`@0x1AC60 | ISR/IOR or IIA | no | recompute the hash (not walker traps) |
| shadow IVA (FP emulation) | `$i_dtlb_miss_sh`@0x191E0, `$i_nadtlb_miss_sh`@0x19220 | -- | no | abort the emulated access and restore IVA from TR7 |

All handlers use only the shadowed GRs (r1, r8, r9, r16, r17, r24, r25) plus SR1, and return with `rfi,r` (R06 s.3.2). None reads CR24-CR27 or CR29-CR31 except TR0 (CR24, the per-CPU pointer) in the slow paths. The walker must never write any TR other than CR28.

### 2.3 Is TR4 (= CR28) ever live when a walk can happen?

`mtctl ...,tr4` appears 109 times in 106 functions or labels: every vector stub, `thandler` entry and `$swap_shadows` user, the alignment/protection fast paths (`rfi_alignment_check_end_5`@0x21298, `fast_prot_*`) and the FP-emulation helpers. They all run in real mode with interruptions off, so no TLB lookup can happen (`thandler`@0x2091EC restores r22 from TR4 at 0x2092E8, before translation is re-enabled).

The only functions that write TR4 *and* turn translation on are `fstd_dte`, `fldd_dte`, `fstw_dte`, `fldw_dte` and `fstq_dte`. Each one **copies TR4 into r29 before `ssm 2` and writes it back after `rsm 2`** (e.g. `fldw_dte`@0x223D4-0x223E4, `fstd_dte`@0x22044-0x22058, `fldd_dte`@0x2213C-0x22150), with IVA switched to `shadow_iva`. HP-UX therefore expects any data TLB miss to clobber CR28, which is exactly what the hardware walker does, and it protects itself. Writing CR28 on failed walks of any kind (6, 15, 17) is safe for HP-UX. Writing it on successful walks would also be tolerated, but there is no reason to.

### 2.4 Linux and CR28

- Linux never calls PDC_TLB, so the ROM leaves DR25 I = D = 1 (selftest2 F000B7A0-F000B7B4 sets bits 28/31 from the 0xE4 shadow).
- But Linux 5.15 can keep a **live** value in CR28: with `CONFIG_TLB_PTLOCK` (SMP only, default n; L `arch/parisc/Kconfig:314-317`), `switch_mm` stores the physical address of the page-table lock there (L `include/asm/mmu_context.h:54-58`), and the TLB handlers read it (`get_ptl`, L `kernel/entry.S:38-40, 434-470`).
- On a UP machine those reads are patched to NOPs (`ALT_COND_NO_SMP`).
- Rule: **a TLB-miss trap with the walker disabled must leave CR28 untouched**. This is the ERS behaviour too: "If they are not enabled, PA7100LC will take TLB miss traps without first activating the hardware handler" (ERS `1771-1772`).

### 2.5 What our walker must write -- exact rules

DR25 as HP-UX sets it: U = 1, N = 0. Here A is the hashed entry address (DR24[0:19] | hash & mask): word0 or word4 of a 32-byte line.

| Trap | Walk performed when | CR28 on failure | Needed by |
|---|---|---|---|
| **15** | DR25.D = 0, every data *access* miss: loads, stores, LDCW/LDCWS, STBY, FLDx/FSTx incl. I/O-space addresses that miss, LDWAX excluded (absolute) | !(V and R): **A**. Tag mismatch with V = R = 1 and U = 1: N = 0 -> the **contents** of word3 (A at word0) or word7 (A at word4); N = 1 -> word3. U = 0: **A**. Every trap 15 raised while DR25.D = 0 must carry a CR28 from this walk; HP-UX does not recompute. | **HP-UX (mandatory)**, ROM 0x41095 |
| **6** | DR25.I = 0, fetch miss | same table | ROM 0x41095 (incl. ITLB); HP-UX ignores it |
| **17** | DR25.D = 0, LPA, PROBE*, FDC, PDC, FIC miss | same table (cpu.md default). Not writing it is equally safe for HP-UX. | nobody; keep for one uniform walker |
| **16** | -- | -- (never raised) | -- |
| any | walker disabled for that side | **CR28 unchanged** | Linux (TLB_PTLOCK), ERS |

Also:
- On success (insert, then re-translate), CR28 is unchanged.
- The walker never writes the PDIR. HP-UX sets R (bit 0) together with bits 1 and 31 in every reference handler (`make_nop_if_split_TLB_1..5`@0x1A9F8, 0x1AB34, 0x1AC1C, 0x1ACFC, 0x1ADF8). So an entry the walker accepts (R = 1) would get the same word1 from HP-UX's non-access handler, and walking non-access misses changes nothing for HP-UX.
- The PDIR is read with real addresses. HP-UX writes PDIR entries through kernel space 0, whose D-cache space hash is the identity, so the walker's reads through the D-cache are coherent with those writes.

**Impact on cpu.md:**
- Sec. 2.6 step 5 and the CR28 table: add "only when the walk was performed (DR25 I/D = 0); otherwise CR28 is unchanged". Add "every trap 15 with DR25.D = 0 carries CR28". Add "N = 0 is the mode HP-UX uses: odd entries take the next pointer from word7".
- Sec. 2.6 last paragraph: "HP-UX does not rely on it" applies to traps 6 and 17, not to trap 15.
- Q4 is answered: written for 17 (harmless); default kept.
- Sec. 2.5 step 1: list the access types that walk (above).

---

## 3. Q7/Q8 -- DIAG and implementation-specific instructions

### 3.1 Method

`implscan.py` decodes every word in the code subspaces ($GATEWAY$, $MILLICODE$, $TLB$, $TRAP$, $ASSEMBLY$, $CODE$; $LIT$ and the unwind tables are data). For each word it checks:

- major 05 (DIAG);
- major 01 with bits 18:25 = 0x10/0x11/0x50/0x51 (IITLBPF/IITLBAF/IDTLBPF/IDTLBAF, either the QEMU form or the "HP-UX 9" b = 9/s = 1 form);
- the MAX-1 ext6 set of major 02;
- major 03 ext4 3/B (PCX-L multi-endian, = PA 2.0 LDD/STD);
- 04 (SPOP);
- 0C with uid >= 2;
- 09/0B with coprocessor uid;
- 06 with ra = 0 (FMPYCFXT);
- FTEST with a clip condition;
- XMPYU, LCI, PROBEI, `mfctl,w`;
- every undefined or PA 2.0 major.

`datascan.py` checks $LIT$/$DATA$ for DIAG, fast-insert or MAX-1 templates. It found only data tables (CRC, audio, VxFS, LAN debug masks). There are no `ldil` constants that could build such words; the only 0x04xxxxxx compare (`trap`@0xCF384) decodes the faulting FIC's IIR.

### 3.2 Every DIAG in HP-UX 10.20

PCX-L decode per ERS s.8.3.9 (ERS `3249-3285`), with X bits ignored:

| Address | Word | Function | PCX-T meaning | **On PCX-L** | Reached on PCX-L? |
|---|---|---|---|---|---|
| 0x1BC08, 0x1BC0C | 0x171A1600 ×2 | `$ehtm_ll_cache_align` (in `enable_hw_tlb_miss_ll`@0x1BB94) | MTCPU r26->DR24 (paired) | code B0: **undefined** | **no**: `enable_hw_tlb_miss_ll` is referenced only by its unwind entry (0x39E1E8) |
| 0x1BC18, 0x1BC1C | 0x17391600 ×2 | same | MTCPU r25->DR25 | undefined | no |
| **0x1BC5C** | **0x1720141C** | **`getCPU25_PCXL`** | -- | **MFCPU_T DR25 -> r28** | **yes: `pfail_poll_switch` every 25 ticks, `sysconf`, `turn_off_power` (s.1.4)** |
| 0x1BCC8, 0x1BCCC | 0x141C1A00 ×2 | `getCPU0` (PCX-T branch) | MFCPU DR0->r28 | **SHDW_GR** (silently overwrites GR1/8/9/16/17/24/25) | no: `getCPU0` -> `getCPU0_PCXL` when `cpu_is_a_PCXL`, and all `getCPU0` callers (`realmain`@0x158F3C/54, 0x159004/1C, `stalloff`, `hintsoff`, `stallon`, `hintson`) are PCX-T-gated (s.1.2) |
| 0x1BD28 | 0x141C0600 | `getCPU0_PCXL` | -- | MFCPU_C DR0 -> r28 | no (callers above) |
| 0x1BDA8, 0x1BDAC | 0x14000E00, 0x141C0600 | `getCPU0_PCXL2` | (PCX-L2) | **WI1** (r0), MFCPU_C | no (`cpu_is_a_PCXL2` only) |
| 0x1BE48, 0x1BE4C | 0x141A1600 ×2 | `setCPU0` (PCX-T) | MTCPU r26->DR0 | undefined | no |
| 0x1BEA8 | 0x141A0240 | `setCPU0_PCXL` | -- | MTCPU r26 -> DR0 | no |
| 0x1BF28, 0x1BF2C | 0x14000E00, 0x141A0240 | `setCPU0_PCXL2` | (PCX-L2) | WI1, MTCPU | no |
| 0x217B8, 0x217BC | 0x16000DA9 ×2 | `patch_exception_trap` | PCX-T cache erratum | code 6D: undefined | no: the routine's first word `b,l continue_exception_trap` is NOPed only for PCX-T rev < 9 with HW assist (`realmain`@0x158F68-0x158F84) |
| 0x217C8, 0x217CC | 0x16000D09 ×2 | `doeven` | same | code 68: undefined | no |
| 0xCFE04 | 0x14C00007 | `disable_TCU_lookaside` | cputype 0x81 | undefined | no (`realmain`@0x159268: cputype 0x81 only) |
| 0xCFE18 | 0x14C72200 | same | | code 10: undefined | no |
| (0x3C490, 0x3C49C, 0x3C4B0) | 0x16000000, 0x14000000, 0x15000000 | `S$402$vx_ivalidate` | -- | -- | data in $LIT$ |

The ROM's PCX-L DIAG set is already in cpu.md sec. 4.3.6/5.1 (HW s.8).

### 3.3 The other PCX-L specifics -- none reachable

| Feature | HP-UX 10.20 | Linux 5.15 |
|---|---|---|
| IITLBAF/IITLBPF/IDTLBAF/IDTLBPF | **0** words in code, 0 templates in data | none |
| MAX-1 (HADD/HSUB/HAVG/HSHxADD) | **0** (the 4 `datascan` hits are the `tform` table) | none |
| FMPYCFXT, clip-test FTEST | 0 | none |
| Multi-endian LDWC/LDWB/LDWL/STWx (03 ext 3/B) | 117 words, **all PA 2.0 LDD/STD**: `*_PCXU*`, `*2_0`, the PA 2.0 `pdir_*_patch_0xx` handlers at 0x1C000+, `read_64`/`write_64`/`init_io_pdir_entry`/`make_dvi_addr` (I/O-PDIR machines, no direct callers), and `get/set_protid_registers`@0x208508/0x208534 (callers gated by `cpu_arch_is_2_0`, e.g. `insqWprot`@0x97D88, `checkprotid`@0x994B8). On a PCX-L they would decode as multi-endian word ops, not trap | none |
| SPOP (04) | 0 | none |
| COPR uid >= 2 | `pa_arm`@0xD1108 / `pa_disarm`@0xD1114 = `copr,3,...` (uid **3**, not the architected uid-2 performance monitor). Unreferenced except by unwind entries. On PCX-L: trap 22 | none |
| XMPYU | `use_xmpyu`@0x17010 (millicode multiply), PA 1.1 standard | -- |
| LCI | `init_io_pdir_entry`@0x46130, `load_io_pdir_entry`@0x46178, `make_dvi_addr`@0xD11C8 (I/O PDIR, not on a 715) | -- |
| `mfctl,w` (bit 17) | `pa2_0_call_prep`, `ei_2_0_save_1`, `trapeeze`, `int_save_crs2_0`, `thand_save_cr2_0`, `movetoctl_cr11_fixup`, `mfctlend_cr11_fixup` (9 sites) | `head.S:253` PA 1.1/2.0 test (R06 s.2.1) |
| ENSPEC | `processor_init`@0x66004 (arch_rev 4 and FPU); the ROM only checks key 0x72 | -- |

### 3.4 PA 2.0 and other undefined opcodes in PA 1.1 paths

1. **Nullified PA 2.0 doubleword ops.** Generic code chooses between a word and a doubleword access in one of two forms:
   - `extrw,u,<> X,27,1,r0 ; <PA 1.1 op> ; extrw,u,= X,27,1,r0 ; <PA 2.0 op>`, testing bit 27 of the per-CPU flags word at TR0+0xD0;
   - `or,= flag,r0,r0 ; <PA 2.0 op>`, testing a "wide" flag register (e.g. `restore_ss_trap_system`@0x21008, `ff_spl7`@0x209AFC).

   Both flags are 0 on PA 1.1, so the PA 2.0 op is always **nullified**. Sites with majors 0x14 (LDD) and 0x1C (STD), which are undefined on PCX-L:
   - `sh_restore_grs`@0x193FC
   - `restore_ss_trap_system`@0x2100C
   - `fpusaved`@0x219F4/0x21A1C
   - `fstw_dte`@0x222B8, `fldw_dte`@0x223A4, `fstq_dte`@0x2252C
   - `int_fp_restore_done`@0x4899C-0x489D8
   - `fuwsr4-6`, `fubsr4-6`, `suwsr4-6`, `subsr4-6` (0xCFFE4-0xD04A8)
   - `t_bttcreate`@0x2094A4
   - `ff_spl7`, `ff_got_fault_type`, `$ff_user_ipgft` (0x209B00-0x209C74)

   The kernel runs them all the time; a decoder that raised trap 8 before checking nullification would break HP-UX at once.
2. **FSTQS (major 0x0F, the Venom quad store)** appears in `bz_quads`@0x44C14/0x44D94, `b_quad_loop`@0x450D4/0x4582C/0x47574 and `pgcopy_quads`@0x47BC4-0x47C1C. These are the `*_fp_method2` routines.
   - `optimize_bcopy`@0x16BA00 tries them only if an FPU is present, arch_rev = 4 **and PDC_MODEL `current_key` bit 31 is set** (0x16BFC8-0x16BFE8, `bb,<,n r21,31`).
   - The 715's ROM returns 0x72, so they are never used. That is consistent with ERS s.2.2.12: Venom/graphics-flush operations take an illegal-instruction trap on PCX-L.
   - If an EEPROM or PDC ever reported a key with bit 0x01 set, HP-UX would trap 8 at boot.
3. Everything else in `implscan`'s `pa20maj` class (1151 words) is in `*_2_0`/`*PCXU*` functions, the PA 2.0 IVA (0x1C000) or the I/O-PDIR code.

### 3.5 Linux

| Site | Words | On pcxl |
|---|---|---|
| `disable_sr_hashing_asm` `srdis_pcxl` (L `arch/parisc/kernel/pacache.S:1314-1321`), from `disable_sr_hashing` (L `kernel/cache.c:264-299`) | 0x141C0600 MFCPU_C DR0->r28; `depwi 0,28,2` (clears DHASH_EN 27, IHASH_EN 28); 0x141C0240 MTCPU r28->DR0; run in real mode | **yes, once at boot** |
| same, `srdis_pcxs` (`pacache.S:1302-1311`) | 0x141C1A00 ×2, 0x141C1600 ×2 (PCX-S/T forms) | no |
| same, `srdis_pa20` (`pacache.S:1323-1329`) | 0x144008BC, 0x145C1840 | no |
| `kpowerswd` (L `drivers/parisc/power.c:61-75, 145`) | 0x1720141C MFCPU_T DR25 | **yes at CPU rev != 0** (1 Hz) |
| `perf_asm.S` (MTDIAG/MFDIAG/STDIAG/SFDIAG) | PCX-U/W | 64-bit only (L `kernel/Makefile:33`) |

The shadow-register, HPMC and TLB paths (`entry.S`, `hpmc.S`, `head.S`) contain no DIAG. Linux uses no fast inserts, MAX-1 or multi-endian ops.

### 3.6 Recommendations and spec differences

- **Q7:** keep **trap 8** for undefined DIAG encodings. No reachable undefined DIAG exists in either OS on a correctly identified PCX-L. Trap 8 turns HP-UX's PCX-T misidentification into a visible failure at `setCPU0`; QEMU's NOP hides it. The PCX-T read 0x141C1A00 is *defined* on PCX-L (SHDW_GR), so the simulator should also log any DIAG executed outside the ROM range.
- **Q8 (10.20):** cpu.md sec. 4 already decodes everything HP-UX 10.20 and Linux execute on a PCX-L: MFCPU_T/MFCPU_C/MTCPU, PA 1.1 forms, `mfctl,w`. Its encodings agree with what the kernels use (MFCPU_T code A0 with t at 27:31; MTCPU code 12 with x at 11:15). Nothing is decoded differently.
- **Q8 (other versions):**
  - HP-UX 9.05 is not on this machine. QEMU's `insns.decode:167` "HP-UX 9 encoding" shows that 9.x uses the fast inserts, so keep IITLBAF/PF and IDTLBAF/PF with b/s ignored as specified.
  - HP-UX 11i v1 (March 2003 OE) install media are in `~/Downloads` as zips. Extracting `/stand/vmunix` from the depot and re-running `implscan.py`/`datascan.py` is a separate task; it was not done here (read-only scope, disk space).
- **Impact on cpu.md:**
  - Sec. 4.3.6 note: replace "HP-UX 10.20 none on PCX-L (R06 s.3.1)" with "HP-UX 10.20: MFCPU_T DR25 (0x1720141C) at 4 Hz from the soft-power poll".
  - Sec. 4.1: add an explicit rule and test "undefined/PA 2.0 opcodes in a nullified slot never trap (HP-UX relies on it at ~30 sites)".
  - Sec. 4.2 0F row: cite the FSTQS gating by PDC `current_key` bit 31.
  - Sec. 4.3.2 fast inserts and sec. 4.3.3 MAX-1: "not used by HP-UX 10.20 or Linux; kept for HP-UX 9 and user code".

---

## 4. Other PCX-L dependencies in HP-UX 10.20 not covered by cpu.md

| # | Finding | Evidence | Impact on cpu.md |
|---|---|---|---|
| 1 | For PCX-L, HP-UX overwrites PDC_CACHE `it_size` and `dt_size` with **64** and sets `dt_conf` bit 15 (4 KB pages) in `cache_tlb_parms`@0x401ED0 | `realmain`@0x158EF8-0x158F1C | none (64 entries already); the page bit is set in the 715's 0xD2000 anyway |
| 2 | **Unified TLB assumed** from PDC_CACHE `tc_sh`. If both I and D `sh` = 0, `optimize_split_TLB`@0x1FF598 NOPs the "set bit 31" stores in the reference handlers. With HP's 0xD2000 (sh = 3) a D-side insert must serve fetches too, and the non-access handler's AR rewrite depends on bit 31 | `monarch_init`@0x172430-0x172458; list at 0x4037A0 | sec. 2.2: state that an IDTLBx insert must satisfy instruction fetches (one shared TLB, as specified) |
| 3 | **CR16 used as a benchmark clock at boot**: `optimize_bcopy`@0x16BA00 times the gr, fp1, prefetch_sl (and gated fp2/pcxu) copy methods with `mfctl itmr` around `fcacheall` + 8 KB `bcopy` and patches in the fastest. Relative timing only, so our CR16 rate and core speed may pick a different (still valid) method | 0x16BEE4-0x16C0F4 | none; note that the prefetch_sl method uses `fldd,m`/`fstd,m` indexed-modify and `,bc` hints (cc field ignored) |
| 4 | CR16 rate comes only from MEM_10MSEC (R06 s.3.6); no hard-coded PCX-L clock was found | `realmain`@0x158D48 | none |
| 5 | `$swap_shadows`@0x1BA28 reads both IIAOQ/IIASQ elements by `mfctl pcoq; mtctl r0,pcoq; mfctl pcoq` (the queue advances on write), then `rfi,r` to `$jumpdest` with IPSW = 0 to swap shadows back into the GRs | 0x1BA3C-0x1BAF0 | covered by "exact CR18 queue writes" (sec. 3.4); add this sequence to the `sys` suite |
| 6 | FP emulation brackets virtual accesses with `ssm 2`/`rsm 2`, switches IVA to `shadow_iva`@0x19000 and saves TR4 (s.2.3) | `fldw_dte`@0x22394 etc. | none beyond s.2.5 |
| 7 | Endianness: PDC_PSW(21, 2, 0) at `processor_init`@0x65F78 keeps the default big-endian; no PSW.E use found | -- | P-011 stays valid for HP-UX |
| 8 | LDCW: only the cache-hint patching already in R06 s.3.2 / cpu.md sec. 5.7 | `patch_ldcw_instructions_with_cache_hint`@0x18E938 | none |
| 9 | L1 I-cache: no use beyond FIC/FICE coherence | -- | none |
| 10 | Shadow registers: the PA89 IVA is installed because `cpu_has_shadow_registers` is set (`realmain`@0x159F24-0x159F98) | -- | none (sec. 3.2) |
| 11 | PDC key: ENSPEC/`current_key` = 0x72 keeps FSTQS off (s.3.4); `pot_key & 7` = 2 selects `set_fpu_type_config(10)` | `processor_init`@0x66044-0x66058 | sec. 5.6: list the PDC key as part of the CPU identity contract |

---

## 5. Corrections to earlier documents

- **R06 s.0 item 8, s.2.2 row 23, s.3.1, s.3.7:** "HP-UX 10.20 executes no DIAG on a PCX-L unless PDC_SOFT_POWER reports a Gecko switch ... make PDC_SOFT_POWER fail". HP's PDC 1.6 never fails PDC_SOFT_POWER (s.1.4): at any revision HP-UX ends up polling DR25 via `getCPU25_PCXL` at 4 Hz, and Linux does so at rev != 0. Making it fail needs a ROM patch. With an unpatched ROM, MFCPU_T DR25 is mandatory.
- **FIRMWARE.md row 23:** "PCR |= 3 when DR25 bit 31 is 0" should read DR25 **bit 0** (`extrw,u r21,0,1` at F0013B78, PA bit numbering).
- **cpu.md sec. 8.4 Q3:** see s.1.4 and s.1.6 (the soft-power consequences differ between the OSes; revision 0xC recommended).
- **cpu.md sec. 2.6:** "HP-UX does not rely on [CR28 on ITLB misses]" is right; HP-UX *does* rely on CR28 for trap 15 (s.2.5).

## 6. Suggested test-bench items arising from this review

1. DR25 bit 0 reads 1 through MFCPU_T (0x1720141C) from PL 0. Optional OSD soft-power input.
2. Nullified 0x14/0x1C/0x0F/03-ext-3 words after `extrw,u,=`/`extrw,u,<>` never trap; un-nullified they trap 8 (or execute as LDWC etc. for 03 ext 3 with z != 01).
3. Walker CR28 matrix (V/R/tag × U/N × even/odd entry) for traps 15 and 6, plus "walker disabled -> CR28 unchanged" for 6, 15 and 17.
4. Gateway: native `B,GATE` through an AR type-4 page at PL 3, and the trap-7 emulation sequence of s.1.3 (IIAOQ rewrite + RFIR to PL 0).
5. `$swap_shadows` queue sequence (s.4 item 5).
6. If option B is chosen: boot the patched ROM with DR0 rev 0xC through selftest2, and confirm that BOOT_ADMIN "information" shows revision 0xC.
