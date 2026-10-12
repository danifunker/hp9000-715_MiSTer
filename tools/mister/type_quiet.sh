#!/usr/bin/env bash
# tq.sh TEXT [MAX] : type TEXT on the board console, then wait until the log is quiet for 3 s (max MAX s, default 60); print new output
cd /home/dani/repos/hp9000-715
L=scratch/board-11i.log; n0=$(wc -c < $L); max=${2:-60}; s=$(date +%s)
tools/mister/board.sh type "$1" >/dev/null
last=$n0; lt=$(date +%s)
until [ $(( $(date +%s) - s )) -ge $max ]; do
  n=$(wc -c < $L); now=$(date +%s)
  [ $n -ne $last ] && { last=$n; lt=$now; }
  [ $n -ne $n0 ] && [ $(( now - lt )) -ge 3 ] && break
  sleep 1
done
tail -c +$((n0+1)) $L
