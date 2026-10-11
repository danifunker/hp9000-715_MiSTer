#!/usr/bin/env bash
# q11i_b160l.sh -- HP-UX 11i install CD on QEMU 11.1.1 -M B160L: CD at SCSI 2, blank 8 GiB disk at 5,
# serial console on q11i/serial.sock (q11i/con.py logs it to q11i/console.log and types from q11i/in.fifo)
D=${Q11I_DIR:?set Q11I_DIR to a work dir (holds the disk image and sockets)}; cp -n "$(dirname "$(readlink -f "$0")")/q11i_con.py" "$D/con.py" 2>/dev/null
Q=/tmp/claude-1000/-home-dani-repos-hp9000-715/c636bb42-9bcf-47e9-83f8-8ade60a40f61/scratchpad/keep/qemu/build-hppa/qemu-system-hppa
[ -f $D/disk11i.img ] || truncate -s 8G $D/disk11i.img
cd $D && exec $Q -M B160L -m ${MEM:-128} -display none -vga none -monitor unix:mon.sock,server,nowait \
  -serial unix:serial.sock,server,nowait \
  -drive if=scsi,bus=0,index=5,file=$D/disk11i.img,format=raw \
  -drive if=scsi,bus=0,index=2,media=cdrom,file=/home/dani/repos/hp9000-715/disks/hpux11i_oe_cd1.iso,format=raw,readonly=on \
  -boot d -s -d ${DFL:-unimp,guest_errors} -D $D/qemu.log $EXTRA
