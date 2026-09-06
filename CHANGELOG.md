# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- Right-clicking a provider mark in the bar no longer launches the wrong
  agent. Each mark's click target covered only the pixels it painted, so the
  gap between two marks, the widget's outer padding, and the bar height above
  and below the percentage text all fell through to the whole-widget button.
  That button's right-click names no provider and falls back to
  `omarchy-agent --pick`, which launches the configured default agent instead
  of asking — so a right-click a few pixels off the Claude mark opened Codex.
  Targets now meet midway in the gap and span the full height of the bar.

## [2.2.0] - 2026-09-05

### Added

- Devin collector and provider mark: reads local CLI token/session history and
  the signed-in account's daily/weekly quota without storing another copy of
  the CLI credential. A plugin-local dispatcher refreshes Devin alongside the
  packaged providers without activating the other optional collectors.
- Multi-device sync now has a Settings UI: a toggle and a sync-folder field,
  with live status ("Merged from N devices"). The merge logic already
  existed (`logic/aggregate.js`); it previously required hand-editing
  `syncMode`/`syncDir` with `omarchy bar set` from a terminal, so almost
  nobody could discover or use it. Documented in the README.
- Optional `brand` record field: a record whose `id` isn't a bundled provider
  id (e.g. a second account like `claude-work`) can declare `"brand":
  "claude"` to render with that provider's mark in the bar and panel. This
  makes multiple accounts of one provider first-class: each account is its
  own record (own meters, own per-provider settings), branded correctly.
  Sanitized like a provider id, carried through sync snapshots, validated by
  `agent-usage-doctor`, and documented in the collector contract.

### Changed

- Moved estimated API cost out of the compact view and into a Details-only
  analytics section with provider comparison, price coverage, model spend
  bars, and an optional daily estimate chart.

### Fixed

- The token-by-model table no longer repeats API prices or displays partial
  cost warnings in yellow; partial estimates are disclosed once in neutral
  text without null-binding errors when a collector has no cost data.
- The Codex collector retries once when the RPC handshake comes back empty
  (limits unavailable), so a slow version-manager shim (mise, asdf, ...)
  resolving `codex` no longer reads as "Codex limits unavailable" on an
  install that is actually authenticated and working.

## [2.1.0] - 2026-08-28

### Added

- An opt-in setting switches percentages, meters, warning controls, and alerts
  together from quota used to quota available without changing trigger points.
- An opt-in traffic-light palette color-codes quota meters in both the bar and
  panel: green while healthy, amber at Warn, and red at Critical. Severity
  stays usage-based when the meter is shown as available quota.
- OpenCode Go collector (`collectors/agent_usage_collectors/opencode_go.py`): reads
  local session/token stats from opencode's own SQLite store and the
  authoritative rolling/weekly/monthly allowances from Zen's usage endpoint,
  matching the shape of Omarchy's own local-plus-remote collectors
  (Claude/Codex) rather than the API-only companion collectors.
- Optional collector automation is available again through `collectors/install.sh`:
  a user-level systemd timer can refresh configured API collectors, optional
  Omarchy command-path links can be created, and transcript-derived cost
  collection can be enabled explicitly.

## [2.0.0] - 2026-08-25

### Changed

- The release QA checklist and troubleshooting guidance now describe the shipped panel: separate Settings and Details actions, bar display modes, thresholds, line history, API-price estimates, and collector error states.
- The bar represents additional providers with a `+N` affordance instead of growing without bound in All mode; the panel remains the complete provider switcher.
- Provider choices are compact logos with hover/focus names, and the panel scrolls more responsively without a permanent scrollbar.
- Settings uses one row per provider with adjacent Enabled and In bar switches. Primary mode has been removed; In bar controls cycle membership as well as normal bar visibility.
- Details shows token use by model before any optional API-price estimate, and the history chart is a labelled line across recorded days.
- Status cards always show the collector's status and show its help text when available, preventing a blank error card.

- Provider marks render at a consistent visual weight (Claude and Codex no longer read larger than the rest) and rasterize at their actual on-screen size instead of a default SVG size scaled after the fact, fixing blurriness. Codex and Kimi's bundled SVGs no longer use a CSS-only `1em` size that Quickshell can't resolve.
- The Behaviour settings fields (cycle slots, rotate/refresh seconds, warn/critical thresholds) now edit a local draft and commit on an explicit Save button, instead of writing on every keystroke — a field being edited could previously be reset mid-edit by any other settings write or a periodic refresh landing at the same time.

### Added

- `docs/manual-qa.md`, a live-bar QA checklist that complements automated checks and records the required QML restart workflow.
- `docs/troubleshooting.md`, including credential, visibility, balance, cost, and QML reload guidance.
- A "Bar labels" control (Icon / Icon + % / Full) so the bar can show just the provider mark, the mark with its percentage, or the full meter — independent of bar role/cycle settings.
- An opt-in "Notify when a provider crosses Warn or Critical" setting, off by default: one `notify-send` notification per provider per crossing (not a repeat every refresh), rearmed on the next billing/session window.
- A pace subtitle is shown only when a real token quota has a rising multi-day
  history and exhaustion is projected before the window reset.

### Fixed

- Notification Test and threshold alerts now use Omarchy's supported D-Bus
  sender instead of `notify-send`; Test reports Sending, Sent, or Failed, and
  the notification controls remain visible beside the available-quota option.
- Bar and panel provider order now stay aligned after Fixed/Cycle selection and
  drag reordering.
- Provider marks in the bar follow the live bar foreground, including hover and
  light/dark surface changes, instead of keeping a stale variant.
- Sync aggregation now uses prototype-safe maps, so hostile or unusual provider,
  model, device, and saved-order names cannot collide with JavaScript built-ins
  or interrupt a refresh.
- Companion collectors cap provider JSON responses at 1 MiB before parsing,
  keeping malformed or unexpectedly large responses from consuming unbounded
  memory.
- Z.AI endpoint overrides are restricted to the two documented provider hosts
  before any bearer key is sent.

### Notes

- The interface follows Omarchy's live theme. Warn remains deliberately amber
  (`#F2B705`); Critical uses the theme's urgent color unless the opt-in
  traffic-light palette is enabled, where Critical is explicitly red.
- This is a major release: the bar/panel interaction model, provider layout,
  optional collectors, notifications, details view, and settings workflow are
  substantially different from 1.x.

## [1.5.0] - 2026-08-23

### Added

- Per-provider bar visibility, all/primary/cycle bar modes, configurable warn/critical thresholds, in-panel settings, expandable cross-provider model data, cost-block rendering, and the expanded labelled history line.
- Pure logic modules, fixtures, Node tests, collector contract validation, and the initial icon/contributor documentation.
