#!/bin/bash
# Changes the system time-to-live (TTL) to a random value in range to decouple the value from deterministic sources
# Use with random schedule via systemd timer
#
# Example:
#
# Systemd Service:
#   [Unit]
#   Description=System TTL Randomizer
#
#   [Service]
#   Type=oneshot
#   ExecStart=/usr/local/bin/ttl_randomizer.sh
#
# Systemd Timer:
#   [Unit]
#   Description=System TTL Randomizer Timer
#
#   [Timer]
#   OnCalendar=*-*-* 00:00:00
#   RandomizedDelaySec=6h
#
#   [Install]
#   WantedBy=timers.target
#

if [[ $EUID -ne 0 ]]; then
	echo "Script requires root privileges to alter operating system TTL"
	exit 1
fi

# Config
logTag="TTL-Randomizer"
minTTL=50
maxTTL=129
persistenceFile="/etc/sysctl.d/99_z_ttl_override.conf"

function randomInRange() {
	local min max range limit
	min=$1 max=$2
	range=$((max - min + 1))
	cutoff=4294967296
	limit=$((cutoff / range * range))

	while :; do
		local r
		r=$(od -An -N4 -tu4 /dev/urandom)
		r=${r//[[:space:]]/}

		((r < limit)) && {
			echo $(((r % range) + min))
			return
		}
	done
}

# Delay run a small amount
delay=$(randomInRange 1 10)
sleep "$delay"

logger -p info -t"$logTag" "Rotating system TTL..."

# Random inclusive range for new value
randomTTL=$(randomInRange "$minTTL" "$maxTTL")
if [[ -z $randomTTL ]]; then
	logger -p err -t"$logTag" "Failed to create random TTL number (function return value missing)"
	exit 1
fi

# Rare, but ensure the persistent directory exists
if ! [[ -d "/etc/sysctl.d" ]]; then
	mkdir "/etc/sysctl.d"
	if [[ $? != 0 ]]; then
		logger -p err -t"$logTag" Failed to create missing /etc/sysctl.d directory
		exit 1
	fi
fi

# Reset persistent override file if already present
if [[ -f "$persistenceFile" ]]; then
	truncate -s0 "$persistenceFile"
fi

# IPv4: Change global ttl
newSetting="net.ipv4.ip_default_ttl=$randomTTL"
sysctl "$newSetting"
if [[ $? != 0 ]]; then
	logger -p err -t"$logTag" Failed to change current IPv4 interface TTL
	exit 1
fi

# IPv4: Persist changes
echo "$newSetting" >>"$persistenceFile"

# IPv6: Walk existing interfaces/globals to make immediate change
while IFS= read -r param; do
	if [[ -z $param ]]; then
		continue
	fi

	key=${param%=*} # Split on key/val separator
	key=${key/ /}   # Delete any spaces

	if [[ -z $key ]]; then
		logger -p err -t"$logTag" Failed extract key from existing sysctl paramter: "$param"
		exit 1
	fi

	newSetting="$key=$randomTTL"

	# Make live change
	sysctl "$newSetting"
	if [[ $? != 0 ]]; then
		logger -p err -t"$logTag" Failed to change IPv6 hop limit: key: "$key"
		exit 1
	fi

	# Persist changes
	printf '%s\n' "$newSetting" >>"$persistenceFile"
	if [[ $? != 0 ]]; then
		logger -p err -t"$logTag" Failed to persistent new hop limit in $persistenceFile: key: "$key"
		exit 1
	fi
done < <(sysctl net.ipv6.conf | grep '\.hop_limit')

logger -p info -t"$logTag" "System TTL Rotated Successfully (New TTL $randomTTL)"
