#!/usr/bin/env bash
# boot the 11i CD on the serial console to the installer's welcome screen (the core already loaded); then i, o into the stall
cd /home/dani/repos/hp9000-715
w() { local s=$(date +%s); until [ $(( $(date +%s) - s )) -ge $2 ] || /usr/bin/grep -q "$1" scratch/board-11i.log; do sleep 2; done; }
w "BOOT_ADMIN>" 120; tools/mister/board.sh type 'boot scsi.2\r' >/dev/null
w "Enter the number of the language" 240; sleep 3; tools/mister/board.sh type '62\r' >/dev/null
w "Please confirm" 30; tools/mister/board.sh type '\r' >/dev/null
w "best matches your terminal" 60; tools/mister/board.sh type '2\r' >/dev/null
w "Advanced Options" 120; sleep 5; echo WELCOME $(date +%T)
if [ "$1" = stall ]; then tools/mister/board.sh type 'i' >/dev/null; sleep 8; tools/mister/board.sh type 'o' >/dev/null; sleep 45; echo STALLED $(date +%T); fi
