# OurSync, built on rclone

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
  deliberately, by `oursync pin`, and nothing else writes there.
- **`:writeback` is deliberately not used.** It copies the whole file to local disk on first read,
  which is caching everything — and the corpus this is for is larger than the disk.

The mount runs with `--vfs-cache-mode full`, so unpinned files are still cached as they are read,
in a sparse file, bounded by `CACHE_MAX_SIZE` and evicted by age and size. Pinning is the way to say
"not this one".

## Install

From a checkout, for the current user:

```sh
./install.sh                                         # also runs oursync setup
systemctl --user enable --now oursync-mount.service
systemctl --user enable --now oursync-refresh.timer
```

Everything lands under `$HOME`. No root, no system file touched. `install.sh` places the scripts,
the Nemo entries and the user units, then hands over to `oursync setup`, which builds the Drive
remote, the union over it and the configuration — and walks the one-time Google Cloud step if there
is no remote yet.

For a machine-wide install, build the package instead: `tools/build-deb.sh`, then
`sudo apt install ./build/deb/oursync_*_all.deb` and `oursync setup` once per user.

## Use

```sh
oursync pin  ~/Drive/Audio/session.wav     # keep it on disk
oursync unpin ~/Drive/Audio/session.wav    # give the space back
oursync list                               # what is pinned, and what it costs
oursync status ~/Drive/some/file           # pinned or streamed
oursync refresh                            # pull remote changes into pinned copies
oursync setup                              # first time: one guided run, Google console to working remote
oursync setup --scope drive                # re-authorise so the mount can write
oursync doctor                             # the configuration, its state, and anything wrong
```

Or right-click in Nemo: **Make available offline** / **Remove local copy**. The two entries are
gated on `Conditions=exec`, so each appears only where it applies and neither appears outside the
mount.

## What `oursync setup` does

One run, in this order: check rclone against the floor; print why the step exists; walk through
six console pages (project, consent screen, branding, **Publish app**, Desktop client, Drive API), opening
each with `xdg-open` when there is a display and no ssh session, otherwise printing the link;
find `client_secret_*.json` in `xdg-user-dir DOWNLOAD` (default `~/Downloads`), newest first, and
ask which when several; validate it (`oursync check-client`: top-level `installed`, with a
`client_id` and a `client_secret`; a `web` client is refused because it ends in
`redirect_uri_mismatch`); copy it to `~/.config/oursync/client_secret.json`, mode 600; append the
remote to rclone's configuration file directly; run `rclone config reconnect --auto-confirm` for
the consent; and finish with `rclone about` against the remote.

The remote is written to the file rather than created with `rclone config create client_secret=...`
because that puts the secret in rclone's argument list, readable by every account through `ps`.
An encrypted rclone configuration is therefore refused rather than worked around. A failure is
matched against `access_denied`, `redirect_uri_mismatch`, `invalid_client`, `accessNotConfigured`
and `SERVICE_DISABLED`; each prints a sentence and the link, using the project number that is the
digits before the hyphen of the client id. The first two bad-client cases remove the half-made
remote and the copied file so the next run starts from the guided steps; `access_denied` and a
disabled API offer a retry, three times. A remote left with no token (an interrupted run) is
consented on the next run without asking for the file again.

## Two-way sync, and what decides the direction

The mount is read-write when the remote's scope allows it. `cmd_mount` derives the flag rather than
hard-coding it: a `drive.readonly` remote is mounted `--read-only` so a write fails at once with
`EROFS`, instead of being accepted and then refused by the API half-way through a save.
`oursync setup --scope drive` upgrades a read-only installation, which needs a new token — Google
binds the scope to the token, so changing the configuration alone does nothing.

Changes made **through the mount** need no sync at all. A new file goes to Drive, because `:nc`
excludes local disk from the CREATE category. An edit to a pinned file goes to both copies, because
`action_policy=epall` applies an action to every upstream holding the path. A delete removes both.

Changes made **to Drive from elsewhere** — the web, a phone, another machine — are the case that
needs work. A streamed file picks them up within `--poll-interval`. A pinned file cannot, because
the union serves the local copy without ever asking Drive. `oursync refresh` is the only thing that
closes that, and `oursync-refresh.timer` runs it every five minutes.

Its direction rule follows from one sentence: **a pin is a cache of Drive, not a second replica.**
So Drive wins and the local copy is re-fetched. A local copy that is *newer* and differs means
something bypassed the mount, which is a **conflict**: it is reported with both timestamps, nothing
is overwritten, and the refresh exits non-zero so the timer's run shows as failed. That is
deliberate — overwriting it could destroy the only copy of something, and a conflict wants a person.

## What this does not do

- **No delta upload** — changing four bytes of a 2 GB file re-uploads 2 GB. No public Drive API
  offers a way round it; Google's own client does it through something undocumented. See
  [../docs/design.md](../docs/design.md) §3.3. Measured against the real corpus, this costs little:
  of 40 files over 100 MB touched in a year, almost none were genuinely edited.
- **No per-file sync emblems in the file manager.** The menu tells you what a file is; the icon does
  not.
- **One account.** A second Google account means a second remote, union and mount.
