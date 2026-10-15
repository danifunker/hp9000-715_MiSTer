# Resume prompt -- CPU speed after fit 57: stall-on-use, cheaper E redirects, then dual issue (2026-10-15)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`
as the **CPU owner** (`rtl/cpu/`). The user asked for CPU speed work on
2026-10-14 ("start working on those speed fixes") and for this plan on
2026-10-15. Every step below needs the user's go-ahead before it is built
(user rule of 2026-10-09: no CPU change without their call), so propose,
show the numbers, then implement.

## Read first

1. `CLAUDE.md` (the rules: one Quartus flow and one simulation at a time,
   never beside each other; `pgrep -a quartus` first and never kill a flow
   that is not this project's; STUBS entries; never delete without asking;
   commit often with the Fable trailer; no `pkill -f`).
2. `docs/design/cpu-timing.md` sections 5-8 (fits 16-19: what was done,
   how it was measured, which paths were critical) and section 9.
3. `docs/design/cpu.md` 6.1-6.2 (the pipeline, the redirect rule), 6.6
   (misses complete in W), 7-8 (PCX-L specifics, dual issue references).
4. `docs/STUBS.md` P-008 (dual issue), P-016 (not cycle-exact), S-011 (the
   ROM word patched so the dual-issue self-test 0x4108D is skipped).
5. `docs/design/area-plan.md` (where the ALMs are; Tier A/B savings not yet
   made: A5, A6, A9, A10, A11, B2-B8).
6. The memory notes `cpu-perf-method` and `misterkvms` (how to measure, how
   to drive the board).

## Where the core is (2026-10-15)

* **Build 57** = the performance core: D-cache misses complete in W (no
  replay), a D-predicted branch target looked up in the redirect cycle,
  three timing cuts (F2 target adder, registered TLB operation, the FPU's
  store select from the decoded size). Fit: core clock **-0.009 ns** on one
  path (the next +0.012), 36,434 ALMs (87 %). On the board it boots HP-UX
  11.11 to CDE; commits `2d5e327`, `372bb69`, `9182259`.
* The `tests/cpu` **perf suite** (`gen_perf`, `perf_report.py`): fit 15 ->
  fit 17: a missed load 33 -> 25 cycles, a missed store 30 -> 22, the
  load-then-use case 29 -> 21, memcpy 12.3 -> 9.5 cycles per word, a taken
  loop branch 2 -> 1 bubble, the suite -17 % cycles.
* The remaining failing path (fit 57, `quartus_sta report_timing`, see
  cpu-timing.md 8): W's FP store data -> the store-to-load forward into M
  (`m_rdata`) -> the M -> D bypass -> `e_gra` (retimed into the ALU's operand
  mux by physical synthesis) -> `opa_sh`. Seeds 1-3 were worse (-0.36,
  -0.36, -0.98); seed 4 is in the QSF.
* The 11i TCOE install on build 53 took 8 h 50 m (Finish 14:08 -> the
  kernel linkstamp 23:00, 2026-10-14; fileset 356/977 after 2 h 02 m). A
  second install on build 57 started 11:37:33 on 2026-10-15 (installer
  clock), fresh image `hpux1111b.img` at ID 5; the 13:10 checkpoint (1 h
  32 m) gives the fileset ratio -- the user did not want to wait for the
  whole run. The installed system is `hpux1111.img` (ID 5, primary path
  scsi.5 in the mounted `hp715_release.eep`).

## The plan, in order (each step: perf suite old/new, cputest 13/13, cosim,
## run-rom, then a fit; the HP-UX boot in romsim before a board build)

### Step 1 -- close the last 0.009 ns (small)

The FP-store forward path above. Options, cheapest first:
* Keep FP stores out of the one-cycle forward `fwd1` in `pa_dcache`: when
  the store in W is `w_c.fpm`, hold M for one cycle instead (the RAM write
  then lands and `fwd2`/`prev_st_data`, a register, serves the load). The
  hold condition must not go through `adv`'s critical fanout: gate
  `dc_m_hit` low for that cycle (the load then looks like a miss and
  completes in W from the filled/present line -- it hits on the re-read).
* Or register `fp_st_data` at the M -> W move from `m_insn` with a bypass of
  an FR write committing in the same cycle (riskier: the FPU's ordering).

### Step 2 -- stall-on-use (medium, est. 300-500 ALMs, 5-10 % on miss-heavy code)

Today a D-cache miss holds the whole pipeline until the line is in. The real
chip lets instructions that do not need the load's result continue. Design:
* The missed load leaves W into a one-entry "pending load" register (rt,
  size, EA, the fill in flight); W commits the following instructions.
* D interlocks any instruction that reads the pending rt (extend `ld_use`),
  any load/store (the cache engine owns the port; or allow hits to other
  lines if the engine's port split allows -- first version: interlock), and
  anything that needs the pipeline drained (traps, serialising ops).
* When the fill completes the pending load's GR write goes through the
  second write port in a cycle where it is free (base updates use it;
  arbitrate: hold D for a cycle if needed).
* Traps while a load is pending: the load is older, its trap (bus error)
  must be taken precisely -> keep pending loads only when the fill cannot
  fault (RAM range) or take the HPMC imprecisely as the chip does (HPMC is
  imprecise on PA-RISC; check cpu.md 3).
* Stores on a miss: already write-allocate in W; a pending store register
  is the same shape (the chip has a store queue).
* Measure with perf `ld-stride32`/`memcpy-32k` and a new kernel with
  independent ALU work after each missed load.

### Step 3 -- one-cycle E redirects (small, ~50 ALMs)

BV/BE/BLE/BLR and mispredicts still cost two bubbles: fit 17's immediate
issue applies only to D's prediction because E's target comes out of the
ALU too late for the I-cache's address register. Options: register
`br_target` into a fetch-side register at E -> M and issue from it the next
cycle anyway (saves nothing), or compute BV's target (`fb + fa << 3`, the
common `bv r0(rp)` has fa = 0) in D from D's bypassed operands when the
operands are not being forwarded from M (a "predicted BV" with E checking
it: the mispredict path exists). Measure with a call/return kernel.

### Step 4 -- dual issue (large: 5-8 sessions, est. 2,500-3,500 ALMs, 1.2-1.35x on integer code)

Do the area plan's remaining Tier A/B items first (A5, A6, A9, A10, A11,
B2-B8; about 1,000 ALMs) -- the design is at 87 % with a router that gave
up at 89 % once (build 34).

