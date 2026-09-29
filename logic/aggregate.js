// Pure merge/aggregation logic for per-provider usage state.
//
// Moved out of Main.qml (see issue #1): this file only ever sees plain
// objects/arrays/numbers/strings — usage records read off disk, sync
// snapshots read from other machines, and the per-provider state the panel
// renders. No QML types, no Process/FileView/Timer, nothing Quickshell-only.
// That keeps it runnable under plain Node (see the module.exports guard at
// the bottom) as well as importable from QML via
// `import "logic/aggregate.js" as Aggregate`.

// ---------------------------------------------------------- untrusted input
//
// Everything in this section sanitizes values that ultimately come from a
// usage record or a synced snapshot — content Main.qml never generated and,
// in the synced case, never even generated on this machine. All of it can
// reach native QML Text/Button/Image sinks in Panel.qml, most of which are
// shared Omarchy components this plugin doesn't own and can't set
// textFormat on directly. Neutralizing the risky characters and capping
// sizes here, once, covers every sink at once.

// Records and synced snapshots are untrusted. Use prototype-less maps for
// every collection keyed by a provider, model, device, or saved order id so
// names such as `constructor` and `toString` are ordinary data keys rather
// than inherited JavaScript properties.
function safeMap() {
  return Object.create(null)
}

function numberValue(value) {
  var n = Number(value || 0)
  return isFinite(n) ? Math.round(n) : 0
}

// A provider id feeds straight into an asset path (Qt.resolvedUrl("assets/"
// + id + ".svg")) in Panel.qml, so it must never contain path separators or
// traversal segments — restrict it to a safe, filename-like charset.
function sanitizeProviderId(raw) {
  var value = String(raw || "").trim()
  value = value.replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^[-_.]+|[-_.]+$/g, "")
  if (value === "") value = "agent"
  return value.length > 64 ? value.substring(0, 64) : value
}

// A brand names which provider's mark a record renders with — an account
// record like `claude-work` declaring `"brand": "claude"` gets the Claude
// mark instead of the generic glyph. It feeds the same asset-path lookup as
// a provider id, so the same charset rules apply; unlike an id, an absent
// or unusable value collapses to "" (render by the record's own id).
function sanitizeBrand(raw) {
  var value = String(raw || "").trim()
  value = value.replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^[-_.]+|[-_.]+$/g, "")
  return value.length > 64 ? value.substring(0, 64) : value
}

// Strips control characters and the characters QML's rich-text detection
// keys off of (`<`, `>`, `&`), so a record can't get itself rendered as
// markup regardless of which Text/Button component ends up displaying it.
// Also caps length so one field can't blow up a panel's layout.
function sanitizeDisplayText(raw, maxLen) {
  var text = raw === undefined || raw === null ? "" : String(raw)
  text = text.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
  text = text.replace(/[<>&]/g, "")
  var limit = maxLen || 200
  return text.length > limit ? text.substring(0, limit) : text
}

// Rate-limit windows come straight from a usage record; cap how many are
// trusted and sanitize the free-text fields before they reach LimitRow.
function sanitizeLimits(raw) {
  var list = Array.isArray(raw) ? raw : []
  var out = []
  for (var i = 0; i < list.length && out.length < 20; i++) {
    var entry = list[i] || {}
    out.push({
      label: sanitizeDisplayText(entry.label, 80),
      title: sanitizeDisplayText(entry.title, 80),
      percent: entry.percent,
      tokenLimit: numberValue(entry.tokenLimit),
      resetsAt: sanitizeDisplayText(entry.resetsAt, 40),
      // Optional, but required for a defensible pace projection: guessing a
      // window length from its label makes an estimate look more certain than
      // the underlying data is.
      startedAt: sanitizeDisplayText(entry.startedAt, 40)
    })
  }
  return out
}

function capRecentDays(raw) {
  var list = Array.isArray(raw) ? raw : []
  return list.length > 31 ? list.slice(0, 31) : list
}

