#!/bin/bash
# Fetch a Drive file with N concurrent HTTP range requests and report the throughput, alongside a
# non-Google control download taken in the same conditions.
#
# This is the measurement the project turns on, stated as plainly as it can be: Aqueduct's read path
# (docs/design.md §6.6) is a parallel fetch pool, justified by the claim that one stream does not
# fill a fast link. rclone's mount reads a file as a single chunked sequential stream. So if N
# concurrent ranges are no faster than one, the read path has nothing to win.
#
# Why curl rather than rclone:
#
#   - It is a faithful model of what Aqueduct would do - the same endpoint, the same Range headers,
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
# Env:     AQ_TOKEN_FILE   file holding a bare OAuth access token (default ~/.config/aqueduct/access_token)
#          WINDOW_MIB      bytes per sample, split across the streams (default 512)
#          FIRST_OFFSET_MIB  where in the file to start (default 1024)
#          CONCURRENCY     stream counts to try, in order (default "1 2 4 8 16 1 2 4 8 16 1 8")
set -u

FILE_ID="${1:?usage: range-fetch-bench.sh <drive-file-id>}"
TOKEN_FILE="${AQ_TOKEN_FILE:-$HOME/.config/aqueduct/access_token}"
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

WINDOW=$((WINDOW_MIB * 1024 * 1024))
FIRST_OFFSET=$((FIRST_OFFSET_MIB * 1024 * 1024))
URL="https://www.googleapis.com/drive/v3/files/$FILE_ID?alt=media&supportsAllDrives=true"

# Fail early and loudly rather than reporting a fast zero-byte transfer as throughput.
PROBE=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' \
    -H "Authorization: Bearer $TOKEN" -H "Range: bytes=0-1048575" "$URL")
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

echo "== Drive range-fetch throughput"
echo "host:     $(hostname) - $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") - kernel $(uname -r)"
echo "date:     $(date -Is)"
echo "link:     $(for i in $(ls /sys/class/net | grep -v lo); do
                    [ "$(cat /sys/class/net/$i/operstate 2>/dev/null)" = up ] || continue
                    s=$(cat /sys/class/net/$i/speed 2>/dev/null)
                    case "$s" in ''|-1) s=wireless ;; *) s="${s}Mb" ;; esac
                    printf '%s(%s) ' "$i" "$s"
                  done)"
echo "file:     $FILE_ID"
echo "window:   $WINDOW_MIB MiB per sample, first offset $FIRST_OFFSET_MIB MiB"
echo "control:  $((CONTROL_BYTES / 1048576)) MiB from speed.cloudflare.com after every sample"
echo
printf '%-7s %-8s %12s %9s %10s %12s\n' "sample" "streams" "offset(MiB)" "secs" "MB/s" "control MB/s"

i=0
for N in $CONCURRENCY; do
    OFFSET=$((FIRST_OFFSET + i * WINDOW))
    CHUNK=$((WINDOW / N))

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

    CSTART=$(date +%s.%N)
    curl -s -o /dev/null --max-time 120 "$CONTROL_URL"
    CEND=$(date +%s.%N)

    SECS=$(elapsed "$START" "$END")
    CSECS=$(elapsed "$CSTART" "$CEND")
    printf '%-7s %-8s %12s %9s %10s %12s\n' \
        "$((i + 1))" "$N" "$((OFFSET / 1048576))" \
        "$SECS" "$(rate "$WINDOW" "$SECS")" "$(rate "$CONTROL_BYTES" "$CSECS")"

    i=$((i + 1))
done

echo
echo "Compare each sample against the control beside it, not against the other samples: the control"
echo "is what the link was carrying at that moment. Where the two move together the link is the"
echo "limit; where the control holds and the sample does not, the limit is Drive's."
