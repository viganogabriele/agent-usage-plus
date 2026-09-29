# Agent Usage Plus

Omarchy/Quickshell bar widget for local AI-subscription usage. Keep changes
small, data-safe, and visually verified; a plausible QML diff is not enough.

## Map

- `Agent.qml`: widget entry point and plugin metadata bridge.
- `Main.qml`: settings, records, refresh and bar-layout state.
- `Panel.qml`: bar and panel UI.
- `logic/`: pure JS, covered by Node tests in `test/`.
- `collectors/`: bundled collectors, with their own Python tests in
  `collectors/tests/`. Read `collectors/README.md` and
  `docs/collector-contract.md` before changing their output.

## Working rules

- Never read or write API keys, OAuth tokens, transcripts, or shell settings
  directly. Collectors emit records; settings changes go through the existing
  spawned `omarchy bar set` path.
- Preserve user worktree changes. Do not push or open PRs unless explicitly
  requested.
- Add or adjust a test in `logic/` for logic changes. Keep collector output
  compliant with `docs/collector-contract.md`, including useful auth-missing
  and endpoint-down states.
- Use bundled SVGs for provider marks. Set `sourceSize` on every mark `Image`
  (`width * Screen.devicePixelRatio`, matching Tray.qml/Menu.qml elsewhere in
  the shell) — without it marks read as soft/blurry, worse the smaller the
  box or the higher the output's pixel density. Do not replace SVGs with
  scaled raster assets; check bar-scale and panel-scale rendering separately.
- Follow the theme contract: surfaces, foregrounds, tracks, fonts, and the
  critical state come from Omarchy's live colors; Warn is intentionally fixed
  amber (`#F2B705`) for a stable, distinct warning state. Bar marks must choose
  their default/light asset from the bar's live foreground, including hover or
  transparent-bar states, so the bar and panel stay visually consistent.
- Treat provider responses as untrusted too: keep collector JSON reads bounded
  before parsing, preserve explicit auth/endpoint error states, and never put an
  upstream response body or credential into a record or log.
- **`omarchy bar set <id> <key> <value> --json` cannot take a top-level JSON
  array value with more than one element** — it miscounts its own arguments
  and fails every time ("Too many arguments provided"), silently, with no
  QML-side error beyond a `console.warn` line in the shell's own log (nothing
  surfaces in the panel). A single-element array, and any JSON object no
  matter how many keys, both write fine — only a bare multi-element array is
  affected. Reproduce/verify directly: `omarchy bar set <id> <key>
  '["a","b"]' --json` fails, `omarchy bar set <id> <key> '"[\"a\",\"b\"]"'
  --json` (the array double-JSON-encoded into a string) succeeds. Any new
  array-valued setting must be written double-encoded
  (`JSON.stringify(JSON.stringify(arr))`) and unwrapped with a guarded
  `JSON.parse` on read — see `providerOrder` in Main.qml for the pattern.
- Do not add a hardcoded cap on how many providers can show in the bar (no
  "3 fixed + cycle slots" style budget). The only real ceiling is however
  many providers the person has actually configured (Fixed count + Cycle
  slots), which is itself already bounded by how many providers exist to
  configure, including additional account records. `selectBarLayout` clamps
  to the eligible list's length; `barSlotLimit`
  (Main.qml) and `maxBarProviderSlots` (Panel.qml) exist only so
  `selectBarLayout`/the "+N" affordance have *a* number to work with and
  should stay far above anything a real configuration would hit.
- A notification not appearing is not necessarily a code bug: Omarchy's own
  Do Not Disturb state lives in `~/.local/state/omarchy/notifications.json`
  (`"dnd": true` suppresses the popup even though `notify-send` still
  succeeds), and every notification actually delivered is logged under
  `~/.local/state/omarchy/notifications/history/*.json` regardless of DND —
  check that history before assuming the panel's own notify-send dispatch is
  broken.
- Reordering draggable items (the panel's provider switcher) does not move a
  real `Grid`/`Row`/`Column` child and rely on the positioner "leaving a
  Drag.active item alone" to snap it back afterward — that did not reliably
  reposition the item once dropped, leaving marks stranded wherever they
  were released. Use a separate, non-positioned ghost item (parented at the
  panel's top level, positioned via `mapToItem`) that follows the pointer;
  the real grid children never move and the model is only reordered once, on
  drop — see `providerSwitch`/`dragGhost` in Panel.qml.

## Required checks

```sh
npm test
(cd collectors && python3 -m unittest tests.test_collectors)
/usr/lib/qt6/bin/qmllint --import=info --unqualified=info --missing-property=info --inheritance-cycle=info --incompatible-type=info --signal-handler-parameters=info --unresolved-type=info Agent.qml Main.qml Panel.qml
jq empty manifest.json && ./scripts/check-manifest.sh manifest.json
```

`qmllint` may emit `Info:` messages for unavailable Omarchy imports. It must
not emit `Warning:` or `Error:` lines. Run the Python suite too whenever a
change touches `collectors/` — it is not wired into `npm test`.

## Live preview

Quickshell caches compiled plugin components. `rescanPlugins` does **not**
reload changed QML. After a meaningful UI batch, preview the branch from the
live checkout and restart the supervised shell:

```sh
cd <live-plugin-dir>
git fetch local-dev <branch>
git checkout -B preview <fetched-commit-or-FETCH_HEAD>
omarchy restart shell
```

Then inspect the bar, normal panel, settings, provider states, scrolling and
hover states. Check the user journal for plugin errors before handoff:

```sh
journalctl --user --since "1 minute ago" --no-pager | grep -iE "error|agent-usage"
```

Replace `<live-plugin-dir>` with the checkout used for the local preview.

A worktree with uncommitted changes can be previewed the same way without a
commit — `cp` the changed `.qml`/`.js` files straight over the live
checkout's copies, skipping the fetch/checkout-B step, then restart. This is
also the fastest way to reproduce a suspected `omarchy bar set`/settings-
write bug directly: run the exact `omarchy bar set <id> <key> <value>
--json` command from a terminal and read its own stdout/exit code, rather
than only inferring success or failure from the panel.

## Documentation contract

- Keep `README.md` short: installation, supported providers, theme/notification
  behavior, the current screenshots, and links to detailed docs belong there.
- Put collector setup, field-level behavior, troubleshooting, and release QA
  in the linked documents instead of expanding the README into a manual.
