#!/usr/bin/env bash
#
# board.sh -- drive the HP9K715 core on a MiSTer over ssh (key login only).
#
#   board.sh setup [RAM_MB [RD]]  OSD status word (/media/fat/config/HP9K715.CFG:
#                             16 bytes, status bit N = byte N/8 bit N%8; RAM
#                             O[5:3] 0..3 = 16/32/64/128 MB, model 715/64,
#                             SDRAM read capture O[9:8] = RD, default 0) and
#                             the remembered mounts (HP9K715.s<n>: the absolute
#                             path NUL-padded to 1024 bytes, mounted again at
#                             every core start -- the CONF_STR slots are "SC"):
#                             slot 0 = disk ID 6, slot 1 = the EEPROM
#   board.sh push RBF         copy a build to $CORE_DIR/HP9K715.rbf (md5-checked)
#   board.sh load             load_core it (cold start: ROM download, reset)
#   board.sh console [SECS]   the serial console (/dev/ttyS1 = the core's
#                             UART, 9600 8N1), timestamped, for SECS (default
#                             forever) -- also appended to $LOG
#   board.sh type TEXT        type into the console (\r for Return)
#   board.sh shot OUT.png     a MiSTer screenshot of the video output
#   board.sh menu             back to the MiSTer menu
#
# Environment: MISTER (default root@192.168.99.92), CORE_DIR
# (/media/fat/_Unstable), GAMES (/media/fat/games/HP9K715), DISK
# (hpux1020.img), EEP (hp715.eep), LOG (scratch file for console).
set -euo pipefail

MISTER="${MISTER:-root@192.168.99.92}"
CORE_DIR="${CORE_DIR:-/media/fat/_Unstable}"
GAMES="${GAMES:-/media/fat/games/HP9K715}"
DISK="${DISK:-hpux1020.img}"
EEP="${EEP:-hp715.eep}"
LOG="${LOG:-/dev/null}"
rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$MISTER" "$@"; }

cmd="${1:-}"; shift || true
case "$cmd" in
setup)
    ram="${1:-64}"; rd="${2:-0}"
    case "$ram" in 16) r=0 ;; 32) r=1 ;; 64) r=2 ;; 128) r=3 ;; *) echo "RAM 16/32/64/128" >&2; exit 2 ;; esac
    rsh "mkdir -p /media/fat/config && python3 - '$r' '$GAMES/$DISK' '$GAMES/$EEP' '$rd'" <<'PY'
import sys
r, disk, eep, rd = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
st = r << 3 | (rd & 3) << 8                   # O[5:3] RAM, O[9:8] SDRAM capture; O[2:1] = 0: 715/64
open('/media/fat/config/HP9K715.CFG', 'wb').write(st.to_bytes(16, 'little'))
for slot, p in ((0, disk), (1, eep)):
    b = p.encode()
    open('/media/fat/config/HP9K715.s%d' % slot, 'wb').write(b + b'\0' * (1024 - len(b)))
print('status 0x%032x; s0 %s; s1 %s' % (st, disk, eep))
PY
    rsh "ls -la /media/fat/config/HP9K715.* $GAMES/"
    ;;
push)
    rbf="$1"
    rsh "mkdir -p '$CORE_DIR'"
    scp -q -o BatchMode=yes "$rbf" "$MISTER:$CORE_DIR/HP9K715.rbf"
    l=$(md5sum < "$rbf" | cut -d' ' -f1); r=$(rsh "md5sum < '$CORE_DIR/HP9K715.rbf'" | cut -d' ' -f1)
    [ "$l" = "$r" ] || { echo "md5 mismatch: $l vs $r" >&2; exit 1; }
    echo "pushed $rbf -> $CORE_DIR/HP9K715.rbf ($l)"
    ;;
load)
    rsh "echo 'load_core $CORE_DIR/HP9K715.rbf' > /dev/MiSTer_cmd"
    echo "load_core $CORE_DIR/HP9K715.rbf"
    ;;
console)
    secs="${1:-0}"
    t=""; [ "$secs" != 0 ] && t="timeout $secs"
    # no tr in the pipe: into a pipe it block-buffers, so lines showed up only
    # when the capture ended (2026-10-09); the loop strips the CR itself. A
    # partial line quiet for a second is a prompt (ISL>, "# ", Console
    # Login:): printed then, the rest of the line comes out as the next one
    rsh "stty -F /dev/ttyS1 9600 cs8 -parenb -cstopb raw -echo -crtscts clocal; $t cat /dev/ttyS1" \
        | while :; do
              IFS= read -r -t 1 line; rc=$?
              if [ $rc -gt 128 ]; then [ -n "$line" ] || continue
              elif [ $rc -ne 0 ]; then [ -n "$line" ] || break; fi
              line=${line%$'\r'}; printf '[%s] %s\n' "$(date +%H:%M:%S)" "$line"
          done \
        | tee -a "$LOG" || true
    ;;
type)
    # one character every 30 ms: the ROM echoes while it polls the UART,
    # and a burst overruns it
    rsh "python3 -c 'import sys,time
s=sys.argv[1].encode().decode(\"unicode_escape\")
f=open(\"/dev/ttyS1\",\"wb\",0)
for c in s: f.write(c.encode(\"latin-1\")); time.sleep(0.03)' '$1'"
    ;;
shot)
    out="$1"
    before=$(rsh "ls -t /media/fat/screenshots/HP9K715/*.png 2>/dev/null | head -1" || true)
    rsh "echo screenshot > /dev/MiSTer_cmd"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 1
        now=$(rsh "ls -t /media/fat/screenshots/HP9K715/*.png 2>/dev/null | head -1" || true)
        [ -n "$now" ] && [ "$now" != "$before" ] && break
    done
    [ -n "$now" ] && [ "$now" != "$before" ] || { echo "no new screenshot" >&2; exit 1; }
    scp -q -o BatchMode=yes "$MISTER:$now" "$out"
    echo "$now -> $out"
    ;;
menu)
    rsh "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd"
    ;;
*)
    sed -n '3,25p' "$0"; exit 2 ;;
esac
