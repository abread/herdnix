{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.modules.herdnix;
in {
  imports = [];

  options.modules.herdnix = {
    enable = lib.mkEnableOption "deploys to this host with herdnix";

    deploymentUser = lib.mkOption {
      type = lib.types.str;
      description = "Which user should be used to deploy the configuration. Keep null to disable. This user will be granted enough permissions to use sudo without password for deployment tasks (if useRemoteSudo is set to true, which is the default for non-root deployment users).";
      default = "herdnix";
      example = "someusername";
    };

    createDeploymentUser = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to create a least-privilege deployment user. This user is created as a password-less, home-less, nogroup user by default, and we expect you to enable authentication separately (e.g. through SSH keys).";
      default = cfg.deploymentUser == "herdnix";
      defaultText = lib.literalExpression ''config.modules.herdnix.deploymentUser == "herdnix"'';
      example = false;
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = "Tags associated with this host";
      default = [config.networking.hostName];
      defaultText = lib.literalExpression ''[config.networking.hostName]'';
      example = lib.literalExpression ''["webserver", "primary"]'';
    };

    targetHost = lib.mkOption {
      type = lib.types.str;
      description = "What to pass as --target-host to nixos-rebuild. Change if the default is not enough to reach your system.";
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

    rebootTimeout = lib.mkOption {
      type = lib.types.int;
      description = "Maximum wait time for host to reboot in seconds";
      default = 60;
      example = 300;
    };

    defaultSelect = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to select this host for deployment by default";
      default = true;
      example = false;
    };

    useRemoteSudo = lib.mkOption {
      type = lib.types.bool;
      description = "Whether to use sudo to deploy this host with --use-remote-sudo. You likely do not want to change this.";
      # enable when root does not have a configured SSH key
      default = cfg.deploymentUser != "root";
      defaultText = lib.literalExpression ''cfg.deploymentUser != "root"'';
      example = false;
    };

    rebootHelperPackage = lib.mkPackageOption pkgs "reboot helper" {
      default = "herdnixRebootHelper";
      extraDescription = "The reboot helper must expose itself in the PATH as \"__herdnix-reboot-helper\". You likely do not want to change this.";
    };
  };

  config = let
    # sudo has terrible argument handling logic so we resort to building a simple script for reboots
    # We only allow the deploy user to reboot when the latest configuration does not match the current configuration.
    rebootHelperName = "__herdnix-reboot-helper";

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
          "/run/current-system/sw/bin/nix-env ^-p /nix/var/nix/profiles/system --set /nix/store/([a-z0-9]+)-nixos-system-${config.networking.hostName}-([0-9.a-z]+)$"
          "/nix/var/nix/profiles/default/bin/nix-env --rollback -p /nix/var/nix/profiles/system"
          "/run/current-system/sw/bin/nix-env --rollback -p /nix/var/nix/profiles/system"

          "/run/current-system/sw/bin/systemd-run ^-E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER=(1?) --collect --no-ask-password --pipe --quiet --same-dir --service-type=exec --unit=nixos-rebuild-switch-to-configuration --wait true$"
          "/run/current-system/sw/bin/systemd-run ^-E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER=(1?) --collect --no-ask-password --pipe --quiet --same-dir --service-type=exec --unit=nixos-rebuild-switch-to-configuration --wait /nix/store/([a-z0-9]+)-nixos-system-${config.networking.hostName}-([0-9.a-z]+)/bin/switch-to-configuration (switch|boot|test|dry-activate)$"
          "/run/current-system/sw/bin/env ^-i LOCALE_ARCHIVE=([^ ]+) NIXOS_INSTALL_BOOTLOADER=(1?) /nix/store/([a-z0-9]+)-nixos-system-${config.networking.hostName}-([0-9.a-z]+)/bin/switch-to-configuration (switch|boot|test|dry-activate)$"

          # Allow rebooting but only when configuration changed
          "/etc/profiles/per-user/${cfg.deploymentUser}/bin/${rebootHelperName} --yes"
        ];
    };
    applySudoRule = cfg.useRemoteSudo && cfg.deploymentUser != "root";
  in
    lib.mkIf cfg.enable {
      users.users."${cfg.deploymentUser}" = lib.mkMerge [
        {
          packages = [cfg.rebootHelperPackage];
        }
        (lib.mkIf cfg.createDeploymentUser {
          isNormalUser = true;
          shell = pkgs.bashInteractive;
          home = "/var/empty";
          createHome = false;
          group = "nogroup";
        })
      ];

      security = {
        sudo.extraRules = lib.mkIf (applySudoRule && config.security.sudo.enable) [sudoRule];
        sudo-rs.extraRules = lib.mkIf (applySudoRule && config.security.sudo-rs.enable) [sudoRule];
      };
    };
}
