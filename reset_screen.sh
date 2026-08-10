#!/bin/bash
#===============================================================
# title:         reset_screen.sh
# description:   临时切换分辨率再恢复，用于让屏幕重新亮起
# author:        duanluan<duanluan@outlook.com>
# date:          2026-08-10
# version:       v2.1
# usage:         reset_screen.sh [--self-update] [output]
#
# changelog:
# v2.1 (2026-08-10)：临时分辨率优先匹配当前宽高比，兼容新版 kscreen-doctor 输出格式，恢复后确认原模式并在超时重试，恢复单实例运行锁以避免连续触发保存临时分辨率
# v2.0 (2026-07-28)：默认临时切换到较低分辨率后恢复，保留 xrandr 与 kscreen-doctor 支持，新增手动自更新能力，移除显示电源开关、关闭显示器输出和虚拟机专用处理
#===============================================================

set -euo pipefail

# 用法：
#   ./reset_screen.sh
#   ./reset_screen.sh HDMI-0
#   ./reset_screen.sh --self-update
#   RESET_SCREEN_OUTPUT=HDMI-0 ./reset_screen.sh
#   RESET_SCREEN_TEMP_MODE=2560x1440@59.95 ./reset_screen.sh
#
# 默认动作：把当前显示器临时切到一个较低分辨率，稍等后恢复原分辨率。

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
UPDATE_SOURCE_URL="${RESET_SCREEN_UPDATE_URL:-https://raw.githubusercontent.com/duanluan/shell-scripts/refs/heads/main/reset_screen.sh}"
LAST_CHECK_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/reset_screen.last_check"
CHECK_COOLDOWN=86400
declare -a UPDATE_PROXIES=(
  "prefix:https://gh-proxy.com/"
  "prefix:https://ghproxy.net/"
  "prefix:https://ghfast.top/"
  "prefix:https://fastgit.cc/"
)

SELF_UPDATE=0
OUTPUT=""
OUTPUT_ARG=""
TEMP_MODE="${RESET_SCREEN_TEMP_MODE:-}"
SWITCH_DELAY=1
RESTORE_POLL_INTERVAL=0.25
RESTORE_POLL_COUNT=20

has_command() {
  command -v "$1" >/dev/null 2>&1
}

acquire_run_lock() {
  local lock_base lock_path

  lock_base="${XDG_RUNTIME_DIR:-/tmp}"
  if [[ ! -d "$lock_base" || ! -w "$lock_base" ]]; then
    lock_base="/tmp"
  fi

  if has_command flock; then
    lock_path="${lock_base}/reset_screen.$(id -u).lock"
    exec 9>"$lock_path"
    flock -n 9
    return
  fi

  lock_path="${lock_base}/reset_screen.$(id -u).lockdir"
  mkdir "$lock_path" 2>/dev/null || return 1
  trap 'rmdir "$lock_path" 2>/dev/null || true' EXIT
}

log_update() {
  printf '%s\n' "$*" >&2
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

print_usage() {
  cat <<'EOF'
用法：
  reset_screen.sh [output]
  reset_screen.sh --self-update

环境变量：
  RESET_SCREEN_OUTPUT       指定显示器输出口
  RESET_SCREEN_TEMP_MODE    指定临时分辨率
  RESET_SCREEN_AUTO_UPDATE  设为 1 时，执行前按冷却时间自动检查更新
  RESET_SCREEN_UPDATE_URL   覆盖自更新下载地址
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --self-update)
        SELF_UPDATE=1
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      --)
        shift
        if [[ $# -gt 0 ]]; then
          if [[ -n "$OUTPUT_ARG" ]]; then
            die "只能指定一个显示器输出口。"
          fi
          OUTPUT_ARG="$1"
          shift
        fi
        if [[ $# -gt 0 ]]; then
          die "未知参数：$*"
        fi
        break
        ;;
      -*)
        die "未知参数：$1"
        ;;
      *)
        if [[ -n "$OUTPUT_ARG" ]]; then
          die "只能指定一个显示器输出口。"
        fi
        OUTPUT_ARG="$1"
        ;;
    esac
    shift
  done

  OUTPUT="${OUTPUT_ARG:-${RESET_SCREEN_OUTPUT:-}}"
}

write_update_check_cache() {
  local current_time="$1"

  mkdir -p "$(dirname -- "$LAST_CHECK_FILE")" 2>/dev/null || return 1
  printf '%s\n' "$current_time" >"$LAST_CHECK_FILE" 2>/dev/null
}

current_script_version() {
  grep -m1 '^# version:' "$SCRIPT_PATH" 2>/dev/null | awk '{print $3}'
}

remote_candidate_url() {
  local entry="$1"
  local mode proxy_url

  if [[ "$entry" == "direct" ]]; then
    printf '%s\n' "$UPDATE_SOURCE_URL"
    return 0
  fi

  mode="${entry%%:*}"
  proxy_url="${entry#*:}"

  case "$mode" in
    prefix)
      printf '%s%s\n' "$proxy_url" "$UPDATE_SOURCE_URL"
      ;;
  esac
}

