#!/usr/bin/env bash
#
# Packaging for the NeoBridge menu-bar app.
#
# The script builds the app (unless asked to reuse the last build), zips the
# assembled bundle so it can travel to another Mac, and — when a Developer ID
# identity is configured — signs and notarizes it. With no identity it packages
# the ad-hoc-signed bundle that Scripts/remote-mac-build.sh produces, which is
# what a side-load onto your own machines needs.
#
# Usage:
#   Scripts/package-app.sh [--configuration release|debug] [--output DIR]
#                          [--skip-build]
#
# Options:
#   --configuration   Build configuration to package. Defaults to release.
#   --output          Directory the archive is written to. Defaults to
#                     Apps/NeoBridgeMac/.build/packages.
#   --skip-build      Package the bundle already in
#                     Apps/NeoBridgeMac/.build/bundle instead of building and
#                     verifying it again. The bundle is packaged as built, still
#                     re-signed when an identity is configured, and --configuration
#                     is ignored. This run is not a verification of the sources.
#
# Environment:
#   SWIFT                       Swift driver to use. Defaults to `swift` on PATH.
#   SKIP_XCODE_GATE             Passed through to Scripts/remote-mac-build.sh.
#   DEVELOPER_ID_APPLICATION    The Developer ID Application identity to sign
#                               with, for example
#                               "Developer ID Application: Name (TEAMID)".
#                               Unset keeps the ad-hoc signature.
#   NOTARY_PROFILE              A `notarytool` keychain profile name. It needs
#                               DEVELOPER_ID_APPLICATION too, so setting it
#                               alone is an error rather than an unnotarized
#                               archive. Unset skips notarization.
#
# The archive is a zip of the whole bundle, written with `ditto` so the bundle
# structure and permissions survive: unpack it on the target with
# `ditto -x -k <archive> /Applications`.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/Apps/NeoBridgeMac"
BUILD_DIR="$APP_DIR/.build"
BUNDLE_DIR="$BUILD_DIR/bundle"
BUNDLE="$BUNDLE_DIR/NeoBridgeMac.app"
CONFIGURATION="release"
OUTPUT_DIR="$BUILD_DIR/packages"
SKIP_BUILD=0
SWIFT="${SWIFT:-swift}"
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:?--configuration needs a value}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:?--output needs a value}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --help|-h)
      sed -n '2,39p' "${BASH_SOURCE[0]}"
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

# Notarization without a Developer ID signature cannot succeed, so a profile with
# no identity is a mistake in the invocation rather than a reason to quietly ship
# an unnotarized archive.
if [[ -n "$NOTARY_PROFILE" && -z "$IDENTITY" ]]; then
  printf 'error: NOTARY_PROFILE needs DEVELOPER_ID_APPLICATION; notarization requires a' >&2
  printf ' Developer ID signature.\n' >&2
  exit 2
fi

