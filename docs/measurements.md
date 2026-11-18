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

If that is false, OurSync's read path wins nothing and the repository should become a thin pinning
and status layer over rclone, or be abandoned. `CLAUDE.md` says to say so plainly, so this document
exists to make the saying possible either way.

## Setup, 2026-11-17

A read-only Drive remote on the personal Google account, scope `drive.readonly` only.

Two OAuth clients were used, and the difference between them is itself a finding:

| client | notes |
|---|---|
| rclone's shared client ID | warns on every call that it is "being retired and will stop working during 2026". Shared by every rclone user. |
| our own, Cloud project `oursync-515016` | Desktop client "OurSync desktop", External/Testing, one test user. Created 2026-11-17. |

The credential is at `~/.config/oursync/client_secret.json` on `jonny-precision` and in
`~/Downloads/oursync-client-secret.json` on the Legion. **No client ID is in this repository, and
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

### reckless-ci-lin-0, wired gigabit, 2026-11-17 - **VOID, taken under CI load**

**Do not use these numbers.** Every sample below was taken while `reckless-ci-lin-0` was running
another session's CI, continuously, at a load average reaching 13.06 on 16 cores.

The runner's own worker logs, read afterwards, show back-to-back jobs with roughly two-second gaps:

```
08:35:32 -> 08:37:32      08:52:23 -> 08:59:52
08:37:34 -> 08:47:12      08:59:55 -> 09:02:10
08:47:14 -> 08:50:51      09:02:12 -> 09:04:25
08:50:53 -> 08:52:21      09:04:27 -> still running
```

The benchmark ran 09:00:55 to about 09:05. There is no window in it that was not under load.

How this was missed, because the same gap will catch the next person: the check that was run was
`pgrep -x fastchess`, for a chess match, which is the rule this workspace writes down and it
correctly reported none. Machine load was read once, at 08:32, and it was 0.00 - **three minutes
before the first CI job started** - and never read again before measuring half an hour later. The
workspace's own guidance names `Runner.Worker` beside `cc1plus` or `cmake` as the sign of an
ordinary CI build, and it was not looked for.

**Before any run on a shared machine: check for the match, check for `Runner.Worker`, and check the
load again immediately before the first sample, not once at the start of the session.**

The numbers are kept below only so the error is legible, and because one feature of them matters:
within the first run, taken over a shorter window, the two single-stream samples were 67.1 and 68.8
- a spread of 1.7 MB/s - while four streams gave 90.9. Pooling that run with the second one produced
the 17.9 MB/s "spread" that the verdict then leaned on. A contaminated repeat had been allowed to
set the noise floor, and that is what made a possible 34% gain look like noise.

| streams | samples (MB/s) | mean | spread |
|---|---|---|---|
| 1 | 67.1, 68.8, 83.3, 65.4, 81.9 | 73.3 | 17.9 |
| 4 | 90.9, 64.5, 87.1 | 80.8 | 26.4 |
| 8 | 78.1 | 78.1 | - |
| 16 | 76.4, 84.7, 88.7 | 83.3 | 12.3 |

Nothing may be concluded from this table. It is here as a record of a run that should not have been
started, and of what pooling a clean window with a contaminated one does to a noise estimate.

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

## Where this actually stands

A verdict was written here on 2026-11-17 saying the design's premise was refuted. **It has been
withdrawn**, because it rested on the lin-0 table above, and that table is void.

What is established, and what is not:

| | status |
|---|---|
| One stream fills **precision's Wi-Fi** | established. 65.5 MB/s mean, and single samples ran above the link control beside them. |
| Parallelism helps **on Wi-Fi** | no effect demonstrated - but this machine cannot show one, because the link saturates at about one stream's rate, so a per-connection cap would be invisible. |
| One stream fills a **gigabit** link | **not measured.** The only wired machine here is a CI runner and it was busy throughout. |
| `rclone mount` keeps up with raw range requests | established on precision: 62.3 MB/s at defaults, 77.6 tuned, against 65.5 for raw ranges. Not measured on a fast link. |
| Four streams, as Google's own desktop client uses | **not measured.** The one clean-looking signal - 90.9 MB/s against 67.1 and 68.8 for single streams, a 34% gain - is from the uncontaminated window of a run whose other half was not, and two samples prove nothing. |

