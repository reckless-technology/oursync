# CLAUDE.md

Guidance for Claude Code working in this repository. The workspace-level
`~/Documents/git/CLAUDE.md` and the `reckless-working-practice` skill still apply; this covers what
is specific to OurSync.

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
  instead, which `/proc/*/environ` restricts to the owner.
- **The Go foundation is gone**, deleted when the repository went public. Its `Makefile` built
  `./cmd/oursyncd`, which never existed.

## Working on it

Shell, so `shellcheck -S style` and plain POSIX-ish bash. There is no compile step.

```sh
./rclone/install.sh                 # per-user install from a checkout, then runs oursync setup
tools/rclone-floor-test.sh          # does this rclone do everything OurSync asks? (no network)
tools/build-deb.sh                  # the package, into build/deb/
```

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
lintian'd, installed, exercised, removed) and the rclone floor test against both the version apt
ships and the current one. `release.yml` follows the house pattern: a tag `vMAJOR.MINOR` or a
dispatch builds `MAJOR.MINOR.BUILD` from `tools/version.sh` and leaves a **draft** release with the
`.deb` and its checksum. Publishing it is Jonny's step, as everywhere else in the organisation.
