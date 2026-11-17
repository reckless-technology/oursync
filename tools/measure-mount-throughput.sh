#!/bin/bash
# Measure what an rclone mount actually delivers when something reads a large file through it, under
# several VFS configurations, with a control download beside each.
#
# This is the incumbent's real number. The range-fetch benchmark says what the API and the link can
# do; this says how much of that survives rclone's VFS, which is what a user would actually get by
# running `rclone mount` today. The gap between the two - if there is one - is the only thing
# Aqueduct's read path could win, and tuning flags may close it without writing any code at all.
#
# Each configuration is measured from a cold cache, because a warm one measures the local disk.
# The mount is always torn down, including on failure, and the cache directory is emptied between
# configurations with `find -delete` rather than a recursive remove.
#
# Usage:  tools/measure-mount-throughput.sh <remote:path/to/large/file>
# Env:    READ_MIB (default 1024), SKIP_MIB (default 1024)
set -u

TARGET="${1:?usage: measure-mount-throughput.sh <remote:path/to/file>}"
REMOTE="${TARGET%%:*}"
RPATH="${TARGET#*:}"
READ_MIB="${READ_MIB:-1024}"
SKIP_MIB="${SKIP_MIB:-1024}"

MNT="$HOME/aqueduct-measure/mnt"
CACHE="$HOME/aqueduct-measure/cache"
CONTROL_BYTES=52428800
CONTROL_URL="https://speed.cloudflare.com/__down?bytes=$CONTROL_BYTES"

mkdir -p "$MNT" "$CACHE"

unmount() {
    fusermount -u "$MNT" 2>/dev/null || fusermount3 -u "$MNT" 2>/dev/null || true
    # Give the daemon a moment to exit before the next mount claims the same directory.
    for _ in 1 2 3 4 5; do
        mountpoint -q "$MNT" || break
        sleep 1
    done
}
trap unmount EXIT INT TERM

rate() { awk -v b="$1" -v s="$2" 'BEGIN { if (s <= 0) print "n/a"; else printf "%.1f", b / s / 1048576 }'; }

echo "== rclone mount read throughput"
echo "host:    $(hostname) - kernel $(uname -r)"
echo "date:    $(date -Is)"
echo "rclone:  $(rclone version | head -1)"
echo "target:  $TARGET"
echo "read:    $READ_MIB MiB from offset $SKIP_MIB MiB, cold cache each time"
echo

printf '%-42s %9s %10s %12s\n' "configuration" "secs" "MB/s" "control MB/s"

run_config() {
    LABEL="$1"
    shift

    unmount
    find "$CACHE" -mindepth 1 -delete 2>/dev/null || true

    rclone mount "$REMOTE:" "$MNT" --cache-dir "$CACHE" --daemon --log-level ERROR "$@" 2>/dev/null
    for _ in $(seq 1 20); do
        mountpoint -q "$MNT" && break
        sleep 1
    done
    if ! mountpoint -q "$MNT"; then
        printf '%-42s %9s %10s %12s\n' "$LABEL" "-" "MOUNT FAILED" "-"
        return
    fi

    START=$(date +%s.%N)
    dd if="$MNT/$RPATH" of=/dev/null bs=1M count="$READ_MIB" skip="$SKIP_MIB" 2>/dev/null
    END=$(date +%s.%N)

    CSTART=$(date +%s.%N)
    curl -s -o /dev/null --max-time 120 "$CONTROL_URL"
    CEND=$(date +%s.%N)

    SECS=$(awk -v a="$START" -v b="$END" 'BEGIN { printf "%.2f", b - a }')
    CSECS=$(awk -v a="$CSTART" -v b="$CEND" 'BEGIN { printf "%.2f", b - a }')
    printf '%-42s %9s %10s %12s\n' \
        "$LABEL" "$SECS" \
        "$(rate $((READ_MIB * 1048576)) "$SECS")" \
        "$(rate "$CONTROL_BYTES" "$CSECS")"

    unmount
}

# The defaults first, because that is what anyone actually gets by typing `rclone mount`.
run_config "vfs-cache-mode full (defaults)"        --vfs-cache-mode full
run_config "vfs-cache-mode off"                    --vfs-cache-mode off
run_config "full, read-chunk 64M no limit"         --vfs-cache-mode full --vfs-read-chunk-size 64M --vfs-read-chunk-size-limit off
run_config "full, read-ahead 512M"                 --vfs-cache-mode full --vfs-read-ahead 512M
run_config "full, 8 transfers, chunk 64M"          --vfs-cache-mode full --transfers 8 --vfs-read-chunk-size 64M --vfs-read-chunk-size-limit off
run_config "full (defaults) repeat"                --vfs-cache-mode full

find "$CACHE" -mindepth 1 -delete 2>/dev/null || true

echo
echo "The repeat of the first configuration is the noise floor: any difference between the other"
echo "rows that is smaller than the gap between those two has not been demonstrated."
