# Token Meter macOS MVP Design

## 1. Scope and Goals

This design targets a macOS status bar app that monitors Codex and Claude Code usage with two separate tracks:

- Track 1: authoritative provider-facing usage snapshots (limits, used/remaining, reset)
- Track 2: local telemetry timeline for token graphing

Hard requirements captured in this design:

- Codex Track 1 uses Method B only (no Method C option in settings)
- Claude Track 1 supports Method B (default) with Method C optional fallback
- Track 1 and Track 2 are never merged, reconciled, or mathematically combined
- CLI tool discovery is built in
- Current plan label is displayed
- Multilingual support is built in from day one


## 2. Product Principles

1. Source transparency: every metric shows its source and confidence.
2. No hidden interpolation: Track 1 and Track 2 are independent data products.
3. Degrade gracefully: if one source fails, only that card/section degrades.
4. Deterministic parsing: schema/version checks before parsing dynamic outputs.
5. Localization first: all user-facing text goes through i18n keys.


## 3. High-Level Architecture

### 3.1 Modules

- AppShell (status bar, settings, menu UI)
- Provider Runtime
  - CodexProvider
  - ClaudeProvider
- Track1 Engine
  - Source adapters
  - Snapshot validator
  - Snapshot store
- Track2 Engine
  - Local parsers
  - Timeline normalizer
  - Timeline store
- Tool Discovery Service
- Plan Resolution Service
- Localization Service

### 3.2 Data Flow

1. Tool Discovery runs at launch and on-demand.
2. Provider Runtime starts enabled providers with resolved binaries.
3. Track1 adapter fetches snapshots per provider method policy.
4. Track2 parser ingests local artifacts and emits timeline points.
5. UI renders sections separately with source badges.
6. Localization Service resolves all labels/messages by locale key.


## 4. Track Model (Strict Separation)

### 4.1 Track 1 (Authoritative)

Track 1 only contains provider/server-derived windowed usage data.

Required fields:

- provider: `codex | claude`
- observedAt: ISO timestamp
- source: `cli_method_b | web_method_c`
- plan: normalized plan label or `unknown`
- windows: array of usage windows
  - windowId: `session | rolling_5h | weekly | model_specific`
  - usedPercent (nullable)
  - remainingPercent (nullable)
  - resetAt (nullable)
  - rawScopeLabel
- confidence: `high | medium`
- parseVersion

### 4.2 Track 2 (Local Telemetry)

Track 2 only contains local token observations for charting.

Required fields:

- provider
- timestamp
- sessionId (nullable)
- model (nullable)
- promptTokens (nullable)
- completionTokens (nullable)
- totalTokens (nullable)
- sourceFile
- confidence: `medium | low`
- parserVersion

### 4.3 Explicit Prohibition Rules

- Do not compute remaining quota from Track 2.
- Do not backfill Track 1 reset times from Track 2.
- Do not combine Track 1 + Track 2 into one number/graph.


## 5. Provider Strategy

## 5.1 Codex

### Track 1

- Fixed to Method B only.
- Source: Codex CLI/App Server/status output channel.
- Settings do not expose Method C or web fallback.

### Track 2

Dual parser:

1. Primary: `~/.codex/sessions/**/*.jsonl`
2. Secondary: `~/.codex/sqlite/*` (or provider-maintained local structured store)

`~/.codex/history.jsonl` may be used for metadata only, not as token source of truth.

## 5.2 Claude

### Track 1

- Method B default.
- Method C optional fallback/selectable in settings.

### Track 2

Local timeline sources:

1. `projects/*.jsonl`
2. OpenCode local message logs (`~/.local/share/opencode/storage/message/**/*.json`, assistant-only)


## 6. CLI Tool Discovery Design

## 6.1 Discovery Order

For each provider CLI binary:

1. User override path from settings (if present)
2. PATH lookup (`command -v` equivalent behavior)
3. Common fallback paths:
   - `/opt/homebrew/bin`
   - `/usr/local/bin`
   - `/usr/bin` (if relevant)

## 6.2 Validation Steps

After candidate path found:

1. executable bit check
2. `--version` probe with timeout
3. lightweight health probe (`--help` or provider-safe command)

## 6.3 Persisted Discovery State

- provider
- resolvedPath
- resolutionSource: `manual | path | fallback_path`
- version
- healthy (bool)
- checkedAt
- errorCode/errorMessage (if failed)

