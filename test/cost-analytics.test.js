"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")

const CostAnalytics = require("../logic/cost-analytics.js")

test("modelRows ranks model spend and adds chart shares", () => {
  const rows = CostAnalytics.modelRows({
    byModel: [
      { model: "small", usd: 2.25, tokens: 100 },
      { model: "top", usd: 7.25, tokens: 500 },
      { model: "", usd: 100, tokens: 1 },
      { model: "broken", usd: -1, tokens: 0 },
    ],
  })

  assert.deepEqual(rows.map((row) => row.model), ["top", "small", "broken"])
  assert.equal(rows[0].usd, 7.25)
  assert.equal(rows[0].share, 7.25 / 9.5)
  assert.equal(rows[2].usd, 0)
})

test("dailyRows sorts dates, drops blank labels, and combines duplicate days", () => {
  const rows = CostAnalytics.dailyRows({
    byDay: [
      { date: "2026-08-30", usd: 1.5 },
      { date: "2026-08-28", usd: 0.5 },
      { date: "2026-08-28", usd: 0.25 },
      { date: "", usd: 100 },
      { date: "2026-08-29", usd: -1 },
    ],
  })

  assert.deepEqual(rows, [
    { date: "2026-08-28", usd: 0.75 },
    { date: "2026-08-29", usd: 0 },
    { date: "2026-08-30", usd: 1.5 },
  ])
})

test("summary exposes useful totals, active-day average, peak, and price coverage", () => {
  const result = CostAnalytics.summary({
    estimateUsd: 10,
    pricedTokens: 900,
    unpricedTokens: 100,
    byModel: [{ model: "top", usd: 10, tokens: 900 }],
    byDay: [
      { date: "2026-08-28", usd: 0.75 },
      { date: "2026-08-29", usd: 0 },
      { date: "2026-08-30", usd: 1.5 },
    ],
  })

  assert.equal(result.totalUsd, 10)
  assert.equal(result.dailyTotalUsd, 2.25)
  assert.equal(result.dailyPeakUsd, 1.5)
  assert.equal(result.dailyActiveDays, 2)
  assert.equal(result.averageDailyUsd, 1.125)
  assert.equal(result.coverage, 0.9)
  assert.equal(result.totalTokens, 1000)
  assert.equal(result.topModel, "top")
})

test("summary derives avg daily from recorded active days when byDay is unavailable", () => {
  const result = CostAnalytics.summary({
    estimateUsd: 12,
    byModel: [{ model: "top", usd: 12, tokens: 1200 }],
    byDay: [],
  }, { activeDays: 4 })

  assert.equal(result.averageDailyUsd, 3)
  assert.equal(result.averageDailyDays, 4)
  assert.equal(result.dailySource, "recorded-days")
  assert.equal(result.hasDailyAverage, true)
})

test("providerRows keeps every provider and separates plan usage from API estimates", () => {
  const rows = CostAnalytics.providerRows([
    {
      providerId: "claude",
      providerName: "Claude",
      limits: [{ title: "Session", percent: 0.61 }],
      cost: { estimateUsd: 10, incomplete: false },
    },
    {
      providerId: "codex",
      providerName: "Codex",
      limits: [{ title: "Weekly", percent: 0.27 }],
      cost: null,
    },
    {
      providerId: "gemini",
      providerName: "Gemini",
      balance: { remaining: 8.5, funded: 10, spent: 1.5, currency: "USD" },
      cost: { estimateUsd: 2, incomplete: true },
    },
  ])

  assert.deepEqual(rows.map((row) => row.providerId), ["claude", "codex", "gemini"])
  assert.equal(rows[0].share, 10 / 12)
  assert.equal(rows[0].subscriptionPercent, 0.61)
  assert.equal(rows[1].hasCost, false)
  assert.equal(rows[1].subscriptionPercent, 0.27)
  assert.equal(rows[2].balanceRemaining, 8.5)
  assert.ok(Math.abs(rows[2].balanceUsedPercent - 0.15) < 1e-9)
  assert.equal(rows[2].incomplete, true)
})

test("providerRows reports usageKind 'none' for a cost-only provider with no limits or balance", () => {
  const rows = CostAnalytics.providerRows([
    {
      providerId: "openrouter",
      providerName: "OpenRouter",
      cost: { estimateUsd: 4.2, incomplete: false },
    },
  ])

  assert.equal(rows[0].usageKind, "none")
  assert.equal(rows[0].usageTitle, "Usage")
  assert.equal(rows[0].usagePercent, -1)
  assert.equal(rows[0].hasCost, true)
  assert.equal(rows[0].estimateUsd, 4.2)
})
