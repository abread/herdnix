#!/usr/bin/env bash
set -o errexit
set -o errtrace

red() {
	tput setaf 1 bold
}
yellow() {
	tput setaf 3 bold
}
reset() {
	tput sgr0
}

if [[ $# -eq 0 ]]; then
	# Switch to temporary directory
	flakedir="$(pwd)"
	ownscript="$(realpath "$0")"
	tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" herdnix.XXXXXXXXXX)"
	tmpdir="$(realpath "$tmpdir")"
	cd "$tmpdir"

	# cleanup on exit
	# shellcheck disable=SC2064
	trap "rm -rf '${tmpdir}'" EXIT

	# Grab list of hosts, selecting only those with herdnix enabled.
	host_metadata="${tmpdir}/metadata.json"
	nix eval --json "${flakedir}#nixosConfigurations" --apply 'f: builtins.mapAttrs (h: v: v.config.modules.herdnix) f' | jq -c '. | map_values(select(.enable))' >"$host_metadata"

	# Ask the user which ones should be updated
	readarray -t checklist_entries < <(jq -r 'to_entries | map(.key + "\n" + .value.targetHost + "\n" + if .value.defaultSelect then "on" else "off" end) | .[]' "$host_metadata")
	chosen_hosts="$(dialog --stdout --checklist 'Select hosts to (re-)build:' 0 0 0 "${checklist_entries[@]}")"
	clear
	[[ -z $chosen_hosts ]] && echo "No hosts chosen, nothing to do." && exit 0

	# Filter host metadata based on user choices
	chosen_hosts_filter="{ $(echo -n "$chosen_hosts" | sed -E 's/^/"/' | sed -E 's/ /": 1,"/g' | sed -E 's/$/": 1/') }"
	jq -c "with_entries(select(.key | in(${chosen_hosts_filter})))" "$host_metadata" >"${host_metadata}.new"
	mv "${host_metadata}.new" "$host_metadata"

	readarray -t build_configs < <(jq -r "keys | sort | map(\"$(echo -n -E "$flakedir" | sed 's \\ \\\\ g' | sed 's " \\" g' | sed 's # \\# g')#nixosConfigurations.\" + . + \".config.system.build.toplevel\") | .[]" "$host_metadata")
	echo "Build output:"
	ionice nice nom build "${build_configs[@]}"
	mv result result-0 # for uniformity

	echo
	read -r -p "Press enter to continue."

	# Open tmux with individual rebuild options for each host
	unset tmux_sock_path
	i=0
	for host_data in $(jq -c 'to_entries | sort_by(.key) | .[]' "$host_metadata"); do
		hostname="$(echo "$host_data" | jq -r '.key')"
		targetHost="$(echo "$host_data" | jq -r '.value.targetHost')"
		useRemoteSudo="$(echo "$host_data" | jq -r '.value.useRemoteSudo')"
		buildResultPath="$(pwd)/result-${i}"
		i=$((i + 1))

		cmd=("$ownscript" "$hostname" "$targetHost" "$useRemoteSudo" "$flakedir" "$buildResultPath")
		if [[ -n $tmux_sock_path ]]; then
			tmux -S"$tmux_sock_path" new-window "${cmd[@]}"
		else
			tmux_sock_path="${tmpdir}/tmux"
			tmux -S"$tmux_sock_path" new-session -d "${cmd[@]}"
		fi

		tmux -S"$tmux_sock_path" rename-window "$hostname"
	done

	tmux -S"$tmux_sock_path" attach
	echo "All done."
	exit 0
fi

pause_on_crash() {
	echo
	echo "$(red)Looks like we crashed on line $(caller)$(reset)"
	read -r -p "Press enter to really exit."
	exit 1
}
trap pause_on_crash ERR

hostname="$1"
target="$2"
[[ $3 == "true" ]] && useRemoteSudo=(--use-remote-sudo) || useRemoteSudo=()
flakedir="$(echo -n -E "$4" | sed 's # \\# g')"
buildResultPath="$5"

reboot_cmd=(echo "$(red)I don't know how to reboot this host$(reset)")
if [[ "$(hostname)" == "$hostname" ]]; then
	targetCmdWrapper=(sh -c)
	reboot_cmd=(echo "$(red)I refuse to reboot the current host.$(reset)")
	targetHost=()
else
	sshopts=(-o ControlPath="$(pwd)/${hostname}.ssh" -o ControlMaster=auto -o ControlPersist=120)
	export NIX_SSHOPTS="${sshopts[*]}"
	targetCmdWrapper=(ssh "${sshopts[@]}" "$target")

	[[ $3 == "true" ]] && remoteSudo=(sudo) || remoteSudo=()
	reboot_cmd=("${targetCmdWrapper[@]}" "${remoteSudo[@]}" "/run/current-system/sw/bin/__herdnix-reboot-helper" "--yes")

	targetHost=(--target-host "$target")
fi
unset target

rebuild() {
	op="$1"
	nixos-rebuild "$op" --flake "${flakedir}#${hostname}" "${targetHost[@]}" "${useRemoteSudo[@]}"
}
ask_reboot() {
	msg="$1"
	if dialog --yesno "$msg" 0 0; then
		clear
		echo "Asking ${hostname} to reboot..."
		"${reboot_cmd[@]}" || {
			echo
			echo "$(yellow)Looks like we failed to reboot. If it's the first run this is normal: we need to install the reboot helper first.$(reset)"
			echo
			read -r -p "Press enter to continue..."
			return 2
		}
	else
		clear
		echo "$(yellow)Not rebooting ${hostname}$(reset)"
		return 1
	fi
}

updateActiveHash() {
	# shellcheck disable=SC2016
	activeHash="$("${targetCmdWrapper[@]}" 'nix hash path "$(readlink -f /run/current-system)"')"
}
updateNextBootHash() {
	# shellcheck disable=SC2016
	nextBootHash="$("${targetCmdWrapper[@]}" 'nix hash path "$(readlink -f /nix/var/nix/profiles/system)"')"
}
updateBootedHash() {
	# shellcheck disable=SC2016
	bootedHash="$("${targetCmdWrapper[@]}" 'nix hash path "$(readlink -f /run/booted-system)"')"
}
currentHash="$(nix hash path "$(readlink -f "$buildResultPath")")"
updateActiveHash
updateNextBootHash
updateBootedHash

menuOptions=()
buildMenuOptions() {
	menuOptions=()

	if [[ $currentHash != "$activeHash" ]]; then
		menuOptions+=(
			"inspect" "Inspect the changes caused by the new configuration (again)"
		)
	fi
	if [[ $currentHash != "$nextBootHash" ]]; then
		menuOptions+=(
			"boot" "Add new configuration to top of boot order"
		)
	fi
	if [[ $currentHash != "$activeHash" ]] && [[ $currentHash == "$nextBootHash" ]]; then
		menuOptions+=(
			"reboot" "Reboot to new configuration"
		)
	fi
	if [[ $currentHash != "$activeHash" ]]; then
		if [[ $currentHash == "$nextBootHash" ]]; then
			menuOptions+=(
				"switch" "Activate new configuration (already at the top of the boot order)"
			)
		else
			menuOptions+=(
				"switch" "Activate new configuration, addint it to the top of the boot order"
			)
		fi
	fi
	if [[ $currentHash != "$activeHash" ]] && [[ $currentHash != "$nextBootHash" ]]; then
		menuOptions+=(
			"test" "Activate new configuration without adding it to the boot order"
		)
	fi
}

buildMenuOptions

# exit early if there's nothing to do
if [[ ${#menuOptions[@]} == 0 ]]; then
	if [[ $currentHash != "$bootedHash" ]]; then
		if [[ $hostname == "$(hostname)" ]]; then
			echo "$(red)${hostname} has the latest config active but it booted the older one. Maybe you want to reboot it$(reset)"
			echo "That said, I refuse to reboot the local host for you"
		else
			ask_reboot "${hostname} has the latest config active, but it booted an older one. Do you want to reboot it?" || true
		fi

		echo
		read -r -p "Press any key to exit..."
	fi

	exit 0
fi

# show result of dry activation (if there is a difference)
[[ $currentHash != "$activeHash" ]] && {
	echo "This is the result of switching to the new configuration in ${hostname}:"
	rebuild dry-activate || pause_on_crash
}

echo
[[ $currentHash == "$activeHash" ]] && echo "$(red)This configuration is already active .$(reset)"
[[ $currentHash == "$nextBootHash" ]] && echo "$(red)This configuration is already in the target host and will be activated on next boot.$(reset)"
echo
read -r -p "Press enter to continue..."

while true; do
	action="$(dialog --stdout --no-cancel --menu "Choose what to do with ${hostname}:" 0 0 0 "${menuOptions[@]}" "exit" "Do nothing, just exit")"
	clear

	case "$action" in
	inspect)
		echo "This is the result of switching to the new configuration in ${hostname}:"
		echo
		rebuild dry-activate || true
		;;
	boot)
		echo "${hostname}: Adding new configuration to boot order"
		echo
		if rebuild boot; then
			if [[ "$(hostname)" == "$hostname" ]]; then
				echo "$(red)Don't forget to reboot! I refuse to reboot the local host for you.$(reset)"
			elif (
				echo
				read -r -p "Press enter to continue..."
				ask_reboot "Do you want to reboot ${hostname}?"
			); then
				echo
				read -r -p "Done. Press enter to exit..."
				exit 0
			fi
		fi

		# refresh possibly changed hashes
		updateNextBootHash
		;;
	reboot)
		if [[ "$(hostname)" == "$hostname" ]]; then
			echo "$(red)I refuse to reboot the local host! THIS SHOULD NOT EVEN BE AN OPTION!$(reset)"
		elif ask_reboot "Are you sure you want to reboot ${hostname}?"; then
			echo
			read -r -p "Done. Press enter to exit..."
			exit 0
		fi
		;;
	switch)
		echo "${hostname}: Switching to new configuration, ensuring it is added to the top of the boot order"
		echo
		if rebuild switch; then
			echo
			read -r -p "Done. Press enter to exit..."
			exit 0
		fi

		# refresh possibly changed hashes
		updateActiveHash
		updateNextBootHash
		;;
	test)
		echo "${hostname}: Switching to new configuration without adding it to boot order"
		echo
		rebuild test || true

		# refresh possibly changed hashes
		updateActiveHash
		;;
	exit)
		if dialog --yesno "Are you sure you want to exit?" 0 0; then
			clear
			exit 0
		fi
		;;
	*)
		echo
		echo "Unknown command '${action}'."
		echo
		;;
	esac

	echo
	buildMenuOptions # refresh options
	echo
	if [[ ${#menuOptions[@]} == 0 ]]; then
		read -r -p "All done. Press enter to exit..."
		exit 0
	else
		read -r -p "Press enter to continue..."
	fi
done
