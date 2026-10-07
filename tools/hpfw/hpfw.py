#!/usr/bin/env python3
"""Unpack an HP 9000 Series 700 firmware update tape image (e.g. C7X50016.frm).

The .frm file is a LIF volume (magic 0x8000 "LIF") holding the update tools
(ISL, ODE, UPDATE, ...) and the ROM images (IMAGE1A, IMAGE1B, ...). Each ROM
image carries a 256-byte "Firmware Image Hdr. v1.00":

    0x00  u32  magic 0x02468ace
    0x04  str  "@(#)Firmware Image Hdr. v1.00"
    0x24  u32  payload offset (0x100)
    0x28  u32  payload length in bytes
    0x40  u32  32-bit big-endian word sum of the payload (zero-padded to 4)

The other fields (0x2c, 0x38, 0x3c, 0x48) are not understood yet.

usage:
    hpfw.py list    FRM
    hpfw.py extract FRM OUTDIR        # every LIF file, plus <name>.payload.bin
                                      # for each firmware image
"""
import os
import struct
import sys

LIF_MAGIC = 0x8000
FWIMG_MAGIC = 0x02468ACE
SECTOR = 256


def lif_entries(data):
    magic, = struct.unpack(">H", data[0:2])
    if magic != LIF_MAGIC:
        raise ValueError("not a LIF volume (magic %#06x)" % magic)
    dir_start = struct.unpack(">I", data[8:12])[0] * SECTOR
    dir_len = struct.unpack(">I", data[16:20])[0] * SECTOR
    for off in range(dir_start, dir_start + dir_len, 32):
        ent = data[off:off + 32]
        ftype, start, length = struct.unpack(">HII", ent[10:20])
        if ftype == 0xFFFF:          # end of directory
            break
        if ftype == 0:               # purged entry
            continue
        name = ent[0:10].decode("ascii", "replace").rstrip()
        yield name, ftype, start * SECTOR, length * SECTOR, ent[20:26].hex()


def fw_image(blob):
    """Return (payload, header dict) if blob is a firmware image, else None."""
    if len(blob) < 0x100 or struct.unpack(">I", blob[0:4])[0] != FWIMG_MAGIC:
        return None
    hdr = {
        "id": blob[4:0x24].split(b"\0")[0].decode("ascii", "replace"),
        "offset": struct.unpack(">I", blob[0x24:0x28])[0],
        "length": struct.unpack(">I", blob[0x28:0x2C])[0],
        "checksum": struct.unpack(">I", blob[0x40:0x44])[0],
        "unknown": {"0x2c": struct.unpack(">I", blob[0x2C:0x30])[0],
                    "0x38": struct.unpack(">I", blob[0x38:0x3C])[0],
                    "0x3c": struct.unpack(">I", blob[0x3C:0x40])[0],
                    "0x48": struct.unpack(">I", blob[0x48:0x4C])[0]},
    }
    payload = blob[hdr["offset"]:hdr["offset"] + hdr["length"]]
    padded = payload + b"\0" * (-len(payload) % 4)
    total = sum(struct.unpack(">%dI" % (len(padded) // 4), padded)) & 0xFFFFFFFF
    hdr["checksum_ok"] = total == hdr["checksum"]
    return payload, hdr


def main(argv):
    if len(argv) < 3 or argv[1] not in ("list", "extract"):
        sys.exit(__doc__)
    data = open(argv[2], "rb").read()
    outdir = argv[3] if argv[1] == "extract" else None
    if outdir:
        os.makedirs(outdir, exist_ok=True)
    for name, ftype, start, length, date in lif_entries(data):
        blob = data[start:start + length]
        line = "%-10s type=%#06x off=%#08x len=%7d date=%s" % (
            name, ftype, start, length, date)
        img = fw_image(blob)
        if img:
            payload, hdr = img
            line += "  [firmware image: %d bytes, checksum %#010x %s, other %s]" % (
                hdr["length"], hdr["checksum"],
                "OK" if hdr["checksum_ok"] else "MISMATCH",
                " ".join("%s=%#x" % kv for kv in hdr["unknown"].items()))
        print(line)
        if outdir:
            with open(os.path.join(outdir, name), "wb") as f:
                f.write(blob)
            if img:
                with open(os.path.join(outdir, name + ".payload.bin"), "wb") as f:
                    f.write(img[0])


if __name__ == "__main__":
    main(sys.argv)
