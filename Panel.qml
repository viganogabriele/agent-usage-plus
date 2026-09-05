import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "logic/thresholds.js" as Thresholds
import "logic/format.js" as Format
import "logic/aggregate.js" as Aggregate
import "logic/history.js" as History
import "logic/agents.js" as Agents
import "logic/pace.js" as Pace
import "logic/cost-analytics.js" as CostAnalytics
import "logic/notifications.js" as Notify
import "logic/meter-colors.js" as MeterColors

Panel {
  id: root
  moduleName: "io.github.viganogabriele.agent-usage-plus"
  ipcTarget: "io.github.viganogabriele.agent-usage-plus"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // The stable traffic-light colors are opt-in. With the option off, healthy
  // meters retain the live foreground and Critical retains Omarchy's urgent
  // color, preserving the widget's original theme contract.
  readonly property color healthy: "#22C55E"
  readonly property color colorfulCritical: "#EF4444"
  // A fixed amber rather than a foreground/urgent blend: warn needs to read
  // as its own distinct traffic-light color at a glance, not a paler shade
  // of critical that's easy to mistake for it against a dim theme.
  readonly property color warn: "#F2B705"
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The bar row only draws providers with showInBar !== false; the panel's
  // chip switcher, provider selection, and empty-state text below all keep
  // using `providers` (enabled-only, unchanged) so a provider hidden from
  // the bar is still reachable from the panel.
  readonly property var barProviders: usage.barProviders
  // How many providers show in the bar is the person's own choice — however
  // many they've marked Fixed, plus however many Cycle slots they've set —
  // not a separate hardcoded ceiling on top of that. This mirrors Main.qml's
  // barSlotLimit (effectively uncapped) so nothing gets trimmed a second
  // time here; the +N affordance still exists purely as a fallback for the
  // otherwise-unreachable case of exceeding the total number of providers
  // the plugin ships collectors for.
  readonly property int maxBarProviderSlots: 999
  readonly property var visibleBarProviders: barProviders.slice(0, maxBarProviderSlots)
  readonly property int hiddenBarProviderCount: Math.max(0, barProviders.length - visibleBarProviders.length)
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Session-only: never written to shell.json, and always false the moment
  // the panel opens (see onOpenedChanged below) — nobody should be surprised
  // by a bigger popup than the one they closed last time.
  //
  // `expanded` (cross-provider data) and `settingsOpen` (the settings form)
  // are mutually exclusive so the panel never has to grow to fit both at
  // once — toggling one closes the other rather than stacking their content.
  property bool expanded: false
  property bool settingsOpen: false
  function toggleExpanded() {
    root.expanded = !root.expanded
    if (root.expanded) root.settingsOpen = false
  }
  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
    if (root.settingsOpen) root.expanded = false
  }

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  readonly property var models: modelRows(provider)
  readonly property var detailModels: expanded ? detailModelRows(provider) : []
  // Only computed while expanded: collapsed behavior/output must stay
  // exactly what it was before this property existed.
  readonly property var allModels: expanded ? allModelRows(providers) : []
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // Optional, collector-reported "what this would cost at published API
  // rates" estimate. Claude and Codex can populate it from local transcript
  // history when the optional cost decorator is installed.
  readonly property var cost: provider ? (provider.cost || null) : null
  // Cost analytics are deliberately session-only and Details-only. The
  // compact view is a quick status glance; showing a derived API price there
  // made it compete with the real subscription allowance and duplicated the
  // same number again below.
  readonly property var costSummary: expanded && cost ? CostAnalytics.summary(cost, provider) : null
  readonly property var costModelRows: costSummary ? costSummary.models : []
  readonly property var costDailyRows: costSummary ? costSummary.days : []
  readonly property var costProviderRows: expanded ? CostAnalytics.providerRows(providers) : []

  // ---------------------------------------------------------- history chart
  //
  // Issue #13. Session-only, like `expanded`/`settingsOpen` above — the
  // selector re-slices `provider.recentDays`, which is already sitting in
  // memory from the last refresh, so flipping it never touches
  // usage.runUpdate()/Main.qml's updateProcess. Defaults to "7d" rather
  // than the manifest's 30-day `historyDays` default because a real
  // collector today only ever fills ~7-31 days (see capRecentDays in
  // logic/aggregate.js): defaulting to a range most collectors can satisfy
  // means expanding the panel for the first time shows a chart, not an
  // immediate "not available" message.
  property string historyRangeId: "7d"
  // Details use every day the collector has actually recorded (up to 30),
  // instead of pretending 24h/30d/90d are interchangeable choices when
  // the source only has a week. This removes a misleading selector and makes
  // the chart's time span self-evident.
  readonly property int detailHistoryDays: provider && provider.recentDays
    ? Math.min(30, Math.max(1, provider.recentDays.length)) : 7
  // Only computed while expanded, same reasoning as `allModels` above.
  readonly property var historySeries: (expanded && provider)
    ? History.buildHistorySeries(provider.recentDays || [], detailHistoryDays)
    : null

  function historyUnavailableText(series) {
    if (!series) return ""
    var n = Number(series.availableDays || 0)
    return "History not available beyond " + n + " day" + (n === 1 ? "" : "s")
      + " for this subscription."
  }

  function historyRangeLabel(rangeId) {
    for (var i = 0; i < History.RANGE_OPTIONS.length; i++)
      if (History.RANGE_OPTIONS[i].id === rangeId) return History.RANGE_OPTIONS[i].label
    return rangeId
  }

  function historySeriesTotal(series) {
    if (!series || !series.points) return 0
    var total = 0
    for (var i = 0; i < series.points.length; i++) total += Number(series.points[i].value || 0)
    return total
  }

  // User-configurable warn/critical cutoffs (percentage points, 0-100),
  // read straight from the manifest schema's defaults when unset.
  readonly property int warnThresholdPct: Number(usage.setting("warnThresholdPct", Thresholds.DEFAULT_WARN_PCT))
  readonly property int criticalThresholdPct: Number(usage.setting("criticalThresholdPct", Thresholds.DEFAULT_CRITICAL_PCT))
  readonly property int displayWarnThresholdPct: usage.showAvailablePercentage
    ? 100 - warnThresholdPct : warnThresholdPct
  readonly property int displayCriticalThresholdPct: usage.showAvailablePercentage
    ? 100 - criticalThresholdPct : criticalThresholdPct
  readonly property var severityThresholds: ({ warn: warnThresholdPct, critical: criticalThresholdPct })

  // ---------------------------------------------------------------- settings
  //
  // The expanded panel's settings section (issue 08) edits the same settings
  // this file already reads elsewhere (warnThresholdPct/criticalThresholdPct
  // above, refreshIntervalSec on `usage`, per-provider enabled/showInBar).
  // Nothing here writes shell.json directly — every control below calls
  // through to one of usage.set*() in Main.qml, which shells out to
  // `omarchy bar set` (see Main.qml's "settings writes" section).

  function providerSettingEnabled(id) {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    return !providers[id] || providers[id].enabled !== false
  }

  function providerSettingShowInBar(id) {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    return !providers[id] || providers[id].showInBar !== false
  }

  // Icon / Icon + % / Full. Without an explicit per-provider choice, the
  // default follows the provider's own Bar slot role rather than one global
  // setting: Fixed is always on screen and earns the full meter+percent,
  // while Cycle only holds a slot briefly, so a compact mark reads better
  // during the rotation. This also means the two "cycle" concepts in this
  // panel stay separate — rotating *which* providers occupy the bar (Bar
  // slot: Cycle) never gets confused with how much any one of them shows.
  function providerSettingLabelMode(id) {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    var mode = providers[id] ? providers[id].barLabelMode : undefined
    if (mode === "icon" || mode === "iconPercent" || mode === "full") return mode
    return providerSettingBarRole(id) === "cycle" ? "iconPercent" : "full"
  }

  function providerRolesConfigured() {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    for (var id in providers) {
      var role = providers[id] ? providers[id].barRole : ""
      if (role === "fixed" || role === "cycle") return true
    }
    return false
  }

  function providerSettingBarRole(id) {
    var providers = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    var cfg = providers[id] || {}
    if (cfg.showInBar === false) return "off"
    if (cfg.barRole === "cycle") return "cycle"
    if (cfg.barRole === "fixed") return "fixed"
    // A pre-role global Cycle configuration still rotates all eligible
    // providers. Reflect that legacy behavior until the user chooses a role.
    return usage.legacyCycleMode && !providerRolesConfigured() ? "cycle" : "fixed"
  }

  function hasCycleSlotConfigured() {
    var rows = root.settingsProviders
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] && rows[i].enabled && rows[i].barRole === "cycle") return true
    }
    return false
  }

  // One row per provider this machine knows about, whether or not it is
  // currently enabled — `usage.agents` covers every discovered usage record
  // regardless of the `enabled` setting (only `enabledProviders` filters that
  // out), so a disabled provider still gets a row here with its toggle ready
  // to flip back on. Falls back to whatever `providers` already names in
  // settings for an id with no record on disk yet (a collector that was
  // configured but has not written a file, or has been uninstalled).
  readonly property var settingsProviders: {
    var rev = usage.dataRevision
    var seen = ({})
    var rows = []
    var agentsList = usage.agents || []
    for (var i = 0; i < agentsList.length; i++) {
      var record = agentsList[i] ? agentsList[i].record : null
      if (!record || !record.id) continue
      var id = Aggregate.sanitizeProviderId(record.id)
      if (seen[id]) continue
      seen[id] = true
      rows.push({
        providerId: id,
        providerName: String(record.name || record.id),
        // ProviderMark resolves brand-first; without this a branded account
        // record shows its real mark everywhere except the settings list.
        brand: Aggregate.sanitizeBrand(record.brand),
        enabled: providerSettingEnabled(id),
        showInBar: providerSettingShowInBar(id),
        barRole: providerSettingBarRole(id),
        labelMode: providerSettingLabelMode(id)
      })
    }
    var configured = usage.settings && usage.settings.providers ? usage.settings.providers : {}
    for (var pid in configured) {
      if (seen[pid]) continue
      seen[pid] = true
      rows.push({
        providerId: pid,
        providerName: pid,
        enabled: providerSettingEnabled(pid),
        showInBar: providerSettingShowInBar(pid),
        barRole: providerSettingBarRole(pid),
        labelMode: providerSettingLabelMode(pid)
      })
    }
    return Aggregate.applyProviderOrder(rows, usage.providerOrder)
  }

  // `percent` here is the 0-1 fraction used throughout the panel's data
  // model; severityFor works in percentage points, so it's scaled up here.
  function severityForPercent(percent) {
    if (typeof percent !== "number" || !isFinite(percent) || percent < 0) return "ok"
    return Thresholds.severityFor(percent * 100, root.severityThresholds)
  }
  function colorForSeverity(severity) {
    var role = MeterColors.paletteRole(severity, usage.colorfulUsageMeters)
    if (role === "critical-red") return root.colorfulCritical
    if (role === "critical") return root.urgent
    if (role === "warn") return root.warn
    if (role === "healthy") return root.healthy
    return root.foreground
  }

  // A prepaid account runs low the way a subscription window fills up: the
  // last stretch of the funded credits lights the same alarm as a
  // rate-limit window nearing its cap.
  readonly property real balanceUsedRatio: (!!balance && balance.funded > 0)
    ? (1 - Number(balance.remaining) / Number(balance.funded)) : -1
  readonly property string balanceSeverity: severityForPercent(balanceUsedRatio)
  readonly property string headlineSeverity: headline ? severityForPercent(headline.percent) : "ok"
  // The bar icon and its badge reflect the worse of the headline window and
  // the balance — either one crossing into "critical" should read as
  // critical even if the other is still "ok".
  readonly property string severity: (headlineSeverity === "critical" || balanceSeverity === "critical")
    ? "critical" : ((headlineSeverity === "warn" || balanceSeverity === "warn") ? "warn" : "ok")
  readonly property bool alarming: severity === "critical"
  readonly property bool balanceAlarming: balanceSeverity === "critical"

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  // Keyboard h/l selection must also reveal the selected chip. The selector
  // wraps when there are more providers than fit on one line, so reveal the
  // selected logo vertically instead of maintaining a second horizontal
  // scroll surface inside the panel.
  function ensureSelectedChipVisible() {
    if (!root.opened || !providerChipRepeater || !providerSwitch || !panelFlick || !column)
      return
    var chip = providerChipRepeater.itemAt(providerIndex)
    if (!chip || chip.width <= 0 || chip.height <= 0 || panelFlick.height <= 0) return

    var point = chip.mapToItem(column, 0, 0)
    var top = point.y
    var bottom = top + chip.height
    var margin = Style.space(10)
    var viewportTop = panelFlick.contentY + margin
    var viewportBottom = panelFlick.contentY + panelFlick.height - margin
    var nextY = panelFlick.contentY
    if (top < viewportTop) nextY = top - margin
    else if (bottom > viewportBottom) nextY = bottom - panelFlick.height + margin
    panelFlick.contentY = clamp(nextY, 0, Math.max(0, panelFlick.contentHeight - panelFlick.height))
  }

  // Opening a specific provider's bar group should show that provider, not
  // whatever was last selected. Only a click opens it; closing only ever
  // happens explicitly (click outside, Esc, or clicking the widget again).
  function openProvider(p) {
    if (p) selectedProviderId = p.providerId
    open()
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  // Right-click launches the agent of the mark that was clicked. Passing no
  // id (the whole-slot button, the overflow button) keeps the old behavior:
  // omarchy-agent reads ~/.config/omarchy/defaults/agent, which is the only
  // sensible answer when the click doesn't name a provider.
  function launchAgent(providerId) {
    if (root.bar) root.bar.run(Agents.launchCommandFor(providerId))
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title, startedAt, tokenLimit) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || ""),
      startedAt: String(startedAt || ""),
      tokenLimit: Number(tokenLimit || 0)
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title, entry.startedAt, entry.tokenLimit))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    return Format.formatDuration(ms)
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function formatMoney(value, currency) {
    return Format.formatMoney(value, currency)
  }

  // ------------------------------------------------------------------ cost
  //
  // Optional collector-reported "what this would cost at published API
  // rates" estimate (issue #12) — a derived figure, never a real bill.

  function formatUsd(value) {
    return Format.formatUsd(value)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. A collector
  // status is deliberately *not* used here: repeating "Waiting for API key"
  // in the hero and again in the status card made an unconfigured provider
  // look like two errors and pushed useful controls below the fold.
  function heroMeta(p) {
    if (!p) return ""
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Missing setup is actionable but not an emergency. Reserve the urgent
  // treatment for an account/endpoint that was configured and then failed;
  // this lets a panel with several optional API collectors stay calm and
  // readable instead of becoming a stack of red warnings.
  function statusSeverity(p) {
    var status = String(p && p.usageStatusText || "").toLowerCase()
    if (status.indexOf("waiting for") >= 0 || status.indexOf("unavailable") >= 0
      || status.indexOf("meter unavailable") >= 0) return "warn"
    if (status.indexOf("rejected") >= 0 || status.indexOf("error") >= 0
      || status.indexOf("could not") >= 0) return "critical"
    return "warn"
  }

  function statusColor(p) {
    return statusSeverity(p) === "critical" ? root.urgent : root.warn
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function shortHistoryDate(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return (parsed.getMonth() + 1) + "/" + parsed.getDate()
  }

  // The switch deliberately gives every provider the same hit target. A
  // plain Text inside qs.Ui.Button does not elide by itself, so cap its
  // visible label here instead of letting a long collector-supplied name
  // bleed into the next chip. The full name remains the hero title when the
  // chip is selected.
  function providerChipLabel(provider) {
    var name = String(provider && provider.providerName || "")
    return name.length > 14 ? name.slice(0, 13) + "…" : name
  }

  // A full collector can retain up to 90 days. Rendering every one as a
  // collapsed row made a normal panel hundreds of pixels taller than the
  // screen, even before a person opened the detailed chart. Keep the useful
  // recent week in the summary; the explicit details control exposes every
  // available day and range without silently discarding data.
  function summaryDays(p, limit) {
    var list = p && Array.isArray(p.recentDays) ? p.recentDays.slice() : []
    list.sort(function(a, b) {
      var left = String(a && a.date || "")
      var right = String(b && b.date || "")
      return left < right ? -1 : (left > right ? 1 : 0)
    })
    var count = Math.max(1, Number(limit) || 7)
    return list.length > count ? list.slice(list.length - count) : list
  }

  function dayPeak(days) {
    var list = Array.isArray(days) ? days : []
    var peak = 0
    for (var i = 0; i < list.length; i++) peak = Math.max(peak, Number(list[i].messageCount || 0))
    return peak
  }

  function unpricedModelText(cost) {
    if (!cost || !cost.incomplete) return ""
    var unknown = Array.isArray(cost.unknownModels) ? cost.unknownModels : []
    var names = []
    for (var i = 0; i < unknown.length; i++) {
      var name = usage.friendlyModelName(unknown[i])
      if (names.indexOf(name) < 0) names.push(name)
    }
    return names.length > 0
      ? "Excluded from estimate: " + names.join(", ") + "."
      : "Some models have no published rate and are excluded."
  }

  function costCoverageText(coverage) {
    var value = Number(coverage)
    return isFinite(value) && value >= 0 ? Math.round(value * 100) + "% priced" : "Rate coverage unavailable"
  }

  function costProviderRow(p) {
    if (!p) return null
    var id = String(p.providerId || "")
    for (var i = 0; i < root.costProviderRows.length; i++) {
      if (String(root.costProviderRows[i].providerId || "") === id) return root.costProviderRows[i]
    }
    return null
  }

  function costPlanValue(row) {
    if (!row) return "—"
    if (row.usageKind === "subscription" && Number(row.subscriptionPercent) >= 0)
      return Format.formatPercent(Number(row.subscriptionPercent))
    if (row.usageKind === "api-credit" && Number(row.balanceRemaining) >= 0) {
      return root.formatMoney(row.balanceRemaining, row.balanceCurrency)
    }
    return "—"
  }

  function costPlanLabel(row) {
    if (!row) return "On plan"
    if (row.usageKind === "subscription") return "On subscription"
    if (row.usageKind === "api-credit") return "API credit left"
    return "Plan usage"
  }

  // Kept short on purpose: this renders inside a fixed-width column next to
  // the plan/API figures, and a long sentence here just gets silently
  // ellipsized — the "resets in" countdown is the one thing that must
  // always fit.
  function costPlanHint(row) {
    if (!row) return "No provider data"
    if (row.usageKind === "subscription") {
      var resetAt = String(row.subscriptionResetAt || "")
      if (resetAt !== "") {
        var remainingMs = new Date(resetAt).getTime() - root.nowMs
        if (remainingMs > 0) return "Resets in " + root.formatDuration(remainingMs)
      }
      return String(row.subscriptionTitle || "Session") + " quota"
    }
    if (row.usageKind === "api-credit") {
      if (Number(row.balanceFunded) > 0 && Number(row.balanceSpent) >= 0) {
        var spent = root.formatMoney(row.balanceSpent, row.balanceCurrency) + " of "
          + root.formatMoney(row.balanceFunded, row.balanceCurrency) + " spent"
        return row.balanceEstimated ? spent + " · est." : spent
      }
      return row.balanceEstimated ? "Estimated balance" : "API balance"
    }
    if (row.statusText !== "") return "Provider data unavailable"
    return "No quota or balance reported"
  }

  function costApiValue(row) {
    return row && row.hasCost ? root.formatUsd(row.estimateUsd) : "—"
  }

  // Combines the two small-print footer lines (price-catalogue coverage and
  // version) into one so the model breakdown doesn't end in a stack of
  // near-identical caption rows.
  function costFooterText(cost, summary) {
    var parts = []
    if (summary && Number(summary.coverage) >= 0) {
      parts.push(summary.totalTokens > 0
        ? root.costCoverageText(summary.coverage) + " of " + usage.formatTokenCount(summary.totalTokens) + " tokens"
        : root.costCoverageText(summary.coverage))
    }
    if (cost && String(cost.pricingVersion || "") !== "") parts.push("catalogue " + String(cost.pricingVersion))
    return parts.join(" · ")
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  // Shared by the per-provider "TOKENS BY MODEL" section and the expanded
  // view's cross-provider one below — both start from a modelId -> token
  // bucket map, they just build it differently (one provider's modelUsage
  // vs. Aggregate.allProviderModelUsage's combined map across every
  // enabled provider).
  function modelUsageRows(usageByModel, limit) {
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        id: String(id),
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, limit || 4)
  }

  function modelRows(p) {
    // The default view is an at-a-glance dashboard. Three ranked rows keep
    // the most useful comparison visible without pushing the current limit
    // and cost information below the fold; the detailed view retains the
    // complete cross-provider table.
    return modelUsageRows(p ? (p.modelUsage || {}) : {}, 3)
  }

  function detailModelRows(p) {
    return modelUsageRows(p ? (p.modelUsage || {}) : {}, 12)
  }

  // Every enabled provider's models in one table, not just the currently
  // selected chip's — only computed/rendered when the panel is expanded.
  // A generous cap (12) since it spans every subscription at once.
  function allModelRows(providerList) {
    return modelUsageRows(Aggregate.allProviderModelUsage(providerList), 12)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // An asset path has to be explicitly registered. QML's Image cannot probe a
  // relative URL quietly, so deriving `assets/<provider>.svg` made every
  // provider without a bundled mark emit a runtime warning on every refresh.
  // Keep this deliberately small: unregistered providers use the readable
  // initial below instead of an invented or unlicensed brand asset.
  // `scale` normalizes marks whose artwork bleeds closer to the edge of its
  // own viewBox than the rest of the set (Claude's brand mark, Codex's glyph)
  // so every mark reads as the same visual size at a given box, not just the
  // same bounding box. Omitted entries default to 1 (no adjustment needed).
  readonly property var providerIconAssets: ({
    claude: { defaultAsset: "claude.svg", scale: 0.88 },
    codex: { defaultAsset: "codex.svg", lightAsset: "codex-light.svg", scale: 0.8 },
    fireworks: { defaultAsset: "fireworks.svg" },
    openrouter: { defaultAsset: "openrouter.svg", lightAsset: "openrouter-light.svg" },
    deepseek: { defaultAsset: "deepseek.svg" },
    gemini: { defaultAsset: "gemini.svg", lightAsset: "gemini-light.svg" },
    cursor: { defaultAsset: "cursor.svg", lightAsset: "cursor-light.svg" },
    kimi: { defaultAsset: "kimi.svg", lightAsset: "kimi-light.svg" },
    xai: { defaultAsset: "xai.svg", lightAsset: "xai-light.svg" },
    grok: { defaultAsset: "grok.svg", lightAsset: "grok-light.svg" },
    zai: { defaultAsset: "zai.svg", lightAsset: "zai-light.svg" },
    devin: { defaultAsset: "devin.svg" },
    "opencode-go": { defaultAsset: "opencode-go.svg", lightAsset: "opencode-go-light.svg" }
  })

  // Known marks resolve through the registry above; everything else falls
  // back to the module's glyph/initial without attempting a missing URL.
  //
  // providerId ultimately comes from a usage record's "id" field (or, when
  // synced, a key inside another machine's snapshot file) and Main.qml's
  // sanitizeProviderId() already restricts it to [A-Za-z0-9_-] before it
  // reaches here — but this is exactly the string that gets concatenated
  // into a resource URL, so it is re-validated at the point of use rather
  // than trusted to have gone through the right upstream function.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    // A record may declare a `brand` naming whose mark it renders with
    // (e.g. a second `claude-work` account using the Claude mark); it went
    // through sanitizeBrand upstream but is re-validated here like the id.
    var id = String(p.brand || p.providerId || "")
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return []
    var assets = root.providerIconAssets[id]
    if (!assets) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5 && assets.lightAsset)
      candidates.push(Qt.resolvedUrl("assets/" + assets.lightAsset))
    if (assets.defaultAsset) candidates.push(Qt.resolvedUrl("assets/" + assets.defaultAsset))
    return candidates
  }

  function iconCandidatesForBarProvider(p) {
    if (!p) return []
    // A record may declare a `brand` naming whose mark it renders with
    // (e.g. a second `claude-work` account using the Claude mark); it went
    // through sanitizeBrand upstream but is re-validated here like the id.
    var id = String(p.brand || p.providerId || "")
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return []
    var assets = root.providerIconAssets[id]
    if (!assets) return []
    var candidates = []
    // The bar can swap its foreground when a transparent/hover state is
    // active. Match the monochrome mark to that live color, rather than to
    // the popup surface used by the panel copy of the same mark.
    var liveForeground = bar ? (bar.barForeground || bar.foreground) : foreground
    if (colorLuminance(liveForeground) < 0.5 && assets.lightAsset)
      candidates.push(Qt.resolvedUrl("assets/" + assets.lightAsset))
    if (assets.defaultAsset) candidates.push(Qt.resolvedUrl("assets/" + assets.defaultAsset))
    return candidates
  }

  // Companion to iconCandidatesForProvider: the fraction of its box a mark's
  // artwork should occupy, so brand marks with less internal padding than
  // the rest of the set don't read as larger. See providerIconAssets.
  function iconScaleForProvider(p) {
    if (!p) return 1
    // Same brand-first resolution as the candidate lookups: a branded
    // account record must render at the exact same size as the provider it
    // borrows the mark from, or two chips of one provider read as different.
    var id = String(p.brand || p.providerId || "")
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return 1
    var assets = root.providerIconAssets[id]
    var scale = assets ? Number(assets.scale) : 1
    return isFinite(scale) && scale > 0 && scale <= 1 ? scale : 1
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  //
  // "Nothing to report" is judged against every *discovered* provider
  // (`settingsProviders`), not just the enabled ones: a machine with real
  // collectors that the user has since disabled everywhere still has a
  // plugin to manage, and it must stay reachable — otherwise turning every
  // provider off from the in-panel settings (issue 08) locks the settings
  // themselves behind a bar icon that no longer exists. A machine that has
  // never produced a single usage record still collapses out entirely.
  // Extra breathing room on both sides so this widget doesn't sit flush
  // against its bar neighbors the way a plain icon slot would.
  readonly property real outerPadding: Style.space(10)

  visible: providers.length > 0 || root.settingsProviders.length > 0
  implicitWidth: Math.max(button.implicitWidth, providersRow.implicitWidth) + outerPadding * 2
  implicitHeight: button.implicitHeight

  // Bar.qml reads this to size the little "panel is open" underline mark —
  // without it, it defaults to ~55% of the slot's width. Full width here so
  // the mark runs the whole span, Claude through Codex, not just a sliver.
  readonly property real openPanelIndicatorWidth: implicitWidth

  onProviderIndexChanged: {
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(root.ensureSelectedChipVisible)
  }
  onOpenedChanged: if (opened) {
    cursorActive = false
    expanded = false
    settingsOpen = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
    moduleId: root.moduleName
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
    // Exposed for the same reason as refresh(): it gives diagnostics and
    // release QA a deterministic path through the exact function the button
    // calls, including its queue and visible result state.
    function testNotification(): string { root.sendTestNotification(); return "queued" }
    function notificationStatus(): string { return root.notificationTestStatus }
  }

  // The provider's primary window: session when it reports one (Claude),
  // otherwise whatever it does report (Codex today: just weekly).
  function providerPrimaryWindow(p) {
    if (!p) return null
    var windows = limitWindows(p)
    for (var i = 0; i < windows.length; i++) if (windows[i].title === "Session") return windows[i]
    return windows.length > 0 ? windows[0] : null
  }

  // Per-provider percent, independent of which one is selected for the
  // popup — the bar shows every enabled subscription at once, not just the
  // one the panel currently has open.
  function providerPercent(p) {
    var w = providerPrimaryWindow(p)
    if (w && w.percent >= 0) return w.percent
    if (p && p.balance && p.balance.funded > 0) return 1 - p.balance.remaining / p.balance.funded
    return -1
  }
  function providerSeverity(p) { return root.severityForPercent(providerPercent(p)) }

  // The chip must warn when ANY of the account's meters is hot, not just
  // the primary window the bar happens to display: a session at 1% can sit
  // in front of a model-scoped weekly at 86% — exactly the account most
  // worth warning about. Worst of every limit window plus the credit gauge.
  function providerWorstSeverity(p) {
    if (!p) return "ok"
    var worst = "ok"
    var windows = limitWindows(p)
    for (var i = 0; i < windows.length; i++)
      worst = Thresholds.worstSeverity(worst, severityForPercent(windows[i].percent))
    var credit = p.balance || null
    if (credit && Number(credit.funded) > 0 && Number(credit.remaining) >= 0)
      worst = Thresholds.worstSeverity(worst, severityForPercent(1 - Number(credit.remaining) / Number(credit.funded)))
    return worst
  }
  function providerPercentText(p) {
    var pct = providerPercent(p)
    return pct >= 0 ? Format.formatPercent(pct, usage.showAvailablePercentage) : "…"
  }
  function displayPercent(percent) {
    return Format.displayPercent(percent, usage.showAvailablePercentage)
  }

  // Everything the bar chip compresses away, on hover: which account this
  // is, its plan, every limit window with its reset countdown, and any
  // credit balance. One line per fact, so multiple accounts of the same
  // provider read apart without opening the panel.
  function barProviderTooltip(p) {
    if (!p) return ""
    var lines = []
    var head = String(p.providerName || p.providerId || "Provider")
    if (p.tierLabel) head += " · " + String(p.tierLabel)
    lines.push(head)
    var windows = limitWindows(p)
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      if (w.percent < 0) continue
      var line = String(w.title || w.label || "Limit") + " " + Format.formatPercent(w.percent)
      if (w.resetAt) {
        var remainingMs = Date.parse(w.resetAt) - Date.now()
        if (isFinite(remainingMs) && remainingMs > 0)
          line += " · resets in " + Format.formatDuration(remainingMs)
      }
      lines.push(line)
    }
    var credit = p.balance || null
    if (credit && Number(credit.remaining) >= 0) {
      var creditLine = Format.formatMoney(Number(credit.remaining), credit.currency) + " left"
      if (Number(credit.funded) > 0)
        creditLine += " of " + Format.formatMoney(Number(credit.funded), credit.currency)
      lines.push(creditLine)
    }
    return lines.join("\n")
  }

  // The weekly percent, when the bar's already showing session as the
  // primary number — drawn as a tick on the same meter rather than a
  // second bar, so seeing both costs a couple of pixels, not double width.
  function providerSecondaryPercent(p) {
    if (!p) return -1
    var primary = providerPrimaryWindow(p)
    if (!primary || primary.title !== "Session") return -1
    var windows = limitWindows(p)
    for (var i = 0; i < windows.length; i++) if (windows[i].title === "Weekly") return windows[i].percent
    return -1
  }

  // ------------------------------------------------------- notifications
  //
  // Opt-in (usage.notificationsEnabled, off by default) and quiet: one
  // notification when a provider crosses Warn, and one more if it goes on to
  // cross Critical — never a repeat on every refresh while it sits in the
  // same band. The first sample for a provider/window establishes a quiet
  // baseline, so a shell restart does not repeat an alert for usage that was
  // already high. The last observed severity is keyed by provider and billing
  // window, so a new session/period naturally rearms it. Balance providers
  // have no reset timestamp; their current severity is enough to rearm after
  // a top-up brings the balance back below Warn.
  property var notificationSeverities: ({})

  onProvidersChanged: checkThresholdNotifications()
  onWarnThresholdPctChanged: checkThresholdNotifications()
  onCriticalThresholdPctChanged: checkThresholdNotifications()

  Connections {
    target: usage
    function onNotificationsEnabledChanged() {
      if (usage.notificationsEnabled) root.checkThresholdNotifications()
      else root.discardQueuedThresholdNotifications()
    }
  }

  function discardQueuedThresholdNotifications() {
    var tests = []
    for (var i = 0; i < root.notificationQueue.length; i++) {
      var entry = root.notificationQueue[i]
      if (entry && entry.isTest === true) tests.push(entry)
    }
    root.notificationQueue = tests
  }

  function notificationSignal(p) {
    if (!p) return null
    var window = providerPrimaryWindow(p)
    if (window) return {
      title: window.title,
      resetAt: window.resetAt,
      kind: "limit"
    }
    if (p.balance && Number(p.balance.funded) > 0) return {
      title: "Balance",
      resetAt: "",
      kind: "balance"
    }
    return null
  }

  function checkThresholdNotifications() {
    for (var i = 0; i < root.providers.length; i++) {
      var p = root.providers[i]
      var signal = notificationSignal(p)
      if (!signal) continue
      var severity = providerSeverity(p)
      var key = String(p.providerId || "") + "|" + signal.kind + "|" + signal.resetAt
      var transition = Thresholds.notificationTransition(root.notificationSeverities[key], severity)
      root.notificationSeverities[key] = transition.severity
      if (usage.notificationsEnabled && transition.notification !== "")
        root.queueNotification(p, signal, transition.notification)
    }
  }

  property var notificationQueue: []
  property bool notificationRunning: false
  property bool activeNotificationIsTest: false
  property string notificationTestStatus: ""

  Process {
    id: notifyProcess
    running: false
    onExited: function(exitCode) {
      if (root.activeNotificationIsTest)
        root.notificationTestStatus = exitCode === 0 ? "Sent" : "Failed"
      if (exitCode !== 0)
        console.warn("agents/notify", "notification command failed:", notifyProcess.command.join(" "))
      root.activeNotificationIsTest = false
      root.notificationRunning = false
      root.pumpNotificationQueue()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents/notify", text.trim())
    }
  }

  // A manual, always-available way to confirm Omarchy's notification pipeline
  // itself works — independent of notificationsEnabled and of waiting for a
  // real Warn/Critical crossing, which may be rare or slow to hit.
  function sendTestNotification() {
    root.notificationTestStatus = root.notificationRunning ? "Queued…" : "Sending…"
    root.notificationQueue.push({
      command: Notify.command("Agent Usage Plus",
        "Test notification — if you see this, notifications are working.", "normal"),
      isTest: true
    })
    root.pumpNotificationQueue()
  }

  function queueNotification(p, signal, severity) {
    var name = String((p && p.providerName) || (p && p.providerId) || "Provider")
    var pct = providerPercentText(p)
    var urgency = severity === "critical" ? "critical" : "normal"
    var summary = name + " — " + (severity === "critical" ? "critical" : "warning")
    var body = signal.title + " at " + pct
      + (usage.showAvailablePercentage ? " available" : " used")
    root.notificationQueue.push({
      command: Notify.command(summary, body, urgency),
      isTest: false
    })
    root.pumpNotificationQueue()
  }

  function pumpNotificationQueue() {
    if (root.notificationRunning) return
    if (root.notificationQueue.length === 0) return
    var next = root.notificationQueue.shift()
    if (!next || !Array.isArray(next.command)) return root.pumpNotificationQueue()
    root.notificationRunning = true
    root.activeNotificationIsTest = next.isTest === true
    if (root.activeNotificationIsTest) root.notificationTestStatus = "Sending…"
    notifyProcess.command = next.command
    notifyProcess.running = true
  }

  // Compact metric tiles give the three key numbers a deliberate visual
  // hierarchy instead of making them read like a wrapped sentence.
  component CostMetric: Item {
    id: costMetric
    property string label: ""
    property string valueText: ""
    property string hint: ""

    implicitHeight: metricContent.implicitHeight + Style.space(16)

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.055)
      border.width: 1
      border.color: root.alpha(root.foreground, 0.10)
    }

    Column {
      id: metricContent
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: costMetric.valueText
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: costMetric.label
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Text {
        visible: costMetric.hint !== ""
        width: parent.width
        text: costMetric.hint
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }
    }
  }

  // A wide track with faint ticks at the quarter marks, so the fill reads
  // as "about two thirds of the way there" rather than an unscaled smear.
  component CheckpointMeter: Item {
    id: checkpointMeter
    property real value: -1
    property string severity: "ok"
    // A second percent, drawn as a small marker sticking past the track
    // rather than a whole extra bar — e.g. the weekly percent riding on
    // the session meter, so both numbers show without doubling the width.
    property real secondaryValue: -1
    readonly property real trackThickness: Math.max(Style.space(5), Math.round(Style.spacing.controlHeight * 0.18))

    implicitHeight: trackThickness

    Rectangle {
      id: checkpointTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: checkpointTrack.left
      anchors.verticalCenter: checkpointTrack.verticalCenter
      height: checkpointTrack.height
      radius: checkpointTrack.radius
      width: checkpointTrack.width * root.clamp(checkpointMeter.value, 0, 1)
      color: root.colorForSeverity(checkpointMeter.severity)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Repeater {
      model: [0.25, 0.5, 0.75]

      Rectangle {
        required property real modelData
        x: Math.round(checkpointTrack.width * modelData) - width / 2
        y: 0
        width: 1
        height: checkpointTrack.height
        color: root.alpha(root.surface, 0.55)
      }
    }

    Rectangle {
      visible: checkpointMeter.secondaryValue >= 0
      x: Math.round(checkpointTrack.width * root.clamp(checkpointMeter.secondaryValue, 0, 1)) - width / 2
      y: -3
      width: 3
      radius: 1
      height: checkpointTrack.height + 6
      color: Color.accent
      border.width: 1
      border.color: root.surface
    }
  }

  // Provider's brand mark at bar scale, with the same asset-then-glyph
  // fallback chain the panel's hero uses, so Claude and Codex read apart at
  // a glance instead of both being an unlabeled bar.
  component ProviderMark: Item {
    id: providerMark
    required property var provider
    // Bar marks follow the bar's live foreground (including transparent-bar
    // and hover inversion updates). Panel marks continue to follow the popup
    // surface, which is a separate visual context.
    property bool barMark: false
    property var candidates: barMark
      ? root.iconCandidatesForBarProvider(provider)
      : root.iconCandidatesForProvider(provider, root.surface)
    property string candidatesKey: candidates.join("\n")
    property int candidateIndex: 0
    property real iconScale: root.iconScaleForProvider(provider)
    onCandidatesKeyChanged: candidateIndex = 0

    width: Style.font.body
    height: Style.font.body

    Image {
      id: markImage
      anchors.centerIn: parent
      width: Math.round(parent.width * providerMark.iconScale)
      height: Math.round(parent.height * providerMark.iconScale)
      // Rasterize the SVG directly at its on-screen size (rather than at
      // whatever default size QtSvg picks and then bilinearly scaling that
      // pixmap) — without this, marks read as soft/blurry, worse the larger
      // the box or the higher the screen's device pixel ratio. Decode at
      // physical pixels, matching Tray.qml/Menu.qml/NotificationCard.qml:
      // logical sourceSize still leaves marks soft on HiDPI outputs.
      sourceSize.width: Math.round(width * Screen.devicePixelRatio)
      sourceSize.height: Math.round(height * Screen.devicePixelRatio)
      smooth: true
      mipmap: true
      source: providerMark.candidateIndex < providerMark.candidates.length ? providerMark.candidates[providerMark.candidateIndex] : ""
      fillMode: Image.PreserveAspectFit
      onStatusChanged: if (status === Image.Error && providerMark.candidateIndex < providerMark.candidates.length)
        Qt.callLater(function() { providerMark.candidateIndex++ })
    }

    Text {
      anchors.centerIn: parent
      visible: markImage.status !== Image.Ready
      text: providerMark.provider ? providerMark.provider.providerId.charAt(0).toUpperCase() : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // WidgetButton owns clicks, hover tooltip, and bar registration for the
  // whole slot; providersRow below draws the visible label+meter per
  // provider on top of it.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    // The per-provider meters in providersRow draw on top of this button
    // and normally are the only visible content — but when every provider
    // is enabled-but-hidden-from-bar (or the discovered set is enabled with
    // nothing yet to report), providersRow's model is empty and, with the
    // label suppressed, the slot would render as an invisible-but-clickable
    // gap: present enough to keep the panel reachable (see `visible` above)
    // but with no visual sign it's there. Fall back to this module's own
    // glyph whenever there's no per-provider content to show instead.
    labelVisible: root.barProviders.length === 0
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      // In "cycle" mode, middle-click manually advances which single
      // provider the BAR shows (usage.cycleNext(), a new index — see
      // Main.qml) instead of the panel's own chip-selection index; the two
      // are deliberately kept separate (see barCycleIndex's comment).
      else if (buttonCode === Qt.MiddleButton) {
        if (usage.cycleBarProviders.length > 0) usage.cycleNext()
        else root.selectProvider(root.providerIndex + 1)
      }
      else root.toggle()
    }
  }

  // Label+meter pairs for enabled, reporting, showInBar-visible providers sit
  // side by side. The layout helper has a safety ceiling equal to the bundled
  // collector count; any future overflow is represented by +N below rather
  // than making the bar progressively wider without bound.
  Row {
    id: providersRow
    anchors.centerIn: button
    spacing: Style.space(12)

    Repeater {
      id: providersRepeater
      model: root.visibleBarProviders

      // Plain Item, not a Row: the click target below needs its own
      // width/height for Bar's hit-test, which a Row-positioned child
      // can't carry alongside anchors.
      Item {
        id: providerGroup
        required property var modelData
        implicitWidth: groupContent.implicitWidth
        implicitHeight: groupContent.implicitHeight

        Row {
          id: groupContent
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(5)

          ProviderMark {
            anchors.verticalCenter: parent.verticalCenter
            // Between the shell's own plain tray badge (Style.space(12)) and
            // the original Style.space(20), which read oversized next to the
            // caption-sized percent text beside it.
            width: Style.space(16)
            height: width
            provider: providerGroup.modelData
            barMark: true
          }

          CheckpointMeter {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(48)
            value: {
              var percent = root.providerPercent(providerGroup.modelData)
              return percent >= 0 ? root.displayPercent(percent) : -1
            }
            secondaryValue: {
              var percent = root.providerSecondaryPercent(providerGroup.modelData)
              return percent >= 0 ? root.displayPercent(percent) : -1
            }
            severity: root.providerWorstSeverity(providerGroup.modelData)
            visible: root.providerSettingLabelMode(providerGroup.modelData.providerId) === "full"
              && root.providerPercent(providerGroup.modelData) >= 0
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.providerSettingLabelMode(providerGroup.modelData.providerId) !== "icon"
            text: root.providerPercentText(providerGroup.modelData)
            color: root.colorForSeverity(root.providerWorstSeverity(providerGroup.modelData))
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Bar.qml dispatches every module click itself (for drag-to-reorder
        // support) and only ever hands it to a *registered* WidgetButton —
        // a plain MouseArea here is never consulted, no matter its z. This
        // has to be a WidgetButton so registerClickTarget() picks it up as
        // its own target, distinct from the whole-slot `button` below.
        WidgetButton {
          id: providerClickTarget
          anchors.fill: parent
          bar: root.bar
          hasVisualContent: true
          text: ""
          labelVisible: false
          onPressed: function(buttonCode) {
            if (buttonCode === Qt.RightButton)
              root.launchAgent(providerGroup.modelData ? providerGroup.modelData.providerId : "")
            else if (buttonCode === Qt.MiddleButton) {
              if (usage.cycleBarProviders.length > 0) usage.cycleNext()
              else root.selectProvider(root.providerIndex + 1)
            }
            else root.openProvider(providerGroup.modelData)
          }
          // The bar's own tooltip window, not a PanelToolTip: a QQC2 popup
          // cannot escape the thin bar window, so multi-line content gets
          // clipped to one line there. Bar.qml's PopupWindow self-sizes to
          // the text and renders every line.
          tooltipText: root.barProviderTooltip(providerGroup.modelData)
        }
      }
    }

    Item {
      visible: root.hiddenBarProviderCount > 0
      implicitWidth: overflowText.implicitWidth
      implicitHeight: overflowText.implicitHeight

      Text {
        id: overflowText
        anchors.verticalCenter: parent.verticalCenter
        text: "+" + root.hiddenBarProviderCount
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // This needs its own registered target just like a meter group. The
      // outer WidgetButton is visually behind the row and is not guaranteed
      // to receive a hit through every bar implementation.
      WidgetButton {
        anchors.fill: parent
        bar: root.bar
        hasVisualContent: true
        text: ""
        labelVisible: false
        onPressed: function(buttonCode) {
          if (buttonCode === Qt.RightButton) root.launchAgent()
          else root.toggle()
        }
      }

      MouseArea {
        id: overflowHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      PanelToolTip {
        visible: overflowHover.containsMouse
        text: root.hiddenBarProviderCount + " more subscription"
          + (root.hiddenBarProviderCount === 1 ? "" : "s") + " — click to open the full list"
        fontFamily: root.fontFamily
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // A dashboard needs room for labels and numbers to breathe. The previous
    // narrow panel regularly truncated the cost source and model names,
    // making otherwise correct information look unfinished.
    contentWidth: panel.fittedContentWidth(root.settingsOpen ? Style.space(840) : Style.space(430))
    // Keep the everyday Claude/Codex view on screen. Details can be longer,
    // but making the default popup short turned even ordinary mouse-wheel
    // scrolling into needless work.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(660))
    // KeyboardPanel derives the card origin from this height. Details reveal
    // several sections at once, so let the card settle to its new anchor over
    // one short transition instead of visibly snapping as each binding lands.
    Behavior on contentHeight {
      NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(150), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "e" || t === "E") root.toggleExpanded()
        else if (t === "s" || t === "S") root.toggleSettings()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        maximumFlickVelocity: 10000
        flickDeceleration: 4200
        // The normal view fits without scrolling. Details and Settings still
        // respond to wheel, touchpad, drag, and keyboard, without a permanent
        // scrollbar competing with the information. WheelHandler below makes
        // the discrete wheel step explicit instead of relying on the small
        // platform default used by Flickable.

        WheelHandler {
          id: panelWheel

          onWheel: function(event) {
            var delta = Number(event.pixelDelta.y || 0)
            if (delta === 0) delta = Number(event.angleDelta.y || 0) / 120 * Style.space(72)
            if (delta === 0 || panelFlick.contentHeight <= panelFlick.height) return

            panelFlick.cancelFlick()
            panelFlick.contentY = root.clamp(
              panelFlick.contentY - delta * 1.7,
              0,
              Math.max(0, panelFlick.contentHeight - panelFlick.height))
            event.accepted = true
          }
        }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(18)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: root.provider ? root.provider.providerName : ""
            meta: root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            // Two distinct, separately-labeled controls rather than one
            // overloaded toggle: the gear opens the settings form (issue
            // 08), the chevron reveals the cross-provider data section
            // (issue 07). They're mutually exclusive (see toggleExpanded/
            // toggleSettings) so opening one never leaves the other's
            // content stacked underneath, taking up scroll height nobody
            // asked to see.
            trailingControl: Component {
              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                PanelActionButton {
                  iconText: "󰒓"
                  tooltipText: root.settingsOpen ? "Close settings (s)" : "Settings (s)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  size: Style.space(28)
                  fontSize: Style.font.body
                  bordered: true
                  focusable: true
                  onClicked: root.toggleSettings()
                }

                PanelActionButton {
                  visible: !root.settingsOpen
                  iconText: root.expanded ? "󰅃" : "󰅀"
                  tooltipText: root.expanded ? "Hide details (e)" : "Show detailed history and all-provider models (e)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  size: Style.space(28)
                  fontSize: Style.font.body
                  bordered: true
                  focusable: true
                  onClicked: root.toggleExpanded()
                }
              }
            }

            iconComponent: Component {
              Item {
                id: heroMark
                property var candidates: root.iconCandidatesForProvider(root.provider, root.surface)
                // Provider objects are rebuilt on every refresh, which churns the
                // array's identity without changing its content. Restart the fallback
                // walk only when the URLs change: re-pointing source at a URL whose
                // load already failed emits no statusChanged, so an identity-only
                // reset would strand the walker on a missing -light twin.
                property string candidatesKey: candidates.join("\n")
                property int candidateIndex: 0
                property real iconScale: root.iconScaleForProvider(root.provider)
                onCandidatesKeyChanged: candidateIndex = 0

                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.centerIn: parent
                  width: Math.round(parent.width * heroMark.iconScale)
                  height: Math.round(parent.height * heroMark.iconScale)
                  // See ProviderMark's bar-scale Image: decode at physical
                  // pixels so the hero mark stays crisp on HiDPI outputs too.
                  sourceSize.width: Math.round(width * Screen.devicePixelRatio)
                  sourceSize.height: Math.round(height * Screen.devicePixelRatio)
                  smooth: true
                  mipmap: true
                  source: heroMark.candidateIndex < heroMark.candidates.length ? heroMark.candidates[heroMark.candidateIndex] : ""
                  fillMode: Image.PreserveAspectFit
                  // Advancing source from inside its own status change trips the
                  // binding-loop detector; defer the step one tick.
                  onStatusChanged: if (status === Image.Error && heroMark.candidateIndex < heroMark.candidates.length)
                    Qt.callLater(function() { heroMark.candidateIndex++ })
                }

                Text {
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: usage.initialDiscoveryComplete
              ? "No AI coding subscriptions found.\nAgents show up here once you've used them."
              : "Scanning AI coding subscriptions…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          // Providers are represented by fixed-size marks rather than text
          // pills. This keeps the selector useful as the provider count
          // grows; the full name is available on hover and keyboard focus.
          // Grid has an explicit height because Flow's implicitHeight is not
          // reliable while a Repeater model is being rebuilt during refresh.
          Grid {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.space(6)
            readonly property real chipSize: Math.max(
              Style.space(32),
              Math.min(Style.space(42),
                (width - spacing * Math.max(0, root.providers.length - 1))
                  / Math.max(1, root.providers.length)))
            readonly property int columnCount: Math.max(1, Math.min(root.providers.length,
              Math.floor((width + spacing) / (chipSize + spacing))))
            readonly property int rowCount: Math.ceil(root.providers.length / columnCount)
            columns: columnCount
            height: rowCount * chipSize + Math.max(0, rowCount - 1) * spacing

            // Reordering never moves a real grid child or touches the model
            // mid-drag — both are exactly what made the previous attempt
            // leave marks floating outside the grid. Only a separate ghost
            // item (below) follows the pointer; the real chips stay exactly
            // where the Grid put them the whole time, so there is nothing
            // for the Grid to "forget" to reposition afterwards. dragFrom is
            // the chip actually being moved; dragTo is whichever chip's slot
            // the pointer is currently over (or -1 over empty space) — read
            // once, on release, to compute the new order.
            property int dragFromIndex: -1
            property int dragToIndex: -1

            function updateDragTarget(offsetX, offsetY) {
              var fromItem = providerChipRepeater.itemAt(dragFromIndex)
              if (!fromItem) { dragToIndex = -1; return }
              var cx = fromItem.x + offsetX + fromItem.width / 2
              var cy = fromItem.y + offsetY + fromItem.height / 2
              var best = -1
              for (var i = 0; i < providerChipRepeater.count; i++) {
                var item = providerChipRepeater.itemAt(i)
                if (!item) continue
                if (cx >= item.x && cx < item.x + item.width && cy >= item.y && cy < item.y + item.height) {
                  best = i
                  break
                }
              }
              dragToIndex = best
            }

            Repeater {
              id: providerChipRepeater
              model: root.providers

              Button {
                id: providerChip
                required property var modelData
                required property int index

                width: providerSwitch.chipSize
                height: providerSwitch.chipSize
                tooltipText: String(modelData && (modelData.providerName || modelData.providerId) || "Provider") + " — drag to reorder"
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                horizontalPadding: 0
                verticalPadding: 0
                leftPadding: 0
                rightPadding: 0
                topPadding: 0
                bottomPadding: 0
                // The chip being lifted fades in place (it does not move);
                // whichever chip the drag currently hovers gets an accent
                // ring, so it's clear where letting go will drop it.
                opacity: providerSwitch.dragFromIndex === index ? 0.35 : 1.0

                Rectangle {
                  anchors.fill: parent
                  visible: providerSwitch.dragFromIndex >= 0
                    && providerSwitch.dragToIndex === index
                    && providerSwitch.dragToIndex !== providerSwitch.dragFromIndex
                  color: "transparent"
                  radius: Style.cornerRadius
                  border.width: 2
                  border.color: Color.accent
                }

                // A plain click still selects the provider (see the Button's
                // own MouseArea below) — this only takes over once the
                // pointer moves past the platform's drag threshold, so a tap
                // and a drag never fight over the same gesture. target: null
                // keeps it from moving providerChip itself; see dragGhost.
                DragHandler {
                  id: chipDrag
                  target: null
                  onActiveChanged: {
                    if (active) {
                      root.cursorActive = true
                      providerSwitch.dragFromIndex = providerChip.index
                      providerSwitch.dragToIndex = providerChip.index
                      dragGhost.begin(providerChip)
                      return
                    }
                    var fromIndex = providerSwitch.dragFromIndex
                    var toIndex = providerSwitch.dragToIndex
                    providerSwitch.dragFromIndex = -1
                    providerSwitch.dragToIndex = -1
                    dragGhost.visible = false
                    if (toIndex < 0 || toIndex === fromIndex) return
                    var ids = root.providers.map(function(p) { return p.providerId })
                    var moved = ids.splice(fromIndex, 1)
                    ids.splice(toIndex, 0, moved[0])
                    usage.setProviderOrder(ids)
                  }
                  onTranslationChanged: {
                    if (!active) return
                    providerSwitch.updateDragTarget(translation.x, translation.y)
                    dragGhost.follow(translation.x, translation.y)
                  }
                }

                ProviderMark {
                  anchors.centerIn: parent
                  width: Math.min(parent.width - Style.space(10), Style.space(24))
                  height: width
                  provider: providerChip.modelData
                  opacity: providerChip.selected || providerChip.hasCursor ? 1.0 : 0.82
                }

                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          Text {
            visible: providerSwitch.visible
            width: parent.width
            text: root.providers.length + " providers · drag marks to reorder"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          // Floating copy of whichever mark is being dragged, parented at the
          // panel's top level (not inside providerSwitch's Grid) so it can
          // render above every sibling section regardless of where the
          // switcher sits, positioned by mapping the stationary source
          // chip's coordinates into root's space rather than by being moved
          // as a grid child itself.
          Item {
            id: dragGhost
            parent: root
            z: 1000
            visible: false
            width: 0
            height: 0

            property var provider: null

            function begin(chipItem) {
              width = chipItem.width
              height = chipItem.height
              provider = chipItem.modelData
              visible = true
              follow(0, 0)
            }

            function follow(offsetX, offsetY) {
              var source = providerChipRepeater.itemAt(providerSwitch.dragFromIndex)
              if (!source) return
              var origin = source.mapToItem(root, 0, 0)
              x = origin.x + offsetX
              y = origin.y + offsetY
            }

            ProviderMark {
              anchors.centerIn: parent
              width: Math.min(parent.width - Style.space(10), Style.space(24))
              height: width
              provider: dragGhost.provider
              opacity: 0.92
            }
          }

          // ---------- Status ----------
            BorderSurface {
              visible: !root.settingsOpen && !!root.provider && String(root.provider.usageStatusText || "") !== ""
              width: parent.width
              implicitHeight: statusContent.implicitHeight + Style.spacing.xl * 2
              color: root.alpha(root.statusColor(root.provider), 0.10)
              borderSpec: Border.flat(root.alpha(root.statusColor(root.provider), 0.35), 1)
              radius: Style.cornerRadius

              Column {
                id: statusContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  text: root.provider ? String(root.provider.usageStatusText || "") : ""
                  textFormat: Text.PlainText
                  color: root.statusColor(root.provider)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: text !== ""
                  width: parent.width
                  text: root.provider ? String(root.provider.authHelpText || "") : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible || detailModelSection.visible || costSection.visible
            foreground: root.foreground
          }

          BorderSurface {
            id: balanceSection
            visible: !root.settingsOpen && !!root.balance
            width: parent.width
            implicitHeight: balanceContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: Style.cornerRadius

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            Column {
              id: balanceContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              PanelSectionHeader {
                width: parent.width
                text: "Prepaid balance"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Item {
                width: parent.width
                implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

                Text {
                  id: balanceLabel
                  text: "Available"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: balanceValue
                  text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Meter {
                visible: balanceSection.ratio >= 0
                width: parent.width
                value: balanceSection.ratio
                severity: root.balanceSeverity
              }

              Text {
                visible: text !== ""
                width: parent.width
                text: root.balanceDetailText(root.balance)
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          BorderSurface {
            id: limitsSection
            visible: !root.settingsOpen && root.limits.length > 0
            width: parent.width
            implicitHeight: limitsContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: Style.cornerRadius

            Column {
              id: limitsContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              PanelSectionHeader {
                width: parent.width
                text: "Allowance"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.limits

                LimitRow {
                  required property var modelData
                  width: limitsContent.width
                  window: modelData
                }
              }
            }
          }

          // ---------- Token usage by model ----------
          // Details starts with the useful accounting view. Price information
          // lives in the analytics card below, so this table stays about the
          // provider's actual recorded token use and never repeats a cost.
          BorderSurface {
            id: detailModelSection
            visible: root.expanded && root.detailModels.length > 0
            width: parent.width
            implicitHeight: detailModelContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: Style.cornerRadius

            Column {
              id: detailModelContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              PanelSectionHeader {
                width: parent.width
                text: "Token use by model"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Item {
                width: parent.width
                implicitHeight: modelHeading.implicitHeight

                Text {
                  id: modelHeading
                  text: "MODEL"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "TOKENS"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Repeater {
                model: root.detailModels

                ModelRow {
                  required property var modelData
                  width: detailModelContent.width
                  row: modelData
                  share: modelData.total / Math.max(1, root.detailModels[0].total)
                }
              }
            }
          }

          // ---------- Plan vs API (Details only) ----------------------------
          // Keep the accounting question in one place: what the provider says
          // was used on the plan/credit ledger, and what the same local token
          // usage would cost at published API rates. The second number is an
          // equivalent, never an invoice or a subscription price.
          Column {
            id: costSection
            visible: root.expanded && !root.settingsOpen
              && root.costProviderRows.length > 0
            width: parent.width
            spacing: Style.space(10)

            BorderSurface {
              id: costProviderOverview
              visible: root.costProviderRows.length > 0
              width: parent.width
              implicitHeight: providerOverviewContent.implicitHeight + Style.space(28)
              color: root.alpha(root.foreground, 0.035)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
              radius: Style.cornerRadius

              Column {
                id: providerOverviewContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(8)

                PanelSectionHeader {
                  width: parent.width
                  text: "All providers"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  width: parent.width
                  text: "Plan usage next to a published API-rate equivalent"
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Item {
                  width: parent.width
                  implicitHeight: providerTableHeading.implicitHeight

                  Text {
                    id: providerTableHeading
                    text: "PROVIDER"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: "ON PLAN / CREDIT"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    horizontalAlignment: Text.AlignRight
                    anchors.right: providerApiColumn.left
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(94)
                  }

                  Text {
                    id: providerApiColumn
                    text: "IF API"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    horizontalAlignment: Text.AlignRight
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(78)
                  }
                }

                Repeater {
                  model: root.costProviderRows

                  Item {
                    id: providerCostRow
                    required property var modelData
                    width: providerOverviewContent.width
                    height: Style.space(50)

                    Rectangle {
                      anchors.fill: parent
                      radius: Style.cornerRadius
                      color: root.provider && root.provider.providerId === providerCostRow.modelData.providerId
                        ? root.alpha(Color.accent, 0.10) : "transparent"
                    }

                    Text {
                      id: providerCostName
                      text: String(providerCostRow.modelData.providerName || "Provider")
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                      anchors.left: parent.left
                      anchors.right: providerCostPlanValue.left
                      anchors.rightMargin: Style.space(8)
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(4)
                    }

                    Text {
                      id: providerCostHint
                      text: root.costPlanHint(providerCostRow.modelData)
                      textFormat: Text.PlainText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      anchors.right: providerCostPlanValue.left
                      anchors.rightMargin: Style.space(8)
                      anchors.left: parent.left
                      anchors.top: providerCostName.bottom
                      anchors.topMargin: Style.space(1)
                    }

                    Text {
                      id: providerCostPlanValue
                      width: Style.space(94)
                      text: root.costPlanValue(providerCostRow.modelData)
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      horizontalAlignment: Text.AlignRight
                      anchors.right: providerCostApiValue.left
                      anchors.rightMargin: Style.space(10)
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(4)
                    }

                    Text {
                      id: providerCostApiValue
                      width: Style.space(78)
                      text: root.costApiValue(providerCostRow.modelData)
                      textFormat: Text.PlainText
                      color: providerCostRow.modelData.hasCost ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: providerCostRow.modelData.hasCost
                      horizontalAlignment: Text.AlignRight
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(4)
                    }

                    Rectangle {
                      id: providerUsageTrack
                      visible: Number(providerCostRow.modelData.usagePercent) >= 0
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      height: Math.max(Style.space(3), Math.round(Style.spacing.controlHeight * 0.10))
                      radius: height / 2
                      color: root.track
                    }

                    Rectangle {
                      anchors.left: providerUsageTrack.left
                      anchors.verticalCenter: providerUsageTrack.verticalCenter
                      width: providerUsageTrack.width * root.clamp(Number(providerCostRow.modelData.usagePercent || 0), 0, 1)
                      height: providerUsageTrack.height
                      radius: providerUsageTrack.radius
                      color: root.provider && root.provider.providerId === providerCostRow.modelData.providerId
                        ? root.foreground : Color.accent
                    }
                  }
                }
              }
            }

            BorderSurface {
              id: costValueCard
              visible: !!root.provider
              width: parent.width
              // Give this information-dense card the same generous breathing
              // room as the provider overview above it. The extra vertical
              // space improves scanability without hiding any analytics.
              implicitHeight: costValueContent.implicitHeight + Style.space(36)
              color: root.alpha(root.foreground, 0.035)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
              radius: Style.cornerRadius

              Column {
                id: costValueContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(18)
                anchors.rightMargin: Style.space(18)
                spacing: Style.space(14)

                PanelSectionHeader {
                  width: parent.width
                  text: "API equivalent" + (root.cost && root.cost.period ? " · " + root.cost.period : "")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  // The "not a bill" disclaimer is already implied by the "If
                  // billed by API" metric label below, so it's only worth a
                  // full line here when there's something actionable to say:
                  // a partial estimate, or no priced data at all.
                  id: costDisclosure
                  visible: !!root.provider
                  width: parent.width
                  text: !root.cost
                    ? "No priced token total for this provider yet."
                    : (root.cost.incomplete
                      ? "Partial estimate · " + root.unpricedModelText(root.cost)
                      : "Published API-rate equivalent · not subscription billing.")
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Row {
                  id: costMetrics
                  width: parent.width
                  spacing: Style.space(14)

                  CostMetric {
                    width: (costMetrics.width - costMetrics.spacing * 2) / 3
                    valueText: root.costPlanValue(root.costProviderRow(root.provider))
                    label: root.costPlanLabel(root.costProviderRow(root.provider))
                    hint: root.costPlanHint(root.costProviderRow(root.provider))
                  }

                  CostMetric {
                    width: (costMetrics.width - costMetrics.spacing * 2) / 3
                    valueText: root.cost ? root.formatUsd(root.cost.estimateUsd) : "—"
                    label: "API equivalent"
                    // The disclosure above already explains the estimate;
                    // repeating "published-rate" in this small tile adds
                    // noise without adding information.
                    hint: ""
                  }

                  CostMetric {
                    width: (costMetrics.width - costMetrics.spacing * 2) / 3
                    valueText: root.costSummary && root.costSummary.hasDailyAverage
                      ? root.formatUsd(root.costSummary.averageDailyUsd) : "—"
                    label: "Avg / recorded day"
                    hint: root.costSummary && root.costSummary.hasDailyAverage
                      ? root.costSummary.averageDailyDays + " recorded days" : "No day count"
                  }
                }

                Column {
                  id: costDailyBlock
                  visible: !!root.cost && root.costDailyRows.length > 0
                  width: parent.width
                  spacing: Style.space(10)

                  PanelSectionHeader {
                    width: parent.width
                    text: "Daily API trend"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Text {
                    visible: root.costDailyRows.length > 0
                    width: parent.width
                    text: root.costSummary
                      ? root.costDailyRows.length + " recorded days · "
                        + root.formatUsd(root.costSummary.dailyTotalUsd)
                        + (root.costSummary.dailySource === "reported" ? " reported" : " derived")
                      : ""
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    id: costDailyChart
                    visible: root.costDailyRows.length > 0
                    width: parent.width
                    height: Style.space(166)

                    readonly property real axisLeft: Style.space(48)
                    readonly property real axisRight: Style.space(8)
                    readonly property real axisTop: Style.space(10)
                    readonly property real axisBottom: Style.space(24)
                    readonly property real plotWidth: Math.max(0, width - axisLeft - axisRight)
                    readonly property real plotHeight: Math.max(0, height - axisTop - axisBottom)
                    readonly property real peak: root.costSummary
                      ? Math.max(0, Number(root.costSummary.dailyPeakUsd || 0)) : 0

                    Repeater {
                      model: [0, 0.5, 1]

                      Item {
                        required property real modelData
                        width: costDailyChart.width
                        height: 1
                        y: costDailyChart.axisTop
                          + costDailyChart.plotHeight * (1 - modelData)

                        Text {
                          width: costDailyChart.axisLeft - Style.space(8)
                          height: Style.space(14)
                          y: -height / 2
                          text: root.formatUsd(costDailyChart.peak * modelData)
                          textFormat: Text.PlainText
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          horizontalAlignment: Text.AlignRight
                          elide: Text.ElideRight
                        }

                        Rectangle {
                          x: costDailyChart.axisLeft
                          width: costDailyChart.plotWidth
                          height: 1
                          color: root.alpha(root.foreground, 0.14)
                        }
                      }
                    }

                    Repeater {
                      model: root.costDailyRows

                      Item {
                        id: costDayBar
                        required property var modelData
                        required property int index
                        width: costDailyChart.plotWidth / Math.max(1, root.costDailyRows.length)
                        height: costDailyChart.plotHeight
                        x: costDailyChart.axisLeft + index * width
                        y: costDailyChart.axisTop

                        Rectangle {
                          width: Math.max(3, Math.min(parent.width * 0.66, parent.width - Style.space(4)))
                          height: Number(costDayBar.modelData.usd || 0) > 0
                            ? Math.max(2, parent.height * Math.min(1,
                              Number(costDayBar.modelData.usd || 0) / Math.max(0.0001, costDailyChart.peak)))
                            : 1
                          anchors.bottom: parent.bottom
                          anchors.horizontalCenter: parent.horizontalCenter
                          radius: Math.min(width / 2, Style.cornerRadius)
                          color: costDayBar.index === root.costDailyRows.length - 1
                            ? root.foreground : Color.accent
                          opacity: costDayBar.index === root.costDailyRows.length - 1 ? 1.0 : 0.78
                        }

                        MouseArea {
                          id: costDayHover
                          anchors.fill: parent
                          hoverEnabled: true
                          acceptedButtons: Qt.NoButton
                        }

                        PanelToolTip {
                          visible: costDayHover.containsMouse
                          text: root.shortHistoryDate(costDayBar.modelData.date) + " · "
                            + root.formatUsd(costDayBar.modelData.usd)
                          fontFamily: root.fontFamily
                        }
                      }
                    }

                    Row {
                      id: costDailyLabels
                      x: costDailyChart.axisLeft
                      y: costDailyChart.height - height
                      width: costDailyChart.plotWidth
                      height: Style.space(16)

                      Repeater {
                        model: root.costDailyRows

                        Text {
                          required property var modelData
                          required property int index
                          width: costDailyLabels.width / Math.max(1, root.costDailyRows.length)
                          visible: index === 0 || index === root.costDailyRows.length - 1
                            || (root.costDailyRows.length > 2
                              && index === Math.floor((root.costDailyRows.length - 1) / 2))
                          text: root.shortHistoryDate(modelData.date)
                          textFormat: Text.PlainText
                          color: index === root.costDailyRows.length - 1 ? root.foreground : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          horizontalAlignment: Text.AlignHCenter
                          elide: Text.ElideRight
                        }
                      }
                    }
                  }
                }

                Column {
                  id: costModelChart
                  visible: root.costModelRows.length > 0
                  width: parent.width
                  spacing: Style.space(10)

                  PanelSectionHeader {
                    width: parent.width
                    text: "API equivalent by model"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    model: root.costModelRows

                    Item {
                      id: costModelRow
                      required property var modelData
                      width: costModelChart.width
                      height: Style.space(44)

                      Text {
                        id: costModelName
                        text: usage.friendlyModelName(costModelRow.modelData.model)
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        elide: Text.ElideRight
                        anchors.left: parent.left
                        anchors.right: costModelValue.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        id: costModelValue
                        width: Style.space(78)
                        text: root.formatUsd(costModelRow.modelData.usd)
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        horizontalAlignment: Text.AlignRight
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: Math.max(Style.space(3), Math.round(Style.spacing.controlHeight * 0.10))
                        radius: height / 2
                        color: root.track
                      }

                      Rectangle {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        width: parent.width * root.clamp(Number(costModelRow.modelData.share || 0), 0, 1)
                        height: Math.max(Style.space(3), Math.round(Style.spacing.controlHeight * 0.10))
                        radius: height / 2
                        color: Color.accent

                        Behavior on width {
                          NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                        }
                      }

                    }
                  }
                }

                Text {
                  visible: !!root.cost && root.costModelRows.length === 0
                  width: parent.width
                  text: "No model-level API pricing was provided."
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: !!root.cost && root.costDailyRows.length === 0
                    && root.costSummary && root.costSummary.hasDailyAverage
                  width: parent.width
                  text: root.costSummary
                    ? "No day-by-day pricing data · average uses "
                      + root.costSummary.averageDailyDays + " recorded usage days."
                    : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: text !== ""
                  width: parent.width
                  text: root.cost ? root.costFooterText(root.cost, root.costSummary) : ""
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            // Replaced by the full labelled history chart in Details. A
            // three-day mini-chart followed by a second chart was redundant
            // and made both the data and the scrolling worse.
            visible: false
            width: parent.width
            spacing: Style.spacing.md

            readonly property int maxSummaryDays: 3
            readonly property int availableDayCount: root.provider && root.provider.recentDays
              ? root.provider.recentDays.length : 0
            readonly property var days: root.summaryDays(root.provider, maxSummaryDays)
            readonly property real peak: Math.max(1, root.dayPeak(days))

            PanelSectionHeader {
              width: parent.width
              text: "Recent activity"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }

            Text {
              visible: usageSection.availableDayCount > usageSection.days.length
              width: parent.width
              text: usageSection.days.length + " of " + usageSection.availableDayCount
                + " days shown · Details has the full history"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            // Keep Details focused on the time-series users can act on.
            // Model totals remain available in the collector records and
            // should return only with a purpose-built comparison view.
            visible: false
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "Most-used models"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          // ---------- Expanded: combined view across every enabled
          // provider, not just the currently selected chip. Purely
          // additive — session-only `expanded` defaults to false, so a
          // panel that never toggles it renders identically to before
          // this section existed.
          PanelSeparator {
            visible: false
            foreground: root.foreground
          }

          Column {
            id: expandedSection
            visible: false
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL · ALL SUBSCRIPTIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.allModels

              ModelRow {
                required property var modelData
                width: expandedSection.width
                row: modelData
                share: modelData.total / Math.max(1, root.allModels[0].total)
              }
            }

            Text {
              visible: root.allModels.length === 0
              width: parent.width
              text: "No model usage yet across enabled subscriptions."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // ---------- History chart (issue 13): all recorded days for the
          // selected provider. The line makes the trend readable at a glance;
          // the axis labels make the scale explicit instead of asking the
          // viewer to infer it from bar height.
          PanelSeparator {
            visible: root.expanded
            foreground: root.foreground
          }

          Column {
            id: historySection
            visible: root.expanded
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "History"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: !root.provider
              width: parent.width
              text: "Select a subscription above to see its history."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Text {
              visible: !!(root.historySeries && root.historySeries.ok)
              width: parent.width
              text: root.historySeries
                ? root.historySeries.points.length + " recorded days · "
                  + usage.formatTokenCount(root.historySeriesTotal(root.historySeries)) + " tokens"
                : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Canvas {
              id: historyCanvas
              visible: !!(root.historySeries && root.historySeries.ok && root.historySeries.points.length > 0)
              width: parent.width
              height: Style.space(146)

              readonly property real axisLeft: Style.space(46)
              readonly property real axisRight: Style.space(8)
              readonly property real axisTop: Style.space(10)
              readonly property real axisBottom: Style.space(22)

              property var series: root.historySeries
              property color lineColor: Color.accent

              onSeriesChanged: requestPaint()
              onWidthChanged: requestPaint()
              onHeightChanged: requestPaint()
              onLineColorChanged: requestPaint()
              onVisibleChanged: if (visible) requestPaint()

              // Canvas paint code has no lint/type-check coverage the rest
              // of this file gets and a thrown exception here can silently
              // blank the whole panel rather than just this chart — the
              // try/catch is a hard backstop, not decoration, and the
              // early returns keep an empty/single-point series (or a
              // still-resizing width/height of 0) from ever reaching the
              // drawing math below.
              onPaint: {
                var ctx = getContext("2d")
                try {
                  ctx.clearRect(0, 0, width, height)

                  var s = historyCanvas.series
                  if (!s || !s.ok || !s.points || s.points.length === 0) return
                  if (width <= 0 || height <= 0) return

                  var points = s.points
                  var n = points.length
                  var left = historyCanvas.axisLeft
                  var right = historyCanvas.axisRight
                  var top = historyCanvas.axisTop
                  var bottom = height - historyCanvas.axisBottom
                  var plotWidth = width - left - right
                  var plotHeight = bottom - top
                  if (plotWidth <= 0 || plotHeight <= 0) return
                  var peak = Math.max(0, Number(s.peak) || 0)
                  var scale = peak > 0 ? peak : 1

                  ctx.font = String(Style.font.caption) + "px " + root.fontFamily
                  ctx.textAlign = "right"
                  ctx.textBaseline = "middle"

                  // Three quiet guides provide a real scale without turning
                  // the chart into a grid. The labels use the same compact
                  // token formatter as the rest of the panel.
                  for (var level = 0; level <= 2; level++) {
                    var fraction = level / 2
                    var guideY = bottom - plotHeight * fraction
                    ctx.strokeStyle = root.alpha(root.foreground, 0.14)
                    ctx.lineWidth = 1
                    ctx.beginPath()
                    ctx.moveTo(left, guideY + 0.5)
                    ctx.lineTo(width - right, guideY + 0.5)
                    ctx.stroke()
                    ctx.fillStyle = root.dim
                    ctx.fillText(usage.formatTokenCount(Math.round(peak * fraction)), left - Style.space(7), guideY)
                  }

                  function pointX(index) {
                    return n <= 1 ? left + plotWidth / 2 : left + plotWidth * index / (n - 1)
                  }
                  function pointY(point) {
                    var value = Math.max(0, Number(point && point.value) || 0)
                    return bottom - plotHeight * Math.min(1, value / scale)
                  }

                  ctx.strokeStyle = historyCanvas.lineColor
                  ctx.lineWidth = 2
                  ctx.lineCap = "round"
                  ctx.lineJoin = "round"
                  ctx.beginPath()
                  for (var i = 0; i < n; i++) {
                    var linePoint = points[i] || {}
                    var lineX = pointX(i)
                    var lineY = pointY(linePoint)
                    if (i === 0) ctx.moveTo(lineX, lineY)
                    else ctx.lineTo(lineX, lineY)
                  }
                  ctx.stroke()

                  // A small dot preserves zero-usage days and makes the
                  // latest point easy to find without filled histogram bars.
                  for (var j = 0; j < n; j++) {
                    var point = points[j] || {}
                    ctx.fillStyle = String(point.date || "") === root.todayDate()
                      ? root.foreground : historyCanvas.lineColor
                    ctx.beginPath()
                    ctx.arc(pointX(j), pointY(point), j === n - 1 ? 3.5 : 2.5, 0, Math.PI * 2)
                    ctx.fill()
                  }
                } catch (e) {
                  // Swallow: a chart that fails to draw should leave a
                  // blank strip, not take the rest of the panel down.
                }
              }
            }

            Row {
              id: historyLabels
              visible: !!(root.historySeries && root.historySeries.ok && root.historySeries.points.length > 0)
              width: parent.width

              Repeater {
                model: root.historySeries && root.historySeries.points ? root.historySeries.points : []

                Text {
                  required property var modelData
                  required property int index
                  width: historyLabels.width / Math.max(1,
                    root.historySeries && root.historySeries.points
                      ? root.historySeries.points.length : 1)
                  visible: {
                    var count = root.historySeries && root.historySeries.points
                      ? root.historySeries.points.length : 0
                    return index === 0 || index === count - 1
                      || (count > 2 && index === Math.floor((count - 1) / 2))
                  }
                  text: root.shortHistoryDate(modelData.date)
                  horizontalAlignment: Text.AlignHCenter
                  color: root.historySeries && root.historySeries.points
                    && index === root.historySeries.points.length - 1
                    ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              visible: !!(root.historySeries && !root.historySeries.ok)
              width: parent.width
              text: root.historyUnavailableText(root.historySeries)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Settings: the same values `omarchy bar set` edits,
          // editable here without a terminal (issue 08). Gated by its own
          // `settingsOpen` flag (not `expanded`) so opening settings doesn't
          // also force the cross-provider data section into view — the two
          // are mutually exclusive, see toggleSettings(). The settings
          // themselves are obviously not session-only — every control
          // writes through to shell.json.
          PanelSeparator {
            visible: root.settingsOpen
            foreground: root.foreground
          }

          Column {
            id: settingsSection
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.spacing.lg

            // Discard any unsaved draft the moment settings are reopened,
            // rather than resuming an edit from a previous visit — resyncing
            // only here (never on a live settings change) is what keeps a
            // draft immune to being clobbered while the panel is open.
            onVisibleChanged: if (visible) behaviourContent.resyncDrafts()

            PanelSectionHeader {
              width: parent.width
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // ----- Per-provider controls -----
            // A single compact row per provider keeps the list scannable even
            // when several collectors are installed. The switches stay in a
            // fixed column so the eye can compare providers without hunting
            // through cards or provider-specific prose.
            Column {
              id: providerSettingsList
              width: parent.width
              spacing: Style.space(8)
              readonly property real contentWidth: width - Style.space(28)
              readonly property real providerColumnWidth: Math.min(300, Math.max(210, contentWidth * 0.36))
              readonly property real controlColumnWidth: contentWidth - providerColumnWidth - Style.space(18)
              readonly property real controlCellWidth: (controlColumnWidth - Style.space(24) * 2) / 3
              readonly property var barRoleOptions: ["off", "fixed", "cycle"]
              readonly property var barRoleLabels: ({ off: "Off", fixed: "Fixed", cycle: "Cycle" })
              readonly property real barRoleButtonWidth: Math.max(Style.space(38),
                (controlCellWidth - Style.space(8)) / barRoleOptions.length)
              readonly property var labelModeOptions: ["icon", "iconPercent", "full"]
              readonly property var labelModeLabels: ({ icon: "Icon", iconPercent: "Icon+%", full: "Full" })
              readonly property real labelModeButtonWidth: Math.max(Style.space(38),
                (controlCellWidth - Style.space(8)) / labelModeOptions.length)

              Row {
                x: Style.space(14)
                width: parent.width - Style.space(28)
                height: Style.space(22)
                spacing: Style.space(18)

                Item { width: providerSettingsList.providerColumnWidth; height: parent.height }

                Repeater {
                  model: ["Enabled", "Bar slot", "Bar shows"]

                  Item {
                    required property string modelData
                    width: providerSettingsList.controlCellWidth
                    height: parent.height

                    Text {
                      anchors.centerIn: parent
                      text: modelData
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                }
              }

              Repeater {
                model: root.settingsProviders

                Rectangle {
                  id: providerSettingsRow
                  required property var modelData
                  width: providerSettingsList.width
                  height: Style.space(62)
                  color: root.alpha(root.foreground, 0.035)
                  border.width: 1
                  border.color: root.alpha(root.foreground, 0.12)
                  radius: Style.cornerRadius

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(14)
                    spacing: Style.space(18)

                    Item {
                      width: providerSettingsList.providerColumnWidth
                      height: parent.height

                      Row {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(10)

                        ProviderMark {
                          width: Style.space(24)
                          height: Style.space(24)
                          provider: providerSettingsRow.modelData
                        }

                        Text {
                          width: parent.width - Style.space(34)
                          text: providerSettingsRow.modelData.providerName
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                          elide: Text.ElideRight
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }

                    Item {
                      width: providerSettingsList.controlColumnWidth
                      height: parent.height

                      Row {
                        anchors.fill: parent
                        spacing: Style.space(24)

                        Item {
                          width: providerSettingsList.controlCellWidth
                          height: parent.height

                          ToggleSwitch {
                            anchors.centerIn: parent
                            checked: providerSettingsRow.modelData.enabled
                            foreground: root.foreground
                            accent: Color.accent
                            onToggled: usage.setProviderEnabled(providerSettingsRow.modelData.providerId, !providerSettingsRow.modelData.enabled)
                          }
                        }

                        Item {
                          width: providerSettingsList.controlCellWidth
                          height: parent.height
                          // Fixed/Cycle also enables the provider. Keep this
                          // selector clickable even while its Enabled switch
                          // is off, otherwise it cannot perform that action.
                          opacity: providerSettingsRow.modelData.enabled ? 1.0 : 0.62

                          Row {
                            anchors.centerIn: parent
                            spacing: Style.space(4)

                            Repeater {
                              model: providerSettingsList.barRoleOptions

                              Button {
                                required property string modelData
                                width: providerSettingsList.barRoleButtonWidth
                                text: providerSettingsList.barRoleLabels[modelData]
                                tooltipText: modelData === "off" ? "Not shown in the bar"
                                  : modelData === "fixed" ? "Always shown in the bar"
                                  : "Rotates through the bar's Cycle slots"
                                selected: providerSettingsRow.modelData.barRole === modelData
                                bordered: true
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                verticalPadding: Style.space(4)
                                onClicked: usage.setProviderBarRole(
                                  providerSettingsRow.modelData.providerId, modelData)
                              }
                            }
                          }
                        }

                        Item {
                          width: providerSettingsList.controlCellWidth
                          height: parent.height
                          // Only matters once this provider actually has a
                          // bar slot — same dimming rule as Bar slot's own
                          // buttons above, just gated on the role instead of
                          // Enabled, since a Fixed/Cycle role is what makes
                          // this provider's own bar mark exist at all.
                          opacity: providerSettingsRow.modelData.barRole === "off" ? 0.5 : 1.0

                          Row {
                            anchors.centerIn: parent
                            spacing: Style.space(4)

                            Repeater {
                              model: providerSettingsList.labelModeOptions

                              Button {
                                required property string modelData
                                width: providerSettingsList.labelModeButtonWidth
                                text: providerSettingsList.labelModeLabels[modelData]
                                tooltipText: modelData === "icon" ? "Just the mark"
                                  : modelData === "iconPercent" ? "Mark and the percent"
                                  : "Mark, percent, and the meter"
                                selected: providerSettingsRow.modelData.labelMode === modelData
                                bordered: true
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                fontSize: Style.font.caption
                                verticalPadding: Style.space(4)
                                onClicked: usage.setProviderLabelMode(
                                  providerSettingsRow.modelData.providerId, modelData)
                              }
                            }
                          }
                        }

                      }
                    }
                  }
                }
              }
            }

            Text {
              visible: root.settingsProviders.length === 0
              width: parent.width
              text: "No subscriptions discovered yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            BorderSurface {
              id: behaviourSection
              width: parent.width
              implicitHeight: behaviourContent.implicitHeight + Style.space(28)
              color: root.alpha(root.foreground, 0.035)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
              radius: Style.cornerRadius

              Column {
                id: behaviourContent
                anchors.fill: parent
                anchors.margins: Style.space(14)
                spacing: Style.space(10)

                // Draft copies of the numeric fields below, committed only on
                // Save. Binding a SpinBox's `value` straight to a setting
                // meant every settings write (even to an unrelated field, or
                // the periodic refresh reloading `settings` wholesale) could
                // reassert a stale number over whatever the person was still
                // typing. Drafts only ever change from resyncDrafts() (on
                // opening settings) or the fields' own onModified, so nothing
                // else can clobber an in-progress edit.
                property int draftCycleSlots: usage.barCycleSlots
                property int draftCycleIntervalSec: usage.barCycleIntervalSec
                property int draftRefreshIntervalSec: usage.refreshIntervalSec
                property int draftWarnThresholdPct: root.displayWarnThresholdPct
                property int draftCriticalThresholdPct: root.displayCriticalThresholdPct
                property bool draftShowsAvailable: usage.showAvailablePercentage

                readonly property bool settingsDirty: draftCycleSlots !== usage.barCycleSlots
                  || draftCycleIntervalSec !== usage.barCycleIntervalSec
                  || draftRefreshIntervalSec !== usage.refreshIntervalSec
                  || draftWarnThresholdPct !== root.displayWarnThresholdPct
                  || draftCriticalThresholdPct !== root.displayCriticalThresholdPct

                // In used terms Warn must be below Critical; complementing
                // both values reverses that ordering in available terms.
                // Catch either invalid form before Save, where the person
                // editing the number can see why it is stuck.
                readonly property bool draftThresholdsValid: draftShowsAvailable
                  ? draftWarnThresholdPct > draftCriticalThresholdPct
                  : draftWarnThresholdPct < draftCriticalThresholdPct

                function resyncDrafts() {
                  draftCycleSlots = usage.barCycleSlots
                  draftCycleIntervalSec = usage.barCycleIntervalSec
                  draftRefreshIntervalSec = usage.refreshIntervalSec
                  draftWarnThresholdPct = root.displayWarnThresholdPct
                  draftCriticalThresholdPct = root.displayCriticalThresholdPct
                  draftShowsAvailable = usage.showAvailablePercentage
                }

                // Preserve every in-progress draft when the presentation mode
                // changes. Only complement the two threshold fields in place;
                // resyncDrafts() would incorrectly discard unrelated edits.
                function syncPercentageMode() {
                  if (draftShowsAvailable === usage.showAvailablePercentage) return
                  draftWarnThresholdPct = 100 - draftWarnThresholdPct
                  draftCriticalThresholdPct = 100 - draftCriticalThresholdPct
                  draftShowsAvailable = usage.showAvailablePercentage
                }

                function saveDrafts() {
                  usage.setBarCycleSlots(draftCycleSlots)
                  usage.setBarCycleIntervalSec(draftCycleIntervalSec)
                  usage.setRefreshIntervalSec(draftRefreshIntervalSec)
                  usage.setWarnThresholdPct(draftShowsAvailable
                    ? 100 - draftWarnThresholdPct : draftWarnThresholdPct)
                  usage.setCriticalThresholdPct(draftShowsAvailable
                    ? 100 - draftCriticalThresholdPct : draftCriticalThresholdPct)
                }

                Connections {
                  target: usage
                  function onShowAvailablePercentageChanged() {
                    behaviourContent.syncPercentageMode()
                  }
                }

                Text {
                  text: "Bar behaviour & limits"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Grid {
                  id: behaviourGrid
                  width: parent.width
                  columns: 3
                  columnSpacing: Style.space(10)
                  rowSpacing: Style.space(10)
                  readonly property real cellWidth: Math.floor((width - columnSpacing * (columns - 1)) / columns)

                  NumberField {
                    // Disabled rather than hidden when unused, so the grid's
                    // shape never changes as providers switch bar roles —
                    // see the hint text above for why.
                    enabled: root.hasCycleSlotConfigured()
                    opacity: enabled ? 1.0 : 0.5
                    width: behaviourGrid.cellWidth
                    label: "Cycle slots"
                    value: behaviourContent.draftCycleSlots
                    from: 0
                    to: 3
                    stepSize: 1
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onModified: function(v) { behaviourContent.draftCycleSlots = v }
                  }

                  NumberField {
                    enabled: root.hasCycleSlotConfigured()
                    opacity: enabled ? 1.0 : 0.5
                    width: behaviourGrid.cellWidth
                    label: "Rotate (s)"
                    value: behaviourContent.draftCycleIntervalSec
                    from: 3
                    to: 120
                    stepSize: 1
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onModified: function(v) { behaviourContent.draftCycleIntervalSec = v }
                  }

                  NumberField {
                    width: behaviourGrid.cellWidth
                    label: "Refresh (s)"
                    value: behaviourContent.draftRefreshIntervalSec
                    from: 30
                    to: 3600
                    stepSize: 30
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    onModified: function(v) { behaviourContent.draftRefreshIntervalSec = v }
                  }

                  NumberField {
                    width: behaviourGrid.cellWidth
                    label: behaviourContent.draftShowsAvailable ? "Warn avail. (%)" : "Warn used (%)"
                    value: behaviourContent.draftWarnThresholdPct
                    from: 1
                    to: 99
                    stepSize: 1
                    foreground: root.foreground
                    accent: root.warn
                    fontFamily: root.fontFamily
                    onModified: function(v) { behaviourContent.draftWarnThresholdPct = v }
                  }

                  NumberField {
                    width: behaviourGrid.cellWidth
                    label: behaviourContent.draftShowsAvailable ? "Critical avail. (%)" : "Critical used (%)"
                    value: behaviourContent.draftCriticalThresholdPct
                    from: behaviourContent.draftShowsAvailable ? 0 : 1
                    to: behaviourContent.draftShowsAvailable ? 99 : 100
                    stepSize: 1
                    foreground: root.foreground
                    accent: root.urgent
                    fontFamily: root.fontFamily
                    onModified: function(v) { behaviourContent.draftCriticalThresholdPct = v }
                  }
                }

                Text {
                  width: parent.width
                  // One fixed line, never appearing/disappearing: it swaps
                  // between the normal hint and the validation error so nothing
                  // below it jumps when Warn/Critical cross each other.
                  text: behaviourContent.draftThresholdsValid
                    ? (behaviourContent.draftShowsAvailable
                      ? "Warn when available quota falls this low; Critical marks the lower urgent level. Type an exact value or use the arrows, then Save applies all five fields above together."
                      : "Warn colors the meter early; Critical marks it urgent. Type an exact value or use the arrows, then Save applies all five fields above together.")
                    : (behaviourContent.draftShowsAvailable
                      ? "Warn availability must be higher than Critical — Save is disabled until that's fixed."
                      : "Warn usage must be lower than Critical — Save is disabled until that's fixed.")
                  color: behaviourContent.draftThresholdsValid ? root.dim : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Row {
                  spacing: Style.space(10)

                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Save"
                    enabled: behaviourContent.settingsDirty && behaviourContent.draftThresholdsValid
                    // Filled/accented while there's something to commit, so
                    // the one control that actually applies these five
                    // fields reads as the primary action, not a peer of the
                    // plain bordered field controls above it.
                    selected: enabled
                    bordered: true
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(12)
                    verticalPadding: Style.space(4)
                    onClicked: behaviourContent.saveDrafts()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: behaviourContent.settingsDirty ? "Unsaved changes" : "Saved"
                    color: behaviourContent.settingsDirty ? root.warn : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                // Keep every immediate preference on one visible row. Adding
                // another toggle must not make Settings taller or introduce
                // scrolling; each cell stays comfortably within the wide
                // settings panel.
                Grid {
                  id: preferenceGrid
                  width: parent.width
                  columns: 3
                  columnSpacing: Style.space(12)
                  readonly property real cellWidth: Math.floor((width - columnSpacing * 2) / 3)

                  Row {
                    width: preferenceGrid.cellWidth
                    spacing: Style.space(10)

                    ToggleSwitch {
                      anchors.verticalCenter: parent.verticalCenter
                      checked: usage.showAvailablePercentage
                      foreground: root.foreground
                      accent: Color.accent
                      onToggled: usage.setShowAvailablePercentage(!usage.showAvailablePercentage)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Show available quota"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Row {
                    width: preferenceGrid.cellWidth
                    spacing: Style.space(6)

                    ToggleSwitch {
                      anchors.verticalCenter: parent.verticalCenter
                      checked: usage.colorfulUsageMeters
                      foreground: root.foreground
                      accent: Color.accent
                      onToggled: usage.setColorfulUsageMeters(!usage.colorfulUsageMeters)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Color-code meters"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  // Notifications are opt-in and fire once at each threshold,
                  // not on every refresh. Test remains independent of the
                  // toggle and reports its process result beside the button.
                  Row {
                    width: preferenceGrid.cellWidth
                    spacing: Style.space(6)

                    ToggleSwitch {
                      anchors.verticalCenter: parent.verticalCenter
                      checked: usage.notificationsEnabled
                      foreground: root.foreground
                      accent: Color.accent
                      onToggled: usage.setNotificationsEnabled(!usage.notificationsEnabled)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Threshold alerts"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Test"
                      tooltipText: "Send one notification now — independent of the notification toggle."
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      verticalPadding: Style.space(4)
                      onClicked: root.sendTestNotification()
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.notificationTestStatus
                      color: text === "Failed" ? root.urgent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: "Available mode switches percentages, meters, and warning values together. Meter colors are optional; alerts remain opt-in."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }

            // ----- Multi-device sync -----
            // The panel never syncs anything itself — it only reads and
            // writes one JSON snapshot per machine into this folder. Combine
            // usage across machines by pointing every one of them at the
            // same folder that's already kept identical some other way
            // (Syncthing, Nextcloud, a network mount — anything works).
            BorderSurface {
              id: syncSection
              width: parent.width
              implicitHeight: syncContent.implicitHeight + Style.space(28)
              color: root.alpha(root.foreground, 0.035)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
              radius: Style.cornerRadius

              Column {
                id: syncContent
                anchors.fill: parent
                anchors.margins: Style.space(14)
                spacing: Style.space(10)

                // Same draft pattern as behaviourContent above: the folder
                // path only ever changes here or on Save, so a keystroke in
                // progress can't be clobbered by a periodic settings reload.
                property string draftSyncDir: usage.syncDir
                readonly property bool syncDirDirty: draftSyncDir !== usage.syncDir

                function resyncDraft() { draftSyncDir = usage.syncDir }
                function saveDraft() { usage.setSyncDir(draftSyncDir) }

                Connections {
                  target: settingsSection
                  function onVisibleChanged() { if (settingsSection.visible) syncContent.resyncDraft() }
                }

                Text {
                  text: "Multi-device sync"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width
                  text: "Combine today's tokens and history from every machine that shares this folder. Point each machine at the same already-synced folder (Syncthing, Nextcloud, a network mount — any tool that keeps a directory identical everywhere); this panel only reads and writes its own snapshot inside it, never the syncing itself."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Row {
                  spacing: Style.space(10)

                  ToggleSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: usage.syncEnabled
                    foreground: root.foreground
                    accent: Color.accent
                    onToggled: usage.setSyncEnabled(!usage.syncEnabled)
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Enable sync"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Row {
                  visible: usage.syncEnabled
                  spacing: Style.space(10)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(320)
                    height: Style.space(30)
                    radius: Style.cornerRadius
                    color: root.alpha(root.foreground, 0.06)
                    border.width: 1
                    border.color: root.alpha(root.foreground, syncDirInput.activeFocus ? 0.4 : 0.2)

                    TextInput {
                      id: syncDirInput
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      verticalAlignment: TextInput.AlignVCenter
                      clip: true
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      text: syncContent.draftSyncDir
                      onTextEdited: syncContent.draftSyncDir = text
                      onAccepted: syncContent.saveDraft()

                      Text {
                        visible: syncDirInput.text === "" && !syncDirInput.activeFocus
                        anchors.verticalCenter: parent.verticalCenter
                        text: "~/Sync/agent-usage-plus"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }

                  Button {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Save"
                    enabled: syncContent.syncDirDirty
                    selected: enabled
                    bordered: true
                    foreground: root.foreground
                    accent: Color.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(12)
                    verticalPadding: Style.space(4)
                    onClicked: syncContent.saveDraft()
                  }
                }

                Text {
                  visible: usage.syncEnabled
                  width: parent.width
                  text: String(usage.syncDir || "").trim() === ""
                    ? "Set a folder above, then Save, to start writing this device's snapshot into it."
                    : (usage.syncStatusText !== "" ? usage.syncStatusText
                      : (usage.aggregateData && usage.aggregateData.deviceCount > 1
                        ? "Merged from " + usage.aggregateData.deviceCount + " devices"
                        : "Waiting for another device to write into this folder…"))
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property string severity: window ? root.severityForPercent(window.percent) : "ok"
    // Only providers that report an explicit quota get this. A percentage
    // meter alone cannot be turned into a token burn projection honestly.
    readonly property var paceProjection: Pace.projectExhaustion(
      root.provider ? root.provider.recentDays : [], window, window ? window.resetAt : "", root.nowMs)

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        text: limitRow.window && limitRow.window.percent >= 0
          ? Format.formatPercent(limitRow.window.percent, usage.showAvailablePercentage)
          : "n/a"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window && limitRow.window.percent >= 0
        ? root.displayPercent(limitRow.window.percent) : -1
      severity: limitRow.severity
    }

    Text {
      id: resetText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: !!limitRow.paceProjection && limitRow.paceProjection.exhaustsBeforeReset
      width: parent.width
      text: (limitRow.paceProjection && limitRow.paceProjection.exhaustsBeforeReset)
        ? "At this pace: exhausted in " + root.formatDuration(limitRow.paceProjection.untilExhaustionMs) : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property string severity: "ok"
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: root.colorForSeverity(meter.severity)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      text: modelRow.row ? modelRow.row.name : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
