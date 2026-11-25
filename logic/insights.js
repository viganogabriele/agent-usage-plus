// Pure, derived insights for the panel's dashboard: how a limit window is
// pacing against the clock, what the recent token history says (streak, best
// day, trend), and the activity heatmap grid.
//
// Everything here is read-only arithmetic over data a collector already
// reported. Nothing fetches, nothing reads the clock on its own (callers pass
// `nowMs` / `todayIso`), and no number is invented: a window whose length
// cannot be established, or a history too short to say anything, returns
// null instead of a guess.

var HOUR_MS = 3600 * 1000
var DAY_MS = 24 * HOUR_MS

function isoMs(value) {
  if (value === undefined || value === null || value === "") return NaN
  var n = new Date(String(value)).getTime()
  return isFinite(n) ? n : NaN
}

// The length of a limit window, or 0 when it is not established.
//
// A collector's own startedAt/resetsAt pair wins. Otherwise only an
// explicit, collector-supplied title naming a window whose length is a
// published fact counts: "Session" (the 5-hour window Claude and Codex
// document), "...Weekly" (7 days, including model-scoped "Opus Weekly") and
// "...Daily". A title the panel derived from a free-text label
// (`titleExplicit === false`) never counts, and nothing is read out of the
// label itself: "Opus 5 (1M context)" or a "30m window" would otherwise be
// filed as a 5-hour session (see sanitizeLimits in logic/aggregate.js).
// Monthly windows are usually calendar-aligned, so they need startedAt.
function windowSpanMs(window) {
  if (!window) return 0
  var started = isoMs(window.startedAt)
  var reset = isoMs(window.resetAt !== undefined ? window.resetAt : window.resetsAt)
  if (isFinite(started) && isFinite(reset) && reset > started) return reset - started
  if (window.titleExplicit === false) return 0
  var title = String(window.title || "").toLowerCase().trim()
  var span = 0
  if (title === "session") span = 5 * HOUR_MS
  else if (/(^|\s)weekly$/.test(title)) span = 7 * DAY_MS
  else if (/(^|\s)daily$/.test(title)) span = DAY_MS
  // A label that states its own, different length ("48h window") wins over
  // the generic title: guessing would project against the wrong clock.
  var stated = labelSpanMs(window.label)
  if (span > 0 && stated > 0 && stated !== span) return 0
  return span
}

// The window length a label states outright ("5h window", "30m", "2 days"),
// or 0. Only ever used to *veto* a title-derived span, never to create one.
function labelSpanMs(label) {
  var match = /(\d+(?:\.\d+)?)\s*-?\s*(m|min|mins|minutes?|h|hr|hrs|hours?|d|days?)\b/.exec(String(label || "").toLowerCase())
  if (!match) return 0
  var n = Number(match[1])
  var unit = match[2].charAt(0)
  return unit === "m" ? n * 60 * 1000 : unit === "h" ? n * HOUR_MS : n * DAY_MS
}

// How a window is tracking against its own clock.
//
// `measuredAtMs` is when `percent` was read (the record's updatedAt); it
// defaults to `nowMs`. Elapsed time is taken at that instant, so a reading
// that has sat unrefreshed does not drift toward "under pace" just because
// the panel's clock moved on. A reading older than max(15 min, 10% of the
// window) is too old to project from and returns null.
//
// Returns null when the window's length, reset, or a meaningful amount of
// elapsed time is unknown. Otherwise:
//   elapsed      0-1 fraction of the window behind us at measurement time
//   used         0-1 fraction of the allowance used (as reported)
//   delta        used - elapsed (positive: burning faster than the clock)
//   status       "idle" | "under" | "on" | "over"
//   projected    linear projection of `used` at reset (may exceed 1)
//   runsOutInMs  time from now until 100% at the window's own average rate,
//                0 when already full, or -1 when the window resets first
//   resetInMs    time from now until reset
//
// The projection is the window's own average rate (used / elapsed), never
// a token quota reverse-engineered from a percentage. It is withheld during
// the first 5% of a window, where one early prompt would extrapolate into a
// wildly alarming number.
function windowPace(window, nowMs, measuredAtMs) {
  if (!window) return null
  var used = Number(window.percent)
  if (!isFinite(used) || used < 0) return null
  var span = windowSpanMs(window)
  var reset = isoMs(window.resetAt !== undefined ? window.resetAt : window.resetsAt)
  var now = Number(nowMs)
  if (!(span > 0) || !isFinite(reset) || !isFinite(now) || reset <= now) return null
  // Omitted means "measured now"; anything passed must be a real instant that
  // is not in the future, or the reading's age is unknown and pace withheld.
  var measured = measuredAtMs === undefined ? now
    : (measuredAtMs === null ? NaN : Number(measuredAtMs))
  if (!isFinite(measured) || measured > now) return null
  if (now - measured > Math.max(15 * 60 * 1000, span * 0.1)) return null

  var elapsedMs = span - (reset - measured)
  if (elapsedMs <= 0) return null
  var elapsed = Math.min(1, elapsedMs / span)
  if (elapsed < 0.05) return null

  var delta = used - elapsed
  var status
  if (used <= 0) status = "idle"
  else if (delta > 0.05) status = "over"
  else if (delta < -0.05) status = "under"
  else status = "on"

  var runsOutIn = -1
  if (used >= 1) {
    runsOutIn = 0
  } else if (used > 0) {
    var runsOutAt = measured + (1 - used) / used * elapsedMs
    if (runsOutAt < reset) runsOutIn = Math.max(0, runsOutAt - now)
  }

  return {
    elapsed: elapsed,
    used: used,
    delta: delta,
    status: status,
    projected: used / elapsed,
    runsOutInMs: runsOutIn,
    resetInMs: reset - now
  }
}

