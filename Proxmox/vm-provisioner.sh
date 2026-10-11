#!/bin/bash
if [ -z "$BASH_VERSION" ]; then
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
  -c, --vm-config <conf.json|{json}>   File path to VM JSON configuration or raw JSON
                                       Optionally provide via stdin
  -i, --iso-file <path>                File path to the installation ISO image (optional)
                                       Will otherwise look for the pre-existing file in the specified storage in config
  -u, --url <https://mgmtaddr>         URL to Proxmox Management
                                       Optionally specify via environment variable 'PVEURL'
  -k, --insecure                       Trust any remote HTTPs certificate
      --show-example-config            Show JSON config template
"
}

configExample='{
  "vmid": 123,
  "start": 1,
  "cpu": "host",
  "name": "TESTVMUEFI",
  "numa": 0,
  "scsihw": "virtio-scsi-pci",
  "efidisk0": "VMStorage:1,efitype=4m,pre-enrolled-keys=1",
  "scsi0": "VMStorage:20,ssd=1",
  "ide0": "local:iso/installos.iso,media=cdrom",
  "agent": "1",
  "cores": 1,
  "sockets": 1,
  "memory": "2048",
  "ostype": "l26",
  "bios": "ovmf",
  "boot": "order=scsi0;ide0",
  "onboot": 1,
  "net0": "virtio=00:50:56:12:34:56,bridge=vmbr0,firewall=0,tag=111"
}'

# Use getopt to parse long and short options
PARSEDARGS=$(getopt -o "hc:i:u:k" -l "help,vm-config:,iso-file:,url:,insecure,show-example-config" -- "$@")
if [[ $? != 0 ]]; then
	exit 1
fi

# Evaluate the options
eval set -- "$PARSEDARGS"
while true; do
	case "$1" in
		-c | --vm-config)
			JSONConf="$2"
			shift 2
			;;
		-i | --iso-file)
			localISOFile="$2"
			shift 2
			;;
		-u | --url)
			PVEAPIURL="$2"
			shift 2
			;;
		-k | --insecure)
			BaseCurlCommand+=" --insecure"
			shift
			;;
		--show-example-config)
			echo "$configExample"
			exit 0
			;;
		-h | --help)
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
alias acurl="$BaseCurlCommand --no-progress-meter -H \"Authorization: PVEAPIToken=$PVEAPIUser=$PVEAPIToken\" "
shopt -s expand_aliases

