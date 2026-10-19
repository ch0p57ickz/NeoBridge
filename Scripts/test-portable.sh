#!/usr/bin/env bash
#
# Portable verification for the portable packages and the integration scenarios.
#
# Runs every portable package's test suite, the integrated fake-transport
# scenarios, and checks that no portable source imports an Apple-only framework.
# The script needs only a Swift toolchain: no Xcode, no macOS frameworks, no
# Bluetooth hardware, and no network access at test time. The first build on a
# cold cache does fetch the pinned dependencies once.
#
# Usage:
#   Scripts/test-portable.sh
#
# Environment:
#   SWIFT   Swift driver to use. Defaults to `swift` on PATH.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT="${SWIFT:-swift}"

# Every package that must build and test on Linux. Sources live under a
# `Sources` directory in each entry.
PACKAGE_DIRS=(
  "Packages/NeoCore"
  "Packages/NeoProtocol"
  "Packages/NeoStorage"
  "Packages/NeoExport"
  "Tests/Integration"
)

# Frameworks that would break the Linux build or hide platform coupling.
FORBIDDEN_IMPORTS=(
  "SwiftUI"
  "AppKit"
  "UIKit"
  "WatchKit"
  "TVUIKit"
  "CoreBluetooth"
  "CoreGraphics"
  "CoreData"
  "CoreImage"
  "CryptoKit"
  "Combine"
  "Metal"
  "MapKit"
  "XCTest"
)

failures=0

section() {
  printf '\n== %s\n' "$1"
}

if ! command -v "$SWIFT" >/dev/null 2>&1; then
  cat >&2 <<'MESSAGE'
error: no Swift driver found on PATH.

Install a Swift toolchain, or point the script at one explicitly, for example:

  SWIFT="$HOME/.local/share/swiftly/bin/swift" Scripts/test-portable.sh
MESSAGE
  exit 1
fi

section "Toolchain"
"$SWIFT" --version

section "SQLite header check"
# NeoStorage reaches SQLite through a system module, so a Linux host needs the
# development header. macOS ships it in the SDK.
sqlite_header_found=0
if [[ "$(uname -s)" == "Darwin" ]]; then
  sqlite_header_found=1
elif command -v pkg-config >/dev/null 2>&1 && pkg-config --exists sqlite3 2>/dev/null; then
  sqlite_header_found=1
elif [[ -f /usr/include/sqlite3.h || -f /usr/local/include/sqlite3.h ]]; then
  sqlite_header_found=1
fi

if [[ "$sqlite_header_found" -eq 1 ]]; then
  printf 'ok: the SQLite development header is available\n'
else
  cat >&2 <<'MESSAGE'
error: the SQLite development header (sqlite3.h) was not found.

Install it before running the portable suite, for example:

  sudo apt-get install libsqlite3-dev   # Debian/Ubuntu
  sudo dnf install sqlite-devel         # Fedora
MESSAGE
  failures=1
fi

section "Forbidden import check"
for package in "${PACKAGE_DIRS[@]}"; do
  sources="$ROOT/$package/Sources"
  if [[ ! -d "$sources" ]]; then
    printf 'error: %s is missing\n' "$sources" >&2
    failures=1
    continue
  fi

  for module in "${FORBIDDEN_IMPORTS[@]}"; do
    matches="$(grep -REn "^[[:space:]]*import[[:space:]]+${module}([[:space:]]|$)" "$sources" || true)"
    if [[ -n "$matches" ]]; then
      printf 'forbidden import %s in %s:\n%s\n' "$module" "$package" "$matches" >&2
      failures=1
    fi
  done
  printf 'ok: %s imports no Apple-only framework\n' "$package"
done

section "Pinned dependency resolution"
# The test suites must run without network services. Resolution is pinned by the
# committed Package.resolved, so the build must succeed without re-resolving.
for package in "${PACKAGE_DIRS[@]}"; do
  printf '\n-- swift build --disable-automatic-resolution (%s)\n' "$package"
  if ! (cd "$ROOT/$package" && "$SWIFT" build --disable-automatic-resolution); then
    printf 'error: %s needs dependency re-resolution; update Package.resolved\n' "$package" >&2
    failures=1
  fi
done

section "Package tests"
for package in "${PACKAGE_DIRS[@]}"; do
  printf '\n-- swift test (%s)\n' "$package"
  if ! (cd "$ROOT/$package" && "$SWIFT" test); then
    failures=1
  fi
done

section "Result"
if [[ "$failures" -ne 0 ]]; then
  printf 'FAILED: portable verification found problems.\n' >&2
  exit 1
fi

printf 'PASSED: portable packages build with pinned dependencies, import no Apple-only framework, and pass their tests, and the integration scenarios pass.\n'
