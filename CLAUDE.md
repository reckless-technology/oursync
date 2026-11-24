# CLAUDE.md

Guidance for Claude Code working in this repository; this covers what is specific to OurSync.

## Parent: claude-skills

This repository inherits its working practice from the private `reckless-technology/claude-skills` repository (cloned at
`~/work/claude-skills`; its `workspace/CLAUDE.md` is the cross-repo guide and its skills are linked into
`~/.claude/skills`). Load the `reckless-working-practice` skill before committing, formatting, testing or installing
anything here. This file holds only what is specific to this repository; where it differs from the parent, it wins
here. Skills that apply here: `reckless-working-practice`, `reckless-releases`.

## What this is

Google Drive as a filesystem on Linux Mint: streamed at `~/Drive`, synchronised both ways, with
chosen files kept on local disk. It is **shell scripts over `rclone`**, in [`rclone/`](rclone/),
packaged from [`debian/`](debian/), and that is the whole product. GPLv3, public repository.

Read [`rclone/README.md`](rclone/README.md) and [docs/plan.md](docs/plan.md) first.

## It was going to be a Go daemon, and measurement killed that

[docs/design.md](docs/design.md) specifies a FUSE daemon with a database, a change-feed poller, a
fetch pool and fifteen components. **It was not built and should not be.** Its central claim — that
one stream would not fill a fast downlink, so a parallel fetch pool was the design's most important
decision — was measured against the real Drive and is false. A single range request averages
65.5 MB/s on `jonny-precision` over Wi-Fi, parallel requests show no effect that clears the spread,
and `rclone mount` keeps up at 62.3. Jonny's acceptance bar is 60.

[docs/measurements.md](docs/measurements.md) has every figure with its machine and date, including
the runs that were void and why. Read it before proposing anything that assumes throughput is a
problem here.

**What that retired was the daemon's architecture, not the product's scope.** The brief is a Drive
for desktop equivalent: streaming by default, chosen files mirrored, two-way sync. A read-only
`drive.readonly` token was authorised for the benchmarking work, and for a while that benchmarking
decision was allowed to harden into the product and get written up in the README as a *limitation*.
It was not a limitation; it was scope dropped without asking. Do not narrow the brief to whatever
the current configuration happens to permit.

**The design document is kept as research, not as a plan.** Its survey of the Drive API — the quota
arithmetic, the name mapping, the failure modes, the absence of delta upload, the conflict naming —
is sound and still answers questions. Its architecture is history.

## Decisions not to reopen without reading why

- **No client ID ships in this repository. Ever.** A restricted scope in a distributed app needs
  OAuth verification plus an annual third-party security assessment. Each user brings their own
  Cloud project under Google's personal-use exemption. See [docs/plan.md](docs/plan.md).
- **There is no delta upload, and no amount of cleverness finds one.** Verified 2026-11-16 against
  `files.update`, the resumable protocol, the revisions resource and the whole v3 method list: no
  write-at-offset, no append, no patch, no block or signature endpoint, no revision-from-diff.
  Google's *own* client has done differential uploads since October 2024 through something
  undocumented, which is why this keeps looking possible. Measured against the real corpus it costs
  little: of 40 files over 100 MB touched in a year, almost none were genuinely edited.
- **`search_policy=epall`, not `ff`.** `ff` races the upstreams by response time; `epall` takes the
  first in *configured* order. Local disk usually wins a race and sometimes does not, and "usually"
  is not what a pin means.
- **`:writeback` is not used.** It copies the whole file to local disk on first read, which is
  caching everything — and the corpus is larger than the disk. It looks like exactly the right flag
  and is exactly the wrong one.
- **`:nc` on the local upstream.** It is not only about accidents: it is what makes a file created
  in the mount land in Drive rather than on local disk, since the local upstream is excluded from
  the CREATE category entirely.
- **A pin is a cache of Drive, not a replica.** That is what settles the sync direction: Drive wins,
  `oursync refresh` pulls, and a locally-newer differing copy is a *conflict* that is reported and
  never overwritten. Anything that resolves a conflict silently is wrong here.
- **The mount's read-only flag is derived from the remote's scope, not hard-coded.** A read-only
  token with a writable mount fails part-way through a save; the derivation makes it fail at once.
