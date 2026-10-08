# CPU timing and area log -- PA-7100LC core on the DE10-Nano

Target: **64 MHz** (15.625 ns), the real 715/64's clock, on the Cyclone V
5CSEBA6U23I7 with Quartus 17.0.2 Lite. Every fit below is a standalone
project in `scratch/cpu_fmax/` (gitignored; `run.sh <revision>` runs
map + fit + STA and writes `output_files/<rev>.fmax.txt`,
`<rev>.paths.txt`, `<rev>.paths_full.txt`): the CPU alone, every port
registered in a wrapper (`top_seq.sv`, `top_pipe.sv`), virtual pins, the
real device, the same optimisation settings as `HP9K715.qsf`, seed 1, one
clock at 64 MHz, slow 1100 mV 100 C corner. Fmax figures swing by 2-3 MHz
between fits of near-identical RTL (the PowerPC core's experience on the
same device); the paths are what to judge by.

## Fits

| # | Date | Commit / RTL | Top | Fmax | Worst slack | ALMs | Regs | M10K | DSP | Notes |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| 1 | 2026-10-07 | 2950b41 `pa_core_seq` (sequential bring-up core) | `top_seq` | **51.6 MHz** | -3.77 ns | 7,314 | 7,511 | 0 | 0 | baseline, section 1 |
| 2 | 2026-10-07 | pipelined `pa_cpu` (uncached fetch and data, no caches/TLB/FPU) | `top_pipe` | **72.5 MHz** | +1.83 ns | 4,849 | 6,179 | 0 | 0 | 64 MHz met; section 2.2 |
| 3 | 2026-10-07 | + 128 KB L2-I, 1 KB L1-I, 128 KB L2-D with diagnose access, fills/write-backs on the line port | `top_pipe` | **71.0 MHz** | +1.53 ns | 6,507 | 7,862 | 291 | 0 | 64 MHz met; section 3.2 |
| 4 | 2026-10-07 | + UTLB (64 page + 8 block entries, DR8), virtual mode in both caches (space hash), protection checks, PROBE/LPA, the hardware walker, the I-LAB | `top_pipe` | **56.3 MHz** | -2.13 ns | 10,385 | 11,723 | 291 | 0 | 64 MHz **missed**; section 4.2 |
| 4b | 2026-10-07 | fit 4's RTL with register retiming off (diagnostic) | `top_pipe` (`cpu_fmax_pipe_nort`) | 51.5 MHz | -3.79 ns | 9,107 | 9,828 | 291 | 0 | per-stage slacks; section 4.3 |
| 5 | 2026-10-07 | + cuts F, A, M1, M2, M3 of section 4.3; CPU revision 2 | `top_pipe` | **62.8 MHz** | -0.31 ns | 12,070 | 14,923 | 291 | 0 | 1.2 MHz short; section 4.3 |
| 6 | 2026-10-07 | + the W-stage TLB operations share the lookup CAM (4.4) | `top_pipe` | **59.0 MHz** | -1.34 ns | 10,635 | 14,162 | 291 | 0 | -1.4k ALMs, but the tag select hurts; section 4.4 |
| 7 | 2026-10-07 | + the operation's CAM cycle as a registered state (S_CAM), tag select from state only | `top_pipe` | **53.6 MHz** | -3.04 ns | 11,106 | 14,436 | 291 | 0 | worse: the operation's tag path; section 4.4 |
| 8 | 2026-10-07 | + the operation's tag registered in the TLB at acceptance | `top_pipe` | **63.1 MHz** | -0.23 ns | 11,443 | 14,989 | 291 | 0 | best so far, 0.9 MHz short; section 4.4 |
| 9 | 2026-10-07 | fit 8's RTL, fitter seed 2 | `top_pipe` | **65.1 MHz** | +0.25 ns | 11,373 | 14,764 | 291 | 0 | **64 MHz met**; section 4.4 |
| 10 | 2026-10-07 | 1365246 + the FPU (`pa_fpunit` + `pa_fpu`, seed 2) | `top_pipe` | **55.8 MHz** | -2.28 ns | 17,545 | 21,254 | 293 | 4 | 64 MHz **missed**: +6.2k ALMs, the TLB path spread out; section 4.5 |

## 1. Baseline: the sequential core (fit 1)

