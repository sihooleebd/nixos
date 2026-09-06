#!/usr/bin/env bash
# globaltun (DIRECT) - full tunnel (TCP/UDP/QUIC/ICMP) to an unprivileged
# Termux/proot phone acting as the internet gateway. See globaltun-findings.md.
#
# For a host that reaches the gateway WITHOUT a jump, i.e. one that holds the
# OpenVPN link into the gateway's network itself -- yulee. Every host on the LAN
# side of that link uses globaltun.sh instead.
#
# Differs from globaltun.sh in exactly two places, both below: no ProxyCommand in
# SSHOPTS, and CARRIER is the gateway rather than the jump host. Keep in sync.
#
#   up      : bring the whole tunnel up (idempotent)
#   down    : tear it down and restore normal routing
#   status  : show carrier, relays, tun devices, routes, egress IP
#   verify  : end-to-end checks (TCP / DNS / UDP / ICMP / tailscale)
#   reload  : restart only the local sing-box (keeps ssh master + phone relay)
#   reicmp  : restart only the ICMP relay and its policy routing
#   is-up   : exit 0 if the tunnel is carrying traffic (for automation)
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# A standalone bundle carries its configuration beside the script. The NixOS
# wrapper exports the same variables directly and ships no such file.
#
# NOT named "env": installed into a bin directory, $HERE/env resolves to
# coreutils' env BINARY, and sourcing that fails with "cannot execute binary
# file". The name has to be one nothing else in a PATH directory can claim.
[ -f "$HERE/globaltun.env" ] && . "$HERE/globaltun.env"

# Endpoints carry no defaults on purpose: a wrong-but-plausible gateway fails as
# a timeout deep in the connection, which reads as a network fault rather than a
# misconfiguration. `:?` makes an unset one fail immediately and by name.
RHOST=${GT_RHOST:?set GT_RHOST, e.g. root@gateway}
KEY=${GT_KEY:?set GT_KEY, path to the ssh private key}
RPORT=${GT_RPORT:-8022}

