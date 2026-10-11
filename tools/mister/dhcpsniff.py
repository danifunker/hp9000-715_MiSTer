#!/usr/bin/env python3
# dhcpsniff.py [SECS] -- run on the MiSTer: print every DHCP frame (UDP 67/68) seen on eth0, in or out (read-only AF_PACKET)
import socket, struct, sys, time
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3)); s.bind(('eth0', 0)); s.settimeout(1)
end = time.time() + float(sys.argv[1] if len(sys.argv) > 1 else 120)
MT = {1: 'DISCOVER', 2: 'OFFER', 3: 'REQUEST', 4: 'DECLINE', 5: 'ACK', 6: 'NAK', 7: 'RELEASE', 8: 'INFORM'}
while time.time() < end:
    try: f, a = s.recvfrom(2048)
    except socket.timeout: continue
    if len(f) < 42 or f[12:14] != b'\x08\x00' or f[23] != 17: continue
    ihl = (f[14] & 15) * 4; u = 14 + ihl
    sp, dp = struct.unpack('>HH', f[u:u+4])
    if not ({sp, dp} & {67, 68}): continue
    b = u + 8; mt = '?'
    o = b + 240
    while o < len(f) - 1 and f[o] != 255:
        if f[o] == 0: o += 1; continue
        if f[o] == 53: mt = MT.get(f[o+2], str(f[o+2]))
        o += 2 + f[o+1]
    chaddr = f[b+28:b+34].hex(':'); yi = socket.inet_ntoa(f[b+16:b+20]); bc = f[b+10] & 0x80
    print('%s %s %s -> %s %s chaddr %s yiaddr %s bcast %d pkttype %d' % (time.strftime('%T'), mt,
          f[6:12].hex(':'), f[0:6].hex(':'), socket.inet_ntoa(f[26:30]) + '->' + socket.inet_ntoa(f[30:34]), chaddr, yi, bool(bc), a[2]), flush=True)
