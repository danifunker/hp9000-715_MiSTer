#!/usr/bin/env bash
# repro.sh TAG: boot the 11i CD (core already pushed), arm the recorder with a never-firing trigger, run the wizard into
# the configuration step; then either the SIGILL reboot (ring frozen: dump it) or the stall (dump the last 64K events)
cd /home/dani/repos/hp9000-715; S=$(dirname "$0"); tag=$1
tools/mister/board.sh trig ${TRIG:-65535} >/dev/null; : > scratch/board-11i.log; tools/mister/board.sh load >/dev/null
$S/inst11i_serial_boot.sh stall
if /usr/bin/grep -q "killed by signal" scratch/board-11i.log; then
  echo SIGILL; /usr/bin/grep "killed by signal\|ERROR\|NOTE" scratch/board-11i.log | tail -5
else echo NOSIG; fi
tools/mister/trace_get.sh scratch/ring$tag.txt --last 70000
python3 tools/mister/trace_sym.py roms/hpux11i/INSTALL scratch/ring$tag.txt --sysc > scratch/ring$tag.sym
echo "traps 8/10/11:"; /usr/bin/grep -n "trap  8\|trap 10\|trap 11" scratch/ring$tag.txt | tail -5
echo "user PC samples:"; /usr/bin/grep "trap  4 at [0-9a-f]*[37] " scratch/ring$tag.txt | awk '{print $6}' | sort | uniq -c | sort -rn | head -12
tail -2 scratch/ring$tag.txt
