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
| 1 | system, 2026-10-07 | Soft-power input: a port (e.g. `soft_pwr_n`, 1 = not pressed, reset 1) that drives DR25 bit 0 (PA numbering) as read by MFCPU_T 0x1720141C | HP-UX polls it at 4 Hz, Linux at 1 Hz (revision != 0); an OSD "soft power off" holding it at 0 for 2+ polls gives a clean shutdown. Review 07 s.1.4, s.6 item 1 | open |
| 2 | system, 2026-10-07 | CPU revision as a parameter (DR0[0:5] reset value), default 0 | User decision pending between revision 0 and 0xC (review 07 s.1.6 option B: DR0 = 0xC plus one ROM word 0xB810 -> 0xE8000012, which the system's ROM loader would apply) | open -- waits on the user |

## Done

| # | What | Commit |
|---|---|---|
