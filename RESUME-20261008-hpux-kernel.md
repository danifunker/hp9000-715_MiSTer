# Resume prompt -- HP-UX 10.20's kernel on the machine (2026-10-08), for Fable

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
The user is handing the **HP-UX kernel bring-up** to you because it now needs
the CPU owner's eyes: the last session (system stream) found and fixed a CPU
bug that HP-UX hit, and the next failures may be CPU or machine -- nobody
knows yet. The user (2026-10-08): CPU changes are checked with you, not made
by the system stream. You may change `rtl/cpu/` and the rest of the machine.

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/cpu-requests.md` **#7** (and #3-#6: all made by the system
   stream, none reviewed yet).
3. `RESUME-20261008-system-next.md` -- the system stream's plan this
   continues (its step 1 is this file's subject); `docs/design/system.md`
   sections 10 (builds) and 11 (simulation).
4. `docs/review/06-os-hpux-linux.md` sections 2-4 (what HP-UX needs; 3.3 is
   the TLB/PDIR/walker/block TLB), `06d-hpux-c720-scsi.md`,
   `07-hpux-cpu-specifics.md`; `docs/design/cpu.md` 2.2-2.6 (TLB, I-LAB,
   walker).

## What happened (2026-10-08, session a88b6b1f)

**The old symptom** (RESUME-...-system-next step 1): after `boot scsi.6`,
ISL and the hpux loader, the kernel ran to chassis 0xCEF2 and then every PC
sample was the `rfi` at 0x20f3c (`skip_int_restore2_0`, the common
interruption return). Not a simulator artefact (turbo was off).

**The cause: a TLB livelock in the CPU.** `--traps` showed only the 100 Hz
clock interrupt (trap 4) at 0x6dcc8, forever. 0x6dcc8 is `stw r3,0(r31)` in
`pa_dma_init` (data page 0x930, code page 0x6d), with all 64 TLB entries
valid:
1. the store's DTLB miss: the walker failed (R = 0), the kernel's handler
   (`dtlbmss_PCXT` via CR28) set R, inserted, `rfi,r`;
2. the insert took the NRU slot of the code page 0x6d -- never marked used,
   because fetches go through the I-LAB, not the UTLB;
3. the refetch missed the I-LAB (it was dropped on every W redirect), the
   ITLB walk put 0x6d back into the same slot (the fresh 0x930 entry was not
   used yet either), the store missed again, the walker put 0x930 back ...
   no traps, no bus traffic.
The board's build-9 panic (16 MB) has the same frame: its stack is
`pa_dma_init` 0x6dcc8 -> clock interrupt -> `update_timers` -> data page
fault, so it was most likely the same livelock ending differently.

**The fix (cpu-requests #7, commit `5cec6d8`, ~25 lines, please review):**
the I-LAB is dropped only on the PCX-L's LAB refresh events (ERS s.6.4,
cpu.md 2.2: interruption, RFI, SSM/RSM/MTSM, MTCTL to a PID, ITLB
insert/purge, DIAG) -- `pa_core.sv` drives `ilab_inval`, `pa_fetch.sv` uses
it instead of `redir_kill_all`; and an I-LAB refill sets its UTLB entry's
used bit (`tlb_lk_use` includes `it_ack`). Gates on it: `tests/run-cputest.sh`
12/12 pass, `tests/run-cosim.sh` 8/8 identical, `tests/run-rom.sh` PASS
(`fd7d435`). Quartus build 10 (`fd7d435`) meets 64 MHz (setup +0.615 ns,
hold +0.249 ns, 28,669 ALMs = 68 %) -- **not yet run on the board**.

Also new: romsim **`--wtrace A B`** (`fd7d435`): the core's W and M stages and
the TLB every cycle from A to B, plus a dump of all 64 + 8 TLB entries at A
and B. It is how the livelock was seen.

## Where it stands now: two new failures, further on

Both runs: ideal-RAM romsim, `ee_boot.hex` (bootstrap EEPROM), `--turbo 15
--turbo-until 860000000`, `--disk0 disks/hpux1020.img --snapshot`,
`--type 'boot scsi.6\r'`. Both get past 0xCEF2 now (the livelock is gone).

**32 MB: `Data page fault` panic in the VM fault path, ~1.7M cycles after
0xCEF2.** Kernel start 873.7M cycles, 0xCEF0 965.4M, 0xCEF2 965.8M, then
0xBF00 (the panic's display code) at 967.5M; 970M-1045M the PC sits at
0xa348-0xa360 (below the kernel's text at 0x11000: the console IODC copied
into RAM, sending the message buffer at 9600 baud), and the console shows:

```
Stored message buffer up to panic:
vuseg=91f000
trap type 15, pcsq.pcoq = 0.ebb00, isr.ior = 0.50
savestate ptr = 0x7ffe7a58, savestate return ptr = 0x1000
panic: (display==0xbf00, flags==0x0) Data page fault
PC-Offset Stack Trace: 0x0022487c 0x001ffbc8 0x000cf484 0x00209d68 0x000ebb00 0x000eb820
                       0x000cf79c 0x00209d68 0x002094e0
