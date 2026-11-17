#!/bin/sh
# MAJOR.MINOR.BUILD from git alone: the nearest annotated vMAJOR.MINOR tag and the commits since it.
# 0.0.0 when no such tag is reachable. Nothing in the tree is edited to release.
set -u
tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*' 2>/dev/null) || tag=""
if [ -z "$tag" ]; then
    echo "0.0.0"
    exit 0
fi
count=$(git rev-list --count "$tag"..HEAD 2>/dev/null) || count=0
echo "${tag#v}.$count"
