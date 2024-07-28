{
  description = "Deploy tool for multi-host NixOS flakes";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixpkgs-stable.follows = "nixpkgs";
      };
    };
  };

  outputs = {
    self,
    nixpkgs,
    pre-commit-hooks,
  }: let
    inherit (nixpkgs) lib;
    systems = lib.systems.flakeExposed;
    forAllSystems = lib.genAttrs systems;
  in {
    nixosModules = {
      default = self.nixosModules.herdnix;
      herdnix = import ./module.nix {myPkgs = self.packages;};
    };

    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      herdnix = pkgs.callPackage ./pkgs/herdnix {};
      herdnix-reboot-helper = pkgs.callPackage ./pkgs/reboot-helper.nix {};
      herdnix-hosts = pkgs.callPackage ./pkgs/herdnix-hosts.nix {};
    });

    apps = forAllSystems (system: {
      default = {
        type = "app";
        program = "${self.packages.${system}.herdnix}/bin/herdnix";
      };
    });

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);

    # Special derivation(s) with deploy target host metadata.
    # It must be exposed by flake users in packages/legacyPackages.
    genHerdnixHostsPackages = nixosConfigurations:
      forAllSystems (
        system: {
          herdnix-hosts = self.packages.${system}.herdnix-hosts.override {inherit nixosConfigurations;};
        }
      );

    checks = forAllSystems (system:
      lib.optionalAttrs (pre-commit-hooks ? lib) {
        pre-commit-check = pre-commit-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            # Nix
            alejandra.enable = true;
            statix.enable = true;
            deadnix.enable = true;

            # Shell
            shellcheck.enable = true;
            shfmt.enable = true;

            # Git
            check-merge-conflicts.enable = true;
            forbid-new-submodules.enable = true;

            typos.enable = true;
          };
        };
      });

    devShells = forAllSystems (system: {
      default = nixpkgs.legacyPackages.${system}.mkShell (
        (lib.optionalAttrs (self.checks.${system} ? pre-commit-check) {
          inherit (self.checks.${system}.pre-commit-check) shellHook;
          buildInputs = self.checks.${system}.pre-commit-check.enabledPackages;
        })
        // {
          packages = [
            self.packages.${system}.herdnix
            self.packages.${system}.herdnix-reboot-helper
          ];
        }
      );
    });
  };
}