function stripCommentsFromJSON() {
	local input=$1
	local lines=()
	while IFS= read -r line; do
		if [[ -z $line ]]; then
			continue
		fi

		# Any line starting with comment or spaces/tabs/indents then comment is excluded
		if [[ $line =~ ^[[:space:]]*# ]]; then
			continue
		fi

		lines+=("$line")
	done <<<"$input"
	printf "%s\n" "${lines[@]}"
}

# Evaluate where VM config was provided
if [[ -f $JSONConf ]]; then
	# Read from file
	VMConfig=$(cat "$JSONConf")
elif [[ -n $JSONConf ]] && ! [[ -f $JSONConf ]]; then
	# Read from arg value
	VMConfig="$JSONConf"
elif ! [[ -t 0 ]] && [[ -z $JSONConf ]]; then
	# Read from STDIN
	VMConfig="$(cat)"
else
	echo "VM Config must be provided via file, argument, or stdin" >&2
	exit 1
fi

VMConfig=$(stripCommentsFromJSON "$VMConfig")
VMConfig=$(jq -c '.' <<<"$VMConfig")
if [[ $? != 0 ]] || [[ -z $VMConfig ]]; then
	echo "Invalid JSON syntax in local config" >&2
	exit 1
fi

# Ensure API variables are present
if [[ -z $PVEAPIURL ]]; then
	if [[ -z $PVEURL ]]; then
		echo "Must specify a URL to the Proxmox Management Interface" >&2
		exit 1
	else
		PVEAPIURL=$PVEURL
	fi
fi
if [[ -z $PVEAPIUser ]]; then
	echo "Could not find the API user environment variable" >&2
	exit 1
fi
if [[ -z $PVEAPIToken ]]; then
	echo "Could not find the API token environment variable" >&2
	exit 1
fi

# Ensure supplied URL does not contain trailing slash
PVEAPIURL="${PVEAPIURL%/}"

# Ensure supplied URL is secure
if ! [[ $PVEAPIURL =~ ^https ]]; then
	echo "API URL must use secure transport (HTTPs)" >&2
	exit 1
fi

VMID=$(jq -r .vmid <<<"$VMConfig")

echo "[*] Checking Proxmox Node Status..."

BaseURL="$PVEAPIURL/api2/json"

# Get initial API info
NodeOverview=$(acurl "$BaseURL/nodes" 2>&1)
curlExitCode=$?
if [[ $curlExitCode != 0 ]] || [[ -z $NodeOverview ]]; then
	if [[ $curlExitCode == 60 ]]; then
		echo "Curl failed at SSL certificafte verification, maybe you need to use -k"
	fi
	echo "Failed curl command to Proxmox status API: Exit status $curlExitCode: $NodeOverview" >&2
	exit 1
fi

# Retrieve Node information
PVENodeName=$(jq -r ".data[0].node" <<<"$NodeOverview")
PVENodeStatus=$(jq -r ".data[0].status" <<<"$NodeOverview")

# Ensure Proxmox node is online
if [[ $PVENodeStatus != online ]]; then
	echo "Node '$PVENodeName' is offline, unable to continue" >&2
	exit 1
fi

echo "[+] Proxmox Node '$PVENodeName' status is '$PVENodeStatus'"

if [[ -n $localISOFile ]]; then
	remoteISOLocation=$(jq -r ".ide0" <<<"$VMConfig")

	storageName="${remoteISOLocation%%:*}"
	if [[ -z $storageName ]]; then
		echo "Could not extract PVE storage location from configuration '$remoteISOLocation'" >&2
		exit 1
	fi

	remoteISOPath="${remoteISOLocation#*:}"
	remoteISOPath="${remoteISOPath%%,*}"
	tgtISOName="${remoteISOPath##*/}"
	if [[ -z $tgtISOName ]]; then
		echo "Could not extract ISO name from configuration location '$remoteISOLocation'" >&2
		exit 1
	fi

	echo "[*] Uploading local installation image '$localISOFile' to store '$storageName' under name '$tgtISOName'"

	# Copy to target file name since curl needs both local and remote to be the same file name (for the config to also work)
	cp "$localISOFile" ./"$tgtISOName"
	if [[ $? != 0 ]]; then
		echo "Failed to rename $localISOFile to $tgtISOName for upload" >&2
		exit 1
	fi

	hash=$(sha256sum "$tgtISOName")
	hash=${hash%% *}

	UploadPOST=$(acurl \
		-w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
		-X POST \
		-F 'content=iso' \
		-F 'checksum-algorithm=sha256' \
		-F "checksum=$hash" \
		-F "filename=@$tgtISOName" \
		"$BaseURL/nodes/$PVENodeName/storage/$storageName/upload" 2>&1)
	curlExitCode=$?
	if [[ $curlExitCode != 0 ]]; then
		echo "Curl command failed. Exit status $curlExitCode: $UploadPOST" >&2
		exit 1
	fi

	HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$UploadPOST" | tail -n1)
	if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]; then
		pveErrorMessage=$(jq -r '.message | select(.)' <<<"$UploadPOST")
		pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$UploadPOST")

		echo "ISO upload call failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails" >&2
		exit 1
	fi

	dataUPID=$(jq -r '. | select(has("data")) | .data' <<<"$UploadPOST")
	if [[ -z $dataUPID ]]; then
		echo "Upload process did not return a UPID, cannot continue (cannot check status)" >&2
		exit 1
	fi

	safeUPID=$(jq -Rr @uri <<<"$dataUPID")
	if [[ $? != 0 ]] || [[ -z $dataUPID ]]; then
		echo "Failed to encode UPID as URL-safe string" >&2
		exit 1
	fi

	echo "[+] Upload complete"
	echo "[*] Checking status of internal copy..."

	maxAttempts=5
	maxTotalTime=30
	totalTime=0
	finalSuccess=false
	for ((attempt = 1; attempt <= maxAttempts; attempt++)); do
		# Calculate backoff time (exponential backoff)
		backoff=$((2 ** (attempt - 1)))

		# Check if adding the backoff time exceeds the max total time
		if ((totalTime + backoff > maxTotalTime)); then
			break
		fi

		UploadStatus=$(acurl \
			-w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
			-X GET \
			"$BaseURL/nodes/$PVENodeName/tasks/$safeUPID/status" 2>&1)
		curlExitCode=$?
		if [[ $curlExitCode != 0 ]]; then
			echo "Curl command failed. Exit status $curlExitCode: $UploadStatus" >&2
			exit 1
		fi

		HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$UploadStatus" | tail -n1)
		if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]; then
			pveErrorMessage=$(jq -r '.message | select(.)' <<<"$UploadStatus")
			pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$UploadStatus")

			echo "ISO Copy job status call failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails" >&2
			exit 1
		fi

		copyStatus=$(jq -r '. | select(has("data")) | .data.status' <<<"$UploadStatus")

		if [[ -n $copyStatus ]] && [[ $copyStatus == "stopped" ]]; then
			copyExitStatus=$(jq -r '. | select(has("data")) | .data.exitstatus' <<<"$UploadStatus")
			if [[ -n $copyExitStatus ]] && [[ $copyExitStatus == "OK" ]]; then
				echo "[*]   Copy job status is '$copyStatus' with exit status '$copyExitStatus'"
				finalSuccess=true
				break
			else
				echo "[-]   Copy job status is '$copyStatus' with exit status '$copyExitStatus'"
				break
			fi
		fi

		echo "[*]   Copy job status is '$copyStatus', waiting and then rechecking..."
		sleep $backoff
		totalTime=$((totalTime + backoff))
	done
	if [[ $finalSuccess != true ]]; then
		echo "[-] Upload did not successfully copy to internal store after $maxTotalTime seconds." >&2
		exit 1
	fi

	echo "[+] Successfully uploaded installation image $localISOFile"
	rm ./"$tgtISOName"
