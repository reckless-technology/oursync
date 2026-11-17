# Aqueduct

A streaming Google Drive filesystem for Linux Mint Cinnamon.

Drive appears at `~/Drive` as an ordinary directory tree. Nothing is downloaded until something
reads it; what has been read is cached locally and served at native speed afterwards. Folders can
be marked "available offline" to be kept on disk, or excluded entirely. Remote changes arrive by
polling Drive's change feed; local changes are uploaded on close. Nemo shows per-file status and
the Cinnamon panel carries a status icon.

**Status: design complete, no code yet.** Read [docs/design.md](docs/design.md) for the
architecture and the evidence behind each decision, and [docs/plan.md](docs/plan.md) for the build
order. Nothing in this repository runs.

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
- **Writes are whole-file.** The Drive API has no write-at-offset, so changing four bytes of a 2 GB
  file re-uploads 2 GB. Aqueduct will tell you it is doing that; it cannot avoid it.

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
