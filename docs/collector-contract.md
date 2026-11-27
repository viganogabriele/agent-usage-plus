# Collector contract

This is the full spec for the JSON record a collector writes to make an AI
coding subscription show up in this panel. Everything the panel draws comes
from one file per agent; write a compliant one and the plugin needs no code
change to pick it up.

You should be able to write a working collector from this file alone,
without reading any QML or any of Omarchy's own collectors.

Once you've written a record, check its shape without installing the
plugin: `scripts/agent-usage-doctor <path/to/record.json>` (or pipe it in
via stdin) validates it against this contract and prints specific,
actionable errors — e.g. a bad `id` charset or a `recentDays[i].date` that
isn't ISO-8601 — rather than a generic "invalid JSON" dump. It also treats
the two documented error states below (auth missing, endpoint down) as
structurally valid, since they're legitimate shapes, not malformed input.

## Where the record lives

Each agent is one JSON file at:

```
~/.local/state/omarchy/agents/usage/<id>.json
```

(`~/.local/state` is actually `$XDG_STATE_HOME`, defaulting to
`~/.local/state` when that variable is unset.)

`<id>` is your agent's id — a short, stable, filename-safe string (letters,
digits, `-`, `_`; 64 characters max). It must match the record's own `id`
field (see below) and is also the key used to look up an optional icon (see
"Icons" below). Once picked, don't change it — it's how synced snapshots
from other machines and any external tooling key on your agent.

Nothing needs to register this id anywhere. The widget's own updater,
`omarchy-agent-usage-update`, scans this directory on every refresh and
picks up every `*.json` file that's there, regardless of who wrote it or
when. A file that appears mid-session shows up at the panel's next refresh;
nothing polls waiting for it.

Practical constraints on the file itself, enforced by the panel before it
ever reads content:

- The directory listing is capped at 500 files.
- Any file at or above 1 MiB is skipped entirely (excluded before the panel
  even opens it).
- The read itself is bounded to 1 MiB; content past that is discarded and
  the record is treated as unusable for that refresh.

Write the file atomically (temp file + rename) so the panel never reads a
half-written record. It's fine — expected, even — for the file to be
rewritten wholesale on every collector run; the panel always reads the
current file from disk rather than watching it for incremental changes.

## Top-level shape

All fields except `id` are optional in the sense that the panel tolerates
their absence and falls back to sane defaults (empty/zero/hidden). But a
record that omits everything renders nothing useful, so "optional" here
means "your collector can validly leave this out when it has nothing to
report for it right now" — not "no one should bother."