51.6 MHz, 7.3k ALMs, 7.5k registers. The worst path is the whole
single-cycle structure of the sequential core: GR flip-flop -> 32:1 read
mux (3.7 ns) -> ALU operand select, 33-bit add, condition -> branch/nullify
-> GR write enable, 18.7 ns of data delay for 15.6 available (the clock
network adds 4.6 ns on both ends, so the skew is small). Per unit:

| Unit | ALMs | Note |
|---|---:|---|
| `pa_core_seq` own logic | 5,898 | 32 GR flops + 7 shadows + CRs/DRs (~2.4k flops) and their muxes, the FSM, commit muxes |
| `pa_shift` | 441 | barrel shifter, extract/deposit masks |
| `pa_max1` | 259 | |
| `pa_alu` | 199 | the 33-bit adder with digit carries, conditions |
| `pa_decode` | 173 | |
| `pa_ldst` | 95 | |

The units themselves are not the problem: the ALU is 199 ALMs and the ALU
part of the worst path is ~5 ns. The 32:1 GR mux, the result-to-GR write
path and the sequential core's "everything in one cycle" are. None of this
carries over: the pipelined core keeps GRs in MLABs (2R2W, 7 flip-flop GRs
for the shadows) and splits the path over D/E/W.

## 2. The pipelined core (fit 2)

### 2.1 Structure chosen for 15.6 ns

Six stages, F1-F2-D-E-M-W (cpu.md 6.1 planned five; the fetch is split in
two so the I-cache RAMs can keep their output registers -- an M10K's
clock-to-out is 2.5 ns against 0.6 ns for a flop, and the 16K-deep arrays
add an 8:1 output mux on top -- and so the tag compare / L1-over-L2 select
has its own cycle). Decisions and what they cost, against the real
PA-7100LC (ERS s.5.3):

