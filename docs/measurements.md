# Measurements

The numbers this project's decisions rest on, with the machine and the date beside each, because the
arithmetic keeps working after the machine goes away.

Everything here was taken with `tools/range-fetch-bench.sh` and `tools/measure-mount-throughput.sh`,
which are in the repository so a figure can be re-derived rather than believed.

## The question being measured

`docs/design.md` §6.6 specifies a parallel fetch pool, justified by the claim that **one stream will
not fill a fast downlink**. `rclone mount` reads a file as a single chunked sequential stream. So the
project's whole read path rests on one proposition:

> N concurrent range requests to Drive are materially faster than one.

If that is false, Aqueduct's read path wins nothing and the repository should become a thin pinning
and status layer over rclone, or be abandoned. `CLAUDE.md` says to say so plainly, so this document
exists to make the saying possible either way.

## Setup, 2026-11-17

A read-only Drive remote on `the personal Google account`, scope `drive.readonly` only.

Two OAuth clients were used, and the difference between them is itself a finding:

| client | notes |
|---|---|
| rclone's shared client ID | warns on every call that it is "being retired and will stop working during 2026". Shared by every rclone user. |
| our own, Cloud project `aqueduct-515016` | Desktop client "Aqueduct desktop", External/Testing, one test user. Created 2026-11-17. |

The credential is at `~/.config/aqueduct/client_secret.json` on `jonny-precision` and in
`~/Downloads/aqueduct-client-secret.json` on the Legion. **No client ID is in this repository, and
none ever will be** - see the README.

The authorised token carried no `refresh_token_expires_in`, which is weak evidence against the
seven-day refresh-token cap that §11.1 raises for apps in Testing. Weak, because rclone keeps only
the OAuth fields it models and may simply have dropped it. Not yet settled.

## Why the first attempt could not be read

`tools/measure-read-throughput.sh`, against rclone's shared client, on `jonny-precision`, Wi-Fi:

| streams | MB/s |
|---|---|
| 1 | 54.5, 41.8, 61.2 |
| 2 | 8.7, 49.1 |
| 4 | 10.7, 5.3 |
| 8 | 47.5, 54.3, 4.9 |
| 16 | 5.3, 60.1 |

Bimodal, with a fast cluster at 42-61 MB/s and a slow one at 4.9-10.7, and **the split does not
follow the stream count**: eight streams produced 47.5, 54.3 and 4.9. The single-stream baseline
alone spanned 41.8 to 61.2. Nothing can be concluded from this.

rclone's own INFO logs recorded **zero** retries, 429s or backoff lines across the slow samples, so
whatever caused them was not a rate limit being signalled. The slow samples simply ran slowly.

Two defects in the method, both mine:

1. **No control.** With nothing measuring the link at the moment of each sample, a slow sample and a
   slow link are indistinguishable. Every later run takes a fixed non-Google download immediately
   after each sample.
2. **The control that was added first did not check its own result.** `speed.cloudflare.com/__down`
   caps below 100 MiB and answers `403` with a 1-byte body above it; dividing that by a near-zero
   time produced 5463 MB/s and 8291 MB/s on `reckless-ci-lin-0` - 45 and 69 Gbit on a gigabit link.
   A transfer that did not happen must never be allowed to read as infinite speed. The control is
   50 MiB, which is the most that endpoint will serve.

The bimodality did not recur against our own client ID. That is suggestive, not established: the
harness changed at the same time, so the client is not the only variable that moved.

## Single stream against parallel ranges

`tools/range-fetch-bench.sh`, own client, 512 MiB per sample split across the streams, each sample
reading a different region of a 9.33 GiB file so none is served from a cache the last one warmed.

### jonny-precision, Wi-Fi, 2026-11-17

Link control that day: Cloudflare 50 MiB at 64.1 MB/s, about 511 Mbit.

| streams | samples (MB/s) | mean |
|---|---|---|
| 1 | 71.8, 54.9, 69.7 | 65.5 |
| 2 | 77.6, 71.8 | 74.7 |
| 4 | 61.4, 68.1 | 64.8 |
| 8 | 56.8, 55.4, 68.4 | 60.2 |
| 16 | 69.4, 77.7 | 73.6 |

**The single-stream spread is 16.9 MB/s**, from 54.9 to 71.8, measured within one run on one machine.
The best parallel configuration beats the single-stream mean by 8.1 MB/s, less than half of that
spread. On this machine, at this link speed, **parallelism has no demonstrated effect**.

