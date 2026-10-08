#!/usr/bin/env bash
#
# sdram_sweep.sh -- try each SDRAM read-capture point (sdram64 rd_mode, OSD
# O[9:8]) on the board with the ROM's LFSR memory test (fastboot off), and
# report which pass (STUBS S-019). Needs the core pushed (board.sh push) and
# games/HP9K715/hp715_diag_slow.eep (mkeeprom.py bootstrap --fastboot 0).
#
#   tools/mister/sdram_sweep.sh [RAM_MB] [MODES]    (default 16, "0 1 2 3")
set -uo pipefail
B="$(dirname "$0")/board.sh"
ram="${1:-16}"; modes="${2:-0 1 2 3}"
MISTER="${MISTER:-root@192.168.99.92}"
for m in $modes; do
    EEP=hp715_diag_slow.eep "$B" setup "$ram" "$m" > /dev/null
    ssh -o BatchMode=yes "$MISTER" "stty -F /dev/ttyS1 9600 cs8 -parenb -cstopb raw -echo -crtscts clocal; \
        rm -f /tmp/sweep.raw; (timeout 45 cat /dev/ttyS1 > /tmp/sweep.raw &); sleep 1; \
        echo 'load_core /media/fat/_Unstable/HP9K715.rbf' > /dev/MiSTer_cmd; sleep 44"
    out=$(ssh -o BatchMode=yes "$MISTER" 'tr -d "\r" < /tmp/sweep.raw | tr "\n" " "')
    if echo "$out" | grep -q "0x02.7"; then v="FAIL (memory test)"
    elif echo "$out" | grep -q "0x04.10D7"; then v="PASS (memory test done)"
    else v="?"; fi
    echo "rd_mode $m: $v"
    echo "    $out" | cut -c1-400
done
