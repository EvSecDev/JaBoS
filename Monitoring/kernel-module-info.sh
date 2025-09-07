#!/bin/bash
# Meant for use with zabbix agent passive checks
# UserParameter=system.proc.modules[*],/etc/zabbix/zabbix_agent2.d/koinfo.sh $1
# 
# Discovers Kernel Modules that are tainting the kernel or do not have a corresponding file located on disk.
# Discovery excludes module names if every loaded module is unsigned (common with a very custom kernel and upstream repositories)
#

kernelModuleDir="/sys/module"
kernelModuleList="/proc/modules"

# Get list of all the unsigned modules by name
function discover {
  moduletaintedlistSYS=$(grep -v "^$" "$kernelModuleDir"/*/taint)

  modulenames=$(echo -e "$moduletaintedlistSYS" | grep -oP "(?<=module\/).*(?=\/taint)")
  modulenameswithoutunsigned=$(echo -e "$moduletaintedlistSYS" | cut -d":" -f2 | grep -Ev "^E$")
  totalmodules=$(cat "$kernelModuleList" | wc -l)
  totaltaintedmodules=$(echo -e "$moduletaintedlistSYS" | wc -l)

  # ignore unsigned if everything is unsigned
  if [[ -z $modulenameswithoutunsigned ]] && [[ $totalmodules == $totaltaintedmodules ]]
  then
      modulenames=
  fi

  modulelistPROC=$(cat "$kernelModuleList" | cut -d" " -f1)
  for module in $modulelistPROC
  do
    modinfo "$module" &>/dev/null || modulenames+="\n$module"
  done

  echo -ne "$modulenames" | sed -z 's/\n/"},{"module":"/g' | sed 's/^/[{"module":"/' | sed 's/$/"}]/'
}

# Tain codes to tainted reasons
function taintcodelookup() {
  local taintword

  while read -r -n1 taintcode
  do
    case "$taintcode" in
      P)
        taintword+="Proprietary "
        ;;
      F)
        taintword+="Forced-Load "
        ;;
      R)
        taintword+="Forced-Unload "
        ;;
      O)
        taintword+="Out-of-Tree "
        ;;
      E)
        taintword+="Unsigned "
        ;;
      C)
        taintword+="Staging-Load "
        ;;
      K)
        taintword+="Live-Patch "
        ;;
      *)
        echo "Warning unknown taint code $taintcode" >&2
        ;;
    esac
  done < <(echo -n "$1")

  # shellcheck disable=SC2001
  taintword=$(sed 's/ $//' <<<"$taintword")
  echo "$taintword"
}

# Retrieve all module information for a particular module name
function moduleinfo() {
  local modulename taintcode taintword taint srcversion version coresize miscinfo

  modulename=$1
  modinfo "$modulename" &>/dev/null || return
  taintcode="$(cat "$kernelModuleDir/$modulename/taint" 2>/dev/null)"
  taintword=$(taintcodelookup "$taintcode")

  # Build JSON string
  taint="\"Taint\":\"$taintword\""
  srcversion="\"SrcVersion\":\"$(cat "$kernelModuleDir/$modulename/srcversion" 2>/dev/null)\""
  version="\"Version\":\"$(cat "$kernelModuleDir/$modulename/version" 2>/dev/null)\""
  coresize="\"CoreSize\":\"$(cat "$kernelModuleDir/$modulename/coresize" 2>/dev/null)\""
  miscinfo=$(modinfo "$modulename" | \
  grep -Ev "^alias|^srcversion|^version|^depends|^name" \
  | awk '/parm:/ {exit} {print}' \
  | sed -rz "s/(:[0-9A-F]{2}:)\n/\1/g" \
  | sed -r 's/([0-9A-F]{2}:)\s+([0-9A-F]{2})/\1\2/g' \
  | sed -r 's/:\s+/":"/g' \
  | sed 's/^/"/' \
  | sed -r 's/$/"/g' \
  | sed -z 's/\n/,/g' \
  | sed 's/,$//g')

  local jsonoutput
  jsonoutput="{$taint,$version,$srcversion,$coresize,$miscinfo}"
  echo "$jsonoutput"
}

inputarg=$(head -c 64 <<<"$1")
if [[ -n "$inputarg" ]]
then
  jsonoutput=$(moduleinfo "$inputarg")
  echo "$jsonoutput"
elif [[ -z $inputarg ]]
then
  discover
else
  exit 1
fi
exit 0
