# Resume prompt -- cpu-requests #10: `b,l`'s link register corrupted by an external interrupt (2026-10-11)

You are continuing the HP 9000/715 MiSTer core in `/home/dani/repos/hp9000-715`.
**Goal: find and fix the CPU bug that makes HP-UX 11i's installer stall, then
install HP-UX 11i v1 (the 12/2004 TCOE DVD, `hpux11i_tcoe_200412.iso` on the
MiSTer) onto `hpux11i.img` (SCSI ID 5) and boot it.** The user has asked for
the CPU fix explicitly (2026-10-11 evening), so `rtl/cpu/` may be edited for
this bug -- with the regressions (`tests/run-cputest.sh`, `tests/run-cosim.sh`)
and a new `tests/cpu` vector that reproduces it.

## Read first

1. `CLAUDE.md` (rules: STUBS entries, never delete without asking, one Quartus
   flow / one simulation at a time, no `pkill -f`/`pgrep -f`, commit often,
   the Fable co-author trailer).
2. `docs/design/cpu-requests.md` **#10** (the bug, with the evidence).
3. `RESUME-20261011-11i-install.md` "Status" (how it was found; the tools).
4. `docs/design/system.md` 10, builds 40-47 (the recorder's new modes).
5. `rtl/cpu/pa_core.sv`: the E stage (`e_seq`, line ~454), the D-stage operand
   bypasses (line ~275), the D->E/F2->D IAOQ handling (line ~1060-1100), the
   trap select at W (line ~757), the W redirect (line ~975).

## The bug, precisely

HP-UX 11i's Ignite `itool` (a lex scanner `yylook` at itool text 0x2ee1a0;
disassembly in the scratchpad `keep/bl-link-interrupt/itool_loop.dis`, full
itool at `scratchpad/itool_all.dis` of this session -- regenerate with
`python3 tools/hpux/som.py --all roms/hpux11i/instcmds/opt/ignite/bin/itool dis`)
loops forever: its `bv r0(rp)` (0x2ee778) returns to **0x2ee1a4**, its own
second instruction, so the prologue's `stw rp,-14(sp)` (0x2ee1a0) is skipped,
the frame keeps 0x2ee1a4 and it calls itself forever (one `read` returning 0
at EOF per round). Recorder flow trace of the onset (build 47, flow-trigger
mode, `keep/bl-link-interrupt/ring47a.txt` events 58594058-58594084):

```
flow 002ed31b -> 002ee1a3   yylook called from 0x2ed314 (rp = 0x2ed31c), runs, returns fine
flow 002ee77f -> 002ed31f
...
flow 002ed407 -> 002ee0df   yylex arrives at 0x2ee0dc (target of `b` at 0x2ed400)
flow 002ee0e3 -> 002ee1a3   `b,l 0x2ee1a0,rp` at 0x2ee0dc (delay slot nop 0x2ee0e0); 0x2ee1a0 `stw rp,-14(sp)` RETIRES
trap  4 at 002ee1a7          external interrupt taken on the NEXT instruction (0x2ee1a4 `stw,ma r3,c0(sp)`)
flow 00035a40 -> 002ee1a7   the kernel's `rfi` (INSTALL kernel 0x35a40) returns to 0x2ee1a4
flow 002ee203 -> 002ee533   ... yylook runs to EOF (reads return 0) ...
flow 002ee77f -> 002ee1a7   its `bv r0(rp)` returns to 0x2ee1a4  <-- rp should be 0x2ee0e4
```

