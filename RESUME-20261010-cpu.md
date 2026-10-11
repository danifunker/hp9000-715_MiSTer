# Resume prompt -- the CPU stream: what the machine still needs from the PA-7100LC (2026-10-10)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`
as the **CPU owner** (`rtl/cpu/`). The system stream (`RESUME-20261010-features.md`)
does not change the CPU; it files requests in `docs/design/cpu-requests.md`.
**Every CPU change needs the user's go-ahead for that change** (user,
2026-10-09) -- propose, show the evidence, then implement what they approve.

## Read first

1. `CLAUDE.md` -- state, layout, tools, rules (binding).
2. `docs/design/cpu-requests.md` -- **#9 is open**; #1-#8 are done (how the
   streams work together).
3. `docs/design/cpu.md` 4.3 (BLR/BV and their reserved bits), 7.3 (QEMU's
   deviations), 8.3 (PA 2.0 opcodes on a PA 1.1 CPU).
4. `docs/STUBS.md` S-011 (the ROM patch for the dual-issue test), S-012 (one
   FP operation at a time), P-008 (dual issue), P-016 (not cycle-exact).
5. `docs/design/cpu-timing.md` (every CPU fit) and `docs/design/system.md`
   section 10, **builds 31-35** (the whole design at the router's limit).

## Where the machine is (2026-10-10)

HP's PDC 1.6 ROM, HP-UX 10.20 multi-user with CDE on Artist (1280x1024 60 Hz
on HDMI), Harmony audio, the CD-ROM with CD audio, and now the **82596 LAN**
all work on the board (MiSTer at 192.168.99.92, build 35; HP-UX's lan1 at
192.168.99.215 -- telnet/ftp in with `tools/mister/hpux.py`). No CPU bug has
shown up in HP-UX 10.20 since build 15. What is left for the CPU:

### 1. cpu-requests #9 -- BV with reserved bits set (blocks HP-UX 11i media)

**Done 2026-10-11** (`1d17078`, build 36): BLR/BV ignore bits 19:29 and 31 (ACD
p.5-2); branch suite `bv-rv`/`blr-rv`; all gates pass; on the board the 11i
INSTALL kernel now runs its I/O probe and panics in `fdc_cmd_exec: FIFO
problem` -- the floppy stub (S-015/P-004), **the system stream's** (system.md
10, build 36). No new CPU-ism seen yet; the next one can only show once the
kernel gets past the floppy. The original request, for the record:

HP-UX 11i v1's install CD (`disks/hpux11i_oe_cd1.iso`, OE March 2003 CD 1;
also on the board in `/media/fat/games/HP9K715/`) boots its ISL from the ROM
and stops: ISL reads the PSW (`ssm 0,r22`), sees W = 0 (narrow firmware, every
PA 1.1 machine), and its PDC-call routine at ISL offset 0x1e690 returns with
`e840d000` -- PA 2.0's `bve (rp)`, i.e. `bv r0(rp)` with **bit 19 set**. The
core raises trap 8 (illegal instruction) at 0x0001e6f8 (board, build 28, the
debug recorder; `objdump -m hppa2.0` of the extracted ISL). HP shipped this ISL
for PA 1.1 machines, so the real PCX-L must execute it as BV: its decoder
ignores (some of) BV's reserved bits 19:29, probably BLR's too. cpu.md 4.3
currently says "BLR/BV with non-zero reserved bits -> trap 8".

To do (after the user approves):
* Decide the rule from evidence: which reserved bits the PCX-L ignores. The
  safe minimum is "BV/BLR ignore bits 19:29" (decode on the major opcode, the
  sub-opcode and the fields the instruction uses). Check what else that
  frees: PA 2.0's `bve`/`bve,l` (bit 19 + bit 18?) must not turn into a
  link-writing branch; HP's PA 1.1 manual and HP's own tools (ISL, the
  11.00/11i loaders: `roms/hpux/` has 10.20's; the 11i CD's `ISL` can be
  pulled from its LIF with `tools/hpfw/hpfw.py` / `tools/hpux/hpdisk.py`).
