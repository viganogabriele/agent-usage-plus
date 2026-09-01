# Manual QA checklist

Run this checklist against the real Omarchy bar before a release. QML is not hot-reloaded: after changing or relinking this plugin, run `omarchy restart shell`. `omarchy-shell shell rescanPlugins` is not enough to load changed QML.

Automated tests cover extracted logic and record validation. They cannot show clipped bar content, a confusing control, or a popup that has become hard to use at a real desktop size.

## Bar

- [ ] With one, two, and three enabled providers that have data and `showInBar: true`, each meter has a readable mark, meter, and percentage. A provider with a weekly limit also has the small weekly tick.
- [ ] With enough eligible providers to exceed the bundled collector safety ceiling, the bar shows the `+N` overflow indicator. Hovering it explains that the remaining subscriptions are in the panel; clicking it opens the full provider list rather than creating an inert gap.
- [ ] Verify Off, Fixed, and Cycle roles. Fixed providers
  stay visible while the configured number of rotating slots advances at the
  interval. Test two rotating slots and one Fixed plus one Cycle. Middle-click
  advances the rotating slice without changing the panel's selected tab.
- [ ] `showInBar: false` hides only the meter, not the provider's panel tab. `enabled: false` hides it from both and stops collector refreshes for it.
- [ ] When every known provider is hidden from the bar or disabled, the module glyph remains visible and opens settings. On a machine with no discovered record at all, the widget correctly stays absent.
- [ ] Check normal and critical meter colors at the configured boundaries and
  confirm they follow the current Omarchy theme after a theme change. Warn is
  intentionally the fixed amber `#F2B705` so it remains distinct from Critical.
- [ ] Every provider mark is crisp (not soft/blurry) and reads as the same visual size at both bar scale and panel scale, including Claude and Codex against the rest of the set. Codex stays a plain white (or black on a light surface) mark, never tinted.
- [ ] Hover or otherwise switch the bar to its light/transparent foreground and
  confirm provider marks switch to the matching light/default assets in the bar
  as well as in the panel; logos must remain in the same provider order.
- [ ] Cycle the "Bar labels" setting through Icon, Icon + %, and Full: the bar shows only the mark, the mark with its percentage, and the mark with percentage and meter, respectively — with no leftover gap or misaligned spacing between slots in any mode.

## Panel hierarchy and interaction

- [ ] The hero has two equal outlined actions: gear for Settings and chevron for Details. Their tooltips name the action and shortcut; `s` toggles Settings and `e` toggles Details. Opening either closes the other.
- [ ] With several providers, the switch shows compact logos instead of text pills. Hover and keyboard focus reveal each full name. `h`/`l` still select every provider, including a logo on a wrapped row.
- [ ] Compact view prioritizes error/help, limits or balance, daily tokens, then model tokens. It should not open scrolled partway down or clip content at 1366x768 and 1920x1080.
- [ ] Details first show the selected provider's token use by model. If known, each row's right column is labelled API price. The derived total follows this table and says that it is not a bill or subscription price.
- [ ] The history is a line chart across every recorded day. It shows a 0/50/100% token scale and start, middle, and end dates without a fake range selector.
- [ ] A pace subtitle appears only for a real token quota with a rising
  multi-day history that would exhaust before reset; it stays absent for one
  day, flat, decreasing, percentage-only, or reset-first data.
- [ ] `r` and Enter refresh, `j`/`k` scroll, Tab moves to the neighbouring panel, and Esc closes. Tab can focus the gear, expansion chevron, and cost disclosure; Enter, Space, and Return activate each.

## Settings

- [ ] Open the gear: every provider occupies one row; its name, Enabled switch,
  and Off/Fixed/Cycle selector do not clip or overlap. Disabled providers dim
  the bar-slot selector.
- [ ] Mark a provider Cycle and verify the rotating-slot count and interval
  appear. Both values must stay within their stated limits.
- [ ] Change refresh interval and warn/critical thresholds, click Save, then confirm values survive `omarchy restart shell`. Settings must apply without a restart because the panel writes via `omarchy bar set`, not directly to `shell.json`.
- [ ] Toggle "Show available instead of used quota": a 13% usage label and meter become 87% available in both the bar and limit rows, while Warn/Critical colors still trigger at the same real quota levels. Threshold controls complement automatically (75/90 used becomes 25/10 available), notifications say "available", the setting survives `omarchy restart shell`, and disabling it restores usage terms.
- [ ] Confirm an invalid externally-written threshold pair (`warn >= critical`) never crashes the panel; it should skip the warn band until the pair is corrected.
- [ ] Edit a Behaviour field (e.g. type a new Warn value) without clicking Save, then toggle an unrelated switch (a provider's Enabled/Bar slot, or Notifications) — the in-progress edit and the "Unsaved changes" label must survive; the field must not snap back to its old value. Save commits every changed field in one go; closing and reopening Settings without saving discards the draft back to the live value.

## Notifications

- [ ] With Notifications off (default), no `notify-send` fires no matter how high usage climbs.
- [ ] With Notifications on, a provider crossing Warn produces exactly one notification, and crossing Critical produces exactly one more — not a repeat on every refresh while it stays above the line.
- [ ] After the window resets (or on the next billing/session period), the same provider crossing Warn again produces a new notification.
- [ ] Restarting the shell while a provider is already above a threshold does not replay that alert; it must first drop below the threshold and cross it again.

## Error and data states

- [ ] An auth-missing or endpoint-down record shows a coloured card with a visible status heading and the collector's actionable help text. A status record with no help text must still show its status rather than a blank card.
- [ ] Claude without valid CLI credentials retains local token statistics but clearly explains that live subscription limits need sign-in.
- [ ] Codex with its app-server RPC unavailable clearly reports the endpoint problem while retaining local statistics where available.
- [ ] Fireworks without `fundedAmount` still shows token usage and simply omits the balance estimate; this is not presented as a failure.
- [ ] Validate valid collector output with `scripts/agent-usage-doctor`, then check malformed and oversized records do not crash or hang the widget.
- [ ] With sync enabled, two snapshots for the same provider merge day data without duplicate days and retain local-only rate limits.

## Release checks

- [ ] `npm test` passes.
- [ ] Qt 6 `qmllint` reports no Warning or Error lines (Quickshell import Info lines outside Omarchy are expected).
- [ ] `jq empty manifest.json` and `./scripts/check-manifest.sh manifest.json` pass.
- [ ] Use the live checkout/restart workflow above for every meaningful QML batch; do not approve a visual change from lint output alone.