So the word the `stw rp,-14(sp)` put at sp-0x14 was 0x2ee1a4 = branch target
+ 4 = `e_seq` (`e_iaoq_b + 4`) of the **delay slot** (whose `e_iaoq_b` is the
branch target), not the `b,l`'s own link (`e_seq` of the `b,l` = 0x2ee0e4).
Other interrupts at other spots in the same trace (one at 0x2ee0e4 right
after another `b,l`'s delay slot) did no harm: the alignment "interrupt taken
on the instruction after a store of the link register, two instructions after
the `b,l`" is what hurts. Nondeterministic and placement-dependent: builds
39-44 stalled 5/5 at the installer's first step, build 45 passed it 2/2 and
stalled at a later step; a run of build 41 instead printed
`run_cmd: Process: 42 (net_cfg_prep): killed by signal: 4` (SIGILL) and
rebooted -- the same class (a corrupted return address). HP-UX 10.20 survives.

Open questions (the mechanism): (a) does the store's `rp` operand come from
the wrong forwarding source (the nop's `e_seq`/result path) or (b) is the
`b,l`'s `e_iaoq_b` overwritten by its own target under the stall/kill that
the interrupt produces (`e_redir && d_valid` patching, line ~1071/1083), or
(c) something in the kernel's `rfi` return + the HP-UX trap entry (shadow
registers, `w_before` traps, `W_REPLAY` of a store on a D-cache miss or a
walker-handled DTLB miss on the stack line -- HP-UX runs translated with the
walker; such misses are invisible in the trace)? The value is a strong hint
for (a)/(b).

## What was tried for a reproduction (tests/cpu `link` suite, uncommitted edits)

`tests/cpu/gen_tests.py` `gen_link` + `tests/cpu/check_link.py` (+ `link` in
the Makefile's SUITES; `make -C tests/cpu build/link.bin`; run with
`verilator/obj_dir_ct/pipe/Vcputest_top +rom=verilator/obj_dir_ct/link.hex
--log L --max-cycles 80000000; python3 tests/cpu/check_link.py L`). Each
vector arms the interval timer K cycles ahead (K sweeps 6..125), then
`ssm 1; b,l 1f,rp; nop; 1: stw rp,0(r14); stw rp,4(r14); stw rp,8(r14); stw
rp,12(r14)` into RAM slots preset to the sentinel; words = expected link, 4
slots, interruptions, K, rp-before (the harness's trap handler *skips* the
trapping instruction, so an interrupt on the `b,l` leaves rp = rp-before: the
checker accepts that). Results on the pipelined core: group `bl-link-irq`
(physical mode, cache hits) 120 vectors / 46 interrupts / **0 bad**; group
`bl-link-irq-miss` (slot line `fdc`'d first) 120 / 69 / **0 bad**. So the
plain and D-cache-miss cases with interrupts at every phase do NOT reproduce
it. The translated groups (`-virt`: page touched by a load first; `-walk`: TLB
entry purged so the store walks) **hang / HPMC on both cores**, i.e. my
walker set-up is wrong (compare with `gen_tlbx`'s `walk_vector`: it works;
differences to find -- the `mtsp %r0,%sr1`, PA = the trap-log page 0xF0000,
the entry's `nxt` word 0). Next for the reproduction, in order:
1. Fix the translated groups (or build on `gen_tlbx`'s `to_virt` to run the
   sequence in virtual mode with C=1, D=1 and TLB entries inserted by hand,
   plus a PL 3 variant via `gate_vector`'s technique), interrupts swept.
2. Add the kernel-like return: the harness handler RFIRs *after* the
   trapping instruction; HP-UX re-executes it (`rfi` to IIAOQ front). A
   variant handler that returns to the front (needs `src/ivt.S` changes or a
   second IVT) matches the real case for an interrupt taken on the store
   itself (`w_before`).
3. The decisive instrumentation (was being added when the session ended;
   the half edit was reverted): `pa_core`/`pa_cpu` outputs `dbg_ea`,
   `dbg_stdata` (set with `dbg_retire` from `w_ea`/`w_stdata`), and in
   `rtl/hp715.sv` a flow-mode event 20 for user-mode loads/stores with base
   sp (insn[25:21] == 30; opcodes 0x12/0x13/0x1A/0x1B) = {insn, EA, the
   store data or the load's GR write data (`dbg_gr_data0`, same cycle)}.
   With `board.sh trig flow 0x2ee1a4` that shows exactly what the `stw` at
   0x2ee1a0 stored (and the sp), and what `ldw -d4(sp),rp` at 0x2ee738
   loaded -- distinguishing a wrong store datum from a wrong sp / wrong load.
   Instantiations to extend: `rtl/hp715.sv`, `verilator/cputest/cputest_top.sv`,
   `verilator/cosim/cosim_top.sv`.
4. If the simulation never reproduces it, the board + recorder is the test
   bench: a fix is validated by N installer runs without the stall (each run
   ~6 min: `tools/mister/inst11i_repro_flow.sh TAG`, which boots the CD on
   the serial console, walks the wizard and dumps the ring when the recorder
   freezes).

## The board tools (all committed; serial console, 128 MB)

* Slots for installer runs: `.s0` empty (NUL-padded empty path; never let the
  10.20 disk be the install target), `.s1` `hp715_serial.eep`, `.s2`
  `hpux11i.img`, `.s3` the CD ISO (`hpux11i_oe_cd1.iso` = the 2003 Base OE
  used so far; `hpux11i_tcoe_200412.iso` = the TCOE DVD the user wants
  installed -- not yet booted). Restore the user's slots afterwards (`.s0`
  hpux1020.img, `.s1` hp715_gfx2.eep, `.s3` hp715audio.cue).
* `LOG=scratch/board-11i.log tools/mister/board.sh console 21600` in the
  background (setsid nohup); `tools/mister/inst11i_serial_boot.sh [stall]`
  (BOOT_ADMIN -> `boot scsi.2` -> language 62 -> VT100 -> welcome; `stall` =
  then `i`, `o`); `tools/mister/type_quiet.sh TEXT [MAX]` (type, wait for
  the log to go quiet); `tools/mister/vt.py LOG` renders the screen; the
  wizard's keys: `i` Install, `o` OK, `n` Next, the disks step needs
  `1\t\t` then `\r` (an `n` there lands in the text field);
  `tools/mister/inst11i_recovery.sh` boots into the recovery shell
  (`loadfile -lINSTCMDS /usr/ccs/lbin/cpp` etc. work there).
* The recorder (build 47 = `scratch/HP9K715-b47.rbf`, on the board in
  `_Unstable`): `board.sh trig N R26 K` (freeze 60000 events after the K-th
  system call N with r26 = R26; `-` = any), `board.sh trig flow ADDR` (itool's
  user-mode control flow from reset, freeze 20000 events after the first
  branch to ADDR), `board.sh trig` (off); Pause on the PS/2 keyboard re-arms;
  `tools/mister/trace_get.sh OUT --last 70000` dumps, `trace_sym.py
  roms/hpux11i/INSTALL OUT --sysc` adds kernel symbols / syscall names;
  events: 15 sysc (r22, r26, r25), 16 sysa (r2, r24, r23), 17 lan, 18 sysr
  (r28 at the first user-mode instruction after the call -- right for
  syscalls; interrupts return by `rfi`), 19 flow (from -> to, insn).
  The freeze survives HP-UX's reboot (only the MiSTer reset clears it).
* Captures of this session: the scratchpad's `keep/bl-link-interrupt/`
  (`ring47a.txt` the onset above, `ring45b.txt` the loop period of 36 flow
  events, `itool_loop.dis`) -- `keep/INDEX.md` lists them. The scratchpad is
  `/tmp/claude-1000/-home-dani-repos-hp9000-715/5f4fec24-df2d-450b-af83-7b67c461b775/scratchpad`
  (session-local; copy what matters into the repo if it is still there).

## After the fix

Run `tests/run-cputest.sh` and `tests/run-cosim.sh`, build (seed 3 in the
QSF; ~30 min; `pgrep -a quartus` first), push, run the installer to
completion on the **HDMI console with the PS/2 keyboard** (the user's wish:
`tools/mister/inst11i_boot.sh`, `board.sh key`, `hdmi_shot.sh`/OBS), from the
TCOE DVD, DHCP off or on (both should work once fixed), boot `scsi.5`, and
tell the user -- they want a copy of the image. Record the builds in
`docs/design/system.md` 10, move cpu-requests #10 to "Done" with the commit,
and update CLAUDE.md's state line.
