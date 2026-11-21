#!/bin/bash
# Tests for the shipped scripts in rclone/: oursync, oursync-setup, oursync-nemo and install.sh.
#
# They run with no network, no Google account and no /dev/fuse. Everything outside the scripts is
# a stub in a temporary directory placed first on PATH: a fake rclone that keeps its "Drive" and
# its remote configuration as plain directories and files, and fakes of mountpoint, fusermount3,
# systemctl, notify-send and gtk-update-icon-cache. HOME and every XDG_* variable point into the
# same temporary directory, so nothing of the person running this is read or written.
#
# What this proves, and what it cannot: it proves the scripts' own logic - which path is accepted,
# which rclone is refused, which way a refresh resolves, what each command asks rclone to do - and
# it records the arguments rclone is given. It cannot prove that real rclone, a real mount or
# Google's consent screen behave as the stub does; tools/rclone-floor-test.sh checks rclone itself
# and tools/acceptance-test.sh drives a real Drive.
#
# tools/coverage.sh runs this under kcov and gates the line coverage of rclone/.
#
# Usage: tools/script-tests.sh [--keep]
set -u

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$REPO/rclone"
KEEP=no
[ "${1:-}" = --keep ] && KEEP=yes

T=$(mktemp -d)
ORIGINAL_PATH="$PATH"
passes=0
failures=0

cleanup() {
    if [ "$KEEP" = yes ]; then printf '\nkept %s\n' "$T"; else rm -rf -- "$T"; fi
}
trap cleanup EXIT

ok()  { passes=$((passes + 1)); }
bad() { failures=$((failures + 1)); printf 'FAIL  %s\n' "$*"; }

expect_eq() { # name want got
    if [ "$2" = "$3" ]; then ok; else bad "$1 (wanted '$2', got '$3')"; fi
}
expect_has() { # name haystack needle
    case "$2" in *"$3"*) ok ;; *) bad "$1 (no '$3' in: $2)" ;; esac
}
expect_lacks() { # name haystack needle
    case "$2" in *"$3"*) bad "$1 (found '$3' in: $2)" ;; *) ok ;; esac
}
expect_file() { # name path
    if [ -e "$2" ]; then ok; else bad "$1 ($2 is missing)"; fi
}
expect_no_file() { # name path
    if [ ! -e "$2" ]; then ok; else bad "$1 ($2 exists)"; fi
}

# ---------------------------------------------------------------------------------------------
# The stubs.
# ---------------------------------------------------------------------------------------------
STUBS="$T/stubs"
mkdir -p "$STUBS"

# STUB_FAIL is a comma-separated list of subcommands that must fail: "copyto", or "config update"
# for a two-word one.
cat > "$STUBS/rclone" <<'STUB'
#!/bin/bash
# A fake rclone. "Drive" is the directory $STUB_DIR/drive and each remote's configuration is the
# section of the INI file $STUB_DIR/rclone.conf. Every call is appended to $STUB_DIR/calls.log.
echo "$*" >> "$STUB_DIR/calls.log"
case ",${STUB_FAIL:-}," in *",$1,"*|*",$1 ${2:-},"*) exit 1 ;; esac
drive="$STUB_DIR/drive"
cf="$STUB_DIR/rclone.conf"
(umask 077; touch "$cf")
# The configuration is one INI file, as rclone's is; `config file` says where.
section() { awk -v n="[$1]" '$0==n{f=1;next} /^\[/{f=0} f' "$cf" | grep . || true; }
drop() { awk -v n="[$1]" '$0==n{f=1;next} /^\[/{f=0} !f' "$cf" > "$cf.new"; mv "$cf.new" "$cf"; }
setkey() { # name key value
    local body
    body=$(section "$1" | grep -v "^$2 = " || true)
    drop "$1"
    { echo "[$1]"; [ -z "$body" ] || echo "$body"; echo "$2 = $3"; } >> "$cf"
}
iso() { date -u -d "@$(stat -c %Y -- "$1")" +%Y-%m-%dT%H:%M:%S.000000000Z; }
case "$1" in
    version)
        case "${STUB_RCLONE_VERSION:-1.76.0}" in
            [0-9]*) echo "rclone v${STUB_RCLONE_VERSION:-1.76.0}" ;;
            *) echo "rclone ${STUB_RCLONE_VERSION}" ;;
        esac
        echo "- os/version: stub" ;;
    config)
        case "$2" in
            file) echo "Configuration file is stored at:"; echo "$cf" ;;
            show) body=$(section "$3"); [ -n "$body" ] || exit 1; echo "$body" ;;
            delete) drop "$3" ;;
            reconnect)
                # STUB_RECONNECT_ERR_ONCE: the first consent prints this and fails.
                if [ -e "$STUB_DIR/reconnect_err_once" ]; then
                    cat "$STUB_DIR/reconnect_err_once" >&2; rm -f "$STUB_DIR/reconnect_err_once"; exit 1
                fi
                echo reconnected > "$STUB_DIR/reconnected"
                setkey "${3%:}" token '{"access_token":"stub"}' ;;
            create|update)
                action="$2"; name="$3"; shift 3
                # STUB_KEEP_SCOPE makes an update report success and change nothing.
                if [ "$action" = update ] && [ -n "${STUB_KEEP_SCOPE:-}" ]; then exit 0; fi
                # `create NAME TYPE ...` has the type as its first remaining argument.
                if [ "$action" = create ] && [ "${1#*=}" = "$1" ]; then setkey "$name" type "$1"; shift; fi
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --non-interactive) shift ;;
                        *=*) setkey "$name" "${1%%=*}" "${1#*=}"; shift ;;
                        *) setkey "$name" "$1" "${2:-}"; shift 2 ;;
                    esac
                done ;;
        esac ;;
    about)
        if [ -e "$STUB_DIR/about_err_once" ]; then
            cat "$STUB_DIR/about_err_once" >&2; rm -f "$STUB_DIR/about_err_once"; exit 1
        fi
        echo "Total: 15 GiB" ;;
    lsjson)
        rel="${2#*:}"
        [ -e "$drive/$rel" ] || exit 3
        if [ -n "${STUB_LSJSON_EMPTY:-}" ]; then echo '[]'; exit 0; fi
        printf '[{"Path":"%s","Name":"%s","Size":1,"ModTime":"%s","IsDir":false}]\n' \
            "$rel" "$(basename -- "$rel")" "$(iso "$drive/$rel")" ;;
    copyto)
        rel="${2#*:}"
        [ -e "$drive/$rel" ] || exit 3
        mkdir -p -- "$(dirname -- "$3")"
        cp -p -- "$drive/$rel" "$3" ;;
    copy)
        rel="${2#*:}"
        [ -d "$drive/$rel" ] || exit 3
        mkdir -p -- "$3"
        cp -au -- "$drive/$rel/." "$3/" ;;
    rc)
        echo "rc-env user=${RCLONE_RC_USER:-} pass=${RCLONE_RC_PASS:-}" >> "$STUB_DIR/env.log" ;;
    mount)
        echo "mount-env rc=${RCLONE_RC:-} addr=${RCLONE_RC_ADDR:-} user=${RCLONE_RC_USER:-} pass=${RCLONE_RC_PASS:-}" \
            >> "$STUB_DIR/env.log" ;;
esac
exit 0
STUB

cat > "$STUBS/mountpoint" <<'STUB'
#!/bin/bash
[ -e "$STUB_DIR/mounted" ]
STUB

for name in fusermount3 fusermount; do
    cat > "$STUBS/$name" <<STUB
#!/bin/bash
echo "$name \$*" >> "\$STUB_DIR/calls.log"
case ",\${STUB_FAIL:-}," in *",$name,"*) exit 1 ;; esac
rm -f -- "\$STUB_DIR/mounted"
STUB
done

cat > "$STUBS/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$STUB_DIR/calls.log"
[ "${1:-}" = --user ] && [ "${2:-}" = is-active ] && { echo "${STUB_TIMER:-inactive}"; exit 3; }
exit 0
STUB

cat > "$STUBS/xdg-open" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/open.log"
STUB

# What xdg-user-dir says when the person has set no Downloads folder: their home.
cat > "$STUBS/xdg-user-dir" <<'STUB'
#!/bin/bash
echo "${STUB_XDG_DOWNLOAD:-$HOME}"
STUB

cat > "$STUBS/notify-send" <<'STUB'
#!/bin/bash
echo "notify $*" >> "$STUB_DIR/notify.log"
STUB

cat > "$STUBS/gtk-update-icon-cache" <<'STUB'
#!/bin/bash
echo "gtk-update-icon-cache $*" >> "$STUB_DIR/calls.log"
STUB

# A stand-in for the oursync program, for oursync-nemo's tests: succeeds or fails on request.
cat > "$STUBS/oursync-fake" <<'STUB'
#!/bin/bash
echo "oursync $*" >> "$STUB_DIR/calls.log"
if [ -n "${FAKE_OURSYNC_FAILS:-}" ]; then
    echo "first line" >&2
    echo "the reason it failed" >&2
    exit 1
