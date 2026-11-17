#!/bin/sh
# Measure what GNOME's own Google Drive integration (gnome-online-accounts + the gvfsd-google
# GVfs backend) can actually do, on this machine, against this Drive.
#
# Why this exists: Mint 22.3 ships that integration by default, so before building a FUSE daemon
# the honest question is whether the thing already installed is good enough. Documentation and bug
# trackers answer it partly; throughput, seek behaviour and listing time on a multi-terabyte Drive
# are only answered by measurement.
#
# What it needs first: a Google account added in Online Accounts (the GTK panel Mint ships as
# gnome-online-accounts-gtk). That is a browser consent click and cannot be scripted.
#
# READ-ONLY by default. Pass --write to include the write tests, which create and delete one small
# file in the Drive's root. Nothing else is ever modified.
#
# Usage:  tools/evaluate-gvfs-google.sh [--write] [--big /path/within/mount/largefile]
set -u

WRITE=0
BIG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --write) WRITE=1 ;;
        --big) shift; BIG="${1:-}" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '\n== %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "environment"
uname -r
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
dpkg -l gvfs-backends gnome-online-accounts 2>/dev/null | awk '/^ii/ {print $2, $3}'

say "is an account configured"
if [ ! -d "$HOME/.config/goa-1.0" ]; then
    echo "no ~/.config/goa-1.0 - no Online Account has ever been added"
fi
ls -la "$HOME/.config/goa-1.0" 2>/dev/null

say "gio mounts"
gio mount -l 2>&1

# The gvfs FUSE bridge is where non-GIO programs see the mount. Its absence is itself a finding:
# it means only GIO-aware applications can read anything at all.
BRIDGE="/run/user/$(id -u)/gvfs"
say "gvfs FUSE bridge at $BRIDGE"
ls -la "$BRIDGE" 2>&1
MOUNT=$(find "$BRIDGE" -maxdepth 1 -name 'google-drive*' 2>/dev/null | head -1)
if [ -z "$MOUNT" ]; then
    echo
    echo "No google-drive mount under the bridge. Add a Google account in Online Accounts, then"
    echo "open it once in Nemo (the backend is started on demand) and run this again."
    exit 1
fi
echo "mount: $MOUNT"

say "top-level listing, and how long it takes"
time ls -la "$MOUNT" 2>&1 | head -40

say "how a Google-native document is presented (name, size, type)"
find "$MOUNT" -maxdepth 2 \( -name '*.gdoc' -o -name '*.gsheet' -o -name '*.docx' \) 2>/dev/null | head -5 | while read -r f; do
    stat -c '%n  size=%s  type=%F' "$f" 2>&1
    file -b "$f" 2>&1
done

say "duplicate names in one folder - does the backend disambiguate or hide one"
ls -1 "$MOUNT" 2>/dev/null | sort | uniq -d | head -10 || echo "(no duplicates at the top level, or listing failed)"

say "stat cost of a deep listing (1000 entries, timed)"
time find "$MOUNT" -maxdepth 3 2>/dev/null | head -1000 | wc -l

# Pick a large file to measure against, unless one was named.
if [ -z "$BIG" ]; then
    BIG=$(find "$MOUNT" -maxdepth 4 -type f -size +200M 2>/dev/null | head -1)
fi
if [ -z "$BIG" ]; then
    echo
    echo "No file over 200 MB found in the first four levels; pass one with --big to measure"
    echo "throughput and seeking. Stopping before the read tests."
    exit 0
fi
say "measuring against: $BIG"
stat -c 'size=%s' "$BIG"

say "sequential read throughput, first 200 MB (this is the number that matters)"
dd if="$BIG" of=/dev/null bs=1M count=200 2>&1 | tail -2

say "cold re-read of the same 200 MB - is anything cached"
dd if="$BIG" of=/dev/null bs=1M count=200 2>&1 | tail -2

say "SEEKING: read 1 MB from 50% into the file. If this takes as long as reading to that point,"
say "there is no random access and the backend is streaming from the start."
time dd if="$BIG" of=/dev/null bs=1M count=1 skip=$(( $(stat -c %s "$BIG") / 2097152 )) 2>&1 | tail -2

say "small partial read far into the file (4 KiB at 90%)"
time dd if="$BIG" of=/dev/null bs=4k count=1 skip=$(( $(stat -c %s "$BIG") / 4096 * 9 / 10 )) 2>&1 | tail -2

say "non-GIO applications"
if have ffprobe; then
    echo "-- ffprobe (seeks, reads headers and the moov atom):"
    time ffprobe -v error -show_entries format=duration,size -of default=nw=1 "$BIG" 2>&1 | head -5
else
    echo "ffprobe not installed"
fi
echo "-- mmap, via a tiny python check:"
python3 - "$BIG" <<'PY' 2>&1
import mmap, sys
path = sys.argv[1]
try:
    with open(path, "rb") as f:
        m = mmap.mmap(f.fileno(), 4096, access=mmap.ACCESS_READ)
        head = m[:16]
        m.close()
    print("mmap ok, first 16 bytes:", head.hex())
except Exception as e:
    print("mmap FAILED:", type(e).__name__, e)
PY

say "O_DIRECT read (many media tools try it)"
dd if="$BIG" of=/dev/null bs=1M count=1 iflag=direct 2>&1 | tail -2

if [ "$WRITE" -eq 1 ]; then
    say "WRITE TESTS - creating one small file in the Drive root, then deleting it"
    T="$MOUNT/aqueduct-write-test-$$.bin"
    dd if=/dev/urandom of=/tmp/aq-write-test.bin bs=1M count=4 2>/dev/null
    echo "-- create 4 MB:"
    time cp /tmp/aq-write-test.bin "$T" 2>&1
    ls -l "$T" 2>&1
    echo "-- modify in place (4 bytes at offset 0) - does it work at all:"
    printf 'XXXX' | dd of="$T" bs=1 seek=0 conv=notrunc 2>&1 | tail -2
    echo "-- rename:"
    mv "$T" "$T.renamed" 2>&1 && echo "rename ok"
    echo "-- delete:"
    rm -f "$T.renamed" 2>&1 && echo "delete ok"
    rm -f /tmp/aq-write-test.bin
else
    say "write tests skipped (pass --write to include them)"
fi

say "done"
