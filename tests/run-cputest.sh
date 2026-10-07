#!/bin/bash
# Run the pacputest suite ROMs (tests/cpu) on the RTL CPU (verilator/cputest)
# and check each log: against tests/cpu/model.py for the suites it covers,
# against QEMU's reference log for the rest (known QEMU bugs excused).
#   [CORE=seq|pipe] tests/run-cputest.sh [suite ...]   default: every integer suite
# CORE selects the core (default pipe, the pipelined pa_cpu; seq = pa_core_seq).
# Exits non-zero if any suite fails.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
V=$HERE/../verilator
CPUT=$HERE/cpu
SUITES=${*:-alu1 alu2 shift max1 mem branch trap sys}
CORE=${CORE:-pipe}
export CORE
make -s -C "$CPUT" >/dev/null || exit 1
make -s -C "$V" obj_dir_ct/$CORE/Vcputest_top >/dev/null || exit 1
fail=0
for s in $SUITES; do
    rm -f "$V/obj_dir_ct/$s.hex"
    make -s -C "$V" "obj_dir_ct/$s.hex" >/dev/null || { echo "$s: no ROM"; fail=1; continue; }
    run=$("$V/obj_dir_ct/$CORE/Vcputest_top" +rom="$V/obj_dir_ct/$s.hex" --log "$V/obj_dir_ct/$s.log" \
          --max-cycles 200000000 2>&1 | tail -1)
    case $s in
        alu1|alu2|shift|max1) ref="--model" ;;
        *)                    ref="--ref $CPUT/ref/qemu/$s.log --known-qemu" ;;
    esac
    res=$(python3 "$CPUT/compare.py" $s "$V/obj_dir_ct/$s.log" $ref 2>&1)
    tot=$(echo "$res" | grep '^total' | sed 's/^total: //')
    if echo "$res" | grep -q '^result: PASS'; then st=PASS; else st=FAIL; fail=1; fi
    printf "%-7s %s  %s\n          (%s)\n" "$s" "$st" "$tot" "${run#cputest: }"
done
exit $fail
