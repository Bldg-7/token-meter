#!/usr/bin/env bash
set -euo pipefail

OUTPUT="./dist/metadata.json"
VERSION=""
CHANNEL="stable"
VERSION_SET="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --version requires a value" >&2
        exit 1
      fi
      VERSION="$2"; VERSION_SET="1"; shift 2;;
    --channel)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --channel requires a value" >&2
        exit 1
      fi
      CHANNEL="$2"; shift 2;;
    --output)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: --output requires a value" >&2
        exit 1
      fi
      OUTPUT="$2"; shift 2;;
    --help|-h)
      echo "Usage: update_metadata.sh --version <version> --channel <stable|prerelease> --output <path>"; exit 0;;
    *)
      echo "Unknown option: $1" >&2; exit 1;;
  esac
done

if [[ "$VERSION_SET" != "1" || -z "${VERSION:-}" ]]; then
  echo "Error: --version is required" >&2; exit 1
fi

if [[ "$VERSION" =~ ^v[0-9] ]]; then
  VERSION="${VERSION#v}"
fi

case "$CHANNEL" in
  stable|prerelease) ;;
  *)
    echo "Error: --channel must be 'stable' or 'prerelease' (got '$CHANNEL')" >&2
    exit 1
    ;;
esac

mkdir -p "$(dirname "$OUTPUT")"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required to generate JSON metadata" >&2
  exit 1
fi

VERSION="$VERSION" CHANNEL="$CHANNEL" python3 - <<'PY' >"$OUTPUT"
import datetime
import json
import os

version = os.environ["VERSION"]
channel = os.environ["CHANNEL"]

built_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')

print(
    json.dumps(
        {
            "version": version,
            "channel": channel,
            "built_at": built_at,
        },
        indent=2,
        sort_keys=True,
    )
)
PY

echo "Metadata written to $OUTPUT"
