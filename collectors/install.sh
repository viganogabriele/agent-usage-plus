#!/usr/bin/env bash
set -euo pipefail

# Install this self-contained package under XDG_DATA_HOME.  Optional Omarchy
# integration adds *symlinks* to an existing writable Omarchy bin directory;
# it never edits Omarchy's updater or plugin files.

source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Omarchy may expose ~/.local/share/omarchy as a symlink to its root-owned
# packaged assets. Keep this companion package in its own XDG-data directory.
data_root=${XDG_DATA_HOME:-"$HOME/.local/share"}/agent-usage-plus-collectors
omarchy_bin=""
enable_timer=false
with_transcript_cost=false
codex_cli_compat=false

usage() {
  cat <<'EOF'
Usage: ./collectors/install.sh [--omarchy-bin DIR] [--enable-timer] [--with-transcript-cost] [--codex-cli-compat]

Installs collectors into $XDG_DATA_HOME/agent-usage-plus-collectors.
--omarchy-bin DIR additionally links the bundled omarchy-agent-usage-* commands
into a writable Omarchy bin directory so Omarchy's usage updater invokes them.
--enable-timer installs a 10-minute user-level systemd timer for the standalone
runner. It is useful when the Omarchy bin directory is not user-writable.
--with-transcript-cost additionally links cost-decorating Claude/Codex wrappers.
--codex-cli-compat installs a user-level compatibility override for an Omarchy
Codex collector that still passes the removed Codex CLI value `-a untrusted`.
An existing user collector is moved once to a recoverable
`agent-usage-plus-base-<provider>` file which the wrapper runs as its base
scanner; that name deliberately stays outside Omarchy's collector glob.
EOF
}

while (($#)); do
  case "$1" in
    --omarchy-bin) omarchy_bin=${2:?--omarchy-bin needs a directory}; shift 2 ;;
    --enable-timer) enable_timer=true; shift ;;
    --with-transcript-cost) with_transcript_cost=true; shift ;;
    --codex-cli-compat) codex_cli_compat=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if $with_transcript_cost && [[ -z $omarchy_bin ]]; then
  echo "--with-transcript-cost requires --omarchy-bin DIR" >&2
  exit 2
fi

mkdir -p "$data_root"
mkdir -p "$data_root/agent_usage_collectors"
cp -a "$source_root/agent_usage_collectors/." "$data_root/agent_usage_collectors/"
mkdir -p "$data_root/bin"
cp -a "$source_root/bin/." "$data_root/bin/"
mkdir -p "$data_root/scripts" "$data_root/logic"
cp -a "$(dirname "$source_root")/scripts/calculate-api-cost" "$data_root/scripts/"
cp -a "$(dirname "$source_root")/logic/cost.js" "$(dirname "$source_root")/logic/api-price-catalogue.js" "$data_root/logic/"
chmod 0755 "$data_root/bin/agent-usage-plus-collectors" "$data_root/bin/omarchy-agent-usage-openrouter" "$data_root/bin/omarchy-agent-usage-deepseek" "$data_root/bin/omarchy-agent-usage-xai" "$data_root/bin/omarchy-agent-usage-zai" "$data_root/bin/omarchy-agent-usage-gemini" "$data_root/bin/omarchy-agent-usage-cursor" "$data_root/bin/omarchy-agent-usage-kimi" "$data_root/bin/omarchy-agent-usage-opencode-go" "$data_root/bin/omarchy-agent-usage-claude-cost" "$data_root/bin/omarchy-agent-usage-codex-cost" "$data_root/scripts/calculate-api-cost"
chmod 0755 "$data_root/bin/omarchy-agent-usage-codex-compat" "$data_root/bin/omarchy-agent-usage-update"

if $codex_cli_compat; then
  user_bin=${XDG_BIN_HOME:-"$HOME/.local/bin"}
  target="$user_bin/omarchy-agent-usage-codex"
  compat="$data_root/bin/omarchy-agent-usage-codex-compat"
  updater_target="$user_bin/omarchy-agent-usage-update"
  updater="$data_root/bin/omarchy-agent-usage-update"
  mkdir -p "$user_bin"
  if [[ -e $target || -L $target ]]; then
    resolved=$(readlink -f "$target" 2>/dev/null || true)
    [[ $resolved == "$compat" ]] || { echo "Refusing to replace an existing local Codex collector: $target" >&2; exit 1; }
  fi
  if [[ -e $updater_target || -L $updater_target ]]; then
    resolved=$(readlink -f "$updater_target" 2>/dev/null || true)
    [[ $resolved == "$updater" ]] || { echo "Refusing to replace an existing local usage updater: $updater_target" >&2; exit 1; }
  fi
  ln -sfn "$compat" "$target"
  ln -sfn "$updater" "$updater_target"
fi

if [[ -n $omarchy_bin ]]; then
  [[ -d $omarchy_bin && -w $omarchy_bin ]] || { echo "Not a writable Omarchy bin directory: $omarchy_bin" >&2; exit 1; }
  ln -sfn "$data_root/bin/omarchy-agent-usage-openrouter" "$omarchy_bin/omarchy-agent-usage-openrouter"
  ln -sfn "$data_root/bin/omarchy-agent-usage-deepseek" "$omarchy_bin/omarchy-agent-usage-deepseek"
  ln -sfn "$data_root/bin/omarchy-agent-usage-xai" "$omarchy_bin/omarchy-agent-usage-xai"
  ln -sfn "$data_root/bin/omarchy-agent-usage-zai" "$omarchy_bin/omarchy-agent-usage-zai"
  ln -sfn "$data_root/bin/omarchy-agent-usage-gemini" "$omarchy_bin/omarchy-agent-usage-gemini"
  ln -sfn "$data_root/bin/omarchy-agent-usage-cursor" "$omarchy_bin/omarchy-agent-usage-cursor"
  ln -sfn "$data_root/bin/omarchy-agent-usage-kimi" "$omarchy_bin/omarchy-agent-usage-kimi"
  ln -sfn "$data_root/bin/omarchy-agent-usage-opencode-go" "$omarchy_bin/omarchy-agent-usage-opencode-go"
  if $with_transcript_cost; then
    for provider in claude codex; do
      target="$omarchy_bin/omarchy-agent-usage-$provider"
      backup="$omarchy_bin/agent-usage-plus-base-$provider"
      if [[ -e $target && ! -L $target ]]; then
        [[ ! -e $backup ]] || { echo "Refusing to replace $target: backup already exists at $backup" >&2; exit 1; }
        mv "$target" "$backup"
      elif [[ -L $target && $(readlink -f "$target") != "$data_root/bin/omarchy-agent-usage-$provider-cost" ]]; then
        echo "Refusing to replace an unknown symlink: $target" >&2
        exit 1
      fi
      ln -sfn "$data_root/bin/omarchy-agent-usage-$provider-cost" "$target"
    done
  fi
fi

if $enable_timer; then
  unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
  mkdir -p "$unit_dir"
  cat > "$unit_dir/agent-usage-plus-collectors.service" <<EOF
[Unit]
Description=Refresh Agent Usage Plus API-provider records

[Service]
Type=oneshot
ExecStart=$data_root/bin/agent-usage-plus-collectors update
EOF
  cat > "$unit_dir/agent-usage-plus-collectors.timer" <<'EOF'
[Unit]
Description=Periodically refresh Agent Usage Plus API-provider records

[Timer]
OnBootSec=1m
OnUnitActiveSec=10m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now agent-usage-plus-collectors.timer
fi

printf 'Installed collectors at %s\n' "$data_root"
printf 'Run: %s/bin/agent-usage-plus-collectors update\n' "$data_root"
