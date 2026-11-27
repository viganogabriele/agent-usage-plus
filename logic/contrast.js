// WCAG relative luminance and contrast helpers, shared by the panel's text
// colors and the light/dark provider-mark choice.
//
// Colors are plain { r, g, b } objects with 0-1 channels (a QML `color`
// satisfies this shape), so the same functions run under Node tests.

function channel(value) {
  var c = Number(value)
  if (!isFinite(c)) return 0
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

function luminance(color) {
  var c = color || {}
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
}

function contrastRatio(a, b) {
  var la = luminance(a) + 0.05
  var lb = luminance(b) + 0.05
  return Math.max(la, lb) / Math.min(la, lb)
}

// The luminance at which black and white reach the same contrast
// ((L + 0.05) / 0.05 === 1.05 / (L + 0.05)). Above it, dark ink reads
// better; below it, light ink does. A plain 0.5 cutoff misfiles mid-tone
// colors such as Tokyo Night's #a9b1d6 foreground (L ≈ 0.45) as "dark".
var INK_CROSSOVER = Math.sqrt(1.05 * 0.05) - 0.05

function isLight(color) {
  return luminance(color) > INK_CROSSOVER
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    luminance: luminance,
    contrastRatio: contrastRatio,
    isLight: isLight,
    INK_CROSSOVER: INK_CROSSOVER
  }
}
