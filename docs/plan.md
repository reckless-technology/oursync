# OurSync — build order

The order things get built in, and what "done" means for each. Written 2026-11-16, before any
code. [design.md](design.md) is the what and the why; this is the sequence.

The ordering principle: **every milestone ends in something Jonny can run and judge**, and the
riskiest unknowns are proved as early as they can be. Nothing here is a week of invisible
scaffolding.

---

## M0 — the repository, and proof that auth works

Exit: `oursync auth` completes a loopback consent in Chrome, stores the token in the keyring, and
`oursync status` prints the account's name and storage quota from `about.get`.

- Go module, `Makefile` (the house wrapper: `build`, `test`, `check`, `cover`, `vet`, `fmt`),
  `.githooks`, `tools/setup-dev.sh`, CI on GitHub-hosted Linux (the repo is private, so see the
  note on runners below).
- `internal/account`: the account registry and its per-account paths, from the start rather than
  retrofitted — a single-account daemon that later grows a second account tends to grow it as a
  special case, and §6.15's whole point is which resources are shared and which are not.
- `internal/auth`: loopback listener, PKCE, `access_type=offline` + `prompt=consent`, Secret
  Service storage over D-Bus with the 0600-file fallback, keyed per account.
- `internal/drive`: the retrying, quota-budgeted transport, and `about.get`.
- `oursync auth --show-expiry` prints `refresh_token_expires_in`.
- `oursync account add|list|remove`, and a measurement of the real uplink and downlink
  (§11.2b) recorded in the repository, since the upload cap and every time estimate derive from it.

**Why this is first.** It settles §11.1 — the seven-day token question — on day one, for the cost
of one command, and it proves the whole credential chain before anything depends on it.

## M1 — metadata, and the names problem solved on real data

Exit: `oursync tree` prints Jonny's actual Drive — all ~5 TB of metadata, which is plausibly
10⁵–10⁶ rows — with every duplicate name, slash-bearing name and shortcut resolved; the ingest
resumes correctly when interrupted halfway; and `oursync sync` applies remote changes to the
database while it runs. Two accounts ingest side by side, each into its own database. No FUSE yet.

- `internal/store`: schema, migrations, WAL.
- `internal/names`: the mapping of §6.4, with a unit-test corpus of hostile names.
- `internal/sync`: full-tree ingest (`files.list`, paged, with an explicit `fields` set), then the
  change poller — one token per drive, token advanced only inside the applying transaction.
- `drives.list` for shared drives; the synthesised virtual roots.

**Why second.** The name mapping is the design's riskiest assumption and his real Drive is the only
honest test of it. A duplicate-name bug found here is a unit test; found in M2 it is a filesystem
that shows the wrong file.

## M2 — a read-only mount that streams

Exit: `~/Drive/<label>` mounts; Nemo browses it; opening a PDF, an image and a 2 GB video all work,
the video starting promptly rather than after a full download; `du -sh` of a folder costs no
downloads; and **a sequential read of a large file sustains a usable fraction of the gigabit link**,
with the worker-count and chunk-size sweep of §11.2a recorded in the repository and the defaults set
from it. A read path that fills the pipe is the main thing this project is for, so it is an exit
criterion rather than a later optimisation.

- `internal/vfs`: go-fuse low-level nodes, inode lifetime and `Forget`, long attribute timeouts
  with the poller pushing `EntryNotify`/`InodeNotify`.
- `internal/cache`: sparse files, the `ranges` table, 16 MiB aligned chunks, sequential detection
  and readahead, LRU eviction with the open-handle and pin exemptions.
- Range reads validated (206 and `Content-Range`, with the 200 fallback).
- Passthrough at `Open` for fully-cached clean files, declined otherwise.
- Native docs as stubs.

This is the milestone that proves or disproves the architecture. The live tests of §11 — range
behaviour, redirect hosts, byte stability — run here as part of it, not later.

## M3 — writes

Exit: creating, editing, renaming, moving and deleting files in the mount from Nemo, from a text
editor and from a terminal all reach Drive; killing the daemon mid-upload and restarting resumes
rather than restarts; a deliberate two-sided edit produces both files, correctly named; **a file
opened, written with identical content and closed uploads nothing at all**; and a large upload in
flight leaves the downlink usable.

- Hydrate-before-write-open; write into the cache; queue on last release with a 1 s debounce.
- The upload-byte economy of §6.7, which on a 50 Mbit uplink is the substance of this milestone
  rather than a refinement: hash-and-skip unchanged content, no upload for metadata-only changes,
  coalescing and cancel-on-supersede, one transfer at a time capped at 80 % of the measured uplink,
  the cost declared before it is spent, and 8 MiB resumable chunks.
