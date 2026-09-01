"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")

const MeterColors = require("../logic/meter-colors.js")

test("paletteRole: colorful meters are explicitly green, amber, and red", () => {
  assert.equal(MeterColors.paletteRole("ok", true), "healthy")
  assert.equal(MeterColors.paletteRole("warn", true), "warn")
  assert.equal(MeterColors.paletteRole("critical", true), "critical-red")
})

test("paletteRole: color coding is opt-in", () => {
  assert.equal(MeterColors.paletteRole("ok", false), "foreground")
  assert.equal(MeterColors.paletteRole("critical", false), "critical")
})
