{ config, lib, pkgs, ... }:

let
  flamenco = pkgs.stdenv.mkDerivation {
    pname = "flamenco";
    version = "3.9.2";
    src = pkgs.fetchurl {
      url = "https://flamenco.blender.org/downloads/flamenco-3.9.2-linux-amd64.tar.gz";
      hash = "sha256-tuVpX8ikAw1a7lFlIjAE7SWQJweuWBdLcN0EoH7QJFI=";
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.libc ];
    sourceRoot = "flamenco-3.9.2-linux-amd64";
    installPhase = ''
      install -Dm755 flamenco-manager $out/bin/flamenco-manager
    '';
    meta.platforms = [ "x86_64-linux" ];
  };

  managerConfig = pkgs.writeText "flamenco-manager.yaml" ''
    _meta:
      version: 3
    manager_name: "Flamenco Manager"
    listen: ":8080"
    autodiscoverable: true
    shared_storage_path: "/var/lib/flamenco-manager/shared"
    local_manager_storage_path: "/var/lib/flamenco-manager/local-storage"
    shaman:
      enabled: true
      garbageCollect:
        enabled: true
        period: 24h0m0s
        maxAge: 744h0m0s
        extraCheckoutPaths: []
    task_timeout: 10m0s
    worker_timeout: 1m0s
    blocklist_threshold: 3
    task_fail_after_softfail_count: 3
    variables:
      blender:
        values:
          - platform: linux
            value: ${pkgs.blender}/bin/blender
  '';
in
lib.mkIf config.my.flamenco.enable {
  users.users.flamenco = {
    isSystemUser = true;
    group = "flamenco";
    home = "/var/lib/flamenco-manager";
    createHome = true;
  };
  users.groups.flamenco = { };

  systemd.tmpfiles.rules = [
    "d /var/lib/flamenco-manager/shared        0775 flamenco flamenco -"
    "d /var/lib/flamenco-manager/local-storage  0750 flamenco flamenco -"
  ];

  environment.systemPackages = [ flamenco ];

  systemd.services.flamenco-manager = {
    description = "Flamenco render farm manager";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      # Nix config is authoritative — overwrite on every start.
      ExecStartPre = pkgs.writeShellScript "flamenco-manager-init" ''
        cfg=/var/lib/flamenco-manager/flamenco-manager.yaml
        cp ${managerConfig} "$cfg"
        chmod 600 "$cfg"
        chown flamenco:flamenco "$cfg"
      '';
      ExecStart = "${flamenco}/bin/flamenco-manager";
      WorkingDirectory = "/var/lib/flamenco-manager";
      User = "flamenco";
      Group = "flamenco";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
