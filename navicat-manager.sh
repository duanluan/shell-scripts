#!/bin/bash
#===============================================================
# title:         navicat-manager.sh
# description:   备份、恢复和检查 Navicat Linux 连接、UI 设置与云账号会话
# author:        duanluan<duanluan@outlook.com>
# date:          2026-05-25
# version:       v1.0
# usage:         navicat-manager.sh [backup|restore|inspect|reset] [options]
#
# description_zh:
#   此脚本用于管理 Navicat Linux 本地配置，支持备份、恢复、检查和 reset 流程。
#   reset 时会保留 Common 连接文件、产品 UI 设置，以及 preferences.json 中可迁移的云账号会话字段。
#
# changelog:
#   v1.0 (2026-05-25)：支持连接/UI/云账号会话备份恢复、reset 保留配置、自动关闭 Navicat、中英提示和自更新
#===============================================================

set -e

# ==========================================
# 全局配置默认值
# ==========================================
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
NAVICAT_DIR="$HOME/.config/navicat"
PRODUCT="Premium"
BACKUP_ROOT="$HOME/navicat-backups"
BACKUP_DIR=""
ACTION=""
KILL_NAVICAT=0
YES=0
DRY_RUN=0
SELF_UPDATE=0
UPDATE_SOURCE_URL="${NAVICAT_MANAGER_UPDATE_URL:-https://raw.githubusercontent.com/duanluan/shell-scripts/refs/heads/main/navicat-manager.sh}"
LAST_CHECK_FILE="$HOME/.cache/navicat-manager.last_check"
CHECK_COOLDOWN=86400

declare -a UPDATE_PROXIES=(
  "prefix:https://gh-proxy.com/"
  "prefix:https://ghproxy.net/"
  "prefix:https://ghfast.top/"
  "prefix:https://fastgit.cc/"
)