// Bounds how many distinct model ids a single record/snapshot can push into
// TOKENS BY MODEL bookkeeping, independent of the top-4 Panel.qml already
// displays — that slice happens after this data is built and merged.
function capModelUsage(raw) {
  var usage = raw && typeof raw === "object" ? raw : {}
  var out = safeMap()
  var count = 0
  for (var id in usage) {
    if (count >= 100) break
    // TokenBucket is canonical for both modelUsage and
    // todayTokensByModel. Dropping a malformed scalar is safer than silently
    // turning it into a made-up input-token count.
    if (!usage[id] || typeof usage[id] !== "object") continue
    out[sanitizeDisplayText(id, 80)] = tokenBucketValue(usage[id])
    count++
  }
  return out
}

function cloneValue(value, fallback) {
  if (value === undefined || value === null) return fallback
  try {
    return JSON.parse(JSON.stringify(value))
  } catch (e) {
    return fallback
  }
}

// Device ids identify a machine inside a synced snapshot file name and
// payload; `fallback` is resolved by the caller (Main.qml falls back to
// $HOSTNAME/$HOST/$USER, aggregateSnapshots below falls back to the literal
// "device") since environment lookups are QML/Quickshell territory, not
// something this module should know about.
function sanitizeDeviceId(raw, fallback) {
  var value = String(raw || "").trim()
  if (value === "") value = String(fallback || "device")
  value = value.replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^[._-]+|[._-]+$/g, "")
  if (value === "") value = "device"
  return value.length > 80 ? value.substring(0, 80) : value
}

// A prepaid agent's credit ledger. Like rate limits, the balance is
// per-account and never merged across devices.
function balanceValue(raw) {
  if (!raw || typeof raw !== "object") return null
  var remaining = Number(raw.remaining)
  var funded = Number(raw.funded)
  if (!isFinite(remaining) || remaining < 0) return null
  return {
    remaining: remaining,
    funded: isFinite(funded) && funded > 0 ? funded : 0,
    spent: Math.max(0, Number(raw.spent) || 0),
    currency: sanitizeDisplayText(raw.currency || "USD", 10),
    estimated: raw.estimated === true
  }
}

// An optional, collector-reported *derived estimate* of what usage would
// cost at published API rates (issue #12) — never a real ledger figure the
// way `balance` is, which is why the panel always labels it as an estimate
// rather than treating it like billing. Like `limits`/`balance`, this is
// per-account and never merged across synced devices.
function costValue(raw) {
  if (!raw || typeof raw !== "object") return null
  var estimateUsd = Number(raw.estimateUsd)
  if (!isFinite(estimateUsd) || estimateUsd < 0) return null

  var byModelIn = Array.isArray(raw.byModel) ? raw.byModel : []
  var byModel = []
  for (var i = 0; i < byModelIn.length && byModel.length < 100; i++) {
    var entry = byModelIn[i] || {}
    var usd = Number(entry.usd)
    byModel.push({
      model: sanitizeDisplayText(entry.model, 80),
      usd: isFinite(usd) && usd >= 0 ? usd : 0,
      tokens: numberValue(entry.tokens)
    })
  }

  var byDayIn = Array.isArray(raw.byDay) ? raw.byDay : []
  var byDay = []
  for (var d = 0; d < byDayIn.length && byDay.length < 31; d++) {
    var day = byDayIn[d] || {}
    var dayUsd = Number(day.usd)
    byDay.push({
      date: sanitizeDisplayText(day.date, 20),
      usd: isFinite(dayUsd) && dayUsd >= 0 ? dayUsd : 0
    })
  }

  var activeDays = Number(raw.activeDays)
  activeDays = isFinite(activeDays) && activeDays > 0
    ? Math.min(100000, Math.floor(activeDays)) : 0

  return {
    estimateUsd: estimateUsd,
    period: sanitizeDisplayText(raw.period, 20),
    pricingVersion: sanitizeDisplayText(raw.pricingVersion, 40),
    incomplete: raw.incomplete === true,
    unknownModels: Array.isArray(raw.unknownModels) ? raw.unknownModels.slice(0, 20).map(function(model) {
      return sanitizeDisplayText(model, 80)
    }).filter(function(model) { return !!model }) : [],
    pricedTokens: numberValue(raw.pricedTokens),
    unpricedTokens: numberValue(raw.unpricedTokens),
    activeDays: activeDays,
    byModel: byModel,
    byDay: byDay
  }
}

// ------------------------------------------------------------ day buckets

function dateString(date) {
  var y = date.getFullYear()
  var m = String(date.getMonth() + 1).padStart(2, "0")
  var d = String(date.getDate()).padStart(2, "0")
  return y + "-" + m + "-" + d
}

