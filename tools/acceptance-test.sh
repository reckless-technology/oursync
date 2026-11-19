#!/bin/bash
# OurSync acceptance test: the corner cases, against a real Drive and a real mount.
#
# This is deliberately NOT tools/live-write-test.sh, which answers "does the happy path work".
# This one answers "does it break on the things that break filesystems": awkward names, empty
# files, deep nesting, directory pins, conflicts, a mount restart, a killed process, and the
# arguments a person gets wrong. Everything happens inside one folder at the top of Drive which is
# created and removed, and nothing outside it is read or written.
#
# It drives whatever `oursync` is on PATH, so it tests the INSTALLED copy, not a checkout.
#
#   tools/acceptance-test.sh
#
# Exit status is the number of failures, capped at 125. Run it with the status in view: a pipeline
# ending in `tail` reports tail's status, which has hidden a failure here before.
set -u

pass=0; fail=0; skipped=0
declare -a PINNED_BY_US=()

ok()      { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad()     { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
skip()    { printf 'SKIP  %s  (%s)\n' "$1" "${2:-}"; skipped=$((skipped + 1)); }
section() { printf '\n--- %s ---\n' "$1"; }

check() { # name want got
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi
}

# Wait for a condition rather than sleeping a fixed time: the write-back delay is configurable and
# a fixed sleep either wastes time or fails on a slow link.
# Wait for Drive's copy of a path to contain a string. Separate from wait_for because the thing
# being waited on is remote and costs a listing each time, so the poll is slower on purpose.
wait_remote() { # seconds relative-path pattern
    local deadline=$(( SECONDS + $1 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if rclone cat "$REMOTE:$2" 2>/dev/null | grep -q "$3"; then return 0; fi
        sleep 2
    done
    return 1
}

# Wait for Drive to no longer have a path at all.
wait_remote_gone() { # seconds relative-path
    local deadline=$(( SECONDS + $1 ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! rclone lsjson "$REMOTE:$2" > /dev/null 2>&1; then return 0; fi
        sleep 2
    done
    return 1
}

wait_for() { # seconds command...
    local deadline=$(( SECONDS + $1 )); shift
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$@" > /dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    return 1
}

command -v oursync > /dev/null || { echo "oursync is not on PATH"; exit 125; }

# Everything is read from doctor rather than assumed, so this works on any configuration.
doc=$(oursync doctor 2>&1)
MOUNT=$(printf '%s\n' "$doc"  | awk '$1=="mount"    {print $2; exit}')
PIN_DIR=$(printf '%s\n' "$doc"| awk '$1=="pin" && $2=="dir" {print $3; exit}')
REMOTE=$(printf '%s\n' "$doc" | awk '$1=="remote"   {print $2; exit}')
VERSION=$(oursync version 2>/dev/null)

[ -n "$MOUNT" ] && [ -n "$PIN_DIR" ] && [ -n "$REMOTE" ] \
    || { echo "could not read mount/pin dir/remote from doctor"; printf '%s\n' "$doc"; exit 125; }
mountpoint -q "$MOUNT" || { echo "$MOUNT is not mounted - start oursync-mount.service first"; exit 125; }
printf '%s\n' "$doc" | grep -q 'read-write' \
    || { echo "the mount is read-only; this test writes. Re-authorise with: oursync setup --scope drive"; exit 125; }

STAMP=$(date -u +%Y%m%dT%H%M%S)
BASE="OurSync acceptance $STAMP"
D="$MOUNT/$BASE"

PINS_BEFORE=$(oursync list 2>/dev/null | sort)

cleanup() {
    # Unpin only what we pinned, so an existing pin list is left exactly as it was.
    local p
    for p in "${PINNED_BY_US[@]:-}"; do
        [ -n "$p" ] && oursync unpin "$p" > /dev/null 2>&1
    done
    rm -rf -- "$D" 2>/dev/null
    # The mount may have been stopped mid-test; clear the remote copy directly in that case.
    rclone purge "$REMOTE:$BASE" > /dev/null 2>&1
    rm -rf -- "${PIN_DIR:?}/$BASE" 2>/dev/null
}
trap cleanup EXIT

pin() { # path -- records it so cleanup can undo it
    PINNED_BY_US+=("$1")
    oursync pin "$1" > /dev/null 2>&1
}

printf 'oursync   %s\n' "$VERSION"
printf 'rclone    %s\n' "$(rclone version 2>/dev/null | head -1 | sed 's/^rclone //')"
printf 'binary    %s\n' "$(command -v oursync)"
printf 'mount     %s\n' "$MOUNT"
printf 'folder    %s\n' "$BASE"

mkdir -p "$D" || { echo "cannot create the test folder"; exit 125; }

# =================================================================================================
section "names that break things"
# =================================================================================================
# Each of these is a name that has broken a shell script, a filesystem or an API client somewhere.
# The bar is the same for all of them: write it through the mount, and it arrives in Drive intact.
declare -a NAMES=(
    "plain.txt"
    "with spaces.txt"
    "with'single.txt"
    'with"double.txt'
    "with\$dollar.txt"
    "with\`backtick.txt"
    "with;semi&amp.txt"
    "with|pipe.txt"
    "-leading-dash.txt"
    "--looks-like-a-flag.txt"
    "üñïçødé-accents.txt"
    "日本語.txt"
    "emoji-🎛️-knob.txt"
    "trailing.space .txt"
    "...dots.txt"
    "#hash.txt"
    "100%percent.txt"
    "paren(s).txt"
    "brack[et]s.txt"
    "new
line.txt"
)
for n in "${NAMES[@]}"; do
    label=$(printf '%s' "$n" | tr '\n' '?')
    if printf 'CONTENT-%s\n' "$label" > "$D/$n" 2>/dev/null; then
        if wait_for 30 test -s "$D/$n"; then
            got=$(tr -d '\r\n' < "$D/$n" 2>/dev/null)
            check "a file named [$label] round-trips through the mount" "CONTENT-$label" "$got"
        else
            bad "a file named [$label] round-trips through the mount (never appeared)"
        fi
    else
        bad "a file named [$label] can be created at all"
    fi
done

# A 255-byte name is the usual filesystem limit; Drive's own limit is higher.
long=$(printf 'n%.0s' $(seq 1 250)).txt
if printf 'LONG\n' > "$D/$long" 2>/dev/null && wait_for 30 test -s "$D/$long"; then
    ok "a 254-character filename round-trips"
else
    bad "a 254-character filename round-trips"
fi

# =================================================================================================
section "shapes of file"
# =================================================================================================
: > "$D/empty.txt"
if wait_for 30 rclone lsjson "$REMOTE:$BASE/empty.txt"; then
    sz=$(rclone lsjson "$REMOTE:$BASE/empty.txt" 2>/dev/null | sed -n 's/.*"Size":\([0-9-]*\).*/\1/p')
    check "a zero-byte file reaches Drive as zero bytes" "0" "$sz"
else
    bad "a zero-byte file reaches Drive at all"
fi

mkdir -p "$D/a/b/c/d/e"
printf 'DEEP\n' > "$D/a/b/c/d/e/deep.txt"
if wait_for 30 rclone lsjson "$REMOTE:$BASE/a/b/c/d/e/deep.txt"; then
    ok "a file five directories deep reaches Drive"
else
    bad "a file five directories deep reaches Drive"
fi

head -c 1048576 /dev/urandom > "$D/binary.bin"
sync
if wait_for 60 rclone lsjson "$REMOTE:$BASE/binary.bin"; then
    want=$(sha256sum < "$D/binary.bin" | awk '{print $1}')
    got=$(rclone cat "$REMOTE:$BASE/binary.bin" 2>/dev/null | sha256sum | awk '{print $1}')
    check "1 MiB of binary arrives byte for byte" "$want" "$got"
else
    bad "1 MiB of binary reaches Drive"
fi

# =================================================================================================
section "pinning: the shapes a person will actually ask for"
# =================================================================================================
printf 'PIN-ME\n' > "$D/pin me.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/pin me.txt"
pin "$D/pin me.txt"
if [ -e "$PIN_DIR/$BASE/pin me.txt" ]; then
    ok "a file with a space in its name can be pinned"
else
    bad "a file with a space in its name can be pinned"
fi

printf 'EDITED-WHILE-PINNED\n' > "$D/pin me.txt"
sync
wait_for 30 grep -q EDITED "$PIN_DIR/$BASE/pin me.txt"
check "saving it reaches the local copy" \
    "EDITED-WHILE-PINNED" "$(tr -d '\r\n' < "$PIN_DIR/$BASE/pin me.txt" 2>/dev/null)"
# The two copies do NOT arrive together, and waiting for the local one is not waiting for Drive:
# the union writes local disk at once while the upload is held by --vfs-write-back, ten seconds by
# default. Checking Drive straight after the local copy passed once and failed the next run.
wait_remote 45 "$BASE/pin me.txt" EDITED
check "saving it reaches Drive" \
    "EDITED-WHILE-PINNED" "$(rclone cat "$REMOTE:$BASE/pin me.txt" 2>/dev/null | tr -d '\r\n')"

# Twice, because the first fix for this bug worked once and then stopped.
printf 'SECOND-SAVE\n' > "$D/pin me.txt"
sync
wait_for 30 grep -q SECOND "$PIN_DIR/$BASE/pin me.txt"
check "and a second save does too" \
    "SECOND-SAVE" "$(tr -d '\r\n' < "$PIN_DIR/$BASE/pin me.txt" 2>/dev/null)"

: > "$D/empty-pin.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/empty-pin.txt"
pin "$D/empty-pin.txt"
if [ -e "$PIN_DIR/$BASE/empty-pin.txt" ]; then
    ok "a zero-byte file can be pinned"
else
    bad "a zero-byte file can be pinned"
fi

mkdir -p "$D/pindir"
printf 'ONE\n' > "$D/pindir/one.txt"
printf 'TWO\n' > "$D/pindir/two.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/pindir/two.txt"
pin "$D/pindir"
if [ -e "$PIN_DIR/$BASE/pindir/one.txt" ] && [ -e "$PIN_DIR/$BASE/pindir/two.txt" ]; then
    ok "pinning a directory brings its files down"
else
    bad "pinning a directory brings its files down (one=$([ -e "$PIN_DIR/$BASE/pindir/one.txt" ] && echo y || echo n) two=$([ -e "$PIN_DIR/$BASE/pindir/two.txt" ] && echo y || echo n))"
fi

# A file added to a pinned directory in Drive should arrive on the next refresh - that is the whole
# point of recording that the DIRECTORY was pinned rather than the files it happened to hold.
printf 'THREE\n' | rclone rcat "$REMOTE:$BASE/pindir/three.txt" > /dev/null 2>&1
oursync refresh > /dev/null 2>&1
if [ -e "$PIN_DIR/$BASE/pindir/three.txt" ]; then
    ok "a file added to a pinned directory in Drive arrives on refresh"
else
    bad "a file added to a pinned directory in Drive arrives on refresh"
fi

# =================================================================================================
section "unpin, rename, delete"
# =================================================================================================
printf 'UNPIN-ME\n' > "$D/unpin.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/unpin.txt"
oursync pin "$D/unpin.txt" > /dev/null 2>&1
had_local=$([ -e "$PIN_DIR/$BASE/unpin.txt" ] && echo yes || echo no)
oursync unpin "$D/unpin.txt" > /dev/null 2>&1
check "unpin removes the local copy" "yes:no" \
    "$had_local:$([ -e "$PIN_DIR/$BASE/unpin.txt" ] && echo yes || echo no)"
check "and the file is still readable through the mount" \
    "UNPIN-ME" "$(tr -d '\r\n' < "$D/unpin.txt" 2>/dev/null)"
check "and it is still in Drive" \
    "UNPIN-ME" "$(rclone cat "$REMOTE:$BASE/unpin.txt" 2>/dev/null | tr -d '\r\n')"

printf 'RENAME-ME\n' > "$D/before.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/before.txt"
mv "$D/before.txt" "$D/after.txt"
if wait_for 30 rclone lsjson "$REMOTE:$BASE/after.txt"; then
    gone=$(rclone lsjson "$REMOTE:$BASE/before.txt" > /dev/null 2>&1 && echo present || echo gone)
    check "a rename through the mount renames it in Drive" "gone" "$gone"
else
    bad "a rename through the mount renames it in Drive"
fi

printf 'DELETE-ME\n' > "$D/doomed.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/doomed.txt"
pin "$D/doomed.txt"
rm -f "$D/doomed.txt"
# Same asymmetry as a write: the local copy goes at once, Drive's goes when the deletion is sent.
wait_for 30 test ! -e "$PIN_DIR/$BASE/doomed.txt"
wait_remote_gone 45 "$BASE/doomed.txt"
local_gone=$([ -e "$PIN_DIR/$BASE/doomed.txt" ] && echo present || echo gone)
remote_gone=$(rclone lsjson "$REMOTE:$BASE/doomed.txt" > /dev/null 2>&1 && echo present || echo gone)
check "deleting a pinned file removes the local copy" "gone" "$local_gone"
check "deleting a pinned file removes it from Drive" "gone" "$remote_gone"

# =================================================================================================
section "conflicts, which must never be resolved silently"
# =================================================================================================
printf 'ORIGINAL\n' > "$D/conflict.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/conflict.txt"
pin "$D/conflict.txt"
# Diverge both copies behind the mount's back: Drive says one thing, local disk says another.
printf 'CHANGED-IN-DRIVE\n' | rclone rcat "$REMOTE:$BASE/conflict.txt" > /dev/null 2>&1
printf 'CHANGED-LOCALLY\n' > "$PIN_DIR/$BASE/conflict.txt"
out=$(oursync refresh 2>&1)
if printf '%s' "$out" | grep -qi 'conflict'; then
    ok "refresh reports a two-sided change as a conflict"
else
    bad "refresh reports a two-sided change as a conflict (said: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140))"
fi
check "and it overwrites neither copy" "CHANGED-LOCALLY:CHANGED-IN-DRIVE" \
    "$(tr -d '\r\n' < "$PIN_DIR/$BASE/conflict.txt" 2>/dev/null):$(rclone cat "$REMOTE:$BASE/conflict.txt" 2>/dev/null | tr -d '\r\n')"

# A conflict is sticky by design - refresh keeps reporting it and keeps exiting non-zero until a
# person settles it, which is correct and is why it has to be cleared here. Leaving it pinned made
# the NEXT refresh test fail on this file and read as a fault in that test's subject.
oursync unpin "$D/conflict.txt" > /dev/null 2>&1

# A modification time in the future is real in this Drive: some uploads carry the source's own
# timestamp, and seven files in Jonny's Drive are dated 2036. Anything resolving by "newest wins"
# is wrong about those for a decade, so refresh must not be confused by one.
printf 'FUTURE\n' > "$D/future.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/future.txt"
pin "$D/future.txt"
if rclone touch --timestamp 2036-02-07T01:58:15 "$REMOTE:$BASE/future.txt" > /dev/null 2>&1; then
    if out=$(oursync refresh 2>&1) && ! printf '%s' "$out" | grep -qiE 'traceback|invalid|cannot'; then
        ok "refresh copes with a modification time ten years in the future"
    else
        bad "refresh copes with a future modification time (said: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140))"
    fi
else
    skip "refresh copes with a future modification time" "rclone touch --timestamp unavailable"
fi

# =================================================================================================
section "surviving the mount going away"
# =================================================================================================
printf 'SURVIVOR\n' > "$D/survivor.txt"
wait_for 30 rclone lsjson "$REMOTE:$BASE/survivor.txt"
pin "$D/survivor.txt"
# Mark the local copy so we can prove the mount serves THAT and not a cached remote read. A pin
# test that does not mark the local copy proves nothing: the VFS cache would answer identically.
printf 'SURVIVOR-LOCAL-MARK\n' > "$PIN_DIR/$BASE/survivor.txt"

if systemctl --user restart oursync-mount.service > /dev/null 2>&1 \
   && wait_for 40 mountpoint -q "$MOUNT"; then
    sleep 2
    check "a pinned file is served from local disk after a mount restart" \
        "SURVIVOR-LOCAL-MARK" "$(tr -d '\r\n' < "$D/survivor.txt" 2>/dev/null)"
    check "and the pin list survived the restart" "yes" \
        "$(oursync list 2>/dev/null | grep -q 'survivor.txt' && echo yes || echo no)"
else
    bad "the mount comes back after systemctl restart"
fi

# Kill rclone outright - a crash, not a clean stop - and see whether the unit brings it back.
#
# `mountpoint -q` alone is NOT the test, and believing it cost a false pass here on 2026-11-18. A
# FUSE mount whose process has been killed still has a kernel mount entry, so mountpoint answers
# yes for a moment while every read gives ENOTCONN; and a moment later, during RestartSec, the
# entry is gone and the mountpoint is an ordinary empty directory that `ls` answers happily. So
# both a yes and a no can be wrong, in opposite directions, seconds apart. What is actually wanted
# is a mount that is usable: the unit active, the mountpoint present, AND a read that works.
# shellcheck disable=SC2329  # invoked indirectly, as the command passed to wait_for
usable_mount() {
    [ "$(systemctl --user is-active oursync-mount.service 2>/dev/null)" = active ] \
        && mountpoint -q "$MOUNT" \
        && ls "$MOUNT" > /dev/null 2>&1
}
rclone_pid=$(systemctl --user show oursync-mount.service -p MainPID --value 2>/dev/null)
restarts_before=$(systemctl --user show oursync-mount.service -p NRestarts --value 2>/dev/null)
if [ -n "$rclone_pid" ] && [ "$rclone_pid" != 0 ]; then
    killed_at=$SECONDS
    kill -9 "$rclone_pid" 2>/dev/null
    sleep 3   # past the window where the stale kernel mount entry still answers yes
    if wait_for 90 usable_mount; then
        took=$(( SECONDS - killed_at ))
        restarts_after=$(systemctl --user show oursync-mount.service -p NRestarts --value 2>/dev/null)
        if [ "$restarts_after" != "$restarts_before" ]; then
            ok "a killed mount is restarted by systemd and usable again (${took}s, NRestarts $restarts_before -> $restarts_after)"
        else
            bad "a killed mount came back but NRestarts did not change ($restarts_before) - something else remounted it"
        fi
    else
        bad "a killed mount is restarted by systemd and usable again (still unusable after 90s)"
    fi
else
    skip "a killed mount is restarted by systemd" "could not read MainPID"
fi

# Whatever the last test concluded, this machine's ~/Drive is somebody's live installation and must
# not be left unmounted because a test killed it. Put it back before going on.
if ! mountpoint -q "$MOUNT"; then
    printf '      mount is down after the kill test - restarting it\n'
    systemctl --user restart oursync-mount.service > /dev/null 2>&1
    if wait_for 60 mountpoint -q "$MOUNT"; then
        printf '      restarted, %s is mounted again\n' "$MOUNT"
    else
        printf '      COULD NOT REMOUNT %s - this needs a person\n' "$MOUNT"
    fi
fi

# =================================================================================================
section "arguments a person gets wrong"
# =================================================================================================
if oursync pin /etc/hostname > /dev/null 2>&1; then
    bad "pinning a path outside the mount is refused"
    oursync unpin /etc/hostname > /dev/null 2>&1
else
    ok "pinning a path outside the mount is refused"
fi

if oursync pin "$D/does-not-exist.txt" > /dev/null 2>&1; then
    bad "pinning a path that does not exist is refused"
else
    ok "pinning a path that does not exist is refused"
fi

if oursync unpin "$D/never-pinned.txt" > /dev/null 2>&1; then
    skip "unpinning something not pinned" "succeeded; harmless either way"
else
    ok "unpinning something not pinned fails rather than doing something odd"
fi

if oursync nonsense-command > /dev/null 2>&1; then
    bad "an unknown command is rejected"
else
    ok "an unknown command is rejected"
fi

out=$(oursync pin 2>&1); st=$?
if [ "$st" -ne 0 ] && [ -n "$out" ]; then
    ok "pin with no argument explains itself rather than crashing"
else
    bad "pin with no argument explains itself (status $st)"
fi

# =================================================================================================
section "the installed package"
# =================================================================================================
check "the binary is the packaged one" "/usr/bin/oursync" "$(command -v oursync)"
if dpkg -l oursync 2>/dev/null | grep -q '^ii'; then
    dpkg_ver=$(dpkg-query -W -f='${Version}' oursync 2>/dev/null)
    check "dpkg's version matches what the program reports" "oursync $dpkg_ver" "$VERSION"
else
    skip "dpkg's version matches" "not installed as a package"
fi
for f in /usr/share/man/man1/oursync.1.gz \
         /usr/share/nemo/actions/10_oursync-pin.nemo_action \
         /usr/share/nemo/actions/11_oursync-unpin.nemo_action \
         /usr/share/icons/hicolor/256x256/apps/oursync.png; do
    if [ -f "$f" ]; then ok "installed: $f"; else bad "installed: $f"; fi
done
if printf '%s' "$VERSION" | grep -q 'from source'; then
    bad "the packaged script reports a real version, not from-source"
else
    ok "the packaged script reports a real version, not from-source"
fi

# =================================================================================================
section "leaving nothing behind"
# =================================================================================================
cleanup
trap - EXIT
sleep 2
if rclone lsjson "$REMOTE:$BASE" > /dev/null 2>&1; then
    bad "the test folder is gone from Drive"
else
    ok "the test folder is gone from Drive"
fi
if [ -d "$PIN_DIR/$BASE" ]; then
    bad "no pinned copies are left on local disk"
else
    ok "no pinned copies are left on local disk"
fi
PINS_AFTER=$(oursync list 2>/dev/null | sort)
check "the pin list is exactly as it was before" "$PINS_BEFORE" "$PINS_AFTER"

printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -gt 125 ] && exit 125
exit "$fail"
