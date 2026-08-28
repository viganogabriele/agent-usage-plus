# Agent Usage Plus collectors

This is the plugin's **supported companion package** for providers with a
useful account budget or subscription-usage source. It is intentionally
dependency-free Python (3.10+) and does not send a credential anywhere other
than the corresponding provider endpoint. The plugin remains usable without
it; these collectors publish additional records into the same state directory
the panel already watches.

| Provider | What the collector reads | First-class credential state |
|---|---|---|
| OpenRouter | current API key's optional spending limit, remaining budget, and usage from `GET /api/v1/auth/key` | `OPENROUTER_API_KEY` or `collectors.json` entry; otherwise **Waiting for API key** tells the user exactly how to set one |
| DeepSeek | account's available credit ledger from `GET /user/balance` | `DEEPSEEK_API_KEY` or `collectors.json` entry; otherwise **Waiting for API key** tells the user exactly how to set one |
| xAI / Grok | team's authoritative prepaid API-credit balance from xAI's Management API | `XAI_MANAGEMENT_API_KEY` (not an inference `XAI_API_KEY`); team-scoped keys discover the team automatically, organization keys also need `XAI_TEAM_ID` |
| Z.AI / GLM | Coding Plan quota windows from the read-only monitor endpoint (`/api/monitor/usage/quota/limit`), with global and China-region hosts and optional team scope | `Z_AI_API_KEY`/`ZAI_API_KEY` or a China-region alias (`BIGMODEL_API_KEY`, `ZHIPU_API_KEY`, `ZHIPUAI_API_KEY`, `GLM_API_KEY`); missing key, invalid region/scope, missing team selectors, rejected key, and endpoint failures are separate visible states |
| Gemini | Gemini CLI's Code Assist model quota buckets from `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` | Gemini CLI Google sign-in credentials in `~/.gemini/oauth_creds.json`, or an explicit short-lived `GEMINI_ACCESS_TOKEN`; otherwise **Waiting for Gemini sign-in** explains the required Google-login flow |
| Cursor | personal subscription pools from Cursor dashboard's `GET /api/usage-summary`, using the locally signed-in Cursor IDE or `cursor-agent` session | Cursor IDE/cursor-agent sign-in; otherwise **Waiting for Cursor sign-in** tells the user to sign in locally. Team accounts without a per-user meter report a clear unavailable status rather than an invented percentage |
| Kimi | weekly Coding Plan quota and any 5-hour rolling window from `GET /coding/v1/usages` | `KIMI_API_KEY` or `collectors.json` entry; otherwise **Waiting for API key** gives the exact setup path |
| OpenCode Go | local session/token stats from opencode's own SQLite store, plus the authoritative rolling/weekly/monthly allowances from Zen's `GET /zen/go/v1/usage` | `opencode auth login` sign-in read from `~/.local/share/opencode/auth.json`; otherwise **Waiting for auth** — local stats still show without it |
| Claude Code | existing local transcript collector, decorated with published API pricing | no new credential; the base Claude collector retains its own sign-in state |
| Codex | existing local transcript collector, decorated with published API pricing | no new credential; the base Codex collector retains its own sign-in state |