section() {
  printf '\n== %s\n' "$1"
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'error: this script packages a macOS app bundle and only runs on macOS.\n' >&2
  exit 1
fi

# The archive is written here, so a missing or unwritable output directory is
# caught before the build rather than after it.
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

# ---------------------------------------------------------------------------
section "Host"
sw_vers
if [[ -n "$IDENTITY" ]]; then
  printf 'Signing identity: %s\n' "$IDENTITY"
else
  printf 'Signing identity: none (DEVELOPER_ID_APPLICATION is not set)\n'
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
  printf 'Notarization profile: %s\n' "$NOTARY_PROFILE"
else
  printf 'Notarization profile: none (NOTARY_PROFILE is not set)\n'
fi

# ---------------------------------------------------------------------------
section "App bundle"
# The build's own verdict is echoed at the end instead of being recomputed here,
# so this script never claims more than the build it ran.
BUILD_VERDICT=""
BUILD_LOG="$BUILD_DIR/package-build.log"
if [[ "$SKIP_BUILD" == "1" ]]; then
  printf 'SKIPPED: --skip-build, so the bundle is packaged as built, and --configuration is ignored.\n'
  printf 'It is still re-signed below when an identity is configured.\n'
  printf 'This run does not build, test, or verify the current sources.\n'
  if [[ ! -d "$BUNDLE" ]]; then
    printf 'error: %s is missing; build it with Scripts/remote-mac-build.sh first.\n' "$BUNDLE" >&2
    exit 1
  fi
else
  # The log lives in the build directory, which --output may point away from, so
  # it is created here rather than assumed.
  mkdir -p "$BUILD_DIR"
  if ! SWIFT="$SWIFT" "$ROOT/Scripts/remote-mac-build.sh" --configuration "$CONFIGURATION" \
    2>&1 | tee "$BUILD_LOG"; then
    printf '\nerror: the build or its verification failed; the full output is in %s\n' "$BUILD_LOG" >&2
    exit 1
  fi
  # The portable suite prints a verdict of its own, so the last one in the log is
  # the build's, which is the one this script repeats.
  BUILD_VERDICT="$(grep -E '^(PASSED|INCOMPLETE)' "$BUILD_LOG" | tail -1 || true)"
fi

PLIST="$BUNDLE/Contents/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  printf 'error: %s has no Contents/Info.plist, so it is not a complete bundle.\n' "$BUNDLE" >&2
  printf 'Build it with Scripts/remote-mac-build.sh and try again.\n' >&2
  exit 1
fi
if [[ ! -x "$BUNDLE/Contents/MacOS/NeoBridgeMac" ]]; then
  printf 'error: %s has no runnable Contents/MacOS/NeoBridgeMac.\n' "$BUNDLE" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  printf 'error: %s has no CFBundleShortVersionString, so the archive cannot be named.\n' "$PLIST" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
section "Signature"
if [[ -z "$IDENTITY" ]]; then
  # Ad hoc signing only. It is enough for this Mac and for a side-load that
  # clears the quarantine attribute, and it is not enough for another person's
  # Mac, which refuses an unnotarized build.
  printf 'Keeping the ad-hoc signature.\n'
  printf 'Gatekeeper refuses an ad-hoc build on another Mac unless that machine clears the\n'
  printf 'quarantine attribute or opens it with a right click. Set DEVELOPER_ID_APPLICATION and\n'
  printf 'NOTARY_PROFILE to package a distributable build.\n'
else
  printf 'Signing with the hardened runtime.\n'
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE"
fi
codesign --verify --verbose "$BUNDLE"

# Assessed here for the signature, and again after stapling in the notarized
# path: an ad-hoc bundle is expected to be refused, and a notarized one is not.
# The verdict also decides whether the printed target steps have to clear the
# quarantine attribute, so what the shipped archive needs is measured, not guessed.
GATEKEEPER_ACCEPTS=0
if spctl --assess --type execute --verbose=2 "$BUNDLE"; then
  printf 'ok: Gatekeeper accepts this bundle.\n'
  GATEKEEPER_ACCEPTS=1
elif [[ -z "$IDENTITY" ]]; then
  printf 'note: Gatekeeper refuses this bundle, which is expected for an ad-hoc build.\n'
else
  printf 'note: Gatekeeper refuses this bundle: notarization is what changes that, and the\n'
  printf 'target machines have to clear the quarantine attribute until then.\n'
fi

# ---------------------------------------------------------------------------
section "Archive"
ARCHIVE="$OUTPUT_DIR/NeoBridgeMac-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$BUNDLE" "$ARCHIVE"
printf 'wrote %s\n' "$ARCHIVE"
printf 'unpacked size: %s\n' "$(du -sh "$BUNDLE" | cut -f1)"

# ---------------------------------------------------------------------------
section "Notarization"
if [[ -z "$NOTARY_PROFILE" ]]; then
  printf 'SKIPPED: NOTARY_PROFILE is not set, so the archive is not notarized.\n'
else
  printf 'Submitting %s with profile %s. This waits for the result.\n' "$ARCHIVE" "$NOTARY_PROFILE"
  # An archive that is not notarized is not shippable, so it is never left under
  # the name a person or a CI job would pick up. The submission archive is
  # removed as soon as it has served its purpose: from here the only archive
  # that may exist is the notarized one written at the end, so a failure while
  # stapling cannot leave a shippable-looking file behind.
  if ! xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait; then
    rm -f "$ARCHIVE"
    printf 'error: notarization failed, so the archive was removed and is not shippable.\n' >&2
    exit 1
  fi
  rm -f "$ARCHIVE"
  # The ticket belongs in the bundle, so the bundle is stapled and the archive is
  # built again from it.
  xcrun stapler staple "$BUNDLE"
  xcrun stapler validate "$BUNDLE"
  if ! spctl --assess --type execute --verbose=2 "$BUNDLE"; then
    printf 'error: Gatekeeper still refuses the stapled bundle, so no archive was written.\n' >&2
    exit 1
  fi
  GATEKEEPER_ACCEPTS=1
  ditto -c -k --keepParent "$BUNDLE" "$ARCHIVE"
  printf 'wrote %s (notarized and stapled)\n' "$ARCHIVE"
fi

# ---------------------------------------------------------------------------
section "Result"
ARCHIVE_NAME="$(basename "$ARCHIVE")"
printf 'Packaged %s\n' "$ARCHIVE"
printf 'On the target Mac:\n'
printf '  ditto -x -k %q /Applications\n' "$ARCHIVE_NAME"
if [[ "$GATEKEEPER_ACCEPTS" != "1" ]]; then
  printf '  xattr -dr com.apple.quarantine /Applications/NeoBridgeMac.app   # required: Gatekeeper refuses this build\n'
fi
printf '  open /Applications/NeoBridgeMac.app\n'
if [[ "$SKIP_BUILD" == "1" ]]; then
  printf 'INCOMPLETE: --skip-build reused an existing bundle, so the sources were not verified.\n'
elif [[ -n "$BUILD_VERDICT" ]]; then
  # The build's own verdict, so a skipped gate is never reported as a pass here.
  printf '%s\n' "$BUILD_VERDICT"
else
  printf 'INCOMPLETE: the build reported no verdict; see %s\n' "$BUILD_LOG"
fi
