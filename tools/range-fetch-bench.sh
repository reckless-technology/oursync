#!/bin/bash
# Fetch a Drive file with N concurrent HTTP range requests and report the throughput, alongside a
# non-Google control download taken in the same conditions.
#
# This is the measurement the project turns on, stated as plainly as it can be: OurSync's read path
# (docs/design.md §6.6) is a parallel fetch pool, justified by the claim that one stream does not
# fill a fast link. rclone's mount reads a file as a single chunked sequential stream. So if N
# concurrent ranges are no faster than one, the read path has nothing to win.
#
# Why curl rather than rclone:
#
#   - It is a faithful model of what OurSync would do - the same endpoint, the same Range headers,
#     the same number of sockets - rather than a proxy for it through another tool's VFS.
#   - It needs nothing installed on the machine under test, which matters because the only wired
#     gigabit machine here is a CI runner.
#   - It takes a bare access token, which expires in an hour, instead of a refresh token that would
#     have to be left behind on that machine.
#
# The control matters as much as the measurement. A parallel row only means something relative to
# what the link could carry at that moment, so every sample is followed by a fixed download from a
# non-Google CDN. If the control moves with the samples, the link is the story and Drive is not.
#
# Usage:   tools/range-fetch-bench.sh <drive-file-id>
# Env:     AQ_TOKEN_FILE   file holding a bare OAuth access token (default ~/.config/oursync/access_token)
#          WINDOW_MIB      bytes per sample, split across the streams (default 512)
#          FIRST_OFFSET_MIB  where in the file to start (default 1024)
#          CONCURRENCY     stream counts to try, in order (default "1 2 4 8 16 1 2 4 8 16 1 8")
# shellcheck source=/dev/null
set -u

FILE_ID="${1:?usage: range-fetch-bench.sh <drive-file-id>}"
TOKEN_FILE="${AQ_TOKEN_FILE:-$HOME/.config/oursync/access_token}"
WINDOW_MIB="${WINDOW_MIB:-512}"
FIRST_OFFSET_MIB="${FIRST_OFFSET_MIB:-1024}"
CONCURRENCY="${CONCURRENCY:-1 2 4 8 16 1 2 4 8 16 1 8}"

CONTROL_BYTES=52428800
CONTROL_URL="https://speed.cloudflare.com/__down?bytes=$CONTROL_BYTES"

if [ ! -r "$TOKEN_FILE" ]; then
    echo "no access token at $TOKEN_FILE" >&2
    exit 1
fi
TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")

# A busy machine is the commonest way to measure something other than what you meant to, and it
# leaves no trace in the output. On 2026-11-17 a whole wired run was taken on reckless-ci-lin-0
# while it ran another session's CI at a load average of 13 on 16 cores; the machine had been
# checked once, half an hour earlier, when it was idle. So the check belongs in the tool, it runs
# immediately before the first sample, and the load is recorded beside every row.
#
# MAX_LOAD defaults to 2.0. FORCE=1 runs anyway, and the rows are still marked.
MAX_LOAD="${MAX_LOAD:-2.0}"

busy_reason() {
    if pgrep -x fastchess > /dev/null 2>&1; then
        echo "a chess match is running (fastchess)"
        return
    fi
    if pgrep -x Runner.Worker > /dev/null 2>&1; then
        echo "a CI job is running (Runner.Worker)"
        return
    fi
    local l
    l=$(awk '{print $1}' /proc/loadavg)
    if awk -v l="$l" -v m="$MAX_LOAD" 'BEGIN { exit !(l > m) }'; then
        echo "load average is $l, above MAX_LOAD=$MAX_LOAD"
        return
    fi
    echo ""
}

REASON=$(busy_reason)
if [ -n "$REASON" ]; then
    echo "refusing to measure on a busy machine: $REASON" >&2
    echo "wait for it to go idle, or set FORCE=1 to measure anyway (rows will be marked)." >&2
    [ "${FORCE:-0}" = 1 ] || exit 2
fi

WINDOW=$((WINDOW_MIB * 1024 * 1024))
FIRST_OFFSET=$((FIRST_OFFSET_MIB * 1024 * 1024))
URL="https://www.googleapis.com/drive/v3/files/$FILE_ID?alt=media&supportsAllDrives=true"

