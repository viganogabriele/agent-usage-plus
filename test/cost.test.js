"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const Cost = require("../logic/cost.js")
const fs = require("node:fs")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

function fixture(name) {
  return JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", name), "utf8"))
}

test("calculateCost rates every TokenBucket dimension for Claude", () => {
  const example = fixture("claude-cost-estimation.json")
  const result = Cost.calculateCost(example)
  assert.deepEqual(result.unknownModels, [])
  assert.equal(result.cost.pricingVersion, example.expected.pricingVersion)
  assert.equal(result.cost.byModel[0].tokens, 4000000)
  assert.equal(result.cost.estimateUsd, example.expected.estimateUsd) // 3 + 15 + .3 + 3.75
})

test("calculateCost prices current Claude Code models, including Opus 5.5", () => {
  const bucket = { inputTokens: 1000000, outputTokens: 1000000, cacheReadInputTokens: 1000000, cacheCreationInputTokens: 1000000 }
  const result = Cost.calculateCost({ provider: "claude", modelUsage: {
    "claude-opus-5-5": bucket,
    "claude-sonnet-5-5": bucket,
  } })

  assert.deepEqual(result.unknownModels, [])
  assert.equal(result.cost.incomplete, false)
  assert.equal(result.cost.byModel.find(row => row.model === "claude-opus-5-5").usd, 29.2)
  assert.equal(result.cost.byModel.find(row => row.model === "claude-sonnet-5-5").usd, 14.7)
})

test("calculateCost uses current Codex standard rates and returns day rows", () => {
  const bucket = { inputTokens: 1000000, outputTokens: 1000000, cacheReadInputTokens: 1000000, cacheCreationInputTokens: 1000000 }
  const result = Cost.calculateCost({ provider: "codex", period: "30d", modelUsage: { "gpt-5.6-sol": bucket }, dailyModelUsage: { "2026-08-23": { "gpt-5.6-sol": bucket } } })
  assert.equal(result.cost.estimateUsd, 29.4) // 4 + 20 + .4 + 5
  assert.deepEqual(result.cost.byDay, [{ date: "2026-08-23", usd: 29.4 }])
})

test("calculateCost covers GPT-6 and charges cache writes at 1.25 times input", () => {
  const bucket = { inputTokens: 1000000, outputTokens: 1000000, cacheReadInputTokens: 1000000, cacheCreationInputTokens: 1000000 }
  const result = Cost.calculateCost({ provider: "codex", modelUsage: {
    "gpt-6-astra": bucket,
    "gpt-6-sol": bucket,
    "gpt-6-luna": bucket,
    "gpt-5.6-terra": bucket,
    "gpt-5.6-luna": bucket,
  } })

  assert.deepEqual(result.unknownModels, [])
  assert.equal(result.cost.byModel.find(row => row.model === "gpt-6-astra").usd, 73.5)
  assert.equal(result.cost.byModel.find(row => row.model === "gpt-6-sol").usd, 14.7)
  assert.equal(result.cost.byModel.find(row => row.model === "gpt-6-luna").usd, 0.735)
  assert.equal(result.cost.byModel.find(row => row.model === "gpt-5.6-terra").usd, 16.7)
  assert.equal(result.cost.byModel.find(row => row.model === "gpt-5.6-luna").usd, 1.67)
})

test("calculateCost marks the priced subtotal partial when another used model is unknown", () => {
  const result = Cost.calculateCost({ provider: "claude", modelUsage: {
    "claude-sonnet-4-20250514": { inputTokens: 100 }, "future-claude": { outputTokens: 100 }
  }, activeDays: 4 })
  assert.equal(result.cost.estimateUsd, 0.0003)
  assert.equal(result.cost.incomplete, true)
  assert.equal(result.cost.pricedTokens, 100)
  assert.equal(result.cost.unpricedTokens, 100)
  assert.equal(result.cost.activeDays, 4)
  assert.deepEqual(result.unknownModels, ["future-claude"])
})

test("calculateCost ignores zero-token unknown models", () => {
  const result = Cost.calculateCost({ provider: "codex", modelUsage: { unknown: {} } })
  assert.ok(result.cost)
  assert.deepEqual(result.unknownModels, [])
  assert.equal(result.cost.estimateUsd, 0)
})

test("calculate-api-cost exposes the same collector-safe JSON interface on stdin", () => {
  const input = fixture("claude-cost-estimation.json")
  const script = path.join(__dirname, "..", "scripts", "calculate-api-cost")
  const result = JSON.parse(execFileSync(script, [], { input: JSON.stringify(input), encoding: "utf8" }))
  assert.equal(result.cost.estimateUsd, input.expected.estimateUsd)
  assert.deepEqual(result.unknownModels, [])
})