# DIFFERENCE 1/2: no jump host. The gateway is dialled directly, so the host
# whose route must not be swallowed by the tun is the gateway itself.
CARRIER=${RHOST##*@}

# Component paths. Set by the NixOS wrapper to store paths; fall back to files
# beside this script so a checkout still runs standalone.
: "${GT_RSOCKS:=$HERE/rsocks.py}"
: "${GT_GTLOCAL:=$HERE/gtlocal.py}"
: "${GT_GTICMP:=$HERE/gticmp.py}"
: "${GT_SBCONF:=$HERE/gt-client.json}"
: "${GT_SINGBOX:=$HERE/sing-box}"
: "${GT_VERIFY:=$HERE/verify.py}"
GT_ICMP=${GT_ICMP:-1}

LPORT=11080              # local end of ssh -L -> remote sing-box
RPORT_SS=${GT_REMOTE_SOCKS_PORT:-1080}   # relay port ON the gateway
# Distinct per client: two hosts tunnelling through the same gateway would
# otherwise share one relay and one pidfile, and whichever ran `up` second
# would kill the other's relay along with every connection on it.
TUN=tun9
CTL=/run/globaltun.ctl
PIDF=/run/globaltun-singbox.pid
GLPID=/run/globaltun-gtlocal.pid
GLLOG=/var/log/globaltun-gtlocal.log
LOCAL_PORT=1081
ICPID=/run/globaltun-gticmp.pid
ICLOG=/var/log/globaltun-gticmp.log
ICTUN=tun8
# Both tun subnets are overridable: 172.19/16 is a common Docker bridge range,
# and a host already using it would have the two fight over the same address.
IC_ADDR=${GT_ICMP_ADDR:-172.19.1.1/30}
TUNADDR_IP=${IC_ADDR%%/*}
IC_TABLE=101
TS_TABLE=102
TS_PRIO=5205
IC_PRIO=5240
LOG=/var/log/globaltun.log
STATE=/run/globaltun.state

SSHOPTS=(-i "$KEY" -p "$RPORT"
         -o StrictHostKeyChecking=accept-new
         -o ServerAliveInterval=30 -o ServerAliveCountMax=10
         -o ExitOnForwardFailure=yes
         -o ControlPersist=10m)

# DIFFERENCE 2/2: no ProxyCommand -- there is no hop to hand the key to.

gw(){  ip route show default | awk '{print $3; exit}'; }

# Keep the ssh carrier out of the tunnel it carries. Its correct path is
# whatever the kernel would choose right now, which is NOT always the default
# gateway: with no jump host the carrier reaches the gateway over an OpenVPN
# tun, and forcing it via the default gw would cut the connection the tunnel
# depends on. Must run BEFORE the 0.0.0.0/1 routes exist, or it reads them back.
# Freeze a destination onto the path the kernel would choose RIGHT NOW, so the
# tun cannot swallow it. Must run BEFORE the 0.0.0.0/1 routes exist, or it reads
# them back and pins the prefix to the tunnel it is meant to bypass.
pin_prefix(){
  local target=$1 label=$2 probe line via dev
  probe=${target%%/*}
  line=$(ip route get "$probe" 2>/dev/null | head -1)
  [ -n "$line" ] || { echo "cannot resolve a route to $label $target" >&2; return 1; }
  via=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
  dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$dev" ] || { echo "no device in route to $label $target" >&2; return 1; }
  if [ -n "$via" ]; then ip route replace "$target" via "$via" dev "$dev"
  else                   ip route replace "$target" dev "$dev"; fi
  echo "$label $target pinned ${via:+via $via }dev $dev"
}

# Tailscale marks its own WireGuard traffic 0x80000 and rule 5210 sends it to
# `main`, where our 0.0.0.0/1 now beats the default -- so the underlay goes
# through the tunnel, STUN reports the gateway's public address, peers cannot
# reach it, and even two machines on one LAN end up relaying via DERP.
#
# A rule ABOVE 5210 puts that traffic back on the physical link. The cost is
# that tailscale then needs the physical uplink: during an outage only LAN
# peers stay reachable, where riding the tun would have kept the whole tailnet
# (slowly). Which is right depends on the host, hence the switch.
tailscale_bypass(){
  [ "${GT_TAILSCALE_DIRECT:-0}" = 1 ] || return 0
  local g d
  g=$(gw); d=$(dev)
  [ -n "$g" ] && [ -n "$d" ] || { echo "no default route; skipping tailscale bypass" >&2; return 0; }
  ip route replace default via "$g" dev "$d" table $TS_TABLE
  ip rule del priority $TS_PRIO 2>/dev/null || true
  ip rule add fwmark 0x80000/0xff0000 lookup $TS_TABLE priority $TS_PRIO
  echo "tailscale underlay kept on $d (table $TS_TABLE, prio $TS_PRIO)"
}

pin_carrier(){
  pin_prefix "$CARRIER/32" carrier || return 1
  # On a headless box the session bringing this up arrives over some network;
  # if its return path is swallowed by the tun the connection dies mid-command
  # and nothing is left to run `down`. GT_KEEP_DIRECT lists prefixes to leave on
  # their existing path -- management networks, in practice.
  local p
  for p in ${GT_KEEP_DIRECT:-}; do pin_prefix "$p" keep-direct || true; done
}
dev(){ ip route show default | awk '{print $5; exit}'; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }; }
have_ctl(){ [ -S "$CTL" ] && ssh -S "$CTL" -O check "$RHOST" >/dev/null 2>&1; }

master(){   # key auth on both hops; no password prompts
  have_ctl && return 0
  rm -f "$CTL"
  ss -ltn 2>/dev/null | grep -q ":$LPORT " && { echo "port $LPORT already in use -- run 'down' first" >&2; exit 1; }
  local n t err delay
  n=0
  err=$(mktemp)
  for t in ${GT_TIMEOUTS:-300 600 900}; do
    n=$((n+1))
    echo "master attempt $n (ConnectTimeout=${t}s; proot login is slow)..." >&2
    # -f backgrounds after auth and takes stderr with it, so the real reason --
    # e.g. "connect failed: No route to host" from the jump host when its VPN to
    # the gateway is re-establishing -- never reaches the terminal. Capture it,
    # otherwise every distinct fault looks like "Connection closed".
    if env ALL_PROXY= ssh -M -S "$CTL" -f -N -o ConnectTimeout="$t" \
         -L "127.0.0.1:$LPORT:127.0.0.1:$RPORT_SS" "${SSHOPTS[@]}" "$RHOST" 2>"$err"; then
      have_ctl && { [ $n -gt 1 ] && echo "(master established on attempt $n)"; rm -f "$err"; return 0; }
    fi
    echo "master attempt $n failed: $(tr '\n' ' ' <"$err" | sed 's/  */ /g;s/ $//')" >&2
    rm -f "$CTL"
    # Backoff long enough to outlast a VPN re-establishment on the path. Three
    # attempts three seconds apart all land inside the same outage and prove
    # nothing; the whole point of retrying is to sample a different moment.
    delay=$(( n * ${GT_RETRY_DELAY:-20} ))
    [ $n -lt 3 ] && { echo "  retrying in ${delay}s" >&2; sleep "$delay"; }
  done
  rm -f "$err"
  echo "could not establish ssh master to $RHOST${JUMP:+ via $JUMP}. Reading the error above:" >&2
  echo "  'No route to host'   -> the hop BEFORE the gateway lost its path to it" >&2
  echo "  'Connection refused' -> the gateway is up but sshd is not listening" >&2
  echo "  'Connection closed'  -> the far end hung up; check it is not rate-limiting" >&2
  echo "  'timed out'          -> reachable but not answering; usually the gateway itself" >&2
  echo "Reproduce interactively with:" >&2
  echo "  ssh -v ${SSHOPTS[*]} $RHOST true" >&2
  exit 1
}



start_gtlocal(){
  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null || true; rm -f "$GLPID"; }
  pkill -f 'python3 -u .*gtlocal.py' 2>/dev/null || true
  sleep 0.3
  setsid python3 -u "$GT_GTLOCAL" >"$GLLOG" 2>&1 </dev/null &
  echo $! > "$GLPID"
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$LOCAL_PORT " \
    && echo "gtlocal up: $(head -1 "$GLLOG")" \
    || { echo "gtlocal FAILED:"; cat "$GLLOG"; exit 1; }
}

