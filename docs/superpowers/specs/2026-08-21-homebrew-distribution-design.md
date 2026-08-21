# Homebrew distribution — design

**Date:** 2026-08-21
**Status:** accepted, implemented in `feat/homebrew-distribution`

## Problem

The app is installable only by cloning the repo and running `build-app.sh`. Make it
installable with `brew`, without an Apple Developer Program membership.

## Why not the official homebrew-cask

Two independent blockers, both verified 2026-08-20:

- **Notability.** Self-submission by the repository owner requires "at least 90 forks,
  90 watchers or 225 stars", and "a code repository less than 30 days old is normally
  not eligible". The repo is at 0/0/0.
- **Gatekeeper.** Homebrew is "ending support for all casks that fail Gatekeeper checks
  on September 1st, 2026" and is removing `--no-quarantine`. An ad-hoc-signed bundle
  fails those checks: on Apple Silicon a quarantined binary without a valid signature
  is refused outright.

Homebrew's documented fallback applies: "Software that does not meet the official
criteria can generally be maintained in a third-party tap."

## Decision

A personal tap, `broilogabriel/homebrew-tap`, holding a **formula that builds from
source** — not a cask, and not a prebuilt download.

The reasoning is narrower than "avoid paying Apple". A locally compiled bundle never
receives the `com.apple.quarantine` attribute, so Gatekeeper never evaluates it and the
existing ad-hoc signature is sufficient. This is not a workaround of Gatekeeper; it is
the case Gatekeeper was never meant to cover. A downloaded build of the same bytes
would be blocked, and would require Developer ID signing plus notarization.

Rejected alternatives:

| Option | Why not |
|---|---|
| Cask + Developer ID + notarization | $99/yr, CI to sign/notarize/staple, and the notability gate still blocks upstreaming for the foreseeable future. Worth revisiting only if the project gains users. |
| Cask with `quarantine: false` | Bets on a stanza whose supporting mechanism Homebrew is actively removing. |
| Caveat instructing a *copy* into `/Applications` | `brew upgrade` would stop updating the running app, removing most of the reason to use brew. |
| `brew services` launchd block | Sidesteps the BTM path problem, but makes the app's own Launch at Login toggle lie to brew users. Reconsider if the deferred fix below proves unworkable. |

## Verified constraints

Established by installing a throwaway tap on a real machine, not from documentation:

1. **`swift build` needs `--disable-sandbox`.** SwiftPM shells out to `sandbox-exec`,
   which cannot nest inside Homebrew's build sandbox. The failure surfaces as
   `error: Invalid manifest` with `sandbox_apply: Operation not permitted` buried in
   the log — it does not resemble a sandbox problem.
2. **A tap is mandatory.** Homebrew 6.0.18 refuses loose formula files outright:
   `Error: Homebrew requires formulae to be in a tap`.
3. **The URL must carry the version.** With one that does not, formula loading fails
   at `invalid attribute for formula: version (nil)`. The repo previously had zero
   tags. Verified that Homebrew parses `1.1.0` out of the release-asset filename
   `SpotifyMenuBar-1.1.0.tar.gz`, so no explicit `version` stanza is needed.
4. **The ad-hoc signature survives installation** — `flags=0x2(adhoc)`,
   `Identifier=com.local.SpotifyMenuBar`, `TeamIdentifier=not set`. `SMAppService` and
   TCC keep the stable identity they need.
5. **No quarantine on the installed keg** — only `com.apple.provenance`, byte-identical
   in posture to a `build-app.sh` install. `spctl -a -t exec` reports `rejected` for
   both the keg build and the known-working `/Applications` build, which establishes
   that spctl's verdict does not predict launchability; quarantine does.
6. **A formula cannot write to `/Applications`.** Only the cask `app` stanza installs
   there, hence the `caveats` symlink instruction.
7. **`SMAppService` registration works from the keg**, but macOS pins it to the
   versioned path. BTM recorded
   `file:///opt/homebrew/Cellar/spotifymenubar/0.0.1/SpotifyMenuBar.app/` with
   disposition `allowed` — not the `/Applications` symlink, because LaunchServices
   resolves the symlink before launching (the running process reported the Cellar path).

## Consequences

- **Launch at Login breaks on upgrade.** The pinned path stops existing, so the user
  must re-toggle. Documented in README and AGENTS.md. The fix — re-register on launch
  when status is already `.enabled` — is deliberately deferred; it needs its own
  verification that re-registration rewrites the recorded URL rather than adding a
  second entry.
- **The consent prompt reappears on upgrade.** Every build produces a new cdhash
  (measured: `207104ca…` for the keg build vs `57c3b7f1…` for the `/Applications`
  build), so TCC treats it as new code. Already true of every `build-app.sh` run, so
  this is not a regression.
- **Releases become a real procedure.** Version lives only in `Info.plist`, and a tag
  must exist before the formula can reference it. Steps in AGENTS.md.
- **A LICENSE was required.** The formula's `license` stanza needs a real answer; MIT
  was chosen.

## Release automation (added same day)

Two workflows. `ci.yml` runs build, unit checks and `build-app.sh` on pull requests.
`release.yml` triggers on a `v*` tag and does everything downstream of the tag:
version/tag consistency check, build, tarball, release asset, and the tap's
`url` + `sha256` bump.

Two decisions inside it are load-bearing:

- **The formula points at an uploaded release asset, not `/archive/refs/tags/`.**
  GitHub states auto-generated archives are not guaranteed byte-stable, and a git
  upgrade has changed them before, breaking pinned checksums across Homebrew,
  MacPorts and Spack at once. Uploaded assets are immutable, so the pinned `sha256`
  cannot rot out from under a release that never changed.
- **Cross-repo push uses a deploy key**, not a PAT — scoped to the one repo and
  without an expiry to forget about.

Bumping `Info.plist` and creating the tag stay manual: that is the deliberate "release
now" decision, and automating it would mean a workflow with write access to `main`.

## Out of scope

Developer ID signing, notarization, bottles, and submission to homebrew-cask.
Automating the version bump and tag creation. Any CI coverage of the no-eviction
guarantee, which is physically impossible on a headless runner.
