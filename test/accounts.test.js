"use strict"
const test = require("node:test")
const assert = require("node:assert/strict")
const Accounts = require("../logic/accounts.js")

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
