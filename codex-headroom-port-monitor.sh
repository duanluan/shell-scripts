#!/bin/bash
#===============================================================
# title:         codex-headroom-port-monitor.sh
# description:   监控 Codex 配置变化，并恢复 Headroom 作为当前供应商
# author:        duanluan<duanluan@outlook.com>
# date:          2026-06-25
# version:       v1.0
#===============================================================

set -u

CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
HEADROOM_MANIFEST="${HEADROOM_MANIFEST:-$HOME/.headroom/deploy/default/manifest.json}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"
DEFAULT_HEADROOM_PORT="${DEFAULT_HEADROOM_PORT:-15721}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

is_valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

resolve_headroom_port() {
  local port="${HEADROOM_PORT:-}"

  if [ -z "$port" ] && [ -f "$HEADROOM_MANIFEST" ]; then
    if command -v jq >/dev/null 2>&1; then
      port="$(jq -r '.base_env.HEADROOM_PORT // .port // empty' "$HEADROOM_MANIFEST" 2>/dev/null)"
    else
      port="$(
        sed -n 's/.*"HEADROOM_PORT"[[:space:]]*:[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' "$HEADROOM_MANIFEST" |
          head -n 1
      )"
      if [ -z "$port" ]; then
        port="$(
          sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEADROOM_MANIFEST" |
            head -n 1
        )"
      fi
    fi
  fi

  if [ -z "$port" ]; then
    port="$DEFAULT_HEADROOM_PORT"
  fi

  if ! is_valid_port "$port"; then
    log "Error: invalid Headroom port: $port"
    return 1
  fi

  printf '%s\n' "$port"
}

rewrite_codex_config() {
  local port headroom_url tmp backup

  if [ ! -f "$CODEX_CONFIG" ]; then
    log "Waiting for Codex config: $CODEX_CONFIG"
    return 0
  fi

  port="$(resolve_headroom_port)" || return 1
  headroom_url="http://127.0.0.1:${port}/v1"
  tmp="${CODEX_CONFIG}.headroom-monitor.$$"

  HEADROOM_URL="$headroom_url" perl -0pe '
    my $url = $ENV{HEADROOM_URL};
    my $proxy_marker = "# --- Headroom proxy (auto-injected by headroom wrap codex) ---";
    my $end_marker = "# --- end Headroom ---";

    s/\n?# --- Headroom proxy \(auto-injected by headroom wrap codex\) ---\n.*?\n# --- end Headroom ---\n?/\n/gs;
    s/\n?# --- Headroom MCP server ---\n\[mcp_servers\.headroom\]\n(?:[^\n]*\n)*?(?=\n?\[|\n?# ---|\z)/\n/gs;
    s/\n?\[mcp_servers\.headroom\]\n(?:[^\n]*\n)*?(?=\n?\[|\n?# ---|\z)/\n/gs;
    s/\n?\[model_providers\.headroom\]\n(?:[^\n]*\n)*?(?=\n?\[|\n?# ---|\z)/\n/gs;

    if (/\A(.*?)(^\[.*\z)/ms) {
      my ($top_level, $rest) = ($1, $2);
      $top_level =~ s/^[ \t]*openai_base_url[ \t]*=.*\n?//mg;
      $_ = $top_level . $rest;
    } else {
      s/^[ \t]*openai_base_url[ \t]*=.*\n?//mg;
    }

    if (/^[ \t]*model_provider[ \t]*=/m) {
      s/^[ \t]*model_provider[ \t]*=.*$/model_provider = "headroom"/m;
    } else {
      s/\A/model_provider = "headroom"\n/;
    }

    s/\n{3,}/\n\n/gs;
    s/\A\s+//s;
    s/\s+\z/\n/s;

    $_ = "$proxy_marker\nopenai_base_url = \"$url\"\n$end_marker\n\n" . $_;
    $_ .= "\n# --- Headroom MCP server ---\n";
    $_ .= "[mcp_servers.headroom]\n";
    $_ .= "command = \"headroom\"\n";
    $_ .= "args = [\"mcp\", \"serve\"]\n\n";
    $_ .= "$proxy_marker\n";
    $_ .= "[model_providers.headroom]\n";
    $_ .= "name = \"OpenAI via Headroom proxy\"\n";
    $_ .= "base_url = \"$url\"\n";
    $_ .= "supports_websockets = true\n";
    $_ .= "env_http_headers = { \"X-Headroom-Project\" = \"HEADROOM_PROJECT\" }\n";
    $_ .= "$end_marker\n";
  ' "$CODEX_CONFIG" >"$tmp" || {
    rm -f "$tmp"
    log "Error: failed to rewrite $CODEX_CONFIG"
    return 1
  }

  if cmp -s "$CODEX_CONFIG" "$tmp"; then
    rm -f "$tmp"
    return 0
  fi

  backup="${CODEX_CONFIG}.headroom-monitor.$(date '+%Y%m%d%H%M%S').bak"
  cp -p "$CODEX_CONFIG" "$backup" || {
    rm -f "$tmp"
    log "Error: failed to create backup: $backup"
    return 1
  }

  mv "$tmp" "$CODEX_CONFIG"
  log "Restored Codex Headroom provider with $headroom_url. Backup: $backup"
}

file_signature() {
  if [ -f "$CODEX_CONFIG" ]; then
    stat -c '%Y:%s' "$CODEX_CONFIG" 2>/dev/null || stat -f '%m:%z' "$CODEX_CONFIG" 2>/dev/null
  else
    printf 'missing\n'
  fi
}

monitor_with_inotify() {
  local config_dir config_name
  config_dir="$(dirname "$CODEX_CONFIG")"
  config_name="$(basename "$CODEX_CONFIG")"

  log "Start monitoring with inotify: $CODEX_CONFIG"
  inotifywait -m -e close_write,moved_to,create,attrib "$config_dir" |
    while read -r _directory _events filename; do
      if [ "$filename" = "$config_name" ]; then
        rewrite_codex_config
      fi
    done
}

monitor_with_polling() {
  local previous current
  previous="$(file_signature)"

  log "Start monitoring with polling (${POLL_INTERVAL}s): $CODEX_CONFIG"
  while true; do
    current="$(file_signature)"
    if [ "$current" != "$previous" ]; then
      rewrite_codex_config
      previous="$(file_signature)"
    fi
    sleep "$POLL_INTERVAL"
  done
}

if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  log "Warning: invalid POLL_INTERVAL='$POLL_INTERVAL', fallback to 2 seconds."
  POLL_INTERVAL=2
fi

if [ "${1:-}" = "--once" ]; then
  rewrite_codex_config
  exit $?
fi

rewrite_codex_config

if command -v inotifywait >/dev/null 2>&1; then
  monitor_with_inotify
else
  log "Warning: inotifywait is unavailable; switch to polling mode."
  monitor_with_polling
fi