function recentDateStrings() {
  var result = []
  for (var offset = 6; offset >= 0; offset--) {
    var date = new Date()
    date.setDate(date.getDate() - offset)
    result.push(dateString(date))
  }
  return result
}

function emptyTokenBucket() {
  return { inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 }
}

function tokenBucketValue(raw) {
  var bucket = raw && typeof raw === "object" ? raw : {}
  return {
    inputTokens: numberValue(bucket.inputTokens),
    outputTokens: numberValue(bucket.outputTokens),
    cacheReadInputTokens: numberValue(bucket.cacheReadInputTokens),
    cacheCreationInputTokens: numberValue(bucket.cacheCreationInputTokens)
  }
}

// Device-scoped stats add up across machines; account-scoped stats
// (Fireworks' billing API) are replicas of the same upstream truth on
// every synced device, so the widest value wins — summing them would
// double every token per machine.
function combineNumber(additive, current, value) {
  return additive ? numberValue(current) + numberValue(value) : Math.max(numberValue(current), numberValue(value))
}

function combineObjectNumbers(additive, target, source) {
  if (!source) return
  for (var key in source) target[key] = combineNumber(additive, target[key], source[key])
}

function combineTokenBuckets(additive, target, source) {
  var bucket = tokenBucketValue(source)
  target.inputTokens = combineNumber(additive, target.inputTokens, bucket.inputTokens)
  target.outputTokens = combineNumber(additive, target.outputTokens, bucket.outputTokens)
  target.cacheReadInputTokens = combineNumber(additive, target.cacheReadInputTokens, bucket.cacheReadInputTokens)
  target.cacheCreationInputTokens = combineNumber(additive, target.cacheCreationInputTokens, bucket.cacheCreationInputTokens)
}

// -------------------------------------------------------------- snapshots

