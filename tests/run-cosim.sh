#!/bin/bash
# Lockstep co-simulation of pa_core_seq (reference) and pa_cpu (pipelined) on
# every pacputest suite ROM: tests/run-cosim.sh [suite ...]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
V=$HERE/../verilator
SUITES=${*:-alu1 alu2 shift max1 mem branch trap sys}
make -s -C "$HERE/cpu" >/dev/null || exit 1
make -s -C "$V" obj_dir_cosim/Vcosim_top >/dev/null || exit 1
fail=0
for s in $SUITES; do
    make -s -C "$V" "obj_dir_ct/$s.hex" >/dev/null || { echo "$s: no ROM"; fail=1; continue; }
    printf "%-7s " "$s"
    "$V/obj_dir_cosim/Vcosim_top" +rom="$V/obj_dir_ct/$s.hex" --max-cycles 200000000 2>&1 | tail -1
    [ ${PIPESTATUS[0]} -eq 0 ] || fail=1
done
exit $fail
