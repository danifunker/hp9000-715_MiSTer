#!/usr/bin/env bash
# inst11i_boot.sh -- reload the core, stop the PDC with Escape, boot the CD, answer US English: ends at the installer's welcome screen (HDMI)
cd /home/dani/repos/hp9000-715 || exit 1
w() { local s=$(date +%s); until [ $(date +%s) -ge $((s+$1)) ]; do sleep 1; done; }
tools/mister/board.sh load >/dev/null 2>&1; s=$(date +%s); w 8
until [ $(date +%s) -ge $((s+50)) ]; do tools/mister/board.sh key '\e' >/dev/null 2>&1; sleep 1; done
w 6; tools/mister/board.sh key '\r' >/dev/null 2>&1; tools/mister/board.sh key 'boot scsi.2\r' >/dev/null 2>&1
w 95; tools/mister/board.sh key '62\r' >/dev/null 2>&1; w 5; tools/mister/board.sh key '\r' >/dev/null 2>&1; w 50
