#!/bin/bash
# Prove that the rclone on this machine does everything OurSync asks of it.
#
# This exists because the dependency line in debian/control is otherwise a guess. Ubuntu 24.04,
# which Mint 22 is built on, ships rclone 1.60.1; development happened on 1.76. Rather than hope,
# every feature OurSync relies on is exercised here against whatever rclone is on the PATH, so
# "Depends: rclone (>= 1.60)" is a measurement.
#
# It needs no network and no Google account: both union upstreams are local directories, which is
# all the union policies can tell apart anyway. The mount phase needs /dev/fuse and is skipped
# without it, reporting that it was skipped rather than passing quietly.
#
# Usage: tools/rclone-floor-test.sh [--keep]
set -u

KEEP=no
[ "${1:-}" = --keep ] && KEEP=yes

RCLONE_VERSION=$(rclone version 2>/dev/null | head -1 | sed 's/^rclone //')
printf 'rclone %s at %s\n\n' "${RCLONE_VERSION:-MISSING}" "$(command -v rclone || echo 'not found')"
command -v rclone > /dev/null || { echo "FAIL: rclone is not installed"; exit 1; }

TMP=$(mktemp -d)
CONFIG="$TMP/rclone.conf"
export RCLONE_CONFIG="$CONFIG"
MOUNT="$TMP/mnt"
PINNED="$TMP/pinned"
CLOUD="$TMP/cloud"
CACHE="$TMP/cache"
mkdir -p "$MOUNT" "$PINNED" "$CLOUD" "$CACHE"

passes=0
failures=0
skipped=0

ok()   { passes=$((passes + 1));   printf 'PASS  %s\n' "$*"; }
bad()  { failures=$((failures + 1)); printf 'FAIL  %s\n' "$*"; }
skip() { skipped=$((skipped + 1)); printf 'SKIP  %s\n' "$*"; }

check() {
    local what="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then ok "$what"; else bad "$what (wanted '$want', got '$got')"; fi
}

