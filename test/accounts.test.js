"use strict"
const test = require("node:test")
const assert = require("node:assert/strict")
const Accounts = require("../logic/accounts.js")

test("existing account directories survive settings and select the same CLI home", () => {
  const profiles = Accounts.normalizeProfiles({
    "codex-personal": { provider: "codex", name: "Personal", path: "~/.codex-t3/personal" }
  })
  assert.equal(profiles["codex-personal"].path, "~/.codex-t3/personal")
  const command = Accounts.commandForProfile("codex-personal", "codex", "/tmp/data", false,
    profiles["codex-personal"].path, "/home/user")
  assert.match(command, /CODEX_HOME='\/home\/user\/\.codex-t3\/personal' codex$/)
})

test("profiles retain only named Claude and Codex accounts with safe ids", () => {
  assert.deepEqual(Accounts.normalizeProfiles({
    "claude-work": { provider: "claude", name: " Work " },
    "codex-home": { provider: "codex", name: "Personal" },
    "claude-../oops": { provider: "claude", name: "Bad" },
    "codex-wrong": { provider: "claude", name: "Wrong" }
  }), {
    "claude-work": { provider: "claude", name: "Work" },
    "codex-home": { provider: "codex", name: "Personal" }
  })
})

test("new profile ids remain unique and filename safe", () => {
  assert.equal(Accounts.nextProfileId("claude", "Work account", {}), "claude-work-account")
  assert.equal(Accounts.nextProfileId("claude", "Work account", { "claude-work-account": {} }), "claude-work-account-2")
  assert.equal(Accounts.nextProfileId("gemini", "Work", {}), "")
})

test("profile commands select the matching CLI directory without interpolating labels", () => {
  const path = "/home/user's/data"
  assert.match(Accounts.commandForProfile("claude-work", "claude", path, false),
    /CLAUDE_CONFIG_DIR='\/home\/user'\\''s\/data\/agent-usage-plus-accounts\/claude-work\/claude' claude --permission-mode auto$/)
  assert.match(Accounts.commandForProfile("claude-work", "claude", path, false), /-u ANTHROPIC_API_KEY/)
  assert.match(Accounts.commandForProfile("codex-work", "codex", path, true), /codex login -c cli_auth_credentials_store=file$/)
  assert.equal(Accounts.commandForProfile("codex-work", "claude", path, false), "")
  assert.equal(Accounts.commandForProfile("claude-$(whoami)", "claude", path, false), "")
})

test("account drafts merge with unrelated live changes and keep discovery ids stable", () => {
  const current = {
    "claude-work": { provider: "claude", name: "Work" },
    "codex-first": { provider: "codex", name: "First", path: "/accounts/first" }
  }
  const imported = { provider: "codex", name: "_Work", path: "/accounts/second" }
  const added = Accounts.newProfiles(current, [current["codex-first"], imported, imported,
    { provider: "claude", name: "仕事" }, { provider: "codex", name: "_Work" }])
  assert.deepEqual(Object.keys(added), ["codex-work", "claude-account", "codex-work-2"])
  assert.deepEqual(Accounts.normalizeProfiles(added), added)
  const edits = { ...added, "codex-first": null }
  const external = { provider: "claude", name: "Lab" }
  const merged = Accounts.applyEdits({ ...current, "claude-lab": external }, edits)
  assert.deepEqual(merged, { "claude-work": current["claude-work"], "claude-lab": external, ...added })
  assert.equal(current["codex-first"].name, "First")
  assert.deepEqual(Accounts.newProfiles(merged, [imported]), {})
})

test("launch account falls back to default for removed, missing and foreign profiles", () => {
  const profiles = { "codex-work": { provider: "codex", name: "Work" } }
  const selected = { codex: "codex-work", claude: "codex-work" }
  assert.equal(Accounts.activeId("codex", profiles, {}), "codex")
  assert.equal(Accounts.activeId("codex", profiles, selected), "codex-work")
  assert.equal(Accounts.activeId("claude", profiles, selected), "claude")
  assert.equal(Accounts.activeId("codex", Accounts.applyEdits(profiles, { "codex-work": null }), selected), "codex")
})
