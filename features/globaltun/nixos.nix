/*
  Full tunnel (TCP/UDP/QUIC/ICMP) out through an UNPRIVILEGED phone acting as the
  gateway, over an existing SSH path. On-demand, never auto-started:
  `sudo globaltun up` / `sudo globaltun down`.

    laptop --LAN--> jump host --OpenVPN--> phone (home wifi) --home ISP--> internet

  Why this shape rather than a VPN. The far end is Termux + proot-distro, where
  PRoot fakes uid 0 via ptrace but the kernel still sees an unprivileged uid: no
  CAP_NET_ADMIN, no CAP_NET_RAW, no tun device, and `ssh -w` is therefore
  impossible. The phone can only terminate and re-originate SOCKETS, never
  forward packets. Everything below follows from that one constraint.

  `ssh -L` carries TCP only and sshd will never sendto() on your behalf, so UDP
  and ICMP are multiplexed over TCP streams and re-emitted as real datagrams by
  a small Python relay on the phone (`rsocks.py`), which is the only thing that
  runs there:

    SOCKS5 CONNECT                -> connect()                     [TCP]
    CONNECT udp.mux.arpa:1        -> sendto/recvfrom               [UDP, QUIC]
    CONNECT icmp.mux.arpa:1       -> unprivileged ping socket      [ICMP echo]

  Native SCTP and DCCP cannot work: Android's kernel has neither, and proot
  cannot load modules. Nor can anything needing raw IP (GRE, ESP/AH). WebRTC is
  fine -- its SCTP rides inside DTLS over UDP.

  sing-box is used LOCALLY only. It wedges on the phone ("initialize interface
  monitor take too much time"), staying alive with an empty log while refusing
  every connection, because Android blocks netlink enumeration for apps.

  Full write-up, including the two traps that cost the most time, lives in
  globaltun-findings.md at the repo root (gitignored).
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.globaltun;

  /*
    Generated rather than shipped as a static file so the resolver cannot drift
    from the option, and so the ports stay in one place.

    "stack" MUST be gvisor. With auto_route off, the "system" stack silently
    drops TCP while UDP and ICMP still arrive -- the tun looks alive, packets
    demonstrably reach sing-box, and the log stays empty. The system stack needs
    the redirect rules auto_route installs; gvisor is self-contained.

    auto_route stays off deliberately: its ip rules sit near priority 9000 and
    lose to tailscale's 5210/5270, which breaks the tailnet. The wrapper script
    installs routes in `main` instead, so tailscale's fwmark rule 5210 lands its
    underlay in the tun and tailscale keeps working over DERP.

    DNS is DNS-over-HTTPS so name resolution never depends on the UDP path.
  */
  clientConfig = pkgs.writeText "globaltun-client.json" (builtins.toJSON {
    log = { level = "info"; timestamp = true; };
    dns = {
      servers = [ { type = "https"; tag = "remote-dns"; server = cfg.dns; detour = "proxy"; } ];
      final = "remote-dns";
      strategy = "ipv4_only";
    };
    inbounds = [{
      type = "tun";
      tag = "tun-in";
      interface_name = "tun9";
      address = [ "172.19.0.1/30" ];
      mtu = 1400;
      auto_route = false;
      stack = "gvisor";
    }];
    outbounds = [
      { type = "socks"; tag = "proxy"; server = "127.0.0.1"; server_port = 1081; version = "5"; }
      { type = "direct"; tag = "direct"; }
    ];
    route = {
      rules = [
        { action = "sniff"; }
        { protocol = "dns"; action = "hijack-dns"; }
        { ip_is_private = true; outbound = "direct"; }
        { ip_cidr = [ "100.64.0.0/10" ]; outbound = "direct"; }
      ];
      final = "proxy";
      auto_detect_interface = true;
    };
  });

  /*
    PATH is pinned rather than inherited: this runs under sudo, and a root PATH
    missing iproute2 or iptables would fail halfway through bringing the tunnel
    up -- with routes already installed and no proxy behind them, which is the
    one failure mode that takes the machine offline.
  */
  runtimeDeps = with pkgs; [
    openssh iproute2 iptables nftables python3 sing-box
    coreutils gnugrep gnused gawk procps iputils curl
  ];

  globaltun = pkgs.writeShellScriptBin "globaltun" ''
    export PATH=${lib.makeBinPath runtimeDeps}:$PATH
    export GT_JUMP=${lib.escapeShellArg cfg.jump}
    export GT_RHOST=${lib.escapeShellArg cfg.remote}
    export GT_RPORT=${toString cfg.remotePort}
    export GT_JUMP_TIMEOUT=${toString cfg.jumpConnectTimeout}
    export GT_REMOTE_SOCKS_PORT=${toString cfg.remoteSocksPort}
    export GT_KEEP_DIRECT=${lib.escapeShellArg (lib.concatStringsSep " " cfg.keepDirect)}
    export GT_KEY=${lib.escapeShellArg cfg.sshKey}
    export GT_ICMP=${if cfg.icmp.enable then "1" else "0"}
    export GT_RSOCKS=${./rsocks.py}
    export GT_GTLOCAL=${./gtlocal.py}
    export GT_GTICMP=${./gticmp.py}
    export GT_VERIFY=${./verify.py}
    export GT_SBCONF=${clientConfig}
    export GT_SINGBOX=${pkgs.sing-box}/bin/sing-box
    ${builtins.readFile ./globaltun.sh}
  '';
  /*
    Decides, on every network event and on a timer, whether the tunnel should be
    carrying traffic. Kept OUT of globaltun.sh: that script is a manual tool and
    stays usable on a machine with no NetworkManager.

    The probe is the whole difficulty. Once the tunnel is up, any ordinary
    connectivity check succeeds THROUGH it and would immediately tear it back
    down, so the probe is bound to the physical device with SO_BINDTODEVICE
    (`curl --interface`, which needs root to bind by device rather than by
    address) and therefore ignores the routing table entirely.

    Hysteresis is asymmetric on purpose. Bringing the tunnel up hijacks the
    default route onto a path that is TCP-over-TCP through a ptraced proot, so
    a transient blip must not flap traffic onto it: that demands
    ${toString cfg.auto.failures} consecutive failures. Tearing it down only
    restores normal routing, so one success is enough.
  */
  autoScript = pkgs.writeShellScriptBin "globaltun-auto" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath (runtimeDeps ++ [ globaltun pkgs.networkmanager pkgs.util-linux ])}:$PATH

    # NM dispatcher and the timer can fire together; serialise them.
    exec 9>/run/globaltun-auto.lock
    flock -n 9 || exit 0

    want=(${lib.escapeShellArgs cfg.auto.ssids})
    # tab-separated: SSIDs may contain spaces, which would split the read
    IFS=$'\t' read -r ssid dev < <(nmcli -t -f ACTIVE,SSID,DEVICE dev wifi 2>/dev/null \
                                    | awk -F: '$1=="yes"{print $2"\t"$3; exit}')
    [ -n "''${dev:-}" ] || { logger -t globaltun-auto "no active wifi; leaving tunnel alone"; exit 0; }

    match=0
    for w in "''${want[@]}"; do [ "$ssid" = "$w" ] && match=1; done

    if [ "$match" = 0 ]; then
      if globaltun is-up; then
        logger -t globaltun-auto "ssid $ssid is not managed; tearing down"
        globaltun down
      fi
      exit 0
    fi

    probe(){ curl -sf --interface "$dev" -m ${toString cfg.auto.probeTimeout} \
               -o /dev/null ${lib.escapeShellArg cfg.auto.probeUrl}; }

    if probe; then
      if globaltun is-up; then
        logger -t globaltun-auto "$ssid uplink recovered; tearing down"
        globaltun down
      fi
      exit 0
    fi

    globaltun is-up && exit 0

    n=1
    while [ "$n" -lt ${toString cfg.auto.failures} ]; do
      sleep 3
      probe && { logger -t globaltun-auto "$ssid uplink came back; not starting"; exit 0; }
      n=$((n + 1))
    done

    logger -t globaltun-auto "$ssid has no uplink after $n probes; bringing tunnel up"
    # Short budget: the timer retries, so a dead jump host must not hold the
    # lock for the 30 minutes the manual escalation would allow.
    GT_TIMEOUTS=${lib.escapeShellArg cfg.auto.connectTimeouts} globaltun up \
      || logger -t globaltun-auto "bring-up FAILED; will retry on next tick"
  '';
