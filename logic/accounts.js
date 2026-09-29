// Public profile metadata only. Credentials remain in the provider CLIs.
var PROFILE_ID = /^(claude|codex)-[a-z0-9][a-z0-9_-]{0,55}$/
var AUTH_ENV = {
  claude: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_OAUTH_SCOPES",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS"],
  codex: ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
    "OPENAI_FEDERATION_RULE_ID", "OPENAI_IDENTITY_TOKEN_FILE"]
}

function normalizeProfiles(raw) {
  var result = {}
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return result
  for (var id in raw) {
    if (!Object.prototype.hasOwnProperty.call(raw, id) || !PROFILE_ID.test(id)) continue
    var profile = raw[id]
    var provider = id.split("-")[0]
    if (!profile || profile.provider !== provider || typeof profile.name !== "string") continue
    var name = profile.name.trim().slice(0, 80)
    if (name) result[id] = { provider: provider, name: name }
  }
  return result
}

function nextProfileId(provider, name, existing) {
  if (provider !== "claude" && provider !== "codex") return ""
  var slug = String(name || "").toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48)
  if (!slug) return ""
  var base = provider + "-" + slug
  var id = base
  var suffix = 2
  while (Object.prototype.hasOwnProperty.call(existing || {}, id)) id = base + "-" + suffix++
  return id
}

function quote(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'" }

function commandForProfile(id, provider, dataRoot, login) {
  if (!PROFILE_ID.test(id) || id.split("-")[0] !== provider) return ""
  var directory = String(dataRoot || "") + "/agent-usage-plus-accounts/" + id
  var cleanEnv = "env " + AUTH_ENV[provider].map(function(name) { return "-u " + name }).join(" ") + " "
  if (provider === "claude")
    return cleanEnv + "CLAUDE_CONFIG_DIR=" + quote(directory + "/claude")
      + " claude" + (login ? " auth login" : " --permission-mode auto")
  return cleanEnv + "CODEX_HOME=" + quote(directory + "/codex")
    + " codex" + (login ? " login -c cli_auth_credentials_store=file" : " -c cli_auth_credentials_store=file --approve-for-me")
}

if (typeof module !== "undefined" && module.exports)
  module.exports = { normalizeProfiles, nextProfileId, commandForProfile }
