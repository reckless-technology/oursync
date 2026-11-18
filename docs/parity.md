# Parity with Drive for desktop

The brief is what Google ships for Windows and macOS and not for Linux. This is that feature list,
item by item, so the gaps are a list rather than an impression.

Each row says how it was established, because "it should work" and "I watched it work" are
different claims. **Verified** means observed on this software. **From rclone's documentation**
means the behaviour is rclone's and documented but not exercised here. **Not exercised** means
nothing has demonstrated it yet.

## Done

| Drive for desktop | OurSync | How established |
|---|---|---|
| Streams My Drive as a drive you can browse | `~/Drive`, an rclone mount of a union remote | Verified, in daily use on `jonny-precision` |
| Nothing downloaded until read; a Drive larger than the disk | `--vfs-cache-mode full` with a sparse cache | Verified — 5 TB mounted on a laptop that cannot hold it |
| Cached what you have read, evicted as it fills | `CACHE_MAX_SIZE`, `CACHE_MAX_AGE` | Verified |
| "Available offline" on a chosen file or folder | `oursync pin`, or the Nemo entry | Verified by marking the local copy and reading the marked bytes back through the mount |
| Mirror mode for chosen items, two-way | A pin is that mirror; writes reach both copies | Verified against a two-directory union on rclone 1.60.1 and 1.76.0 (`tools/rclone-floor-test.sh`); **not yet against Google**, see Next |
| Local changes go up | The mount is read-write, `--vfs-write-back` coalescing repeated saves | Verified through the mount against a local upstream; not yet against Google |
| A new local file goes to the cloud, not to the mirror | `:nc` excludes local disk from the union's CREATE category | Verified — the floor test asserts the file appears in the remote upstream and not the local one |
| Remote changes appear | Streamed files within `--poll-interval` from Drive's change feed; pinned files when `oursync refresh` runs, every 5 minutes | Verified for streamed files; refresh verified against a local upstream |
| Deletes are recoverable | Deletes go to Drive's trash | From rclone's documentation (`--drive-use-trash` defaults to true); not exercised, the token is read-only |
| Starts at login | `oursync-mount.service`, a systemd user unit | Verified |
| Bandwidth limit | `BWLIMIT` in the configuration | Verified that rclone accepts it; the rate was not measured |
| File-manager integration | Two Nemo entries, gated so each appears only where it applies | Verified |

## Partly

| Drive for desktop | OurSync | Why it is short |
|---|---|---|
| Makes a conflict copy when both sides changed | Reports the conflict with both timestamps, overwrites nothing, exits non-zero | Deliberate for now: the thing that would be overwritten could be the only copy. The naming for a conflict copy is specified in [design.md](design.md) §9 and is not implemented |
| Google Docs, Sheets and Slides open in the browser from a stub file | They appear as exported documents of unknown size | Verified: `lsjson` on a real native document reports `Size: -1`, a `docx` MIME type and **no hash at all**. They cannot be edited in place and there is no write-back |
| Pause and resume syncing | `systemctl --user stop oursync-mount.service` stops the lot | There is no pause that leaves reads working while holding uploads |

## Not done

| Drive for desktop | What it would take |
|---|---|
| Shared drives (Team Drives) | rclone's drive backend takes `team_drive` per remote; `oursync setup` does not offer it and the union would need one upstream per drive |
| "Shared with me" | A second remote with `--drive-shared-with-me`, and a second mount or another union upstream |
| Backs local folders up to Drive's "Computers" | Nothing: the API offers no way to discover those roots. See [design.md](design.md) |
| Up to four Google accounts at once | One remote, one union, one mount. A second account needs a second set, and the scripts assume one |
| Status emblems on every file, in every file manager | Nemo shows no emblem; the right-click menu is the only indicator. Other file managers and `ls` show nothing |
| Google Photos | A different API and a different rclone backend |
| Offline editing of Google Docs | Not possible through a filesystem |
| Share, copy link, manage access from the file manager | More Nemo actions over `rclone backend` calls |
| Differential upload | **Nothing. It cannot be done.** No public Drive API offers write-at-offset, append, patch, a block or signature endpoint, or a revision from a diff. Google's own client has done it since October 2024 through something undocumented. Verified against the whole v3 method list, 2026-11-16 |

## Next, in order

1. **The live write test.** Everything in the two-way rows was proved against a union of two local
   directories, which is all the union's policies can distinguish, plus a read-only Drive. One
   re-consent (`oursync setup --scope drive`) and then: create, edit, rename, delete, a pinned file
   edited on both sides, and a save larger than the write-back delay.
2. **Shared drives and "shared with me"**, which are configuration rather than design.
3. **A conflict copy**, so a conflict does not need a person reading a journal.