* Change `rtl/cpu/pa_decode.sv` (and `pa_core_seq.sv`, the reference core),
  cpu.md 4.3, add a pacputest vector (`tests/cpu/gen_tests.py`, a `bve (rp)`
  word in a branch suite; `tests/cpu/model.py`'s expectation), excuse QEMU if
  it differs (`QEMU_BUGS`).
* Gates: `tests/run-cputest.sh` (12/12), `tests/run-cosim.sh`,
  `tests/run-rom.sh`, then a Quartus fit (see 2.) and the board: boot the 11i
  CD (OSD: the CD slot = `hpux11i_oe_cd1.iso`; at the ROM's "Press <ESC>"
  stop the autoboot, `boot scsi.2`; console on graphics -- watch with
  `tools/mister/obs_shot.py`) and see how far ISL / the 11i kernel get. A
  blank 8 GiB disk `hpux11i.img` is on the board for the installer (mount it
  as the second disk, SCSI ID 5). The next stop is likely another PA 2.0-ism
  or a 7100LC detail 11i needs (`docs/review/07-hpux-cpu-specifics.md`):
  file each as a new cpu-requests row with evidence.

### 2. Area -- the design is at the router's limit

Build 33 routed at 36,717 ALMs (88 %); build 34 (+40 ALMs) did not route;
build 35 (the same RTL, fitter seed 2) routed at 36,581 (87 %) with the HDMI
clock at +0.038 ns. The user does not want framework features switched off
(`MISTER_DISABLE_*`); they want optimisations. `pa_cpu` is ~13,900 ALMs, 38 %
of the design (the next biggest: Artist ~3,670, the 53C710 ~2,182, the MIOC
~2,134). Any CPU change must not grow the CPU; ideally the CPU stream finds
savings (the fit report's "Resource Utilization by Entity" per CPU module;
cpu-timing.md has the history). A separate task (the user's idea: a Fable
agent for optimisations, the "Find ALM savings" chip) covers the non-CPU RTL
-- coordinate: one Quartus flow at a time on this box.

### 3. Later (not requested yet; ask before starting)

* Dual issue (P-008): then the ROM loader's one-word patch (S-011) can go and
  the ROM's dual-issue self-test 0x4108D runs as on the real chip.
* FPU overlap (S-012) and cycle timing (P-016) -- performance, not function.
* DR0 revision: 2 now (user, 2026-10-07; 0xC would switch HP-UX 10.20 onto
  its PCX-L2 paths -- review 07).

## Gates and rules

* `tests/run-cputest.sh` (12 suites, `CORE=pipe`/`seq`), `tests/run-cosim.sh`
  (both cores in lockstep), `tests/run-rom.sh` (HP's ROM to `BOOT_ADMIN>`,
  ~10 min with the build), the unit benches (`make -C verilator tb_alu
  tb_shift tb_max1 tb_ldst tb_fpu`).
* Quartus 17.0.2: `setsid nohup quartus_sh --flow compile HP9K715 >
  scratch/buildNN.log` (~35 min); **one flow at a time** (`pgrep -a quartus`
  first; other cores build here too); **never edit `files.qip`, the QSF or
  the SDC while a fit runs**; record the fit in `docs/design/cpu-timing.md`
  and `docs/design/system.md` 10; the QSF has `SEED 2` since build 35.
* **One simulation at a time, none beside a fit.** Prefer the board for OS
  behaviour.
* Never edit `sys/`; no git worktrees; never delete without asking; every
  stub or simplification in `docs/STUBS.md`; small, frequent commits.
* Board: `tools/mister/board.sh push|load|key|mouse|vram|console`, OBS
  screenshots with `tools/mister/obs_shot.py`; ask before loading a core or
  shutting HP-UX down if the user may be using it. Shut HP-UX down over the
  LAN: `tools/mister/hpux.py run 'sync; (nohup /sbin/shutdown -h -y 0 >
  /dev/null 2>&1 &)'`.
