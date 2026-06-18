#!/bin/bash
# Builds SpotifyMenuBar.app -- a self-contained, launch-at-login menu-bar app bundle.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP="SpotifyMenuBar.app"
BIN="SpotifyMenuBar"

echo "[1/3] Compiling (release)..."
swift build -c release

echo "[2/3] Assembling ${APP} ..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp ".build/release/${BIN}" "${APP}/Contents/MacOS/${BIN}"
cp "Info.plist" "${APP}/Contents/Info.plist"

# Ad-hoc code signature gives the bundle a stable identity, which SMAppService
# (launch-at-login) and macOS Automation consent (TCC) rely on.
echo "[3/3] Ad-hoc signing..."
codesign --force --sign - "${APP}"

echo ""
echo "Built: ${DIR}/${APP}"
echo ""
echo "Next steps:"
echo "  1. Move it to Applications:   mv \"${DIR}/${APP}\" /Applications/"
echo "  2. Open it:                   open /Applications/${APP}"
echo "  3. Approve the one-time 'control Spotify' prompt."
echo "  4. Right-click the menu-bar item -> enable 'Launch at Login'."
