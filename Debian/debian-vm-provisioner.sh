#!/bin/bash

usage() {
	cat <<EOF
Usage: $0 -i <input.iso> -p <preseed.cfg> -c <vmcfg.json>

Arguments:
  -i <path>              Path to original Debian netinst ISO image
  -p <preseed.cfg>       Path to preseed file to embed in ISO
  -c <conf.json>         File path to VM JSON configuration
  -u <https://mgmtaddr>  URL to Proxmox Management
  -k                     Trust any proxmox HTTPs certificate
  -h                     Show this help message and exit
EOF
}

check_dependencies() {
	local deps=(vm-provisioner.sh debian_autoinstall_iso_creator.sh)
	local missing=()
	for cmd in "${deps[@]}"; do
		if ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done
	if ((${#missing[@]})); then
		echo "[-] ERROR: Missing required commands: ${missing[*]}" >&2
		echo "Please install them and retry." >&2
		exit 1
	fi
}

check_dependencies

inputISO=""
vmJSON=""
preseedCfg=""
proxmoxURL=""
allowInsecure=false

while getopts "i:p:c:u:kh" opt; do
	case $opt in
		i) inputISO=$OPTARG ;;
		c) vmJSON=$OPTARG ;;
		p) preseedCfg=$OPTARG ;;
		u) proxmoxURL=$OPTARG ;;
		k) allowInsecure=true ;;
		h)
			usage
			exit 0
			;;
		*)
			usage
			exit 1
			;;
	esac
done

if [[ -z "$inputISO" || -z "$vmJSON" || -z "$preseedCfg" ]]; then
	echo "[-] ERROR: Missing required arguments." >&2
	usage
	exit 1
fi

urlArg="--url $proxmoxURL"

set -e

preseededISO="/tmp/img-$(date +%s).iso"

debian_autoinstall_iso_creator.sh -i "$inputISO" -o "$preseededISO" -p "$preseedCfg"
if [[ $allowInsecure == true ]]; then
	# shellcheck disable=SC2086
	vm-provisioner.sh -i "$preseededISO" -c "$vmJSON" -k $urlArg
else
	# shellcheck disable=SC2086
	vm-provisioner.sh -i "$preseededISO" -c "$vmJSON" $urlArg
fi
