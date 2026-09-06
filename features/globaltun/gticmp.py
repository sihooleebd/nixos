#!/usr/bin/env python3
"""ICMP echo relay on its own tun device.

sing-box refuses to hand ICMP to any outbound ("icmp is not supported by default
outbound"), so ICMP gets its own tun and `ip rule ipproto icmp` steers only ICMP
here. Echo requests are framed over the existing ssh -L stream to the phone, which
re-emits them through an unprivileged ping socket.

Echo only: ping sockets cannot emit arbitrary ICMP types.
"""
import os, sys, socket, struct, threading, fcntl, subprocess, time

TUNSETIFF, IFF_TUN, IFF_NO_PI = 0x400454ca, 0x0001, 0x1000
TUN    = os.environ.get("GT_ICMP_TUN", "tun8")
TUNADDR= os.environ.get("GT_ICMP_ADDR", "172.19.1.1/30")
REMOTE = ("127.0.0.1", int(os.environ.get("GT_REMOTE_PORT", "11080")))
MAGIC  = "icmp.mux.arpa"
BUFSZ  = 65536
DEBUG  = os.environ.get("GT_DEBUG", "") not in ("", "0")

def dbg(*a):
    if DEBUG: print(*a, flush=True)

def csum(d):
    if len(d) % 2: d += b"\x00"
    s = sum(struct.unpack("!%dH" % (len(d)//2), d))
    while s >> 16: s = (s & 0xffff) + (s >> 16)
    return ~s & 0xffff

def ip_hdr(src, dst, plen, proto=1, ttl=64, ident=0):
    h = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20+plen, ident, 0, ttl, proto, 0, src, dst)
    return struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20+plen, ident, 0, ttl, proto, csum(h), src, dst)

def readn(s, n):
    b = b""
    while len(b) < n:
        d = s.recv(n-len(b))
        if not d: raise EOFError
        b += d
    return b

def pack_frame(host, port, payload):
    return b"\x01" + socket.inet_aton(host) + struct.pack("!HH", port, len(payload)) + payload

def read_frame(s):
    atyp = readn(s, 1)[0]
    if atyp == 1:   host = socket.inet_ntoa(readn(s, 4))
    elif atyp == 4: host = socket.inet_ntop(socket.AF_INET6, readn(s, 16))
    else: raise ValueError("bad atyp")
    port, ln = struct.unpack("!HH", readn(s, 4))
    return host, port, readn(s, ln)

def open_mux():
    r = socket.create_connection(REMOTE, 20)
    r.sendall(b"\x05\x01\x00")
    if readn(r, 2) != b"\x05\x00": raise OSError("no socks auth")
    hb = MAGIC.encode()
    r.sendall(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack("!H", 1))
    rep = readn(r, 4)
    if rep[1] != 0: raise OSError("socks reply %d" % rep[1])
    a = rep[3]
    readn(r, 4 if a == 1 else (16 if a == 4 else readn(r, 1)[0])); readn(r, 2)
    r.settimeout(None)
    return r

def open_tun():
    fd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(fd, TUNSETIFF, struct.pack("16sH", TUN.encode(), IFF_TUN | IFF_NO_PI))
    subprocess.run(["ip", "addr", "replace", TUNADDR, "dev", TUN], check=False)
    subprocess.run(["ip", "link", "set", TUN, "mtu", "1400", "up"], check=False)
    return fd

def main():
    fd = open_tun()
    print(f"gticmp: {TUN} {TUNADDR} pid={os.getpid()}", flush=True)
    pend = {}                      # (peer_ip, seq) -> (orig_src, orig_id) ; kernel rewrites id
    lock = threading.Lock()
    mux = [None]

    def connect():
        while True:
            try:
                mux[0] = open_mux(); print("gticmp: mux up", flush=True); return
            except Exception as e:
                print("gticmp: mux connect failed:", e, flush=True); time.sleep(3)
    connect()

    def down():                    # replies from the phone -> ICMP echo replies on the tun
        while True:
            try:
                peer, _p, msg = read_frame(mux[0])
            except Exception:
                print("gticmp: mux lost, reconnecting", flush=True)
                try: mux[0].close()
                except Exception: pass
                connect(); continue
            try:
                if len(msg) < 8:
                    dbg(f"  rx short {len(msg)}B from {peer}"); continue
                rtype = msg[0]
                rid, seq = struct.unpack("!HH", msg[4:8])
                if rtype != 0:
                    dbg(f"  rx type={rtype} from {peer} (not echo reply)"); continue
                with lock: ent = pend.pop((peer, seq), None)
                if not ent:
                    with lock: keys = list(pend.keys())[:4]
                    dbg(f"  rx UNMATCHED {peer} seq={seq} rid={rid}; pending={keys}"); continue
                orig_src, orig_id = ent
                body = b"\x00\x00" + b"\x00\x00" + struct.pack("!HH", orig_id, seq) + msg[8:]
                body = body[:2] + struct.pack("!H", csum(body)) + body[4:]
                pkt = ip_hdr(socket.inet_aton(peer), orig_src, len(body)) + body
                os.write(fd, pkt)
                dbg(f"  rx OK {peer} seq={seq} id={orig_id} -> {socket.inet_ntoa(orig_src)} ({len(pkt)}B)")
            except Exception:
                continue
    threading.Thread(target=down, daemon=True).start()

    while True:                    # echo requests off the tun -> frames to the phone
        try:
            pkt = os.read(fd, BUFSZ)
        except OSError:
            break
        try:
            if len(pkt) < 20 or (pkt[0] >> 4) != 4: continue
            ihl = (pkt[0] & 0xF) * 4
            if pkt[9] != 1:
                dbg(f"  tun saw non-icmp proto={pkt[9]}"); continue
            src, dst = pkt[12:16], pkt[16:20]
            msg = pkt[ihl:]
            if len(msg) < 8 or msg[0] != 8:
                dbg(f"  tun icmp type={msg[0] if msg else '?'} (not echo request)"); continue
            eid, seq = struct.unpack("!HH", msg[4:8])
            peer = socket.inet_ntoa(dst)
            with lock:
                pend[(peer, seq)] = (src, eid)
                if len(pend) > 4096: pend.clear()
            mux[0].sendall(pack_frame(peer, 0, msg))
            dbg(f"  tx {peer} id={eid} seq={seq} ({len(msg)}B icmp)")
        except Exception:
            continue

main()
