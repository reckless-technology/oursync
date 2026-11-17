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

### reckless-ci-lin-0, wired gigabit

Pending - see below.

## What is not yet measured

- rclone mount throughput, which is the incumbent's real number. The range benchmark says what the
  API and the link can do; the mount says how much of that survives rclone's VFS, and only the gap
  between them is available for Aqueduct's read path to win.
- Whether ~70 MB/s is a per-connection cap. Wi-Fi cannot answer it: the link is at roughly the same
  rate, so a cap would be invisible. Jonny reports about 900 Mbit on ethernet, where a per-connection
  cap at 70 MB/s would leave nearly half the link unused and parallelism would pay.