| Item | Ours | Real PCX-L | Cost |
|---|---|---|---|
| Static prediction (backward conditional branches, BL, GATE taken; forward not; disabled in a branch's delay slot; a nullified backward branch still predicted taken) | decided in **D** from the registered instruction word, redirect at the end of D | decided in the stage the word arrives (its I stage), 0 bubbles | **1 bubble per predicted-taken branch**. Moving the decision into F2 (predecode on the F2 select-mux output + target adder into the next-PC mux, ~12 ns) would remove it; to measure once the caches are in |
| Branch resolve / GR-based branches (BV, BE, BLE, BLR) | in E, redirect at the end of E, unregistered | 1 extra state | **2 bubbles** (1 for the resolve, 1 for the second fetch stage) |
| Load-use | interlock in D on instruction fields 6:10 / 11:15 against the load's target (the real chip's rule, decode-independent so the compare is 2 x 5 bits from registers) | 1 | 1 bubble; LDSID is a late producer too (space read in M) |
| MTCTL (not CR11), MTSP | D stalls until the writer commits | 1-state interlock | up to 3 bubbles (rare; CR11 and PSW C/B/V are forwarded) |
| RFI/RFIR, SSM/RSM/MTSM, DIAG, TLB/cache ops | commit in W, flush, refetch at IAOQ back | freeze 1-3 states | 5 bubbles |
| Interruptions | priority select and entry in W, one cycle | | pipeline flush (5 bubbles to the handler's first instruction) |
| Forwarding | E takes operands from E/M and M/W registers (4 sources + the D-read value); the **selects are decided in D** and registered, so E's operand mux is a plain 5:1 with registered selects; W-to-D write-through bypass for the register file | | 0 bubbles for ALU chains |
| Effective address | taken from the AGU adder's sum, not from the result mux; unaligned check on its two low bits in E | | |
| Uncached loads | issued from W, non-speculative; W holds the whole pipeline until the data is in a register, commits the next cycle | stall | 3-4 cycles each until the caches exist |
| Uncached stores | one-entry store buffer; a bus error on a posted store becomes an HPMC at the next instruction boundary (IIAOQ = the next instruction, not the store) -- STUBS S-006 | | 0-1 cycles |
| Fetch misses | non-speculative: the burst goes out only once D/E/M/W are empty and the store buffer drained (BOOT s.4.5) | | wrong-path fetches never reach the bus |

### 2.2 Result

**72.5 MHz, 4,849 ALMs, 6,179 registers, no block RAM** (the GRs are 4
MLABs). Every integer suite passes on it (`tests/run-cputest.sh`, 10,567
vectors) and the lockstep co-simulation against `pa_core_seq` is identical
on every suite (`tests/run-cosim.sh`).

| Module | ALMs | Note |
|---|---:|---|
| `pa_core` own logic | 2,524 | pipeline registers, forwarding muxes, CRs/DRs, W commit, interruption select |
| `pa_fetch` | 621 | UIB (4 x 64 flops), fetch state, delay-slot patch logic |
| `pa_shift` | 416 | |
| `pa_regfile` | 303 | 4 MLABs (80) + 7 flop GRs + 7 shadows + read/bypass muxes |
| `pa_alu` | 182 | |
| `pa_max1` | 157 | |
| `pa_decode` | 121 | |
| `pa_cr16` | 63 | |
| `pa_ldst` | 58 | |
| `pa_biu` | 49 | |

The 40 slowest paths (1.8-2.1 ns slack, 12.9-13.1 ns of data delay) are
all the **next-PC path** of cpu.md 6.9: E's forwarded operand -> `pa_alu`
operand select and adder -> condition -> branch taken -> `redir_target`
mux -> the fetch unit's `nb` register, and the D-stage variant `d_valid`
-> prediction -> the same mux. Cell by cell: 6 LUT levels + the register
file MLAB read on the way (the D path) and ~1 ns of routing per hop. This
is the ceiling of the E stage; the caches must not lengthen it (their hit
logic lands in F2 and M, and misses act in W).

## 3. The caches (fit 3)

### 3.1 Structure

| Item | Ours |
|---|---|
| Arrays | L2-I and L2-D each: data 16K x 66 (two words + two even-parity bits), tag 4K x 23 ({RPN, dirty, odd dirty parity, even tag parity}); L1-I 128 x 96 ({parities, STEER, RPN, QPAGE, doubleword}). `pa_cache_ram`: the read address register loads on an enable and holds, the output is unregistered |
| I side | the lookup is issued with the address of the instruction entering F1; during F1 the RAMs read, the tags compare (real mode: PA = VA), L1 wins over L2, parity is checked, and the word is registered into F2. An L1 miss with an L2 hit copies the doubleword into L1 when DR0.L1ICACHE_EN. Fills are non-speculative (pipeline drained) through the engine; `lk_valid` makes the fetch unit re-issue a lookup the engine disturbed |
| D side | the RAM address register loads from the AGU sum at the E -> M move and holds while W stalls, so the outputs stay the M instruction's; hit/dirty/parity and the doubleword (with forwarding from the store in W and the one before it) are registered into W; a store hit writes the merged doubleword and the dirty tag in W (one cycle); a miss runs the engine from W (re-read the tag, write back the victim if dirty, fill, then **replay** the instruction: flush and refetch it) |
| W engine ops | FDC/FDCE/PDC, FIC/FICE (+ the four L1 entries), LDCW without a hint (re-check: in the cache if dirty, else invalidate and read-and-clear memory), RDD/RDT/WDD/WDT, RI2D/RI2T/WI2D/WI2T, RI1/WI1 with DR27-29, SET_TAG latch; every younger instruction is flushed afterwards |
| Costs | D-miss: tag re-read 2 + write-back (4 reads + 4 beats) + fill (4 beats) + replay 6 bubbles; I-miss: drain + fill + re-lookup; LDCW (no hint) 3 cycles + flush |

### 3.2 Result

**71.0 MHz, 6,507 ALMs, 7,862 registers, 291 M10K.** Every suite passes
(`tests/run-cputest.sh`, now including the `cache` suite: 137 vectors of
diagnose walks, planted lines, L1-over-L2, dirty/FDC, SMC) and the lockstep
co-simulation against the uncached sequential core is identical.

| Module | ALMs | Note |
|---|---:|---|
| `pa_core` own logic | 2,954 | + the cache engine control, store merge, replay |
| `pa_fetch` | 757 | + I-fill control |
| `pa_icache` | 503 | engine, L1 fill, parity (RAMs: 132 + 12 + 3 M10K) |
| `pa_dcache` | 424 | engine, forwarding, parity (RAMs: 132 + 12 M10K) |
| `pa_shift` | 437 | |
| `pa_regfile` | 314 | |
| `pa_alu` / `pa_max1` / `pa_decode` / `pa_ldst` / `pa_cr16` / `pa_biu` | 183 / 164 / 131 / 79 / 64 / 67 | |

The 16K x 66 data arrays were packed by Quartus as 4K x 2 slices (132
M10K each) rather than the 2K x 5 packing the spec assumed (112): 291 M10K
in all against the ~247 estimate. A `max_depth = 2048` attribute on the
arrays is the next thing to try (-40 M10K; the output mux grows from 4:1
to 8:1).

Slowest paths (1.5-1.8 ns slack): the W-stage decision whether the
instruction in W commits (`hpmc_req`, the trap select) feeding the
store-to-load forwarding select of the D-cache and from there the M-stage
load word into the forwarded operand of E -- i.e. W's commit gate is now
in series with M's data path through `dc_st_we` -> `fwd1`. Registering
the forwarding decision (deciding `fwd1` from W's registered state, not
from the commit gate) is the cut to make when the TLB lookup lands in the
same stage.

## 4. The TLB (fit 4)

### 4.1 Structure

| Item | Ours |
|---|---|
| `pa_tlb` | 64 page entries: tag {space, vpn} + lock-out/lock-in/E/used in flip-flops compared every cycle, the 46-bit payload in an MLAB at the encoded hit; 8 block entries in flip-flops with the mask compare and the assembled RPN; a page hit wins. One combinational lookup port; the W-stage operations (inserts, purges, the walker's inserts) walk their target set one entry per cycle |
| Lookup port | shared: the instruction in M when it translates (loads/stores with PSW.D, PROBE/LPA always, FDC/PDC/FIC with PSW.D, RDTLB) else the fetch unit's I-LAB refill. The space register is read in E (the s/sr rule or IIASQ / ISR for the fast inserts) and registered with the VA, so the M cycle starts at the CAM |
| M stage | CAM -> encode -> payload MLAB -> RPN -> D-cache tag compare (the cpu.md 6.9 path), with the access-rights, PID, B/D/T checks on the payload in parallel; trap 15/17/26/27/19/20/21 flags merged with E's; the U bit and the PA decide cached vs uncached; PROBE's result and LPA's PA are late results (load-use interlock) |
| Hashed index | the space hash of the cache index (DR0 DHASH_EN / IHASH_EN with PSW.D / PSW.C) is applied in E on the way to the RAM address register (5 XORs); every cache operation carries its hash and its RPN |
| Walker | in the W state machine: the hashed PDIR address, one 16-byte read through the D-cache engine (filling on a miss, as the ROM's planted lines need), the V/tag/R checks, IxTLBA + IxTLBP through the TLB port, then replay; failures take 15/17/6 with CR28 per the ERS table (U/N), never when the walker is off |
| I-LAB | one entry in the fetch unit {space, vpn, rpn, execute-ok per PL, AR type}; a miss asks the TLB through the core (M first), an absent page tags the instruction ITLB-miss (it travels as a NOP); IMP and the GATE's page type travel with the instruction |
| Costs | I-LAB refill 1-2 bubbles; walk: ~10 cycles + the PDIR read + 2 TLB ops + replay; TLB ops: 2-3 cycles + flush |

### 4.2 Result

56.3 MHz, -2.13 ns: the TLB in M costs 14.7 MHz against fit 3 and misses
64 MHz by 2.1 ns. Area 10,385 ALMs / 11,723 registers, of which `pa_tlb`
alone is 3,869 ALMs / 4,140 registers (`pa_core` 4,322 incl. the walker
and the hash, `pa_fetch` 734 with the I-LAB, both caches ~950 together).
The M10K count is unchanged (291); the TLB payload is two MLABs.

The 40 worst paths are all the same chain, launched from the registered
M-stage lookup operands (`tlb_lk_space`, `tlb_lk_vpn`) and landing on a
register Quartus retimed into the ALU operand (`opa_sh`), 17.0 ns of data
delay against the 15.6 ns budget:

| ns | segment |
|---|---|
| 4.6 -> 10.2 | the 64-entry CAM compare and its hit encode into the payload MLAB address (`comb~113/122` -> `prot_mem.raddr_a`) |
| 10.2 -> 13.5 | MLAB read (1.6 ns of routing to it, 0.65 ns in it) and the page/block RPN select (`lk_rpn`) |
| 13.5 -> 17.5 | the RPN into the core (`dc_m_rpn`) and the cached/uncached decision from the PA for the load in M (`w_ld`, `w_cached`) |
| 17.5 -> 21.7 | that decision selects the W-stage load data (`wd0`) that is forwarded into E's operand mux and the ALU (`Mux30` -> `opa` -> `opa_sh`) |

So the lookup itself (CAM + encode + payload) takes 9 ns of the cycle and
the load-data forwarding path that consumes its result takes another 8:
the two are in series because the cached/uncached decision for the load in
M is made from the translated PA in the same cycle, and the forwarding
select for E depends on it. The entity report also shows why the TLB is
3.9k ALMs: the W-stage operations (IxTLBA/IxTLBP, the purges, the walker's
inserts, DR8 access) have their own 36-bit comparators over the same 64 page entries
(`op_match`), duplicating the lookup CAM (`match`).

Cuts, cheapest first (none applied yet; the lockstep co-simulation and all
ten suites pass on this RTL):

1. **Register the cached/uncached decision and the forwarding select**:
   decide `w_cached` from the registered PA at the start of W (one more
   bubble only for an uncached load followed by a dependent use, the case
   that already waits for the bus), and take the E forwarding select from
   W's registered state rather than from M's translation. This is the
   fit-3 cut of section 3.2 restated; it removes the 13.5 -> 21.7 tail,
   worth up to 8 ns, i.e. it alone should recover 64 MHz.
2. **Share the comparators**: one CAM, time-multiplexed -- the W-stage
   operations walk entries one per cycle anyway, so they can use the
   lookup port's compare while the pipeline is held. Area only (-1.5k
   ALMs expected), no timing gain, but it is what makes the next cut cheap.
3. **Space compare in E**: the space half of the tag compare (16 bits of
   the 36-bit tag) can be done in E on the registered space and ANDed in M, taking
   ~1.5 ns out of the CAM. Costs one 72-bit register.
4. **One-hot payload**: read the payload from flip-flops through an AND-OR
   over the one-hot hit vector instead of encoding the hit into an MLAB
   address (removes the encode and the 1.6 ns of routing to the MLAB,
   ~2.5 ns; the payload moves from the two MLABs into 64 x 46 flip-flops, so only if 2 and 3 are not enough).
5. **A registered translation** (translate in E for the common case, M
   only checks): the real PCX-L way, but it moves the address generation
   earlier and costs a bubble on every base-register forward; last resort.

### 4.3 Diagnosis without retiming, and the cuts (fit 5)

Fit 4's report is a retimed netlist: Quartus had moved the M/W registers
(`w_ld`, `w_cached`) forward into E's operand path and the E/M lookup
operands forward through the port mux, so its worst chain crossed two RTL
stages and said little about which stage is long. A diagnostic fit of the
same RTL with `PHYSICAL_SYNTHESIS_REGISTER_RETIMING OFF` (revision
`cpu_fmax_pipe_nort`, 51.5 MHz, 9,107 ALMs) gives the stages themselves,
worst setup slack per destination:

| Stage (destination registers) | Slack | Worst path |
|---|---:|---|
| fetch F1 (`f1_iaoq_b`), F2 (`f2_iaoq_b`) | **-3.79 / -3.10** | W result forwarded into E (`wd0` -> `fa` -> ALU operand) -> adder -> `result == 0` -> condition -> `e_taken` -> `redir_slot` mux -> **32-bit compare `n_f1_iaoq_f == redir_slot`** -> the IAOQ-back select -> `f1_iaoq_b` (sload). 18.7 ns, of which ~8 ns is routing |
| M -> W (`w_ld`) | **-2.92** | `m_valid` -> `m_need` -> TLB port mux -> CAM -> hit encode -> payload MLAB -> RPN -> `m_io` -> `m_cached_c` as the **enable of `w_ld`** |
| M -> W from the TLB entries (`w_result`, `w_ld`) | -1.52 | the lookup itself plus one mux (LPA's PA, the enable) |
| D -> E (`e_iaoq_b`) | -0.89 | the same E branch decision into D's slot handling |
| TLB operations (`targets`) | -0.97 | `w_trap` -> the walker's insert request |
| I-cache RAM address | -0.54 | `w_trap` (ITLB) -> redirect -> fetch -> RAM address |
| E -> M (`m_result`), D-cache RAM | +0.05, +0.03 | fine |

So two stages miss, by 3.8 and 2.9 ns, and they are independent of each
other. The TLB lookup (CAM + encode + MLAB) is ~9 ns from its own
flip-flops; the branch path has grown from fit 2 mostly in routing (the
3.9k-ALM TLB sits between the core and the fetch unit).

Cuts applied for fit 5 (all suites and the lockstep co-simulation pass):

| Cut | What | Where | Saves |
|---|---|---|---|
| **F** | the delay-slot compares run from registers, in parallel with the branch decision: `f2_iaoq_f`, `f1_iaoq_f` and `nf` are each compared with both candidate slots (E's `e_iaoq_b`, D's `d_iaoq_b`), and `e_redir` / `adv_f2` / `issue` only select among the six results; the core passes `redir_slot_e`, `redir_slot_d`, `redir_from_e` instead of the muxed `redir_slot` | `pa_fetch.sv`, `pa_core.sv`, `pa_cpu.sv` | the 32-bit compare after `e_taken`: ~2 ns + routing |
| **A** | the ALU's zero flag from the operands, not the sum: a + b + cin == 0 iff (a ^ b) == ((a \| b) << 1 \| cin), two LUT levels in parallel with the carry chain (the logical class keeps `lres == 0`) | `pa_alu.sv` | the adder + result mux + 32-bit zero reduce on every `=`/`<>` branch: ~2.5 ns; `<` and `<<` still wait for the chain |
| **M1** | `w_ld` captures the aligned cache word unconditionally (an uncached load overwrites it at its ack), so the translated PA is no longer the enable of 32 flip-flops | `pa_core.sv` | the TLB out of the data path; `m_cached_c` now only feeds `w_cached` |
| **M2** | `m_need` (the instruction in M translates) is a register set at E -> M, so the TLB port mux is one LUT from flip-flops instead of `m_valid` (high fanout) -> decode -> mux | `pa_core.sv` | ~1.4 ns at the head of the lookup |
| **M3** | the payload (RPN + protection, 46 bits) in flip-flops, read by an AND-OR over the one-hot `match & valid` instead of a hit encoder addressing two MLABs; the used-bit update is `used \| sel` | `pa_tlb.sv` | the encoder, the routing to the MLAB and the MLAB read: ~2.5 ns; costs 64 x 46 flip-flops and ~1k LUTs |

Not applied: sharing the W-stage operations' 64 comparators with the
lookup CAM (area only, -1.5k ALMs, see 4.2 cut 2); registering the E
redirect (one more bubble per mispredicted branch, ~2 % of cycles) if F + A
are not enough; the D-cache tag compare in W if M3 is not enough.

#### Result

**62.8 MHz, -0.31 ns; 12,070 ALMs / 14,923 registers** (`pa_tlb` 5,377 ALMs /
7,108 registers: cut M3's 64 x 46 payload flip-flops and their AND-OR cost
+1.5k ALMs; `pa_core` 4,429, `pa_fetch` 764). From 56.3 to 62.8 MHz, and
the fetch unit's PC registers are no longer in the 40 worst paths.

The remaining chain is again retimed across stages: Quartus moved the
lookup operand register forward through the CAM to the one-hot `sel`, and
the W result register forward through the forwarding muxes into the
shifter. From `sel`: the payload AND-OR (3 levels, 4.6 ns with routing)
-> `lk_aid` -> the PID compare (`pid_rd_ok`) -> PROBE's result
(`m_result2`) -> `w_result` -> MTSAR's value forwarded into the shift
amount (`sar_in` -> `sh_amount`) -> the shifter's first mux. 15.2 ns of
data delay against the 15.6 ns budget, lost to the clock skew (-0.5 ns)
and setup. In RTL terms the two halves (M: lookup + PID check + result
mux; W -> E: result forward + shift-amount select) are each inside a cycle;
their sum is 0.3 ns over two.

Next: the area cut (share the lookup CAM with the W-stage operations, 4.2
cut 2) -- it also relieves the placement around the TLB -- then a second
seed; failing that, make PROBE's result a registered late result (it has
the load-use interlock already, so a forward from M is never used).


### 4.4 Sharing the CAM (fit 6)

The W-stage TLB operations (IxTLBA/IxTLBP, the walker's inserts, PxTLB)
had their own 64 x 36-bit comparators (`op_match`) to find their targets.
Now the lookup CAM compares the operation's tag instead in the one cycle
the operation is accepted (`op_cam`, state S_IDLE with `op_req`): W holds
the pipeline for the whole operation, so the instruction in M consumes
nothing that cycle, and the core withholds the I-LAB refill's `it_ack`.
The tag select is a 3:1 mux (operation / M / I-LAB) that still fits one
LUT per bit. `pa_tlb.sv`, `pa_core.sv` (`it_ack`), `pa_cpu.sv`. All ten
suites pass.

#### Result

**59.0 MHz, -1.34 ns; 10,635 ALMs** (`pa_tlb` 3,996: the second comparator
set is gone, -1.4k ALMs as expected) -- but 3.8 MHz slower than fit 5. The
worst 40 paths all end on the CAM's `match` (retimed into registers) and
start on `lk_tag`: the tag select `op_cam = (st == S_IDLE) && op_req &&
!op_done` hangs off `tlb_op_req`, which is combinational W-stage control,
and the retimer had also moved `w_trap` forward, so the chain M trap check
(`pid_wr_ok` -> `m_trap_xd`) -> W control -> `op_cam` -> the 36-bit tag
mux -> the CAM sat in one cycle (16.3 ns).

**Fix (fit 7):** the operation is accepted into a registered state `S_CAM`
first; `op_cam = (st == S_CAM)` is a state decode, so nothing from W or M
is in front of the CAM. One cycle more per TLB operation (they take 4+).

**Fit 7: 53.6 MHz, -3.04 ns, 11,106 ALMs.** Worse. The 40 worst paths now
end on the CAM compare of the *operation's* tag (`Equal17..63`, retimed
into registers) and start on `lk_tag`; the chain is the lookup (`match` ->
`sel` -> hit) -> the M trap decision (`m_trap_xd`) -> `w_trap` (retimed
forward again) -> the walker's offset select (`wk_off`: I- or D-side
address) -> `tlb_op_off` -> `op_tag` -> the CAM in the S_CAM cycle. The
operation's tag was a combinational function of W's state and the walker's
muxes, 36 bits fanned out to 64 comparators.

**Fix (fit 8):** `op_tag` is a register in the TLB, captured with the
acceptance (S_IDLE -> S_CAM); the CAM cycle and the target walk start from
flip-flops. If this does not get back above fit 5's 62.8 MHz, the shared
CAM is reverted (commits 7fc0551, 9bb4514) and the 1.4k ALMs stay.

**Fit 8: 63.1 MHz, -0.23 ns, 11,443 ALMs / 14,989 registers** (`pa_tlb`
4,770 ALMs). Better than fit 5 on both counts, so the shared CAM stays. The
worst path is the fit-5 shape again, retimed across M and W: lookup
(`match` -> `sel` -> hit) -> page/block RPN select -> `dc_m_rpn` ->
`w_cached` (moved forward) -> the W write-data select `wd0` -> E's operand
mux -> the shifter's first mux (`ext_raw`), 15.2 ns. Within fitter noise of
the target: fit 9 is the same RTL with seed 2. If the seeds scatter around
63, the RTL cut is to make the `wd0` select a flag registered at M -> W
(`w_ld_sel`) instead of `wst`/`w_is_cmem`/`w_is_load` decode, which takes
`w_cached` out of the write-data path entirely.

**Fit 9 (seed 2): 65.1 MHz, +0.25 ns, 11,373 ALMs / 14,764 registers --
64 MHz met.** Same RTL as fit 8; the seed alone moved it by 2 MHz, so the
margin is placement, not logic. `scratch/cpu_fmax/cpu_fmax_pipe.qsf` keeps
`SEED 2`. The worst path is the same shape (lookup -> RPN -> `w_cached`,
retimed, -> `wd0` -> E's operand -> the ALU pre-shift), +0.25 ns. For real
margin the `w_ld_sel` cut above is still the one to make, and the fetch
redirect path (4.3) is the other candidate that retiming currently hides.

Area summary at fit 9, against the ~8-10k ALM budget: 11.4k ALMs without
the FPU -- `pa_tlb` 4.8k (64 x 36-bit CAM + 64 x 46-bit payload in
flip-flops), `pa_core` 4.4k, `pa_fetch` 0.8k, the two caches 0.9k, the
rest 0.5k. The TLB's flip-flop payload is the obvious place to buy area
back (an MLAB payload costs ~2.5 ns on the lookup; a 2-cycle registered
translation would allow it) once the FPU's cost is known.


### 4.5 The FPU (fit 10)

The committed tree (1365246: the fit-9 core plus `pa_fpunit` + `pa_fpu`,
nothing else), seed 2. **55.8 MHz, -2.28 ns; 17,545 ALMs / 21,254 registers,
293 M10K, 4 DSP blocks** (the 53x53 multiplier: four 27x27, one output adder
chain). The FPU costs **6,174 ALMs and 6,490 registers**, far above anything
budgeted, and 9 MHz:

| Entity | ALMs | Registers | What |
|---|---:|---:|---|
| `pa_fpunit` (own logic) | 2,909 | 3,168 | the FR file is **flip-flops**: `frl`/`frr` have three asynchronous read ports each (two operands, the store source), which Quartus will not put in MLABs -- 28 x 64 FFs plus three 64-bit 32:1 read muxes; the `hold_*` operand registers and their select; the FPSR / exception registers; the decode |
| `pa_fpu` (engine) | 3,581 | 2,950 | the datapath: unpack x 2, the early-decision result muxes, the 58-bit align shifter + sticky mask, the 58-bit normalise shifter + `lzc58`, the 64-bit `lzc64` + shifter of FCNVXF, the 55-bit shifter + mask of FCNVFX, the divide/sqrt recurrences, rounding; ~1,000 of the registers are the RTL's (`prod` 106, `sq_rad` 110, `na`/`nb`, `rsig`, ...), the rest retiming duplicates |

The 40 worst paths: 39 are the **TLB lookup chain** of fits 8/9 (`lk_tag` ->
CAM `match` -> `sel` -> payload AND-OR `pl_all` -> `lk_aid` -> PID compare ->
`pid_wr_ok` -> `m_trap_xd` -> `w_trap`, retimed), now 17.2 ns of which
**11.6 ns is routing** (68 %): the same logic as fit 9 (+0.25 ns) with the
TLB placed at X11-X28 and the core's W control at X45. The 6k extra ALMs
pushed the placement apart. The one FPU path (-2.04 ns) is the issue:
W's commit decision (`w_commit`, `hpmc_req`, the nullify) -> `fp_issue` ->
`eng_start` -> the operand select (`rd_a`/`rd_b` from the flip-flop FR file
through `opnd` and the `nx_a`/`hold_a` mux) -> the engine's `unpack` -> `na`
(retimed into `rsig`); the FR read addresses (`rd_a_n`) alone are -1.2 ns
into the same registers.

Cuts for fit 11, in order:

1. **FR file in MLABs**: one bank copy per read port (six 32 x 32 MLAB
   arrays, every write goes to all copies), as `pa_regfile` does. Removes
   ~1.8k flip-flops and the three 32:1 muxes: about -1.3k ALMs.
2. **Operands from registers**: the operation is accepted at W commit into a
   read state (`S_RD`): the register numbers come from the captured
   instruction, the FR file is read during that cycle into `hold_a`/`hold_b`,
   and the engine starts the cycle after from flip-flops. One more cycle
   per operation (FADD 3 -> 4, P-016); the W commit decision leaves the
   engine's input cone.
3. Then the area items of the engine if still needed: FCNVXF normalised
   through the `S_NORM` shifter (drops `lzc64` and a 64-bit shifter), one
   right shifter shared by align and FCNVFX, the special results encoded
   as {kind, sign} and packed once.
4. If the TLB chain is still the worst at the smaller area, it is placement:
   seeds 1 and 3 before any RTL change there (fit 8 -> 9 moved 2 MHz on
   the seed alone).

## 5. Open items

- **Fit 11**: the FPU cuts of 4.5; 64 MHz with the FPU is the gate.

- Prediction in F2 instead of D (see 2.1) once the real F2 (tag compare +
  select) exists and its slack is known.
- The caches' M10K output registers: the plan is registered outputs with the
  compare in F2 (I side) and M (D side); if the D-side compare + load align
  does not fit M, the fallback is the compare in W with a second load-use
  bubble (the PowerPC core measured that at 9-14 % cycles).
