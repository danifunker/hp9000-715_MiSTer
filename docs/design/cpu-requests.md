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

| # | Requested by / date | What | Why (ROM step / OS need, doc ref) | Status / answer |
|---|---|---|---|---|
| 3 | system, 2026-10-07 | uncached **loads** drive `io_be` for the bytes they read (as stores do), not the whole word: a byte load sends one enable, a halfword two | an I/O byte read must not touch the neighbouring registers -- the ROM's `ldb` of the 16550's IIR (F010_5802) went out as a word read of F010_5800-5803 and popped RBR / cleared THRE, so `uart_init_test` saw IIR != 0xC1 and the console never came up (BOOT 6). cpu.md 6.8 io_be | **Made by the system stream** (the CPU sessions were idle; please review): `pa_core.sv` d_be uses `w_be` for loads too (one line). `tests/run-cputest.sh` re-run on it; it is in the tree the FPU fit (fit 10) measures |
| 4 | system, 2026-10-08 | cache and TLB flushes/purges with the **,m** completer (FIC/FICE/FDC/FDCE/PDC/PxTLB/PxTLBE x(s,b)) use the **unmodified GR[b]** as the offset, then GR[b] += GR[x] (ACD 5-169..5-174: `case M: offset <- GR[b]`) | the core used base + index, so every flush loop skipped its first line. HP's ROM: `f00078ec` (`fice,m r1(sr0,r24)`) never flushed line 0 of the code it plants in the I-cache, the L1-I kept the previous test's first 16 bytes, and **self-test 0x41094 (PROBE) executed stale code and failed** ("failed selftest: Processor Board", then the FP tests are skipped and PDC reports the FPU not functional). The OSes' PDC_CACHE flush loops have the same shape | **Made by the system stream** (please review): `pa_decode.sv` major 01 sets `ea_is_base = m`. Found with the whole-machine ROM simulation (`verilator/romsim`, `--l1trace`). No suite covered `,m` flushes -- worth a cache/tlbx test |
| 5 | system, 2026-10-08 | the hardware walker's second PDIR read (`W_WALK_RD3`: DR25 U = 1, N = 1, tag mismatch on an entry in the upper half of its line) must hold W like `W_WALK_RD` | it was missing from the `w_hold` list, so the access **retired without its trap** (a load returned 0) and CR28 was not written: **ROM self-test 0x41095 failed** at its U = 1, N = 1 case (f0009a90, CR28 must be word 3 of the line = 0xAAAAAAAA) | **Made by the system stream** (please review): `pa_core.sv` adds `W_WALK_RD3` to the hold list. HP-UX runs U = 1, N = 0, so this path is the ROM's |
| 6 | system, 2026-10-08 | a D-cache line transaction (fill or write-back) must not overtake an **older posted uncached store** still in the BIU's store buffer | PA 1.1 keeps a processor's accesses in program order. The ROM's ECC test (`mem_ecc_singlebit` f000d9d4: `stw` MIOC+0xC0 to turn ECC on, then `ldw` of the line it just flushed) failed on the board (chassis 0x210D7) because the load's miss reached the MIOC before the store: the BIU's line port does not wait for the store buffer, and the MIOC serves its line port first when both are waiting -- which the ideal simulator RAM never caused, the real SDRAM's latency does (romsim `ROMSIM_SDRAM=1`, `--miotrace`) | **Made by the system stream** (the CPU sessions were idle; please review): `pa_biu.sv` grants the line port to the D side only when `!sb_valid` (one condition). `tests/run-cputest.sh` re-run on it |

## Done

| # | What | Commit |
|---|---|---|
| 1 | `pa_cpu` port `soft_pwr_n` (1 = not pressed; sampled every cycle into DR25 bit 0, read by MFCPU_T). `pa_core_seq` has no DR25 input (DR25 reads what MTCPU wrote) | pipelined core commit |
| 2 | `pa_cpu #(.CPU_REVISION(6'd2))` sets DR0 bits 0:5 (reset DR0 = {rev, 0x200}). **Decided 2026-10-07: revision 2.** Because it is not 0, the ROM runs self-test 0x4108D (dual-issue timing), which the single-issue core fails: **the system's ROM loader must patch file offset 0xB810 from 0x86802012 to 0xE8000012** (`b,l,n` over the test; review 07 s.1.6) until the core passes it (STUBS S-011) | pipelined core commit; the patch is the system stream's |
