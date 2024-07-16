{
  description = "Deploy tool for multi-host NixOS flakes";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
      };
    };

    # We only have this input to pass it to other dependencies and
    # avoid having multiple versions in our dependencies.
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = inputs: (inputs.flake-parts.lib.mkFlake {inherit inputs;} ({moduleWithSystem, ...}: {
    imports = [
      # Derive the output overlay automatically from all packages that we define.
      inputs.flake-parts.flakeModules.easyOverlay
      inputs.pre-commit-hooks.flakeModule
    ];

    flake.nixosModules.default = moduleWithSystem (perSystem @ {self'}: {...}: {
      imports = [./module];
      modules.herdnix.rebootHelperPackage = perSystem.self'.packages.herdnixRebootHelper;
    });

    systems = inputs.nixpkgs.lib.systems.flakeExposed;
    perSystem = {
      system,
      self',
      pkgs,
      ...
    }: {
      packages = let
        mkRebootHelperPkg = import ./pkgs/reboot-helper;
        mkNixiesPkg = import ./pkgs/herdnix;
      in {
        herdnixRebootHelper = mkRebootHelperPkg pkgs;
        herdnix = mkNixiesPkg pkgs;
        default = self'.packages.herdnix;
      };

      apps = {
        herdnix = {
          type = "app";
          program = "${self'.packages.herdnix}/bin/herdnix";
        };
        default = self'.apps.herdnix;
      };

      formatter = pkgs.alejandra;

      checks = {
        pre-commit-check = inputs.pre-commit-hooks.lib."${system}".run {
          src = ./.;
          hooks = {
            # Nix
            alejandra.enable = true;
            statix.enable = true;
            deadnix.enable = true;

            # Shell
            shfmt.enable = true;

            # Git
            check-merge-conflicts.enable = true;
            forbid-new-submodules.enable = true;

            typos.enable = true;
          };
        };
      };

      devShells.default = pkgs.mkShell {
        inherit (self'.checks.pre-commit-check) shellHook;
        buildInputs = self'.checks.pre-commit-check.enabledPackages;
      };
    };
  }));
}
