#!/usr/bin/env python3
"""Read the core's debug event ring (rtl/mister/trace_ddr3.sv) from DDR3.

Runs on the MiSTer (python3, /dev/mem). The ring is 64K records of 32 bytes
at physical 0x32000000; each record holds a sequence number, the cycle, and
one event of rtl/hp715.sv's dbg_ev (types below). DDR3 is not cleared when a
core loads, so `clear` the ring before the run you want to look at.

    trace_dump.py clear
    trace_dump.py dump [--last N] [--raw]      oldest first
    trace_dump.py decode LOG                   the simulator's --evtrace lines, decoded

Output lines match the simulator's --evtrace ("EV seq tT aAA addr data"),
decoded unless --raw:
    1 SCSI byte (aux = phase)      2 SCRIPTS instruction (addr = DSP)
    3 SCSI interrupt                4/5 DMA read/write (aux = byte enables)
    6/7 CPU line read/write (lineRI = I-cache fill)
    8/9 CPU uncached read/write (RAM, 53C710)
    10 selection (aux = ID)         11 interruption (vector, IIAOQ, insn, IIASQ)
    12 cache maintenance (FDC/FDCE/PDC/FIC/FICE: physical line, VA)
    13 PS/2 byte (kbd/mouse, > host to device, < device to host)
    14 key event from hps_io (make/break, E0, set-2 code)
    15 HP-UX system call (r22 = number, r26/r25 = first two arguments)
    16 the rest of it (addr = r2, the caller of libc's stub; r24/r23)
    17 82596 event (PORT, CA, CB, STAT, RX, TX, reset)
    18 the system call's return (r28, r22 at the return to user mode)
    19 user-mode control flow after the one-shot trigger (from -> to, the instruction reached)
The recorder freezes 1024 events after a user-mode trap 8/10/11 (until the
core is reset), so after a SIGILL the ring ends with what led to it.
"""
import mmap, os, struct, sys

BASE, N, REC = 0x32000000, 1 << 16, 32
PHASE = ['DATA_OUT', 'DATA_IN', 'CMD', 'STATUS', 'RES4', 'RES5', 'MSG_OUT', 'MSG_IN']


def ring(write=False):
    fd = os.open('/dev/mem', (os.O_RDWR if write else os.O_RDONLY) | os.O_SYNC)
    prot = mmap.PROT_READ | (mmap.PROT_WRITE if write else 0)
    return mmap.mmap(fd, N * REC, mmap.MAP_SHARED, prot, offset=BASE)


def decode(t, a, addr, d):
    if t == 1: return 'scsi %-8s %02x' % (PHASE[a & 7], d & 0xFF)
    if t == 2: return 'scr  %08x: %08x %08x' % (addr, d >> 32, d & 0xFFFFFFFF)
    if t == 3: return 'irq  dstat %02x sstat0 %02x dsps %08x' % (d >> 56, (d >> 48) & 0xFF, d & 0xFFFFFFFF)
    if t in (4, 5): return 'dma%s %08x be=%02x %016x' % ('R' if t == 4 else 'W', addr, a, d)
    if t == 6: return 'line%s %08x' % ('RI' if a & 1 else 'R', addr)
    if t == 7: return 'lineW %08x' % addr
    if t == 11:
        return 'trap %2d at %08x insn %08x space %04x psw %04x' % (
            a & 0x3F, addr, d >> 32, (d >> 16) & 0xFFFF, d & 0xFFFF)
    if t == 12:
        ops = (['FIL', 'FIC', 'FICE'] if a & 0x80 else ['MISS', 'FDC', 'FDCE', 'PDC'])
        op = a & 0xF
        return '%-4s pa %08x va %08x' % (ops[op] if op < len(ops) else 'op%d' % op, addr, d >> 32)
    if t in (8, 9): return 'io%s  %08x be=%02x %016x' % ('R' if t == 8 else 'W', addr, a, d)
    if t == 13: return 'ps2  %s %s %02x' % ('mouse' if a & 2 else 'kbd  ', '<' if a & 1 else '>', d & 0xFF)
    if t == 14: return 'key  %s %s%02x' % ('make ' if d >> 9 & 1 else 'break', 'E0 ' if d >> 8 & 1 else '', d & 0xFF)
    if t == 10: return 'sel  id %d %s' % (a & 7, 'answered' if d & 1 else 'no target')
    if t == 15: return 'sysc %3d r26 %08x r25 %08x' % (addr, d >> 32, d & 0xFFFFFFFF)
    if t == 16: return 'sysa rp %08x r24 %08x r23 %08x' % (addr, d >> 32, d & 0xFFFFFFFF)
    if t == 18: return 'sysr ret %08x r22 %08x at %08x' % (addr, d >> 32, d & 0xFFFFFFFF)
    if t == 19: return 'flow %08x -> %08x insn %08x' % (addr, d >> 32, d & 0xFFFFFFFF)
    if t == 17:
        k = ['?', 'PORT', 'CA', 'CB', 'STAT', 'RX', 'TX', 'RESET'][a] if a < 8 else 'k%d' % a
        if a == 2: return 'lan  CA    scb %08x cmd %04x' % (addr, d & 0xFFFF)
        if a == 3: return 'lan  CB    %08x cmd %04x link %08x' % (addr, (d >> 32) & 0xFFFF, d & 0xFFFFFFFF)
        if a == 4: return 'lan  STAT  scb %08x ev %x cus %d rus %d' % (addr, (d >> 8) & 0xF, (d >> 4) & 7, d & 0xF)
        if a == 5: return 'lan  RX    rfd %08x count %d eof %d' % (addr, d & 0x3FFF, (d >> 15) & 1)
        return 'lan  %-5s %08x %016x' % (k, addr, d)
    return 't%d a%02x %08x %016x' % (t, a, addr, d)


def main(argv):
    if not argv or argv[0] not in ('clear', 'dump', 'decode'):
        print(__doc__); return 2
    if argv[0] == 'decode':
        for line in open(argv[1], errors='replace'):
            f = line.split()
            if len(f) == 6 and f[0] == 'EV' and f[2][0] == 't':
                print('EV %s %s' % (f[1], decode(int(f[2][1:]), int(f[3][1:], 16), int(f[4], 16), int(f[5], 16))))
        return 0
    if argv[0] == 'clear':
        m = ring(True)
        m[:] = b'\xff' * (N * REC)      # seq 0xffffffff = empty
        print('cleared'); return 0
    raw = '--raw' in argv
    last = int(argv[argv.index('--last') + 1]) if '--last' in argv else None
    m = ring()
    data = m[:]
    recs = []
    for i in range(N):
        w0, w1, w2 = struct.unpack_from('<QQQ', data, i * REC)
        seq = w0 & 0xFFFFFFFF
        if seq == 0xFFFFFFFF:
            continue
        recs.append((seq, w0 >> 32, w1 >> 56, (w1 >> 48) & 0xFF, w1 & 0xFFFFFFFF, w2))
    recs.sort()
    if last:
        recs = recs[-last:]
    prev = None
    for seq, cyc, t, a, addr, d in recs:
        if prev is not None and seq != prev + 1:
            print('-- %d events lost' % (seq - prev - 1))
        prev = seq
        if raw: print('EV %d t%d a%02x %08x %016x' % (seq, t, a, addr, d))
        else:   print('EV %d %s' % (seq, decode(t, a, addr, d)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