// Merges one or more synced snapshots (one per machine) into per-provider
// totals. Moved verbatim out of Main.qml's `providers[id]` accumulator and
// `snapshotProviders` loop — see the issue #1 write-up for why this needed
// to be testable outside of QML: every later bar-mode/threshold/history
// feature builds on top of this merge.
function aggregateSnapshots(snapshots, maxSnapshots) {
  var snapshotLimit = maxSnapshots || 50
  var dates = recentDateStrings()
  var devices = safeMap()
  var providers = safeMap()

  function providerAcc(id) {
    if (providers[id]) return providers[id]
    var recentByDay = safeMap()
    for (var d = 0; d < dates.length; d++) recentByDay[dates[d]] = 0
    providers[id] = {
      providerId: id,
      providerName: "",
      brand: "",
      ready: false,
      hasLocalStats: false,
      hasPromptStats: false,
      todayPrompts: 0,
      todaySessions: 0,
      todayTotalTokens: 0,
      todayTokensByModel: safeMap(),
      recentByDay: recentByDay,
      totalPrompts: 0,
      totalSessions: 0,
      activeDays: 0,
      activeDates: safeMap(),
      modelUsage: safeMap(),
      devices: safeMap()
    }
    return providers[id]
  }

  // Snapshots are written by other machines over whatever transport backs
  // the sync directory, so every shape and size below is untrusted. The
  // caps here (snapshot count, providers per snapshot, distinct providers
  // overall, and the per-collection loops) bound the CPU and memory this
  // merge can be made to spend, on top of the file-count/size limits the
  // scan itself already enforces.
  var snapshotCap = Math.min(snapshots.length, snapshotLimit)
  for (var i = 0; i < snapshotCap; i++) {
    var snapshot = snapshots[i]
    var device = sanitizeDeviceId(snapshot.deviceId, "device")
    devices[device] = true
    var snapshotProviders = snapshot.providers || {}
    var providerCount = 0
    for (var rawProviderId in snapshotProviders) {
      if (++providerCount > 100) break
      var providerId = sanitizeProviderId(rawProviderId)
      if (!providers[providerId] && Object.keys(providers).length >= 100) continue
      var stats = snapshotProviders[rawProviderId] || {}
      var acc = providerAcc(providerId)
      acc.devices[device] = true
      if (stats.providerName && acc.providerName === "") acc.providerName = sanitizeDisplayText(stats.providerName, 80)
      if (stats.brand && acc.brand === "") acc.brand = sanitizeBrand(stats.brand)
      acc.ready = acc.ready || stats.ready === true
      acc.hasLocalStats = acc.hasLocalStats || stats.hasLocalStats !== false
      // Snapshots from before the field existed only came from agents that
      // count prompts, so a missing value reads as true.
      acc.hasPromptStats = acc.hasPromptStats || stats.hasPromptStats !== false
      var additive = String(stats.scope || "device") !== "account"
      acc.todayPrompts = combineNumber(additive, acc.todayPrompts, stats.todayPrompts)
      acc.todaySessions = combineNumber(additive, acc.todaySessions, stats.todaySessions)
      acc.todayTotalTokens = combineNumber(additive, acc.todayTotalTokens, stats.todayTotalTokens)
      acc.totalPrompts = combineNumber(additive, acc.totalPrompts, stats.totalPrompts)
      acc.totalSessions = combineNumber(additive, acc.totalSessions, stats.totalSessions)
      // Active days overlap between machines, so union the dates rather than
      // summing counts. Snapshots written before activeDates existed only
      // carry a count; the widest one stands in for them.
      var activeDates = Array.isArray(stats.activeDates) ? stats.activeDates : []
      for (var ad = 0; ad < activeDates.length && ad < 400; ad++) {
        if (Object.keys(acc.activeDates).length >= 1000) break
        acc.activeDates[String(activeDates[ad]).slice(0, 20)] = true
      }
      acc.activeDays = Math.max(acc.activeDays, numberValue(stats.activeDays))
      var todayUsage = capModelUsage(stats.todayTokensByModel)
      for (var todayModelId in todayUsage) {
        var todayBucket = acc.todayTokensByModel[todayModelId]
        if (!todayBucket) todayBucket = acc.todayTokensByModel[todayModelId] = emptyTokenBucket()
        combineTokenBuckets(additive, todayBucket, todayUsage[todayModelId])
      }

      var recent = Array.isArray(stats.recentDays) ? stats.recentDays : []
      for (var r = 0; r < recent.length && r < 366; r++) {
        var day = recent[r] || {}
        var date = String(day.date || "")
        if (acc.recentByDay[date] !== undefined)
          acc.recentByDay[date] = combineNumber(additive, acc.recentByDay[date], day.messageCount)
      }

      var usage = capModelUsage(stats.modelUsage)
      for (var modelId in usage) {
        var bucket = acc.modelUsage[modelId]
        if (!bucket) bucket = acc.modelUsage[modelId] = emptyTokenBucket()
        combineTokenBuckets(additive, bucket, usage[modelId])
      }
    }
  }

  var outProviders = safeMap()
  for (var id in providers) {
    var acc2 = providers[id]
    var recentDays = []
    for (var di = 0; di < dates.length; di++) recentDays.push({ date: dates[di], messageCount: acc2.recentByDay[dates[di]] || 0 })
    var providerDevices = Object.keys(acc2.devices).sort()
    outProviders[id] = {
      providerId: acc2.providerId,
      providerName: acc2.providerName,
      brand: acc2.brand,
      ready: acc2.ready || providerDevices.length > 0,
      hasLocalStats: acc2.hasLocalStats,
      hasPromptStats: acc2.hasPromptStats,
      todayPrompts: acc2.todayPrompts,
      todaySessions: acc2.todaySessions,
      todayTotalTokens: acc2.todayTotalTokens,
      todayTokensByModel: acc2.todayTokensByModel,
      recentDays: recentDays,
      totalPrompts: acc2.totalPrompts,
      totalSessions: acc2.totalSessions,
      activeDays: Math.max(acc2.activeDays, Object.keys(acc2.activeDates).length),
      modelUsage: acc2.modelUsage,
      deviceCount: providerDevices.length,
      devices: providerDevices
    }
  }

  return {
    schemaVersion: 1,
    updatedAt: new Date().toISOString(),
    updatedAtMs: Date.now(),
    deviceCount: Object.keys(devices).length,
    devices: Object.keys(devices).sort(),
    providers: outProviders
  }
}

