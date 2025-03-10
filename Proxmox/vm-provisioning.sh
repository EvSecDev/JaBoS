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
  -c, --vm-config    File path to VM JSON configuration (like '~/TestVM-101-Config.json'
  -u, --url          URL to Proxmox Management (like 'https://192.168.1.10:8006')
  -k, --insecure     Trust any remote HTTPs certificate
"
}

# Use getopt to parse long and short options
PARSEDARGS=$(getopt -o "hc:u:k" -l "help,vm-config:,url:,insecure" -- "$@")
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

alias acurl="$BaseCurlCommand --silent -H \"Authorization: PVEAPIToken=$PVEAPIUser=$PVEAPIToken\" "
shopt -s expand_aliases

# Ensure API variables are present
if [[ -z $PVEAPIURL ]]
then
	>&2 echo "Must specify a URL to the Proxmox Management Interface"
	exit
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
if ! [[ $(echo $PVEAPIURL | grep "^https") ]]
then
	>&2 echo "API URL must use secure transport (HTTPs)"
	exit 1
fi

# Get initial API info
BaseURL="$PVEAPIURL/api2/json"
NodeOverview=$(acurl $BaseURL/nodes)
if [[ $? != 0 ]]
then
	exit 1
fi

# Retrieve Node information
PVENodeName=$(echo $NodeOverview | jq -r ".data[0].node")
PVENodeStatus=$(echo $NodeOverview | jq -r ".data[0].status")

# Ensure Proxmox node is online
if [[ $PVENodeStatus != online ]]
then
	>&2 echo "Node $PVENodeName is offline, unable to continue"
	exit 1
fi

# Retrieve VM configuration
VMConfig=$(jq -c . $JSONConfPath)
if [[ $? != 0 ]]
then
	>&2 echo "Invalid JSON"
	exit 1
fi

# Create VM
CreateVMPost=$(acurl -w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' -X POST $BaseURL/nodes/$PVENodeName/qemu -H "Content-Type: application/json" -d "$VMConfig")
HTTPResponseCode=$(echo $CreateVMPost | jq -r ".markerForCurlHTTPStatusCode" | tail -n1)
if [[ $? != 0 ]]
then
	>&2 echo "Curl command failed. Exit status $?"
	exit 1
fi
if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]
then
	>&2 echo "VM Create Call Failed with HTTP Code $HTTPResponseCode"
	exit 1
fi

exit 0
