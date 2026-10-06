{ config, lib, ... }:

let
  cfg = config.my.syncthing;
  # Runs as the host's primary user (my.users.<name>.primary = true), so nothing here hardcodes an
  # account -- a cloned host for a different user gets syncthing under that user with no edits.
  user = config.my.internal.primaryUser;
in
{
  options.my.syncthing = {
    enable = lib.mkEnableOption "Syncthing file sync, running as the primary user";

    openDefaultPorts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open the firewall for sync (22000 tcp/udp) + local discovery (21027 udp), so direct/LAN peers
        connect without relaying. Tailscale peers work regardless; this just covers the non-tailnet
        case.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.syncthing = {
      enable = true;
      inherit user;
      group = "users";
      dataDir = "/home/${user}";
      configDir = "/home/${user}/.config/syncthing";
      inherit (cfg) openDefaultPorts;
      # Let the user own the device/folder set via the web UI; config here doesn't fight it.
      overrideDevices = false;
      overrideFolders = false;
    };

    # Raise the inotify watch ceiling for Syncthing. Without enough watches a large synced folder
    # can't be watched live and Syncthing falls back to slow periodic rescans. The common "204800"
    # advice assumes the old ~8k default, but modern kernels already scale it to 524288 by RAM -- so
    # pin it HIGHER (1048576) to be a genuine increase, not a downgrade. It's only a ceiling; kernel
    # memory is charged per watch actually taken (~1 KiB each).
    boot.kernel.sysctl."fs.inotify.max_user_watches" = 1048576;
  };
}
