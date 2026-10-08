# CPU design specification -- PA-7100LC (PCX-L) for the HP 9000/715 core

Status: specification, 2026-10-07, with review 07 (`docs/review/07-hpux-cpu-specifics.md`)
folded in the same day. The RTL in `rtl/cpu/` is built from it: `pa_cpu` is
the pipelined core (sections 6.1-6.8; the fit log is `cpu-timing.md`),
`pa_core_seq` the sequential reference it is co-simulated against. Every requirement names the document that imposes
it. Where the architecture leaves a choice, the choice is stated as **ours**
and, where it is a simplification, it has a `docs/STUBS.md` entry.

**How to cite (used throughout)**

| Prefix | Document |
|---|---|
| ACD p.x-y | PA-RISC 1.1 Architecture and Instruction Set Reference Manual, 3rd ed. (`docs/reference/txt/Pa11_acd.txt`), manual page numbers |
| ERS s.n | PA7100LC ERS (`PCXL_ers.txt`; reversed page order -- read the forward copy `keep/doc-review-text/pcxl_fwd.txt` in the session scratchpad), section numbers |
| L2ERS | PA7300LC (PCX-L2) ERS (`Pcxl2_ers.txt`), used for what the 7100LC ERS copy lacks (its appendix: MAX-1, fast inserts, multi-endian loads) |
| PA2 p.x-y | PA-RISC 2.0 manual (`parisc2.0.txt`), MAX-1 definitions only |
| BOOT s.n / HW s.n / FW s.n | `docs/reference/rom/BOOTFLOW.md`, `HARDWARE.md`, `FIRMWARE.md` |
| R06 s.n | `docs/review/06-os-hpux-linux.md` |
| Q file:line | QEMU 11.1.1 `~/src/qemu-11.1.1/target/hppa/` |
| L file:line | Linux 5.15, `~/repos/Linux-Kernel_MiSTer/arch/parisc/` |

Bit numbering is PA-RISC big-endian (bit 0 = MSB of a 32-bit word) unless a
field is written `[n:m]` in Verilog order, which is said explicitly.

---

## 0. Summary of the decisions

