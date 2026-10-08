# Resume prompt -- CPU: the PA-7100LC floating-point unit (for a Fable session)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
Your job is the **FPU**: finish the floating-point arithmetic engine
`rtl/cpu/pa_fpu.sv`, integrate it into the pipelined core `pa_cpu`, make the
`fp` suite pass against QEMU and the `fpedge` suite against the PCX-L rules,
and keep the whole CPU at **64 MHz**. Everything else of the CPU exists and is
tested (pipeline, caches with diagnose access, TLB with the hardware walker).

## Read first

1. `CLAUDE.md` -- project state, decisions, layout, tools, rules (binding).
2. `docs/design/cpu.md` sections **3.5** (delayed FP traps), **4.3.12** (every
   FP instruction and its encoding), **6.11** (the FPU design), 5.1 (CCR,
   FPSR identity), and section 6.3 (hazards: "FP register busy / FPU busy /
   FCMP pending for FTEST").
3. `docs/design/cpu-timing.md` -- the fits so far and how `scratch/cpu_fmax/`
   measures them; fit after every step.
4. `docs/STUBS.md` -- S-005 is the FPU's own entry; P-016 covers latencies.
5. `tests/cpu/README.md`, then `gen_fp_common` in `tests/cpu/gen_tests.py`
   (the `fp` and `fpedge` suites: operands, rounding modes, what is stored).
6. The PA-7100LC ERS chapter 7 (forward copy
   `/tmp/claude-1000/-home-dani-repos-hp9000-715/c636bb42-9bcf-47e9-83f8-8ade60a40f61/scratchpad/keep/doc-review-text/pcxl_fwd.txt`
   lines 2034-2540 while that scratchpad lives; otherwise `docs/reference/txt/PCXL_ers.txt`,
   reversed page order) and the ACD chapter 6 (`docs/reference/txt/Pa11_acd.txt`
   lines ~11100-12100: status register, exception registers, tables 6-13..6-20).
7. QEMU's `~/src/qemu-11.1.1/target/hppa/insns.decode` lines 460-600 for the
   0C/0E register-specifier formats (the single-word L/R bit positions: r1's
   at PA bit 24, r2's at bit 19, t's at bit 25 in 0E; FLDW/FSTW's at bit 25;
   the FMPYADD single mapping is QEMU's `fmpyadd_s_reg`: specifier 0-15 ->
   fr(16+r)L, 16-31 -> fr(r)R).

## Status update (2026-10-07, later session): steps 1 and 2 done

- **Step 1 done:** `make -C verilator tb_fpu` replays the fp suite's 1360
  vectors through the engine alone (QEMU's results as expectations): 0
  mismatches; the 80 "unimplemented" are FRND, by design. Fixed on the way:
  the restoring divide never produced the units digit (now 56 steps against
  2b), the square root fed a 162-bit radicand into 81 steps (now m << 56, 55
  steps) and mixed signed/unsigned in its exponent.
- **Step 2 done:** `rtl/cpu/pa_fpunit.sv` (FR file, FPSR + compare queue +
  exception registers, the W-stage decode of the operation word, FMPYADD/
  SUB/CFXT sequencing, the unimplemented exception) is wired into `pa_cpu`;
  the core decodes 09/0B as FP loads/stores with a doubleword size and a
  64-bit data path, traps 22/14 as sec. 3.5 says, FTEST nullifies from E.
  Simplification: one operation at a time, every FP instruction waits in D
  while one is pending (STUBS S-012). **`tests/run-cputest.sh fp` passes
  (1300 vectors)**, all other suites too; FRND was moved out of the `fp`
  suite (the PCX-L traps on it; QEMU rounds).
- **Not done:** step 3's `fpedge` expectations (STUBS S-013), step 4's fit
  (cpu-timing.md section 5, "fit 10"), the ROM's FP tests in the system
  simulator. The CPU without the FPU meets 64 MHz (fit 9: 65.1 MHz, seed 2).

The text below is the original handoff.

## Where the FPU stands (2026-10-07, end of the previous session)

- `rtl/cpu/pa_fpu.sv` is a **first draft of the arithmetic engine, untested
  and not yet instantiated**: one multi-cycle operation at a time
  (`start`/`done`), the PCX-L exception model of ERS s.7.3 (every NaN /
  denormal / enabled-trap / tiny-with-D=0 case -> `unimpl`, the delayed
  trap; IEEE default results and flags otherwise; D = 1 flushes), add/sub
  with alignment + 3 guard positions + sticky, multiply through a registered
  53x53 product (DSP blocks), restoring divide (56 cycles), digit-by-digit
  square root (81 cycles), FCNVFF/XF/FX/FXT, FCMP with the 5-bit condition
  and PA-RISC's NaN convention (fraction MSB 1 = signalling; default qNaN
  0x7FF4000000000000 / 0x7FA00000), XMPYU on the multiplier. Single operands
  travel left-justified in bits 63:32. It lints under Verilator; **nothing
  has been simulated**. Expect bugs in the exponent bookkeeping of the
  normalise/round path (`re`, `rsig` bit 57 convention), the square-root
  scaling and the integer conversions -- write a unit bench first
  (`verilator/tb/`, like `tb_alu.cpp`) replaying the `fp` suite's QEMU log
  vectors through the engine alone, as `tests/cpu/unit_vectors.py` does for
  the ALU.
- `pa_pkg.sv` has `fpu_op_e`; `pa_decode.sv` still maps every FP major
  (06, 09, 0B, 0C, 0E, 26) to `FU_FP` + `assist` (trap 22). `pa_core_seq`
  (the sequential reference core) has no FPU and never will; the lockstep
  co-simulation (`tests/run-cosim.sh`) therefore cannot cover FP suites.

## The task

1. **Unit-test the engine** against QEMU's `fp` log vectors (finite normal
   operands, all rounding modes, converts, compares, XMPYU) and fix it.
