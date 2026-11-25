"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const Insights = require("../logic/insights.js")

const HOUR = 3600 * 1000
const DAY = 24 * HOUR
const now = Date.parse("2026-11-25T12:00:00Z")
const iso = (ms) => new Date(ms).toISOString()

function days(values, endIso) {
  const end = Date.parse(endIso + "T00:00:00Z")
  return values.map((v, i) => ({
    date: new Date(end - (values.length - 1 - i) * DAY).toISOString().slice(0, 10),
    messageCount: v
  }))
}

test("windowSpanMs: explicit startedAt/resetAt wins over the title", () => {
  const span = Insights.windowSpanMs({ title: "Weekly", startedAt: iso(now - HOUR), resetAt: iso(now + HOUR) })
  assert.equal(span, 2 * HOUR)
})

test("windowSpanMs: known titles, including model-scoped weekly", () => {
  assert.equal(Insights.windowSpanMs({ title: "Session" }), 5 * HOUR)
  assert.equal(Insights.windowSpanMs({ title: "Weekly" }), 7 * DAY)
  assert.equal(Insights.windowSpanMs({ title: "Opus Weekly" }), 7 * DAY)
  assert.equal(Insights.windowSpanMs({ title: "Daily" }), DAY)
  assert.equal(Insights.windowSpanMs({ title: "Monthly" }), 30 * DAY)
})

test("windowSpanMs: unknown titles return 0 rather than a guess", () => {
  assert.equal(Insights.windowSpanMs({ title: "Opus 5 (1M context)" }), 0)
  assert.equal(Insights.windowSpanMs({ title: "Credits" }), 0)
  assert.equal(Insights.windowSpanMs(null), 0)
})

test("windowPace: half-way through a session at 70% is over pace and runs out before reset", () => {
  const pace = Insights.windowPace({ title: "Session", percent: 0.7, resetAt: iso(now + 2.5 * HOUR) }, now)
  assert.ok(pace)
  assert.equal(pace.elapsed, 0.5)
  assert.equal(pace.status, "over")
  assert.ok(Math.abs(pace.delta - 0.2) < 1e-9)
  assert.ok(Math.abs(pace.projected - 1.4) < 1e-9)
  // 70% in 2.5h -> remaining 30% takes 2.5h * 30/70 ≈ 1.07h, before the 2.5h reset.
  assert.ok(Math.abs(pace.runsOutInMs - 2.5 * HOUR * 0.3 / 0.7) < 1)
  assert.equal(pace.resetInMs, 2.5 * HOUR)
})

test("windowPace: under pace never reports a run-out", () => {
  const pace = Insights.windowPace({ title: "Weekly", percent: 0.2, resetAt: iso(now + 3.5 * DAY) }, now)
  assert.equal(pace.status, "under")
  assert.equal(pace.runsOutInMs, -1)
})

test("windowPace: within ±5 points of the clock is on pace", () => {
  const pace = Insights.windowPace({ title: "Weekly", percent: 0.52, resetAt: iso(now + 3.5 * DAY) }, now)
  assert.equal(pace.status, "on")
})

test("windowPace: zero usage reads idle", () => {
  const pace = Insights.windowPace({ title: "Session", percent: 0, resetAt: iso(now + 2 * HOUR) }, now)
  assert.equal(pace.status, "idle")
  assert.equal(pace.runsOutInMs, -1)
})

test("windowPace: withheld for unknown span, passed reset, missing percent, or a just-started window", () => {
  assert.equal(Insights.windowPace({ title: "Credits", percent: 0.5, resetAt: iso(now + HOUR) }, now), null)
  assert.equal(Insights.windowPace({ title: "Session", percent: 0.5, resetAt: iso(now - HOUR) }, now), null)
  assert.equal(Insights.windowPace({ title: "Session", percent: -1, resetAt: iso(now + HOUR) }, now), null)
  assert.equal(Insights.windowPace({ title: "Session", percent: 0.1, resetAt: iso(now + 4.9 * HOUR) }, now), null)
  assert.equal(Insights.windowPace({ title: "Session", percent: 0.1, resetAt: "" }, now), null)
})

