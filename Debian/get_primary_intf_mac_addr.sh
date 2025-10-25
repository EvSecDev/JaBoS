#!/bin/bash
# Designed to extract the first mac address of the primary network interface (the one with the default gateway)

sysDir="/sys/class/net"

defaultRoute=$(ip -o -6 route show default 2>/dev/null)
if [[ -z $defaultRoute ]]; then
    defaultRoute=$(ip -o -4 route show default 2>/dev/null)
fi
if [[ -z $defaultRoute ]]; then
    echo "Failed to retrieve default route for either IPv4 or IPv6" >&2
    exit 1
fi

primaryIntfName=$(awk '{print $5}' <<<"$defaultRoute" | head -n1)
if [[ -z $primaryIntfName ]]; then
    echo "Failed to find primary interface name from default route" >&2
    exit 1
fi

if ! [[ -d $sysDir/$primaryIntfName ]]; then
    echo "Found interface name is not valid or not found" >&2
    exit 1
fi

cat "/sys/class/net/$primaryIntfName/address" 2>/dev/null
if [[ $? != 0 ]]; then
    echo "Unable to access $sysDir/$primaryIntfName/address" >&2
    exit 1
fi

exit 0
