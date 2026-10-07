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

## 3. Open items

- Prediction in F2 instead of D (see 2.1) once the real F2 (tag compare +
  select) exists and its slack is known.
- The caches' M10K output registers: the plan is registered outputs with the
  compare in F2 (I side) and M (D side); if the D-side compare + load align
  does not fit M, the fallback is the compare in W with a second load-use
  bubble (the PowerPC core measured that at 9-14 % cycles).
