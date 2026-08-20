#!/bin/bash
# Verifies the guarantee this app exists to keep: adding our status item must never
# make macOS hide somebody else's.
#
# The test is the in-region status-window count. Our item is exactly one window, so
# with the app running the count must be exactly one MORE than without it. If it is
# equal, we gained a window and something else lost one -- an eviction.
#
# That invariant is self-calibrating: no hardcoded counts, so it holds on any bar,
# any icon set, and any display. See AGENTS.md decision #20.
#
# Plain ASCII on purpose, same as build-app.sh.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${DIR}"

APP="/Applications/SpotifyMenuBar.app"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A pinned rung deliberately bypasses the measured ceiling, so it would invalidate
# the whole test rather than fail it honestly.
PIN="$(defaults read com.local.SpotifyMenuBar displayMode 2>/dev/null || echo auto)"
if [ "${PIN}" != "auto" ]; then
  echo "ABORT: displayMode is pinned to '${PIN}'. A pin bypasses the ceiling by design."
  echo "       Run: defaults delete com.local.SpotifyMenuBar displayMode"
  exit 2
fi

echo "[1/5] Unit checks..."
swift build > /dev/null
swift run SpotifyMenuBarCoreTests | tail -1

echo "[2/5] Building the bundle..."
./build-app.sh > /dev/null
rm -rf "${APP}"
mv "${DIR}/SpotifyMenuBar.app" /Applications/

cat > "${WORK}/probe.swift" <<'SWIFT'
import AppKit
// Counts status-level windows inside the same region BarLayout.region computes, using
// the same notch-or-half-screen rule, so the probe and the app agree on the boundary.
let level = Int(CGWindowLevelForKey(.statusWindow))
guard let screen = NSScreen.main else { print("0,0,0,0"); exit(1) }
let menuBarHeight: CGFloat = 24
var region: CGRect
if let aux = screen.auxiliaryTopRightArea, aux.width > 0 {
    region = aux
} else {
    region = CGRect(x: screen.frame.midX, y: screen.frame.maxY - menuBarHeight,
                    width: screen.frame.width / 2, height: menuBarHeight)
}
let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? region.maxY
guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] else { print("0,0,0,0"); exit(1) }
var rects: [CGRect] = []
for e in raw {
    guard (e[kCGWindowLayer as String] as? Int) == level,
          let b = e[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let w = b["Width"], let y = b["Y"], let h = b["Height"] else { continue }
    let r = CGRect(x: x, y: primaryMaxY - (y + h), width: w, height: h)
    guard r.maxX > region.minX, r.minX < region.maxX,
          r.maxY > region.minY, r.minY < region.maxY else { continue }
    rects.append(r)
}
let leftEdge = rects.map(\.minX).min() ?? 0
let widest = rects.map(\.width).max() ?? 0
// count, leftEdge, gap to the region's left edge, widest item
print(String(format: "%d,%.0f,%.0f,%.0f", rects.count, leftEdge, leftEdge - region.minX, widest))
SWIFT
xcrun swiftc -O "${WORK}/probe.swift" -o "${WORK}/probe" 2>/dev/null

echo "[3/5] Sampling the bar WITHOUT our item..."
osascript -e 'quit app "SpotifyMenuBar"' 2>/dev/null || true
sleep 3
BEFORE="$(${WORK}/probe)"
N0="$(echo "${BEFORE}" | cut -d, -f1)"
echo "      count=${N0}  leftEdge=$(echo "${BEFORE}" | cut -d, -f2)  gap=$(echo "${BEFORE}" | cut -d, -f3)"

echo "[4/5] Launching and letting the ceiling settle..."
open -a "${APP}"
sleep 6
AFTER="$(${WORK}/probe)"
N1="$(echo "${AFTER}" | cut -d, -f1)"
echo "      count=${N1}  leftEdge=$(echo "${AFTER}" | cut -d, -f2)  gap=$(echo "${AFTER}" | cut -d, -f3)  ourWindow=$(echo "${AFTER}" | cut -d, -f4)"

echo "[5/5] Verdict"
EXPECTED=$((N0 + 1))
if [ "${N1}" -eq "${EXPECTED}" ]; then
  echo ""
  echo "PASS: count went ${N0} -> ${N1}. Our item was added and nobody was hidden."
  exit 0
fi
echo ""
echo "FAIL: expected ${EXPECTED} (${N0} + our one item), got ${N1}."
if [ "${N1}" -le "${N0}" ]; then
  echo "      We gained a window and the total did not rise: an icon was evicted."
  echo "      Try a larger reserve, which is the dial for exactly this:"
  echo "        defaults write com.local.SpotifyMenuBar barReserve -float 56"
  echo "      Then re-run. See AGENTS.md decision #20."
else
  echo "      Count rose by more than one -- another app added an item mid-test."
  echo "      Re-run with a quiet bar."
fi
exit 1
