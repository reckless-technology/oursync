#!/bin/bash
# Build the OurSync .deb.
#
# The version comes from the git tags and nothing in the tree is edited to release, which is why
# debian/changelog is generated here rather than committed: it is the one file dpkg insists on
# having a version in, and a committed one would be a second place to forget.
#
# Everything lands under build/, the house rule. dpkg-buildpackage writes to the parent directory,
# so the products are moved back in afterwards.
set -eu

cd -- "$(dirname -- "$0")/.."
ROOT=$(pwd)
OUT="$ROOT/build/deb"

VERSION=$(sh tools/version.sh)
# Not lsb_release -cs: on Mint that answers with Mint's own codename (zena), which is not a
# distribution lintian knows, and it fails the package with bad-distribution-in-changes-file.
# This field only matters for an archive upload, so the neutral value is the right default.
DISTRIBUTION=${DISTRIBUTION:-unstable}
HEADLINE=${HEADLINE:-"OurSync $VERSION"}
DATE=$(date -R)

command -v dpkg-buildpackage > /dev/null \
    || { echo "dpkg-buildpackage is missing (apt install dpkg-dev debhelper build-essential)" >&2; exit 1; }

sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@DISTRIBUTION@|$DISTRIBUTION|g" \
    -e "s|@HEADLINE@|$HEADLINE|g" \
    -e "s|@DATE@|$DATE|g" \
    debian/changelog.in > debian/changelog
echo "debian/changelog: oursync ($VERSION) $DISTRIBUTION"

dpkg-buildpackage -us -uc --build=binary

# After the build, not before: dpkg-buildpackage runs debian/rules clean first.
mkdir -p "$OUT"

# The products are in the parent directory, which on a build machine is somebody else's workspace.
moved=0
for f in "$ROOT/../oursync_${VERSION}_"*; do
    [ -e "$f" ] || continue
    mv -f -- "$f" "$OUT/"
    moved=$((moved + 1))
done
[ "$moved" -gt 0 ] || { echo "no oursync_${VERSION}_* products were produced" >&2; exit 1; }

echo
ls -l "$OUT"
echo
echo "contents:"
dpkg-deb --contents "$OUT/oursync_${VERSION}_all.deb"
