#!/usr/bin/env python3
# con.py -- connect to serial.sock: append output to console.log, send what is written to in.fifo (\r etc. as in the text)
import os, socket, select, time
D = os.path.dirname(os.path.abspath(__file__)); fifo = D + '/in.fifo'
if not os.path.exists(fifo): os.mkfifo(fifo)
s = socket.socket(socket.AF_UNIX)
for i in range(50):
    try: os.chdir(D); s.connect('serial.sock'); break
    except OSError: time.sleep(0.2)
f = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK); log = open(D + '/console.log', 'ab')
while True:
    r, _, _ = select.select([s, f], [], [], 1)
    if s in r:
        d = s.recv(65536)
        if not d: break
        log.write(d); log.flush()
    if f in r:
        d = os.read(f, 4096)
        if d:
            for ch in d.decode('latin1').encode('latin1').decode('unicode_escape').encode('latin1'):
                s.send(bytes([ch])); time.sleep(0.02)
        else:
            os.close(f); f = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
