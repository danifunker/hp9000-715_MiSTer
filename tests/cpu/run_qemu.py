#!/usr/bin/env python3
"""Run a pacputest ROM on QEMU -M 715 and capture its serial output.

usage: run_qemu.py ROM.elf LOG [--timeout SECONDS]

QEMU is $QEMU_HPPA, else the session build noted in CLAUDE.md, else
qemu-system-hppa on PATH (the distro's 8.2 has no -M 715). The run stops
when the ROM prints "== end" (or "!! " for an unhandled HPMC/TOC).
"""
import os
import shutil
import subprocess
import sys
import time

def find_qemu():
    q = os.environ.get("QEMU_HPPA")
    if q:
        return q
    for c in ("/tmp/claude-1000/-home-dani-repos-hp9000-715/c636bb42-9bcf-47e9-83f8-8ade60a40f61/scratchpad/keep/qemu/build-hppa/qemu-system-hppa",
              os.path.expanduser("~/src/qemu-11.1.1/build-hppa/qemu-system-hppa")):
        if os.path.exists(c):
            return c
    return shutil.which("qemu-system-hppa")

def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    rom, log = argv[1], argv[2]
    timeout = float(argv[argv.index("--timeout") + 1]) if "--timeout" in argv else 120
    qemu = find_qemu()
    cmd = [qemu, "-M", "715", "-m", "64", "-bios", rom, "-display", "none",
           "-monitor", "none", "-serial", "stdio", "-nodefaults"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = bytearray()
    start = time.time()
    os.set_blocking(p.stdout.fileno(), False)
    done = False
    while time.time() - start < timeout:
        chunk = p.stdout.read()
        if chunk:
            out += chunk
            tail = out[-200:]
            if b"== end" in tail or b"!! " in tail:
                time.sleep(0.2)
                out += p.stdout.read() or b""
                done = True
                break
        elif p.poll() is not None:
            break
        else:
            time.sleep(0.05)
    p.kill()
    p.wait()
    text = out.decode("latin-1").replace("\r", "")
    with open(log, "w") as f:
        f.write(text)
    status = "complete" if done and b"== end" in out else "INCOMPLETE"
    print("%s: %d bytes, %s (%.1f s)" % (log, len(text), status, time.time() - start))
    return 0 if status == "complete" else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv))