- **Credentials never go on a command line.** `--rc-pass` published the mount control password to
  every account on the machine through `ps` and `/proc/*/cmdline`; it goes through `RCLONE_RC_PASS`
  instead, which `/proc/*/environ` restricts to the owner. **The same goes for the OAuth
  `client_secret`**: `rclone config create ... client_secret=...` puts it in rclone's argv, so
  `oursync setup` appends the remote to rclone's configuration file itself (found with `rclone
  config file`) and runs only `rclone config reconnect`, which takes everything from the file.
  Checked against real rclone 1.76.0, 2026-11-19: no secret in any rclone argument. An encrypted
  configuration is refused, not worked around.
- **The Go foundation is gone**, deleted when the repository went public. Its `Makefile` built
  `./cmd/oursyncd`, which never existed.

## Working on it

Shell, so `shellcheck -S style` and plain POSIX-ish bash. There is no compile step.

```sh
./rclone/install.sh                 # per-user install from a checkout, then runs oursync setup
tools/rclone-floor-test.sh          # does this rclone do everything OurSync asks? (no network)
tools/script-tests.sh               # the shipped scripts against a stub rclone (no network, no FUSE)
tools/coverage.sh                   # the same under kcov 43, failing under the line-coverage gate
tools/build-deb.sh                  # the package, into build/deb/
python3 tools/make-icons.py         # only when icons/source/ changes
```

**`oursync setup` is one guided run** (2026-11-19): it opens six console pages with `xdg-open`
(only with a display and no `SSH_CONNECTION`), finds the downloaded `client_secret_*.json` in
`xdg-user-dir DOWNLOAD`, validates it with `oursync check-client` (Desktop `installed` only; a
`web` client is refused), consents, and checks the remote with `rclone about`. The user fills in the Branding
page (name `OurSync`, home page and privacy page on recklesstechnology.com, that authorised domain,
no logo) and publishes the app ("In production") *before* the client exists, so there is no
test-user step; **that ordering was confirmed against a real fresh project on 2026-11-20**, provided
Branding is filled in first (Publish app is disabled until it is). The access_denied diagnosis says
what blocks that button and tells the user to publish or add themselves as a test user. The
sequence is only proven against the stub: a real consent needs Jonny's click-through.

**There are three kinds of test, and only the first two run in CI.** `tools/script-tests.sh` runs
`rclone/oursync`, `oursync-setup`, `oursync-nemo` and `install.sh` against stubs placed first on
`PATH` in a temporary directory: a fake `rclone` whose "Drive" is a directory and whose remote
configuration is one INI file (`rclone config file` says where), and fakes of `mountpoint`, `fusermount3`, `systemctl`,
`notify-send`, `xdg-open`, `xdg-user-dir` and `gtk-update-icon-cache`. `HOME` and every `XDG_*` variable point into the same
directory. It checks the scripts' own logic and the arguments they give rclone: the rclone floor,
which paths are accepted, the refresh rule (Drive wins, a locally newer copy is a conflict and is
never overwritten), the mount flags, that the control password never reaches a command line, and
what `install.sh` places. It cannot show that real rclone, a real mount or Google's consent behave as
the stub does; `tools/rclone-floor-test.sh` checks rclone itself, and `tools/acceptance-test.sh` and
`tools/live-write-test.sh` need a real Drive and a mount, so they are run by hand on
`jonny-precision`. A change to a script's behaviour changes the stub's expectations in the same
commit, and a new command comes with a case in `script-tests.sh`.

**Coverage is gated at 92 % of the lines in `rclone/`**, measured with kcov 43 by
`tools/coverage.sh` and run as the `coverage` job in `build.yml`. It was 95.8 % when the gate was set
(2026-11-19, kcov 43, 430 lines in the four scripts; 94.29 % of 630 lines after the guided setup, measured again 2026-11-21). kcov is not packaged for Ubuntu 24.04, so the
job builds the v43 tag and caches it; `coverage.sh` refuses any other version, because the gate
depends on what kcov counts as a line. Nothing is excluded with a marker: the mount, control-port and
consent paths all run against the stubs. What the percentage cannot show is that those paths work
against the real thing. The lines that stay uncovered are `case` patterns and the initialiser of the
`flags` array, which kcov does not report as executed even when they are, and the last two lines of
the `setup` dispatch, which `exec` replaces before kcov records them. kcov leaves a script that never
ran out of its report, so `coverage.sh` also fails if any script in `rclone/` is missing from it. The
report is the `oursync-coverage` artifact of the run. To run it locally, build kcov v43 (cmake, g++,
libdw-dev, libelf-dev, libcurl4-openssl-dev, binutils-dev, libssl-dev, zlib1g-dev) and put it on `PATH`.

**The icon is Jonny's artwork, and the committed PNGs are the deliverable.** `icons/source/` holds
what he supplied — a dark circle on white — and `tools/make-icons.py` finds the circle, cuts it out
with an anti-aliased alpha and writes the seven hicolor sizes. The PNGs are committed so a package
build needs neither Python nor Pillow. The icon installs under the name `oursync`, which is what
`oursync-nemo` hands to `notify-send`: rename it and every pin notification silently falls back to
a blank placeholder.

**It cannot be tested on Windows.** It needs `/dev/fuse` and a real mount. Test on
`jonny-precision` (`ssh -4 jonny@jonny-precision.local`, Mint 22.3, kernel 7.0.0-42). It is Jonny's
own laptop with his session live: work in a directory of your own, change no system settings, and
clean up. His own installation is live there — `~/Drive` is mounted and
`oursync-mount.service` is running — so never reconfigure it as a side effect of a test.
`tools/rclone-floor-test.sh` sets its own `RCLONE_CONFIG`, which is why it is safe to run there.

**A pin test that does not mark the local copy proves nothing.** The VFS cache will serve a
previously-read file at local-disk speed whether or not it is pinned, and the bytes are identical,
so both timing and checksums agree with either answer. Use a file never read through the mount,
append a marker to the local copy, invalidate, and compare. This was got wrong once already.

**Run a new checker where the answer is already known.** The floor test failed six of fourteen
checks against rclone 1.76 — a version known to work — because its fixture gave a local directory
upstream a trailing colon (`/tmp/x/cloud:`), which resolves to nothing and leaves a silent
one-upstream union, and because it grepped for `"forgot"` where rclone answers `"forgotten"`. Both
bugs would have read as "1.60 is too old" had it been run there first.

## Traps particular to this project

- **Build the package on Mint, not only in CI.** Three faults showed up only there, because
  lintian's idea of a valid distribution depends on its vendor: `lsb_release -cs` gives Mint's own
  codename (`zena`), which lintian has never heard of; `unstable` is a Debian suite that lintian
  rejects on an Ubuntu-derived system; and `/etc/os-release` is the portable answer, since Mint
  carries `UBUNTU_CODENAME=noble` beside `VERSION_CODENAME=zena`. **Source it in a subshell** —
  `/etc/os-release` sets `VERSION`, which otherwise replaced the version from the git tags with
  "22.3 (Zena)".
- **Do not depend on an Essential package.** `coreutils`, `sed` and `findutils` are always present,
  and depending on one without a version is a lintian *error*, not a warning.
- **`dpkg-buildpackage` runs `debian/rules clean` first**, so a clean target that removes the whole
  of `build/` deletes the output directory the caller just made. It removes only `build/staged`.
- **`dpkg-checkbuilddeps` wants `build-essential`** even though nothing here compiles: Debian policy
  makes it an implicit build dependency. Install it rather than passing `-d`, which would skip every
  build dependency check.
- **Never run `lsof +D ~/Drive`.** It walks the whole mount, which means listing 5 TB of Drive: it
  hangs, and it spends quota doing it. To find what has the mount open, read `/proc/*/fd` instead.
- **Nor anything else that walks `$HOME`.** The mount lives *inside* the home directory, so a plain
  `find ~ -name something` descends into all of Drive — it looks like an ordinary search and is the
  same mistake as the one above. `find "$HOME" -xdev` stays on the real filesystem and is what to
  reach for by default. Killing the local `ssh` client does **not** stop the remote `find`: check
  with `pgrep -ax find` and kill it by pid, or it keeps spending quota after you have moved on.
- **Never name a variable `RCLONE_<anything>` unless you mean the flag.** rclone reads every flag
  from `RCLONE_<FLAG>`, which is exactly why the control-port password can be passed safely through
  the environment — and it means an innocent-looking workflow variable is a command-line argument.
  `RCLONE_VERSION: "1.76.0"` in `release.yml` was read as `--version`, so every later rclone call
  died with `strconv.ParseBool: parsing "1.76.0": invalid syntax`. The mechanism the project relies
  on deliberately is the one that bites. Keep workflow and script variables out of that namespace
  (`TARGET_RCLONE`, not `RCLONE_VERSION`) rather than hoping a name is not a flag.
- **`apt install ./oursync.deb` pulls the whole GTK tree, and it is slow enough to kill a release.**
  The package `Recommends: nemo, libnotify-bin`, and apt installs Recommends by default, so a plain
  install drags in nemo, gvfs, webkit2gtk, yelp, file-roller and gstreamer. On 2026-11-18 that took
  **32 minutes** on a hosted runner and killed three release runs at the timeout — which was twice
  misread as a slow mirror and "fixed" by raising the cap. Use `--no-install-recommends` wherever
  the Nemo integration is not the thing under test. And read the timestamps in a log before
  blaming the network: the step names were different each time, but the minutes were all in apt.
- **`vfs/forget` cannot make a new pin visible; only `vfs/refresh` can.** Measured on 1.76.0,
  2026-11-18, five runs of each and deterministic. A pin copies the file to local disk behind the
  mount's back, and the mount's object for that path was resolved when only the remote upstream held
  it, so every later save follows that stale object and goes only to Drive. A forget drops a cached
  listing; only a *re-read* rebuilds the union object. `vfs/forget` fails aimed at the file
  (`file=`), at the parent (`dir=`) and at everything — and with no argument it answers
  `{"forgotten":[]}` and forgets **nothing**, so "forget everything" is not available. A remount
  also fixes it, which is what locates the staleness. Use the parent directory, non-recursively:
  `recursive=true` from the root re-lists the whole of Drive at 100 quota units a listing. The root
  is addressed by omitting `dir`, because `dir=""` answers "file does not exist".
- **`--inplace` is load-bearing and it moved the dependency floor seven minor versions.** Without
  it the VFS uploads to `<name>.<hash>.partial` and renames, making a save a *create*, which `:nc`
  keeps out of the local upstream. It does not exist before rclone 1.63, and the union does not
  carry an update to both upstreams before 1.67, so the floor is **1.67 or newer, excluding
  1.68.0**, which cannot parse `rc_addr` from the environment — the one place OurSync must use the
  environment, since a password on a command line is readable through `ps`. Not monotonic, so it is
  not a single `>=`: `require_usable_rclone` enforces it in the program and `Depends: rclone` is
  unversioned, because PATH decides which rclone runs and dpkg cannot see one installed from
  rclone.org into `/usr/local/bin`. **Run the floor test against old rclone after any mount-flag
  change** — the `--inplace` regression existed for a day because the test had only been re-run on
  the current version.
- **A union upstream that is a local path takes no trailing colon.** The colon belongs on a remote
  *name* (`gdrive-own:`). `/path:nc` is a path with a modifier; `/path:` is a remote that does not
  exist, and the union silently carries on with one upstream.
- **A scope change needs a new token.** Google binds the scope to the token, so editing
  `scope = drive` in the configuration changes nothing by itself. `oursync setup` does it in two
  steps for a reason: `rclone config update ... config_refresh_token=false --non-interactive`
  changes only the configuration, so a failure leaves a working remote, and then
  `rclone config reconnect` replaces the token. Verified on rclone 1.60.1 and 1.76.0.
- **rclone's OAuth consent wants a browser on the same machine.** Over ssh, answer Y anyway and
  tunnel the port: `ssh -L 53682:localhost:53682 user@host`. Answering N works too and prints what
  to run elsewhere.
- **Google-native documents have no hash and report `Size: -1`.** Anything comparing copies must
  cope with a missing hash rather than treating it as a difference.
- **`modifiedTime` can be in the future, and is in this Drive.** Seven 1 GiB DVD `.VOB` files
  created in July 2026 report `2036-02-07T01:58:15.000Z` — ten years ahead, read straight from the
  API, because Drive stores whatever `modifiedTime` an upload supplies and that rip carried the
  disc's own. Anything assuming `modifiedTime <= now` or resolving conflicts by "newest wins" will
  be wrong about these files for a decade. `oursync refresh` compares two copies of *one* file,
  which both carry the same odd time, so it is unaffected — that is why the comparison is written
  that way rather than against the clock.
- **A 403 is not one error.** `rateLimitExceeded` and `userRateLimitExceeded` are retryable;
  `storageQuotaExceeded` is terminal; `downloadQuotaExceeded` is undocumented, real, and per-file.
  The reason must be parsed from the body; the status code does not distinguish them.
- **Quota is metered in units, not requests**: 325,000 per user per minute, a download costing 200
  and a list 100. Small, frequent reads are disproportionately expensive, which is why the refresh
  timer runs every five minutes rather than every thirty seconds.
- **`prompt=consent` is required as well as `access_type=offline`.** Without it, a second
  authorisation of the same client returns no refresh token at all. This has already cost time on
  the YouTube project in this workspace.
- **Benchmarks must refuse a busy machine.** `tools/range-fetch-bench.sh` checks for `fastchess`
  *and* `Runner.Worker` *and* the load average, immediately before the first sample, and records the
  load on every row. A whole wired campaign was once taken on `reckless-ci-lin-0` during another
  session's CI because the machine was checked once, half an hour earlier, when it was idle.
- **A failed transfer reads as infinite speed.** `speed.cloudflare.com/__down` caps below 100 MiB
  and answers `403`, then `429`, with a one-byte body; divided by a near-zero time that reported
  416 MB/s on a 511 Mbit link. Every timed transfer asserts the bytes it received.

## CI and releases

The repository is public, so every job runs on a **GitHub-hosted** image and none of this competes
for the organisation's self-hosted machines. `build.yml` is shellcheck, the package (built,
lintian'd, installed, exercised, removed), the rclone floor test against both the version apt
ships and the current one, and the coverage job above. `release.yml` follows the house pattern: a tag `vMAJOR.MINOR` or a
dispatch builds `MAJOR.MINOR.BUILD` from `tools/version.sh` and leaves a **draft** release with the
`.deb` and its checksum. Publishing it is Jonny's step, as everywhere else in the organisation.