| Topic | Decision | Why |
|---|---|---|
| Architecture | PA-RISC 1.1 3rd ed., Level 1 (16-bit space IDs, 48-bit VA), + MAX-1 halfword ops (32-bit forms), + PCX-L implementation specifics (diagnose, fast TLB inserts, FMPYCFXT, clip-test FTEST, multi-endian word ops) | user decision; ERS s.1.3, s.2 |
| Issue | single issue, in order; DR0 revision field = **2** (`pa_cpu` parameter `CPU_REVISION`; user's decision 2026-10-07: a value in 1..0xB) | at rev != 0 the ROM runs the cycle-exact dual-issue test 0x4108D (BOOT s.4.2), which a single-issue core fails, so the system patches the one ROM word of review 07 s.1.6 when loading the image until dual issue exists (STUBS S-011, P-008). Rev != 0 gives Linux a valid PDC_SOFT_POWER answer; rev < 0xC keeps HP-UX 10.20 on its trap-7 gateway path (review 07 s.1.3) -- Q3 |
| Pipeline | 5 stages F-D-E-M-W, precise commit in W, replay from W for misses | sec. 6 |
| Clock | **64 MHz** (the real 715/64's clock); the pipelined core without caches fits at 72.5 MHz (`cpu-timing.md`) | sec. 6.9 |
| L2 caches | **real 128 KB I + 128 KB D**, direct-mapped, 32-byte lines, VIPT (index VA[15:26] with the PCX-L space hash, tag = 20-bit RPN), write-back, write-allocate, per-word parity, full diagnose access; ~244 M10K | the ROM's cache/TLB/memory tests and code-in-cache need exactly this (BOOT s.4.3-4.5, HW s.8.3) |
| L1 I-cache | **real** 1 KB (128 x 8 bytes) on-chip I-cache in front of L2-I, with DR27-29/RI1/WI1 | test 0x42094 checks that an L1 hit overrides L2 on a real fetch; 0x42097 that FIC invalidates both |
| TLB | 64-entry fully associative unified CAM + 8 block entries, PCX-L lock/replacement rules, DR8 diagnose control, 1-entry I-lookaside (I-LAB) | ERS s.6; tests 0x41091-0x41096 |
| HW TLB walker | **implemented** exactly per ERS s.6.7, I and D side | the real PDC implements PDC_TLB (FW s.2.2 #19), so HP-UX enables the walker and then depends on it (R06 s.3.3) |
| FPU | PCX-L model: every trap-enabled IEEE exception, NaN operand, denormal operand or tiny result becomes an **unimplemented exception** with a delayed trap, so the hardware never handles denormals/NaNs; multi-cycle add/mul on 4 DSPs, iterative divide/sqrt; XMPYU on the FP multiplier | ERS s.7.3 (this is the real chip's behaviour, not a stub) |
| Coherence | none: DMA is not snooped; the OS flushes (FDC/PDC) around DMA | R06 s.3.4; ACD p.3-17 |
| Ports | cacheable line port (to the MIOC/SDRAM block), uncached port (I/O space, U-bit pages, I/O-space instruction fetch), EIR/TOC/HPMC/LPMC inputs, debug taps | sec. 6.8 |
| CR16 | counts at exactly the strap clock (64/80/100 MHz) from a fractional tick generator; compare matches detected by range so 2-tick steps never skip | BOOT s.5; R06 s.3.6 |
| Little-endian | PSW.E stored but without effect (stub P-011); the 9 explicit-endian word loads/stores are implemented | R06 s.0 item 8 |

Budget (sec. 6.10): integer core + TLB + walker + cache control
~**8.7k ALMs**, FPU ~**2.3k ALMs**, **~247 M10K** (almost all cache), **4 DSP**.

---

## 1. Architectural state

### 1.1 Register files

| State | Width / count | PCX-L specifics | Reset value (ours) | Source |
|---|---|---|---|---|
| GR0-GR31 | 32 x 32 | GR0 reads 0, writes discarded | GR1-31 = 0 | ACD p.2-7 |
| Shadow registers SHR0-6 | 7 x 32 | copies of **GR1, 8, 9, 16, 17, 24, 25** | 0 | ACD p.2-8; ERS s.2.2.2 |
| SR0-SR7 | 8 x **16** bits (bits 16:31) | SR[0:15] read 0 (Level 1) | 0 | ACD p.2-9 fig 2-8; ERS s.5.4 |
| IASQ front/back | 2 x 16 | -- | 0, 0 | ACD p.2-12 |
| IAOQ front/back | 2 x 32 (offset 0:29, PL 30:31) | -- | 0xF0000004, 0xF0000008 (PL 0) | ERS s.5.3.1 |
| PSW | 32 | implemented bits below | **M = 1 only** (0x00010000) | ERS s.5.3.1 |
| CR0-CR31 | see 1.3 | | | |
| FP registers fr0-fr31 | 32 x 64 | fr0L status, fr0R..fr3R = exception registers 1-7 | 0 | ACD p.6-5, p.6-23 |
| Diagnose registers | DR0, 1, 8, 24-29 | sec. 5.1 | sec. 5.1 | ERS s.8.2 |
| TOC mask | 1 bit | set at reset, on a taken TOC and by TOC_DIS; cleared by TOC_EN | **1** (masked) | ERS s.5.3.5, s.8.3.3 |
| TLB | 64 page + 8 block entries | all **locked out (and locked in) at reset** | sec. 2 | ERS s.6.3.3, s.6.5 |

**Shadow register semantics** (ACD p.4-16 step 6, p.4-17, p.5-141; ERS s.5.3.5;
R06 s.3.2):

| Event | Effect |
|---|---|
| Every interruption, **including HPMC and TOC**, whatever PSW.Q was | SHR[0..6] <- GR[1, 8, 9, 16, 17, 24, 25] as committed before the interrupted instruction |
| RFIR | GR[1, 8, 9, 16, 17, 24, 25] <- SHR[0..6], then everything RFI does; SHRs undefined after (ours: unchanged) |
| RFI | SHRs untouched |
| DIAG GR_SHDW (0x14001A40) | SHR <- GR (7 registers) |
| DIAG SHDW_GR (0x14001A00) | GR <- SHR (7 registers) -- the ROM's expected-HPMC path depends on it (BOOT s.2.4) |

QEMU captures the shadows only when PSW.Q was 1 (Q int_helper.c:133-201), which
differs from ACD step 6 and the ERS ("any trap").

### 1.2 PSW

ACD p.2-9..2-11, ERS s.5.4. "impl" = implemented as a stored bit.

| Bit | Name | PCX-L | Ours | Notes |
|---|---|---|---|---|
| 0, 1 | Y, Z | reserved (no debug SFU) | read 0 | ACD p.2-11 |
| 2:4 | rv | reserved | read 0 | |
| 5 | E | implemented (little endian) | **stored, no effect** (P-011) | set from DR0[23] on interruption; IPSW.E restored by RFI (ERS s.2.1.3) |
| 6 | S | impl | impl | MFCTL CR16 privileged when 1 |
| 7 | T | impl | impl | taken-branch trap 25 |
| 8 | H | impl | impl | higher-privilege transfer trap 23 |
| 9 | L | impl | impl | lower-privilege transfer trap 24 |
| 10 | N | impl | impl | nullify current instruction |
| 11 | X | impl | impl | disables data memory break trap 19 for one instruction |
| 12 | B | impl | impl | taken branch; GATE with B = 1 -> trap 8 |
| 13 | C | impl | impl | code translation |
| 14 | V | impl | impl | divide-step |
| 15 | M | impl | impl | HPMC mask |
| 16:23 | C/B | impl | impl | 8 digit carries |
| 24 | rv | reserved | read 0 | ERS s.5.4 (IPSW[24:26] read 0) |
| 25 | G | reserved (no debug SFU) | read 0 | |
| 26 | F | reserved (no performance monitor) | read 0 | |
| 27 | R | impl | impl | recovery counter |
| 28 | Q | impl | impl | interruption state collection; SSM/MTSM **may** set it (the ROM does, BOOT s.4.2 0x41082/0x4108B) |
| 29 | P | impl | impl | PID check |
| 30 | D | impl | impl | data translation |
| 31 | I | impl | impl | external interrupt / LPMC unmask |

IPSW (CR22) stores bits 5:23 and 27:31; the ROM checks 6:23 and 27:31 with
0x01555515/0x02AAAA0A (BOOT s.4.2 0x4108B). The system mask is bits 25:31
(SSM/RSM/MTSM, ACD p.5-143..5-145); G and F stay 0.

### 1.3 Control registers (all 32)

ACD p.2-12..2-17, ERS s.2.2.7, s.5.4. "priv" = most privileged level only;
violations raise **trap 11** (privileged register).

| CR | Name | Bits stored | Read / write semantics | Access | Reset |
|---|---|---|---|---|---|
| 0 | RCTR recovery counter | 32 | decremented by every non-nullified instruction that starts with PSW.R = 1; restored if that instruction ends in a group 1-3 interruption; trap 3 when bit 0 = 1 and R = 1 | priv | 0 |
| 1-7 | reserved | -- | read 0, writes ignored (**ours**; ACD: undefined) | priv | -- |
| 8, 9, 12, 13 | PID1-4 | bits 16:31 (15-bit PID + WD) | bits 0:15 read 0 | priv | 0 |
| 10 | CCR (+SCR) | bits 24:31 | bits 0:23 read 0 (no SFUs); all 8 CCR bits read back (ROM writes 0x55/0xAA, BOOT s.4.2 0x4108B); only bits 24:25 (CCR{0,1}) enable the FPU | priv | 0 |
| 11 | SAR | bits 27:31 | bits 0:26 read 0; MTCTL takes GR[27:31]; `mfctl,w` (bit 17 set) reads it the same way (L, R06 s.3.7) | any | 0 |
| 14 | IVA | 32 | reads back all 32 bits (ROM writes 0x55555555/0xAAAAAAAA); vector address = {IVA[0:21], vector[4:0], 00000} (ERS s.5.4: IVA[22:31] not used) | priv | 0 |
| 15 | EIEM | 32 | plain | priv | 0 |
| 16 | interval timer | counter 32 + compare 32 | MFCTL reads the **counter**; MTCTL writes the **compare**; DR1 writes the counter (sec. 5.2) | write priv; read priv if PSW.S | counter 0, compare 0 |
| 17 | IIASQ | 2 x 16 | read: front; write (Q = 0): advance queue, write back element | priv | 0 |
| 18 | IIAOQ | 2 x 32 | read: front; write (Q = 0): advance, write back (the ROM's `set_psw` relies on it, BOOT s.2.11, f0015ca0) | priv | 0 |
| 19 | IIR | 32 | written at interruption (Q = 1); MTCTL writes it (**ours**; ACD: undefined) | priv | 0 |
| 20 | ISR | 16 (bits 16:31) | bits 0:15 read 0 | priv | 0 |
| 21 | IOR | 32 | full 32-bit offset | priv | 0 |
| 22 | IPSW | as PSW | | priv | 0 |
| 23 | EIRR | 32 | MTCTL: EIRR &= ~GR (write-1-to-clear); set by IO_EIR transactions and the timer | priv | 0 |
| 24, 25 | TR0, TR1 | 32 | | priv | 0 |
| 26, 27 | TR2, TR3 | 32 | readable at any PL, writable at PL 0 (ERS s.2.2.7) | r any / w priv | 0 |
| 28 | TR4 | 32 | also written by the hardware TLB walker on a failed walk (sec. 2.6) | priv | 0 |
| 29-31 | TR5-TR7 | 32 | | priv | 0 |

Queue behaviour with Q = 1: the architecture leaves CR17/18 reads and writes
undefined; ours behave as with Q = 0. The IIA queues and IPRs are only written
by an interruption taken with PSW.Q = 1 (ACD p.2-16..2-17); they are not "continually
updated" in hardware -- nothing can observe the difference. (QEMU writes the
IIA queues even when Q = 0, Q int_helper.c:113-130.)

### 1.4 Instruction address queues and privilege

| Item | Rule | Source |
|---|---|---|
| IAOQ_Front | address + PL of the current instruction | ACD p.2-12 |
| IAOQ_Back | address + PL of the instruction that executes next | |
| Not-taken / sequential | next = Back + 4, PL of Back | ACD p.4-11 fig 4-3 |
| Taken branch | next = target (PL computed by the branch); IASQ_next = target space for BE/BLE, else IASQ_Back | |
| Branch in a delay slot | both branches take effect: I1 target executes out of line, then I2's target (fig 4-4) -- the ROM tests this (BOOT s.4.2 0x41081, 0x41082) | ACD p.4-12 |
| Link (BL, BLR, BLE, GATE) | GR[t] = IAOQ_Back + 4 (includes the PL bits); GATE deposits the GATE's own PL in GR[t]{30:31} | ACD p.5-63..5-68; ROM checks r5 = IAOQ_Back+4 (0x41082) |
| BLR target | IAOQ_Front + 8 + (GR[x] << 3) (negative index allowed) | ACD p.5-65 |
| PL lowering | BV/BE/BLE: target PL = max(current, GR[b]{30:31}) -- takes effect at the target, not the delay slot | ACD p.5-66..5-68 |
| GATE promotion | C = 1: new PL = min(current, type{1:2}) if the fetch page's AR type >= 4; C = 0: PL 0; takes effect at the target (**ours**; the delay slot keeps the old PL) | ACD p.5-63 |

---

## 2. Virtual memory

### 2.1 Address spaces and translation

| Item | PCX-L | Source |
|---|---|---|
| Level | 1: 16-bit space IDs, VPN = {space[16], offset[0:19]} = 36 bits | ERS s.1.3, s.6.1 |
| Physical | 32 bits; **I/O space = PA 0xF0000000-0xFFFFFFFF** (never cached) | ACD p.2-2 |
| Data space select | s != 0: SR[s]; s = 0: SR[4 + GR[b]{0:1}] | ACD p.3-3 fig 3-2 |
| Instruction space | IASQ; FIC/IITLBx/PITLBx use a 3-bit SR field | ACD p.5-166, p.5-172 |
| Translation on | data: PSW.D (and always for PROBE, LPA, LCI); code: PSW.C; FIC/FDC/PDC use PSW.D | ACD p.3-11, p.5-169..5-172 |
| Absolute ops | LDWAX/LDWAS/STWAS ignore PSW.D, privileged | ACD p.4-21 (trap 10 list) |

### 2.2 TLB organisation (ERS s.6.1-6.5)

**Page entry (x64)**, stored as:

| Field | Bits | Written by | Notes |
|---|---|---|---|
| VPN tag | space 16 + VPN 20 | IxTLBA | compared fully associatively (CAM, flip-flops) |
| lock-out | 1 | IxTLBA <- DR8[16] | forces a mismatch; set at reset |
| lock-in | 1 | IxTLBA <- DR8[17] | excluded from replacement unless VPN match or diagnostic insert; set at reset |
| E (valid) | 1 | IxTLBA clears, IxTLBP sets, PxTLB/PxTLBE clear | |
| used (NUR) | 1 | set on every translation hit; cleared all at once (below) | |
| RPN | 20 | IxTLBA: GR[r]{7:26} | |
| AR | 7 (type 3, PL1 2, PL2 2) | IxTLBP: GR[r]{5:11} | |
| access ID | 15 | IxTLBP: GR[r]{16:30} (rightmost 15 of {13:30}) | 0 = public page |
| T, D, B, U | 4 | IxTLBP: GR[r]{2}, {3}, {4}, {12} -- **also by IITLBP** (combined TLB, ACD p.5-168) | IxTLBA clears them (ERS s.6.1.1) |

Payload (RPN..U, 46 bits) lives in an MLAB indexed by the encoded hit; the tag,
E, lock and used bits in flip-flops.

**Block entry (x8)** (ERS s.6.1.2, s.6.3.5):

| Field | Bits | Notes |
|---|---|---|
| space | 16 | |
| VPN | 13 (offset bits 0:12) | bits 6:12 compared only where mask = 1 |
| mask | 7 (mask[6:12]) | from VA{13:19} at insert; legal: 0000000, 1000000, 1100000, ..., 1111111 = 16K..128 pages |
| TRANS | 13 (RPN 0:12) | RPN = cat(TRANS where mask/always compared, VA bits elsewhere) |
| lock-out, E | 1 + 1 | locked out at reset |
| AR, AID, T, D, B, U | as page entries | |

Example (ERS s.6.3.5): space 0x1F06, vpn 0111011001011, rpn 0001001000110,
mask 1100000: 0x76584321 -> 0x12584321; 0x77777777 -> miss. These four are test
vectors.

**Lookup:** page and block entries are searched in parallel. A double hit is
undefined (software must not create one, ERS s.6.3.5); **ours: the page entry
wins**. LPA and PROBE use block entries like page entries (ERS s.6.3.5), and
LPA must return the assembled RPN with the size mask removed (BOOT s.4.4
0x41091).

**I-lookaside (I-LAB)**, ERS s.6.4: one entry {VPN, RPN, AR type/PL, AID check
result, miss/protection flags}; refilled from the UTLB on a page crossing,
branch to another page or space, PL change, RFI, SSM/RSM/MTSM, ITLB
insert/purge, MTCTL to a PID, any DR8 write. Architecturally invisible.

### 2.3 Inserts, purges, replacement (ERS s.6.2, s.6.3; tests 0x41090/0x41093)

| Instruction | Target selection | Effect |
|---|---|---|
| IxTLBA r,(s,b) | **every** page entry whose VPN matches (even if invalid) **and**, if DR8[18] = 0, the entry DR8[19:24]; if DR8[31] = 1 (with [18] = [25] = 1), the block entry DR8[28:30]; otherwise, with no VPN match and DR8[25] = 0: lowest-numbered invalid non-locked-in entry, else lowest-numbered non-locked-in entry with used = 0, else clear all used bits and take the lowest non-locked-in entry; **no candidate -> insert dropped** | VPN, RPN written; E = 0; T/D/B/U/AR/AID cleared; lock-out <- DR8[16], lock-in <- DR8[17]; block entry: mask from VA{13:19}, TRANS from GR[r]{7:19} |
| IxTLBP r,(s,b) | page entries whose VPN matches; the DR8-selected block entry | AR, AID, T, D, B, U written; E = 1 |
| PxTLB (s,b) | page entries whose VPN matches; the DR8-selected block entry (DR8[18] = [25] = [31] = 1) | E = 0 |
| PxTLBE (s,b) | **all 64 page entries**, address ignored; block entries never | E = 0 |
| IITLBAF/IITLBPF/IDTLBAF/IDTLBPF r | as IxTLBA/IxTLBP with VA = {IIASQ front, IIAOQ front} (I) or {ISR, IOR} (D) | L2ERS ch.13 "Fast TLB Insert"; ERS s.6.8 |

* I and D forms are identical on the unified TLB (ERS s.6.4); IITLBx/PITLBx
  take the 3-bit SR field, IDTLBx/PDTLBx the 2-bit space select.
* With the real 715's PDC_CACHE (TLB count 1, stride 0) the OS purge-all loops
  execute **one PITLBE and one PDTLBE** (R06 s.3.3) -- one PxTLBE must purge
  every page entry.
* The ROM's checks (BOOT s.4.4): 0x41093 -- normal insert writes the VPN-match
  entry and leaves it invalid until IDTLBP; VPN match beats the replacement
  pointer; lock-out forces a mismatch; all entries locked -> insert dropped;
  unlocking one makes it the only candidate; locked-out block entry -> LPA
  misses (trap 17). 0x41090 -- 64 diagnostic inserts clear the power-on
  lock-out.

### 2.4 DR8 (UTLB diagnose control, ERS s.6.3.1)

| DR8 bit | r/w | Meaning | Normal |
|---|---|---|---|
| 16 | r/w | force VPN mismatch (lock-out) for inserted entries | 0 |
| 17 | r/w | inhibit replacement (lock-in) for inserted entries | 0 |
| 18 | r/w | page force-insert **disable** (0 = insert to pointer) | 1 |
| 19:24 | w | page replacement pointer | -- |
| 25 | r/w | page LRU-insert disable | 0 |
| 26 | w | accelerated failure mode -- must stay 0 (ours: ignored) | 0 |
| 28:30 | w | block entry pointer | -- |
| 31 | r/w | block force-insert enable | 0 |

Bits 0:15 do not exist (read 0). Reset value (**ours**): 0x00002000. ROM values:
0x2000/0x3780/0x3F80 normal, `0x40 | n<<7` diagnostic page insert (+0x4000
lock-in, +0xC000 lock-out+in), `0x2041 | n<<1 | lock<<14` block insert (BOOT
s.4.4, HW s.8.1).

### 2.5 Protection checks and the interruption each raises

Checked in this order (ACD p.4-14 priority list, p.3-10..3-13 table 3-1):

| Step | Data access (load/store/semaphore/PDC) | Instruction fetch (C = 1) | Fault |
|---|---|---|---|
| 1 | translation miss (page and block) -> walker if DR25.D = 0 | miss -> walker if DR25.I = 0 | **15** (load/store/semaphore), **17** (LPA, PROBE, FDC, PDC, **FIC** -- PCX-L translates FIC in the UTLB, ERS s.5.3.5), **6** (fetch). Trap **16 is never raised** on PCX-L. |
| 2 | access rights: read PL <= PL1 & type allows read; write PL <= PL2 & type allows write; PDC = write | execute: PL2 <= PL <= PL1 & type allows execute | **26** (data, PCX-L replaces 18, ERS s.2.2.8), **7** (fetch) |
| 3 | PSW.P = 1: some PID == AID (and for writes, its WD = 0), or AID = 0 | same | **27** (data), **7** (fetch) |
| 4 | unaligned (halfword odd, word not %4, doubleword not %8) | -- | **28** (sec. 8.1) |
| 5 | store/semaphore/PDC purge to a page with B = 1 and PSW.X = 0 | -- | **19** |
| 6 | store/semaphore with D = 0 | -- | **20** |
| 7 | load/store/semaphore with T = 1 | -- | **21** |
| 8 | U = 1 or PA in I/O space -> uncached transaction | U ignored for fetches (ACD: undefined) | -- |

* PROBE (ACD p.5-154): translation regardless of PSW.D; miss -> 17; result
  GR[t] = 1/0 from the access-rights (and, if P = 1, PID) check **at the PL in
  GR[r]{30:31} or the immediate** -- PA 1.1 has no "min with current PL" rule
  (QEMU applies the PA 2.0 rule, Q op_helper.c:331-334).
* No interruption occurs for absolute accesses except 28 (sec. 8.1).
* Table 3-1 is the exact truth table; the ROM probes all 128 AR values x PL
  0-3 (BOOT s.4.4 0x41094).

### 2.6 Hardware TLB-miss walker (ERS s.6.7; BOOT s.4.4 0x41095; R06 s.3.3)

Enabled per side by DR25 (I = bit 28 disables ITLB walks, D = bit 31 disables
DTLB walks; reset value 1/1, PDC writes 9 at reset). On a UTLB miss for a
translation that needs one (fetch, data access, LPA/PROBE/FDC/PDC/FIC):

1. hash: `h = ((off >> 12) << 4) ^ (space << 9)` (bits 7:27); address
   `A = (DR24 & 0xFFFFF000) | (h & M)`, M = DR25 bits 7:19 in place with bits
   20:31 forced to 1 -- **merged, not added** (table aligned to its size);
   entry = 16 bytes at A (word0 or word4 of a 32-byte line).
2. read the entry **through the D-cache with a real address, no hashing**
   (fill from memory on a miss; the ROM plants PDIR lines in the D-cache by
   diagnose writes with no RAM behind them).
3. check: tag word V (bit 0) = 1, tag offset[0:14] (bits 1:15) and space
   (16:31) match, prot word R (bit 0) = 1.
4. pass: insert (word2 as IxTLBA's GR[r], word1 as IxTLBP's GR[r]; normal
   replacement), then re-translate the access (ERS s.6.7.7) -- protection
   traps etc. follow normally.
5. fail: trap **15** / **17** / **6** and write **CR28**:

| (R = 1 and V = 1) | tag match | DR25[29] U | DR25[30] N | CR28 |
|---|---|---|---|---|
| no | x | x | x | address of the current entry |
| yes | no | 0 | x | address of the current entry |
| yes | no | 1 | 0 | next pointer: word3 (entry at word0) or word7 (entry at word4) |
| yes | no | 1 | 1 | word3 of the line |

CR28 rules settled by review 07 (s.2.5):

* **Trap 15 with DR25.D = 0 must carry CR28 from this walk, exactly as the
  table says**: HP-UX 10.20's DTLB-miss handler does not recompute the hash,
  it starts the chain at CR28 and treats CR28 = 0 as a page fault
  (`dtlb_got_next_ptr_PCXT`). With U = 1, N = 0 (HP-UX's mode) a tag
  mismatch takes the *contents* of word3 (entry at word0) or word7 (entry at
  word4), which may be 0.
* Trap 6: the same table (ROM 0x41095 checks it; HP-UX ignores it). Trap 17:
  the same, harmless (Q4 answered). Trap 16: never raised.
* **A walker that is disabled for that side (DR25 I/D = 1) never writes
  CR28** -- Linux keeps a live value there with `CONFIG_TLB_PTLOCK`. On a
  successful walk CR28 is unchanged. The walker never writes the PDIR.
* The walk is performed for every data access miss (loads, stores, LDCW,
  STBYS, FP loads/stores, also to I/O-space addresses; LDWAX/STWAS are
  absolute) and for LPA/PROBE/FDC/PDC/FIC (17).

The PDIR is big-endian (DR0.ENDIAN ignored, P-011). No buddy pages (ERS
s.6.7.6). HP-UX mode: DR25 U = 1, N = 0 ("cr28 mode 2", R06 s.3.3; set_state
5 enables both walkers). Linux never enables the walker. One shared TLB: a
D-side insert serves instruction fetches too (HP-UX relies on it, review 07
s.4 item 2).

### 2.7 Caches as the VM sees them

| Rule | Ours | Source |
|---|---|---|
| L2 index | VA[15:26] (line), VA[15:28] (doubleword); in virtual mode with DR0.DHASH_EN (D) / IHASH_EN (I): bit 19 ^= sid[29], 18 ^= sid[30], 17 ^= sid[31], 16 ^= sid[28], 15 ^= sid[27] | ERS s.4.5, s.4.6 hash tables (bits 12:14 unused at 128 KB) |
| L2 tag | RPN = PA[0:19] | HW s.8.3 |
| Equivalent aliases | VA{12:31} equal and space bits 20:31 equal -> same line: compliant with ACD p.3-6 rules 1-3 | ACD p.3-6 |
| Non-equivalent aliases | software's job (flush), as on the real chip; Linux assumes <= 4 MB colouring (R06 s.3.4) | ACD p.3-6/3-7 |
| L1-I index | VA[22:28], tag RPN + VA[20:21] (QPAGE) -- inside the page, no aliasing | ERS s.4.5, s.8.2.9 |
| U bit / I/O space | always an uncached transaction, the cache is not looked up (ERS s.5.3.6 "D-Cache Miss is signalled for accesses to I/O or U-bit space") | ACD p.3-22 table 3-2 |
| DMA | not snooped; OS flushes/purges (HP-UX: flush before DMA; Linux: FDC both ways + an uncached window, L pci-dma.c:401-456) | R06 s.3.4 |
| I-cache vs stores | data stores and D-fills never touch the I-caches; SMC needs FDC + FIC (ROM 0x42097); the ROM's memory test relies on it to keep code planted in the I-cache at PA 0 (BOOT s.4.5) | ACD p.3-16 |

---

## 3. Interruptions

### 3.1 Vectors

Group/priority order inside a group is the ACD p.4-14 list order. Req: R = HP's
ROM (PDC 1.6 self-tests/PDC), H = HP-UX 10.20/11.00, L = Linux; "dbg" =
debuggers only.

| # | Name | Grp | Raised on PCX-L by | IIR | ISR/IOR | Req |
|---|---|---|---|---|---|---|
| -- | **TOC** | 1 | `toc_req` (IO_COMMAND = 5 at CPU_HPA+0x30, front-panel TOC via LASI ICR), not masked by PSW.M, masked by the TOC mask | -- | -- | R, H |
| 1 | HPMC | 1 | uncached/fill response error (absent device, unconfigured memory, multi-bit ECC, injected parity), `hpmc_req` level from the MIOC, DR0 cache parity flags not masked | -- | -- | R (probes, tests 0x410D2/0x410D8/0x410D9/0x42095) |
| 2 | power fail | 2 | never (P-014) | -- | -- | -- |
| 3 | recovery counter | 2 | RCTR bit 0 = 1 and PSW.R = 1 | -- | -- | R (0x4108B), L (single-step), dbg |
| 4 | external interrupt | 2 | PSW.I and (EIRR & EIEM) != 0 | -- | -- | R, H, L |
| 5 | LPMC | 2 | `lpmc_req` (MIOC single-bit ECC with LPMC enable), PSW.I | -- | -- | R (0x410D7) |
| 29 | performance monitor | 2 | never (no performance monitor) | | | -- |
| 6 | ITLB miss | 3 | fetch translation miss after a failed/disabled walk | -- | -- | H, L, R (0x41095) |
| 7 | instruction memory protection | 3 | execute rights or PID | -- | -- | H, L |
| 30 | instruction debug | 3 | never (no debug SFU) | | | -- |
| 8 | illegal instruction | 3 | undefined major opcodes and sub-opcodes (sec. 4.1), GATE with PSW.B = 1 | yes | -- | all |
| 9 | BREAK | 3 | BREAK | yes | -- | all (ROM test IVA uses im5 = 1/2/3) |
| 10 | privileged operation | 3 | IxTLBx, PxTLBx, MTSM, SSM, RSM, RFI, RFIR, LDWAX/AS, STWAS, DIAG, LPA, LCI at PL != 0 | yes | -- | all |
| 11 | privileged register | 3 | MTSP SR5-7, MTCTL (not CR11), MFCTL privileged CRs, at PL != 0 | yes | -- | all |
| 12 | overflow | 3 | *O forms, ADDIO/ADDITO/SUBIO | yes | -- | R (0x4108A) |
| 13 | conditional | 3 | ADDIT/ADDITO/SUBT/SUBTO conditions | yes | -- | R (0x4108A), compilers |
| 14 | assist exception | 3 | FP instruction with FPSR.T = 1 (delayed FP trap), except FSTD fr0 | yes | -- | R (0x44082), H, L |
| 15 | DTLB miss | 3 | sec. 2.5 | yes | yes | all |
| 16 | non-access ITLB miss | 3 | **never** (FIC uses the UTLB -> 17) | | | -- |
| 17 | non-access DTLB miss | 3 | LPA, PROBE*, FDC, PDC, FIC | yes | yes | all |
| 26 | data memory access rights | 3 | sec. 2.5 | yes | yes | all |
| 27 | data memory protection ID | 3 | sec. 2.5 | yes | yes | all |
| 28 | unaligned data reference | 3 | sec. 8.1 | yes | yes | all |
| 18 | data memory protection/unaligned | 3 | **never** on PCX-L (ERS s.2.2.8) | | | -- |
| 19 | data memory break | 3 | B bit, PSW.X = 0 | yes | yes | R (0x41096) |
| 20 | TLB dirty bit | 3 | D bit = 0 on store/semaphore | yes | yes | all |
| 21 | page reference | 3 | T bit | yes | yes | R, H |
| 31 | data debug | 3 | never | | | -- |
| 22 | assist emulation | 3 | FP instruction with CCR{0,1} != 11 (CCR = 0 traps; 1/2 undefined, ours trap), COPR/CLDx/CSTx with uid >= 2 (uid 1 for doubleword), SPOPn, debug-SFU ops | yes | yes for coprocessor loads/stores | R, H, L |
| 23 | higher-privilege transfer | 4 | PSW.H, next instruction's PL more privileged | -- | -- | dbg |
| 24 | lower-privilege transfer | 4 | PSW.L, next instruction's PL less privileged (not after RFI) | -- | -- | dbg |
| 25 | taken branch | 4 | PSW.T and a taken branch | -- | -- | L (block-step), dbg |

Group 4 traps are "taken-before" (ERS s.5.3.5): they are raised on the
instruction **after** the branch (IIAOQ = {delay slot, target}), which does not
execute, and have priority over everything including HPMC. Group 3 traps never
occur on nullified instructions (ERS s.5.3.5); group 2 can be taken before a
nullified instruction (IPSW.N = 1).

### 3.2 Entry sequence (ACD p.4-15..4-16, ERS s.5.3.5)

1. IPSW <- PSW (groups 1-3: PSW at the start of the instruction; group 4: after
   the branch).
2. PSW <- 0, then M = 1 for HPMC (not for TOC: "TOCs do not set the M-bit",
   ERS s.5.3.5), E = DR0[23].
3. If the old PSW.Q = 1: IIASQ/IIAOQ <- {IASQ, IAOQ} front/back of the
   interrupted instruction; IIR/ISR/IOR per the table. If Q = 0: all
   unchanged.
4. Shadow registers <- GR1/8/9/16/17/24/25 (always).
5. RCTR restored for groups 1-3 (the interrupted instruction did not count).
6. Fetch from {IVA[0:21], vector, 00000} at PL 0, or **0xF0000000** for HPMC
   and TOC (ERS s.5.3.5; BOOT s.1). TOC also sets the TOC mask.

### 3.3 RFI / RFIR (ACD p.5-139, p.5-141)

PSW <- IPSW (all implemented bits, including N, B, X, Q, E), IAOQ <- IIAOQ,
IASQ <- IIASQ; RFIR also restores the shadowed GRs. Execution resumes at
IIAOQ front with IIAOQ back as the following instruction; if IPSW.N = 1 the
front instruction is nullified (ROM 0x4108B checks it with IPSW = 0x00210008).
No lower-privilege transfer trap after RFI. A DIAG must not immediately
precede RFI/RFIR (ERS s.8.4) -- no hardware consequence for us.

### 3.4 HPMC, TOC, bus errors and the ROM's probes

| Mechanism | Ours | Source |
|---|---|---|
| Entry | 0xF0000000 in real mode, PSW = M (HPMC) or 0 (TOC); IIAQ captured if Q was 1; shadows captured | ERS s.5.3.5; BOOT s.2.11 |
| Bus error on an uncached read (absent device, `io_err`) | the load does **not** write its target and the HPMC is taken **on the load** (IIAOQ front = load), if PSW.M = 0; with M = 1 the load completes with undefined data and the HPMC stays pending (via `hpmc_req`) until M = 0 | the ROM's probe idiom is `ld ; sync ; sync ; sync` and the test vector handler skips the IIAOQ front instruction (BOOT s.2.4, rom.dis f0000880-f000088c, f000b2b0-f000b2bc) -- either the load or a sync may be skipped, so precise is safe; the real chip takes it within the syncs (ERS s.8.4) |
| Bus error on an uncached store | precise if the system acks with `io_err`; if the system posted the write, via `hpmc_req` at a later boundary | ERS s.9.6 |
| Error on a cache fill (`mem_rerr`: unconfigured memory -> MIOC status 0x02, multi-bit ECC -> 0x20) | HPMC on the instruction whose access caused the fill; the line is filled and left valid (software must purge it, ERS s.9.7) | BOOT s.4.6 0x410D8 |
| `hpmc_req` level input | HPMC at the next instruction boundary while asserted and PSW.M = 0 | MIOC status write-back clears it (HW s.1.3) |
| Cache parity | DR0 flags 6/8/10 (+12:15) set on detection; HPMC while (flag and not its _DIS bit) and M = 0 | ERS s.8.2.2, s.8.3.4 |
| DR0 bit 18 (STORE[1]) | **pure scratch**: "an HPMC is expected" is a ROM convention, hardware does nothing with it; bit 16 likewise ("inside HPMC/OS handler") | ERS s.8.2.2; BOOT s.2.2 |
| TOC | `toc_req` latched as pending; taken at a boundary while the TOC mask is 0, independent of PSW.M; sets the mask | ERS s.5.3.5 |
| TOC mask | 1 at reset/broadcast reset; TOC_EN clears, TOC_DIS sets | ERS s.8.3.3; ROM: TOC_EN at f00002c8 after memory init |

The ROM's expected-HPMC path (BOOT s.2.4, s.2.11): 0xF0000000 ->
`hpmc_toc_entry` saves r1/r8/r9/r16/r17 in GRs, `set_psw(M)` (IPSW/IIAOQ saved
and restored around an RFI with Q = 0 -- needs exact CR18 queue writes) ->
`hpmc_probe_forward`: DR0[18] set -> SHDW_GR, branch to IVA+0x20 -> test vector
1 clears MIOC status, skips the instruction and RFIs.

### 3.5 Floating-point delayed traps (ACD p.6-26..6-28; ERS s.7.3)

PCX-L generates **only the unimplemented exception**, always as a delayed
trap: any condition in ERS s.7.3 (NaN input, denormal input or tiny result with
FPSR.D = 0, any IEEE exception whose trap is enabled, FCNVFX overflow, FRND,
quad format, reserved sub-ops) completes the operation **without writing its
destination or any flag**, writes **exception register 2 (fr1L)** = {code,
instruction bits 6:31} with code 001001 (0C), 001011 (0E), 000011 (06),
100011 (26), and sets FPSR.T. The next FP instruction (any, including FP
loads/stores, FTEST and COPR) then takes **trap 14** with IIR = that
instruction -- except FSTD fr0, which stores the status with T = 1, then
clears T and does not trap. With traps disabled, IEEE exceptions set flags and
return the default results (ACD table 6-20). ROM test 0x44082 checks exactly
this (the store after the excepting op must trap and then store 0, BOOT
s.4.4). QEMU traps immediately (Q fpu_helper.c:134), so it cannot be the
reference here; `tests/cpu/model.py` (`fp_operate`) is, and the `fpedge`
suite checks it. The trap check runs in E on the live FPSR.T, so the core
holds an FP instruction in D while an FP load or store of fr0-fr3 is in
E/M/W (FSTD fr0 clears T, FLD fr0 rewrites the status at W commit) -- the
real chip's 4-cycle interlock on those (ERS s.7.5.6).

---
## 4. Instruction set

Derived from ACD appendix D (tables D-1..D-22, the authoritative PA 1.1 list),
cross-checked against QEMU's `insns.decode` with its PA 2.0-only forms
removed, plus the PCX-L additions. Encodings: `MM` = major opcode (bits 0:5) in
hex, then the extension field and its bit range. Class: `int` integer ALU,
`sh` shift/extract/deposit, `ld`/`st` memory, `br` branch, `sys` system
control, `mmu` TLB/cache, `diag` PCX-L diagnose, `fp` FP operation, `fpm` FP
load/store, `max` MAX-1, `asst` coprocessor/SFU trap. Status is `planned` for
everything (no RTL); Test is `todo` (tests/cpu, sec. 7).

### 4.1 Decode policy

| Case | Action | Source |
|---|---|---|
| Undefined major opcode: 07, 0F, 14-17, 1C-1F, 27, 2E, 2F, 36, 37, 3B-3F | **illegal instruction trap 8** | ACD p.5-1 ("an undefined major opcode is an illegal instruction"), p.4-20..4-21 trap 8, table D-1; 0F is "product specific" and PCX-L defines nothing there (its Viper graphics-flush ops trap 8, ERS s.2.2.12) |
| Undefined extension inside a defined major opcode (integer, memory, system, branch) | trap 8 (**ours**; ACD leaves it to the implementation) | ACD p.5-1 |
| Undefined/reserved FP sub-op (0C/0E) | unimplemented exception, delayed (sec. 3.5) | ERS s.7.2.1 |
| Undefined DIAG encoding | **trap 8** at PL 0 (Q7 settled by review 07: no reachable undefined DIAG in either OS on a correctly identified PCX-L; trap 8 makes HP-UX's PCX-T misidentification visible). At PL != 0 the privilege check comes first (trap 10), as for every DIAG. The simulator logs every DIAG executed outside the ROM | ERS s.8.3.9 lists every defined one |
| **Nullified** undefined or PA 2.0 opcode | never traps (nullification is decided before the decode-time traps are raised): HP-UX 10.20 has ~30 nullified LDD/STD words in generic PA 1.1 paths (review 07 s.3.4) | ERS s.5.3.5 (group 3 traps never occur on nullified instructions) |
| Reserved instruction fields ("rv", ERS "X" bits) | ignored | ACD p.5-2; ERS s.8.3.9 "assume X == 0" |
| PA 2.0-only forms (bit 26 of 02 set, `,*`/`,d` completers, LDD/STD/LDDA/STDA/LDCD/STDBY, the 14/16/17/1C/1E/1F long-displacement loads/stores, FMPYFADD 2E, CMPB/CMPIB doubleword 27/2F/3B, EXTRD/DEPD 36/3C/3D, MAX-2 3E, BVE, B,L,PUSH, B,L long, CLRBTS/POPBTS/PUSHBTS, MFIA, MTSARCM, IxTLBT, PxTLB,L, FDC short, FIC 4F, unsigned FCNV, FNEG/FNEGABS) | trap 8 (or unimplemented exception for 0C/0E forms) -- never execute them | PA 1.1 tables; QEMU wrongly executes several of them (sec. 7.3) |
| Privileged instruction at PL != 0 | trap 10 before any other effect | ACD p.4-21 |
| MAX-1 in QEMU | QEMU refuses MAX-1 unless PA 2.0 (Q translate.c:3099-3143); **wrong for the 7100LC** -- MAX-1 is a PCX-L feature (ERS s.2.1.4) | |

### 4.2 Major opcode map (ACD table D-1 + PCX-L)

| hex | op | hex | op | hex | op | hex | op |
|---|---|---|---|---|---|---|---|
| 00 | system (4.3.1) | 10 | LDB | 20 | COMBT | 30 | BVB |
| 01 | mem mgmt (4.3.2) | 11 | LDH | 21 | COMIBT | 31 | BB |
| 02 | arith/log + MAX-1 (4.3.3) | 12 | LDW | 22 | COMBF | 32 | MOVB |
| 03 | index mem (4.3.4) | 13 | LDWM | 23 | COMIBF | 33 | MOVIB |
| 04 | SPOPn -> trap 22 | 14 | -- | 24 | COMICLR | 34 | extract (4.3.10) |
| 05 | DIAG (4.3.6) | 15 | -- | 25 | SUBI/SUBIO | 35 | deposit (4.3.10) |
| 06 | FMPYADD / FMPYCFXT | 16 | -- | 26 | FMPYSUB | 36 | -- |
| 07 | -- | 17 | -- | 27 | -- | 37 | -- |
| 08 | LDIL | 18 | STB | 28 | ADDBT | 38 | BE |
| 09 | copr word ld/st (FLDW/FSTW) | 19 | STH | 29 | ADDIBT | 39 | BLE |
| 0A | ADDIL | 1A | STW | 2A | ADDBF | 3A | branch (4.3.11) |
| 0B | copr dword ld/st (FLDD/FSTD) | 1B | STWM | 2B | ADDIBF | 3B | -- |
| 0C | COPR (FP class 0-3, perf mon) | 1C | -- | 2C | ADDIT/ADDITO | 3C | -- |
| 0D | LDO | 1D | -- | 2D | ADDI/ADDIO | 3D | -- |
| 0E | FP (L/R regs), XMPYU | 1E | -- | 2E | -- | 3E | -- |
| 0F | product specific: nothing on PCX-L -> trap 8 | 1F | -- | 2F | -- | 3F | -- |

### 4.3 Instruction tables

#### 4.3.1 System control -- major 00, ext8 = bits 19:26 (ACD table D-2)

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| BREAK im5,im13 | 00 / 00 | sys | trap 9, IIR = word (ROM: `break 2,0x1555` -> IIR 0x02AAA002) | planned | todo |
| SYNC | 00 / 20, bits 11:15 = 0 | sys | drain store buffer and pending flushes/write-backs | planned | todo |
| SYNCDMA | 00 / 20, bits 11:15 = 0x10 | sys | = SYNC (non-coherent system) | planned | todo |
| RFI | 00 / 60 | sys | priv; sec. 3.3 | planned | todo |
| RFIR | 00 / 65 | sys | priv; + shadow restore | planned | todo |
| SSM i,t | 00 / 6B | sys | priv; GR[t] <- PSW{25:31}; may set Q | planned | todo |
| RSM i,t | 00 / 73 | sys | priv | planned | todo |
| MTSM r | 00 / C3 | sys | priv | planned | todo |
| LDSID (s,b),t | 00 / 85 | sys | GR[t] <- space (16 bits) | planned | todo |
| MTSP r,sr | 00 / C1 | sys | sr = bits 16:18 (assemble_3); SR5-7 priv (trap 11) | planned | todo |
| MFSP sr,t | 00 / 25 | sys | | planned | todo |
| MTCTL r,t | 00 / C2 | sys | sec. 1.3; CR11 any PL | planned | todo |
| MFCTL r,t | 00 / 45 | sys | bit 17 (PA 2.0 `,w`) ignored | planned | todo |

#### 4.3.2 Memory management -- major 01 (ACD tables D-3, D-4; ERS s.6.8)

Instruction group: bit 19 = 0, ext7 = bits 19:25, s = bits 16:18. Data group:
bit 19 = 1, ext8 = bits 18:25, s = bits 16:17. m = bit 26.

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| IITLBA r,(sr,b) | 01 / ext7 01 | mmu | priv; = IDTLBA on the unified TLB | planned | todo |
| IITLBP r,(sr,b) | 01 / ext7 00 | mmu | priv; writes U/T/D/B too | planned | todo |
| PITLB x(sr,b) | 01 / ext7 08 | mmu | priv; m | planned | todo |
| PITLBE x(sr,b) | 01 / ext7 09 | mmu | priv; purges all page entries | planned | todo |
| FIC x(sr,b) | 01 / ext7 0A | mmu | invalidates the L2-I line and its 4 L1 entries; UTLB translation (D bit), miss -> 17 | planned | todo |
| FICE x(sr,b) | 01 / ext7 0B | mmu | invalidates L2-I line at index VA[15:26] (+ its L1 entries); no translation | planned | todo |
| IDTLBA r,(s,b) | 01 / ext8 41 | mmu | priv | planned | todo |
| IDTLBP r,(s,b) | 01 / ext8 40 | mmu | priv | planned | todo |
| PDTLB x(s,b) | 01 / ext8 48 | mmu | priv | planned | todo |
| PDTLBE x(s,b) | 01 / ext8 49 | mmu | priv; purges all page entries | planned | todo |
| FDC x(s,b) | 01 / ext8 4A | mmu | write back if dirty, invalidate; miss -> 17 | planned | todo |
| FDCE x(s,b) | 01 / ext8 4B | mmu | flush line at index VA[15:26]; no translation | planned | todo |
| PDC x(s,b) | 01 / ext8 4E | mmu | PL 0: invalidate without write-back; PL != 0: = FDC; needs write rights (26/27/19) | planned | todo |
| PROBER (s,b),r,t | 01 / ext8 46 | mmu | sec. 2.5 | planned | todo |
| PROBERI (s,b),i,t | 01 / ext8 C6 | mmu | | planned | todo |
| PROBEW (s,b),r,t | 01 / ext8 47 | mmu | | planned | todo |
| PROBEWI (s,b),i,t | 01 / ext8 C7 | mmu | | planned | todo |
| LPA x(s,b),t | 01 / ext8 4D | mmu | priv; translation regardless of D; miss -> 17 | planned | todo |
| LCI x(s,b),t | 01 / ext8 4C | mmu | priv; GR[t] <- 0 (P-017) | planned | todo |
| IITLBPF r | 01 / bits 18:25 = 10 | mmu | PCX-L; VA = IIASQ/IIAOQ front; b (6:10) and s (16:17) ignored so HP-UX 9's variant (b = 9, s = 1; Q insns.decode) decodes too | planned | todo |
| IITLBAF r | 01 / 11 | mmu | PCX-L | planned | todo |
| IDTLBPF r | 01 / 50 | mmu | PCX-L; VA = ISR/IOR | planned | todo |
| IDTLBAF r | 01 / 51 | mmu | PCX-L | planned | todo |

#### 4.3.3 Arithmetic/logical -- major 02, ext6 = bits 20:25, bit 26 = 0, c = 16:18, f = 19 (ACD table D-5; MAX-1: L2ERS ch.13, PA2 p.7-58..7-64)

| Mnemonic | ext6 | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| ANDCM | 00 | int | logical cond (table 5-5) | planned | todo |
| AND | 08 | int | | planned | todo |
| OR | 09 | int | `nop` = OR 0,0,0 | planned | todo |
| XOR | 0A | int | | planned | todo |
| UXOR | 0E | int | unit cond (table 5-6) | planned | todo |
| SUB | 10 | int | sets C/B; compare cond (table 5-3) | planned | todo |
| DS | 11 | int | divide step: PSW.V, C/B | planned | todo |
| SUBT | 13 | int | trap 13 on cond | planned | todo |
| SUBB | 14 | int | borrow in | planned | todo |
| ADD | 18 | int | add cond (table 5-4) | planned | todo |
| SH1ADD | 19 | int | | planned | todo |
| SH2ADD | 1A | int | | planned | todo |
| SH3ADD | 1B | int | | planned | todo |
| ADDC | 1C | int | carry in | planned | todo |
| COMCLR | 22 | int | GR[t] <- 0, nullify on cond | planned | todo |
| UADDCM | 26 | int | unit cond | planned | todo |
| UADDCMT | 27 | int | trap 13 on cond | planned | todo |
| ADDL | 28 | int | no C/B | planned | todo |
| SH1ADDL | 29 | int | | planned | todo |
| SH2ADDL | 2A | int | | planned | todo |
| SH3ADDL | 2B | int | | planned | todo |
| DCOR | 2E | int | decimal correct from C/B (ROM 0x41087) | planned | todo |
| IDCOR | 2F | int | | planned | todo |
| SUBO | 30 | int | trap 12 | planned | todo |
| SUBTO | 33 | int | traps 12/13 | planned | todo |
| SUBBO | 34 | int | | planned | todo |
| ADDO | 38 | int | | planned | todo |
| SH1ADDO | 39 | int | | planned | todo |
| SH2ADDO | 3A | int | | planned | todo |
| SH3ADDO | 3B | int | | planned | todo |
| ADDCO | 3C | int | | planned | todo |
| HSUB,US | 04 (minor 08) | max | cf (16:19) must be 0, else trap 8 | planned | todo |
| HSUB,SS | 05 (minor 0A) | max | | planned | todo |
| HSUB | 07 (minor 0E) | max | modular | planned | todo |
| HAVG | 0B (minor 16) | max | unbiased rounding: lsb' = sum{14} \| sum{15} (PA2 p.7-59) | planned | todo |
| HADD,US | 0C (minor 18) | max | r1 unsigned + r2 signed, clamp [0, FFFF] | planned | todo |
| HADD,SS | 0D (minor 1A) | max | signed saturation | planned | todo |
| HADD | 0F (minor 1E) | max | modular | planned | todo |
| HSHRADD r1,1..3,r2,t | 15/16/17 (minor 2A/2C/2E), sa = bits 24:25 | max | arithmetic shift of r1, signed saturation | planned | todo |
| HSHLADD r1,1..3,r2,t | 1D/1E/1F (minor 3A/3C/3E) | max | **pre-shift overflow saturates first** (L2ERS "HSLxADD" notes; PA2 table 6-3) -- QEMU differs | planned | todo |

Conditions apply to every target including GR0 (ROM 0x41087). Overflow `O`
forms set C/B only if no trap (ACD p.2-10). The 7300LC ERS lists HSUB's minor
codes under the label "HADD" -- a typo; the codes above are HSUB's (they match
PA2 p.7-63).

#### 4.3.4 Indexed and short loads/stores -- major 03, bit 19 = 0 indexed / 1 short, ext4 = bits 22:25 (ACD table D-6)

Completers: u/a = bit 18, m = bit 26, cc (cache hint) = bits 20:21 (ignored).
Base modification writes GR[b] in the same cycle as the load target (2 GR
write ports, sec. 6.4); if b = t the loaded value wins (ACD p.5-40 note).

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| LDBX/LDBS | 03 / 0 | ld | | planned | todo |
| LDHX/LDHS | 03 / 1 | ld | | planned | todo |
| LDWX/LDWS | 03 / 2 | ld | | planned | todo |
| LDWAX/LDWAS | 03 / 6 | ld | priv, absolute | planned | todo |
| LDCWX/LDCWS | 03 / 7 | ld | semaphore, sec. 5.7 / 8.2 | planned | todo |
| STBS | 03 / 8 (short) | st | | planned | todo |
| STHS | 03 / 9 (short) | st | | planned | todo |
| STWS | 03 / A (short) | st | | planned | todo |
| STBYS,B/E | 03 / C (short) | st | 0-4 bytes; ROM 0x42098 values | planned | todo |
| STWAS | 03 / E (short) | st | priv, absolute | planned | todo |
| LDWCX/LDWBX/LDWLX | 03 / 3 indexed, z = bits 20:21 = 00/10/11 | ld | PCX-L multi-endian: C = opposite of PSW.E, B = big, L = little (byte-reversed word); encoding from L2ERS ch.13 (the 7100LC appendix is not in our copy); z = 01 -> trap 8 | planned | todo |
| LDWCS/LDWBS/LDWLS | 03 / 3 short | ld | as above | planned | todo |
| STWCS/STWBS/STWLS | 03 / B short | st | as above | planned | todo |
| (indexed stores, ext4 8-F with bit 19 = 0; ext4 4, 5, D, F) | -- | -- | trap 8 (PA 2.0 LDDA/LDCD/STDBY/STDA) | -- | todo |

#### 4.3.5 SPOP / SFU -- major 04 (ACD table D-11, D-22)

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| SPOP0..SPOP3 (incl. IDENTIFY SFU) | 04 / bits 21:22 = 0..3 | asst | SCR = 0 (no SFU): **trap 22** | planned | todo |
| debug SFU ops (MTDBAO .. MFIBAM, DEBUGID) | 04, uid 1 | asst | trap 22 (no debug SFU on PCX-L) | planned | todo |

Neither HP-UX nor Linux uses SPOP (R06 s.3.7).

#### 4.3.6 DIAG -- major 05, PCX-L encodings (ERS s.8.3.9; HW s.8)

Code = bits 19:26 (decode on bits 19, 20:22, 23, 24, 25 as the ERS table; X
bits ignored). All privileged (trap 10 at PL != 0). Template = the word with
all register fields 0.

| Mnemonic | code | Template | Fields | Effect | Status | Test |
|---|---|---|---|---|---|---|
| MTCPU x,dr | 12 | 0x14000240 | dr = 6:10, x = 11:15 | DR[dr] <- GR[x] (W1C bits in DR0) | planned | todo |
| MFCPU_C dr,t | 30 | 0x14000600 | dr = 6:10, t = 11:15 | GR[t] <- DR[dr] (ERS: DR0, DR8) | planned | todo |
| MFCPU_T dr,t | a0 | 0x14001400 | dr = 6:10, t = 27:31 | GR[t] <- DR[dr] (ERS: DR25, 27, 28, 29) | planned | todo |
| TOC_EN | 50 | 0x14000A00 | -- | TOC mask <- 0 | planned | todo |
| TOC_DIS | 52 | 0x14000A40 | -- | TOC mask <- 1 | planned | todo |
| SHDW_GR | d0 | 0x14001A00 | -- | GR <- SHR | planned | todo |
| GR_SHDW | d2 | 0x14001A40 | -- | SHR <- GR | planned | todo |
| RDD b,t | e2 | 0x14001C40 | b = 6:10, t = 27:31 | GR[t] <- L2-D data word at real index GR[b]{15:29}; DR0 HIT/PARERR | planned | todo |
| RDTLB (s,b),t | e6 | 0x14001CC0 | s = 16:17 | as RDD with the UTLB-translated, hashed address, TLB traps suppressed (miss -> HIT = 0) | planned | todo |
| RDT b,t | ea | 0x14001D40 | | GR[t] <- tag word of the line + data parity of the addressed doubleword (sec. 5.4) | planned | todo |
| RI2D b,t | 62 | 0x14000C40 | | L2-I data word | planned | todo |
| RI2T b,t | 6a | 0x14000D40 | | L2-I tag word | planned | todo |
| RI1 | 40 | 0x14000800 | address = IIAOQ **back** (CR18 written with Q = 0) | DR27/28/29 read latches <- L1 entry; DR0 PARERR, L1IHPMC | planned | todo |
| WDD b,x | f2 | 0x14001E40 | b = 6:10, x = 11:15 | L2-D data word <- GR[x] with computed parity | planned | todo |
| WDT b | fa | 0x14001F40 | | L2-D tag of the line <- SET_TAG latch (+ arbitrary parity, sec. 5.4) | planned | todo |
| WI2D b,x | 72 | 0x14000E40 | | L2-I data word | planned | todo |
| WI2T b | 7a | 0x14000F40 | | L2-I tag | planned | todo |
| WI1 b | 70 | 0x14000E00 | index = GR[b]{22:28} | L1 entry <- DR27/28/29 write latches | planned | todo |
| SET_TAG x | 42 | 0x14000840 | x = 11:15 | tag latch <- GR[x] | planned | todo |

DIAG instructions do not come in pairs on PCX-L and can be nullified (ERS
s.8.4). Linux executes MFCPU_C/MTCPU DR0 (0x141C0600/0x141C0240, L
pacache.S:1314-1321) once at boot and MFCPU_T DR25 once a second at rev != 0;
HP-UX 10.20 executes **MFCPU_T DR25 (0x1720141C) at 4 Hz** (the soft-power
poll, review 07 s.1.4) and nothing else on a PCX-L. Note: the PCX-T
DR0 read 0x141C1A00 that HP-UX uses on a misidentified CPU decodes on PCX-L as
**SHDW_GR** -- harmless only because the PCX-L path is taken when PDC reports
8 BTLB slots.

#### 4.3.7 Long immediates and long-displacement memory (ACD table D-1)

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| LDIL i,t | 08 | int | | planned | todo |
| ADDIL i,r | 0A | int | target GR1 | planned | todo |
| LDO d(b),t | 0D | int | | planned | todo |
| LDB d(s,b),t | 10 | ld | 14-bit disp, 2-bit s | planned | todo |
| LDH | 11 | ld | | planned | todo |
| LDW | 12 | ld | | planned | todo |
| LDWM | 13 | ld | modify: pre (d < 0) / post (d >= 0) | planned | todo |
| STB r,d(s,b) | 18 | st | | planned | todo |
| STH | 19 | st | | planned | todo |
| STW | 1A | st | | planned | todo |
| STWM | 1B | st | | planned | todo |

#### 4.3.8 Compare/add-and-branch, immediates (ACD table D-1, D-7)

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| COMBT/COMBF | 20 / 22 | br | compare cond; static prediction: backward taken | planned | todo |
| COMIBT/COMIBF | 21 / 23 | br | | planned | todo |
| ADDBT/ADDBF | 28 / 2A | br | add cond; writes r2 | planned | todo |
| ADDIBT/ADDIBF | 29 / 2B | br | ROM uses `addib,tr` and ,UV/NUV/EV/OD (0x41087) | planned | todo |
| COMICLR i,r,t | 24 | int | | planned | todo |
| SUBI / SUBIO | 25, bit 20 = 0/1 | int | | planned | todo |
| ADDIT / ADDITO | 2C, bit 20 = 0/1 | int | trap 13 / 12 | planned | todo |
| ADDI / ADDIO | 2D, bit 20 = 0/1 | int | ROM: ADDIO 0x7FFFFFFF+1 -> trap 12 | planned | todo |

#### 4.3.9 Bit branches, move-and-branch (ACD p.5-69..5-80)

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| BVB,cond,n r,target | 30, c = 16:18 | br | bit SAR of GR r | planned | todo |
| BB,cond,n r,p,target | 31, c = 16:18 | br | bit p | planned | todo |
| MOVB,cond,n r1,r2,target | 32 | br | shift/extract cond (table 5-7) | planned | todo |
| MOVIB,cond,n i,r,target | 33 | br | | planned | todo |

**BB/BVB condition decode: bit 16 only** (0 = `<`, bit is 1; 1 = `>=`, bit is
0); bits 17:18 ignored. PA 1.1 defines only c = 010 and 110 (ACD p.5-79/5-80);
the ROM executes **0xC482A12A** (BB, p = 4, r2, c = 101) and **0xC002A06A**
(BVB, c = 101) in test 0x41086 and requires both to be *taken* on 0xF7DFFFFF
(bit 4 = 0) and *not* to trap (BOOT s.4.2). objdump cannot decode them; QEMU
traps them as illegal (its `bb_*` patterns require bit 17 = 1, Q insns.decode
`bb_sar`/`bb_imm`).

#### 4.3.10 Shift, extract, deposit -- 34/35, ext3 = bits 19:21 (ACD table D-8)

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| VSHD r1,r2,t | 34 / 0, bits 22:26 = 0 | sh | shift by SAR | planned | todo |
| SHD r1,r2,cp,t | 34 / 2 | sh | | planned | todo |
| VEXTRU r,len,t | 34 / 4 | sh | | planned | todo |
| VEXTRS | 34 / 5 | sh | | planned | todo |
| EXTRU r,p,len,t | 34 / 6 | sh | | planned | todo |
| EXTRS | 34 / 7 | sh | | planned | todo |
| ZVDEP r,len,t | 35 / 0 | sh | | planned | todo |
| VDEP | 35 / 1 | sh | | planned | todo |
| ZDEP r,cp,len,t | 35 / 2 | sh | | planned | todo |
| DEP | 35 / 3 | sh | | planned | todo |
| ZVDEPI i,len,t | 35 / 4 | sh | | planned | todo |
| VDEPI | 35 / 5 | sh | | planned | todo |
| ZDEPI i,cp,len,t | 35 / 6 | sh | | planned | todo |
| DEPI | 35 / 7 | sh | | planned | todo |

34/1, 34/3, and non-zero bits 22:26 on the V forms -> trap 8 (PA 2.0 SHRPD etc.).

#### 4.3.11 Unconditional branches (ACD p.5-58..5-68, table D-9)

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| BE,n wd(sr,b) | 38 | br | interspace; PL lowering | planned | todo |
| BLE,n wd(sr,b) | 39 | br | GR31 <- IAOQ_Back + 4, SR0 <- IASQ_Back | planned | todo |
| BL,n target,t | 3A / 0 (bits 16:18) | br | always predicted taken | planned | todo |
| GATE,n target,t | 3A / 1 | br | trap 8 if PSW.B; privilege promotion from the I-LAB type | planned | todo |
| BLR,n x,t | 3A / 2, bits 19:29 = 0, bit 31 = 0 | br | | planned | todo |
| BV,n x(b) | 3A / 6, bits 19:29 = 0, bit 31 = 0 | br | | planned | todo |

3A/3, 3A/4, 3A/5, 3A/7 and BLR/BV with non-zero reserved bits -> trap 8 (PA 2.0
B,L,PUSH / B,L long / BVE / CLRBTS ...).

#### 4.3.12 Floating point (ACD ch.6, tables D-10, D-12..D-20; ERS ch.7)

FP instructions require CCR{0,1} = 11 (else **trap 22**, ACD table 6-7) and
trap **14** while FPSR.T = 1 (sec. 3.5). Formats: 0C fmt 0 = sgl, 1 = dbl,
3 = quad (-> unimplemented); 0E f bit = sgl/dbl with L/R register halves.

| Mnemonic | Encoding | Class | Notes | Status | Test |
|---|---|---|---|---|---|
| FLDWX/FLDWS | 09, bit 19 = 0/1, bit 22 = 0, uid 0 (left) / 1 (right) | fpm | single-word access to fr0R..fr3R undefined | planned | todo |
| FSTWX/FSTWS | 09, bit 22 = 1 | fpm | | planned | todo |
| FLDDX/FLDDS | 0B, bit 22 = 0, uid 0 | fpm | FLDD fr0 waits for the FPU to drain | planned | todo |
| FSTDX/FSTDS | 0B, bit 22 = 1, uid 0 | fpm | FSTD fr0 clears T after storing, never traps 14 | planned | todo |
| CLDx/CSTx uid 2-7 (uid 1 for doubleword) | 09/0B | asst | trap 22 (ISR/IOR set) | planned | todo |
| COPR,0,0 (FID) | 0C, word 0x30000000 | fp | FPSR{10:15} <- model **0x0D**, {16:20} <- revision **0x01** (FPSR = 0x000D0800) (ERS s.7.1; used by PDC_COPROC, FW s.2.2 #7) | planned | todo |
| FCPY,fmt r,t | 0C/0E class 0 sub 2 | fp | no traps, bit copy | planned | todo |
| FABS,fmt | class 0 sub 3 | fp | bit copy, clears sign | planned | todo |
| FSQRT,fmt | class 0 sub 4 | fp | iterative | planned | todo |
| FRND,fmt | class 0 sub 5 | fp | always unimplemented exception (emulated, ERS s.7.2.2) | planned | todo |
| class 0 sub 1, 6, 7 | -- | fp | reserved-op -> unimplemented (PA 2.0 FNEG/FNEGABS) | planned | todo |
| FCNVFF,sf,df | class 1 sub 0 (bits 15:16) | fp | sgl<->dbl; FCNVFF,sgl,sgl = FCPY,sgl, dbl,dbl = FABS,dbl (ERS s.7.2.5) | planned | todo |
| FCNVXF,sf,df | class 1 sub 1 | fp | int32/int64 -> fp | planned | todo |
| FCNVFX,sf,df | class 1 sub 2 | fp | fp -> int, current rounding; overflow always unimplemented | planned | todo |
| FCNVFXT,sf,df | class 1 sub 3 | fp | truncating | planned | todo |
| (class 1 with bit 14 = 1) | -- | fp | PA 2.0 unsigned forms -> unimplemented | planned | todo |
| FCMP,cond,fmt r1,r2 | class 2 sub 0 | fp | 5-bit cond (ACD table 6-13); shifts C into the compare queue CQ (FPSR{10:20}, ERS s.7.4.3) | planned | todo |
| FTEST[,acc/acc8/acc6/acc4/acc2/rej/rej8] | 0C class 2 sub 1, cond 27:31 = 00/01/05/09/0D/11/02/06 | fp | nullifies next on the ERS s.7.4.3 condition; other conds reserved -> unimplemented | planned | todo |
| class 2 sub 2-7 | -- | fp | reserved-op | planned | todo |
| FADD,fmt r1,r2,t | class 3 sub 0 | fp | | planned | todo |
| FSUB | class 3 sub 1 | fp | | planned | todo |
| FMPY | class 3 sub 2 | fp | 4-DSP multiplier | planned | todo |
| FDIV | class 3 sub 3 | fp | iterative | planned | todo |
| class 3 sub 4-7; 0E fmt 11; 0E non-XMPYU with bit 23 | -- | fp | reserved-op | planned | todo |
| XMPYU r1,r2,t | 0E class 3 sub 2, bit 23 = 1, bit 20 = 0 | fp | 32x32 -> 64 unsigned on the FP multiplier (integer multiply on PA 1.1); bit 20 = 1 reserved-op | planned | todo |
| FMPYADD,fmt rm1,rm2,tm,ra,ta | 06 (bit 26: 0 dbl, 1 sgl) | fp | two independent ops (multiply, add), done in sequence; a trapping half -> whole instruction unimplemented, neither result written (ERS s.7.3) | planned | todo |
| FMPYSUB | 26 | fp | | planned | todo |
| FMPYCFXT,fmt rm1,rm2,tm ta | 06 with ra (bits 16:20) = 0 | fp | PCX-L: tm = rm1 x rm2; ta = FCNVFXT(ta) to int32 (dbl: in ta's MSW) (ERS s.7.4.2); sgl undefined if fr16L != 0 | planned | todo |
| PMDIS/PMENB | 0C uid 2 | asst | trap 22 (no performance monitor; HP-UX uses it only if the CCR bit is set, R06 s.3.7) | planned | todo |
| other COPR uid != 0 | 0C | asst | trap 22 | planned | todo |

FP loads/stores to I/O space are **defined** on PCX-L (word and doubleword,
ERS s.2.1.5) -- the uncached port carries 8-byte transfers for them.

---
## 5. Implementation-specific behaviour the ROM and the OSes depend on

### 5.1 Diagnose registers (ERS s.8.2; HW s.8.1-8.2; BOOT s.4)

DRs not listed (2-7, 9-23, 30, 31) do not exist: MFCPU returns 0, MTCPU is
ignored. Both MFCPU flavours read any DR (**ours**; the ERS reserves _C for
DR0/8 and _T for DR25/27-29 and calls DR1/24/26 unreadable -- P-018).

**DR0** (reset **0x00000200**: rev 0, error flags clear, DUAL_DIS = 01 (bit 22 = 1, ERS "powers up to zero except [22] = 1"))

| Bits | Name | Access | Ours | Used by |
|---|---|---|---|---|
| 0:5 | revision | r | `CPU_REVISION` parameter, **2** (Q3 decided 2026-10-07; `set_dr0` touches nothing at rev 2..0xA, rev 1 would clear ISTRM_EN) | five ROM consumers (review 07 s.1.1): `set_dr0` (SOU/ISTRM/DUAL_DIS fix-ups), selftest2 (test 0x4108D runs unless rev 0 -- or the ROM word at offset 0xB810 is patched), MIOC control bit 14, `pdc_soft_power` (returns without writing at rev 0), `pdc_model_versions` (the real 715/64 reports **0xC**). HP-UX 10.20: rev < 0xC -> `normal_gate = 0`, every syscall through trap 7 (review 07 s.1.3) |
| 6 | L2IHPMC | r / W1C | set on any L2-I parity error (fetch hit, RI2D/RI2T) | HPMC classifier, 0x42095 |
| 7 | L2IHPMC_DIS | r/w | masks (holds pending) the L2-I HPMC | |
| 8 | L2DHPMC | r / W1C | L2-D parity error (load/store hit, walker read, RDD/RDT) | |
| 9 | L2DHPMC_DIS | r/w | | |
| 10 | L1IHPMC | r / W1C | L1 parity error (fetch hit, RI1, WI1 with a seeded bit) | |
| 11 | L1IHPMC_DIS | r/w | | |
| 12:15 | L2PARERR | r / W1C | per tree: 12 even data word, 13 odd data word, 14 tag, 15 dirty | |
| 16 | STORE[0] | r/w | scratch (ROM: "inside HPMC/TOC handler") | |
| 17 | PF_MASK | r/w | stored (no power fail, P-014) | |
| 18 | STORE[1] | r/w | scratch (ROM: "HPMC expected") | probes |
| 19 | FAST_MODE | r | 0 | |
| 20 | ISTRM_EN | r/w | stored, no effect (P-013) | |
| 21:22 | DUAL_DIS | r/w | stored, no effect (always single issue) | |
| 23 | ENDIAN | r/w | copied to PSW.E on interruption; no other effect (P-011); PDC_PSW reads/writes it (FW #21) | |
| (DR25 bit 0) | POWFAIL / soft-power | r | `pa_cpu` input `soft_pwr_n` (1 = button not pressed, reset 1), sampled every cycle; **HP-UX 10.20 polls it at 4 Hz** (`getCPU25_PCXL`, MFCPU_T 0x1720141C) and Linux at 1 Hz at rev != 0: 0 for two polls = clean shutdown (review 07 s.1.4; cpu-requests #1) | |
| 24 | SOU_EN | r/w | stored, no effect | |
| 25 | SHINT_EN | r/w | stored, no effect (store hints ignored) | |
| 26 | IPREF_EN | r/w | stored, no effect | |
| 27 | DHASH_EN | r/w | **effective**: space hash of the L2-D index in virtual mode (sec. 2.7); Linux clears it (L pacache.S:1316-1321) | |
| 28 | IHASH_EN | r/w | **effective**, I side | |
| 29 | L1ICACHE_EN | r/w | **effective**: L1 used and filled only when 1; "takes effect for the next fetch" (BOOT 0x42094) | |
| 30 | HIT | r | latched by RDD/RDT/RI2D/RI2T/RDTLB: tag RPN == address RPN (RDTLB: translated) | 0x42094, 0x42099 |
| 31 | PARERR | r | latched by every diagnose cache read (L1 or L2): parity mismatch in what was read | 0x42095 |

Write rules: W1C bits clear where GR = 1, unchanged where 0; read-only bits
ignore writes. ROM 0x41080 checks (pattern & 0x0150EFFC) == (readback &
0x0150EFFC) for 0xABFAAAAA, 0x55555555, 0x01500000, 0xFFFFFFFF -- i.e. bits 7,
9, 11, 16-18, 20-29 store exactly; the patterns flip hashing, L1 enable and
ENDIAN while running from ROM (I/O space, real mode), which has no effect on
uncached fetches.

**DR1**: write sets the CR16 **counter** (MTCTL CR16 sets the compare). The
timer test writes compare - 0x100, 0xFFFFFF00 with compare 0, and spins with
no timeout (BOOT s.4.2 0x4108C).

**DR8**: sec. 2.4.

**DR24** (ERS s.8.2.4): bits 0:19 walker table base (bits 20:31 masked off for
the address), 24:31 DCACHE_SIZE stored, no effect (P-013; ROM writes 0xE0 =
128 KB). Reset 0.

**DR25** (ERS s.8.2.5, s.6.7.4): bit 0 POWFAIL reads **1** (power good; HP-UX
polls it as the power switch only if PDC_SOFT_POWER reported no status
register, R06 s.3.1), 7:19 walker mask (w), 24:26 FP_DELAY (r/w, no effect),
28 I (ITLB walker disable), 29 U, 30 N, 31 D (DTLB walker disable). Readable
bits: 0, 24:26, 28:31 (ours also 7:19). Reset **0x80000009**.

**DR26**: debug configuration -- writes ignored, reads 0 (P-015).

**DR27/DR28/DR29** (ERS s.8.2.7-8.2.9): each is a write latch (MTCPU, consumed
by WI1) and a separate read latch (filled by RI1, read by MFCPU_T). DR27 = even
(high) instruction word, DR28 = odd word, DR29 = {FPDATA 0, FPTAG 1, STEER[0:7]
2:9, RPN 10:29, QPAGE 30:31}. Parity: on WI1 the stored parity = even parity of
the written bits XOR the written FPDATA/FPTAG bit (seeding); RI1 returns the
stored parity bits, sets DR0.PARERR if either check fails (BOOT 0x42090:
"read back as XOR(written bits) ^ written parity bit"). Hardware L1 fills
write STEER = a constant (P-012), compute both parities, RPN, QPAGE.

### 5.2 Interval timer (CR16) and the fractional tick generator

| Requirement | Source |
|---|---|
| CR16 counts at the board clock: page0 MEM_10MSEC = 640000 / 800000 / 1000000 for 64 / 80 / 100 MHz (strap at 0xF00FFFFC bits 4:7) and both OSes take HZ and their clocksource from it | BOOT s.5; R06 s.3.6; L time.c |
| MTCTL CR16 writes the compare; a match sets **EIRR bit 0** (0x80000000) | ACD p.2-15; HW s.9 |
| A spurious match during setup hangs ROM test 0x4108C | BOOT s.4.2 |
| ROM delays scale with the strap, not with measured speed | BOOT s.5 |

Generator (in `pa_cr16`), inputs from the board model and the core clock:
`TQ` (integer ticks/clock), `TR` (remainder), `TD` (denominator), all 16-bit,
with f_board / f_cpu = TQ + TR/TD exactly.

```
every clk:  s   = acc + TR
            c   = (s >= TD)
            inc = TQ + c                 // 1 or 2 for 64/50; 0..3 allowed
            acc = c ? s - TD : s
            old = counter; counter = old + inc
            if inc != 0 and ((compare - old - 1) mod 2^32) < inc:   // compare in (old, old+inc]
                EIRR[0] = 1
DR1 write:  counter = GR (no match check); MTCTL CR16: compare = GR (no match check)
```

| Board model | f_board | core 50 MHz: TQ, TR, TD | ticks per 50 clocks |
|---|---|---|---|
| 715/64 | 64 MHz | 1, 14, 50 | 64 |
| 715/80 | 80 MHz | 1, 30, 50 | 80 |
| 715/100 | 100 MHz | 2, 0, 50 | 100 |

If the PLL's actual core frequency is not exactly 50.000 MHz, TD/TR come from
the exact rational ratio (16 bits is enough for any MiSTer PLL setting). The
real chip counts one tick per CPU cycle; ours steps by 1-2 (P-016). CR16 is
readable at PL != 0 only when PSW.S = 0.

### 5.3 External interrupts, EIR, TOC command

| Item | Behaviour | Source |
|---|---|---|
| IO_EIR = CPU_HPA + 0 (0xFFFBE000), and broadcast EIR | a 32-bit write of n (low 5 bits) from **any** bus master (LASI's interrupt transaction, the CPU's own store -- HP-UX `setsoftnet` stores 25) sets EIRR bit n (PA numbering: 0x80000000 >> n); decoded by the system bus, delivered as `eir_set`/`eir_num` | HW s.2; R06 s.3.5 |
| Latency | taken within <= 3 instructions after `ssm I` with a request pending; visible in EIRR within ~10 instructions of the store | BOOT s.4.2 0x4108C, 0x410D1 |
| Taking | PSW.I = 1 and (EIRR & EIEM) != 0 -> trap 4 at the next boundary | ACD p.2-17 |
| EIRR write | MTCTL CR23 clears the bits set in GR (W1C); writing -1 reads back 0 (0x410D1) | |
| LASI power-up IAR 0xFFFBE003 | LASI uses EIRR bit 3 (ROM's PS/2 loopback check, silent halt if missing) | BOOT s.2.3 |
| IO_COMMAND = CPU_HPA + 0x30 | write of 5 -> TOC (system pulses `toc_req` and sets MIOC status bit 27); other values ignored | HW s.2; BOOT 0x410D2 |
| CPU HPA reads | must answer (PDC_ADD_VALID probes HPAs) -- system bus's job, no CPU register behind them | FW s.2.2 #12 |

### 5.4 L2 cache diagnose formats (ERS s.8.3.4-8.3.6; BOOT s.4.3)

Tag word (RDT/RI2T read, SET_TAG source):

| Bits | Field | Stored | Notes |
|---|---|---|---|
| 0:19 | RPN | per line | "invalid" = 0xF0000 (I/O space, never matches: the cache is never looked up for I/O addresses) |
| 20 | dirty | per line | set by stores/LDCW in cache |
| 21 | dirty parity | per line | **odd** (= ~dirty); always taken from GR on SET_TAG |
| 22 | tag parity | per line | even over RPN |
| 23 | data parity 0 | per word (data RAM) | even word of the addressed doubleword |
| 24 | data parity 1 | per word | odd word |
| 25 | Arb enable | SET_TAG only | 1: bits 22-24 come from GR (bit 23/24: the word last written by WDD/WI2D, even -> 23, odd -> 24); 0: computed. Reads return 0 |
| 26:31 | unused | -- | read 0 |

* RDD/RI2D/WDD/WI2D: word address GR[b]{15:29}; RDT/RI2T/WDT/WI2T: doubleword
  address, tag of line GR[b]{15:26}. Real addresses, no hashing (RDTLB
  excepted).
* WDD/WI2D write the RAM immediately with computed parity (the real chip
  holds the last one in its store buffer until SET_TAG/WDT -- P-018);
  WDT/WI2T write {RPN, D, Dpar, Tpar} and, with Arb = 1, rewrite the parity
  bit of the last WDD/WI2D word. The ROM always uses WxD, SET_TAG, WxT (BOOT
  s.4.5 `l2ic_load`: tag = page | 0x400 = dirty parity 1, Arb 0).
* Reads compute HIT and PARERR into DR0 and set L2IHPMC/L2DHPMC + L2PARERR on
  a mismatch; the error then raises an HPMC unless masked (DR0 7/9) or PSW.M.
* Hardware fills write tag {RPN, D = 0, Dpar = 1, Tpar}, data with computed
  parity; RI2T/RI2D after an I-miss fill must show them (BOOT 0x42099); RDT
  after a store shows dirty = 1 (0x4209A).
* Lines planted by diagnose writes **serve real loads and fetches by tag
  match alone** with no memory behind them: no refill while the tag matches,
  no next-line prefetch, no speculative bus access (BOOT s.4.5, HW s.8.3).
* Reset/FPGA initialisation: every tag = 0xF0000400 + correct tag parity
  (= the ROM's own "invalid" tag, BOOT 0x42096), data 0. Real silicon powers
  up with garbage; the ROM initialises the caches before using them.

### 5.5 Cache maintenance semantics (ACD p.5-169..5-174; R06 s.3.4)

| Instruction | L2-D | L2-I / L1-I | Notes |
|---|---|---|---|
| FDC x(s,b) | if the line at the (hashed) VA index has tag == translated RPN: write back if dirty, invalidate | -- | NA miss 17 when D = 1 |
| FDCE x(s,b) | line at index VA[15:26] (no hash, no translation): write back if dirty, invalidate | -- | 4096 strided calls (PDC_CACHE: base 0, stride 32, count 4096, loop 1) clear the cache |
| PDC x(s,b) | as FDC but PL 0: invalidate **without** write-back | -- | needs write rights; HP-UX on PCX-L does not purge after inbound DMA (R06 s.3.4) |
| FIC x(sr,b) | -- | invalidate the L2-I line if its tag matches and the 4 L1 entries of that line (writes RPN 0xF0000) | translation through the UTLB with PSW.D, NA miss 17 |
| FICE x(sr,b) | -- | L2-I line at index VA[15:26] + its 4 L1 entries | |
| SYNC / SYNCDMA | wait until the BIU is idle (uncached store buffer, write-backs) | | ROM brackets every diag sequence with SYNC |

Flush effects are visible "two instructions later" at the latest (BOOT
0x42097); ours are complete when the instruction commits. ROM `flush_caches`
runs FICE + FDCE over 128 KB before the IPL (BOOT s.2.10).

### 5.6 CPU identity

| Item | Value | Where it comes from |
|---|---|---|
| HVERSION 0x60A (715/64), 0x619 / 0x60B for 715/80/100 | PDC_MODEL info from the EEPROM HV area | ROM/EEPROM, not a CPU register (FW s.2.2 #4) |
| PDC_MODEL CPU_ID | fails on a 715 | PDC (715_64.h:36); HP-UX then counts BTLB slots: **8 -> PCX-L** (R06 s.3.1) |
| CPU revision | DR0[0:5] (= 2) -> PDC_MODEL versions | sec. 5.1, Q3 |
| FP model/revision | 0x0D / 0x01 via COPR,0,0 | ERS s.7.1; PDC_COPROC |
| Linux | hversion >> 4 in 0x600-0x61F -> pcxl (L hardware.c:1303) | PDC |

The CPU itself has no HVERSION register; the CPU HPA page's IODC/HVERSION
answers come from PDC tables.

### 5.7 LDCW / LDCWS semantics (ACD p.5-40; ERS s.2.2.5; R06 s.3.2; BOOT 0x410D4)

| Case | Action |
|---|---|
| cache hint cc != 0 (HP-UX patches its LDCWs with one) | in the D-cache: write-allocate on miss, GR[t] <- word, word <- 0, line dirty |
| cc = 0, line present and dirty | same, in the cache |
| cc = 0, line absent or clean (Linux's plain `ldcw`) | invalidate the clean line if present, then an atomic **read-and-clear of the word in memory** (`io_rclr` on the uncached port); the line is not re-fetched |
| U = 1 page or I/O space | atomic read-and-clear transaction on the uncached port |
| address not 16-byte aligned | undefined (ACD); ours: word-aligned -> operate on that word, no trap; not word-aligned -> trap 28 (sec. 8.2) |

ROM 0x410D4 checks dirty -> B then 0, clean -> A then 0, absent -> B then 0.

### 5.8 Uncacheable accesses

Data accesses to I/O space (PA >= 0xF0000000) or to a page with U = 1 go out
on the uncached port as single transfers of 1, 2, 4 or 8 bytes (8 for
FLDD/FSTD, ERS s.2.1.5), in program order, never merged; STBYS sends one
transfer with byte enables. Instruction fetches from I/O space (the ROM at
0xF0000000) are uncached reads, issued only on the architectural path (sec.
6.5) and served through a one-line uncached fetch buffer.

---
## 6. Microarchitecture

### 6.1 Pipeline

Five stages, one instruction per stage, commit in W. The real PCX-L is
F-I-B-A-R with two-phase clocking and dual issue (ERS s.5.1-5.2); ours is a
single-phase classic pipeline with the same hazard profile (1-cycle load-use,
1-cycle mispredict, interlocks on system-state writes).

```
          F                D                 E                  M                   W
  next-PC mux ->   I-cache data/tag  ->  decode, GR read ->  ALU/shift/MAX-1  ->  UTLB CAM + block  ->  commit / trap
  (L1+L2-I M10K    + I-LAB compare     PC-rel target       conditions:          D-cache tag+data     GR write (2 ports)
   address regs)   + L1/L2/UIB select  static prediction   nullify, branch      (VIPT, same cycle)   store -> D RAM
                   + parity            interlocks          resolve, AGU ->      protection, align    CR/SR/PSW/DR writes
                                                           D-cache/TLB addr     load align/extend    replay, interrupts
```

| Stage | Work | Produces |
|---|---|---|
| F | the next-PC mux (end of the previous cycle) drives the M10K address registers of L1-I and L2-I; this cycle: RAM read, L1/L2 tag compare against the I-LAB RPN (or the real address), select L1 > L2 > uncached buffer, parity check, I-LAB VPN check, execute-rights check result | IR, iaoq_f/b, iasq_f/b, fetch flags (ITLB miss, IMP, parity) |
| D | full decode to a control word; GR read (2 async MLAB ports + shadowed-GR flip-flops); immediate assembly; PC-relative target adder (IAOQ_F + 8 + disp); static prediction -> fetch redirect; interlock checks (load-use, system-state, FP scoreboard, SR use after MTSP) | D/E register |
| E | operand forwarding from M and W; ALU, shifter, MAX-1; condition evaluation -> nullify-next / branch taken; mispredict and GR-based branch (BV/BE/BLE/BLR) redirect; AGU: offset, base-modify value, space select, hash, D-cache/TLB address registered at the end of E; MFCTL/MFSP/LDSID/MFCPU reads of committed state; FP op issue | E/M register |
| M | UTLB CAM (64 page + 8 block compare) -> encoded hit -> payload MLAB (RPN, AR, AID, flags); D-cache tag + data read (M10K, VIPT, address registered at end of E); tag compare with RPN (or real address); protection/alignment/T/D/B checks; parity; load align/sign-extend; store merge data; PROBE/LPA result | M/W register with hit/miss/trap flags |
| W | priority-select interruption (group 4 pending, HPMC/TOC, group 2, group 3 from the instruction's flags); else commit: GR writes (target + base modify), store data/tag write to the D-cache RAMs, CR/SR/PSW/DR updates, EIRR, recovery counter; or start a W-operation (below) | architectural state |

### 6.2 IAOQ, branches, nullification

* **Every instruction carries (iaoq_f, iaoq_b, iasq_f, iasq_b)** from fetch to
  W. The fetch unit keeps (pc_f, pc_b): fetching pc_f tags the instruction with
  (pc_f, pc_b) and then sets pc_f <- pc_b, pc_b <- pc_b + 4.
* **A taken branch X with target T** redirects "the instruction after X":
  if X's successor (the delay slot) is already fetched, its iaoq_b is patched
  to T, everything younger than it is killed and the fetch state becomes
  (T, T + 4); if it is not fetched yet, only pc_b <- T. This one rule covers
  branches in delay slots (ACD fig 4-4, ROM 0x41081/0x41082), RFI (state <-
  (IIAOQ front, IIAOQ back)) and interruptions (state <- (vector, vector + 4)).
* **Static prediction** (as the real chip, ERS s.4.3/s.5.3.7): in D,
  PC-relative conditional branches with negative displacement and BL/GATE
  redirect fetch to the target; forward conditional branches fall through.
  E resolves; a misprediction kills the one younger fetched instruction
  (1 bubble). BV, BE, BLE, BLR redirect from E (1 bubble).
* **Nullification**: E computes "nullify next" (ALU conditions, branch ,n
  rules: forward taken / backward not taken, unconditional ,n always; ACD
  p.4-11). The flag attaches to the next valid instruction in program order
  (patched into D/E if present, else held until one arrives). A nullified
  instruction flows to W as a no-op: it advances IAOQ, clears PSW X/B, never
  nullifies its own successor, does not decrement RCTR,
  takes no group 3 trap, but can be preceded by a group 2/4 interruption
  with IPSW.N = 1. Committed PSW.N is restored into the "nullify next" state
  after RFI and after any flush.
* **PSW.B** of an instruction = "the previous instruction was a taken branch"
  (forwarded from the instruction ahead); GATE with B = 1 -> trap 8.
* **Privilege** comes from iaoq_f{30:31}; W compares the committing
  instruction's PL with its iaoq_b PL to raise group 4 traps 23/24 (not after
  RFI), and a taken branch with PSW.T arms trap 25 for the next instruction.

### 6.3 Hazards and forwarding

| Producer (in M or W) -> consumer in E | Bubbles | Mechanism |
|---|---|---|
| ALU/shift/AGU base-modify/MFCTL/MFSP result | 0 | forward from E/M and M/W registers |
| load, LPA, PROBE, RDD/RDT/RI2x, MFCPU_T (result at end of M) | **1** (load-use, as the real chip, ERS s.5.3.9) | interlock in D |
| PSW C/B, V (ADDC, SUBB, DS, DCOR, IDCOR) | 0 | speculative C/B/V forwarded with the result |
| SAR (MTCTL CR11) -> variable shift/extract/BVB | 0 | forwarded like a GR (ERS s.5.2: CR11 set early) |
| MTSP -> any SR user (memory ops, BE/BLE, MFSP, LDSID) | up to 2 | interlock until MTSP commits |
| MTCTL (other CRs), MTCPU, SSM/RSM/MTSM, DIAG, TLB/cache ops, RFI | -- | "serialising": commit in W, then flush younger instructions and refetch at iaoq_b (ERS s.5.3.9 interlocks + s.5.3.11 LAB updates) |
| store in W / W+1 -> load in M, same doubleword | 0 | store-to-load forwarding window of 2 cycles (the M10K returns old data on read-during-write) |
| store in W -> store in M, same doubleword | 0 | merge from the forwarded data (stores are read-merge-write) |
| FP register busy (scoreboard) / FPU busy / FCMP pending for FTEST | n | stall in D |

### 6.4 General registers and shadows

* GR1, 8, 9, 16, 17, 24, 25 live in **flip-flops** (with their 7 shadow
  flip-flop registers beside them), so interruption capture, RFIR, GR_SHDW and
  SHDW_GR are single-cycle parallel copies.
* The other 24 GRs live in **MLAB** LUT-RAM with asynchronous read (the Indy
  core's `RamMLAB` pattern, Quartus 17.0 needs `ramstyle = "MLAB, no_rw_check"`),
  arranged **2 write x 2 read**: two banks (one per write port) x two read
  copies + a 32-bit live-value table. Write port 0: result/load target; write
  port 1: base-register modification (loads/stores with ,m/,ma/,mb, LDWM/STWM,
  PDC/FDC/FIC ,m). Both write in W, so commit stays atomic.
* W-to-D same-cycle write-through bypass (MLAB returns old data).

### 6.5 Fetch side

| Item | Design |
|---|---|
| L2-I | 128 KB: data 16K x 66 bits (2 words + 2 parity), tag 4K x 23 bits; M10K simple dual-port (read = fetch / diagnose read, write = fill / WI2x) |
| L1-I | 128 entries x {2 words, STEER, RPN, QPAGE, 2 parity}, M10K; read in parallel with L2-I every fetch; **L1 hit (enabled, RPN and QPAGE match, parity) overrides L2**; on L1 miss + L2 hit the doubleword is written into L1 (when L1ICACHE_EN) |
| Index | VA (hashed with IASQ when IHASH_EN and PSW.C); tag compare against the I-LAB RPN (virtual) or PA (real) |
| I-LAB | 1 entry (ERS s.6.4); refill uses the UTLB lookup port in a cycle when M is not using it (M has priority); costs 1-2 bubbles on a page or space change, like the real "seqhang" |
| I/O-space fetch | PA >= 0xF0000000 bypasses both caches; a **one-line uncached fetch buffer (UIB)** holds the last 32-byte burst read from I/O space (the ROM runs from there for minutes); invalidated by SYNC, FIC/FICE and any uncached store into its line |
| Misses | **non-speculative**: an L1/L2/UIB miss (or ITLB miss) waits until every older instruction has committed before any bus transaction (or walk) starts -- wrong-path fetches never touch memory or I/O. The ROM depends on this: code planted at PA 0 runs before memory exists, and a stray fill to unconfigured memory would HPMC (BOOT s.4.5) |
| Fill | 32-byte line via the BIU; the fetch resumes when the line is written (critical-word restart is a later optimisation) |
| ITLB miss / IMP | the fetched slot is marked and travels to W, where the walker runs or the trap is taken |

### 6.6 Data side

| Item | Design |
|---|---|
| L2-D | 128 KB: data 16K x 66 bits, tag 4K x 23 bits, M10K simple dual-port; read port in M (and for write-back/diagnose reads while frozen), write port at the end of W (stores, fills, diagnose) |
| Lookup | VIPT: index from the VA registered at the end of E; the UTLB CAM and payload MLAB run in the same M cycle; tag compare with the payload RPN. Real mode: PA = VA, the TLB is not used |
| Stores | read-merge-write of a whole doubleword in W (the merge data and the line's dirty state come from the M read); byte-lane writes are therefore never needed, parity is regenerated per word, and STB/STH/STBY need no byte enables (2K x 5 M10K slices have none) |
| Misses | registered in M, acted on in W: **replay**. W writes back the victim if dirty, fills the line (write-allocate for stores; no store hints), then flushes the pipeline and refetches the missing instruction itself, which now hits. Only one miss outstanding. (The real chip's stall-on-use is a later optimisation, P-016) |
| Uncached loads/stores | issued from W (non-speculative), in order. Loads stall W until `io_ack`; stores go into a **one-entry uncached store buffer** and W continues; any later uncached access, line transaction or SYNC waits for it to drain |
| TLB miss | W runs the walker (if enabled) using the D-cache read port and the BIU, inserts, then replays; or traps |
| Multi-cycle W ops | TLB insert/purge, DIAG cache/L1 ops, FDC/FDCE/PDC with write-back, FIC/FICE (4 L1 entries), LDCW memory RMW: W holds, the operation completes, younger instructions are flushed and refetched |
| Ordering | one in-order queue of external transactions (strong ordering, ACD p.4-3); D-side writes never touch the I-caches |

### 6.7 Commit and interruptions in W

Per cycle W checks, in this order: pending group 4 trap for this instruction
-> HPMC/TOC (`hpmc_req` & ~M, precise error flag on this instruction, DR0
parity flags & ~mask & ~M; TOC pending & ~TOC mask) -> group 2 (power fail
never, recovery counter, external interrupt, LPMC; masked by I, and R for 3) ->
group 3 flags carried by the instruction (fetch flags, decode flags, E flags
(12, 13), M flags (15-28)). The winner performs the entry sequence of
sec. 3.2 in one cycle (IPSW, PSW, IIAQ, IPRs, shadows) and redirects fetch;
everything younger is killed. Because W is the only place where architectural
state changes, every interruption is precise; the IIA queues are exactly the
iaoq_f/iaoq_b the instruction carries.

### 6.8 External interfaces (`pa_cpu`)

All synchronous to `clk`; valid/ready style; the MIOC/system block handles any
clock crossing, the memory map, MIOC registers and the CPU HPA page.

| Signal | Dir | Width | Meaning |
|---|---|---|---|
| clk, rst_n | in | 1 | CPU clock (50 MHz), synchronous reset (power-on and broadcast reset) |
| cfg_tq, cfg_tr, cfg_td | in | 16 each | CR16 ratio (sec. 5.2), from the OSD model setting |
| **Cacheable line port** ||||
| mem_req | out | 1 | request; held until mem_ack |
| mem_we | out | 1 | 1 = write-back of a 32-byte line, 0 = fill |
| mem_addr | out | 32 | PA; fill: critical doubleword address; write-back: line base |
| mem_ifill | out | 1 | fill for the I-cache (priority/statistics) |
| mem_ack | in | 1 | request accepted |
| mem_wdata, mem_wvalid / mem_wready | out / in | 64, 1/1 | 4 write-back beats in address order |
| mem_rdata, mem_rvalid, mem_rbeat | in | 64, 1, 2 | 4 fill beats, critical doubleword first, wrapping; rbeat = doubleword index |
| mem_rerr | in | 1 | fill error (unconfigured address, multi-bit ECC); the MIOC also latches its status |
| **Uncached port** ||||
| io_req, io_we | out | 1, 1 | request held until io_ack |
| io_addr | out | 32 | byte address |
| io_be | out | 8 | byte enables over the aligned doubleword, io_be[7] = byte offset 0 (big-endian lanes) |
| io_wdata | out | 64 | byte offset 0 in bits [63:56] |
| io_ifetch, io_burst | out | 1, 1 | instruction fetch; 32-byte aligned 4-beat read (I/O-space code only) |
| io_rclr | out | 1 | atomic read-and-clear of a word (LDCW) |
| io_ack, io_last | in | 1, 1 | transfer (beat) complete; last beat of a burst. A write may be acked early (posted) at the system's discretion |
| io_rdata | in | 64 | read data |
| io_err | in | 1 | bus error / no responder with this ack -> HPMC on the instruction |
| **Interrupts** ||||
| eir_set, eir_num | in | 1, 5 | an IO_EIR write of eir_num by any master |
| toc_req | in | 1 | pulse: TOC (IO_COMMAND = 5, TOC button) |
| hpmc_req | in | 1 | level: asserted while the MIOC status holds an HPMC-class error (also the ones reported with io_err/mem_rerr), until software writes the status back; the HPMC sets PSW.M, so a precise error and the level never cause two HPMCs |
| lpmc_req | in | 1 | level: LPMC request |
| powerfail | in | 1 | tie 0 (DR25.POWFAIL = ~powerfail) |
| **Debug taps (simulator, beacons)** ||||
| dbg_retire, dbg_nullified | out | 1, 1 | an instruction left W (nullified ones too) |
| dbg_iaoq_f, dbg_iaoq_b, dbg_iasq_f | out | 32, 32, 16 | of the retiring instruction (IAOQ front/back) |
| dbg_insn | out | 32 | its word |
| dbg_trap, dbg_trap_vec | out | 1, 6 | interruption taken (vector 1-31, 32 = TOC) |
| dbg_gr_we, dbg_gr_num, dbg_gr_data | out | 2, 2x5, 2x32 | the two GR write ports |
| dbg_mem_* | out | -- | committed data access: PA, size, we, data |
| dbg_psw | out | 32 | committed PSW |
| dbg_halted | out | 1 | a branch-to-self loop is committing with no way out (PSW.I = 0 or EIEM & EIRR-able = 0, no HPMC/TOC pending) -- e.g. the ROM's `halt_forever` (`sync; diag TOC_EN; b .`, BOOT s.2.1) |
| dbg_perf | out | n x 32 | counters: cycles, retired, F/D/E/W stall cycles by cause, I/D fills, write-backs, uncached ops, TLB walks (the Indy core's lesson, `SGIIndy_MiSTer/docs/design/cpu-speed-tlb-icache.md`) |

### 6.9 Clock target and timing

**Target 64 MHz** (15.6 ns, the real 715/64's clock; user decision
2026-10-07). Measured fits are logged in `cpu-timing.md`: the sequential core
51.6 MHz, the pipelined core without caches 72.5 MHz with the E-stage
branch-resolve -> next-PC path on top. The fetch is split into F1 (RAM
access) and F2 (tag compare / select) so the I-cache M10Ks keep their output
registers; the costs are in cpu-timing.md 2.1. CR16 is decoupled from the
core clock either way (sec. 5.2). Paths to watch:

| Path | Estimate | Mitigation if it fails |
|---|---|---|
| E branch resolve -> next-PC mux -> I-cache M10K address register | forward mux + 32-bit compare + mux, ~14 ns | register the redirect (+1 mispredict bubble) |
| M: CAM compare (36-bit, 64 entries) -> 64:6 encode -> payload MLAB -> 20-bit tag compare -> hit | ~12-14 ns | the hit is only registered (misses act in W, no same-cycle stall fan-out); fall back to one-hot payload flip-flops |
| D: L1/L2 select (in F) ... GR MLAB read -> forwarding | ~10 ns | -- |
| M10K 2K-deep slices: 8:1 output mux on the 16K-deep arrays | +2 ns | enable output registers and move the compare to W (adds a load-use bubble) |
| FPU normalise/round | multi-cycle by design | add a stage |

### 6.10 Module breakdown and resource estimate

Estimates from the Indy core's measured numbers and component counts;
expect +-25 %. M10K assume 2K x 5 packing (`maximum_depth = 2048`) for the
deep arrays.

| Module (rtl/cpu/) | Function | Talks to | ALMs | M10K | DSP |
|---|---|---|---:|---:|---:|
| `pa_pkg.sv` | types: decoded control word, trap codes, PSW struct, DIAG/opcode constants | all | 0 | 0 | 0 |
| `pa_cpu.sv` | top level, external ports (6.8) | system | 50 | 0 | 0 |
| `pa_core.sv` | pipeline registers, hazards, forwarding, kill/replay, commit, interruption sequencer, PSW, IAQ/IIAQ, group-4 logic, debug taps + perf counters | everything | 1250 | 0 | 0 |
| `pa_fetch.sv` | pc_f/pc_b, next-PC mux, prediction, I-LAB, UIB, non-speculative miss gate | core, icache, tlb, biu | 550 | 0 | 0 |
| `pa_icache.sv` | L1-I + L2-I arrays, hit/parity, fills, FIC/FICE, RI1/WI1/RI2x/WI2x | fetch, biu, diag | 350 | 125 | 0 |
| `pa_decode.sv` | word -> control word, trap 8/10 classification, condition fields | core | 700 | 0 | 0 |
| `pa_regfile.sv` | GR 2R2W (MLAB + FF), shadows | core | 450 | 0 | 0 |
| `pa_alu.sv` | add/sub/logical/unit, digit carries, conditions, DS, DCOR/IDCOR, overflow, MAX-1 | core | 750 | 0 | 0 |
| `pa_shift.sv` | SHD/VSHD, EXTRU/S, DEP/ZDEP/DEPI (fixed + SAR), BB/BVB bit select | core | 400 | 0 | 0 |
| `pa_agu.sv` | offset, base modify, space select, cache-index hash, alignment check | core | 200 | 0 | 0 |
| `pa_csr.sv` | CR0-31, SR0-7, EIRR/EIEM, PID compare, MFCTL/MFSP mux, interrupt-pending | core, cr16, tlb | 700 | 0 | 0 |
| `pa_cr16.sv` | counter, compare, fractional generator, range match | csr | 120 | 0 | 0 |
| `pa_tlb.sv` | 64-entry CAM, 8 block entries, payload MLAB, DR8, replacement/lock, protection checks, PROBE/LPA, I-LAB refill port | core, fetch, hwalk | 1600 | 0 | 0 |
| `pa_hwalk.sv` | walker FSM, hash, CR28 rule | core, dcache, tlb, diag | 200 | 0 | 0 |
| `pa_dcache.sv` | L2-D arrays, hit/parity, store merge, LDCW, flush/purge, RDD/RDT/WDD/WDT/SET_TAG/RDTLB | core, tlb, biu, hwalk | 650 | 122 | 0 |
| `pa_biu.sv` | arbitration, line buffers (MLAB), uncached store buffer, port protocol | icache, dcache, fetch, core | 400 | 0 | 0 |
| `pa_diag.sv` | DR0/1/24/25/26/27-29, TOC mask, DIAG sequencing | core, caches, tlb, cr16 | 300 | 0 | 0 |
| **integer side total** | | | **~8,700** | **247** | **0** |
| `pa_fpu.sv` + `pa_fpu_regs`, `_add`, `_mul`, `_divsqrt`, `_cvt` | sec. 6.11 | core | **~2,300** | 0 | **4** |
| **CPU total** | | | **~11,000** | **~247** | **4** |

For scale: the Indy's R4600 (64-bit, FPU, 16 KB caches) is 9.4k ALMs, 33
M10K, 18 DSP; its whole machine used 393 M10K and the MiSTer framework ~98
(`SGIIndy_MiSTer/reports/summary.md`). With ~247 M10K for the CPU, about 200
remain for Artist, LASI, SCSI and the scaler-side. Fallback if M10K runs
short: 32 KB I + 32 KB D (~65 M10K) with the ROM's own one-word switch
(`cache_size` at 0xF00158E4: `ldil L%0x20000` 0x23900000 -> `ldil L%0x8000`
0x23840000, which the ROM's tests, DR24 and PDC_CACHE all follow, BOOT s.4.3,
rom.dis f00158e0-f00158fc) -- a patched ROM, so only if needed (Q1).

### 6.11 FPU

| Item | Design | Source |
|---|---|---|
| Registers | fr4-fr31 as two 32-bit MLAB halves (L, R), 3 read ports (2 for operations, 1 for FP stores: one MLAB copy per port, every write to all three) and 1 write port (FPU result or FP load: they never coincide while one operation at a time, S-012; the 2-port banks + LVT scheme comes with the overlap); fr0-fr3 (status + 7 exception registers) in flip-flops | ACD p.6-5 |
| Issue | one operation at a time (multi-cycle, not pipelined). **Implemented (2026-10-07, `pa_fpunit`, STUBS S-012):** the operation issues at W commit with its operands read from the FR file in W; any FP instruction waits in D while an FP operation is in E/M/W or in flight (and while an FP load/store of fr0-fr3 is in E/M/W, sec. 3.5), so no scoreboard is needed; the integer pipeline continues. Measured cost (2026-10-07, `dbg_fp_stall` in the cputest harness): 0.15 % of the fp suite's cycles, 0 in integer code -- so the refinement waits for an FP-heavy workload. Planned refinement: issue from E with a per-register busy bit; FLDD/FSTD of fr0-fr3 and COPR wait for the FPU to drain; FTEST waits for a pending FCMP | ACD p.6-27 |
| Unpack/classify | zero, normal, denormal, inf, qNaN, sNaN per operand; **NaN or denormal (D = 0) input -> unimplemented exception immediately** (no compute) | ERS s.7.3 |
| Add/sub/compare/convert | 55-bit alignment shifter, adder, leading-zero count, normaliser, IEEE rounding (4 modes, FPSR.RM); FCNVxx through the same shifters | |
| Multiply | 53x53 from **four 27x27 DSPs**, 2 cycles + normalise/round; XMPYU (32x32 unsigned) on the same array | ERS s.7.5.2: XMPYU uses the MPY unit |
| Divide/sqrt | shared radix-2 digit recurrence, 1 bit per cycle: sgl ~28, dbl ~57 cycles (real chip 8/15, it also stalls on them, ERS s.2.2.10) | |
| Results | overflow/underflow/inexact/invalid/divide-by-zero detected at rounding; trap-enabled -> unimplemented; tiny result with D = 0 -> unimplemented; D = 1: flush to zero and set I if enabled (ERS s.7.4.1); else IEEE default result and flag | ERS s.7.3-7.4 |
| Unimplemented exception | destination and flags untouched, fr1L <- {code, insn{6:31}}, FPSR.T <- 1 | sec. 3.5 |
| Compare | 5-bit FCMP condition; C -> FPSR{5}, queue FPSR{10:20} shifted (ERS s.7.4.3); sNaN input or qNaN with a trapping condition -> unimplemented | |
| FMPYADD/FMPYSUB/FMPYCFXT | multiply then add (or FCNVFXT of ta) as two sequenced steps; if either would trap, neither result is written | ERS s.7.3, s.7.4.2 |
| Latency (ours) | measured 2026-10-07 (`make -C verilator tb_fpu`, `tb_fpu ... -v`), engine start -> done: FCPY/FABS/FCMP 2, FCNVxx 4, FADD/FSUB/FMPY/XMPYU 6, FDIV 60, FSQRT 59 (singles take the full double-length recurrence), FMPYADD/SUB/CFXT = multiply + add + 1; plus 3 cycles in `pa_fpunit` (the operand read cycle, the registered start, done -> idle) during which the next FP instruction waits in D (S-012) | P-016 |

---
## 7. Verification plan hooks

### 7.1 Test ROMs and references

`tests/cpu/` (pacputest) already builds bare-metal PA 1.1 ROMs (suites alu1,
alu2, shift, mem, branch, trap, fp, fpedge, max1), runs them on QEMU `-M 715`
(`ref/qemu/<suite>.log`), and judges logs with `compare.py` against
`model.py`, an independent model written from the ACD/ERS (with documented
QEMU bugs in `model.QEMU_BUGS`). The same ROM images run on the Verilator
model and on the board (UART output). Policy for the CPU: **a vector passes if
it satisfies the manual-derived model; QEMU is a second opinion, not the
reference** (CLAUDE.md "QEMU is not ground truth"). The commit trace from the
debug taps (`dbg_retire`, IAOQ, insn, GR writes, traps, memory accesses) is
the per-instruction diff format for the simulator.

### 7.2 Coverage per instruction class

| Class | Must cover | Expected values from | Suite |
|---|---|---|---|
| ALU (02, 08, 0A, 0D, 24, 25, 2C, 2D) | every op x condition x f; C/B digit map; V for DS; O forms and traps 12/13 (no GR write, C/B unchanged on trap); conditions with target GR0; DCOR/IDCOR sequences (ROM 0x41087 values) | model.py; QEMU except `shadd-uv` | alu1, alu2, trap |
| Shift/extract/deposit | fixed and SAR forms, every pos/len, conditions; ROM 0x41086 SHRPW/EXTR/DEP vectors | model.py, QEMU | shift |
| MAX-1 | 13 ops, saturation edges, **pre-shift overflow precedence** in HSHLADD, HAVG rounding; cf != 0 -> trap 8 | model.py only (QEMU refuses MAX-1 at PA 1.1 and mis-saturates HSHLADD) | max1 |
| Loads/stores | sizes, every completer (pre/post modify, scaled index, base = target), STBYS B/E (ROM 0x42098 values), LDWM/STWM, LDWA/STWA (priv), LDCW in 3 cache states (0x410D4), multi-endian word ops, unaligned -> 28 | model + QEMU (not for LDWx/STWx-endian) | mem, trap |
| Branches | all conditional branches x cond x n x direction (nullification rules), BL/BLR (negative index)/BV/BE/BLE/GATE links with PL bits, branch in delay slot, nullified branches, BB/BVB odd encodings, GATE promotion and GATE-after-taken-branch trap 8 | model; QEMU except BB odd words; ROM 0x41081/0x41082 values | branch |
| System | every CR read/write with the bit masks of sec. 1.3, CR17/18 queue semantics, EIRR W1C, SSM/RSM/MTSM incl. setting Q, RFI/RFIR with IPSW.N, shadows (also for Q = 0), RCTR exact count (start - 4), traps 10/11 at PL 3, PSW.S on CR16, CCR = 0 -> 22 | manual; QEMU is wrong for RCTR, shadows, IIAQ with Q = 0 | trap (+ new `sys`) |
| Interruptions | each reachable vector: IIR/ISR/IOR/IIAQ/IPSW contents, priorities (15 > 26 > 27 > 28 > 19 > 20 > 21), group 4 taken-before with IIAOQ = {delay slot, target}, interrupt before a nullified instruction, external-interrupt latency <= 3 instructions after SSM | manual | trap |
| TLB | IxTLBA/P, PxTLB, PxTLBE (all page entries, not blocks), DR8 diagnostic insert, lock-in/out, replacement order, dropped insert, block entries (ERS example), LPA/PROBE over all 128 AR x 4 PL x P, PID/WD, T/D/B/U traps, walker hash/insert/CR28 table | manual + ROM 0x41090-0x41096 | new `tlb` (needs PCX-L DIAG: no QEMU reference) |
| Caches | diagnose access to every tag/data/parity bit, HIT/PARERR, Arb parity, code executed from diagnose-planted I-lines with no RAM, L1-over-L2, SMC with FDC+FIC, dirty eviction at +128 KB, FDCE/FICE loops, PDC at PL 0 vs 3, U-bit uncached, no I-cache update by stores | ROM 0x42090-0x4209B + manual | new `cache` |
| Diagnose | DR0 masks (0x0150EFFC), W1C, read-only bits, DR1, DR24/25, TOC_EN/DIS, SHDW_GR/GR_SHDW, MFCPU_C/_T forms | ERS + ROM | new `diag` |
| FP | all ops sgl/dbl x 4 rounding modes, conversions incl. int64, 32 FCMP conditions, compare queue and clip FTESTs, FMPYADD/SUB/CFXT, XMPYU, FID = 0x000D0800, every ERS s.7.3 unimplemented case (dest untouched, fr1L code, delayed trap on the next FP instruction, FSTD fr0 clears T), D-bit flush mode, CCR = 0 -> 22 | IEEE reference (SoftFloat) for numeric results; ERS s.7.3 for trap cases (QEMU traps immediately) | fp, fpedge |
| CR16 | ticks per second at 64/80/100 MHz settings, match across a 2-tick step, wrap with compare 0, DR1 load | cycle arithmetic | `sys` |

Integration: HP's ROM is the system test. Sim milestones in BOOT s.4.0 order:
selftest1 CPU tests 0x41081 ... 0x410D2 (LED codes 0x41 on the latch at
0xF00EFFFF show progress), cache tests 0x42090-0x42095, memory sizing,
selftest2 (cache, TLB incl. walker, LDCW, FP), then BOOT_ADMIN, then the IPL.

### 7.3 Where QEMU 11.1.1 is not a valid CPU reference

From CLAUDE.md: `-M 715` is a PA-7300LC with a 256-entry TLB and 16 BTLB slots
(so HP-UX takes PCX-T paths); MAX-1 refused unless PA 2.0
(translate.c:3099); unknown DIAG encodings logged and ignored
(translate.c:4635), PCX-L diagnose not decoded; CR16 fixed at 250 MHz; FP
traps immediate; CPU HPA at 0xFFFB0000. Found while writing this spec:

| # | Deviation | Where | Correct behaviour |
|---|---|---|---|
| 1 | recovery counter never decremented, trap 3 never raised | no EXCP_RC source in translate.c | sec. 1.3, ROM 0x4108B |
| 2 | traps 23, 24, 25 never raised | names only, int_helper.c:261-263 | sec. 3.1 |
| 3 | shadow registers captured only when PSW.Q was 1 | int_helper.c:133-201 | always (ACD p.4-16 step 6, ERS s.5.3.5) |
| 4 | IIASQ/IIAOQ written even when PSW.Q = 0; IIASQ forced to 0 when PSW.C = 0 | int_helper.c:113-130 | unchanged when Q = 0 (ACD p.2-17) |
| 5 | TOC entry overwrites GR24/GR25 ("help SeaBIOS") | int_helper.c:212-214 | GRs untouched |
| 6 | PSW.E not implemented | translate.c:105 | stored (P-011) |
| 7 | PROBE returns 0 if the probed PL is more privileged than the current one (PA 2.0 rule) | op_helper.c:331-334 | PA 1.1 checks at the given PL (ACD p.5-154) |
| 8 | BB/BVB words with c bit 17 = 0 (ROM 0xC482A12A, 0xC002A06A) are illegal | insns.decode `bb_sar`/`bb_imm` | condition from bit 16 (sec. 4.3.9) |
| 9 | PA 2.0 opcodes execute instead of trapping on a PA 1.1 CPU: 0x16/0x17/0x1E/0x1F and 0x14/0x1C with bit 30 = 1 (FLDW/FSTW/FLDD/FSTD long, LDW/STW ,ma/,mb); 0x2E FMPYFADD; unsigned FCNV; FNEG/FNEGABS; MFIA; MTSARCM | trans_fldw/fstw/fldd/fstd (translate.c:1714-1794), trans_ld/st gate only size > 32 (3301-3325), trans_fmpyfadd_* (4537), trans_fcnv_u* (4278-4333), trans_fneg* (4169-4205), trans_mfia (2152), trans_mtsarcm (2326) | trap 8 / unimplemented (sec. 4.1, 8.3) |
| 10 | SH1/2/3ADD(L) NUV/ZNV/UV/VNZ conditions | translate.c do_add_uv; `tests/cpu/model.py` QEMU_BUGS `shadd-uv` | ACD p.5-88..5-95 |
| 11 | HSHLADD saturates on the sum only (pre-shift overflow ignored) | op_helper.c:442-456 | PA2 table 6-3, L2ERS |
| 12 | FID returns PCX-L2 model 0x0F | translate.c:4094-4106 | 0x0D rev 1 |
| 13 | IEEE trap-enabled exceptions trap as such, immediately; excepting insn put in fr0R | fpu_helper.c:134, int_helper.c:182-184 | PCX-L: delayed unimplemented exception, fr1L (sec. 3.5) |
| 14 | PCX-L MTCPU (0x...0240) is "unimplemented diag" (QEMU's mtdiag is the 0x1600 form); no TOC_EN/DIS, no cache or L1 diagnose, no DR8 BTLB inserts (BTLB through a private `diag_btlb` PDC hook), no hardware walker | insns.decode diag block; mem_helper.c:716+ | sec. 4.3.6 |
| 15 | caches not modelled: I/D always coherent, no aliasing, no write-back -- missing FDC/FIC in guest code goes unnoticed | -- | sec. 2.7, 5.5 |
| 16 | 256-entry TLB never evicts what PCX-L's 64 would; PxTLBE semantics only for its own layout | cpu.h:249-251, mem_helper.c:651 | sec. 2.3 |
| 17 | IIR = 0 when the faulting instruction cannot be re-read | int_helper.c:174-176 | IIR = instruction word |
| 18 | RSM with i = 0 executes at any privilege level ("HP-UX 11i and HP ODE use rsm for read-access to PSW") | translate.c trans_rsm | trap 10 at PL != 0 (ACD p.5-144); `tests/cpu/model.py` QEMU_REF_BUGS `rsm0-pl3`. Worth remembering for HP-UX 11i: its user code expects something to execute `rsm 0` |
| 19 | B,GATE's link register is not IAOQ_Back + 4 with the GATE's PL in bits 30:31 (the sys suite sees link - target = 3 - target) | translate.c trans_b_gate | ACD p.5-63; QEMU_REF_BUGS `gate-link` |

Agreeing with ours (no action): unaligned trap 28 also for absolute accesses
(MO_ALIGN, cpu.c:170); LDCW at word but not 16-byte alignment loads and clears
(translate.c:3350-3357); LCI returns 0 (translate.c:2747).

---

## 8. Settled behaviours, open questions, next steps

### 8.1 Unaligned data references, access rights and protection-ID faults

PCX-L raises **26** (access rights), **27** (protection ID) and **28**
(unaligned data reference) and **never 18**: "PA7100LC replaces the data
memory protection trap (trap 18) with a data memory access rights trap (trap
26), data memory protection ID trap (trap 27), and an unaligned data reference
trap (trap 28). This is per PA-RISC1.1." (ERS s.2.2.8, pcxl_fwd.txt:349-353).
ACD p.4-24 (trap 18 notes): trap 18 is retained only for compatibility and
"in PA-RISC 1.1 (Second Edition) and later revisions, processors must use
traps 26, 27, and 28". Linux agrees (L kernel/traps.c:668-669 "case 18: PCXS
only -- later cpu's split this into types 26,27 & 28"; :676-677 "PCXL: Data
memory access rights trap"). RTL: 26 for a failed access-rights check on a
load, store, semaphore or PDC purge; 27 for a failed PID check (PSW.P = 1);
28 for an unaligned load/store (halfword odd, word not % 4, doubleword not %
8), all with IIR, ISR = space, IOR = full unaligned offset; priority 26 > 27 >
28, all below the TLB miss 15/17 (ACD p.4-14). ACD p.4-24 defines 28 only with
data translation enabled and calls unaligned *absolute* accesses undefined;
**ours also raises 28 in real mode** (one rule, matches QEMU, no known guest
depends on either choice). QEMU's 28 for unaligned accesses is therefore the
right vector for PCX-L.

### 8.2 LDCWS/LDCWX alignment

The architecture makes misalignment **undefined**, not a trap: "The address
must be 16-byte aligned. If the address is unaligned, the operation of the
instruction is undefined." (ACD p.5-40, LDCWX; LDCWS likewise); "These
instructions are required to use 16-byte aligned addresses" (ACD p.3-16);
trap 28 "not detected for absolute accesses or semaphore instructions -- they
are undefined operations" (ACD p.4-24). The PCX-L ERS says nothing about
semaphore alignment (only the hints, s.2.2.5). Real hardware reportedly works
with word alignment (QEMU's comment, translate.c:3350-3357). **RTL**: a
word-aligned LDCW that is not 16-byte aligned operates normally on the
addressed word (no trap, low 4 bits **not** ignored -- QEMU's behaviour is
right); a non-word-aligned LDCW raises 28 (ours; matches QEMU's MO_ALIGN).
Tests may check the word-aligned case against QEMU, labelled
implementation-defined. Both kernels keep lock words 16-byte aligned
(R06 s.3.2).

### 8.3 Major opcode 0x1F

**Undefined in PA-RISC 1.1 and on PCX-L -> illegal instruction trap 8; QEMU
is wrong.** ACD table D-1 (p.D-2) lists 0x1F ("bits 0:1 = 01, bits 2:5 =
1111") as "--", and "An undefined major opcode is considered an illegal
instruction. Execution of an illegal instruction causes an illegal instruction
trap" (ACD p.5-1; trap 8 notes p.4-21). PCX-L adds nothing there (its
product-specific additions are in 01, 02, 03, 05, 06 and 0C, ERS ch.2/7/8,
L2ERS ch.13; the ERS s.3.2 bundling-class list "13-19, 1B-1F" is a decode
shortcut for issue rules, not a definition). QEMU decodes 011111 as the PA 2.0
long-displacement FSTW (`fstw 011111 ... .............0..`, bit 29 = 0 -- so
0x7C000000 is "FSTW fr0,0(r0)") or STW,MA/MB (`st 011111 ...10.`), and
`trans_fstw` has no `is_pa20` check (translate.c:1768-1772) while `trans_st`
only rejects size > 32 (3318-3325). The same QEMU bug covers 0x16, 0x17, 0x1E
and the bit-30 (FLDD/FSTD) forms of 0x14/0x1C -- 0x14/0x1C trapped in the
coordinator's run only because their LDD/STD forms are size-gated. The full
PA 1.1 illegal set: 07, 0F, 14-17, 1C-1F, 27, 2E, 2F, 36, 37, 3B-3F (sec.
4.1); `model.QEMU_BUGS` should gain an entry for 0x14(bit 30)/0x16/0x17/0x1C
(bit 30)/0x1E/0x1F and 0x2E.

### 8.4 Open questions for the user

| # | Question | Default if no answer |
|---|---|---|
| Q1 | Full **128 KB + 128 KB** caches cost ~247 M10K of 553 (the framework takes ~98). OK, or plan for the ROM-supported 32 KB variant (one-word ROM patch, ~65 M10K)? | 128 + 128, unpatched ROM |
| Q2 | **50 MHz** core (64 MHz stretch). Acceptable that we are slower than a real 715/64 (single issue, replay misses)? | 50 MHz |
| Q3 | **CPU revision**: 0 (ROM unpatched, dual-issue test skipped) or a non-zero value with the one-word ROM patch of review 07 s.1.6 (offset 0xB810: 0x86802012 -> 0xE8000012). Review 07: rev 0 is unsafe for Linux (stale PDC_SOFT_POWER pointer); any rev < 0xC puts HP-UX 10.20 on its trap-7 gateway path; 0xC is what a real 715/64 reports. **Decided (user, 2026-10-07): revision in 1..0xB, implemented as 2**, with the ROM word patched by the loader until the core passes the dual-issue timing test (a later task, STUBS S-011) | `CPU_REVISION` = 2 (cpu-requests #2) |
| Q4 | answered by review 07 s.2: CR28 written for 15, 6 and 17 per the table, never when the walker is disabled | -- |
| Q5 | Little-endian: is "PSW.E stored, no effect" (P-011) acceptable for every target OS (NeXTSTEP? NetBSD?) | yes |
| Q6 | MAX-1 reference: patch the scratch QEMU to allow MAX-1 on `-M 715` (and fix HSHLADD), or rely on `model.py` alone? | model.py; optional QEMU patch |
| Q7 | answered by review 07 s.3.6: trap 8, simulator logs DIAGs outside the ROM | -- |
| Q8 | HP-UX 10.20 and Linux scanned (review 07 s.3): the only DIAG HP-UX executes on a PCX-L is MFCPU_T DR25; no fast inserts, MAX-1, multi-endian ops or SPOPs; FSTQS (major 0F) stays off while PDC's key is 0x72. HP-UX 11i's kernel (media in `~/Downloads`) and 9.05 (no image) remain unscanned | keep IxTLBxF and MAX-1 for HP-UX 9 and user code |
| Q9 | Should the trap suite also expect 28 for unaligned *absolute* accesses (our choice) or skip them as undefined? | expect 28 |

### 8.5 Next steps

1. User decisions on Q1-Q3.
2. `pa_pkg.sv` + `pa_decode.sv` first, with a machine-readable copy of sec. 4
   (opcode/extension/class/trap) that generates a decode test: every row of
   section 4.3 and every illegal/PA 2.0 class of section 4.1 hit at least once.
3. Integer pipeline with uncached-only fetch/data (no TLB, no caches): run
   alu1/alu2/shift/branch/mem in Verilator against model.py and the QEMU logs.
4. CSRs, interruptions, CR16, shadows: the trap suite plus a new `sys` suite.
5. Caches with diagnose access, then the ROM's selftest1 in simulation.
6. TLB, block TLB, walker: new `tlb` suite, ROM selftest2 TLB tests.
7. FPU: fp/fpedge suites, ROM 0x44080-0x44082.
8. Full ROM to BOOT_ADMIN, then HP-UX 10.20 and Linux boots.
