{pkgs}:
pkgs.writeShellApplication {
  name = "herdnix";
  runtimeInputs = [pkgs.dialog pkgs.nix-output-monitor pkgs.jq pkgs.tmux pkgs.ncurses];
  text = builtins.readFile ./herdnix.sh;
}
