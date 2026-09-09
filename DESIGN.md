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

Optional fields:

- resetCreditsAvailable: banked rate-limit reset credits still available to
  spend (Codex reset banking, June 2026); omitted when the source does not
  report it

Providers are not required to report every window. Codex stopped reporting
`rolling_5h` in July 2026 (weekly-only limits); widget surfaces that show a
single quota window prefer `rolling_5h` and fall back to `weekly`.

### 4.2 Track 2 (Local Telemetry)

Track 2 only contains local token observations for charting. The persisted
store keeps a rolling 30-day window (anchored to the newest point); older
points are pruned on persist so the store stays bounded.

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

Third-party agent sources that can run GPT models (section 5.3) also feed this
provider.

## 5.2 Claude

### Track 1

- Method B default.
- Method C optional fallback/selectable in settings.

### Track 2

Local timeline sources:

1. `projects/*.jsonl`
2. OpenCode local message logs (`~/.local/share/opencode/storage/message/**/*.json`, assistant-only)

Third-party agent sources that can run Claude models (section 5.3) also feed
this provider.

## 5.3 Third-Party Agent Sources

Agents that are not providers in their own right — they hold no quota and
expose no usage endpoint, but spend the quota of the provider behind the model
they call — are modelled as additional Track 2 *sources* rather than as
providers. Each turn is attributed to the provider that owns the model, so a
Claude model driven by another agent lands on the Claude timeline alongside
Claude Code's own. Turns on models owned by neither provider (Gemini, DeepSeek,
local models) have no home in the two-provider model and are dropped.

These sources are Track 2 only. They must never contribute to Track 1, per the
prohibitions in section 4.3.

Each file-based source keeps its own incremental cursor scope, keyed by
provider *and* source. The incremental reader evicts cursors for every path a
pass did not scan, so two sources sharing a provider and a scope would erase
each other's cursors on every cycle and re-read their files from the start
forever.

A cursor carries two pieces of the bytes it has already read: a `pendingTail`
holding a trailing line the writer had not finished, and a `contextTail`
holding the last 64KB of complete lines, which gives the next parse the
preceding lines a point may need (a model name, a session header). Both are
prepended to the next buffer, `contextTail` first, so a fragment must live in
exactly one of them: stored in both, it is glued to a duplicate of itself once
the writer completes the line, the entry fails to parse, and the offset has
already moved past it, so it is lost for good. A live agent is mid-line
whenever the first scan of its log happens, which is the common case for pi.

### OpenCode

`~/.local/share/opencode/opencode.db` (SQLite), assistant rows only.

### pi

`~/.pi/agent/sessions/--<encoded cwd>--/<timestamp>_<session-id>.jsonl`, one
append-only JSONL file per session. Assistant turns and the summarization
entries described below are the token-bearing lines. pi supports Claude
Pro/Max and ChatGPT subscription OAuth, so these turns draw down the same quota
Track 1 already reports for those providers.

Parsing rules that the format demands:

- `usage.reasoning` is a subset of `usage.output` and `usage.cacheWrite1h` a
  subset of `usage.cacheWrite`; neither may be added again.
- `/fork` and `/clone` copy the source session's entries verbatim into a new
  file while writing a fresh header. Turns older than their file's session
  header are inherited history and must be skipped, or they are counted twice
  under a second session id.
- `responseModel` names the model that actually answered a routed request and
  takes precedence over `model` for attribution.
- `compaction` and `branch_summary` entries carry their summarization call's
  `usage` at the entry level, with no message wrapper and no model field.
  These are among the most expensive calls in a long session, and pi counts
  them in its own totals, so they are attributed to the model the session was
  last seen running, tracked forward from assistant turns and `model_change`
  entries within the same parse buffer. That model is deliberately not carried
  across incremental cycles: a point whose provider depends on how much
  history the buffer happened to hold would be re-emitted under a different
  key each time the context tail is re-read, defeating the content dedup. The
  cost is that a summarization entry is skipped when no model precedes it in
  the buffer, which is preferred over charting it against the wrong quota.
- The session root follows `PI_CODING_AGENT_SESSION_DIR`, then
  `PI_CODING_AGENT_DIR`, then `~/.pi/agent`. A GUI launch inherits no shell
  exports, so those overrides only apply when the app itself was started with
  them; there is no settings override, since a source has no settings of its
  own.

Known limitation: attribution is by model name first, provider hint second, so
a locally served model whose name contains `gpt` (`gpt-oss-*` through a local
runner, for example) is charted against the Codex timeline even though it costs
nothing. Distinguishing it would need a provider allowlist keyed to pi's local
runner ids.


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
