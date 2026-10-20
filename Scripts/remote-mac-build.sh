#!/usr/bin/env bash
#
# Mac build and packaging for the NeoBridge menu-bar app.
#
# The script is the single entry point for the macOS side of the change. It
# builds the portable packages, verifies them with Scripts/test-portable.sh,
# builds the app under both SwiftPM and Xcode, and assembles a launchable
# NeoBridgeMac.app bundle.
#
# Usage:
#   Scripts/remote-mac-build.sh [--configuration release|debug]
#
# Environment:
#   SWIFT             Swift driver to use. Defaults to `swift` on PATH.
#   SKIP_XCODE_GATE   Set to 1 to skip the Xcode build. The Xcode build is part
#                     of this change's verification, so a skip is reported as
#                     such and must not be recorded as a full verification.
#
# The bundle is assembled here rather than by SwiftPM because CoreBluetooth
# reads its usage description from Info.plist, which a bare `swift run`
# executable does not have.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/Apps/NeoBridgeMac"
BUILD_DIR="$APP_DIR/.build"
BUNDLE_DIR="$BUILD_DIR/bundle"
BUNDLE="$BUNDLE_DIR/NeoBridgeMac.app"
CONFIGURATION="release"
SWIFT="${SWIFT:-swift}"
SKIP_XCODE_GATE="${SKIP_XCODE_GATE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:?--configuration needs a value}"
      shift 2
      ;;
    --help|-h)
      sed -n '2,21p' "${BASH_SOURCE[0]}"
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

section() {
  printf '\n== %s\n' "$1"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'error: this script assembles a macOS app bundle and only runs on macOS.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
section "Host"
sw_vers
"$SWIFT" --version
if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -version
else
  printf 'xcodebuild: not installed\n'
fi

# ---------------------------------------------------------------------------
section "Portable packages"
# This builds both packages with pinned dependencies, checks the portability
# boundary, and runs both suites. It is the Linux-facing gate as well.
SWIFT="$SWIFT" "$ROOT/Scripts/test-portable.sh"

# ---------------------------------------------------------------------------
section "App build (SwiftPM)"
"$SWIFT" build --package-path "$APP_DIR" -c "$CONFIGURATION" --disable-automatic-resolution

# ---------------------------------------------------------------------------
section "App build (Xcode)"
# The verdict below keys on whether the gate actually ran, not on the skip
# variable alone: a host without xcodebuild skips the gate without anyone
# setting that variable, and a skipped gate is never full verification.
XCODE_GATE_RAN=0
XCODE_LOG="$BUILD_DIR/xcodebuild.log"
if [[ "$SKIP_XCODE_GATE" == "1" ]]; then
  printf 'SKIPPED: SKIP_XCODE_GATE=1.\n'
  printf 'The Xcode build is required by this change and is NOT verified by this run.\n'
elif ! command -v xcodebuild >/dev/null 2>&1; then
  printf 'SKIPPED: xcodebuild is not installed.\n'
  printf 'The Xcode build is required by this change and is NOT verified by this run.\n'
else
  mkdir -p "$BUILD_DIR"
  printf 'Invocation: xcodebuild -scheme NeoBridgeMac -destination platform=macOS'
  printf ' -configuration %s -derivedDataPath %s build\n' "$CONFIGURATION" "$BUILD_DIR/xcode"
  printf 'Log: %s\n' "$XCODE_LOG"
  if ! (
    cd "$APP_DIR"
    xcodebuild \
      -scheme NeoBridgeMac \
      -destination 'platform=macOS' \
      -configuration "$CONFIGURATION" \
      -derivedDataPath "$BUILD_DIR/xcode" \
      build
  ) >"$XCODE_LOG" 2>&1; then
    printf '\n-- last 40 lines of the Xcode log\n' >&2
    tail -40 "$XCODE_LOG" >&2
    printf '\nerror: the Xcode build failed. The gate is not satisfied.\n' >&2
    exit 1
  fi
  printf 'ok: the Xcode build succeeded.\n'
  XCODE_GATE_RAN=1
fi

# ---------------------------------------------------------------------------
section "Bundle"
PRODUCT="$BUILD_DIR/$CONFIGURATION/NeoBridgeMac"
if [[ ! -x "$PRODUCT" ]]; then
  printf 'error: %s is missing; the app build did not produce an executable.\n' "$PRODUCT" >&2
  exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$PRODUCT" "$BUNDLE/Contents/MacOS/NeoBridgeMac"

cat >"$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>NeoBridgeMac</string>
	<key>CFBundleIdentifier</key>
	<string>com.sushidev.neobridge.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>NeoBridge</string>
	<key>CFBundleDisplayName</key>
	<string>NeoBridge</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSBluetoothAlwaysUsageDescription</key>
	<string>NeoBridge reads offline strokes from a Neo Smartpen A1 over Bluetooth.</string>
</dict>
</plist>
PLIST

printf 'assembled %s\n' "$BUNDLE"

# ---------------------------------------------------------------------------
section "Bundle verification"
plutil -lint "$BUNDLE/Contents/Info.plist"

require_plist_value() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    printf 'error: Info.plist has no %s\n' "$key" >&2
    return 1
  fi
  printf 'ok: %s = %s\n' "$key" "$value"
}

require_plist_value CFBundleIdentifier
require_plist_value CFBundleExecutable
require_plist_value LSMinimumSystemVersion
require_plist_value NSBluetoothAlwaysUsageDescription
require_plist_value LSUIElement

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$BUNDLE/Contents/Info.plist")" != "true" ]]; then
  printf 'error: LSUIElement must be true so the app runs as a menu-bar accessory.\n' >&2
  exit 1
fi

file "$BUNDLE/Contents/MacOS/NeoBridgeMac"

if command -v codesign >/dev/null 2>&1; then
  # Ad hoc signing only: signing and notarization for distribution are out of
  # scope for this change.
  codesign --force --sign - "$BUNDLE"
  codesign --verify --verbose "$BUNDLE"
fi

# ---------------------------------------------------------------------------
section "Result"
printf 'Built %s\n' "$BUNDLE"
if [[ "$XCODE_GATE_RAN" != "1" ]]; then
  printf 'INCOMPLETE: the Xcode build gate was skipped, so this run is not full verification.\n'
else
  printf 'PASSED: portable packages verified, app built under SwiftPM and Xcode, bundle assembled.\n'
fi
