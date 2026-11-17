#!/bin/bash
# Measure Google Drive read throughput: one sequential stream against N parallel byte ranges.
#
# This answers the question the whole project turns on. rclone's mount reads a file as a single
# chunked sequential stream; OurSync's design (docs/design.md §6.6) assumes a parallel fetch pool
# beats that on a fast downlink. If parallel ranges are no faster than one stream, the read path has
# nothing to win and this repository should become a pinning and status layer over rclone, or be
# abandoned. That is a measurement, and until it is run everything downstream of it is a guess.
#
# Method notes, because the obvious way to run this would mislead:
#
#   - Samples alternate between methods rather than running all of one then all of the other, so
#     that drift in the link over the run shows up as spread *within* a method instead of as a
#     difference *between* them. A single before-and-after pair cannot tell a change from the
#     machine.
#   - Every sample reads a different region of the file, so no sample is served from a cache that
#     the previous one warmed - neither Google's edge nor the local page cache.
#   - The single-stream and parallel paths use the same binary, the same credentials and the same
#     transport, so concurrency is the only variable.
#   - Throughput is computed from the window size and wall clock, not from rclone's own reported
#     figure, which excludes its startup and token refresh.
#
# Usage:  tools/measure-read-throughput.sh [remote:path]
# Env:    WINDOW_MIB (default 512), FIRST_OFFSET_MIB (default 1024)
set -u

REMOTE="${1:-gdrive:Videos/Film/Prometheus.mkv}"
WINDOW_MIB="${WINDOW_MIB:-512}"
FIRST_OFFSET_MIB="${FIRST_OFFSET_MIB:-1024}"

WINDOW=$((WINDOW_MIB * 1024 * 1024))
FIRST_OFFSET=$((FIRST_OFFSET_MIB * 1024 * 1024))

if ! command -v rclone > /dev/null 2>&1; then
    echo "rclone is not on PATH" >&2
    exit 1
fi

SIZE=$(rclone size "$REMOTE" --json --log-level ERROR 2>/dev/null | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p')
if [ -z "${SIZE:-}" ]; then
    echo "could not read the size of $REMOTE - is the remote configured and the path right?" >&2
    exit 1
fi

# The sweep: three single-stream samples spread through the run give the baseline's own spread,
# and the concurrency ladder is run twice so a win can be told from a lucky sample.
SEQUENCE="1 2 4 8 16 1 2 4 8 16 1 8"

COUNT=$(echo $SEQUENCE | wc -w)
NEEDED=$((FIRST_OFFSET + COUNT * WINDOW))
if [ "$NEEDED" -gt "$SIZE" ]; then
    echo "file is $SIZE bytes; this run needs $NEEDED. Use a larger file or a smaller WINDOW_MIB." >&2
    exit 1
fi

echo "== Drive read throughput"
echo "host:     $(hostname) - $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") - kernel $(uname -r)"
echo "date:     $(date -Is)"
echo "rclone:   $(rclone version | head -1)"
echo "link:     $(for i in $(ls /sys/class/net | grep -v lo); do
                    [ "$(cat /sys/class/net/$i/operstate 2>/dev/null)" = up ] || continue
                    s=$(cat /sys/class/net/$i/speed 2>/dev/null)
                    printf '%s(%s) ' "$i" "${s:-wireless}"
                  done)"
echo "file:     $REMOTE ($SIZE bytes)"
echo "window:   $WINDOW_MIB MiB per sample, first offset $FIRST_OFFSET_MIB MiB"
echo
printf '%-6s %-8s %12s %10s %10s\n' "sample" "streams" "offset(MiB)" "secs" "MB/s"

i=0
for N in $SEQUENCE; do
    OFFSET=$((FIRST_OFFSET + i * WINDOW))
    CHUNK=$((WINDOW / N))

    START=$(date +%s.%N)
    j=0
    while [ "$j" -lt "$N" ]; do
        rclone cat "$REMOTE" \
            --offset $((OFFSET + j * CHUNK)) --count "$CHUNK" \
            --log-level ERROR > /dev/null &
        j=$((j + 1))
    done
    wait
    END=$(date +%s.%N)

    ELAPSED=$(echo "$END - $START" | bc)
    RATE=$(echo "scale=1; $WINDOW / $ELAPSED / 1048576" | bc)
    printf '%-6s %-8s %12s %10.2f %10s\n' \
        "$((i + 1))" "$N" "$((OFFSET / 1048576))" "$ELAPSED" "$RATE"

    i=$((i + 1))
done

echo
echo "Read the single-stream rows against each other first: their spread is the noise floor, and a"
echo "parallel row only means something if it clears it."
