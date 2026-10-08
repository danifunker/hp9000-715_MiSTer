# Resume prompt -- CPU: finish the FPU (fit, fpedge expectations, overlap)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
The PA-7100LC core (`rtl/cpu/pa_cpu.sv`) is complete and tested: pipeline,
caches with diagnose access, TLB with the hardware walker, and -- since commit
91bf0e8 -- the FPU (`pa_fpunit.sv` + `pa_fpu.sv`). Without the FPU it meets
64 MHz (fit 9: 65.1 MHz, seed 2, 11,373 ALMs). Three things are open, in this
order:

1. **Fit 10**: measure the core *with* the FPU and get it back to 64 MHz.
2. **fpedge expectations** (STUBS S-013): a PCX-L model of the edge cases so
   `tests/run-cputest.sh fpedge` means something.
3. **FPU overlap** (STUBS S-012): the FPU issues one operation at a time and
   holds every later FP instruction in D; recover the lost overlap.

Work in that order; each step is committed on its own when green (the user
wants small, frequent commits for easy rollback).

## Read first

1. `CLAUDE.md` -- state, decisions, layout, tools, rules (binding).
2. `docs/design/cpu-timing.md` -- **sections 4.2-4.4** (fits 4-9: what was
   cut and why, how the retimer hides stages, the per-stage diagnosis with
   `PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF`) and **section 5** (fit 10 is
   the first open item). `scratch/cpu_fmax/run.sh cpu_fmax_pipe` runs a fit;
   `cpu_fmax_pipe.qsf` already lists `pa_fpu.sv` and `pa_fpunit.sv` and keeps
   `SEED 2`.
3. `docs/STUBS.md` -- S-011 (ROM word for the dual-issue test), **S-012**
   (FPU issue model), **S-013** (fpedge), P-016 (latencies).
4. `docs/design/cpu.md` 3.5 (delayed FP traps), 4.3.12 (every FP instruction),
   6.11 (FPU design; its "Issue" row records what is implemented vs planned).
5. `rtl/cpu/pa_fpunit.sv` (323 lines: FR file, FPSR, decode of the operation
   word, sequencing) and `rtl/cpu/pa_fpu.sv` (the engine). The header
   comments are current.
