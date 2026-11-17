# Aqueduct — design

A streaming Google Drive filesystem for Linux Mint Cinnamon, with the features Jonny uses on
Windows: a virtual drive that holds no local copy until something reads a file, per-folder
"available offline", two-way mirrored folders, and per-file status in the file manager.

Written 2026-11-16. Every figure below says what produced it and when, because the arithmetic keeps
working after the machine goes away.

---

## 1. What this is, and what it is not

**Is.** One user-session daemon that mounts Drive at a path, streams file content on demand over
HTTPS, caches what it has fetched in sparse local files, applies remote changes by polling Drive's
change feed, uploads local changes, and reports status to Nemo and the Cinnamon panel.

**Is not.** Not a reimplementation of Google's client, and not described as one. Not a general
cloud-storage abstraction — one provider, done properly. Not a server: nothing of Jonny's data
passes through any machine but his own, which is also what keeps the project out of Google's
security-assessment regime (§3.1).

**Target.** `jonny-precision`: Linux Mint 22.3 (Zena), Ubuntu 24.04 base, Cinnamon 6.6.9 on X11,
kernel **7.0.0-42-generic**, 12 threads, 30 GB RAM, 267 GB free on an ext4 root (checked
2026-11-16). Written to run on stock Mint 22.x as well, whose own ISO ships 6.14.

### 1.1 The usage profile this is built for

Stated by Jonny on 2026-11-16, and it is not a generic cloud-sync workload. Every number here is
load-bearing somewhere below.

| | |
|---|---|
| Data in Drive | **~5 TB** — roughly 19× the free space on the target machine |
| Link | **~1 Gbit down, ~50 Mbit up.** Asymmetric by a factor of 20 |
| Dominant use | **Streaming reads.** The great majority of access is read-only viewing |
| Writes | Occasional, and sometimes to large files |
| Accounts | **More than one**, each wanting its own mount point |

Four consequences follow, and they are the spine of the rest of this document:

1. **The cache can never hold the corpus.** 5 TB against 267 GB means the design is a streaming
   one by necessity, not by preference, and that eviction policy and "available offline" sizing are
   first-class concerns rather than tidying (§6.6, §6.9).
2. **The read path is the hot path and must fill a gigabit link.** A single HTTPS stream will not;
   this is where the engineering effort goes (§6.6).
3. **Upload bytes are the scarce resource.** 50 Mbit is ~6.25 MB/s, so ~22 GB/hour at theoretical
   line rate. Every byte we do not have to send is worth more than every byte we fetch quickly, and
   §3.3 is where the bad news lives.
4. **The metadata set is large.** 5 TB is plausibly 10⁵–10⁶ files, which changes the ingest,
   the memory model and the inode strategy from "walk the tree" to something that paginates,
   resumes and does not hold the tree in RAM (§6.3, §6.5).

**Language.** Go 1.26.x, Jonny's choice on 2026-11-16 over Rust and C++20. The reasoning is in
§2.3 and it held up: the two libraries the project leans on both turned out to do more than
expected.

---

## 2. The two mechanism decisions

These were the only genuinely open questions. Both are now settled by measurement rather than
reading, and both are recorded here with the evidence so nobody reopens them from first principles.

### 2.1 FUSE, not fanotify pre-content hooks

Windows gives a sync engine the Cloud Filter API: the kernel owns placeholder files and calls the
provider back to hydrate them, so files on disk look and behave local while holding no data. Linux
has no equivalent — except that kernel 6.14 added **fanotify pre-content events**
(`FAN_CLASS_PRE_CONTENT` with `FAN_PRE_ACCESS`), which lets a daemon fill a sparse file *during*
another process's `read()`. That is close enough to the Windows mechanism to be worth testing
rather than assuming, so it was tested.

**It works.** On `jonny-precision` (kernel 7.0.0-42, ext4, 2026-11-16): a 4 MiB sparse file was
read at offset 0 and at 3 MiB; the daemon wrote real bytes through the event fd and answered
`FAN_ALLOW`; **the reader received the hydrated bytes, not the zeros that were there when it
called `read`.** The event carries `FAN_EVENT_INFO_TYPE_RANGE` with a byte offset and count,
page-rounded (a 10-byte read at 3 MiB reports offset 3145728, count 4096). `CAP_SYS_ADMIN` alone
suffices, with no root. `copy_file_range`, `sendfile`, `splice`, `readv` and `O_DIRECT` all fire
events.

**It is still the wrong primary mechanism**, for five reasons found in the same session:

1. **It silently corrupts copies.** `stat`, `SEEK_DATA` and `FIEMAP` generate no events, so a
   sparse placeholder reports itself as all holes. coreutils 9.4 `cp` consults `SEEK_DATA` first —
   even with `--sparse=never` — found no data, and produced a **4 MiB file of zeros with not one
   event fired**. Any tool that trusts a hole map is exposed: `cp`, and very probably
   `rsync --sparse`, `tar --sparse` and backup tools. `fallocate`-ing the placeholder avoids it,
   at the cost of reserving the file's full size on disk, which defeats the purpose.
2. **`mmap` hydrates the whole file.** One event fires at `mmap()` time with count equal to the
   entire file size; there are no per-fault events (the page-fault hook was backed out upstream
   after regressions). Mapping a 5 GB file would block until all 5 GB had been fetched.
3. **It fails open.** With a read blocked in an event, killing the daemon returned the reader to
   userspace within ~30 ms **holding zeros**. A dead daemon serves silent wrong data, not an
   error. `/proc/sys/fs/fanotify/watchdog_timeout` was 0 and no timeout was observed with the
   daemon stopped. The upstream "restartable permission events" work that would block instead is
   not merged.
4. **No lazy directory listing.** Directory pre-content events are not in 7.0 (they deadlock
   upstream), so every one of Jonny's Drive entries would have to exist as a real local inode
   before anything could list it. That is the opposite of streaming.
5. **It needs `CAP_SYS_ADMIN` on a user-reachable binary.** A `systemd --user` unit cannot have it
   (the user manager's permitted set holds only `CAP_WAKE_ALARM`; an `AmbientCapabilities` unit
   fails with status 218). It would take `setcap cap_sys_admin+ep` from a `.deb` postinst, or a
   root service. That is a real security cost for a convenience feature.

Add a sixth, structural one: the daemon cannot touch its own marked tree without deadlocking — the
listener reading a file it marked hung until `SIGKILL`, and a `SIGALRM` handler never ran.

**Decision: FUSE, via `github.com/hanwen/go-fuse/v2` v2.12.1, low-level API.** It gives lazy
`readdir`, a clean streaming `read`, open/release refcounts for free (which the cache eviction
needs anyway), and failure modes that surface as errors rather than as zeros. Its one real cost —
a userspace round trip per operation — is addressed in §2.2.

Fanotify is **not** discarded. It is the right mechanism for a future "hydrate-on-read inside an
ordinary ext4 directory" mode, where the files are real and the hazards above are a documented
trade rather than a surprise. It is recorded in §11 as deferred, not rejected.

### 2.2 Two library findings that change the shape of the build

Both checked on 2026-11-16 by fetching the modules and reading their source, not their READMEs.

**go-fuse speaks `/dev/fuse` directly, with no libfuse linkage** (no cgo anywhere under `fuse/`).
Mint ships libfuse **3.14.0**, which predates libfuse's own passthrough API (3.17), and that was
expected to be a constraint. It is not one: we never link libfuse. `fuse3` is still a runtime
dependency, for the setuid `fusermount3` that lets an unprivileged user mount and that
`auto_unmount` requires.

