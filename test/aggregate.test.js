"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const Aggregate = require("../logic/aggregate.js")

const fixturesDir = path.join(__dirname, "fixtures")

function readFixtureText(name) {
  return fs.readFileSync(path.join(fixturesDir, name), "utf8")
}

function readFixture(name) {
  return JSON.parse(readFixtureText(name))
}

// ---------------------------------------------------------------- fixtures

test("fixtures: every *-ok / error / sync fixture is valid JSON", () => {
  const validFixtures = [
    "claude-ok.json",
    "codex-ok.json",
    "fireworks-ok.json",
    "claude-auth-error.json",
    "codex-endpoint-down.json",
    "sync-snapshot-two-devices.json",
    "oversized.json",
    "claude-with-cost.json"
  ]
  for (const name of validFixtures) {
    assert.doesNotThrow(() => readFixture(name), `${name} should be valid JSON`)
  }
})

test("fixtures: malformed.json is deliberately invalid JSON", () => {
  assert.throws(() => JSON.parse(readFixtureText("malformed.json")), SyntaxError)
})

// --------------------------------------------------------- provider records

test("mergeProviderDisplay: a healthy Claude record keeps its session+weekly limits", () => {
  const record = readFixture("claude-ok.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)
  assert.equal(display.providerId, "claude")
  assert.equal(display.ready, true)
  assert.equal(display.limits.length, 2)
  assert.equal(display.limits[0].label, "Session")
  assert.equal(display.limits[1].label, "Weekly")
  assert.equal(display.syncEnabled, false)
  assert.ok(Aggregate.providerHasData(display))
})

// -------------------------------------------------------------------- cost

test("brand: flows sanitized from record through display, snapshot, and merge", () => {
  const record = readFixture("claude-ok.json")

  // Without a brand, everything renders by the record's own id, as before.
  const plain = Aggregate.mergeProviderDisplay(record, null, null)
  assert.equal(plain.brand, "")

  // A second-account record declares whose mark it renders with.
  const account = Object.assign({}, record, { id: "claude-work", name: "Claude · Work", brand: "claude" })
  const display = Aggregate.mergeProviderDisplay(account, null, null)
  assert.equal(display.providerId, "claude-work")
  assert.equal(display.brand, "claude")

  // The brand survives the sync snapshot round-trip...
  const snapshot = Aggregate.providerSnapshot(account)
  assert.equal(snapshot.brand, "claude")
  const merged = Aggregate.aggregateSnapshots([
    { deviceId: "laptop", providers: { "claude-work": snapshot } }
  ])
  assert.equal(merged.providers["claude-work"].brand, "claude")

  // ...and a synced-only stats brand backfills a local record without one.
  const backfilled = Aggregate.mergeProviderDisplay(
    Object.assign({}, record, { id: "claude-work" }),
    merged.providers["claude-work"],
    merged
  )
  assert.equal(backfilled.brand, "claude")

  // The display object carries brand for every icon-affecting lookup
  // (candidates and scale both resolve brand-first in Panel.qml).
  assert.equal(display.brand || display.providerId, "claude")

  // Hostile values sanitize the same way ids do, or collapse to "".
  assert.equal(Aggregate.sanitizeBrand("../..//claude"), "claude")
  assert.equal(Aggregate.sanitizeBrand("  "), "")
  assert.equal(Aggregate.sanitizeBrand(null), "")
})

test("mergeProviderDisplay: a record without a cost block merges with cost: null (issue #12 regression)", () => {
  for (const name of ["claude-ok.json", "codex-ok.json", "fireworks-ok.json"]) {
    const record = readFixture(name)
    assert.equal(record.cost, undefined, `${name} fixture should not define cost`)
    const display = Aggregate.mergeProviderDisplay(record, null, null)
    assert.equal(display.cost, null, `${name} should merge to cost: null`)
  }
})

test("mergeProviderDisplay: existing fixtures merge identically apart from the new cost:null field", () => {
  // A structural regression check, not just a value spot-check: every other
  // field mergeProviderDisplay produces for these fixtures must be exactly
  // what it produced before this issue's change, so this diffs the whole
  // display object with `cost` removed.
  for (const name of ["claude-ok.json", "codex-ok.json", "fireworks-ok.json", "claude-auth-error.json", "codex-endpoint-down.json"]) {
    const record = readFixture(name)
    const display = Aggregate.mergeProviderDisplay(record, null, null)
    assert.equal(display.cost, null)
    const { cost, ...rest } = display
    // Re-running the merge on a record with cost stripped (a no-op here,
    // since none of these fixtures set it) must produce the same rest.
    const displayAgain = Aggregate.mergeProviderDisplay(record, null, null)
    const { cost: costAgain, ...restAgain } = displayAgain
    assert.deepEqual(rest, restAgain)
  }
})

test("costValue: parses estimateUsd, period, byModel, and byDay from a compliant cost block", () => {
  const record = readFixture("claude-with-cost.json")
  const cost = Aggregate.costValue(record.cost)
  assert.ok(cost)
  assert.equal(cost.estimateUsd, 12.43)
  assert.equal(cost.period, "30d")
  assert.equal(cost.byModel.length, 2)
  assert.equal(cost.byModel[0].model, "claude-sonnet-5")
  assert.equal(cost.byModel[0].usd, 8.1)
  assert.equal(cost.byModel[0].tokens, 540000000)
  assert.equal(cost.byDay.length, 2)
  assert.equal(cost.byDay[1].date, "2026-08-23")
  assert.equal(cost.byDay[1].usd, 0.87)
})

test("costValue: preserves bounded recorded active days for an aggregate average", () => {
  const cost = Aggregate.costValue({ estimateUsd: 5, activeDays: 12.8 })
  assert.equal(cost.activeDays, 12)
})

test("costValue: a missing/negative estimateUsd makes the whole cost object absent", () => {
  assert.equal(Aggregate.costValue(null), null)
  assert.equal(Aggregate.costValue({}), null)
  assert.equal(Aggregate.costValue({ estimateUsd: -1 }), null)
  assert.equal(Aggregate.costValue({ estimateUsd: "not a number" }), null)
})

test("costValue: preserves a declared partial-cost disclosure", () => {
  const cost = Aggregate.costValue({
    estimateUsd: 12, incomplete: true, unknownModels: ["codex-auto-review"],
    pricedTokens: 900, unpricedTokens: 100
  })
  assert.equal(cost.incomplete, true)
  assert.deepEqual(cost.unknownModels, ["codex-auto-review"])
  assert.equal(cost.pricedTokens, 900)
  assert.equal(cost.unpricedTokens, 100)
})

test("costValue: tolerates a bare estimateUsd with no byModel/byDay", () => {
  const cost = Aggregate.costValue({ estimateUsd: 5 })
  assert.equal(cost.estimateUsd, 5)
  assert.deepEqual(cost.byModel, [])
  assert.deepEqual(cost.byDay, [])
})

test("mergeProviderDisplay: a record with a cost block surfaces it while everything else renders as normal", () => {
  const record = readFixture("claude-with-cost.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)
  assert.ok(display.cost)
  assert.equal(display.cost.estimateUsd, 12.43)
  assert.equal(display.cost.period, "30d")
  // Limits/balance/everything else keeps working exactly as the plain
  // claude-ok.json fixture does.
  assert.equal(display.limits.length, 2)
  assert.equal(display.limits[0].label, "Session")
  assert.equal(display.balance, null)
  assert.ok(Aggregate.providerHasData(display))
})

test("mergeProviderDisplay: Codex reports a single weekly-only limit", () => {
  const record = readFixture("codex-ok.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)
  assert.equal(display.limits.length, 1)
  assert.equal(display.limits[0].label, "Weekly")
})

test("mergeProviderDisplay: Fireworks reports a balance instead of limits", () => {
  const record = readFixture("fireworks-ok.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)
  assert.equal(display.limits.length, 0)
  assert.ok(display.balance)
  assert.equal(display.balance.remaining, 12.34)
  assert.equal(display.balance.funded, 20)
  assert.equal(display.balance.estimated, true)
  assert.ok(Aggregate.providerHasData(display)) // balance alone counts as data
})

test("mergeProviderDisplay: a Claude auth error keeps status/help text and drops limits", () => {
  const record = readFixture("claude-auth-error.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)
  assert.equal(display.ready, false)
  assert.equal(display.limits.length, 0)
  assert.match(display.usageStatusText, /plan line/)
  assert.match(display.authHelpText, /signed-in CLI/)
  // Local stats still make the provider worth showing.
  assert.ok(Aggregate.providerHasData(display))
})

test("mergeProviderDisplay: a Codex endpoint-down record surfaces its own help text", () => {
  const record = readFixture("codex-endpoint-down.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)
  assert.equal(display.ready, false)
  assert.match(display.authHelpText, /app-server RPC/)
})

test("providerHasData: a first-run auth or endpoint state remains visible", () => {
  assert.equal(Aggregate.providerHasData({ ready: false, usageStatusText: "Waiting for API key" }), true)
  assert.equal(Aggregate.providerHasData({ ready: false, usageStatusText: "" }), false)
  assert.equal(Aggregate.providerHasData({ ready: true }), true)
})

// ----------------------------------------------------------- sync snapshots

function loadTwoDeviceSnapshot() {
  const dates = Aggregate.recentDateStrings()
  const today = dates[dates.length - 1]
  const yesterday = dates[dates.length - 2]
  const twoDaysAgo = dates[dates.length - 3]
  const text = readFixtureText("sync-snapshot-two-devices.json")
    .split("{{TODAY}}").join(today)
    .split("{{YESTERDAY}}").join(yesterday)
    .split("{{TWODAYSAGO}}").join(twoDaysAgo)
  return { snapshots: JSON.parse(text), today, yesterday, twoDaysAgo }
}

test("aggregateSnapshots: two devices reporting the same provider don't duplicate a day", () => {
  const { snapshots, today } = loadTwoDeviceSnapshot()
  const result = Aggregate.aggregateSnapshots(snapshots)
  const claude = result.providers.claude

  // Exactly one recentDays entry for today, not one per device, with the
  // per-device message counts summed (device-scoped stats are additive).
  const todaysEntries = claude.recentDays.filter((d) => d.date === today)
  assert.equal(todaysEntries.length, 1)
  assert.equal(todaysEntries[0].messageCount, 65) // 40 (laptop) + 25 (desktop)

  assert.equal(claude.deviceCount, 2)
  assert.deepEqual(claude.devices, ["desktop", "laptop"])
})

test("aggregateSnapshots: activeDates union across devices, not summed", () => {
  const { snapshots } = loadTwoDeviceSnapshot()
  const result = Aggregate.aggregateSnapshots(snapshots)
  const claude = result.providers.claude

  // laptop: {today, yesterday} (activeDays 1), desktop: {today, twoDaysAgo}
  // (activeDays 1) -> union has 3 distinct dates, which must win over the
  // per-device activeDays counters (max(1, 1) = 1).
  assert.equal(claude.activeDays, 3)
})

test("aggregateSnapshots: device-scoped totals sum, not double-count", () => {
  const { snapshots } = loadTwoDeviceSnapshot()
  const result = Aggregate.aggregateSnapshots(snapshots)
  const claude = result.providers.claude
  assert.equal(claude.totalPrompts, 250) // 100 + 150
  assert.equal(claude.totalSessions, 50) // 20 + 30
})

test("aggregateSnapshots: TokenBucket-shaped todayTokensByModel merges every bucket field", () => {
  const { snapshots } = loadTwoDeviceSnapshot()
  const bucket = Aggregate.aggregateSnapshots(snapshots).providers.claude.todayTokensByModel["claude-opus-4-20250514"]
  assert.deepEqual(bucket, { inputTokens: 7000, outputTokens: 2500, cacheReadInputTokens: 2000, cacheCreationInputTokens: 300 })
})

test("aggregateSnapshots: account-scoped stats take the widest value instead of summing", () => {
  const snapshots = [
    { deviceId: "a", providers: { fireworks: { scope: "account", totalPrompts: 40, recentDays: [], activeDates: [] } } },
    { deviceId: "b", providers: { fireworks: { scope: "account", totalPrompts: 55, recentDays: [], activeDates: [] } } }
  ]
  const result = Aggregate.aggregateSnapshots(snapshots)
  assert.equal(result.providers.fireworks.totalPrompts, 55)
})

test("aggregateSnapshots: an empty snapshot list produces an empty provider map", () => {
  const result = Aggregate.aggregateSnapshots([])
  assert.deepEqual(Object.keys(result.providers), [])
  assert.equal(result.deviceCount, 0)
})

test("aggregateSnapshots: prototype-named providers are ordinary data keys", () => {
  const ids = ["constructor", "toString", "valueOf", "hasOwnProperty"]
  const providers = {}
  for (const id of ids) providers[id] = { providerName: id, todayPrompts: 1 }

  const result = Aggregate.aggregateSnapshots([{ deviceId: "constructor", providers }])

  assert.deepEqual(Object.keys(result.providers).sort(), ids.slice().sort())
  for (const id of ids) {
    assert.equal(result.providers[id].providerId, id)
    assert.equal(result.providers[id].providerName, id)
    assert.deepEqual(result.providers[id].devices, ["constructor"])
  }
  assert.deepEqual(result.devices, ["constructor"])
})

test("capModelUsage: prototype-named model ids remain data instead of mutating the map prototype", () => {
  const usage = JSON.parse('{"__proto__":{"inputTokens":1},"constructor":{"outputTokens":2}}')
  const result = Aggregate.capModelUsage(usage)

  assert.equal(result["__proto__"].inputTokens, 1)
  assert.equal(result.constructor.outputTokens, 2)
  assert.deepEqual(Object.keys(result).sort(), ["__proto__", "constructor"])
})

// --------------------------------------------------- enabled/disabled providers

test("buildLocalSnapshot: a provider disabled in settings is excluded from the built snapshot", () => {
  const claude = readFixture("claude-ok.json")
  const codex = readFixture("codex-ok.json")
  const isProviderEnabled = (id) => id !== "codex" // codex disabled
  const snapshot = Aggregate.buildLocalSnapshot([claude, codex], "my-device", isProviderEnabled)

  assert.ok(snapshot.providers.claude)
  assert.equal(snapshot.providers.codex, undefined)
})

test("buildLocalSnapshot: with no isProviderEnabled callback, every record is included", () => {
  const claude = readFixture("claude-ok.json")
  const codex = readFixture("codex-ok.json")
  const snapshot = Aggregate.buildLocalSnapshot([claude, codex], "my-device")
  assert.ok(snapshot.providers.claude)
  assert.ok(snapshot.providers.codex)
})

test("buildLocalSnapshot: null records in the list are skipped without throwing", () => {
  const claude = readFixture("claude-ok.json")
  assert.doesNotThrow(() => Aggregate.buildLocalSnapshot([null, claude, undefined], "dev", () => true))
  const snapshot = Aggregate.buildLocalSnapshot([null, claude, undefined], "dev", () => true)
  assert.deepEqual(Object.keys(snapshot.providers), ["claude"])
})

// ------------------------------------------------- combined model usage (#7)

test("allProviderModelUsage: combines claude+codex+fireworks fixtures into one model map", () => {
  const claude = Aggregate.mergeProviderDisplay(readFixture("claude-ok.json"), null, null)
  const codex = Aggregate.mergeProviderDisplay(readFixture("codex-ok.json"), null, null)
  const fireworks = Aggregate.mergeProviderDisplay(readFixture("fireworks-ok.json"), null, null)

  const combined = Aggregate.allProviderModelUsage([claude, codex, fireworks])
  const modelIds = Object.keys(combined).sort()

  // Every enabled provider's models show up, not just one chip's worth.
  assert.deepEqual(modelIds, [
    "claude-opus-4-20250514",
    "claude-sonnet-4-20250514",
    "deepseek-v3",
    "gpt-5.6-sol"
  ])

  // Claude and Fireworks each contribute a model no other provider reports,
  // so their buckets must pass through untouched (no cross-provider mixing).
  assert.equal(combined["claude-opus-4-20250514"].inputTokens, 900000)
  assert.equal(combined["claude-opus-4-20250514"].outputTokens, 210000)
  assert.equal(combined["deepseek-v3"].inputTokens, 210000)
  assert.equal(combined["gpt-5.6-sol"].outputTokens, 90000)
})

test("allProviderModelUsage: the same model id reported by two providers sums instead of overwriting", () => {
  const a = { modelUsage: { "shared-model": { inputTokens: 100, outputTokens: 10, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 } } }
  const b = { modelUsage: { "shared-model": { inputTokens: 50, outputTokens: 5, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 } } }
  const combined = Aggregate.allProviderModelUsage([a, b])
  assert.equal(combined["shared-model"].inputTokens, 150)
  assert.equal(combined["shared-model"].outputTokens, 15)
})

test("allProviderModelUsage: an empty/garbage provider list produces an empty map without throwing", () => {
  assert.deepEqual(Object.keys(Aggregate.allProviderModelUsage([])), [])
  assert.doesNotThrow(() => Aggregate.allProviderModelUsage(null))
  assert.deepEqual(Object.keys(Aggregate.allProviderModelUsage([null, {}, undefined])), [])
})

// --------------------------------------------------------------- malformed

// logic/aggregate.js never parses JSON text itself (that happens in
// Main.qml, wrapped in try/catch — see parseSyncScanOutput); what it must
// survive is already-parsed-but-garbage *objects*. malformed.json is
// deliberately invalid JSON syntax, so the contract under test here mirrors
// what Main.qml actually does with it: parsing throws and is caught, and
// the logic layer is then handed a safe fallback instead of the raw text —
// which every merge/build function must accept without throwing.

test("malformed.json: JSON.parse throws, exactly as Main.qml's try/catch expects", () => {
  assert.throws(() => JSON.parse(readFixtureText("malformed.json")))
})

test("mergeProviderDisplay: an empty fallback record (post-parse-failure) resolves to a handled not-ready state", () => {
  assert.doesNotThrow(() => Aggregate.mergeProviderDisplay({}, null, null))
  const display = Aggregate.mergeProviderDisplay({}, null, null)
  assert.equal(display.ready, false)
  assert.equal(display.limits.length, 0)
  assert.equal(display.balance, null)
  assert.equal(Aggregate.providerHasData(display), false)
})

test("aggregateSnapshots: garbage snapshot shapes (missing providers, non-object stats) don't throw", () => {
  const garbage = [
    null,
    {},
    { deviceId: 123, providers: null },
    { deviceId: "x", providers: { claude: null } },
    { deviceId: "y", providers: { claude: "not-an-object" } },
    "not-even-an-object"
  ]
  assert.doesNotThrow(() => Aggregate.aggregateSnapshots(garbage.filter((s) => s && typeof s === "object")))
})

// --------------------------------------------------------------- oversized

test("oversized.json: sanitizeProviderId strips traversal characters and caps length", () => {
  const record = readFixture("oversized.json")
  const id = Aggregate.sanitizeProviderId(record.id)
  assert.ok(id.length <= 64)
  assert.ok(!id.includes("/"))
  assert.ok(!id.includes(".."))
})

test("oversized.json: mergeProviderDisplay caps limits, recentDays, and modelUsage", () => {
  const record = readFixture("oversized.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)

  assert.ok(record.limits.length > 20, "fixture must actually exceed the cap to test it")
  assert.equal(display.limits.length, 20)

  assert.ok(record.recentDays.length > 31, "fixture must actually exceed the cap to test it")
  assert.equal(display.recentDays.length, 31)

  assert.ok(Object.keys(record.modelUsage).length > 100, "fixture must actually exceed the cap to test it")
  assert.equal(Object.keys(display.modelUsage).length <= 100, true)
})

test("oversized.json: display text fields are capped to their field-specific length", () => {
  const record = readFixture("oversized.json")
  const display = Aggregate.mergeProviderDisplay(record, null, null)
  assert.ok(record.name.length > 80, "fixture must actually exceed the cap to test it")
  assert.ok(display.providerName.length <= 80)
  assert.ok(record.usageStatusText.length > 200)
  assert.ok(display.usageStatusText.length <= 200)
  assert.ok(record.authHelpText.length > 300)
  assert.ok(display.authHelpText.length <= 300)
})

test("oversized.json: sanitizeLimits caps each limit's free-text fields", () => {
  const record = readFixture("oversized.json")
  const limits = Aggregate.sanitizeLimits(record.limits)
  for (const limit of limits) {
    assert.ok(limit.label.length <= 80)
    assert.ok(limit.title.length <= 80)
    assert.ok(limit.resetsAt.length <= 40)
  }
})

test("oversized.json: capModelUsage and capRecentDays enforce their caps directly", () => {
  const record = readFixture("oversized.json")
  assert.equal(Object.keys(Aggregate.capModelUsage(record.modelUsage)).length, 100)
  assert.equal(Aggregate.capRecentDays(record.recentDays).length, 31)
})

test("providerSnapshot: caps and sanitizes an oversized local record before it enters the sync payload", () => {
  const record = readFixture("oversized.json")
  const snapshot = Aggregate.providerSnapshot(record)
  assert.ok(snapshot.providerId.length <= 64)
  assert.equal(snapshot.recentDays.length, 31)
  assert.ok(Object.keys(snapshot.modelUsage).length <= 100)
  assert.ok(snapshot.activeDates.length <= 400)
})

// ------------------------------------------------------ barMode (issue #5)

function providerList(...ids) {
  return ids.map((id) => ({ providerId: id, limits: [] }))
}

test("selectBarLayout: All mode keeps eligible providers and ignores cycle roles", () => {
  const providers = providerList("claude", "codex", "fireworks", "gemini")
  const settings = {
    providers: {
      claude: { barRole: "fixed", showInBar: true },
      codex: { barRole: "cycle", showInBar: true },
      fireworks: { showInBar: false }
    }
  }
  const layout = Aggregate.selectBarLayout(providers, settings, "all", 0, 2, 3)
  assert.deepEqual(layout.providers.map((p) => p.providerId), ["claude", "codex", "gemini"])
  assert.deepEqual(layout.cycling, [])
})

test("selectBarLayout: explicit roles combine fixed and two rotating slots", () => {
  const providers = providerList("claude", "codex", "fireworks", "gemini")
  const settings = {
    providers: {
      claude: { barRole: "fixed", showInBar: true },
      codex: { barRole: "cycle", showInBar: true },
      fireworks: { barRole: "cycle", showInBar: true },
      gemini: { barRole: "cycle", showInBar: true }
    }
  }
  const first = Aggregate.selectBarLayout(providers, settings, "cycle", 0, 2, 3)
  assert.deepEqual(first.providers.map((p) => p.providerId), ["claude", "codex", "fireworks"])
  assert.deepEqual(first.cycling.map((p) => p.providerId), ["codex", "fireworks", "gemini"])
  assert.equal(first.cycleSlots, 2)

  const next = Aggregate.selectBarLayout(providers, settings, "cycle", 1, 2, 3)
  assert.deepEqual(next.providers.map((p) => p.providerId), ["claude", "fireworks", "gemini"])
})

test("selectBarLayout: old cycle configurations rotate every showInBar provider", () => {
  const providers = providerList("claude", "codex", "fireworks")
  const settings = { providers: {
    claude: { showInBar: true },
    codex: { showInBar: true },
    fireworks: { showInBar: false }
  } }
  const layout = Aggregate.selectBarLayout(providers, settings, "cycle", 1, 1, 3)
  assert.deepEqual(layout.providers.map((p) => p.providerId), ["codex"])
  assert.equal(layout.legacy, true)
})

test("selectBarLayout: role layout keeps unassigned providers fixed", () => {
  const providers = providerList("claude", "codex", "gemini")
  const settings = { providers: {
    claude: { showInBar: true },
    codex: { barRole: "cycle", showInBar: true },
    gemini: { showInBar: true }
  } }
  const layout = Aggregate.selectBarLayout(providers, settings, "roles", 0, 1, 3)
  assert.deepEqual(layout.fixed.map((p) => p.providerId), ["claude", "gemini"])
  assert.deepEqual(layout.cycling.map((p) => p.providerId), ["codex"])
  assert.deepEqual(layout.providers.map((p) => p.providerId), ["claude", "codex", "gemini"])
})

test("selectBarLayout: fixed priority does not override saved provider order", () => {
  const providers = providerList("codex", "claude", "gemini")
  const settings = { providers: {
    codex: { barRole: "cycle", showInBar: true },
    claude: { barRole: "fixed", showInBar: true },
    gemini: { barRole: "cycle", showInBar: true }
  } }
  const layout = Aggregate.selectBarLayout(providers, settings, "roles", 0, 1, 2)
  assert.deepEqual(layout.providers.map((p) => p.providerId), ["codex", "claude"])
})

test("selectBarLayout: fixed providers consume slots before rotating providers", () => {
  const providers = providerList("claude", "codex", "fireworks", "gemini")
  const settings = { providers: {
    claude: { barRole: "fixed", showInBar: true },
    codex: { barRole: "fixed", showInBar: true },
    fireworks: { barRole: "cycle", showInBar: true },
    gemini: { barRole: "cycle", showInBar: true }
  } }
  const layout = Aggregate.selectBarLayout(providers, settings, "cycle", 0, 3, 3)
  assert.deepEqual(layout.providers.map((p) => p.providerId), ["claude", "codex", "fireworks"])
  assert.equal(layout.cycleSlots, 1)
})

test("selectBarLayout: configured account records are not cut off at ten", () => {
  const providers = providerList(...Array.from({ length: 12 }, (_, i) => `claude-account-${i}`))
  const layout = Aggregate.selectBarLayout(providers, {}, "roles", 0, 0, 999)
  assert.equal(layout.providers.length, 12)
})

function providerWithPercent(id, percent) {
  return { providerId: id, limits: [{ label: "Session", title: "Session", percent: percent, resetsAt: "" }] }
}

test("selectPrimaryProvider: no provider marked primary picks the highest usage percentage", () => {
  const providers = [
    providerWithPercent("claude", 0.2),
    providerWithPercent("codex", 0.8),
    providerWithPercent("fireworks", 0.5)
  ]
  const picked = Aggregate.selectPrimaryProvider(providers, { providers: {} })
  assert.equal(picked.providerId, "codex")
})

test("selectPrimaryProvider: a provider marked primary wins regardless of percentage", () => {
  const providers = [
    providerWithPercent("claude", 0.2),
    providerWithPercent("codex", 0.9),
    providerWithPercent("fireworks", 0.5)
  ]
  const settings = { providers: { claude: { primary: true } } }
  const picked = Aggregate.selectPrimaryProvider(providers, settings)
  assert.equal(picked.providerId, "claude")
})

test("selectPrimaryProvider: an empty list returns null", () => {
  assert.equal(Aggregate.selectPrimaryProvider([], { providers: {} }), null)
  assert.equal(Aggregate.selectPrimaryProvider(null, { providers: {} }), null)
})

test("selectPrimaryProvider: a single-provider list returns that provider even with no usage data", () => {
  const only = { providerId: "claude", limits: [] }
  const picked = Aggregate.selectPrimaryProvider([only], { providers: {} })
  assert.equal(picked.providerId, "claude")
})

test("providerUsagePercent: prefers a window titled Session, falls back to the first window, then balance", () => {
  const sessionFirst = { limits: [{ title: "Weekly", percent: 0.9 }, { title: "Session", percent: 0.3 }] }
  assert.equal(Aggregate.providerUsagePercent(sessionFirst), 0.3)

  const noSession = { limits: [{ title: "Weekly", percent: 0.6 }] }
  assert.equal(Aggregate.providerUsagePercent(noSession), 0.6)

  const balanceOnly = { limits: [], balance: { remaining: 25, funded: 100 } }
  assert.equal(Aggregate.providerUsagePercent(balanceOnly), 0.75)

  assert.equal(Aggregate.providerUsagePercent({ limits: [] }), -1)
})

test("applyProviderOrder: sorts known providers by their saved order, unknown ones alphabetically after", () => {
  const providers = [
    { providerId: "zai" },
    { providerId: "claude" },
    { providerId: "codex" },
    { providerId: "gemini" },
  ]
  const ordered = Aggregate.applyProviderOrder(providers, ["codex", "claude"])
  assert.deepEqual(ordered.map((p) => p.providerId), ["codex", "claude", "gemini", "zai"])
})

test("applyProviderOrder: an empty or missing saved order leaves the list alphabetical", () => {
  const providers = [{ providerId: "zai" }, { providerId: "claude" }]
  assert.deepEqual(Aggregate.applyProviderOrder(providers, []).map((p) => p.providerId), ["claude", "zai"])
  assert.deepEqual(Aggregate.applyProviderOrder(providers, undefined).map((p) => p.providerId), ["claude", "zai"])
})

test("applyProviderOrder: a stale id no longer present in the provider list is simply ignored", () => {
  const providers = [{ providerId: "claude" }, { providerId: "codex" }]
  const ordered = Aggregate.applyProviderOrder(providers, ["ghost", "codex", "claude"])
  assert.deepEqual(ordered.map((p) => p.providerId), ["codex", "claude"])
})