# ==========================================
# 语言设置
# ==========================================
L_USAGE="Usage"
L_ACTIONS="Actions"
L_OPTIONS="Options"
L_ACTION_BACKUP="Back up current Navicat config"
L_ACTION_RESTORE="Restore config from a backup directory"
L_ACTION_INSPECT="Inspect current Navicat config"
L_ACTION_RESET="Reset current state and preserve UI settings"
L_OPT_CONFIG_DIR="Navicat config directory"
L_OPT_BACKUP_ROOT="Backup root"
L_OPT_PRODUCT="Product name"
L_OPT_KILL="Force-close Navicat before running"
L_OPT_YES="Skip confirmation prompts"
L_OPT_DRY_RUN="Preview only; do not modify files"
L_OPT_SELF_UPDATE="Update this script and exit"
L_OPT_HELP="Show help"
L_DEFAULT="default"
L_ERR_MISSING_CMD="Missing command: %s. Please install it first."
L_CANCELLED="Cancelled."
L_BACKUP_NO_CONFIG="Backup does not contain Navicat config: %s"
L_CLOSE_NAVICAT="Closing Navicat processes..."
L_DRY_RUN_RUN="[dry-run] Would run: %s"
L_DRY_RUN_COPY="[dry-run] Would copy %s -> %s"
L_DRY_RUN_COPY_DIR="[dry-run] Would copy directory %s -> %s"
L_DRY_RUN_MANIFEST="[dry-run] Would write manifest to %s"
L_START_BACKUP="Starting backup to %s..."
L_DRY_RUN_BACKUP="[dry-run] Would back up %s and %s to %s"
L_SAFETY_BACKUP_WRITTEN="Safety backup written: %s"
L_SAFETY_BACKUP_BEFORE="Creating safety backup before writing..."
L_INVALID_JSON="Invalid JSON: %s"
L_DRY_RUN_MERGE_PREF="[dry-run] Would merge portable preference keys: %s -> %s"
L_MISSING_CONNECTIONS="Missing connections.json in backup: %s"
L_MISSING_BACKUP_DIR="Missing backup dir."
L_BACKUP_DIR_NOT_FOUND="Backup dir not found: %s"
L_CONFIRM_RESTORE="Restore connections, UI settings, and cloud account sessions from %s?"
L_RESTORE_FINISHED="Restore finished."
L_INSPECT_NAVICAT_DIR="Navicat config dir: %s"
L_INSPECT_PRODUCT="Product: %s"
L_INSPECT_CONNECTIONS_FILE="Connections file: %s"
L_INSPECT_SERVER_COUNT="Connection count: %s"
L_INSPECT_UI_COUNT="UI connection entry count: %s"
L_INSPECT_CLOUD_COUNT="Cloud account session count: %s"
L_INSPECT_UI_PREF="UI preferences file: %s"
L_INSPECT_PORTABLE_KEYS="Portable preference keys:"
L_PRESENT="present"
L_MISSING="missing"
L_NONE="none"
L_DCONF_COUNT="dconf entries under %s: %s"
L_LABEL_AUTOSAVES="auto-save records"
L_LABEL_CLOUD_SESSIONS_ZH="Simplified Chinese cloud account sessions"
L_LABEL_CLOUD_SESSIONS="cloud account sessions"
L_LABEL_CLOUDS="cloud sync config"
L_LABEL_CONTINUES="continue records"
L_LABEL_RECENTS="recent records"
L_LABEL_OPEN=" ("
L_LABEL_CLOSE=")"
L_CONFIRM_RESET="This will reset the current Navicat state and preserve connections, UI settings, and cloud account sessions. Continue?"
L_DRY_RUN_PRESERVE="[dry-run] Would preserve current Common and %s config."
L_PRESERVE_CURRENT="Preserving current connections, UI settings, and cloud account sessions..."
L_DRY_RUN_RESET_DCONF="[dry-run] Would reset dconf path: %s"
L_DRY_RUN_DELETE_FILE="[dry-run] Would delete file: %s"
L_RESET_DCONF="Resetting dconf path: %s"
L_REMOVE_PREFS="Removing preference and lock files..."
L_CLEANUP_DONE="Cleanup complete: dconf, preferences.json, and .lock handled."
L_START_NAVICAT=">>> Start Navicat now."
L_WAIT_PREF="Waiting for preferences.json: %s"
L_WAIT_START_LONG="Waiting... %d seconds. Start Navicat."
L_WAIT_PREF_PROGRESS="Waiting for preferences.json... %d seconds"
L_TIMEOUT_PREF="Timed out. New preferences.json was not detected."
L_TIMEOUT_PREF_HINT="Rerun reset and start Navicat when prompted."
L_DETECTED_PREF="New preferences.json detected: %s"
L_CONFIRM_AUTO_CLOSE_NAVICAT="Close Navicat automatically?"
L_AUTO_CLOSE_NAVICAT="Closing Navicat..."
L_CLOSE_NAVICAT_NOW=">>> Close Navicat now."
L_WAIT_CLOSE_LONG="Waiting... %d seconds. Close Navicat."
L_WAIT_EXIT_PROGRESS="Waiting for Navicat to exit... %d seconds"
L_NAVICAT_STILL_RUNNING="Navicat is still running. Close Navicat and rerun reset; if the window is already closed, rerun: %s reset --kill"
L_NAVICAT_CLOSED="Navicat closed; restoring config."
L_RESTORE_PREVIOUS="Restoring previous connections, UI settings, and cloud account sessions..."
L_SETTINGS_MERGED="Settings merged."
L_RESET_DONE="Reset finished. You can open Navicat now."
L_ARG_MISSING="Missing value for %s"
L_UNKNOWN_ARG="Unknown argument: %s"
L_SELF_UPDATE_CHECKING="Checking for script updates..."
L_SELF_UPDATE_FETCH="Fetching update: %s"
L_SELF_UPDATE_DOWNLOAD_FAILED="Update check failed: script download failed."
L_SELF_UPDATE_INVALID_SCRIPT="Update check failed: downloaded file is not navicat-manager.sh."
L_SELF_UPDATE_PARSE_FAILED="Update check failed: remote version was not found."
L_SELF_UPDATE_CURRENT_VERSION="Local version: %s"
L_SELF_UPDATE_NEW_VERSION="New version found: %s (current: %s)"
L_SELF_UPDATE_INSTALLING="Updating script..."
L_SELF_UPDATE_DONE="Update finished. Rerun the script."
L_SELF_UPDATE_LATEST="Already up to date (%s)."
L_SELF_UPDATE_SKIP_NO_CURL="Skipping update check: curl is not installed."
L_SELF_UPDATE_SKIP_NO_VERSION="Skipping update check: local version was not found."
L_SELF_UPDATE_WRITE_FAILED="Cannot write to script path: %s"
L_SELF_UPDATE_DIRECT="direct"
L_SELF_UPDATE_CACHE_WRITE_FAILED="Could not write update check cache: %s"

