#!/usr/bin/env bash
# trace_get.sh OUT [dump args...] -- run tools/mister/trace_dump.py on the MiSTer and save its output locally
#   trace_get.sh scratch/ring.txt --last 70000     (also: trace_get.sh - clear)
M="${MISTER:-root@192.168.99.92}"; out=$1; shift
scp -q -o BatchMode=yes "$(dirname "$0")/trace_dump.py" "$M:/tmp/trace_dump.py"
if [ "$out" = - ]; then ssh -o BatchMode=yes "$M" "python3 /tmp/trace_dump.py $*"
else ssh -o BatchMode=yes "$M" "python3 /tmp/trace_dump.py dump $*" > "$out"; wc -l "$out"; fi