| Field | Type | Required | Meaning |
|---|---|---|---|
| `id` | string | **yes** | Stable agent id. Must match the filename (`<id>.json`) and use only `[A-Za-z0-9_-]`, 64 chars max. Anything outside that charset gets sanitized/truncated by the panel, so use a clean id from the start. |
| `name` | string | no | Display name shown in the hero and the subscription-switch chips (e.g. `"Claude Code"`). Falls back to `id` when absent. Max 80 chars (longer values are truncated). |
| `brand` | string | no | Which provider's mark this record renders with, when that differs from `id`. This is what makes multiple accounts of one provider first-class: a second Claude login can live in its own record (`"id": "claude-work"`, `"name": "Claude · Work"`) and still get the Claude mark by declaring `"brand": "claude"`. Same charset rules as `id` (`[A-Za-z0-9_-]`, 64 chars max); an unknown brand falls back to the generic glyph exactly like an unknown id, so a typo degrades gracefully. |
| `schemaVersion` | integer | no | Present for forward-compatibility; today's value is `1`. The panel doesn't currently branch on it, but set it so a future breaking change to this contract can. |
| `updatedAt` | string (ISO-8601) | no | When the collector last ran. Not currently rendered directly, but useful for your own debugging and for anything reading these files besides the panel. |
| `ready` | boolean | no | `true` once the collector has produced *some* real signal (either local stats or a working limits/balance probe). Used when merging synced snapshots from other machines; a record with `ready: false` (or absent) contributes nothing to the merged "device is reporting" signal until it flips true. |
| `hasLocalStats` | boolean | no, defaults to `true` | Whether this collector reports local prompt/session/token stats at all (as opposed to a pure remote billing view). Anything other than `false` reads as `true`. |
| `hasPromptStats` | boolean | no, defaults to `true` | Whether prompt/session counts are meaningful for this agent. Set this to `false` when your data source only ever reports tokens (e.g. a billing API with no concept of a "prompt") — the panel then omits "N prompts · M sessions" from the today tooltip instead of showing a misleading `0`. |
| `scope` | string: `"device"` \| `"account"` | no, defaults to `"device"` | Whether the numbers below are local-machine stats (`"device"`, the default — summed across synced devices) or an account-global truth every machine reports identically (`"account"` — merged by taking the widest value instead of summing, so the same account synced from two machines isn't double-counted). Use `"account"` for anything backed by a billing/usage API rather than local transcripts. |
| `tierLabel` | string | no | The plan/tier name shown in the hero line (e.g. `"Max 20x"`, `"Pro"`, `"Prepaid"`). Max 60 chars. |
| `usageStatusText` | string | no | See "Error states" below. When set, this text replaces the plan line in the hero and marks the record as having something to say about a problem. Max 200 chars. |
| `authHelpText` | string | no | See "Error states" below. Longer explanatory text shown in a status card beneath the hero. Max 300 chars. |
| `retryAdvised` | boolean | no | Set this to `true` when your collector failed to reach its remote endpoint for transport reasons (DNS/network down, not a real HTTP error) rather than an auth problem. The panel schedules one retry ~30s later instead of waiting out the full refresh interval, and only for agents that set this flag — one provider's outage doesn't put every other collector on a fast retry loop. |
| `limits` | array of limit windows | no | Rate-limit allowances (session/weekly/model-scoped/etc). See "Limits" below. Mutually meaningful alongside or instead of `balance` — an agent can report neither, either, or (unusually) both. |
| `balance` | object | no | A prepaid credit ledger, for agents billed by consumption rather than a rate-limit window. See "Balance" below. |
| `resetCredits` | object | no | Free full resets the provider granted and the account can redeem. See "Free reset credits" below. |
| `cost` | object | no | An optional, derived estimate of what usage would cost at published API rates — not a real bill. See "Cost" below. |
| `todayPrompts` | integer | no | Number of prompts sent today (local time). Leave at `0`/omit when `hasPromptStats` is `false`. |
| `todaySessions` | integer | no | Number of distinct sessions today. |
| `todayTotalTokens` | integer | no | Total tokens (input + output + cache, however your provider buckets them) consumed today. |
| `todayTokensByModel` | object: `{ "<modelId>": TokenBucket }` | no | Today's per-model token split, using the exact same TokenBucket shape as `modelUsage`. Capped at 100 distinct model ids; extra ones are dropped. This is canonical: do not write legacy scalar totals. |
| `recentDays` | array of `{ "date": "YYYY-MM-DD", "messageCount": integer }` | no | One entry per day, oldest first, ending on today. Despite the field's name, `messageCount` is a **token total for that day**, not a count of messages — this is a legacy name kept for compatibility with older snapshots and must not be reinterpreted. Capped at 31 entries; see `historyDays` below for how many of those entries a collector should actually try to fill. |
| `totalPrompts` | integer | no | All-time (or as-far-back-as-your-source-goes) prompt count. |
| `totalSessions` | integer | no | All-time session count. |
| `activeDays` | integer | no | Count of distinct days with any activity. |
| `activeDates` | array of `"YYYY-MM-DD"` strings | no | The actual set of active dates, used (when present) to union activity across synced devices rather than trusting each device's own `activeDays` count. Capped at 400 entries. |
| `modelUsage` | object: `{ "<modelId>": TokenBucket }` | no | All-time (or as-far-back-as-your-source-goes) token usage per model, broken into the four-field bucket described below. Capped at 100 distinct model ids. |

### TokenBucket shape (used by `todayTokensByModel` and `modelUsage`)

```json
{
  "inputTokens": 0,
  "outputTokens": 0,
  "cacheReadInputTokens": 0,
  "cacheCreationInputTokens": 0
}
```

All four fields are integers, all default to `0` when a source doesn't
distinguish them. If your provider doesn't have a cache-token concept at
all, just report `0` for both cache fields — don't omit them, since the
panel reads them by name for the input/output/cache breakdown shown on
hover.

### Limit window shape (used by `limits`)

```json
{
  "label": "Session (5-hour)",
  "title": "Session",
  "percent": 0.42,
  "resetsAt": "2026-08-23T18:00:00+00:00"
}
```

| Field | Type | Required | Meaning |
|---|---|---|---|
| `label` | string | recommended | Free-text description of the window, e.g. `"Session (5-hour)"`, `"Weekly (7-day)"`, `"30m window"`. Used to infer `title` when `title` is absent, by looking for words like "week"/"7-day"/"month"/"30-day"/"session". Max 80 chars. |
| `title` | string | no | Explicit, already-resolved window name (`"Session"`, `"Weekly"`, `"Monthly"`, or a model name like `"Opus 5 Weekly"` for a model-scoped limit). **Prefer setting this explicitly** — label-sniffing breaks on a label like `"Opus 5 (1M context)"`, where `"1M"` gets misread as a one-minute window. If your allowance is scoped to a specific model, title it `"<model display name> <Window>"` so it reads apart from the account-wide windows. Max 80 chars. |
| `percent` | number, `0.0`-`1.0` | **yes** | Fraction of the allowance used, already normalized to `0.0`-`1.0` (not `0`-`100`). A negative value or a missing field causes the panel to drop that limit entry entirely rather than show a nonsensical number — so omit an entry you can't compute rather than sending a placeholder. |
| `tokenLimit` | integer, > 0 | no | The actual token allowance for this exact window. Only provide it when the provider exposes a real quota, not an inferred conversion from `percent`. Together with token history and `resetsAt`, it enables the panel's token burn-rate projection ("Token trend: exhausted in …"), which then replaces the window-pace run-out for that row. Without it the meter, reset countdown and window pace (below) still work. |
| `resetsAt` | string (ISO-8601, with timezone) | no | When the window resets. Used to render "Resets in 3h 12m" and, on the next run, to decide whether a cached percentage is still valid (a window whose `resetsAt` has already passed is treated as stale and dropped rather than shown as a leftover reading). Omit or leave empty when unknown — the panel then just doesn't show a countdown. |
| `startedAt` | string (ISO-8601, with timezone) | no | The actual start of this exact window. Keep it when the source has it: together with `resetsAt` it gives the window's exact length, which the panel's window pace needs (see below). Do not guess from a label. |

**Window pace.** For each window the panel compares `percent` with how much
of the window's clock had passed when the record was written (`updatedAt`):
a tick on the meter, "12% ahead of pace" / "under pace", and — when the
window's own average rate would reach 100% before `resetsAt` — "Out in 1h 20m
at this rate". This needs the window's length, taken from `startedAt` +
`resetsAt`, or from an explicit `title` of exactly `"Session"` (5 hours) or
one ending in `"Weekly"` (7 days) or `"Daily"` (24 hours). A title the panel
had to infer from `label`, or a calendar-aligned monthly window without
`startedAt`, gets no pace. Pace is also withheld for the first 5% of a
window, and when the record is older than 15 minutes or 10% of the window.
Set `updatedAt` so a carried-forward reading is not judged against the
current clock.

Up to 20 limit entries per record are kept; extras are dropped. The panel
picks the highest-`percent` entry as the "binding" one for the bar's meter
and the alarm state, and separately looks for one titled exactly `"Session"`
to pair with one titled exactly `"Weekly"` as a secondary tick on the same
meter — so if your agent has a genuine session+weekly pair, title them
precisely `"Session"` and `"Weekly"` to get that treatment; anything else
(monthly-only, model-scoped-only, credit-only) just renders as its own row
with no special pairing.

### Balance shape (used by `balance`)

```json
{
  "remaining": 14.32,
  "funded": 20.0,
  "spent": 5.68,
  "currency": "USD",
  "estimated": true
}
```

| Field | Type | Required | Meaning |
|---|---|---|---|
| `remaining` | number, ≥ 0 | **yes** (to make the object count at all) | Remaining credit. A missing or negative value makes the panel treat the whole `balance` object as absent. |
| `funded` | number | no, defaults to `0` | Total credit funded/purchased. When `> 0`, the panel renders a fuel-gauge meter (draining toward empty, the opposite direction from a limit meter) and a "spent of funded" detail line. When `0`/absent, the panel still shows the raw `remaining` figure with no meter. |
| `spent` | number | no, defaults to `0` | Amount spent so far. Only shown when `funded > 0`. |
| `currency` | string (ISO 4217-ish) | no, defaults to `"USD"` | `"USD"`/`"EUR"`/`"GBP"` get a symbol prefix (`$`/`€`/`£`); anything else is shown as `"<CODE> "` followed by the number. Max 10 chars. |
| `estimated` | boolean | no, defaults to `false` | Set this to `true` when `remaining`/`spent` are computed/estimated rather than read from an authoritative ledger endpoint (see the README's Fireworks section for a worked example of when and why to set this). The panel appends "· estimated" to the detail line. |

A prepaid/credit-based agent (no rate-limit windows at all) reports
`balance` and omits `limits`. Reporting both is unusual but not forbidden —
nothing stops an agent from having both a rate limit and a running credit
balance.

### Cost shape (used by `cost`)

```json
{
  "estimateUsd": 12.43,
  "period": "30d",
  "activeDays": 12,
  "byModel": [
    { "model": "claude-sonnet-5", "usd": 8.10, "tokens": 540000000 }
  ],
  "byDay": [
    { "date": "2026-08-22", "usd": 1.02 }
  ]
}
```

An optional block for an agent whose plan doesn't carry a real dollar
figure at all (a subscription rate-limit window, unlike Fireworks'
prepaid `balance`) but whose collector can still work out **what the
underlying usage would have cost at published per-token API rates** — the
same idea as T3 Chat's usage page, which shows what a subscription's usage
would have cost billed à la carte.

**`estimateUsd` is a derived estimate, not a real bill.** It is a number
your collector computes by multiplying token counts by a price list you
maintain yourself; it is never read from an actual invoice or billing
API for a rate-limited plan (if it were, you'd be reporting `balance`
instead). The panel labels this figure "At API prices" (published rates, not a bill)
wherever it's shown, and your collector should do the same anywhere else it
surfaces the number — never present it as "this is what you were charged."

| Field | Type | Required | Meaning |
|---|---|---|---|
| `estimateUsd` | number, ≥ 0 | **yes** (to make the object count at all) | The headline derived estimate for `period`, in US dollars. A missing or negative value makes the panel treat the whole `cost` object as absent, the same convention `balance.remaining` uses. |
| `period` | string | no | Free-text label for the window `estimateUsd` covers, e.g. `"30d"`, `"This month"`, `"All time"`. Shown next to the estimate; omit it if your estimate doesn't have a clean window. Max 20 chars. |
| `pricingVersion` | string | recommended | Version of the rate catalogue used to compute this estimate (for the bundled estimator, e.g. `"2026-08-23"`). This makes a cached estimate auditable after a price update. |
| `incomplete` | boolean | no | `true` only when this is a partial subtotal: at least one used model has no published API rate. The panel labels it **partial** and names the excluded models. |
| `unknownModels` | array of strings | required when `incomplete` | Model ids excluded from the subtotal because no exact price is known. Capped at 20 for display. |
| `pricedTokens` / `unpricedTokens` | integers, ≥ 0 | no | Auditable token coverage for a partial subtotal. |
| `activeDays` | integer, ≥ 0 | no | Number of distinct recorded usage days covered by the aggregate estimate. Used only to calculate an average when `byDay` is unavailable; it is not a subscription quota. |
| `byModel` | array of `{ "model": string, "usd": number, "tokens": integer }` | no | Per-model breakdown of the same estimate. Capped at 100 entries; a negative `usd` reads as `0`. |
| `byDay` | array of `{ "date": "YYYY-MM-DD", "usd": number }` | no | Per-day breakdown of the same estimate, meant to line up with `recentDays`. Capped at 31 entries; a negative `usd` reads as `0`. |

Like `limits` and `balance`, `cost` is per-account and is never merged or
summed across synced devices — the panel always reads it straight off the
selected device's own record.

The expanded Details view separates three different facts for every enabled
provider: the provider's subscription quota (`limits`), a real prepaid API
ledger (`balance`), and the optional published-rate equivalent (`cost`). The
compact view renders none of this derived accounting. A missing `cost` is
shown as unavailable, never as `$0`; that means the provider did not expose
enough model/token data for an honest API equivalent. `byModel` powers the
model bars and `byDay`, when present, powers the daily chart. If `byDay` is
absent, `activeDays` supports an explicitly labelled recorded-day average
instead of a fabricated daily series. A collector that computes `cost` must
identify the price-list version/source in its own documentation and must never
present the estimate as a provider invoice. The supported companion collectors
package lives in this repository now; third-party collectors remain welcome
too — see `CONTRIBUTING.md`.

The reusable, versioned estimator is [`logic/cost.js`](../logic/cost.js),
with its official-rate catalogue in
[`logic/api-price-catalogue.js`](../logic/api-price-catalogue.js). It is
intended for the Claude and Codex transcript collectors. When a transcript
has both priced and unknown models, it emits a clearly marked partial subtotal
with `unknownModels`; when every used model is unknown it emits no cost at all.
It never guesses a price from a similarly named model.

## Free reset credits

```json
{
  "available": 3,
  "nextExpiresAt": "2026-12-10T22:00:00Z",
  "expiries": ["2026-12-10T22:00:00Z", "2026-12-15T17:00:00Z", ""]
}
```

- `available` is the count at collection time, capped at 99. Omit the
  block when the account has no redeemable credits.
- `expiries` lists one timestamp per credit, including repeated timestamps.
  Use ISO-8601 with an explicit time zone and `""` when the provider has
  no date for a credit. Keep `nextExpiresAt` as the earliest known expiry
  (or `""`) for older clients.
- For older records that only have `nextExpiresAt`, Usage displays that
  date and marks the remaining dates as unreported. The panel removes known
  expired credits from the list and the count while open.
- Reset credits belong to the selected account's local record. They appear
  in Usage and are omitted from sync snapshots and the bar. The bundled
  compatibility collectors report them for Claude and Codex.


## Error states

Two conventions exist today, matching what Claude's and Codex's own
collectors do — reuse them exactly so the panel shows the right message
rather than a generic one:

- **Auth missing / expired.** Set `usageStatusText` to something short like
  `"Waiting for auth"` or `"Sign-in expired"`, and `authHelpText` to a
  longer, actionable sentence (e.g. `"Run `your-cli auth login` to restore
  authoritative usage."`). Leave `limits`/`balance` empty, or — better —
  keep serving the last known-good values you have cached, since a window
  that hasn't reset yet is still a true reading. Do **not** set
  `retryAdvised` for this case: an auth problem doesn't resolve itself on a
  30-second timer the way a network hiccup might, so the panel just leaves
  it to the normal refresh interval (and to the user fixing their
  credentials).
- **Endpoint unreachable (transport failure).** Same two text fields
  (`usageStatusText` like `"<Agent> limits unavailable"`, `authHelpText`
  with the underlying reason), but this time also set `"retryAdvised":
  true`. This is specifically for "no route to the server at all" failures
  — DNS failure, connection refused, timeout with no response — as opposed
  to the server answering with a real HTTP error status. The panel honors
  this by re-running your collector's limits probe roughly 30 seconds
  later instead of waiting for the next full refresh cycle, which matters
  most right after login before the network is fully up. A real HTTP error
  response (429 rate-limited, 5xx, etc.) is *not* a transport failure in
  this sense — report it via `usageStatusText`/`authHelpText` without
  `retryAdvised`, since hammering a server that answered with "no" every
  30 seconds is the wrong response.

In both cases, keep reporting whatever local stats (`todayPrompts`,
`recentDays`, `modelUsage`, etc.) you can still compute independent of the
failing remote call — an auth or network problem with the limits endpoint
shouldn't blank out numbers that came from local transcripts or a separate,
working code path.

A bundled collector gets this for the remote-only fields too
(`limits`/`balance`/`cost`/`todayPrompts`/`recentDays`/`modelUsage`) without
doing anything extra: build your problem record with `auth_missing()` or
`endpoint_problem()` from `agent_usage_collectors.common`, and they carry
forward the last successfully-read value for any of those fields your fresh
record doesn't set, reusing its original `updatedAt` too — a lower refresh
interval hitting a rate limit reads as "the number hasn't moved since
&lt;time&gt;", not as a blank meter. A third-party collector that builds its
problem record by hand should do the same against its own last-published
`<id>.json`.

When everything is fine, leave `usageStatusText` and `authHelpText` as
empty strings (or omit them) — a non-empty `usageStatusText` is exactly
what tells the panel to show a problem state instead of the normal plan
line.

## Icons

An icon is optional; without one the panel falls back to its own generic
bar glyph. To ship one:

- `assets/<id>.svg` — the default mark, used on dark/normal panel surfaces.
- `assets/<id>-light.svg` — optional twin for a mark that needs a
  different (typically dark-on-light) rendering when the active surface is
  light. Ship this only if your mark doesn't already work on both — a
  mark using a fixed brand color that reads fine on any background (like
  Claude's brand orange) doesn't need one.

`<id>` here is exactly the same id as the record's `id` field and the
`<id>.json` filename. Add the new file name to `Panel.qml`'s
`providerIconAssets` registry in the same change: QML otherwise has no safe
way to test a relative asset URL before loading it, and a missing URL becomes
a runtime warning. The panel resolves a registered `-light` twin first on a
light surface (by relative luminance ≥ 0.5), then the registered default;
an unregistered provider deliberately falls back to a plain glyph without
attempting an asset URL. `<id>` is re-validated against
`[A-Za-z0-9_-]{1,64}` at the point these paths are considered.

These asset files live in *this repository* (`assets/`), not with your
collector — since a third-party collector, by design, never touches this
repo, shipping a new icon here requires a small contribution (see the
planned icon registry/`CONTRIBUTING.md` work) rather than being something
your collector can drop in on its own. Until then, an agent without a
shipped icon simply uses the fallback glyph, which is a fully supported,
unremarkable state.

## Settings note (what's *not* part of this contract)

Everything in `manifest.json`'s `providers.<id>` settings block —
`enabled` and `showInBar` — is configuration the *user* sets for the widget, not something
a collector writes into its own record. Most of the display/settings work
(per-provider bar visibility, bar display modes, warning/critical color
thresholds, the expandable panel view, or the in-panel settings editor)
changes nothing about what a collector is expected to report — it all
operates purely on the record shape documented above. If a future change
does add a collector-facing field for one of those, it'll be added to the
tables above rather than requiring a second contract document.

The one exception so far is `historyDays` (manifest schema, default `30`,
range 7-90): it is a *hint to collector authors*, not something the panel
enforces or fetches on its own. The panel only ever reads whatever is
already sitting in a record's `recentDays` array (capped at 31 entries —
see above) and draws the expanded history view from the days actually
present. It never asks a collector for more history or invents a longer
range; if a collector has no usable history, the panel says so explicitly.
`historyDays` exists purely so a collector author knows roughly how many days
of `recentDays` history is worth writing.

## Minimal valid example

The smallest record that renders something sane — a name, no limits or
balance yet, some tokens for today:

```json
{
  "id": "example",
  "name": "Example Agent",
  "ready": true,
  "todayTotalTokens": 1234,
  "todayTokensByModel": {
    "example-model-v1": {
      "inputTokens": 1234,
      "outputTokens": 0,
      "cacheReadInputTokens": 0,
      "cacheCreationInputTokens": 0
    }
  }
}
```

This shows up in the panel with the hero mark/name, a "Subscription" plan
line (the generic fallback for a missing `tierLabel`), no limits/balance
section, and a "Tokens by day"/"Tokens by model" section limited to
whatever `recentDays`/`modelUsage` you also provide (both omitted here, so
those sections simply don't render).

## Complete example

Exercises every field above, including a model-scoped limit, a live
(non-estimated) balance shown alongside limits (unusual, but valid), the
full week of token history, and a synced-friendly `activeDates` list:

```json
{
  "schemaVersion": 1,
  "id": "example",
  "name": "Example Agent",
  "updatedAt": "2026-08-23T09:00:00+00:00",
  "ready": true,
  "hasLocalStats": true,
  "hasPromptStats": true,
  "scope": "device",
  "tierLabel": "Pro 20x",
  "usageStatusText": "",
  "authHelpText": "",
  "limits": [
    {
      "label": "Session (5-hour)",
      "title": "Session",
      "percent": 0.42,
      "tokenLimit": 500000,
      "startedAt": "2026-08-23T13:00:00+00:00",
      "resetsAt": "2026-08-23T18:00:00+00:00"
    },
    {
      "label": "Weekly (7-day)",
      "title": "Weekly",
      "percent": 0.61,
      "resetsAt": "2026-08-27T00:00:00+00:00"
    },
    {
      "label": "Opus 5 (1M context) Weekly",
      "title": "Opus 5 Weekly",
      "percent": 0.18,
      "resetsAt": "2026-08-27T00:00:00+00:00"
    }
  ],
  "balance": {
    "remaining": 14.32,
    "funded": 20.0,
    "spent": 5.68,
    "currency": "USD",
    "estimated": false
  },
  "cost": {
    "estimateUsd": 12.43,
    "period": "30d",
    "byModel": [
      { "model": "example-model-v1", "usd": 8.10, "tokens": 96000000 },
      { "model": "example-model-v1-mini", "usd": 4.33, "tokens": 32000000 }
    ],
    "byDay": [
      { "date": "2026-08-22", "usd": 1.02 },
      { "date": "2026-08-23", "usd": 0.87 }
    ]
  },
  "todayPrompts": 37,
  "todaySessions": 4,
  "todayTotalTokens": 128000,
  "todayTokensByModel": {
    "example-model-v1": { "inputTokens": 96000, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0 },
    "example-model-v1-mini": { "inputTokens": 32000, "outputTokens": 0, "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0 }
  },
  "recentDays": [
    { "date": "2026-08-17", "messageCount": 210000 },
    { "date": "2026-08-18", "messageCount": 185000 },
    { "date": "2026-08-19", "messageCount": 0 },
    { "date": "2026-08-20", "messageCount": 240000 },
    { "date": "2026-08-21", "messageCount": 199000 },
    { "date": "2026-08-22", "messageCount": 260000 },
    { "date": "2026-08-23", "messageCount": 128000 }
  ],
  "totalPrompts": 5210,
  "totalSessions": 340,
  "activeDays": 58,
  "activeDates": [
    "2026-06-01", "2026-06-02", "2026-08-21", "2026-08-22", "2026-08-23"
  ],
  "modelUsage": {
    "example-model-v1": {
      "inputTokens": 4200000,
      "outputTokens": 1800000,
      "cacheReadInputTokens": 900000,
      "cacheCreationInputTokens": 150000
    },
    "example-model-v1-mini": {
      "inputTokens": 1100000,
      "outputTokens": 400000,
      "cacheReadInputTokens": 0,
      "cacheCreationInputTokens": 0
    }
  }
}
```

An auth-missing variant of the same agent (limits section falls back to
whatever was last cached, or empty if there's nothing cached yet):

```json
{
  "id": "example",
  "name": "Example Agent",
  "ready": false,
  "hasLocalStats": true,
  "tierLabel": "Pro 20x",
  "usageStatusText": "Waiting for auth",
  "authHelpText": "Run `example-cli auth login` to restore authoritative usage.",
  "limits": [],
  "todayTotalTokens": 0
}
```

A transport-failure variant (network unreachable, worth a fast retry):

```json
{
  "id": "example",
  "name": "Example Agent",
  "ready": true,
  "hasLocalStats": true,
  "tierLabel": "Pro 20x",
  "usageStatusText": "Example limits unavailable",
  "authHelpText": "Couldn't reach Example's usage endpoint. Retrying shortly. Local stats are still shown.",
  "retryAdvised": true,
  "limits": [],
  "todayTotalTokens": 128000
}
```
