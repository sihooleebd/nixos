#!/usr/bin/env python3
"""Local SOCKS5 front-end for sing-box.
TCP CONNECT is chained straight to the remote relay. UDP ASSOCIATE is handled here
(loopback UDP is unrestricted) and multiplexed over one TCP stream to the remote,
because ssh -L carries TCP only and sshd will never sendto() for us."""
import socket, struct, threading, select, os, signal, sys

LISTEN   = ("127.0.0.1", int(os.environ.get("GT_LOCAL_PORT", "1081")))
REMOTE   = ("127.0.0.1", int(os.environ.get("GT_REMOTE_PORT", "11080")))  # ssh -L -> rsocks
MUX_HOST = "udp.mux.arpa"
MUX_PORT = 1
BUFSZ    = 65536

def readn(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d: raise EOFError
        b += d
    return b

def socks_connect(host, port, timeout=20):
    """Open a SOCKS5 CONNECT to the remote relay."""
    r = socket.create_connection(REMOTE, timeout)
    r.sendall(b"\x05\x01\x00")
    if readn(r, 2) != b"\x05\x00": raise OSError("no socks auth")
    if isinstance(host, str) and not host.replace(".", "").isdigit():
        hb = host.encode(); req = b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb
    else:
        req = b"\x05\x01\x00\x01" + socket.inet_aton(host)
    r.sendall(req + struct.pack("!H", port))
    rep = readn(r, 4)
    if rep[1] != 0: raise OSError("socks reply %d" % rep[1])
    a = rep[3]
    readn(r, 4 if a == 1 else (16 if a == 4 else readn(r, 1)[0]))
    readn(r, 2)
    return r

def pack_frame(host, port, payload):
    return b"\x01" + socket.inet_aton(host) + struct.pack("!HH", port, len(payload)) + payload

def read_frame(s):
    atyp = readn(s, 1)[0]
    if atyp == 1:   host = socket.inet_ntoa(readn(s, 4))
    elif atyp == 4: host = socket.inet_ntop(socket.AF_INET6, readn(s, 16))
    else: raise ValueError("bad atyp")
    port, ln = struct.unpack("!HH", readn(s, 4))
    return host, port, readn(s, ln)

def udp_associate(c):
    """Give the client a loopback UDP port; bridge it to the remote over one TCP mux."""
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(("127.0.0.1", 0))
    bport = u.getsockname()[1]
    try:
        mux = socks_connect(MUX_HOST, MUX_PORT)
    except Exception:
        c.sendall(b"\x05\x01\x00\x01" + b"\x00" * 6); u.close(); return
    c.sendall(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", bport))
    peer = [None]
    stop = threading.Event()

    def down():                        # remote -> client, re-wrapped as SOCKS5 UDP
        while not stop.is_set():
            try:
                h, p, data = read_frame(mux)
                if peer[0]:
                    u.sendto(b"\x00\x00\x00\x01" + socket.inet_aton(h) + struct.pack("!H", p) + data, peer[0])
            except Exception: break
        stop.set()
    threading.Thread(target=down, daemon=True).start()

    def up():                          # client -> remote, SOCKS5 UDP header stripped
        while not stop.is_set():
            try:
                d, src = u.recvfrom(BUFSZ)
                peer[0] = src
                if len(d) < 10 or d[2] != 0: continue      # no fragmentation support
                a = d[3]
                if a == 1:   host = socket.inet_ntoa(d[4:8]);  off = 8
                elif a == 3: ln = d[4]; host = d[5:5+ln].decode(); off = 5+ln
                elif a == 4: host = socket.inet_ntop(socket.AF_INET6, d[4:20]); off = 20
                else: continue
                port = struct.unpack("!H", d[off:off+2])[0]
                try: host = socket.gethostbyname(host)
                except Exception: continue
                mux.sendall(pack_frame(host, port, d[off+2:]))
            except Exception: break
        stop.set()
    threading.Thread(target=up, daemon=True).start()

    try:                               # the control TCP connection holds the association open
        while not stop.is_set():
            if not c.recv(1): break
    except Exception:
        pass
    stop.set()
    for s in (u, mux, c):
        try: s.close()
        except Exception: pass

def pipe(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 300)
            if not r: break
            for s in r:
                d = s.recv(BUFSZ)
                if not d: return
                (b if s is a else a).sendall(d)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try: s.close()
            except Exception: pass

def handle(c):
    try:
        c.settimeout(60)
        ver, nm = struct.unpack("!BB", readn(c, 2))
        if ver != 5: return
        readn(c, nm); c.sendall(b"\x05\x00")
        ver, cmd, _, atyp = struct.unpack("!BBBB", readn(c, 4))
        if atyp == 1:   host = socket.inet_ntoa(readn(c, 4))
        elif atyp == 3: host = readn(c, readn(c, 1)[0]).decode()
        elif atyp == 4: host = socket.inet_ntop(socket.AF_INET6, readn(c, 16))
        else:
            c.sendall(b"\x05\x08\x00\x01" + b"\x00" * 6); return
        port = struct.unpack("!H", readn(c, 2))[0]
        if cmd == 3:                                  # UDP ASSOCIATE
            c.settimeout(None); udp_associate(c); return
        if cmd != 1:
            c.sendall(b"\x05\x07\x00\x01" + b"\x00" * 6); return
        try:
            r = socks_connect(host, port)
        except Exception:
            c.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6); return
        c.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
        c.settimeout(None); r.settimeout(None)
        pipe(c, r)
    except Exception:
        try: c.close()
        except Exception: pass

def main():
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN); srv.listen(128)
    print(f"gtlocal on {LISTEN[0]}:{LISTEN[1]} -> remote {REMOTE[0]}:{REMOTE[1]} pid={os.getpid()}", flush=True)
    while True:
        try:
            c, _ = srv.accept()
            threading.Thread(target=handle, args=(c,), daemon=True).start()
        except Exception as e:
            print("accept:", e, flush=True)

main()