## The acceptance bar, and why this stops here

Jonny closed the throughput question on 2026-11-17, before the wired re-run happened:

> "If we can consistently achieve 60MB/sec over Wi-Fi on the precision I'll be happy with that.
> Don't stress about exactly what the speed is because it varies according to other users on the
> network. [...] I think you're prematurely optimizing for a problem that in real world conditions
> isn't an issue."

**60 MB/s on precision's Wi-Fi.** Measured there: a single range request averages 65.5 MB/s over
twelve samples, and `rclone mount` gives 62.3 at its defaults and 77.6 tuned. The bar is met by the
simplest thing, and by the tool that already exists.

That makes the wired-gigabit re-run moot and it was cancelled. The household shares the link, so a
figure measured to a few percent on an idle wired machine would not describe the conditions the
software runs in. The question is **parked, not answered**: whether one stream fills a gigabit, and
whether Google's own client is right to use four streams, remain unknown and are now uninteresting
here.

The lasting correction is to the design, not the data. §6.6 called a parallel fetch pool "the single
most important performance decision in the design" and sized it at 8 workers, reasoning from a
measurement taken against a *different service*. The pool is now a latency convenience with a
default of 2, and §11.2a - "the most consequential measurement in the project" - is closed as a
question about a bottleneck that was not there.

Still untouched, and still the strongest remaining case for the project:

- **Small-file and metadata latency** across a 5 TB corpus - listings, `stat` storms, opening a file
  from an application. Throughput on one large file says nothing about it, and it is where a local
  database fed by Drive's change feed could plausibly beat rclone.
- **Write behaviour.** Not measured at all.

## What the corpus actually looks like, 2026-11-17

Jonny's remaining frustration with Drive is that **any change to a large file re-uploads all of it**,
however small the change. That is accurate and it is Google's doing, not something a client can work
around - §3.3 and the README record the verification. It is also the one thing that would justify
chunked storage, which §9.16 rejects as a default because it makes the files unusable in Drive's own
web interface.

So the question is how often it actually bites. Asked of the live Drive rather than guessed:

Files over 100 MB with **any** modification in the last 12 months: **40**, totalling 31.6 GiB. That
is a complete count, not a sample - the query ordered by `quotaBytesUsed desc` and the 41st result
was already under 100 MB.

Of those 40, the ones whose `modifiedTime` differs from their `createdTime` - the only ones that
could have been edited in place rather than simply uploaded - number **10**, and seven of them are
not edits at all (see below). What is left is a few replaced installer downloads, such as a plugin
pack re-uploaded three months after the first copy.

Almost everything large on this account is **write-once**: installers, `.iso` images, films, DVD
rips, archives. They are uploaded and then read. **The no-delta limitation costs this corpus very
little**, and chunked storage would trade away Drive-native usability to fix a cost that is close to
hypothetical here. It stays rejected, and now for a measured reason rather than a judgement.

This does not cover the Workspace account (§9 A7), which Jonny says is larger and is not in scope
yet. If large files are genuinely edited anywhere, it is likelier to be there.

### A real trap found while asking: `modifiedTime` can be in the future

Seven 1 GiB DVD `.VOB` chunks, created 2026-07-26 and 2026-07-27, all report:

```
modified = 2036-02-07T01:58:15.000Z
```

**Ten years ahead**, identical across every file in the rip, read straight from the API. Drive
accepts a client-supplied `modifiedTime` on upload and will store whatever it is given; this came
from the disc's own filesystem.

Anything that assumes `modifiedTime <= now`, or that resolves a conflict by "newest wins", or that
validates a cache entry by comparing a stored timestamp against a fetched one, will do the wrong
thing with these files **and will keep doing it for ten years**. Treat `modifiedTime` as an opaque
change marker, compare it only for equality against the value last seen, and never as a clock.

## A note on the control

`speed.cloudflare.com/__down` caps below 100 MiB, answers `403` above it, and begins answering `429`
to an address that has used it repeatedly - which this one now has. Both benchmark scripts therefore
require the control to return the bytes it asked for and print "failed" otherwise.

For a single-against-parallel comparison the external control is not needed anyway: if N streams
aggregate more than one does on the same machine in the same minutes, then one stream was not the
limit, and that conclusion needs nothing outside the measurement.