// Of several windows, the one that will run out first at its own rate
// (before its reset), as { window, pace }; null when none is on course to
// run out. A full window is excluded — it has already stopped you, and the
// fullest-window gauge already says so.
function firstRunOut(windows, nowMs, measuredAtMs) {
  var list = Array.isArray(windows) ? windows : []
  var best = null
  for (var i = 0; i < list.length; i++) {
    var pace = windowPace(list[i], nowMs, measuredAtMs)
    if (!pace || pace.used >= 1 || !(pace.runsOutInMs >= 0)) continue
    if (!best || pace.runsOutInMs < best.pace.runsOutInMs) best = { window: list[i], pace: pace }
  }
  return best
}

function dayValue(day) {
  var n = Number(day && day.messageCount)
  return isFinite(n) && n > 0 ? n : 0
}

function sortedDays(recentDays) {
  var list = Array.isArray(recentDays) ? recentDays.filter(function(d) {
    return d && /^\d{4}-\d{2}-\d{2}$/.test(String(d.date || ""))
  }) : []
  list.sort(function(a, b) { return a.date < b.date ? -1 : (a.date > b.date ? 1 : 0) })
  return list
}

function isoDay(ms) {
  var d = new Date(ms)
  return d.getUTCFullYear() + "-" + String(d.getUTCMonth() + 1).padStart(2, "0")
    + "-" + String(d.getUTCDate()).padStart(2, "0")
}

function shiftIso(iso, days) {
  var ms = Date.parse(String(iso) + "T00:00:00Z")
  return isFinite(ms) ? isoDay(ms + days * DAY_MS) : ""
}

// Summary numbers for one provider's daily token history.
//
//   total, activeDays, today            straightforward sums/counts
//   streak                              consecutive active days ending today
//                                       (or yesterday, so a streak does not
//                                       read as broken before today's first
//                                       prompt)
//   best { date, value }                busiest recorded day
//   avg7                                mean of the last 7 calendar days
//                                       before today (-1 if fewer recorded)
//   hasToday                            whether the record has an entry for
//                                       today at all (a stats-cache
//                                       fallback can stop short of it)
//   todayVsAvg                          today / avg7 - 1 (null when avg7 is
//                                       unavailable or zero, or today has
//                                       no entry)
//   weekChange                          the last 7 complete days vs the 7
//                                       before them, ratio - 1 (null
//                                       without 14 recorded days)
function activityStats(recentDays, todayIso) {
  var days = sortedDays(recentDays)
  var byDate = {}
  var total = 0
  var active = 0
  var best = null
  for (var i = 0; i < days.length; i++) {
    var v = dayValue(days[i])
    byDate[days[i].date] = (byDate[days[i].date] || 0) + v
  }
  var dates = Object.keys(byDate).sort()
  for (var j = 0; j < dates.length; j++) {
    var value = byDate[dates[j]]
    total += value
    if (value > 0) active++
    if (value > 0 && (!best || value > best.value)) best = { date: dates[j], value: value }
  }

  var today = String(todayIso || (dates.length ? dates[dates.length - 1] : ""))
  var todayValue = byDate[today] || 0

  var streak = 0
  var cursor = todayValue > 0 ? today : shiftIso(today, -1)
  while (cursor && byDate[cursor] > 0) {
    streak++
    cursor = shiftIso(cursor, -1)
  }

  function windowSum(endOffset, length) {
    var sum = 0
    var seen = 0
    for (var k = 0; k < length; k++) {
      var key = shiftIso(today, -(endOffset + k))
      if (byDate[key] !== undefined) seen++
      sum += byDate[key] || 0
    }
    return { sum: sum, seen: seen }
  }

  var hasToday = byDate[today] !== undefined
  var prior7 = windowSum(1, 7)
  var avg7 = prior7.seen >= 7 ? prior7.sum / 7 : -1
  var todayVsAvg = avg7 > 0 && hasToday ? todayValue / avg7 - 1 : null

  // Complete days only: including today's partial day made every morning
  // read as a "quieter week".
  var prev7 = windowSum(8, 7)
  var weekChange = (prior7.seen >= 7 && prev7.seen >= 7 && prev7.sum > 0)
    ? prior7.sum / prev7.sum - 1 : null

  return {
    total: total,
    activeDays: active,
    recordedDays: dates.length,
    today: todayValue,
    hasToday: hasToday,
    streak: streak,
    best: best,
    avg7: avg7,
    todayVsAvg: todayVsAvg,
    weekChange: weekChange
  }
}

