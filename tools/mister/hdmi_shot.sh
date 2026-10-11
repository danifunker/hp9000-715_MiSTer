#!/usr/bin/env bash
# hdmi_shot.sh OUT.png [scale] -- the board's HDMI through OBS, cropped to the HP9K715 source (1488x837 at 432,243)
cd /home/dani/repos/hp9000-715 || exit 1
tmp=$(mktemp --suffix=.png)
timeout 30 python3 tools/mister/obs_shot.py "$tmp" >/dev/null 2>&1
python3 -c "
import sys; from PIL import Image
im=Image.open(sys.argv[1]).crop((432,243,1920,1080)); s=float(sys.argv[3])
im=im.resize((int(1488*s),int(837*s))) if s!=1 else im; im.save(sys.argv[2])" "$tmp" "$1" "${2:-1}"
rm -f "$tmp"
