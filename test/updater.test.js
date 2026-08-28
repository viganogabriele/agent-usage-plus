"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const updater = path.join(__dirname, "..", "collectors", "bin", "omarchy-agent-usage-update")
const installer = path.join(__dirname, "..", "collectors", "install.sh")

function executable(file, body) {
  fs.writeFileSync(file, `#!/usr/bin/env bash\nset -euo pipefail\n${body}\n`, { mode: 0o755 })
}

function harness(args) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-updater-"))
  const packaged = path.join(root, "packaged-updater")
  const codex = path.join(root, "codex-collector")
  const calls = path.join(root, "calls")
  executable(packaged, `printf 'packaged:%s\\n' "$*" >>"${calls}"`)
  executable(codex, `printf 'codex:%s\\n' "$*" >>"${calls}"; printf '%s\\n' '{"id":"codex","ready":true,"limits":[{"percent":0.25}]}'`)
  execFileSync("bash", [updater, ...args], {
    env: {
      ...process.env,
      XDG_STATE_HOME: path.join(root, "state"),
      AGENT_USAGE_PLUS_PACKAGED_UPDATER: packaged,
      AGENT_USAGE_PLUS_CODEX_COLLECTOR: codex,
    },
  })
  return { root, calls: fs.readFileSync(calls, "utf8"), record: path.join(root, "state", "omarchy", "agents", "usage", "codex.json") }
}

test("local updater replaces packaged Codex while forwarding flags", t => {
  const result = harness(["--force", "codex"])
  t.after(() => fs.rmSync(result.root, { recursive: true, force: true }))
  assert.equal(result.calls, "packaged:--except codex --force codex\ncodex:--force\n")
  assert.equal(JSON.parse(fs.readFileSync(result.record)).limits[0].percent, 0.25)
})

test("local updater leaves an excluded Codex untouched", t => {
  const result = harness(["--except", "codex"])
  t.after(() => fs.rmSync(result.root, { recursive: true, force: true }))
  assert.equal(result.calls, "packaged:--except codex --except codex\n")
  assert.equal(fs.existsSync(result.record), false)
})

test("compat installer links both the collector and updater", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-install-"))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const bin = path.join(root, "bin")
  const data = path.join(root, "data")
  execFileSync("bash", [installer, "--codex-cli-compat"], {
    env: { ...process.env, XDG_BIN_HOME: bin, XDG_DATA_HOME: data },
  })
  assert.equal(
    fs.realpathSync(path.join(bin, "omarchy-agent-usage-codex")),
    path.join(data, "agent-usage-plus-collectors", "bin", "omarchy-agent-usage-codex-compat"),
  )
  assert.equal(
    fs.realpathSync(path.join(bin, "omarchy-agent-usage-update")),
    path.join(data, "agent-usage-plus-collectors", "bin", "omarchy-agent-usage-update"),
  )
})
