# CPU feature requests (system -> CPU)

The CPU (`rtl/cpu/`) and the rest of the machine are built by separate work
streams. The system side does not edit `rtl/cpu/`; when it needs something
from the CPU -- a feature, an interface change, a bug fix -- it adds a row
here, and the CPU side answers in the same row and moves it to "Done" with
the commit that delivered it. Keep entries short; put detail in the
referenced docs.

Interface contract: `docs/design/cpu.md` section 6.8 (`pa_cpu` ports). Until
the pipelined core exists, the system uses `pa_core_seq` (uncached port only,
`docs/STUBS.md` S-005).

## Open

None (2026-10-18).

## Done

| # | What | Commit |
|---|---|---|
| 3 | uncached **loads** drive `io_be` for the bytes they read (as stores do), not the whole word: a byte load sends one enable, a halfword two | `18043d1` (2026-10-07); made by the system stream, in every build since (moved to Done 2026-10-18) |
| 4 | cache and TLB flushes/purges with the **,m** completer (FIC/FICE/FDC/FDCE/PDC/PxTLB/PxTLBE x(s,b)) use the **unmodified GR[b]** as the offset, then GR[b] += GR[x] (ACD 5-169..5-174: `case M: offset <- GR[b]`) | `10b1ad4` (2026-10-08); made by the system stream, in every build since (moved to Done 2026-10-18) |
| 5 | the hardware walker's second PDIR read (`W_WALK_RD3`: DR25 U = 1, N = 1, tag mismatch on an entry in the upper half of its line) must hold W like `W_WALK_RD` | `10b1ad4` (2026-10-08); made by the system stream, in every build since (moved to Done 2026-10-18) |
| 6 | a D-cache line transaction (fill or write-back) must not overtake an **older posted uncached store** still in the BIU's store buffer | `44babfc` (2026-10-08); made by the system stream, in every build since (moved to Done 2026-10-18) |
| 7 | the I-LAB is dropped only on the PCX-L's LAB refresh events (ERS s.6.4, cpu.md 2.2: interruption, RFI, SSM/RSM/MTSM, MTCTL to a PID, ITLB insert/purge, DIAG), not on every W redirect; and an I-LAB refill sets its UTLB entry's used bit (cpu.md 2.2: "set on every translation hit") | `5cec6d8`, `45c4ad1` (2026-10-08); made by the system stream, in every build since (moved to Done 2026-10-18) |
| 8 | a fetch **without execute rights** at its PL (trap 7) must not fill the I-cache (or the UIB): it goes down the pipeline as a NOP marked IMP, like an ITLB miss | `68ec0f6` (2026-10-09); made by the system stream, in every build since (moved to Done 2026-10-18) |
| 9 | **BV (3A/6) with reserved bits set executes as BV** instead of trap 8 -- at least bit 19 (PA 2.0's BVE: `e840d000` = `bve (rp)` = `bv r0(rp)` with bit 19 set); probably BLR's and BV's whole reserved field 19:29 is ignored by the PCX-L (cpu.md 4.3 "BLR/BV with non-zero reserved bits -> trap 8" would go) | `1d17078` (2026-10-11); made by the system stream, in every build since (moved to Done 2026-10-18) |
| 10 | the link of `b,l` corrupted after an `rfi` into a nullified branch whose IIAOQ back is its target (the target fetched twice, the second copy as the first's delay slot) -- HP-UX 11i's installer stalls | `5cda517` (2026-10-14; the evidence and the mechanism in the row above) |
| 1 | `pa_cpu` port `soft_pwr_n` (1 = not pressed; sampled every cycle into DR25 bit 0, read by MFCPU_T). `pa_core_seq` has no DR25 input (DR25 reads what MTCPU wrote) | pipelined core commit |
| 2 | `pa_cpu #(.CPU_REVISION(6'd2))` sets DR0 bits 0:5 (reset DR0 = {rev, 0x200}). **Decided 2026-10-07: revision 2.** Because it is not 0, the ROM runs self-test 0x4108D (dual-issue timing), which the single-issue core fails: **the system's ROM loader must patch file offset 0xB810 from 0x86802012 to 0xE8000012** (`b,l,n` over the test; review 07 s.1.6) until the core passes it (STUBS S-011) | pipelined core commit; the patch is the system stream's |
