#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Package a macOS .app into a DMG using hdiutil.

Usage:
  dmg_packager.sh <app_bundle_path> <output_dir> [version]

Notes:
  - Fails if the .app bundle does not exist.
  - Creates a staging folder containing the app and an Applications symlink.
  - Version is used only for naming; it may be derived from git if omitted.
USAGE
}

APP_BUNDLE_PATH="${1:-./build/Release/TokenMeter.app}"
OUTPUT_DIR="${2:-./dist}"
VERSION_INPUT="${3:-${VERSION:-}}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

echo "[DMG] Packaging '$APP_BUNDLE_PATH' into '$OUTPUT_DIR'"

if [[ -z "$APP_BUNDLE_PATH" ]]; then
  echo "Error: APP_BUNDLE_PATH is empty" >&2
  exit 1
fi

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "Error: App bundle '$APP_BUNDLE_PATH' not found" >&2
  exit 1
fi

if [[ "$APP_BUNDLE_PATH" != *.app ]]; then
  echo "Error: Expected a .app bundle path, got '$APP_BUNDLE_PATH'" >&2
  exit 1
fi

VERSION_TAG="$VERSION_INPUT"
if [[ -z "$VERSION_TAG" ]]; then
  set +e
  VERSION_TAG="$(git describe --tags --always 2>/dev/null)"
  GIT_DESCRIBE_RC="$?"
  set -e
  if [[ "$GIT_DESCRIBE_RC" != "0" ]]; then
    VERSION_TAG=""
  fi
fi
if [[ -z "$VERSION_TAG" ]]; then
  VERSION_TAG="0.0.0"
fi

VERSION_NORM="$VERSION_TAG"
if [[ "$VERSION_NORM" =~ ^v[0-9] ]]; then
  VERSION_NORM="${VERSION_NORM#v}"
fi

DMG_VERSION_SAFE="$(printf '%s' "$VERSION_NORM" | tr -c 'A-Za-z0-9._-' '_' )"

mkdir -p "$OUTPUT_DIR"
DMG_NAME="TokenMeter-${DMG_VERSION_SAFE}.dmg"
OUTPUT_PATH="$OUTPUT_DIR/$DMG_NAME"

STAGING_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

APP_BASENAME="$(basename "$APP_BUNDLE_PATH")"
echo "[DMG] Staging '$APP_BASENAME'"

ditto "$APP_BUNDLE_PATH" "$STAGING_DIR/$APP_BASENAME"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
  -volname "TokenMeter" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  -ov \
  "$OUTPUT_PATH"

echo "[DMG] Created $OUTPUT_PATH"
