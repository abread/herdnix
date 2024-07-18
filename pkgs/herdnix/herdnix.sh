#!/usr/bin/env bash
set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

red() {
	tput setaf 1 bold
}
green() {
	tput setaf 2 bold
}
yellow() {
	tput setaf 3 bold
}
reset() {
	tput sgr0
}
dialog_red() {
	echo -n -E '\Zb\Z1'
}
dialog_green() {
	echo -n -E '\Zb\Z2'
}
dialog_yellow() {
	echo -n -E '\Zb\Z3'
}
dialog_reset() {
	echo -n -E '\Zn'
}

if [[ $# -eq 0 ]] || [[ $1 != "--single-host-do-not-call" ]]; then
	# Switch to temporary directory
	flakedir="$(pwd)"
	ownscript="$(realpath "$0")"
	tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" herdnix.XXXXXXXXXX)"
	tmpdir="$(realpath "$tmpdir")"
	cd "$tmpdir"

	# cleanup on exit
	# shellcheck disable=SC2064
	trap "rm -rf '${tmpdir}'" EXIT

	# Build a jq filter that selects hosts matching the provided tags
	tag_filter=""
	if [[ $# -gt 0 ]]; then
		tag_array="[\"${*// /\",\"}\"]"
		tag_filter="| map_values(select(((.tags | unique) as \$A | (${tag_array} | unique) as \$B | \$A - (\$A - \$B) | length) > 0))"
	fi

	# Grab list of hosts, selecting only those with herdnix enabled.
	host_metadata="${tmpdir}/metadata.json"
	nix eval --json "${flakedir}#nixosConfigurations" --apply 'f: builtins.mapAttrs (h: v: v.config.modules.herdnix // { rebootHelperPackage = null; }) f' |
		jq -c ". | map_values(select(.enable)) ${tag_filter}" \
			>"$host_metadata"

	# Ask the user which ones should be updated
	readarray -t checklist_entries < <(jq -r 'to_entries | map(.key + "\n" + .value.targetHost + "\n" + if .value.defaultSelect then "on" else "off" end) | .[]' "$host_metadata")
	[[ ${#checklist_entries[@]} == 0 ]] && echo "$(yellow)No hosts selected by filter, nothing to do.$(reset)" && exit 0
	chosen_hosts="$(dialog --stdout --checklist 'Select hosts to (re-)build:' 0 0 0 "${checklist_entries[@]}")"
	clear
	[[ -z $chosen_hosts ]] && echo "No hosts chosen, nothing to do." && exit 0

	# Filter host metadata based on user choices
	chosen_hosts_filter="{ $(echo -n "$chosen_hosts" | sed -E 's/^/"/' | sed -E 's/ /": 1,"/g' | sed -E 's/$/": 1/') }"
	jq -c "with_entries(select(.key | in(${chosen_hosts_filter})))" "$host_metadata" >"${host_metadata}.new"
	mv "${host_metadata}.new" "$host_metadata"

	# Prepare list of configurations to be built
	declare -A build_configs
	while IFS="=" read -r hostname outPath; do
		build_configs[$hostname]="$outPath"
	done < <(jq -r 'to_entries | sort_by(.key) | map("\( .key )=\( .key )") | .[]' "$host_metadata")
	for hostname in "${!build_configs[@]}"; do
		outPath="$(nix derivation show "${flakedir}#nixosConfigurations.${hostname}.config.system.build.toplevel" | jq -r 'to_entries | .[].value.outputs.out.path')"

		if [[ -d $outPath ]]; then
			# Filter out already-built configurations.
			echo "$(yellow)Skipping $(red)${hostname}$(yellow): already built.$(reset)"
			unset 'build_configs["$hostname"]'
		else
			# Prepare nix build args for kept configurations.
			build_configs[$hostname]="$(echo -n -E "$flakedir" | sed 's \\ \\\\ g' | sed 's " \\" g' | sed 's # \\# g')#nixosConfigurations.${hostname}.config.system.build.toplevel"
		fi
	done

	# Build missing configurations for selected hosts
	if [[ ${#build_configs[@]} -gt 0 ]]; then
		echo
		echo "Build output:"
		echo
		ionice nice nom build "${build_configs[@]}"
		echo
		read -r -p "Press enter to continue."
	fi

	# Open tmux with individual rebuild options for each host
	tmux_sock_path=""
	for host_data in $(jq -c 'to_entries | sort_by(.key) | .[]' "$host_metadata"); do
		hostname="$(echo "$host_data" | jq -r '.key')"
		targetHost="$(echo "$host_data" | jq -r '.value.targetHost')"
		useRemoteSudo="$(echo "$host_data" | jq -r '.value.useRemoteSudo')"
		buildResultPath="$(nix derivation show "${flakedir}#nixosConfigurations.${hostname}.config.system.build.toplevel" | jq -r 'to_entries | .[].value.outputs.out.path')"

		cmd=("$ownscript" "--single-host-do-not-call" "$hostname" "$targetHost" "$useRemoteSudo" "$flakedir" "$buildResultPath")
		if [[ -n ${tmux_sock_path} ]]; then
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

if [[ $# != 6 ]]; then
	echo "$(red)Invalid arguments in internal invocation. This is a bug.$(reset)"
	echo
	read -r -p "Press enter to exit."
	exit 1
fi

pause_on_crash() {
	echo
	echo "$(red)Looks like we crashed on line $(caller)$(reset)"
	read -r -p "Press enter to really exit."
	exit 1
}
trap pause_on_crash ERR

hostname="$2"
target="$3"
useRemoteSudo="$4"
flakedir="$(echo -n -E "$5" | sed 's # \\# g')"
buildResultPath="$6"

[[ $useRemoteSudo == "true" ]] && useRemoteSudoArg=(--use-remote-sudo) || useRemoteSudoArg=()

reboot_cmd=(echo "$(red)I don't know how to reboot this host. This is a bug.$(reset)")
if [[ "$(hostname)" == "$hostname" ]]; then
	targetCmdWrapper=(sh -c)
	reboot_cmd=(echo "$(red)I refuse to reboot the current host.$(reset)")
	targetHostArg=()
else
	sshopts=(-o ControlPath="$(pwd)/${hostname}.ssh" -o ControlMaster=auto -o ControlPersist=120)
	export NIX_SSHOPTS="${sshopts[*]}" # share SSH connection with nixos-rebuild invocations
	targetCmdWrapper=(ssh "${sshopts[@]}" "$target")

	[[ $useRemoteSudo == "true" ]] && helperWrapper=(sudo) || helperWrapper=()

	# shellcheck disable=SC2016
	reboot_cmd=("${targetCmdWrapper[@]}" "${helperWrapper[@]}" '/etc/profiles/per-user/${USER}/bin/__herdnix-reboot-helper' "--yes")

	targetHostArg=(--target-host "$target")
fi
unset target

rebuild() {
	op="$1"
	nixos-rebuild "$op" --flake "${flakedir}#${hostname}" "${targetHostArg[@]}" "${useRemoteSudoArg[@]}"
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
	if [[ $currentHash == "$nextBootHash" ]] && [[ $currentHash != "$bootedHash" ]]; then
		if [[ $currentHash == "$activeHash" ]]; then
			menuOptions+=(
				"reboot" "Reboot with (already active) new configuration"
			)
		else
			menuOptions+=(
				"reboot" "Reboot to new configuration"
			)
		fi
	fi
	if [[ $currentHash != "$activeHash" ]]; then
		if [[ $currentHash == "$nextBootHash" ]]; then
			menuOptions+=(
				"switch" "Activate new configuration (already at the top of the boot order)"
			)
		else
			menuOptions+=(
				"switch" "Activate new configuration and add it to the top of the boot order"
			)
		fi
	fi
	if [[ $currentHash != "$activeHash" ]] && [[ $currentHash != "$nextBootHash" ]]; then
		menuOptions+=(
			"test" "Activate new configuration (without adding it to the boot order)"
		)
	fi
}

buildMenuOptions

# show result of dry activation (if there is a difference)
if [[ $currentHash != "$activeHash" ]]; then
	echo "This is the result of switching to the new configuration in $(yellow)${hostname}$(reset):"
	rebuild dry-activate || pause_on_crash

	echo
	read -r -p "Press enter to continue..."
fi

while [ ${#menuOptions[@]} -gt 0 ]; do
	[[ $currentHash == "$activeHash" ]] && is_active="$(dialog_green)activated$(dialog_reset)" || is_active="$(dialog_red)NOT activated$(dialog_reset)"
	[[ $currentHash == "$nextBootHash" ]] && is_nextboot="$(dialog_green)active on next boot$(dialog_reset)" || is_nextboot="$(dialog_red)NOT active on next boot$(dialog_reset)"
	[[ $currentHash == "$activeHash" ]] && [[ $currentHash == "$nextBootHash" ]] && extra_warning="WARNING: System was booted with an older configuration." || extra_warning=""
	read -r -d '' title <<-EOS || true
		Deploying $(dialog_yellow)${hostname}$(dialog_reset)
		New configuration status: ${is_active}, ${is_nextboot}
		$(dialog_yellow)${extra_warning}$(dialog_reset)

		What should we do?
	EOS

	action="$(dialog --stdout --no-cancel --colors --cr-wrap --menu "${title}" 0 0 0 "${menuOptions[@]}" "exit" "Do nothing, just exit")"
	clear

	case "$action" in
	inspect)
		echo "This is the result of switching to the new configuration in $(yellow)${hostname}$(reset):"
		echo
		rebuild dry-activate || true
		;;
	boot)
		echo "$(yellow)${hostname}$(reset): Adding new configuration to boot order"
		echo
		rebuild boot || true

		# refresh possibly changed hashes
		updateNextBootHash
		;;
	reboot)
		if [[ "$(hostname)" == "$hostname" ]]; then
			echo "$(red)I refuse to reboot the local host! THIS SHOULD NOT EVEN BE AN OPTION!$(reset)"
		else
			dialog_out=""
			while [[ $dialog_out != "$hostname" && $dialog_out != "__CANCEL_${hostname}" ]]; do
				clear
				dialog_out="$(dialog --stdout --colors --cr-wrap --inputbox "Input $(dialog_yellow)${hostname}$(dialog_reset) below to confirm you want to reboot it.\nPress Cancel to cancel." 0 0 || echo "__CANCEL_${hostname}")"
			done
			clear

			if [[ $dialog_out == "$hostname" ]]; then
				echo "Asking $(yellow)${hostname}$(reset) to reboot..."

				# retcode 255 likely means connection closed, which is fine.
				"${reboot_cmd[@]}" && _reboot_ret=0 || _reboot_ret=$?
				if [[ $_reboot_ret == 0 || $_reboot_ret == 255 ]]; then
					echo
					read -r -p "Press enter to exit."
				else
					echo
					echo "$(yellow)Looks like we failed to reboot. If it's the first run this is normal: we need to install the reboot helper first.$(reset)"
					echo "You may want to activate the new configuration."
					echo
					read -r -p "Press enter to continue..."
				fi
			fi

			# Nothing changed, so there is no need for rebuilding menu options
			# and we don't want to prompt the user to press enter to continue
			continue
		fi
		;;
	switch)
		echo "${hostname}: Switching to new configuration, ensuring it is added to the top of the boot order"
		echo
		rebuild switch || true

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