2. **Integrate** (cpu.md 6.11, 6.3):
   - `pa_fpu_regs`: fr4-fr31 as two 32-bit halves in MLABs, 3 read ports
     (2 operands + 1 store), 2 write ports (FPU result, FP load); fr0-fr3
     (FPSR + 7 exception registers) in flip-flops. FPSR layout (Verilog
     bits): flags V Z O U I = [31:27], C = [26], CQ = [21:11], RM = [10:9],
     T = [6], D = [5], enables V Z O U I = [4:0].
   - decode of 0C / 0E (classes 0-3, the L/R specifier bits, formats), 06/26
     (FMPYADD/SUB, FMPYCFXT when ra = 0), 09/0B (FLDW/FSTW/FLDD/FSTD indexed
     and short, uid 0/1; other uids -> trap 22), COPR,0,0 (FID -> FPSR model
     0x0D rev 0x01 = 0x000D0800), FTEST with the ERS s.7.4.3 clip conditions.
   - trap 22 only when CCR{0,1} != 11 (CR10 bits 24:25 = `ccr[7:6]` in
     `pa_core`), not for every FP instruction as now.
   - issue the operation **at W commit** (so an older instruction's trap
     never leaves a started op), operands read in D/E and carried; stall any
     FP instruction in D while the FPU is busy (simplest correct version:
     no overlap; P-016 notes it); FPSR.T = 1 at the next FP instruction ->
     trap 14 with IIR = that instruction, except FSTD fr0 (stores the status
     with T, then clears T); the excepting instruction's word with the code
     from ACD table 6-18 goes into exception register 2 (fr1L) -- codes
     001001 (0C), 001011 (0E), 000011 (06), 100011 (26).
   - FP loads/stores need a **64-bit data path**: the D-cache already
     merges a full doubleword (`m_stdw`) and the uncached port carries 64
     bits; `w_ld` / `m_ld` / `m_stdata` are 32-bit today. FLDW/FSTW use one
     half (uid selects L/R), FLDD/FSTD the whole register; I/O-space FLDD/
     FSTD are 8-byte uncached transfers (cpu.md 5.8).
   - FMPYADD/FMPYSUB/FMPYCFXT: multiply then add (or FCNVFXT of ta) as two
     sequenced engine operations; if either is unimplemented, neither
     result is written and no flag is set.
   - FCMP shifts the compare queue (ERS s.7.4.3); FTEST reads C / CQ in E
     (the previous FCMP has completed because of the busy stall).
3. **Tests**: `tests/run-cputest.sh fp` (QEMU reference, `--ref`); `fpedge`
   needs expectations by the PCX-L rules, not QEMU's immediate traps --
   either a Python model of ERS s.7.3 in `tests/cpu/model.py` (the way the
   `cache`/`tlbx` suites carry generator-computed `expect` words) or a
   reduced fpedge comparison; add the ROM's FP tests 0x44080-0x44082 as the
   integration check once the system session can run the ROM.
