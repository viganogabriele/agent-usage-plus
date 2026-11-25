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
})

test("windowSpanMs: calendar-aligned monthly windows need startedAt", () => {
  assert.equal(Insights.windowSpanMs({ title: "Monthly" }), 0)
  const span = Insights.windowSpanMs({ title: "Monthly", startedAt: "2026-02-01T00:00:00Z", resetAt: "2026-03-01T00:00:00Z" })
  assert.equal(span, 28 * DAY)
})

test("windowSpanMs: a title derived from a label is never trusted", () => {
  // The panel files "30m window" and "Opus 5 (1M context)" under "Session";
  // without an explicit collector title that must not become 5 hours.
  assert.equal(Insights.windowSpanMs({ title: "Session", titleExplicit: false }), 0)
  assert.equal(Insights.windowSpanMs({ title: "Session", titleExplicit: true }), 5 * HOUR)
})

test("windowSpanMs: an explicit startedAt beats a title that disagrees", () => {
  const span = Insights.windowSpanMs({ title: "Session", startedAt: iso(now - 20 * 60000), resetAt: iso(now + 10 * 60000) })
  assert.equal(span, 30 * 60000)
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
  // Complete days only: the 7 days before today (7×100) vs the 7 before
  // those (7×50).
  assert.equal(stats.weekChange, 700 / 350 - 1)
  assert.equal(stats.hasToday, true)
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

test("activityStats: a quiet morning does not read as a quieter week", () => {
  // Steady 100/day for 14 days, 10 tokens so far today.
  const values = Array(14).fill(100).concat([10])
  const stats = Insights.activityStats(days(values, "2026-11-25"), "2026-11-25")
  assert.equal(stats.weekChange, 0)
})

test("activityStats: a record ending yesterday withholds the today comparison", () => {
  const stats = Insights.activityStats(days(Array(10).fill(100), "2026-11-24"), "2026-11-25")
  assert.equal(stats.hasToday, false)
  assert.equal(stats.todayVsAvg, null)
  assert.equal(stats.streak, 10)
})

test("windowPace: percent above 100% is reported as run out", () => {
  const pace = Insights.windowPace({ title: "Session", percent: 1.3, resetAt: iso(now + HOUR) }, now)
  assert.equal(pace.runsOutInMs, 0)
  assert.equal(pace.status, "over")
})

test("windowPace: elapsed is taken when the reading was made, not now", () => {
  const window = { title: "Session", percent: 0.5, resetAt: iso(now + 2.5 * HOUR) }
  // Read 10 minutes ago: at that moment 2h20m of the 5h window had passed.
  const pace = Insights.windowPace(window, now, now - 10 * 60000)
  assert.ok(Math.abs(pace.elapsed - (140 / 300)) < 1e-9)
  assert.equal(pace.resetInMs, 2.5 * HOUR)
})

test("windowPace: a reading too old to project from returns null", () => {
  const window = { title: "Session", percent: 0.5, resetAt: iso(now + 2.5 * HOUR) }
  assert.equal(Insights.windowPace(window, now, now - 2 * HOUR), null)
  // A week-long window tolerates a proportionally older reading.
  const weekly = { title: "Weekly", percent: 0.5, resetAt: iso(now + 3 * DAY) }
  assert.ok(Insights.windowPace(weekly, now, now - 2 * HOUR))
})

test("firstRunOut: picks the window that empties first, not the fullest", () => {
  const windows = [
    // Fullest, but comfortably under pace.
    { title: "Weekly", percent: 0.6, resetAt: iso(now + 2.1 * DAY) },
    // Emptier, but burning fast: 45% after 30 minutes of a 5h window.
    { title: "Session", percent: 0.45, resetAt: iso(now + 4.5 * HOUR) }
  ]
  const result = Insights.firstRunOut(windows, now)
  assert.equal(result.window.title, "Session")
  assert.ok(result.pace.runsOutInMs > 0 && result.pace.runsOutInMs < HOUR)
  assert.equal(Insights.firstRunOut([windows[0]], now), null)
  assert.equal(Insights.firstRunOut([{ title: "Session", percent: 1, resetAt: iso(now + HOUR) }], now), null)
})

test("heatmapGrid: today on a Monday and on a Sunday", () => {
  const monday = Insights.heatmapGrid(days([1], "2026-11-23"), "2026-11-23", 1)
  assert.equal(monday.weeks[0][0].today, true)
  assert.equal(monday.weeks[0][1].future, true)
  const sunday = Insights.heatmapGrid(days([1], "2026-11-29"), "2026-11-29", 1)
  assert.equal(sunday.weeks[0][6].today, true)
  assert.equal(sunday.weeks[0][0].date, "2026-11-23")
})

test("heatmapGrid: a day after today that has data is shown, not hidden", () => {
  const grid = Insights.heatmapGrid(days([5, 9], "2026-11-26"), "2026-11-25", 1)
  const tomorrow = grid.weeks[0][3]
  assert.equal(tomorrow.date, "2026-11-26")
  assert.equal(tomorrow.future, false)
  assert.equal(tomorrow.level, 4)
  assert.equal(grid.peak, 9)
})

test("heatmapGrid: month and leap-day boundaries", () => {
  const grid = Insights.heatmapGrid(days([1, 2, 3], "2028-03-01"), "2028-03-01", 2)
  const flat = grid.weeks.flat().map((c) => c.date)
  assert.ok(flat.includes("2028-02-29"))
  assert.ok(flat.includes("2028-03-01"))
})

test("tokenMix: non-finite counts are ignored", () => {
  const mix = Insights.tokenMix({ a: { inputTokens: "1e400", outputTokens: NaN, cacheReadInputTokens: -5, cacheCreationInputTokens: 10 } })
  assert.equal(mix.total, 10)
})
