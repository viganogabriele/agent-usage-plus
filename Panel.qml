import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "logic/thresholds.js" as Thresholds
import "logic/format.js" as Format
import "logic/aggregate.js" as Aggregate
import "logic/history.js" as History
import "logic/agents.js" as Agents
import "logic/accounts.js" as Accounts
import "logic/pace.js" as Pace
import "logic/cost-analytics.js" as CostAnalytics
import "logic/notifications.js" as Notify
import "logic/meter-colors.js" as MeterColors
import "logic/insights.js" as Insights
import "logic/contrast.js" as Contrast

Panel {
  id: root
  moduleName: "io.github.viganogabriele.agent-usage-plus"
  ipcTarget: "io.github.viganogabriele.agent-usage-plus"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  // The stable traffic-light colors are opt-in. With the option off, healthy
  // meters retain the live foreground and Critical retains Omarchy's urgent
  // color, preserving the widget's original theme contract.
  readonly property color healthy: "#22C55E"
  readonly property color colorfulCritical: "#EF4444"
  // A fixed amber rather than a foreground/urgent blend: warn needs to read
  // as its own distinct traffic-light color at a glance, not a paler shade
  // of critical that's easy to mistake for it against a dim theme.
  readonly property color warn: "#F2B705"
  // The panel's own softness, independent of Hyprland's window rounding:
  // with sharp windows (rounding 0) every card and control read as hard
  // boxes. The shell's card frame itself still follows the theme.
  readonly property real cardRadius: Math.max(Style.cornerRadius, Style.space(12))
  readonly property real controlRadius: Math.max(Style.cornerRadius, Style.space(8))
  readonly property color surface: Commons.Color.popups.background
  // Secondary panel text. A fixed Qt.darker(foreground) fell below a 4.5:1
  // contrast on several dark themes (Everforest, Gruvbox, Tokyo Night, Nord)
  // and, on light themes, came out *darker* than the primary text so it read
  // as emphasis. Blending toward the surface keeps it visibly secondary in
  // both modes; readableOn() then guarantees it stays legible.
  readonly property color dim: readableOn(mix(foreground, surface, 0.38), surface, 4.5)
  // The bar keeps its original secondary color (only the rare "+N" overflow
  // uses it), so the bar renders exactly as before.
  readonly property color barDim: Qt.darker(foreground, 1.55)
  // Text versions of the state colors. Meters and fills keep the exact
  // theme/amber colors; only text is nudged when a theme puts it below 4.5:1
  // (the fixed amber is ~1.7:1 on every light theme).
  readonly property color warnText: readableOn(warn, surface, 4.5)
  readonly property color accentText: readableOn(Commons.Color.accent, surface, 4.5)
  readonly property color track: Style.selectedFillFor(foreground, Commons.Color.accent)
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
  readonly property string accountBrand: provider ? (provider.brand || provider.providerId) : ""
  readonly property var accountRows: providers.filter(function(p) {
    return (p.brand || p.providerId) === root.accountBrand
  })
  function accountRecordExists(id) {
    var revision = usage.dataRevision
    var agents = usage.agents || []
    for (var i = 0; i < agents.length; i++)
      if (agents[i] && agents[i].record && agents[i].record.id === id) return true
    return false
  }

  property bool cursorActive: false

  // Each opening uses the saved preference; tab switches are session-only.
  //
  // Under the overview the panel shows one view at a time — Usage, Activity,
  // Models or Cost — instead of one long scroll where nothing said which
  // card belonged to what. `expanded` means "a detail view is showing" and
  // gates the heavier derived data. Settings replaces the views entirely.
  readonly property var viewTabs: [
    { id: "usage", label: "Usage", glyph: "󰓅" },
    { id: "activity", label: "Activity", glyph: "󰸘" },
    { id: "models", label: "Models", glyph: "󰘚" },
    { id: "cost", label: "Cost", glyph: "󰄔" }
  ]
  property string viewTab: "usage"
  readonly property bool expanded: viewTab !== "usage" && !settingsOpen
  property bool settingsOpen: false
  // `e` steps through the views (and leaves Settings).
  function toggleExpanded() {
    root.settingsOpen = false
    var ids = root.viewTabs.map(function(t) { return t.id })
    root.viewTab = ids[(ids.indexOf(root.viewTab) + 1) % ids.length]
  }
  function toggleSettings() {
    root.settingsOpen = !root.settingsOpen
  }

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  readonly property var limits: limitWindows(provider)
  // Windows the overview does not already draw as a ring (a model-scoped
  // weekly, a credits window): the Usage view lists only these.
  readonly property var otherLimits: limits.filter(function(w) {
    for (var i = 0; i < root.ringWindows.length; i++) {
      var ring = root.ringWindows[i]
      if (ring.title === w.title && ring.resetAt === w.resetAt && ring.percent === w.percent) return false
    }
    return true
  })
  readonly property var detailModels: expanded ? modelUsageRows(provider) : []
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

  // The trend covers every day retained by the collector, including day 31.
  readonly property var historySeries: expanded && provider && Array.isArray(provider.recentDays) && provider.recentDays.length
    ? History.buildHistorySeries(provider.recentDays, provider.recentDays.length) : null

  function historySeriesTotal(series) {
    if (!series || !series.points) return 0
    var total = 0
    for (var i = 0; i < series.points.length; i++) total += Number(series.points[i].value || 0)
    return total
  }

  // ---------------------------------------------------------- settings UI

  // Session-only, like `expanded`: which Settings tab is showing.
  property string settingsTab: "providers"

  function providerById(id) {
    for (var i = 0; i < root.providers.length; i++)
      if (root.providers[i].providerId === id) return root.providers[i]
    return null
  }

  // One line under a provider's name in Settings: its problem if it has
  // one, otherwise its plan and where it sits in the bar.
  function providerSettingsSummary(row, live) {
    if (!row) return ""
    if (!row.enabled) return "Off · not collected"
    if (live && String(live.usageStatusText || "") !== "") return String(live.usageStatusText)
    var brand = row.brand || row.providerId
    var inactive = (brand === "claude" || brand === "codex") && usage.activeAccountId(brand) !== row.providerId
    // Short enough to sit beside the bar preview without being cut.
    var place = inactive ? "Not the active account"
      : (row.barRole === "fixed" ? "In the bar"
        : (row.barRole === "cycle" ? "Rotating" : "Panel only"))
    var plan = live && String(live.tierLabel || "") !== "" ? String(live.tierLabel) + " · " : ""
    return plan + place
  }

  function formatSeconds(seconds) {
    var n = Math.max(0, Math.round(Number(seconds) || 0))
    if (n < 60) return n + "s"
    if (n % 60 === 0) return (n / 60) + " min"
    return Math.floor(n / 60) + "m " + (n % 60) + "s"
  }

  // ---------------------------------------------------------- insights
  //
  // Derived, read-only views over data the selected provider already
  // reported (logic/insights.js): how each limit window is pacing against
  // its own clock, and what the daily token history says. Nothing here
  // triggers a collector run.
  readonly property var activity: provider ? Insights.activityStats(provider.recentDays || [], todayDate()) : null
  readonly property bool hasActivity: !!activity && activity.recordedDays > 0 && !!provider
    && provider.hasLocalStats !== false
  readonly property var heatmap: (expanded && provider)
    ? Insights.heatmapGrid(provider.recentDays || [], todayDate(), 5) : null
  readonly property var tokenMixData: (expanded && provider) ? Insights.tokenMix(provider.modelUsage || {}) : null
  // When the selected record's percentages were read; pace is measured at
  // that instant rather than at the panel's clock.
  // updatedAt is optional in the collector contract: absent means "now";
  // present but unparseable withholds pace rather than guessing its age.
  readonly property var measuredAtMs: provider && String(provider.updatedAt || "") !== ""
    ? Date.parse(String(provider.updatedAt)) : undefined

  function paceFor(window) {
    return window ? Insights.windowPace(window, root.nowMs, root.measuredAtMs) : null
  }

  // What the overview card talks about. A full window has already stopped
  // you; otherwise the window that empties first at its own rate beats the
  // merely fullest one (a fast Session can run out long before a fuller,
  // slower Weekly); otherwise the fullest current window. A prepaid balance
  // takes over when its own state is worse.
  readonly property var overviewWindow: {
    var fullest = currentBindingWindow(provider)
    if (!fullest) return null
    if (fullest.percent >= 1 || windowIsStale(fullest)) return fullest
    var racing = Insights.firstRunOut(limitWindows(provider).filter(function(w) { return !root.windowIsStale(w) }),
      root.nowMs, root.measuredAtMs)
    return racing ? racing.window : fullest
  }
  readonly property var headlinePace: overviewWindow ? paceFor(overviewWindow) : null
  readonly property string overviewSeverity: overviewWindow ? severityForPercent(overviewWindow.percent) : "ok"
  readonly property bool overviewShowsBalance: !!balance && balance.funded > 0
    && (!overviewWindow || windowIsStale(overviewWindow) || Thresholds.worstSeverity(overviewSeverity, balanceSeverity) !== overviewSeverity)

  // One short phrase per window. A run-out that lands before the reset is
  // the only case that earns the warning color; "ahead of pace" alone is
  // information, not an alarm.
  function paceText(pace) {
    if (!pace) return ""
    if (pace.used >= 1) return "Limit reached"
    if (pace.runsOutInMs >= 0) return "Out in " + root.formatDuration(pace.runsOutInMs) + " at this rate"
    if (pace.status === "idle") return "Unused this window"
    var points = Math.round(Math.abs(pace.delta) * 100)
    if (pace.status === "on") return "On pace"
    if (pace.status === "over") return points + "% ahead of pace"
    return points + "% under pace"
  }

  // Keep the ring's value and color tied to the same current allowance.
  function chipMeter(p) {
    var w = currentBindingWindow(p)
    var hasWindow = w && !windowIsStale(w)
    var credit = p ? p.balance : null
    if (credit && credit.funded > 0) {
      var remaining = clamp(credit.remaining / credit.funded, 0, 1)
      var creditSeverity = severityForPercent(1 - remaining)
      if (!hasWindow || Thresholds.worstSeverity(severityForPercent(w.percent), creditSeverity) !== severityForPercent(w.percent))
        return { value: remaining, severity: creditSeverity }
    }
    return hasWindow ? { value: displayPercent(w.percent), severity: severityForPercent(w.percent) } : null
  }

  function withoutRunOut(pace) {
    if (!pace || pace.runsOutInMs < 0 || pace.used >= 1) return pace
    var copy = {}
    for (var key in pace) copy[key] = pace[key]
    copy.runsOutInMs = -1
    return copy
  }

  function paceColor(pace) {
    if (!pace) return root.dim
    if (pace.used >= 1) return root.textFor(root.urgent)
    if (pace.runsOutInMs >= 0) return root.warnText
    return root.dim
  }

  // The headline verdict for the gauge card: one plain sentence a person can
  // act on, picked from the fullest window's own severity and pace.
  readonly property var verdict: {
    if (root.overviewShowsBalance) {
      if (root.balanceSeverity === "critical") return { title: "Credit running low", color: root.textFor(root.colorForSeverity("critical")) }
      if (root.balanceSeverity === "warn") return { title: "Credit getting low", color: root.warnText }
      return { title: "Credit healthy", color: root.foreground }
    }
    var w = root.overviewWindow
    if (!w) return null
    var pace = root.headlinePace
    if (root.windowIsStale(w)) return { title: "Window has reset", color: root.foreground }
    if (w.percent >= 1) return { title: "Limit reached", color: root.textFor(root.urgent) }
    if (root.overviewSeverity === "critical") return { title: "Almost out", color: root.textFor(root.colorForSeverity("critical")) }
    if (pace && pace.runsOutInMs >= 0) return { title: "Running hot", color: root.warnText }
    if (root.overviewSeverity === "warn") return { title: "Getting close", color: root.warnText }
    if (pace && pace.status === "over") return { title: "Ahead of pace", color: root.foreground }
    if (pace && pace.status === "on") return { title: "On pace", color: root.foreground }
    return { title: "Plenty of room", color: root.foreground }
  }

  readonly property string verdictDetail: {
    if (root.overviewShowsBalance) {
      return root.formatMoney(root.balance.remaining, root.balance.currency) + " of "
        + root.formatMoney(root.balance.funded, root.balance.currency) + " left"
    }
    var w = root.overviewWindow
    if (!w) return ""
    var title = String(w.title || "Limit")
    if (root.windowIsStale(w)) return title + " last read " + Format.formatPercent(w.percent, usage.showAvailablePercentage) + " · updates on the next refresh"
    var pace = root.headlinePace
    var resetMs = root.resetMsFor(w)
    var resetText = resetMs > 0 ? root.formatDuration(resetMs) : ""
    if (w.percent >= 1)
      return title + " is full" + (resetText ? " · back in " + resetText + " (" + root.resetClock(w) + ")" : "")
    if (pace && pace.runsOutInMs >= 0 && resetMs > 0)
      return title + " runs out in " + root.formatDuration(pace.runsOutInMs) + ", "
        + root.formatDuration(Math.max(0, resetMs - pace.runsOutInMs)) + " before it resets"
    // Nothing urgent: the most useful fact is when room comes back next.
    var next = root.nextReset
    return next ? "Next reset: " + String(next.title || "Limit") + " in " + root.formatDuration(root.resetMsFor(next))
      + " (" + root.resetClock(next) + ")" : ""
  }

  // The windows the overview draws as rings: Session and Weekly when the
  // account has both (the pair coding plans are judged by), otherwise up to
  // the two fullest current windows, soonest reset first.
  readonly property var ringWindows: {
    var all = limitWindows(provider)
    var current = all.filter(function(w) { return !root.windowIsStale(w) })
    var pool = current.length > 0 ? current : all
    var session = null
    var weekly = null
    for (var i = 0; i < pool.length; i++) {
      if (!session && pool[i].title === "Session") session = pool[i]
      if (!weekly && pool[i].title === "Weekly") weekly = pool[i]
    }
    var picked = session && weekly ? [session, weekly]
      : pool.slice().sort(function(a, b) { return b.percent - a.percent }).slice(0, 2)
    return picked.sort(function(a, b) {
      var ra = root.resetMsFor(a), rb = root.resetMsFor(b)
      return (ra < 0 ? Infinity : ra) - (rb < 0 ? Infinity : rb)
    })
  }

  // The current window that hands room back soonest.
  readonly property var nextReset: {
    var best = null
    var windows = limitWindows(provider)
    for (var i = 0; i < windows.length; i++) {
      var ms = resetMsFor(windows[i])
      if (ms > 0 && (!best || ms < resetMsFor(best))) best = windows[i]
    }
    return best
  }

  // The reset as a wall-clock moment, in the locale's own time format:
  // "today 18:40", "tomorrow 09:00", "Fri 09:00", or a date further out.
  function resetClock(w) {
    var ms = w ? Date.parse(String(w.resetAt || "")) : NaN
    var parts = momentParts(ms)
    return parts.day === "" ? "" : parts.day + " " + parts.clock
  }

  // A moment split into its day ("today", "tomorrow", "Fri", "Wed 2 Dec")
  // and its clock time in the locale's own short format, minus seconds.
  function momentParts(ms) {
    if (!isFinite(ms)) return { day: "", clock: "" }
    var at = new Date(ms)
    var now = new Date(root.nowMs)
    var format = String(Qt.locale().timeFormat(Locale.ShortFormat)).replace(/[:.]ss/, "").replace(/\s*t$/, "")
    var clock = Qt.formatTime(at, format)
    var startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var dayOffset = Math.floor((new Date(at.getFullYear(), at.getMonth(), at.getDate()).getTime() - startOfToday) / 86400000 + 0.5)
    var day = dayOffset <= 0 ? "today" : (dayOffset === 1 ? "tomorrow"
      : (dayOffset < 7 ? Qt.locale().dayName(at.getDay(), Locale.ShortFormat)
        : Qt.locale().dayName(at.getDay(), Locale.ShortFormat) + " " + at.getDate() + " "
          + Qt.locale().monthName(at.getMonth(), Locale.ShortFormat)))
    return { day: day, clock: clock }
  }

  // Where a granted free reset is redeemed; the panel only reports them.
  function redeemHint(p) {
    var id = p ? String(p.providerId || "") : ""
    if (id === "codex") return "Redeem with /usage in Codex"
    if (id === "claude") return "Redeem in claude.ai Settings › Usage"
    return ""
  }

  // A ring is drawn in the theme accent while it has room; only the
  // Warn and Critical thresholds change its color (and the opt-in
  // traffic-light palette keeps its green), so a color always means the
  // same thing everywhere in the panel.
  function ringTint(w) {
    var severity = w ? severityForPercent(w.percent) : "ok"
    if (severity !== "ok" || usage.colorfulUsageMeters) return colorForSeverity(severity)
    return Commons.Color.accent
  }

  // Series in a chart are tonal steps of the theme accent rather than new
  // hues, so no series ever reads as a warning color.
  function seriesColor(index) {
    var steps = [1, 0.72, 0.5, 0.34, 0.22]
    return root.alpha(Commons.Color.accent, steps[Math.max(0, index) % steps.length])
  }

  // Cards under the tabs fade in on a view change instead of popping.
  property real viewFade: 1
  NumberAnimation {
    id: viewFadeIn
    target: root
    property: "viewFade"
    from: 0.25
    to: 1
    duration: 220
    easing.type: Easing.OutCubic
  }
  onViewTabChanged: viewFadeIn.restart()

  // "Updated 4m ago" from the collector's own timestamp; blank when the
  // record does not carry one, rather than implying it is live.
  function updatedAgoText(p) {
    var ms = p ? Date.parse(String(p.updatedAt || "")) : NaN
    if (!isFinite(ms)) return ""
    var age = root.nowMs - ms
    if (age < -60000) return ""
    if (age < 60000) return "Updated just now"
    return "Updated " + root.formatDuration(age) + " ago"
  }

  // Opaque blends (not alpha) so the day number drawn on a cell can pick
  // its own readable ink with inkOn().
  function heatColor(level) {
    if (level <= 0) return root.mix(root.surface, root.foreground, 0.07)
    return root.mix(root.surface, Commons.Color.accent, [0, 0.3, 0.52, 0.76, 1][Math.max(0, Math.min(4, level))])
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

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function mix(a, b, t) {
    var k = clamp(Number(t) || 0, 0, 1)
    return Qt.rgba(a.r * (1 - k) + b.r * k, a.g * (1 - k) + b.g * k, a.b * (1 - k) + b.b * k, 1)
  }

  function contrastRatio(a, b) {
    return Contrast.contrastRatio(a, b)
  }

  // The same hue, pushed toward black (light surface) or white (dark
  // surface) only as far as it takes to reach `minRatio` against `bg`.
  function readableOn(c, bg, minRatio) {
    var target = Number(minRatio) || 4.5
    if (contrastRatio(c, bg) >= target) return c
    var extreme = Contrast.isLight(bg) ? Qt.rgba(0, 0, 0, 1) : Qt.rgba(1, 1, 1, 1)
    for (var step = 1; step <= 10; step++) {
      var candidate = mix(c, extreme, step / 10)
      if (contrastRatio(candidate, bg) >= target) return candidate
    }
    return extreme
  }

  function textFor(c) { return readableOn(c, root.surface, 4.5) }

  // Foreground or surface, whichever reads better on an opaque fill.
  function inkOn(fill) {
    return contrastRatio(root.foreground, fill) >= contrastRatio(root.surface, fill)
      ? root.foreground : root.surface
  }

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
    if (!root.opened || root.settingsOpen || !providerChipRepeater || !providerSwitch || !panelFlick || !column)
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

  // Set by a refresh the person asked for (button, r, Enter) and cleared
  // when that run ends. Background runs — the one every opening starts,
  // the refresh timer — stay silent, so the panel never looks permanently
  // busy while a slow collector works.
  property bool manualRefresh: false
  function refreshNow() {
    root.manualRefresh = true
    usage.refreshAll(true)
  }
  Connections {
    target: usage
    function onUpdatingChanged() { if (!usage.updating) root.manualRefresh = false }
  }

  // Right-click launches the agent of the mark that was clicked. Passing no
  // id (the whole-slot button, the overflow button) keeps the old behavior:
  // omarchy-agent reads ~/.config/omarchy/defaults/agent, which is the only
  // sensible answer when the click doesn't name a provider.
  function launchAgent(providerId) {
    var profile = usage.accountProfiles[providerId]
    var command = profile
      ? Accounts.commandForProfile(providerId, profile.provider, usage.accountDataRoot, false, profile.path, usage.home) : ""
    if (root.bar) root.bar.run(command
      ? Agents.WORKDIR_GUARD + Agents.LAUNCH_PREFIX + " " + command
      : Agents.launchCommandFor(providerId))
    root.close()
  }

  function loginToAccount(accountId) {
    var profile = usage.accountProfiles[accountId]
    if (!profile || !root.bar) return
    var command = Accounts.commandForProfile(accountId, profile.provider, usage.accountDataRoot, true, profile.path, usage.home)
    if (command) root.bar.run(Agents.WORKDIR_GUARD + Agents.LAUNCH_PREFIX + " " + command)
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
      label: String(label || ""),
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      // Pace only trusts a window length the collector stated; a title read
      // back out of a free-text label is not one (see logic/insights.js).
      titleExplicit: String(title || "") !== "",
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
  // that is what stops the next prompt. (The bar's alarm state reads this;
  // keep it exactly as it was.)
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  // Panel-only variant: a window whose reset time has already passed is a
  // leftover reading until the collector runs again, so it only wins when
  // nothing current is left.
  function currentBindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    var stale = null
    for (var i = 0; i < windows.length; i++) {
      if (windowIsStale(windows[i])) {
        if (!stale || windows[i].percent > stale.percent) stale = windows[i]
      } else if (!best || windows[i].percent > best.percent) {
        best = windows[i]
      }
    }
    return best || stale
  }

  function windowIsStale(w) {
    if (!w || w.resetAt === "") return false
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) && ms <= root.nowMs
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

  // Axis ticks only need magnitude, and a fixed-width gutter cannot fit
  // cents on a three-digit day: "$216" instead of an elided "$216.…".
  function axisUsd(value) {
    var n = Number(value)
    if (!isFinite(n) || n <= 0) return "$0"
    if (n >= 1000) return "$" + (n / 1000).toFixed(1) + "k"
    if (n >= 10) return "$" + Math.round(n)
    return "$" + n.toFixed(2)
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

  function shortHistoryDate(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return (parsed.getMonth() + 1) + "/" + parsed.getDate()
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

  function modelUsageRows(p) {
    var usageByModel = p ? p.modelUsage || {} : {}
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
    return rows.slice(0, 12)
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
    devin: { defaultAsset: "devin.svg", lightAsset: "devin-light.svg" },
    agy: { defaultAsset: "agy.svg", lightAsset: "agy-light.svg" },
    opencode: { defaultAsset: "opencode-go.svg", lightAsset: "opencode-go-light.svg" },
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
    if (Contrast.isLight(surfaceColor || Commons.Color.background) && assets.lightAsset)
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
    // Dark ink (the -light twin) only when the bar's own text is dark. The
    // old 0.5 luminance cutoff filed mid-tone light text such as Tokyo
    // Night's #a9b1d6 as dark and drew a near-black mark on a dark bar.
    if (!Contrast.isLight(liveForeground) && assets.lightAsset)
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

  // How far a bar click target has to bleed above and below its own content
  // to cover the full height of the slot: caption-sized text leaves a few
  // pixels of bar on each side that are visibly part of the widget and have
  // to click like it.
  function barBleedVertical(itemHeight) {
    return Math.max(0, (root.height - itemHeight) / 2)
  }

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
    viewTab = usage.openInDetailedView ? "activity" : "usage"
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

  // Draft copies of the numeric settings, committed only from the save bar.
  // Binding a field's `value` straight to a setting meant every settings
  // write (even to an unrelated field, or the periodic refresh reloading
  // `settings` wholesale) could reassert a stale number over whatever the
  // person was still typing. Drafts only change from resyncDrafts() (on
  // opening settings, or Discard) or the fields' own onModified.
  QtObject {
    id: settingsDraft

    property int cycleSlots: usage.barCycleSlots
    property int cycleIntervalSec: usage.barCycleIntervalSec
    property int refreshIntervalSec: usage.refreshIntervalSec
    property int warnThresholdPct: root.displayWarnThresholdPct
    property int criticalThresholdPct: root.displayCriticalThresholdPct
    property bool showsAvailable: usage.showAvailablePercentage

    readonly property bool rotationDirty: cycleSlots !== usage.barCycleSlots
      || cycleIntervalSec !== usage.barCycleIntervalSec
    readonly property bool refreshDirty: refreshIntervalSec !== usage.refreshIntervalSec
    readonly property bool thresholdsDirty: warnThresholdPct !== root.displayWarnThresholdPct
      || criticalThresholdPct !== root.displayCriticalThresholdPct
    readonly property bool dirty: rotationDirty || refreshDirty || thresholdsDirty

    // In used terms Warn must be below Critical; complementing both values
    // reverses that ordering in available terms. Catch either invalid form
    // before Save, where the person editing the number can see why.
    readonly property bool thresholdsValid: showsAvailable
      ? warnThresholdPct > criticalThresholdPct
      : warnThresholdPct < criticalThresholdPct

    function resyncDrafts() {
      cycleSlots = usage.barCycleSlots
      cycleIntervalSec = usage.barCycleIntervalSec
      refreshIntervalSec = usage.refreshIntervalSec
      warnThresholdPct = root.displayWarnThresholdPct
      criticalThresholdPct = root.displayCriticalThresholdPct
      showsAvailable = usage.showAvailablePercentage
    }

    // Preserve every in-progress draft when the presentation mode changes.
    // Only complement the two threshold fields in place; resyncDrafts()
    // would discard unrelated edits.
    function syncPercentageMode() {
      if (showsAvailable === usage.showAvailablePercentage) return
      warnThresholdPct = 100 - warnThresholdPct
      criticalThresholdPct = 100 - criticalThresholdPct
      showsAvailable = usage.showAvailablePercentage
    }

    // Writes only the groups that changed, so saving a new refresh interval
    // does not rewrite five unrelated keys through `omarchy bar set`.
    function saveDrafts() {
      if (rotationDirty) {
        usage.setBarCycleSlots(cycleSlots)
        usage.setBarCycleIntervalSec(cycleIntervalSec)
      }
      if (refreshDirty) usage.setRefreshIntervalSec(refreshIntervalSec)
      if (thresholdsDirty && thresholdsValid) {
        usage.setWarnThresholdPct(showsAvailable ? 100 - warnThresholdPct : warnThresholdPct)
        usage.setCriticalThresholdPct(showsAvailable ? 100 - criticalThresholdPct : criticalThresholdPct)
      }
    }
  }

  Connections {
    target: usage
    function onShowAvailablePercentageChanged() { settingsDraft.syncPercentageMode() }
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
    function importCodexPaths(paths: string): string {
      usage.importAccounts("codex", paths)
      return "queued"
    }
    function accountStatus(): string {
      return JSON.stringify({ profiles: usage.accountProfiles, status: usage.accountImportStatus })
    }
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
      var line = String(w.title || w.label || "Limit") + " " + Format.formatPercent(w.percent, usage.showAvailablePercentage)
        + (usage.showAvailablePercentage ? " available" : " used")
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

  // A compact value chip: a bold figure with its unit beside it and a line
  // of context underneath.
  component CostChip: Rectangle {
    id: costChip
    property string valueText: ""
    property string label: ""
    property string hint: ""

    implicitHeight: costChipColumn.implicitHeight + Style.space(16)
    height: implicitHeight
    radius: root.controlRadius
    color: root.alpha(Commons.Color.accent, 0.08)
    border.width: 1
    border.color: root.alpha(Commons.Color.accent, 0.20)

    Column {
      id: costChipColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      Row {
        spacing: Style.space(5)

        Text {
          anchors.baseline: costChipLabel.baseline
          text: costChip.valueText
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          id: costChipLabel
          text: costChip.label
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        visible: costChip.hint !== ""
        width: parent.width
        text: costChip.hint
        textFormat: Text.PlainText
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

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
      color: Commons.Color.accent
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
        required property int index
        implicitWidth: groupContent.implicitWidth
        implicitHeight: groupContent.implicitHeight

        // A group is only as wide and as tall as the mark and percentage it
        // draws, but the strip it sits in is neither: the row's spacing
        // between groups, the module's outerPadding at either end, and the
        // bar height above and below caption-sized text all fell through to
        // the whole-slot button. Its right-click has no provider to name, so
        // it runs the picker — which, once a default agent is set, silently
        // starts *that* agent. Right-clicking a few pixels off the Claude
        // mark therefore opened Codex: exactly the confusion the table in
        // logic/agents.js exists to remove, reintroduced by the fallback.
        // Bleeding each target into half the gap (and, at the row's ends,
        // into the outer padding) makes neighboring targets meet midway with
        // nothing dead between them. Nothing in the chain clips, so the
        // out-of-bounds area still takes clicks, and the bleed stays inside
        // the module, so no neighboring bar module loses one.
        readonly property real bleedStart: providersRow.spacing / 2
          + (index === 0 ? root.outerPadding : 0)
        readonly property real bleedEnd: providersRow.spacing / 2
          + (index === providersRepeater.count - 1 && root.hiddenBarProviderCount === 0
            ? root.outerPadding : 0)

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
          anchors.leftMargin: -providerGroup.bleedStart
          anchors.rightMargin: -providerGroup.bleedEnd
          anchors.topMargin: -root.barBleedVertical(providerGroup.height)
          anchors.bottomMargin: -root.barBleedVertical(providerGroup.height)
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
      id: overflowGroup
      visible: root.hiddenBarProviderCount > 0
      implicitWidth: overflowText.implicitWidth
      implicitHeight: overflowText.implicitHeight

      Text {
        id: overflowText
        anchors.verticalCenter: parent.verticalCenter
        text: "+" + root.hiddenBarProviderCount
        color: root.barDim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // This needs its own registered target just like a meter group. The
      // outer WidgetButton is visually behind the row and is not guaranteed
      // to receive a hit through every bar implementation. It bleeds like a
      // meter group too, so the row's last gap and the trailing padding do
      // not become another dead strip.
      WidgetButton {
        anchors.fill: parent
        anchors.leftMargin: -providersRow.spacing / 2
        anchors.rightMargin: -root.outerPadding
        anchors.topMargin: -root.barBleedVertical(overflowGroup.height)
        anchors.bottomMargin: -root.barBleedVertical(overflowGroup.height)
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
    // One width for every view: Settings used to jump to twice the width,
    // which moved the card under the pointer.
    contentWidth: panel.fittedContentWidth(Style.space(440))
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
      blocked: root.settingsOpen && (accountPathsInput.activeFocus || accountNameInput.activeFocus || syncDirInput.activeFocus)

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
        if (!root.settingsOpen && (t === "r" || t === "R")) root.refreshNow()
        else if (t === "e" || t === "E") root.toggleExpanded()
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
          spacing: Style.space(14)

          // ---------- Hero: provider mark · name · plan · actions ----------
          // Always present: it holds the Settings gear, which must stay
          // reachable even when every provider has been turned off.
          Item {
            id: hero
            width: parent.width
            implicitHeight: Math.max(heroTile.height, heroText.implicitHeight, heroActions.implicitHeight)

            Rectangle {
              id: heroTile
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(46)
              height: width
              radius: root.cardRadius
              color: root.alpha(Commons.Color.accent, 0.10)
              border.width: 1
              border.color: root.alpha(Commons.Color.accent, 0.28)

              Text {
                anchors.centerIn: parent
                visible: root.settingsOpen
                text: "󰢻"
                color: root.accentText
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.display * 0.95)
              }

              Item {
                id: heroMark
                visible: !root.settingsOpen
                anchors.centerIn: parent
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

                width: Style.space(28)
                height: width

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

            Column {
              id: heroText
              anchors.left: heroTile.right
              anchors.leftMargin: Style.space(12)
              anchors.right: heroActions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(5)

              Text {
                width: parent.width
                text: root.settingsOpen ? "Settings" : (root.provider ? root.provider.providerName : "Agent Usage Plus")
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.subtitle * 1.25)
                font.bold: true
                elide: Text.ElideRight
              }

              Row {
                spacing: Style.space(8)
                width: parent.width

                Rectangle {
                  id: planPill
                  visible: !root.settingsOpen && !!root.provider
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(planPillText.implicitWidth + Style.space(12), parent.width * 0.62)
                  height: planPillText.implicitHeight + Style.space(4)
                  radius: height / 2
                  color: root.alpha(Commons.Color.accent, 0.14)

                  Text {
                    id: planPillText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, planPill.width - Style.space(12))
                    elide: Text.ElideRight
                    text: root.heroMeta(root.provider)
                    textFormat: Text.PlainText
                    color: root.accentText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 0.6
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(0, parent.width - (planPill.visible ? planPill.width + parent.spacing : 0))
                  text: root.settingsOpen ? "Agent Usage Plus · saved to your bar config"
                    : (root.provider ? root.updatedAgoText(root.provider) : "AI coding usage")
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            // Three separate, labeled controls rather than one overloaded
            // toggle: refresh runs the collectors now, the gear opens the
            // settings form, the chevron reveals Details. Settings and
            // Details are mutually exclusive (see toggleExpanded/
            // toggleSettings) so one never stacks under the other.
            Row {
              id: heroActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Button {

                radius: root.controlRadius
                id: refreshAction
                visible: !root.settingsOpen
                width: Style.space(28)
                height: Style.space(28)
                horizontalPadding: 0
                verticalPadding: 0
                iconText: "󰑐"
                iconSize: Style.font.body
                // Spins only while a refresh you asked for runs (Button
                // honors Omarchy's reduced-motion setting on its own).
                iconSpinning: root.manualRefresh && usage.updating
                tooltipText: root.manualRefresh && usage.updating ? "Refreshing…" : "Refresh now (r)"
                bordered: true
                focusable: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.refreshNow()
              }

              PanelActionButton {

                radius: root.controlRadius
                iconText: root.settingsOpen ? "󰁍" : "󰒓"
                tooltipText: root.settingsOpen ? "Back to usage (s)" : "Settings (s)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                size: Style.space(28)
                fontSize: Style.font.body
                bordered: true
                focusable: true
                onClicked: root.toggleSettings()
              }
            }
          }

          Text {
            visible: root.providers.length === 0 && !root.settingsOpen
            width: parent.width
            topPadding: Style.space(24)
            text: !usage.initialDiscoveryComplete
              ? "Scanning AI coding subscriptions…"
              : (root.settingsProviders.length > 0
                ? (root.settingsProviders.some(function(row) { return row.enabled })
                  ? "Waiting for usage data. Refresh to check again."
                  : "Every provider is turned off.\nOpen Settings (gear, or s) to turn one back on.")
                : "No AI coding subscriptions found.\nAgents show up here once you've used them.")
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
            visible: !root.settingsOpen && root.providers.length > 1
            width: parent.width
            spacing: Style.space(6)
            readonly property real chipSize: Math.max(
              Style.space(36),
              Math.min(Style.space(44),
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
              // Indexed, so a refresh updates rows in place instead of
              // rebuilding them (rebuilt rows re-animated and re-laid out).
              model: (root.providers).length

              Button {

                radius: root.controlRadius
                id: providerChip
                readonly property var modelData: (root.providers)[index] || ({})
                required property int index

                width: providerSwitch.chipSize
                height: providerSwitch.chipSize
                // The reorder hint lives here, not as a line under the marks
                // that appeared on hover and resized the whole panel.
                tooltipText: String(modelData && (modelData.providerName || modelData.providerId) || "Provider")
                  + "\n" + root.providers.length + " providers · drag marks to reorder"
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
                  radius: root.controlRadius
                  border.width: 2
                  border.color: Commons.Color.accent
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
                    providerSwitch.updateDragTarget(activeTranslation.x, activeTranslation.y)
                    dragGhost.follow(activeTranslation.x, activeTranslation.y)
                  }
                }

                // Each chip carries its account's fullest meter as a ring, so
                // the switcher is also a glance at every subscription.
                ChipRing {
                  anchors.centerIn: parent
                  width: parent.width - Style.space(4)
                  height: width
                  readonly property var meter: root.chipMeter(providerChip.modelData)
                  visible: !!meter
                  value: meter ? meter.value : 0
                  color: root.colorForSeverity(meter ? meter.severity : "ok")
                }

                ProviderMark {
                  anchors.centerIn: parent
                  width: Math.min(parent.width - Style.space(16), Style.space(22))
                  height: width
                  provider: providerChip.modelData
                  opacity: providerChip.selected || providerChip.hasCursor ? 1.0 : 0.82
                }

                // A problem state (sign-in missing, endpoint down) gets a
                // small amber/red dot, so it is visible without selecting.
                Rectangle {
                  visible: String(providerChip.modelData && providerChip.modelData.usageStatusText || "") !== ""
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(2)
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: root.statusColor(providerChip.modelData)
                  border.width: 1
                  border.color: root.surface
                }

                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }


          // Floating copy of whichever mark is being dragged, parented at the
          // panel's top level (not inside providerSwitch's Grid) so it can
          // render above every sibling section regardless of where the
          // switcher sits. Keep the ghost in the popup window; the widget
          // root belongs to the separate, bar-height window.
          Item {
            id: dragGhost
            parent: keyCatcher
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
              var origin = source.mapToItem(keyCatcher, 0, 0)
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
              radius: root.cardRadius

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
                  color: root.textFor(root.statusColor(root.provider))
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

          // ---------- Overview: rings, resets, forecast ----------
          // What the bar cannot show: how full each window is, when it
          // resets (as large as the percentage it gives back), and whether
          // it will run out before that reset at the current rate.
          BorderSurface {
            id: overviewCard
            visible: !root.settingsOpen && !!root.provider && !!root.verdict
            width: parent.width
            implicitHeight: overviewContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(Commons.Color.accent, 0.22), 1)
            radius: root.cardRadius

            readonly property bool creditOnly: root.ringWindows.length === 0 && !!root.balance && root.balance.funded > 0
            readonly property int ringCount: creditOnly ? 1 : Math.min(2, root.ringWindows.length)

            Rectangle {
              anchors.fill: parent
              anchors.margins: 1
              radius: parent.radius
              gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0; color: root.alpha(Commons.Color.accent, 0.09) }
                GradientStop { position: 0.75; color: root.alpha(Commons.Color.accent, 0.0) }
              }
            }

            Column {
              id: overviewContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(14)

              // Fixed instances rather than a Repeater: a refresh rebinds
              // them in place, so the rings never re-fill from zero.
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(10)
                readonly property real tileWidth: overviewCard.ringCount === 2
                  ? (overviewContent.width - spacing) / 2 : Math.min(overviewContent.width, Style.space(220))

                RingTile {
                  width: parent.tileWidth
                  visible: overviewCard.ringCount >= 1
                  creditMode: overviewCard.creditOnly
                  window: !overviewCard.creditOnly && root.ringWindows.length > 0 ? root.ringWindows[0] : null
                  tint: root.ringTint(window)
                }

                RingTile {
                  width: parent.tileWidth
                  visible: overviewCard.ringCount === 2
                  window: root.ringWindows.length > 1 ? root.ringWindows[1] : null
                  tint: root.ringTint(window)
                }
              }

              // Free full resets the provider granted and you can still
              // redeem: worth knowing before a limit bites.
              Rectangle {
                id: freeResets
                readonly property var credits: root.provider ? root.provider.resetCredits : null
                readonly property real expiresMs: credits ? Date.parse(String(credits.nextExpiresAt || "")) - root.nowMs : NaN
                visible: !!credits && credits.available > 0
                width: parent.width
                height: Math.max(freeResetsText.implicitHeight, freeResetsExpiry.implicitHeight) + Style.space(16)
                radius: root.controlRadius
                color: root.alpha(Commons.Color.accent, 0.08)
                border.width: 1
                border.color: root.alpha(Commons.Color.accent, 0.24)

                Text {
                  id: freeResetsGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰑓"
                  color: root.accentText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                }

                Column {
                  id: freeResetsText
                  anchors.left: freeResetsGlyph.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: freeResetsExpiry.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: freeResets.credits ? freeResets.credits.available + " free reset"
                      + (freeResets.credits.available === 1 ? "" : "s") + " to redeem" : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    width: parent.width
                    visible: text !== ""
                    elide: Text.ElideRight
                    text: root.redeemHint(root.provider)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  id: freeResetsExpiry
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: text !== ""
                  text: freeResets.expiresMs > 0 ? "expires in " + root.formatDuration(freeResets.expiresMs) : ""
                  color: freeResets.expiresMs > 0 && freeResets.expiresMs < 2 * 86400000 ? root.warnText : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                visible: overviewCard.creditOnly
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) + " of "
                  + root.formatMoney(root.balance.funded, root.balance.currency) + " left" : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // ---------- View tabs ----------
          // One view at a time under the overview, so every card below has
          // an obvious home: Usage (limits, today, accounts), Activity
          // (calendar and trend), Models (token mix and per-model use) and
          // Cost (API-rate equivalent).
          TabStrip {
            id: viewTabStrip
            visible: !root.settingsOpen && !!root.provider
            width: parent.width
            tabs: root.viewTabs
            current: root.viewTab
            onPicked: function(id) {
              root.viewTab = id
              if (panelFlick) panelFlick.contentY = 0
            }
          }

          // ---------- Today at a glance ----------
          Row {
            id: todayTiles
            opacity: root.viewFade
            visible: root.viewTab === "usage" && !root.settingsOpen && !!root.provider && root.provider.hasLocalStats !== false
              && (root.hasActivity || todayTokens > 0 || root.provider.todayPrompts > 0 || root.provider.todaySessions > 0)
            width: parent.width
            spacing: Style.space(8)
            readonly property real tileWidth: (width - spacing * 2) / 3
            readonly property real todayTokens: root.provider && Number(root.provider.todayTotalTokens) > 0
              ? Number(root.provider.todayTotalTokens) : (root.activity ? root.activity.today : 0)
            readonly property bool promptStats: !!root.provider && root.provider.hasPromptStats !== false

            StatTile {
              width: todayTiles.tileWidth
              glyph: "󱐋"
              label: "Today"
              valueText: usage.formatTokenCount(todayTiles.todayTokens)
              // Compared from the same number the tile shows, and only when
              // the history actually has a day for today.
              readonly property var change: root.activity && root.activity.hasToday && root.activity.avg7 > 0
                ? todayTiles.todayTokens / root.activity.avg7 - 1 : null
              hint: change !== null ? Insights.formatChange(change) + " vs 7d avg" : "tokens"
              hintColor: change !== null && change > 0.5 ? root.accentText : root.dim
              tooltipText: root.activity && root.activity.avg7 >= 0
                ? "Tokens today · 7-day average " + usage.formatTokenCount(Math.round(root.activity.avg7)) + "/day"
                : "Tokens today"
            }

            StatTile {
              width: todayTiles.tileWidth
              glyph: todayTiles.promptStats ? "󰍪" : "󰄧"
              label: todayTiles.promptStats ? "Prompts" : "7-day avg"
              valueText: todayTiles.promptStats
                ? String(Number(root.provider ? root.provider.todayPrompts : 0) || 0)
                : (root.activity && root.activity.avg7 >= 0 ? usage.formatTokenCount(Math.round(root.activity.avg7)) : "—")
              hint: todayTiles.promptStats
                ? (Number(root.provider ? root.provider.todaySessions : 0) || 0) + " sessions today"
                : "tokens per day"
            }

            StatTile {
              width: todayTiles.tileWidth
              glyph: "󰈸"
              label: "Streak"
              valueText: root.hasActivity
                ? root.activity.streak + (root.activity.streak === 1 ? " day" : " days") : "—"
              hint: root.activity && root.activity.best
                ? "Best " + usage.formatTokenCount(root.activity.best.value) + " · " + root.shortHistoryDate(root.activity.best.date)
                : ""
              tooltipText: "Consecutive days with recorded usage"
            }
          }

          BorderSurface {
            id: balanceSection
            opacity: root.viewFade
            visible: root.viewTab === "usage" && !root.settingsOpen && !!root.balance
            width: parent.width
            implicitHeight: balanceContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: root.cardRadius

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

              CardTitle {
                width: parent.width
                glyph: "󰯝"
                text: "Prepaid balance"
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
            opacity: root.viewFade
            visible: root.viewTab === "usage" && !root.settingsOpen && root.otherLimits.length > 0
            width: parent.width
            implicitHeight: limitsContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: root.cardRadius

            Column {
              id: limitsContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              CardTitle {
                width: parent.width
                glyph: "󰓅"
                text: root.ringWindows.length > 0 ? "Other limits" : "Allowance"
                note: root.otherLimits.length > 1 ? root.otherLimits.length + " windows" : ""
              }

              Repeater {
                // Indexed, so a refresh updates rows in place instead of
                // rebuilding them (rebuilt rows re-animated and re-laid out).
                model: (root.otherLimits).length

                LimitRow {
                  readonly property var modelData: (root.otherLimits)[index] || ({})
                  required property int index
                  width: limitsContent.width
                  window: modelData
                }
              }
            }
          }

          // ---------- Accounts of this provider ----------
          // Every login of the selected provider side by side: its fullest
          // meter as a ring, its reading and next reset, and which one the
          // bar uses. Selecting a row shows that account above.
          BorderSurface {
            id: accountsCard
            opacity: root.viewFade
            visible: root.viewTab === "usage" && (root.accountBrand === "claude" || root.accountBrand === "codex")
              && root.accountRows.length > 1 && !root.settingsOpen
            width: parent.width
            implicitHeight: accountComparison.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: root.cardRadius

            Column {
              id: accountComparison
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(6)

              CardTitle {
                width: parent.width
                glyph: "󰀏"
                text: root.accountBrand === "claude" ? "Claude accounts" : "Codex accounts"
                note: root.accountRows.length + " logins"
              }

              Repeater {
                // Indexed, so a refresh updates rows in place instead of
                // rebuilding them (rebuilt rows re-animated and re-laid out).
                model: (root.accountRows).length

                Rectangle {
                  id: accountRow
                  readonly property var modelData: (root.accountRows)[index] || ({})
                  required property int index
                  readonly property bool current: !!root.provider && root.provider.providerId === modelData.providerId
                  readonly property var meter: root.chipMeter(modelData)
                  readonly property var next: {
                    var windows = root.limitWindows(modelData)
                    var best = null
                    for (var i = 0; i < windows.length; i++) {
                      var ms = root.resetMsFor(windows[i])
                      if (ms > 0 && (!best || ms < root.resetMsFor(best))) best = windows[i]
                    }
                    return best
                  }
                  width: accountComparison.width
                  height: Style.space(48)
                  radius: root.controlRadius
                  color: current ? root.alpha(Commons.Color.accent, 0.10)
                    : (accountRowHover.containsMouse ? root.alpha(root.foreground, 0.05) : "transparent")
                  border.width: current ? 1 : 0
                  border.color: root.alpha(Commons.Color.accent, 0.30)

                  MouseArea {
                    id: accountRowHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectedProviderId = accountRow.modelData.providerId
                  }

                  Item {
                    id: accountRowMark
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(34)
                    height: width

                    ChipRing {
                      anchors.fill: parent
                      visible: !!accountRow.meter
                      value: accountRow.meter ? accountRow.meter.value : -1
                      color: root.colorForSeverity(accountRow.meter ? accountRow.meter.severity : "ok")
                    }

                    ProviderMark {
                      anchors.centerIn: parent
                      width: Style.space(16)
                      height: width
                      provider: accountRow.modelData
                    }
                  }

                  Column {
                    anchors.left: accountRowMark.right
                    anchors.leftMargin: Style.space(10)
                    anchors.right: useAccountButton.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: accountRow.modelData.providerName
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width
                      text: String(accountRow.modelData.usageStatusText || "") !== ""
                        ? String(accountRow.modelData.usageStatusText)
                        : root.providerPercentText(accountRow.modelData)
                          + (accountRow.next ? " · " + String(accountRow.next.title || "Limit").toLowerCase()
                            + " resets in " + root.formatDuration(root.resetMsFor(accountRow.next)) : "")
                          + (accountRow.modelData.resetCredits ? " · " + accountRow.modelData.resetCredits.available
                            + " free reset" + (accountRow.modelData.resetCredits.available === 1 ? "" : "s") : "")
                      textFormat: Text.PlainText
                      color: String(accountRow.modelData.usageStatusText || "") !== ""
                        ? root.textFor(root.statusColor(accountRow.modelData)) : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  LaunchAccountButton {

                    radius: root.controlRadius
                    id: useAccountButton
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    providerBrand: root.accountBrand
                    accountId: accountRow.modelData.providerId
                    enabled: accountId === providerBrand || !!usage.accountProfiles[accountId]
                  }
                }
              }
            }
          }

          // ---------- Empty view ----------
          // A view with nothing to draw says why, instead of ending in a
          // blank strip under the tabs.
          BorderSurface {
            id: emptyViewCard
            opacity: root.viewFade
            readonly property bool viewEmpty: root.viewTab === "usage"
              ? !(todayTiles.visible || balanceSection.visible || limitsSection.visible || accountsCard.visible)
              : root.viewTab === "activity" ? !(activityCard.visible || historyCard.visible)
              : root.viewTab === "models" ? !(tokenMixCard.visible || detailModelSection.visible)
              : !costSection.visible
            visible: !root.settingsOpen && !!root.provider && viewEmpty
            width: parent.width
            implicitHeight: emptyViewContent.implicitHeight + Style.space(32)
            color: "transparent"
            borderSpec: Border.flat(root.alpha(root.foreground, 0.14), 1)
            radius: root.cardRadius

            Column {
              id: emptyViewContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(18)
              anchors.rightMargin: Style.space(18)
              spacing: Style.space(6)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.viewTab === "usage" ? "󰓅" : root.viewTab === "activity" ? "󰸘"
                  : root.viewTab === "models" ? "󰘚" : "󰄔"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Math.round(Style.font.display * 0.9)
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: {
                  var name = root.provider ? root.provider.providerName : "This provider"
                  var waiting = root.provider && String(root.provider.usageStatusText || "") !== ""
                  if (root.viewTab === "usage")
                    return waiting ? "Nothing to show until " + name + " reports again." : name + " reports no limits or usage for today."
                  if (root.viewTab === "activity") return name + " doesn't report daily token history."
                  if (root.viewTab === "models") return name + " doesn't report per-model token use."
                  return "No plan usage or API-rate data to compare yet."
                }
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }
          }

          // ---------- Token mix (Details) ----------
          // Where the tokens actually went: fresh input, output, and prompt
          // cache traffic, with the cache hit share that explains why a
          // "billion-token" month is mostly cheap cache reads.
          BorderSurface {
            id: tokenMixCard
            opacity: root.viewFade
            visible: root.viewTab === "models" && !root.settingsOpen && !!root.tokenMixData && root.tokenMixData.total > 0
            width: parent.width
            implicitHeight: tokenMixContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: root.cardRadius

            readonly property var segments: {
              var m = root.tokenMixData
              if (!m || !(m.total > 0)) return []
              return [
                { label: "Cache read", value: m.cacheRead, color: Commons.Color.accent },
                { label: "Cache write", value: m.cacheWrite, color: root.alpha(Commons.Color.accent, 0.45) },
                { label: "Input", value: m.input, color: root.foreground },
                { label: "Output", value: m.output, color: root.alpha(root.foreground, 0.45) }
              ]
            }

            Column {
              id: tokenMixContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              CardTitle {
                width: parent.width
                glyph: "󱘲"
                text: "Token mix"
                note: "all time" + (root.tokenMixData && root.tokenMixData.cacheHitRate >= 0
                  ? " · " + Math.round(root.tokenMixData.cacheHitRate * 100) + "% cache hit" : "")
              }

              Item {
                width: parent.width
                height: Style.space(12)
                clip: true

                Rectangle {
                  anchors.fill: parent
                  radius: height / 2
                  color: root.track
                }

                Row {
                  id: mixBar
                  anchors.fill: parent
                  spacing: 2

                  Repeater {
                    model: tokenMixCard.segments

                    Rectangle {
                      required property var modelData
                      required property int index
                      height: mixBar.height
                      width: Math.max(0, (mixBar.width - mixBar.spacing * 3) * modelData.value
                        / Math.max(1, root.tokenMixData ? root.tokenMixData.total : 1))
                      radius: height / 2
                      color: modelData.color
                      visible: width >= 1
                    }
                  }
                }
              }

              Grid {
                width: parent.width
                columns: 2
                rowSpacing: Style.space(6)
                columnSpacing: Style.space(12)

                Repeater {
                  model: tokenMixCard.segments

                  Item {
                    required property var modelData
                    width: (tokenMixContent.width - Style.space(12)) / 2
                    implicitHeight: mixLabel.implicitHeight

                    Rectangle {
                      id: mixSwatch
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(8)
                      height: width
                      radius: width / 2
                      color: modelData.color
                    }

                    Text {
                      id: mixLabel
                      anchors.left: mixSwatch.right
                      anchors.leftMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.label
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: usage.formatTokenCount(modelData.value) + " · "
                        + Math.round(modelData.value / Math.max(1, root.tokenMixData ? root.tokenMixData.total : 1) * 100) + "%"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          // ---------- History chart (issue 13): all recorded days for the
          // selected provider. The line makes the trend readable at a glance;
          // the axis labels make the scale explicit instead of asking the
          // viewer to infer it from bar height.
          BorderSurface {
            id: historyCard
            opacity: root.viewFade
            // Nothing to plot for a provider that reports no daily history
            // at all (a billing-only collector); an empty "0 days" card was
            // just noise.
            visible: root.viewTab === "activity" && !root.settingsOpen && !!root.provider
              && Array.isArray(root.provider.recentDays) && root.provider.recentDays.length > 0
            width: parent.width
            implicitHeight: historySection.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: root.cardRadius

          Column {
            id: historySection
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(14)
            spacing: Style.spacing.md

            CardTitle {
              width: parent.width
              glyph: "󰺓"
              text: "Token trend"
              note: root.historySeries && root.historySeries.ok
                ? usage.formatTokenCount(root.historySeriesTotal(root.historySeries)) + " · "
                  + root.historySeries.points.length + " days"
                : ""
            }

            Text {
              visible: !!(root.historySeries && root.historySeries.ok && root.historySeries.peak <= 0)
              width: parent.width
              topPadding: Style.space(6)
              bottomPadding: Style.space(6)
              text: "No tokens recorded in the last " + (root.historySeries ? root.historySeries.points.length : 0) + " days."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            Canvas {
              id: historyCanvas
              visible: !!(root.historySeries && root.historySeries.ok && root.historySeries.points.length > 0
                && root.historySeries.peak > 0)
              width: parent.width
              height: Style.space(150)

              readonly property real axisLeft: Style.space(46)
              readonly property real axisRight: Style.space(8)
              readonly property real axisTop: Style.space(10)
              readonly property real axisBottom: Style.space(22)

              property var series: root.historySeries
              property color lineColor: Commons.Color.accent
              property int hoverIndex: -1

              onHoverIndexChanged: requestPaint()
              // Repaint on a live theme switch: onPaint reads these root colors
              // directly, and Canvas does not track them on its own.
              readonly property string themeKey: [root.foreground, root.surface, root.track, root.dim, root.fontFamily].join("|")
              onThemeKeyChanged: requestPaint()

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

                  var xs = []
                  var ys = []
                  for (var i = 0; i < n; i++) {
                    xs.push(pointX(i))
                    ys.push(pointY(points[i] || {}))
                  }

                  // Interpolate through each day's measured value. Horizontal
                  // tangents keep the curve inside the adjacent samples.
                  function tracePath() {
                    ctx.moveTo(xs[0], ys[0])
                    for (var k = 1; k < n; k++) {
                      var mx = (xs[k - 1] + xs[k]) / 2
                      ctx.bezierCurveTo(mx, ys[k - 1], mx, ys[k], xs[k], ys[k])
                    }
                  }

                  var area = ctx.createLinearGradient(0, top, 0, bottom)
                  area.addColorStop(0, root.alpha(historyCanvas.lineColor, 0.32))
                  area.addColorStop(1, root.alpha(historyCanvas.lineColor, 0.0))
                  ctx.fillStyle = area
                  ctx.beginPath()
                  tracePath()
                  ctx.lineTo(xs[n - 1], bottom)
                  ctx.lineTo(xs[0], bottom)
                  ctx.closePath()
                  ctx.fill()

                  ctx.strokeStyle = historyCanvas.lineColor
                  ctx.lineWidth = 2
                  ctx.lineCap = "round"
                  ctx.lineJoin = "round"
                  ctx.beginPath()
                  tracePath()
                  ctx.stroke()

                  if (historyCanvas.hoverIndex >= 0 && historyCanvas.hoverIndex < n) {
                    var hx = Math.round(xs[historyCanvas.hoverIndex]) + 0.5
                    ctx.strokeStyle = root.alpha(root.foreground, 0.35)
                    ctx.lineWidth = 1
                    ctx.beginPath()
                    ctx.moveTo(hx, top)
                    ctx.lineTo(hx, bottom)
                    ctx.stroke()
                    ctx.fillStyle = historyCanvas.lineColor
                    ctx.beginPath()
                    ctx.arc(xs[historyCanvas.hoverIndex], ys[historyCanvas.hoverIndex], 4, 0, Math.PI * 2)
                    ctx.fill()
                  }

                  // Mark the busiest day and the latest one; zero-usage days
                  // stay visible as the line touching the baseline.
                  var peakIndex = 0
                  for (var j = 1; j < n; j++)
                    if (Number(points[j].value || 0) > Number(points[peakIndex].value || 0)) peakIndex = j
                  var marks = peakIndex === n - 1 ? [n - 1] : [peakIndex, n - 1]
                  for (var m = 0; m < marks.length; m++) {
                    var idx = marks[m]
                    ctx.fillStyle = root.surface
                    ctx.beginPath()
                    ctx.arc(xs[idx], ys[idx], 5, 0, Math.PI * 2)
                    ctx.fill()
                    ctx.fillStyle = idx === n - 1 ? root.foreground : historyCanvas.lineColor
                    ctx.beginPath()
                    ctx.arc(xs[idx], ys[idx], 3.5, 0, Math.PI * 2)
                    ctx.fill()
                  }
                } catch (e) {
                  // Swallow: a chart that fails to draw should leave a
                  // blank strip, not take the rest of the panel down.
                }
              }

              MouseArea {
                id: historyHover
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onExited: historyCanvas.hoverIndex = -1
                onPositionChanged: function(mouse) {
                  var s = historyCanvas.series
                  var count = s && s.points ? s.points.length : 0
                  var plot = historyCanvas.width - historyCanvas.axisLeft - historyCanvas.axisRight
                  if (count === 0 || plot <= 0) { historyCanvas.hoverIndex = -1; return }
                  var t = (mouse.x - historyCanvas.axisLeft) / plot
                  historyCanvas.hoverIndex = count <= 1 ? 0 : Math.round(root.clamp(t, 0, 1) * (count - 1))
                }
              }

              PanelToolTip {
                visible: historyHover.containsMouse && historyCanvas.hoverIndex >= 0
                text: {
                  var s = historyCanvas.series
                  var point = s && s.points ? s.points[historyCanvas.hoverIndex] : null
                  return point ? root.dayTooltip({ date: point.date, messageCount: point.value },
                    String(point.date) === root.todayDate()) : ""
                }
                fontFamily: root.fontFamily
              }
            }

            // Labels sit under their own data points (same x as the
            // chart's pointX), positioned explicitly: a Row collapses the
            // hidden in-between labels and piles the visible ones up.
            Item {
              id: historyLabels
              visible: historyCanvas.visible
              width: parent.width
              height: Style.space(14)

              Repeater {
                // Indexed, so a refresh updates rows in place instead of
                // rebuilding them (rebuilt rows re-animated and re-laid out).
                model: (root.historySeries && root.historySeries.points ? root.historySeries.points : []).length

                Text {
                  readonly property var modelData: (root.historySeries && root.historySeries.points ? root.historySeries.points : [])[index] || ({})
                  required property int index
                  readonly property int count: root.historySeries && root.historySeries.points
                    ? root.historySeries.points.length : 0
                  readonly property real plotWidth: historyLabels.width - historyCanvas.axisLeft - historyCanvas.axisRight
                  readonly property real pointX: count <= 1
                    ? historyCanvas.axisLeft + plotWidth / 2
                    : historyCanvas.axisLeft + plotWidth * index / (count - 1)
                  x: root.clamp(pointX - implicitWidth / 2, 0, Math.max(0, historyLabels.width - implicitWidth))
                  visible: index === 0 || index === count - 1
                    || (count > 2 && index === Math.floor((count - 1) / 2))
                  text: root.shortHistoryDate(modelData.date)
                  color: index === count - 1 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

          }
          }

          // ---------- Activity calendar (Details) ----------
          // Five weeks (collectors keep up to 31 days) of the selected
          // provider's daily tokens as a calendar
          // heatmap: rows are weeks, columns Monday..Sunday. A day outside
          // the collector's record is drawn hollow, never as a quiet zero.
          BorderSurface {
            id: activityCard
            opacity: root.viewFade
            visible: root.viewTab === "activity" && !root.settingsOpen && root.hasActivity && !!root.heatmap
            width: parent.width
            implicitHeight: activityContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: root.cardRadius

            Column {
              id: activityContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              CardTitle {
                width: parent.width
                glyph: "󰸘"
                text: "Activity"
                note: root.activity ? root.activity.activeDays + " active of " + root.activity.recordedDays + " days" : ""
              }

              Row {
                width: parent.width
                spacing: Style.space(4)
                readonly property real cellWidth: (width - spacing * 6) / 7

                Repeater {
                  model: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

                  Text {
                    required property var modelData
                    width: parent.cellWidth
                    text: modelData
                    horizontalAlignment: Text.AlignHCenter
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  // Indexed, so a refresh updates rows in place instead of
                  // rebuilding them (rebuilt rows re-animated and re-laid out).
                  model: (root.heatmap ? root.heatmap.weeks : []).length

                  Row {
                    id: heatWeek
                    readonly property var modelData: (root.heatmap ? root.heatmap.weeks : [])[index] || ({})
                    required property int index
                    width: parent.width
                    spacing: Style.space(4)
                    readonly property real cellWidth: (width - spacing * 6) / 7

                    Repeater {
                      // Indexed, so a refresh updates rows in place instead of
                      // rebuilding them (rebuilt rows re-animated and re-laid out).
                      model: (heatWeek.modelData).length

                      Rectangle {
                        id: heatCell
                        readonly property var modelData: (heatWeek.modelData)[index] || ({})
                        required property int index
                        width: heatWeek.cellWidth
                        height: Style.space(22)
                        radius: Style.space(6)
                        color: heatCell.modelData.future || heatCell.modelData.missing
                          ? "transparent" : root.heatColor(heatCell.modelData.level)
                        border.width: heatCell.modelData.today ? 2 : (heatCell.modelData.missing && !heatCell.modelData.future ? 1 : 0)
                        border.color: heatCell.modelData.today ? root.foreground : root.alpha(root.foreground, 0.10)
                        opacity: heatCell.modelData.future ? 0.0 : 1.0

                        Text {
                          anchors.centerIn: parent
                          text: Number(String(heatCell.modelData.date).slice(8, 10))
                          color: heatCell.modelData.future || heatCell.modelData.missing
                            ? root.dim : root.inkOn(root.heatColor(heatCell.modelData.level))
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: heatCell.modelData.today
                        }

                        MouseArea {
                          id: heatHover
                          anchors.fill: parent
                          hoverEnabled: !heatCell.modelData.future
                          acceptedButtons: Qt.NoButton
                        }

                        PanelToolTip {
                          visible: heatHover.containsMouse
                          text: heatCell.modelData.missing
                            ? root.shortHistoryDate(heatCell.modelData.date) + " · no record"
                            : root.dayTooltip({ date: heatCell.modelData.date, messageCount: heatCell.modelData.value },
                                heatCell.modelData.today)
                          fontFamily: root.fontFamily
                        }
                      }
                    }
                  }
                }
              }

              Item {
                width: parent.width
                implicitHeight: heatLegend.implicitHeight

                Row {
                  id: heatLegend
                  anchors.right: parent.right
                  spacing: Style.space(4)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Less"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Repeater {
                    model: [0, 1, 2, 3, 4]

                    Rectangle {
                      required property int modelData
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(10)
                      height: width
                      radius: Style.space(3)
                      color: root.heatColor(modelData)
                    }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "More"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  anchors.left: parent.left
                  anchors.verticalCenter: heatLegend.verticalCenter
                  text: root.heatmap && root.heatmap.peak > 0
                    ? "Peak " + usage.formatTokenCount(root.heatmap.peak) + " / day" : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                readonly property real tileWidth: (width - spacing * 2) / 3

                StatTile {
                  width: parent.tileWidth
                  label: "Recorded"
                  valueText: root.activity ? usage.formatTokenCount(root.activity.total) : "—"
                  hint: "tokens recorded"
                }

                StatTile {
                  width: parent.tileWidth
                  label: "7-day avg"
                  valueText: root.activity && root.activity.avg7 >= 0
                    ? usage.formatTokenCount(Math.round(root.activity.avg7)) : "—"
                  hint: "tokens / day"
                }

                StatTile {
                  width: parent.tileWidth
                  label: "Week vs last"
                  valueText: root.activity && root.activity.weekChange !== null
                    ? Insights.formatChange(root.activity.weekChange) : "—"
                  hint: root.activity && root.activity.weekChange !== null
                    ? (root.activity.weekChange === 0 ? "same usage" : (root.activity.weekChange > 0 ? "busier week" : "quieter week")) : "needs 14 days"
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
            opacity: root.viewFade
            visible: root.viewTab === "models" && !root.settingsOpen && root.detailModels.length > 0
            width: parent.width
            implicitHeight: detailModelContent.implicitHeight + Style.space(28)
            color: root.alpha(root.foreground, 0.035)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
            radius: root.cardRadius

            Column {
              id: detailModelContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: Style.space(10)

              CardTitle {
                width: parent.width
                glyph: "󰘚"
                text: "Token use by model"
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
                // Indexed, so a refresh updates rows in place instead of
                // rebuilding them (rebuilt rows re-animated and re-laid out).
                model: (root.detailModels).length

                ModelRow {
                  readonly property var modelData: (root.detailModels)[index] || ({})
                  required property int index
                  width: detailModelContent.width
                  row: modelData
                  share: modelData.total / Math.max(1, root.detailModels[0].total)
                }
              }
            }
          }

          // ---------- Plan vs API (Details only) ----------------------------
          // The Cost view, kept to two cards: what this account's recorded
          // usage would cost at published API rates (an equivalent, never an
          // invoice or a subscription price), then how the providers that
          // have an estimate compare.
          Column {
            id: costSection
            opacity: root.viewFade
            visible: root.expanded && !root.settingsOpen && root.viewTab === "cost"
              && root.costProviderRows.length > 0
            width: parent.width
            spacing: Style.space(12)

            BorderSurface {
              id: costValueCard
              visible: !!root.provider
              width: parent.width
              implicitHeight: costValueContent.implicitHeight + Style.space(36)
              color: root.alpha(root.foreground, 0.035)
              borderSpec: Border.flat(root.alpha(Commons.Color.accent, root.cost ? 0.24 : 0.12), 1)
              radius: root.cardRadius

              Rectangle {
                visible: !!root.cost
                anchors.fill: parent
                anchors.margins: 1
                radius: parent.radius
                gradient: Gradient {
                  orientation: Gradient.Vertical
                  GradientStop { position: 0; color: root.alpha(Commons.Color.accent, 0.10) }
                  GradientStop { position: 0.45; color: root.alpha(Commons.Color.accent, 0.0) }
                }
              }

              Column {
                id: costValueContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(18)
                anchors.rightMargin: Style.space(18)
                spacing: Style.space(16)

                CardTitle {
                  width: parent.width
                  glyph: "󰄔"
                  text: "If billed by API"
                  note: root.cost && root.cost.period ? String(root.cost.period) : ""
                }

                Column {
                  visible: !!root.cost
                  width: parent.width
                  spacing: Style.space(4)

                  Text {
                    width: parent.width
                    text: root.cost ? root.formatUsd(root.cost.estimateUsd) : "—"
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: "Estimated at published API rates · not a bill"
                    textFormat: Text.PlainText
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                Text {
                  id: costDisclosure
                  visible: !!root.provider && (!root.cost || root.cost.incomplete)
                  width: parent.width
                  text: !root.cost
                    ? "No priced token total for this provider yet. Estimates come from collectors that record per-model tokens with a published API rate."
                    : "Partial estimate · " + root.unpricedModelText(root.cost)
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  lineHeight: 1.15
                }

                Row {
                  id: costMetrics
                  visible: !!root.cost && !!root.costSummary && root.costSummary.hasDailyAverage
                  width: parent.width
                  spacing: Style.space(10)

                  CostChip {
                    width: (costMetrics.width - costMetrics.spacing) / 2
                    valueText: root.costSummary && root.costSummary.hasDailyAverage
                      ? root.formatUsd(root.costSummary.averageDailyUsd) : "—"
                    label: "a day"
                    hint: root.costSummary && root.costSummary.hasDailyAverage
                      ? root.costSummary.averageDailyDays + "-day average" : ""
                  }

                  // A month at that average — the number to hold against a
                  // plan's price.
                  CostChip {
                    width: (costMetrics.width - costMetrics.spacing) / 2
                    valueText: root.costSummary && root.costSummary.hasDailyAverage
                      ? root.formatUsd(root.costSummary.averageDailyUsd * 30) : "—"
                    label: "per 30 days"
                    hint: "at that average"
                  }
                }

                Column {
                  id: costDailyBlock
                  visible: !!root.cost && root.costDailyRows.length > 0
                  width: parent.width
                  spacing: Style.space(8)

                  Item {
                    width: parent.width
                    implicitHeight: costDailyTitle.implicitHeight

                    Text {
                      id: costDailyTitle
                      anchors.left: parent.left
                      text: "By day"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }

                    Text {
                      anchors.right: parent.right
                      anchors.verticalCenter: costDailyTitle.verticalCenter
                      text: root.costSummary
                        ? root.formatUsd(root.costSummary.dailyTotalUsd)
                          + (root.costSummary.dailySource === "reported" ? " reported" : " derived")
                        : ""
                      textFormat: Text.PlainText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Item {
                    id: costDailyChart
                    visible: root.costDailyRows.length > 0
                    width: parent.width
                    height: Style.space(130)

                    readonly property real axisLeft: Style.space(44)
                    readonly property real axisRight: Style.space(2)
                    readonly property real axisTop: Style.space(8)
                    readonly property real axisBottom: Style.space(22)
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
                          text: root.axisUsd(costDailyChart.peak * modelData)
                          textFormat: Text.PlainText
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          horizontalAlignment: Text.AlignRight
                        }

                        Rectangle {
                          x: costDailyChart.axisLeft
                          width: costDailyChart.plotWidth
                          height: 1
                          color: root.alpha(root.foreground, 0.10)
                        }
                      }
                    }

                    Repeater {
                      // Indexed, so a refresh updates bars in place.
                      model: (root.costDailyRows).length

                      Item {
                        id: costDayBar
                        required property int index
                        readonly property var modelData: (root.costDailyRows)[index] || ({})
                        readonly property bool latest: index === root.costDailyRows.length - 1
                        width: costDailyChart.plotWidth / Math.max(1, root.costDailyRows.length)
                        height: costDailyChart.plotHeight
                        x: costDailyChart.axisLeft + index * width
                        y: costDailyChart.axisTop

                        Rectangle {
                          width: Math.max(3, Math.min(parent.width * 0.7, parent.width - Style.space(2)))
                          height: Number(costDayBar.modelData.usd || 0) > 0
                            ? Math.max(2, parent.height * Math.min(1,
                              Number(costDayBar.modelData.usd || 0) / Math.max(0.0001, costDailyChart.peak)))
                            : 1
                          anchors.bottom: parent.bottom
                          anchors.horizontalCenter: parent.horizontalCenter
                          radius: Math.min(width / 2, Style.space(3))
                          gradient: Gradient {
                            GradientStop { position: 0; color: costDayBar.latest ? root.foreground : Commons.Color.accent }
                            GradientStop { position: 1; color: root.alpha(costDayBar.latest ? root.foreground : Commons.Color.accent, 0.35) }
                          }
                          opacity: costDayHover.containsMouse || costDayBar.latest ? 1.0 : 0.85
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

                    // Positioned items, not a Row: a Row collapses its
                    // invisible children, which stacked the three visible
                    // dates on top of each other at the left edge.
                    Item {
                      id: costDailyLabels
                      x: costDailyChart.axisLeft
                      y: costDailyChart.height - height
                      width: costDailyChart.plotWidth
                      height: Style.space(16)

                      Repeater {
                        model: (root.costDailyRows).length

                        Text {
                          required property int index
                          readonly property var modelData: (root.costDailyRows)[index] || ({})
                          readonly property real slot: costDailyLabels.width / Math.max(1, root.costDailyRows.length)
                          x: root.clamp(index * slot + slot / 2 - implicitWidth / 2, 0,
                            Math.max(0, costDailyLabels.width - implicitWidth))
                          visible: index === 0 || index === root.costDailyRows.length - 1
                            || (root.costDailyRows.length > 2
                              && index === Math.floor((root.costDailyRows.length - 1) / 2))
                          text: root.shortHistoryDate(modelData.date)
                          textFormat: Text.PlainText
                          color: index === root.costDailyRows.length - 1 ? root.foreground : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }

                // By model: one stacked bar in the series colors, then a
                // legend line per model.
                Column {
                  id: costModelChart
                  visible: root.costModelRows.length > 0
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    text: "By model"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Item {
                    width: parent.width
                    height: Style.space(10)
                    clip: true

                    Rectangle {
                      anchors.fill: parent
                      radius: height / 2
                      color: root.track
                    }

                    Row {
                      id: costModelStack
                      anchors.fill: parent
                      spacing: 2

                      Repeater {
                        model: (root.costModelRows).length

                        Rectangle {
                          required property int index
                          readonly property var modelData: (root.costModelRows)[index] || ({})
                          height: costModelStack.height
                          width: Math.max(0, (costModelStack.width - costModelStack.spacing * Math.max(0, root.costModelRows.length - 1))
                            * root.clamp(Number(modelData.share || 0), 0, 1))
                          radius: height / 2
                          color: root.seriesColor(index)
                          visible: width >= 1
                        }
                      }
                    }
                  }

                  Repeater {
                    model: (root.costModelRows).length

                    Item {
                      id: costModelRow
                      required property int index
                      readonly property var modelData: (root.costModelRows)[index] || ({})
                      width: costModelChart.width
                      height: Style.space(22)

                      Rectangle {
                        id: costModelDot
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(8)
                        height: width
                        radius: width / 2
                        color: root.seriesColor(costModelRow.index)
                      }

                      Text {
                        id: costModelName
                        text: usage.friendlyModelName(costModelRow.modelData.model)
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                        anchors.left: costModelDot.right
                        anchors.leftMargin: Style.space(8)
                        anchors.right: costModelShare.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        id: costModelShare
                        text: Math.round(root.clamp(Number(costModelRow.modelData.share || 0), 0, 1) * 100) + "%"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        anchors.right: costModelValue.left
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        id: costModelValue
                        text: root.formatUsd(costModelRow.modelData.usd)
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
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
                  wrapMode: Text.WordWrap
                }
              }
            }

            // The providers that have an estimate, ranked, each with its
            // share of the combined total; the rest are named once below
            // rather than as rows of dashes.
            BorderSurface {
              id: costProviderOverview
              visible: root.costProviderRows.length > 0
              width: parent.width
              implicitHeight: providerOverviewContent.implicitHeight + Style.space(28)
              color: root.alpha(root.foreground, 0.035)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
              radius: root.cardRadius

              readonly property var priced: root.costProviderRows.filter(function(r) { return r.hasCost })
                .sort(function(a, b) { return b.estimateUsd - a.estimateUsd })
              readonly property var unpriced: root.costProviderRows.filter(function(r) { return !r.hasCost })
              readonly property real totalUsd: {
                var total = 0
                for (var i = 0; i < priced.length; i++) total += Number(priced[i].estimateUsd) || 0
                return total
              }

              Column {
                id: providerOverviewContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(4)

                CardTitle {
                  width: parent.width
                  glyph: "󰀏"
                  text: "All providers"
                  note: costProviderOverview.totalUsd > 0 ? root.formatUsd(costProviderOverview.totalUsd) + " total" : ""
                }

                Text {
                  width: parent.width
                  bottomPadding: Style.space(4)
                  text: "API-rate estimates side by side · periods vary by provider"
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.costProviderRows.length > 0 ? costProviderOverview.priced.length : 0

                  Rectangle {
                    id: providerCostRow
                    required property int index
                    readonly property var modelData: costProviderOverview.priced[index] || ({})
                    readonly property bool current: !!root.provider && root.provider.providerId === modelData.providerId
                    readonly property var live: root.providerById(modelData.providerId)
                    width: providerOverviewContent.width
                    height: Style.space(44)
                    radius: root.controlRadius
                    color: current ? root.alpha(Commons.Color.accent, 0.10)
                      : (providerCostHover.containsMouse ? root.alpha(root.foreground, 0.04) : "transparent")

                    MouseArea {
                      id: providerCostHover
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectedProviderId = providerCostRow.modelData.providerId
                    }

                    ProviderMark {
                      id: providerCostMark
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(8)
                      width: Style.space(16)
                      height: width
                      provider: providerCostRow.live || providerCostRow.modelData
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
                      anchors.left: providerCostMark.right
                      anchors.leftMargin: Style.space(8)
                      anchors.right: providerCostKind.left
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: providerCostMark.verticalCenter
                    }

                    Text {
                      id: providerCostKind
                      text: (providerCostRow.modelData.incomplete ? "partial" : "")
                        + (providerCostRow.modelData.incomplete && providerCostRow.modelData.period ? " · " : "")
                        + (providerCostRow.modelData.period || "")
                      textFormat: Text.PlainText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.right: providerCostApiValue.left
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: providerCostMark.verticalCenter
                    }

                    Text {
                      id: providerCostApiValue
                      text: root.costApiValue(providerCostRow.modelData)
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.verticalCenter: providerCostMark.verticalCenter
                    }

                    // Share of the combined estimate, in the series color.
                    Rectangle {
                      id: providerShareTrack
                      anchors.left: providerCostName.left
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(8)
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: Style.space(8)
                      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.12))
                      radius: height / 2
                      color: root.track
                    }

                    Rectangle {
                      anchors.left: providerShareTrack.left
                      anchors.verticalCenter: providerShareTrack.verticalCenter
                      width: providerShareTrack.width * root.clamp(Number(providerCostRow.modelData.share || 0), 0, 1)
                      height: providerShareTrack.height
                      radius: height / 2
                      color: root.seriesColor(providerCostRow.index)

                      Behavior on width {
                        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                      }
                    }
                  }
                }

                Text {
                  visible: costProviderOverview.unpriced.length > 0
                  width: parent.width
                  topPadding: Style.space(4)
                  text: "No estimate: " + costProviderOverview.unpriced.map(function(r) { return r.providerName }).join(", ")
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          // ---------- Settings: the same values `omarchy bar set` edits,
          // editable here without a terminal (issue 08). Gated by its own
          // `settingsOpen` flag (not `expanded`) so opening settings doesn't
          // also force the cross-provider data section into view — the two
          // are mutually exclusive, see toggleSettings(). Every control writes
          // through usage.set*() in Main.qml; numeric fields go through the
          // `settingsDraft` object and the pinned save bar.
          Column {
            id: settingsSection
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(14)

            // Discard any unsaved draft the moment settings are reopened,
            // rather than resuming an edit from a previous visit — resyncing
            // only here (never on a live settings change) is what keeps a
            // draft immune to being clobbered while the panel is open.
            onVisibleChanged: if (visible) {
              settingsDraft.resyncDrafts()
              syncContent.resyncDraft()
            }

            // ----- Section tabs -----
            TabStrip {
              id: settingsTabs
              width: parent.width
              tabs: [
                { id: "providers", label: "Providers", glyph: "󰨝" },
                { id: "accounts", label: "Accounts", glyph: "󰀏" },
                { id: "display", label: "Display", glyph: "󰸌" },
                { id: "alerts", label: "Alerts", glyph: "󰂜" },
                { id: "sync", label: "Sync", glyph: "󰓦" }
              ]
              current: root.settingsTab
              // A dot on a tab that holds unsaved edits, so a draft left on
              // another tab is never invisible.
              badges: ({
                providers: settingsDraft.rotationDirty,
                display: settingsDraft.refreshDirty,
                alerts: settingsDraft.thresholdsDirty,
                sync: syncContent.syncDirDirty
              })
              onPicked: function(id) {
                root.settingsTab = id
                if (panelFlick) panelFlick.contentY = 0
              }
            }

            // =========================================== Providers tab
            Column {
              id: providerSettingsList
              visible: root.settingsTab === "providers"
              width: parent.width
              spacing: Style.space(10)

              readonly property var barRoleOptions: [
                { value: "off", label: "Off", tip: "Not shown in the bar" },
                { value: "fixed", label: "Fixed", tip: "Always shown in the bar" },
                { value: "cycle", label: "Cycle", tip: "Rotates through the bar's Cycle slots" }
              ]
              readonly property var labelModeOptions: [
                { value: "icon", label: "Icon", tip: "Just the mark" },
                { value: "iconPercent", label: "Icon %", tip: "Mark and the percent" },
                { value: "full", label: "Full", tip: "Mark, meter and percent" }
              ]

              Text {
                width: parent.width
                text: "Choose which subscriptions are collected and how each one sits in the bar. To change their order, drag the provider marks in the usage view."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                lineHeight: 1.15
              }

              Repeater {
                // Indexed, so a refresh updates rows in place instead of
                // rebuilding them (rebuilt rows re-animated and re-laid out).
                model: (root.settingsProviders).length

                BorderSurface {
                  id: providerSettingsRow
                  readonly property var modelData: (root.settingsProviders)[index] || ({})
                  required property int index
                  readonly property var liveProvider: root.providerById(modelData.providerId)
                  readonly property bool inBar: modelData.enabled && modelData.barRole !== "off"
                  width: providerSettingsList.width
                  implicitHeight: providerCardContent.implicitHeight + Style.space(24)
                  color: root.alpha(root.foreground, modelData.enabled ? 0.045 : 0.02)
                  borderSpec: Border.flat(root.alpha(modelData.enabled ? Commons.Color.accent : root.foreground,
                    modelData.enabled ? 0.22 : 0.10), 1)
                  radius: root.cardRadius

                  Column {
                    id: providerCardContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(12)

                    Item {
                      width: parent.width
                      implicitHeight: Math.max(Style.space(34), providerHeading.implicitHeight)

                      Rectangle {
                        id: providerMarkTile
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(34)
                        height: width
                        radius: root.controlRadius
                        color: root.alpha(root.foreground, 0.06)
                        opacity: providerSettingsRow.modelData.enabled ? 1.0 : 0.5

                        ProviderMark {
                          anchors.centerIn: parent
                          width: Style.space(20)
                          height: width
                          provider: providerSettingsRow.modelData
                        }
                      }

                      Column {
                        id: providerHeading
                        anchors.left: providerMarkTile.right
                        anchors.leftMargin: Style.space(10)
                        anchors.right: barPreviewStrip.visible ? barPreviewStrip.left : providerToggle.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)

                        Text {
                          width: parent.width
                          text: providerSettingsRow.modelData.providerName
                          textFormat: Text.PlainText
                          color: providerSettingsRow.modelData.enabled ? root.foreground : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: true
                          elide: Text.ElideRight
                        }

                        Text {
                          width: parent.width
                          text: root.providerSettingsSummary(providerSettingsRow.modelData, providerSettingsRow.liveProvider)
                          textFormat: Text.PlainText
                          color: providerSettingsRow.modelData.enabled && providerSettingsRow.liveProvider
                            && String(providerSettingsRow.liveProvider.usageStatusText || "") !== ""
                            ? root.textFor(root.statusColor(providerSettingsRow.liveProvider)) : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                      }

                      // What the bar will draw for this provider, built from
                      // the same parts as the real bar group.
                      Rectangle {
                        id: barPreviewStrip
                        visible: providerSettingsRow.inBar
                        anchors.right: providerToggle.left
                        anchors.rightMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        height: Style.space(24)
                        width: barPreviewRow.implicitWidth + Style.space(16)
                        radius: root.controlRadius
                        color: Commons.Color.bar.background
                        border.width: 1
                        border.color: root.alpha(root.foreground, 0.14)

                        Row {
                          id: barPreviewRow
                          anchors.centerIn: parent
                          spacing: Style.space(5)
                          readonly property string mode: providerSettingsRow.modelData.labelMode
                          readonly property var previewProvider: providerSettingsRow.liveProvider || providerSettingsRow.modelData

                          ProviderMark {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(16)
                            height: width
                            provider: barPreviewRow.previewProvider
                            barMark: true
                          }

                          CheckpointMeter {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(48)
                            visible: barPreviewRow.mode === "full" && root.providerPercent(barPreviewRow.previewProvider) >= 0
                            value: {
                              var percent = root.providerPercent(barPreviewRow.previewProvider)
                              return percent >= 0 ? root.displayPercent(percent) : -1
                            }
                            secondaryValue: {
                              var percent = root.providerSecondaryPercent(barPreviewRow.previewProvider)
                              return percent >= 0 ? root.displayPercent(percent) : -1
                            }
                            severity: root.providerWorstSeverity(barPreviewRow.previewProvider)
                          }

                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: barPreviewRow.mode !== "icon"
                            text: root.providerPercentText(barPreviewRow.previewProvider)
                            color: root.colorForSeverity(root.providerWorstSeverity(barPreviewRow.previewProvider))
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }
                      }

                      ToggleSwitch {

                        rounded: true
                        id: providerToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        checked: providerSettingsRow.modelData.enabled
                        foreground: root.foreground
                        accent: Commons.Color.accent
                        onToggled: usage.setProviderEnabled(providerSettingsRow.modelData.providerId, !providerSettingsRow.modelData.enabled)
                      }
                    }

                    // Bar placement only matters for a collected provider:
                    // where it sits, and how much of it the bar draws.
                    Row {
                      visible: providerSettingsRow.modelData.enabled
                      width: parent.width
                      spacing: Style.space(10)
                      readonly property real half: (width - spacing) / 2

                      Column {
                        width: parent.half
                        spacing: Style.space(5)

                        Text {
                          text: "In the bar"
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Segmented {
                          width: parent.width
                          options: providerSettingsList.barRoleOptions
                          current: providerSettingsRow.modelData.barRole
                          onPicked: function(value) { usage.setProviderBarRole(providerSettingsRow.modelData.providerId, value) }
                        }
                      }

                      Column {
                        width: parent.half
                        spacing: Style.space(5)
                        enabled: providerSettingsRow.inBar
                        opacity: enabled ? 1.0 : 0.45

                        Text {
                          text: "Shows"
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        Segmented {
                          width: parent.width
                          options: providerSettingsList.labelModeOptions
                          current: providerSettingsRow.modelData.labelMode
                          onPicked: function(value) { usage.setProviderLabelMode(providerSettingsRow.modelData.providerId, value) }
                        }
                      }
                    }
                  }
                }
              }

              BorderSurface {
                visible: root.settingsProviders.length === 0
                width: parent.width
                implicitHeight: noProvidersText.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Text {
                  id: noProvidersText
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(14)
                  text: "No subscriptions discovered yet. Use Claude Code or Codex once, or install the optional collectors for other providers — they show up here on the next refresh."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }


              // ----- Rotation -----
              BorderSurface {
                width: parent.width
                implicitHeight: rotationContent.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: rotationContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(10)

                  CardTitle {
                    width: parent.width
                    glyph: "󰑧"
                    text: "Bar rotation"
                    note: root.hasCycleSlotConfigured() ? "" : "no Cycle providers"
                  }

                  Text {
                    width: parent.width
                    text: root.hasCycleSlotConfigured()
                      ? "Providers set to Cycle take turns in these slots, next to the Fixed ones. Middle-click the bar to advance."
                      : "Set a provider's Bar slot to Cycle to rotate it through the bar instead of showing it all the time."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(12)
                    // Disabled rather than hidden when unused, so the card's
                    // shape never changes as providers switch bar roles.
                    enabled: root.hasCycleSlotConfigured()
                    opacity: enabled ? 1.0 : 0.5

                    NumberField {
                      width: (parent.width - parent.spacing) / 2
                      fieldWidth: width
                      label: "Cycle slots"
                      value: settingsDraft.cycleSlots
                      from: 0
                      to: 3
                      stepSize: 1
                      foreground: root.foreground
                      accent: Commons.Color.accent
                      fontFamily: root.fontFamily
                      onModified: function(v) { settingsDraft.cycleSlots = v }
                    }

                    NumberField {
                      width: (parent.width - parent.spacing) / 2
                      fieldWidth: width
                      label: "Rotate every (s)"
                      value: settingsDraft.cycleIntervalSec
                      from: 3
                      to: 120
                      stepSize: 1
                      foreground: root.foreground
                      accent: Commons.Color.accent
                      fontFamily: root.fontFamily
                      onModified: function(v) { settingsDraft.cycleIntervalSec = v }
                    }
                  }
                }
              }
            }

            // ============================================ Accounts tab
            // Several Claude or Codex logins side by side. The list comes
            // first (what exists and which one the bar uses), then the two
            // ways to add one: a fresh login, or importing existing CLI homes.
            Column {
              id: accountSettingsContent
              visible: root.settingsTab === "accounts"
              width: parent.width
              spacing: Style.space(10)

              property string newProvider: "claude"
              readonly property string providerLabel: newProvider === "claude" ? "Claude" : "Codex"
              readonly property var accounts: {
                var profiles = usage.accountProfiles
                return Object.keys(profiles).sort().filter(function(id) { return profiles[id].provider === accountSettingsContent.newProvider })
              }
              function addNewAccount() {
                if (usage.addAccount(newProvider, accountNameInput.text)) accountNameInput.text = ""
              }

              Text {
                width: parent.width
                text: "Track several Claude or Codex logins side by side. The active account is the one the bar shows and right-click launches; changes apply immediately."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                lineHeight: 1.15
              }

              Segmented {
                width: parent.width
                options: [{ value: "claude", label: "Claude" }, { value: "codex", label: "Codex" }]
                current: accountSettingsContent.newProvider
                onPicked: function(value) { accountSettingsContent.newProvider = value }
              }

              BorderSurface {
                width: parent.width
                implicitHeight: accountListContent.implicitHeight + Style.space(24)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: accountListContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(12)
                  anchors.rightMargin: Style.space(12)
                  spacing: Style.space(6)

                  CardTitle {
                    width: parent.width
                    glyph: "󰀏"
                    text: accountSettingsContent.providerLabel + " accounts"
                    note: (accountSettingsContent.accounts.length + 1) + " total"
                  }

                  Repeater {
                    model: [accountSettingsContent.newProvider].concat(accountSettingsContent.accounts)

                    Rectangle {
                      id: configuredAccountRow
                      required property string modelData
                      readonly property var profile: usage.accountProfiles[modelData]
                      readonly property bool ready: !profile || root.accountRecordExists(modelData)
                      readonly property var live: root.providerById(modelData)
                      readonly property bool active: usage.activeAccountId(accountSettingsContent.newProvider) === modelData
                      width: accountListContent.width
                      height: Math.max(accountRowText.implicitHeight, accountActions.implicitHeight) + Style.space(14)
                      radius: root.controlRadius
                      color: active ? root.alpha(Commons.Color.accent, 0.10) : root.alpha(root.foreground, 0.03)
                      border.width: 1
                      border.color: active ? root.alpha(Commons.Color.accent, 0.35) : root.alpha(root.foreground, 0.08)

                      Column {
                        id: accountRowText
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(10)
                        anchors.right: accountActions.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)

                        Text {
                          width: parent.width
                          text: configuredAccountRow.profile ? configuredAccountRow.profile.name : "Default login"
                          textFormat: Text.PlainText
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                          elide: Text.ElideRight
                        }

                        // Its live state when it has a record, then where it
                        // lives on disk.
                        Text {
                          width: parent.width
                          text: {
                            var live = configuredAccountRow.live
                            if (!configuredAccountRow.ready) return "Preparing its record…"
                            if (live && String(live.usageStatusText || "") !== "") return String(live.usageStatusText)
                            if (live && root.providerPercent(live) >= 0) return root.providerPercentText(live) + " used"
                              + (live.tierLabel ? " · " + live.tierLabel : "")
                            return configuredAccountRow.profile ? "Waiting for its first reading" : "The login the CLI uses by default"
                          }
                          textFormat: Text.PlainText
                          color: configuredAccountRow.live && String(configuredAccountRow.live.usageStatusText || "") !== ""
                            ? root.textFor(root.statusColor(configuredAccountRow.live)) : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }

                        Text {
                          visible: text !== ""
                          width: parent.width
                          text: configuredAccountRow.profile ? (configuredAccountRow.profile.path || "") : ""
                          textFormat: Text.PlainText
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideMiddle
                        }
                      }

                      Row {
                        id: accountActions
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        Button {

                          radius: root.controlRadius
                          id: loginButton
                          visible: !!configuredAccountRow.profile
                          text: enabled ? "Sign in" : "Preparing…"
                          tooltipText: "Open the provider's own browser login for this account"
                          enabled: configuredAccountRow.ready
                          bordered: true
                          foreground: root.foreground
                          fontFamily: root.fontFamily
                          fontSize: Style.font.caption
                          onClicked: root.loginToAccount(configuredAccountRow.modelData)
                        }

                        LaunchAccountButton {

                          radius: root.controlRadius
                          id: launchAccountButton
                          providerBrand: accountSettingsContent.newProvider
                          accountId: configuredAccountRow.modelData
                          enabled: configuredAccountRow.ready
                        }

                        Button {

                          radius: root.controlRadius
                          id: removeButton
                          visible: !!configuredAccountRow.profile
                          width: Style.space(28)
                          horizontalPadding: 0
                          iconText: "󰩺"
                          iconSize: Style.font.body
                          tooltipText: "Remove from the widget; the CLI login directory stays on disk"
                          bordered: true
                          foreground: root.foreground
                          fontFamily: root.fontFamily
                          onClicked: usage.removeAccount(configuredAccountRow.modelData)
                        }
                      }
                    }
                  }
                }
              }

              BorderSurface {
                width: parent.width
                implicitHeight: addAccountContent.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: addAccountContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(10)

                  CardTitle {
                    width: parent.width
                    glyph: "󰐙"
                    text: "New login"
                  }

                  Text {
                    width: parent.width
                    text: "Name it, add it, then use Sign in on its row. It gets its own CLI home, so it never touches the default login."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Rectangle {
                      width: parent.width - addAccountButton.width - parent.spacing
                      height: Style.space(32)
                      radius: root.controlRadius
                      color: root.alpha(root.foreground, 0.06)
                      border.width: 1
                      border.color: accountNameInput.activeFocus ? Commons.Color.accent : root.alpha(root.foreground, 0.2)

                      TextInput {
                        id: accountNameInput
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        color: root.foreground
                        selectionColor: root.alpha(Commons.Color.accent, 0.4)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        maximumLength: 80
                        onAccepted: accountSettingsContent.addNewAccount()

                        Text {
                          visible: accountNameInput.text === "" && !accountNameInput.activeFocus
                          anchors.verticalCenter: parent.verticalCenter
                          text: accountSettingsContent.providerLabel + " account name, e.g. Work"
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }
                    }

                    Button {

                      radius: root.controlRadius
                      id: addAccountButton
                      height: Style.space(32)
                      text: "Add"
                      enabled: accountNameInput.text.trim().length > 0
                      selected: enabled
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      horizontalPadding: Style.space(14)
                      onClicked: accountSettingsContent.addNewAccount()
                    }
                  }
                }
              }

              BorderSurface {
                width: parent.width
                implicitHeight: importAccountContent.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: importAccountContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(10)

                  CardTitle {
                    width: parent.width
                    glyph: "󱃩"
                    text: "Import existing logins"
                  }

                  Text {
                    width: parent.width
                    text: "One CLI home per line (~/ works). A parent folder imports each account inside it. Only filenames are inspected; nothing is copied."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(72)
                    radius: root.controlRadius
                    color: root.alpha(root.foreground, 0.06)
                    border.width: 1
                    border.color: accountPathsInput.activeFocus ? Commons.Color.accent : root.alpha(root.foreground, 0.2)

                    TextEdit {
                      id: accountPathsInput
                      anchors.fill: parent
                      anchors.margins: Style.space(10)
                      clip: true
                      color: root.foreground
                      selectionColor: root.alpha(Commons.Color.accent, 0.4)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      textFormat: TextEdit.PlainText
                      wrapMode: TextEdit.WrapAnywhere
                      selectByMouse: true

                      Text {
                        visible: accountPathsInput.text === "" && !accountPathsInput.activeFocus
                        width: parent.width
                        text: accountSettingsContent.newProvider === "claude" ? "~/.claude-work\n~/.claude-accounts/" : "~/.codex-work\n~/.codex-accounts/"
                        wrapMode: Text.WordWrap
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(10)

                    Button {

                      radius: root.controlRadius
                      id: importAccountsButton
                      anchors.verticalCenter: parent.verticalCenter
                      text: usage.accountImportRunning ? "Importing…" : "Import"
                      enabled: accountPathsInput.text.trim().length > 0 && !usage.accountImportRunning
                      selected: enabled
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      horizontalPadding: Style.space(14)
                      onClicked: usage.importAccounts(accountSettingsContent.newProvider, accountPathsInput.text)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - importAccountsButton.width - parent.spacing
                      visible: usage.accountImportStatus !== ""
                      text: usage.accountImportStatus
                      textFormat: Text.PlainText
                      wrapMode: Text.WordWrap
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }

            // ============================================= Display tab
            Column {
              visible: root.settingsTab === "display"
              width: parent.width
              spacing: Style.space(10)

              BorderSurface {
                width: parent.width
                implicitHeight: displayContent.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: displayContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(12)

                  CardTitle {
                    width: parent.width
                    glyph: "󰛐"
                    text: "Appearance"
                  }

                  SettingToggle {
                    width: parent.width
                    title: "Show available quota"
                    description: "Percentages, meters and warning values count down what is left instead of up to what is used. Trigger points stay the same."
                    checked: usage.showAvailablePercentage
                    onToggled: usage.setShowAvailablePercentage(!usage.showAvailablePercentage)
                  }

                  SettingToggle {
                    width: parent.width
                    title: "Color-code meters"
                    description: "Green, amber and red for Healthy, Warn and Critical. Off keeps meters in your theme's colors."
                    checked: usage.colorfulUsageMeters
                    onToggled: usage.setColorfulUsageMeters(!usage.colorfulUsageMeters)
                  }

                  SettingToggle {
                    width: parent.width
                    title: "Open on Activity"
                    description: "Start every opening on the Activity view (calendar and trend) instead of Usage."
                    checked: usage.openInDetailedView
                    onToggled: usage.setOpenInDetailedView(!usage.openInDetailedView)
                  }
                }
              }

              BorderSurface {
                width: parent.width
                implicitHeight: refreshContent.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: refreshContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(10)

                  CardTitle {
                    width: parent.width
                    glyph: "󰅐"
                    text: "Refresh"
                    note: "every " + root.formatSeconds(settingsDraft.refreshIntervalSec)
                  }

                  NumberField {
                    width: parent.width
                    fieldWidth: width
                    label: "Collect usage every (seconds)"
                    value: settingsDraft.refreshIntervalSec
                    from: 30
                    to: 3600
                    stepSize: 30
                    foreground: root.foreground
                    accent: Commons.Color.accent
                    fontFamily: root.fontFamily
                    onModified: function(v) { settingsDraft.refreshIntervalSec = v }
                  }

                  Text {
                    width: parent.width
                    text: "Opening the panel always refreshes limits, and the refresh button (or r) runs every collector at once."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            // ============================================== Alerts tab
            Column {
              visible: root.settingsTab === "alerts"
              width: parent.width
              spacing: Style.space(10)

              BorderSurface {
                width: parent.width
                implicitHeight: thresholdContent.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: thresholdContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(12)

                  CardTitle {
                    width: parent.width
                    glyph: "󰓅"
                    text: "Thresholds"
                    note: settingsDraft.showsAvailable ? "available quota" : "quota used"
                  }

                  // The three zones a meter passes through, drawn from the
                  // draft values so the effect of an edit is visible before
                  // Save. In available mode the scale runs the other way.
                  Item {
                    id: thresholdScale
                    width: parent.width
                    height: Style.space(34)

                    readonly property real warnUsed: settingsDraft.showsAvailable
                      ? 1 - settingsDraft.warnThresholdPct / 100 : settingsDraft.warnThresholdPct / 100
                    readonly property real criticalUsed: settingsDraft.showsAvailable
                      ? 1 - settingsDraft.criticalThresholdPct / 100 : settingsDraft.criticalThresholdPct / 100
                    function xFor(used) {
                      var p = root.clamp(used, 0, 1)
                      return (settingsDraft.showsAvailable ? 1 - p : p) * width
                    }

                    Item {
                      id: zoneTrack
                      width: parent.width
                      height: Style.space(10)
                      clip: true

                      Rectangle {
                        anchors.fill: parent
                        radius: height / 2
                        color: root.track
                      }

                      Rectangle {
                        x: Math.min(thresholdScale.xFor(0), thresholdScale.xFor(thresholdScale.warnUsed))
                        width: Math.abs(thresholdScale.xFor(thresholdScale.warnUsed) - thresholdScale.xFor(0))
                        height: parent.height
                        color: usage.colorfulUsageMeters ? root.colorForSeverity("ok") : Commons.Color.accent
                        opacity: 0.55
                      }

                      Rectangle {
                        x: Math.min(thresholdScale.xFor(thresholdScale.warnUsed), thresholdScale.xFor(thresholdScale.criticalUsed))
                        width: Math.abs(thresholdScale.xFor(thresholdScale.criticalUsed) - thresholdScale.xFor(thresholdScale.warnUsed))
                        height: parent.height
                        color: root.warn
                        visible: thresholdScale.criticalUsed > thresholdScale.warnUsed
                      }

                      Rectangle {
                        x: Math.min(thresholdScale.xFor(thresholdScale.criticalUsed), thresholdScale.xFor(1))
                        width: Math.abs(thresholdScale.xFor(1) - thresholdScale.xFor(thresholdScale.criticalUsed))
                        height: parent.height
                        color: root.colorForSeverity("critical")
                      }
                    }

                    Repeater {
                      model: [
                        { used: thresholdScale.warnUsed, label: settingsDraft.warnThresholdPct + "%", tone: "warn" },
                        { used: thresholdScale.criticalUsed, label: settingsDraft.criticalThresholdPct + "%", tone: "critical" }
                      ]

                      Text {
                        required property var modelData
                        y: zoneTrack.height + Style.space(4)
                        // Warn's label ends at its tick and Critical's starts
                        // at its own, on the sides facing away from each
                        // other, so close values never print on top of
                        // one another.
                        readonly property bool before: (modelData.tone === "warn") !== settingsDraft.showsAvailable
                        x: root.clamp(before
                            ? thresholdScale.xFor(modelData.used) - implicitWidth - Style.space(3)
                            : thresholdScale.xFor(modelData.used) + Style.space(3),
                          0, Math.max(0, thresholdScale.width - implicitWidth))
                        text: modelData.label
                        color: modelData.tone === "warn" ? root.warnText : root.textFor(root.colorForSeverity("critical"))
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(12)

                    NumberField {
                      width: (parent.width - parent.spacing) / 2
                      fieldWidth: width
                      label: settingsDraft.showsAvailable ? "Warn below (% left)" : "Warn at (% used)"
                      value: settingsDraft.warnThresholdPct
                      from: 1
                      to: 99
                      stepSize: 1
                      foreground: root.foreground
                      accent: root.warn
                      fontFamily: root.fontFamily
                      onModified: function(v) { settingsDraft.warnThresholdPct = v }
                    }

                    NumberField {
                      width: (parent.width - parent.spacing) / 2
                      fieldWidth: width
                      label: settingsDraft.showsAvailable ? "Critical below (% left)" : "Critical at (% used)"
                      value: settingsDraft.criticalThresholdPct
                      from: settingsDraft.showsAvailable ? 0 : 1
                      to: settingsDraft.showsAvailable ? 99 : 100
                      stepSize: 1
                      foreground: root.foreground
                      accent: root.urgent
                      fontFamily: root.fontFamily
                      onModified: function(v) { settingsDraft.criticalThresholdPct = v }
                    }
                  }

                  Text {
                    width: parent.width
                    // One fixed line, never appearing/disappearing: it swaps
                    // between the normal hint and the validation error so
                    // nothing below it jumps when Warn/Critical cross.
                    text: settingsDraft.thresholdsValid
                      ? (settingsDraft.showsAvailable
                        ? "Warn when available quota falls this low; Critical marks the lower, urgent level."
                        : "Warn colors a meter early; Critical marks it urgent and lights the bar.")
                      : (settingsDraft.showsAvailable
                        ? "Warn must stay above Critical — Save is disabled until that's fixed."
                        : "Warn must stay below Critical — Save is disabled until that's fixed.")
                    color: settingsDraft.thresholdsValid ? root.dim : root.textFor(root.urgent)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }

              BorderSurface {
                width: parent.width
                implicitHeight: notifyContent.implicitHeight + Style.space(28)
                color: root.alpha(root.foreground, 0.035)
                borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
                radius: root.cardRadius

                Column {
                  id: notifyContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(14)
                  anchors.rightMargin: Style.space(14)
                  spacing: Style.space(12)

                  CardTitle {
                    width: parent.width
                    glyph: "󰂜"
                    text: "Notifications"
                  }

                  // Notifications are opt-in and fire once at each
                  // threshold, not on every refresh.
                  SettingToggle {
                    width: parent.width
                    title: "Threshold alerts"
                    description: "One desktop notification when a provider crosses Warn, and one more at Critical."
                    checked: usage.notificationsEnabled
                    onToggled: usage.setNotificationsEnabled(!usage.notificationsEnabled)
                  }

                  // Test stays independent of the toggle and reports its
                  // process result beside the button.
                  Row {
                    spacing: Style.space(10)

                    Button {

                      radius: root.controlRadius
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Send a test"
                      tooltipText: "Send one notification now — independent of the toggle above."
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.bodySmall
                      horizontalPadding: Style.space(12)
                      verticalPadding: Style.space(5)
                      onClicked: root.sendTestNotification()
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.notificationTestStatus
                      color: text === "Failed" ? root.textFor(root.urgent) : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    width: parent.width
                    text: "Nothing showing up? Omarchy's Do Not Disturb hides the popup; delivered alerts still land in notification history."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            // =========================================== Sync tab
            // The panel never syncs anything itself — it only reads and
            // writes one JSON snapshot per machine into this folder. Combine
            // usage across machines by pointing every one of them at the
            // same folder that's already kept identical some other way
            // (Syncthing, Nextcloud, a network mount — anything works).
            BorderSurface {
              id: syncSection
              visible: root.settingsTab === "sync"
              width: parent.width
              implicitHeight: syncContent.implicitHeight + Style.space(28)
              color: root.alpha(root.foreground, 0.035)
              borderSpec: Border.flat(root.alpha(root.foreground, 0.12), 1)
              radius: root.cardRadius

              Column {
                id: syncContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(14)
                spacing: Style.space(12)

                // Same draft pattern as settingsDraft: the folder path only
                // ever changes here or on Save, so a keystroke in progress
                // can't be clobbered by a periodic settings reload.
                property string draftSyncDir: usage.syncDir
                readonly property bool syncDirDirty: draftSyncDir !== usage.syncDir

                function resyncDraft() { draftSyncDir = usage.syncDir }
                function saveDraft() { usage.setSyncDir(draftSyncDir) }

                CardTitle {
                  width: parent.width
                  glyph: "󰓦"
                  text: "Multi-device sync"
                  note: usage.syncEnabled ? "on" : "off"
                }

                SettingToggle {
                  width: parent.width
                  title: "Combine machines"
                  description: "Add up today's tokens and history from every machine that shares one already-synced folder (Syncthing, Nextcloud, a network mount). This panel only reads and writes its own snapshot there — it never does the syncing."
                  checked: usage.syncEnabled
                  onToggled: usage.setSyncEnabled(!usage.syncEnabled)
                }

                Column {
                  visible: usage.syncEnabled
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: "Sync folder"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Rectangle {
                    width: parent.width
                    height: Style.space(32)
                    radius: root.controlRadius
                    color: root.alpha(root.foreground, 0.06)
                    border.width: 1
                    border.color: syncDirInput.activeFocus ? Commons.Color.accent : root.alpha(root.foreground, 0.2)

                    TextInput {
                      id: syncDirInput
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(10)
                      anchors.rightMargin: Style.space(10)
                      verticalAlignment: TextInput.AlignVCenter
                      clip: true
                      color: root.foreground
                      selectionColor: root.alpha(Commons.Color.accent, 0.4)
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

                  Text {
                    width: parent.width
                    text: "Use the same folder on every machine. Enter or Save applies it."
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                // Live status, with a colored dot so the state reads at a
                // glance: accent when merging, amber while waiting.
                Row {
                  visible: usage.syncEnabled
                  width: parent.width
                  spacing: Style.space(8)

                  readonly property bool merging: usage.aggregateData && usage.aggregateData.deviceCount > 1
                    && usage.syncStatusText === ""

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(8)
                    height: width
                    radius: width / 2
                    color: parent.merging ? Commons.Color.accent : root.warn
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(16)
                    text: String(usage.syncDir || "").trim() === ""
                      ? "Set a folder above, then Save, to start writing this device's snapshot."
                      : (usage.syncStatusText !== "" ? usage.syncStatusText
                        : (usage.aggregateData && usage.aggregateData.deviceCount > 1
                          ? "Merged from " + usage.aggregateData.deviceCount + " devices"
                          : "Waiting for another device to write into this folder…"))
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            // Room for the pinned save bar so it never covers the last card.
            Item {
              width: parent.width
              height: saveBar.visible ? saveBar.height + Style.space(4) : 0
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

      // Pinned to the bottom of the card while Settings holds unsaved
      // numeric or folder edits, whichever tab they were made on.
      Rectangle {
        id: saveBar
        readonly property bool pending: settingsDraft.dirty || syncContent.syncDirDirty
        readonly property bool valid: !settingsDraft.thresholdsDirty || settingsDraft.thresholdsValid
        visible: root.settingsOpen && pending
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(46)
        radius: root.cardRadius
        color: root.mix(root.surface, Commons.Color.accent, 0.10)
        border.width: 1
        border.color: root.alpha(Commons.Color.accent, 0.45)

        Row {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: width
            radius: width / 2
            color: saveBar.valid ? root.warn : root.urgent
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: saveBar.valid ? "Unsaved changes" : "Fix the thresholds to save"
            color: saveBar.valid ? root.foreground : root.textFor(root.urgent)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Button {

            radius: root.controlRadius
            text: "Discard"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(12)
            verticalPadding: Style.space(5)
            onClicked: {
              settingsDraft.resyncDrafts()
              syncContent.resyncDraft()
            }
          }

          Button {

            radius: root.controlRadius
            text: "Save"
            enabled: saveBar.valid
            selected: true
            bordered: true
            foreground: root.foreground
            accent: Commons.Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.space(16)
            verticalPadding: Style.space(5)
            onClicked: {
              settingsDraft.saveDrafts()
              if (syncContent.syncDirDirty) syncContent.saveDraft()
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------- settings parts

  component LaunchAccountButton: Button {
    id: launchAccount
    radius: root.controlRadius
    required property string providerBrand
    required property string accountId

    width: Style.space(68)
    text: selected ? "Active" : "Use"
    tooltipText: selected ? "Active account for the bar and CLI launch" : "Use this account in the bar and for CLI launch"
    selected: usage.activeAccountId(providerBrand) === accountId
    bordered: true
    focusable: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    onClicked: if (!selected) usage.selectAccount(launchAccount.providerBrand, launchAccount.accountId)
  }

  // A row label on the left, any control (the default child) on the right.
  component SettingLine: Item {
    id: settingLine
    property string title: ""
    // The control column has an explicit width; children fill it with
    // `width: parent.width`. (Sizing it from childrenRect made a child that
    // sized itself from its parent collapse to zero.)
    property real controlWidth: Math.min(Style.space(236), width * 0.66)
    default property alias control: settingLineControl.data

    implicitHeight: Math.max(settingLineTitle.implicitHeight, settingLineControl.height)

    Text {
      id: settingLineTitle
      anchors.left: parent.left
      anchors.right: settingLineControl.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: settingLine.title
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Item {
      id: settingLineControl
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: settingLine.controlWidth
      height: childrenRect.height
    }
  }

  // A labelled switch with a sentence of explanation underneath. The whole
  // row toggles, not only the small knob.
  component SettingToggle: Item {
    id: settingToggle
    property string title: ""
    property string description: ""
    property bool checked: false
    signal toggled()

    implicitHeight: Math.max(settingToggleText.implicitHeight, settingToggleSwitch.implicitHeight)

    Column {
      id: settingToggleText
      anchors.left: parent.left
      anchors.right: settingToggleSwitch.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: settingToggle.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
      }

      Text {
        visible: settingToggle.description !== ""
        width: parent.width
        text: settingToggle.description
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        lineHeight: 1.1
      }
    }

    MouseArea {
      anchors.fill: settingToggleText
      cursorShape: Qt.PointingHandCursor
      onClicked: settingToggle.toggled()
    }

    ToggleSwitch {

      rounded: true
      id: settingToggleSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: settingToggle.checked
      foreground: root.foreground
      accent: Commons.Color.accent
      onToggled: settingToggle.toggled()
    }
  }

  // A pill-shaped segmented control: one choice of a few, the current one
  // filled in the accent tint. `options` is [{ value, label, tip }].
  component Segmented: Rectangle {
    id: segmented
    property var options: []
    property string current: ""
    signal picked(string value)

    implicitHeight: Style.space(28)
    height: implicitHeight
    radius: root.controlRadius
    color: root.alpha(root.foreground, 0.05)
    border.width: 1
    border.color: root.alpha(root.foreground, 0.12)

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(2)
      spacing: Style.space(2)

      Repeater {
        model: segmented.options

        Rectangle {
          id: segment
          required property var modelData
          readonly property bool chosen: segmented.current === modelData.value
          width: (segmented.width - Style.space(4) - Style.space(2) * Math.max(0, segmented.options.length - 1))
            / Math.max(1, segmented.options.length)
          height: parent.height
          radius: root.controlRadius - Style.space(2)
          color: chosen ? root.alpha(Commons.Color.accent, 0.22)
            : (segmentHover.containsMouse && segmented.enabled ? root.alpha(root.foreground, 0.07) : "transparent")
          border.width: chosen ? 1 : 0
          border.color: root.alpha(Commons.Color.accent, 0.55)

          Behavior on color { ColorAnimation { duration: 110 } }

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(6)
            horizontalAlignment: Text.AlignHCenter
            text: segment.modelData.label
            color: segment.chosen ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: segment.chosen
            elide: Text.ElideRight
          }

          MouseArea {
            id: segmentHover
            anchors.fill: parent
            hoverEnabled: true
            enabled: segmented.enabled
            cursorShape: Qt.PointingHandCursor
            onClicked: if (!segment.chosen) segmented.picked(segment.modelData.value)
          }

          PanelToolTip {
            visible: segmentHover.containsMouse && String(segment.modelData.tip || "") !== ""
            text: String(segment.modelData.tip || "")
            fontFamily: root.fontFamily
          }
        }
      }
    }
  }

  // One limit window as a ring, with its reset underneath: countdown,
  // wall-clock time and the outlook at the current rate.
  // `creditMode` draws a prepaid balance's credit left instead.
  component RingTile: Item {
    id: ringTile
    property var window: null
    property bool creditMode: false
    property color tint: Commons.Color.accent
    readonly property var pace: creditMode ? null : root.paceFor(window)
    readonly property bool stale: !creditMode && root.windowIsStale(window)
    readonly property bool hasValue: creditMode ? (!!root.balance && root.balance.funded > 0) : (!!window && window.percent >= 0)
    readonly property real ringValue: creditMode
      ? (hasValue ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1) : 0)
      : (hasValue ? root.displayPercent(window.percent) : 0)
    readonly property color ringColor: creditMode ? root.colorForSeverity(root.balanceSeverity) === root.foreground
      ? Commons.Color.accent : root.colorForSeverity(root.balanceSeverity) : tint
    readonly property real resetMs: creditMode ? -1 : root.resetMsFor(window)
    readonly property var resetParts: root.momentParts(resetMs > 0 ? root.nowMs + resetMs : NaN)
    readonly property bool full: !creditMode && hasValue && window.percent >= 1
    readonly property bool runsOut: !full && !stale && resetMs > 0 && !!pace && pace.runsOutInMs >= 0
    readonly property string resetLead: stale ? "Window reset" : (resetMs > 0 ? (full ? "Back in" : "Resets in") : "No reset reported")
    readonly property string resetValue: !stale && resetMs > 0 ? root.formatDuration(resetMs) : ""
    readonly property string resetWhen: stale ? "updates on the next refresh"
      : (resetParts.day !== "" ? resetParts.day + " " + resetParts.clock : "")
    readonly property string outlook: {
      if (creditMode || stale || full || !pace) return ""
      if (runsOut) return "Runs out " + root.formatDuration(Math.max(0, resetMs - pace.runsOutInMs)) + " before reset"
      if (pace.status === "idle" || !(pace.projected >= 0)) return ""
      var used = Math.min(99, Math.round(pace.projected * 100))
      return usage.showAvailablePercentage ? "~" + (100 - used) + "% left at reset" : "~" + used + "% used by reset"
    }
    readonly property string detail: {
      if (creditMode || !window) return ""
      var lines = [String(window.title || "Limit") + " · " + Format.formatPercent(window.percent, usage.showAvailablePercentage)
        + (usage.showAvailablePercentage ? " left" : " used")]
      if (resetWhen !== "" && !stale) lines.push("Resets " + resetWhen)
      if (runsOut) {
        var at = root.momentParts(root.nowMs + pace.runsOutInMs)
        lines.push("At this rate it empties " + at.day + " " + at.clock)
      }
      if (pace && pace.elapsed >= 0 && !stale) lines.push(Math.round(pace.elapsed * 100) + "% of the window has passed (the dot on the ring)")
      return lines.join("\n")
    }

    implicitHeight: ringTileColumn.implicitHeight

    Column {
      id: ringTileColumn
      width: parent.width
      spacing: Style.space(6)

      Item {
        width: parent.width
        height: Style.space(100)

        RingGauge {
          id: tileGauge
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.height
          height: parent.height
          value: ringTile.ringValue
          marker: ringTile.pace ? root.displayPercent(ringTile.pace.elapsed) : -1
          color: ringTile.ringColor
          thickness: Style.space(9)
          opacity: ringTile.stale ? 0.5 : 1.0
        }

        Column {
          anchors.centerIn: tileGauge
          spacing: 0

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: !ringTile.hasValue ? "—"
              : (ringTile.creditMode ? Math.round(ringTile.ringValue * 100) + "%"
                : Format.formatPercent(ringTile.window.percent, usage.showAvailablePercentage))
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Math.round(Style.font.display * 0.95)
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: ringTile.creditMode ? "credit left" : (usage.showAvailablePercentage ? "left" : "used")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(7)
          height: width
          radius: width / 2
          color: ringTile.ringColor
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: ringTile.creditMode ? "Prepaid credit" : (ringTile.window ? String(ringTile.window.title || "Limit") : "")
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.capitalization: Font.AllUppercase
          font.letterSpacing: 0.8
          elide: Text.ElideRight
          width: Math.min(implicitWidth, ringTile.width - Style.space(14))
        }
      }

      // When this window hands its room back (the one place the panel
      // says so) and, under it, how the current rate compares with that.
      Column {
        visible: !ringTile.creditMode
        width: parent.width
        spacing: Style.space(2)

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(4)

          Text {
            anchors.baseline: resetValueText.baseline
            text: ringTile.resetLead
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: resetValueText
            visible: text !== ""
            text: ringTile.resetValue
            textFormat: Text.PlainText
            color: ringTile.full ? root.textFor(root.urgent) : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: ringTile.resetWhen
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Always one line tall, so both tiles keep the same height
        // whatever their outlook says.
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: ringTile.outlook
          textFormat: Text.PlainText
          color: ringTile.runsOut ? root.warnText : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: ringTile.runsOut
        }
      }
    }

    MouseArea {
      id: ringTileHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: ringTileHover.containsMouse && text !== ""
      text: ringTile.detail
      fontFamily: root.fontFamily
    }
  }

  // A row of equal tabs with a glyph and label each; the current one is
  // filled in the accent tint. `tabs` is [{ id, label, glyph }]; `badges`
  // maps a tab id to true to mark it (unsaved edits, for example).
  component TabStrip: Rectangle {
    id: tabStrip
    property var tabs: []
    property string current: ""
    property var badges: ({})
    signal picked(string id)

    // Glyphs show on every tab or on none: the widest label decides.
    readonly property real cellWidth: (width - Style.space(6) - Style.space(3) * Math.max(0, tabs.length - 1))
      / Math.max(1, tabs.length)
    readonly property string longestLabel: {
      var longest = ""
      for (var i = 0; i < tabs.length; i++)
        if (String(tabs[i].label).length > longest.length) longest = String(tabs[i].label)
      return longest
    }
    readonly property bool showGlyphs: cellWidth >= tabLabelMetrics.advanceWidth + Style.font.body + Style.space(20)

    TextMetrics {
      id: tabLabelMetrics
      text: tabStrip.longestLabel
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    height: Style.space(34)
    radius: root.cardRadius
    color: root.alpha(root.foreground, 0.05)
    border.width: 1
    border.color: root.alpha(root.foreground, 0.10)

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(3)
      spacing: Style.space(3)

      Repeater {
        model: tabStrip.tabs

        Rectangle {
          id: tabCell
          required property var modelData
          readonly property bool chosen: tabStrip.current === modelData.id
          width: tabStrip.cellWidth
          height: parent.height
          radius: root.controlRadius
          color: chosen ? root.alpha(Commons.Color.accent, 0.18)
            : (tabCellHover.containsMouse ? root.alpha(root.foreground, 0.06) : "transparent")
          border.width: chosen ? 1 : 0
          border.color: root.alpha(Commons.Color.accent, 0.45)

          Behavior on color { ColorAnimation { duration: 120 } }

          Row {
            anchors.centerIn: parent
            spacing: Style.space(5)

            // The glyphs give way (all together) when five tabs share a
            // narrow row, so no label has to be cut.
            Text {
              id: tabCellGlyph
              anchors.verticalCenter: parent.verticalCenter
              text: tabCell.modelData.glyph || ""
              visible: text !== "" && tabStrip.showGlyphs
              color: tabCell.chosen ? root.accentText : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: tabCellLabel
              anchors.verticalCenter: parent.verticalCenter
              text: tabCell.modelData.label
              color: tabCell.chosen ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: tabCell.chosen
            }
          }

          Rectangle {
            visible: !!tabStrip.badges[tabCell.modelData.id]
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Style.space(4)
            width: Style.space(6)
            height: width
            radius: width / 2
            color: root.warn
          }

          MouseArea {
            id: tabCellHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tabStrip.picked(tabCell.modelData.id)
          }
        }
      }
    }
  }

  // ------------------------------------------------------- dashboard parts

  // A 270° gauge, open at the bottom: the fullest limit window at a glance.
  // `marker` is where the window's clock stands (same 0-1 scale as value),
  // drawn as a small dot on the track so "used vs elapsed" reads without a
  // second number.
  component RingGauge: Canvas {
    id: ring
    property real value: 0
    property real marker: -1
    property color color: root.foreground
    property color trackColor: root.track
    property color markerColor: root.foreground
    property real thickness: Style.space(9)
    property real shownValue: root.clamp(value, 0, 1)

    Behavior on shownValue {
      NumberAnimation { duration: 650; easing.type: Easing.OutCubic }
    }

    // Repaint on a live theme switch: onPaint reads these root colors
    // directly, and Canvas does not track them on its own.
    readonly property string themeKey: [root.foreground, root.surface, root.track, root.dim, root.fontFamily].join("|")
    onThemeKeyChanged: requestPaint()
    onShownValueChanged: requestPaint()
    onMarkerChanged: requestPaint()
    onMarkerColorChanged: requestPaint()
    onColorChanged: requestPaint()
    onTrackColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      try {
        ctx.reset()
        if (width <= 0 || height <= 0) return
        var r = Math.min(width, height) / 2 - ring.thickness / 2 - 1
        if (r <= 0) return
        var cx = width / 2
        var cy = height / 2
        var start = Math.PI * 0.75
        var sweep = Math.PI * 1.5
        ctx.lineCap = "round"
        ctx.lineWidth = ring.thickness

        ctx.strokeStyle = ring.trackColor
        ctx.beginPath()
        ctx.arc(cx, cy, r, start, start + sweep, false)
        ctx.stroke()

        if (ring.shownValue > 0.001) {
          var end = start + sweep * ring.shownValue
          // A soft wider underlay reads as a glow without a blur pass.
          ctx.strokeStyle = Qt.rgba(ring.color.r, ring.color.g, ring.color.b, 0.18)
          ctx.lineWidth = ring.thickness + Style.space(6)
          ctx.beginPath()
          ctx.arc(cx, cy, r, start, end, false)
          ctx.stroke()

          var gradient = ctx.createLinearGradient(cx - r, cy + r, cx + r, cy - r)
          gradient.addColorStop(0, Qt.rgba(ring.color.r, ring.color.g, ring.color.b, 0.55))
          gradient.addColorStop(1, ring.color)
          ctx.strokeStyle = gradient
          ctx.lineWidth = ring.thickness
          ctx.beginPath()
          ctx.arc(cx, cy, r, start, end, false)
          ctx.stroke()
        }

        if (ring.marker >= 0) {
          var angle = start + sweep * root.clamp(ring.marker, 0, 1)
          var mx = cx + Math.cos(angle) * r
          var my = cy + Math.sin(angle) * r
          ctx.fillStyle = root.surface
          ctx.beginPath()
          ctx.arc(mx, my, ring.thickness * 0.42 + 1.5, 0, Math.PI * 2)
          ctx.fill()
          ctx.fillStyle = ring.markerColor
          ctx.beginPath()
          ctx.arc(mx, my, ring.thickness * 0.42, 0, Math.PI * 2)
          ctx.fill()
        }
      } catch (e) {
        // A gauge that fails to paint leaves an empty square, never a
        // broken panel.
      }
    }
  }

  // Thin full-circle progress ring drawn around a provider chip's mark, so
  // the switcher doubles as an every-account overview.
  component ChipRing: Canvas {
    id: chipRing
    property real value: -1
    property color color: root.foreground
    property real thickness: Math.max(2, Style.space(2.5))

    // Repaint on a live theme switch: onPaint reads these root colors
    // directly, and Canvas does not track them on its own.
    readonly property string themeKey: [root.foreground, root.surface, root.track, root.dim, root.fontFamily].join("|")
    onThemeKeyChanged: requestPaint()
    onValueChanged: requestPaint()
    onColorChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onVisibleChanged: if (visible) requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      try {
        ctx.reset()
        if (width <= 0 || height <= 0) return
        var r = Math.min(width, height) / 2 - chipRing.thickness / 2 - 0.5
        var cx = width / 2
        var cy = height / 2
        ctx.lineWidth = chipRing.thickness
        ctx.lineCap = "round"
        ctx.strokeStyle = root.alpha(root.foreground, 0.10)
        ctx.beginPath()
        ctx.arc(cx, cy, r, 0, Math.PI * 2, false)
        ctx.stroke()
        if (chipRing.value > 0.001) {
          ctx.strokeStyle = chipRing.color
          ctx.beginPath()
          ctx.arc(cx, cy, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * root.clamp(chipRing.value, 0, 1), false)
          ctx.stroke()
        }
      } catch (e) {
      }
    }
  }

  // A compact number card: glyph + label, a large value, and a one-line hint.
  component StatTile: BorderSurface {
    id: statTile
    property string glyph: ""
    property string label: ""
    property string valueText: ""
    property string hint: ""
    property color hintColor: root.dim
    property color glyphColor: root.accentText
    property string tooltipText: ""

    implicitHeight: tileContent.implicitHeight + Style.space(20)
    color: root.alpha(root.foreground, 0.035)
    borderSpec: Border.flat(root.alpha(root.foreground, 0.10), 1)
    radius: root.cardRadius

    Column {
      id: tileContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(3)

      Row {
        spacing: Style.space(5)
        width: parent.width

        Text {
          visible: statTile.glyph !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: statTile.glyph
          color: statTile.glyphColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - x
          text: statTile.label
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.capitalization: Font.AllUppercase
          font.letterSpacing: 0.6
          elide: Text.ElideRight
        }
      }

      Text {
        width: parent.width
        text: statTile.valueText
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.subtitle * 1.3)
        font.bold: true
        elide: Text.ElideRight
      }

      // Always present (blank when there is no hint) so tiles in one row
      // keep the same height.
      Text {
        width: parent.width
        text: statTile.hint !== "" ? statTile.hint : " "
        textFormat: Text.PlainText
        color: statTile.hintColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: tileHover
      anchors.fill: parent
      hoverEnabled: statTile.tooltipText !== ""
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: tileHover.containsMouse && statTile.tooltipText !== ""
      text: statTile.tooltipText
      fontFamily: root.fontFamily
    }
  }

  // Section card title: an accent glyph, an uppercase caption, and an
  // optional right-aligned note.
  component CardTitle: Item {
    id: cardTitle
    property string glyph: ""
    property string text: ""
    property string note: ""

    implicitHeight: Math.max(cardTitleLabel.implicitHeight, cardTitleNote.implicitHeight)

    Row {
      anchors.left: parent.left
      anchors.right: cardTitleNote.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Text {
        visible: cardTitle.glyph !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: cardTitle.glyph
        color: root.accentText
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: cardTitleLabel
        anchors.verticalCenter: parent.verticalCenter
        text: cardTitle.text
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.8
      }
    }

    Text {
      id: cardTitleNote
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: cardTitle.note
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // A limit window: label and percentage, meter with the window's clock
  // marked on it, reset countdown, and how the window is pacing.
  component LimitRow: Column {
    id: limitRow
    property var window: null
    opacity: root.windowIsStale(window) ? 0.6 : 1.0

    readonly property string severity: window ? root.severityForPercent(window.percent) : "ok"
    readonly property var pace: root.paceFor(window)
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
        color: limitRow.severity === "ok" ? root.foreground : root.textFor(root.colorForSeverity(limitRow.severity))
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: limitRow.window && limitRow.window.percent >= 0
        ? root.displayPercent(limitRow.window.percent) : -1
      // Where the clock stands in this window. In used mode, fill past the
      // tick means the allowance is going faster than time; in available
      // mode both run down, so fill short of the tick means the same.
      marker: limitRow.pace ? root.displayPercent(limitRow.pace.elapsed) : -1
      severity: limitRow.severity
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(resetText.implicitHeight, paceLabel.implicitHeight)
      visible: resetText.text !== "" || paceLabel.text !== ""

      Text {
        id: resetText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (root.windowIsStale(limitRow.window)) return "Reset passed · updates on the next refresh"
          var remainingMs = root.resetMsFor(limitRow.window)
          return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        id: paceLabel
        anchors.right: parent.right
        anchors.left: resetText.right
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        // One projection per row: a real token quota (the trend line
        // below) outranks the window's percentage rate.
        text: root.paceText(limitRow.paceProjection ? root.withoutRunOut(limitRow.pace) : limitRow.pace)
        textFormat: Text.PlainText
        color: root.paceColor(limitRow.paceProjection ? root.withoutRunOut(limitRow.pace) : limitRow.pace)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      visible: !!limitRow.paceProjection && limitRow.paceProjection.exhaustsBeforeReset
      width: parent.width
      text: (limitRow.paceProjection && limitRow.paceProjection.exhaustsBeforeReset)
        ? "Token trend: exhausted in " + root.formatDuration(limitRow.paceProjection.untilExhaustionMs) : ""
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used, with an
  // optional tick for where the window's clock stands.
  component Meter: Item {
    id: meter
    property real value: -1
    property real marker: -1
    property string severity: "ok"
    property real thickness: Math.max(Style.space(6), Math.round(Style.spacing.controlHeight * 0.2))

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
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: root.alpha(root.colorForSeverity(meter.severity), 0.6) }
        GradientStop { position: 1; color: root.colorForSeverity(meter.severity) }
      }

      Behavior on width {
        NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
      }
    }

    // The clock tick: a foreground bar on a surface-colored halo, so it
    // reads on the fill and on the empty track alike. (A bordered 2px
    // Rectangle painted only its border, in the surface color — invisible
    // on the track.)
    Rectangle {
      visible: meter.marker >= 0
      x: Math.round(meterTrack.width * root.clamp(meter.marker, 0, 1)) - width / 2
      anchors.verticalCenter: meterTrack.verticalCenter
      width: Math.max(5, Style.space(5))
      height: meterTrack.height + Style.space(8)
      radius: width / 2
      color: root.surface

      Rectangle {
        anchors.centerIn: parent
        width: Math.max(3, Style.space(3))
        height: parent.height - 2
        radius: width / 2
        color: root.foreground
      }
    }
  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: root.controlRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: root.controlRadius
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
