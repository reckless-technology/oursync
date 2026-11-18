#!/bin/bash
# Exercise the write path against the real Google Drive.
#
# Everything else about OurSync can be tested without Google: tools/rclone-floor-test.sh proves the
# union's policies against two local directories, which is all those policies can tell apart. What
# it cannot prove is that a write through the mount reaches Drive, that a delete is recoverable, or
# that a pinned file edited on both sides is caught as a conflict. That needs a read-write token.
#
# It works only inside a folder of its own, created at the top of Drive and removed at the end, so
# nothing that was already there is touched. It refuses to run against a read-only mount, and it
# refuses to delete anything whose path it did not build itself.
#
# Usage: tools/live-write-test.sh [--keep]
set -u

KEEP=no
[ "${1:-}" = --keep ] && KEEP=yes

CONF="${OURSYNC_CONF:-$HOME/.config/oursync/oursync.conf}"
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"
REMOTE="${REMOTE:-gdrive-own}"
MOUNT="${MOUNT:-$HOME/Drive}"
PIN_DIR="${PIN_DIR:-$HOME/.local/share/oursync/pinned}"
WRITE_BACK="${WRITE_BACK:-10s}"
OURSYNC=$(command -v oursync || printf '%s' "$HOME/.local/bin/oursync")

FOLDER="OurSync write test $(date +%Y-%m-%dT%H%M%S)"
DIR="$MOUNT/$FOLDER"

passes=0
failures=0
ok()  { passes=$((passes + 1));   printf 'PASS  %s\n' "$*"; }
bad() { failures=$((failures + 1)); printf 'FAIL  %s\n' "$*"; }
check() {
    local what="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then ok "$what"; else bad "$what (wanted '$want', got '$got')"; fi
}

# Wait for something to become true rather than sleeping a guessed amount: an upload lands when
# --vfs-write-back expires and then when Drive has finished with it, and that is not a fixed time.
wait_for() {
    local what="$1" seconds="$2"; shift 2
    local i=0
    while [ "$i" -lt $((seconds * 4)) ]; do
        if "$@" > /dev/null 2>&1; then return 0; fi
        i=$((i + 1)); sleep 0.25
    done
    printf '      (gave up waiting %ss for %s)\n' "$seconds" "$what"
    return 1
}
in_drive() { rclone lsjson "$REMOTE:$1" --log-level ERROR > /dev/null 2>&1; }
gone_from_drive() { ! in_drive "$1"; }

cleanup() {
    if [ "$KEEP" = yes ]; then
        printf '\nkept %s\n' "$DIR"
        return
    fi
    # Only ever this folder, by the name built above, and only through the remote.
    case "$FOLDER" in
        "OurSync write test "*) rclone purge "$REMOTE:$FOLDER" --log-level ERROR 2>/dev/null || true ;;
        *) printf 'refusing to purge an unexpected folder name: %s\n' "$FOLDER" >&2 ;;
    esac
    # ${PIN_DIR:?} rather than $PIN_DIR: an empty PIN_DIR would make this rm -rf /<folder>.
    rm -rf -- "${PIN_DIR:?}/$FOLDER" 2>/dev/null || true
    "$OURSYNC" refresh --quiet > /dev/null 2>&1 || true
    printf '\nremoved %s\n' "$FOLDER"
}

printf 'mount   %s\n' "$MOUNT"
printf 'remote  %s  scope=%s\n' "$REMOTE" \
    "$(rclone config show "$REMOTE" 2>/dev/null | sed -n 's/^scope = //p')"
printf 'folder  %s\n\n' "$FOLDER"

mountpoint -q "$MOUNT" || { echo "FAIL: $MOUNT is not mounted"; exit 1; }
case "$(rclone config show "$REMOTE" 2>/dev/null | sed -n 's/^scope = //p')" in
    *readonly*)
        echo "This needs a read-write remote. Run: oursync setup --scope drive"
        exit 1 ;;
esac

trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
echo "--- create ---"
# ---------------------------------------------------------------------------------------------

if ! mkdir -p "$DIR" 2>/dev/null; then
    bad "a directory can be created through the mount"
    exit 1
fi
ok "a directory can be created through the mount"

printf 'hello from OurSync\n' > "$DIR/created.txt"
wait_for "created.txt to reach Drive" 60 in_drive "$FOLDER/created.txt"
if in_drive "$FOLDER/created.txt"; then
    ok "a new file reaches Drive"
    check "and Drive has the bytes that were written" \
        "hello from OurSync" "$(rclone cat "$REMOTE:$FOLDER/created.txt" 2>/dev/null | tr -d '\r\n')"
else
    bad "a new file reaches Drive"
fi
# :nc is what should keep it off local disk, which is the thing most easily got wrong.
if [ -e "$PIN_DIR/$FOLDER/created.txt" ]; then
    bad "a new file must NOT be created on local disk - :nc did not hold"
else
    ok "a new file is not created on local disk (:nc holds)"
fi

# ---------------------------------------------------------------------------------------------
echo
echo "--- edit, and the write-back delay ---"
# ---------------------------------------------------------------------------------------------

