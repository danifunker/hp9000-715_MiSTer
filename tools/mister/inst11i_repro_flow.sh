#!/usr/bin/env bash
# repro_flow.sh TAG: boot the 11i CD with the flow trigger armed (branch to 0x2ee1a4), walk the wizard until the recorder
# freezes (a stall) or the steps run out; dump the ring
cd /home/dani/repos/hp9000-715; S=$(dirname "$0"); tag=$1
tools/mister/board.sh trig flow 0x2ee1a4 >/dev/null; : > scratch/board-11i.log; tools/mister/board.sh load >/dev/null
$S/inst11i_serial_boot.sh
frozen() { a=$(tools/mister/trace_get.sh - dump --last 1 | tail -1 | awk '{print $2}'); sleep 4; b=$(tools/mister/trace_get.sh - dump --last 1 | tail -1 | awk '{print $2}'); [ "$a" = "$b" ]; }
step() { $S/type_quiet.sh "$1" ${2:-120} >/dev/null; echo "step '$1' $(date +%T): $(python3 tools/mister/vt.py scratch/board-11i.log | /usr/bin/grep -o 'Install HP-UX wizard: [A-Za-z /-]*' | tail -1)"; if frozen; then echo FROZEN; return 1; fi; }
step i 30 && step o 240 && step n && step n 300 && step n && step n && step n && step '1\t\t' 30 && step '\r' 300 && step n 400 && step n 400 && step n 900
echo "end $(date +%T)"
tools/mister/trace_get.sh scratch/ring$tag.txt --last 70000
/usr/bin/grep -c flow scratch/ring$tag.txt; /usr/bin/grep -c lost scratch/ring$tag.txt
