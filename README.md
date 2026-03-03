# TokenMeter

macOS status bar app that monitors token usage for AI coding assistants.

Keep your **Codex** and **Claude Code** quota visible on your desktop with native macOS widgets.

## Features

- **Rate limit & quota widgets** — see remaining usage at a glance from your desktop
- **Local token tracking** — tracks token consumption over time with 24h/12h/6h/3h/1h graphs
- **Multi-provider** — monitors Codex and Claude Code side by side
- **Plan & reset timing** — shows your current plan and when quota resets
- **Dual-track architecture** — authoritative provider snapshots (Track 1) and local telemetry (Track 2), kept strictly independent
- **Auto-updates** — built-in Sparkle updates from GitHub Releases
- **Multilingual** — English, Korean, Japanese, Chinese (Simplified/Traditional), Spanish

All usage data stays local. No external telemetry.

## Install

Download the latest DMG from [Releases](https://github.com/Bldg-7/token-meter/releases/latest/download/TokenMeter.dmg), open it, and drag TokenMeter to Applications.

### Requirements

- macOS 13.0+
- Apple Silicon or Intel

## Build from Source

### Prerequisites

- Xcode 15.3+
- Ruby 2.7+ with Bundler

### Steps

```bash
# Install Ruby dependencies
bundle install

# Generate Xcode project
ruby scripts/generate_xcodeproj.rb

# Build
xcodebuild \
  -project TokenMeter.xcodeproj \
  -scheme TokenMeter \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO

# Run
open build/Build/Products/Release/TokenMeter.app
```

### Package DMG

```bash
./scripts/packaging/dmg_packager.sh \
  ./build/Build/Products/Release/TokenMeter.app \
  ./dist \
  0.1.0
```

## Architecture

```
TokenMeter/
├── Domain/          # Track1/Track2 data models
├── Providers/       # Codex & Claude adapters (Track1 snapshots, Track2 parsers)
├── Orchestration/   # App runtime, collection scheduling
├── Widget/          # Widget data bridge (shared app group)
├── Settings/        # User preferences
├── Store/           # Data persistence
├── ToolDiscovery/   # CLI binary detection
├── Diagnostics/     # Debug logging
└── *.lproj/         # Localized strings

TokenMeterWidget/    # macOS WidgetKit extension
```

**Data flow:** CLI Tool Discovery → Provider Adapters → Track1/Track2 Stores → Widget Snapshot Builder → Shared App Group → Widget

## Links

- [Landing Page](https://bldg-7.github.io/token-meter)
- [Releases](https://github.com/Bldg-7/token-meter/releases)
- [Design Document](DESIGN.md)