Both endpoint references are provider documentation: [OpenRouter current-key
metadata](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)
and [DeepSeek balance](https://api-docs.deepseek.com/api/get-user-balance).
OpenRouter's endpoint is a *per-key* budget: if the key has no configured
spending limit the record deliberately says “no key budget” instead of
mistaking account credit for one. DeepSeek can return both CNY and USD
ledgers; the panel record has one currency slot, so USD is preferred when
present and otherwise the first provider-returned ledger is shown.

## Install and run

From a clone of this repository:

```bash
./collectors/install.sh
~/.local/share/agent-usage-plus-collectors/bin/agent-usage-plus-collectors update
```

The runner atomically writes `openrouter.json`, `deepseek.json`, `xai.json`,
`zai.json`, `gemini.json`, `cursor.json`, `kimi.json`, and `opencode-go.json` under
`$XDG_STATE_HOME/omarchy/agents/usage` (default
`~/.local/state/omarchy/agents/usage`). Run either collector directly when
you want to inspect only its JSON output:

```bash
~/.local/share/agent-usage-plus-collectors/bin/omarchy-agent-usage-openrouter
```

To refresh in the background without modifying Omarchy, install the optional
user timer. It runs at boot and every ten minutes:

```bash
./collectors/install.sh --enable-timer
systemctl --user status agent-usage-plus-collectors.timer
```

To have Omarchy's own `omarchy agent usage-update` invoke the collectors on
its normal refresh, explicitly choose a *writable* Omarchy bin directory:

```bash
./collectors/install.sh --omarchy-bin "$OMARCHY_PATH/bin"
```

The installer refuses a non-writable target; it never uses `sudo` or modifies
Omarchy's updater. If your distribution's `$OMARCHY_PATH/bin` is
root-owned (as `/usr/share/omarchy/bin` normally is), use the timer, or ask
your system administrator to install the two symlinks. Re-run `install.sh`
after updating this repository; it replaces only its own package and symlinks.

If a recent Codex CLI is logged in but Codex shows local totals with
`Codex limits unavailable`, an older Omarchy collector may still pass the
removed `-a untrusted` approval mode. Install the explicit user-level
compatibility override:

```bash
./collectors/install.sh --codex-cli-compat
omarchy agent usage-update --force codex
```

It links `~/.local/bin/omarchy-agent-usage-codex` and the companion updater
that the plugin prefers, never edits `/usr/share/omarchy`, and refuses to
replace another local override. The updater delegates every provider except
Codex to Omarchy's packaged command.

## Claude and Codex API-cost estimates

`omarchy-agent-usage-claude-cost` and `omarchy-agent-usage-codex-cost` run an
existing local transcript collector, then add the versioned `cost` block from
the repository's official-rate catalogue. They never send transcript content,
credentials, or usage to a network endpoint. A used model without an exact
price is excluded from the subtotal and the resulting estimate is explicitly
marked partial, never silently treated as zero.

Run either wrapper directly to inspect the resulting record. The Claude
wrapper defaults to Omarchy's packaged scanner. For Codex or a custom scanner,
point it at the preserved base executable:

```bash
AGENT_USAGE_PLUS_CODEX_BASE_COLLECTOR="$HOME/.local/bin/omarchy-agent-usage-codex" \
  ./collectors/bin/omarchy-agent-usage-codex-cost | jq '.cost'
```

With `--with-transcript-cost`, an existing regular user collector is moved
once to a recoverable `agent-usage-plus-base-<provider>` file; the wrapper
prefers that preserved scanner over the packaged copy and then adds cost. The backup name is outside
Omarchy's collector-discovery pattern, so it is never shown as a duplicate
provider. Unknown symlinks and a pre-existing backup stop the install rather
than being overwritten. See
[`../docs/cost-estimation.md`](../docs/cost-estimation.md) for price-list
version and model-coverage rules.

## Credentials and error states

Use an environment variable for a one-off/manual run:

```bash
export OPENROUTER_API_KEY='…'
export DEEPSEEK_API_KEY='…'
export XAI_MANAGEMENT_API_KEY='…'
# Only needed for an organization-scoped xAI management key:
export XAI_TEAM_ID='…'
export ZAI_API_KEY='…'
export KIMI_API_KEY='…'
```

For a user timer, where an interactive shell's environment is usually not
available, create this **mode 600** file instead:

```json
{
  "openrouter": { "apiKey": "…" },
  "deepseek": { "apiKey": "…" },
  "xai": { "managementKey": "…", "teamId": "optional-team-id" },
  "zai": { "apiKey": "…", "region": "global", "usageScope": "personal" },
  "kimi": { "apiKey": "…" }
}
```

Save it as `~/.config/omarchy/agent-usage-plus/collectors.json` and run
`chmod 600 ~/.config/omarchy/agent-usage-plus/collectors.json`. A group- or
world-readable file is deliberately ignored and reported as missing auth.
Never commit this file or paste its contents into an issue.

Missing or rejected credentials produce the panel's documented non-retrying
auth state, with the exact remediation above. A DNS, connection, or timeout
failure produces “usage unavailable”, includes a network instruction, and
sets `retryAdvised: true`; a real 4xx/5xx provider response does not retry
aggressively. A successful call is account-scoped and leaves local token
stats absent rather than inventing transcript numbers the APIs do not offer.

### xAI / Grok details

xAI deliberately separates ordinary inference keys from Management API keys.
The latter have the documented billing endpoints, so this collector does not
accept `XAI_API_KEY` as if it could fetch personal usage. Create a Management
Key in **xAI Console → Settings → Management Keys** and grant the needed
billing read access. Its validation endpoint yields the team ID for a
team-scoped key. For an organization-scoped key, copy the Team ID from **xAI
Console → Team settings** into `XAI_TEAM_ID`/`xai.teamId`. The collector calls
only the documented validation endpoint and `GET
/v1/billing/teams/{team_id}/prepaid/balance`; the latter's signed cents are
converted to the positive USD balance rendered by the panel. It does not
mislabel a prepaid balance as a subscription quota or fabricate token counts.

References: [xAI Management API guide](https://docs.x.ai/developers/management-api-guide)
and [xAI Billing Management reference](https://docs.x.ai/developers/rest-api-reference/management/billing).

### Z.AI / GLM details

The collector uses the read-only quota endpoint used by supported Z.AI
coding-tool integrations. Global keys use `api.z.ai`; China-region keys use
`open.bigmodel.cn`. Set `Z_AI_REGION=bigmodel-cn` for the China host. The
personal response is mapped to its shortest and longest token/credit windows;
an optional MCP time limit is shown separately. Team scope appends `type=2`
and requires both `Z_AI_ORGANIZATION` and `Z_AI_PROJECT`, because the provider
returns an empty successful response when either selector is missing.

The collector never scrapes the console or makes a paid model request. An
unfamiliar response is reported as unavailable instead of becoming a fake
zero meter. References: [Z.AI API authentication](https://docs.z.ai/api-reference/introduction),
[Coding Plan FAQ](https://docs.z.ai/devpack/faq), [Usage Policy](https://docs.z.ai/devpack/usage-policy),
and the read-only quota integration documented by [CodexBar](https://github.com/steipete/CodexBar/blob/main/docs/zai.md).

## Endpoint stability and provider coverage

OpenRouter, DeepSeek, and Z.AI's quota route are provider APIs. Gemini's Code Assist
quota RPC is called by the [official Gemini CLI source](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/code_assist/server.ts),
but is not a public API contract. Cursor's `usage-summary` route is the
dashboard's own undocumented endpoint, and Kimi's Coding Plan route is
community-confirmed rather than formally documented. The three parsers fail
closed on an unfamiliar response: the panel shows “usage unavailable” instead
of a fabricated zero meter. Their exact expected response shapes are covered
by offline tests.

Gemini API-key and Vertex API usage are deliberately not represented by the
Gemini subscription collector: Google exposes per-project billing/quota in its
Cloud console, not a universal account-level balance endpoint. Likewise,
Cursor team accounts that omit `individualUsage.plan` do not have a usable
per-seat percentage in this endpoint. Those states are shown plainly, rather
than being mistaken for no usage.

## Development

```bash
PYTHONPATH=collectors python -m unittest discover -s collectors/tests -v
```

Tests exercise parsing and every error-state classification without a real
credential or network request.