download_update_script() {
  local tmp_script="$1"
  local candidates=()
  local entry url

  if [[ "$UPDATE_SOURCE_URL" == http://* || "$UPDATE_SOURCE_URL" == https://* ]]; then
    candidates=("${UPDATE_PROXIES[@]}" "direct")
  else
    candidates=("direct")
  fi

  for entry in "${candidates[@]}"; do
    url="$(remote_candidate_url "$entry")"
    [[ -n "$url" ]] || continue
    if curl -fsSL --connect-timeout 5 --max-time 20 "$url" -o "$tmp_script"; then
      [[ -s "$tmp_script" ]] && return 0
    fi
  done

  return 1
}

version_gt() {
  local left="${1#v}"
  local right="${2#v}"

  awk -v left="$left" -v right="$right" '
    BEGIN {
      left_count = split(left, left_parts, ".")
      right_count = split(right, right_parts, ".")
      max_count = (left_count > right_count) ? left_count : right_count

      for (i = 1; i <= max_count; i++) {
        left_value = left_parts[i] + 0
        right_value = right_parts[i] + 0

        if (left_value > right_value) {
          print 1
          exit
        }

        if (left_value < right_value) {
          print 0
          exit
        }
      }

      print 0
    }
  '
}

check_self_update() {
  local force_check="$1"
  shift || true

  local current_time last_check elapsed current_ver tmp_script remote_ver install_tmp
  current_time="$(date +%s)"

  if [[ "$force_check" != "true" && -f "$LAST_CHECK_FILE" ]]; then
    last_check="$(cat "$LAST_CHECK_FILE" 2>/dev/null || printf '0')"
    if [[ "$last_check" =~ ^[0-9]+$ ]]; then
      elapsed=$((current_time - last_check))
      [[ "$elapsed" -lt "$CHECK_COOLDOWN" ]] && return 0
    fi
  fi

  if ! has_command curl; then
    [[ "$force_check" == "true" ]] && die "自更新失败：缺少 curl。"
    return 0
  fi

  current_ver="$(current_script_version)"
  if [[ -z "$current_ver" ]]; then
    [[ "$force_check" == "true" ]] && die "自更新失败：无法读取当前版本。"
    return 0
  fi

  [[ "$force_check" == "true" ]] && log_update "当前版本：$current_ver"

  tmp_script="$(mktemp)"
  if ! download_update_script "$tmp_script"; then
    rm -f "$tmp_script"
    write_update_check_cache "$current_time" || true
    [[ "$force_check" == "true" ]] && die "自更新失败：无法下载远程脚本。"
    return 0
  fi

  write_update_check_cache "$current_time" || true

  if ! grep -q '^# title:[[:space:]]*reset_screen.sh' "$tmp_script"; then
    rm -f "$tmp_script"
    [[ "$force_check" == "true" ]] && die "自更新失败：远程脚本名称不匹配。"
    return 0
  fi

  remote_ver="$(grep -m1 '^# version:' "$tmp_script" | awk '{print $3}')"
  if [[ -z "$remote_ver" ]]; then
    rm -f "$tmp_script"
    [[ "$force_check" == "true" ]] && die "自更新失败：无法读取远程版本。"
    return 0
  fi

  if [[ "$(version_gt "$remote_ver" "$current_ver")" == "1" ]]; then
    [[ -w "$SCRIPT_PATH" && -w "$(dirname -- "$SCRIPT_PATH")" ]] || {
      rm -f "$tmp_script"
      die "自更新失败：当前脚本不可写：$SCRIPT_PATH"
    }

    log_update "发现新版本：$remote_ver（当前：$current_ver）"
    install_tmp="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")" || {
      rm -f "$tmp_script"
      die "自更新失败：无法创建临时安装文件。"
    }
    cp "$tmp_script" "$install_tmp"
    chmod +x "$install_tmp"
    mv "$install_tmp" "$SCRIPT_PATH"
    rm -f "$tmp_script"

    if [[ "$force_check" == "true" ]]; then
      log_update "自更新完成。"
      exit 0
    fi

    log_update "自更新完成，继续执行当前操作。"
    RESET_SCREEN_SKIP_SELF_UPDATE=1 exec "$SCRIPT_PATH" "$@"
    die "自更新失败：无法重新执行脚本。"
  fi

  rm -f "$tmp_script"
  [[ "$force_check" == "true" ]] && log_update "已是最新版本：$current_ver"
  return 0
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*[[:alpha:]]//g'
}

