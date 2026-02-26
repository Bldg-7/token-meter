# Release Runbook (macOS)

This repo ships a macOS app plus optional DMG packaging artifacts.

The goal of this runbook is to make releases repeatable and to enforce privacy/performance checks via executable scripts.

## 0) Preconditions

- macOS with Xcode installed (or Xcode Command Line Tools)
- `python3` available

Quick sanity:

```bash
xcodebuild -version
sw_vers
python3 --version
```

## 1) Build + Tests (required)

Run these exact commands (source of truth):

```bash
xcodebuild build -scheme TokenMeter -project TokenMeter.xcodeproj
xcodebuild test -scheme TokenMeter -project TokenMeter.xcodeproj -destination platform=macOS
```

## 2) Hardening Checks (required)

Self-check scripts (fast):

```bash
chmod +x scripts/hardening/idle_resources.sh
python3 scripts/hardening/secret_scan.py --self-check
python3 scripts/hardening/validate_runtime_tuning.py --self-check
./scripts/hardening/idle_resources.sh --self-check
```

### 2.1 Idle Resource Budget (capture)

Capture an idle report (informational by default):

```bash
./scripts/hardening/idle_resources.sh --output dist/hardening/idle_resources.json
```

Optional enforcement mode (recommended only on known/stable machine classes):

```bash
./scripts/hardening/idle_resources.sh \
  --enforce \
  --max-cpu-core 0.02 \
  --max-rss-mb 150 \
  --max-footprint-mb 250
```

### 2.2 Secret Scan (diagnostics/export outputs)

Scan exported artifacts for plaintext secrets. Typical targets:

```bash
python3 scripts/hardening/secret_scan.py dist
```

If you export diagnostics into a bundle directory or file, scan that output as well:

```bash
python3 scripts/hardening/secret_scan.py /path/to/diagnostics-bundle
```

If a finding is confirmed fake test data, add its `finding_id` to `scripts/hardening/secret_scan_allowlist.json`.

## 3) Packaging (optional)

### 3.1 Build Release configuration (recommended for DMG)

```bash
xcodebuild \
  -project TokenMeter.xcodeproj \
  -scheme TokenMeter \
  -configuration Release \
  -derivedDataPath build
```

### 3.2 Create DMG

```bash
chmod +x scripts/packaging/dmg_packager.sh
./scripts/packaging/dmg_packager.sh "./build/Build/Products/Release/TokenMeter.app" "./dist" "$(git describe --tags --always 2>/dev/null || echo 0.0.0)"
```

### 3.3 Write metadata

```bash
chmod +x scripts/packaging/update_metadata.sh
./scripts/packaging/update_metadata.sh --version "$(git describe --tags --always 2>/dev/null || echo 0.0.0)" --channel stable --output dist/metadata.json
```

## 4) Release Outputs

- `dist/*.dmg` (if packaging ran)
- `dist/metadata.json` (if metadata ran)
- `dist/hardening/idle_resources.json` (if idle capture ran)
