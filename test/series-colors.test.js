"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const Series = require("../logic/series-colors.js")
const Contrast = require("../logic/contrast.js")

const hex = (h) => ({
  r: parseInt(h.slice(1, 3), 16) / 255,
  g: parseInt(h.slice(3, 5), 16) / 255,
  b: parseInt(h.slice(5, 7), 16) / 255
})

// Accent + popup surface pairs from bundled Omarchy themes, dark and light.
const THEMES = {
  "catppuccin": [hex("#89b4fa"), hex("#1e1e2e")],
  "catppuccin-latte": [hex("#1e66f5"), hex("#eff1f5")],
  "tokyo-night": [hex("#7aa2f7"), hex("#1a1b26")],
  "gruvbox": [hex("#d79921"), hex("#282828")],
  "everforest": [hex("#a7c080"), hex("#2d353b")],
  "rose-pine": [hex("#9ccfd8"), hex("#faf4ed")],
  "matte-black": [hex("#8a8a8d"), hex("#121212")],
}

function hueDistance(a, b) {
  const d = Math.abs(a - b) % 360
  return Math.min(d, 360 - d)
}

for (const [name, [accent, surface]] of Object.entries(THEMES)) {
  test(`categorical: ${name} series are distinct, readable and never a warning hue`, () => {
    const colors = Series.categorical(accent, surface, 6, Contrast.contrastRatio)
    assert.equal(colors.length, 6)
    const hues = colors.map(c => Series.toHsl(c).h)
    for (let i = 0; i < colors.length; i++) {
      assert.ok(Contrast.contrastRatio(colors[i], surface) >= 3 - 1e-9, `${name} #${i} contrast`)
      if (i > 0) {
        for (const band of Series.WARNING_BANDS) {
          const inside = band[0] <= band[1] ? hues[i] >= band[0] && hues[i] <= band[1] : hues[i] >= band[0] || hues[i] <= band[1]
          assert.ok(!inside, `${name} #${i} hue ${hues[i]} in a warning band`)
        }
      }
    }
    // The first four (the most a chart usually shows) are far apart.
    for (let i = 0; i < 4; i++) {
      for (let j = i + 1; j < 4; j++) {
        assert.ok(hueDistance(hues[i], hues[j]) >= 25, `${name} #${i}/#${j} hues ${hues[i]}/${hues[j]} too close`)
      }
    }
  })
}

test("categorical: a readable accent is kept as the first series", () => {
  const [accent, surface] = THEMES["catppuccin"]
  const first = Series.categorical(accent, surface, 1, Contrast.contrastRatio)[0]
  assert.deepEqual(first, accent)
})

test("safeHue moves red and amber out of the warning bands", () => {
  assert.equal(Series.safeHue(0), 337)
  assert.equal(Series.safeHue(45), 70)
  assert.equal(Series.safeHue(30), 17)
  assert.equal(Series.safeHue(200), 200)
})

test("categorical handles zero, missing and odd input", () => {
  assert.deepEqual(Series.categorical(hex("#89b4fa"), hex("#1e1e2e"), 0, Contrast.contrastRatio), [])
  assert.equal(Series.categorical(null, hex("#ffffff"), 3, Contrast.contrastRatio).length, 3)
  assert.equal(Series.categorical(hex("#89b4fa"), hex("#1e1e2e"), 14, Contrast.contrastRatio).length, 14)
})
