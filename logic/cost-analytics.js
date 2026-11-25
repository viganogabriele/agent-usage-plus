// Pure, display-ready summaries for the optional API-rate cost data.
//
// Collectors already validate the cost contract before it reaches QML, but
// this module keeps chart preparation defensive and testable: no UI code has
// to sort untrusted rows, divide by zero, or guess what an empty breakdown
// means.

function nonnegative(value) {
  var number = Number(value)
  return isFinite(number) && number >= 0 ? number : 0
}

function boundedPercent(value) {
  var number = Number(value)
  return isFinite(number) && number >= 0 ? Math.min(1, number) : -1
}

function boundedDayCount(value) {
  var number = Number(value)
  return isFinite(number) && number > 0 ? Math.min(100000, Math.floor(number)) : 0
}

function tokenTotal(cost) {
  var accounted = nonnegative(cost && cost.pricedTokens) + nonnegative(cost && cost.unpricedTokens)
  if (accounted > 0) return accounted
  var rows = cost && Array.isArray(cost.byModel) ? cost.byModel : []
  var total = 0
  for (var i = 0; i < rows.length; i++) total += nonnegative(rows[i] && rows[i].tokens)
  return total
}

function recordedDayCount(cost, provider) {
  var declared = boundedDayCount(cost && cost.activeDays)
  if (declared > 0) return declared

  declared = boundedDayCount(provider && provider.activeDays)
  if (declared > 0) return declared

  var recent = provider && Array.isArray(provider.recentDays) ? provider.recentDays : []
  var active = 0
  for (var i = 0; i < recent.length; i++) {
    if (nonnegative(recent[i] && recent[i].messageCount) > 0) active++
  }
  return active
}

function coverageFor(cost) {
  if (!cost || typeof cost !== "object") return -1
  var priced = nonnegative(cost.pricedTokens)
  var unpriced = nonnegative(cost.unpricedTokens)
  var total = priced + unpriced
  return total > 0 ? priced / total : -1
}

function modelRows(cost) {
  var input = cost && Array.isArray(cost.byModel) ? cost.byModel : []
  var rows = []
  for (var i = 0; i < input.length; i++) {
    var entry = input[i] || {}
    var model = String(entry.model || "")
    if (model === "") continue
    rows.push({
      model: model,
      usd: nonnegative(entry.usd),
      tokens: nonnegative(entry.tokens)
    })
  }

  rows.sort(function(a, b) {
    if (b.usd !== a.usd) return b.usd - a.usd
    if (b.tokens !== a.tokens) return b.tokens - a.tokens
    return a.model < b.model ? -1 : (a.model > b.model ? 1 : 0)
  })

  var total = 0
  for (var j = 0; j < rows.length; j++) total += rows[j].usd
  for (var k = 0; k < rows.length; k++) rows[k].share = total > 0 ? rows[k].usd / total : 0
  return rows
}

function dailyRows(cost) {
  var input = cost && Array.isArray(cost.byDay) ? cost.byDay : []
  var rows = []
  for (var i = 0; i < input.length; i++) {
    var entry = input[i] || {}
    var date = String(entry.date || "")
    if (date === "") continue
    var existing = -1
    for (var j = 0; j < rows.length; j++) {
      if (rows[j].date === date) {
        existing = j
        break
      }
    }
    if (existing >= 0) rows[existing].usd += nonnegative(entry.usd)
    else rows.push({ date: date, usd: nonnegative(entry.usd) })
  }

  rows.sort(function(a, b) { return a.date < b.date ? -1 : (a.date > b.date ? 1 : 0) })
  return rows
}

