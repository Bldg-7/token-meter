Release Runbook — TokenMeter DMG Packaging

Purpose
- Provides a concise, executable readiness checklist for a release build that outputs a DMG artifact and metadata.

Prerequisites
- macOS CI or macOS build env with Xcode and the repo checked out.
- Access to the DMG packaging scripts and workflows listed in this repository.
- Secrets as named in CI (optional): MACOS_CODESIGN_IDENTITY, NOTARYTOOL_KEYCHAIN_PROFILE.

Checklist (release-ready state)
- Build the Xcode Release target
  - Command: xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -configuration Release -derivedDataPath build -quiet
- Build artifacts for packaging
  - Ensure APP_BUNDLE_PATH points to "./build/Build/Products/Release/TokenMeter.app"
- Package DMG
  - Version tag: derive from Git tag or pass via workflow_dispatch inputs
  - Command: ./scripts/packaging/dmg_packager.sh "<APP_BUNDLE_PATH>" "<OUTPUT_DIR>" "<VERSION_TAG>"
- Optional signing
  - If MACOS_CODESIGN_IDENTITY is set, sign the DMG:
    codesign --force --sign "<identity>" --timestamp "<DMG_PATH>"
- Optional notarization
  - If NOTARYTOOL_KEYCHAIN_PROFILE is set, notarize and staple:
    xcrun notarytool submit "<DMG_PATH>" --wait --keychain-profile "<PROFILE>"
    xcrun stapler staple "<DMG_PATH>"
- Update metadata for channel
  - Command: ./scripts/packaging/update_metadata.sh --version "<VERSION>" --channel "<stable|prerelease>" --output dist/metadata.json
- Validation
  - Verify dist/metadata.json exists and contains version and channel
  - Ensure dist/*.dmg exists
- Publish
  - Upload dmg to release artifacts or artifact storage as configured
- Optional redaction & idle budget checks
  - Redaction: ./scripts/hardening/check_redaction.sh
  - Idle budget: ./scripts/hardening/check_idle_budget.sh TokenMeter 60 1 50 500

Rollback / Abort criteria
- If any step fails (build, packaging, signing, notarization, metadata update, or tests), abort release and revert artifacts.
- Do not publish any artifacts until all checks pass.
- Maintain an empty dist/ on abort to avoid accidental publishing.

Notes
- Signing/notarization secrets are named only; do not commit secrets to repo.
- This runbook keeps commands stable and executable for prerelease and stable channels.

End of runbook