The PA-7100LC's pairing rules (OpenPA "PA-7100LC" table 2.20; ERS s.5.2;
`docs/review/02` has the chip docs):
* one integer-unit instruction (ALU/shift/MAX-1, conditional branch) paired
  with one load/store or FP instruction per cycle;
* both from the same aligned doubleword (the fetch delivers 64 bits; the
  caches already hold doublewords);
* no data dependency between the pair, no two memory operations, a branch
  only in the first slot with its delay slot alone or paired by the rules,
  nothing nullified in the second slot that the first decides, no
  serialising/system instruction paired;
* the DIAG instructions never pair (cpu.md 5.x).

**The cheap shape first (user's question 2026-10-15, "a smarter second
ALU"): the pair is asymmetric, as the chip's is.** Slot A = the existing
integer pipeline unchanged. Slot B = a load/store or FP instruction only:
an address adder (base + disp / base + index << scale, ~60 ALMs), no
shifter, no ALU; the FP unit is already separate. Cut the cost where it
really is:
* read ports: slot B reads base/index from a second MLAB copy of the
  register file (~250 ALMs), not a 4-port file;
* **no bypass into slot B** in the first version: a pair issues only when
  B's base and index are not written by the instructions in E, M or W
  (register-number compares in D); else B issues alone next cycle, as today.
  This keeps the E-stage operand muxes as they are (the critical paths);
* **no base-modify in a pair** (`,ma`/`,mb` loads and stores issue alone),
  so W's two write ports suffice (A's result, B's load data);
* a cut-down decoder for B (loads, stores, FP ops and their fields);
* B is always the younger: a trap in A kills B, a trap in B commits A;
  nullification flows A -> B only; no branch in B.
Estimate 1,200-1,800 ALMs, pairing rate ~10-15 % cycles saved on real code
(the chip's 20-35 % needs the bypass into B -- a later step). Below, the
full-rule version for reference.

Design sketch for our pipeline (cpu.md 6.1):
* F2 delivers the doubleword with two valid bits; D decodes both words
  (second `pa_decode`), checks the pairing rules on the control words and
  the register fields, and issues one or two. The IAOQ of the second slot is
  the first's + 4 (same space); the pair carries one `iaoq_f` and a "pair"
  flag.
* E: a second integer datapath (ALU + shifter; the first slot's ALU stays
  the AGU for the memory slot -- or the reverse: the memory op in slot B
  uses a dedicated AGU adder, ~100 ALMs, and the ALU stays in slot A).
  Register file: 4 read ports (MLAB duplication: the file is already 2R2W
  MLABs, each extra read port is another copy = ~250 ALMs for 32 x 32),
  one more write port for the pair's two results plus the base update
  (three writes: either stall pairs with a base-modify, or a third port).
* Bypasses: each stage has two producers; D's 4-way and E's 3:1 muxes grow
  to 6-7 inputs -- this lands on the critical E paths; budget a fit per
  design choice (`scratch/cpu_fmax/run.sh`, cpu-timing.md 2-4 for the
  method).
* M/W: the pair commits together; a trap on the first slot kills the second;
  a trap on the second commits the first (IIAOQ = the second's); nullify
  rules per cpu.md 6.2 with the "next instruction" being the pair's second
  or the next pair's first; `dbg_retire` twice per cycle (the recorder and
  cosim need a two-slot retire interface: `verilator/cosim/` compares retire
  events in order -- extend it to pop two).
* The ROM's self-test 0x4108D (BOOTFLOW.md 4.2, S-011) times a dual-issue
  sequence against CR16 and expects the pairing to be exact: either pass it
  (the test is the spec of the minimum pairing) or keep the loader's patch.
  cpu-requests #2 / cpu.md Q3 has the history.
* Gates: cputest 13/13 (every suite exercises pairs implicitly; add a `pair`
  suite from the OpenPA table: each legal pair, each illegal one, with the
  perf counters checking the cycle count), cosim identical, run-rom, the
  HP-UX boot in romsim, the perf suite, then a fit and the board.

## Measuring

`tests/cpu/perf_report.py` on `verilator/obj_dir_ct/perf.hex`; build the
previous core in `scratch/oldcore` for the baseline (memory
`cpu-perf-method`). For the board: `misterkvms-cli` screenshots and keys;
the install's fileset counter against 2026-10-14's run (fileset 356 at
2 h 02 m, 738 at 5 h 35 m, done at 8 h 50 m) is the end-to-end number.
