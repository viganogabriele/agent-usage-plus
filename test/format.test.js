"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")

const Format = require("../logic/format.js")

test("formatTokenCount: scales to K/M/B and passes small numbers through", () => {
  assert.equal(Format.formatTokenCount(0), "0")
  assert.equal(Format.formatTokenCount(999), "999")
  assert.equal(Format.formatTokenCount(1500), "1.5K")
  assert.equal(Format.formatTokenCount(2_500_000), "2.5M")
  assert.equal(Format.formatTokenCount(3_200_000_000), "3.2B")
})

test("formatTokenCount: undefined/null read as zero", () => {
  assert.equal(Format.formatTokenCount(undefined), "0")
  assert.equal(Format.formatTokenCount(null), "0")
})

test("formatPercent: rounds to a whole-number percentage", () => {
  assert.equal(Format.formatPercent(0.5), "50%")
  assert.equal(Format.formatPercent(0.421), "42%")
  assert.equal(Format.formatPercent(1), "100%")
})

test("formatPercent: optionally shows the available complement", () => {
  assert.equal(Format.formatPercent(0.13, true), "87%")
  assert.equal(Format.formatPercent(0.421, true), "58%")
  assert.equal(Format.formatPercent(1, true), "0%")
  assert.equal(Format.formatPercent(0, true), "100%")
})

test("displayPercent: reverses meter fill without changing usage mode", () => {
  assert.equal(Format.displayPercent(0.13, false), 0.13)
  assert.equal(Format.displayPercent(0.13, true), 0.87)
  assert.equal(Format.displayPercent(1, true), 0)
})

test("formatDuration: non-positive durations read as now", () => {
  assert.equal(Format.formatDuration(0), "now")
  assert.equal(Format.formatDuration(-100), "now")
})

test("formatDuration: formats minutes, hours, and days", () => {
  assert.equal(Format.formatDuration(30 * 1000), "1m") // rounds up to at least 1m
  assert.equal(Format.formatDuration(45 * 60000), "45m")
  assert.equal(Format.formatDuration(3 * 3600000 + 20 * 60000), "3h 20m")
  assert.equal(Format.formatDuration(2 * 86400000 + 5 * 3600000), "2d 5h")
})

test("formatMoney: prefixes known currencies and falls back to a code", () => {
  assert.equal(Format.formatMoney(12.3, "USD"), "$12.30")
  assert.equal(Format.formatMoney(5, "EUR"), "€5.00")
  assert.equal(Format.formatMoney(5, "GBP"), "£5.00")
  assert.equal(Format.formatMoney(5, "JPY"), "JPY 5.00")
})

test("formatMoney: defaults currency to USD and non-finite amounts to zero", () => {
  assert.equal(Format.formatMoney(1), "$1.00")
  assert.equal(Format.formatMoney(NaN, "USD"), "$0.00")
  assert.equal(Format.formatMoney(undefined, "USD"), "$0.00")
})

test("formatUsd: zero and sub-cent values", () => {
  assert.equal(Format.formatUsd(0), "$0.00")
  assert.equal(Format.formatUsd(0.001), "<$0.01")
  assert.equal(Format.formatUsd(0.0099), "<$0.01")
})

test("formatUsd: values over 1000 get a thousands separator", () => {
  assert.equal(Format.formatUsd(1234.5), "$1,234.50")
  assert.equal(Format.formatUsd(1000), "$1,000.00")
})

test("formatUsd: rounds to the nearest cent", () => {
  assert.equal(Format.formatUsd(8.005), "$8.01")
  assert.equal(Format.formatUsd(12.3), "$12.30")
})

test("formatUsd: non-finite or negative input reads as zero", () => {
  assert.equal(Format.formatUsd(NaN), "$0.00")
  assert.equal(Format.formatUsd(undefined), "$0.00")
  assert.equal(Format.formatUsd(-5), "$0.00")
})

test("friendlyModelName: rejoins a split version and title-cases words", () => {
  assert.equal(Format.friendlyModelName("claude-opus-4-8"), "Opus 4.8")
  assert.equal(Format.friendlyModelName("gpt-5.6-sol"), "GPT 5.6 Sol")
})

test("friendlyModelName: special-cases known acronyms/brand words", () => {
  assert.equal(Format.friendlyModelName("deepseek-v3"), "DeepSeek V3")
})

test("friendlyModelName: strips a trailing claude date suffix", () => {
  assert.equal(Format.friendlyModelName("claude-opus-4-20250514"), "Opus 4")
})

test("friendlyModelName: falls back to Unknown for empty input", () => {
  assert.equal(Format.friendlyModelName(""), "Unknown")
  assert.equal(Format.friendlyModelName(undefined), "Unknown")
  assert.equal(Format.friendlyModelName(null), "Unknown")
})
