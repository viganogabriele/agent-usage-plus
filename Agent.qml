import QtQuick
import Quickshell.Io

// One agent's usage record, read straight off the data file that
// omarchy-agent-usage-update maintains. The panel never learns how the
// numbers were made — a record that appears in the usage directory is an
// agent, whoever wrote it.
//
// Read through a bounded `head -c` rather than FileView: the record is
// replaceable (rewritten by the collector on every refresh, or by whatever
// external tool the README says is also welcome to write one), so a
// size check made before the read — Main.qml's find -size filter, or a
// check made after FileView.text() has already materialized the whole
// file — only rejects the result of an allocation that already happened.
// `head -c maxBytes+1` bounds the actual bytes transferred at the source,
// no matter how large the file is or how much it grows mid-read.
Item {
  id: root
  visible: false

  property string agentId: ""
  property string path: ""
  property var record: null

  readonly property int maxBytes: 1048576

  property bool reloadPending: false

  Process {
    id: readProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parse(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (root.reloadPending) {
        root.reloadPending = false
        Qt.callLater(root.reload)
      }
    }
  }

  // Main.qml calls this on every refresh cycle (the collector just ran, or
  // the panel just opened) instead of watching the file for changes —
  // FileView has no bounded read, so per-record live-watching would bring
  // the unbounded read straight back in through the side door.
  function reload() {
    if (root.path === "") {
      root.record = null
      return
    }
    if (readProcess.running) {
      root.reloadPending = true
      return
    }
    readProcess.command = ["head", "-c", String(root.maxBytes + 1), root.path]
    readProcess.running = true
  }

  function parse(content) {
    var raw = String(content || "")
    if (raw.length > root.maxBytes) {
      console.warn("agents", "Ignoring oversized usage record", root.path, raw.length)
      root.record = null
      return
    }
    try {
      const parsed = JSON.parse(raw)
      root.record = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null
    } catch (e) {
      console.warn("agents", "Ignoring bad usage record", root.path, e)
      root.record = null
    }
  }

  Component.onCompleted: reload()
}