if [[ "${LANG:-}" == *"zh_"* ]]; then
  L_USAGE="Usage"
  L_ACTIONS="动作"
  L_OPTIONS="Options"
  L_ACTION_BACKUP="备份当前 Navicat 配置"
  L_ACTION_RESTORE="从备份目录恢复配置"
  L_ACTION_INSPECT="检查当前 Navicat 配置详情"
  L_ACTION_RESET="重置当前状态，并保留 UI 设置（推荐使用）"
  L_OPT_CONFIG_DIR="Navicat 配置目录"
  L_OPT_BACKUP_ROOT="备份根目录"
  L_OPT_PRODUCT="产品名称"
  L_OPT_KILL="在执行动作前强制关闭 Navicat"
  L_OPT_YES="跳过所有确认提示（静默执行）"
  L_OPT_DRY_RUN="预演模式（仅显示将要执行的操作，不实际修改）"
  L_OPT_SELF_UPDATE="更新脚本本身后退出"
  L_OPT_HELP="显示帮助信息"
  L_DEFAULT="默认"
  L_ERR_MISSING_CMD="缺少命令: %s。请先安装它。"
  L_CANCELLED="已取消。"
  L_BACKUP_NO_CONFIG="备份目录中没有 Navicat 配置: %s"
  L_CLOSE_NAVICAT="正在关闭 Navicat 进程..."
  L_DRY_RUN_RUN="[预演] 将执行: %s"
  L_DRY_RUN_COPY="[预演] 将复制 %s -> %s"
  L_DRY_RUN_COPY_DIR="[预演] 将复制目录 %s -> %s"
  L_DRY_RUN_MANIFEST="[预演] 将写入清单文件 %s"
  L_START_BACKUP="开始备份到 %s..."
  L_DRY_RUN_BACKUP="[预演] 将备份 %s 和 %s 到 %s"
  L_SAFETY_BACKUP_WRITTEN="安全备份已写入: %s"
  L_SAFETY_BACKUP_BEFORE="写入前先创建安全备份..."
  L_INVALID_JSON="JSON 文件无效: %s"
  L_DRY_RUN_MERGE_PREF="[预演] 将合并可迁移偏好字段: %s -> %s"
  L_MISSING_CONNECTIONS="备份中缺少 connections.json: %s"
  L_MISSING_BACKUP_DIR="缺少备份目录。"
  L_BACKUP_DIR_NOT_FOUND="备份目录不存在: %s"
  L_CONFIRM_RESTORE="要从 %s 恢复连接、UI 设置和云账号会话吗？"
  L_RESTORE_FINISHED="恢复完成。"
  L_INSPECT_NAVICAT_DIR="Navicat 配置目录: %s"
  L_INSPECT_PRODUCT="产品: %s"
  L_INSPECT_CONNECTIONS_FILE="连接文件: %s"
  L_INSPECT_SERVER_COUNT="连接数量: %s"
  L_INSPECT_UI_COUNT="UI 连接记录数量: %s"
  L_INSPECT_CLOUD_COUNT="云账号会话数量: %s"
  L_INSPECT_UI_PREF="UI 偏好文件: %s"
  L_INSPECT_PORTABLE_KEYS="可迁移偏好字段:"
  L_PRESENT="存在"
  L_MISSING="缺失"
  L_NONE="无"
  L_DCONF_COUNT="%s 下的 dconf 记录数量: %s"
  L_LABEL_AUTOSAVES="自动保存记录"
  L_LABEL_CLOUD_SESSIONS_ZH="简体中文云账号会话"
  L_LABEL_CLOUD_SESSIONS="云账号会话"
  L_LABEL_CLOUDS="云同步配置"
  L_LABEL_CONTINUES="继续使用记录"
  L_LABEL_RECENTS="最近使用记录"
  L_LABEL_OPEN="（"
  L_LABEL_CLOSE="）"
  L_CONFIRM_RESET="这会重置 Navicat 当前状态，并保留连接、UI 设置和云账号会话。继续吗？"
  L_DRY_RUN_PRESERVE="[预演] 将保存当前 Common 和 %s 配置。"
  L_PRESERVE_CURRENT="正在保存当前连接、UI 设置和云账号会话..."
  L_DRY_RUN_RESET_DCONF="[预演] 将重置 dconf 路径: %s"
  L_DRY_RUN_DELETE_FILE="[预演] 将删除文件: %s"
  L_RESET_DCONF="正在重置 dconf 路径: %s"
  L_REMOVE_PREFS="正在删除偏好文件和锁文件..."
  L_CLEANUP_DONE="清理完成：dconf、preferences.json 和 .lock 已处理。"
  L_START_NAVICAT=">>> 请启动 Navicat。"
  L_WAIT_PREF="等待 preferences.json: %s"
  L_WAIT_START_LONG="等待中... %d 秒。请启动 Navicat。"
  L_WAIT_PREF_PROGRESS="正在等待 preferences.json... %d 秒"
  L_TIMEOUT_PREF="超时，未检测到新的 preferences.json。"
  L_TIMEOUT_PREF_HINT="请重新执行 reset，并在提示后启动 Navicat。"
  L_DETECTED_PREF="已检测到新的 preferences.json: %s"
  L_CONFIRM_AUTO_CLOSE_NAVICAT="是否自动关闭 Navicat？"
  L_AUTO_CLOSE_NAVICAT="正在自动关闭 Navicat..."
  L_CLOSE_NAVICAT_NOW=">>> 请关闭 Navicat。"
  L_WAIT_CLOSE_LONG="等待中... %d 秒。请关闭 Navicat。"
  L_WAIT_EXIT_PROGRESS="正在等待 Navicat 退出... %d 秒"
  L_NAVICAT_STILL_RUNNING="Navicat 仍在运行。请关闭 Navicat 后重新执行 reset；如果确认界面已经关掉，可重新执行: %s reset --kill"
  L_NAVICAT_CLOSED="Navicat 已关闭，可以恢复配置。"
  L_RESTORE_PREVIOUS="正在恢复原有连接、UI 设置和云账号会话..."
  L_SETTINGS_MERGED="设置已合并完成。"
  L_RESET_DONE="重置完成。你可以正常打开 Navicat 继续使用了。"
  L_ARG_MISSING="%s 缺少参数值"
  L_UNKNOWN_ARG="未知参数: %s"
  L_SELF_UPDATE_CHECKING="正在检查脚本更新..."
  L_SELF_UPDATE_FETCH="正在获取更新: %s"
  L_SELF_UPDATE_DOWNLOAD_FAILED="检查更新失败：无法下载脚本。"
  L_SELF_UPDATE_INVALID_SCRIPT="检查更新失败：下载到的文件不是 navicat-manager.sh。"
  L_SELF_UPDATE_PARSE_FAILED="检查更新失败：未找到远程版本号。"
  L_SELF_UPDATE_CURRENT_VERSION="本地版本: %s"
  L_SELF_UPDATE_NEW_VERSION="发现新版本: %s（当前: %s）"
  L_SELF_UPDATE_INSTALLING="正在更新脚本..."
  L_SELF_UPDATE_DONE="更新完成，请重新运行脚本。"
  L_SELF_UPDATE_LATEST="当前已是最新版本（%s）。"
  L_SELF_UPDATE_SKIP_NO_CURL="跳过更新检查：未安装 curl。"
  L_SELF_UPDATE_SKIP_NO_VERSION="跳过更新检查：未找到本地版本号。"
  L_SELF_UPDATE_WRITE_FAILED="无法写入脚本路径: %s"
  L_SELF_UPDATE_DIRECT="直连"
  L_SELF_UPDATE_CACHE_WRITE_FAILED="无法写入更新检查缓存: %s"
