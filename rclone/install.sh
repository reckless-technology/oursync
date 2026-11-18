#!/bin/bash
# Install OurSync for the current user, from a checkout. Everything lands under $HOME, nothing
# needs root, and no system file is touched. Where a .deb is available, prefer it - this is the
# from-source path, and the two place the same files in different prefixes.
#
# It does the half a package would do - the scripts, the Nemo menu entries, the user units - and
# then hands over to `oursync setup`, which does the half a package cannot: the Drive remote, the
# union over it and the configuration file, all of which belong to a person rather than a machine.
#
# It is safe to re-run.
set -eu

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
BIN="$HOME/.local/bin"
ACTIONS="$HOME/.local/share/nemo/actions"
UNITS="$HOME/.config/systemd/user"

# MAJOR.MINOR.BUILD from the tags, the same rule the package uses, so a from-source install reports
# a version that can be told apart from a released one by its commit count.
VERSION=$(cd -- "$HERE/.." && sh tools/version.sh 2>/dev/null || echo "0.0.0")

mkdir -p "$BIN" "$ACTIONS" "$UNITS"

for script in oursync oursync-setup oursync-nemo; do
    sed -e "s|@VERSION@|$VERSION|g" "$HERE/$script" > "$BIN/$script"
    chmod 755 "$BIN/$script"
    echo "installed $BIN/$script"
done

for f in "$HERE"/nemo/*.nemo_action.in; do
    [ -e "$f" ] || continue
    out="$ACTIONS/$(basename -- "${f%.in}")"
    sed -e "s|@BIN@|$BIN|g" "$f" > "$out"
    chmod 644 "$out"
    echo "installed $out"
done

for f in "$HERE"/oursync-*.service.in "$HERE"/oursync-*.timer.in; do
    [ -e "$f" ] || continue
    out="$UNITS/$(basename -- "${f%.in}")"
    sed -e "s|@BIN@|$BIN|g" "$f" > "$out"
    chmod 644 "$out"
    echo "installed $out"
done
systemctl --user daemon-reload

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "WARNING: $BIN is not on your PATH; add it or call $BIN/oursync by its full path" >&2 ;;
esac

echo
exec "$BIN/oursync-setup" "$@"
