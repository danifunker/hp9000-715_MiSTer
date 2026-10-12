#!/usr/bin/env bash
# reboot into the 11i CD's recovery shell (serial): ends at the "# " prompt
cd /home/dani/repos/hp9000-715; S=$(dirname "$0")
tools/mister/board.sh trig >/dev/null; : > scratch/board-11i.log; tools/mister/board.sh load >/dev/null
$S/inst11i_serial_boot.sh
w() { local s=$(date +%s); until [ $(( $(date +%s) - s )) -ge $2 ] || /usr/bin/grep -q "$1" scratch/board-11i.log; do sleep 2; done; }
tools/mister/board.sh type 'r' >/dev/null; w "startup networking" 60; tools/mister/board.sh type 'n\r' >/dev/null
w "Select one of the above" 400; sleep 2; tools/mister/board.sh type 'x\r' >/dev/null; sleep 5; echo SHELL $(date +%T)
