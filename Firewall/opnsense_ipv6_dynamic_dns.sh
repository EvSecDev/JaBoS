#!/usr/local/bin/bash
# Uses IPv6 delegated prefix from opnsense and given ipv6 address suffix to update given dns record using nsupdate (w/ TSIG)
# Specifically meant for /60 delegated prefixes (will break with other sizes)

# Generic
DNSServerIP="2606:4700:4700::1111"           # Upstream DNS to retrieve current IPv6 suffix for given domain name
currentPublicPrefixFile="/tmp/igb0_prefixv6" # Opnsense file that contains the current WAN IPv6 prefix
remoteLoggingConfFile="/usr/local/etc/syslog-ng.conf.d/syslog-ng-destinations.conf" # Configured through web UI
logFile="/var/log/ipv6-dyndns.log"

# NSupdate parameters
keyFile="/usr/local/share/efw-ns1"                      # Info: https://linux.die.net/man/8/dnssec-keygen
authDNSAddressFile="/usr/local/share/auth-ns1-addr.txt" # IP of the authoritative DNS server to send update to

# Logging
remoteLoggingInfo=$(awk '/network/ {f=1} f; /\);/ {f=0; exit}' "$remoteLoggingConfFile")
if [[ $? != 0 ]] || [[ -z $remoteLoggingInfo ]]
then
	echo "Warning: Could not find remote logging information in syslog-ng config $remoteLoggingConfFile, remote logging will not be enabled"
else
	remoteSyslogIP=$(pcre2grep -o '(?<= \")[a-fA-F0-9:]+(?=\")' <<<"$remoteLoggingInfo")
	remoteSyslogPort=$(pcre2grep -o '(?<=port\()[0-9]+(?=\))' <<<"$remoteLoggingInfo")
	if [[ -z $remoteSyslogIP ]] || [[ -z $remoteSyslogPort ]]
	then
		echo "Warning: Could not find remote logging address or port from syslog-ng config $remoteLoggingConfFile, remote logging will not be enabled"
		unset remoteSyslogIP remoteSyslogPort
	fi
fi

function logMsg() {
	local message
	message=$1
	stdNum="$2"

	echo "$(date -Iseconds) $message" >> "$logFile"
	echo "$message" >&"$stdNum"
	if [[ -n $remoteSyslogIP ]] && [[ -n $remoteSyslogPort ]]
	then
		logger -h "$remoteSyslogIP" -P "$remoteSyslogPort" -t IPv6-Dynamic-DNS "$message"
	fi
}

if [[ "$#" -le 2 ]]
then
	echo "Usage: $0 <IPv6 /60 suffix> <Record Domain Name> <Record TTL>"
	exit 1
fi

# Inputs
suffixToUpdate=$1 # like 2003:999[9:1111:2222:3333:4444]
RecordToUpdate=$2 # like web.domain.com
TTL=$3            # like 60/180/3600

if [[ -z $suffixToUpdate ]]
then
	logMsg "input suffix cannot be empty" "2"
	exit 1
elif [[ -z $RecordToUpdate ]]
then
	logMsg "input record name cannot be empty" "2"
	exit 1
elif [[ -z $TTL ]]
then
	logMsg "input record TTL cannot be empty" "2"
	exit 1
fi

NS1=$(cat "$authDNSAddressFile")
if [[ $? != 0 ]] || [[ -z $NS1 ]]
then
	logMsg "Failed to retrieve authoritative nameserver address from $authDNSAddressFile" "2"
	exit 1
fi

# Retrieve prefix from cache file
publicPrefix=$(cat "$currentPublicPrefixFile")
if [[ $? != 0 ]] || [[ -z $publicPrefix ]]
then
	logMsg "Failed to retrieve WAN IPv6 prefix from prefix file $currentPublicPrefixFile" "2"
	exit 1
fi

# Parse the prefix
prefix=$(echo "$publicPrefix" | cut -d"/" -f1 | sed 's/[0-9]:://g') # Trim off cidr and last digit
if [[ -z $prefix ]]
then
	logMsg "Failed to parse prefix: Input: \"$publicPrefix\" Output: \"$prefix\"" "2"
	exit 1
fi

newDomainAAAArecord=$prefix$suffixToUpdate

# Ensure prefix file had contents
if [[ -z $newDomainAAAArecord ]]
then
	logMsg "Failed to parse WAN IPv6 prefix from prefix file $currentPublicPrefixFile" "2"
	exit 1
fi

# Backoff time range
backoffMin=5
backoffMax=30
backoffRange=$((backoffMin - backoffMax + 1))

# Get current record from external - Retry as needed
retriedLookup='false'
for ((i = 0 ; i < 5 ; i++ ))
do
	currentDomainAAAArecord=$(dig +short @$DNSServerIP AAAA "$RecordToUpdate")
	if [[ $? != 0 ]] || [[ -z $currentDomainAAAArecord ]] || [[ $currentDomainAAAArecord =~ "communications error to" ]]
	then
		logMsg "Failed to retrieve current DNS AAAA record for $RecordToUpdate, going to retry" "2"
		retriedLookup='true'

		if [[ $i == 4 ]]
		then
        	logMsg "Attempted DNS lookup $i times, failed to get a response for $RecordToUpdate" "2"
			exit 1
		else
			RAND=$(od -An -N4 -tu4 < /dev/urandom | tr -d ' ')
			backoffSeconds=$((RAND % backoffRange + backoffMin))
			sleep $backoffSeconds
			continue
		fi
	fi

	if [[ $retriedLookup == true ]]
	then
		logMsg "DNS resolution retry worked, continuing to update record $RecordToUpdate" "1"
	fi

	break
done

# Only continue to update if current prefix has changed
if [[ $currentDomainAAAArecord == $newDomainAAAArecord ]]
then
	exit 0
fi

logMsg "Record $RecordToUpdate value ($currentDomainAAAArecord) does NOT match current public IPv6 record value ($newDomainAAAArecord), running update" "1"

# Update AAAA record
nsupdate -k $keyFile <<EOF
server $NS1
zone $RecordToUpdate.
update delete $RecordToUpdate. AAAA
update add $RecordToUpdate. $TTL AAAA $newDomainAAAArecord
send
EOF

# Check if update worked
if [[ $? -eq 0 ]]
then
	logMsg "Domain AAAA record successfully changed from \"$currentDomainAAAArecord\" to \"$newDomainAAAArecord\"" "1"
else
	logMsg "Failed to nsupdate AAAA record for $RecordToUpdate: encountered error running nsupdate" "2"
	exit 1
fi

exit 0