# Fail early and loudly rather than reporting a fast zero-byte transfer as throughput.
PROBE=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' \
    -H "Authorization: Bearer $TOKEN" -H "Range: bytes=0-1048575" "$URL")
# Deliberate word splitting: the probe is "code bytes" and both halves are wanted.
# shellcheck disable=SC2086
set -- $PROBE
if [ "$1" != "206" ] && [ "$1" != "200" ]; then
    echo "probe failed: HTTP $1 (is the token fresh, and the file id right?)" >&2
    exit 1
fi
if [ "$2" -lt 1048576 ]; then
    echo "probe returned only $2 bytes - the server is not honouring Range" >&2
    exit 1
fi

rate() { awk -v b="$1" -v s="$2" 'BEGIN { if (s <= 0) print "n/a"; else printf "%.1f", b / s / 1048576 }'; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

# The control must prove it transferred what it asked for. speed.cloudflare.com answers 403 with a
# one-byte body when it is unhappy - above its size cap, or under repeated requests - and dividing
# that by a near-zero time reads as hundreds of MB/s on a link that cannot carry it. A transfer that
# did not happen must never read as infinite speed, so a short body is reported as "failed", not as
# a number.
control() {
    local start end got
    start=$(date +%s.%N)
    got=$(curl -s -o /dev/null -w '%{size_download}' --max-time 120 "$CONTROL_URL")
    end=$(date +%s.%N)
    if [ "${got:-0}" -lt "$CONTROL_BYTES" ]; then
        echo "failed"
    else
        rate "$CONTROL_BYTES" "$(elapsed "$start" "$end")"
    fi
}

echo "== Drive range-fetch throughput"
echo "host:     $(hostname) - $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") - kernel $(uname -r)"
echo "date:     $(date -Is)"
echo "link:     $(for d in /sys/class/net/*; do i=${d##*/}; [ "$i" = lo ] && continue
                    [ "$(cat "$d/operstate" 2>/dev/null)" = up ] || continue
                    s=$(cat "$d/speed" 2>/dev/null)
                    case "$s" in ''|-1) s=wireless ;; *) s="${s}Mb" ;; esac
                    printf '%s(%s) ' "$i" "$s"
                  done)"
echo "file:     $FILE_ID"
echo "window:   $WINDOW_MIB MiB per sample, first offset $FIRST_OFFSET_MIB MiB"
echo "control:  $((CONTROL_BYTES / 1048576)) MiB from speed.cloudflare.com after every sample"
echo
printf '%-7s %-8s %12s %9s %10s %12s %6s %s\n' \
    "sample" "streams" "offset(MiB)" "secs" "MB/s" "control MB/s" "load" "busy"

i=0
for N in $CONCURRENCY; do
    OFFSET=$((FIRST_OFFSET + i * WINDOW))
    CHUNK=$((WINDOW / N))

    SAMPLE_BUSY=$(busy_reason)
    LOAD=$(awk '{print $1}' /proc/loadavg)

    START=$(date +%s.%N)
    j=0
    while [ "$j" -lt "$N" ]; do
        S=$((OFFSET + j * CHUNK))
        E=$((S + CHUNK - 1))
        curl -s -o /dev/null \
            -H "Authorization: Bearer $TOKEN" -H "Range: bytes=$S-$E" "$URL" &
        j=$((j + 1))
    done
    wait
    END=$(date +%s.%N)

    CONTROL_RATE=$(control)

    SECS=$(elapsed "$START" "$END")
    printf '%-7s %-8s %12s %9s %10s %12s %6s %s\n' \
        "$((i + 1))" "$N" "$((OFFSET / 1048576))" \
        "$SECS" "$(rate "$WINDOW" "$SECS")" "$CONTROL_RATE" \
        "$LOAD" "${SAMPLE_BUSY:+* $SAMPLE_BUSY}"

    i=$((i + 1))
done

echo
echo "Any row with a * in the last column was taken on a machine that was doing something else, and"
echo "is not evidence of anything. Do not average it together with the clean rows: a contaminated"
echo "repeat that widens the spread will make a real effect look like noise."
echo
echo "Where there is an external control, compare each sample against the control beside it rather"
echo "than against the other samples. Where the control reads 'failed' it transferred nothing and"
echo "says nothing; the single-against-parallel comparison does not depend on it."
