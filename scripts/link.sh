#!/usr/bin/env bash
#
# link.sh — wire TyKaozKit's C target (TyKaozHostC) to the XS headers it compiles
# against.
#
# TyKaozKit reuses XSBridgeKit's already-linked, ABI-patched XS tree (same
# mac_xs.h, same defines) rather than re-linking from $MODDABLE, so the two
# targets stay ABI-identical. SwiftPM forbids header search paths outside the
# package root, so we expose that tree through vendor/ symlinks (git-ignored).
# The XS .c under vendor/ are never compiled (vendor/ is not a SwiftPM target).
#
# Usage (from the package root):
#   scripts/link.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XSBRIDGE="$ROOT/../XSBridgeKit/Sources/XSBridge"
[ -d "$XSBRIDGE/xs/sources" ] || {
  echo "error: XSBridgeKit XS tree not found at $XSBRIDGE/xs — run XSBridgeKit's scripts/link-moddable.sh first" >&2
  exit 1
}

mkdir -p "$ROOT/vendor"
ln -sfn ../../XSBridgeKit/Sources/XSBridge/xs      "$ROOT/vendor/xs"
ln -sfn ../../XSBridgeKit/Sources/XSBridge/include "$ROOT/vendor/include"

echo "Done. Now: swift build"
