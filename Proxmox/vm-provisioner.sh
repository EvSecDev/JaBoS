#!/bin/bash
if [ -z "$BASH_VERSION" ]
then
        echo "This script must be run in BASH."
        exit 1
fi

## Required commands
command -v curl >/dev/null || exit 1
command -v jq >/dev/null || exit 1

## CONSTANTS
BaseCurlCommand="curl"

## Help Menu
function usage {
        echo "Usage of $0

This script requires authentication using environment variables
  export PVEAPIUser='root@pam!main'
  export PVEAPIToken='deabbeef-deadbeef-deadbeef'

Options:
  -c, --vm-config <path/to/conf.json>  File path to VM JSON configuration
  -u, --url <https://mgmtaddr>         URL to Proxmox Management
                                       Optionally specify via environment variable 'PVEURL'
  -k, --insecure                       Trust any remote HTTPs certificate
"
}

# Use getopt to parse long and short options
PARSEDARGS=$(getopt -o "hc:u:i:k" -l "help,vm-config:,url:,install-iso:,insecure" -- "$@")
if [[ $? != 0 ]]
then
    exit 1
fi

# Evaluate the options
eval set -- "$PARSEDARGS"
while true; do
    case "$1" in
        -c|--vm-config)
            JSONConfPath="$2"
            shift 2
            ;;
        -u|--url)
            PVEAPIURL="$2"
            shift 2
            ;;
        -k|--insecure)
            BaseCurlCommand+=" --insecure"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option $1"
            exit 1
            ;;
    esac
done

# shellcheck disable=SC2139
alias acurl="$BaseCurlCommand --silent -H \"Authorization: PVEAPIToken=$PVEAPIUser=$PVEAPIToken\" "
shopt -s expand_aliases

# Ensure API variables are present
if [[ -z $PVEAPIURL ]]
then
    if [[ -z $PVEURL ]]
    then
	    >&2 echo "Must specify a URL to the Proxmox Management Interface"
	    exit 1
    else
        PVEAPIURL=$PVEURL
    fi
fi
if [[ -z $PVEAPIUser ]]
then
	>&2 echo "Could not find the API user environment variable"
	exit 1
fi
if [[ -z $PVEAPIToken ]]
then
        >&2 echo "Could not find the API token environment variable"
        exit 1
fi

# Ensure supplied URL does not contain trailing slash
PVEAPIURL="${PVEAPIURL%/}"

# Ensure supplied URL is secure
if ! [[ $PVEAPIURL =~ ^https ]]
then
	>&2 echo "API URL must use secure transport (HTTPs)"
	exit 1
fi

# Validate input config
if ! [[ -f $JSONConfPath ]]
then
    >&2 echo "No config file found at path \"$JSONConfPath\""
    exit 1
fi

# Retrieve VM configuration
VMConfig=$(jq -c . "$JSONConfPath")
if [[ $? != 0 ]] || [[ -z $VMConfig ]]
then
	>&2 echo "Invalid JSON syntax in local config file \"$VMConfig\""
	exit 1
fi

VMID=$(jq -r .vmid <<<"$VMConfig")

echo "[*] Checking Proxmox Node Status..."

# Get initial API info
BaseURL="$PVEAPIURL/api2/json"
NodeOverview=$(acurl "$BaseURL/nodes")
if [[ $? != 0 ]]
then
	exit 1
fi

# Retrieve Node information
PVENodeName=$(jq -r ".data[0].node" <<<"$NodeOverview")
PVENodeStatus=$(jq -r ".data[0].status" <<<"$NodeOverview")

# Ensure Proxmox node is online
if [[ $PVENodeStatus != online ]]
then
	>&2 echo "Node $PVENodeName is offline, unable to continue"
	exit 1
fi

echo "[*] Requesting VM creation with config file \"$JSONConfPath\""

# Create VM
CreateVMPost=$(acurl \
    -w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
    -X POST \
    "$BaseURL/nodes/$PVENodeName/qemu" \
    -H "Content-Type: application/json" \
    -d "$VMConfig")
curlExitCode=$?
if [[ $curlExitCode != 0 ]]
then
	>&2 echo "Curl command failed. Exit status $curlExitCode"
	exit 1
fi

HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$CreateVMPost" | tail -n1)
if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]
then
    pveErrorMessage=$(jq -r '.message | select(.)' <<<"$CreateVMPost")
    pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$CreateVMPost")

	>&2 echo "VM Create Call Failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails"
	exit 1
fi

# Wait for proxmox post-vm-creation validations before checking
sleep 2

# Validate VM created
StatusVMGet=$(acurl \
    -w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
    -X GET \
    "$BaseURL/nodes/$PVENodeName/qemu/$VMID/status/current")
curlExitCode=$?
if [[ $curlExitCode != 0 ]]
then
	>&2 echo "Curl command failed. Exit status $curlExitCode"
	exit 1
fi

HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$StatusVMGet" | tail -n1)
if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]
then
    pveErrorMessage=$(jq -r '.message | select(.)' <<<"$StatusVMGet")
    pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$StatusVMGet")

	>&2 echo "VM Status Call Failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails"

    # try and get more detailed errors about failures
    VMTaskErrors=$(acurl \
        -w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
        -X GET \
        "$BaseURL/nodes/$PVENodeName/qemu/$VMID/tasks" \
        -H "Content-Type: application/json" \
        -d '{"errors":true,"vmid":'"$VMID"'}')
    curlExitCode=$?
    if [[ $curlExitCode != 0 ]]
    then
    	>&2 echo "Curl command failed. Exit status $curlExitCode"
    	exit 1
    fi
    HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$CreateVMPost" | tail -n1)
    if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]
    then
        pveErrorMessage=$(jq -r '.message | select(.)' <<<"$CreateVMPost")
        pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$CreateVMPost")

    	>&2 echo "VM Tasks List Call Failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails"
    	exit 1
    fi

    VMFailedTasks=$(jq -r '.' <<<"$StatusVMGet")
    if [[ -n $VMFailedTasks ]]
    then
        echo -e "[-] Found failed tasks for VM $VMID:\n$VMFailedTasks"
    fi

	exit 1
fi

newVMStatus=$(jq -c -r '.data.status | select(.)' <<<"$StatusVMGet")
if [[ -z $newVMStatus ]]
then
    echo "[-] Unable to determine newly created VM status" >&2
    exit 1
fi

echo "[+] VM $VMID created and is currently in status $newVMStatus"

exit 0