**Kernel FUSE passthrough is reachable, and per-file.** go-fuse exposes
`fs.FilePassthroughFder` — `PassthroughFd() (int, bool)`, called once while handling `Open` or
`Create`. Returning an fd hands the kernel a backing file so `read`, `write`, `splice` and `mmap`
bypass our process entirely; returning `false` keeps the normal FUSE path. That boolean is exactly
the hook this design needs:

- file fully cached locally → return the cache file's fd, and it reads at native ext4 speed with
  no round trip at all;
- file partially cached or not cached → return `false`, and serve through `Read`, fetching ranges.

So the round-trip cost falls on cold reads, which are network-bound anyway, and disappears for
pinned and recently-read files. `CONFIG_FUSE_PASSTHROUGH=y` on the target (checked 2026-11-16);
the feature needs `CAP_SYS_ADMIN` to register a backing file, so where that is unavailable the
daemon simply never offers passthrough and everything still works, more slowly. **Passthrough is
an optimisation with a working fallback, never a requirement.**

**Attribute caching.** go-fuse's `Server` carries `InodeNotify`, `EntryNotify`, `DeleteNotify`,
`PruneNotify` and `InodeNotifyStoreCache`. That resolves the usual FUSE dilemma — short attribute
timeouts cost a round trip on every `stat`, long ones go stale against a store that changes
remotely. Aqueduct takes **long timeouts plus active invalidation**: the change poller (§6.5)
pushes an invalidation for each node it learns has changed. Stale windows then track the poll
interval rather than the timeout, and `ls -la` of a cached directory costs nothing. This is
strictly better than the 60-second metadata cache of `google-drive-ocamlfuse` or rclone's
5-minute `--dir-cache-time`.

### 2.3 Why Go, in hindsight

The job is 80 % HTTP concurrency, retry, resumable transfer and a sync state machine, and 20 %
filesystem. Both of those turned out to be well served:

- `google.golang.org/api/drive/v3` (v0.315.0, first-party, generated) implements the whole
  resumable-upload protocol in `internal/gensupport/resumable.go` — 256 KiB-aligned chunking,
  `Content-Range`, the resume-incomplete flow, per-chunk retry with a deadline — which is the
  fiddliest part of the Drive API and would otherwise be hand-written. It also honours
  caller-supplied headers on `files.get`, so byte-range reads work through the typed client
  (verified by reading the generated `doRequest`).
- `go-fuse` gives the low-level API, passthrough and the notify calls, in pure Go.

One gap, dealt with in §6.2: **ordinary calls do not retry.** All 64 call sites in `drive-gen.go`
use `gensupport.SendRequest`; none use `SendRequestWithRetry`. The backoff machinery exists in the
package but is wired only into media uploads.

---

## 3. What the Drive API forces on the design

The full API reference gathered for this project is summarised here only where it constrains a
decision. Figures are Google's, read 2026-11-16.

### 3.1 Scope, and why the OAuth client is Jonny's own

A client that enumerates and writes a user's existing tree needs the **restricted** `drive` scope.
`drive.file` — which Google recommends instead — can only see files the app itself created, so it
cannot back a filesystem view of existing content.

Publishing an app that requests a restricted scope requires OAuth verification and, where the app
moves restricted data "from or through a third-party server", the CASA security assessment,
renewed annually. Aqueduct has no server, and in any case the route taken is the documented
**personal-use exemption**: the app is used by its owner with an OAuth client from his own Cloud
project. No verification, no assessment, no user cap that matters, and a per-project quota that
nobody else is sharing.

This is a **product constraint, not just a code one**: Aqueduct can never ship a built-in client
ID. First run therefore has to walk the user through creating one. Jonny already has a usable
project — see §6.1.

### 3.2 There is no server push, so we poll

`changes.watch` requires a publicly reachable HTTPS endpoint with a valid certificate, and
channels expire (one week for `changes`, one hour by default). A desktop client cannot receive
them without a relay, and a relay would put user data through a third-party server — the exact
trigger §3.1 avoids. So: poll `changes.list`.

The cost is affordable. Drive meters in quota units against **325,000 per user per minute**:
`list` 100, `get` 5, `edit` 50, **`alt=media` download 200**. A 30-second idle poll is 200
units/minute. The budget is not the constraint; politeness and responsiveness are.

The download cost is the interesting one: at 200 units a request, small readahead chunks are
expensive, which argues for large ranges (§6.6).

### 3.3 Writes are whole-object, and this is the design's one real defeat

**A client using the public Drive API cannot send only the changed bytes of a file.** This was
verified rather than assumed, on 2026-11-16, because Jonny asked for it specifically and because it
is the difference between a four-byte edit costing four bytes and costing the whole file:

- `files.update` has no byte-range, offset, patch, append or partial-content parameter. Its "patch
  semantics" are about metadata fields, not content.
- The resumable protocol's `Content-Range` describes progress through *this upload*, not a region of
  the stored file. A session can be opened against an existing file, but only to replace it.
- The revisions resource has no `create` at all — a revision cannot be made from a diff, a patch or
  a base revision plus changes. `revisions.update` is metadata-only.
- There is no delta, signature, block or chunk-level endpoint anywhere in v3, and the three
  checksum fields are read-only whole-file metadata, never used for block negotiation.
- v3 never states outright that uploading media replaces the entire content. **v2 does**, in
  `newRevision`: "the blob data in the current head revision is replaced". That is the clearest
  statement available, and it is about the same storage.

**And yet Google's own client does it.** Drive for desktop 99.0 (21 October 2024) and a Workspace
Updates post of 10 January 2025 both announce that "when large files are edited, Drive for desktop
will now upload only the parts of the file that changed", rolled out to personal accounts as well as
Workspace. Google documents the *feature* and nowhere documents the *mechanism*: no size threshold,
no block size, no protocol, no public endpoint. The one attempt at packet analysis found on the
rclone forum (December 2024) concluded it is "probably undocumented APIs", drew no replies and was
auto-closed.

So the honest statement, and it goes in the README rather than being buried here: **Google can do
this and we cannot.** Not because of a design choice, and not something more effort fixes — there
is no public interface to the capability. Anyone claiming otherwise should be asked for the endpoint.

**What this costs Jonny, in minutes.** At ~50 Mbit up (≈6.25 MB/s at line rate, so call it 5.5 MB/s
sustained) a full re-upload runs at about **20 GB/hour**:

| Edited file | Bytes we must send | Time |
|---|---|---|
| 50 MB | 50 MB | ~10 s |
| 500 MB | 500 MB | ~90 s |
| 2 GB | 2 GB | ~6 min |
| 5 GB | 5 GB | ~15 min |
| 50 GB | 50 GB | ~2.5 hours |

Note which limit binds: Drive's cap is 750 GB/day, and a 50 Mbit link cannot physically exceed
~540 GB/day. **Google's upload quota is irrelevant to this machine; the uplink is the constraint**,
and so the design's job is not to stay inside a quota but to spend as few bytes as possible and to
stay out of the way while it spends them (§6.7).

The other consequences stand: the write path is write-to-cache-and-upload-on-close, an
`open(O_RDWR)` on a large file must hydrate it fully first, and a resumable session URI lives one
week so an interrupted upload resumes rather than restarts.

