"use strict"

const test = require("node:test")
const assert = require("node:assert/strict")

const Notify = require("../logic/notifications.js")

test("command: uses Omarchy's supported notification transport", () => {
  assert.deepEqual(Notify.command("Agent Usage Plus", "Test notification", "normal"), [
    "omarchy", "notification", "send",
    "--app-name", "Agent Usage Plus",
    "-u", "normal",
    "Agent Usage Plus", "Test notification"
  ])
})

test("command: keeps untrusted summary and body as discrete arguments", () => {
  assert.deepEqual(Notify.command("Provider --exec", "-50% available", "critical").slice(-2), [
    "Provider --exec", "-50% available"
  ])
})

test("command: falls back to normal urgency", () => {
  assert.equal(Notify.command("Title", "Body", "unexpected")[6], "normal")
})
