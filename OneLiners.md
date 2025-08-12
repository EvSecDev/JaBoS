# Useful Commands

## Openssl

```bash
openssl req -x509 -nodes -days 3365 -subj "/C=US/ST=StateFullName/L=CityFullName/O=/CN=localhost/emailAddress=admin@example.com" \
-newkey ec -pkeyopt ec_paramgen_curve:secp521r1 \
-keyout selfsigned.key -out selfsigned.crt
```

```bash
openssl req -x509 -nodes -days 3365 -subj "/C=US/ST=StateFullName/L=CityFullName/O=/CN=localhost/emailAddress=admin@example.com" \
-newkey ed25519 -keyout selfsigned.key -out selfsigned.crt
```

```bash
openssl req -x509 -nodes -days 3365 -newkey rsa:4096 -keyout /etc/ssl/private/nginx-selfsigned.key -out /etc/ssl/certs/nginx-selfsigned.crt
```

## ZFS Pasta

List available disks by their unique ID for use with ZFS commands:

`ls -l /dev/disk/by-id/ | egrep -v "\-part"`

If ZFS spare becomes in use but original disk also reappears, then relegate the spare disk back to a spare with this command:

`zpool detach POOLNAME DISK-ID`

## LED Control

Binary ledctl is part of ledmon package:

`apt install ledmon`

Turn Indicator LED of Drive on (Blinking Red):

`ledctl locate=/dev/disk/by-id/[drive-id]`

OR

`ledctl locate=/dev/sda`

To turn off:

`ledctl locate_off=/dev/sda`

Tested to work on LSI HBA (in Supermicro chassis with backplane)

## DVD Drive

Generate ISO image to burn:

`mkisofs -o archive.iso /home/admin/Downloads/video1.MP4 /home/admin/Downloads/video2.MP4`

Burn Image to Disc:

`growisofs -dvd-compat -speed=8 -Z /dev/sr0=/home/admin/Downloads/archive.iso`

Drive can be mounted normally to access ISO contents.

## IPMI MISC

Lower fan thresholds locally (requires ipmitool package):

`ipmitool -U ADMIN sensor thresh FAN1 lower 150 225 300`

Good Info: <https://www.thomas-krenn.com/en/wiki/IPMI_Basics>

## Proxmox

`qm importdisk VM-ID /tmp/VM.whatever DESTINATION-DISK`

## SSH Tunnels

*Must enable `gateway ports = yes` in sshd_config*

`ssh -4 -R 0.0.0.0:LISTENPORT:IP-TOCONNECTTO:PORTTOCONNECTTO user@IPADDR`

`ssh -LLISTENPORTLOCAL:IP-TOCONNECTTO:PORTTCONNECTTO -N user@IPADDR`

## Shortcuts and Misc

Native CPU Stress Testing:

```bash
for i in $(seq $(getconf _NPROCESSORS_ONLN)); do yes > /dev/null & done
killall yes
```

Monitor Live CPU Clock Freq:

`watch -n.1 "grep \"^[c]pu MHz\" /proc/cpuinfo"`

Extract Binaries and Libraries from DEB files:

`ar x {file.deb}`

IPMI First to query 3rd party fan control; Second line to disable 3rd party fan adjustment

```bash
ipmitool raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00
ipmitool raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00
```
