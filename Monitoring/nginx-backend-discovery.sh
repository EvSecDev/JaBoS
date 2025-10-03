#!/bin/bash
# Meant for integration with Zabbix for monitoring backend servers from a NGINX reverse proxy
# Extracts the proxy_pass values from all configs
# Produces JSON output like
# [
#   {"frontendName":"host1.mydomain.com","frontendPath":"/","backendURL":"https://host1.int.mydomain.com/"},
#   {"frontendName":"server1.mydomain.com","frontendPath":"/api","backendURL":"https://192.168.20.3:8080/"}
# ]

# Check config validity before continuing
nginxFullConf=$(nginx -T 2>/dev/null) || {
    echo "Error: failed to retrieve nginx config" >&2
    exit 1
}

# Retrieve proxy pass values lines with their line numbers
mapfile -t proxPassLines < <(echo "$nginxFullConf" | grep -n "^\s*proxy_pass ")
if [[ ${#proxPassLines[@]} -eq 0 ]]; then
    echo "Error: failed to retrieve nginx proxy_pass values" >&2
    exit 1
fi

# Retrieve variable list
allVariables=$(echo "$nginxFullConf" |
    grep "^\s*set " |
    tr '\t' ' ' |
    tr -s '[:space:]' |
    sed -e 's/^ //g' -e 's/;//g' |
    cut -d" " -f2,3)

# Create map of variable names to values
declare -A varLookup
if [[ -n $allVariables ]]; then
    while IFS=' ' read -r varName varValue; do
        varLookup["$varName"]="$varValue"
    done <<<"$allVariables"
fi

# Convert nginx output to array for line number referencing
mapfile -t nginxLines <<<"$nginxFullConf"

backends=()

for entry in "${proxPassLines[@]}"; do
    # Extract line number and line content
    line_num=${entry%%:*}
    line="${entry#*:}"
    proxyValue=$(echo "$line" | tr '\t' ' ' | tr -s '[:space:]' | sed -e 's/^ //g' -e 's/;//g' | cut -d" " -f2)

    # Find the closest server name above this line
    frontendName=""
    for ((i = line_num - 2; i >= 0; i--)); do
        currentLine="${nginxLines[i]}"
        currentLine=$(echo "$currentLine" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ $currentLine =~ ^server_name[[:space:]]+(.+) ]]; then
            # Take first server name only
            frontendName=$(echo "${BASH_REMATCH[1]}" | awk '{print $1}' | sed 's/;//g')
            break
        fi
    done

    if [[ -z $frontendName ]]; then
        continue
    fi

    # Find the closest location block above this proxy pass line
    frontendPath=""
    for ((k = line_num - 2; k >= 0; k--)); do
        location_line="${nginxLines[k]}"
        location_line=$(echo "$location_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ $location_line =~ ^location[[:space:]]+([^ \{]+)[[:space:]]*\{? ]]; then
            frontendPath="${BASH_REMATCH[1]}"
            break
        fi
    done

    # Put real variable value in place
    if [[ $proxyValue =~ ^\$ ]] && [[ -n $allVariables ]]; then
        for key in "${!varLookup[@]}"; do
            if [[ "$proxyValue" == *"$key"* ]]; then
                proxyValue="${proxyValue//$key/${varLookup[$key]}}"
                break
            fi
        done
    fi

    # Encode IPv6 brackets for Zabbix compatibility
    proxyValueFormatted="$proxyValue" # Save the unescaped version
    proxyValue=$(sed -e 's/\[/\%5B/g' -e 's/\]/\%5D/g' <<<"$proxyValue")

    backends+=("$frontendName|$frontendPath|$proxyValue|$proxyValueFormatted")
done

# Deduplicate based on backend URL
declare -A seen_backends
sortedBackends=()

for entry in "${backends[@]}"; do
    IFS='|' read -r frontendName frontendPath backendURL <<<"$entry"
    if [[ -z "${seen_backends[$backendURL]}" ]]; then
        seen_backends["$backendURL"]=1
        sortedBackends+=("$frontendName|$frontendPath|$backendURL")
    fi
done

printf '%s\n' "${sortedBackends[@]}" | jq -R -s -c '
  split("\n")[:-1] |
  map(split("|") | {
    frontendName: .[0],
    frontendPath: .[1],
    backendURL: .[2],
    backendURLFormatted: .[3]
  })
'
