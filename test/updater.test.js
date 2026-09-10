"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const updater = path.join(__dirname, "..", "collectors", "bin", "omarchy-agent-usage-update")
const pluginUpdater = path.join(__dirname, "..", "collectors", "bin", "agent-usage-plus-update")
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
  // The packaged updater and the Codex collector now run concurrently, so
  // their relative write order isn't guaranteed.
  assert.deepEqual(result.calls.trim().split("\n").sort(), ["codex:--force", "packaged:--except codex --force codex"])
  assert.equal(JSON.parse(fs.readFileSync(result.record)).limits[0].percent, 0.25)
})

test("local updater leaves an excluded Codex untouched", t => {
  const result = harness(["--except", "codex"])
  t.after(() => fs.rmSync(result.root, { recursive: true, force: true }))
  assert.equal(result.calls, "packaged:--except codex --except codex\n")
  assert.equal(fs.existsSync(result.record), false)
})

test("a failing packaged updater still lets the Codex refresh land", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-updater-"))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const packaged = path.join(root, "packaged-updater")
  const codex = path.join(root, "codex-collector")
  executable(packaged, "exit 1")
  executable(codex, "printf '%s\\n' '{\"id\":\"codex\",\"ready\":true,\"limits\":[{\"percent\":0.5}]}'")

  const record = path.join(root, "state", "omarchy", "agents", "usage", "codex.json")
  assert.throws(() =>
    execFileSync("bash", [updater, "--force"], {
      env: {
        ...process.env,
        XDG_STATE_HOME: path.join(root, "state"),
        AGENT_USAGE_PLUS_PACKAGED_UPDATER: packaged,
        AGENT_USAGE_PLUS_CODEX_COLLECTOR: codex,
      },
    })
  )
  assert.equal(JSON.parse(fs.readFileSync(record)).limits[0].percent, 0.5)
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

test("plugin updater adds Devin without running every bundled collector", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-plugin-updater-"))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const base = path.join(root, "base-updater")
  const bundled = path.join(root, "bundled-runner")
  const calls = path.join(root, "calls")
  executable(base, `printf 'base:%s\n' "$*" >>"${calls}"`)
  executable(bundled, `printf 'bundled:%s\n' "$*" >>"${calls}"`)

  execFileSync("bash", [pluginUpdater, "--force", "devin", "--except", "kimi"], {
    env: {
      ...process.env,
      AGENT_USAGE_PLUS_BASE_UPDATER: base,
      AGENT_USAGE_PLUS_BUNDLED_RUNNER: bundled,
    },
  })

  const lines = fs.readFileSync(calls, "utf8").trim().split("\n")
  assert.ok(lines.includes("bundled:update --force devin"))
  const baseCall = lines.find(line => line.startsWith("base:"))
  assert.equal(baseCall, "base:--force devin --except kimi --except devin --except agy")
})

test("plugin updater adds agy without running every bundled collector", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-plugin-updater-"))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const base = path.join(root, "base-updater")
  const bundled = path.join(root, "bundled-runner")
  const calls = path.join(root, "calls")
  executable(base, `printf 'base:%s\n' "$*" >>"${calls}"`)
  executable(bundled, `printf 'bundled:%s\n' "$*" >>"${calls}"`)

  execFileSync("bash", [pluginUpdater, "--force", "agy", "--except", "kimi"], {
    env: {
      ...process.env,
      AGENT_USAGE_PLUS_BASE_UPDATER: base,
      AGENT_USAGE_PLUS_BUNDLED_RUNNER: bundled,
    },
  })

  const lines = fs.readFileSync(calls, "utf8").trim().split("\n")
  assert.ok(lines.includes("bundled:update --force agy"))
  const baseCall = lines.find(line => line.startsWith("base:"))
  assert.equal(baseCall, "base:--force agy --except kimi --except devin --except agy")
})

test("plugin updater deduplicates repeated provider arguments", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-plugin-updater-"))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const base = path.join(root, "base-updater")
  const bundled = path.join(root, "bundled-runner")
  const calls = path.join(root, "calls")
  executable(base, `printf 'base:%s\n' "$*" >>"${calls}"`)
  executable(bundled, `printf 'bundled:%s\n' "$*" >>"${calls}"`)

  execFileSync("bash", [pluginUpdater, "devin", "devin", "agy", "agy"], {
    env: {
      ...process.env,
      AGENT_USAGE_PLUS_BASE_UPDATER: base,
      AGENT_USAGE_PLUS_BUNDLED_RUNNER: bundled,
    },
  })

  const lines = fs.readFileSync(calls, "utf8").trim().split("\n")
  assert.ok(lines.includes("bundled:update devin agy"))
})

test("plugin updater reaches the real packaged updater through an installed --codex-cli-compat override, not itself", t => {
  // Regression for a reviewed-but-unreproduced recursion concern: the
  // plugin dispatcher's own local_updater auto-detection (no
  // AGENT_USAGE_PLUS_BASE_UPDATER override, exactly how Main.qml invokes it)
  // must resolve the installed ~/.local/bin/omarchy-agent-usage-update to the
  // safe compat wrapper the installer actually links it to, not back into
  // itself. `install.sh --codex-cli-compat` already targets the wrapper (see
  // "compat installer links both the collector and updater" above); this
  // proves the full default-detection chain reaches the real packaged
  // updater end to end instead of spinning or silently doing nothing.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agent-usage-e2e-"))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const bin = path.join(root, "bin")
  const data = path.join(root, "data")
  const packaged = path.join(root, "packaged-updater")
  const codex = path.join(root, "codex-collector")
  const bundled = path.join(root, "bundled-runner")
  const calls = path.join(root, "calls")
  executable(packaged, `printf 'packaged:%s\\n' "$*" >>"${calls}"`)
  executable(codex, `printf 'codex:%s\\n' "$*" >>"${calls}"; printf '%s\\n' '{"id":"codex","ready":true,"limits":[{"percent":0.1}]}'`)
  executable(bundled, `printf 'bundled:%s\\n' "$*" >>"${calls}"`)

  execFileSync("bash", [installer, "--codex-cli-compat"], {
    env: { ...process.env, XDG_BIN_HOME: bin, XDG_DATA_HOME: data },
  })

  execFileSync("bash", [pluginUpdater, "--force"], {
    env: {
      ...process.env,
      XDG_BIN_HOME: bin,
      XDG_STATE_HOME: path.join(root, "state"),
      AGENT_USAGE_PLUS_PACKAGED_UPDATER: packaged,
      AGENT_USAGE_PLUS_CODEX_COLLECTOR: codex,
      AGENT_USAGE_PLUS_BUNDLED_RUNNER: bundled,
    },
  })

  const lines = fs.readFileSync(calls, "utf8").trim().split("\n")
  assert.ok(lines.includes("packaged:--except codex --force --except devin --except agy"))
  assert.ok(lines.includes("codex:--force"))
})
