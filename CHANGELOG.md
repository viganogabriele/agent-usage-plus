# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Redesigned panel dashboard (the bar is unchanged, pixel for pixel):
  - An overview with Session and Weekly side by side as rings in the theme
    accent (or the two fullest windows, or prepaid credit); only the Warn and
    Critical thresholds change a ring's color. Each window's reset is stated
    once, under its own ring: "Resets in 2h 12m", the wall-clock time, and
    the outlook at the current rate ("Runs out 39m before reset" or "~88%
    used by reset"); hovering a ring gives the exact run-out time. A dot on
    the ring marks how much of the window has elapsed.
  - Free resets the provider granted and you can still redeem: a plain row in
    the Usage view with how many and how many days are left (where to redeem
    on hover), and a note on each account row. Codex's come from Omarchy's collector; Claude's are
    read by the new `omarchy-agent-usage-claude-compat`, which opts Omarchy's
    own usage request in to Anthropic's `cedar_ember` block, keeps no grant
    identifiers, and falls back to Omarchy's updater if it fails.
  - Four views under the overview — Usage, Activity, Models, Cost — instead
    of one long Details scroll; `e` steps through them, and a view with
    nothing to show says why.
  - Window pace on every allowance row: a clock tick on the meter and "12%
    ahead of pace" / "Out in 1h 20m at this rate". The projection is the
    window's own average rate and is withheld for the first 5% of a window and
    for windows whose length is unknown (`logic/insights.js`).
  - Today, Prompts/7-day average, and Streak tiles, with today compared to the
    7-day average.
  - Provider chips ringed with each account's fullest meter, plus a status dot
    for sign-in/endpoint problems, so the switcher doubles as an overview.
  - A hero with a plan pill, "Updated … ago", and a one-click refresh button.
  - Activity: a smoothed, area-filled token trend with a hover guide, then a
    five-week calendar heatmap with recorded total, 7-day average and
    week-over-week change. Models: a token-mix bar with cache hit share and
    per-model use. Cost: the selected account's API-rate estimate with "a
    day" / "per 30 days" chips, a gradient daily chart and models as one
    stacked bar in tonal steps of the accent; then ranked rows for the providers that have an
    estimate, each with its share of the total, and one line naming the
    rest — nothing cut to "Partial · A…".
  - Accounts of the selected provider as rows with a ring, reading, next
    reset and Use/Active.
- Redesigned Settings at the panel's own width (it used to jump to twice
  the width): Providers / Accounts / Display / Alerts / Sync tabs; a compact
  card per provider with its plan or problem, an Enabled switch, "In the bar"
  and "Shows" segmented controls and a live preview built from the real bar
  parts; an Accounts tab listing every login with its live reading and
  Sign in / Use / Remove, then New login and Import existing logins;
  explained toggle rows; a threshold scale drawn from the values being
  edited; and a pinned save bar (Discard / Save, a dot on the tab holding
  the edit) that writes only the settings that changed.

### Changed

- Panel cards and controls keep a soft minimum corner radius (12px cards,
  8px controls, pill switches) even when Hyprland's window rounding is 0,
  instead of turning into hard boxes; the bar is untouched.

- Panel text is contrast-checked against the popup surface: secondary text
  no longer drops below 4.5:1 on dark themes (Everforest, Gruvbox, Tokyo
  Night, Nord) or reads darker than primary text on light ones, and amber,
  red and accent text is deepened only as far as a theme needs (the fixed
  amber was ~1.7:1 on every light theme). Meter and bar colors are
  unchanged.
- Token counts past a trillion read `1.2T` instead of `1234.0B`.

### Fixed

- The panel no longer resizes or re-animates on its own: a hover-only hint
  under the provider marks added and removed a line of text, and every
  refresh rebuilt the rings and lists (re-filling rings from zero). Lists now
  update in place, and the refresh icon spins only for a refresh you asked
  for, not for the background run every opening starts.

- Bar marks with a dark twin (Codex, Devin, OpenRouter, …) were drawn
  near-black on dark bars whose text color is a mid-tone light, such as
  Tokyo Night's `#a9b1d6`: the light/dark choice used a 0.5 luminance cutoff
  instead of the black/white contrast crossover (~0.18). Nothing else about
  the bar changes.
- With every provider turned off, the panel header and its Settings gear
  disappeared, leaving only the `s` key to turn one back on.

- Date labels under the token trend and the API-equivalent-by-day chart no
  longer pile up at the left edge (a `Row` collapsed its hidden labels), and
  the daily chart's dollar axis no longer elides values like `$216.…`.

## [2.3.0] - 2026-11-25

### Changed

- Renamed to **AI Agent Usage Plus** in the marketplace and widget picker. The
  plugin id, install command and settings are unchanged.
- The API cost card now leads with the "If billed by API" estimate, labels
  every provider row as an estimate (or "Partial" / "No estimate") with its
  period, and states that figures are published API rates, not a bill.

### Added

- Multiple Claude and Codex accounts: import existing account directories or
  add new ones in Settings, see each account's limits, and choose which account
  the bar launches. See `docs/multi-account.md`.
- Google Antigravity (`agy`) collector and provider mark: reads local CLI and IDE
  SQLite databases for token and session history, plus quota allowances from
  `agy -p /usage --output-format json`.

### Fixed

- API cost estimates use current model prices, including GPT-5.6 cache writes
  at 1.25 times the input rate, and per-metric cost tiles no longer truncate
  their labels.

- The Antigravity collector no longer opens a browser tab and steals focus on
  every refresh while signed out. `agy -p /usage` runs a real agent turn: when
  signed out it prints an OAuth URL, opens it in the browser, and blocks for
  up to a minute waiting for the callback — repeated on every unattended
  refresh cycle, this meant a new tab grabbing focus every cycle. The
  collector now probes sign-in state first with the cheap, non-interactive
  `agy models` (fails fast, no browser, no prompt) and only ever runs
  `-p /usage` once that probe confirms a signed-in session. A probe failure
  unrelated to auth (timeout, launch failure, an unrecognized exit) is
  reported as a transport problem, not misread as "please sign in".
- The Antigravity collector no longer drops a whole `gen_metadata`/`steps` row
  (token counts included) just because that row also embeds a large, unrelated
  blob — the full chat context on a session's final generation, or a tool
  invocation payload — which some rows carry alongside their small usage
  fields. The row-size cap is now generous enough to admit real-world rows,
  and the protobuf parser skips past an oversized embedded field instead of
  aborting the rest of the message, so the small fields that matter are found
  regardless of size or ordering of the fields around them.
- Right-clicking a provider mark in the bar no longer launches the wrong
  agent. Each mark's click target covered only the pixels it painted, so the
  gap between two marks, the widget's outer padding, and the bar height above
  and below the percentage text all fell through to the whole-widget button.
  That button's right-click names no provider and falls back to
  `omarchy-agent --pick`, which launches the configured default agent instead
  of asking — so a right-click a few pixels off the Claude mark opened Codex.
  Targets now meet midway in the gap and span the full height of the bar.
- Codex limits no longer show "Codex limits unavailable / account/read" with
  Codex CLI 0.156. The CLI now writes notifications and the RPC reply in one
  stdout chunk; Omarchy's collector reads the chunk with `readline()`, keeps
  only the first line, and then waits on an empty pipe until `account/read`
  times out. The `--codex-cli-compat` wrapper now patches that reader to drain
  buffered lines before waiting (omacom/omarchy#10143, #12979), and skips the
  patch once Omarchy ships the fix.

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
