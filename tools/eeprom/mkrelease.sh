#!/usr/bin/env bash
#
# mkrelease.sh -- make the EEPROM image the core ships with (STUBS S-016).
#
# The ROM builds it itself: a cold boot in verilator/romsim from
# mkeeprom.py's bootstrap image (manufacturing mode, so straight to
# BOOT_ADMIN), where the ROM writes the identity and default stable storage;
# then these BCH commands are typed in and the EEPROM is dumped:
#
#   manufactureoff          normal boots from now on (EE 0x1694 bit 0)
#   chassis off             no chassis codes on the serial console
#   path console graphics   the console on Artist (CONSOLE=rs232: on RS-232)
#   monitor graphics.1      monitor type 1, 1280x1024 72 Hz (EE 0x16CA; unset,
#                           the ROM would ask on the first boot). In this order
#                           the console path keeps no monitor of its own (with
#                           the monitor set first, `path console graphics`
#                           records .1 in the path as well)
#
# The rest is the ROM's defaults: primary path scsi.6 (disk 0), alternate
# lan, keyboard ps2, auto boot and auto search on, fastboot on (from the
# bootstrap image), LAN address 08:00:09:71:5A:01.
#
#   [CONSOLE=graphics|rs232] tools/eeprom/mkrelease.sh [OUT.bin]
#                                     (default: tools/eeprom/hp715_default.eep)
#
# Takes about 6 minutes (the ROM's power-on tests at 8 MB).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/tools/eeprom/hp715_default.eep}"
SIM="${SIM:-}"                  # a romsim binary; default: build verilator/obj_dir_rom
ROM="${ROM:-$ROOT/roms/hp715_pdc_rev1.6.bin}"
CONSOLE="${CONSOLE:-graphics}"
case "$CONSOLE" in graphics) CON="graphics" ;; rs232) CON="rs232" ;; *) echo "CONSOLE graphics|rs232" >&2; exit 2 ;; esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$SIM" ]; then make -s -C "$ROOT/verilator" romsim; SIM="$ROOT/verilator/obj_dir_rom/Vemu"; fi
python3 "$ROOT/tools/eeprom/mkeeprom.py" bootstrap --hex "$TMP/boot.hex"
"$SIM" --rom "$ROM" +eeprom="$TMP/boot.hex" +eeprom_out="$TMP/out.hex" --ram-lg 3 --turbo 15 \
    --type "manufactureoff\r" \
    --then "BOOT_ADMIN>" "chassis off\r" \
    --then "BOOT_ADMIN>" "path console $CON\r" \
    --then "BOOT_ADMIN>" "monitor graphics.1\r" \
    --then "BOOT_ADMIN>" "path\r" \
    --then "BOOT_ADMIN>" "auto\r" \
    --until "BOOT_ADMIN>" --max-cycles 200000000 > "$TMP/console.txt" 2>&1 || {
        cat "$TMP/console.txt"; echo "mkrelease: the ROM run failed" >&2; exit 1; }
sed -n '/manufactureoff/,$p' "$TMP/console.txt" | grep -v '^romsim'
python3 "$ROOT/tools/eeprom/mkeeprom.py" fromhex "$TMP/out.hex" "$OUT"
python3 "$ROOT/tools/eeprom/mkeeprom.py" show "$OUT"
sha256sum "$OUT"
