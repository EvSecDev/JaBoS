#!/bin/bash
# Scans entire filesystem looking for symbolic links that point to a file that does not exist
# Attempts to throttle itself, best run on cron at night once a week.
# Cron example for once a week at 4:10am:
# 10 4    */7 * * root    /bin/bash /usr/local/bin/dangling_link_detector.sh

# Directories to skip (pseudo / noisy / slow / pointless)
EXCLUDES=(
	/proc
	/sys
	/dev
	/run
	/tmp
	/var/tmp
	/mnt
)

# Build prune expression for find
PRUNE_EXPR=()
for dir in "${EXCLUDES[@]}"; do
	PRUNE_EXPR+=(-path "$dir" -prune -o)
done

logTag="Dangling-SymLink-Finder"

logger -p info -t$logTag Starting dangling symlink scan...

# Lower CPU+IO priority
logger -p info -t$logTag Setting scan process priority to 10
renice 10 $$
if [[ $? != 0 ]]; then
	logger -t$logTag Failed setting scan process priority
	exit 1
fi

logger -p info -t$logTag Setting scan scheduling to lowest priority best-effort
ionice -c2 -n7 -p $$
if [[ $? != 0 ]]; then
	logger -t$logTag Failed setting scan scheduling priority
	exit 1
fi

# Walk filesystem
logger -p info -t$logTag Beginning Filesystem Scan
find / "${PRUNE_EXPR[@]}" -type l -print0 2>/dev/null \
	| while IFS= read -r -d '' link; do
		# Check if symlink target exists
		if [[ ! -e "$link" ]]; then
			logger -p alert -t$logTag WARNING: Dangling symlink found: "$link"
		fi

		# Small sleep to reduce CPU impact
		sleep 0.01
	done
logger -p info -t$logTag Filesystem Scan Complete
