pkgs: let
  inhibitorPath = "/dev/shm/herdnix-dont-reboot";
in
  pkgs.writeShellScriptBin "__herdnix-reboot-helper" ''
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
    if [ -f "${inhibitorPath}" ]; then
      echo "Not rebooting: ${inhibitorPath} exists"
      exit 1
    fi

    # Safeguard: only allow reboots if the configuration actually changed
    if [ "z$(readlink -f /nix/var/nix/profiles/system)" = "z$(readlink -f /run/booted-system)" ]; then
       echo Not rebooting, booted configuration matches latest
      exit 1
    fi

    # use non-terminal stdin to avoid molly-guard interference
    exec reboot </dev/null
  ''
