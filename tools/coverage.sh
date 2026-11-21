#!/bin/bash
# Line coverage of the shipped scripts in rclone/, measured with kcov while tools/script-tests.sh
# runs them, and a gate under it.
#
#   tools/coverage.sh [--fail-under PERCENT] [--out DIR]
#
# Only rclone/ counts: the tests, the benchmarks and the other tools/ scripts are not the product.
# The report is left in DIR (default build/coverage); open DIR/script-tests.sh/index.html.
#
# kcov is pinned to 43 and a different version is refused, because the figure depends on how the
# tool counts a continuation line or a case pattern, and a gate means nothing across versions.
# Build it from the v43 tag (CI does, and caches it); it is not packaged for Ubuntu 24.04.
#
# kcov leaves a script that never ran out of its report altogether, so a script nothing exercises
# would raise the figure by vanishing from the denominator. This fails on that rather than hide it:
# every file in rclone/ that has a shebang must appear in the report.
set -u

# Measured 95.8 % on 2026-11-19 (kcov 43, bash 5.2, 430 lines in four scripts), and 94.29 % at 630
# lines after the guided setup was added (measured again 2026-11-21). A few points under,
# so that an ordinary edit does not trip it and an untested new command does.
GATE=92
KCOV_VERSION=43

REPO=$(cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$REPO/build/coverage"
while [ $# -gt 0 ]; do
    case "$1" in
        --fail-under) GATE="${2:?--fail-under needs a number}"; shift 2 ;;
        --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
        *) echo "usage: $0 [--fail-under PERCENT] [--out DIR]" >&2; exit 2 ;;
    esac
done

command -v kcov > /dev/null || { echo "coverage: kcov is not installed (v$KCOV_VERSION, built from source)" >&2; exit 2; }
got=$(kcov --version | sed -n 's/^kcov //p')
[ "$got" = "$KCOV_VERSION" ] || { echo "coverage: kcov $got found, but the gate is calibrated on $KCOV_VERSION" >&2; exit 2; }

rm -rf -- "$OUT"
mkdir -p -- "$OUT"
kcov --include-path="$REPO/rclone" "$OUT" "$REPO/tools/script-tests.sh" || {
    echo "coverage: the tests failed, so there is no figure to gate" >&2; exit 1; }

# kcov also writes a directory named for the script plus a hash, holding the same run.
python3 -I - "$OUT/script-tests.sh/coverage.json" "$REPO" "$GATE" <<'PY'
import json, os, sys
report, repo, gate = sys.argv[1], sys.argv[2], float(sys.argv[3])
data = json.load(open(report))
seen = {os.path.basename(f["file"]): f for f in data["files"]}
shipped = []
for name in sorted(os.listdir(os.path.join(repo, "rclone"))):
    path = os.path.join(repo, "rclone", name)
    if os.path.isfile(path) and open(path, "rb").read(2) == b"#!":
        shipped.append(name)
missing = [n for n in shipped if n not in seen]
print("\n%-22s %8s %s" % ("file", "covered", "lines"))
for name in shipped:
    if name in seen:
        f = seen[name]
        print("%-22s %7s%% %s/%s" % (name, f["percent_covered"], f["covered_lines"], f["total_lines"]))
total = float(data["percent_covered"])
print("%-22s %7.2f%% %s/%s  (gate %.1f%%)" % ("total", total, data["covered_lines"], data["total_lines"], gate))
if missing:
    print("coverage: not in the report at all, so never run: " + ", ".join(missing))
    sys.exit(1)
if total < gate:
    print("coverage: %.2f%% is under the %.1f%% gate" % (total, gate))
    sys.exit(1)
PY