// GitHub-style activity grid: `weeks` is an array of weeks (oldest first),
// each an array of seven days Monday..Sunday; the last week contains
// `todayIso`. (The panel draws each week as a calendar row.) Each cell carries its date, token value, a 0-4 intensity
// level, and flags for "after today" (future) and "no record" (missing), so
// the panel can render an absent day differently from a real zero.
//
// Levels are relative to the busiest day in view (quartiles of the peak),
// which keeps a light user's grid as readable as a heavy one's.
function heatmapGrid(recentDays, todayIso, weeks) {
  var days = sortedDays(recentDays)
  var byDate = {}
  for (var i = 0; i < days.length; i++)
    byDate[days[i].date] = (byDate[days[i].date] || 0) + dayValue(days[i])
  var today = String(todayIso || (days.length ? days[days.length - 1].date : ""))
  var todayMs = Date.parse(today + "T00:00:00Z")
  var weekCount = Math.max(1, Math.min(53, Math.round(Number(weeks) || 5)))
  if (!isFinite(todayMs)) return { weeks: [], peak: 0, weekCount: 0 }

  var weekday = (new Date(todayMs).getUTCDay() + 6) % 7 // Monday = 0
  var startMs = todayMs - (weekday + 7 * (weekCount - 1)) * DAY_MS

  var peak = 0
  var columns = []
  for (var w = 0; w < weekCount; w++) {
    var column = []
    for (var d = 0; d < 7; d++) {
      var ms = startMs + (w * 7 + d) * DAY_MS
      var iso = isoDay(ms)
      var missing = byDate[iso] === undefined
      var value = missing ? 0 : byDate[iso]
      // A collector writing UTC dates can already hold "tomorrow" for a
      // user west of UTC; a day with data is shown, never hidden as future.
      var future = ms > todayMs && missing
      if (!future && value > peak) peak = value
      column.push({ date: iso, value: value, future: future, missing: missing, today: iso === today, level: 0 })
    }
    columns.push(column)
  }
  for (var c = 0; c < columns.length; c++) {
    for (var r = 0; r < 7; r++) {
      var cell = columns[c][r]
      if (cell.future || cell.value <= 0 || peak <= 0) continue
      cell.level = Math.max(1, Math.min(4, Math.ceil(cell.value / peak * 4)))
    }
  }
  return { weeks: columns, peak: peak, weekCount: weekCount }
}

function finiteCount(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? n : 0
}

// Token mix for a modelId -> TokenBucket map: how much of the traffic was
// fresh input, output, and cache reads/writes, and the cache hit share of
// all input-side tokens (cache reads / (input + cache reads + cache writes)).
function tokenMix(usageByModel) {
  var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
  var map = usageByModel && typeof usageByModel === "object" ? usageByModel : {}
  for (var id in map) {
    var b = map[id] || {}
    input += finiteCount(b.inputTokens)
    output += finiteCount(b.outputTokens)
    cacheRead += finiteCount(b.cacheReadInputTokens)
    cacheWrite += finiteCount(b.cacheCreationInputTokens)
  }
  var total = input + output + cacheRead + cacheWrite
  var inputSide = input + cacheRead + cacheWrite
  return {
    total: total,
    input: input,
    output: output,
    cacheRead: cacheRead,
    cacheWrite: cacheWrite,
    cacheHitRate: inputSide > 0 ? cacheRead / inputSide : -1
  }
}

// Signed percentage text for a ratio change: 0.234 -> "+23%", -0.05 -> "−5%".
function formatChange(ratio) {
  var n = Number(ratio)
  if (ratio === null || ratio === undefined || !isFinite(n)) return ""
  var pct = Math.round(n * 100)
  if (pct === 0) return "±0%"
  return (pct > 0 ? "+" : "−") + Math.abs(pct) + "%"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    windowSpanMs: windowSpanMs,
    windowPace: windowPace,
    firstRunOut: firstRunOut,
    activityStats: activityStats,
    heatmapGrid: heatmapGrid,
    tokenMix: tokenMix,
    formatChange: formatChange
  }
}
