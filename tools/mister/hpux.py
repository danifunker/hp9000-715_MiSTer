#!/usr/bin/env python3
"""Run commands on the board's HP-UX over its LAN (the 82596, lan1).

    hpux.py run 'cmd' ['cmd' ...]      telnet in as root, run each command,
                                       print its output and exit status
    hpux.py put LOCAL REMOTE           ftp a file in (binary)
    hpux.py get REMOTE LOCAL           ftp a file out

Environment: HPUX_HOST (default 192.168.99.215), HPUX_USER (root),
HPUX_PASS (password, the board image's -- disks/README.md).
"""
import ftplib, os, sys, time, warnings

warnings.filterwarnings('ignore', category=DeprecationWarning)
import telnetlib                                              # noqa: E402

HOST = os.environ.get('HPUX_HOST', '192.168.99.215')
USER = os.environ.get('HPUX_USER', 'root')
PASS = os.environ.get('HPUX_PASS', 'password')
MARK = '__HP715_%d__' % os.getpid()


def run(cmds):
    t = telnetlib.Telnet(HOST, 23, 30)
    t.read_until(b'login:', 30); t.write(USER.encode() + b'\r\n')
    t.read_until(b'assword:', 30); t.write(PASS.encode() + b'\r\n')
    # the login's TERM question, then a plain shell without echo
    i, _, _ = t.expect([rb'TERM = \([^)]*\)', rb'# $'], 30)
    if i == 0:
        t.write(b'dumb\r\n')
        t.read_until(b'# ', 30)
    t.write(b'exec /usr/bin/sh\r\n')
    time.sleep(1)
    t.write(b'PS1=""; stty -echo\r\n')
    time.sleep(1)
    t.read_very_eager()
    rc = 0
    for c in cmds:
        t.write(('%s; echo %s $?\r\n' % (c, MARK)).encode())
        out = t.read_until(MARK.encode(), 600).decode('latin-1')
        tail = t.read_until(b'\n', 10).decode('latin-1').strip()
        body = out[:out.rfind(MARK)]
        lines = [l.rstrip('\r') for l in body.split('\n')]
        while lines and (lines[0].strip() in ('', '$') or lines[0].lstrip('$ ').startswith(c[:20])):
            lines.pop(0)
        print('\n'.join(l for l in lines if l.strip() not in ('$',)).rstrip())
        if tail not in ('0', ''):
            print('[exit %s]' % tail); rc = 1
    t.write(b'exit\r\n')
    t.close()
    return rc


def ftp(op, a, b):
    f = ftplib.FTP(HOST, timeout=60)
    f.login(USER, PASS)
    if op == 'put':
        with open(a, 'rb') as fh: f.storbinary('STOR ' + b, fh)
    else:
        with open(b, 'wb') as fh: f.retrbinary('RETR ' + a, fh.write)
    f.quit()
    return 0


if __name__ == '__main__':
    if len(sys.argv) >= 3 and sys.argv[1] == 'run':
        sys.exit(run(sys.argv[2:]))
    if len(sys.argv) == 4 and sys.argv[1] in ('put', 'get'):
        sys.exit(ftp(sys.argv[1], sys.argv[2], sys.argv[3]))
    print(__doc__); sys.exit(2)