6. `tests/cpu/gen_tests.py` `gen_fp_common` (the `fp` and `fpedge` suites),
   `tests/cpu/unit_vectors.py` `fp_lines` and `verilator/tb/tb_fpu.cpp`
   (`make -C verilator tb_fpu`: the engine alone on the fp suite's vectors).
7. `RESUME-20261007-fpu.md` -- the previous handoff, with the status update
   at its top and the original design notes below it.
8. ERS chapter 7 (forward copy at
   `/tmp/claude-1000/-home-dani-repos-hp9000-715/c636bb42-9bcf-47e9-83f8-8ade60a40f61/scratchpad/keep/doc-review-text/pcxl_fwd.txt`
   lines 2034-2540 while that scratchpad lives; else
   `docs/reference/txt/PCXL_ers.txt` in reversed page order): s.7.3 is the
   unimplemented-exception list, s.7.4.1 the D-bit rules, s.7.4.3 the
   compare queue and FTEST conditions. ACD chapter 6 table 6-20 has the
   IEEE default results.

## Facts you need (found the hard way this session)

- **The engine reads its inputs throughout an operation** (`op`, `sgl`,
  `dsgl`, `cond`, `a`, `b`, and `rm`/`dmode`/`enables` from the FPSR).
  `pa_fpunit` therefore holds them in `hold_*` registers from the start
  cycle to `done`. Keep that if you restructure the issue path.
- The FPSR cannot change while an operation is in flight (no FP instruction
  commits then) -- the engine's live reads of RM/D/enables rely on it. If
  FP loads are allowed to overlap an operation (step 3), FLDW/FLDD to fr0
  must still wait.
- **FRND is unimplemented on the PCX-L** (sets T, result untouched); QEMU
  rounds. It was moved out of the `fp` suite into `fpedge` only. Once T is
  set, *every* FP instruction except FSTD fr0 takes trap 14, so a suite that
  provokes the unimplemented exception must store the status with FSTD fr0
  first (that clears T) before any other FP store.
- FMPYSUB's second operation is **ta <- ta - ra** (not ra - ta); FMPYADD is
  ta <- ra + ta; FMPYCFXT (ra = 0) is ta <- FCNVFXT(ta) into ta's left word.
- The register-specifier bits of 0E: r1's half at PA bit 24, r2's at 19, t's
  at 25; 06/26 singles map 0-15 -> fr(16+s)L, 16-31 -> fr(s)R; class 1
  (conversions) puts sub at PA 14:16, df at 17:18, sf at 19:20, the other
  classes sub at 16:18 and fmt at 19:20 (`pa_fpunit` decode, checked
  against QEMU's `insns.decode`).
- Quartus retimes registers across stages; the fit report's worst path is
  then a merged chain. To see the RTL stages, fit once with retiming off
  (section 4.3 shows how) and read the per-destination slacks.
- Fitter seed moves this design by ~2 MHz (fit 8 -> 9); do not conclude from
  one seed.

## The task

### 1. Fit 10 -- the FPU's timing and area

- Run `scratch/cpu_fmax/run.sh cpu_fmax_pipe` on the committed tree (no other
  change in the same fit). Log the result as fit 10 in `cpu-timing.md`
  (table row + a 4.5 section: Fmax, ALMs, registers, DSPs, `pa_fpunit` /
  `pa_fpu` area, the worst path).
- Expect: the 53x53 multiplier (`prod <= mul_a * mul_b`, one registered stage
  after `mul_a/mul_b`) in DSP blocks, probably the worst path -- split it
  (two registered stages, cpu.md 6.11 says 2 cycles) if it is; the
  normalise/round path (`lzc58`, the 58-bit shift, `pk`) is the next
  candidate -- `S_NORM` and `S_ROUND` are already separate cycles, so a
  further split costs one cycle per operation. The FR file's three
  asynchronous MLAB read ports feed the engine's start cycle from W
  (`rd_a/rd_b` -> `opnd` -> `eng_a/eng_b` -> the engine's registers): if
  that is long, register the operands one cycle before the start (the
  issue is at W commit, the pipeline does not wait for it).
- If the integer paths got worse only by placement, try seed 1 and 3 before
  changing RTL -- one fit at a time, always.
- Gate: 64 MHz with the FPU; area noted against the 8-10k budget (the TLB's
  flip-flop payload, 4.2 cut M3, is the known place to buy area back if the
  system needs it).

### 2. fpedge expectations (S-013)

Goal: `tests/run-cputest.sh fpedge` checks every vector against a Python
model of the PCX-L rules, the way `cache`/`tlbx` carry generator-computed
`expect` words (see `model.py` for how those suites are dispatched).

- **Change the fpedge vector code** in `gen_fp_common` (edge only) so a
  vector survives the unimplemented exception: after the operation, store
  `fstds %fr0, 8(%r9)` **first** (status with T, exception register 1;
  clears T), then `fstds %fr6, 0(%r9)` (the result or the untouched
  sentinel), then `fstds %fr1, 16(%r9)` (exception registers 2 = {code,
  insn bits 6:31} and 3). FP_WORDS becomes 8 for fpedge (fstds needs 8-byte
  alignment; 6 words + pad). Keep the status reload (`fldws 0(%r3), %fr0`)
  per vector: it clears T and the flags.
- **The model** (`tests/cpu/model.py`, new `predict_fpedge`): classify the
  operands (zero, denormal, normal, inf, qNaN, sNaN -- PA-RISC's sNaN has
  fraction MSB = 1); apply ERS s.7.3: any NaN operand, any denormal operand
  (D = 0), FRND, quad/reserved forms, FCNVFX/FCNVFXT overflow, a tiny result
  with D = 0, and any IEEE exception whose enable is set -> unimplemented:
  fr6 untouched (sentinel), FPSR = RM | T, fr1L = {code (001001 for 0C,
  001011 for 0E, 000011 for 06, 100011 for 26), insn & 0x03FFFFFF}.
  Otherwise the IEEE default result and flags (ACD table 6-20): inf - inf,
  0 x inf, 0/0, inf/inf, sqrt(-x) -> the default qNaN (0x7FF4000000000000 /
  0x7FA00000) with V; x/0 -> inf with Z; overflow -> inf or the largest
  finite by rounding mode with O and I; results that are exact stay exact.
  Compute correctly rounded results with `fractions.Fraction` (exact
  rational arithmetic, then round to the format in the 4 modes) -- not with
  Python floats, which are doubles and would round twice for singles.
  FCMP: C and the queue advance (`status[11:20] := status[10:19]`,
  `status[10] := status[5]`, `status[5] := C`); sNaN, or qNaN with a
  trapping condition (bit 0 of the 5-bit cond), -> unimplemented.
- Cross-check the model against the engine's unit bench on the `fp`
  vectors first (`unit_vectors.py` can take the model as the expectation
  source the way `alu` does), then run fpedge on the whole CPU. Where the
  model and the RTL disagree, the ERS decides; record any PCX-L behaviour
  you had to guess in STUBS S-013 (or retire S-013 when the suite is green).
- Add `fpedge` to `run-cputest.sh`'s default list when it passes.

### 3. FPU overlap (S-012)

Today: an FP operation issues at W commit; any FP instruction waits in D
while an operation is in E/M/W or in flight (`fp_pending` in `pa_core.sv`).
Correct, but every FP instruction pays the previous operation's latency.

- First measure what it costs: count the D-stall cycles due to `fp_pending`
  on the fp suite (add a counter to `cputest_top.sv` or the harness) and
  decide whether it matters before the system can run HP-UX; if not, leave
  S-012 as it is and move on.
- If worth doing, the cheap half: let FP **loads and stores** proceed past
  an in-flight operation when they do not touch its destination (a per-FR
  busy bit set at issue, cleared at the write; FLDW/FLDD/FSTW/FSTD of
  fr0-fr3 and FTEST still wait; a store of the pending destination waits).
  The FR file then needs its two write ports to be real (load write and
  engine write can coincide): two MLAB banks with a live-value table like
  `pa_regfile`, or a one-cycle stall of the load when the engine's `done`
  is in the same cycle.
- The full version (cpu.md 6.11 "planned"): issue from E with the
  scoreboard, so independent FP operations queue behind the engine without
  blocking integer instructions in D. Keep "neither result written if either
  half traps" for FMPYADD/SUB/CFXT and the order of FPSR updates.
- Every change here reruns `make -C verilator tb_fpu`, `run-cputest.sh`
  (all suites incl. fp) and `run-cosim.sh`, then a fit.

## Gates and rules

- `tests/run-cputest.sh` (11 suites: alu1 alu2 shift max1 mem branch trap sys
  cache tlbx fp) stays green on every commit; `tests/run-cosim.sh` stays
  identical (it covers the integer suites only).
- A step is done when it passes its tests **and** its timing is measured.
- **One Quartus flow at a time, strictly sequential** -- the user insisted:
  `pgrep -a quartus` first, finish and read one fit before starting the
  next, no seed sweeps in parallel. Quartus 17.0.2 at
  `~/intelFPGA_lite/17.0/quartus/bin`; run fits in the background with a
  single completion wait, ~10 minutes each.
- Commit small and often, with explicit paths, in the project's message
  style ("CPU: ..."); never commit `roms/`, `docs/reference/` PDFs or scratch.
- Every stub goes in `docs/STUBS.md` in the same change; never delete
  anything without asking; do not edit `sys/`.
- The CPU revision is **2** (DR0 bits 0:5, decided by the user); the ROM
  loader patches offset 0xB810 until dual issue exists (S-011). Do not
  change it.
- QEMU 11.1.1 (`-M 715`) is not ground truth: its FP traps are immediate, it
  implements FRND, its FID reports a different model, its FCMP does not
  advance the compare queue. The built binary is in the previous
  scratchpad's `keep/qemu/build-hppa/` (path in `tests/cpu/run_qemu.py`);
  `make -C tests/cpu qemu` regenerates the references for the suites QEMU
  can run (`QEMU_SUITES` in the Makefile).
