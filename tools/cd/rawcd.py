#!/usr/bin/env python3
"""rawcd.py -- raw CD images (BIN, MDF) to the 2048-byte-sector ISO the
core's CD-ROM slot takes (HP9K715.sv "CD-ROM (ID 2)", rtl/scsi/scsi_targets.sv).

A raw image keeps every sector as recorded: 2352 bytes (sync, header, user
data, EDC/ECC), or 2448 with the 96 bytes of subchannel after each (Alcohol
120% MDF). The sector size is found from the file size and the sync pattern;
mode 1 sectors give bytes 16..2063, mode 2 form 1 bytes 24..2071. Only data
tracks are converted: the image must be a single data track (as HP's
install CDs are).

  rawcd.py info  IMAGE
  rawcd.py iso   IMAGE OUT.iso
"""
import sys

SYNC = bytes([0] + [0xFF] * 10 + [0])


def sector_size(path):
    with open(path, "rb") as f:
        head = f.read(2448 * 4)
        f.seek(0, 2)
        size = f.tell()
    for ss in (2448, 2352):
        if size % ss == 0 and all(head[i * ss:i * ss + 12] == SYNC for i in range(4)):
            return ss, size // ss
    if size % 2048 == 0:
        return 2048, size // 2048
    raise SystemExit(f"{path}: not a raw 2352/2448 or 2048-byte image ({size} bytes)")


def user_data(sec):
    mode = sec[15]
    if mode == 1:
        return sec[16:2064]
    if mode == 2:
        return sec[24:2072]
    raise ValueError(f"sector mode {mode}")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd, path = sys.argv[1], sys.argv[2]
    ss, n = sector_size(path)
    if cmd == "info":
        with open(path, "rb") as f:
            sec = f.read(ss)
        mode = sec[15] if ss != 2048 else None
        print(f"{path}: {n} sectors of {ss} bytes, mode {mode}, {n * 2048} bytes as an ISO")
        return
    if cmd != "iso" or len(sys.argv) != 4:
        raise SystemExit(__doc__)
    with open(path, "rb") as f, open(sys.argv[3], "wb") as o:
        for i in range(n):
            sec = f.read(ss)
            o.write(sec if ss == 2048 else user_data(sec))
    print(f"{sys.argv[3]}: {n} sectors, {n * 2048} bytes")


if __name__ == "__main__":
    main()
