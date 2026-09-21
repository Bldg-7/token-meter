Release Runbook — TokenMeter DMG Packaging

Purpose
- Provides a concise, executable readiness checklist for a release build that outputs a DMG artifact and metadata.

Prerequisites
- macOS CI or macOS build env with Xcode and the repo checked out.
- Access to the DMG packaging scripts and workflows listed in this repository.
- Required secret: SPARKLE_PRIVATE_KEY (EdDSA private key used to sign the appcast; the workflow fails without it).
- Signing secrets (all three required to sign, otherwise the build is ad-hoc signed and Gatekeeper blocks first launch):
  MACOS_CERTIFICATE_P12_BASE64 (Developer ID Application certificate, base64 of the .p12),
  MACOS_CERTIFICATE_PASSWORD, MACOS_CODESIGN_IDENTITY (e.g. "Developer ID Application: Name (TEAMID)").
  Optional: MACOS_TEAM_ID.
- Notarization secrets (all three required; needs signing): NOTARY_API_KEY_ID, NOTARY_API_ISSUER_ID,
  NOTARY_API_KEY_P8_BASE64 (App Store Connect API key, base64 of the .p8).

Checklist (release-ready state)
- Build the Xcode Release target
  - Command: xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter -configuration Release -derivedDataPath build -quiet
- Build artifacts for packaging
  - Ensure APP_BUNDLE_PATH points to "./build/Build/Products/Release/TokenMeter.app"
- Package DMG
  - Version tag: derive from Git tag or pass via workflow_dispatch inputs
  - Command: ./scripts/packaging/dmg_packager.sh "<APP_BUNDLE_PATH>" "<OUTPUT_DIR>" "<VERSION_TAG>"
- Signing (when the signing secrets are set)
  - The certificate is imported into a temporary keychain and xcodebuild signs the app with
    ENABLE_HARDENED_RUNTIME=YES, so every nested item (widget, Sparkle) gets its own entitlements.
  - Both DMGs in dist/ (versioned and TokenMeter.dmg) are then signed:
    codesign --force --sign "<identity>" --timestamp "<DMG_PATH>"
- Notarization (when the notarization secrets are set)
  - The app is notarized and stapled before packaging, so the Sparkle ZIP carries a stapled bundle too:
    xcrun notarytool submit "<APP_ZIP>" --wait --key "<p8>" --key-id "<id>" --issuer "<issuer>"
    xcrun stapler staple "<APP_PATH>"
  - Each DMG is notarized and stapled the same way.
- Update metadata for channel
  - Command: ./scripts/packaging/update_metadata.sh --version "<VERSION>" --channel "<stable|prerelease>" --output dist/metadata.json
- Validation
  - Verify dist/metadata.json exists and contains version and channel
  - Ensure dist/*.dmg exists
- Publish
  - Upload dmg to release artifacts or artifact storage as configured
- Hardening checks (see docs/release/RELEASE_CHECKLIST.md for the required set)
  - Runtime tuning: python3 scripts/hardening/validate_runtime_tuning.py
  - Secret scan: python3 scripts/hardening/secret_scan.py --self-check && python3 scripts/hardening/secret_scan.py dist
  - Redaction: ./scripts/hardening/check_redaction.sh dist
  - Idle budget: ./scripts/hardening/idle_resources.sh --output dist/hardening/idle_resources.json

Rollback / Abort criteria
- If any step fails (build, packaging, signing, notarization, metadata update, or tests), abort release and revert artifacts.
- Do not publish any artifacts until all checks pass.
- Maintain an empty dist/ on abort to avoid accidental publishing.

Notes
- Signing/notarization secrets are named only; do not commit secrets to repo.
- This runbook keeps commands stable and executable for prerelease and stable channels.

End of runbook
