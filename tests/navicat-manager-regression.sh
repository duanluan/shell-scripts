#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT_UNDER_TEST="$ROOT_DIR/navicat-manager.sh"
TEMP_DIRS=()

cleanup() {
  local dir
  for dir in "${TEMP_DIRS[@]}"; do
    rm -rf "$dir"
  done
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle=$1
  local haystack=$2
  printf '%s' "$haystack" | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g' | grep -Fq -- "$needle" || fail "missing output: $needle"
}

create_config() {
  local config_dir=$1

  mkdir -p "$config_dir/Common" "$config_dir/Premium"
  printf '%s\n' '{"Users":[{"Projects":[{"Servers":[{"Name":"preserved-connection"}]}]}]}' >"$config_dir/Common/connections.json"
  printf '%s\n' '{"User":[]}' >"$config_dir/Common/ui_connections.json"
  printf '%s\n' '{"CloudSessions":[{"UserUUID":"preserved-user"}],"CloudSessions_SimpChinese":[],"Continues":{}}' >"$config_dir/Premium/preferences.json"
  printf '%s\n' '{"Preferences":{}}' >"$config_dir/Premium/ui_preferences.json"
}

create_reset_fakes() {
  local fake_bin=$1

  mkdir -p "$fake_bin"

  cat >"$fake_bin/dconf" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat >"$fake_bin/pgrep" <<'EOF'
#!/bin/bash
# Simulate a stale Navicat background process that never exits.
exit 0
EOF

  cat >"$fake_bin/pkill" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat >"$fake_bin/xdotool" <<'EOF'
#!/bin/bash
if [[ "$1" == "search" && -f "$NAVICAT_TEST_STATE/window-open" ]]; then
  printf '123\n'
  exit 0
fi
exit 1
EOF

  cat >"$fake_bin/sleep" <<'EOF'
#!/bin/bash
set -euo pipefail

count_file="$NAVICAT_TEST_STATE/sleep-count"
count=0
[[ -f "$count_file" ]] && count=$(<"$count_file")
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

if [[ "$count" -eq 1 ]]; then
  mkdir -p "$(dirname -- "$NAVICAT_TEST_PREF")"
  printf '%s\n' '{"CloudSessions":[],"CloudSessions_SimpChinese":[],"Continues":{}}' >"$NAVICAT_TEST_PREF"
  touch "$NAVICAT_TEST_STATE/window-open"
elif [[ "${NAVICAT_TEST_KEEP_WINDOW:-0}" != "1" ]]; then
  rm -f "$NAVICAT_TEST_STATE/window-open"
fi
EOF

  chmod +x "$fake_bin/dconf" "$fake_bin/pgrep" "$fake_bin/pkill" "$fake_bin/xdotool" "$fake_bin/sleep"
}

run_reset_case() {
  local keep_window=$1
  local work_dir fake_bin config_dir backup_dir state_dir output status

  work_dir=$(mktemp -d)
  TEMP_DIRS+=("$work_dir")
  fake_bin="$work_dir/bin"
  config_dir="$work_dir/navicat"
  backup_dir="$work_dir/backups"
  state_dir="$work_dir/state"
  mkdir -p "$state_dir"
  create_config "$config_dir"
  create_reset_fakes "$fake_bin"

  set +e
  output=$(
    printf 'y\nN\n' |
      env \
        HOME="$work_dir/home" \
        LC_ALL=C \
        LANG=C \
        NAVICAT_MANAGER_SKIP_SELF_UPDATE=1 \
        NAVICAT_TEST_PREF="$config_dir/Premium/preferences.json" \
        NAVICAT_TEST_STATE="$state_dir" \
        NAVICAT_TEST_KEEP_WINDOW="$keep_window" \
        PATH="$fake_bin:/usr/bin:/bin" \
        "$SCRIPT_UNDER_TEST" reset --config-dir "$config_dir" --backup-root "$backup_dir" 2>&1
  )
  status=$?
  set -e

  printf '%s\n' "$status"
  printf '%s' "$output"
}