fi

# ==========================================
# 辅助工具与路径计算函数
# ==========================================
log() { echo "ℹ️  $1"; }
die() { echo "❌ $1" >&2; exit 1; }
fmt() { local template=$1; shift; printf "$template" "$@"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "$(fmt "$L_ERR_MISSING_CMD" "$1")"; }

confirm() {
  [[ "$YES" -eq 1 ]] && return 0
  read -r -p "⚠️  $1 [y/N]: " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

usage() {
  cat <<EOF
${L_USAGE}: $0 [backup|restore|inspect|reset] [options]

${L_ACTIONS}:
  backup   ${L_ACTION_BACKUP}
  restore  ${L_ACTION_RESTORE}
  inspect  ${L_ACTION_INSPECT}
  reset    ${L_ACTION_RESET}

${L_OPTIONS}:
  --config-dir <dir>    ${L_OPT_CONFIG_DIR} (${L_DEFAULT}: $NAVICAT_DIR)
  --backup-root <dir>   ${L_OPT_BACKUP_ROOT} (${L_DEFAULT}: $BACKUP_ROOT)
  --product <name>      ${L_OPT_PRODUCT} (${L_DEFAULT}: $PRODUCT)
  --kill                ${L_OPT_KILL}
  --yes                 ${L_OPT_YES}
  --dry-run             ${L_OPT_DRY_RUN}
  --self-update         ${L_OPT_SELF_UPDATE}
  -h, --help            ${L_OPT_HELP}
EOF
}

common_dir() { echo "$NAVICAT_DIR/Common"; }
product_dir() { echo "$NAVICAT_DIR/$PRODUCT"; }
pref_file() { echo "$(product_dir)/preferences.json"; }
ui_pref_file() { echo "$(product_dir)/ui_preferences.json"; }
dconf_path() {
  local prod_lower
  prod_lower=$(echo "$PRODUCT" | tr '[:upper:]' '[:lower:]')
  echo "/com/premiumsoft/navicat-${prod_lower}/"
}

navicat_running() {
  pgrep -u "$(id -u)" -x navicat >/dev/null 2>&1 || \
    pgrep -u "$(id -u)" -x Navicat >/dev/null 2>&1
}

close_navicat_processes() {
  pkill -x navicat || true
  pkill -x Navicat || true
}

resolve_existing_backup_navicat_dir() {
  local dir=$1
  if [[ -d "$dir/navicat" ]]; then
    echo "$dir/navicat"
  elif [[ -d "$dir/Common" || -d "$dir/$PRODUCT" ]]; then
    echo "$dir"
  else
    die "$(fmt "$L_BACKUP_NO_CONFIG" "$dir")"
  fi
}

close_navicat_if_needed() {
  if [[ "$KILL_NAVICAT" -eq 1 ]]; then
    log "$L_CLOSE_NAVICAT"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "$(fmt "$L_DRY_RUN_RUN" "pkill -x navicat")"
    else
      close_navicat_processes
    fi
  fi
}

copy_file() {
  local src=$1 dst=$2
  if [[ -f "$src" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "$(fmt "$L_DRY_RUN_COPY" "$src" "$dst")"
    else
      mkdir -p "$(dirname "$dst")"
      cp -a "$src" "$dst"
    fi
  fi
}

copy_dir_contents() {
  local src=$1 dst=$2
  if [[ -d "$src" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "$(fmt "$L_DRY_RUN_COPY_DIR" "$src" "$dst")"
    else
      mkdir -p "$dst"
      cp -a "$src/." "$dst/"
    fi
  fi
}

# ==========================================
# 自更新逻辑
# ==========================================
write_update_check_cache() {
  local current_time=$1
  mkdir -p "$(dirname "$LAST_CHECK_FILE")" 2>/dev/null || return 1
  printf '%s\n' "$current_time" >"$LAST_CHECK_FILE" 2>/dev/null
}

current_script_version() {
  grep -m1 '^# version:' "$SCRIPT_PATH" 2>/dev/null | awk '{print $3}'
}

remote_candidate_url() {
  local entry=$1
  local mode proxy_url rest

  if [[ "$entry" == "direct" ]]; then
    printf '%s\n' "$UPDATE_SOURCE_URL"
    return 0
  fi

  mode=$(printf '%s' "$entry" | cut -d':' -f1)
  proxy_url=$(printf '%s' "$entry" | cut -d':' -f2-)
  case "$mode" in
    prefix)
      printf '%s%s\n' "$proxy_url" "$UPDATE_SOURCE_URL"
      ;;
    replace)
      rest=$(printf '%s' "$UPDATE_SOURCE_URL" | cut -f4- -d'/')
      printf '%s%s\n' "$proxy_url" "$rest"
      ;;
  esac
}

remote_candidate_label() {
  local entry=$1
  if [[ "$entry" == "direct" ]]; then
    printf '%s\n' "$L_SELF_UPDATE_DIRECT"
  else
    printf '%s\n' "$(printf '%s' "$entry" | cut -d':' -f2-)"
  fi
}

download_update_script() {
  local tmp_script=$1
  local candidates=("direct")
  local entry url label

  for entry in "${UPDATE_PROXIES[@]}"; do
    candidates+=("$entry")
  done

  for entry in "${candidates[@]}"; do
    url=$(remote_candidate_url "$entry")
    [[ -n "$url" ]] || continue
    label=$(remote_candidate_label "$entry")
    log "$(fmt "$L_SELF_UPDATE_FETCH" "$label")"
    if curl -fsSL --connect-timeout 10 --max-time 30 -o "$tmp_script" "$url" 2>/dev/null && [[ -s "$tmp_script" ]]; then
      return 0
    fi
  done

  return 1
}

version_gt() {
  local remote=${1#v}
  local current=${2#v}
  awk -v r="$remote" -v c="$current" '
    BEGIN {
      nr = split(r, rv, /[.-]/)
      nc = split(c, cv, /[.-]/)
      max = nr > nc ? nr : nc
      for (i = 1; i <= max; i++) {
        a = rv[i] + 0
        b = cv[i] + 0
        if (a > b) { print 1; exit }
        if (a < b) { print 0; exit }
      }
      print 0
    }
  '
}

check_self_update() {
  local force_check=$1
  local current_time last_check elapsed current_ver remote_ver tmp_script

  current_time=$(date +%s)

  if [[ "$force_check" != "true" ]]; then
    if [[ -f "$LAST_CHECK_FILE" ]]; then
      last_check=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)
      if [[ "$last_check" =~ ^[0-9]+$ ]]; then
        elapsed=$((current_time - last_check))
        [[ $elapsed -lt $CHECK_COOLDOWN ]] && return 0
      fi
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    [[ "$force_check" == "true" ]] && die "$L_SELF_UPDATE_SKIP_NO_CURL"
    return 0
  fi

  current_ver=$(current_script_version)
  if [[ -z "$current_ver" ]]; then
    [[ "$force_check" == "true" ]] && die "$L_SELF_UPDATE_SKIP_NO_VERSION"
    return 0
  fi

  log "$L_SELF_UPDATE_CHECKING"
  [[ "$force_check" == "true" ]] && log "$(fmt "$L_SELF_UPDATE_CURRENT_VERSION" "$current_ver")"

  tmp_script=$(mktemp)
  if ! download_update_script "$tmp_script"; then
    rm -f "$tmp_script"
    write_update_check_cache "$current_time" || log "$(fmt "$L_SELF_UPDATE_CACHE_WRITE_FAILED" "$LAST_CHECK_FILE")"
    [[ "$force_check" == "true" ]] && die "$L_SELF_UPDATE_DOWNLOAD_FAILED"
    return 0
  fi

  write_update_check_cache "$current_time" || log "$(fmt "$L_SELF_UPDATE_CACHE_WRITE_FAILED" "$LAST_CHECK_FILE")"

  if ! grep -q '^# title:[[:space:]]*navicat-manager.sh' "$tmp_script"; then
    rm -f "$tmp_script"
    [[ "$force_check" == "true" ]] && die "$L_SELF_UPDATE_INVALID_SCRIPT"
    return 0
  fi

  remote_ver=$(grep -m1 '^# version:' "$tmp_script" | awk '{print $3}')
  if [[ -z "$remote_ver" ]]; then
    rm -f "$tmp_script"
    [[ "$force_check" == "true" ]] && die "$L_SELF_UPDATE_PARSE_FAILED"
    return 0
  fi

  if [[ "$(version_gt "$remote_ver" "$current_ver")" == "1" ]]; then
    log "$(fmt "$L_SELF_UPDATE_NEW_VERSION" "$remote_ver" "$current_ver")"
    [[ -w "$SCRIPT_PATH" ]] || die "$(fmt "$L_SELF_UPDATE_WRITE_FAILED" "$SCRIPT_PATH")"
    log "$L_SELF_UPDATE_INSTALLING"
    cp "$tmp_script" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    rm -f "$tmp_script"
    log "$L_SELF_UPDATE_DONE"
    exit 0
  fi

  rm -f "$tmp_script"
  [[ "$force_check" == "true" ]] && log "$(fmt "$L_SELF_UPDATE_LATEST" "$current_ver")"
}

# ==========================================
# JSON 与 数据检查逻辑
# ==========================================
json_ok() {
  need_cmd jq
  jq empty "$1" >/dev/null 2>&1
}

portable_pref_keys() {
  need_cmd jq
  jq -r 'keys[]' "$1" 2>/dev/null | grep -E '^(Clouds|CloudSessions.*|Recents.*|Continues.*|AutoSaves.*)' || true
}

portable_pref_key_label() {
  case "$1" in
    AutoSaves*) echo "$1${L_LABEL_OPEN}${L_LABEL_AUTOSAVES}${L_LABEL_CLOSE}" ;;
    CloudSessions_SimpChinese*) echo "$1${L_LABEL_OPEN}${L_LABEL_CLOUD_SESSIONS_ZH}${L_LABEL_CLOSE}" ;;
    CloudSessions*) echo "$1${L_LABEL_OPEN}${L_LABEL_CLOUD_SESSIONS}${L_LABEL_CLOSE}" ;;
    Clouds*) echo "$1${L_LABEL_OPEN}${L_LABEL_CLOUDS}${L_LABEL_CLOSE}" ;;
    Continues*) echo "$1${L_LABEL_OPEN}${L_LABEL_CONTINUES}${L_LABEL_CLOSE}" ;;
    Recents*) echo "$1${L_LABEL_OPEN}${L_LABEL_RECENTS}${L_LABEL_CLOSE}" ;;
    *) echo "$1" ;;
  esac
}