start_gticmp(){
  [ -f "$ICPID" ] && { kill "$(cat "$ICPID")" 2>/dev/null || true; rm -f "$ICPID"; }
  pkill -f 'python3 -u .*gticmp.py' 2>/dev/null || true
  sleep 0.3; ip link del "$ICTUN" 2>/dev/null || true
  GT_ICMP_ADDR="$IC_ADDR" setsid python3 -u "$GT_GTICMP" >"$ICLOG" 2>&1 </dev/null &
  echo $! > "$ICPID"
  for _ in $(seq 50); do ip link show "$ICTUN" >/dev/null 2>&1 && break; sleep 0.1; done
  ip link show "$ICTUN" >/dev/null 2>&1 || { echo "gticmp FAILED:"; cat "$ICLOG"; return 1; }

  # steer ONLY icmp at tun8, with carve-outs so tailnet + LAN pings stay native
  local d lan
  d=$(dev)
  [ -n "$d" ] || { echo "  no default interface; skipping icmp carve-outs" >&2; d=""; }
  lan=""
  [ -n "$d" ] && lan=$(ip -o -4 route show dev "$d" scope link | awk '{print $1; exit}')
  ip route replace 100.64.0.0/10 dev tailscale0 table $IC_TABLE 2>/dev/null || true
  [ -n "$lan" ] && [ -n "$d" ] && ip route replace "$lan" dev "$d" table $IC_TABLE
  ip route replace default dev "$ICTUN" table $IC_TABLE
  ip rule del priority $IC_PRIO 2>/dev/null || true
  ip rule add ipproto icmp lookup $IC_TABLE priority $IC_PRIO

  # Reverse-path validation of an injected reply looks up the route to the reply's
  # SOURCE with no protocol set, so the `ipproto icmp` rule above cannot match it;
  # it falls through to main, finds tun9, and drops the packet. That lookup carries
  # our tun's address as its source, so key a rule on it: it matches those
  # validation lookups and nothing else, and resolves them to $ICTUN.
  ip rule del priority $((IC_PRIO - 1)) 2>/dev/null || true
  ip rule add from ${TUNADDR_IP} lookup $IC_TABLE priority $((IC_PRIO - 1))

  # Injected echo replies arrive on $ICTUN sourced from the pinged host, whose
  # route is tun9 -- strict reverse-path filtering drops them before ping sees
  # them. Exempt this one interface (raw skips rpfilter, INPUT covers a default
  # DROP policy). Scoped to $ICTUN so the rest of the firewall is untouched.
  echo 0 > /proc/sys/net/ipv4/conf/$ICTUN/rp_filter 2>/dev/null || true
  echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
  echo 1 > /proc/sys/net/ipv4/conf/$ICTUN/accept_local 2>/dev/null || true
  echo 0 > /proc/sys/net/ipv4/conf/$ICTUN/log_martians 2>/dev/null || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -t raw -C PREROUTING -i "$ICTUN" -j ACCEPT 2>/dev/null || \
      iptables -t raw -I PREROUTING 1 -i "$ICTUN" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -i "$ICTUN" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -i "$ICTUN" -j ACCEPT 2>/dev/null || true
  fi
  if command -v nft >/dev/null 2>&1 && nft list table inet nixos-fw >/dev/null 2>&1; then
    nft add table inet globaltun 2>/dev/null || true
    nft 'add chain inet globaltun pre { type filter hook prerouting priority -310 ; }' 2>/dev/null || true
    nft 'add chain inet globaltun inp { type filter hook input priority -10 ; }' 2>/dev/null || true
    nft flush chain inet globaltun pre 2>/dev/null || true
    nft flush chain inet globaltun inp 2>/dev/null || true
    nft add rule inet globaltun pre iifname "'"$ICTUN"'" accept 2>/dev/null || true
    nft add rule inet globaltun inp iifname "'"$ICTUN"'" accept 2>/dev/null || true
  fi
  echo "gticmp up: $(head -1 "$ICLOG"); icmp -> $ICTUN (table $IC_TABLE, lan=$lan direct)"
}

