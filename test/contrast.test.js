"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const Contrast = require("../logic/contrast.js")

const hex = (h) => ({
  r: parseInt(h.slice(1, 3), 16) / 255,
  g: parseInt(h.slice(3, 5), 16) / 255,
  b: parseInt(h.slice(5, 7), 16) / 255
})

test("contrastRatio: black on white is 21:1 and symmetric", () => {
  assert.ok(Math.abs(Contrast.contrastRatio(hex("#000000"), hex("#ffffff")) - 21) < 1e-9)
  assert.equal(Contrast.contrastRatio(hex("#123456"), hex("#abcdef")),
    Contrast.contrastRatio(hex("#abcdef"), hex("#123456")))
})

test("isLight: mid-tone theme foregrounds count as light (they sit on dark bars)", () => {
  // Tokyo Night's foreground, L ≈ 0.45: the old 0.5 cutoff called it dark
  // and put the dark #111 Codex mark on a dark bar.
  assert.equal(Contrast.isLight(hex("#a9b1d6")), true)
  assert.equal(Contrast.isLight(hex("#cacccc")), true)
})

test("isLight: light-theme foregrounds count as dark", () => {
  assert.equal(Contrast.isLight(hex("#4c4f69")), false) // Catppuccin Latte
  assert.equal(Contrast.isLight(hex("#575279")), false) // Rose Pine Dawn
  assert.equal(Contrast.isLight(hex("#000000")), false)
})

test("INK_CROSSOVER: black and white have equal contrast there", () => {
  const L = Contrast.INK_CROSSOVER
  assert.ok(Math.abs((L + 0.05) / 0.05 - 1.05 / (L + 0.05)) < 1e-9)
})
