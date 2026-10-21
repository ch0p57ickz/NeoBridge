#!/usr/bin/env bash
#
# Build PenLab and assemble the bundle it needs.
#
# PenLab is the physical-A1 experiment tool for the two deletion commands the app
# refuses to frame (`0x25` and `0x27`). It lives in Tests/Hardware/PenLab and is
# not part of any app target, so no shipped binary can reach it.
#
# Usage:
#   Scripts/pen-lab-build.sh [--configuration release|debug]
#
# Environment:
#   SWIFT   Swift driver to use. Defaults to `swift` on PATH.
#
# The bundle is assembled here rather than by SwiftPM because CoreBluetooth reads
# its usage description from Info.plist, which a bare `swift run` executable does
# not have: without it a command-line tool is refused Bluetooth access.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_DIR="$ROOT/Tests/Hardware/PenLab"
BUILD_DIR="$LAB_DIR/.build"
BUNDLE="$BUILD_DIR/bundle/PenLab.app"
CONFIGURATION="release"
SWIFT="${SWIFT:-swift}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:?--configuration needs a value}"
      shift 2
      ;;
    --help|-h)
      sed -n '2,17p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf 'error: unknown argument %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
  printf 'error: --configuration must be release or debug\n' >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'error: PenLab drives CoreBluetooth and only builds on macOS.\n' >&2
  exit 1
fi

printf '== Build\n'
"$SWIFT" build --package-path "$LAB_DIR" --configuration "$CONFIGURATION"

PRODUCT="$BUILD_DIR/$CONFIGURATION/PenLab"
if [[ ! -x "$PRODUCT" ]]; then
  printf 'error: %s is missing; the lab build did not produce an executable.\n' "$PRODUCT" >&2
  exit 1
fi

printf '\n== Bundle\n'
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$PRODUCT" "$BUNDLE/Contents/MacOS/PenLab"

cat >"$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>PenLab</string>
	<key>CFBundleIdentifier</key>
	<string>com.sushidev.neobridge.penlab</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>PenLab</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>PenLab sends deletion experiments to a Neo Smartpen A1 over Bluetooth.</string>
</dict>
</plist>
PLIST

plutil -lint "$BUNDLE/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$BUNDLE"
fi

printf '\nBuilt %s\n' "$BUNDLE"
printf 'Run it from inside the bundle:\n'
printf '  %s/Contents/MacOS/PenLab --help\n' "$BUNDLE"
