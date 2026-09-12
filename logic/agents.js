// Which coding agent a provider mark launches on right-click.
//
// Right-clicking a mark used to run `omarchy-agent --pick` with no argument.
// That script has no way to be told which agent to start: it reads
// ~/.config/omarchy/defaults/agent and launches that one. So with two marks in
// the bar, right-clicking *either* of them started the same default agent —
// right-clicking Claude opened a Codex terminal. The behavior only looked
// correct while the single visible provider happened to be the default.
//
// The command therefore has to be built here. Flags mirror
// /usr/share/omarchy/bin/omarchy-agent so a mark launches an agent exactly as
// Omarchy's own keybinding and menu do; the table is duplicated knowledge and
// is the one thing to re-check when Omarchy changes an agent's flags.
//
// A provider that is not a coding agent (fireworks, openrouter, deepseek, …)
// returns null: those marks report usage for an API key, there is no terminal
// to open, and the caller falls back to the picker.

var AGENT_COMMANDS = {
  claude: ["claude", "--permission-mode", "auto"],
  codex: ["codex", "--approve-for-me"],
  gemini: ["gemini", "--yolo"],
  copilot: ["copilot", "--allow-all"],
  crush: ["crush", "--yolo"],
  grok: ["grok", "--permission-mode", "bypassPermissions"],
  opencode: ["opencode", "--auto"],
  "opencode-go": ["opencode", "--auto"],
  omp: ["omp", "--auto-approve"],
  pi: ["pi"]
}

// A fixed app-id rather than the default org.omarchy.<binary>, so every agent
// window shares one class for window rules and themes — same reasoning, and
// same value, as omarchy-agent's own launch.
var LAUNCH_PREFIX = "omarchy-launch-tui --app-id=org.omarchy.agent"

// Agents refuse to remember trust for $HOME, so omarchy-agent starts in the
// work directory rather than re-asking on every session. The bar has to do the
// same or the terminal opens in $HOME: the shell's own cwd IS $HOME, so this
// branch is always taken for a click on the bar. Kept byte-identical to
// omarchy-agent's line, including leaving a cwd that isn't $HOME alone.
var WORKDIR_GUARD = '[[ $PWD == "$HOME" && -d $HOME/Work ]] && cd "$HOME/Work"; '

// Fallback for a provider with no agent of its own: the picker Omarchy shows
// when no default is set, which is what right-click did for every mark before.
var PICKER_COMMAND = "omarchy-agent --pick"

// Returns the shell command that opens `providerId`'s agent, or "" when that
// provider has no agent. Only ids present in the table above are ever
// interpolated, so a record-supplied id can never reach the command line even
// if it slipped past Main.qml's sanitizeProviderId().
function agentCommandFor(providerId) {
  var id = typeof providerId === "string" ? providerId : ""
  var command = AGENT_COMMANDS[id]
  if (!command || !Object.prototype.hasOwnProperty.call(AGENT_COMMANDS, id)) return ""
  return WORKDIR_GUARD + LAUNCH_PREFIX + " " + command.join(" ")
}

// The command a right-click should run for a mark: that provider's agent when
// it has one, the picker otherwise.
function launchCommandFor(providerId) {
  return agentCommandFor(providerId) || PICKER_COMMAND
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    AGENT_COMMANDS: AGENT_COMMANDS,
    PICKER_COMMAND: PICKER_COMMAND,
    WORKDIR_GUARD: WORKDIR_GUARD,
    agentCommandFor: agentCommandFor,
    launchCommandFor: launchCommandFor
  }
}
