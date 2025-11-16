#!/usr/local/bin/bash

rawTables=$(pfctl -vsT 2>/dev/null)
if [[ -z $rawTables ]]; then
    echo "Failed to list tables" >&2
    exit 1
fi

maxTableEntries=$(pfctl -sm 2>/dev/null | grep table-entries | awk '{printf $4}')
if [[ -z $maxTableEntries ]]; then
    echo "Could not determine max table entries" >&2
    exit 1
fi

totalTableEntries=0
while IFS= read -r line; do
    tableName=$(awk '{printf $2}' <<<"$line")
    tableEntryCount=$(pfctl -t "$tableName" -vT show 2>/dev/null | grep -Evc "^\s*Cleared: ")
    totalTableEntries=$((totalTableEntries + tableEntryCount))
done <<<"$rawTables"
tableUsage=$(awk -v used="$totalTableEntries" -v max="$maxTableEntries" 'BEGIN { printf "%.2f", (used/max)*100 }')

echo "$tableUsage"