## 6.4 UX Requirements

- Settings page includes manual path override per provider.
- Diagnostics screen shows latest discovery result and reason on failure.
- When unhealthy, disable only affected provider widgets.


## 7. Plan Label Resolution

## 7.1 Normalized Plan Enum

- `free`
- `plus`
- `pro`
- `max`
- `team`
- `business`
- `enterprise`
- `unknown`

## 7.2 Resolution Policy

1. Use direct plan field from Track1 source when available.
2. Else parse provider status text with versioned parser rules.
3. Else set `unknown` and display source confidence badge.

## 7.3 UI Display

- Provider card header includes plan badge.
- Badge tooltip includes source method and freshness timestamp.


## 8. Settings Model

```json
{
  "providers": {
    "codex": {
      "enabled": true,
      "track1": {
        "source": "method_b"
      },
      "track2": {
        "mode": "dual_parser"
      },
      "cli": {
        "pathOverride": null,
        "probeTimeoutSec": 5
      }
    },
    "claude": {
      "enabled": true,
      "track1": {
        "source": "method_b",
        "allowMethodC": true
      },
      "track2": {
        "mode": "dual_parser"
      },
      "cli": {
        "pathOverride": null,
        "probeTimeoutSec": 5
      }
    }
  },
  "app": {
    "locale": "system",
    "refreshIntervalSec": 60
  }
}
```


## 9. Multilingual Support (i18n/l10n)

## 9.1 Locale Strategy

- Default locale: system locale.
- User can force locale in settings.
- Fallback chain: selected locale -> language base -> English.

## 9.2 String Management

- No hardcoded UI strings in view layer.
- All text uses stable localization keys.
- Separate key namespaces:
  - `menu.*`
  - `settings.*`
  - `provider.codex.*`
  - `provider.claude.*`
  - `track1.*`
  - `track2.*`
  - `errors.*`
  - `diagnostics.*`

## 9.3 Dynamic Formatting

- Locale-aware date/time and number formatting.
- Plural rules for token/unit labels.
- Relative reset text localized (for example, "resets in 2h 15m").

## 9.4 Initial Language Set

- `en` (baseline)
- `ko` (required for current product context)

## 9.5 i18n QA Checklist

- Long-string overflow in menu/status panel.
- Right truncation policy for narrow status bar width.
- Missing key fallback marker in debug builds.


## 10. UI Information Architecture

## 10.1 Status Bar Popover

- Section A: Provider health + plan badge
- Section B: Track 1 snapshots (authoritative)
- Section C: Track 2 mini graph (local telemetry)
- Section D: source badges + last updated

## 10.2 Settings

- Providers tab
  - Codex: enable, binary path, Track2 parser options
  - Claude: enable, Track1 method (B default, C optional), binary path
- Language tab
  - System / English / Korean
- Diagnostics tab
  - discovery logs, parser status, last errors


## 11. Parser and Schema Versioning

- Every parser has `parserVersion`.
- If schema signature mismatch occurs:
  - mark parser degraded
  - keep previous good data
  - show warning badge in diagnostics


## 12. Reliability and Error Handling

- Timeout budget per external command.
- Circuit-breaker style temporary backoff on repeated failures.
- Independent retries per track/provider.
- Never block UI thread for collection.


## 13. Security and Privacy

- No secret value logging.
- Redact tokens/credentials in diagnostics.
- Local data read is read-only.
- Optional telemetry (if ever added) disabled by default.


## 14. MVP Delivery Phases

### Phase 1: Foundation

- settings model
- tool discovery
- localization scaffolding
- data stores

### Phase 2: Track Engines

- Codex Track1 Method B adapter
- Codex Track2 dual parser
- Claude Track1 B/C adapter
- Claude Track2 dual parser

### Phase 3: UI

- status bar sections
- source badges/confidence labels
- plan badges
- diagnostics and settings screens

### Phase 4: Stabilization

- parser fixtures
- timeout/backoff tuning
- localization QA (en/ko)


## 15. Acceptance Criteria

1. Codex Track1 method is fixed to B and cannot be changed in settings.
2. Claude Track1 defaults to B and optionally allows C.
3. Track1 and Track2 are visually and structurally separated.
4. CLI discovery reliably reports installed/not installed with path and version.
5. Plan badge is shown per provider with source freshness.
6. App supports at least English and Korean with runtime language switch.
7. Parser failures degrade gracefully and do not crash status bar app.
