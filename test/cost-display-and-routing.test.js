"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const panel = path.join(__dirname, "..", "Panel.qml")
const claudeCostCollector = path.join(__dirname, "..", "collectors", "bin", "omarchy-agent-usage-claude-cost")
const costCalculator = path.join(__dirname, "..", "scripts", "calculate-api-cost")

function readCostCard() {
  const source = fs.readFileSync(panel, "utf8")
  const start = source.indexOf("id: costSection")
  const end = source.indexOf("// ---------- Usage ----------", start)
  assert.ok(start >= 0 && end > start, "cost card block should be present")
  return source.slice(start, end)
}

function readDetailModelSection() {
  const source = fs.readFileSync(panel, "utf8")
  const start = source.indexOf("id: detailModelSection")
  const end = source.indexOf("// ---------- Plan vs API", start)
  assert.ok(start >= 0 && end > start, "detail model section should be present")
  return source.slice(start, end)
}

function readSelectedCostCard() {
  const source = fs.readFileSync(panel, "utf8")
  const start = source.indexOf("id: costValueCard")
  const end = source.indexOf("// ---------- Usage ----------", start)
  assert.ok(start >= 0 && end > start, "selected cost card block should be present")
  return source.slice(start, end)
}

function executable(file, body) {
  fs.writeFileSync(file, `#!/usr/bin/env bash\nset -euo pipefail\n${body}\n`, { mode: 0o755 })
}

test("panel keeps estimated API cost out of compact view", () => {
  const source = fs.readFileSync(panel, "utf8")
  assert.match(source, /id: costSection/)
  assert.match(source, /visible:\s*root\.expanded\s*&&\s*!root\.settingsOpen/)
  assert.match(source, /root\.costProviderRows\.length/)
  assert.match(source, /text: "Plan vs API"/)
  assert.match(source, /return "On subscription"/)
  assert.match(source, /label: "If billed by API"/)
  assert.match(source, /root\.cost\.estimateUsd/)
})

test("panel guards optional cost values before evaluating a hidden card", () => {
  const source = readCostCard()
  assert.doesNotMatch(source, /text:\s*root\.cost\.incomplete\b/)
  assert.doesNotMatch(source, /color:\s*root\.cost\.incomplete\b/)
  assert.doesNotMatch(source, /text:\s*root\.formatUsd\(root\.cost\.estimateUsd\)/)
  assert.match(source, /!root\.cost\s*\|\|\s*root\.cost\.incomplete/)
  assert.match(source, /root\.cost\s*\?\s*root\.formatUsd\(root\.cost\.estimateUsd\)\s*:\s*"—"/)
})

test("panel displays the collector cost period next to the estimate", () => {
  assert.match(readCostCard(), /"Plan vs API"\s*\+\s*\(root\.cost\s*&&\s*root\.cost\.period/)
})

test("cost details keep the partial disclosure neutral and singular", () => {
  const source = readCostCard()
  assert.doesNotMatch(source, /color:\s*root\.warn/)
  assert.doesNotMatch(source, /API USD is a published-rate estimate, not subscription billing\./)
  assert.match(source, /Partial estimate/)
})

test("token details do not repeat API prices or partial warnings", () => {
  const source = readDetailModelSection()
  assert.doesNotMatch(source, /API USD|apiCost|modelCost|root\.warn/)
  assert.match(source, /text: "Token use by model"/)
})

test("expanded cost details include provider, daily, and model analytics", () => {
  const source = readCostCard()
  assert.match(source, /id: costProviderOverview/)
  assert.match(source, /id: costDailyChart/)
  assert.match(source, /id: costModelChart/)
  assert.match(source, /model: root\.costProviderRows/)
  assert.match(source, /id: costValueCard/)
})

test("selected cost details use the spacious card rhythm", () => {
  const source = readSelectedCostCard()

  assert.match(source, /implicitHeight: costValueContent\.implicitHeight \+ Style\.space\(36\)/)
  assert.match(source, /anchors\.leftMargin: Style\.space\(18\)/)
  assert.match(source, /anchors\.rightMargin: Style\.space\(18\)/)
  assert.match(source, /id: costMetrics[\s\S]*?spacing: Style\.space\(14\)/)
  assert.match(source, /id: costModelRow[\s\S]*?height: Style\.space\(44\)/)
  assert.doesNotMatch(source, /costApiHint\(/)
})

test("cost average uses the provider's recorded days when collectors omit byDay", () => {
  const source = fs.readFileSync(panel, "utf8")

  assert.match(source, /CostAnalytics\.summary\(cost, provider\)/)
  assert.match(source, /root\.costSummary\.hasDailyAverage/)
  assert.match(source, /root\.costSummary\.averageDailyDays/)
  assert.match(source, /root\.costSummary\.dailySource/)
})

test("details expansion animates popup height to avoid a re-anchor snap", () => {
  const source = fs.readFileSync(panel, "utf8")

  assert.match(
    source,
    /Behavior on contentHeight\s*\{[\s\S]*?NumberAnimation\s*\{[\s\S]*?duration:\s*180/
  )
})

test("Claude cost wrapper routes a base record through the bundled estimator", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-cost-routing-"))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const base = path.join(root, "claude-base")
  executable(base, `printf '%s\\n' '{"id":"claude","ready":true,"activeDays":3,"modelUsage":{"claude-sonnet-5":{"inputTokens":1000000}}}'`)

  const output = execFileSync(claudeCostCollector, [], {
    env: {
      ...process.env,
      AGENT_USAGE_PLUS_CLAUDE_BASE_COLLECTOR: base,
      AGENT_USAGE_PLUS_COST_HELPER: costCalculator,
    },
    encoding: "utf8",
  })
  const record = JSON.parse(output)
  assert.equal(record.id, "claude")
  assert.equal(record.cost.estimateUsd, 2)
  assert.equal(record.cost.period, "All time")
  assert.equal(record.cost.activeDays, 3)
})
