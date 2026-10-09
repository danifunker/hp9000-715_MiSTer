#!/usr/bin/env python3
"""A screenshot of the MiSTer's real HDMI output, through the user's OBS.

OBS captures the MiSTer's HDMI; obs-websocket v5 (no authentication) gives a
source's picture. Python standard library only.

    obs_shot.py OUT.png [--host 192.168.99.82] [--port 4455] [--source NAME]

Without --source the current program scene is taken.
"""
import argparse, base64, json, os, socket, struct, sys


class WS:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(('GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                        'Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n'
                        'Sec-WebSocket-Protocol: obswebsocket.json\r\n\r\n' % (host, port, key)).encode())
        hdr = b''
        while b'\r\n\r\n' not in hdr:
            c = self.s.recv(1)
            if not c: raise IOError('connection closed during the handshake')
            hdr += c
        if b' 101 ' not in hdr.split(b'\r\n')[0]: raise IOError(hdr.decode(errors='replace'))

    def _read(self, n):
        b = b''
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c: raise IOError('connection closed')
            b += c
        return b

    def recv(self):
        msg = b''
        while True:
            h = self._read(2)
            fin, op, n = h[0] & 0x80, h[0] & 15, h[1] & 0x7F
            if n == 126: n = struct.unpack('>H', self._read(2))[0]
            elif n == 127: n = struct.unpack('>Q', self._read(8))[0]
            mask = self._read(4) if h[1] & 0x80 else None
            d = self._read(n)
            if mask: d = bytes(x ^ mask[i % 4] for i, x in enumerate(d))
            if op == 9: self._send(d, 10); continue          # ping -> pong
            if op == 8: raise IOError('closed by OBS: %r' % d[2:])
            msg += d
            if fin: return json.loads(msg)

    def _send(self, d, op=1):
        m = os.urandom(4)
        n = len(d)
        h = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else
                                   bytes([0x80 | 126]) + struct.pack('>H', n) if n < 65536 else
                                   bytes([0x80 | 127]) + struct.pack('>Q', n))
        self.s.sendall(h + m + bytes(x ^ m[i % 4] for i, x in enumerate(d)))

    def send(self, obj): self._send(json.dumps(obj).encode())

    def request(self, rtype, data=None):
        rid = os.urandom(4).hex()
        self.send({'op': 6, 'd': {'requestType': rtype, 'requestId': rid, 'requestData': data or {}}})
        while True:
            r = self.recv()
            if r.get('op') == 7 and r['d'].get('requestId') == rid:
                st = r['d']['requestStatus']
                if not st.get('result'): raise IOError('%s: %s' % (rtype, st))
                return r['d'].get('responseData', {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--host', default=os.environ.get('OBS_HOST', '192.168.99.82'))
    ap.add_argument('--port', type=int, default=4455)
    ap.add_argument('--source')
    a = ap.parse_args()
    ws = WS(a.host, a.port)
    hello = ws.recv()
    if hello.get('d', {}).get('authentication'): sys.exit('OBS asks for a password: disable authentication')
    ws.send({'op': 1, 'd': {'rpcVersion': 1, 'eventSubscriptions': 0}})
    ws.recv()                                                  # Identified
    src = a.source or ws.request('GetCurrentProgramScene')['currentProgramSceneName']
    r = ws.request('GetSourceScreenshot', {'sourceName': src, 'imageFormat': 'png'})
    img = r['imageData'].split(',', 1)[1]
    open(a.out, 'wb').write(base64.b64decode(img))
    print('%s: %s' % (a.out, src))


if __name__ == '__main__':
    main()