// Snapshots keep the field names older Omarchy versions wrote, so a fleet
// of machines on mixed versions still merges cleanly in both directions.
// This is also what this machine writes into the shared sync directory, so
// it gets sanitized and capped just like an incoming snapshot: a corrupted
// or hostile local record shouldn't be able to use the fleet's own sync
// mechanism to push oversized or malformed data onto every other machine.
function providerSnapshot(record) {
  return {
    providerId: sanitizeProviderId(record.id),
    providerName: sanitizeDisplayText(record.name || record.id, 80),
    brand: sanitizeBrand(record.brand),
    ready: record.ready === true,
    hasLocalStats: record.hasLocalStats !== false,
    hasPromptStats: record.hasPromptStats !== false,
    scope: String(record.scope || "device"),
    todayPrompts: numberValue(record.todayPrompts),
    todaySessions: numberValue(record.todaySessions),
    todayTotalTokens: numberValue(record.todayTotalTokens),
    todayTokensByModel: capModelUsage(record.todayTokensByModel),
    recentDays: capRecentDays(cloneValue(record.recentDays, [])),
    totalPrompts: numberValue(record.totalPrompts),
    totalSessions: numberValue(record.totalSessions),
    activeDays: numberValue(record.activeDays),
    activeDates: cloneValue(record.activeDates, []).slice(0, 400),
    modelUsage: capModelUsage(record.modelUsage)
  }
}

// Builds the snapshot this machine writes into the shared sync directory.
// `records` is the raw `agent.record` list (nulls allowed, exactly as
// Main.qml's `agents` Instantiator produces them); `isProviderEnabled(id)`
// mirrors Main.qml's settings-backed `providerEnabled()`.
function buildLocalSnapshot(records, deviceId, isProviderEnabled) {
  var list = Array.isArray(records) ? records : []
  var providerMap = safeMap()
  var count = 0
  for (var i = 0; i < list.length; i++) {
    var record = list[i]
    if (!record || !record.id) continue
    var id = sanitizeProviderId(record.id)
    if (isProviderEnabled && !isProviderEnabled(id)) continue
    if (++count > 100) break
    providerMap[id] = providerSnapshot(record)
  }
  return {
    schemaVersion: 1,
    deviceId: deviceId,
    updatedAt: new Date().toISOString(),
    providers: providerMap
  }
}

// Combines the per-model token buckets of every given provider display
// object into one map, keyed by model id — same shape as a single
// provider's `modelUsage`, so any caller that already knows how to turn a
// `modelUsage` map into display rows (Panel.qml's modelRows/modelUsageRows)
// can reuse it unchanged. Built for the expanded panel view (issue #7),
// which shows one "tokens by model" table across every enabled provider
// instead of just the currently selected chip.
//
// Providers report disjoint model ids in practice (each vendor names its
// own models), so summing unconditionally is safe; on the rare case two
// providers happen to share a model id, this is a "combined view" and
// summing is exactly what a reader would expect from a fleet-wide total.
function allProviderModelUsage(providers) {
  var list = Array.isArray(providers) ? providers : []
  var combined = safeMap()
  for (var i = 0; i < list.length; i++) {
    var provider = list[i] || {}
    var usage = capModelUsage(provider.modelUsage)
    for (var modelId in usage) {
      var bucket = combined[modelId]
      if (!bucket) bucket = combined[modelId] = emptyTokenBucket()
      combineTokenBuckets(true, bucket, usage[modelId])
    }
  }
  return combined
}

// --------------------------------------------------------- display state

