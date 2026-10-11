#!/usr/bin/env bash
# hdmi_wait.sh BASE.png OUT.png [MAXSEC] -- capture every 60 s until the HDMI picture differs from BASE (>0.3 % of pixels), or MAXSEC
K=$(dirname "$0"); base=$1; out=$2; max=${3:-3600}; s=$(date +%s)
while [ $(( $(date +%s) - s )) -lt $max ]; do
  sleep 60; "$K/hdmi_shot.sh" "$out" 0.5
  d=$(python3 -c "
import sys; from PIL import Image, ImageChops
a=Image.open(sys.argv[1]).convert('L'); b=Image.open(sys.argv[2]).convert('L').resize(a.size)
h=ImageChops.difference(a,b).point(lambda v: 255 if v>40 else 0).histogram()
print(h[255]/(a.size[0]*a.size[1]))" "$base" "$out")
  echo "$(date +%T) diff $d"
  python3 -c "import sys; sys.exit(0 if float(sys.argv[1])>0.003 else 1)" "$d" && { echo CHANGED; exit 0; }
done
echo TIMEOUT