cleanup() {
    mountpoint -q "$MOUNT" 2>/dev/null && { fusermount3 -u "$MOUNT" 2>/dev/null || fusermount -u "$MOUNT" 2>/dev/null; }
    [ -n "${MOUNT_PID:-}" ] && kill "$MOUNT_PID" 2>/dev/null
    if [ "$KEEP" = yes ]; then printf '\nkept %s\n' "$TMP"; else rm -rf -- "$TMP"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
echo "--- the union, which is where pinning comes from ---"
# ---------------------------------------------------------------------------------------------

printf 'CLOUD\n' > "$CLOUD/shared.txt"
printf 'LOCAL\n' > "$PINNED/shared.txt"
printf 'CLOUD-ONLY\n' > "$CLOUD/streamed.txt"

# The second upstream is a bare path with NO trailing colon. A colon belongs on a remote *name* -
# the real configuration's second upstream is "gdrive-own:" - and "/tmp/.../cloud:" resolves to
# nothing, which silently leaves a one-upstream union: the read test still passes and every write
# test fails. That cost one confusing run against an rclone that was working perfectly.
if rclone config create union union \
    upstreams "$PINNED:nc $CLOUD" \
    search_policy epall action_policy epall create_policy epmfs \
    --non-interactive > /dev/null 2>&1; then
    ok "union remote with :nc and the epall policies is accepted"
else
    bad "union remote with :nc and the epall policies is accepted"
    echo; echo "nothing else can be tested without it."; exit 1
fi

# search_policy=epall: the FIRST upstream holding the path, in configured order. This is the whole
# of pinning - if it resolved by response time instead, a pin would win only usually.
check "a pinned file is served from the local upstream" \
    "LOCAL" "$(rclone cat union:shared.txt 2>/dev/null | tr -d '\r\n')"
check "a file only in the remote upstream is still readable" \
    "CLOUD-ONLY" "$(rclone cat union:streamed.txt 2>/dev/null | tr -d '\r\n')"

# :nc on the local upstream: a new file must go to the remote, never to local disk.
printf 'NEW\n' | rclone rcat union:created.txt 2>/dev/null
if [ -e "$CLOUD/created.txt" ] && [ ! -e "$PINNED/created.txt" ]; then
    ok "a new file is created in the remote upstream only (:nc holds)"
else
    bad "a new file is created in the remote upstream only (:nc holds): cloud=$([ -e "$CLOUD/created.txt" ] && echo yes || echo no) local=$([ -e "$PINNED/created.txt" ] && echo yes || echo no)"
fi

# action_policy=epall: writing an existing file reaches EVERY upstream holding it, so a pinned
# copy cannot silently diverge from the copy in Drive.
printf 'UPDATED\n' | rclone rcat union:shared.txt 2>/dev/null
check "updating a pinned file writes the local copy" \
    "UPDATED" "$(tr -d '\r\n' < "$PINNED/shared.txt")"
check "updating a pinned file writes the remote copy" \
    "UPDATED" "$(tr -d '\r\n' < "$CLOUD/shared.txt")"

rclone delete union:shared.txt > /dev/null 2>&1
if [ ! -e "$PINNED/shared.txt" ] && [ ! -e "$CLOUD/shared.txt" ]; then
    ok "deleting a pinned file removes both copies"
else
    bad "deleting a pinned file removes both copies"
fi

# ---------------------------------------------------------------------------------------------
echo
echo "--- what refresh reads ---"
# ---------------------------------------------------------------------------------------------

# oursync refresh parses ModTime out of lsjson for a single file path. Both halves matter: that
# lsjson accepts a file rather than only a directory, and that the field is named ModTime.
modtime=$(rclone lsjson "$CLOUD/streamed.txt" 2>/dev/null \
    | sed -n 's/.*"ModTime":"\([^"]*\)".*/\1/p' | head -1)
if [ -n "$modtime" ] && date -d "$modtime" +%s > /dev/null 2>&1; then
    ok "lsjson of a single file gives a parseable ModTime ($modtime)"
else
    bad "lsjson of a single file gives a parseable ModTime (got '$modtime')"
fi

# ---------------------------------------------------------------------------------------------
# What setup does to turn a read-only installation into one that can write. The token cannot be
# exercised without Google, but the configuration mechanics can: a scope change has to persist
# without interaction and without destroying the existing token, or re-authorising would leave an
# unusable remote behind when it failed.
# ---------------------------------------------------------------------------------------------

rclone config create probe drive \
    client_id=floor-test client_secret=floor-test scope=drive.readonly --non-interactive \
    > /dev/null 2>&1 || true
if [ "$(rclone config show probe 2>/dev/null | sed -n 's/^type = //p')" = drive ]; then
    ok "a Drive remote can be created non-interactively"
    rclone config update probe scope=drive config_refresh_token=false --non-interactive \
        > /dev/null 2>&1 || true
    check "a scope change persists without interaction" \
        "drive" "$(rclone config show probe 2>/dev/null | sed -n 's/^scope = //p')"
else
    bad "a Drive remote can be created non-interactively"
fi

# A pinned directory tracks what Drive gains, which is copy --update.
mkdir -p "$CLOUD/dir" "$PINNED/dir"
printf 'ONE\n' > "$CLOUD/dir/one.txt"
if rclone copy "$CLOUD/dir" "$PINNED/dir" --update > /dev/null 2>&1 && [ -e "$PINNED/dir/one.txt" ]; then
    ok "copy --update brings a new file into a pinned directory"
else
    bad "copy --update brings a new file into a pinned directory"
fi

# ---------------------------------------------------------------------------------------------
echo
echo "--- the mount ---"
# ---------------------------------------------------------------------------------------------

if [ ! -e /dev/fuse ]; then
    skip "the mount phase: no /dev/fuse on this machine"
elif ! command -v fusermount3 > /dev/null 2>&1 && ! command -v fusermount > /dev/null 2>&1; then
    skip "the mount phase: no fusermount3 or fusermount"
else
    printf 'CLOUD\n' > "$CLOUD/shared.txt"
    printf 'LOCAL\n' > "$PINNED/shared.txt"

    RC_ADDR=127.0.0.1:5579
    RC_PASS=floor-test-password

    # Exactly the flags oursync mount uses, including the write path, so an rclone that rejects one
    # of them fails here instead of on a user's machine. The control-port credentials go through
    # the environment, which is the other thing being tested.
    RCLONE_RC=true RCLONE_RC_ADDR="$RC_ADDR" RCLONE_RC_USER=oursync RCLONE_RC_PASS="$RC_PASS" \
    rclone mount union: "$MOUNT" \
        --vfs-cache-mode full \
        --cache-dir "$CACHE" \
        --vfs-cache-max-size 1G \
        --vfs-cache-max-age 72h \
        --vfs-read-chunk-size 64M \
        --vfs-read-chunk-size-limit 2G \
        --inplace \
        --vfs-write-back 2s \
        --dir-cache-time 5m \
        --poll-interval 1m \
        --umask 022 \
        > "$TMP/mount.log" 2>&1 &
    MOUNT_PID=$!

    for _ in $(seq 1 50); do
        mountpoint -q "$MOUNT" && break
        sleep 0.2
    done

    if ! mountpoint -q "$MOUNT"; then
        bad "the mount comes up with every flag oursync passes"
        echo "      --- mount log ---"
        sed 's/^/      /' "$TMP/mount.log" | head -20
    else
        ok "the mount comes up with every flag oursync passes"
        check "a pinned file reads as the local copy through the mount" \
            "LOCAL" "$(tr -d '\r\n' < "$MOUNT/shared.txt")"

        printf 'THROUGH-THE-MOUNT\n' > "$MOUNT/written.txt"
        sync
        for _ in $(seq 1 40); do
            [ -e "$CLOUD/written.txt" ] && break
            sleep 0.25
        done
        if [ -e "$CLOUD/written.txt" ] && [ ! -e "$PINNED/written.txt" ]; then
            ok "a file written through the mount lands in the remote upstream"
        else
            bad "a file written through the mount lands in the remote upstream: cloud=$([ -e "$CLOUD/written.txt" ] && echo yes || echo no) local=$([ -e "$PINNED/written.txt" ] && echo yes || echo no)"
        fi

        # A file that exists in BOTH upstreams, edited through the mount. This is a pinned file
        # being saved, and it is the case the live run against Drive caught on 2026-11-18: the
        # remote copy took the new bytes and the local one kept the old, after which the mount
        # served the stale local copy until the next refresh. Everything above writes either a new
        # file or an existing one through rclone directly, and neither exercises this path.
        printf 'EDITED-THROUGH-THE-MOUNT\n' > "$MOUNT/shared.txt"
        sync
        for _ in $(seq 1 40); do
            grep -q EDITED "$CLOUD/shared.txt" 2>/dev/null && break
            sleep 0.25
        done
        check "editing a pinned file through the mount reaches the remote copy" \
            "EDITED-THROUGH-THE-MOUNT" "$(tr -d '\r\n' < "$CLOUD/shared.txt")"
        check "editing a pinned file through the mount reaches the local copy" \
            "EDITED-THROUGH-THE-MOUNT" "$(tr -d '\r\n' < "$PINNED/shared.txt")"

        # vfs/forget is what makes a new pin visible at once instead of after --dir-cache-time, and
        # it has to authenticate through RCLONE_RC_USER/PASS rather than a command line.
        out=$(RCLONE_RC_USER=oursync RCLONE_RC_PASS="$RC_PASS" \
              rclone rc --rc-addr "$RC_ADDR" vfs/forget dir="" 2>&1)
        if printf '%s' "$out" | grep -q '"forgotten"'; then
            ok "rc vfs/forget authenticates through the environment"
        else
            bad "rc vfs/forget authenticates through the environment: $(printf '%s' "$out" | tr -d '\n' | cut -c1-120)"
        fi

        out=$(rclone rc --rc-addr "$RC_ADDR" vfs/forget dir="" 2>&1)
        if printf '%s' "$out" | grep -qiE '401|unauthor'; then
            ok "the control port refuses an unauthenticated caller"
        else
            bad "the control port refuses an unauthenticated caller: $(printf '%s' "$out" | tr -d '\n' | cut -c1-120)"
        fi
    fi
fi

echo
printf '%s passed, %s failed, %s skipped, against rclone %s\n' \
    "$passes" "$failures" "$skipped" "${RCLONE_VERSION:-unknown}"
[ "$failures" -eq 0 ]
