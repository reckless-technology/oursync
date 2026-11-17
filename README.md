# Aqueduct

A streaming Google Drive filesystem for Linux Mint Cinnamon.

Drive appears at `~/Drive` as an ordinary directory tree. Nothing is downloaded until something
reads it; what has been read is cached locally and served at native speed afterwards. Folders can
be marked "available offline" to be kept on disk, or excluded entirely. Remote changes arrive by
polling Drive's change feed; local changes are uploaded on close. Several Google accounts can run
in one daemon, each with its own mount point. Nemo shows per-file status and the Cinnamon panel
carries a status icon.

It is built for a particular shape of use: a corpus far larger than the local disk, an asymmetric
connection, and reading much more than writing. The read path is parallel and tuned to fill a fast
downlink; the write path is built to spend as few upload bytes as it can.

**Status: the premise was measured, and it did not hold.** The design is complete and the foundation
is written, but the read path it is built around wins nothing. Against a real 5 TB Drive, on Wi-Fi
and on wired gigabit, a single range request runs at whatever the link will carry, parallel requests
add less than the variation between repeats, and `rclone mount` lands in the same band. The numbers,
with the machine and date beside each, are in [docs/measurements.md](docs/measurements.md).

What is left to decide is whether this becomes a thin pinning and status layer over rclone or is
abandoned, and the one thing that could still justify it — small-file and metadata latency across a
corpus that size — has not been measured. [CLAUDE.md](CLAUDE.md) has the full state;
[docs/design.md](docs/design.md) has the architecture and the evidence behind each decision, and
[docs/plan.md](docs/plan.md) the build order. Nothing here runs yet.

## Why it exists

Google ships a desktop client for Windows and macOS and none for Linux. The Windows client's
streaming drive is built on the Cloud Filter API, where the kernel owns placeholder files and calls
the provider back to fill them. Linux has no equivalent, so Aqueduct is a FUSE filesystem instead —
see [design.md §2.1](docs/design.md) for the measurement that settled that, including a live test
of kernel 7.0's `fanotify` pre-content hooks, which work and are still the wrong primary mechanism.

## What it will not do

Said up front, because these are platform limits rather than things left undone:

- **Status emblems only in Nemo.** Other file managers, GTK file choosers and `ls` show no sync
  status. The mount itself works everywhere.
- **Google Docs, Sheets and Slides are not editable through the filesystem.** They have no byte
  stream to serve. They appear as small stub files that open in the browser, or optionally as
  read-only exports capped at 10 MB by the API.
- **No "Computers" backup roots.** The API offers no way to discover them.
- **No differential upload — Google's own client can do this and Aqueduct cannot.** Since October
  2024, Drive for desktop uploads only the changed parts of a large file. No public Drive API
  exposes that: there is no write-at-offset, no append, no patch, no block or signature endpoint,
  and a revision cannot be made from a diff. So editing four bytes of a 2 GB file re-uploads 2 GB.
  Aqueduct does everything it can short of the impossible — it hashes before uploading and skips
  content that has not really changed, coalesces repeated saves, never uploads for a rename or a
  move, rate-limits the transfer so it does not strangle the rest of your connection, and tells you
  what a transfer will cost before it spends it. It cannot send a delta, and nor can anything else
  built on the public API.

## The one-time Google setup

Aqueduct will never ship a built-in OAuth client ID. A client that can see your whole Drive needs
Google's **restricted** `drive` scope, and an app distributing its own client ID with that scope
needs OAuth verification plus an annually renewed third-party security assessment. Using an OAuth
client from your own Google Cloud project falls under Google's documented personal-use exemption
instead — no verification, no assessment, and a per-project API quota nobody else is sharing.

The cost is one console visit, once, and clicking through an "unverified app" warning when you
consent. `aqueduct auth` walks it.

## Licence

Proprietary. Private repository, not for distribution.
