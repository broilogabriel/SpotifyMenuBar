# CLAUDE.md

This project's AI guidance lives in **[AGENTS.md](./AGENTS.md)** — read it before
making changes.

Quick reference:

- AppKit app is `Sources/SpotifyMenuBar/main.swift`; pure logic is in
  `Sources/SpotifyMenuBarCore/` (never `import AppKit` there). `swift build` to verify;
  `swift run SpotifyMenuBarCoreTests` for the unit checks (safe non-interactively).
  **Do not** run `swift run` — it launches a foreground GUI app that blocks.
- Controls the local Spotify desktop app via AppleScript. No API keys / OAuth /
  network — do not add any.
- AGENTS.md lists hard-won design decisions (notch handling, trailing anchor,
  AppleScript re-query, smart-previous, `.menu` for right-click). Don't regress them.
- **Never add AI attribution** (`Co-Authored-By`, "Generated with Claude", etc.) to
  commits, PRs, comments, or anything. See AGENTS.md → "Attribution — hard rule".
- Superpowers specs/plans under `docs/superpowers/` are **versioned and committed** — no
  `.gitignore` there. See AGENTS.md → "Design docs".
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/);
  review comments follow [Conventional Comments](https://conventionalcomments.org/).
  See AGENTS.md for the formats.
