#!/usr/bin/env bash
#
# run-rom.sh -- boot HP's PDC 1.6 boot ROM on the whole machine
# (verilator/romsim) and check how far it gets.
#
# A progress ratchet: each milestone the ROM has reached must still be
# reached, and none of the failure strings may appear. Add a line to EXPECT
# when the boot gets further; never remove one to make the script pass.
#
# The EEPROM is tools/eeprom/mkeeprom.py's bootstrap image (initialised,
# manufacturing mode = console and chassis codes on RS-232, fastboot on),
# the RAM 8 MB (the ROM sizes and tests all of it, so less RAM is faster).
# CR16 runs 15x faster after selftest1 (--turbo): the ROM's long delays
# (0.3 s waits in the RS-232 IODC, 1 s waits) are CR16 loops, and its
# timer test (0x4108C, in selftest1) needs the real rate.
#
#   tests/run-rom.sh [--no-build] [--keep]
#
# Writes verilator/obj_dir_rom/rom-console.txt (the serial log).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
V="$ROOT/verilator"
SIM="$V/obj_dir_rom/Vemu"
ROM="${ROM:-$ROOT/roms/hp715_pdc_rev1.6.bin}"
OUTDIR="$V/obj_dir_rom"
LOG="$OUTDIR/rom-console.txt"
MAXC="${MAXC:-400000000}"

# milestones, in the order the ROM prints them (chassis codes go to RS-232
# as 0x<LED>.<sub-code> while the EEPROM says manufacturing mode)
EXPECT=(
    "0x04.1081"        # selftest1 starts: the console and the ROM fetch path work
    "0x04.10D2"        # HPMC on an I/O timeout, TOC through IO_COMMAND
    "0x04.2095"        # the cache tests, incl. code planted in the I-cache
    "0x06.C201"        # memory init: the bus-error probes came back
    "0x04.10DA"        # memory sizing and the ones/zeros test
    "0x04.10D7"        # ECC single-bit correction, LPMC
    "0x04.10D8"        # ECC multi-bit detection, HPMC
    "BootRom Version    1.6"   # the PS/2 loopback interrupt, the I/O table, the console
    "Memory Size:  8 MB"
    "0x04.2097"        # selftest2: caches
    "0x04.1094"        # TLB: PROBE (needs ,m flushes from the base, cpu-requests #4)
    "0x04.1095"        # the hardware TLB-miss walker
    "0x04.1096"        # T/D/B traps
    "0x04.10D9"        # injected I/O parity errors (one HPMC per posted store)
    "0x04.4082"        # the FP tests, delayed traps
    "0x06.C2EF"        # EISA: none, skipped
    "0x04.300C"        # boot selection
    "BOOT_ADMIN>"      # manufacturing mode: straight to the prompt
)
FORBID=(
    "failed selftest"
    "SYSTEM HALTED"
    "Memory card failed"
    "No memory found"
    "not functional"   # PDC_COPROC: the FP self-test did not pass
)
STOP="${STOP:-BOOT_ADMIN>}"

build=1
for a in "$@"; do
    case $a in
        --no-build) build=0 ;;
        *) echo "usage: $0 [--no-build]"; exit 2 ;;
    esac
done
[ -f "$ROM" ] || { echo "no ROM at $ROM (roms/README.md)"; exit 2; }
if [ $build = 1 ]; then make -s -C "$V" romsim >/dev/null || exit 1; fi
mkdir -p "$OUTDIR"
python3 "$ROOT/tools/eeprom/mkeeprom.py" bootstrap --hex "$OUTDIR/ee_boot.hex" || exit 1

"$SIM" --rom "$ROM" +eeprom="$OUTDIR/ee_boot.hex" --ram-lg 3 --turbo 15 --max-cycles "$MAXC" \
       --until "$STOP" --serial-log "$LOG" > "$OUTDIR/rom-run.txt" 2>&1
rc=$?
tail -1 "$OUTDIR/rom-run.txt"

fail=0
pos=0
for m in "${EXPECT[@]}"; do
    # each milestone after the previous one
    off=$(tail -c +$((pos + 1)) "$LOG" | grep -a -b -o -F -- "$m" | head -1 | cut -d: -f1)
    if [ -z "$off" ]; then echo "MISSING  $m"; fail=1; else echo "ok       $m"; pos=$((pos + off + ${#m})); fi
done
for f in "${FORBID[@]}"; do
    if grep -a -q -F -- "$f" "$LOG"; then echo "FORBIDDEN $f"; fail=1; fi
done
if [ $rc != 0 ]; then echo "did not reach \"$STOP\""; fail=1; fi
[ $fail = 0 ] && echo "run-rom: PASS" || echo "run-rom: FAIL"
exit $fail
