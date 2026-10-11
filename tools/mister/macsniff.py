#!/usr/bin/env python3
# macsniff.py MAC [SECS] -- on the MiSTer: one line per frame from or to MAC on eth0 (ethertype, IP proto/ports, length)
import socket, struct, sys, time
mac = bytes.fromhex(sys.argv[1].replace(':', '')); end = time.time() + float(sys.argv[2] if len(sys.argv) > 2 else 120)
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3)); s.bind(('eth0', 0)); s.settimeout(1)
while time.time() < end:
    try: f, a = s.recvfrom(4096)
    except socket.timeout: continue
    if f[6:12] != mac and f[0:6] != mac: continue
    et = f[12:14].hex(); d = ''
    if et == '0800':
        p = f[23]; src = socket.inet_ntoa(f[26:30]); dst = socket.inet_ntoa(f[30:34]); u = 14 + (f[14] & 15) * 4
        d = '%s->%s proto %d' % (src, dst, p)
        if p in (6, 17): d += ' %d->%d' % struct.unpack('>HH', f[u:u+4])
    elif et == '0806': d = 'ARP op %d %s asks %s' % (f[21], socket.inet_ntoa(f[28:32]), socket.inet_ntoa(f[38:42]))
    print('%s %s %s->%s type %s len %d %s' % (time.strftime('%T'), 'OUT' if f[6:12] == mac else 'IN ', f[6:12].hex(':'), f[0:6].hex(':'), et, len(f), d), flush=True)
