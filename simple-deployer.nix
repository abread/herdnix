{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.modules.simple-deployer;
in {
  imports = [];

  options.modules.simple-deployer = {
    enable = lib.mkOption {
      # we use mkOption instead of mkEnableOption to use true as the default
      type = lib.types.bool;
      description = "Whether to enable deploys to this host";
      default = true;
      example = false;
    };

    defaultSelect = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to select this host for deployment by default";
      default = true;
      example = false;
    };

    deploymentUser = lib.mkOption {
      type = lib.types.str;
      description = "Which user should be used to deploy the configuration. Keep null to disable. This user will be granted enough permissions to use sudo without password for deployment tasks.";
      default = null;
      example = "someusername";
    };

    useRemoteSudo = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to use sudo to deploy this host with --use-remote-sudo";
      # enable when root does not have a configured SSH key
      default = cfg.deploymentUser != null && cfg.deploymentUser != "root";
      defaultText = lib.literalExpression ''cfg.deploymentUser != null && cfg.deploymentUser != "root"'';
      example = true;
    };

    targetHost = lib.mkOption {
      type = lib.types.str;
      description = "What to pass as --target-host to nixos-rebuild";
      default =
        (
          if cfg.deploymentUser != null
          then "${cfg.deploymentUser}@"
          else ""
        )
        + config.networking.fqdnOrHostName;
      defaultText = lib.literalExpression ''( if cfg.deploymentUser != null then "${cfg.deploymentUser}@" else "" ) + config.networking.fqdnOrHostName'';
      example = "user@machine.com";
    };
  };

  config = let
    # sudo has terrible argument handling logic so we resort to building a simple script for reboots
    # We only allow the deploy user to reboot when the latest configuration does not match the current configuration.
    rebootHelperName = "__simple-deployer-reboot-helper";
    rebootHelperDrv = pkgs.writeShellScriptBin rebootHelperName ''
      # Safeguard: prevent accidental invocation from autocompleted command
      if [ "$#" != "1" ] || [ "$1" != "--yes" ]; then
        echo "Not rebooting: must be invoked with a single argument (--yes)."
        exit 1
      fi

      # Safeguard: allow an administrator to prevent consecutive reboots (DoS attack)
      if [ $(cat /proc/uptime | cut -d' ' -f1 | cut -d. -f1) -le 120 ]; then
        echo "Not rebooting: uptime is under 120s"
        exit 1
      fi
      if [ -f /dev/shm/__simple-deployer-dont-reboot ]; then
        echo "Not rebooting: /dev/shm/__simple-deployer-dont-reboot exists"
        exit 1
      fi

      # Safeguard: only allow reboots if the configuration actually changed
      if [ "z$(readlink -f /nix/var/nix/profiles/system)" = "z$(readlink -f /run/booted-system)" ]; then
         echo Not rebooting, booted configuration matches latest
        exit 1
      fi

      exec ${pkgs.systemd}/bin/systemctl reboot
    '';

    # Allow deploy user to nixos-rebuild without a password
    # This allows the admin to, without password:
    # - Change the system profile to a store path that roughly matches the format for NixOS system configurations. All store paths must be signed so this *should* limit options to valid configurations.
    # - Switch between NixOS configurations with/without bootloader installation.
    # - Reboot the system if /run/current-system and /run/booted-system point to different paths.
    # ...using the current-system versions of nix-env/systemd-run/env/sh/reboot.
    # All in all, we expect an attacker with control of the admin user to be able to switch between valid configurations but never introduce its own (because it must be signed by cache.nixos.org or one of the build hosts).
    sudoRule = {
      users = [cfg.deploymentUser];
      runAs = "root";
      commands =
        builtins.map (cmd: {
          command = cmd;
          options = ["NOPASSWD"];
        }) [
          "/nix/var/nix/profiles/default/bin/nix-env ^-p /nix/var/nix/profiles/system --set /nix/store/([a-z0-9]+)-nixos-system-${config.networking.hostName}-([0-9.a-z]+)$"
          "/nix/var/nix/profiles/default/bin/nix-env --rollback -p /nix/var/nix/profiles/system"
          "/run/current-system/sw/bin/systemd-run ^-E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER=(1?) --collect --no-ask-password --pipe --quiet --same-dir --service-type=exec --unit=nixos-rebuild-switch-to-configuration --wait true$"
          "/run/current-system/sw/bin/systemd-run ^-E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER=(1?) --collect --no-ask-password --pipe --quiet --same-dir --service-type=exec --unit=nixos-rebuild-switch-to-configuration --wait /nix/store/([a-z0-9]+)-nixos-system-${config.networking.hostName}-([0-9.a-z]+)/bin/switch-to-configuration (switch|boot|test|dry-activate)$"
          "/run/current-system/sw/bin/env ^-i LOCALE_ARCHIVE=([^ ]+) NIXOS_INSTALL_BOOTLOADER=(1?) /nix/store/([a-z0-9]+)-nixos-system-${config.networking.hostName}-([0-9.a-z]+)/bin/switch-to-configuration (switch|boot|test|dry-activate)$"

          # Allow rebooting but only when configuration changed
          "/run/current-system/sw/bin/${rebootHelperName} --yes"
        ];
    };
    applySudoRule = cfg.useRemoteSudo && cfg.deploymentUser != null && cfg.deploymentUser != "root";
  in {
    security.sudo.extraRules = lib.mkIf (applySudoRule && config.security.sudo.enable) [sudoRule];
    security.sudo-rs.extraRules = lib.mkIf (applySudoRule && config.security.sudo-rs.enable) [sudoRule];

    environment.systemPackages = lib.mkIf (cfg.deploymentUser != null && cfg.deploymentUser != "root") [rebootHelperDrv];
  };
}