prefer_kscreen() {
  [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && return 0
  [[ "${KDE_FULL_SESSION:-}" == "true" ]] && return 0
  [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]] && return 0
  [[ "${XDG_CURRENT_DESKTOP:-}" == *Plasma* ]] && return 0
  [[ "${DESKTOP_SESSION:-}" == *plasma* ]] && return 0
  [[ "${DESKTOP_SESSION:-}" == *kde* ]] && return 0
  return 1
}

kscreen_info() {
  NO_COLOR=1 kscreen-doctor -o 2>/dev/null | strip_ansi
}

detect_kscreen_output() {
  local info="$1"

  awk '
    /^Output:/ {
      if (output != "" && enabled && connected) {
        print output
        found = 1
        exit
      }
      output = $3
      enabled = ($0 ~ / enabled /)
      connected = ($0 ~ / connected /)
      next
    }
    $1 == "enabled" {
      enabled = 1
      next
    }
    $1 == "disabled" {
      enabled = 0
      next
    }
    $1 == "connected" {
      connected = 1
      next
    }
    $1 == "disconnected" {
      connected = 0
      next
    }
    END {
      if (!found && output != "" && enabled && connected) {
        print output
      } else if (!found && output == "") {
        exit 1
      }
    }
  ' <<<"$info"
}

get_kscreen_current_mode_info() {
  local info="$1"
  local output="$2"

  awk -v output="$output" '
    /^Output:/ {
      active = ($3 == output)
      next
    }
    active && /Modes:/ {
      for (i = 1; i <= NF; i++) {
        raw = $i
        if (raw ~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+[*!]*$/ && raw ~ /\*/) {
          id = raw
          sub(/:.*/, "", id)
          mode = raw
          sub(/^[0-9]+:/, "", mode)
          gsub(/[*!]/, "", mode)
          print id, mode
          exit
        }
      }
    }
  ' <<<"$info"
}

get_kscreen_position() {
  local info="$1"
  local output="$2"

  awk -v output="$output" '
    /^Output:/ {
      active = ($3 == output)
      next
    }
    active && /^[[:space:]]*Geometry:/ {
      print $2
      exit
    }
  ' <<<"$info"
}

choose_kscreen_temp_mode_id() {
  local info="$1"
  local output="$2"
  local current_mode="$3"

  awk -v output="$output" -v current_mode="$current_mode" -v requested="$TEMP_MODE" '
    BEGIN {
      split(current_mode, current_parts, "@")
      split(current_parts[1], current_size, "x")
      if (current_size[1] <= 0 || current_size[2] <= 0) {
        exit 1
      }
      current_area = current_size[1] * current_size[2]
      current_ratio = current_size[1] / current_size[2]
      best_ratio_delta = -1
      best_area = 0
    }
    /^Output:/ {
      active = ($3 == output)
      next
    }
    active && /Modes:/ {
      for (i = 1; i <= NF; i++) {
        raw = $i
        if (raw !~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+[*!]*$/) {
          continue
        }

        id = raw
        sub(/:.*/, "", id)
        mode = raw
        sub(/^[0-9]+:/, "", mode)
        gsub(/[*!]/, "", mode)

        split(mode, parts, "@")
        split(parts[1], size, "x")
        if (size[1] <= 0 || size[2] <= 0) {
          continue
        }
        area = size[1] * size[2]
        ratio_delta = (size[1] / size[2]) - current_ratio
        if (ratio_delta < 0) {
          ratio_delta = -ratio_delta
        }

        if (requested != "") {
          if (requested == id || requested == mode || requested == parts[1]) {
            selected = id
          }
          continue
        }

        if (mode != current_mode && area < current_area) {
          if (best_ratio_delta < 0 || ratio_delta < best_ratio_delta - 0.000001 ||
              (ratio_delta <= best_ratio_delta + 0.000001 && area > best_area)) {
            best = id
            best_ratio_delta = ratio_delta
            best_area = area
          }
        }
      }
    }
    END {
      if (requested != "" && selected != "") {
        print selected
      } else if (requested == "" && best != "") {
        print best
      } else {
        exit 1
      }
    }
  ' <<<"$info"
}