print_portable_pref_key_labels() {
  local file=$1
  local key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    printf '  - %s\n' "$(portable_pref_key_label "$key")"
  done < <(portable_pref_keys "$file")
}

server_count() {
  if [[ -f "$1" ]]; then
    jq '[
      .Users[]?.Projects[]?.Servers[]?,
      .Users[]?.Projects[]?.Server[]?,
      .Users[]?.Project[]?.Servers[]?,
      .Users[]?.Project[]?.Server[]?,
      .Connections[]?,
      .connections[]?
    ] | length' "$1" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

ui_server_count() {
  if [[ -f "$1" ]]; then
    jq '[
      .User[]?.Project[]?.Server[]?,
      .User[]?.Projects[]?.Servers[]?,
      .User[]?.Projects[]?.Server[]?,
      .Users[]?.Projects[]?.Servers[]?,
      .Users[]?.Projects[]?.Server[]?,
      .Connections[]?,
      .connections[]?
    ] | length' "$1" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

cloud_session_count() {
  if [[ -f "$1" ]]; then
    jq '[to_entries[] | select(.key | startswith("CloudSessions")) | .value[]?] | length' "$1" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ==========================================
# 核心动作函数
# ==========================================
write_manifest() {
  local dir=$1
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "$(fmt "$L_DRY_RUN_MANIFEST" "$dir/manifest.txt")"
    return 0
  fi
  local navicat_copy="$dir/navicat"
  local connections="$navicat_copy/Common/connections.json"
  local ui_connections="$navicat_copy/Common/ui_connections.json"
  local preferences="$navicat_copy/$PRODUCT/preferences.json"
  cat <<EOF > "$dir/manifest.txt"
Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Product: $PRODUCT
NavicatDir: $NAVICAT_DIR
Servers: $(server_count "$connections")
UIConnectionEntries: $(ui_server_count "$ui_connections")
CloudSessions: $(cloud_session_count "$preferences")
EOF
}

copy_current_navicat_tree() {
  local out_dir=$1
  local out_navicat="$out_dir/navicat"
  mkdir -p "$out_navicat"
  copy_dir_contents "$(common_dir)" "$out_navicat/Common"
  copy_dir_contents "$(product_dir)" "$out_navicat/$PRODUCT"
  if command -v dconf >/dev/null 2>&1; then
    dconf dump "$(dconf_path)" > "$out_dir/dconf_navicat.dump" 2>/dev/null || true
  fi
}

backup_action() {
  local ts out_dir
  ts=$(date +%Y%m%d-%H%M%S)
  out_dir="$BACKUP_ROOT/backup-$ts"

  log "$(fmt "$L_START_BACKUP" "$out_dir")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "$(fmt "$L_DRY_RUN_BACKUP" "$(common_dir)" "$(product_dir)" "$out_dir/navicat")"
    return 0
  fi

  mkdir -p "$out_dir/navicat"
  copy_current_navicat_tree "$out_dir"

  write_manifest "$out_dir"
  log "$(fmt "$L_SAFETY_BACKUP_WRITTEN" "$out_dir")"
}

backup_before_write() {
  log "$L_SAFETY_BACKUP_BEFORE"
  backup_action
}

merge_preferences() {
  local src_pref=$1
  local dst_pref=$2

  [[ -f "$src_pref" ]] || return 0
  json_ok "$src_pref" || die "$(fmt "$L_INVALID_JSON" "$src_pref")"

  if [[ -f "$dst_pref" ]]; then
    json_ok "$dst_pref" || die "$(fmt "$L_INVALID_JSON" "$dst_pref")"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "$(fmt "$L_DRY_RUN_MERGE_PREF" "$src_pref" "$dst_pref")"
    print_portable_pref_key_labels "$src_pref"
    return 0
  fi

  local tmp_base tmp_out
  tmp_base=$(mktemp)
  tmp_out=$(mktemp)
  trap 'rm -f "$tmp_base" "$tmp_out"' RETURN

  if [[ -f "$dst_pref" ]]; then
    cp -a "$dst_pref" "$tmp_base"
  else
    printf '{}\n' >"$tmp_base"
  fi

  jq -s '
    def portable_key:
      . as $k |
      ($k == "Clouds")
      or ($k | startswith("CloudSessions"))
      or ($k | startswith("Recents"))
      or ($k | startswith("Continues"))
      or ($k | startswith("AutoSaves"));
    .[0] as $src |
    .[1] as $dst |
    reduce ($src | to_entries[] | select(.key | portable_key)) as $item
      ($dst; .[$item.key] = $item.value)
  ' "$src_pref" "$tmp_base" >"$tmp_out"

  jq empty "$tmp_out" >/dev/null
  mkdir -p "$(dirname "$dst_pref")"
  cp -a "$tmp_out" "$dst_pref"
  rm -f "$tmp_base" "$tmp_out"
  trap - RETURN
}

restore_preserved_state() {
  local src_navicat=$1
  local require_connections=${2:-0}
  local src_common="$src_navicat/Common"
  local src_product="$src_navicat/$PRODUCT"
  local dst_common
  local dst_product
  dst_common=$(common_dir)
  dst_product=$(product_dir)

  if [[ -f "$src_common/connections.json" ]]; then
    json_ok "$src_common/connections.json" || die "$(fmt "$L_INVALID_JSON" "$src_common/connections.json")"
    copy_file "$src_common/connections.json" "$dst_common/connections.json"
  elif [[ "$require_connections" -eq 1 ]]; then
    die "$(fmt "$L_MISSING_CONNECTIONS" "$src_common")"
  fi

  if [[ -f "$src_common/ui_connections.json" ]]; then
    json_ok "$src_common/ui_connections.json" || die "$(fmt "$L_INVALID_JSON" "$src_common/ui_connections.json")"
    copy_file "$src_common/ui_connections.json" "$dst_common/ui_connections.json"
  fi

  copy_file "$src_common/system_wide_preferences.json" "$dst_common/system_wide_preferences.json"
  copy_file "$src_product/ui_preferences.json" "$dst_product/ui_preferences.json"
  merge_preferences "$src_product/preferences.json" "$(pref_file)"
}

restore_action() {
  need_cmd jq
  [[ -n "$BACKUP_DIR" ]] || die "$L_MISSING_BACKUP_DIR"
  [[ -d "$BACKUP_DIR" ]] || die "$(fmt "$L_BACKUP_DIR_NOT_FOUND" "$BACKUP_DIR")"

  local src_navicat
  src_navicat=$(resolve_existing_backup_navicat_dir "$BACKUP_DIR")

  confirm "$(fmt "$L_CONFIRM_RESTORE" "$BACKUP_DIR")" || die "$L_CANCELLED"
  close_navicat_if_needed
  backup_before_write

  restore_preserved_state "$src_navicat" 1

  log "$L_RESTORE_FINISHED"
  inspect_action
}

inspect_action() {
  need_cmd jq

  local connections ui_connections preferences ui_preferences
  connections="$(common_dir)/connections.json"
  ui_connections="$(common_dir)/ui_connections.json"
  preferences="$(pref_file)"
  ui_preferences="$(ui_pref_file)"

  log "$(fmt "$L_INSPECT_NAVICAT_DIR" "$NAVICAT_DIR")"
  log "$(fmt "$L_INSPECT_PRODUCT" "$PRODUCT")"
  log "$(fmt "$L_INSPECT_CONNECTIONS_FILE" "$connections")"
  log "$(fmt "$L_INSPECT_SERVER_COUNT" "$(server_count "$connections")")"
  log "$(fmt "$L_INSPECT_UI_COUNT" "$(ui_server_count "$ui_connections")")"
  log "$(fmt "$L_INSPECT_CLOUD_COUNT" "$(cloud_session_count "$preferences")")"
  log "$(fmt "$L_INSPECT_UI_PREF" "$([[ -f "$ui_preferences" ]] && printf '%s' "$L_PRESENT" || printf '%s' "$L_MISSING")")"
  log "$L_INSPECT_PORTABLE_KEYS"
  if [[ -f "$preferences" ]]; then
    print_portable_pref_key_labels "$preferences"
  else
    log "  - $L_NONE"
  fi
  if command -v dconf >/dev/null 2>&1; then
    local dconf_lines
    dconf_lines=$(dconf dump "$(dconf_path)" 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    log "$(fmt "$L_DCONF_COUNT" "$(dconf_path)" "$dconf_lines")"
  fi
}

reset_action() {
  need_cmd jq
  confirm "$L_CONFIRM_RESET" || die "$L_CANCELLED"

  close_navicat_if_needed

  local pref
  pref=$(pref_file)
  local lock_file="${pref}.lock"
  local dconf_target
  dconf_target=$(dconf_path)
  local keep_dir keep_navicat
  keep_dir=$(mktemp -d)
  keep_navicat="$keep_dir/navicat"

  # 1. 保存当前连接、UI、账号会话配置，后续放回新配置里。
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "$(fmt "$L_DRY_RUN_PRESERVE" "$PRODUCT")"
  else
    log "$L_PRESERVE_CURRENT"
    copy_current_navicat_tree "$keep_dir"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "$(fmt "$L_DRY_RUN_RESET_DCONF" "$dconf_target")"
    log "$(fmt "$L_DRY_RUN_DELETE_FILE" "$pref")"
    log "$(fmt "$L_DRY_RUN_DELETE_FILE" "$lock_file")"
    rm -rf "$keep_dir"
    return 0
  fi

  # 2. 彻底重置状态
  log "$(fmt "$L_RESET_DCONF" "$dconf_target")"
  if command -v dconf >/dev/null 2>&1; then
    dconf reset -f "$dconf_target" 2>/dev/null || true
  fi

  log "$L_REMOVE_PREFS"
  rm -f "$pref" "$lock_file"

  log "$L_CLEANUP_DONE"
  echo ""
  echo "$L_START_NAVICAT"
  echo ""

  # 3. 等待新配置生成
  local max_wait=120
  local count=0
  log "$(fmt "$L_WAIT_PREF" "$pref")"

  while [[ ! -f "$pref" ]] && [[ $count -lt $max_wait ]]; do
    sleep 1
    count=$((count + 1))
    if (( count % 10 == 0 )); then
      printf "\r⏳ $(fmt "$L_WAIT_START_LONG" "$count")   "
    else
      printf "\r⏳ $(fmt "$L_WAIT_PREF_PROGRESS" "$count")   "
    fi
  done
  printf "\n"

  if [[ ! -f "$pref" ]]; then
    rm -rf "$keep_dir"
    log "❌ $L_TIMEOUT_PREF"
    die "$L_TIMEOUT_PREF_HINT"
  fi

  log "✅ $(fmt "$L_DETECTED_PREF" "$pref")"

  if navicat_running; then
    echo ""
    if confirm "$L_CONFIRM_AUTO_CLOSE_NAVICAT"; then
      log "$L_AUTO_CLOSE_NAVICAT"
      close_navicat_processes
    else
      echo "$L_CLOSE_NAVICAT_NOW"
    fi
    echo ""
  fi

  count=0
  while navicat_running && [[ $count -lt $max_wait ]]; do
    sleep 1
    count=$((count + 1))
    if (( count % 10 == 0 )); then
      printf "\r⏳ $(fmt "$L_WAIT_CLOSE_LONG" "$count")   "
    else
      printf "\r⏳ $(fmt "$L_WAIT_EXIT_PROGRESS" "$count")   "
    fi
  done
  printf "\n"

  if navicat_running; then
    rm -rf "$keep_dir"
    die "$(fmt "$L_NAVICAT_STILL_RUNNING" "$0")"
  fi

  log "✅ $L_NAVICAT_CLOSED"

  # 4. 放回连接文件、UI 状态和可迁移账号会话字段。
  log "$L_RESTORE_PREVIOUS"
  restore_preserved_state "$keep_navicat" 0
  rm -rf "$keep_dir"
  log "✅ $L_SETTINGS_MERGED"

  log "🎉 $L_RESET_DONE"
}

# ==========================================
# 参数解析与入口
# ==========================================
parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      backup|restore|inspect|reset)
        ACTION=$1
        shift
        ;;
    esac
  fi

  if [[ "$ACTION" == "restore" && $# -gt 0 && "$1" != --* ]]; then
    BACKUP_DIR=$1
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config-dir)
        [[ $# -ge 2 ]] || die "$(fmt "$L_ARG_MISSING" "--config-dir")"
        NAVICAT_DIR=$2
        shift 2
        ;;
      --backup-root)
        [[ $# -ge 2 ]] || die "$(fmt "$L_ARG_MISSING" "--backup-root")"
        BACKUP_ROOT=$2
        shift 2
        ;;
      --product)
        [[ $# -ge 2 ]] || die "$(fmt "$L_ARG_MISSING" "--product")"
        PRODUCT=$2
        shift 2
        ;;
      --kill)
        KILL_NAVICAT=1
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --self-update)
        SELF_UPDATE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "$(fmt "$L_UNKNOWN_ARG" "$1")"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ "$SELF_UPDATE" -eq 1 ]]; then
    check_self_update "true"
    exit 0
  fi

  if [[ -n "$ACTION" && "$DRY_RUN" -eq 0 ]]; then
    check_self_update "false"
  fi

  case "$ACTION" in
    backup)
      backup_action
      ;;
    restore)
      restore_action
      ;;
    inspect)
      inspect_action
      ;;
    reset)
      reset_action
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
