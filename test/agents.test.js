"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")

const Agents = require("../logic/agents.js")

test("agentCommandFor: each provider gets its own agent, not a shared default", () => {
  const claude = Agents.agentCommandFor("claude")
  const codex = Agents.agentCommandFor("codex")

  assert.notEqual(claude, codex)
  assert.match(claude, /\bclaude --permission-mode auto$/)
  assert.match(codex, /\bcodex --approve-for-me$/)
})

test("agentCommandFor: launches with omarchy-agent's own app-id", () => {
  for (const id of Object.keys(Agents.AGENT_COMMANDS)) {
    assert.match(
      Agents.agentCommandFor(id),
      /; omarchy-launch-tui --app-id=org\.omarchy\.agent /,
      `${id} should share the org.omarchy.agent window class`
    )
  }
})

test("agentCommandFor: starts in the work directory, like omarchy-agent does", () => {
  // The shell's cwd is $HOME, so without this the terminal opens there and the
  // agent re-asks for trust on every session.
  for (const id of Object.keys(Agents.AGENT_COMMANDS))
    assert.ok(
      Agents.agentCommandFor(id).startsWith(Agents.WORKDIR_GUARD),
      `${id} should cd to the work directory first`
    )

  assert.match(Agents.WORKDIR_GUARD, /\$PWD == "\$HOME"/)
  assert.match(Agents.WORKDIR_GUARD, /cd "\$HOME\/Work"/)
})

test("agentCommandFor: OpenCode Go launches the opencode agent", () => {
  assert.equal(Agents.agentCommandFor("opencode-go"), Agents.agentCommandFor("opencode"))
  assert.match(Agents.agentCommandFor("opencode-go"), /\bopencode --auto$/)
})

test("agentCommandFor: a provider that is not an agent has no command", () => {
  for (const id of ["fireworks", "openrouter", "deepseek", "cursor", "kimi", "xai", "zai"])
    assert.equal(Agents.agentCommandFor(id), "")
})

test("agentCommandFor: unknown, empty and non-string ids are never interpolated", () => {
  for (const id of ["", "nope", "claude; rm -rf ~", "__proto__", "toString", "constructor",
    null, undefined, 7, {}, ["claude"]])
    assert.equal(Agents.agentCommandFor(id), "")
})

test("launchCommandFor: falls back to the picker only when there is no agent", () => {
  assert.equal(Agents.launchCommandFor("claude"), Agents.agentCommandFor("claude"))
  assert.equal(Agents.launchCommandFor("fireworks"), Agents.PICKER_COMMAND)
  assert.equal(Agents.launchCommandFor(""), Agents.PICKER_COMMAND)
})
