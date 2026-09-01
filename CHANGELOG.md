# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- An opt-in setting switches percentages, meters, warning controls, and alerts
  together from quota used to quota available without changing trigger points.
- OpenCode Go collector (`collectors/agent_usage_collectors/opencode_go.py`): reads
  local session/token stats from opencode's own SQLite store and the
  authoritative rolling/weekly/monthly allowances from Zen's usage endpoint,
  matching the shape of Omarchy's own local-plus-remote collectors
  (Claude/Codex) rather than the API-only companion collectors.

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
  (`#F2B705`); Critical uses the theme's urgent color.
- This is a major release: the bar/panel interaction model, provider layout,
  optional collectors, notifications, details view, and settings workflow are
  substantially different from 1.x.

## [1.5.0] - 2026-08-23

### Added

- Per-provider bar visibility, all/primary/cycle bar modes, configurable warn/critical thresholds, in-panel settings, expandable cross-provider model data, cost-block rendering, and the expanded labelled history line.
- Pure logic modules, fixtures, Node tests, collector contract validation, and the initial icon/contributor documentation.
