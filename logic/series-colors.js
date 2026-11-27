// Categorical colors for chart series (models, token kinds) that must be
// told apart at a glance.
//
// The first series is the theme accent itself; the rest are the accent
// turned around the color wheel at well-separated steps, at a saturation
// and lightness close to the accent's so the set still looks like the
// theme. Hues in the warning bands (red and amber, which the panel reserves
// for the Warn and Critical thresholds) are pushed out of them, so a model
// never reads as an alert. Each color is then lightened or darkened only as
// far as it takes to reach `minRatio` against the surface it sits on.
//
// Colors are plain { r, g, b } objects with 0-1 channels (a QML `color`
// satisfies this shape), so the same functions run under Node tests.
// `contrastRatio(a, b)` is passed in (logic/contrast.js in both places).

// Degrees added to the accent's hue for series 1, 2, 3, ...: the first
// three split the wheel in thirds, the next three sit between them.
var HUE_STEPS = [0, 120, 240, 60, 180, 300, 30, 150, 270, 90, 210, 330]

// [from, to] in degrees, inclusive, wrapping at 360.
var WARNING_BANDS = [[345, 15], [25, 62]]

function clamp01(v) {
  var n = Number(v)
  return isFinite(n) ? Math.max(0, Math.min(1, n)) : 0
}

function toHsl(c) {
  var r = clamp01(c && c.r), g = clamp01(c && c.g), b = clamp01(c && c.b)
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2
  var d = max - min
  if (d === 0) return { h: 0, s: 0, l: l }
  var s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
  var h
  if (max === r) h = ((g - b) / d + (g < b ? 6 : 0))
  else if (max === g) h = (b - r) / d + 2
  else h = (r - g) / d + 4
  return { h: h * 60, s: s, l: l }
}

function hueToChannel(p, q, t) {
  if (t < 0) t += 1
  if (t > 1) t -= 1
  if (t < 1 / 6) return p + (q - p) * 6 * t
  if (t < 1 / 2) return q
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
  return p
}

function fromHsl(h, s, l) {
  var hue = (((Number(h) || 0) % 360) + 360) % 360 / 360
  var sat = clamp01(s), light = clamp01(l)
  if (sat === 0) return { r: light, g: light, b: light }
  var q = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
  var p = 2 * light - q
  return { r: hueToChannel(p, q, hue + 1 / 3), g: hueToChannel(p, q, hue), b: hueToChannel(p, q, hue - 1 / 3) }
}

function inBand(hue, band) {
  return band[0] <= band[1] ? hue >= band[0] && hue <= band[1] : hue >= band[0] || hue <= band[1]
}

// The hue, moved to the nearer edge of any warning band it falls in.
function safeHue(hue) {
  var h = ((hue % 360) + 360) % 360
  for (var i = 0; i < WARNING_BANDS.length; i++) {
    var band = WARNING_BANDS[i]
    if (!inBand(h, band)) continue
    var toStart = ((h - band[0]) + 360) % 360
    var toEnd = ((band[1] - h) + 360) % 360
    h = toStart <= toEnd ? (band[0] - 8 + 360) % 360 : (band[1] + 8) % 360
  }
  return h
}

// Lighten or darken `c` (keeping its hue) until it reaches `minRatio`
// against `surface`; gives up gracefully at black or white.
function readable(c, surface, minRatio, contrastRatio) {
  if (typeof contrastRatio !== "function" || contrastRatio(c, surface) >= minRatio) return c
  var hsl = toHsl(c)
  var surfaceLight = toHsl(surface).l
  var direction = surfaceLight < 0.5 ? 1 : -1
  var best = c
  for (var step = 1; step <= 20; step++) {
    var candidate = fromHsl(hsl.h, hsl.s, hsl.l + direction * step * 0.025)
    best = candidate
    if (contrastRatio(candidate, surface) >= minRatio) return candidate
  }
  return best
}

// `count` distinct series colors. The accent comes first, unchanged unless
// it misses `minRatio` against `surface` (default 3:1, WCAG's bar for
// graphics). A greyscale accent gets a neutral-blue base so the set still
// has hues to tell apart.
function categorical(accent, surface, count, contrastRatio, minRatio) {
  var n = Math.max(0, Math.floor(Number(count) || 0))
  var ratio = Number(minRatio) || 3
  var source = accent || { r: 0.5, g: 0.6, b: 0.9 }
  var base = toHsl(source)
  var saturation = base.s < 0.12 ? 0.55 : Math.max(0.42, Math.min(0.8, base.s))
  var lightness = Math.max(0.42, Math.min(0.72, base.l))
  var hue = base.s < 0.12 ? 220 : base.h
  var colors = []
  for (var i = 0; i < n; i++) {
    if (i === 0 && base.s >= 0.12) {
      colors.push(readable({ r: clamp01(source.r), g: clamp01(source.g), b: clamp01(source.b) }, surface, ratio, contrastRatio))
      continue
    }
    var step = HUE_STEPS[i % HUE_STEPS.length]
    // Past the table, alternate lighter/darker so a 13th series still differs.
    var round = Math.floor(i / HUE_STEPS.length)
    var l = lightness + (round % 2 === 1 ? -0.12 : 0) * Math.ceil(round / 2)
    colors.push(readable(fromHsl(safeHue(hue + step), saturation, l), surface, ratio, contrastRatio))
  }
  return colors
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    categorical: categorical,
    safeHue: safeHue,
    toHsl: toHsl,
    fromHsl: fromHsl,
    WARNING_BANDS: WARNING_BANDS
  }
}
