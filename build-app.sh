#!/bin/bash
# Builds SpotifyMenuBar.app -- a self-contained, launch-at-login menu-bar app bundle.
#
# This is the ONLY build recipe: CI, the release workflow and the Homebrew formula all
# run it, so the SDK pin and its check below cannot drift between them. AGENTS.md #22.
#
# SWIFT_BUILD_FLAGS is passed through to `swift build` (the formula needs
# --disable-sandbox, because SwiftPM's sandbox cannot nest inside Homebrew's).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

APP="SpotifyMenuBar.app"
BIN="SpotifyMenuBar"
PLIST="${APP}/Contents/Info.plist"

# The SDK the binary records decides which AppKit behaviours it gets, and SwiftPM's
# default build system records the deployment target instead (13.0) -- measured at
# ~90% CPU against ~55% for the same source stamped 26.5. Stamp the installed SDK
# explicitly, and fail below if the binary disagrees.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
SDK="$(xcrun --show-sdk-version)"

echo "[1/4] Compiling (release, macOS ${MIN_OS}+, SDK ${SDK})..."
# shellcheck disable=SC2086  # SWIFT_BUILD_FLAGS is deliberately word-split
swift build -c release ${SWIFT_BUILD_FLAGS:-} \
    -Xlinker -platform_version -Xlinker macos -Xlinker "${MIN_OS}" -Xlinker "${SDK}"

echo "[2/4] Checking the SDK the binary records..."
RECORDED="$(vtool -show-build ".build/release/${BIN}" | awk '$1 == "sdk" { print $2 }')"
if [ "${RECORDED}" != "${SDK}" ]; then
    echo "error: binary records sdk ${RECORDED:-<none>}, expected ${SDK} (the installed SDK)." >&2
    echo "       AppKit treats a wrong SDK stamp as an older app; see AGENTS.md decision #22." >&2
    exit 1
fi

echo "[3/4] Assembling ${APP} ..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp ".build/release/${BIN}" "${APP}/Contents/MacOS/${BIN}"
cp "Info.plist" "${PLIST}"

# Identify the build, so "which build is running?" is one right-click (the menu shows
# these). A release tarball is a `git archive` with no .git, so no SHA there means a
# release build; inside a checkout, anything not exactly on a tag is a dev build.
if git rev-parse --git-dir >/dev/null 2>&1; then
    COMMIT="$(git rev-parse --short HEAD)"
    if git describe --exact-match --tags HEAD >/dev/null 2>&1 && git diff --quiet HEAD; then
        CHANNEL="release"
    else
        CHANNEL="dev"
    fi
else
    COMMIT=""
    CHANNEL="release"
fi
/usr/libexec/PlistBuddy -c "Add :SMBBuildCommit string ${COMMIT}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Add :SMBBuildSDK string ${RECORDED}" "${PLIST}"
/usr/libexec/PlistBuddy -c "Add :SMBBuildChannel string ${CHANNEL}" "${PLIST}"

# Ad-hoc code signature gives the bundle a stable identity, which SMAppService
# (launch-at-login) and macOS Automation consent (TCC) rely on.
echo "[4/4] Ad-hoc signing..."
codesign --force --sign - "${APP}"

echo ""
echo "Built: ${DIR}/${APP}  (sdk ${RECORDED}, ${CHANNEL}${COMMIT:+ ${COMMIT}})"
echo ""
echo "Run it from here to try it:   open \"${DIR}/${APP}\""
echo "To install, use Homebrew (README -> Install with Homebrew). Do not move a local"
echo "build into /Applications: it would shadow the installed one under the same bundle ID."