- Resumable upload queue with the session URI and committed offset persisted per chunk.
- Pre-generated ids for creates; one `files.update` for rename-and-move; `trashed` for unlink with
  `EPERM` and an explanation for a non-owner.
- The conflict rule, and `oursync conflicts`.
- `fsync` that does not block on the network.

## M4 — offline files and selective sync

Exit: "available offline" on a folder hydrates it and keeps it hydrated across a reboot;
an excluded folder is absent from the mount and costs nothing; pin state survives a daemon
restart and is visible in `oursync status`.

## M5 — the desktop

Exit: Nemo shows a per-file status emblem and a working "Available offline" context menu; the
Cinnamon panel carries a status icon with sync state and quota; the handful of events that matter
raise a notification.

- `nemo-python` `InfoProvider`, `MenuProvider`, `ColumnProvider`, over the unix socket.
- `XAppStatusIcon` tray applet.
- `libnotify` for auth-expired, quota-full, conflict, terminal upload failure, mount lost.

## M6 — shipping

Exit: `apt install ./oursync_*.deb` on a clean Mint 22.3 install gets a working mount after one
`oursync auth`, the service survives a reboot, and `oursync doctor` is clean.

- `.deb` via debhelper for noble; `systemd --user` unit wanted by `graphical-session.target`.
- First-run wizard: the Cloud-project walkthrough of §6.1, opening the right console pages in
  order, since no API can mint an OAuth client.
- `oursync doctor`.
- README with the honest limitations of §10.

---

## Deferred, on purpose

- **Mirror mode** (§6.10) — the largest single piece of work here and the easiest to defer. It
  waits on A4: whether streaming plus "available offline" already covers what Jonny uses the
  Windows client's mirroring for. If it is wanted, it is an M7 of its own.
- **The fanotify hydration mode** (§2.1) — real files on ext4 that hydrate on read, with the
  `cp`-reads-zeros hazard documented rather than hidden. A genuinely interesting experiment and
  not on the path to a working product.
- **Chunked storage for large files** (design §6.7, A6) — splitting a large file into many Drive
  objects so an edit re-sends only the affected pieces. It is the only way to get real delta
  uploads against the public API, and it costs those files their usability from Drive's web
  interface, from a phone and from Google's own clients. An opt-in for one nominated folder if the
  upload cost ever becomes intolerable, and not before.
- **Any file manager but Nemo.** The emblem APIs are not portable and the mount works everywhere
  regardless.

---

## Risks, and what each one would cost

| Risk | If it bites | Mitigation already in the design |
|---|---|---|
| Seven-day token cap survives publishing | A weekly `oursync auth` | Read-only-from-cache degradation and a notification, not a broken mount (§6.1) |
| `alt=media` ignores `Range` for some file class | Whole-file fetches for those files | The 200 response is handled, not assumed away (§6.2) |
| Change-feed latency is minutes, not seconds | Remote edits appear late | Never wait on the feed for our own writes; poll interval tunable (§6.5) |
| A write pattern that rewrites large files repeatedly | Hours of uplink per edit — the uplink binds long before Drive's 750 GB/day cap does | Hash-and-skip, coalescing, rate limiting, and the cost declared before it is spent (§3.3, §6.7). Not solvable: no public API sends a delta |
| Parallel range fetches do not scale, and reads stay at one stream's throughput | The central premise of the read path fails; streaming large files stays slow | Measured in M2 as an exit criterion, before anything is built on top of it (§11.2a) |
| 10⁶ metadata rows make ingest or `readdir` slow | A sluggish mount on a large account | SQLite is the tree rather than memory, paged `readdir`, resumable ingest, and the mount serves while ingest continues (§6.3, §6.5) |
| `mmap` on the mount misbehaving with `writeback_cache` | Some application fails oddly | §11.9 tests it before M3 depends on it |
| Nemo extension cannot refresh emblems live | Status goes stale until a refresh | `invalidate_extension_info()` exists; if it disappoints, the tray carries the status instead |

---

## CI

The repository is private, so its jobs land on the self-hosted pool — which is **one Linux
machine** (`reckless-ci-lin-0`, which also serves `lin-0-alt` for `light` jobs) since lin-2 was
retired on 2026-11-15. That machine is also the chess-match machine, so this repository's jobs
are kept small and cheap: `go vet`, `go test`, `gofmt -l` and a coverage gate, and nothing that
builds for fifteen minutes. The FUSE tests need `/dev/fuse` and so are tagged and run on
`jonny-precision` by hand, not in CI; a mount test on a shared runner would be a bad neighbour.

The live Drive tests (§11) never run in CI at all. They need Jonny's real credentials and they
spend his quota.
