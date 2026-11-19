# Plan

OurSync is installed from [`../rclone/`](../rclone/) and packaged from [`../debian/`](../debian/).
What follows is what is done, what is next, and the two things that are Jonny's call rather than
engineering.

The plan this file used to hold — M0 to M6, building the Go daemon described in
[design.md](design.md) — is gone. The measurements in [measurements.md](measurements.md) retired
it: a single stream already clears the acceptance bar and `rclone mount` keeps up with it, so the
daemon would have reimplemented something already installed on the machine. **What that retired
was the daemon's architecture, not the product's scope.** The brief was and is a Drive for desktop
equivalent: streaming by default, chosen files mirrored, synchronised both ways.

## Done

- Drive at `~/Drive`, streamed on demand, nothing mirrored, cache bounded and evicted.
- Pinning: a real local copy, served instead of the remote and never evicted. Proved by marking the
  local copy and reading the marked bytes back through the mount.
- Two-way sync. A write through the mount reaches both upstreams, so a pinned file cannot diverge;
  a new file created in the mount goes to Drive and never to local disk, which is what `:nc` is
  for. `oursync refresh` carries a remote change into a pinned copy, and reports a conflict rather
  than resolving one. `oursync-refresh.timer` runs it every five minutes.

  **That took two fixes, and neither is sufficient alone** — measured 2026-11-18, both ways round.
  Without `--inplace` the VFS uploads to `<name>.<hash>.partial` and renames it over the target, so
  a save is a *create*, which `:nc` keeps out of the local upstream. And a file created through the
  mount is pinned afterwards, behind the mount's back, so the mount's object for that path was
  resolved when only one upstream held it and every later save follows that stale object; only a
  `vfs/refresh` of the parent rebuilds it, and no form of `vfs/forget` does. Dropping either fix
  puts a pinned-write check back on the floor. The first was found by the live run against Drive,
  the second by a fixture that reproduces it with no Google involved.
- The mount's read-only flag is derived from the remote's own scope, so a read-only token gives an
  immediate `EROFS` instead of an API refusal half-way through a save.
- `oursync pin / unpin / refresh / list / status / mount / unmount / setup / doctor / version`, a
  man page, and two Nemo entries gated so each appears only where it applies.
- `oursync setup`: the per-user half a package cannot do, including the one-time Google Cloud
  walkthrough (one run: it opens each console page, finds the downloaded client JSON, refuses a
  Web client, writes the remote straight into rclone's configuration so the secret never appears
  in `ps`, runs the consent, and checks the remote with `rclone about`, explaining the usual
  failures with project-specific links) and the scope upgrade (`--scope drive`), which changes the configured scope without
  touching the existing token and only then replaces it.
- A `.deb`: `debian/`, built by `tools/build-deb.sh`, with the version coming from the git tags so
  nothing in the tree is edited to release.
- CI on GitHub-hosted images, since the repository is public: shellcheck at style level, the
  package built, lintian'd, installed, exercised and removed, and the rclone floor test against
  both the version apt ships and the current one. `release.yml` leaves a draft release, as the
  organisation's other products do.
- An icon: Jonny's artwork at the seven hicolor sizes, installed by the package under the name
  `oursync`, which is the name `oursync-nemo` hands to `notify-send`.
- **The dependency floor is measured, and it is not a single `>=`.** `tools/rclone-floor-test.sh`
  passes 20 of 20 on 1.67.0, 1.68.1, 1.68.2, 1.70.3 and 1.76.0, and fails on everything below 1.67
  and on 1.68.0, run against rclone's own release binaries on `jonny-precision`, 2026-11-18:

  | rclone | result |
  |---|---|
  | 1.60.1, 1.61.1, 1.62.2 | no `--inplace`, so the mount will not start |
  | 1.63.0, 1.63.1, 1.64.2, 1.66.0 | the union does not carry an update to both upstreams, with no mount involved |
  | 1.67.0 | 20 of 20 |
  | 1.68.0 | cannot parse `rc_addr` from the environment, which is how the control-port credentials are passed |
  | 1.68.1, 1.68.2, 1.70.3, 1.76.0 | 20 of 20 |

  Because that is not expressible as one `>=`, and because PATH decides which rclone runs while
  dpkg cannot see one installed from rclone.org into `/usr/local/bin`, the floor is enforced by
  `require_usable_rclone` in the program and `Depends: rclone` carries no version. Mint 22 and
  Ubuntu 24.04 ship 1.60.1, so installing the current rclone is now a documented first step.

  The test itself was wrong twice before it was right — see the comment in it about the trailing
  colon — which is why it was first run where the answer was already known. The same discipline
  caught the `--inplace` regression: the floor test had not been run on 1.60.1 since `--inplace`
  was added, and that one flag silently moved the floor seven minor versions.

## Next

