#!/usr/bin/env python3
"""Type on the MiSTer's keyboard and move its mouse from a script.

Runs on the MiSTer (python3, /dev/uinput, no modules beyond the standard
library): creates a virtual keyboard and a virtual mouse through uinput,
waits for Main_MiSTer to pick them up, sends the events, and removes them.
Main_MiSTer passes them to the core like a real USB keyboard/mouse -- for the
HP9K715 core that is the LASI PS/2 keyboard (hps_io ps2_key) and mouse, so
this drives the graphics console, HP-UX's ITE and X without anyone at the
board. tools/mister/board.sh `key` and `mouse` wrap it.

    kbd.py type TEXT        TEXT with \\r (Enter), \\t, \\b, \\e (Escape) escapes;
                            {up} {down} {left} {right} {f1}..{f12} {ctrl-x}
    kbd.py mouse DX DY [BUTTONS]   relative move in steps of at most 10,
                            then BUTTONS (l, r, m: press and release each)
"""
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
BTN = {'l': 0x110, 'r': 0x111, 'm': 0x112}

# US layout: character -> (Linux keycode, shift)
KEYS = {}
for i, c in enumerate('1234567890'): KEYS[c] = (2 + i, False)
for i, c in enumerate('!@#$%^&*()'): KEYS[c] = (2 + i, True)
for row, base in (('qwertyuiop', 16), ('asdfghjkl', 30), ('zxcvbnm', 44)):
    for i, c in enumerate(row):
        KEYS[c] = (base + i, False)
        KEYS[c.upper()] = (base + i, True)
for c, k in (('-', 12), ('=', 13), ('[', 26), (']', 27), (';', 39), ("'", 40), ('`', 41),
             ('\\', 43), (',', 51), ('.', 52), ('/', 53), (' ', 57)):
    KEYS[c] = (k, False)
for c, k in (('_', 12), ('+', 13), ('{', 26), ('}', 27), (':', 39), ('"', 40), ('~', 41),
             ('|', 43), ('<', 51), ('>', 52), ('?', 53)):
    KEYS[c] = (k, True)
KEYS['\r'] = KEYS['\n'] = (28, False)
KEYS['\t'] = (15, False)
KEYS['\b'] = (14, False)
KEYS['\x1b'] = (1, False)
NAMED = {'up': 103, 'down': 108, 'left': 105, 'right': 106, 'home': 102, 'end': 107,
         'pgup': 104, 'pgdn': 109, 'ins': 110, 'del': 111}
for n in range(1, 11): NAMED['f%d' % n] = 58 + n
NAMED['f11'], NAMED['f12'] = 87, 88
SHIFT, CTRL = 42, 29


def device(name, keys=(), rels=()):
    fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in keys: fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    if rels:
        fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
        for r in rels: fcntl.ioctl(fd, UI_SET_RELBIT, r)
    # struct uinput_user_dev: name[80], input_id (bus, vendor, product, version), ff_effects_max, 4 x 64 s32
    os.write(fd, struct.pack('80sHHHHi', name.encode(), 3, 0x1209, 0x7150, 1, 0) + bytes(4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    return fd


def ev(fd, t, c, v):
    os.write(fd, struct.pack('llHHi', 0, 0, t, c, v))


def syn(fd):
    ev(fd, EV_SYN, 0, 0)


def press(fd, k, shift=False, ctrl=False):
    for m, on in ((SHIFT, shift), (CTRL, ctrl)):
        if on: ev(fd, EV_KEY, m, 1); syn(fd); time.sleep(0.03)
    ev(fd, EV_KEY, k, 1); syn(fd); time.sleep(0.05)
    ev(fd, EV_KEY, k, 0); syn(fd); time.sleep(0.03)
    for m, on in ((CTRL, ctrl), (SHIFT, shift)):
        if on: ev(fd, EV_KEY, m, 0); syn(fd); time.sleep(0.03)
    time.sleep(0.06)


def tokens(text):
    text = text.encode().decode('unicode_escape').replace('\\e', '\x1b')
    i = 0
    while i < len(text):
        if text[i] == '{' and '}' in text[i:]:
            j = text.index('}', i)
            yield text[i + 1:j]
            i = j + 1
        else:
            yield text[i]
            i += 1


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('type', 'mouse'):
        print(__doc__); sys.exit(2)
    if sys.argv[1] == 'type':
        fd = device('hp715 virtual keyboard', keys=range(1, 120))
        time.sleep(1.5)                 # Main_MiSTer finds new input devices by inotify
        for t in tokens(sys.argv[2]):
            if len(t) == 1 and t in KEYS:
                press(fd, *KEYS[t])
            elif t.startswith('ctrl-') and t[5:] in KEYS:
                press(fd, KEYS[t[5:]][0], ctrl=True)
            elif t in NAMED:
                press(fd, NAMED[t])
            else:
                print('no key for %r' % t, file=sys.stderr)
    else:
        dx, dy = int(sys.argv[2]), int(sys.argv[3])
        buttons = sys.argv[4] if len(sys.argv) > 4 else ''
        fd = device('hp715 virtual mouse', keys=BTN.values(), rels=(0, 1))
        time.sleep(1.5)
        while dx or dy:
            sx = max(-10, min(10, dx)); sy = max(-10, min(10, dy))
            ev(fd, EV_REL, 0, sx); ev(fd, EV_REL, 1, sy); syn(fd)
            dx -= sx; dy -= sy
            time.sleep(0.02)
        for b in buttons:
            ev(fd, EV_KEY, BTN[b], 1); syn(fd); time.sleep(0.08)
            ev(fd, EV_KEY, BTN[b], 0); syn(fd); time.sleep(0.08)
    time.sleep(0.5)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)


main()
