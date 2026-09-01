// Number/percentage/time-to-reset formatting helpers.
//
// Moved out of Main.qml (formatTokenCount, friendlyModelName) and Panel.qml
// (formatDuration, formatMoney, currencyPrefix) — issue #1. Pure string
// formatting only; nothing here reads the clock except formatDuration's
// caller-supplied millisecond count.

function formatTokenCount(n) {
  if (n === undefined || n === null) return "0"
  if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
  return String(n)
}

// Converts the provider's canonical used fraction into whichever fraction the
// interface is currently presenting. Keep this separate from threshold logic:
// severity always classifies usage, even when meters run down toward zero.
function displayPercent(percent, showAvailable) {
  return showAvailable === true ? 1 - percent : percent
}

// A valid (>= 0) usage fraction as a whole-number string, e.g. 0.5 -> "50%".
// When showAvailable is true, complement the already-rounded usage value so
// the two display modes always add up to exactly 100 (13% used / 87%
// available). Callers decide what to show for a negative/unknown percent,
// since that fallback differs by call site.
function formatPercent(percent, showAvailable) {
  var used = Math.round(percent * 100)
  return (showAvailable === true ? 100 - used : used) + "%"
}

function formatDuration(ms) {
  if (!(ms > 0)) return "now"
  var minutes = Math.floor(ms / 60000)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "m"
  return Math.max(1, minutes) + "m"
}

function currencyPrefix(currency) {
  var code = String(currency || "USD").toUpperCase()
  if (code === "USD") return "$"
  if (code === "EUR") return "€"
  if (code === "GBP") return "£"
  return code + " "
}

function formatMoney(value, currency) {
  var amount = Number(value)
  if (!isFinite(amount)) amount = 0
  return currencyPrefix(currency) + amount.toFixed(2)
}

// Formats a USD *estimate* (issue #12's `cost.estimateUsd`), not a real
// ledger balance. Deliberately not just `formatMoney(amount, "USD")`:
//
// - A real API-rate estimate can be a small fraction of a cent per call
//   (e.g. "$0.0031 today"). `formatMoney`'s two decimal places would round
//   that all the way down to "$0.00", which reads as free when it isn't —
//   fine for `balance` (a ledger already rounded to cents by whoever funds
//   it), wrong for a derived estimate. Anything strictly between $0 and
//   $0.01 renders as "<$0.01" instead of a misleading "$0.00".
// - Estimates can also run well past what a prepaid balance ever shows
//   (a monthly all-model estimate over $1,000), so amounts of $1,000 or
//   more get thousands separators for readability.
//
// Negative and non-finite input reads as $0, same convention as
// `formatMoney`'s NaN handling.
function formatUsd(amount) {
  var value = Number(amount)
  if (!isFinite(value) || value < 0) value = 0
  if (value > 0 && value < 0.01) return "<$0.01"
  var fixed = value.toFixed(2)
  var parts = fixed.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return "$" + parts.join(".")
}

function modelWordCase(word) {
  if (word === "gpt") return "GPT"
  if (word === "deepseek") return "DeepSeek"
  return word.charAt(0).toUpperCase() + word.slice(1)
}

// Model ids arrive hyphenated with the version split across segments
// (`claude-opus-4-8`, `gpt-5.6-sol`). Rejoin the numeric run into one
// version and title-case the words around it.
function friendlyModelName(id) {
  if (!id) return "Unknown"
  var name = String(id).replace(/^claude-/, "").replace(/-\d{8}$/, "")
  var parts = name.split("-")
  var words = []
  var version = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue
    if (/^\d/.test(part)) {
      version.push(part)
      continue
    }
    if (version.length > 0) {
      words.push(version.join("."))
      version = []
    }
    words.push(modelWordCase(part))
  }
  if (version.length > 0) words.push(version.join("."))
  return words.length > 0 ? words.join(" ") : "Unknown"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    formatTokenCount: formatTokenCount,
    displayPercent: displayPercent,
    formatPercent: formatPercent,
    formatDuration: formatDuration,
    currencyPrefix: currencyPrefix,
    formatMoney: formatMoney,
    formatUsd: formatUsd,
    modelWordCase: modelWordCase,
    friendlyModelName: friendlyModelName
  }
}
