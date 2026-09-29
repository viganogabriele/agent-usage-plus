# Multiple Claude and Codex accounts

Open the widget's **Settings → Accounts**, choose Claude or Codex, enter a
recognizable name, and select **Add**. Use **Sign in** on the new row to complete
the provider's normal browser login once. Back in the usage panel, open Claude
or Codex to compare the accounts' current limits; select a row to see its full
windows and reset times. **Use** chooses the account shown in the bar. Right
clicking its bar mark starts a new CLI session with that account.

The original `claude` and `codex` logins remain the default account for each
provider. Additional logins use directories under
`$XDG_DATA_HOME/agent-usage-plus-accounts/<provider>-<name>` (or
`~/.local/share/agent-usage-plus-accounts` when XDG_DATA_HOME is unset).
Claude runs with `CLAUDE_CONFIG_DIR`; Codex runs with `CODEX_HOME` and file-based
credential storage. The widget stores only account IDs, names, and the active
choice in its settings. The providers' CLIs handle their own credentials.

Choosing an account affects new CLI sessions launched from the widget. It
doesn't change terminals or sessions already running, nor a `claude` or
`codex` command typed in another terminal. Removing an account from Settings
removes its usage record on the next refresh but leaves its CLI directory in
place, so an accidental removal doesn't destroy a login or its history.

Each extra account has its own limit record and native transcript stats. The
shared pi/omp and OpenCode histories cannot be assigned reliably to a specific
login, so those histories are excluded from extra account records. A freshly
added account shows **Waiting for auth** until its login is completed. Expired
logins and endpoint failures retain the collector's explicit status.

Claude Code documents separate configuration directories for simultaneous
accounts. Its documentation notes one exception: two Claude Console sign-ins
without API keys are not isolated by `CLAUDE_CONFIG_DIR`. Codex can use either
file or keyring credentials; this feature sets file storage within each
additional `CODEX_HOME`.

- [Claude Code authentication](https://code.claude.com/docs/en/authentication)
- [Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Codex configuration](https://learn.chatgpt.com/docs/config-file/config-advanced)
