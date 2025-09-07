#!/bin/bash
# Meant for use with zabbix agent passive checks
# UserParameter=system.proc.net[*],/etc/zabbix/zabbix_agent2.d/procnet.sh $1
#
# Grabs extra information about processes that have entries in /proc/net/packet and /proc/net/raw
# Requires sudo access, like user ALL=(root) NOPASSWD:/usr/bin/bash -c ls -l /proc/\*/fd/\*
#
function procnet() {
  local requestedNet fieldNum line pid

  requestedNet=$1
  if [[ $requestedNet == packet ]]
  then
    fieldNum='9'
  elif [[ $requestedNet == raw ]]
  then
    fieldNum='11'
  fi

  if [[ $(wc -l "/proc/net/$requestedNet" | cut -d" " -f1) -lt 2 ]]
  then
    # No processes have anything in requested net
    return
  fi

  pid=()
  # data retrieved here is single numbers, splitting on words vs newlines is irrelevant
  # shellcheck disable=SC2013
  for line in $(cat "/proc/net/$requestedNet" | sed -r 's/\s+/,/g' | cut -d"," -f$fieldNum | sed '1d')
  do
    mapfile -t pid < <(sudo /usr/bin/bash -c 'ls -l /proc/*/fd/*' 2>/dev/null | grep -oP "(?<=proc\/)[0-9]+(?=\/fd.*\[$line\])")
  done

  ps ef -o user,group,uid,gid,pid,ppid,command:100,tty,s,wchan,stime,etime,c,%mem,vsize,rss,size -p "$(printf '%s,' "${pid[@]}" | grep -oP "([0-9]+,)+.*" | sed 's/,$//')"

  pid=()
}

if [[ -z $1 ]]
then
  echo "The only supported options are packetinfo or rawinfo" >&2
  exit 1
fi

if [[ $1 == "packetinfo" ]]
then
  procnet "packet"
elif [[ $1 == "rawinfo" ]]
then
  procnet "raw"
fi
exit 0
