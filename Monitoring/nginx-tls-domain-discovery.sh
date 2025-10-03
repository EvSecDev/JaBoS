#!/bin/bash
# Meant for integration with Zabbix multiple certificate monitoring for monitoring local NGINX server (for certificate details/expiration times)
# Designed to extract the first listen address and server name from each server block (a combination that would pass a TLS handshake)
# Produces JSON output like
# [
#   {"hostname":"host1.mycompany.com","port":"","address":""},
#   {"hostname":"host2.mycompany.com","port":"443","address":"127.0.0.1"}
# ]
# This does rely on each NGINX block containing a server_name and listen (addr+port) directive

# Required commands
command jq -V >/dev/null || exit 1
command nginx -v 2>/dev/null || exit 1

if ! nginx -t &>/dev/null; then
    echo "Nginx config test failed. Aborting." >&2
    exit 1
fi

if [[ $1 == compact ]]; then
    jsonSingleLine='true'
fi

# Collapsing server blocks (with selected fields) down to single lines for further processing
# Do not change sed into single -e it will break formatting
# What this does:
# - all tabs are gone
# - multiple concurrent spaces are collapsed to a single one
# - all configuration options are on their own line
# - retrieves the following specific lines from the output so far:
#   - server block start and end
#   - server_name directive
#   - listen directive (only ssl quic ones) <- this + missing field check later ensures we only get TLS domains
# - Remove the server block start and just have a plain bracket
# - Next 3 sed's focus on collapsing each filtered block down to a single line
# - Remove start and end brackets for the block
# - Cleanup all spaces around fields and add a field key/value delimiter
serverBlocks=$(nginx -T 2>/dev/null |
    tr '\t' ' ' | tr -s '[:space:]' |
    sed -e 's/;\s*/;\n/g' |
    grep -E "^\s*server {\s*$|^\s*}\s*$|^\s*server_name |^\s*listen .*ssl|^\s*listen .*quic" |
    sed 's/^\s*server {$/{/g' |
    sed ':a;N;$!ba;s/;\n/;/g' |
    sed ':a;N;$!ba;s/;\n}/;}/g' |
    sed ':a;N;$!ba;s/\n{\n/\n{/g' |
    grep -Ev "^\s*}\s*$|^\s*{\s*$" |
    sed -e 's/{\s*//g' -e 's/\s*}//g' -e 's/;\s*/;/g' -e 's/listen /listen=/g' -e 's/server_name /server_name=/g')

if [[ -z $serverBlocks ]]; then
    echo "Error: failed to parse nginx server blocks" >&2
    exit 1
fi

# Parse block by block, field by field to create output json
jsonArray=()
while IFS= read -r serverBlock; do
    if [[ -z $serverBlock ]]; then
        continue
    fi

    # Init this iteration's vars to default
    skipBlock='false'
    listenAddress=""
    listenPort=""
    hostname=""

    IFS=';' read -ra fields <<<"$serverBlock"
    for field in "${fields[@]}"; do
        if [[ -z $field ]]; then
            continue
        fi

        key="${field%%=*}"
        value="${field#*=}"

        # Ensure leading/trailing spaces don't affect conditional checks on key text
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        # For either listen/server_name values the first word is most important
        value="${value%% *}"
        value="${value#"${value%%[![:space:]]*}"}" # trim leading space
        value="${value%"${value##*[![:space:]]}"}" # trim trailing space

        # Skipping 'default' server blocks (not actual hostnames)
        if [[ $value == "_" ]]; then
            skipBlock='true'
            break
        fi

        # Assign hostname/addr/port
        if [[ $key == listen ]]; then
            listenAddress="${value%:*}"
            listenPort="${value##*:}"

            # Skip non number listen ports
            if ! [[ $listenPort =~ [0-9]+ ]]; then
                skipBlock='true'
                break
            fi

            # Trim IPv6 brackets
            listenAddress="${listenAddress#[}"
            listenAddress="${listenAddress%]}"
        elif [[ $key == server_name ]]; then
            hostname="$value"
        fi
    done

    if [[ $skipBlock == true ]]; then
        continue
    fi

    # Check for missing fields - normal when we exclude listen addresses not for ssl/quic
    if [[ -z $hostname ]] || [[ -z $listenAddress ]] || [[ -z $listenPort ]]; then
        continue
    fi

    # Add this JSON object
    jsonArray+=("$(jq -n \
        --arg h "$hostname" \
        --arg p "$listenPort" \
        --arg a "$listenAddress" \
        '{hostname:$h, port:$p, address:$a}')")
done <<<"$serverBlocks"
jsonOutput="[${jsonArray[0]}"
for ((i = 1; i < ${#jsonArray[@]}; i++)); do
    jsonOutput+=",${jsonArray[i]}"
done
jsonOutput+="]"

# Validate parsing and output
if [[ $jsonSingleLine == true ]]; then
    jq -c '.' <<<"$jsonOutput"
    jqExitCode=$?
else
    jq '.' <<<"$jsonOutput"
    jqExitCode=$?
fi

if [[ $jqExitCode != 0 ]]; then
    echo "Building JSON failed - parsing resulted in invalid syntax" >&2
    exit 1
fi
exit 0