up(){
  need_root
  SB="$GT_SINGBOX"
  [ -x "$SB" ] || { echo "missing $SB" >&2; exit 1; }

  master
  echo "--- starting remote relay (python socks5)"
  ssh -S "$CTL" "$RHOST" "cat > /tmp/rsocks-$RPORT_SS.py" < "$GT_RSOCKS"
  # Double-quoted so $RPORT_SS expands HERE; \$ escapes what must expand on the
  # gateway. Single quotes would send the port through literally, and the relay
  # would silently start on its default while the -L forward pointed elsewhere.
  ssh -S "$CTL" "$RHOST" "
    P=/tmp/globaltun-server-$RPORT_SS.pid
    [ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P
    # Migration: relays predating per-client ports used unsuffixed names and are
    # invisible to the pidfile above, so they survive and hold the port, making
    # the new relay fail to bind. Only the legacy names -- never another
    # client's suffixed relay.
    L=/tmp/globaltun-server.pid
    [ -f \$L ] && kill \$(cat \$L) 2>/dev/null; rm -f \$L /tmp/rsocks.py /tmp/globaltun-server.log
    : > /tmp/globaltun-server-$RPORT_SS.log
    RSOCKS_PORT=$RPORT_SS setsid python3 -u /tmp/rsocks-$RPORT_SS.py >/tmp/globaltun-server-$RPORT_SS.log 2>&1 </dev/null &
    echo \$! > \$P
    sleep 2
    if (exec 3<>/dev/tcp/127.0.0.1/$RPORT_SS) 2>/dev/null; then
      echo \"remote relay up: \$(head -1 /tmp/globaltun-server-$RPORT_SS.log)\"
    else
      echo 'remote relay FAILED:'; cat /tmp/globaltun-server-$RPORT_SS.log; exit 1
    fi
  "

  echo "--- starting local udp/tcp adapter"
  start_gtlocal

  echo "--- clearing any previous local sing-box / tun"
  [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; }
  pkill -f 'sing-box.orig run -c .*gt-client' 2>/dev/null || true
  for _ in $(seq 30); do ip link show "$TUN" >/dev/null 2>&1 || break; sleep 0.1; done
  ip link del "$TUN" 2>/dev/null || true

  echo "--- starting local sing-box (tun)"
  setsid "$SB" run -c "$GT_SBCONF" >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDF"
  sleep 2
  kill -0 "$(cat "$PIDF")" 2>/dev/null || { echo "local sing-box died:"; tail -30 "$LOG"; exit 1; }
  for _ in $(seq 50); do ip link show "$TUN" >/dev/null 2>&1 && break; sleep 0.1; done
  ip link show "$TUN" >/dev/null 2>&1 || { echo "$TUN never appeared:"; tail -30 "$LOG"; exit 1; }

  echo "--- routing (main table, so tailscale's fwmark rule 5210 lands in the tun too)"
  pin_carrier
  ip route replace 0.0.0.0/1   dev "$TUN"
  ip route replace 128.0.0.0/1 dev "$TUN"
  tailscale_bypass
  if [ "$GT_ICMP" = 1 ]; then
    echo "--- starting icmp relay"
    start_gticmp || echo "(icmp relay unavailable -- tcp/udp unaffected)"
  fi
  echo "up -- TCP + UDP (udp-over-tcp); tailscale underlay rides the tun, peers stay on tailscale0"
}

down(){
  need_root
  [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; }
  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null || true; rm -f "$GLPID"; }
  pkill -f 'python3 -u .*gtlocal.py' 2>/dev/null || true
  [ -f "$ICPID" ] && { kill "$(cat "$ICPID")" 2>/dev/null || true; rm -f "$ICPID"; }
  pkill -f 'python3 -u .*gticmp.py' 2>/dev/null || true
  ip rule del priority $IC_PRIO 2>/dev/null || true
  ip rule del priority $((IC_PRIO - 1)) 2>/dev/null || true
  ip rule del priority $TS_PRIO 2>/dev/null || true
  ip route flush table $TS_TABLE 2>/dev/null || true
  ip route flush table $IC_TABLE 2>/dev/null || true
  iptables -t raw -D PREROUTING -i "$ICTUN" -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -i "$ICTUN" -j ACCEPT 2>/dev/null || true
  nft delete table inet globaltun 2>/dev/null || true
  ip link del "$ICTUN" 2>/dev/null || true
  sleep 1
  have_ctl && ssh -S "$CTL" "$RHOST" "P=/tmp/globaltun-server-$RPORT_SS.pid; [ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P; true" || true
  [ -S "$CTL" ] && { ssh -S "$CTL" -O exit "$RHOST" 2>/dev/null || true; }
  rm -f "$CTL"
  ip route del 0.0.0.0/1   2>/dev/null || true
  ip route del 128.0.0.0/1 2>/dev/null || true
  ip route del "$CARRIER/32" 2>/dev/null || true
  for p in ${GT_KEEP_DIRECT:-}; do ip route del "$p" 2>/dev/null || true; done
  ip link del "$TUN" 2>/dev/null || true
  rm -f "$STATE"
  echo "down"
}

