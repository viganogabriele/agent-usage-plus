"use strict"

// Source-level guards for the panel's view structure. The QML itself is
// verified by rendering; these keep the structure from regressing silently.

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const source = fs.readFileSync(path.join(__dirname, "..", "Panel.qml"), "utf8")

function block(startMarker, endMarker) {
  const start = source.indexOf(startMarker)
  const end = source.indexOf(endMarker, start + startMarker.length)
  assert.ok(start >= 0 && end > start, `block ${startMarker} should be present`)
  return source.slice(start, end)
}

test("the panel offers exactly the Usage, Activity, Models and Cost views", () => {
  const tabs = block("readonly property var viewTabs: [", "]")
  const ids = [...tabs.matchAll(/id: "(\w+)"/g)].map((m) => m[1])
  assert.deepEqual(ids, ["usage", "activity", "models", "cost"])
})

test("every detail card belongs to exactly one view", () => {
  const expectations = {
    "id: todayTiles": "usage",
    "id: freeResetsCard": "usage",
    "id: balanceSection": "usage",
    "id: limitsSection": "usage",
    "id: accountsCard": "usage",
    "id: activityCard": "activity",
    "id: historyCard": "activity",
    "id: tokenMixCard": "models",
    "id: detailModelSection": "models",
    "id: costSection": "cost"
  }
  for (const [marker, view] of Object.entries(expectations)) {
    const start = source.indexOf(marker)
    assert.ok(start >= 0, `${marker} should exist`)
    const visibleLine = source.slice(start, start + 600).match(/visible:[^\n]*(\n\s+(&&|\|\|)[^\n]*)*/)
    assert.ok(visibleLine, `${marker} should declare visibility`)
    assert.match(visibleLine[0], new RegExp(`root\\.viewTab === "${view}"`), `${marker} should be gated to ${view}`)
  }
})

test("each window's reset is stated once, under its own ring", () => {
  const ring = block("component RingTile: Item {", "component TabStrip")
  assert.match(ring, /root\.formatDuration\(resetMs\)/)
  assert.match(ring, /resetWhen:.*\n\s*:.*root\.resetClock\(window\)/)
  assert.match(ring, /" before reset"/)
  // No second or third copy of the same reset elsewhere in the panel.
  assert.doesNotMatch(source, /component ForecastLane|upcomingResets|id: resetsCard/)
  // Rings are fixed instances, not Repeater delegates rebuilt on refresh.
  const overview = block("id: overviewCard", "// ---------- View tabs")
  assert.doesNotMatch(overview, /model: overviewCard\.ringCount === 2 \? root\.ringWindows/)
  // Free resets live in the Usage view, not in the overview.
  assert.doesNotMatch(overview, /resetCredits/)
})

test("quota resets and redeemable credits show day, month and local clock", () => {
  const formatter = block("function formatResetMoment(ms)", "\n  }")
  assert.match(formatter, /dateLabel\(at, false\) \+ " " \+ Qt\.formatTime\(at, "HH:mm"\)/)
  assert.match(block("function resetClock(w)", "\n  }"), /formatResetMoment\(ms\)/)
  assert.match(block("id: freeResetsCard", "id: balanceSection"), /formatDuration\(remaining\) \+ " left · " \+ root\.formatResetMoment\(expiry\)/)
  assert.match(block("component LimitRow: Column", "component Meter: Item"), /root\.resetClock\(limitRow\.window\)/)
})

test("ring and chart colors stay on the theme accent until a threshold says otherwise", () => {
  const tint = block("function ringTint(w) {", "\n  }")
  assert.doesNotMatch(tint, /hslHue|Qt\.hsla/)
  assert.match(tint, /severity !== "ok"/)
  const series = block("function seriesColor(index) {", "\n  }")
  assert.doesNotMatch(series, /hslHue|Qt\.hsla/)
})

test("the all-providers list never truncates its labels into fixed columns", () => {
  const list = block("id: costProviderOverview", "// ---------- Settings:")
  assert.doesNotMatch(list, /width: Style\.space\((78|94)\)/)
  assert.match(list, /id: providerCostKind[\s\S]*?anchors\.right: providerCostApiValue\.left/)
  assert.doesNotMatch(list.slice(list.indexOf("id: providerCostKind"), list.indexOf("id: providerCostKind") + 700), /elide:/)
})

test("settings has a dedicated Accounts tab", () => {
  const tabs = block("id: settingsTabs", "onPicked")
  for (const id of ["providers", "accounts", "display", "alerts", "sync"]) assert.match(tabs, new RegExp(`id: "${id}"`))
  assert.match(source, /id: accountSettingsContent\s*\n\s*visible: root\.settingsTab === "accounts"/)
})
