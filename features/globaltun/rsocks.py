#!/usr/bin/env python3
"""SOCKS5 relay for a netlink-less Android/proot box.
CONNECT for TCP, plus a datagram-mux mode for UDP tunnelled over one TCP stream.
Nothing here enumerates interfaces (Android blocks netlink for apps)."""
import os, socket, struct, threading, select, signal, sys

LISTEN   = ("127.0.0.1", int(os.environ.get("RSOCKS_PORT", "1080")))
MUX_HOST  = "udp.mux.arpa"     # magic CONNECT target -> UDP datagram mux
ICMP_HOST = "icmp.mux.arpa"    # magic CONNECT target -> ICMP echo mux
MUX_PORT  = 1
BUFSZ    = 65536

def readn(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n - len(b))
        if not d: raise EOFError
        b += d
    return b

def pack_frame(host, port, payload):
    ip = socket.inet_aton(host)
    return b"\x01" + ip + struct.pack("!HH", port, len(payload)) + payload

def read_frame(s):
    atyp = readn(s, 1)[0]
    if atyp == 1:   host = socket.inet_ntoa(readn(s, 4))
    elif atyp == 4: host = socket.inet_ntop(socket.AF_INET6, readn(s, 16))
    else: raise ValueError("bad atyp %d" % atyp)
    port, ln = struct.unpack("!HH", readn(s, 4))
    return host, port, readn(s, ln)

def udp_mux(c):
    """One TCP stream <-> one unconnected UDP socket doing real sendto/recvfrom."""
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(None)
    stop = threading.Event()
    def up():                      # UDP replies -> TCP frames
        while not stop.is_set():
            try:
                d, (h, p) = u.recvfrom(BUFSZ)
                c.sendall(pack_frame(h, p, d))
            except OSError: break
            except Exception: break
        stop.set()
        try: c.shutdown(socket.SHUT_RDWR)
        except Exception: pass
    t = threading.Thread(target=up, daemon=True); t.start()
    try:
        c.settimeout(None)
        while True:                # TCP frames -> real UDP sendto
            h, p, data = read_frame(c)
            try: u.sendto(data, (h, p))
            except Exception: pass
    except Exception:
        pass
    finally:
        stop.set()
        for s in (u, c):
            try: s.close()
            except Exception: pass

def icmp_mux(c):
    """ICMP echo over an unprivileged ping socket. Android leaves ping_group_range
    open, so no CAP_NET_RAW is needed. Kernel rewrites the echo id; seq survives,
    which is what the local side keys replies on."""
    try:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP)
    except Exception as e:
        print("icmp socket failed:", e, flush=True)
        try: c.close()
        except Exception: pass
        return
    stop = threading.Event()
    def up():
        while not stop.is_set():
            try:
                d, (h, _p) = u.recvfrom(BUFSZ)
                c.sendall(pack_frame(h, 0, d))
            except Exception: break
        stop.set()
        try: c.shutdown(socket.SHUT_RDWR)
        except Exception: pass
    threading.Thread(target=up, daemon=True).start()
    try:
        c.settimeout(None)
        while True:
            h, _p, data = read_frame(c)
            try: u.sendto(data, (h, 0))
            except Exception: pass
    except Exception:
        pass
    finally:
        stop.set()
        for s_ in (u, c):
            try: s_.close()
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
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass

def handle(c):
    try:
        c.settimeout(30)
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
        if cmd != 1:
            c.sendall(b"\x05\x07\x00\x01" + b"\x00" * 6); return
        if host == MUX_HOST and port == MUX_PORT:      # UDP tunnel
            c.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
            udp_mux(c); return
        if host == ICMP_HOST and port == MUX_PORT:    # ICMP echo tunnel
            c.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
            icmp_mux(c); return
        try:
            r = socket.create_connection((host, port), 15)
        except Exception:
            c.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6); return
        c.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
        c.settimeout(None); r.settimeout(None)
        for s in (c, r):
            try: s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except Exception: pass
        pipe(c, r)
    except Exception:
        try: c.close()
        except Exception: pass

def main():
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN); srv.listen(128)
    print(f"rsocks listening on {LISTEN[0]}:{LISTEN[1]} pid={os.getpid()} (tcp+udp+icmp)", flush=True)
    while True:
        try:
            c, _ = srv.accept()
            threading.Thread(target=handle, args=(c,), daemon=True).start()
        except Exception as e:
            print("accept:", e, flush=True)

main()