in
{
  options.my.globaltun = {
    enable = lib.mkEnableOption ''
      an on-demand full tunnel through a phone gateway, reached via an SSH jump
      host. Defines the `globaltun` command; starts nothing. Bring it up with
      `sudo globaltun up` and check it with `sudo globaltun verify`
    '';

    jump = lib.mkOption {
      type = lib.types.str;
      example = "user@192.0.2.1";
      description = ''
        SSH jump host, `user@host`, reachable from this machine and itself able
        to reach `remote`.

        Required, with no default: every host in this flake sits on the LAN side
        of the VPN link into the gateway's network and cannot reach the gateway
        itself. A machine that DOES hold that link needs no jump and uses
        globaltun-direct.sh instead -- it is not a NixOS host, so that case is
        deliberately absent from this module rather than modelled as an option.
      '';
    };

    jumpConnectTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        ConnectTimeout for the jump hop, in seconds. Ignored when `jump` is
        empty.

        Separate from the gateway's own budget (GT_TIMEOUTS, 300/600/900)
        because the two fail differently: the gateway is slow because every
        syscall there is ptraced by proot, whereas a slow jump host means a
        loaded or marginally-reachable machine, which is worth waiting out
        rather than failing fast and retrying the whole chain.
      '';
    };

    remote = lib.mkOption {
      type = lib.types.str;
      example = "root@192.0.2.50";
      description = "The phone gateway, `user@host`, as reached FROM the jump host.";
    };

    remotePort = lib.mkOption {
      type = lib.types.port;
      default = 8022;
      description = "sshd port on the gateway. 8022 is the Termux default.";
    };

    sshKey = lib.mkOption {
      type = lib.types.str;
      example = "/run/agenix/globaltun-key";
      description = ''
        Private key authenticating to BOTH hops, read at runtime from outside
        the store.

        It is passed to the jump hop with an explicit ProxyCommand rather than
        `-J`, because ssh(1) applies command-line options to the DESTINATION
        only: under `-J` the jump silently falls back to password auth on every
        connection. Each prompt then holds an unauthenticated slot on the jump
        host's sshd for the whole LoginGraceTime, and enough of them at once
        crosses the default MaxStartups, at which point that host starts
        dropping NEW connections from this machine entirely -- which looks like
        a network outage and heals by itself, so it is easy to misdiagnose.

        A STRING, not a path literal -- `./key` would be copied into the
        world-readable Nix store. The type forbids expressing that at all.
      '';
    };

    remoteSocksPort = lib.mkOption {
      type = lib.types.port;
      example = 1080;
      description = ''
        Port the relay listens on ON THE GATEWAY, and the suffix of its pidfile
        and log there.

        Deliberately has NO default. It must differ per client: several machines
        tunnelling through one gateway would otherwise share a single relay and
        pidfile, and whichever ran `up` last would kill the others' relay along
        with every connection on it -- silently, since nothing on either side
        reports it.

        A default would make that the failure mode of simply enabling the
        feature on a new host. This module cannot assert against a collision
        because it sees only its own host's config, so the check has to be a
        human one, and a required option is what forces it.

        Assigned so far: 1080 galaxybook4-pro360, 1081 yulee (standalone
        bundle), 1082 victus-15.
      '';
    };

    keepDirect = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "192.0.2.0/24" ];
      description = ''
        Prefixes frozen onto the path they already use, instead of being
        swallowed by the tunnel.

        Two things belong here. On a headless machine, the network the admin
        session arrives over -- otherwise `up` cuts the connection mid-command
        and nothing is left running to undo it. And the underlay of any VPN the
        carrier depends on: routing that into the tunnel it carries survives
        only until the next rekey, and then cannot re-establish.
      '';
    };

    dns = lib.mkOption {
      type = lib.types.str;
      default = "1.1.1.1";
      description = "Upstream resolver, queried over DNS-over-HTTPS through the tunnel.";
    };

    auto = {
      enable = lib.mkEnableOption ''
        bringing the tunnel up automatically when a managed SSID has no uplink
        of its own, and tearing it down again when the uplink returns.

        Off by default because it hijacks the default route on a heuristic,
        onto a path several times slower than any working uplink. With it on, a
        manual
        `globaltun down` is undone by the next tick if the conditions still
        hold -- pin it off with `systemctl stop globaltun-auto.timer`
      '';

      ssids = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "KSA" ];
        description = ''
          Wi-Fi networks this applies to. Everywhere else the tunnel is left
          alone, and an already-running tunnel is torn down on arrival.

          A list rather than "any network without an uplink": a captive portal
          reads as no-uplink, and silently tunnelling out of an unknown network
          is a worse failure than staying offline.
        '';
      };

      probeUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://1.1.1.1/";
        description = ''
          Reachability probe for the PHYSICAL uplink. Requested with
          `curl --interface <dev>`, which as root binds by device
          (SO_BINDTODEVICE) and so bypasses the routing table -- without that
          the probe would succeed through the tunnel and tear it straight down.

          An IP literal, not a name: the interesting case is a network where
          DNS itself does not work.
        '';
      };

      probeTimeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
        description = "Seconds allowed per probe.";
      };

      failures = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = ''
          Consecutive failed probes before the tunnel is brought up. Teardown
          needs only one success: starting moves traffic onto a much slower
          path, stopping only restores normal routing.
        '';
      };

      connectTimeouts = lib.mkOption {
        type = lib.types.str;
        default = "120";
        description = ''
          GT_TIMEOUTS for automatic bring-up. Deliberately far shorter than the
          manual default (300/600/900): proot's slow login justifies a long wait
          when a person is watching, but here a dead jump host would hold the
          lock and block every later tick.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "2min";
        description = ''
          Timer period. A safety net only -- the NetworkManager dispatcher is
          what reacts promptly; this catches an uplink that dies without any
          link-state change.
        '';
      };
    };

    icmp.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Relay ICMP echo, so `ping` and `traceroute` report the real path rather
        than being answered locally by sing-box.

        Separable because it is the only part that touches policy routing and
        the firewall: it adds a second tun, an `ipproto icmp` rule, a routing
        table, and an interface-scoped netfilter exemption. TCP, UDP and QUIC do
        not depend on it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    /*
      Root-only by construction: no setuid helper and no polkit rule,
      deliberately. Bringing this up rewrites the default route.
    */
    environment.systemPackages = [ globaltun ] ++ lib.optional cfg.auto.enable autoScript;

    assertions = [
      {
        assertion = !cfg.auto.enable || cfg.auto.ssids != [ ];
        message = "my.globaltun.auto.enable requires at least one my.globaltun.auto.ssids entry";
      }
      {
        assertion = !cfg.auto.enable || config.networking.networkmanager.enable;
        message = "my.globaltun.auto.enable requires networking.networkmanager.enable (the SSID is read with nmcli)";
      }
    ];

    systemd.services.globaltun-auto = lib.mkIf cfg.auto.enable {
      description = "Decide whether the globaltun tunnel should be up";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe autoScript;
      };
    };

    systemd.timers.globaltun-auto = lib.mkIf cfg.auto.enable {
      description = "Periodic globaltun uplink check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.auto.interval;
        AccuracySec = "10s";
      };
    };

    /*
      --no-block matters: dispatcher scripts run synchronously inside
      NetworkManager, and bring-up can take minutes on a slow proot login.
      Blocking here would stall NM's own event processing.
    */
    networking.networkmanager.dispatcherScripts = lib.mkIf cfg.auto.enable [{
      type = "basic";
      source = pkgs.writeShellScript "globaltun-dispatch" ''
        case "$2" in
          up|down|connectivity-change) systemctl start --no-block globaltun-auto.service ;;
        esac
      '';
    }];
  };
}