```

= `panic` <- `report_trap_or_int_and_panic` <- `trap` <- `$thndlr_rtn` <-
**`hdl_vfault` 0xebb00** <- `vfault` <- `trap` <- `$thndlr_rtn` <- `noksovfl`.
So a fault went `trap` -> `vfault` -> `hdl_vfault`, and `hdl_vfault` itself
faulted at 0xebb00 `ldw 50(r31)` with r31 = 0: r1 = its first argument
(stored at -0x70(sp)), r26 = `*(r1+0x1c)`, r31 = `*(r26+0x74)` = **NULL**.
What the first fault was (address, why) is not known yet. Then `Dumpsys()
failed` and the machine rebooted to the ROM (0x04.1081 at 1391.8M). Logs:
`keep/logs/kb1.out` (console), `kb1.err` (PC samples).

**16 MB: the kernel goes idle, right after 0xCEF2.** Kernel start 754.9M,
0xCEF0 801.4M, 0xCEF2 801.8M, then nothing on the console; from 810M to the
end of the run (1.5G, ~11 s of machine time) every PC sample but one
(`clock_int`, 840M) is in `idle` (0xd23e0..), PSW 0x0004000f (I = 1), 4362
interruptions in the whole run. So it waits for something -- an interrupt,
an I/O completion, a wakeup that never comes. Both RAM sizes fail within a
few million cycles of 0xCEF2, i.e. close to `pa_dma_init`: possibly one
cause showing two ways. `vuseg=` is not printed to the console at this
stage (it only showed in the 32 MB panic's message buffer), so whether the
16 MB run got that far is unknown. Logs: `keep/logs/kb16.*`.

**Not known yet: CPU or machine.** Things to keep in mind:
* #7 changes when the I-LAB is refreshed. A D-side purge (PDTLB/PDTLBE) of
  a code page now leaves the LAB translating it, as the ERS describes for
  the real chip -- if HP-UX relies on anything else, the 32 MB fault could
  be that. Cheap check: the same run with the LAB also dropped on D-side
  purges.
* The kernel is now in code nobody has run on this machine: VM, the clock,
  LASI interrupts, the c720 SCSI driver (06d: SIGP vs WAIT RESELECT, DFE),
  PDC calls answered by our hardware (the ROM is HP's).
* QEMU reference: the same image boots on `-M B160L` (session c636bb42's
  `keep/qemu/`: `run-715-hpux.sh`, `hpux-boot-trace.py`, the PDC-call logs
  in `keep/qemu/logs-os/`). After 0xCEF2 it does PDC_PCI_INDEX (B160L only),
  PDC_INITIATOR, PDC_IODC, PDC_CHASSIS 128, prints `vuseg=`, then "System
  Console is on the Built-In Serial Interface", PDC_TOD, swap/root config.
  Note B160L reports 16 BTLB slots (PCX-T paths); our 715 reports 8 (PCX-L).

## Checkpoints and files

Session scratchpad `/tmp/claude-1000/-home-dani-repos-hp9000-715/a88b6b1f-2a43-4768-8a38-f2e70d50f9b3/scratchpad/keep/`
(its `INDEX.md` lists everything):

| file | what |
|---|---|
| `ck_k_ilab.sav` | 32 MB, kernel start (cycle 873,737,060) |
| `ck_k16_ilab.sav` | 16 MB, kernel start (cycle 754,886,236) |
| `ee_boot.hex` | the EEPROM image |
| `builds/HP9K715_build10.rbf` | build 10, untested on the board |
| `logs/` | the two kernel runs, the livelock traces, the build-10 log |
| `obj_dbg/` | the pre-fix model; with session e93fdf95's `ck_kernel2.sav` it replays the livelock |

The two checkpoints restore into `verilator/obj_dir_rom_ilab` built at
`fd7d435` (`make -C verilator romsim ROMSIM_DIR=obj_dir_rom_ilab`; verified).
Any RTL change makes a new model: then boot from scratch (~1 h to the kernel
at either size; the two ran in parallel with a Quartus fit alongside) and
`--save-on 'start 0x18fe68' FILE` for a new kernel checkpoint. Example, from `verilator/`:

```
K=/tmp/claude-1000/-home-dani-repos-hp9000-715/a88b6b1f-2a43-4768-8a38-f2e70d50f9b3/scratchpad/keep
./obj_dir_rom_ilab/Vemu --restore $K/ck_k_ilab.sav --disk0 ../disks/hpux1020.img --snapshot \
    --ram-lg 5 --stamp --traps --sample 10000000 --max-cycles 1100000000