- **The acceptance suite passes 57 of 57, twice consecutively**, against the installed 0.1.10
  package and the real Drive, 2026-11-18 on `jonny-precision`. `tools/acceptance-test.sh` is the
  corner-case half: twenty awkward filenames (quotes, `$`, backticks, pipes, a leading dash, a name
  that looks like a flag, accents, CJK, an emoji, a trailing space, an embedded newline), a
  254-character name, a zero-byte file, five levels of nesting, a megabyte of binary byte-for-byte,
  pinning a directory and a name with a space, a file added to a pinned directory in Drive
  arriving on refresh, unpin, rename, delete, a two-sided conflict reported and neither copy
  touched, a modification time ten years in the future, a mount restart, the rclone process killed
  outright, five wrong arguments, and the installed package's own files.

  It was run twice on purpose. The first two runs failed in *different* places, and both were races
  in the test rather than faults in the product — a suite that moves around is no use as a gate.
  One assumed a pinned file's two copies arrive together, when the union writes local disk during
  the save and the upload is held by `--vfs-write-back`. The other believed `mountpoint -q` about a
  mount whose process had just been SIGKILLed; see the comment in the script, because that one can
  be wrong in both directions within seconds.

  **One real thing came out of it**, and it is in the README's limitations rather than fixed: a
  write into `~/Drive` during the ~15 second restart window after a crash lands on local disk and
  is then hidden under the mount. That is how FUSE works everywhere rather than something OurSync
  does wrong, and nothing is destroyed, but a sync tool should say so. Worth revisiting after 1.0:
  the mount point could be made unwritable while nothing is mounted on it.
- **The live write test** passes 15 of 15 against the real Drive, 2026-11-18 on `jonny-precision`:
  create, edit, rename, delete and its recoverable trash, 24 MiB byte for byte, repeated
  saves inside the write-back window, and a remote change pulled into a pinned copy.
  `tools/live-write-test.sh` works inside a folder of its own at the top of Drive that it creates
  and removes, touches nothing else, and refuses to run against a read-only mount. It should be
  run again whenever the union's policies or the write path change; it is the only thing that
  tests them against Google rather than against two local directories, which is all the union
  policies can tell apart.

  Run it with the exit status in view. A pipeline that ends in `tail` reports `tail`'s status, so
  the run that found the pin bug looked like a clean exit while printing `1 failed`.
- **A Cloud project must be published to production**, which is a step in the walkthrough rather
  than engineering, but it is the difference between a mount that keeps working and one that asks
  for consent every seven days. Google ties that to the consent screen carrying no logo. Jonny's
  own project was published on 2026-11-18 and its logo removed for exactly this reason. Since
  2026-11-19 setup has the user publish *before* the client exists and consent happens, which
  drops the test-user step. Google's documentation says production is open to any account and
  that Testing expires the token; it does not say publishing before a client exists is allowed,
  and that ordering is unconfirmed against a real fresh project (see the PR that introduced it).
  `oursync doctor` cannot read the publishing status, and says so rather than guess.
- **Shared drives and "shared with me"**, which are configuration rather than design, and the
  largest remaining gap after writes. [parity.md](parity.md) is the full audit against Drive for
  desktop, with how each row was established.
- **A conflict that a person can act on.** Today a conflict is a message in the journal and a
  non-zero exit from the timer. Drive for desktop makes a conflict copy; the naming for that is
  already specified in [design.md](design.md) §9.
- `oursync doctor` could check reachability and token expiry, not only configuration. It now
  reports the client's project and file type, but not the publishing status, which nothing it
  can ask exposes.

## Jonny's call

1. **Publishing a release.** The machinery leaves a draft; putting it in front of the public is a
   human step, as everywhere else in the organisation.
2. **Whether the Google onboarding wall is acceptable** for the people he wants to share this with.
   Every user must create their own Cloud project and OAuth client — five console pages, each opened for
   them by `oursync setup`. It cannot be removed:

   - Seeing a whole Drive needs Google's **restricted** `drive` scope.
   - An application that ships its own client ID with a restricted scope needs OAuth verification
     **plus an annually renewed third-party security assessment**, at a five-figure yearly cost.
   - A client from the user's own Cloud project falls under Google's documented personal-use
     exemption: no verification, no assessment, and a per-project quota nobody else shares.

   So `oursync setup` makes the wall as short as it can (one run, no re-run, no file to move by hand) and the README says so before anyone installs, but the
   wall stays. It is the one thing that decides whether OurSync is shareable in a friendly way or
   only to people who will tolerate that.

## Not doing

- The Go daemon. See [measurements.md](measurements.md). The foundation under `internal/` was
  deleted when the repository went public rather than shipped as dead code.
- Chunked storage to work around the absent delta upload. Measured against the real corpus, almost
  nothing large is edited in place, so it would trade Drive-native usability for a cost that is
  barely paid.
- Per-file sync emblems in the file manager. The menu says what a file is; the icon does not.
