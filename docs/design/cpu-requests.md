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

## Done

| # | What | Commit |
|---|---|---|
| 1 | `pa_cpu` port `soft_pwr_n` (1 = not pressed; sampled every cycle into DR25 bit 0, read by MFCPU_T). `pa_core_seq` has no DR25 input (DR25 reads what MTCPU wrote) | pipelined core commit |
| 2 | `pa_cpu #(.CPU_REVISION(6'd0))` sets DR0 bits 0:5 (reset DR0 = {rev, 0x200}); default 0 until the user decides (revision 0xC needs the one-word ROM patch of review 07 s.1.6) | pipelined core commit |
