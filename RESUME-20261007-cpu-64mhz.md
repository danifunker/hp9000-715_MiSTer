# Resume prompt -- CPU: pipelined PA-7100LC core at 64 MHz (for a Fable session)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
Your job is the **CPU**: turn the working sequential bring-up core into the
pipelined PA-7100LC of `docs/design/cpu.md` and make it **close timing at
64 MHz** (the real 715/64's clock, 15.6 ns) on the DE10-Nano's Cyclone V
(5CSEBA6U23I7) with Quartus 17.0.2 -- without breaking a single test.

## Read first

1. `CLAUDE.md` -- project state, decisions, layout, tools, rules (they are binding).
2. `docs/design/cpu.md` -- the CPU specification; for this task above all
   section 6 (microarchitecture: 6.1 pipeline, 6.2 IAOQ/nullification, 6.3
   hazards, 6.5/6.6 fetch and data sides, 6.8 interfaces, **6.9 clock target
   and the paths to watch**, 6.10 module plan and budget) and section 8.5
   (implementation order).
3. `docs/STUBS.md` -- every stub; S-005 lists what the sequential core lacks.
4. `tests/cpu/README.md` -- the CPU test ROMs, the reference model, compare.py.
5. `docs/reference/rom/README.md` -- what HP's boot ROM demands of the CPU
   (caches with diagnose access, code planted in the I-cache, delayed FP
   traps, the hardware TLB walker, DR registers, CR16 rate).
6. `docs/review/07-hpux-cpu-specifics.md` -- answers spec questions Q3, Q4,
   Q7 and Q8 from the HP-UX 10.20 kernel, the ROM and Linux. Every finding
   ends with an "Impact on cpu.md" line; **folding those into cpu.md is
   yours** (you own the spec). The ones that change the RTL:
   - **DR25 bit 0 (PA numbering) is the soft-power button** (1 = not
     pressed, reset 1), read by MFCPU_T 0x1720141C at 4 Hz by HP-UX and
     1 Hz by Linux -- the only DIAG HP-UX executes on a PCX-L. The system
     stream wants it on an input port (`cpu-requests.md` #1).
   - **CR28 on walker failure** follows the ERS table exactly for trap 15
     (HP-UX does not recompute the hash; CR28 = 0 means page fault) and
     trap 6; harmless for 17; **unchanged when that side's walker is off**.
   - A **nullified** undefined or PA 2.0 opcode never traps (~30 sites in
     generic HP-UX paths).
   - One shared TLB: a D-side insert must also serve instruction fetches.
   - Q7: undefined DIAG stays trap 8; the simulator should log every DIAG
     executed outside the ROM.
   - Q3 (revision 0 or 0xC) is **waiting on the user**: review 07
     recommends 0xC with a one-word ROM patch (option B) because revision
     0 leaves Linux a stale soft-power pointer. Make the revision a
     parameter (`cpu-requests.md` #2) and keep 0 until the user decides.
   Its section 6 lists test items for your `sys`/`tlb` suites.

## Where the CPU stands (2026-10-07)

- `rtl/cpu/pa_pkg.sv` (control word `ctrl_t`), `pa_decode.sv` (PA 1.1 + MAX-1 +
  PCX-L diagnose decode), units `pa_alu.sv`, `pa_shift.sv`, `pa_max1.sv`,
  `pa_ldst.sv`, and `pa_core_seq.sv` -- a **sequential** milestone-A core
  (one instruction at a time over the uncached port, ~4.3 clocks per
  instruction): real mode, integer/branch/memory/system/diag, interruptions
  with shadow registers, RFI/RFIR, HPMC on bus errors, TOC.
- **All seven integer suites pass on it**: `tests/run-cputest.sh` (alu1, alu2,
  shift, max1, mem, branch, trap -- 10,567 vectors, ~29 M instructions;
  expectations from `tests/cpu/model.py`, or QEMU's logs with known QEMU bugs
  excused). Unit benches: `make -C verilator tb_alu tb_shift tb_max1 tb_ldst`.
- Not there yet (S-005): pipeline, caches + cache diagnose, TLB + block TLB +
  hardware walker + PROBE/LPA (major 01), FPU (FP takes trap 22), recovery
  counter, group 4 traps, explicit-endian loads/stores, CR16 fractional rate.
- **No Quartus run has been made of any CPU logic yet** -- there is no Fmax
  number at all. The spec's 50 MHz target and its 6.9 path estimates are
  paper figures.

## The task

1. **Baseline.** Make a standalone Quartus 17.0.2 project for the CPU in
   `scratch/cpu_fmax/` (gitignored): a top that registers every CPU port
   (so I/O does not dominate), virtual pins, the real device, a 64 MHz
   clock constraint. Fit `pa_core_seq` and record Fmax, the worst paths
   and ALMs. The units (`pa_alu` with its 33-bit adder and condition
   logic, `pa_shift`, `pa_max1`) are the first suspects.
2. **Design the pipeline for 15.6 ns from the start** (cpu.md 6.1: 5 stages
   F-D-E-M-W, single issue, precise commit in W, replay on D-miss,
   non-speculative fetch misses). Where 6.9 says a path is at risk (E branch
   resolve -> next-PC -> M10K address; the M-stage TLB CAM -> payload ->
   tag compare; M10K deep-array output muxes; the FPU), choose the
   structure that meets 64 MHz -- an extra stage or a registered redirect
   is acceptable -- and write the decision and its cost in bubbles down.
   Single issue stays (DR0 revision 0, STUBS P-008).
3. **Build it in the spec's order** (8.5): integer pipeline with uncached
   fetch/data -> CSRs/interruptions/CR16 -> caches with full diagnose
   access (128 KB I + 128 KB D direct-mapped, 32-byte lines, the 1 KB L1-I;
   the ROM plants code in the I-cache) -> TLB + block TLB + walker -> FPU
   (PCX-L model: NaN/denormal/trap-enabled -> unimplemented, delayed trap;
   4 DSPs, iterative divide/sqrt). Fit after every step; keep a table.
4. **Keep `pa_core_seq` as the reference.** Build a lockstep co-simulation
   (both cores on the same ROM, compare every retired instruction through
   the debug taps -- IAOQ, word, GR writes, traps) and use it alongside the
   suites. Do not break or remove the sequential core: the system work
   stream uses it until your pipelined `pa_cpu` exposes the cpu.md 6.8
   ports.
5. **New tests where the suites do not reach**: a `sys` suite (space
   registers, CRs, PSW masks, privilege, RFI corner cases), a `tlb` suite,
   and the fp/fpedge suites once the FPU exists (fpedge expectations follow
   the PCX-L unimplemented-exception rule, not QEMU -- see cpu.md 3.5).
   Generator: `tests/cpu/gen_tests.py`; references: QEMU via
   `tests/cpu/run_qemu.py` (`make -C tests/cpu qemu`) and `model.py`.
6. **Report** in `docs/design/cpu-timing.md`: every fit (commit, Fmax per
   clock, worst paths, ALMs, M10K, DSP), what changed, and -- if 64 MHz is
   out of reach -- the achievable Fmax, the blocking paths and the
   trade-offs that would get there (deeper pipeline, registered M10K
   outputs, smaller caches with the ROM's own 32 KB switch at 0xF00158E4).

## Gates

- `tests/run-cputest.sh` stays green on every commit (and on the pipelined
  core once it can run the suites); the unit benches stay green.
- A step is done when it passes its tests **and** its timing is measured.

## Rules for this session (from the user; also in CLAUDE.md and memory)

- **You own `rtl/cpu/`** (and the CPU tests/benches). Another session is
  building the rest of the machine at the same time in this same checkout
  (no git worktrees -- the user finds them confusing). It consumes the CPU
  only through the cpu.md 6.8 ports / `pa_core_seq`, and files what it needs
  in `docs/design/cpu-requests.md` -- check it regularly and answer there.
- Commit with explicit paths (`git add rtl/cpu/... docs/design/cpu-timing.md`),
  never `git add -A`; shared files (`CLAUDE.md`, `docs/STUBS.md`,
  `verilator/Makefile`, `tests/cpu/gen_tests.py`) get small targeted edits,
  re-read just before editing. CLAUDE.md says commit only when the user
  asks; for this work the user said "commit it and keep going"
  (2026-10-07), so commit finished, tested steps -- unless the user tells
  you otherwise in your session. End commit messages with the
  `Co-Authored-By` line the session's attribution reminder gives.
- **One Quartus flow on this box at a time** (6 cores, 15 GB): run
  `pgrep -a quartus` first; never kill a flow that is not yours. Quartus is
  `~/intelFPGA_lite/17.0/quartus/bin`. Scratch projects live in `scratch/`.
- Every stub or simplification goes in `docs/STUBS.md` in the same change.
- **Never delete anything without asking** (scratch included); keep
  reusable scratch in the session scratchpad's `keep/` with an `INDEX.md`.
  Disk space is limited -- clean temporary output when done.
- Do not edit `sys/` (MiSTer framework). Quartus 17.0.x only.

## Useful facts

- QEMU 11.1.1 with `-M 715` is not ground truth (CLAUDE.md lists its bugs).
  The distro's QEMU (8.2.2) has no `-M 715`. A built `qemu-system-hppa` may
  still be at the previous session's scratchpad
  `/tmp/claude-1000/-home-dani-repos-hp9000-715/c636bb42-9bcf-47e9-83f8-8ade60a40f61/scratchpad/keep/qemu/build-hppa/`;
  if it is gone: copy `~/src/qemu-11.1.1`, `configure --target-list=hppa-softmmu`,
  `ninja` (~4 min), and point `QEMU_HPPA` at it for `run_qemu.py`.
- Cross tools: `hppa-linux-gnu-{as,gcc,objdump}`, `gdb-multiarch`.
- The SGI Indy core's R4600 (64-bit, FPU, 16 KB caches) is 9.4k ALMs and
  closes 50 MHz: `../SGIIndy_MiSTer/reports/summary.md`,
  `../SGIIndy_MiSTer/docs/design/cpu-speed-tlb-icache.md`. The Quadra 800
  core's notes on seed walks and M10K inference traps are worth reading
  (`../MacQuadra800_MiSTer/CLAUDE.md`, Build section).
- Open spec questions (cpu.md 8.4) run on defaults: full 128+128 KB caches,
  revision 0 (pending, see Read first 6), undefined DIAG -> trap 8, PSW.E
  stored without effect. Q4, Q7 and Q8 are answered by review 07.
