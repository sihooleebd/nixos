# end-to-end checks through the tun (no SOCKS, no resolv.conf): run with sshuttle OFF
import socket, struct, time, subprocess, sys
def dnsq(name):
    return struct.pack(">HHHHHH",0x1234,0x0100,1,0,0,0)+b"".join(bytes([len(p)])+p.encode() for p in name.split("."))+b"\0"+struct.pack(">HH",1,1)
def udp(host,port,payload,label,timeout=6):
    t=time.time(); s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(timeout)
    try:
        s.sendto(payload,(host,port)); d,_=s.recvfrom(1024)
        extra=""
        if port==53 and len(d)>=12: extra=f"answers={struct.unpack('>H',d[6:8])[0]}"
        print(f"  {label:<34} OK   {len(d)}B {extra} {time.time()-t:.2f}s")
        return True
    except Exception as e: print(f"  {label:<34} FAIL {type(e).__name__} {time.time()-t:.1f}s"); return False
    finally: s.close()
def curl(url,label,extra=()):
    t=time.time()
    r=subprocess.run(["curl","-s","-m","8",*extra,"-o","/dev/null","-w","%{http_code}",url],capture_output=True,text=True)
    reach=r.stdout[:1] in '2345'; print(f"  {label:<34} {'OK  ' if reach else 'FAIL'} http={r.stdout or '000'} {time.time()-t:.2f}s")
    return reach

print("[1] wait for remote to settle (TCP by IP via tun)")
for i in range(5):
    if curl("https://1.1.1.1/","  1.1.1.1:443"): break
    time.sleep(3)
print("[2] TCP by IP")
curl("https://8.8.8.8/","  8.8.8.8:443"); curl("http://23.192.228.84/","  akamai ip :80")
print("[3] DNS via tun hijack-dns  (UDP :53 -> local sing-box -> DoH over proxy)")
udp("8.8.8.8",53,dnsq("example.com"),"  udp 8.8.8.8:53 example.com")
udp("1.1.1.1",53,dnsq("www.google.com"),"  udp 1.1.1.1:53 www.google.com")
print("[4] REAL UDP end-to-end (not :53, so this is UoT -> remote sendto)")
udp("216.239.35.0",123,b"\x1b"+b"\0"*47,"  ntp time.google.com:123")
udp("162.159.200.1",123,b"\x1b"+b"\0"*47,"  ntp cloudflare:123")
print("[4b] ICMP echo through the tunnel (real ping, not locally faked)")
_self_ip=_sp.run(["tailscale","ip","-4"],capture_output=True,text=True).stdout.strip() if __import__("shutil").which("tailscale") else ""
import subprocess as _sp
for host in ("1.1.1.1","8.8.8.8"):
    r=_sp.run(["ping","-c","2","-W","5",host],capture_output=True,text=True)
    line=[l for l in r.stdout.splitlines() if "packet loss" in l]
    print(f"  ping {host:<12} {'OK  ' if r.returncode==0 else 'FAIL'} {line[0] if line else r.stdout.strip()[:60]}")
# A tailnet peer, to prove the tunnel did not swallow the tailscale carve-out.
# Discovered rather than hardcoded: the address is site-specific, and a wrong
# literal would report a failure that says nothing about the tunnel.
_ts=_sp.run(["tailscale","status","--peers=true"],capture_output=True,text=True)
_peer=next((l.split()[0] for l in _ts.stdout.splitlines()
            if l[:1].isdigit() and "offline" not in l and l.split()[0] != _self_ip), None)
if _peer:
    r=_sp.run(["ping","-c","2","-W","5",_peer],capture_output=True,text=True)
    print(f"  ping {_peer} (tailnet) {'OK  ' if r.returncode==0 else 'FAIL'} (must stay native, not tunnelled)")
else:
    print("  ping tailnet peer      SKIP (no online peer found)")
print("[5] name-based via system resolver (/etc/resolv.conf -> tailscale)")
curl("https://www.google.com/","  www.google.com")
curl("https://api.anthropic.com/","  api.anthropic.com")
print("[6] egress ip (no DNS)")
r=subprocess.run(["curl","-s","-m","8","https://1.1.1.1/cdn-cgi/trace"],capture_output=True,text=True)
print("  "+" ".join(l for l in r.stdout.split() if l.startswith(("ip=","loc=","colo="))) or "  FAIL")
print("[7] tailscale")
r=subprocess.run(["tailscale","status","--peers=false"],capture_output=True,text=True); print("  "+(r.stdout.strip().splitlines() or ["?"])[0])
r=subprocess.run(["tailscale","status","--json"],capture_output=True,text=True)
import json
try:
    j=json.loads(r.stdout); print("  BackendState:",j.get("BackendState"),"| Health:",j.get("Health") or "ok")
except Exception: pass
