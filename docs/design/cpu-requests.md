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

## Done

| # | What | Commit |
|---|---|---|
| 1 | `pa_cpu` port `soft_pwr_n` (1 = not pressed; sampled every cycle into DR25 bit 0, read by MFCPU_T). `pa_core_seq` has no DR25 input (DR25 reads what MTCPU wrote) | pipelined core commit |
| 2 | `pa_cpu #(.CPU_REVISION(6'd2))` sets DR0 bits 0:5 (reset DR0 = {rev, 0x200}). **Decided 2026-10-07: revision 2.** Because it is not 0, the ROM runs self-test 0x4108D (dual-issue timing), which the single-issue core fails: **the system's ROM loader must patch file offset 0xB810 from 0x86802012 to 0xE8000012** (`b,l,n` over the test; review 07 s.1.6) until the core passes it (STUBS S-011) | pipelined core commit; the patch is the system stream's |