```

Pass the same `--ram-lg` the checkpoint was made with (5 = 32 MB, 4 = 16 MB):
the RAM size comes from the harness every cycle, so a wrong value changes it
mid-run. Fresh boot: `./obj_dir_rom_ilab/Vemu +eeprom=$K/ee_boot.hex --ram-lg 5
--turbo 15 --turbo-until 860000000 --stamp --disk0 ../disks/hpux1020.img
--snapshot --type 'boot scsi.6\r' --sample 10000000 --save-on 'start 0x18fe68'
NEW.sav`.

## Suggested next steps

1. Review #7 (keep, rework or revert -- the user is fine with it staying since
   it fixed the livelock).
2. 32 MB panic: restore `ck_k_ilab.sav` with `--traps` to ~1.05G, find the
   trap that leads into `vfault`/`hdl_vfault` (the second-to-last trap 15
   before the panic print), then `--trace N --trace-from C` and `--wtrace`
   around it: the faulting address, its PDIR entry, what the kernel expected.
3. 16 MB idle: restore `ck_k16_ilab.sav` with `--traps` (which interrupts
   still come?) and `--gsctrace` / `--scsitrace` (what the kernel last asked
   the hardware for), and find what `idle` waits for.
4. Then the board: `tools/mister/board.sh push keep/builds/HP9K715_build10.rbf`,
   `setup 16 0` (release EEPROM `hp715.eep` autoboots scsi.6), `load`,
   `console`; compare with the 16 MB sim.

## How to work

* romsim options: `verilator/romsim/tb_rom.cpp` header and system.md 11
  (`--traps --trace N --trace-from C --wtrace A B --sample N --gsctrace
  --scsitrace --miotrace --evtrace --sdtrace --flags-from C --save-at/--save-on
  /--restore`). ~230k cycles/s; a 10M-cycle window costs ~45 s.
* Kernel symbols: `roms/hpux/vmunix.dis` and `vmunix.syms`
  (`tools/hpux/som.py`); grep helpers in session c636bb42's
  `keep/hpux-analysis/` (`fn.sh`, `callers.py`, `findref2.py`, `dumpwords.py`,
  `realmain.dis`).
* Gates after `rtl/cpu` changes: `tests/run-cputest.sh`, `tests/run-cosim.sh`,
  `tests/run-rom.sh`; fits in `docs/design/cpu-timing.md`, whole-core builds
  in system.md 10 (one Quartus flow at a time, `pgrep -a quartus` first).
* Rules (CLAUDE.md, the user's memory): commit often in small steps with
  explicit paths (never `git add -A`, never the `.qsf` version-stamp noise),
  every stub in `docs/STUBS.md` in the same change, never delete anything
  without asking (scratch included; reusable scratch goes in your
  scratchpad's `keep/` with an `INDEX.md`), kill sims by PID, the MiSTer at
  .92 is cleared for this core, show the user console screenshots as things
  move (`tools/sim/console_png.py`).
