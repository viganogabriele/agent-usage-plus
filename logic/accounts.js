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
    if (name) {
      result[id] = { provider: provider, name: name }
      if (typeof profile.path === "string" && profile.path.trim()) result[id].path = profile.path.trim()
    }
  }
  return result
}

function nextProfileId(provider, name, existing) {
  if (provider !== "claude" && provider !== "codex") return ""
  var label = String(name || "").trim()
  if (!label) return ""
  var slug = label.toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^[-_]+|-+$/g, "").slice(0, 48) || "account"
  var base = provider + "-" + slug
  var id = base
  var suffix = 2
  while (Object.prototype.hasOwnProperty.call(existing || {}, id)) id = base + "-" + suffix++
  return id
}

// Merge just the edited entries into the latest settings. A null entry stages
// a removal without mutating the live object or another provider's choices.
function applyEdits(current, edits) {
  var result = Object.assign({}, current)
  for (var key of Object.keys(edits)) {
    if (edits[key] === null) delete result[key]
    else result[key] = edits[key]
  }
  return result
}

// Both interactive discovery and the diagnostic IPC use the same path
// deduplication, including duplicates within one parent-directory import.
function newProfiles(current, candidates) {
  var all = Object.assign({}, current)
  var additions = {}
  for (var candidate of candidates) {
    if (!candidate) continue
    var id = nextProfileId(candidate.provider, candidate.name, all)
    if (!id) continue
    var profile = { provider: candidate.provider, name: candidate.name.trim().slice(0, 80) }
    if (candidate.path) {
      profile.path = candidate.path
      if (Object.keys(all).some(function(key) {
        return all[key].provider === profile.provider && all[key].path === profile.path
      })) continue
    }
    all[id] = additions[id] = profile
  }
  return additions
}

function activeId(provider, profiles, selected) {
  var id = selected && selected[provider]
  return id && profiles[id] && profiles[id].provider === provider ? id : provider
}

function quote(value) { return "'" + String(value).replace(/'/g, "'\\''") + "'" }

function commandForProfile(id, provider, dataRoot, login, path, home) {
  if (!PROFILE_ID.test(id) || id.split("-")[0] !== provider) return ""
  var directory = String(dataRoot || "") + "/agent-usage-plus-accounts/" + id
  var native = path ? String(path).replace(/^~(?=\/|$)/, function() { return String(home || "") }) : directory + "/" + provider
  var cleanEnv = "env " + AUTH_ENV[provider].map(function(name) { return "-u " + name }).join(" ") + " "
  if (provider === "claude")
    return cleanEnv + "CLAUDE_CONFIG_DIR=" + quote(native)
      + " claude" + (login ? " auth login" : " --permission-mode auto")
  return cleanEnv + "CODEX_HOME=" + quote(native)
    + " codex" + (login ? " login" : "") + (path ? "" : " -c cli_auth_credentials_store=file")
}

if (typeof module !== "undefined" && module.exports)
  module.exports = { normalizeProfiles, nextProfileId, newProfiles, applyEdits, activeId, commandForProfile }
