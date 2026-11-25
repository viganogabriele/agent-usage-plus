// Versioned standard API prices, in USD per one million tokens.
// Update this file in one reviewable commit whenever a provider changes a
// rate. `source` URLs are primary provider documentation; update the
// `publishedAt` date and affected model entry together.

var PRICE_CATALOGUE = {
  version: "2026-09-29",
  currency: "USD",
  unit: "per-1m-tokens",
  providers: {
    claude: {
      source: "https://platform.claude.com/docs/en/about-claude/pricing",
      publishedAt: "2026-09-29",
      // cacheCreationInputTokens has no TTL in the record contract. The
      // normal 5-minute cache-write rate is therefore the only defensible
      // default; collectors with 1-hour cache data must not reuse this
      // estimate without a future TTL-aware contract field.
      models: {
        // Current Claude Code transcript ids. Rates are first-party Claude
        // API standard rates, not the subscription price or a cloud-reseller
        // regional/fast-mode surcharge.
        "claude-opus-5-5": { input: 4, output: 20, cacheRead: 0.2, cacheWrite: 5 },
        "claude-sonnet-5-5": { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 },
        "claude-opus-5": { input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25 },
        "claude-sonnet-5": { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 },
        "claude-haiku-4-5-20251001": { input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25 },
        "claude-opus-4-20250514": { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 },
        "claude-opus-4-1-20250805": { input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75 },
        "claude-sonnet-4-20250514": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
        "claude-3-7-sonnet-20250219": { input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75 },
        "claude-3-5-haiku-20241022": { input: 0.8, output: 4, cacheRead: 0.08, cacheWrite: 1 }
      }
    },
    codex: {
      source: "https://developers.openai.com/api/docs/pricing",
      publishedAt: "2026-09-29",
      // GPT-5.6 and later charge cache writes at 1.25x input. The model map
      // intentionally uses exact transcript ids, never fuzzy matching.
      // These are standard short-context rates; transcripts do not identify
      // long-context or faster processing tiers.
      models: {
        "gpt-6-astra": { input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5 },
        "gpt-6-sol": { input: 2, output: 10, cacheRead: 0.2, cacheWrite: 2.5 },
        "gpt-6-luna": { input: 0.1, output: 0.5, cacheRead: 0.01, cacheWrite: 0.125 },
        "gpt-5.6-sol": { input: 4, output: 20, cacheRead: 0.4, cacheWrite: 5 },
        "gpt-5.6-terra": { input: 2, output: 12, cacheRead: 0.2, cacheWrite: 2.5 },
        "gpt-5.6-luna": { input: 0.2, output: 1.2, cacheRead: 0.02, cacheWrite: 0.25 },
        "gpt-5.5": { input: 5, output: 30, cacheRead: 0.5, cacheWrite: 5 },
        "gpt-5.3-codex": { input: 1.75, output: 14, cacheRead: 0.175, cacheWrite: 1.75 },
        "gpt-5-codex": { input: 1.25, output: 10, cacheRead: 0.125, cacheWrite: 1.25 }
      }
    }
  }
}

if (typeof module !== "undefined" && module.exports) module.exports = PRICE_CATALOGUE
