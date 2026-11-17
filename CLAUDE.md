# CLAUDE.md

Guidance for Claude Code working in this repository. The workspace-level
`~/Documents/git/CLAUDE.md` and the `reckless-working-practice` skill still apply; this covers what
is specific to OurSync.

## What this is

Google Drive streamed at `~/Drive` on Linux Mint, with chosen files kept on local disk. It is
**shell scripts over `rclone`**, in [`rclone/`](rclone/), and that is the whole product. It is
installed and working on `jonny-precision`.

Read [`rclone/README.md`](rclone/README.md) first. The next piece of work is a `.deb` so it can be
shared — [docs/plan.md](docs/plan.md).

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

**The design document is kept as research, not as a plan.** Its survey of the Drive API — the quota
arithmetic, the name mapping, the failure modes, the absence of delta upload — is sound and still
answers questions. Its architecture is history. The Go foundation under `internal/` is unused;
removing it is a decision not yet taken.

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
- **`:nc` on the local upstream.** Nothing is ever *created* on the local side by accident; a pin is
  placed deliberately and nothing else writes there.
- **The mount is `--read-only`**, because the remote holds the `drive.readonly` scope. A write
  otherwise fails late and confusingly, part-way through a save. Removing the flag means
  re-authorising the remote for read-write, which is Jonny's decision and not yet made.
- **Credentials never go on a command line.** `--rc-pass` published the mount control password to
  every account on the machine through `ps` and `/proc/*/cmdline`; it goes through `RCLONE_RC_PASS`
  instead, which `/proc/*/environ` restricts to the owner.

## Working on it

Shell, so `shellcheck` and plain POSIX-ish bash. There is no build.

Install or re-install on a machine:

```sh
./rclone/install.sh
systemctl --user enable --now oursync-mount.service
oursync doctor
```

**It cannot be tested on Windows.** It needs `/dev/fuse` and a real mount. Test on
`jonny-precision` (`ssh -4 jonny@jonny-precision.local`, Mint 22.3, kernel 7.0.0-42). It is Jonny's
own laptop with his session live: work in a directory of your own, change no system settings, and
clean up.

**A pin test that does not mark the local copy proves nothing.** The VFS cache will serve a
previously-read file at local-disk speed whether or not it is pinned, and the bytes are identical,
so both timing and checksums agree with either answer. Use a file never read through the mount,
append a marker to the local copy, invalidate, and compare. This was got wrong once already.

## Traps particular to this project

- **apt ships rclone 1.60.1** on Ubuntu 24.04, which Mint 22.3 is built on. Development and all
  testing happened on **1.76.0**, installed by hand into `/usr/local/bin`. Nothing is tested against
  1.60.1, so `Depends: rclone` in a package would be a guess. See the dependency section of
  [docs/plan.md](docs/plan.md).
- **`modifiedTime` can be in the future, and is in this Drive.** Seven 1 GiB DVD `.VOB` files
  created in July 2026 report `2036-02-07T01:58:15.000Z` — ten years ahead, read straight from the
  API, because Drive stores whatever `modifiedTime` an upload supplies and that rip carried the
  disc's own. Anything assuming `modifiedTime <= now`, resolving conflicts by "newest wins", or
  validating a cache entry by comparing timestamps will be wrong about these files for a decade.
- **A 403 is not one error.** `rateLimitExceeded` and `userRateLimitExceeded` are retryable;
  `storageQuotaExceeded` is terminal; `downloadQuotaExceeded` is undocumented, real, and per-file.
  The reason must be parsed from the body; the status code does not distinguish them.
- **Quota is metered in units, not requests**: 325,000 per user per minute, a download costing 200
  and a list 100. Small, frequent reads are disproportionately expensive.
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

## Jonny's open decisions

Named in [docs/plan.md](docs/plan.md), and none of them is an engineering question:

1. **The licence**, since the README still says proprietary and not for distribution.
2. **Repository visibility**, currently private.
3. **Whether writes are enabled**, which means re-authorising Drive with the full `drive` scope.
4. **Whether the Google onboarding wall is acceptable** for the people he wants to share this with
   — each needs their own Cloud project, and it cannot be removed.