// Merges one usage record with its synced counterpart (if any) into the
// per-provider object the panel actually renders. `stats` is the entry from
// an already-aggregated sync snapshot (aggregateSnapshots' output), or null
// when this provider has no synced data. `aggregateMeta` carries the two
// snapshot-level fields (deviceCount, updatedAt) this merge needs but that
// live outside any single provider's stats.
function mergeProviderDisplay(record, stats, aggregateMeta) {
  var meta = aggregateMeta || {}
  var providerId = sanitizeProviderId(record.id)
  var synced = !!stats
  var deviceCount = synced ? Number(stats.deviceCount || meta.deviceCount || 0) : 0

  return {
    providerId: providerId,
    providerName: sanitizeDisplayText(record.name || record.id, 80),
    brand: sanitizeBrand(record.brand) || (synced ? sanitizeBrand(stats.brand) : ""),
    ready: record.ready === true || synced,
    usageStatusText: sanitizeDisplayText(record.usageStatusText, 200),
    authHelpText: sanitizeDisplayText(record.authHelpText, 300),

    // Rate limits and balances stay per-account and are never merged
    // across devices.
    limits: sanitizeLimits(record.limits),
    tierLabel: sanitizeDisplayText(record.tierLabel, 60),
    balance: balanceValue(record.balance),
    cost: costValue(record.cost),

    todayPrompts: synced ? numberValue(stats.todayPrompts) : numberValue(record.todayPrompts),
    todaySessions: synced ? numberValue(stats.todaySessions) : numberValue(record.todaySessions),
    todayTotalTokens: synced ? numberValue(stats.todayTotalTokens) : numberValue(record.todayTotalTokens),
    todayTokensByModel: synced ? capModelUsage(stats.todayTokensByModel) : capModelUsage(record.todayTokensByModel),
    recentDays: synced ? capRecentDays(stats.recentDays) : capRecentDays(record.recentDays),
    totalPrompts: synced ? numberValue(stats.totalPrompts) : numberValue(record.totalPrompts),
    totalSessions: synced ? numberValue(stats.totalSessions) : numberValue(record.totalSessions),
    activeDays: synced ? numberValue(stats.activeDays) : numberValue(record.activeDays),
    modelUsage: synced ? capModelUsage(stats.modelUsage) : capModelUsage(record.modelUsage),
    hasLocalStats: synced ? (stats.hasLocalStats !== false) : (record.hasLocalStats !== false),
    hasPromptStats: synced ? (stats.hasPromptStats !== false) : (record.hasPromptStats !== false),

    syncEnabled: synced,
    syncDeviceCount: deviceCount,
    syncUpdatedAt: meta.updatedAt || ""
  }
}

// Narrows an already-built provider display list down to the ones that
// should take up space in the bar itself. `enabled` still gates both the
// panel and the bar (a disabled provider is never collected, so it never
// has a display object to begin with, but honor it here too in case a
// caller passes an unfiltered list). `showInBar` only gates the bar: a
// provider with `enabled: true, showInBar: false` stays reachable as a
// chip in the panel — callers building that chip list must keep using
// `enabled` alone and not run the result through this function. Both flags
// default to true, so a `shell.json` written before `showInBar` existed
// (or one that never sets `enabled`) behaves exactly as it did before this
// function existed.
function selectBarProviders(providers, settings) {
  var list = Array.isArray(providers) ? providers : []
  var providerSettings = settings && settings.providers ? settings.providers : {}
  return list.filter(function(p) {
    var id = p && p.providerId
    var cfg = id && providerSettings[id] ? providerSettings[id] : {}
    return cfg.enabled !== false && cfg.showInBar !== false
  })
}

// Applies a user's saved drag-to-reorder result to a provider list. `order`
// is a plain array of provider ids (most-recent drag wins, oldest first);
// anything in `providers` that isn't in it yet — a provider added after the
// order was last saved — is appended afterwards in alphabetical order, so a
// newly discovered provider gets a stable, predictable spot instead of
// jumping to wherever object-insertion order happened to put it. Used for
// both the settings list and (via Main.qml's enabledProviders) the bar and
// panel switcher, so dragging a mark in one place reorders it everywhere.
function applyProviderOrder(providers, order) {
  var list = Array.isArray(providers) ? providers : []
  var orderList = Array.isArray(order) ? order : []
  var rank = safeMap()
  for (var i = 0; i < orderList.length; i++) {
    var id = orderList[i]
    if (typeof id === "string" && !(id in rank)) rank[id] = i
  }
  var known = []
  var unknown = []
  for (var j = 0; j < list.length; j++) {
    var item = list[j]
    var pid = item && item.providerId
    if (typeof pid === "string" && Object.prototype.hasOwnProperty.call(rank, pid)) known.push(item)
    else unknown.push(item)
  }
  known.sort(function(a, b) { return rank[a.providerId] - rank[b.providerId] })
  unknown.sort(function(a, b) {
    return a.providerId < b.providerId ? -1 : (a.providerId > b.providerId ? 1 : 0)
  })
  return known.concat(unknown)
}

