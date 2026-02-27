#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build Sparkle release artifacts from a built .app bundle.

Usage:
  sparkle_release_bundle.sh \
    --app <app_bundle_path> \
    --version <version> \
    --download-url-prefix <url_prefix> \
    [--output <output_dir>] \
    [--channel <stable|prerelease>] \
    [--derived-data-path <path>] \
    [--sparkle-private-key-env <env_name>]

Examples:
  sparkle_release_bundle.sh \
    --app "./build/Build/Products/Release/TokenMeter.app" \
    --version "1.2.3" \
    --download-url-prefix "https://github.com/org/repo/releases/download/v1.2.3"

Notes:
  - Creates:
      - <output>/TokenMeter-<version>.dmg
      - <output>/sparkle/TokenMeter-<version>.zip
      - <output>/sparkle/appcast.xml
      - <output>/appcast.xml (copy)
      - <output>/metadata.json
  - If --sparkle-private-key-env is provided, the env var must contain the
    Sparkle private EdDSA key and appcast generation will use it.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_BUNDLE_PATH=""
OUTPUT_DIR="./dist"
VERSION=""
CHANNEL="stable"
DOWNLOAD_URL_PREFIX=""
DERIVED_DATA_PATH="./build"
SPARKLE_PRIVATE_KEY_ENV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_BUNDLE_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --download-url-prefix)
      DOWNLOAD_URL_PREFIX="${2:-}"
      shift 2
      ;;
    --derived-data-path)
      DERIVED_DATA_PATH="${2:-}"
      shift 2
      ;;
    --sparkle-private-key-env)
      SPARKLE_PRIVATE_KEY_ENV="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$APP_BUNDLE_PATH" ]]; then
  echo "Error: --app is required" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "Error: --version is required" >&2
  exit 1
fi

if [[ -z "$DOWNLOAD_URL_PREFIX" ]]; then
  echo "Error: --download-url-prefix is required" >&2
  exit 1
fi

case "$CHANNEL" in
  stable|prerelease) ;;
  *)
    echo "Error: --channel must be 'stable' or 'prerelease' (got '$CHANNEL')" >&2
    exit 1
    ;;
esac

if [[ ! -d "$APP_BUNDLE_PATH" ]]; then
  echo "Error: App bundle '$APP_BUNDLE_PATH' not found" >&2
  exit 1
fi

if [[ "$APP_BUNDLE_PATH" != *.app ]]; then
  echo "Error: --app must point to a .app bundle (got '$APP_BUNDLE_PATH')" >&2
  exit 1
fi

VERSION_NORM="$VERSION"
if [[ "$VERSION_NORM" =~ ^v[0-9] ]]; then
  VERSION_NORM="${VERSION_NORM#v}"
fi

VERSION_SAFE="$(printf '%s' "$VERSION_NORM" | tr -c 'A-Za-z0-9._-' '_' )"
SPARKLE_DIR="$OUTPUT_DIR/sparkle"
ZIP_PATH="$SPARKLE_DIR/TokenMeter-${VERSION_SAFE}.zip"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$SPARKLE_DIR"

echo "[RELEASE] Creating DMG"
"$SCRIPT_DIR/dmg_packager.sh" "$APP_BUNDLE_PATH" "$OUTPUT_DIR" "$VERSION"

echo "[RELEASE] Creating Sparkle ZIP: $ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE_PATH" "$ZIP_PATH"

find_sparkle_tool() {
  local tool_name="$1"
  local candidate=""
  local candidates=(
    "$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool_name"
    "$DERIVED_DATA_PATH/SourcePackages/checkouts/Sparkle/bin/$tool_name"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  candidate="$(find "$DERIVED_DATA_PATH" -type f -path "*/SourcePackages/*/Sparkle/bin/$tool_name" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
    candidate="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -path "*/SourcePackages/*/Sparkle/bin/$tool_name" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  fi

  return 1
}

GENERATE_APPCAST_BIN="$(find_sparkle_tool "generate_appcast" || true)"
if [[ -z "$GENERATE_APPCAST_BIN" ]]; then
  echo "Error: Unable to locate Sparkle generate_appcast binary." >&2
  echo "Hint: run an Xcode build with -derivedDataPath '$DERIVED_DATA_PATH' first." >&2
  exit 1
fi

echo "[RELEASE] Using Sparkle tool: $GENERATE_APPCAST_BIN"

appcast_args=(
  "--download-url-prefix" "$DOWNLOAD_URL_PREFIX"
)

if [[ "$CHANNEL" == "prerelease" ]]; then
  appcast_args+=("--channel" "prerelease")
fi

if [[ -n "$SPARKLE_PRIVATE_KEY_ENV" ]]; then
  PRIVATE_KEY_VALUE="${!SPARKLE_PRIVATE_KEY_ENV:-}"
  if [[ -z "$PRIVATE_KEY_VALUE" ]]; then
    echo "Error: '$SPARKLE_PRIVATE_KEY_ENV' is empty or not set" >&2
    exit 1
  fi

  echo "[RELEASE] Generating appcast with provided private key env"
  printf '%s' "$PRIVATE_KEY_VALUE" | "$GENERATE_APPCAST_BIN" --ed-key-file - "${appcast_args[@]}" "$SPARKLE_DIR"
else
  echo "[RELEASE] Generating appcast using keychain key"
  "$GENERATE_APPCAST_BIN" "${appcast_args[@]}" "$SPARKLE_DIR"
fi

if [[ ! -f "$SPARKLE_DIR/appcast.xml" ]]; then
  echo "Error: appcast was not generated at '$SPARKLE_DIR/appcast.xml'" >&2
  exit 1
fi

cp "$SPARKLE_DIR/appcast.xml" "$OUTPUT_DIR/appcast.xml"
echo "[RELEASE] Copied appcast to $OUTPUT_DIR/appcast.xml"

"$SCRIPT_DIR/update_metadata.sh" --version "$VERSION" --channel "$CHANNEL" --output "$OUTPUT_DIR/metadata.json"

echo "[RELEASE] Artifacts ready:"
echo "  - $(ls -1 "$OUTPUT_DIR"/*.dmg | head -n 1)"
echo "  - $ZIP_PATH"
echo "  - $OUTPUT_DIR/appcast.xml"
echo "  - $OUTPUT_DIR/metadata.json"
