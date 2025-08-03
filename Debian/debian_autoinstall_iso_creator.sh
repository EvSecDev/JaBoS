#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -i <input.iso> -o <output.iso> -p <preseed.cfg>

Arguments:
  -i INPUT_ISO       Path to original Debian netinst ISO image
  -o OUTPUT_ISO      Path to output customized ISO image
  -p PRESEED_FILE    Path to preseed file to embed in ISO
  -h                 Show this help message and exit

Requirements:
  - xorriso
  - 7z (from p7zip-full)
  - isohybrid (from syslinux-utils)
EOF
}

check_dependencies() {
  local deps=(xorriso 7z isohybrid)
  local missing=()
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if ((${#missing[@]})); then
    echo "[-] ERROR: Missing required commands: ${missing[*]}" >&2
    echo "Please install them and retry." >&2
    exit 1
  fi
}

INPUT_ISO=""
OUTPUT_ISO=""
PRESEED_FILE=""

while getopts "i:o:p:h" opt; do
  case $opt in
    i) INPUT_ISO=$OPTARG ;;
    o) OUTPUT_ISO=$OPTARG ;;
    p) PRESEED_FILE=$OPTARG ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_ISO" || -z "$OUTPUT_ISO" || -z "$PRESEED_FILE" ]]; then
  echo "[-] ERROR: Missing required arguments." >&2
  usage
  exit 1
fi

INPUT_ISO=$(readlink -f "$INPUT_ISO")
OUTPUT_ISO=$(readlink -f "$OUTPUT_ISO")
PRESEED_FILE=$(readlink -f "$PRESEED_FILE")

if ! [[ -f $INPUT_ISO ]]
then
  echo "[-] ERROR: Input ISO file '$INPUT_ISO' does not exist." >&2
  exit 1
fi

if [[ -f $OUTPUT_ISO ]]
then
  echo "[-] ERROR: Output file already exists at \"$OUTPUT_ISO\"" >&2
  exit 1
fi

if [[ ! -f $PRESEED_FILE ]]
then
  echo "[-] ERROR: Preseed file '$PRESEED_FILE' does not exist." >&2
  exit 1
fi

check_dependencies

echo "[+] Creating new ISO from \"$INPUT_ISO\" using preseed file \"$PRESEED_FILE\""

WORKDIR=$(mktemp -d)
echo "[+] Working in temporary directory: $WORKDIR"

cleanup() {
  echo "[+] Cleaning up..."
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

cd "$WORKDIR"

echo "[+] Extracting ISO contents to temp directory"

7z x "$INPUT_ISO"

echo "[+] Copying preseed file into ISO root"

cp "$PRESEED_FILE" ./preseed.cfg
if ! [[ -f ./preseed.cfg ]]
then
  echo "[-] Failed to copy preseed to temp directory" >&2
  exit 1
fi

GRUB_CFG="$WORKDIR/boot/grub/grub.cfg"

if [[ ! -f "$GRUB_CFG" ]]; then
  echo "[-] ERROR: GRUB config not found in ISO."
  exit 1
fi

echo "[+] Modifying GRUB config to boot directly into automatic installation"

# Blow away the entire grub menu and use preseed autoinstall
cat > "$GRUB_CFG" <<EOF
set default=0
set timeout=0

menuentry "Unattended Installation" {
    linux /install.amd/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed.cfg quiet ---
    initrd /install.amd/initrd.gz
}
EOF

echo "[+] Rebuilding ISO with new additions into \"$OUTPUT_ISO\""

xorriso -as mkisofs \
  -r -V "Custom Debian Install" \
  -o "$OUTPUT_ISO" \
  -J -joliet-long \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  .
if [[ $? != 0 ]]
then
  echo "[-] ERROR: iso creation failed" >&2
  exit 1
fi

newISOhash=$(sha256sum "$OUTPUT_ISO" | awk '{print $1}')

echo "[+] Successfully built new ISO."
echo "    <$OUTPUT_ISO> - Hash: $newISOhash"
cleanup
exit 0