### 3.4 Names are not identity

This is where a POSIX view of Drive breaks, and it has to be handled once, centrally, or it leaks
everywhere:

- **ids are canonical, paths are not.** There is no path-resolution call; resolving `/a/b/c` is a
  `files.list` per component, each of which may return several matches.
- **duplicate names in one folder are legal.** `name` "isn't necessarily unique within a folder".
- **names may contain `/`**, and `.`/`..` are permitted.
- **there is no atomic rename-over or replace.** The write-temp-then-rename idiom cannot be atomic;
  the closest thing is a media update on an existing id, which keeps the id and makes a revision.
- a file has **one parent** (the stray doc line saying otherwise is contradicted by every
  reference page; the code tolerates `len(parents) > 1` and takes the first, logging it).
- **"Shared with me", "Starred" and "Trash" are queries, not folders**, and "Computers" (machine
  backup roots) has no documented discovery path at all.

§6.4 is the single place that resolves all of this.

### 3.5 Google-native documents do not stream

A Doc, Sheet or Slide has no byte stream: no `alt=media`, no ranges, no checksum, an unreliable
`size`, and `files.export` is capped at **10 MB**. They need their own representation (§6.8).

---

## 4. Architecture

```
                    ┌──────────────────────────────────────────────┐
  Nemo extension ──►│                                              │
  (emblems, menu)   │                aqueductd                     │
                    │                                              │
  Tray applet ─────►│  ┌────────────┐      ┌────────────────────┐  │
  (XAppStatusIcon)  │  │  control   │      │   sync engine      │  │
                    │  │  plane     │      │  change poller     │  │
  aqueduct CLI ────►│  │ (unix sock)│      │  local scanner     │  │
                    │  └────────────┘      │  upload queue      │  │
                    │         │            └─────────┬──────────┘  │
                    │         ▼                      ▼             │
                    │  ┌──────────────────────────────────────┐    │
                    │  │       metadata store (SQLite)        │    │
                    │  │  nodes · drives · ranges · pins ·    │    │
                    │  │  uploads · conflicts · sync_state    │    │
                    │  └──────────────────────────────────────┘    │
                    │         ▲                      ▲             │
    kernel          │         │                      │             │
  ┌────────┐  FUSE  │  ┌──────┴───────┐      ┌───────┴──────────┐  │
  │ /dev/  │◄──────►│  │  vfs layer   │◄────►│  drive client    │  │
  │ fuse   │        │  │  (go-fuse)   │      │  transport:      │──┼──► Drive API
  └────────┘        │  │  passthrough │      │  quota · retry   │  │
       ▲            │  └──────┬───────┘      │  range reads     │  │
       │            │         │              └──────────────────┘  │
  ~/Drive           │         ▼                                    │
  (mount)           │  ┌──────────────┐                            │
                    │  │ chunk cache  │  sparse files              │
                    │  │ ~/.cache     │  + range bitmap            │
                    │  └──────────────┘                            │
                    └──────────────────────────────────────────────┘
```

One process. The Nemo extension, the tray applet and the CLI are thin clients over a unix socket;
none of them talks to Google.

**Why one process:** the cache, the kernel's view, the upload queue and the change feed all have
to agree, and splitting them across processes buys nothing but a consistency problem. Go's
goroutines make the concurrency internal rather than architectural.

**With several accounts** (§6.15) the boxes above the metadata store multiply — one store, one
poller set, one mount and one quota budget per account — while the two boxes at the bottom right do
not: the fetch pool, the upload queue and the cache budget are **one set, shared**, because they
schedule a link and a disk rather than an API allowance. One process is what makes that sharing
possible at all.

---

## 5. Layout

```
aqueduct/
  cmd/aqueductd/        the daemon
  cmd/aqueduct/         the CLI
  internal/account/     an account's identity, label, paths and lifecycle; the registry of them
  internal/auth/        OAuth loopback, token storage in the keyring
  internal/drive/       typed client wrapper, retrying transport, range reads, exports
  internal/sched/       the global fetch pool and the rate-limited upload queue (§6.15)
  internal/store/       SQLite schema, migrations, queries
  internal/names/       Drive name  <->  POSIX name mapping (§6.4)
  internal/sync/        change poller, local scanner, reconciler, upload queue
  internal/cache/       sparse chunk files, range bitmap, eviction
  internal/vfs/         go-fuse nodes, passthrough decision, invalidation
  internal/control/     unix-socket protocol, served by the daemon, used by the CLI
  desktop/nemo/         nemo-python extension
  desktop/tray/         Cinnamon tray applet (XAppStatusIcon)
  packaging/debian/     the .deb
  docs/                 this file, plan.md, and the API reference notes
  tools/                setup-dev.sh, version.sh
```

---

## 6. Components

### 6.1 Auth

Loopback OAuth: a one-shot listener on a random `127.0.0.1` port, PKCE (`S256`), `access_type=
offline` **and** `prompt=consent` — without the prompt a second authorisation of the same client
returns no refresh token at all and the next run cannot refresh. Out-of-band codes and custom URI
schemes are no longer supported, so loopback is the only desktop route. `xdg-open` takes the
consent URL to the user's browser; on the target that is `google-chrome.desktop`.

**Token storage: the Secret Service, not a dotfile.** `gnome-keyring` 46.1 is running on the
target and owns `org.freedesktop.secrets` on the session bus, with Cinnamon providing the prompter
(checked 2026-11-16). The daemon talks D-Bus directly (`godbus/dbus`) rather than linking
libsecret through cgo. Fallback, for a machine with no Secret Service: a file at
`~/.config/aqueduct/token.json`, created 0600, with the daemon warning once that the token is on
disk in the clear. (`os.Chmod` to 0600 is honoured on Linux; the note in the YouTube skill about
it being a no-op applies to Windows and NTFS ACLs, not here.)

**The Cloud project.** Jonny already has `an existing Cloud project` on `the personal Google account`: a
Desktop-app OAuth client, consent screen "Reckless Technology uploader", External. Reusing it
means enabling the Drive API in that project and adding the `drive` scope — so first run is
*one console visit*, not six, and that is the documented happy path in the README.

Two things follow, and one is unresolved:

- **A second Desktop OAuth client, not a shared one.** Drive and YouTube get separate clients in
  the one project, so revoking or re-authorising one never disturbs the other. The project-level
  quota is shared, which is irrelevant at one user.
- **The project is in Testing status, which caps refresh tokens at seven days.** That is
  tolerable for occasional video uploads — re-run `auth` when it fails — and **not** tolerable for
  a mounted filesystem, which would go read-only weekly.

  Google documents the cap as a property of *Testing* status: a project with an external consent
  screen and "a publishing status of 'Testing' is issued a refresh token expiring in 7 days".
  Nothing on any Google page says the cap survives publishing, and **nothing says it is lifted
  either** — the researched position (2026-11-16) is *strongly indicated, undocumented*. The
  affirmative evidence is Google's personal-use language plus rclone's own instructions to publish
  and accept the warning screen; against it is a developer-forum report from **2026-10-19** of an
  app reading "In production" that still issued a seven-day token, blamed on propagation lag and
  never resolved. Everything arguing either way from before 2025 predates the Google Auth Platform
  rework and is discounted.

  **The test is same-day, not seven days**, which is what makes this cheap to settle: the token
  response carries `refresh_token_expires_in`, and a value near **604799** means the cap is still
  on. So `aqueduct auth --show-expiry` prints that field, and `aqueduct doctor` warns when a
  refresh token is capped. We will know within a minute of consenting, both before and after any
  publish.

  **The daemon is built for the capped case regardless**, because three other things can also kill
  a refresh token (user revocation, six months unused, and the hundred-live-tokens-per-client cap):
  on `invalid_grant` it keeps the mount up and read-only from cache, raises a notification naming
  `aqueduct auth` as the repair, and never presents an empty or broken tree. A weekly re-auth would
  be an irritation, not a failure.

