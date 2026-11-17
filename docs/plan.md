# Plan

OurSync is working on `jonny-precision` and installed from [`../rclone/`](../rclone/). What follows
is what stands between that and a `.deb` other people can install.

The plan this file used to hold — M0 to M6, building the Go daemon described in
[design.md](design.md) — is gone. The measurements in [measurements.md](measurements.md) retired it:
a single stream already clears the acceptance bar and `rclone mount` keeps up with it, so the daemon
would have reimplemented something already installed on the machine.

## Done

- Drive streamed on demand at `~/Drive`, nothing mirrored, cache bounded and evicted.
- Pinning: a real local copy that is served instead of the remote and never evicted. Proved by
  marking the local copy and reading the marked bytes back through the mount.
- `oursync pin / unpin / list / status / doctor`, and two Nemo entries gated so each appears only
  where it applies.
- A `systemd --user` service that mounts at login and clears a stale mount before starting.

## Blocking a public release, and all of them are Jonny's call

These are not engineering tasks. Packaging before they are settled would be building the wrong
thing.

1. **The licence.** The README still says *"Proprietary. Private repository, not for distribution."*
   A shared `.deb` needs a licence, and the rest of the organisation's public code is GPLv3.
2. **Repository visibility.** Private today. Source has to be reachable for anyone to trust or
   rebuild the package, and GPLv3 requires an offer of source in any case.
3. **The Google onboarding wall, which is the real one.** Every user must create *their own* Google
   Cloud project and OAuth client before OurSync can see their Drive. That is roughly ten minutes of
   console clicking, and it cannot be removed:

   - Seeing a whole Drive needs Google's **restricted** `drive` scope.
   - An application that ships its own client ID with a restricted scope needs OAuth verification
     **plus an annually renewed third-party security assessment**, at a five-figure yearly cost.
   - Using a client from the user's own Cloud project falls under Google's documented personal-use
     exemption: no verification, no assessment, and a per-project quota nobody else shares.

   So the package can make the wall *shorter* — a `oursync setup` that walks the console steps and
   takes the downloaded `client_secret.json` — but it cannot remove it, and the README must say so
   before anyone installs. **This is the thing that decides whether OurSync is shareable in a
   friendly way or only to people who will tolerate that.**

## The package

Mechanically small; the scripts are already the whole product.

- `debian/` with `control`, `rules`, `install`, `postinst`, `prerm`; built with `dpkg-buildpackage`
  or `equivs`-style minimal tooling, in CI on the Linux runner.
- Paths move from the per-user install to system ones: `/usr/bin/oursync`,
  `/usr/bin/oursync-nemo`, `/usr/share/nemo/actions/`, `/usr/lib/systemd/user/oursync-mount.service`.
  The `@BIN@` templating already in the `.in` files covers this; only the substituted value changes.
- **Per-user state cannot be created at install time**, because a `.deb` installs once for the
  machine and the config, the union remote and the pin directory are per-user. So `install.sh`
  splits: the file-placing half becomes the package, and the per-user half becomes
  **`oursync setup`**, run once by each user, which is also where the Google onboarding lives.

### The dependency question, which is not routine

`Depends: rclone` is wrong as written. **Ubuntu 24.04, which Mint 22.3 is built on, ships rclone
1.60.1**; the machine this was developed and tested on runs **1.76.0**, installed by hand into
`/usr/local/bin`. Nothing has been tested against 1.60.1.

Before the dependency line is written, find the real floor by testing against 1.60.1 in a container:
the union `:nc` modifier and the `epall` policies, `--vfs-cache-mode full` with the cache flags
used, `rc vfs/forget`, and the `RCLONE_RC_*` environment variables. Then either

- `Depends: rclone (>= <the measured floor>)` if 1.60.1 clears it, or
- document that rclone must come from rclone.org's own `.deb` rather than from apt, and have
  `oursync setup` check the version and say so plainly rather than failing obscurely later.

Guessing here produces a package that installs cleanly and then misbehaves in a way whose cause is
invisible to the user.

## Functional gaps worth closing first

- **Writes.** The mount is `--read-only` because the remote holds `drive.readonly`. Shipping a
  read-only Drive client to other people needs saying out loud, or fixing.
- **One account.** A second Google account needs a second remote, union and mount. The scripts
  assume one of each.
- **`--help`, a man page, and a `oursync doctor` that diagnoses rather than only reports.**

## Not doing

- The Go daemon. See [measurements.md](measurements.md).
- Chunked storage for delta uploads. Measured against the real corpus, almost nothing large is
  edited in place, so it would trade Drive-native usability for a cost that is barely paid.
- Per-file sync emblems in the file manager. The menu says what a file is; the icon does not.
