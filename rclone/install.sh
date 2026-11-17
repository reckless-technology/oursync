#!/bin/bash
# Install OurSync for the current user: the scripts, the union remote, the Nemo menu entries and
# the service that mounts Drive at login. Everything lands under $HOME; nothing needs root and no
# system file is touched.
#
# It is safe to re-run. The one thing it will not do is overwrite an existing configuration file,
# because that holds the generated control-port password.
#
# Prerequisite: an rclone remote for Drive must already exist (default name "gdrive-own"). Create
# one with `rclone config`, or `rclone authorize drive --drive-scope drive.readonly` on a machine
# with a browser.
set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
BIN="$HOME/.local/bin"
CONFDIR="$HOME/.config/oursync"
ACTIONS="$HOME/.local/share/nemo/actions"
UNITS="$HOME/.config/systemd/user"

REMOTE="${REMOTE:-gdrive-own}"
UNION="${UNION:-drive-pinned}"
MOUNT="${MOUNT:-$HOME/Drive}"
PIN_DIR="${PIN_DIR:-$HOME/.local/share/oursync/pinned}"

command -v rclone > /dev/null || { echo "rclone is not installed" >&2; exit 1; }
rclone config show "$REMOTE" > /dev/null 2>&1 || {
    echo "no rclone remote called '$REMOTE' - create one first (see the header of this script)" >&2
    exit 1
}

mkdir -p "$BIN" "$CONFDIR" "$ACTIONS" "$UNITS" "$MOUNT" "$PIN_DIR" "$HOME/.cache/oursync"
chmod 700 "$CONFDIR"

install -m 755 "$HERE/oursync" "$BIN/oursync"
install -m 755 "$HERE/oursync-nemo" "$BIN/oursync-nemo"
echo "installed $BIN/oursync and $BIN/oursync-nemo"

# The union remote. Rebuilt every run so a changed pin directory takes effect, which is harmless:
# it holds no credentials of its own, only a reference to the Drive remote.
#
#   <pin dir>:nc   local disk, and ":nc" so nothing is ever *created* here by accident. A pin is
#                  placed deliberately by the script; everything else goes to Drive.
#   search epall   a read takes the first upstream, in configured order, where the path exists -
#                  so the local copy wins and the file is served from disk.
#   action epall   a write to an existing file applies to every upstream holding it, so a pinned
#                  copy cannot silently diverge from the copy in Drive.
rclone config delete "$UNION" > /dev/null 2>&1 || true
rclone config create "$UNION" union \
    upstreams "$PIN_DIR:nc $REMOTE:" \
    search_policy epall \
    action_policy epall \
    create_policy epmfs \
    --non-interactive > /dev/null
echo "configured union remote '$UNION'"

if [ ! -e "$CONFDIR/oursync.conf" ]; then
    umask 077
    cat > "$CONFDIR/oursync.conf" <<CONF
# OurSync configuration. Shell syntax, sourced by the oursync script.
REMOTE=$REMOTE
UNION=$UNION
MOUNT=$MOUNT
PIN_DIR=$PIN_DIR
CACHE_DIR=\$HOME/.cache/oursync
CACHE_MAX_SIZE=20G
CACHE_MAX_AGE=72h

# Control port, used to invalidate the mount's directory cache the moment a pin changes - without
# it a new pin stays invisible until --dir-cache-time expires. Bound to localhost, and given a
# generated password so that a web page cannot POST to it.
RC_ADDR=127.0.0.1:5572
RC_USER=oursync
RC_PASS=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
CONF
    chmod 600 "$CONFDIR/oursync.conf"
    echo "wrote $CONFDIR/oursync.conf"
else
    echo "kept existing $CONFDIR/oursync.conf"
fi

for f in "$HERE"/nemo/*.nemo_action.in; do
    [ -e "$f" ] || continue
    out="$ACTIONS/$(basename -- "${f%.in}")"
    sed -e "s|@BIN@|$BIN|g" "$f" > "$out"
    chmod 644 "$out"
    echo "installed $out"
done

sed -e "s|@BIN@|$BIN|g" -e "s|@MOUNT@|$MOUNT|g" \
    "$HERE/oursync-mount.service.in" > "$UNITS/oursync-mount.service"
systemctl --user daemon-reload
echo "installed $UNITS/oursync-mount.service"

cat <<DONE

Installed. To start it now and at every login:

    systemctl --user enable --now oursync-mount.service

Drive will appear at $MOUNT. Check it with:

    oursync doctor

Right-click a file there in Nemo for "Make available offline".
DONE
