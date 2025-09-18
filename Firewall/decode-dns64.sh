#!/bin/bash
# Translates DNS64 fake IPv6 to the encoded IPv4 address
# Usage ./decode_dns64.sh 64:ff9b::1122:3344

if [[ -z "$1" ]]; then
    echo "Usage: $0 <synthesized IPv6 address>"
    exit 1
fi

ipv6=$1

# Get last two hex sections, assumes form: 64:ff9b::[last2hextets]
ipv4_hex=$(awk -F'::' '{print $2}' <<<"$ipv6" | tr ':' ' ')

read -r h1 h2 <<< "$ipv4_hex"

if [[ -z $h1 ]] || [[ -z $h2 ]]; then
    echo "Unable to extract embedded IPv4 from IPv6: $ipv6" >&2
    exit 1
fi

# Convert hex to decimal
ipv4_part1=$(( 0x${h1:0:2} ))
ipv4_part2=$(( 0x${h1:2:2} ))
ipv4_part3=$(( 0x${h2:0:2} ))
ipv4_part4=$(( 0x${h2:2:2} ))

# Output in v4 format
echo "${ipv4_part1}.${ipv4_part2}.${ipv4_part3}.${ipv4_part4}"
