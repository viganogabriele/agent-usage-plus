import QtQuick
import Quickshell
import Quickshell.Io
import "logic/aggregate.js" as Aggregate
import "logic/format.js" as Format

// The display side of agent usage. All extraction lives behind
// omarchy-agent-usage-update, which writes one JSON record per agent into
// the usage directory; this file only discovers those records, watches them
// for changes, and optionally merges snapshots synced from other machines.
Item {
  id: root
  visible: false

  property var settings: ({})

  // Set by Panel.qml to its own moduleName ("io.github.viganogabriele.
  // agent-usage-plus"). Needed here, not just there, because settings writes
  // go through the same `omarchy bar set <id> ...` CLI the README documents,
  // and that command needs the widget id as its first argument.
  property string moduleId: ""

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/usage"

  // ------------------------------------------------------------- discovery

  property var agentIds: []
  property var agents: []
  property int dataRevision: 0
  // A cold shell restart needs one bounded directory listing plus per-record
  // reads before a panel can honestly say that no subscriptions exist.
  // Expose that short-lived state so Panel.qml does not flash a false empty
  // state while its initial scan is still in flight.
  property bool initialDiscoveryComplete: false

  // Hard caps on the local usage-directory scan: a file at or above maxAgentFileBytes
  // is excluded before any Agent/FileView is ever created for it, the file count is
  // capped at the shell level (head), and the whole scan is time-boxed. These are the
  // limits requested in the marketplace security review — enforced at the source
  // rather than after the fact.
  readonly property int maxAgentFiles: 500
  readonly property int maxAgentFileBytes: 1048576

  Process {
    id: listProcess
    running: false
    command: ["timeout", "5", "bash", "-c",
      "find \"$1\" -maxdepth 1 -name '*.json' -size -" + root.maxAgentFileBytes + "c -printf '%f\\n' 2>/dev/null | head -n " + root.maxAgentFiles,
      "find-agents", root.usageDir]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applyAgentListing(text)
        // External refresh jobs can write records independently. They do not
        // run through updateProcess, so reload after each
        // bounded directory scan as well as after this widget's own update.
        root.reloadAllAgents()
      }
    }
  }

  function rescanAgents() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyAgentListing(output) {
    var ids = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length && ids.length < root.maxAgentFiles; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".json") ids.push(name.slice(0, -5))
    }
    ids.sort()
    // Same list, same objects: reassigning the model would tear down every
    // FileView just to build identical ones.
    if (JSON.stringify(ids) !== JSON.stringify(agentIds)) agentIds = ids
    initialDiscoveryComplete = true
  }

  Instantiator {
    id: agentInstantiator
    model: root.agentIds

    delegate: Agent {
      required property var modelData
      agentId: modelData
      path: root.usageDir + "/" + modelData + ".json"
      onRecordChanged: root.recordsChanged()
    }

    onObjectAdded: (index, object) => root.rebuildAgents()
    onObjectRemoved: (index, object) => root.rebuildAgents()
  }

  function rebuildAgents() {
    var result = []
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) result.push(agent)
    }
    agents = result
    recordsChanged()
  }

  // Agent.qml reads its record through a bounded, one-shot process rather
  // than a watched FileView (see Agent.qml for why), so nothing re-reads a
  // record on its own when the file changes underneath it. Call this
  // whenever the collector may just have rewritten records — a newly
  // discovered agent picks up its first record on its own via
  // Component.onCompleted, so this only needs to cover ones that already
  // existed.
  function reloadAllAgents() {
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) agent.reload()
    }
  }

  function recordsChanged() {
    dataRevision++
    scheduleLimitsRetry()
    scheduleSync()
  }

  // A collector that could not reach its limits endpoint at all — typically
  // the seconds after login before the network is up — writes retryAdvised
  // into its record. Honor it with one sooner try instead of waiting out the
  // full refresh interval; a run that reaches the endpoint clears the flag.
  // Only the advising agents rerun, so an outage at one provider does not
  // put every other collector on a 30-second treadmill.
  property var retryAgentIds: []

  Timer {
    id: limitsRetry
    interval: 30000
    repeat: false
    onTriggered: root.runUpdate("limits", root.retryAgentIds)
  }

  function scheduleLimitsRetry() {
    var advising = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (record && record.retryAdvised === true && providerEnabled(Aggregate.sanitizeProviderId(record.id)))
        advising.push(Aggregate.sanitizeProviderId(record.id))
    }
    retryAgentIds = advising
    if (advising.length > 0) limitsRetry.restart()
    else limitsRetry.stop()
  }

  Component.onCompleted: {
    rescanAgents()
    if (syncConfigured()) scheduleSync()
  }

  // Records are atomically replaced by both Omarchy's updater and the
  // optional standalone companion jobs. FileView would observe those writes
  // but has no bounded-read mode, so poll the already bounded directory and
  // per-record readers instead. This makes first use and an external
  // refresh appear without needing a shell restart.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.rescanAgents()
  }

  // -------------------------------------------------------------- refresh

  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)))
  property string pendingUpdateKind: ""

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runUpdate("normal")
  }

  // A collector talking to a misbehaving provider API could dump an
  // arbitrarily large error body to stderr; cap what actually reaches this
  // process's memory at the producer boundary instead of trusting the
  // collector to behave.
  readonly property int maxUpdateStderrBytes: 65536

  Process {
    id: updateProcess
    running: false
    onExited: {
      root.rescanAgents()
      root.reloadAllAgents()
      if (root.pendingUpdateKind !== "") {
        var kind = root.pendingUpdateKind
        root.pendingUpdateKind = ""
        root.runUpdate(kind)
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents", text.trim())
    }
  }

  function updateCommand(kind, agentIds) {
    var updateArgs = []
    var providers = settings && settings.providers ? settings.providers : {}
    for (var id in providers) {
      if (providers[id] && providers[id].enabled === false) updateArgs.push("--except", id)
    }
    if (agentIds) {
      for (var i = 0; i < agentIds.length; i++) updateArgs.push(agentIds[i])
    }
    // A local updater is optional: this plugin must still refresh on a
    // normal Omarchy installation where only the packaged command exists.
    // Prefer the local copy when present because it can carry a compatibility
    // fix ahead of the distro package (notably the Codex CLI auth-mode fix).
    var localUpdater = home + "/.local/bin/omarchy-agent-usage-update"
    var script = 'if [[ -x "$1" ]]; then exec "$1" "${@:2}"; fi; exec omarchy-agent-usage-update "${@:2}"'
    if (kind === "force") updateArgs.unshift("--force")
    if (kind === "limits") updateArgs.unshift("--limits-only")
    return ["bash", "-c", script, "agent-usage-update", localUpdater].concat(updateArgs)
  }

  // Wraps the real command so only the first maxUpdateStderrBytes bytes of
  // its stderr ever reach updateProcess's StdioCollector, no matter how
  // much a provider collector's diagnostics try to write.
  function boundedCommand(command, maxStderrBytes) {
    var script = 'exec "$0" "$@" 2> >(head -c ' + maxStderrBytes + ' >&2)'
    return ["bash", "-c", script].concat(command)
  }

  function runUpdate(kind, agentIds) {
    if (updateProcess.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateProcess.command = boundedCommand(updateCommand(kind, agentIds), root.maxUpdateStderrBytes)
    updateProcess.running = true
  }

  function refresh() { refreshAll(true) }
  function refreshAll(force) { runUpdate(force === true ? "force" : "normal") }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk — the collectors reuse their
  // recent scans in this mode.
  function refreshLimits() { runUpdate("limits") }

  // ------------------------------------------------------------- providers

  // An agent earns a place in the bar and the panel by being switched on in
  // settings and having actually produced numbers — locally or on a synced
  // device. With nothing to show, the whole module collapses out of the bar
  // rather than sitting there dimmed.
  property var enabledProviders: {
    var rev = dataRevision
    var syncRev = syncRevision
    var result = []
    var localIds = {}
    var localDisplays = []
    var localIndexById = {}
    var localIsCanonicalFile = {}
    for (var i = 0; i < agents.length; i++) {
      var agent = agents[i]
      var record = agent ? agent.record : null
      if (!record || !record.id) continue
      var id = Aggregate.sanitizeProviderId(record.id)
      localIds[id] = true
      var display = displayProvider(record)
      if (!Aggregate.providerHasData(display)) continue

      // A stale or third-party file can report the same provider id as the
      // updater's canonical `<id>.json`. Keep exactly one tab/meter per
      // provider, preferring that canonical file when both exist. Without
      // this, a failed migration could show duplicate Codex meters and make
      // selection appear to switch to the wrong card.
      var canonical = agent && String(agent.agentId || "") === id
      if (localIndexById[id] === undefined) {
        localIndexById[id] = localDisplays.length
        localIsCanonicalFile[id] = canonical
        localDisplays.push(display)
      } else if (canonical && !localIsCanonicalFile[id]) {
        localIsCanonicalFile[id] = true
        localDisplays[localIndexById[id]] = display
      }
    }
    for (var local = 0; local < localDisplays.length; local++) {
      var localDisplay = localDisplays[local]
      if (providerEnabled(localDisplay.providerId)) result.push(localDisplay)
    }
    // An agent that only ever ran on another machine has no local record, but
    // its synced numbers still deserve a tab. Rate limits stay blank — they
    // are per-account and never travel. aggregateData.providers is already
    // keyed by sanitized id (aggregateSnapshots does this on ingestion), so
    // syncedId here needs no further sanitizing before use as a lookup key —
    // it does still get sanitized again inside displayProvider before it is
    // ever used to build an asset path or a display label.
    var syncedProviders = syncConfigured() && aggregateData && aggregateData.providers ? aggregateData.providers : {}
    var syncedCount = 0
    for (var syncedId in syncedProviders) {
      if (localIds[syncedId] || !providerEnabled(syncedId)) continue
      if (++syncedCount > 50) break
      var stats = syncedProviders[syncedId] || {}
      var syncedDisplay = displayProvider({ id: syncedId, name: stats.providerName || syncedId })
      if (Aggregate.providerHasData(syncedDisplay)) result.push(syncedDisplay)
    }
    return Aggregate.applyProviderOrder(result, root.providerOrder)
  }

  // A user's drag-to-reorder result (Panel.qml's provider switcher), as a
  // plain array of provider ids. Feeds both the bar layout and the panel
  // switcher below, since both are built from enabledProviders — dragging a
  // mark in one place is meant to reorder it everywhere.
  //
  // Stored double-JSON-encoded (a string containing the array's JSON text,
  // not a bare JSON array) because of an `omarchy bar set ... --json` bug:
  // a top-level array value with more than one element makes it miscount
  // its own arguments and fail every time ("Too many arguments provided"),
  // while the exact same array encoded as a JSON *string* round-trips fine.
  // A plain string setting has no such problem, so unwrap it back into an
  // array on read instead.
  readonly property var providerOrder: {
    var raw = setting("providerOrder", "[]")
    try {
      var parsed = JSON.parse(typeof raw === "string" ? raw : "[]")
      return Array.isArray(parsed) ? parsed : []
    } catch (e) {
      return []
    }
  }

  function setProviderOrder(ids) {
    var clean = []
    for (var i = 0; i < (ids ? ids.length : 0); i++) {
      if (typeof ids[i] === "string" && ids[i]) clean.push(ids[i])
    }
    writeSetting("providerOrder", JSON.stringify(JSON.stringify(clean)))
  }

  function providerEnabled(id) {
    if (!settings || !settings.providers || !settings.providers[id]) return true
    return settings.providers[id].enabled !== false
  }

  // The bar-widget slice of enabledProviders: same "enabled and has data"
  // list the panel's chip switcher uses, narrowed by `showInBar`.
  // `barRole` divides eligible providers into fixed and rotating slots.
  // The old global bar mode has no user-facing control anymore: the per-row
  // role is the complete, composable layout. An older hand-written
  // `barMode: "cycle"` remains readable until a role is chosen.
  function settingsHaveBarRoles() {
    var providers = settings && settings.providers ? settings.providers : {}
    for (var id in providers) {
      var role = providers[id] ? providers[id].barRole : ""
      if (role === "fixed" || role === "cycle") return true
    }
    return false
  }
  readonly property bool legacyCycleMode: setting("barMode", "all") === "cycle"
    && !settingsHaveBarRoles()
  readonly property int barCycleIntervalSec: {
    var v = Number(setting("barCycleIntervalSec", 8))
    if (!isFinite(v)) v = 8
    return Math.max(3, Math.min(120, Math.round(v)))
  }
  readonly property int barCycleSlots: {
    var v = Number(setting("barCycleSlots", 1))
    if (!isFinite(v)) v = 1
    return Math.max(0, Math.min(3, Math.round(v)))
  }
  // Only meaningful in Cycle mode. It wraps against the rotating pool, not
  // the panel's selected-provider index.
  property int barCycleIndex: 0
  // No cap of our own: Fixed providers fill this budget first, and only
  // what's left goes to rotating slots (see selectBarLayout), so an
  // arbitrary number here silently shrinks Cycle slots the person actually
  // asked for the moment enough providers are marked Fixed. The real, non-
  // arbitrary ceiling is however many providers exist to mark in the first
  // place — selectBarLayout's own internal clamp already stops at 10, the
  // total the bundled collectors ship — so this is left high enough to
  // never be the thing doing the trimming.
  readonly property int barSlotLimit: 999

  function booleanSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    if (typeof value === "string") {
      var text = value.trim().toLowerCase()
      if (text === "true" || text === "1" || text === "on") return true
      if (text === "false" || text === "0" || text === "off" || text === "") return false
    }
    return fallback
  }

  // Off by default: a notification is an interruption, and nobody asked for
  // one just by installing the widget. See Panel.qml for the actual
  // threshold-crossing watch and Omarchy notification dispatch queue.
  readonly property bool notificationsEnabled: booleanSetting("notificationsEnabled", false)
  // Presentation only: the UI may show the available complement, while
  // collectors and internal threshold comparisons retain their canonical
  // used fractions so switching modes never changes when a warning fires.
  readonly property bool showAvailablePercentage: booleanSetting("showAvailablePercentage", false)
  // Opt-in visual treatment only. Severity and notification transitions do
  // not depend on this setting.
  readonly property bool colorfulUsageMeters: booleanSetting("colorfulUsageMeters", false)

  readonly property var showInBarList: Aggregate.selectBarProviders(enabledProviders, settings)
  readonly property var barLayout: Aggregate.selectBarLayout(
    enabledProviders, settings, legacyCycleMode ? "legacy-cycle" : "roles",
    barCycleIndex, barCycleSlots, barSlotLimit)
  readonly property var cycleBarProviders: barLayout.cycling || []

  readonly property var barProviders: barLayout.providers || []

  // Automatic rotation for `barMode: "cycle"`. Manual advances (cycleNext(),
  // wired to the bar's middle-click in cycle mode — see Panel.qml) call
  // advanceCycle() and then restart the rotation clock, so a manual click and
  // the next automatic tick don't double-skip a provider.
  Timer {
    id: cycleTimer
    interval: root.barCycleIntervalSec * 1000
    running: root.barCycleSlots > 0
      && root.cycleBarProviders.length > root.barCycleSlots
    repeat: true
    onTriggered: root.advanceCycle()
  }

  function advanceCycle() {
    var list = root.cycleBarProviders
    if (root.barCycleSlots <= 0 || list.length <= root.barCycleSlots) return
    root.barCycleIndex = (root.barCycleIndex + 1) % list.length
  }

  // The manual "cycle to next provider" action: advances immediately, then
  // restarts the rotation clock so the next automatic tick waits a full
  // interval from this advance.
  function cycleNext() {
    if (root.barCycleSlots <= 0 || root.cycleBarProviders.length === 0) return
    advanceCycle()
    cycleTimer.stop()
    cycleTimer.start()
  }

  // Merges one usage record with its synced counterpart (if any) into the
  // per-provider object the panel renders — see logic/aggregate.js for the
  // pure merge (mergeProviderDisplay) and the "has this provider produced
  // anything worth a tab" check (providerHasData).
  function displayProvider(record) {
    var providerId = Aggregate.sanitizeProviderId(record.id)
    var stats = syncedStatsFor(providerId)
    return Aggregate.mergeProviderDisplay(record, stats, {
      deviceCount: aggregateData ? aggregateData.deviceCount : 0,
      updatedAt: aggregateData && aggregateData.updatedAt ? aggregateData.updatedAt : ""
    })
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // --------------------------------------------------------- settings writes
  //
  // The panel's settings section (issue 08) never touches shell.json itself:
  // every write shells out to the same `omarchy bar set <id> <key> <value>
  // --json` command documented in the README, so there is exactly one code
  // path that can put a value into shell.json, whether it was typed at a
  // terminal or clicked in the panel. `omarchy bar set` calls through to
  // `omarchy-shell shell setBarWidget`, which is what actually rewrites
  // shell.json and reloads it into every widget's `settings` property — so a
  // successful write here reaches `root.settings` (and everything derived
  // from it, like `refreshIntervalSec` above) through that same reactive
  // path, with no extra plumbing and no reopening the panel required.
  property var settingsWriteQueue: []
  property bool settingsWriteRunning: false

  Process {
    id: settingsWriteProcess
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("agents/settings", "omarchy bar set failed:", settingsWriteProcess.command.join(" "))
      root.settingsWriteRunning = false
      root.pumpSettingsWriteQueue()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents/settings", text.trim())
    }
  }

  // Queued rather than fired immediately: a slider release and a toggle click
  // landing in the same tick would otherwise race two `omarchy bar set`
  // invocations against the same shell.json write lock. `jsonValue` is
  // already a JSON-shaped string (a bare number, or a JSON object for
  // `providers`) — always passed with `--json` so `set` parses it instead of
  // writing it back out as a quoted string.
  function writeSetting(key, jsonValue) {
    if (root.moduleId === "") return
    root.settingsWriteQueue.push({ key: key, jsonValue: jsonValue })
    root.pumpSettingsWriteQueue()
  }

  function pumpSettingsWriteQueue() {
    if (root.settingsWriteRunning) return
    if (root.settingsWriteQueue.length === 0) return
    var next = root.settingsWriteQueue.shift()
    root.settingsWriteRunning = true
    settingsWriteProcess.command = ["omarchy", "bar", "set", root.moduleId, next.key, next.jsonValue, "--json"]
    settingsWriteProcess.running = true
  }

  function setRefreshIntervalSec(value) {
    writeSetting("refreshIntervalSec", String(Math.round(Number(value))))
  }

  function setWarnThresholdPct(value) {
    writeSetting("warnThresholdPct", String(Math.round(Number(value))))
  }

  function setCriticalThresholdPct(value) {
    writeSetting("criticalThresholdPct", String(Math.round(Number(value))))
  }

  // Per-agent settings are nested, and `set` writes its key literally rather
  // than walking a dotted path (see README), so a single-field change still
  // has to round-trip the *whole* `providers` object — this rebuilds it from
  // the current settings, patches one provider's one field, and writes it
  // back the same shape `omarchy bar set ... providers '{...}' --json` from
  // the README would.
  function setProviderField(id, field, value) {
    var fields = {}
    fields[field] = value
    setProviderFields(id, fields)
  }

  function setProviderFields(id, fields) {
    if (String(id || "") === "") return
    var providers = {}
    var current = settings && settings.providers ? settings.providers : {}
    for (var pid in current) providers[pid] = Object.assign({}, current[pid])
    if (!providers[id]) providers[id] = {}
    var patch = fields && typeof fields === "object" ? fields : {}
    for (var key in patch) providers[id][key] = patch[key]
    writeSetting("providers", JSON.stringify(providers))
  }

  function setProviderEnabled(id, value) {
    // Mirror setProviderBarRole's own symmetry: choosing a bar role turns
    // Enabled on, so turning Enabled off should turn the bar role back off
    // too — otherwise a disabled provider still reads as Fixed/Cycle in
    // Settings (even though enabledProviders already keeps it out of the
    // bar), and reappears with its old role the moment it's re-enabled.
    var fields = { enabled: !!value }
    if (!value) {
      fields.showInBar = false
      fields.barRole = "fixed"
    }
    setProviderFields(id, fields)
  }
  function setProviderShowInBar(id, value) { setProviderField(id, "showInBar", !!value) }

  function setProviderLabelMode(id, value) {
    var v = value === "icon" || value === "iconPercent" ? value : "full"
    setProviderField(id, "barLabelMode", v)
  }
  function setBarCycleIntervalSec(value) {
    writeSetting("barCycleIntervalSec", String(Math.max(3, Math.min(120, Math.round(Number(value))))))
  }

  function setBarCycleSlots(value) {
    writeSetting("barCycleSlots", String(Math.max(0, Math.min(3, Math.round(Number(value))))))
  }

  function setNotificationsEnabled(value) {
    writeSetting("notificationsEnabled", JSON.stringify(!!value))
  }

  function setShowAvailablePercentage(value) {
    writeSetting("showAvailablePercentage", JSON.stringify(!!value))
  }

  function setColorfulUsageMeters(value) {
    writeSetting("colorfulUsageMeters", JSON.stringify(!!value))
  }

  function setProviderBarRole(id, value) {
    var role = value === "cycle" || value === "fixed" ? value : "off"
    // Keep the old showInBar switch authoritative for compatibility with
    // hand-written shell.json files. A role selection updates both fields in
    // one queued write, so the UI cannot show an enabled Cycle role that the
    // bar still excludes.
    var fields = {
      showInBar: role !== "off",
      barRole: role === "off" ? "fixed" : role
    }
    // Choosing Fixed or Cycle is an intent to use this provider. Avoid the
    // state where a selected role remains invisible because Enabled was off.
    if (role !== "off") fields.enabled = true
    setProviderFields(id, fields)
  }

  // ------------------------------------------------------------------ sync

  property var syncModeSetting: setting("syncMode", setting("syncEnabled", false))
  property bool syncEnabled: parseSyncEnabled(syncModeSetting)
  property string syncDir: String(setting("syncDir", ""))
  property string syncFileName: String(setting("syncFileName", ""))
  property string syncDeviceId: String(setting("syncDeviceId", ""))
  property string detectedHostname: ""
  readonly property string syncEffectiveDir: expandPath(syncDir)
  readonly property string syncEffectiveFileName: safeSnapshotFileName(syncFileName, syncDeviceId)
  readonly property string syncEffectiveDeviceId: safeDeviceId(syncDeviceId || syncEffectiveFileName.replace(/\.json$/i, ""))
  readonly property string syncSnapshotPath: syncConfigured() ? syncEffectiveDir + "/" + syncEffectiveFileName : home + "/.cache/omarchy/agents-disabled.json"
  property var aggregateData: ({})
  property int syncRevision: 0
  property bool syncRunning: false
  property bool syncRequestedWhileRunning: false
  property string syncStatusText: ""
  property double aggregateUpdatedAtMs: aggregateData && aggregateData.updatedAtMs ? Number(aggregateData.updatedAtMs) : 0

  onSyncEnabledChanged: syncSettingsChanged()
  onSyncDirChanged: syncSettingsChanged()
  onSyncFileNameChanged: if (syncConfigured()) scheduleSync()
  onSyncDeviceIdChanged: if (syncConfigured()) scheduleSync()

  Timer {
    id: syncDebounce
    interval: 1000
    repeat: false
    onTriggered: root.runSync()
  }

  Process {
    id: syncMkdirProcess
    running: false
    onRunningChanged: root.updateSyncRunning()
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (root.syncConfigured()) root.syncStatusText = "Usage sync mkdir failed"
        root.finishSyncRun()
        return
      }
      root.writeSyncSnapshot()
    }
  }

  Process {
    id: syncScanProcess
    running: false
    onRunningChanged: root.updateSyncRunning()
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.syncConfigured()) root.syncStatusText = "Usage sync scan failed"
      root.finishSyncRun()
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseSyncScanOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents/sync", text.trim())
    }
  }

  FileView {
    id: syncSnapshotFile
    path: root.syncSnapshotPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    watchChanges: false
    printErrors: false
    onLoaded: root.detectedHostname = String(text() || "").trim()
  }

  function parseSyncEnabled(value) {
    if (value === true) return true
    var text = String(value || "").trim().toLowerCase()
    return text === "on" || text === "enabled" || text === "true" || text === "yes" || text === "1"
  }

  function syncConfigured() {
    return root.syncEnabled === true && String(root.syncDir || "").trim() !== ""
  }

  function syncSettingsChanged() {
    if (syncConfigured()) {
      scheduleSync()
    } else {
      syncDebounce.stop()
      syncRequestedWhileRunning = false
      aggregateData = ({})
      syncStatusText = ""
      syncRevision++
    }
  }

  function updateSyncRunning() {
    root.syncRunning = syncMkdirProcess.running || syncScanProcess.running
  }

  function scheduleSync() {
    if (!syncConfigured()) return
    syncDebounce.restart()
  }

  function runSync() {
    if (!syncConfigured()) return
    if (root.syncRunning) {
      syncRequestedWhileRunning = true
      return
    }

    syncRequestedWhileRunning = false
    syncStatusText = ""
    syncMkdirProcess.command = ["mkdir", "-p", root.syncEffectiveDir]
    syncMkdirProcess.running = true
  }

  function writeSyncSnapshot() {
    if (!syncConfigured()) {
      finishSyncRun()
      return
    }
    syncSnapshotFile.setText(JSON.stringify(localSnapshot(), null, 2) + "\n")
    Qt.callLater(root.startSyncScan)
  }

  // Caps on the sync-directory scan: snapshots come from other machines over
  // whatever transport backs the configured sync directory, so none of it is
  // trusted. At most maxSyncSnapshots files are read, each truncated to
  // maxSyncSnapshotBytes, the whole concatenated output is capped again, and
  // the scan itself is time-boxed — limits enforced in the shell pipeline
  // itself, before any of it reaches QML.
  readonly property int maxSyncSnapshots: 50
  readonly property int maxSyncSnapshotBytes: 262144
  readonly property int maxSyncScanOutputBytes: 20971520

  function startSyncScan() {
    if (!syncConfigured()) {
      finishSyncRun()
      return
    }
    var script = "dir=$0; [[ -d \"$dir\" ]] || exit 0; shopt -s nullglob;"
      + " { n=0; for f in \"$dir\"/*.json; do [[ -f \"$f\" ]] || continue;"
      + " n=$((n+1)); [[ $n -le " + root.maxSyncSnapshots + " ]] || break;"
      + " printf '===%s===\\n' \"$f\"; head -c " + root.maxSyncSnapshotBytes + " \"$f\";"
      + " printf '\\n=== EOM ===\\n'; done; } | head -c " + root.maxSyncScanOutputBytes
    syncScanProcess.command = ["timeout", "10", "bash", "-c", script, root.syncEffectiveDir]
    syncScanProcess.running = true
  }

  function finishSyncRun() {
    if (syncRequestedWhileRunning && syncConfigured()) {
      syncRequestedWhileRunning = false
      scheduleSync()
    }
  }

  function expandPath(path) {
    var value = String(path || "").trim()
    if (value === "") return ""
    if (value === "~") return home
    if (value.indexOf("~/") === 0) return home + value.substring(1)
    if (value.indexOf("$HOME/") === 0) return home + value.substring(5)
    if (value.charAt(0) !== "/") return home + "/" + value
    return value
  }

  function safeDeviceId(raw) {
    var envFallback = Quickshell.env("HOSTNAME") || root.detectedHostname || Quickshell.env("HOST") || Quickshell.env("USER") || "device"
    return Aggregate.sanitizeDeviceId(raw, envFallback)
  }

  function safeSnapshotFileName(rawFileName, rawDeviceId) {
    var value = String(rawFileName || "").trim()
    if (value === "") value = safeDeviceId(rawDeviceId) + ".json"
    value = value.split("/").pop().replace(/[^A-Za-z0-9_.-]+/g, "-").replace(/^[._-]+|[._-]+$/g, "")
    if (value === "") value = safeDeviceId(rawDeviceId) + ".json"
    if (!/\.json$/i.test(value)) value += ".json"
    return value.length > 100 ? value.substring(0, 95) + ".json" : value
  }

  function parseSyncScanOutput(output) {
    var lines = String(output || "").split("\n")
    var snapshots = []
    var currentPath = ""
    var currentJson = []

    function flush() {
      if (currentPath === "") return
      if (snapshots.length >= root.maxSyncSnapshots) return
      var raw = currentJson.join("\n").trim()
      try {
        var parsed = JSON.parse(raw)
        if (parsed && parsed.providers) snapshots.push(parsed)
      } catch (e) {
        console.warn("agents/sync", "Ignoring bad snapshot", currentPath, e)
      }
      currentPath = ""
      currentJson = []
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      var start = line.match(/^===(.+)===$/)
      if (start && line !== "=== EOM ===") {
        flush()
        currentPath = start[1]
        currentJson = []
        continue
      }
      if (line === "=== EOM ===") {
        flush()
        continue
      }
      if (currentPath !== "") currentJson.push(line)
    }
    flush()

    aggregateData = Aggregate.aggregateSnapshots(snapshots, root.maxSyncSnapshots)
    syncStatusText = ""
    syncRevision++
  }

  // ---------------------------------------------------------- untrusted input
  //
  // The sanitizers that used to live here (sanitizeProviderId,
  // sanitizeDisplayText, sanitizeLimits, capRecentDays, capModelUsage,
  // cloneValue, numberValue) moved to logic/aggregate.js: they're pure and
  // shared by the merge functions there. See that file's header comment for
  // why they still matter — everything they touch can reach a native QML
  // Text/Button/Image sink in Panel.qml.

  // localSnapshot() feeds the write side of sync: one plain record per
  // agent, handed to logic/aggregate.js's buildLocalSnapshot (which sanitizes
  // and caps each one through providerSnapshot before it ever reaches disk).
  function localSnapshot() {
    var records = []
    for (var i = 0; i < agents.length; i++) records.push(agents[i] ? agents[i].record : null)
    return Aggregate.buildLocalSnapshot(records, syncEffectiveDeviceId, providerEnabled)
  }

  function syncedStatsFor(providerId) {
    var rev = syncRevision
    if (!syncConfigured() || !aggregateData || !aggregateData.providers) return null
    return aggregateData.providers[providerId] || null
  }

  // ---------------------------------------------------------------- format
  //
  // Both moved to logic/format.js; Panel.qml calls these through `usage.`
  // (the Main {} instance it embeds), so they stay here as thin wrappers
  // rather than making every call site import Format itself.

  function formatTokenCount(n) {
    return Format.formatTokenCount(n)
  }

  function friendlyModelName(id) {
    return Format.friendlyModelName(id)
  }
}
