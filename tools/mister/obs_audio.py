#!/usr/bin/env python3
"""The audio levels of the MiSTer's real HDMI output, through the user's OBS.

obs-websocket v5 (no authentication) streams every input's volume meters
(the InputVolumeMeters event, ~20 a second); this prints, every --step
seconds, each input's peak level per channel in dBFS over that step
(-inf = silence), for --secs seconds. A sound played by the core shows as
the capture device's levels rising above its noise floor.

    obs_audio.py [--secs 10] [--step 0.5] [--input NAME] [--host ...] [--port ...]
"""
import argparse, math, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from obs_shot import WS                                       # noqa: E402

INPUT_VOLUME_METERS = 1 << 16


def db(x):
    return '-inf' if x <= 0 else '%.1f' % (20 * math.log10(x))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--secs', type=float, default=10)
    ap.add_argument('--step', type=float, default=0.5)
    ap.add_argument('--input')
    ap.add_argument('--host', default=os.environ.get('OBS_HOST', '192.168.99.82'))
    ap.add_argument('--port', type=int, default=4455)
    a = ap.parse_args()
    ws = WS(a.host, a.port)
    hello = ws.recv()
    if hello.get('d', {}).get('authentication'): sys.exit('OBS asks for a password: disable authentication')
    ws.send({'op': 1, 'd': {'rpcVersion': 1, 'eventSubscriptions': INPUT_VOLUME_METERS}})
    ws.recv()                                                  # Identified
    t0 = time.time(); t_next = t0 + a.step
    peaks = {}
    overall = {}
    while time.time() - t0 < a.secs:
        m = ws.recv()
        if m.get('op') != 5 or m['d'].get('eventType') != 'InputVolumeMeters':
            continue
        for inp in m['d']['eventData']['inputs']:
            name = inp['inputName']
            if a.input and name != a.input:
                continue
            lv = [ch[1] for ch in inp.get('inputLevelsMul', [])]  # [magnitude, peak, input peak]
            p = peaks.setdefault(name, [0.0] * len(lv))
            o = overall.setdefault(name, [0.0] * len(lv))
            for i, v in enumerate(lv[:len(p)]):
                p[i] = max(p[i], v); o[i] = max(o[i], v)
        if time.time() >= t_next:
            t_next += a.step
            line = '  '.join('%s: %s' % (n, '/'.join(db(v) for v in p) or 'no channels') for n, p in sorted(peaks.items()))
            print('%6.1f s  %s' % (time.time() - t0, line), flush=True)
            peaks = {}
    print('peak over %g s: %s' % (a.secs, '  '.join('%s: %s dBFS' % (n, '/'.join(db(v) for v in o)) for n, o in sorted(overall.items()))))


if __name__ == '__main__':
    main()
