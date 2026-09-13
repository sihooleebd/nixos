{ config, lib, pkgs, ... }:

let
  cfg = config.my.boot;
in
{
  options.my.boot = {
    enable = lib.mkEnableOption "systemd-boot with a deep rollback window";

    configurationLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = ''
        Generations kept in the ESP. The ESP here is ~1GB with only ~60MB per
        generation (kernel + initrd), so there is plenty of headroom for a much
        deeper rollback window than the old 2-generation limit.
      '';
    };

    extraEntries = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = lib.literalExpression ''
        { "windows.conf" = "title Windows\nefi /EFI/Microsoft/Boot/bootmgfw.efi\n"; }
      '';
      description = ''
        Extra loader entries. An option rather than a constant because these
        name EFI binaries that exist on one particular disk -- a cloned host
        must not inherit another machine's boot menu.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.systemd-boot = {
      enable = true;
      inherit (cfg) configurationLimit extraEntries;
    };

    boot.loader.efi.canTouchEfiVariables = true;

    # Keep the console quiet enough that late kernel messages don't draw over
    # the TUI greeter -- tuigreet shares tty1 with the kernel console. The
    # default consoleLogLevel of 4 prints KERN_ERR (level 3) too, e.g. the
    # benign Dell/Intel DPTF "ACPI BIOS Error [\_TZ.ETMD]" that fires right as
    # greetd starts and scribbles over the greeter. 3 sends only crit/alert/
    # emerg to the console; everything (errors included) still hits the journal.
    boot.consoleLogLevel = 3;

    /*
      Plymouth boot splash: a NixOS-branded splash covering the kernel/systemd/
      udev scroll from early boot until the greeter, so boot is a clean logo,
      not a wall of text. nixos-bgrt draws the firmware boot logo ringed by a
      NixOS-snowflake throbber. Paired with consoleLogLevel = 3 above (kernel
      chatter already suppressed, greeter kept clean), initrd.verbose = false,
      and quieted udev, so nothing prints over the splash. No "quiet" param --
      it would raise the console loglevel back to 4 and undo the greeter fix;
      loglevel=3 is already stricter.
    */
    boot.plymouth = {
      enable = true;
      theme = "nixos-bgrt";
      themePackages = [ pkgs.nixos-bgrt-plymouth ];
    };
    boot.initrd.verbose = false;
    boot.kernelParams = [
      "splash"
      "rd.udev.log_level=3"
      "udev.log_level=3"
    ];
  };
}