printf 'edited through the mount\n' > "$DIR/created.txt"
wait_for "the edit to reach Drive" 90 \
    sh -c "rclone cat \"$REMOTE:$FOLDER/created.txt\" 2>/dev/null | grep -q edited"
check "an edit reaches Drive" \
    "edited through the mount" "$(rclone cat "$REMOTE:$FOLDER/created.txt" 2>/dev/null | tr -d '\r\n')"

# Several saves inside the write-back window should cost one upload, not one each. What is checked
# here is only that the last one wins; the upload count would need the mount's own log.
for i in 1 2 3 4 5; do printf 'save %s\n' "$i" > "$DIR/repeated.txt"; done
wait_for "repeated saves to settle" 90 in_drive "$FOLDER/repeated.txt"
check "repeated saves inside the ${WRITE_BACK} window leave the last one" \
    "save 5" "$(rclone cat "$REMOTE:$FOLDER/repeated.txt" 2>/dev/null | tr -d '\r\n')"

# ---------------------------------------------------------------------------------------------
echo
echo "--- a file bigger than one chunk ---"
# ---------------------------------------------------------------------------------------------

dd if=/dev/urandom of="$DIR/big.bin" bs=1M count=24 status=none 2>/dev/null
local_sum=$(sha256sum < "$DIR/big.bin" | cut -d' ' -f1)
wait_for "24 MiB to reach Drive" 300 in_drive "$FOLDER/big.bin"
remote_sum=$(rclone cat "$REMOTE:$FOLDER/big.bin" 2>/dev/null | sha256sum | cut -d' ' -f1)
check "24 MiB arrives byte for byte" "$local_sum" "$remote_sum"

# ---------------------------------------------------------------------------------------------
echo
echo "--- rename and delete ---"
# ---------------------------------------------------------------------------------------------

mv "$DIR/repeated.txt" "$DIR/renamed.txt" 2>/dev/null
wait_for "the rename to reach Drive" 60 in_drive "$FOLDER/renamed.txt"
if in_drive "$FOLDER/renamed.txt" && ! in_drive "$FOLDER/repeated.txt"; then
    ok "a rename through the mount renames it in Drive"
else
    bad "a rename through the mount renames it in Drive"
fi

rm -f "$DIR/renamed.txt"
wait_for "the delete to reach Drive" 60 gone_from_drive "$FOLDER/renamed.txt"
if gone_from_drive "$FOLDER/renamed.txt"; then
    ok "a delete through the mount removes it from Drive"
    # Recoverable, not destroyed: rclone's drive backend trashes by default.
    if rclone lsjson "$REMOTE:$FOLDER/renamed.txt" --drive-trashed-only --log-level ERROR 2>/dev/null \
        | grep -q renamed.txt; then
        ok "and the deleted file is in Drive's trash, so it is recoverable"
    else
        bad "the deleted file is NOT in Drive's trash - it may have been removed permanently"
    fi
else
    bad "a delete through the mount removes it from Drive"
fi

# ---------------------------------------------------------------------------------------------
echo
echo "--- a pinned file written through the mount ---"
# ---------------------------------------------------------------------------------------------

printf 'before pinning\n' > "$DIR/pinned.txt"
wait_for "pinned.txt to reach Drive" 60 in_drive "$FOLDER/pinned.txt"
"$OURSYNC" pin "$DIR/pinned.txt" > /dev/null 2>&1
if [ ! -e "$PIN_DIR/$FOLDER/pinned.txt" ]; then
    bad "the file can be pinned"
else
    ok "the file can be pinned"
    printf 'written while pinned\n' > "$DIR/pinned.txt"
    wait_for "the pinned file's edit to reach Drive" 90 \
        sh -c "rclone cat \"$REMOTE:$FOLDER/pinned.txt\" 2>/dev/null | grep -q 'while pinned'"
    # action_policy=epall should send this to BOTH upstreams. If only one has it, a pin diverges
    # from Drive silently, which is the worst failure this design can have.
    check "the local pinned copy has the new bytes" \
        "written while pinned" "$(tr -d '\r\n' < "$PIN_DIR/$FOLDER/pinned.txt")"
    check "and so does Drive" \
        "written while pinned" "$(rclone cat "$REMOTE:$FOLDER/pinned.txt" 2>/dev/null | tr -d '\r\n')"

    echo
    echo "--- a pinned file changed in Drive behind the mount's back ---"
    rclone rcat "$REMOTE:$FOLDER/pinned.txt" > /dev/null 2>&1 <<< "changed in Drive directly"
    sleep 2
    out=$("$OURSYNC" refresh 2>&1)
    printf '%s\n' "$out" | sed 's/^/      /'
    if printf '%s' "$out" | grep -q "1 updated from Drive"; then
        ok "refresh pulls a remote change into the pinned copy"
        check "the pinned copy now holds Drive's bytes" \
            "changed in Drive directly" "$(tr -d '\r\n' < "$PIN_DIR/$FOLDER/pinned.txt")"
    elif printf '%s' "$out" | grep -q CONFLICT; then
        bad "refresh called it a conflict; Drive was newer, so it should have pulled"
    else
        bad "refresh neither pulled nor reported a conflict"
    fi
fi

echo
printf '%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
