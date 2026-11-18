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
- The mount's read-only flag is derived from the remote's own scope, so a read-only token gives an
  immediate `EROFS` instead of an API refusal half-way through a save.
- `oursync pin / unpin / refresh / list / status / mount / unmount / setup / doctor / version`, a
  man page, and two Nemo entries gated so each appears only where it applies.
- `oursync setup`: the per-user half a package cannot do, including the one-time Google Cloud
  walkthrough and the scope upgrade (`--scope drive`), which changes the configured scope without
  touching the existing token and only then replaces it.
- A `.deb`: `debian/`, built by `tools/build-deb.sh`, with the version coming from the git tags so
  nothing in the tree is edited to release.
- CI on GitHub-hosted images, since the repository is public: shellcheck at style level, the
  package built, lintian'd, installed, exercised and removed, and the rclone floor test against
  both the version apt ships and the current one. `release.yml` leaves a draft release, as the
  organisation's other products do.
- An icon: Jonny's artwork at the seven hicolor sizes, installed by the package under the name
  `oursync`, which is the name `oursync-nemo` hands to `notify-send`.
- **The dependency floor is measured.** `tools/rclone-floor-test.sh` passes 16 of 16 on rclone
  1.60.1 (what Ubuntu 24.04 and Mint 22 ship) and on 1.76.0, on `jonny-precision`, 2026-11-17. So
  `Depends: rclone (>= 1.60)` is evidence. The test itself was wrong twice before it was right —
  see the comment in it about the trailing colon — which is why it was first run where the answer
  was already known.

## Next

- **The live write test**, which is written and waiting: `tools/live-write-test.sh`. Everything
  above is proved against a union of two local directories, which is all the union policies can
  tell apart, plus a read-only Drive. The remote still holds `drive.readonly`, so the one thing not
  yet exercised against Google is a real upload. The script covers create, edit, rename, delete and
  its trash, a 24 MiB file, repeated saves inside the write-back window, a pinned file written
  through the mount reaching both copies, and a pinned file changed in Drive behind the mount's
  back. It works inside a folder of its own that it creates and removes, touches nothing else, and
  refuses to run against a read-only mount — verified refusing, 2026-11-17. All it needs is one
  re-consent: `oursync setup --scope drive`.

  Until that is run, the product's headline feature is unproven against Google and the mount on
  `jonny-precision` is read-only in practice, whatever the code can do.
- **A Cloud project must be published to production**, which is a step in the walkthrough rather
  than engineering, but it is the difference between a mount that keeps working and one that asks
  for consent every seven days. Google ties that to the consent screen carrying no logo. Jonny's
  own project was published on 2026-11-18 and its logo removed for exactly this reason.
- **Shared drives and "shared with me"**, which are configuration rather than design, and the
  largest remaining gap after writes. [parity.md](parity.md) is the full audit against Drive for
  desktop, with how each row was established.
- **A conflict that a person can act on.** Today a conflict is a message in the journal and a
  non-zero exit from the timer. Drive for desktop makes a conflict copy; the naming for that is
  already specified in [design.md](design.md) §9.
- `oursync doctor` could check reachability and token expiry, not only configuration.

## Jonny's call

1. **Publishing a release.** The machinery leaves a draft; putting it in front of the public is a
   human step, as everywhere else in the organisation.
2. **Whether the Google onboarding wall is acceptable** for the people he wants to share this with.
   Every user must create their own Cloud project and OAuth client — roughly ten minutes of console
   clicking. It cannot be removed:

   - Seeing a whole Drive needs Google's **restricted** `drive` scope.
   - An application that ships its own client ID with a restricted scope needs OAuth verification
     **plus an annually renewed third-party security assessment**, at a five-figure yearly cost.
   - A client from the user's own Cloud project falls under Google's documented personal-use
     exemption: no verification, no assessment, and a per-project quota nobody else shares.

   So `oursync setup` makes the wall shorter and the README says so before anyone installs, but the
   wall stays. It is the one thing that decides whether OurSync is shareable in a friendly way or
   only to people who will tolerate that.

## Not doing

- The Go daemon. See [measurements.md](measurements.md). The foundation under `internal/` was
  deleted when the repository went public rather than shipped as dead code.
- Chunked storage to work around the absent delta upload. Measured against the real corpus, almost
  nothing large is edited in place, so it would trade Drive-native usability for a cost that is
  barely paid.
- Per-file sync emblems in the file manager. The menu says what a file is; the icon does not.