reload_local(){   # restart only the local sing-box; keeps the ssh master + remote side
  need_root
  have_ctl || { echo "refusing: no live ssh master. Installing tun routes now would black-hole this box -- run 'up' instead." >&2; exit 1; }
  ss -ltn 2>/dev/null | grep -q ":$LPORT " || { echo "refusing: no :$LPORT forward -- run 'up' instead." >&2; exit 1; }
  SB="$GT_SINGBOX"
  start_gtlocal
  [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; }
  for _ in $(seq 30); do ip link show "$TUN" >/dev/null 2>&1 || break; sleep 0.1; done
  setsid "$SB" run -c "$GT_SBCONF" >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDF"
  for _ in $(seq 50); do ip link show "$TUN" >/dev/null 2>&1 && break; sleep 0.1; done
  ip link show "$TUN" >/dev/null 2>&1 || { echo "$TUN never came back:"; tail -20 "$LOG"; exit 1; }
  pin_carrier || true
  ip route replace 0.0.0.0/1   dev "$TUN"
  ip route replace 128.0.0.0/1 dev "$TUN"
  echo "local sing-box reloaded"
}






verify(){
  if ss -ltn 2>/dev/null | grep -q '127.0.0.1:12300 '; then echo "!! sshuttle still listening on :12300 -- stop it first"; exit 1; fi
  echo "=== verify $(date +%T) ==="
  python3 "$GT_VERIFY"
  echo "=== local log (last errors, icmp noise filtered)"
  grep -v 'icmp is not supported' "$LOG" 2>/dev/null | grep -E 'ERROR|FATAL|outbound|proxy' | tail -10
  echo "=== remote log tail"; have_ctl && ssh -S "$CTL" "$RHOST" "tail -n 8 /tmp/globaltun-server-$RPORT_SS.log" || echo "(no master)"
}