fi
exit 0
STUB
chmod +x "$STUBS"/*

# A PATH with the ordinary tools and none of the stubs, for the "not installed" cases.
BARE="$T/bare"
mkdir -p "$BARE"
for tool in bash sh sed head cat mkdir chmod dirname basename readlink tr base64 rm mv sort \
            grep awk date stat find du cut wc cp env touch ln df numfmt uniq ls tail mktemp git tee; do
    found=$(PATH="$ORIGINAL_PATH" command -v "$tool" || true)
    [ -n "$found" ] && ln -sf -- "$found" "$BARE/$tool"
done

# ---------------------------------------------------------------------------------------------
# One fresh world per case.
# ---------------------------------------------------------------------------------------------
CASE_NUMBER=0
fresh() {
    CASE_NUMBER=$((CASE_NUMBER + 1))
    W="$T/case$CASE_NUMBER"
    mkdir -p "$W/home" "$W/stub/drive"
    export HOME="$W/home" XDG_CONFIG_HOME="$W/home/.config" XDG_CACHE_HOME="$W/home/.cache" \
           XDG_DATA_HOME="$W/home/.local/share" STUB_DIR="$W/stub"
    PATH="$STUBS:$BARE"; export PATH
    unset OURSYNC_CONF REMOTE UNION MOUNT PIN_DIR PIN_LIST CACHE_DIR CACHE_MAX_SIZE CACHE_MAX_AGE \
          RC_ADDR RC_USER RC_PASS READ_ONLY WRITE_BACK BWLIMIT STUB_FAIL STUB_RCLONE_VERSION \
          STUB_LSJSON_EMPTY STUB_KEEP_SCOPE STUB_TIMER FAKE_OURSYNC_FAILS OURSYNC_BIN \
          STUB_XDG_DOWNLOAD DISPLAY WAYLAND_DISPLAY SSH_CONNECTION
    MOUNT_DIR="$HOME/Drive"
    PIN="$HOME/.local/share/oursync/pinned"
    CONF_FILE="$HOME/.config/oursync/oursync.conf"
    PINS="$HOME/.config/oursync/pins"
    mkdir -p "$MOUNT_DIR"
}

# A configuration file, one assignment per argument.
conf() {
    mkdir -p -- "$(dirname -- "$CONF_FILE")"
    printf '%s\n' "$@" > "$CONF_FILE"
}

# run COMMAND...: OUT, ERR and RC for one invocation.
run() {
    OUT=$("$@" 2> "$W/err" < /dev/null)
    RC=$?
    ERR=$(cat -- "$W/err")
}

# run_with INPUT COMMAND...: as run, with INPUT (printf %b) on standard input, for the prompts.
run_with() {
    local input="$1"; shift
    OUT=$(printf '%b' "$input" | "$@" 2> "$W/err")
    RC=$?
    ERR=$(cat -- "$W/err")
}

# A Google client JSON, as Google writes it: one line. client_file PATH KIND ID SECRET.
client_file() {
    mkdir -p -- "$(dirname -- "$1")"
    printf '{"%s":{"client_id":"%s","project_id":"p","auth_uri":"https://x","client_secret":"%s","redirect_uris":["http://localhost"]}}' \
        "$2" "$3" "$4" > "$1"
}

drive_put() { # relative-path content epoch
    mkdir -p -- "$(dirname -- "$STUB_DIR/drive/$1")"
    printf '%s\n' "$2" > "$STUB_DIR/drive/$1"
    touch -d "@${3:-1700000000}" -- "$STUB_DIR/drive/$1"
}
local_put() { # path content epoch
    mkdir -p -- "$(dirname -- "$1")"
    printf '%s\n' "$2" > "$1"
    touch -d "@${3:-1700000000}" -- "$1"
}
pins_set() { # kind<TAB>path lines are given as "k path" pairs
    mkdir -p -- "$(dirname -- "$PINS")"
    : > "$PINS"
    while [ $# -gt 1 ]; do printf '%s\t%s\n' "$1" "$2" >> "$PINS"; shift 2; done
}
calls() { cat -- "$STUB_DIR/calls.log" 2>/dev/null || true; }
mark_mounted() { : > "$STUB_DIR/mounted"; }
# A remote that exists, with its token unless the fourth argument is "no-token".
set_remote() { # name type scope [no-token]
    {
        printf '[%s]\ntype = %s\n' "$1" "$2"
        [ -z "${3:-}" ] || printf 'scope = %s\n' "$3"
        [ "${4:-}" = no-token ] || [ "$2" != drive ] || printf 'token = {"access_token":"x"}\n'
    } >> "$STUB_DIR/rclone.conf"
}
# The stub's configuration for one remote, as `rclone config show` prints it.
remote_conf() { awk -v n="[$1]" '$0==n{f=1;next} /^\[/{f=0} f' "$STUB_DIR/rclone.conf"; }

OURSYNC="$SRC/oursync"
SETUP="$SRC/oursync-setup"
NEMO="$SRC/oursync-nemo"
INSTALL="$SRC/install.sh"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: dispatch and help ---"
# ---------------------------------------------------------------------------------------------
fresh
run "$OURSYNC" version
expect_eq "version from a checkout says so" "oursync 0.0.0 (from source)" "$OUT"
run "$OURSYNC" --version
expect_eq "--version is the same" "oursync 0.0.0 (from source)" "$OUT"
run "$OURSYNC" help
expect_has "help lists pin" "$OUT" "oursync pin <path>"
run "$OURSYNC"
expect_has "no argument prints help" "$OUT" "oursync doctor"
run "$OURSYNC" frobnicate
expect_eq "an unknown command exits 2" 2 "$RC"
expect_has "and names the command" "$ERR" 'unknown command "frobnicate"'

# A shipped copy has its version substituted in.
sed -e 's|@VERSION@|3.4.5|' "$OURSYNC" > "$W/oursync-versioned"
chmod +x "$W/oursync-versioned"
run "$W/oursync-versioned" version
expect_eq "a substituted version is printed as it is" "oursync-versioned 3.4.5" "$OUT"

# The configuration file is read, from OURSYNC_CONF when it is set.
conf 'MOUNT=/nowhere/at/all'
run "$OURSYNC" status /nowhere/at/all/x.txt
expect_eq "OURSYNC_CONF-less default configuration is sourced" "streamed  x.txt" "$OUT"
printf 'MOUNT=/elsewhere\n' > "$W/other.conf"
OURSYNC_CONF="$W/other.conf" run "$OURSYNC" status /elsewhere/y.txt
expect_eq "OURSYNC_CONF names another configuration" "streamed  y.txt" "$OUT"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: which rclone is refused ---"
# ---------------------------------------------------------------------------------------------
fresh
for version in 1.67.0 1.68.1 1.70.3 1.76.0 1.100.0 2.0.0; do
    STUB_RCLONE_VERSION=$version run "$OURSYNC" check-rclone
    expect_eq "rclone $version is accepted" 0 "$RC"
done
for version in 1.60.1 1.62.2 1.66.0 1.9.0; do
    STUB_RCLONE_VERSION=$version run "$OURSYNC" check-rclone
    expect_eq "rclone $version is refused" 1 "$RC"
    expect_has "and refused as too old" "$ERR" "too old for OurSync"
done
STUB_RCLONE_VERSION=1.68.0 run "$OURSYNC" check-rclone
expect_eq "rclone 1.68.0 is refused" 1 "$RC"
expect_has "by name, for the control port" "$ERR" "cannot read the mount's control-port address"
STUB_RCLONE_VERSION=2026-dev-build run "$OURSYNC" check-rclone
expect_eq "an unrecognisable build is let through rather than refused" 0 "$RC"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: rel_path, status and the argument checks ---"
# ---------------------------------------------------------------------------------------------
fresh
run "$OURSYNC" status
expect_eq "status with nothing to look at is a usage error" 1 "$RC"
expect_has "and gives the usage" "$ERR" "usage: oursync status"
run "$OURSYNC" status "$MOUNT_DIR/a/b.txt"
expect_eq "an unpinned file is streamed" "streamed  a/b.txt" "$OUT"
local_put "$PIN/a/b.txt" x
run "$OURSYNC" status "$MOUNT_DIR/a/b.txt" "$MOUNT_DIR/a/../c.txt"
expect_eq "a pinned file is pinned and a dot-dot path is normalised first" \
    "pinned    a/b.txt
streamed  c.txt" "$OUT"
run "$OURSYNC" status "$MOUNT_DIR/../escape.txt"
expect_eq "a path that climbs out of the mount is refused" 1 "$RC"
expect_has "naming the mount" "$ERR" "not inside $MOUNT_DIR"
run "$OURSYNC" status /etc/passwd
expect_eq "a path outside the mount is refused" 1 "$RC"

# The mount root is not a path under the mount. Before it was refused, `pin ~/Drive` handed rclone
# the whole absolute path as if it were a path in Drive (gdrive-own:/home/.../Drive).
mark_mounted
for root in "$MOUNT_DIR" "$MOUNT_DIR/" "$MOUNT_DIR/." "$MOUNT_DIR/sub/.."; do
    : > "$STUB_DIR/calls.log"
    for verb in pin unpin refresh status; do
        run "$OURSYNC" "$verb" "$root"
        expect_eq "$verb '$root' is refused" 1 "$RC"
        expect_has "$verb '$root' says it is the mount root" "$ERR" "the mount root itself"
    done
    expect_eq "rclone was never called for '$root'" "" "$(calls)"
done
rm -f "$STUB_DIR/mounted"

run "$OURSYNC" pin
expect_has "pin with no argument gives the usage" "$ERR" "usage: oursync pin"
run "$OURSYNC" unpin
expect_has "unpin with no argument gives the usage" "$ERR" "usage: oursync unpin"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: pin ---"
# ---------------------------------------------------------------------------------------------
fresh
drive_put docs/a.txt "alpha"
run "$OURSYNC" pin "$MOUNT_DIR/docs/a.txt"
expect_eq "pin refuses when the mount is not mounted" 1 "$RC"
expect_has "and says to mount it" "$ERR" "is not mounted"
expect_no_file "and copies nothing" "$PIN/docs/a.txt"

mark_mounted
run "$OURSYNC" pin "$MOUNT_DIR/docs/a.txt"
expect_eq "pin succeeds" 0 "$RC"
expect_eq "the pinned copy is Drive's bytes" "alpha" "$(cat "$PIN/docs/a.txt" 2>/dev/null)"
expect_eq "its modification time is Drive's, so a refresh sees them equal" \
    "$(stat -c %Y "$STUB_DIR/drive/docs/a.txt")" "$(stat -c %Y "$PIN/docs/a.txt")"
expect_eq "the pin is listed with its kind" "f	docs/a.txt" "$(cat "$PINS")"
expect_has "and announced" "$ERR" "pinned: docs/a.txt"
expect_has "copied with copyto from the remote, not through the mount" "$(calls)" "copyto gdrive-own:docs/a.txt"
expect_has "and the file is copied verbosely-quiet" "$(calls)" "--log-level ERROR"

run "$OURSYNC" pin "$MOUNT_DIR/docs/a.txt"
expect_has "pinning twice says so" "$ERR" "already pinned: docs/a.txt"
expect_eq "and lists it once" 1 "$(grep -c . "$PINS")"

# A directory pin is a copy of the tree, recorded as a directory.
fresh; mark_mounted
drive_put photos/1.jpg one; drive_put photos/sub/2.jpg two
mkdir -p "$MOUNT_DIR/photos"
run "$OURSYNC" pin "$MOUNT_DIR/photos"
expect_eq "a directory pin succeeds" 0 "$RC"
expect_eq "it brings the tree" "two" "$(cat "$PIN/photos/sub/2.jpg" 2>/dev/null)"
expect_eq "and is recorded as a directory" "d	photos" "$(cat "$PINS")"
expect_has "using copy" "$(calls)" "copy gdrive-own:photos"

# A failed transfer dies rather than recording a pin.
fresh; mark_mounted
drive_put docs/a.txt alpha
STUB_FAIL=copyto run "$OURSYNC" pin "$MOUNT_DIR/docs/a.txt"
expect_eq "a failed file copy is an error" 1 "$RC"
expect_has "naming the file" "$ERR" "pin failed: docs/a.txt"
expect_no_file "and records no pin" "$PINS"
mkdir -p "$MOUNT_DIR/photos"; drive_put photos/1.jpg one
STUB_FAIL=copy run "$OURSYNC" pin "$MOUNT_DIR/photos"
expect_has "a failed directory copy is an error too" "$ERR" "pin failed: photos"

run "$OURSYNC" pin "$HOME/not-the-mount.txt"
expect_eq "a path outside the mount is refused by pin" 1 "$RC"

# With a control password, a pin tells the mount to look again, at the parent and not at the root
# of Drive; for a file in the root it asks for the root, which is addressed by omitting dir.
fresh; mark_mounted
conf 'RC_PASS=hunter2' 'RC_ADDR=127.0.0.1:9999'
drive_put docs/a.txt alpha; drive_put top.txt beta
run "$OURSYNC" pin "$MOUNT_DIR/docs/a.txt" "$MOUNT_DIR/top.txt"
expect_has "a pin refreshes the file's parent directory" "$(calls)" "rc --rc-addr 127.0.0.1:9999 vfs/refresh dir=docs"
expect_eq "a pin in the root refreshes the root, addressed with no dir" "rc --rc-addr 127.0.0.1:9999 vfs/refresh" \
    "$(calls | grep -x 'rc --rc-addr 127.0.0.1:9999 vfs/refresh')"
expect_lacks "the password is never on a command line" "$(calls)" "hunter2"
expect_has "it reaches rclone through the environment" "$(cat "$STUB_DIR/env.log")" "pass=hunter2"
expect_has "with the configured user" "$(cat "$STUB_DIR/env.log")" "user=oursync"
fresh; mark_mounted; drive_put docs/a.txt alpha
run "$OURSYNC" pin "$MOUNT_DIR/docs/a.txt"
expect_lacks "with no control password no rc call is made" "$(calls)" "rc --rc-addr"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: unpin ---"
# ---------------------------------------------------------------------------------------------
fresh; mark_mounted
drive_put docs/a.txt alpha
"$OURSYNC" pin "$MOUNT_DIR/docs/a.txt" 2> /dev/null
run "$OURSYNC" unpin "$MOUNT_DIR/docs/a.txt"
expect_eq "unpin succeeds" 0 "$RC"
expect_no_file "the local copy is gone" "$PIN/docs/a.txt"
expect_no_file "and so is the directory it leaves empty" "$PIN/docs"
expect_eq "and the list is empty" "0" "$(grep -c . "$PINS" || true)"
expect_has "announced" "$ERR" "unpinned: docs/a.txt"
expect_file "Drive's copy is untouched" "$STUB_DIR/drive/docs/a.txt"

run "$OURSYNC" unpin "$MOUNT_DIR/docs/a.txt"
expect_eq "unpinning what is not pinned is not an error" 0 "$RC"
expect_has "and says so" "$ERR" "not pinned: docs/a.txt"
pins_set f docs/ghost.txt f keep/me.txt
run "$OURSYNC" unpin "$MOUNT_DIR/docs/ghost.txt"
expect_eq "a stale list entry for a missing file is dropped" "f	keep/me.txt" "$(cat "$PINS")"

# The local copy is the only one: refuse to delete it.
local_put "$PIN/only/here.txt" precious
run "$OURSYNC" unpin "$MOUNT_DIR/only/here.txt"
expect_eq "unpin refuses when Drive has no copy" 1 "$RC"
expect_has "and explains" "$ERR" "the local copy is the only one"
expect_file "and deletes nothing" "$PIN/only/here.txt"

# A symlink inside the pin directory must not let unpin delete something outside it.
mkdir -p "$W/outside"; printf 'keep\n' > "$W/outside/file"
mkdir -p "$PIN"; ln -s "$W/outside" "$PIN/evil"
run "$OURSYNC" unpin "$MOUNT_DIR/evil/file"
expect_eq "a path that resolves outside the pin directory is refused" 1 "$RC"
expect_has "naming the pin directory" "$ERR" "refusing to remove something outside"
expect_file "and the file outside survives" "$W/outside/file"

run "$OURSYNC" unpin "$HOME/not-the-mount.txt"
expect_eq "a path outside the mount is refused by unpin" 1 "$RC"

fresh; mark_mounted
conf 'RC_PASS=pw'
drive_put docs/a.txt alpha
"$OURSYNC" pin "$MOUNT_DIR/docs/a.txt" 2> /dev/null
run "$OURSYNC" unpin "$MOUNT_DIR/docs/a.txt"
expect_has "unpin also tells the mount to look again" "$(calls)" "vfs/refresh dir=docs"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: refresh, where Drive wins and a newer local copy is a conflict ---"
# ---------------------------------------------------------------------------------------------
OLD=1700000000; NEW=1700000500

fresh
run "$OURSYNC" refresh
expect_eq "refresh with nothing pinned succeeds" 0 "$RC"
expect_has "and says so" "$ERR" "nothing pinned"
run "$OURSYNC" refresh -q
expect_eq "quiet refresh with nothing pinned is silent" "" "$ERR"
run "$OURSYNC" refresh --bogus
expect_eq "an unknown option is an error" 1 "$RC"
expect_has "naming it" "$ERR" "unknown option for refresh: --bogus"

# Equal times mean equal content.
fresh
drive_put f.txt "same" $OLD; local_put "$PIN/f.txt" "same" $OLD; pins_set f f.txt
run "$OURSYNC" refresh
expect_eq "equal times: nothing to do" 0 "$RC"
expect_eq "summary counts one checked" "1 checked, 0 updated from Drive, 0 conflict(s), 0 no longer in Drive" "$OUT"
run "$OURSYNC" refresh --quiet
expect_eq "quiet and clean prints no summary" "" "$OUT"

# Drive is newer: Drive wins.
fresh
drive_put f.txt "from drive" $NEW; local_put "$PIN/f.txt" "stale" $OLD; pins_set f f.txt
run "$OURSYNC" refresh
expect_eq "Drive newer: refresh succeeds" 0 "$RC"
expect_eq "the local copy takes Drive's bytes" "from drive" "$(cat "$PIN/f.txt")"
expect_has "and says it did" "$ERR" "updated from Drive: f.txt"
expect_has "counted" "$OUT" "1 updated from Drive"
local_put "$PIN/f.txt" "stale" $OLD
run "$OURSYNC" refresh -q
expect_eq "quiet suppresses the line" "" "$ERR"
expect_eq "and the copy was still updated" "from drive" "$(cat "$PIN/f.txt")"

# Local is newer: a conflict, reported, never overwritten.
fresh
drive_put f.txt "from drive" $OLD; local_put "$PIN/f.txt" "my edit" $NEW; pins_set f f.txt
run "$OURSYNC" refresh
expect_eq "locally newer: refresh reports failure" 1 "$RC"
expect_has "as a conflict" "$ERR" "CONFLICT: f.txt is newer on disk"
expect_has "saying nothing was overwritten" "$ERR" "nothing was overwritten"
expect_eq "and the local edit survives" "my edit" "$(cat "$PIN/f.txt")"
expect_has "counted" "$OUT" "1 conflict(s)"
run "$OURSYNC" refresh -q
expect_eq "a conflict fails even when quiet" 1 "$RC"
expect_has "and quiet still prints the summary for it" "$OUT" "1 conflict(s)"

# Explicit paths, a file and a directory, instead of the list.
fresh
drive_put f.txt "from drive" $NEW; local_put "$PIN/f.txt" "stale" $OLD
drive_put d/x.txt "x" $OLD
run "$OURSYNC" refresh "$MOUNT_DIR/f.txt" "$MOUNT_DIR/d"
expect_eq "explicit paths need no list" 0 "$RC"
expect_eq "the file was refreshed" "from drive" "$(cat "$PIN/f.txt")"
mkdir -p "$PIN/d"
run "$OURSYNC" refresh "$MOUNT_DIR/d"
expect_eq "an existing directory is refreshed as a directory" "x" "$(cat "$PIN/d/x.txt" 2>/dev/null)"
run "$OURSYNC" refresh -- "$MOUNT_DIR/f.txt"
expect_eq "-- ends the options" 0 "$RC"
run "$OURSYNC" refresh "$HOME/outside.txt"
expect_eq "a path outside the mount is refused by refresh" 1 "$RC"

# A pinned directory takes what Drive has newer and leaves a newer local file alone.
fresh
drive_put d/new.txt "n" $NEW; drive_put d/mine.txt "drive's" $OLD
local_put "$PIN/d/mine.txt" "local's" $NEW
pins_set d d
run "$OURSYNC" refresh
expect_eq "a directory pin pulls what is new" "n" "$(cat "$PIN/d/new.txt" 2>/dev/null)"
expect_eq "and keeps a locally newer file" "local's" "$(cat "$PIN/d/mine.txt")"
expect_has "using --update" "$(calls)" "--update"
STUB_FAIL=copy run "$OURSYNC" refresh
expect_has "a failed directory read is reported" "$ERR" "refresh: could not read d from gdrive-own"
fresh; conf 'RC_PASS=pw'; drive_put d/new.txt "n" $NEW; pins_set d d
run "$OURSYNC" refresh
expect_has "a directory refresh tells the mount to look again" "$(calls)" "vfs/refresh"

# Pinned but gone from disk.
fresh
drive_put f.txt "remote" $OLD; pins_set f f.txt
run "$OURSYNC" refresh
expect_eq "a missing local copy is fetched again" "remote" "$(cat "$PIN/f.txt" 2>/dev/null)"
expect_has "and counted as updated" "$OUT" "1 updated from Drive"
rm -f "$PIN/f.txt"
STUB_FAIL=copyto run "$OURSYNC" refresh
expect_has "a failed fetch is reported" "$ERR" "refresh: could not fetch f.txt"

fresh
pins_set f gone.txt f keep.txt; drive_put keep.txt k $OLD; local_put "$PIN/keep.txt" k $OLD
run "$OURSYNC" refresh
expect_eq "missing on both sides: the stale entry is dropped" "f	keep.txt" "$(cat "$PINS")"
expect_has "and counted as gone" "$OUT" "1 no longer in Drive"

# On disk, absent from Drive: the local copy is the only one, so keep the pin and warn.
fresh
local_put "$PIN/orphan.txt" "o" $OLD; pins_set f orphan.txt
run "$OURSYNC" refresh
expect_has "a pin whose Drive copy is gone is warned about" "$ERR" "no longer in gdrive-own - the local copy is the only one"
expect_file "and kept" "$PIN/orphan.txt"
expect_eq "and stays listed" "f	orphan.txt" "$(cat "$PINS")"

# Drive replied but gave no time.
fresh
drive_put f.txt x $OLD; local_put "$PIN/f.txt" x $OLD; pins_set f f.txt
STUB_LSJSON_EMPTY=1 run "$OURSYNC" refresh
expect_has "a listing with no ModTime is treated as gone" "$ERR" "no longer in gdrive-own"

# Drive newer but the copy fails.
fresh
drive_put f.txt "from drive" $NEW; local_put "$PIN/f.txt" "stale" $OLD; pins_set f f.txt
STUB_FAIL=copyto run "$OURSYNC" refresh
expect_has "a failed update is reported" "$ERR" "refresh: could not update f.txt"
expect_eq "and leaves the local copy" "stale" "$(cat "$PIN/f.txt")"

# Blank and malformed list lines are skipped, not trusted.
fresh
drive_put f.txt x $OLD; local_put "$PIN/f.txt" x $OLD
mkdir -p "$(dirname "$PINS")"; printf '\nf\nf\tf.txt\n' > "$PINS"
run "$OURSYNC" refresh
expect_has "blank and path-less lines are skipped" "$OUT" "1 checked"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: list ---"
# ---------------------------------------------------------------------------------------------
fresh
run "$OURSYNC" list
expect_has "no pin directory: nothing pinned" "$ERR" "nothing pinned"
mkdir -p "$PIN"
run "$OURSYNC" ls
expect_has "an empty pin directory: nothing pinned" "$ERR" "nothing pinned"
head -c 3000 /dev/zero > "$PIN/big.bin"; mkdir -p "$PIN/sub"; printf 'abc' > "$PIN/sub/small.txt"
pins_set f big.bin f sub/small.txt
run "$OURSYNC" list
expect_has "the largest file is listed first" "$(printf '%s\n' "$OUT" | head -1)" "big.bin"
expect_has "and the small one with its path" "$OUT" "sub/small.txt"
expect_has "the summary counts files and pins" "$OUT" "2 file(s) on disk, from 2 pin(s)"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: mount and unmount ---"
# ---------------------------------------------------------------------------------------------
fresh
mark_mounted
run "$OURSYNC" mount
expect_has "an already-mounted mount says so" "$ERR" "already mounted at"
expect_lacks "and does not mount again" "$(calls)" "mount "

fresh
STUB_RCLONE_VERSION=1.60.1 run "$OURSYNC" mount
expect_eq "mount refuses a too-old rclone" 1 "$RC"
expect_lacks "before running rclone mount" "$(calls)" "mount drive-pinned"

fresh
conf 'RC_PASS=s3cret' 'BWLIMIT=1M' 'WRITE_BACK=30s' 'READ_ONLY=no'
run "$OURSYNC" mount --extra-flag
expect_eq "mount succeeds" 0 "$RC"
mount_line=$(calls | grep '^mount ')
expect_has "mounts the union at the mount point" "$mount_line" "mount drive-pinned: $MOUNT_DIR"
expect_has "writable mounts are in place" "$mount_line" "--inplace"
for flag in "--vfs-cache-mode full" "--cache-dir $HOME/.cache/oursync" "--vfs-cache-max-size 20G" \
            "--vfs-cache-max-age 72h" "--vfs-read-chunk-size 64M" "--vfs-read-chunk-size-limit 2G" \
            "--dir-cache-time 5m" "--poll-interval 1m" "--umask 022"; do
    expect_has "the mount is given $flag" "$mount_line" "$flag"
done
expect_has "with the configured write-back delay" "$mount_line" "--vfs-write-back 30s"
expect_has "and bandwidth limit" "$mount_line" "--bwlimit 1M"
expect_has "and the caller's extra flags" "$mount_line" "--extra-flag"
expect_lacks "never read-only here" "$mount_line" "--read-only"
expect_lacks "the control password is not on the command line" "$mount_line" "s3cret"
expect_has "it goes in the environment" "$(cat "$STUB_DIR/env.log")" "mount-env rc=true addr=127.0.0.1:5572 user=oursync pass=s3cret"
expect_file "the pin directory is created" "$PIN"
expect_file "and the cache directory" "$HOME/.cache/oursync"

fresh
set_remote gdrive-own drive drive.readonly
run "$OURSYNC" mount
mount_line=$(calls | grep '^mount ')
expect_has "a read-only token gives a read-only mount" "$mount_line" "--read-only"
expect_lacks "without --inplace" "$mount_line" "--inplace"
expect_has "and explains" "$ERR" "will be read-only: gdrive-own has scope 'drive.readonly'"
expect_lacks "with no bandwidth limit unless asked" "$mount_line" "--bwlimit"
expect_lacks "and no control environment when there is no password" "$(cat "$STUB_DIR/env.log")" "rc=true"

fresh
set_remote gdrive-own drive drive
run "$OURSYNC" mount
expect_lacks "a read-write token gives a writable mount" "$(calls)" "--read-only"
fresh; conf 'READ_ONLY=yes'
run "$OURSYNC" mount
expect_has "READ_ONLY=yes forces it" "$(calls)" "--read-only"

fresh
run "$OURSYNC" unmount
expect_has "unmounting what is not mounted says so" "$ERR" "is not mounted"
expect_eq "and succeeds" 0 "$RC"
mark_mounted
run "$OURSYNC" unmount
expect_has "unmount uses fusermount3" "$(calls)" "fusermount3 -u $MOUNT_DIR"
expect_has "and says so" "$ERR" "unmounted"
mark_mounted
STUB_FAIL=fusermount3 run "$OURSYNC" umount
expect_has "it falls back to fusermount" "$(calls)" "fusermount -u"
expect_eq "which works" 0 "$RC"
mark_mounted
STUB_FAIL=fusermount3,fusermount run "$OURSYNC" unmount
expect_eq "unmount fails when both fail" 1 "$RC"
expect_has "and says it could not" "$ERR" "could not unmount"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: doctor ---"
# ---------------------------------------------------------------------------------------------
fresh
run "$OURSYNC" doctor
expect_eq "doctor always exits 0" 0 "$RC"
expect_has "it reports the version" "$OUT" "oursync      0.0.0 (from source)"
expect_has "and a missing configuration" "$OUT" "(missing, using defaults)"
expect_has "and a missing remote" "$ERR" "PROBLEM: no rclone remote called 'gdrive-own'"
expect_has "and that nothing is mounted" "$ERR" "is not mounted"
expect_has "and the missing control password" "$ERR" "no control password"
expect_has "and the timer state" "$OUT" "inactive"
expect_lacks "and does not claim all is well" "$ERR" "no problems found"

fresh
mark_mounted; conf 'RC_PASS=pw' 'BWLIMIT=2M'
set_remote gdrive-own drive drive.readonly
set_remote drive-pinned union ""; printf 'upstreams = a:nc b:\n' >> "$STUB_DIR/rclone.conf"
mkdir -p "$PIN" "$HOME/.cache/oursync"; printf 'x' > "$PIN/f"
pins_set f f
STUB_TIMER=active run "$OURSYNC" doctor
expect_has "a read-only remote is noted" "$ERR" "NOTE: gdrive-own is read-only"
expect_has "the mount is shown mounted and read-only" "$OUT" "mounted, READ-ONLY"
expect_has "the union's upstreams are shown" "$OUT" "upstreams=a:nc b:"
expect_has "the bandwidth limit is shown" "$OUT" ", bwlimit 2M"
expect_has "the control address is shown" "$OUT" "127.0.0.1:5572"
expect_has "the timer is shown active" "$OUT" "active"
expect_has "pins are counted" "$OUT" "1 listed in"
expect_has "and nothing else is wrong" "$ERR" "no problems found"
fresh
STUB_RCLONE_VERSION=1.60.1 run "$OURSYNC" doctor
expect_has "doctor reports an unusable rclone as a problem" "$ERR" "too old for OurSync"
PATH="$BARE" run "$OURSYNC" doctor
expect_has "doctor reports a missing rclone" "$ERR" "PROBLEM: rclone is not installed"

# The client behind the remote: its project, its file's kind, and what doctor will not pretend.
fresh
set_remote gdrive-own drive drive
printf 'client_id = 424242-abc.apps.googleusercontent.com\n' >> "$STUB_DIR/rclone.conf"
client_file "$HOME/.config/oursync/client_secret.json" installed 424242-abc.apps.googleusercontent.com s
run "$OURSYNC" doctor
expect_has "doctor reports the project number" "$OUT" "client       project 424242, file desktop"
expect_has "it does not claim to know the publishing status" "$OUT" "not readable from here"
expect_has "and links to where it is, in the project" "$OUT" "auth/audience?project=424242"
expect_has "naming the seven-day expiry" "$OUT" "7 days"
client_file "$HOME/.config/oursync/client_secret.json" web 424242-abc.apps.googleusercontent.com s
run "$OURSYNC" doctor
expect_has "a Web client file is a problem" "$ERR" "PROBLEM: $HOME/.config/oursync/client_secret.json is a Web application client"
fresh
set_remote gdrive-own drive drive
run "$OURSYNC" doctor
expect_has "a remote with no client of its own says so" "$OUT" "rclone's built-in"
expect_lacks "and has no publishing line" "$OUT" "publishing"

echo "--- oursync: the client-file checks oursync-setup relies on ---"
fresh
client_file "$W/d.json" installed 99-z.apps.googleusercontent.com topsecret
run "$OURSYNC" check-client "$W/d.json"
expect_has "a Desktop client is recognised" "$OUT" "kind=desktop"
expect_has "its id is read" "$OUT" "client_id=99-z.apps.googleusercontent.com"
expect_has "its project number is read" "$OUT" "project=99"
expect_has "its secret is noticed" "$OUT" "has_secret=yes"
expect_lacks "but never printed" "$OUT" "topsecret"
printf '{\n  "web": {\n    "client_id": "7-w",\n    "client_secret": "s"\n  }\n}\n' > "$W/w.json"
run "$OURSYNC" check-client "$W/w.json"
expect_has "a Web client over many lines is recognised" "$OUT" "kind=web"
printf '{"installed":{"client_id":"nohyphen"}}' > "$W/n.json"
run "$OURSYNC" check-client "$W/n.json"
expect_has "an id with no project prefix has none" "$OUT" "project=
"
expect_has "and no secret" "$OUT" "has_secret=no"
printf '{"installed":{"client_id":"x1-a","client_secret":"s"}}' > "$W/n.json"
run "$OURSYNC" check-client "$W/n.json"
expect_has "a non-numeric prefix is not a project" "$OUT" "project=
"
printf 'hello' > "$W/n.json"
run "$OURSYNC" check-client "$W/n.json"
expect_has "anything else is unknown" "$OUT" "kind=unknown"
run "$OURSYNC" check-client "$W/missing.json"
expect_eq "an unreadable file is an error" 1 "$RC"
run "$OURSYNC" client-project 123-abc
expect_eq "client-project gives the number" "123" "$OUT"
run "$OURSYNC" client-project ""
expect_eq "and nothing for nothing" "" "$OUT"

# ---------------------------------------------------------------------------------------------
echo "--- oursync: setup is found beside it, or on the PATH, or not at all ---"
# ---------------------------------------------------------------------------------------------
fresh
run "$OURSYNC" setup --help
expect_has "the sibling oursync-setup is used" "$OUT" "oursync-setup - create or re-authorise"
mkdir -p "$W/lone" "$W/onpath"
sed -e 's|@VERSION@|1.0.0|' "$OURSYNC" > "$W/lone/oursync"; chmod +x "$W/lone/oursync"
PATH="$STUBS:$BARE" run "$W/lone/oursync" setup --help
expect_eq "with no sibling and none on the PATH it says so" 1 "$RC"
expect_has "naming it" "$ERR" "oursync-setup is not installed"
printf '#!/bin/bash\necho on-path "$@"\n' > "$W/onpath/oursync-setup"; chmod +x "$W/onpath/oursync-setup"
PATH="$W/onpath:$STUBS:$BARE" run "$W/lone/oursync" setup --scope drive
expect_eq "with none beside it, the one on the PATH is used" "on-path --scope drive" "$OUT"

# ---------------------------------------------------------------------------------------------
echo "--- oursync-setup: arguments and the cases that stop early ---"
# ---------------------------------------------------------------------------------------------
fresh
run "$SETUP" --help
expect_eq "--help succeeds" 0 "$RC"
expect_has "and shows the default client path" "$OUT" "$HOME/.config/oursync/client_secret.json"
run "$SETUP" -h
expect_has "-h is the same" "$OUT" "--force-reauth"
run "$SETUP" --bogus
expect_eq "an unknown option is an error" 1 "$RC"
expect_has "naming it" "$ERR" "unknown option: --bogus"
run "$SETUP" --scope everything
expect_has "a bad scope is refused" "$ERR" "--scope must be drive or drive.readonly"
run "$SETUP" --scope=nonsense
expect_eq "in the = form too" 1 "$RC"
PATH="$BARE" run "$SETUP" --scope drive
expect_has "setup needs rclone" "$ERR" "rclone is not installed"

fresh
STUB_RCLONE_VERSION=1.60.1 run "$SETUP"
expect_eq "an rclone OurSync refuses stops setup" 1 "$RC"
expect_has "before anything is changed" "$ERR" "Nothing has been changed"
expect_no_file "and creates no configuration directory" "$HOME/.config/oursync"

# No oursync beside it and none on the PATH: warn, carry on.
fresh
mkdir -p "$W/alone"; cp "$SETUP" "$W/alone/oursync-setup"
run "$W/alone/oursync-setup" --client-secret "$W/none.json"
expect_has "no oursync to check the version with is a warning" "$ERR" "WARNING: cannot find the oursync program"
expect_has "and setup carries on to the missing client file" "$ERR" "no OAuth client JSON at $W/none.json"
mkdir -p "$W/withbin"; ln -s "$OURSYNC" "$W/withbin/oursync"
PATH="$W/withbin:$STUBS:$BARE" run "$W/alone/oursync-setup" --client-secret=
expect_lacks "an oursync on the PATH is used instead" "$ERR" "WARNING: cannot find"
expect_has "and an empty client path falls back to the guided steps" "$OUT" "Step 1 of 6"
# With no oursync to ask, a client file cannot be checked, and that is said rather than skipped.
client_file "$W/c.json" installed 1-a s
run "$W/alone/oursync-setup" --client-secret "$W/c.json"
expect_has "no oursync to check a client file with is an error" "$ERR" "cannot find the oursync program to check the client file"

# ---------------------------------------------------------------------------------------------
echo "--- oursync-setup: a new remote from a client file ---"
# ---------------------------------------------------------------------------------------------
fresh
printf '{"installed":{}}\n' > "$W/bad.json"
run "$SETUP" --client-secret "$W/bad.json"
expect_has "a client file without an id is refused" "$ERR" "has no client_id/client_secret"
expect_eq "and nothing was added to rclone" "" "$(remote_conf gdrive-own)"
printf '{"installed":{"client_id":"1-a"}}\n' > "$W/nosecret.json"
run "$SETUP" --client-secret "$W/nosecret.json"
expect_has "one with no secret is refused too" "$ERR" "has no client_id/client_secret"
printf 'not json at all\n' > "$W/junk.json"
run "$SETUP" --client-secret "$W/junk.json"
expect_has "a file that is not a client is refused" "$ERR" "is not a Google OAuth client file"
run "$SETUP" --client-secret "$W/missing.json"
expect_has "a path that is not there is said so" "$ERR" "no OAuth client JSON at $W/missing.json"

# A Web client fails later with redirect_uri_mismatch, so it is refused now, and says what to do.
client_file "$W/web.json" web 4242-web.apps.googleusercontent.com wsecret
run "$SETUP" --client-secret "$W/web.json"
expect_eq "a Web application client is refused" 1 "$RC"
expect_has "naming the failure it would have caused" "$ERR" "redirect_uri_mismatch"
expect_has "and the link that makes the right kind, in its own project" "$ERR" "console.cloud.google.com/auth/clients/create?project=4242"
expect_no_file "nothing is configured" "$STUB_DIR/open.log"

client_file "$W/client.json" installed 777-abc.apps.googleusercontent.com sec-456
run "$SETUP" --client-secret "$W/client.json"
expect_eq "a good client file creates the remote" 0 "$RC"
expect_has "announced" "$ERR" "created remote 'gdrive-own'"
expect_has "with the client id" "$(remote_conf gdrive-own)" "client_id = 777-abc.apps.googleusercontent.com"
expect_has "and the secret" "$(remote_conf gdrive-own)" "client_secret = sec-456"
expect_has "and the default scope, which can write" "$(remote_conf gdrive-own)" "scope = drive"
expect_has "and a token from the consent" "$(remote_conf gdrive-own)" "token = "
expect_lacks "the secret never reaches rclone's command line" "$(calls)" "sec-456"
expect_lacks "nor the client id" "$(calls)" "777-abc"
expect_has "the consent is a reconnect that asks nothing" "$(calls)" "config reconnect gdrive-own: --auto-confirm"
expect_has "the remote is checked with one cheap call" "$(calls)" "about gdrive-own:"
expect_has "and the result is reported" "$ERR" "Google Drive answered: gdrive-own works"
expect_has "the unverified-app warning is explained" "$ERR" "unverified app"
expect_eq "the client file is made private" "600" "$(stat -c %a "$W/client.json")"
expect_eq "and installed where setup keeps it, private" "600" "$(stat -c %a "$HOME/.config/oursync/client_secret.json")"
expect_has "the union is configured on both upstreams" "$(remote_conf drive-pinned)" "upstreams = $PIN:nc gdrive-own:"
expect_has "with the policies that keep a pin and Drive together" "$(remote_conf drive-pinned)" "action_policy = epall"
expect_has "and search_policy epall" "$(remote_conf drive-pinned)" "search_policy = epall"
expect_file "the user configuration is written" "$CONF_FILE"
expect_eq "readable only by its owner" "600" "$(stat -c %a "$CONF_FILE")"
expect_has "naming the remote" "$(cat "$CONF_FILE")" "REMOTE=gdrive-own"
password=$(sed -n 's/^RC_PASS=//p' "$CONF_FILE")
expect_eq "with a generated 24-character control password" 24 "${#password}"
expect_has "the finish tells how to start it" "$OUT" "systemctl --user enable --now oursync-mount.service"
expect_has "and says read-write" "$OUT" "read-write"
expect_lacks "the password is not echoed" "$OUT$ERR" "$password"

run "$SETUP" --client-secret "$W/client.json"
expect_has "a second run leaves the matching scope alone" "$ERR" "remote 'gdrive-own' already has scope 'drive'"
expect_has "keeps the configuration" "$ERR" "kept existing"
expect_eq "and the same password" "$password" "$(sed -n 's/^RC_PASS=//p' "$CONF_FILE")"

# Next to an rclone configuration that already holds other remotes, the new one is appended.
fresh
printf '[other]\ntype = s3\n' > "$STUB_DIR/rclone.conf"
client_file "$W/client.json" installed 5-x sec
run "$SETUP" --client-secret "$W/client.json"
expect_has "other remotes in rclone's file are kept" "$(remote_conf other)" "type = s3"
expect_has "and the new one is added beside them" "$(remote_conf gdrive-own)" "type = drive"

# An encrypted rclone configuration cannot be appended to, and the secret will not go on argv instead.
fresh
printf '# Encrypted rclone configuration File\n\nRCLONE_ENCRYPT_V0:\nabc\n' > "$STUB_DIR/rclone.conf"
client_file "$W/client.json" installed 5-x sec
run "$SETUP" --client-secret "$W/client.json"
expect_eq "an encrypted rclone configuration is refused" 1 "$RC"
expect_has "saying why" "$ERR" "is encrypted"

# A read-only first run says so at the end.
fresh
client_file "$W/client.json" installed a-1 b
run "$SETUP" --scope drive.readonly --client-secret "$W/client.json"
expect_has "a read-only remote is created read-only" "$(remote_conf gdrive-own)" "scope = drive.readonly"
expect_has "and the summary says read-only" "$OUT" "read-only"
fresh
client_file "$W/client.json" installed a-1 b
set_remote gdrive-own drive drive
STUB_FAIL="config create" run "$SETUP" --client-secret "$W/client.json"
expect_has "a failed union creation is reported" "$ERR" "could not create the union remote"
fresh
run "$SETUP" --remote work --mount "$W/m" --client-secret "$W/none"
expect_has "--remote names the remote" "$ERR" "No rclone remote called 'work' yet"
expect_file "--mount names the mount point" "$W/m"
run "$SETUP" --remote=work2 --mount="$W/m2" --client-secret="$W/none"
expect_has "the = forms work" "$ERR" "No rclone remote called 'work2' yet"

# A client file already at the default place is used without the guided steps.
fresh
client_file "$HOME/.config/oursync/client_secret.json" installed 31-d sec
run "$SETUP"
expect_eq "a client already kept by setup is reused" 0 "$RC"
expect_has "and says so" "$ERR" "Using the client file already at"
expect_lacks "with no steps shown" "$OUT" "Step 1 of 6"

# ---------------------------------------------------------------------------------------------
echo "--- oursync-setup: the guided run, from nothing to a working remote ---"
# ---------------------------------------------------------------------------------------------
GOOGLE_NAME="client_secret_9001-abcdef.apps.googleusercontent.com.json"
fresh
client_file "$HOME/Downloads/$GOOGLE_NAME" installed 9001-abcdef.apps.googleusercontent.com gsec
DISPLAY=:0 run_with '\n\n\n\n\n\n\n\n' "$SETUP"
expect_eq "one run, with no re-run, ends at a working remote" 0 "$RC"
expect_has "step 1 is the project" "$OUT" "Step 1 of 6 - a project"
expect_has "there are six steps, the last being the Drive API" "$OUT" "Step 6 of 6 - the Drive API"
expect_lacks "and no step claims a seventh" "$OUT" "of 5 -"
expect_has "the intro says six" "$OUT" "Six short steps"
expect_has "step 3 is the branding" "$OUT" "Step 3 of 6 - the branding"
expect_has "step 3 gives the app name" "$OUT" "App name:                          OurSync"
expect_has "step 3 gives the home page" "$OUT" "https://recklesstechnology.com/oursync/"
expect_has "step 3 gives the privacy page" "$OUT" "https://recklesstechnology.com/legal/privacy/"
expect_has "step 3 adds the authorized domain" "$OUT" "\"+ Add domain\" and enter recklesstechnology.com"
expect_has "step 3 keeps the no-logo instruction" "$OUT" "Leave the logo"
expect_has "step 4 publishes, which is what stops the seven-day expiry" "$OUT" "Step 4 of 6 - publish it"
expect_has "step 4 names Google's dialog" "$OUT" "Push to"
expect_has "step 4 says what the unverified consequences are" "$OUT" "cap of 100 users"
expect_lacks "and no longer claims no verification is needed" "$OUT" "No verification is needed"
expect_has "step 5 says to download before closing the box" "$OUT" "BEFORE you close it"
expect_has "step 5 says what to do if the browser asks where" "$OUT" "choose your Downloads folder"
expect_lacks "and there is no test-user step" "$OUT" "Test users"
expect_has "step 6 enables the Drive API in the project from the file" "$OUT" "project 9001"
opened=$(cat "$STUB_DIR/open.log" 2>/dev/null)
expect_has "step 1 opens its page" "$opened" "https://console.cloud.google.com/projectcreate"
expect_has "step 2 opens its page" "$opened" "https://console.cloud.google.com/auth/overview"
expect_has "step 3 opens the branding page" "$opened" "https://console.cloud.google.com/auth/branding"
expect_has "step 4 opens the audience page" "$opened" "https://console.cloud.google.com/auth/audience"
expect_has "step 5 opens its page" "$opened" "https://console.cloud.google.com/auth/clients/create"
expect_has "step 6 opens the project's own enable link" "$opened" "https://console.cloud.google.com/flows/enableapi?apiid=drive.googleapis.com&project=9001"
expect_has "the links are printed as well" "$ERR" "https://console.cloud.google.com/projectcreate"
expect_has "the downloaded file was found by its Google name" "$ERR" "$GOOGLE_NAME"
expect_has "and installed" "$(cat "$HOME/.config/oursync/client_secret.json")" "gsec"
expect_eq "private" "600" "$(stat -c %a "$HOME/.config/oursync/client_secret.json")"
expect_has "the remote carries it" "$(remote_conf gdrive-own)" "client_id = 9001-abcdef.apps.googleusercontent.com"
expect_lacks "the secret is not on any command line" "$(calls)" "gsec"
expect_no_file "the copy in Downloads is deleted by default" "$HOME/Downloads/$GOOGLE_NAME"
expect_has "and the run ends with the mount instructions" "$OUT" "Set up. Drive will appear at"

# No display, or ssh: nothing is opened and the links are printed.
fresh
client_file "$HOME/Downloads/$GOOGLE_NAME" installed 9001-abcdef.apps.googleusercontent.com gsec
run_with '\n\n\n\n\n\n\n\n' "$SETUP"
expect_no_file "with no display no browser is started" "$STUB_DIR/open.log"
expect_has "the link is printed instead" "$ERR" "https://console.cloud.google.com/auth/audience"
fresh
client_file "$HOME/Downloads/$GOOGLE_NAME" installed 9001-abcdef.apps.googleusercontent.com gsec
DISPLAY=:0 SSH_CONNECTION="1 2 3 4" run_with '\n\n\n\n\n\n\n\n' "$SETUP"
expect_no_file "over ssh none is started even with DISPLAY set" "$STUB_DIR/open.log"
fresh
client_file "$HOME/Downloads/$GOOGLE_NAME" installed 9001-abcdef.apps.googleusercontent.com gsec
WAYLAND_DISPLAY=wayland-0 run_with '\n\n\n\n\n\n\n\n' "$SETUP"
expect_file "under Wayland the browser is opened" "$STUB_DIR/open.log"

# Declining the deletion keeps the file.
fresh
client_file "$HOME/Downloads/$GOOGLE_NAME" installed 9001-abcdef.apps.googleusercontent.com gsec
run_with '\n\n\n\n\n\n\nn\n' "$SETUP"
expect_file "answering n keeps the Downloads copy" "$HOME/Downloads/$GOOGLE_NAME"

# Several downloads: newest first, and the choice is the person's.
fresh
client_file "$HOME/Downloads/client_secret_1-old.apps.googleusercontent.com.json" installed 1-old.apps.googleusercontent.com oldsec
client_file "$HOME/Downloads/client_secret_2-new.apps.googleusercontent.com.json" installed 2-new.apps.googleusercontent.com newsec
touch -d '2026-01-01' "$HOME/Downloads/client_secret_1-old.apps.googleusercontent.com.json"
printf 'unrelated' > "$HOME/Downloads/notes.json"
run_with '\n\n\n\n\n\n\n\n' "$SETUP"
expect_has "the newest is the default" "$(remote_conf gdrive-own)" "client_id = 2-new"
expect_has "and both are listed, newest first" "$ERR" "1) client_secret_2-new"
expect_has "the older is listed second" "$ERR" "2) client_secret_1-old"
expect_lacks "a file that is not a client download is not offered" "$ERR" "notes.json"
fresh
client_file "$HOME/Downloads/client_secret_1-old.apps.googleusercontent.com.json" installed 1-old.apps.googleusercontent.com oldsec
client_file "$HOME/Downloads/client_secret_2-new.apps.googleusercontent.com.json" installed 2-new.apps.googleusercontent.com newsec
touch -d '2026-01-01' "$HOME/Downloads/client_secret_1-old.apps.googleusercontent.com.json"
run_with '\n\n\n\n\n2\n\n\n' "$SETUP"
expect_has "typing 2 takes the second" "$(remote_conf gdrive-own)" "client_id = 1-old"
fresh
client_file "$HOME/Downloads/client_secret_1-a.json" installed 1-a s
run_with '\n\n\n\n\n7\n9\nzzz-not-a-path\n\n\n\n' "$SETUP"
expect_has "a number out of range is said so" "$ERR" "there is no number 7"
expect_has "so is an unreadable path" "$ERR" "cannot read 'zzz-not-a-path'"
expect_eq "and it still gets there" 0 "$RC"
fresh
client_file "$HOME/Downloads/client_secret_1-a.json" installed 1-a s
client_file "$W/elsewhere/mine.json" installed 55-mine s2
run_with "\\n\\n\\n\\n\\n$W/elsewhere/mine.json\\n\\n\\n" "$SETUP"
expect_has "a path typed by hand is taken" "$(remote_conf gdrive-own)" "client_id = 55-mine"
expect_file "and its source is not deleted, since it was not found in Downloads' list" "$W/elsewhere/mine.json"

# Nothing downloaded yet: it waits, and takes a typed path or a second look.
fresh
client_file "$W/late/client.json" installed 8-late s3
mkdir -p "$HOME/Downloads"
run_with "\\n\\n\\n\\n\\n\\nnope\\n$W/late/client.json\\n\\n\\n" "$SETUP"
expect_has "no download yet is said so" "$ERR" "No client_secret_*.json in $HOME/Downloads yet"
expect_has "and an unreadable path is said so" "$ERR" "cannot read 'nope'"
expect_has "a typed path then works" "$(remote_conf gdrive-own)" "client_id = 8-late"

# The Downloads folder is the one the desktop names, not just ~/Downloads.
fresh
client_file "$HOME/Telechargements/client_secret_3-fr.json" installed 3-fr s4
STUB_XDG_DOWNLOAD="$HOME/Telechargements" run_with '\n\n\n\n\n\n\n\n' "$SETUP"
expect_has "xdg-user-dir's Downloads folder is searched" "$(remote_conf gdrive-own)" "client_id = 3-fr"

# A wrong file does not end the run: it says what is wrong and offers another go.
fresh
client_file "$HOME/Downloads/client_secret_web.json" web 6-web s
run_with "\\n\\n\\n\\n\\n$W/good.json\\n\\n\\n" "$SETUP"
expect_has "a Web client in Downloads is refused precisely" "$ERR" "is a Web application client"
expect_has "with the way to fix it" "$ERR" "Application type 'Desktop app'"
expect_has "and asks again" "$ERR" "Pick another, or download it again"

# No terminal at all is a clear stop rather than a loop.
fresh
run "$SETUP"
expect_eq "with nobody to answer it stops" 1 "$RC"
expect_has "and says to use --client-secret" "$ERR" "--client-secret PATH"
expect_has "the explanation of why this step exists comes first" "$OUT" "OurSync ships no OAuth client ID and never will"

# ---------------------------------------------------------------------------------------------
echo "--- oursync-setup: what goes wrong after the consent ---"
# ---------------------------------------------------------------------------------------------
fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'googleapi: Error 403: Google Drive API has not been used in project 1234 before. accessNotConfigured\n' > "$STUB_DIR/about_err_once"
run_with '\n' "$SETUP" --client-secret "$W/client.json"
expect_has "an API that is not enabled is named" "$ERR" "Google Drive API is not enabled"
expect_has "with the exact link for the project" "$ERR" "flows/enableapi?apiid=drive.googleapis.com&project=1234"
expect_has "then it checks again and succeeds" "$ERR" "gdrive-own works"
expect_eq "the retry is counted as two calls" 2 "$(grep -c '^about ' "$STUB_DIR/calls.log")"
fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'SERVICE_DISABLED\n' > "$STUB_DIR/about_err_once"
run_with '\n' "$SETUP" --client-secret "$W/client.json"
expect_has "SERVICE_DISABLED reads the same" "$ERR" "Google Drive API is not enabled"
fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'something nobody expected\n' > "$STUB_DIR/about_err_once"
run "$SETUP" --client-secret "$W/client.json"
expect_eq "an error nobody recognised is a failure" 1 "$RC"
expect_has "which prints what rclone said" "$ERR" "something nobody expected"
expect_has "and says how to retry" "$ERR" "Run 'oursync-setup' again to retry"
# Three goes at an API that will not enable, then stop.
fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
cat > "$STUBS/rclone-about-fails" <<'STUB'
STUB
rm -f "$STUBS/rclone-about-fails"
STUB_FAIL=about run_with '\n\n\n' "$SETUP" --client-secret "$W/client.json"
expect_eq "a remote that never answers is a failure" 1 "$RC"

fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'Error: access_denied\n' > "$STUB_DIR/reconnect_err_once"
run_with '\n' "$SETUP" --client-secret "$W/client.json"
expect_has "access_denied says the app is not published" "$ERR" "not published and you are not a listed test user"
expect_has "with the link to publish it, in the project" "$ERR" "auth/audience?project=1234"
expect_has "and says what blocks the Publish app button" "$ERR" "greyed out until the branding is saved"
expect_has "with the branding link, in the project" "$ERR" "auth/branding?project=1234"
expect_has "offering the retry" "$ERR" "Press Enter to try again"
expect_eq "which then succeeds" 0 "$RC"
expect_has "and the remote has its token" "$(remote_conf gdrive-own)" "token = "

fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'Error: access_denied\n' > "$STUB_DIR/reconnect_err_once"
STUB_FAIL="config reconnect" run_with '\n\n\n' "$SETUP" --client-secret "$W/client.json"
expect_eq "three refusals and it stops" 1 "$RC"
expect_has "naming the step" "$ERR" "authorising 'gdrive-own' failed"
run_with '\n' "$SETUP" --client-secret "$W/client.json"
expect_has "the next run finds the remote without a token" "$ERR" "exists but has no token"
expect_has "and does the consent without asking for the file again" "$(calls)" "config reconnect"

for failure in redirect_uri_mismatch invalid_client; do
    fresh
    client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
    printf 'Error 400: %s\n' "$failure" > "$STUB_DIR/reconnect_err_once"
    run "$SETUP" --client-secret "$W/client.json"
    expect_eq "$failure stops the run" 1 "$RC"
    expect_has "$failure links to a new Desktop client" "$ERR" "auth/clients/create?project=1234"
    expect_eq "$failure removes the bad remote" "" "$(remote_conf gdrive-own)"
    expect_no_file "$failure removes the installed client" "$HOME/.config/oursync/client_secret.json"
done
fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'Error 400: redirect_uri_mismatch\n' > "$STUB_DIR/reconnect_err_once"
run "$SETUP" --client-secret "$W/client.json"
expect_has "redirect_uri_mismatch says the client is not a Desktop app" "$ERR" "not a Desktop app"
fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'oauth2: "invalid_client" "Unauthorized"\n' > "$STUB_DIR/reconnect_err_once"
run "$SETUP" --client-secret "$W/client.json"
expect_has "invalid_client says Google does not know it" "$ERR" "does not recognise the client"
fresh
client_file "$W/client.json" installed 1234-q.apps.googleusercontent.com sec
printf 'Error: something odd\n' > "$STUB_DIR/reconnect_err_once"
run "$SETUP" --client-secret "$W/client.json"
expect_has "an unrecognised consent error is just a failure" "$ERR" "authorising 'gdrive-own' failed"

# ---------------------------------------------------------------------------------------------
echo "--- oursync-setup: an existing remote ---"
# ---------------------------------------------------------------------------------------------
fresh
set_remote gdrive-own s3 ""
run "$SETUP"
expect_eq "a remote of the wrong type is refused" 1 "$RC"
expect_has "naming the type" "$ERR" "is not a Drive remote (type=s3)"

fresh
set_remote gdrive-own drive drive.readonly
run "$SETUP"
expect_has "with no --scope an existing remote keeps its own" "$ERR" "already has scope 'drive.readonly'"
expect_lacks "and no consent is started" "$(calls)" "config reconnect"
fresh
set_remote gdrive-own drive ""
run "$SETUP"
expect_has "an existing remote with no scope is treated as drive" "$ERR" "scope 'drive'"

fresh
set_remote gdrive-own drive drive.readonly
run "$SETUP" --scope drive
expect_eq "widening the scope succeeds" 0 "$RC"
expect_has "it says why Google asks again" "$ERR" "re-authorising it for 'drive'"
expect_has "changing the configuration without touching the token" "$(calls)" "config update gdrive-own scope=drive config_refresh_token=false --non-interactive"
expect_has "then reconnects" "$(calls)" "config reconnect gdrive-own:"
expect_has "and confirms" "$ERR" "re-authorised 'gdrive-own' with scope 'drive'"
expect_has "the scope is now drive" "$(remote_conf gdrive-own)" "scope = drive"

fresh
set_remote gdrive-own drive drive
run "$SETUP" --force-reauth
expect_has "--force-reauth consents again at the same scope" "$(calls)" "config reconnect"
expect_has "and says what it is doing" "$ERR" "re-authorising it for 'drive'"

fresh
set_remote gdrive-own drive drive.readonly
STUB_KEEP_SCOPE=1 run "$SETUP" --scope drive
expect_eq "a scope that did not change stops before the consent" 1 "$RC"
expect_has "and says so" "$ERR" "could not set scope 'drive'"
expect_lacks "without reconnecting" "$(calls)" "config reconnect"

fresh
set_remote gdrive-own drive drive.readonly
STUB_FAIL="config reconnect" run "$SETUP" --scope drive
expect_eq "a failed consent is an error" 1 "$RC"
expect_has "naming it" "$ERR" "re-authorising 'gdrive-own' failed"

# ---------------------------------------------------------------------------------------------
echo "--- oursync-nemo ---"
# ---------------------------------------------------------------------------------------------
fresh
run "$NEMO"
expect_eq "no verb is a usage error" 2 "$RC"
expect_has "which names the verbs" "$ERR" "usage: oursync-nemo {can-pin|can-unpin|pin|unpin}"
run "$NEMO" bogus
expect_eq "an unknown verb is a usage error" 2 "$RC"

run "$NEMO" can-pin
expect_eq "can-pin with nothing selected: no" 1 "$RC"
run "$NEMO" can-pin "$HOME/elsewhere/x"
expect_eq "can-pin outside the mount: no" 1 "$RC"
run "$NEMO" can-pin "$MOUNT_DIR/a.txt" "$MOUNT_DIR/b.txt"
expect_eq "can-pin on unpinned files under the mount: yes" 0 "$RC"
local_put "$PIN/b.txt" x
run "$NEMO" can-pin "$MOUNT_DIR/a.txt" "$MOUNT_DIR/b.txt"
expect_eq "can-pin when any is already pinned: no, offer unpin instead" 1 "$RC"

run "$NEMO" can-unpin
expect_eq "can-unpin with nothing selected: no" 1 "$RC"
run "$NEMO" can-unpin "$HOME/elsewhere/x"
expect_eq "can-unpin outside the mount: no" 1 "$RC"
run "$NEMO" can-unpin "$MOUNT_DIR/b.txt"
expect_eq "can-unpin on a pinned file: yes" 0 "$RC"
run "$NEMO" can-unpin "$MOUNT_DIR/a.txt" "$MOUNT_DIR/b.txt"
expect_eq "can-unpin when any is not pinned: no" 1 "$RC"

# A MOUNT in the configuration is honoured.
conf "MOUNT=$W/custom" "PIN_DIR=$W/custompin"
mkdir -p "$W/custompin"; : > "$W/custompin/z"
run "$NEMO" can-unpin "$W/custom/z"
expect_eq "the configuration's mount and pin directory are used" 0 "$RC"
rm -f "$CONF_FILE"

export OURSYNC_BIN="$STUBS/oursync-fake"
run "$NEMO" pin
expect_eq "pin with nothing selected is a usage error" 2 "$RC"
run "$NEMO" unpin
expect_eq "unpin with nothing selected is a usage error" 2 "$RC"

run "$NEMO" pin "$MOUNT_DIR/a.txt" "$MOUNT_DIR/b.txt" "$MOUNT_DIR/c.txt"
expect_eq "pin succeeds when oursync does" 0 "$RC"
expect_has "oursync is given every path" "$(calls)" "oursync pin $MOUNT_DIR/a.txt $MOUNT_DIR/b.txt $MOUNT_DIR/c.txt"
expect_has "the first notification says what is happening" "$(cat "$STUB_DIR/notify.log")" "Keeping offline a.txt and 2 more"
expect_has "the second says it worked" "$(cat "$STUB_DIR/notify.log")" "Available offline a.txt and 2 more"
expect_has "under the OurSync name and icon" "$(cat "$STUB_DIR/notify.log")" "-a OurSync -i oursync"
rm -f "$STUB_DIR/notify.log"
run "$NEMO" pin "$MOUNT_DIR/a.txt"
expect_has "one file is named without a count" "$(cat "$STUB_DIR/notify.log")" "Available offline a.txt"
expect_lacks "and with no 'more'" "$(cat "$STUB_DIR/notify.log")" "more"

rm -f "$STUB_DIR/notify.log"
FAKE_OURSYNC_FAILS=1 run "$NEMO" pin "$MOUNT_DIR/a.txt"
expect_eq "pin fails when oursync does" 1 "$RC"
expect_has "with a critical notification" "$(cat "$STUB_DIR/notify.log")" "-u critical Could not keep offline the reason it failed"
FAKE_OURSYNC_FAILS=1 run "$NEMO" unpin "$MOUNT_DIR/a.txt"
expect_eq "unpin fails when oursync does" 1 "$RC"
expect_has "likewise" "$(cat "$STUB_DIR/notify.log")" "-u critical Could not remove local copy the reason it failed"
rm -f "$STUB_DIR/notify.log"
run "$NEMO" unpin "$MOUNT_DIR/a.txt" "$MOUNT_DIR/b.txt"
expect_eq "unpin succeeds when oursync does" 0 "$RC"
expect_has "and says the file is streamed again" "$(cat "$STUB_DIR/notify.log")" "Local copy removed a.txt and 1 more - now streamed"
unset OURSYNC_BIN

# Without notify-send it is silent, not broken.
PATH="$BARE" OURSYNC_BIN="$STUBS/oursync-fake" run "$NEMO" pin "$MOUNT_DIR/a.txt"
expect_eq "no notify-send: pin still works" 0 "$RC"
# And with no oursync on the PATH the fallback is the per-user install location.
PATH="$BARE" run "$NEMO" can-pin "$MOUNT_DIR/q"
expect_eq "no oursync on the PATH: the checks still work" 0 "$RC"

# ---------------------------------------------------------------------------------------------
echo "--- install.sh, into a temporary home ---"
# ---------------------------------------------------------------------------------------------
fresh
mkdir -p "$HOME/.local/bin"
PATH="$HOME/.local/bin:$STUBS:$BARE" run "$INSTALL" --help
expect_eq "install ends by running setup, which takes the arguments" 0 "$RC"
expect_has "so --help reaches oursync-setup" "$OUT" "oursync-setup - create or re-authorise"
for script in oursync oursync-setup oursync-nemo; do
    expect_file "$script is installed" "$HOME/.local/bin/$script"
    if [ -x "$HOME/.local/bin/$script" ]; then ok; else bad "$script is executable"; fi
    expect_eq "$script has its version substituted" 0 "$(grep -c '@VERSION@' "$HOME/.local/bin/$script" || true)"
done
expect_file "the Nemo actions are installed" "$HOME/.local/share/nemo/actions/10_oursync-pin.nemo_action"
expect_lacks "with the install directory substituted" "$(cat "$HOME/.local/share/nemo/actions/10_oursync-pin.nemo_action")" "@BIN@"
expect_has "pointing at it" "$(cat "$HOME/.local/share/nemo/actions/10_oursync-pin.nemo_action")" "$HOME/.local/bin"
expect_file "every icon size is installed" "$HOME/.local/share/icons/hicolor/512x512/apps/oursync.png"
expect_file "including the smallest" "$HOME/.local/share/icons/hicolor/16x16/apps/oursync.png"
expect_file "the user units are installed" "$HOME/.config/systemd/user/oursync-mount.service"
expect_file "with the timer" "$HOME/.config/systemd/user/oursync-refresh.timer"
expect_lacks "units have the install directory substituted" "$(cat "$HOME/.config/systemd/user/oursync-mount.service")" "@BIN@"
expect_has "the icon cache is refreshed" "$(calls)" "gtk-update-icon-cache -q -t -f"
expect_has "and systemd told to reload" "$(calls)" "systemctl --user daemon-reload"
expect_lacks "no PATH warning when the install directory is on it" "$ERR" "is not on your PATH"
expect_eq "the installed program reports a real version, not the placeholder" 0 \
    "$("$HOME/.local/bin/oursync" version | grep -c '@')"

fresh
run "$INSTALL" --help
expect_has "an install directory off the PATH is warned about" "$ERR" "is not on your PATH"
# No icon cache tool: not an error.
fresh
rm -f "$STUBS/gtk-update-icon-cache.off"
mv "$STUBS/gtk-update-icon-cache" "$STUBS/gtk-update-icon-cache.off"
run "$INSTALL" --help
expect_eq "no gtk-update-icon-cache: the install still completes" 0 "$RC"
mv "$STUBS/gtk-update-icon-cache.off" "$STUBS/gtk-update-icon-cache"

# ---------------------------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
