pkgs:
pkgs.writeShellApplication {
  name = "nixies";
  runtimeInputs = [pkgs.dialog pkgs.nix-output-monitor pkgs.jq pkgs.tmux pkgs.ncurses];
  text = builtins.readFile ./nixies.sh;
}