**Routes that do not exist**, checked 2026-11-16 and recorded so they are not re-explored. A
**service account** cannot be the access path: Google's own words are that service accounts "don't
have storage quota and can't own any files", impersonating a human needs domain-wide delegation,
and that needs a Workspace super administrator. A **shared drive** is not available either —
"Personal Google Accounts (@gmail.com) cannot create shared drives". An **Internal** audience needs
a Workspace or Cloud Identity organisation. On a consumer account the only mechanism for a
long-lived credential is an OAuth refresh token. The alternative to living with that is paying for
Workspace, which is not a sensible price for this.

### 6.2 Drive transport

Everything goes through one `http.RoundTripper` under the generated client, because the generated
client will not do any of this:

- **Retry.** 429, 5xx, `ECONNRESET`/`ECONNREFUSED`, and the 403s whose reason is
  `rateLimitExceeded` or `userRateLimitExceeded` — the reason has to be parsed out of the body,
  since the status alone does not distinguish them from `storageQuotaExceeded`, which is terminal.
  Exponential backoff from 100 ms, jitter up to 1 s, capped at 32 s, honouring `Retry-After`.
- **Quota-unit budgeting.** A token-bucket limiter costed per method class (download 200, list
  100, edit 50, get/other 5) against 325,000/user/minute, so a recursive listing or a big
  readahead throttles itself instead of earning a 403.
- **Terminal-error classification.** `storageQuotaExceeded`, `downloadQuotaExceeded` (undocumented
  but real: a hot file blocks for roughly a day), `cannotDownloadAbusiveFile` (needs
  `acknowledgeAbuse`, owner only, and the user must be asked rather than it being set silently).
- **Observability.** Per-method call counts, units spent, retry counts and latency, readable via
  `aqueduct status --api` — because the first question about any misbehaviour will be "what is it
  asking Google for?"

Range reads get a helper that sets `Range` via `FilesGetCall.Header()`, calls `Download()`, and
**validates the response**: a 206 with a parsed `Content-Range` is the expected case; a 200 means
the server ignored the range and the body is the whole file, which must be handled rather than
assumed away (the docs promise the header is honoured but never promise a 206).

### 6.3 Metadata store

SQLite (`modernc.org/sqlite`, pure Go — no cgo, so cross-compilation and the `.deb` stay simple),
WAL mode, **one database per account** at
`~/.local/share/aqueduct/accounts/<account>/metadata.db` (§6.15). Per-account rather than one shared
database with an account column: change tokens, ingest state and ids then never have to be
qualified, a query cannot accidentally span accounts, and removing an account is deleting a
directory.

```sql
nodes(
  id TEXT PRIMARY KEY,            -- Drive file id; canonical identity
  drive_id TEXT,                  -- NULL for My Drive, else the shared drive
  parent_id TEXT,                 -- NULL for a root
  name TEXT NOT NULL,             -- Drive's name, verbatim
  local_name TEXT NOT NULL,       -- the POSIX name we present (§6.4)
  ino INTEGER NOT NULL UNIQUE,    -- our inode number, stable for the node's life
  mime TEXT NOT NULL,
  size INTEGER,                   -- NULL where Drive gives none (native docs)
  md5 TEXT,
  version INTEGER,                -- monotonic; the cheap "did it change" test
  modified_time INTEGER,          -- unix ns
  trashed INTEGER NOT NULL,
  shortcut_target TEXT,
  UNIQUE(parent_id, local_name)   -- the invariant the whole mapping exists to hold
)
drives(id TEXT PRIMARY KEY, name TEXT, change_token TEXT)
sync_state(key TEXT PRIMARY KEY, value TEXT)      -- My Drive's change token, schema version
ranges(id TEXT, start INTEGER, end INTEGER)       -- what the cache actually holds
pins(id TEXT PRIMARY KEY, mode TEXT)              -- offline | online | excluded
uploads(id TEXT, path TEXT, session_uri TEXT, committed INTEGER, attempts INTEGER, state TEXT)
conflicts(id TEXT, local_path TEXT, detected_at INTEGER, resolution TEXT)
mirrors(local_path TEXT PRIMARY KEY, drive_id TEXT, folder_id TEXT, last_scan INTEGER)
```

Inode numbers are allocated by us and stored, never derived from the Drive id — a hash would
collide eventually and a collision in an inode number is a data-corruption bug, not a glitch.

**The tree is not held in memory.** At a million nodes, a resident node object graph would be
hundreds of megabytes of long-lived heap for a daemon that is supposed to sit in the background, and
it would have to be kept coherent with the change feed as well as with SQLite. Instead **SQLite is
the tree**: go-fuse's live inodes are a working set, populated on `lookup` from indexed queries
(`UNIQUE(parent_id, local_name)` makes a lookup a single index hit, and `parent_id` is indexed for
`readdir`), and released on the kernel's `FORGET`. Memory then tracks what is actually open and
recently traversed, not what exists. `readdir` streams a page of children per call rather than
materialising a 500,000-entry folder — Drive permits that many in one folder, and a user with 5 TB
may well have one.

### 6.4 The name mapping — one place, decided at ingest

Every hostile property in §3.4 is resolved **once**, when a node is first seen or its name
changes, and the answer is stored in `nodes.local_name`. Nothing downstream ever re-derives it,
which is what makes names stable across restarts, listings and cache files.

Rules, in order:

1. `/` becomes U+2215 DIVISION SLASH (`∕`). Visible, copyable, and not a path separator.
2. A name that is exactly `.` or `..` becomes `~.` / `~..`.
3. A trailing space or dot is kept — Linux permits both — but flagged in `aqueduct status` as a
   name that will break if the file is ever copied to Windows or a FAT volume.
4. A name longer than 255 bytes is truncated on a UTF-8 boundary with a `~N` discriminator.
5. **Duplicates:** the first-seen node keeps the plain name; later ones get ` (2)`, ` (3)` by
   ascending `(createdTime, id)` so the order does not depend on the order pages arrived in. The
   suffix lands before the extension: `report (2).pdf`.
6. The result is checked against `UNIQUE(parent_id, local_name)` inside the ingest transaction. A
   collision there is a bug, and it fails loudly rather than overwriting.

The reverse direction is a lookup, not an algorithm: given a parent id and a POSIX name, read the
row. That is the only correct way round, because the mapping is not injective.

**Virtual roots.** The mount's top level is synthesised, since Drive's own top level does not
match what a user expects to see:

```
~/Drive/My Drive/              root
~/Drive/Shared drives/<name>/  one per drives.list entry
~/Drive/Shared with me/        the sharedWithMe query, flat, read-only
~/Drive/Starred/               the starred query, flat, symlinks into the tree
```