reset_with_kscreen() {
  has_command kscreen-doctor || return 1

  local info selected_output current_info current_mode_id current_mode temp_mode_id position
  info="$(kscreen_info)" || return 1

  selected_output="$OUTPUT"
  if [[ -z "$selected_output" ]]; then
    selected_output="$(detect_kscreen_output "$info")" || return 1
  fi
  [[ -n "$selected_output" ]] || return 1

  current_info="$(get_kscreen_current_mode_info "$info" "$selected_output")" || return 1
  [[ -n "$current_info" ]] || return 1
  read -r current_mode_id current_mode <<<"$current_info"

  temp_mode_id="$(choose_kscreen_temp_mode_id "$info" "$selected_output" "$current_mode")" || return 1
  [[ -n "$temp_mode_id" ]] || return 1

  position="$(get_kscreen_position "$info" "$selected_output" || true)"

  local temp_args restore_args
  temp_args=("output.${selected_output}.mode.${temp_mode_id}")
  restore_args=("output.${selected_output}.mode.${current_mode_id}")

  if [[ -n "$position" && "$position" != "0,0" ]]; then
    temp_args+=("output.${selected_output}.position.${position}")
    restore_args+=("output.${selected_output}.position.${position}")
  fi

  kscreen-doctor "${temp_args[@]}" >/dev/null
  sleep "$SWITCH_DELAY"
  restore_kscreen_mode "$selected_output" "$current_mode_id" "${restore_args[@]}"
}

wait_for_kscreen_mode() {
  local output="$1"
  local expected_mode_id="$2"
  local attempt info current_info current_mode_id

  for ((attempt = 0; attempt < RESTORE_POLL_COUNT; attempt++)); do
    info="$(kscreen_info || true)"
    current_info="$(get_kscreen_current_mode_info "$info" "$output" || true)"
    read -r current_mode_id _ <<<"$current_info"
    if [[ "$current_mode_id" == "$expected_mode_id" ]]; then
      return 0
    fi
    ((attempt + 1 < RESTORE_POLL_COUNT)) && sleep "$RESTORE_POLL_INTERVAL"
  done

  return 1
}

restore_kscreen_mode() {
  local output="$1"
  local expected_mode_id="$2"
  shift 2

  kscreen-doctor "$@" >/dev/null 2>&1 || true
  if wait_for_kscreen_mode "$output" "$expected_mode_id"; then
    return 0
  fi

  kscreen-doctor "$@" >/dev/null 2>&1 || true
  printf '恢复原分辨率超时：未确认输出 %s 恢复到模式 %s。\n' "$output" "$expected_mode_id" >&2
  return 2
}

detect_xrandr_output() {
  local query="$1"

  awk '
    /^[^[:space:]]+ connected/ {
      score = 0
      if ($0 ~ / primary /) {
        score += 100
      }
      if ($0 ~ /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {
        score += 50
      }
      if ($1 ~ /^HDMI/) {
        score += 20
      }
      if ($1 ~ /^DP/ || $1 ~ /^DisplayPort/) {
        score += 10
      }
      if (best == "" || score > best_score) {
        best = $1
        best_score = score
      }
    }
    END {
      if (best != "") {
        print best
      } else {
        exit 1
      }
    }
  ' <<<"$query"
}

get_xrandr_state() {
  local query="$1"
  local output="$2"

  awk -v output="$output" '
    $1 == output && $2 == "connected" {
      primary = ($0 ~ / primary /) ? "1" : "0"
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
          split($i, geometry, /[+]/)
          print geometry[1], geometry[2], geometry[3], primary
          exit
        }
      }
    }
  ' <<<"$query"
}

choose_xrandr_temp_mode() {
  local query="$1"
  local output="$2"
  local current_mode="$3"

  if [[ -n "$TEMP_MODE" ]]; then
    printf '%s\n' "${TEMP_MODE%@*}"
    return 0
  fi

  awk -v output="$output" -v current_mode="$current_mode" '
    BEGIN {
      split(current_mode, current_size, "x")
      if (current_size[1] <= 0 || current_size[2] <= 0) {
        exit 1
      }
      current_area = current_size[1] * current_size[2]
      current_ratio = current_size[1] / current_size[2]
      best_ratio_delta = -1
      best_area = 0
    }
    $1 == output && $2 == "connected" {
      active = 1
      next
    }
    active && /^[^[:space:]]/ {
      active = 0
    }
    active && /^[[:space:]]+[0-9]+x[0-9]+/ {
      mode = $1
      split(mode, size, "x")
      if (size[1] <= 0 || size[2] <= 0) {
        next
      }
      area = size[1] * size[2]
      ratio_delta = (size[1] / size[2]) - current_ratio
      if (ratio_delta < 0) {
        ratio_delta = -ratio_delta
      }
      if (mode != current_mode && area < current_area) {
        if (best_ratio_delta < 0 || ratio_delta < best_ratio_delta - 0.000001 ||
            (ratio_delta <= best_ratio_delta + 0.000001 && area > best_area)) {
          best = mode
          best_ratio_delta = ratio_delta
          best_area = area
        }
      }
    }
    END {
      if (best != "") {
        print best
      } else {
        exit 1
      }
    }
  ' <<<"$query"
}

