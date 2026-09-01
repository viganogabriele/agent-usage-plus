// Notification command construction. Omarchy's supported sender calls its
// notification service directly over D-Bus; do not fall back to notify-send,
// whose libnotify dependency can return success without reaching the shell.

function command(summary, body, urgency) {
  var level = urgency === "critical" || urgency === "low" ? urgency : "normal"
  return [
    "omarchy", "notification", "send",
    "--app-name", "Agent Usage Plus",
    "-u", level,
    String(summary || "Agent Usage Plus"),
    String(body || "")
  ]
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { command: command }
}
