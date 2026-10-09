{ config, lib, pkgs, ... }:

let
  cfg = config.my.tailscale;

  # Health check + restart. "Connected" = the backend is Running AND this node reports Online to the
  # control plane. If the backend is wedged (status errors/times out) or Running-but-offline, that's
  # the "disconnected" a `systemctl restart tailscaled` fixes. DEBOUNCED via a /run flag: a single
  # bad check only arms the flag; the restart fires only when the NEXT check is also bad -- so a
  # transient blip (which tailscale recovers from on its own) is ignored, and only a sustained drop
  # (>= one interval) triggers a restart. Intentional states (Stopped after `tailscale down`,
  # NeedsLogin, or mid-Startup) are left alone -- a restart there would thrash or not help.
  watchdog = pkgs.writeShellScript "tailscale-watchdog" ''
    export PATH=${lib.makeBinPath [ pkgs.tailscale pkgs.jq pkgs.coreutils pkgs.systemd ]}:$PATH
    flag=/run/tailscale-watchdog.down

    out=$(timeout 10 tailscale status --json 2>/dev/null); rc=$?
    healthy=0
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
      state=$(printf '%s' "$out" | jq -r '.BackendState // ""')
      online=$(printf '%s' "$out" | jq -r '.Self.Online // false')
      [ "$state" = "Running" ] && [ "$online" = "true" ] && healthy=1
      # Intentional / transient states we must NOT restart out of:
      case "$state" in Stopped|NeedsLogin|Starting|NoState) healthy=1 ;; esac
    fi

    if [ "$healthy" = 1 ]; then
      rm -f "$flag"
      exit 0
    fi

    # Disconnected. Restart only if it was already down on the previous check.
    if [ -e "$flag" ]; then
      rm -f "$flag"
      systemctl restart tailscaled.service
    else
      touch "$flag"
    fi
    exit 0
  '';
in
{
  options.my.tailscale = {
    enable = lib.mkEnableOption "Tailscale (tailscaled + the CLI)";

    watchdog = {
      enable = lib.mkEnableOption ''
        a periodic check that restarts tailscaled when the tailnet connection has dropped (backend
        wedged, or Running-but-offline), debounced so a transient blip does not trigger it
      '';

      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 60;
        description = "Seconds between connection checks. A sustained drop restarts after ~2 of these.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.tailscale.enable = true;

      # DNS robustness across network changes. Without systemd-resolved, NM (dns=default) AND tailscale
      # MagicDNS both rewrite /etc/resolv.conf directly, so after a Wi-Fi change tailscale's forwarder is
      # left pointing at a stale upstream -> health "dns-forward-failing" -> it can't resolve the control
      # plane -> ~90s wedge -> the watchdog restarts it. systemd-resolved gives tailscale proper split-DNS
      # (it registers MagicDNS via the resolved API while NM registers each link's own servers), so the
      # upstream updates instantly and nothing fights over resolv.conf. tailscale auto-detects resolved.
      services.resolved.enable = true;
      networking.networkmanager.dns = "systemd-resolved";

      # Stop NM randomizing the Wi-Fi MAC during scans: tailscaled reads the hwaddr flip as a MAJOR link
      # change and does a full rebind on every scan/blip. A stable MAC = far fewer spurious rebinds.
      networking.networkmanager.wifi.scanRandMacAddress = false;
    }

    (lib.mkIf cfg.watchdog.enable {
      systemd.services.tailscale-watchdog = {
        description = "Restart tailscaled when the tailnet connection has dropped";
        after = [ "tailscaled.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = watchdog;
        };
      };

      systemd.timers.tailscale-watchdog = {
        description = "Periodic tailscaled connection check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Let tailscale settle after boot before the first check; then every `interval`.
          OnBootSec = "3min";
          OnUnitActiveSec = "${toString cfg.watchdog.interval}s";
          Persistent = true;
        };
      };
    })
  ]);
}
