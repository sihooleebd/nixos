{ config, lib, pkgs, ... }:

let
  cfg = config.my.power;

  # power-profiles-daemon owns the real "how hot / how loud" dial: it drives EPP AND the ACPI
  # platform profile that the Dell EC's fan curve follows. So the profile below is applied to PPD
  # at boot; this module only ADDS the matching sched_ext bias, powertop auto-tune, and governor.
  # (An earlier static EPP=power udev rule was removed -- PPD overrode it anyway, so it was a no-op
  # that just made the config lie about what the machine was doing.)
  ppdProfile = {
    powersave = "power-saver";
    balanced = "balanced";
    performance = "performance";
  }.${cfg.profile};

  # scx_bpfland primary domain: "powersave" packs work onto the most efficient CPUs (lowest power,
  # a touch more latency); "performance" spreads across all cores (snappier, higher throughput).
  schedArgs =
    if cfg.profile == "powersave"
    then [ "--primary-domain" "powersave" ]
    else [ "--primary-domain" "performance" ];

  ppdSet = pkgs.writeShellScript "apply-ppd-profile" ''
    for _ in 1 2 3 4 5; do
      ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set ${ppdProfile} && exit 0
      sleep 1
    done
    exit 0
  '';
in
{
  options.my.power = {
    enable = lib.mkEnableOption "laptop power management (sched_ext scheduler + governor + power profile)";

    profile = lib.mkOption {
      type = lib.types.enum [ "powersave" "balanced" "performance" ];
      default = "balanced";
      description = ''
        Overall CPU/thermal bias. The dominant "how hot / how loud" lever is EPP + the ACPI
        platform profile, both owned by power-profiles-daemon; this option applies the matching PPD
        profile at boot and sets the sched_ext domain + powertop auto-tune to match. A runtime
        `powerprofilesctl set <...>` (or a bar toggle) still overrides it until the next boot.

          powersave   - coolest/quietest, most throttled: PPD power-saver, scx packs onto efficient
                        cores, powertop auto-tune on (aggressive device power gating).
          balanced    - snappy but quiet: full turbo for short bursts, calm fan under sustained
                        load. PPD balanced, scx spreads across all cores. (recommended)
          performance - max sustained clocks, LOUDER fan under load: PPD performance.

        thermald stays on in every profile, so the chip thermal-throttles long before anything is
        at risk -- "performance" cannot damage the machine, it just runs the fan harder.
      '';
    };

    scheduler = lib.mkOption {
      type = lib.types.str;
      default = "scx_bpfland";
      description = "sched_ext scheduler to run.";
    };

    schedulerArgs = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      description = "Override the sched_ext scheduler args; null derives them from `profile`.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.scx = {
      enable = true;
      package = pkgs.scx.rustscheds; # scx_bpfland is a Rust scheduler; avoids C BPF build
      scheduler = cfg.scheduler;
      extraArgs = if cfg.schedulerArgs != null then cfg.schedulerArgs else schedArgs;
    };

    powerManagement = {
      enable = true;
      # intel_pstate active mode: the governor is just a mode, and EPP (set by PPD) does the real
      # biasing -- so "powersave" here still turbos to max on demand when EPP is balance/perf.
      cpuFreqGovernor = "powersave";
      # Aggressive per-device power gating (USB autosuspend, PCIe ASPM, ...) only when saving power;
      # off otherwise, since it trades responsiveness/peripheral latency for idle watts.
      powertop.enable = cfg.profile == "powersave";
    };

    # Pin power-profiles-daemon to the chosen profile at boot (it does not persist across reboots).
    # Guarded on PPD being enabled so this module stays usable on a host without it.
    systemd.services.my-power-profile = lib.mkIf config.services.power-profiles-daemon.enable {
      description = "Apply my.power profile (${cfg.profile}) to power-profiles-daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "power-profiles-daemon.service" ];
      wants = [ "power-profiles-daemon.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ppdSet;
      };
    };
  };
}
