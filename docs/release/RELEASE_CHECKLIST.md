# Release Checklist

## Required (always)

- [ ] `xcodebuild build -scheme TokenMeter -project TokenMeter.xcodeproj`
- [ ] `xcodebuild test -scheme TokenMeter -project TokenMeter.xcodeproj -destination platform=macOS`

- [ ] Scripts self-check:

```bash
chmod +x scripts/hardening/idle_resources.sh
python3 scripts/hardening/secret_scan.py --self-check
python3 scripts/hardening/validate_runtime_tuning.py --self-check
./scripts/hardening/idle_resources.sh --self-check
```

- [ ] Capture idle resource report:

```bash
./scripts/hardening/idle_resources.sh --output dist/hardening/idle_resources.json
```

- [ ] Secret scan export outputs:

```bash
python3 scripts/hardening/secret_scan.py dist
```

## Optional (packaging)

- [ ] Release build (derived data pinned):

```bash
xcodebuild \
  -project TokenMeter.xcodeproj \
  -scheme TokenMeter \
  -configuration Release \
  -derivedDataPath build
```

- [ ] DMG package:

```bash
chmod +x scripts/packaging/dmg_packager.sh
./scripts/packaging/dmg_packager.sh "./build/Build/Products/Release/TokenMeter.app" "./dist" "$(git describe --tags --always 2>/dev/null || echo 0.0.0)"
```

- [ ] Metadata:

```bash
chmod +x scripts/packaging/update_metadata.sh
./scripts/packaging/update_metadata.sh --version "$(git describe --tags --always 2>/dev/null || echo 0.0.0)" --channel stable --output dist/metadata.json
```

## Notes

- Budget enforcement (`idle_resources.sh --enforce`) is intentionally opt-in to avoid cross-machine flakiness.
- If secret scan finds false positives in generated test artifacts, allowlist by `finding_id` only in `scripts/hardening/secret_scan_allowlist.json`.