fi

echo "[*] Requesting VM $VMID creation"

# Create VM
CreateVMPost=$(acurl \
	-w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
	-X POST \
	"$BaseURL/nodes/$PVENodeName/qemu" \
	-H "Content-Type: application/json" \
	-d "$VMConfig" 2>&1)
curlExitCode=$?
if [[ $curlExitCode != 0 ]]; then
	echo "Curl command failed. Exit status $curlExitCode: $CreateVMPost" >&2
	exit 1
fi

HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$CreateVMPost" | tail -n1)
if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]; then
	pveErrorMessage=$(jq -r '.message | select(.)' <<<"$CreateVMPost")
	pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$CreateVMPost")

	echo "VM Create Call Failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails" >&2
	exit 1
fi

# Wait for proxmox post-vm-creation validations before checking
sleep 2

# Validate VM created
StatusVMGet=$(acurl \
	-w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
	-X GET \
	"$BaseURL/nodes/$PVENodeName/qemu/$VMID/status/current" 2>&1)
curlExitCode=$?
if [[ $curlExitCode != 0 ]]; then
	echo "Curl command failed. Exit status $curlExitCode: $StatusVMGet" >&2
	exit 1
fi

HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$StatusVMGet" | tail -n1)
if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]; then
	pveErrorMessage=$(jq -r '.message | select(.)' <<<"$StatusVMGet")
	pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$StatusVMGet")

	echo "VM Status Call Failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails" >&2

	# try and get more detailed errors about failures
	VMTaskErrors=$(acurl \
		-w '{"markerForCurlHTTPStatusCode":"%{http_code}"}' \
		-X GET \
		"$BaseURL/nodes/$PVENodeName/qemu/$VMID/tasks" \
		-H "Content-Type: application/json" \
		-d '{"errors":true,"vmid":'"$VMID"'}' 2>&1)
	curlExitCode=$?
	if [[ $curlExitCode != 0 ]]; then
		echo "Curl command failed. Exit status $curlExitCode: $VMTaskErrors" >&2
		exit 1
	fi
	HTTPResponseCode=$(jq -r ".markerForCurlHTTPStatusCode" <<<"$CreateVMPost" | tail -n1)
	if [[ -n $HTTPResponseCode ]] && [[ $HTTPResponseCode != 200 ]]; then
		pveErrorMessage=$(jq -r '.message | select(.)' <<<"$CreateVMPost")
		pveErrorDetails=$(jq -c -r '.errors | select(.)' <<<"$CreateVMPost")

		echo "VM Tasks List Call Failed with HTTP Code $HTTPResponseCode and error: $pveErrorMessage $pveErrorDetails" >&2
		exit 1
	fi

	VMFailedTasks=$(jq -r '.' <<<"$StatusVMGet")
	if [[ -n $VMFailedTasks ]]; then
		echo -e "[-] Found failed tasks for VM $VMID:\n$VMFailedTasks"
	fi

	exit 1
