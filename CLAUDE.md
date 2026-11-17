# CLAUDE.md

Guidance for Claude Code working in this repository. The workspace-level
`~/Documents/git/CLAUDE.md` and the `reckless-working-practice` skill still apply; this covers what
is specific to Aqueduct.

## What this is

A streaming Google Drive filesystem for Linux Mint Cinnamon — a FUSE mount that fetches content on
demand, caches it in sparse files, polls Drive's change feed, and uploads on close. Go 1.26.x.

**[docs/design.md](docs/design.md) is the authority.** It records not only the design but the
evidence for each decision and, in §9, the decisions themselves as a numbered list. Read it before
proposing anything structural. §11 holds the questions that are genuinely open, each with the live
test that would settle it — if you are about to assume one of those, run the test instead.

## Status

Design only. No code has been written. [docs/plan.md](docs/plan.md) has the build order; start at
M0 unless told otherwise, and do not skip ahead — M0 and M1 exist to settle the two riskiest
assumptions (the refresh-token cap, and the name mapping against real data) before anything is
built on them.

## Decisions not to reopen without reading why

Each of these was settled with evidence, not preference. Reversing one is fine; reversing one
without reading §2 and §9 of the design is not.

- **FUSE, not fanotify pre-content hooks.** The hooks were tested live on kernel 7.0 and they
  work. They are still wrong here, chiefly because `cp` consults `SEEK_DATA`, finds a sparse
  placeholder empty, and silently writes a file of zeros with no event fired. Five more reasons in
  §2.1.
- **go-fuse, low-level API, no libfuse.** go-fuse speaks `/dev/fuse` directly, so Mint's libfuse
  3.14.0 lacking the passthrough API does not constrain us.
- **Poll, never push.** `changes.watch` needs a public HTTPS endpoint; a relay would put Jonny's
  data through a third-party server and drag the project into Google's security-assessment regime.
- **ids are identity, never paths.** Drive allows duplicate names in one folder, allows `/` in a
  name, and has no atomic rename-over.
- **One stored `local_name` per node**, computed once at ingest, protected by
  `UNIQUE(parent_id, local_name)`. Never re-derive a POSIX name from a Drive name at use time.
- **No client ID ships in this repository.** Ever. See the README.
- **There is no delta upload, and no amount of cleverness finds one.** Verified 2026-11-16 against
  `files.update`, the resumable protocol, the revisions resource and the whole v3 method list: no
  write-at-offset, no append, no patch, no block or signature endpoint, no revision-from-diff.
  Google's *own* client has done differential uploads since October 2024 through something
  undocumented, which is why this keeps looking possible. If you think you have found a way, you
  have found an endpoint nobody has documented — check it twice before building on it.
- **The read path is parallel by design.** One stream will not fill a gigabit link. Do not
  simplify the fetch pool into a single sequential reader; the premise is measured in M2.
- **Accounts are isolated; the link and the disk are not.** Per-account tokens, databases, caches
  and quota budgets; one global fetch pool, upload queue and cache budget. Making the pools
  per-account would let two accounts each saturate a 50 Mbit uplink.

## Working on it

```sh
make build          # -> ./aqueductd and ./aqueduct
make check          # the full gate: tests plus vet plus gofmt
make cover          # statement coverage, gated
```

Go, so `gofmt`, not clang-format — the 22.1.8 pin in the working-practice skill does not apply
here. Build trees go under `build/`, as everywhere in this workspace.

**Checking a Linux build from Windows needs `CGO_ENABLED=0`.** This PC has `go env CC` set to
MSYS2's clang (pawnstar-go's race detector needs it), so a bare `GOOS=linux go build` tries to
compile `runtime/cgo` with a Windows clang and dies on `grp.h`. Aqueduct uses no cgo at all — that
is the point of go-fuse and the pure-Go SQLite driver — so the right invocation is
`CGO_ENABLED=0 GOOS=linux go build ./...`, which `make crosscheck` runs.

**Do not edit `go.mod` or `go.sum`.** Every dependency the project needs is already required at a
pinned version, held in place by `internal/deps` so `go mod tidy` cannot drop one before real code
imports it. A new dependency is a decision — raise it rather than adding it.

**The FUSE tests cannot run on Windows and will not run in CI.** They need `/dev/fuse` and a real
mount. Run them on `jonny-precision` (`ssh -4 jonny@jonny-precision.local`, Mint 22.3, kernel
7.0.0-42, Go 1.26.9 at `/usr/local/go/bin/go` which is **not** on the non-interactive PATH, and
libfuse3-dev installed 2026-11-16). It is Jonny's own laptop with his session live: work in a
directory of your own, change no system settings, and clean up.

**CI is deliberately small.** The repository is private, so its jobs land on the self-hosted pool,
which is one Linux machine — `reckless-ci-lin-0`, which is also the chess-match machine. Keep CI to
`vet`, `test`, `gofmt -l` and the coverage gate. Check for a running match before pushing
(`ssh -4 jonny@192.168.50.22 'pgrep -x fastchess'` — `-x`, never `-f`, which self-matches).

**The live Drive tests** under `internal/drive/livetest/` are behind a build tag, use Jonny's real
account, and spend his API quota. They never run in CI and never run unattended.

## Traps particular to this project

- **The Drive Go client does not retry.** All 64 call sites in `drive-gen.go` use
  `gensupport.SendRequest`, not `SendRequestWithRetry`; the backoff machinery in the package is
  wired only into media uploads. Everything goes through our own `RoundTripper` (§6.2) — do not
  add a direct call that bypasses it.
- **A 403 is not one error.** `rateLimitExceeded` and `userRateLimitExceeded` are retryable;
  `storageQuotaExceeded` is terminal; `downloadQuotaExceeded` is undocumented, real, and per-file.
  The reason must be parsed from the body, since the status code does not distinguish them.
- **Quota is metered in units, not requests**: 325,000 per user per minute, with a download at
  **200** and a list at 100. Small readahead chunks are disproportionately expensive, which is why
  chunks are 16 MiB.
- **Never advance a change token before the page is applied.** It goes in the same transaction as
  the node updates, or changes are lost silently.
- **Never wait on the change feed to confirm our own write.** The latency is undocumented and
  anecdotally minutes.
- **`prompt=consent` is required as well as `access_type=offline`.** Without it, a second
  authorisation of the same client returns no refresh token at all and the next run cannot refresh.
  This has already cost time on the YouTube project in this workspace.
- **The project's OAuth app is in Testing status**, which caps refresh tokens at seven days.
  Whether publishing lifts it is open (§11.1), and `refresh_token_expires_in` near 604799 in the
  token response is the one-minute test. Do not promise a permanent token.

## Jonny's open decisions

In §9 of the design, as A1 to A4: the repository name, whether to publish the Cloud app, the mount
point, and whether mirror mode is wanted at all. Do not implement around them by guessing — A4 in
particular governs the largest piece of work in the plan.
