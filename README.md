# OurSync

**Google Drive on Linux Mint: streamed, synchronised both ways, with the files you choose kept on
local disk.** What Drive for desktop does on Windows and macOS, on the platform Google never
shipped it for.

Drive appears at `~/Drive` as an ordinary directory tree. Nothing is downloaded until something
reads it, so a corpus far larger than the disk costs nothing to mount: 5 TB of Drive on a 500 GB
laptop is the case this was built for. What has been read is cached and evicted as the cache fills.
A file that must always be fast is **pinned** — a real copy is placed on local disk, served from
there, and never evicted.

Google publishes Drive for desktop on Windows and macOS, and nothing for Linux.

```sh
oursync pin   ~/Drive/Audio/session.wav    # keep it on disk
oursync unpin ~/Drive/Audio/session.wav    # give the space back
oursync list                               # what is pinned, and what it costs
oursync doctor                             # the whole configuration and its state
```

Or right-click a file in Nemo: **Make available offline** / **Remove local copy**.

It syncs both ways. Save a file under `~/Drive` and it uploads; delete one and it goes to Drive's
trash; rename one and it is renamed in Drive. Change something in Drive from the web, a phone or
another machine and a streamed file picks it up within the minute, while a pinned file is brought
up to date by `oursync refresh`, which the timer runs every five minutes.

## What it is made of, which is the point

OurSync is a few hundred lines of shell over [rclone](https://rclone.org). Streaming Drive through
a FUSE mount with a bounded local cache is what `rclone mount --vfs-cache-mode full` has done for
years, and it does it at whatever speed the link carries. What rclone genuinely lacks is a way to
say *keep this one*: its cache is eviction-based, and `--vfs-cache-max-age` will throw out the file
you care about to make room for one you opened once.

OurSync closes that gap and nothing else:

```
~/Drive                        an rclone mount of a union remote
  └─ union                     two upstreams, consulted in configured order
       ├─ <pin dir>:nc         local disk - a pinned file is served from here
       └─ gdrive-own:          Drive itself
```

`search_policy=epall` makes a read take the **first** upstream, in configured order, that holds
the path — so a pin wins deterministically rather than by winning a race. `action_policy=epall`
makes a write to an existing file apply to every upstream holding it, so a pinned copy cannot
silently diverge from the copy in Drive. The `:nc` modifier means nothing is ever *created* on
local disk by accident; a pin is placed deliberately and nothing else writes there.

A pin is a *cache* of Drive, not a second replica, and that one sentence settles the sync rule. A
write through the mount reaches both upstreams, so the local copy cannot get ahead by ordinary use.
A change made to Drive from somewhere else reaches only Drive — the union serves the local copy and
never asks — so `oursync refresh` compares each pinned file with Drive and re-copies the ones Drive
has changed. If the local copy is *newer* and differs, something bypassed the mount: that is a
conflict, and a conflict is reported with both timestamps and never resolved by overwriting,
because the thing that would be overwritten might be the only copy of something.

That is the whole design. An earlier version of this repository specified a 15-component FUSE
daemon with its own database and parallel fetch pool, on the premise that one HTTP stream could not
fill a fast downlink. Measurement killed it — see [below](#how-it-got-here).

## Before you install: the Google setup, which cannot be avoided

**OurSync ships no OAuth client ID, and never will.** You create one, once, in your own Google
Cloud project. It is about ten minutes of clicking in a console, and it is not optional:

- Seeing your whole Drive needs Google's **restricted** `drive` scope.
- An application that ships its own client ID with a restricted scope needs OAuth verification
  **plus an annually renewed third-party security assessment** — a five-figure yearly cost that no
  free tool is going to carry.
- An OAuth client from *your own* Cloud project falls under Google's documented personal-use
  exemption: no verification, no assessment, and an API quota nobody else is sharing.

So the wall is real, and the trade is a good one: your credential, your project, your quota.
`oursync setup` walks you through it and takes the `client_secret.json` you download. You will
click through an "unverified app" warning when you consent, because the app is yours and you have
not paid Google to verify it.

## Install

A `.deb` for each release is on the
[releases page](https://github.com/reckless-technology/oursync/releases).

```sh
sudo apt install ./oursync_1.0.0_all.deb
oursync setup                                        # once per user
systemctl --user enable --now oursync-mount.service  # mount it now and at every login
systemctl --user enable --now oursync-refresh.timer  # keep pinned files up to date
oursync doctor                                       # check it over
```

`oursync setup` creates the per-user parts a package cannot: the Drive remote, the union over it,
the configuration file and the pin directory. A `.deb` installs once for a machine, while a Drive
token belongs to a person, so this is the half each user runs for themselves. It is safe to re-run
and will not overwrite a configuration file you already have. `oursync setup --scope drive.readonly`
installs a read-only Drive instead, if that is what you want.

Requirements: Linux Mint 22 / Ubuntu 24.04 or newer, `fuse3`, and **rclone 1.60 or newer**. That
floor is measured, not guessed: `tools/rclone-floor-test.sh` exercises every rclone feature OurSync
depends on — the union's `:nc` and `epall` policies, the VFS cache flags, the write path through
the mount, the control port and the single-file `lsjson` that `refresh` reads — and CI runs it
against the version apt ships as well as the current one. A newer rclone from
[rclone.org](https://rclone.org/install/) is faster at large reads and works equally well.

From a checkout, without a package: `./rclone/install.sh` installs the same thing under `$HOME`,
needing no root.

## What it does not do

[docs/parity.md](docs/parity.md) is the full feature-by-feature comparison with Drive for desktop,
each row saying how it was established. The ones worth knowing before you install:

- **No differential upload — Google's own client can do this and nothing else can.** Since October
  2024 Drive for desktop uploads only the changed parts of a large file, through something
  undocumented. No public Drive API exposes it: there is no write-at-offset, no append, no patch,
  no block or signature endpoint, and a revision cannot be made from a diff. Editing four bytes of
  a 2 GB file means re-uploading 2 GB. This was verified against the whole v3 method list, and is
  the single largest thing wrong with using Drive this way.
- **Status in Nemo only.** The right-click entries are Nemo's; other file managers, GTK file
  choosers and `ls` show no pin status. The mount itself works everywhere.
- **Google Docs, Sheets and Slides are not editable through the filesystem.** They have no byte
  stream to serve, and appear as small stub files that open in the browser.
- **One account.** A second Google account needs a second remote, union and mount; the scripts
  assume one of each.
- **No "Computers" backup roots.** The API offers no way to discover them.

## How it got here

[docs/measurements.md](docs/measurements.md) is the record, with every figure, the machine and the
date beside it, and the runs that were void and why. The short version: a single range request
against real Drive averages **65.5 MB/s** over Wi-Fi on the test laptop, `rclone mount` keeps up at
**62.3**, and parallel requests show no effect that clears the measurement spread. The daemon's
central premise was false, so the daemon was not built.

[docs/design.md](docs/design.md) is that daemon's specification, kept as research rather than as a
plan. Its survey of the Drive API — the quota arithmetic, the name mapping, the failure modes, the
absence of delta upload — is sound and still answers questions. Its architecture is history.
[docs/plan.md](docs/plan.md) is what is actually next.

## Licence

GNU General Public License, version 3 or later. See [LICENSE](LICENSE) for the licence,
[COPYRIGHT](COPYRIGHT) for the statement and what it does not cover, and [NOTICE](NOTICE) for what
OurSync needs at run time and does not distribute.
