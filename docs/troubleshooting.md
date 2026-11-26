# Troubleshooting

The panel renders the latest usage record written by each collector. It does not invent limits or hide a collector failure, so the message shown in a provider tab is the useful place to start.

## Colors or logos look wrong

The panel follows Omarchy's live foreground, surfaces, tracks, fonts, and
critical color. Provider marks choose their light/default SVG from the bar's
current foreground, including hover states. Warn is intentionally fixed amber
(`#F2B705`) and does not change with the theme; Critical uses Omarchy's urgent
color. Restart the shell after a QML change because plugin components are
cached.

## I see an auth or endpoint card

The coloured card shows the provider status in its heading and the collector's next step below it. It is intentionally not a generic plugin error.

- **Claude:** live session/weekly limits need a signed-in `claude` CLI. Sign in again, or check `CLAUDE_CONFIG_DIR` when using a non-default Claude configuration. Local transcript-derived token statistics can still appear without live limits.
- **Codex:** limits require the Codex app-server RPC. Confirm Codex itself can reach the app-server and that its local configuration (`CODEX_HOME`, when set) is the one you expect. Local session statistics can remain available while the endpoint is down.
- **Fireworks:** check `FIREWORKS_API_KEY` and `FIREWORKS_ACCOUNT_ID`, then the fallback credentials in `~/.fireworks/auth.ini` or OpenCode's auth file. The exact collector help text identifies which credential was not detected.

For another provider, follow the card's collector-supplied help text. A collector should use the `auth-missing` and `endpoint-down` conventions in [collector-contract.md](collector-contract.md), so its panel state names both the problem and how to resolve it.

## Understanding Plan vs API

The expanded Details view keeps the accounting labels separate:

- **On subscription** is the provider-reported quota percentage and reset
  window. It is not converted into fake dollar credits.
- **API credit left** is the real prepaid balance returned by a provider such
  as OpenRouter, DeepSeek, or xAI; when the provider reports funded/spent
  values, the hint shows both.
- **At API prices** is a published-rate equivalent of recorded tokens. It
  is available only when exact model/token pricing exists for that provider;
  "No API-price estimate" means the data was not provided, not that the cost
  was zero.

The "a day" figure is the estimate divided by the collector's distinct
active days when no per-day price matrix is available; the panel then shows
no daily bars rather than made-up ones.

## A provider is missing

Check the three deliberately different visibility states:

- `enabled: false` hides the provider everywhere and excludes it from refresh.
- `enabled: true` with `showInBar: false` hides only its bar meter; it remains selectable in the panel.
- `Bar slot: Off` hides a provider, `Fixed` keeps it visible, and `Cycle`
  puts it in the rotating pool. `barCycleSlots` controls how many rotating
  meters are visible at once. Choosing Fixed or Cycle enables that provider.

The bar lays out the configured providers up to the bundled collector safety
ceiling; any future overflow is collapsed into a `+N` indicator. Click it to
open the complete provider switcher. A provider with no usage record yet is
also absent until the next collector refresh produces usable data.

If every known provider is disabled or hidden from the bar, the module glyph remains so Settings are still reachable. A completely new machine with no discovered usage record has no widget at all; that is the intentional empty state.

## Fireworks has no balance

Fireworks can report token usage without a prepaid balance. The live balance endpoint may be unavailable to API keys; in that case an estimate needs a `fundedAmount` in `~/.config/omarchy/agents/fireworks.json`:

```json
{
  "accountId": "",
  "fundedAmount": 20,
  "fundedAt": "2026-07-01"
}
```

Without that amount, the balance section is intentionally omitted rather than pretending the account is empty.

## Cost estimate is absent or differs from a bill

`Plan vs API` appears in Details only. It compares the provider's real
subscription quota or prepaid API balance with a token-derived published-rate
equivalent; compact view intentionally stays focused on subscription status.
The equivalent is not an invoice, subscription charge, tax calculation, or
account balance. A provider shows `—` when it has no exact model/token pricing,
not when its cost is zero. Check the selected provider and record timestamp
before comparing it with a vendor bill; cached reads, non-token charges, or a
changed price list can differ. A partial estimate names the models excluded
from the subtotal once, in neutral text. When `byDay` is absent, `Avg /
recorded day` is the total divided by the collector's reported active days; no
synthetic daily bars are drawn.

## The panel looks unchanged after editing QML

Quickshell caches compiled plugin components by URL. A plugin rescan does not reload a changed QML file. Run:

```bash
omarchy restart shell
```

This is Omarchy's supervised shell restart. For a local branch preview, fetch/check out that branch in the live plugin checkout first, then restart.

## A custom collector does not render

Run the record through the validator before debugging the panel:

```bash
./scripts/agent-usage-doctor /path/to/provider.json
```

or pipe JSON to its standard input. The record contract documents required fields, error conventions, and the size/data limits the display enforces.