test_self_update_continues_original_args() {
  local work_dir fake_bin config_dir runner remote output

  work_dir=$(mktemp -d)
  TEMP_DIRS+=("$work_dir")
  fake_bin="$work_dir/bin"
  config_dir="$work_dir/navicat"
  runner="$work_dir/navicat-manager.sh"
  remote="$work_dir/navicat-manager.remote.sh"
  mkdir -p "$fake_bin"
  create_config "$config_dir"
  cp "$SCRIPT_UNDER_TEST" "$runner"
  cp "$SCRIPT_UNDER_TEST" "$remote"
  sed -i 's/^# version:.*/# version: v99.9/' "$remote"

  cat >"$fake_bin/dconf" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$fake_bin/dconf"

  cat >"$fake_bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail

output_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_file=$2
      shift 2
      ;;
    --connect-timeout|--max-time)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

cp "$NAVICAT_TEST_REMOTE" "$output_file"
EOF
  chmod +x "$fake_bin/curl"

  output=$(
    env \
      HOME="$work_dir/home" \
      LC_ALL=C \
      LANG=C \
      NAVICAT_TEST_REMOTE="$remote" \
      PATH="$fake_bin:/usr/bin:/bin" \
      "$runner" inspect --config-dir "$config_dir" --backup-root "$work_dir/backups" 2>&1
  )

  assert_contains "New version found: v99.9 (current: v1.3)" "$output"
  assert_contains "Connection count:" "$output"
  grep -Eq '^# version:.*v99\.9$' "$runner" || fail "updated script was not installed"
}

test_reset_continues_after_window_closes() {
  local result status output

  result=$(run_reset_case 0)
  status=$(printf '%s\n' "$result" | sed -n '1p')
  output=$(printf '%s\n' "$result" | sed -n '2,$p')

  [[ "$status" -eq 0 ]] || fail "reset exited with $status: $output"
  assert_contains "Reset finished." "$output"
  assert_contains "Navicat windows closed; restoring config." "$output"
}

test_reset_timeout_keeps_recovery_copy() {
  local work_dir fake_bin config_dir backup_dir state_dir output status recovery_dir

  work_dir=$(mktemp -d)
  TEMP_DIRS+=("$work_dir")
  fake_bin="$work_dir/bin"
  config_dir="$work_dir/navicat"
  backup_dir="$work_dir/backups"
  state_dir="$work_dir/state"
  mkdir -p "$state_dir"
  create_config "$config_dir"
  create_reset_fakes "$fake_bin"

  set +e
  output=$(
    printf 'y\nN\n' |
      env \
        HOME="$work_dir/home" \
        LC_ALL=C \
        LANG=C \
        NAVICAT_MANAGER_SKIP_SELF_UPDATE=1 \
        NAVICAT_TEST_PREF="$config_dir/Premium/preferences.json" \
        NAVICAT_TEST_STATE="$state_dir" \
        NAVICAT_TEST_KEEP_WINDOW=1 \
        PATH="$fake_bin:/usr/bin:/bin" \
        "$SCRIPT_UNDER_TEST" reset --config-dir "$config_dir" --backup-root "$backup_dir" 2>&1
  )
  status=$?
  set -e

  [[ "$status" -ne 0 ]] || fail "reset timeout unexpectedly succeeded"
  assert_contains "Original config is kept at:" "$output"
  recovery_dir=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name 'reset-preserve-*' | head -n 1)
  [[ -n "$recovery_dir" ]] || fail "reset recovery copy was not retained"
  [[ "$(jq '.CloudSessions | length' "$recovery_dir/navicat/Premium/preferences.json")" -eq 1 ]] || fail "cloud session was not preserved"
  grep -q 'preserved-connection' "$recovery_dir/navicat/Common/connections.json" || fail "connection data was not preserved"
}

test_self_update_continues_original_args
test_reset_continues_after_window_closes
test_reset_timeout_keeps_recovery_copy
printf 'navicat-manager regression tests passed\n'