apply_xrandr_mode() {
  local output="$1"
  local mode="$2"
  local xpos="$3"
  local ypos="$4"
  local primary="$5"

  local args
  args=(--output "$output" --mode "$mode" --pos "${xpos}x${ypos}")
  if [[ "$primary" == "1" ]]; then
    args+=(--primary)
  fi

  xrandr "${args[@]}" >/dev/null
}

reset_with_xrandr() {
  has_command xrandr || return 1

  local query selected_output state current_mode xpos ypos primary temp_mode
  query="$(xrandr --query 2>/dev/null)" || return 1

  selected_output="$OUTPUT"
  if [[ -z "$selected_output" ]]; then
    selected_output="$(detect_xrandr_output "$query")" || return 1
  fi
  [[ -n "$selected_output" ]] || return 1

  state="$(get_xrandr_state "$query" "$selected_output")" || return 1
  [[ -n "$state" ]] || return 1
  read -r current_mode xpos ypos primary <<<"$state"

  temp_mode="$(choose_xrandr_temp_mode "$query" "$selected_output" "$current_mode")" || return 1
  [[ -n "$temp_mode" ]] || return 1

  apply_xrandr_mode "$selected_output" "$temp_mode" "$xpos" "$ypos" "$primary"
  sleep "$SWITCH_DELAY"
  restore_xrandr_mode "$selected_output" "$current_mode" "$xpos" "$ypos" "$primary"
}

wait_for_xrandr_mode() {
  local output="$1"
  local expected_mode="$2"
  local attempt query state current_mode

  for ((attempt = 0; attempt < RESTORE_POLL_COUNT; attempt++)); do
    query="$(xrandr --query 2>/dev/null || true)"
    state="$(get_xrandr_state "$query" "$output" || true)"
    read -r current_mode _ <<<"$state"
    if [[ "$current_mode" == "$expected_mode" ]]; then
      return 0
    fi
    ((attempt + 1 < RESTORE_POLL_COUNT)) && sleep "$RESTORE_POLL_INTERVAL"
  done

  return 1
}

restore_xrandr_mode() {
  local output="$1"
  local mode="$2"
  local xpos="$3"
  local ypos="$4"
  local primary="$5"

  apply_xrandr_mode "$output" "$mode" "$xpos" "$ypos" "$primary" || true
  if wait_for_xrandr_mode "$output" "$mode"; then
    return 0
  fi

  apply_xrandr_mode "$output" "$mode" "$xpos" "$ypos" "$primary" || true
  printf '恢复原分辨率超时：未确认输出 %s 恢复到模式 %s。\n' "$output" "$mode" >&2
  return 2
}

main() {
  parse_args "$@"

  if [[ "$SELF_UPDATE" -eq 1 ]]; then
    check_self_update "true"
    return 0
  fi

  if [[ "${RESET_SCREEN_AUTO_UPDATE:-0}" == "1" && "${RESET_SCREEN_SKIP_SELF_UPDATE:-0}" != "1" ]]; then
    check_self_update "false" "$@"
  fi

  acquire_run_lock || return 0

  local reset_status

  if prefer_kscreen; then
    if reset_with_kscreen; then
      return 0
    fi
    reset_status=$?
    ((reset_status == 2)) && return "$reset_status"
    if reset_with_xrandr; then
      return 0
    fi
    reset_status=$?
    ((reset_status == 2)) && return "$reset_status"
  else
    if reset_with_xrandr; then
      return 0
    fi
    reset_status=$?
    ((reset_status == 2)) && return "$reset_status"
    if reset_with_kscreen; then
      return 0
    fi
    reset_status=$?
    ((reset_status == 2)) && return "$reset_status"
  fi

  echo "无法临时切换分辨率：请确认 kscreen-doctor 或 xrandr 可用，并且当前显示器有可切换的较低分辨率。" >&2
  return 1
}

main "$@"
