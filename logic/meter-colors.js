// Semantic meter palette selection. QML owns the actual colors so the default
// roles can keep following Omarchy's live theme; this module only decides
// which role applies for a severity and the opt-in traffic-light setting.

function paletteRole(severity, colorful) {
  if (severity === "critical") return colorful === true ? "critical-red" : "critical"
  if (severity === "warn") return "warn"
  return colorful === true ? "healthy" : "foreground"
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { paletteRole: paletteRole }
}