// Builds the compact bar layout used by Main.qml. `showInBar` remains the
// compatibility gate: false always means the provider is out of the bar.
// Newer settings can add `barRole` (`fixed` or `cycle`) to choose whether an
// eligible provider stays visible or participates in the rotating pool.
// Providers without an explicit role are fixed. `legacy-cycle` is reserved
// for an old saved global cycle setting, where every showInBar provider used
// to rotate before per-provider roles existed.
//
// `cycleSlots` is the number of rotating meters visible at once. The result
// is capped by `slotLimit` so a large provider set cannot stretch the bar.
// Fixed providers are selected first when slots are scarce, followed by a
// contiguous rotating slice; the final visible list is put back into the
// caller's provider order so the bar and panel never disagree visually.
function selectBarLayout(providers, settings, mode, cycleIndex, cycleSlots, slotLimit) {
  var list = Array.isArray(providers) ? providers : []
  var eligible = selectBarProviders(list, settings)
  var providerSettings = settings && settings.providers ? settings.providers : {}
  var explicitRoles = false
  for (var r = 0; r < eligible.length; r++) {
    var roleValue = eligible[r] && providerSettings[eligible[r].providerId]
      ? providerSettings[eligible[r].providerId].barRole : ""
    if (roleValue === "fixed" || roleValue === "cycle") {
      explicitRoles = true
      break
    }
  }

  var fixed = []
  var cycling = []
  var layoutMode = String(mode || "all")
  var cycleMode = layoutMode === "cycle" || layoutMode === "roles"
    || layoutMode === "legacy-cycle"
  var legacyCycle = layoutMode === "cycle" || layoutMode === "legacy-cycle"
  for (var i = 0; i < eligible.length; i++) {
    var provider = eligible[i]
    var id = provider && provider.providerId
    var cfg = id && providerSettings[id] ? providerSettings[id] : {}
    var role = cfg.barRole === "cycle" ? "cycle" : "fixed"
    // Preserve the pre-role global-cycle behavior only for an old setting.
    if (legacyCycle && !explicitRoles && cfg.barRole !== "fixed") role = "cycle"
    if (cycleMode && role === "cycle") cycling.push(provider)
    else fixed.push(provider)
  }

  var limit = Number(slotLimit)
  if (!isFinite(limit) || limit < 0) limit = 3
  // Account profiles can add records beyond the bundled collector count.
  // The eligible list is the real upper bound on visible bar providers.
  limit = Math.max(0, Math.min(eligible.length, Math.floor(limit)))

  if (!cycleMode) {
    return {
      providers: eligible.slice(0, limit),
      fixed: eligible.slice(),
      cycling: [],
      cycleSlots: 0,
      legacy: false
    }
  }

  var fixedVisible = fixed.slice(0, limit)
  var availableSlots = Math.max(0, limit - fixedVisible.length)
  var requestedSlots = Number(cycleSlots)
  if (!isFinite(requestedSlots)) requestedSlots = 1
  requestedSlots = Math.max(0, Math.min(availableSlots, Math.floor(requestedSlots)))
  var index = Number(cycleIndex)
  if (!isFinite(index)) index = 0
  index = Math.floor(index)
  var rotating = []
  if (cycling.length > 0 && requestedSlots > 0) {
    for (var c = 0; c < requestedSlots && c < cycling.length; c++) {
      var offset = ((index + c) % cycling.length + cycling.length) % cycling.length
      rotating.push(cycling[offset])
    }
  }

  // Fixed providers still win the capacity calculation above, but their
  // role must not silently override the person's drag-to-reorder choice.
  // Sorting the selected subset against `eligible` also keeps every visible
  // bar group in exactly the same order as the panel switcher.
  var visible = fixedVisible.concat(rotating)
  visible.sort(function(a, b) { return eligible.indexOf(a) - eligible.indexOf(b) })

  return {
    providers: visible,
    fixed: fixed,
    cycling: cycling,
    cycleSlots: requestedSlots,
    legacy: !explicitRoles
  }
}