# Quiet predicate for automation: 0 = carrying traffic, 1 = not.
is_up(){ have_ctl && ip link show "$TUN" >/dev/null 2>&1; }

status(){
  echo "--- ssh master"; have_ctl && echo "connected" || echo "no control socket"
  echo "--- forward";    ss -ltn 2>/dev/null | grep ":$LPORT" || echo "no :$LPORT listener"
  echo "--- gticmp";     ip -br addr show "$ICTUN" 2>/dev/null || echo "  no $ICTUN"
  echo "--- icmp rule";  ip rule show | grep -E "$IC_PRIO" || echo "  no icmp rule"
  echo "--- gtlocal";     ss -ltn 2>/dev/null | grep ":$LOCAL_PORT " || echo "  not listening"
  echo "--- local sing-box"; [ -f "$PIDF" ] && ps -o pid,etime,cmd -p "$(cat "$PIDF")" 2>/dev/null || echo "not running"
  echo "--- tun";        ip -br addr show "$TUN" 2>/dev/null || echo "no $TUN"
  echo "--- routes";     ip route show | grep -E '^(0\.0\.0\.0/1|128\.0\.0\.0/1|default|'"$CARRIER"')' || true
  echo "--- tailscale";  tailscale status --peers=false 2>&1 | grep -E 'Health|DNS|^[0-9]' | head -3
  echo "--- egress v4";  curl -s --max-time 10 https://ifconfig.me 2>&1; echo
  echo "--- udp test";   command -v dig >/dev/null && dig +short +time=5 @8.8.8.8 example.com 2>&1 || echo "(no dig)"
  echo "--- log tail";   tail -5 "$LOG" 2>/dev/null
}

case "${1:-}" in
  up)      up ;;
  down)    down ;;
  status)  status ;;
  verify)  verify ;;
  reload)  reload_local ;;
  reicmp)  need_root; start_gticmp ;;
  is-up)   need_root; is_up ;;
  *) echo "usage: $0 {up|down|status|verify|reload|reicmp|is-up}" >&2; exit 2 ;;
esac