One stream also repeatedly ran *faster* than the Cloudflare control beside it (71.8 against 64.1).
A single Drive connection is therefore not the binding constraint here; the link is.

### reckless-ci-lin-0, wired gigabit, 2026-11-17

Run on the wired machine because Wi-Fi could not answer the question: precision's link is at about
the same rate as a single Drive stream, so a per-connection cap would be invisible there. Jonny
reports about 900 Mbit on ethernet, where a cap at 70 MB/s would leave nearly half the link unused.

1 GiB per sample. Two runs: the first was cut short at four samples when the ssh carrying it dropped
under load, so the second was launched detached with `setsid`. Both are kept; they are independent
repeats of the same configurations.

| streams | samples (MB/s) | mean | spread |
|---|---|---|---|
| 1 | 67.1, 68.8, 83.3, 65.4, 81.9 | 73.3 | 17.9 |
| 4 | 90.9, 64.5, 87.1 | 80.8 | 26.4 |
| 8 | 78.1 | 78.1 | - |
| 16 | 76.4, 84.7, 88.7 | 83.3 | 12.3 |

**A single connection reached 83.3 MB/s, 666 Mbit** - faster than several of the parallel samples.
There is no per-connection cap anywhere near 70 MB/s. Sixteen streams beat one by 10.0 MB/s on
means, against a single-stream spread of 17.9: the advantage does not clear the noise.

The Cloudflare control read 68-77 MB/s while Drive samples reached 90.9, so the control understates
this link - 50 MiB is too short a transfer to measure it, and that endpoint will not serve more.
The best observed figure puts the link at 727 Mbit or better, consistent with Jonny's 900.

## rclone mount, the incumbent's real number

`tools/measure-mount-throughput.sh`, `jonny-precision`, 2026-11-17, 1 GiB read from a cold cache for
each configuration.

| configuration | MB/s |
|---|---|
| `--vfs-cache-mode full` (defaults) | 62.3 |
| `--vfs-cache-mode off` | 64.4 |
| full, `--vfs-read-chunk-size 64M --vfs-read-chunk-size-limit off` | 69.2 |
| full, `--vfs-read-ahead 512M` | 77.6 |
| full, `--transfers 8 --vfs-read-chunk-size 64M` | 72.4 |
| **full (defaults), repeated** | **42.5** |

The first configuration repeated at the end gives 62.3 against 42.5, so **the noise floor of this
run is 19.8 MB/s** and every difference between the other rows is smaller than it. No tuning flag is
demonstrated to do anything.

The control column of this run is void. It was not guarded, Cloudflare began answering 403 with
one-byte bodies under repeated requests, and the script reported 357, 263, 250 and 416 MB/s on a
511 Mbit link. The same defect had already been found an hour earlier and was not carried into this
script. Both scripts now require the control to return the bytes it asked for and print "failed"
otherwise. The mount throughputs themselves are unaffected - `dd` moved a real GiB each time.

## The verdict

| path | precision, Wi-Fi | lin-0, wired |
|---|---|---|
| one range request | 65.5 mean | 73.3 mean, 83.3 best |
| parallel range requests | 60.2-74.7 by stream count | 78.1-83.3 by stream count |
| rclone mount | 42.5-77.6, 62.3 at defaults | not measured (no rclone there) |

**The design's premise is not supported.** `docs/design.md` §6.6 asserts that one stream will not
fill a fast downlink. On both machines a single Drive connection runs at or near whatever the link
will carry, parallel ranges add at most about 10 MB/s, and that gain is smaller than the variation
between repeats of the same configuration. rclone's mount lands in the same band as raw range
requests, so its VFS is not leaving throughput on the table either.

There is no gap here for Aqueduct's read path to win. What survives is the narrower list already in
`CLAUDE.md`: pinning, per-file status in Nemo, and cross-account bandwidth scheduling. None of those
is a reason to write a filesystem.

What this does **not** settle, stated so nobody mistakes the scope:

- Small-file and metadata latency, which is where a 5 TB corpus is actually painful - directory
  listings, `stat` storms, opening a file in an application. Throughput on one large file says
  nothing about it, and it is the one dimension where a local database over Drive's change feed
  could plausibly beat rclone.
- Write behaviour. Measured not at all.
- Whether the gain that does not clear the noise here is real. Settling a 10 MB/s difference against
  a 17.9 MB/s spread would need many more repeats than were run.