// A pure, provider-selection-only approximation of Panel.qml's
// providerPercent() (issue #5's `barMode: "primary"`). Panel.qml's version
// is the source of truth for what a bar meter actually *displays* — it
// prefers a window titled "Session" (falling back to whatever windowTitle()
// infers from the label's wording, which depends on QML-side helpers this
// file intentionally has no access to), then falls back to a balance-based
// fraction. This mirrors just the parts knowable from the sanitized
// `limits`/`balance` fields alone: a window whose own title/label already
// says "session" wins, otherwise the first reported window with a valid
// percent, otherwise the balance-used fraction, otherwise -1 (no data).
// Good enough to rank providers by "how full is it"; never used for display.
function providerUsagePercent(p) {
  var limits = p && Array.isArray(p.limits) ? p.limits : []
  var firstPercent = -1
  var sessionPercent = -1
  for (var i = 0; i < limits.length; i++) {
    var entry = limits[i] || {}
    var percent = Number(entry.percent)
    if (!(percent >= 0)) continue
    if (firstPercent < 0) firstPercent = percent
    var title = String(entry.title || entry.label || "").toLowerCase()
    if (sessionPercent < 0 && title.indexOf("session") >= 0) sessionPercent = percent
  }
  if (sessionPercent >= 0) return sessionPercent
  if (firstPercent >= 0) return firstPercent
  if (p && p.balance && p.balance.funded > 0) return 1 - Number(p.balance.remaining) / Number(p.balance.funded)
  return -1
}

// `barMode: "primary"` (issue #5): picks exactly one provider out of an
// already-`selectBarProviders`-filtered list. A provider explicitly marked
// `primary: true` in its own settings entry always wins, regardless of
// usage; with no such provider, the one with the highest current usage
// percentage (providerUsagePercent above) wins; ties keep the first (list
// order, same order the bar itself would otherwise render them in). Returns
// null for an empty list so callers can turn that into an empty
// `barProviders` array without a special case.
function selectPrimaryProvider(providers, settings) {
  var list = Array.isArray(providers) ? providers : []
  if (list.length === 0) return null
  var providerSettings = settings && settings.providers ? settings.providers : {}
  for (var i = 0; i < list.length; i++) {
    var id = list[i] && list[i].providerId
    var cfg = id && providerSettings[id] ? providerSettings[id] : {}
    if (cfg.primary === true) return list[i]
  }
  var best = list[0]
  var bestPercent = providerUsagePercent(best)
  for (var j = 1; j < list.length; j++) {
    var percent = providerUsagePercent(list[j])
    if (percent > bestPercent) {
      best = list[j]
      bestPercent = percent
    }
  }
  return best
}

// All-time keeps a quiet day from hiding an agent; today's counts admit a
// machine whose only source is history.jsonl, which knows nothing older.
function providerHasData(p) {
  return numberValue(p.totalPrompts) > 0 || numberValue(p.totalSessions) > 0
    || numberValue(p.activeDays) > 0 || numberValue(p.todayPrompts) > 0
    || numberValue(p.todaySessions) > 0 || (p.limits && p.limits.length > 0)
    || !!p.balance || !!p.cost || p.ready === true
    // An auth or endpoint problem is itself useful state. In particular, a
    // newly installed API-backed collector has no historical local stats to
    // keep it visible, so suppressing this made the documented error record
    // a silent gap in the panel.
    || String(p.usageStatusText || "").trim().length > 0
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    numberValue: numberValue,
    sanitizeProviderId: sanitizeProviderId,
    sanitizeBrand: sanitizeBrand,
    sanitizeDisplayText: sanitizeDisplayText,
    sanitizeLimits: sanitizeLimits,
    capRecentDays: capRecentDays,
    capModelUsage: capModelUsage,
    cloneValue: cloneValue,
    sanitizeDeviceId: sanitizeDeviceId,
    balanceValue: balanceValue,
    costValue: costValue,
    dateString: dateString,
    recentDateStrings: recentDateStrings,
    emptyTokenBucket: emptyTokenBucket,
    tokenBucketValue: tokenBucketValue,
    combineNumber: combineNumber,
    combineObjectNumbers: combineObjectNumbers,
    combineTokenBuckets: combineTokenBuckets,
    aggregateSnapshots: aggregateSnapshots,
    allProviderModelUsage: allProviderModelUsage,
    providerSnapshot: providerSnapshot,
    buildLocalSnapshot: buildLocalSnapshot,
    mergeProviderDisplay: mergeProviderDisplay,
    selectBarProviders: selectBarProviders,
    applyProviderOrder: applyProviderOrder,
    selectBarLayout: selectBarLayout,
    providerUsagePercent: providerUsagePercent,
    selectPrimaryProvider: selectPrimaryProvider,
    providerHasData: providerHasData
  }
}