function summary(cost, provider) {
  var models = modelRows(cost)
  var days = dailyRows(cost)
  var dailyTotalUsd = 0
  var dailyPeakUsd = 0
  var dailyActiveDays = 0
  for (var i = 0; i < days.length; i++) {
    dailyTotalUsd += days[i].usd
    dailyPeakUsd = Math.max(dailyPeakUsd, days[i].usd)
    if (days[i].usd > 0) dailyActiveDays++
  }

  var totalUsd = nonnegative(cost && cost.estimateUsd)
  var recordedDays = recordedDayCount(cost, provider)
  var hasReportedDailyAverage = dailyActiveDays > 0
  var averageDailyUsd = hasReportedDailyAverage
    ? dailyTotalUsd / dailyActiveDays
    : (totalUsd > 0 && recordedDays > 0 ? totalUsd / recordedDays : 0)

  return {
    totalUsd: totalUsd,
    period: String(cost && cost.period || ""),
    models: models,
    days: days,
    // With no byDay matrix, this is the aggregate total used for the
    // recorded-day average, not a claim that every individual day cost the
    // same amount.
    dailyTotalUsd: hasReportedDailyAverage ? dailyTotalUsd : totalUsd,
    dailyPeakUsd: dailyPeakUsd,
    dailyActiveDays: hasReportedDailyAverage ? dailyActiveDays : recordedDays,
    averageDailyUsd: averageDailyUsd,
    averageDailyDays: hasReportedDailyAverage ? dailyActiveDays : recordedDays,
    dailySource: hasReportedDailyAverage ? "reported" : (recordedDays > 0 ? "recorded-days" : "none"),
    hasDailyAverage: hasReportedDailyAverage || (totalUsd > 0 && recordedDays > 0),
    totalTokens: tokenTotal(cost),
    coverage: coverageFor(cost),
    topModel: models.length > 0 ? models[0].model : ""
  }
}

function primaryLimit(provider) {
  var limits = provider && Array.isArray(provider.limits) ? provider.limits : []
  var first = null
  var session = null
  for (var i = 0; i < limits.length; i++) {
    var entry = limits[i] || {}
    var percent = boundedPercent(entry.percent)
    if (percent < 0) continue
    var candidate = {
      percent: percent,
      title: String(entry.title || entry.label || "Limit"),
      resetAt: String(entry.resetsAt || "")
    }
    if (!first) first = candidate
    var title = candidate.title.toLowerCase()
    if (!session && (title === "session" || title.indexOf("session") >= 0)) session = candidate
  }
  return session || first
}

function balanceInfo(provider) {
  var balance = provider && provider.balance
  if (!balance || typeof balance !== "object") return null
  var remaining = Number(balance.remaining)
  if (!isFinite(remaining) || remaining < 0) return null
  var funded = nonnegative(balance.funded)
  return {
    remaining: remaining,
    funded: funded,
    spent: nonnegative(balance.spent),
    currency: String(balance.currency || "USD"),
    usedPercent: funded > 0 ? Math.max(0, Math.min(1, 1 - remaining / funded)) : -1,
    estimated: balance.estimated === true
  }
}

function providerRows(providers) {
  var list = Array.isArray(providers) ? providers : []
  var rows = []
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var provider = list[i] || {}
    var cost = provider.cost
    var estimate = Number(cost && cost.estimateUsd)
    var hasCost = !!cost && typeof cost === "object" && isFinite(estimate) && estimate >= 0
    var limit = primaryLimit(provider)
    var balance = balanceInfo(provider)
    estimate = hasCost ? nonnegative(estimate) : -1
    rows.push({
      providerId: String(provider.providerId || ""),
      providerName: String(provider.providerName || provider.providerId || "Provider"),
      hasCost: hasCost,
      estimateUsd: estimate,
      incomplete: hasCost && cost.incomplete === true,
      period: hasCost ? String(cost.period || "") : "",
      coverage: hasCost ? coverageFor(cost) : -1,
      usageKind: limit ? "subscription" : (balance ? "api-credit" : "none"),
      usageTitle: limit ? limit.title : (balance ? "API credit" : "Usage"),
      usagePercent: limit ? limit.percent : (balance ? balance.usedPercent : -1),
      subscriptionPercent: limit ? limit.percent : -1,
      subscriptionTitle: limit ? limit.title : "",
      subscriptionResetAt: limit ? limit.resetAt : "",
      balanceRemaining: balance ? balance.remaining : -1,
      balanceFunded: balance ? balance.funded : 0,
      balanceSpent: balance ? balance.spent : 0,
      balanceCurrency: balance ? balance.currency : "USD",
      balanceUsedPercent: balance ? balance.usedPercent : -1,
      balanceEstimated: balance ? balance.estimated : false,
      recordedDays: recordedDayCount(cost, provider),
      statusText: String(provider.usageStatusText || "")
    })
    if (hasCost) total += estimate
  }

  for (var j = 0; j < rows.length; j++) {
    rows[j].share = total > 0 && rows[j].hasCost ? rows[j].estimateUsd / total : 0
  }
  return rows
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    coverageFor: coverageFor,
    modelRows: modelRows,
    dailyRows: dailyRows,
    summary: summary,
    providerRows: providerRows
  }
}