Trash is not mounted (deleting goes to Drive's trash, and the web UI is the place to dig through
it). "Computers" roots are not mounted, because the API offers no way to discover them; `aqueduct
mount-id <id>` can graft one in by hand if Jonny ever wants it.

**Shortcuts become symlinks** to the target's path inside the mount where the target is known, and
a broken symlink where it is not — which is exactly what a dangling shortcut is. Cycles are
detected at ingest and the symlink is left dangling rather than followed.

### 6.5 Change detection, remote

**The first ingest, at 10⁵–10⁶ files.** Before any polling there is a full enumeration, and at this
scale it is a job rather than a loop. `files.list` at `pageSize=1000` with an explicit `fields`
selection, written in batched transactions of one page each; the page token is persisted with each
batch, so an interrupted ingest **resumes at the page it reached** instead of starting again. The
change token is taken *before* the enumeration begins and applied *after* it completes, so anything
that changed during a long ingest is picked up by the first poll rather than missed.

Cost, for calibration: a million files is a thousand pages at 100 units each — 100,000 units, a
third of one minute's budget, so quota is not the limit. Wall-clock and Drive's own paging latency
are, and the ingest therefore reports progress (`aqueduct status` and the tray) and never blocks the
mount: the mount can come up and serve what has been ingested while the rest arrives.

Then, one poller per change token: My Drive, plus each shared drive (their change ids are per-drive,
so they need separate tokens). `changes.getStartPageToken` once, then `changes.list` with
`includeRemoved`, `includeItemsFromAllDrives` and `supportsAllDrives`.

Three rules that matter:

1. **The token advances only after a page is fully applied**, inside the same transaction as the
   node updates. Persisting it first and crashing loses changes silently; this cannot.
2. **The feed is idempotent, not a diff.** Each entry carries the file's *current* state, so a
   rename seen twice is harmless and intermediate states are invisible. Apply as an upsert.
3. **Never wait on the feed to confirm our own write.** The create/update response is applied
   locally at once; the feed entry that follows is a no-op confirmation. The latency between the
   two is undocumented and anecdotally seconds-to-minutes.

After each applied page, the poller pushes kernel invalidations for the affected nodes
(`EntryNotify` for a rename or a move, `InodeNotify` for content or size, `DeleteNotify` for a
trash) and drops any cached ranges whose `md5`/`version` moved. Poll interval: 30 s active, backing
off to 5 min after an idle hour, and immediate on a local write or on `aqueduct sync`.

### 6.6 The read path

```
read(ino, offset, size)
  └─ if the whole file is cached and clean  →  passthrough was already chosen at open; we are not called
  └─ ranges table says the bytes are present → serve from the sparse cache file
  └─ otherwise → fetch, serve, record
```

**Chunking.** Fetch in 16 MiB chunks aligned to chunk boundaries. A file under 16 MiB is fetched
whole. The chunk size is chosen by two constraints at once, which happen to agree:

- a download costs **200 quota units whatever its size**, so small chunks are disproportionately
  expensive. At a gigabit (≈125 MB/s) 16 MiB chunks mean ≈7.8 requests/s — about 94,000 units a
  minute against the 325,000 budget, comfortable. The same rate in 1 MiB chunks would be 1.5
  million units a minute, four times over budget. **Chunk size is set by the quota meter, not by
  taste**;
- fewer, larger requests amortise TLS and request latency, which is what a sequential read of a
  large file is dominated by.

**Parallel fetching, because one stream will not fill the link.** A single HTTPS stream does not
reach a gigabit, so the read path is a **fetch pool**: N workers (default 8, tunable) issuing
concurrent range requests for *distinct* chunks of the same file. Completion order does not matter,
because each chunk is written into the sparse cache file at its own offset and the `ranges` table is
updated per chunk. This is the single most important performance decision in the design, given §1.1.

Prior, not prediction: this workspace has measured exactly this shape against another large-file
host — roughly 1.8 MB/s per connection, scaling close to linearly with concurrent streams. That was
a different service, so it sets the expectation that per-connection throughput is the limit and
parallelism is the lever, and nothing more. **M2 measures Drive itself** (§11.2) and sets the
default from the result rather than from this paragraph. Google serves HTTP/2, where many streams
on one connection can be flow-control bound rather than bandwidth bound, so the transport is
configured for several connections and the measurement compares the two.

**First bytes before whole chunks.** A video player asking for the first 64 KiB must not wait for
16 MiB to land. The chunk containing the request is fetched first and **streamed through to the
kernel as it arrives**, byte ranges being satisfied from the in-flight response the moment they
have been received, with the remainder of the chunk continuing into the cache behind the reader.
Latency to first byte is what makes this feel like a local file; throughput is what makes it finish.

**Readahead.** Two consecutive chunks mark the handle sequential, and the pool then keeps a window
of up to N chunks ahead of the reader in flight, so a long sequential read runs with the pipe full
rather than stalling at every chunk boundary. The window is per handle, so two files streaming at
once share the pool fairly. Random access stays at one chunk and never earns readahead — a database
file or a seeking player would otherwise fetch gigabytes nobody asked for.

**Cache.** One sparse file per node at `~/.cache/aqueduct/content/<id-prefix>/<id>`, created with
`ftruncate` to the full size, written at the right offsets. The `ranges` table is the authority on
what is present — a hole in the file is indistinguishable from real zeros, so the file is never
asked. Rows are coalesced on insert.

**Passthrough.** At `Open`, if the `ranges` row set covers the whole file and `md5` matches what
we last verified, `PassthroughFd()` returns the cache file's descriptor and the kernel takes over
entirely. Otherwise it returns `false` and reads come to us. A file being written is never
passed through (we need to see the writes), and nor is one whose fetch is incomplete.

