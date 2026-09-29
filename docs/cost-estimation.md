# Transcript API-cost estimation

`logic/cost.js` is the shared, dependency-free interface for Claude and
Codex collectors. It consumes the same `TokenBucket` shape written to usage
records and returns the contract-ready `cost` block. A complete executable
input/expected-output example lives in
[`test/fixtures/claude-cost-estimation.json`](../test/fixtures/claude-cost-estimation.json).

```js
const Cost = require("/path/to/agent-usage-plus/logic/cost.js")
const result = Cost.calculateCost({
  provider: "claude", // or "codex"
  period: "30d",
  modelUsage,          // { modelId: TokenBucket }
  activeDays,          // optional distinct recorded usage days
  dailyModelUsage      // optional { "YYYY-MM-DD": { modelId: TokenBucket } }
})

if (result.cost) {
  record.cost = result.cost // `incomplete` means the subtotal excludes unknown models
} else {
  delete record.cost
  record.usageStatusText = "API cost estimate needs a price update"
  record.authHelpText = "No published API rate is catalogued for: " + result.unknownModels.join(", ")
}
```

Python (or shell) collectors can use the equivalent stable bridge instead
of duplicating pricing logic:

```sh
printf '%s' "$input_json" | /path/to/agent-usage-plus/scripts/calculate-api-cost
```

Parse the returned JSON; copy its `cost` to the record only when non-null,
and handle `unknownModels` as above.

If at least one model has an exact price, the result may be an explicitly
marked partial subtotal: `cost.incomplete` is `true`, `unknownModels` names
the excluded models, and the panel says so. If every used model is unknown,
`cost` remains absent — never publish a fabricated `$0` estimate. Store
`pricingVersion` with the output so a cached record is auditable after prices
change. The wrapper also passes the base collector's `activeDays` through to
the cost block. When `byDay` is unavailable, the Details view uses
`estimateUsd / activeDays` for **Avg / recorded day** and says explicitly that
the value is derived; it never invents a day-by-day chart.

The catalogue uses standard, non-batch USD API rates per million tokens and
is versioned in `logic/api-price-catalogue.js`. Update its version,
`publishedAt`, source URL, and exact model entry in one reviewable change.
Anthropic cache writes use the standard five-minute write rate because the
record does not carry cache TTL; a collector with one-hour write usage must
not estimate it until the contract can distinguish it. OpenAI GPT-5.6 and
later cache writes use 1.25 times the standard input rate. The estimate uses
standard short-context rates: transcript totals do not reveal request-level
context length, processing tier, or region, so those adjustments cannot be
reconstructed. Unknown model ids are never pattern-matched.

## Collectors with their own price source

`logic/cost.js` and `logic/api-price-catalogue.js` are Claude/Codex-specific.
A collector pricing usage from a different provider's own catalogue (e.g. an
OpenRouter-style collector reading `GET /v1/models` pricing) cannot reuse that
wrapper, but must still uphold the same honesty rule by hand: a model with no
matching catalogue entry is **unpriced**, not free. Never fold it into the
subtotal at a `0` rate — track it separately, set `cost.incomplete = true`,
list it in `cost.unknownModels`, and split `pricedTokens`/`unpricedTokens`
accordingly, exactly as the contract in `docs/collector-contract.md` requires.

Once a collector emits a contract-shaped `cost` block (`byModel`/`byDay`,
`incomplete`/`unknownModels` when partial), it needs no display code of its
own: `logic/cost-analytics.js` and the Details panel already render any
provider's `cost` data — model/day breakdowns, partial-subtotal disclosure,
and price coverage — generically. Don't add a second, provider-specific
model-cost UI or a parallel record field for this; extend the shared
analytics/UI instead if it's missing something you need.
