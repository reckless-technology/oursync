# Aqueduct, built on rclone

Google Drive at `~/Drive`, streamed on demand, with chosen files kept on local disk.

This replaces the daemon the rest of this repository designs. The reason is in
[../docs/measurements.md](../docs/measurements.md): the design's central claim was that one stream
would not fill the link and a parallel fetch pool was needed. Measured, a single stream runs at
whatever the link carries — 65.5 MB/s on `jonny-precision` over Wi-Fi — and `rclone mount` keeps up
with it at 62.3. The streaming half of the design was already shipped, by someone else, years ago.

What rclone genuinely lacks is **pinning**. Its cache is *eviction*-based, not intent-based:
`--vfs-cache-max-age` defaults to an hour, and size pressure evicts by least-recently-used. There is
no flag that means "keep this one". That gap is what the scripts here close, and it is all they do.

## How it works

```
~/Drive                         an rclone mount of the union remote
  └─ union "drive-pinned"       two upstreams, consulted in configured order
       ├─ <pin dir>:nc          local disk - a real copy of each pinned file
       └─ gdrive-own:           Drive itself
```

- `search_policy=epall` — a read takes the first upstream, **in configured order**, where the path
  exists. The local copy is first, so a pinned file is served from disk. (`ff` would race the
  upstreams by response time instead, which usually gives the same answer and sometimes does not.)
- `action_policy=epall` — a write to an existing file applies to **every** upstream holding it, so a
  pinned copy cannot silently diverge from the copy in Drive.
- `:nc` on the local upstream — nothing is ever *created* there by accident. A pin is placed
  deliberately, by `aqueduct pin`, and nothing else writes there.
- **`:writeback` is deliberately not used.** It copies the whole file to local disk on first read,
  which is caching everything — and the corpus this is for is larger than the disk.

The mount runs with `--vfs-cache-mode full`, so unpinned files are still cached as they are read,
in a sparse file, bounded by `CACHE_MAX_SIZE` and evicted by age and size. Pinning is the way to say
"not this one".

## Install

Needs an rclone remote for Drive first (default name `gdrive-own`):

```sh
rclone authorize drive --drive-scope drive.readonly      # on a machine with a browser
rclone config create gdrive-own drive scope drive.readonly token '<the JSON it printed>'
```

Then:

```sh
./install.sh
systemctl --user enable --now aqueduct-mount.service
```

Everything lands under `$HOME`. No root, no system file touched.

## Use

```sh
aqueduct pin  ~/Drive/Audio/session.wav     # keep it on disk
aqueduct unpin ~/Drive/Audio/session.wav    # give the space back
aqueduct list                               # what is pinned, and what it costs
aqueduct status ~/Drive/some/file           # pinned or streamed
aqueduct doctor                             # the whole configuration and its state
```

Or right-click in Nemo: **Make available offline** / **Remove local copy**. The two entries are
gated on `Conditions=exec`, so each appears only where it applies and neither appears outside the
mount.

## Read-only, for now

The Drive remote holds the **`drive.readonly`** scope, so the mount is started with `--read-only`.
A write fails immediately and clearly rather than part-way through a save.

Making it read-write means re-authorising the remote with the full `drive` scope and dropping
`--read-only` from `cmd_mount`. That is a deliberate decision, not an oversight: a read-write mount
over 5 TB of irreplaceable data is a different risk, and the Windows client already handles writes.

## What this does not do

- **No delta upload** — changing four bytes of a 2 GB file re-uploads 2 GB. No public Drive API
  offers a way round it; Google's own client does it through something undocumented. See
  [../docs/design.md](../docs/design.md) §3.3. Measured against the real corpus, this costs little:
  of 40 files over 100 MB touched in a year, almost none were genuinely edited.
- **No per-file sync emblems in the file manager.** The menu tells you what a file is; the icon does
  not.
- **One account.** A second Google account means a second remote, union and mount.