**Eviction, sized for a corpus 19× the disk.** This is not a cache that will ever be warm, so the
policy has to be deliberate rather than incidental. LRU over `ranges`, triggered by
`--cache-max-size` (default **50 GB**, or 25 % of the filesystem, whichever is smaller — on the
target that is 50 GB against 267 GB free) or `--cache-min-free` (default 10 GB, which must win:
filling a user's root filesystem is a worse failure than a slow read). Never evicts: a node with an
open handle (FUSE gives us the refcount), a node pinned `offline`, or a node with a pending upload.

**Eviction is by range, not by file.** Dropping whole files would mean a 40 GB video either wholly
present or wholly absent; instead the tail of something watched once goes first while the opening of
something watched often stays. Ranges carry a last-read timestamp, and eviction punches holes with
`fallocate(PUNCH_HOLE|KEEP_SIZE)` and deletes the rows in one transaction.

**The cache survives a restart**, which matters when refetching costs real time: on start the
`ranges` table is reconciled against the files actually on disk (size and mtime per cache file),
and any row whose file is missing or short is dropped. The alternative — trusting the table — would
serve zeros out of a truncated cache file, which is precisely the failure mode §2.1 rejected
fanotify for.

### 6.7 The write path

Drive has no partial write, so:

1. `open(O_WRONLY|O_RDWR)` on an existing file **hydrates it fully first** — a read-modify-write
   cannot be done against a partial cache, and this is the one place a user may wait for a file
   they did not read. The daemon notifies if the hydration exceeds a few seconds.
2. Writes land in the cache file. The node is marked dirty. Nothing goes to Google yet.
3. On the last `release`, the node is queued for upload. A 1-second debounce catches
   write-close-write-close patterns from editors.
4. The upload queue uploads one file at a time (bandwidth is the scarce resource, not
   concurrency), resumable above 5 MB, with the session URI and committed offset written to
   `uploads` after each chunk. A daemon restart resumes from the committed offset by querying the
   session; a session older than a week is restarted from scratch.
5. `files.update` keeps the id and makes a new revision, which is the closest thing Drive has to
   an atomic replace. `modifiedTime` is sent explicitly so the local mtime survives the round
   trip.

`create` uses a **pre-generated id** from `files.generateIds`, so a retry after an ambiguous
failure cannot produce two files — a 409 says the first attempt landed. This is the only defence
against duplicate creation, and §3.4 says Drive will happily keep both.

`rename` and `move` are one `files.update` carrying `name`, `addParents` and `removeParents`
together. `unlink` sets `trashed`; a non-owner cannot trash, and that returns `EPERM` with a
notification explaining why, rather than appearing to work.

**Spending as few bytes as possible.** Since §3.3 means we cannot send a delta, everything here is
about not sending the file at all, or sending it once instead of five times. In rough order of how
much each is worth:

1. **Hash before upload, and skip if it matches.** On close, the cache file's MD5 is compared with
   the `md5Checksum` Drive already holds. Identical content is **not uploaded**. This costs a local
   read of a file we already have and it catches a surprising amount: an application that opens
   `O_RDWR` and writes nothing, a save that rewrites identical bytes, a tool that rewrites a whole
   file to change nothing, a `touch`. Against a 20 GB/hour uplink this is the single most valuable
   line in the design.
2. **Upload only if bytes were actually written.** The write path tracks whether any `write` dirtied
   the file at all, so a no-op open does not even reach the hashing step. A metadata-only change —
   rename, move, trash, mtime — never uploads content.
3. **Debounce and coalesce.** An editor that writes, closes, writes and closes again produces one
   upload, not two. A file re-dirtied while its upload is queued replaces the queued copy; a file
   re-dirtied while its upload is *in flight* cancels that upload and requeues, since finishing a
   transfer of superseded bytes is pure waste on this link.
4. **One upload at a time, rate-limited.** Concurrency buys nothing when the uplink is the
   bottleneck, and it makes failure handling worse. The queue runs one transfer, by default capped
   at **80 % of the measured uplink**. The cap is not politeness: a saturated upstream queue delays
   the ACKs for downstream traffic, so an unthrottled 5 GB upload makes a gigabit *download* link
   feel broken for fifteen minutes. On an asymmetric connection this is the difference between a
   daemon you forget about and one you turn off.
5. **Say what it will cost, before it costs it.** An upload above a threshold (default 1 GB) raises
   a notification naming the file, the bytes and the estimate — "5.2 GB, about 16 minutes" — with a
   cancel. `aqueduct status` shows the queue, the current transfer's progress and the time
   remaining. Given that a 50 GB edit is a two-and-a-half-hour transfer, the user finding out from
   a progress display rather than from a slow internet connection is most of the usability of this
   feature.
6. **Resumable chunks of 8 MiB** rather than the client's 16 MiB default: on a thin uplink a chunk
   is ~90 seconds of work, and that is the granularity we lose to an interruption. The 256 KiB
   alignment rule is satisfied either way.

**What is deliberately not done**, recorded so it is a decision rather than an omission: large files
could be stored *chunked* — split into many Drive objects whose unchanged pieces are not re-sent,
which would genuinely give delta uploads. It is rejected as a default because those files would stop
being files in Drive: unusable from the web interface, from a phone, and from Google's own clients,
which is most of the point of keeping them in Drive at all. It remains available as a possible
opt-in for one nominated folder, and it is noted in §11 rather than built.

**fsync** flushes to the cache file and returns. It does **not** wait for the upload: an fsync that
blocked on a 2 GB upload would hang every editor. `aqueduct status` shows the queue, and quitting
the daemon drains it (with a timeout, and the queue survives in SQLite regardless).

### 6.8 Google-native documents

Default: a **stub file**, `<name>.gdoc`/`.gsheet`/`.gslides`, containing the small JSON Google's
own clients use (`{"url": ..., "doc_id": ..., "email": ...}`), with a registered MIME type and a
`.desktop` handler that opens the URL in the browser. Read-only, a few hundred bytes, honest about
what it is.

Optional (`--export-native`): present the file as its exported form (`.docx`/`.xlsx`/`.pptx`),
materialised on open via `files.export`, read-only, and **capped at 10 MB by the API**. Over the
cap, the read fails with `EFBIG` and a notification saying why. `size` is unreliable for these, so
the stat shows the exported size once known and 0 before that — which is what rclone does, and it
is the least-bad option.

Writing back is not supported. Re-importing a `.docx` over a Doc replaces its full contents and
loses what the format cannot carry; that is a data-loss operation dressed as a file save, and the
answer is the browser.

### 6.9 Pin states and selective sync

Three states, per node, inherited by descendants unless overridden:

| State | Meaning |
|---|---|
| `online` | default. Visible, streamed, cache evictable. |
| `offline` | "Available offline". Hydrated eagerly, kept hydrated, never evicted, re-fetched when the change feed says it moved. |
| `excluded` | Not present in the mount at all. Its metadata is still tracked (so the feed stays consistent) but it is invisible and costs no space. |

Set from the CLI (`aqueduct pin <path>`), the Nemo context menu, or a config file. `offline` on a
folder walks it and queues hydration at low priority, reporting progress in the tray.

**Pinning is checked against the disk before it starts.** With 5 TB in Drive and 267 GB free, "make
this folder available offline" is an instruction that can silently fill a root filesystem, and the
metadata to prevent that is already in the database. So a pin sums the subtree's size first and
refuses outright when it will not fit — naming the subtree's size, the free space and the shortfall
— rather than hydrating until `ENOSPC`. Pinned bytes are **not** part of the LRU budget, because
pinned data is not a cache; they are accounted separately, and the pin is refused if pinned plus
cache would breach `--cache-min-free`. `aqueduct status` reports both totals.

### 6.10 Mirror mode

Separate from the mount, and deliberately so: a mirror pair is `(local directory, Drive folder)`,
two-way synced, with the local side being **ordinary files on ext4** that work when the daemon is
not running. That is what mirroring is for.

Local change detection: `fanotify` with a filesystem mark for the whole pair (no inotify watch
explosion, no missed moves, and it needs `CAP_SYS_ADMIN` — which mirror mode therefore declares as
a requirement, unlike the mount), falling back to `inotify` plus a periodic full scan where the
capability is absent. Either way, **the database is the authority and events are only hints**: a
scan on start reconciles inode, size, mtime-ns and ctime against `nodes`, because events across a
daemon restart are simply absent. A full true-up scan runs hourly, the pattern
`abraunegg/onedrive` has proven.

### 6.11 Conflicts

Remote metadata is authoritative. Content conflicts keep both sides, always:

A conflict is a local dirty node whose remote `version` or `md5` has also moved since our
snapshot. Resolution: upload the local copy under
`<name> (conflict 2026-11-16 jonny-precision)<ext>` in the same folder, keep the remote as `<name>`,
record it in `conflicts`, and notify. Nothing is ever silently discarded and nothing is
auto-merged.

A remote delete of a locally-modified file is the same shape: the local copy is preserved under a
`(conflict ...)` name and uploaded, and the delete is honoured for the original.

### 6.12 Desktop integration

**Nemo.** A `nemo-python` extension (the package is not installed on the target — the `.deb`
depends on it) under `~/.local/share/nemo-python/extensions/`, implementing `InfoProvider` for
emblems (offline / online-only / syncing / error / conflict), `MenuProvider` for the context menu
("Available offline", "Online only", "Open in Google Drive", "Resolve conflict…"), and
`ColumnProvider` for a Status column. Status comes from the daemon over the unix socket; live
updates use `invalidate_extension_info()`. The extension cannot be reloaded without restarting
Nemo, so it is deliberately thin — all logic is daemon-side, and the extension is a view.

**Tray.** `XAppStatusIcon` through `gir1.2-xapp-1.0`, which is what Cinnamon's panel handles
natively; `Gtk.StatusIcon` is the fallback. Shows sync state, pending uploads, quota, and a menu.
Python, for the same reason as the extension: it is the binding Cinnamon documents.

**Notifications.** `libnotify`, for the handful of things a user must know: auth expired, quota
full, conflict created, upload failed terminally, mount lost.

### 6.13 Control plane and CLI

A unix socket at `$XDG_RUNTIME_DIR/aqueduct.sock`, mode 0600, JSON lines. `aqueduct` subcommands:
`auth`, `status`, `mount`, `unmount`, `pin`, `unpin`, `exclude`, `sync`, `mirror add|remove|list`,
`conflicts`, `cache stats|evict`, `quota`, `logs`, `doctor`.

`doctor` is the one that will earn its keep: it checks the token's validity and age, the Secret
Service, `fusermount3`, `user_allow_other`, the kernel's FUSE and passthrough support, the mount's
liveness, free space, the Nemo extension's presence, the API error counters, and prints what is
wrong rather than that something is.

### 6.14 Service and packaging

A `systemd --user` unit, `aqueductd.service`, `Restart=on-failure`, wanted by
`graphical-session.target`. Linger is off on the target, so the daemon stops at logout, which is
correct for a desktop filesystem. `fusermount3 -u` runs in `ExecStop`, and the mount is created
with `auto_unmount` so a daemon death does not leave a hung mount point.

A `.deb` built with debhelper for noble (Mint 22.x is Ubuntu 24.04-based). Dependencies: `fuse3`,
`nemo-python`, `gir1.2-xapp-1.0`, `python3-gi`, `libnotify-bin`. No libfuse-dev, no libsecret
(D-Bus direct), no SQLite C library (pure-Go driver) — one static-ish binary plus two Python files.

**Flatpak is ruled out**, and the reasoning belongs here so it is not revisited: `/dev/fuse` is
only exposed by `--device=all`, the setuid `fusermount3` that unprivileged mounting relies on is
not available in the sandbox, a mount made inside the sandbox would not be visible to the host's
Nemo, and autostart needs a portal backend. AppImage loses `setcap`, autostart and the Nemo
integration. A `.deb`, optionally in a PPA, is the fit.

### 6.15 Multiple accounts, one daemon

One daemon, several Google accounts, **one FUSE mount each** — the arrangement Jonny asked for on
2026-11-16. An account is the unit of isolation, and the split between what is per-account and what
is global is the whole design:

**Per account** — its own refresh token (a separate keyring item), its own SQLite database, its own
cache directory, its own ingest and change pollers, its own **quota budget** (Drive meters units
per user, so two accounts have genuinely separate 325,000/minute allowances and one must not be
charged for the other), and its own mount point.

**Global, because the machine is** — the **fetch pool** and the **upload queue**. These are
scheduled across all accounts together, because the contended resource is one 1 Gbit/50 Mbit link
and one disk, not an account's API allowance. Two accounts streaming at once share the eight fetch
workers; two accounts with queued uploads still upload one file at a time. The cache budget
(§6.6) is likewise global, with per-account directories underneath it. Getting this the wrong way
round — per-account pools — would let two accounts each saturate the uplink and make both slow.

```
~/.local/share/aqueduct/accounts/<label>/metadata.db
~/.cache/aqueduct/accounts/<label>/content/...
~/Drive/<label>/                                     one mount per account
```

The label is the user's, not Google's: `aqueduct account add --label work` runs the consent flow and
mounts at `~/Drive/work`. `aqueduct account list|remove`, and every other subcommand takes
`--account` (defaulting to the only one, where there is only one). Removing an account unmounts it
and deletes its directories, and nothing else is touched.

Two consequences of §6.1's auth model. Each account consents **separately** against the same OAuth
client, so each one is a separate "user" against Google's 100-user lifetime cap on an unverified
app — irrelevant at a handful, worth knowing before adding fifty. And **while the Cloud app is in
Testing status, every account must be added as a test user** or its consent is refused outright,
which is a confusing failure if you do not know to expect it; `aqueduct account add` names it when
consent fails that way.

The Nemo extension and the tray aggregate across accounts, each reporting per-account state, since
a user with two mounts wants one status icon rather than two.

---

## 7. Failure modes, and what the user sees

The research found several ways this class of program fails silently. Each one gets an explicit
answer, because "fails silently" is the only unacceptable behaviour in a filesystem.

| Failure | Behaviour |
|---|---|
| Network down | Cached content readable; uncached reads return `EHOSTUNREACH` quickly rather than hanging; writes accepted into the cache and queued; tray shows offline. |
| Refresh token expired | Mount stays up, read-only from cache, notification naming `aqueduct auth`. Never an empty tree. |
| Daemon killed | `auto_unmount` tears the mount down, so a stale mount cannot serve wrong data. Queue and cache survive in SQLite. |
| `downloadQuotaExceeded` on a file | That read fails with `EIO` and a notification naming the file; everything else carries on. |
| Drive storage full | Uploads stop, queue retained, notification. Local writes keep succeeding into the cache — with the tray showing the backlog, since pretending otherwise would be worse. |
| Disk full locally | Hydration stops, eviction runs, writes fail with `ENOSPC`. |
| A file changed remotely while open | The open handle keeps serving the cached version; the change is applied on close with the conflict rule. |
| Clock skew | Nothing depends on local time ordering; `version` and `md5` decide, not mtime. |

---

## 8. Security

- No server, no telemetry, no third party. The only network peer is `googleapis.com`.
- The refresh token lives in the Secret Service; the fallback file is 0600 and warned about.
- The client secret for a Desktop-type OAuth client is **not** confidential — Google treats it as
  shipped inside distributed apps — so it is not treated as a secret to be protected, and that is
  said plainly rather than discovered later.
- The mount is the user's own, mode 0700, no `allow_other` by default.
- The mount needs no capability at all. Passthrough wants `CAP_SYS_ADMIN` and is skipped without
  it. Mirror mode's `fanotify` mark wants `CAP_SYS_ADMIN` and falls back to `inotify` without it.
  **Nothing in the default configuration is privileged.**
- Logs name paths. They are 0600 under `~/.local/state/aqueduct/`, and `--log-redact` hashes
  names for when a log is to be shared.

---

## 9. Decisions taken

Numbered so they can be cited and reversed on purpose rather than by drift.

1. **FUSE as the mechanism**, with per-file kernel passthrough for fully-cached files. Fanotify
   pre-content hooks tested and deferred (§2.1) — the `cp`-reads-zeros hazard decided it.
2. **Go 1.26.x** (Jonny, 2026-11-16).
3. **go-fuse low-level API**, no libfuse linkage.
4. **Poll the change feed**; no push, no relay, no server (§3.2).
5. **One daemon**, with the file manager, tray and CLI as socket clients.
6. **SQLite as the authority** on names, ranges, pins and queue state; pure-Go driver.
7. **Names resolved once at ingest** into a stored `local_name`, with a uniqueness constraint
   (§6.4).
8. **ids, never paths**, as identity; pre-generated ids for creates.
9. **Write-back on close**, never on write; fsync does not wait for the upload.
10. **Native docs are stubs by default**, export-on-open optional, write-back never.
11. **Both sides kept on conflict**, with a dated-and-hostnamed suffix. No auto-merge, ever.
12. **Mirror mode is ordinary files**, separate from the mount, and declares its own capability
    requirement.
13. **A `.deb`**, with a `systemd --user` service. Not Flatpak, not AppImage (§6.14).
14. **Bring-your-own OAuth client**, reusing `an existing Cloud project` with a second Desktop client
    (§6.1). No client ID will ever ship in this repository.
15. **The read path is a parallel fetch pool** of concurrent range requests, with 16 MiB chunks
    sized by the quota meter, partial chunks streamed through to the reader, and readahead only for
    handles that have proved sequential. The worker count is set by measurement in M2, not by this
    document (§6.6).
16. **Upload bytes are treated as the scarce resource**: hash-compare and skip unchanged content,
    never upload for a metadata-only change, coalesce repeated saves, one transfer at a time capped
    at 80 % of the uplink, and the cost shown before it is spent (§6.7). Chunked storage of large
    files, which would give real deltas at the price of the files no longer being usable in Drive
    itself, is rejected as a default.
17. **Several accounts in one daemon, one mount each**, with per-account tokens, databases, caches
    and quota budgets, but a **global** fetch pool, upload queue and cache budget — because the
    contended resource is the link and the disk, not an account's API allowance (§6.15).
18. **The cache is sized and evicted for a corpus far larger than the disk**: 50 GB by default,
    range-granular LRU, `--cache-min-free` winning any argument, and pinning refused up front when
    a subtree will not fit (§6.6, §6.9).

### Awaiting Jonny

- **A1. Repository name.** `aqueduct` — it carries content on demand over a distance, and it sits
  beside `trebuchet` without pretending to be a Google product. Say the word and it is renamed.
- **A2. Publishing `an existing Cloud project` to "In production"** to escape the seven-day refresh-token
  cap. His consent screen and his Google account, so his call. It would also end the weekly
  re-auth on YouTube uploads, and the cost is a homepage and privacy-policy URL under Branding
  (both already exist on recklesstechnology.com) plus clicking through an "unverified app" warning
  at each consent. The outcome is visible in the token response within a minute, so it is a
  five-minute experiment rather than a commitment (§6.1, §11.1).
- **A3. Mount point.** `~/Drive` by default. `~/Google Drive` matches the Windows client's
  wording but puts a space in every path.
- **A4. Whether mirror mode is wanted at all**, or whether streaming plus "available offline"
  covers what he actually uses it for. It is the largest single piece of work in the plan and the
  easiest to defer. §3.3 sharpens this one: on a 50 Mbit uplink a mirrored folder is a standing
  upload liability, since every local change in it is a full file upload.
- **A5. Which accounts, and what to call their mount points.** `~/Drive/<label>` with labels of his
  choosing. Needed before M1 can be tested against more than one.
- **A6. Whether the chunked-storage option is wanted for one working folder** (§6.7), accepting that
  those files stop being readable from Drive's web interface and from Google's own clients in
  exchange for genuine delta uploads on large edits. Not needed until there is a reason.

---

## 10. What Linux cannot match

Said plainly, so nobody spends a week trying:

- **No OS-level pin state or placeholder.** "Available offline" is our database, not the kernel's.
- **No file-manager-agnostic status overlay.** Emblems work in Nemo. Thunar, Dolphin, a terminal
  and every GTK file chooser will show no status at all.
- **No lazy directory population outside FUSE**, so a real-files-on-ext4 design must materialise
  every entry.
- **No kernel guarantee that a cloud file is always handled.** On Windows the filter driver
  guarantees the provider is called; on Linux a dead FUSE daemon gives `ENOTCONN` (honest) and a
  dead fanotify daemon gives zeros (not).
- **No differential upload.** This one is not about Linux at all — it is about being a third party.
  Google's own client uploads only the changed parts of a large file and has done since October
  2024; no public Drive API exposes that, so an edit to a 5 GB file costs 5 GB of uplink here and a
  few megabytes there (§3.3). It is the one place where the Windows client is not merely more
  integrated but categorically better, and no amount of work on this codebase closes it.

---

## 11. Open questions, and the live tests to run before relying on anything

The API documentation is silent or ambiguous on all of these. Each is cheap to test and expensive
to assume.

1. **Does publishing an unverified External app lift the seven-day refresh-token cap?** Researched
   2026-11-16: strongly indicated, undocumented, with one unresolved counter-report from
   2026-10-19 (§6.1). Settled empirically in a minute by reading `refresh_token_expires_in` from
   the token response, so the design does not depend on the answer — but the answer is worth
   having, and it would also end the weekly re-auth on Jonny's YouTube uploads.

   Two obstacles found at the publish step, neither documented by Google: the console's **Publish
   app** button is reported disabled until Branding carries a homepage and a privacy-policy URL
   (recklesstechnology.com and its `legal/privacy/` page both exist and serve), and one 2026-04
   report had a publish rejected because the app name did not match the name on the homepage — the
   consent screen is currently "Reckless Technology uploader". Both are Jonny's to decide (A2).
2. **Range-read behaviour in practice:** does `alt=media` answer 206 with `Content-Range`, does it
   redirect to a `googleusercontent.com` host, does the range survive the redirect, and are a
   file's bytes stable between two range requests? §6.2 handles the 200 case defensively either
   way.
2a. **How many parallel range requests it takes to fill a gigabit, and whether separate connections
   beat HTTP/2 streams on one.** The most consequential measurement in the project, since §1.1
   makes read throughput the hot path: throughput against 1, 2, 4, 8, 16 workers, at 4, 16 and
   64 MiB chunks, with the quota units spent recorded beside each. It sets the default worker count
   and may move the chunk size. Measured in M2 on `jonny-precision`, over its own link.
2b. **The real sustained uplink**, measured rather than assumed from "about 50 Mbit", since the
   upload cap, the time estimates and the debounce thresholds are all derived from it.
3. **Do `modifiedTime` and `createdTime` stick** on create and on update?
4. **Name limits:** the maximum length Drive accepts, and its behaviour with NUL, `/`, trailing
   dots and spaces, and case-only differences. §6.4 is conservative; the tests may let it relax.
5. **Change-feed latency** between an upload completing and its entry appearing.
6. **What `size` reports for native docs**, and the error an over-10 MB export returns.
7. **XDG trash on a FUSE mount:** what Nemo does with a delete. Drive's trash is the intent, but
   Nemo may try `$topdir/.Trash-$uid` first.
8. **Shared-drive change feeds** for a drive the user is a member of but has never opened.
9. **FUSE passthrough with `writeback_cache`** — the kernel documentation says nothing about their
   interaction, and we want both.

Each becomes a test under `internal/drive/livetest/`, run against Jonny's real account behind a
build tag, never in CI.
