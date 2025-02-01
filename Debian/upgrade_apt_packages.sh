#!/bin/bash
# Root is required for APT
if [ "$EUID" -ne 0 ]
then
	>&2 echo "APT upgrades require root privileges"
	exit
fi

# Check presence of required commands
required_commands=("apt" "apt-get" "logger" "egrep")
for cmd in "${required_commands[@]}"; do
	if ! command -v "$cmd" &>/dev/null; then
            >&2 echo "Command not found: '$cmd'"
            exit 127
	fi
done

# Environment Variables for Sudo session
#  Ensure APT is running in a non-interactive manner
export DEBIAN_FRONTEND=noninteractive
#  Ensure any apt script that connects to internet goes through network proxy
export http_proxy=http://apt.aperturecorp.net:3142
export https_proxy=http://apt.aperturecorp.net:3142

# Update the package list
aptErr=$(apt-get update -y 2>&1 > /dev/null)
if [[ $? != 0 ]]
then
	>&2 echo "Failed updating package lists: $aptErr"
	exit 1
fi

# Get upgradable package list before upgrade
pkgs=$(apt list --upgradable 2>/dev/null)
if [[ $? != 0 ]]
then
	>&2 echo "Failed listing upgradable packages"
	exit 1
fi

# Exit normally if nothing to upgrade
upgradable=$(echo "$pkgs" | egrep -v "Listing")
if [[ -z $upgradable ]]
then
	echo "All packages already upgraded"
	exit 0
fi

# Upgrade all packages without prompting, preserving old configurations
apt-get upgrade -y --assume-yes -o Dpkg::Options::="--force-confold"
if [[ $? != 0 ]]
then
	>&2 echo "Failed running upgrade"
	exit 1
fi

# Perform a distribution upgrade (handles new dependencies, etc.)
apt-get dist-upgrade -y --assume-yes -o Dpkg::Options::="--force-confold"
if [[ $? != 0 ]]
then
	>&2 echo "Failed running dist-upgrade"
	exit 1
fi

# Log upgraded packages
while IFS= read -r pkg
do
	# Skip header
	if [[ $pkg == "Listing..." ]]
	then
		continue
	fi

	# Skip any empty lines
	if [[ $pkg == "" ]]
	then
		continue
	fi

	# Send log of all packages
	logger -t APT-Upgrade -p local7.info "Upgrading package $pkg"
done <<< "$pkgs"

# Zero out upgradable package counter file
echo "0" > /tmp/.upgradable_packages_count

# Clean up unused packages
apt-get autoremove -y
apt-get clean
if [[ $? != 0 ]]
then
	>&2 echo "Failed apt autoremove/cleaning"
	exit 1
fi

exit 0