fi

newVMStatus=$(jq -c -r '.data.status | select(.)' <<<"$StatusVMGet")
if [[ -z $newVMStatus ]]; then
	echo "[-] Unable to determine newly created VM status" >&2
	exit 1
fi

if [[ -n $localISOFile ]]; then
	rm "$localISOFile"
fi

echo "[+] VM $VMID created and is currently in status $newVMStatus"

shouldStart=$(jq -r '.start // 0' <<<"$VMConfig")
if [[ $shouldStart -eq 1 ]]; then
	echo "[*] Waiting for VM $VMID to reach running status..."

	maxTotalWait=1800
	pollInterval=5
	elapsedWait=0
	vmRunning=false
	while ((elapsedWait < maxTotalWait)); do
		vmStatusGet=$(acurl -s "$BaseURL/nodes/$PVENodeName/qemu/$VMID/status/current" 2>&1)
		curlExitCode=$?
		if [[ $curlExitCode == 0 ]]; then
			currentStatus=$(jq -r '.data.status // empty' <<<"$vmStatusGet")
			if [[ $currentStatus == "running" ]]; then
				vmRunning=true
				break
			fi
		fi
		sleep $pollInterval
		elapsedWait=$((elapsedWait + pollInterval))
	done

	if [[ $vmRunning != true ]]; then
		echo "[-] VM $VMID did not reach running status within $maxTotalWait seconds" >&2
		exit 1
	fi

	echo "[+] VM $VMID is running, waiting for OS installation to complete..."

	waitStart=$(date +%s)
	elapsedWait=0
	installDone=false
	while ((elapsedWait < maxTotalWait)); do
		agentPing=$(acurl -s -o /dev/null -w "%{http_code}" -X POST "$BaseURL/nodes/$PVENodeName/qemu/$VMID/agent/ping" 2>&1)
		# Not checking exit code, current bug in curl trying to truncate the output file (Failing for dev null, gh #17371)
		if [[ $agentPing == "200" ]]; then
			installDone=true
			break
		fi
		sleep $pollInterval
		elapsedWait=$((elapsedWait + pollInterval))
		if ((elapsedWait > 0 && elapsedWait % 60 == 0)); then
			echo "[*] VM $VMID still waiting for guest agent (${elapsedWait}s elapsed. HTTP status: $agentPing)"
		fi
	done

	if [[ $installDone != true ]]; then
		echo "[-] VM $VMID guest agent did not respond within $maxTotalWait seconds" >&2
		exit 1
	fi

	installDuration=$(($(date +%s) - waitStart))
	echo "[+] VM $VMID installation complete, guest agent responding after ${installDuration}s"
else
	echo "[*] VM start was not requested (start=0 in config), skipping install wait"
fi

exit 0
