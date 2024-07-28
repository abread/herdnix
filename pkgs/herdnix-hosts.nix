{
  lib,
  pkgs,
  # should be overridden
  nixosConfigurations ? {},
}:
pkgs.writeText "herdnix-hosts" (
  let
    hosts =
      builtins.mapAttrs
      (_host: v: v.config.modules.herdnix // {rebootHelperPackage = null;})
      (
        lib.attrsets.filterAttrs
        (_host: v: v.config.modules.herdnix.enable)
        nixosConfigurations
      );
  in
    builtins.toJSON hosts
)