test("windowPace: a full window has already run out", () => {
  const pace = Insights.windowPace({ title: "Session", percent: 1, resetAt: iso(now + HOUR) }, now)
  assert.equal(pace.runsOutInMs, 0)
})

test("activityStats: streak, best day, and averages", () => {
  // 14 days ending today; today = 300, previous 7 average = 100.
  const values = [50, 50, 50, 50, 50, 50, 50, 100, 100, 100, 100, 100, 100, 100].concat([300])
  const stats = Insights.activityStats(days(values, "2026-11-25"), "2026-11-25")
  assert.equal(stats.today, 300)
  assert.equal(stats.streak, 15)
  assert.deepEqual(stats.best, { date: "2026-11-25", value: 300 })
  assert.equal(stats.avg7, 100)
  assert.equal(stats.todayVsAvg, 2)
  // Last 7 days: 6×100 + 300 = 900. Previous 7: 6×50 + 100 = 400.
  assert.equal(stats.weekChange, 900 / 400 - 1)
  assert.equal(stats.activeDays, 15)
})

test("activityStats: a streak survives a quiet morning but breaks on a gap", () => {
  const quietToday = Insights.activityStats(days([10, 10, 10, 0], "2026-11-25"), "2026-11-25")
  assert.equal(quietToday.streak, 3)
  const gap = Insights.activityStats(days([10, 0, 10, 10], "2026-11-25"), "2026-11-25")
  assert.equal(gap.streak, 2)
})

test("activityStats: short history withholds averages instead of inventing them", () => {
  const stats = Insights.activityStats(days([10, 20, 30], "2026-11-25"), "2026-11-25")
  assert.equal(stats.avg7, -1)
  assert.equal(stats.todayVsAvg, null)
  assert.equal(stats.weekChange, null)
})

test("activityStats: empty and malformed input", () => {
  const stats = Insights.activityStats([{ date: "bad", messageCount: 5 }, null], "2026-11-25")
  assert.equal(stats.total, 0)
  assert.equal(stats.best, null)
  assert.equal(stats.streak, 0)
})

test("heatmapGrid: ends on the week containing today, Monday first", () => {
  // 2026-11-25 is a Wednesday.
  const grid = Insights.heatmapGrid(days([1, 2, 3, 4, 8], "2026-11-25"), "2026-11-25", 3)
  assert.equal(grid.weeks.length, 3)
  const last = grid.weeks[2]
  assert.equal(last[0].date, "2026-11-23") // Monday
  assert.equal(last[2].date, "2026-11-25")
  assert.equal(last[2].today, true)
  assert.equal(last[2].level, 4)
  assert.equal(last[3].future, true)
  assert.equal(last[3].level, 0)
  assert.equal(grid.peak, 8)
  // A day outside the record is flagged missing, not a real zero.
  assert.equal(grid.weeks[0][0].missing, true)
})

test("heatmapGrid: levels are quartiles of the peak", () => {
  const grid = Insights.heatmapGrid(days([1, 25, 50, 75, 100], "2026-11-25"), "2026-11-25", 1)
  const levels = grid.weeks[0].slice(0, 3).map((c) => c.level)
  assert.deepEqual(levels, [2, 3, 4])
})

test("tokenMix: sums buckets and computes cache hit rate", () => {
  const mix = Insights.tokenMix({
    a: { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 80, cacheCreationInputTokens: 10 },
    b: { inputTokens: 0, outputTokens: 5, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 }
  })
  assert.equal(mix.total, 110)
  assert.equal(mix.output, 10)
  assert.equal(mix.cacheHitRate, 0.8)
  assert.equal(Insights.tokenMix({}).cacheHitRate, -1)
})

test("formatChange: signed whole percentages", () => {
  assert.equal(Insights.formatChange(0.234), "+23%")
  assert.equal(Insights.formatChange(-0.05), "−5%")
  assert.equal(Insights.formatChange(0.001), "±0%")
  assert.equal(Insights.formatChange(null), "")
})