4. **Fit** (`scratch/cpu_fmax/run.sh cpu_fmax_pipe`, add the new files to
   `cpu_fmax_pipe.qsf`) and log it in `docs/design/cpu-timing.md`: the
   multiplier (two registered stages) and the rounding step are the paths
   to watch; 64 MHz is the gate.
5. Update `docs/STUBS.md` (retire the FPU part of S-005, add what is
   simplified: latencies, no overlap), `CLAUDE.md`'s layout row, and commit
   as steps land ("commit it and keep going" stands).

## CPU revision (DECIDED 2026-10-07: the user chose a value in 1..0xB; implemented as 2)

**Decision:** `CPU_REVISION = 2`. Consequences: the ROM runs the dual-issue test, so the system's loader patches ROM offset 0xB810 (STUBS S-011) until a later task (the user: "probably a task for Opus") makes the core pass it; Linux gets the Gecko-style soft-power answer; HP-UX 10.20 stays on its trap-7 gateway path (rev < 0xC). The table below is the analysis that preceded the decision.

`pa_cpu #(.CPU_REVISION(...))` sets DR0 bits 0:5. The facts
(`docs/review/07-hpux-cpu-specifics.md` section 1):

| Option | What it takes | HP-UX 10.20 | Linux | ROM |
|---|---|---|---|---|
| **A: revision 0** (today's default) | nothing | works, but on its pre-production gateway path: every system call takes trap 7 and is emulated (`normal_gate = 0` for rev < 0xC) | **unsafe**: PDC_SOFT_POWER returns without writing its result at rev 0, Linux takes a stale word as the soft-power register address, polls it every second and may bus-error (HPMC) or shut down | skips the cycle-exact dual-issue self-test 0x4108D |
| **B: revision 0xC** (what a real 715/64 reports) + one ROM word patched by the system's ROM loader (file offset 0xB810: 0x86802012 -> 0xE8000012, `b,l,n` over the dual-issue test) | the patch | the native gateway page (B,GATE promotion, no per-syscall trap) and the Gecko-style soft-power poll of DR25 bit 0 | the same poll; safe | identical flow to rev 0 at the patched word; `set_dr0` writes DUAL_DIS = 00 (stored, no effect) |
| C: revision 0 + two ROM words (versions -> 0xC, SOFT_POWER rev check) | two patches | as B | as B | MIOC control bit 14 still cleared |
| D: any revision >= 0xC unpatched | nothing | as B | as B | **runs the dual-issue timing test**, which a single-issue core fails |

**Recommendation: B.** It is the only option that gives both OSes exactly
what a real 715/64 gives, at the cost of one ROM word that the system stream
applies when loading `boot.rom` (a `docs/STUBS.md` entry, since the ROM
image on the SD card stays HP's). If the user rules out patching the ROM,
A is acceptable for HP-UX 10.20 only and Linux's power driver must be kept
off. Until the user decides, `CPU_REVISION` stays 0; the change is one
parameter on `pa_cpu` plus `docs/design/cpu.md` 0/5.1/8.4-Q3 and
`CLAUDE.md`'s "Decisions" row, and `cpu-requests.md` #2 records the choice.

## Gates and rules (unchanged)

- `tests/run-cputest.sh` (all 10 integer/system/cache/TLB suites) stays
  green on every commit; `tests/run-cosim.sh` stays identical (the cosim
  ends at the first `mfctl cr16`, which is timer-dependent code).
- A step is done when it passes its tests **and** its timing is measured.
- You own `rtl/cpu/`, the CPU tests and benches; the system stream files
  requests in `docs/design/cpu-requests.md`. Commit with explicit paths.
- One Quartus flow on this box at a time (`pgrep -a quartus` first); Quartus
  17.0.2 at `~/intelFPGA_lite/17.0/quartus/bin`. Launch long flows with
  `setsid nohup ... &` (a plain `nohup ... &` from a tool call was killed
  once with its shell).
- Every stub goes in `docs/STUBS.md` in the same change; never delete
  anything without asking; do not edit `sys/`.
- QEMU 11.1.1 (`-M 715`) is not ground truth: its FP traps are immediate,
  its FID reports model 0x0F, its NaN handling follows softfloat. The built
  binary is in the previous scratchpad's `keep/qemu/build-hppa/` (see
  `RESUME-20261007-cpu-64mhz.md` for the rebuild recipe).
