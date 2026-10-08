#!/usr/bin/env python3
"""Build an EEPROM image for the 715's 8 KB EEPROM at 0xF00C0000.

FIRMWARE.md 5 and BOOTFLOW.md 2.3: a blank part (all 0xFF) makes PDC 1.6 run
its first-boot initialisation (EE 0x16D9 != 'N'), which leaves the machine in
manufacturing mode with fastboot off. `bootstrap` writes exactly what that
initialisation writes, with two changes chosen here:

  * fastboot (EE 0x1695) on, so the power-on tests are the short ones and the
    1-second waits of manufacturing mode are skipped;
  * the LAN station address (EE 0x16B4) set (default 08:00:09:71:5A:01), so
    the ROM does not ask for it.

The manufacturing / chassis-code byte (EE 0x1694) stays 0xB1 by default:
console and keyboard on RS-232, chassis codes printed there, BOOT_ADMIN at
once. Identity and stable storage (EE 0x16D8 != 'G') are left blank, so the
ROM writes its own defaults on the first boot.

Outputs: an 8192-byte binary (MiSTer) and/or a $readmemh file of 2048 32-bit
big-endian words (the simulator's +eeprom=).

  mkeeprom.py bootstrap -o ee.bin --hex ee.hex [--mac 08:00:09:71:5A:01]
              [--manufacturing 0xB1] [--fastboot 1]
  mkeeprom.py tohex ee.bin ee.hex        (and fromhex ee.hex ee.bin)
  mkeeprom.py show ee.bin                 the flag bytes
"""
import argparse, sys

SIZE = 8192


def put32(b, off, v):
    b[off:off + 4] = v.to_bytes(4, 'big')


def bootstrap(mac, manuf, fastboot):
    b = bytearray([0xFF] * SIZE)
    for off in (0x16A4, 0x16A8, 0x16AC, 0x16B0):
        put32(b, off, 0)
    b[0x1694] = manuf          # 0xB1 manufacturing + chassis codes, 0xB0 codes only, 0xFF off
    b[0x1699] = 1              # diagnostic boot
    b[0x1695] = fastboot
    b[0x1696] = 0              # secure off
    b[0x16B4:0x16BA] = mac
    b[0x16BA:0x16C0] = bytes([0x08, 0x00, 0x09, 0xFF, 0xFF, 0xFF])
    b[0x16D9] = ord('N')       # EEPROM initialised
    b[0x16DA] = ord('Y')
    put32(b, 0x1E0C, 1)
    for off in (0x1E04, 0x400, 0x404, 0x408):
        put32(b, off, 0xFFFFFFFF)
    return b


def to_hex(b):
    return ''.join('%08x\n' % int.from_bytes(b[i:i + 4], 'big') for i in range(0, SIZE, 4))


def from_hex(text):
    words = [int(w, 16) for w in text.split() if not w.startswith('//') and not w.startswith('@')]
    b = bytearray()
    for w in words:
        b += w.to_bytes(4, 'big')
    return bytes(b[:SIZE]).ljust(SIZE, b'\xff')


def show(b):
    def c(x):
        return chr(x) if 32 <= x < 127 else '.'
    print('0x1694 chassis/manuf %02X   0x1695 fastboot %02X   0x1696 secure %02X   0x1699 diag %02X'
          % (b[0x1694], b[0x1695], b[0x1696], b[0x1699]))
    print('0x16D8 %02X %s   0x16D9 %02X %s   0x16DA %02X %s'
          % (b[0x16D8], c(b[0x16D8]), b[0x16D9], c(b[0x16D9]), b[0x16DA], c(b[0x16DA])))
    print('LAN 1 %s   LAN 2 %s' % (':'.join('%02X' % x for x in b[0x16B4:0x16BA]),
                                   ':'.join('%02X' % x for x in b[0x16BA:0x16C0])))
    print('HV area +0 %08X +4 %08X   monitor 0x16CA %02X'
          % (int.from_bytes(b[0x1200:0x1204], 'big'), int.from_bytes(b[0x1204:0x1208], 'big'), b[0x16CA]))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('bootstrap')
    p.add_argument('-o', '--out')
    p.add_argument('--hex')
    p.add_argument('--mac', default='08:00:09:71:5A:01')
    p.add_argument('--manufacturing', default='0xB1')
    p.add_argument('--fastboot', default='1')
    p = sub.add_parser('tohex'); p.add_argument('bin'); p.add_argument('hex')
    p = sub.add_parser('fromhex'); p.add_argument('hex'); p.add_argument('bin')
    p = sub.add_parser('show'); p.add_argument('file')
    a = ap.parse_args()
    if a.cmd == 'bootstrap':
        mac = bytes(int(x, 16) for x in a.mac.split(':'))
        assert len(mac) == 6
        b = bootstrap(mac, int(a.manufacturing, 0), int(a.fastboot, 0))
        if a.out:
            open(a.out, 'wb').write(b)
        if a.hex:
            open(a.hex, 'w').write(to_hex(b))
    elif a.cmd == 'tohex':
        open(a.hex, 'w').write(to_hex(open(a.bin, 'rb').read()))
    elif a.cmd == 'fromhex':
        open(a.bin, 'wb').write(from_hex(open(a.hex).read()))
    else:
        d = open(a.file, 'rb').read()
        if a.file.endswith('.hex'):
            d = from_hex(d.decode())
        show(d)


if __name__ == '__main__':
    main()
