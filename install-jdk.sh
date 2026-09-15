#!/bin/bash
#===============================================================
# title:         install-jdk.sh
# description:   Interactively install one of seven OpenJDK distributions
#                (Zulu / Temurin / Corretto / Dragonwell / Liberica / Kona /
#                BiSheng) with per-distro version menus, LTS tags, install
#                registry update checks and stable jdk<major> symlinks
# author:        duanluan<duanluan@outlook.com>
# date:          2026-09-14
# version:       v1.2
# usage:         install-jdk.sh [--self-update]
#
# description_zh:
#   交互式安装七个发行版的 OpenJDK（Zulu / Temurin / Corretto / Dragonwell /
#   Liberica / Kona / 毕昇）：依赖按六种包管理器自动安装、架构与 musl 识别、
#   大版本倒序菜单并标注 LTS、下载后按官方来源校验完整性（API 字段或旁挂
#   文件，无来源时警告跳过）、安装登记表（已是最新询问重装 / 旧版本走更新
#   并可清理旧目录）、带平台后缀的目录可选去后缀、jdk<大版本> 稳定软链接、
#   JAVA_HOME 三种配置范围。
#   运行 --self-update 强制更新脚本自身；平时每次运行静默检查（每日一次）。
#
# changelog:
#   v1.2 (2026-09-15)：下载后按官方来源校验完整性（sha256/sha1/md5），失配
#                     即中止；无校验源的发行版（Corretto/Dragonwell）警告跳过
#   v1.1 (2026-09-14)：新增 Eclipse Temurin、Amazon Corretto、BellSoft
#                     Liberica、Tencent Kona、毕昇 JDK 五个发行版；目录
#                     去平台后缀重命名推广到所有带 -linux_* 目录的发行版
#   v1.0 (2026-09-14)：由 install-jdk-dragonwell.sh 重构而来：支持 Zulu
#                     （Azul Metadata API）、安装登记表更新检查、LTS 标注、
#                     稳定软链接、目录重命名、脚本自更新
#===============================================================

set -euo pipefail

# Testing overrides (all optional): INSTALL_DIR (prompt default), PROFILE_D,
# RC_FILE, ETC_PROFILE, DB_FILE, SUDO ("" disables privilege escalation),
# INSTALL_JDK_UPDATE_URL (self-update source), INSTALL_JDK_SKIP_SELF_UPDATE=1.
SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
UPDATE_SOURCE_URL="${INSTALL_JDK_UPDATE_URL:-https://raw.githubusercontent.com/duanluan/shell-scripts/refs/heads/main/install-jdk.sh}"
LAST_CHECK_FILE="$HOME/.cache/install-jdk.last_check"
CHECK_COOLDOWN=86400

# mirror-first download candidates for self-update (same set as the other
# scripts in this repo)
declare -a UPDATE_PROXIES=(
  "prefix:https://gh-proxy.com/"
  "prefix:https://ghproxy.net/"
  "prefix:https://ghfast.top/"
  "prefix:https://fastgit.cc/"
)

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

L_CHECK_DEPS=">>> [0/8] Checking dependencies..."
L_DEPS_PASS="Dependencies checked."
L_ERR_MISSING="Error: Missing tools:"
L_PM_UNKNOWN="No supported package manager found. Please install manually and retry:"
L_ERR_INSTALL_DEP="Error: failed to install missing tools, see output above."
L_CONFIG=">>> [1/8] Configure installation..."
L_ASK_DIR="Install directory [%s]: "
L_ERR_DIR="Please enter an absolute path starting with '/'."
L_DIR_ROOT="Install dir requires root privileges."
L_DIR_NOROOT="Install dir is user-writable (no root needed)."
L_ASK_ENV="Configure JAVA_HOME environment variable?"
L_ENV_OPT1="  1) Skip (configure it myself later)"
L_ENV_OPT2="  2) System-wide (all users): %s"
L_ENV_OPT3="  3) Current user only: %s"
L_ERR_NO_ROOT="Error: root privileges required for this step. Run as root or install sudo:"
L_SELECT_DISTRO=">>> [2/8] Select distribution"
L_DISTRO_OPT1="  1) Azul Zulu (official OpenJDK build, global CDN)"
L_DISTRO_OPT2="  2) Eclipse Temurin (Adoptium, the community default)"
L_DISTRO_OPT3="  3) Amazon Corretto (AWS, free LTS)"
L_DISTRO_OPT4="  4) Alibaba Dragonwell (Alibaba OpenJDK, Aliyun OSS mirror)"
L_DISTRO_OPT5="  5) BellSoft Liberica (Spring-recommended, musl builds)"
L_DISTRO_OPT6="  6) Tencent Kona (Tencent OpenJDK)"
L_DISTRO_OPT7="  7) BiSheng JDK (Huawei openEuler, Kunpeng-optimized)"
L_ARCH_DETECT="Detected architecture:"
L_MUSL_NOTICE="musl (Alpine) detected: musl build preferred when available."
L_SELECT_VERSION=">>> [3/8] Select version"
L_SELECT_SOURCE="Select download source"
L_SELECT_TYPE="Select distribution type"
L_QUERY_VERSIONS="Querying available versions (takes a few seconds)..."
L_CHECKSUM_VERIFY="Verifying checksum..."
L_ERR_CHECKSUM="Checksum mismatch (%s): expected %s, got %s. The download may be corrupted or tampered with — aborted."
L_WARN_NO_CHECKSUM="%s: no checksum available for this build, skipping integrity check."
L_ERR_FETCH="Error: failed to fetch the release index:"
L_ZULU_ERR="Error: no Zulu JDK package for this architecture/libc."
L_NO_VERSION="Error: no release for this source/type/arch."
L_INVALID_INPUT="Invalid choice, try again."
L_UPDATE_CHECK=">>> [4/8] Checking installed version..."
L_INSTALLED_FOUND="Installed on record:"
L_ALREADY_LATEST="You already have the latest version (%s)."
L_ASK_FORCE="Force reinstall? [y/N]: "
L_ABORT_USER="Aborted by user."
L_UPDATING="Updating %s: %s -> %s."
L_ASK_REMOVE_OLD="Remove the old directory after the update? [y/N]: "
L_ASK_RENAME="Rename the installed directory to '%s' (drop the -linux_* suffix)? [Y/n]: "
L_ASK_SYMLINK="Create a stable symlink '%s' -> '%s' (JAVA_HOME survives updates)? [Y/n]: "
L_SYMLINK_SKIP="'%s' already exists and is not a symlink; symlink skipped."
L_OLD_REMOVED="Removed old directory:"
L_OLD_KEPT="Old directory kept:"
L_DOWNLOAD=">>> [5/8] Downloading..."
L_ERR_DOWNLOAD="Error: download failed:"
L_INSTALL=">>> [6/8] Extracting to"
L_ERR_TOPDIR="Error: unexpected archive layout (no top-level directory)."
L_ENV_WRITE=">>> [7/8] Writing environment:"
L_MIGRATE_BACKUP="Legacy JAVA_HOME lines found in profile, backing up to"
L_LEGACY_SKIP="Legacy JAVA_HOME lines (from the old script) left in %s: they may point to a removed directory."
L_VERIFY=">>> [8/8] Installed. Verify:"
L_DONE="Done."
L_RELOGIN_HINT="Run 'source %s' or re-login, then 'java -version' will use the new JDK."
L_MANUAL_ENV="Add these lines to your shell profile if needed:"
L_SELF_UPDATE_CHECKING="Checking for script updates..."
L_SELF_UPDATE_FETCH="Fetching update: %s"
L_SELF_UPDATE_DOWNLOAD_FAILED="Update check failed: script download failed."
L_SELF_UPDATE_INVALID_SCRIPT="Update check failed: downloaded file is not install-jdk.sh."
L_SELF_UPDATE_PARSE_FAILED="Update check failed: remote version was not found."
L_SELF_UPDATE_CURRENT_VERSION="Local version: %s"
L_SELF_UPDATE_NEW_VERSION="New version found: %s (current: %s)"
L_SELF_UPDATE_INSTALLING="Updating script..."
L_SELF_UPDATE_DONE="Update finished. Rerun the script."
L_SELF_UPDATE_CONTINUING="Update finished. Continuing with the requested action..."
L_SELF_UPDATE_RESTART_FAILED="Could not restart updated script: %s"
L_SELF_UPDATE_LATEST="Already up to date (%s)."
L_SELF_UPDATE_SKIP_NO_CURL="Skipping update check: curl is not installed."
L_SELF_UPDATE_SKIP_NO_VERSION="Skipping update check: local version was not found."
L_SELF_UPDATE_WRITE_FAILED="Cannot write to script path: %s"
L_SELF_UPDATE_DIRECT="direct"
L_SELF_UPDATE_CACHE_WRITE_FAILED="Could not write update check cache: %s"
L_DL_MIRROR="Downloading via: %s"

if [[ "${LANG:-}" == *"zh_"* ]]; then
  L_CHECK_DEPS=">>> [0/8] 检查依赖..."
  L_DEPS_PASS="依赖检查通过。"
  L_ERR_MISSING="错误：缺少以下工具："
  L_PM_UNKNOWN="未识别到受支持的包管理器，请手动安装后重试："
  L_ERR_INSTALL_DEP="错误：依赖安装失败，请检查上方输出。"
  L_CONFIG=">>> [1/8] 配置安装选项..."
  L_ASK_DIR="安装目录 [%s]："
  L_ERR_DIR="请输入以 / 开头的绝对路径。"
  L_DIR_ROOT="该目录需要 root 权限写入。"
  L_DIR_NOROOT="该目录当前用户可写（无需 root）。"
  L_ASK_ENV="是否配置 JAVA_HOME 环境变量？"
  L_ENV_OPT1="  1) 跳过（之后自行配置）"
  L_ENV_OPT2="  2) 全局（所有用户）：%s"
  L_ENV_OPT3="  3) 仅当前用户：%s"
  L_ERR_NO_ROOT="错误：此步骤需要 root 权限，请以 root 运行或安装 sudo："
  L_SELECT_DISTRO=">>> [2/8] 选择发行版"
  L_DISTRO_OPT1="  1) Azul Zulu（官方 OpenJDK 构建，全球 CDN）"
  L_DISTRO_OPT2="  2) Eclipse Temurin（Eclipse 基金会，社区首选）"
  L_DISTRO_OPT3="  3) Amazon Corretto（AWS 免费 LTS）"
  L_DISTRO_OPT4="  4) Alibaba Dragonwell（阿里 OpenJDK，阿里云 OSS 源）"
  L_DISTRO_OPT5="  5) BellSoft Liberica（Spring 推荐，支持 musl）"
  L_DISTRO_OPT6="  6) Tencent Kona（腾讯 OpenJDK）"
  L_DISTRO_OPT7="  7) 毕昇 JDK（华为 openEuler，鲲鹏优化）"
  L_ARCH_DETECT="检测到架构："
  L_MUSL_NOTICE="检测到 musl（Alpine）：优先使用 musl 构建。"
  L_SELECT_VERSION=">>> [3/8] 选择版本"
  L_SELECT_SOURCE="选择下载源"
  L_SELECT_TYPE="选择发行类型"
  L_QUERY_VERSIONS="查询可用版本（需几秒钟）..."
  L_CHECKSUM_VERIFY="正在校验完整性..."
  L_ERR_CHECKSUM="校验和不匹配（%s）：期望 %s，实际 %s。下载可能已损坏或被篡改，已中止。"
  L_WARN_NO_CHECKSUM="%s：该版本没有可用的校验和来源，跳过完整性检查。"
  L_ERR_FETCH="错误：获取版本索引失败："
  L_ZULU_ERR="错误：该架构/libc 下没有可用的 Zulu JDK 包。"
  L_NO_VERSION="错误：该下载源/类型/架构下没有可用版本。"
  L_INVALID_INPUT="输入无效，请重试。"
  L_UPDATE_CHECK=">>> [4/8] 检查已安装版本..."
  L_INSTALLED_FOUND="已有安装记录："
  L_ALREADY_LATEST="检测到您已经安装了该版本（%s）。"
  L_ASK_FORCE="是否强制重新安装？[y/N]："
  L_ABORT_USER="用户已取消。"
  L_UPDATING="更新 %s：%s -> %s。"
  L_ASK_REMOVE_OLD="更新完成后是否删除旧版本目录？[y/N]："
  L_ASK_RENAME="是否将安装目录重命名为 '%s'（去掉 -linux_* 后缀）？[Y/n]："
  L_ASK_SYMLINK="是否创建稳定软链接 '%s' -> '%s'（JAVA_HOME 更新后仍有效）？[Y/n]："
  L_SYMLINK_SKIP="'%s' 已存在且不是软链接，已跳过软链接创建。"
  L_OLD_REMOVED="已删除旧目录："
  L_OLD_KEPT="保留旧目录："
  L_DOWNLOAD=">>> [5/8] 下载中..."
  L_ERR_DOWNLOAD="错误：下载失败："
  L_INSTALL=">>> [6/8] 解压到"
  L_ERR_TOPDIR="错误：压缩包结构异常（未找到顶层目录）。"
  L_ENV_WRITE=">>> [7/8] 写入环境变量："
  L_MIGRATE_BACKUP="检测到旧版脚本写入 /etc/profile 的 JAVA_HOME 配置，已备份到"
  L_LEGACY_SKIP="%s 中仍留有旧版脚本写入的 JAVA_HOME 配置，可能指向已删除的目录。"
  L_VERIFY=">>> [8/8] 安装完成，验证："
  L_DONE="完成。"
  L_RELOGIN_HINT="执行 'source %s' 或重新登录后，'java -version' 即为新 JDK。"
  L_MANUAL_ENV="如需手动配置环境变量，可在 shell 配置文件中加入以下两行："
  L_SELF_UPDATE_CHECKING="正在检查脚本更新..."
  L_SELF_UPDATE_FETCH="获取更新：%s"
  L_SELF_UPDATE_DOWNLOAD_FAILED="更新检查失败：脚本下载失败。"
  L_SELF_UPDATE_INVALID_SCRIPT="更新检查失败：下载的文件不是 install-jdk.sh。"
  L_SELF_UPDATE_PARSE_FAILED="更新检查失败：未找到远端版本号。"
  L_SELF_UPDATE_CURRENT_VERSION="本地版本: %s"
  L_SELF_UPDATE_NEW_VERSION="发现新版本: %s（当前: %s）"
  L_SELF_UPDATE_INSTALLING="正在更新脚本..."
  L_SELF_UPDATE_DONE="更新完成，请重新运行脚本。"
  L_SELF_UPDATE_CONTINUING="更新完成，继续执行原操作..."
  L_SELF_UPDATE_RESTART_FAILED="无法重启更新后的脚本: %s"
  L_SELF_UPDATE_LATEST="已是最新版本（%s）。"
  L_SELF_UPDATE_SKIP_NO_CURL="跳过更新检查：未安装 curl。"
  L_SELF_UPDATE_SKIP_NO_VERSION="跳过更新检查：未找到本地版本号。"
  L_SELF_UPDATE_WRITE_FAILED="无法写入脚本路径: %s"
  L_SELF_UPDATE_DIRECT="直连"
  L_SELF_UPDATE_CACHE_WRITE_FAILED="无法写入更新检查缓存: %s"
  L_DL_MIRROR="下载渠道：%s"
fi

DRAGONWELL_URL="https://dragonwell-jdk.io/releases.json"
ZULU_API="https://api.azul.com/metadata/v1/zulu/packages/"
INSTALL_DIR_DEFAULT="${INSTALL_DIR:-/opt/java}"
PROFILE_D="${PROFILE_D:-/etc/profile.d/java.sh}"
ETC_PROFILE="${ETC_PROFILE:-/etc/profile}"
DB_FILE="${DB_FILE:-}"  # resolved after INSTALL_DIR is chosen
# user-scope env file, resolved from the login shell (overridable via RC_FILE)
RC_FILE="${RC_FILE:-}"
if [ -z "$RC_FILE" ]; then
  case "${SHELL:-}" in
    *zsh) RC_FILE="$HOME/.zshrc" ;;
    *)    RC_FILE="$HOME/.bashrc" ;;
  esac
fi

die() { echo -e "${RED}${1}${NC}" >&2; exit 1; }

# Run a command with root privileges (skipped when already root, or when the
# SUDO env override is set -- SUDO="" forces no escalation for tests).
as_root() {
  if [ "${SUDO+x}" = "x" ]; then
    if [ -n "$SUDO" ]; then $SUDO "$@"; else "$@"; fi
  elif [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    command -v sudo > /dev/null 2>&1 \
      || die "${L_ERR_NO_ROOT} $*"
    sudo "$@"
  fi
}

# Operations on INSTALL_DIR: plain when the dir is user-writable
DIR_NEEDS_ROOT=0
dir_op() {
  if [ "$DIR_NEEDS_ROOT" -eq 1 ]; then as_root "$@"; else "$@"; fi
}

read_choice() {
  # $1: prompt   $2: default (may be empty)   $3: max
  local reply
  while :; do
    read -r -p "$1" reply || die "aborted."
    reply="${reply:-$2}"
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "$3" ]; then
      echo "$reply"
      return 0
    fi
    echo -e "${YELLOW}${L_INVALID_INPUT}${NC}" >&2
  done
}

ask_yes_no() { # $1: prompt   $2: default (y|n) -> return 0 on yes
  local reply
  read -r -p "$1" reply || die "aborted."
  if [ "$2" = "y" ]; then
    [[ ! "$reply" =~ ^[Nn]$ ]]
  else
    [[ "$reply" =~ ^[Yy]$ ]]
  fi
}

# Java LTS lines: 8 and 11, then every 4 majors since 17 (17/21/25/29...);
# the upstream indexes have no LTS flag, so this cadence is used to tag menus
java_lts_tag() { # $1: major -> "  (LTS)" or empty
  local m="$1"
  if [ "$m" -eq 8 ] || [ "$m" -eq 11 ] \
    || { [ "$m" -ge 17 ] && [ $(( (m - 17) % 4 )) -eq 0 ]; }; then
    echo "  (LTS)"
  fi
}

# ==========================================
# Script self-update (mirror-first, same pattern as navicat-manager.sh)
# ==========================================
self_update_log() { echo -e "${BLUE}${1}${NC}"; }

# download with CN-friendly fallbacks for github.com assets (same mirror set
# as the self-update check); non-github URLs download directly
download_file() { # $1: output file   $2: url
  local entry target
  if [[ "$2" != https://github.com/* ]]; then
    curl -fL --progress-bar --retry 3 --connect-timeout 15 -o "$1" "$2"
    return 0
  fi
  for entry in "${UPDATE_PROXIES[@]}" direct; do
    target="$2"
    [ "$entry" = "direct" ] || target="${entry#prefix:}${target}"
    self_update_log "$(printf "${L_DL_MIRROR}" "$(remote_candidate_label "$entry")")"
    if curl -fL --progress-bar --retry 3 --connect-timeout 15 -o "$1" "${target}"; then
      return 0
    fi
  done
  return 1
}

write_update_check_cache() { # $1: current unix time
  mkdir -p "$(dirname -- "$LAST_CHECK_FILE")" 2>/dev/null || true
  printf '%s\n' "$1" > "$LAST_CHECK_FILE" 2>/dev/null
}

current_script_version() {
  grep -m1 '^# version:' "$SCRIPT_PATH" 2>/dev/null | awk '{print $3}'
}

remote_candidate_url() {
  if [ "$1" = "direct" ]; then
    printf '%s\n' "$UPDATE_SOURCE_URL"
    return 0
  fi
  printf '%s%s\n' "${1#prefix:}" "$UPDATE_SOURCE_URL"
}

remote_candidate_label() {
  if [ "$1" = "direct" ]; then
    printf '%s\n' "$L_SELF_UPDATE_DIRECT"
  else
    printf '%s\n' "${1#prefix:}"
  fi
}

download_update_script() { # $1: temp file -> 0 on success
  local entry
  for entry in "${UPDATE_PROXIES[@]}" direct; do
    # per-candidate lines are verbose output: only shown for --self-update
    if [ "${SELF_UPDATE_VERBOSE:-0}" = "1" ]; then
      self_update_log "$(printf "${L_SELF_UPDATE_FETCH}" "$(remote_candidate_label "$entry")")"
    fi
    if curl -fsSL --connect-timeout 10 --max-time 30 -o "$1" "$(remote_candidate_url "$entry")" 2>/dev/null \
      && [ -s "$1" ]; then
      return 0
    fi
  done
  return 1
}

version_gt() { # $1 remote   $2 current -> 1 when remote is newer
  local remote="${1#v}" current="${2#v}"
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

check_self_update() { # $1: force (true/false)   $2...: original args to re-exec
  local force_check="$1"
  shift
  local current_time last_check elapsed current_ver remote_ver tmp_script install_tmp

  [ "$force_check" = "true" ] || [ "${INSTALL_JDK_SKIP_SELF_UPDATE:-0}" != "1" ] || return 0

  current_time="$(date +%s)"
  if [ "$force_check" != "true" ] && [ -f "$LAST_CHECK_FILE" ]; then
    last_check="$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)"
    if [[ "$last_check" =~ ^[0-9]+$ ]]; then
      elapsed=$((current_time - last_check))
      [ "$elapsed" -lt "$CHECK_COOLDOWN" ] && return 0 || true
    fi
  fi

  if ! command -v curl > /dev/null 2>&1; then
    [ "$force_check" = "true" ] && die "${L_SELF_UPDATE_SKIP_NO_CURL}" || true
    return 0
  fi

  current_ver="$(current_script_version)"
  if [ -z "$current_ver" ]; then
    [ "$force_check" = "true" ] && die "${L_SELF_UPDATE_SKIP_NO_VERSION}" || true
    return 0
  fi

  self_update_log "${L_SELF_UPDATE_CHECKING}"
  SELF_UPDATE_VERBOSE=0
  if [ "$force_check" = "true" ]; then
    SELF_UPDATE_VERBOSE=1
    self_update_log "$(printf "${L_SELF_UPDATE_CURRENT_VERSION}" "$current_ver")"
  fi

  tmp_script="$(mktemp)"
  if ! download_update_script "$tmp_script"; then
    rm -f "$tmp_script"
    write_update_check_cache "$current_time" \
      || self_update_log "$(printf "${L_SELF_UPDATE_CACHE_WRITE_FAILED}" "$LAST_CHECK_FILE")"
    [ "$force_check" = "true" ] && die "${L_SELF_UPDATE_DOWNLOAD_FAILED}" || true
    return 0
  fi

  write_update_check_cache "$current_time" \
    || self_update_log "$(printf "${L_SELF_UPDATE_CACHE_WRITE_FAILED}" "$LAST_CHECK_FILE")"

  if ! grep -q '^# title:[[:space:]]*install-jdk.sh' "$tmp_script"; then
    rm -f "$tmp_script"
    [ "$force_check" = "true" ] && die "${L_SELF_UPDATE_INVALID_SCRIPT}" || true
    return 0
  fi

  remote_ver="$(grep -m1 '^# version:' "$tmp_script" | awk '{print $3}')"
  if [ -z "$remote_ver" ]; then
    rm -f "$tmp_script"
    [ "$force_check" = "true" ] && die "${L_SELF_UPDATE_PARSE_FAILED}" || true
    return 0
  fi

  if [ "$(version_gt "$remote_ver" "$current_ver")" = "1" ]; then
    self_update_log "$(printf "${L_SELF_UPDATE_NEW_VERSION}" "$remote_ver" "$current_ver")"
    [ -w "$SCRIPT_PATH" ] && [ -w "$(dirname -- "$SCRIPT_PATH")" ] \
      || die "$(printf "${L_SELF_UPDATE_WRITE_FAILED}" "$SCRIPT_PATH")"
    self_update_log "${L_SELF_UPDATE_INSTALLING}"
    install_tmp="$(mktemp "${SCRIPT_PATH}.tmp.XXXXXX")" \
      || die "$(printf "${L_SELF_UPDATE_WRITE_FAILED}" "$SCRIPT_PATH")"
    cp "$tmp_script" "$install_tmp"
    chmod +x "$install_tmp"
    mv "$install_tmp" "$SCRIPT_PATH"
    rm -f "$tmp_script"
    if [ "$force_check" = "true" ]; then
      self_update_log "${L_SELF_UPDATE_DONE}"
      exit 0
    fi
    self_update_log "${L_SELF_UPDATE_CONTINUING}"
    INSTALL_JDK_SKIP_SELF_UPDATE=1 exec "$SCRIPT_PATH" "$@"
    die "$(printf "${L_SELF_UPDATE_RESTART_FAILED}" "$SCRIPT_PATH")"
  fi

  rm -f "$tmp_script"
  [ "$force_check" = "true" ] && self_update_log "$(printf "${L_SELF_UPDATE_LATEST}" "$current_ver")" || true
  return 0
}

# --- script self-update -------------------------------------------------------
if [ "${1:-}" = "--self-update" ]; then
  check_self_update "true"
  exit 0
fi
check_self_update "false" "$@"

# --- [0/8] dependencies -------------------------------------------------------
echo -e "${BLUE}${L_CHECK_DEPS}${NC}"

MISSING=()
command -v curl > /dev/null 2>&1 || MISSING+=("curl")
command -v jq > /dev/null 2>&1 || MISSING+=("jq")
command -v tar > /dev/null 2>&1 || MISSING+=("tar")

if [ ${#MISSING[@]} -ne 0 ]; then
  echo -e "${YELLOW}${L_ERR_MISSING} ${MISSING[*]}${NC}"

  detect_pm() {
    local pm
    for pm in apt-get dnf yum zypper pacman apk; do
      if command -v "$pm" > /dev/null 2>&1; then
        echo "$pm"
        return 0
      fi
    done
    return 1
  }

  PM="$(detect_pm)" || {
    echo -e "${RED}${L_PM_UNKNOWN}${NC}"
    echo "  Debian/Ubuntu:  sudo apt-get install curl jq tar"
    echo "  Fedora/RHEL:    sudo dnf install curl jq tar"
    echo "  openSUSE:       sudo zypper install curl jq tar"
    echo "  Arch:           sudo pacman -S curl jq tar"
    echo "  Alpine:         sudo apk add curl jq tar"
    exit 1
  }

  echo ">>> package manager: ${PM}"
  case "$PM" in
    apt-get) as_root apt-get update -qq && as_root apt-get install -y "${MISSING[@]}" ;;
    dnf)     as_root dnf install -y "${MISSING[@]}" ;;
    yum)     as_root yum install -y "${MISSING[@]}" ;;
    zypper)  as_root zypper --non-interactive install "${MISSING[@]}" ;;
    pacman)  as_root pacman -S --needed --noconfirm "${MISSING[@]}" ;;
    apk)     as_root apk add "${MISSING[@]}" ;;
  esac || die "${L_ERR_INSTALL_DEP}"
fi
echo -e "${GREEN}${L_DEPS_PASS}${NC}"

# --- [1/8] configure: install dir + env scope ---------------------------------
echo -e "${BLUE}${L_CONFIG}${NC}"

while :; do
  read -r -e -p "$(printf "${L_ASK_DIR}" "${INSTALL_DIR_DEFAULT}")" REPLY || die "aborted."
  REPLY="${REPLY:-${INSTALL_DIR_DEFAULT}}"
  REPLY="${REPLY/#\~/$HOME}"
  REPLY="${REPLY%/}"
  if [[ "$REPLY" == /* ]] && [ "$REPLY" != "/" ]; then
    INSTALL_DIR="$REPLY"
    break
  fi
  echo -e "${YELLOW}${L_ERR_DIR}${NC}" >&2
done

# does the install dir need root? (mkdir first if we can)
if [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; then
  :
elif mkdir -p "$INSTALL_DIR" 2>/dev/null && [ -w "$INSTALL_DIR" ]; then
  :
else
  DIR_NEEDS_ROOT=1
fi
if [ "$DIR_NEEDS_ROOT" -eq 1 ]; then
  echo -e "${BLUE}${L_DIR_ROOT}${NC}"
else
  echo -e "${BLUE}${L_DIR_NOROOT}${NC}"
fi
DB_FILE="${DB_FILE:-${INSTALL_DIR}/.install-jdk.db}"

# env scope defaults to skip; the user opts in when wanted
DEFAULT_ENV=1

echo -e "${BLUE}${L_ASK_ENV}${NC}"
echo "${L_ENV_OPT1}"
printf "${L_ENV_OPT2}\n" "$PROFILE_D"
printf "${L_ENV_OPT3}\n" "$RC_FILE"
ENV_MODE="$(read_choice "env [1-3], default ${DEFAULT_ENV}: " "$DEFAULT_ENV" 3)"

# --- architecture / libc ------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  ARCH_LABEL="x64";      ZULU_ARCH="x86_64";  ZULU_NAME_ARCH="x64" ;;
  aarch64|arm64) ARCH_LABEL="aarch64";  ZULU_ARCH="aarch64"; ZULU_NAME_ARCH="aarch64" ;;
  riscv64)       ARCH_LABEL="riscv64";  ZULU_ARCH="";        ZULU_NAME_ARCH="" ;;
  *) die "Unsupported architecture: ${ARCH}" ;;
esac
echo -e "${BLUE}${L_ARCH_DETECT} ${ARCH_LABEL} (${ARCH})${NC}"

MUSL=0
if ldd --version 2>&1 | head -1 | grep -qi musl; then
  MUSL=1
  echo -e "${BLUE}${L_MUSL_NOTICE}${NC}"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

# --- [2/8] distribution -------------------------------------------------------
echo -e "${BLUE}${L_SELECT_DISTRO}${NC}"
echo "${L_DISTRO_OPT1}"
echo "${L_DISTRO_OPT2}"
echo "${L_DISTRO_OPT3}"
echo "${L_DISTRO_OPT4}"
echo "${L_DISTRO_OPT5}"
echo "${L_DISTRO_OPT6}"
echo "${L_DISTRO_OPT7}"
CHOICE="$(read_choice 'distribution [1-7], default 1: ' 1 7)"
case "$CHOICE" in
  1) DISTRO="zulu";       DISTRO_LABEL="Zulu" ;;
  2) DISTRO="temurin";    DISTRO_LABEL="Temurin" ;;
  3) DISTRO="corretto";   DISTRO_LABEL="Corretto" ;;
  4) DISTRO="dragonwell"; DISTRO_LABEL="Dragonwell" ;;
  5) DISTRO="liberica";   DISTRO_LABEL="Liberica" ;;
  6) DISTRO="kona";       DISTRO_LABEL="Kona" ;;
  7) DISTRO="bisheng";    DISTRO_LABEL="BiSheng" ;;
esac

# --- [3/8] version ------------------------------------------------------------
echo -e "${BLUE}${L_SELECT_VERSION}${NC}"
MAJOR=""
VERSION=""
DOWNLOAD_URL=""
# integrity check, set per distro: algo (sha256|sha1|md5) + expected hash
# fetched from the trusted origin (API response or sidecar file, never the
# download proxy); empty = no source, warn and skip
CHECKSUM_ALGO=""
CHECKSUM_EXPECTED=""

if [ "$DISTRO" = "dragonwell" ]; then
  # URL key for this arch (Dragonwell musl builds are x64-only: apurl)
  ARCH_KEY="x"; [ "$ARCH_LABEL" = "aarch64" ] && ARCH_KEY="a"
  [ "$ARCH_LABEL" = "riscv64" ] && ARCH_KEY="r"
  PREF_KEY="${ARCH_KEY}url"
  FALLBACK_KEY="${ARCH_KEY}url"
  [ "$MUSL" -eq 1 ] && [ "$ARCH_KEY" = "x" ] && PREF_KEY="apurl" || true

  echo "${L_SELECT_SOURCE}"
  echo "  1) Aliyun OSS (fast in China)   2) GitHub Releases"
  CHOICE="$(read_choice 'source [1-2], default 1: ' 1 2)"
  case "$CHOICE" in
    1) SRC="oss" ;;
    2) SRC="github" ;;
  esac

  echo "${L_SELECT_TYPE}"
  echo "  1) extended (more features)   2) standard (LTS upstream)"
  CHOICE="$(read_choice 'type [1-2], default 1: ' 1 2)"
  case "$CHOICE" in
    1) TYPE="extended" ;;
    2) TYPE="standard" ;;
  esac

  JSON_FILE="${WORK_DIR}/releases.json"
  curl -fsSL --retry 3 --connect-timeout 15 -o "${JSON_FILE}" "${DRAGONWELL_URL}" \
    || die "${L_ERR_FETCH} ${DRAGONWELL_URL}"
  SECTION_JSON="$(jq -c --arg s "$SRC" --arg t "$TYPE" '.[$s][$t] // {}' "${JSON_FILE}")"

  # Lines "major<TAB>version" for release lines that have a URL for our arch.
  mapfile -t VERSION_ROWS < <(jq -r --arg pref "${PREF_KEY}" --arg fb "${FALLBACK_KEY}" '
    . as $sec
    | [ $sec | to_entries[]
        | select(.key | test("^version[0-9]+$"))
        | select(.value != null and .value != "0")
        | .key | ltrimstr("version") | tonumber ]
    | sort | reverse | .[]  # newest major first
    | . as $m
    | select(($sec[$pref + ($m | tostring)] // $sec[$fb + ($m | tostring)]) != null)
    | "\($m)\t\($sec["version" + ($m | tostring)])"
  ' <<<"${SECTION_JSON}")

  [ ${#VERSION_ROWS[@]} -ne 0 ] || die "${L_NO_VERSION}"
  for i in "${!VERSION_ROWS[@]}"; do
    major="$(cut -f1 <<<"${VERSION_ROWS[$i]}")"
    echo "  $((i + 1))) JDK ${major}$(java_lts_tag "$major")  (Dragonwell $(cut -f2 <<<"${VERSION_ROWS[$i]}"))"
  done

  CHOICE="$(read_choice "version [1-${#VERSION_ROWS[@]}]: " "" "${#VERSION_ROWS[@]}")"
  ROW="${VERSION_ROWS[$((CHOICE - 1))]}"
  MAJOR="$(cut -f1 <<<"$ROW")"
  VERSION="$(cut -f2 <<<"$ROW")"
  DOWNLOAD_URL="$(jq -r --arg p "${PREF_KEY}${MAJOR}" --arg f "${FALLBACK_KEY}${MAJOR}" \
    'if (.[$p] // "") != "" then .[$p] else .[$f] end' <<<"${SECTION_JSON}")"
elif [ "$DISTRO" = "zulu" ]; then
  # Zulu: name pattern keeps plain CA JDK tarballs (CRaC / fx / JRE excluded)
  [ -n "$ZULU_ARCH" ] || die "${L_ZULU_ERR}"
  if [ "$MUSL" -eq 1 ]; then
    ZULU_RE="^zulu[0-9.]+-ca-jdk[0-9.]+-linux_musl_${ZULU_NAME_ARCH}\.tar\.gz$"
  else
    ZULU_RE="^zulu[0-9.]+-ca-jdk[0-9.]+-linux_${ZULU_NAME_ARCH}\.tar\.gz$"
  fi

  # fetch to a file first: jq exits after a complete JSON value and would
  # SIGPIPE-truncate curl's output mid-stream otherwise
  zulu_fetch() { # $1: output file   $2: extra params (may be empty)   $3: page size
    curl -fsSL --retry 2 --connect-timeout 15 -o "$1" \
      "${ZULU_API}?os=linux&arch=${ZULU_ARCH}&package_type=jdk&archive_type=tar.gz&release_status=ga&availability_types=ca${2}&page=1&page_size=${3}"
  }

  echo -e "${BLUE}${L_QUERY_VERSIONS}${NC}"
  # one broad "latest" query covers recent majors; older ones need probing
  mapfile -t ZULU_MAJORS < <(
    if zulu_fetch "${WORK_DIR}/zulu.json" "" 100 2>/dev/null; then
      jq -r --arg re "$ZULU_RE" \
        '[.[] | select(.latest == true) | select(.name | test($re)) | .java_version[0]] | unique | .[]' \
        "${WORK_DIR}/zulu.json" 2>/dev/null || true
    fi
    for m in 7 8 11; do
      if zulu_fetch "${WORK_DIR}/zulu-probe.json" "&java_version=${m}" 5 2>/dev/null; then
        jq -e --arg re "$ZULU_RE" '[.[] | select(.name | test($re))] | length > 0' \
          "${WORK_DIR}/zulu-probe.json" > /dev/null 2>&1 && echo "$m" || true
      fi
    done
  )
  [ ${#ZULU_MAJORS[@]} -ne 0 ] || die "${L_ZULU_ERR}"
  mapfile -t ZULU_MAJORS < <(printf '%s\n' "${ZULU_MAJORS[@]}" | sort -rn | uniq)

  for i in "${!ZULU_MAJORS[@]}"; do
    echo "  $((i + 1))) JDK ${ZULU_MAJORS[$i]}$(java_lts_tag "${ZULU_MAJORS[$i]}")"
  done
  CHOICE="$(read_choice "version [1-${#ZULU_MAJORS[@]}]: " "" "${#ZULU_MAJORS[@]}")"
  MAJOR="${ZULU_MAJORS[$((CHOICE - 1))]}"

  zulu_fetch "${WORK_DIR}/zulu.json" "&java_version=${MAJOR}" 100 || die "${L_ZULU_ERR}"
  ZULU_PKG="$(jq -c --arg re "$ZULU_RE" '
    [ .[] | select(.latest == true) | select(.name | test($re)) ]
    | sort_by(.distro_version) | last | select(. != null)' "${WORK_DIR}/zulu.json")"
  [ -n "$ZULU_PKG" ] || die "${L_ZULU_ERR}"
  VERSION="$(jq -r '.distro_version | map(tostring) | join(".")' <<<"$ZULU_PKG") / Java $(jq -r '.java_version | map(tostring) | join(".")' <<<"$ZULU_PKG")"
  DOWNLOAD_URL="$(jq -r '.download_url' <<<"$ZULU_PKG")"
  CHECKSUM_ALGO="md5"
  CHECKSUM_EXPECTED="$(curl -fsSL --retry 2 --connect-timeout 15 \
    "https://api.azul.com/metadata/v1/zulu/packages/$(jq -r '.package_uuid' <<<"$ZULU_PKG")" 2>/dev/null \
    | jq -r '.md5_hash // empty' || true)"
elif [ "$DISTRO" = "temurin" ]; then
  # Adoptium v3: one call lists majors, per-major "latest" gives the asset;
  # musl systems use the alpine-linux platform
  [ "$ARCH_LABEL" = "x64" ] || [ "$ARCH_LABEL" = "aarch64" ] || [ "$ARCH_LABEL" = "riscv64" ] \
    || die "${L_NO_VERSION}"
  TEM_OS="linux"
  [ "$MUSL" -eq 1 ] && [ "$ARCH_LABEL" = "x64" ] && TEM_OS="alpine-linux" || true

  TEM_IDX="$(curl -fsSL --retry 2 --connect-timeout 15 \
    'https://api.adoptium.net/v3/info/available_releases')" || die "${L_ERR_FETCH} api.adoptium.net"
  mapfile -t TEM_MAJORS < <(jq -r '.available_releases | reverse | .[]' <<<"${TEM_IDX}")
  [ ${#TEM_MAJORS[@]} -ne 0 ] || die "${L_NO_VERSION}"

  for i in "${!TEM_MAJORS[@]}"; do
    echo "  $((i + 1))) JDK ${TEM_MAJORS[$i]}$(java_lts_tag "${TEM_MAJORS[$i]}")"
  done
  CHOICE="$(read_choice "version [1-${#TEM_MAJORS[@]}]: " "" "${#TEM_MAJORS[@]}")"
  MAJOR="${TEM_MAJORS[$((CHOICE - 1))]}"

  TEM_ASSET="$(curl -fsSL --retry 2 --connect-timeout 15 \
    "https://api.adoptium.net/v3/assets/latest/${MAJOR}/hotspot?os=${TEM_OS}&architecture=${ARCH_LABEL}&image_type=jdk")" \
    || die "${L_NO_VERSION}"
  VERSION="$(jq -r '.[0].release_name // empty' <<<"${TEM_ASSET}")"
  DOWNLOAD_URL="$(jq -r '.[0].binary.package.link // empty' <<<"${TEM_ASSET}")"
  [ -n "$VERSION" ] && [ -n "$DOWNLOAD_URL" ] || die "${L_NO_VERSION}"
  CHECKSUM_ALGO="sha256"
  CHECKSUM_EXPECTED="$(jq -r '.[0].binary.package.checksum // empty' <<<"${TEM_ASSET}")"
elif [ "$DISTRO" = "corretto" ]; then
  # fixed "latest" URL pattern; majors are Corretto's LTS lines; the real
  # version comes from the redirect Location header
  [ "$ARCH_LABEL" = "x64" ] || [ "$ARCH_LABEL" = "aarch64" ] || die "${L_NO_VERSION}"
  C_ARCH="x64"
  [ "$ARCH_LABEL" = "aarch64" ] && C_ARCH="aarch64" || true
  CORRETO_MAJORS=(21 17 11 8)

  for i in "${!CORRETO_MAJORS[@]}"; do
    echo "  $((i + 1))) JDK ${CORRETO_MAJORS[$i]}$(java_lts_tag "${CORRETO_MAJORS[$i]}")"
  done
  CHOICE="$(read_choice "version [1-${#CORRETO_MAJORS[@]}]: " "" "${#CORRETO_MAJORS[@]}")"
  MAJOR="${CORRETO_MAJORS[$((CHOICE - 1))]}"

  DOWNLOAD_URL="https://corretto.aws/downloads/latest/amazon-corretto-${MAJOR}-${C_ARCH}-linux-jdk.tar.gz"
  VERSION="$(curl -fsSI --retry 2 --connect-timeout 15 "${DOWNLOAD_URL}" \
    | awk 'tolower($1) == "location:" { print $2 }' | head -1 \
    | sed -E 's|.*/resources/([^/]+)/.*|\1|' || true)"
  [[ "$VERSION" =~ ^[0-9][0-9.]*$ ]] || die "${L_NO_VERSION}"
elif [ "$DISTRO" = "liberica" ]; then
  # api.bell-sw.com: arch=x86|arm + bitness=64; musl is its own os value;
  # newest = numeric version sort (string order would rank 21.0.7 > 21.0.12)
  [ "$ARCH_LABEL" = "x64" ] || [ "$ARCH_LABEL" = "aarch64" ] || die "${L_NO_VERSION}"
  LIB_ARCH="x86"
  [ "$ARCH_LABEL" = "aarch64" ] && LIB_ARCH="arm" || true
  LIB_OS="linux"
  [ "$MUSL" -eq 1 ] && LIB_OS="linux-musl" || true

  echo -e "${BLUE}${L_QUERY_VERSIONS}${NC}"
  LIB_BASE="https://api.bell-sw.com/v1/liberica/releases?os=${LIB_OS}&arch=${LIB_ARCH}&bitness=64&bundle-type=jdk"
  LIB_LIST="$(curl -fsSL --retry 2 --connect-timeout 15 "${LIB_BASE}")" || die "${L_ERR_FETCH} api.bell-sw.com"

  mapfile -t LIB_MAJORS < <(jq -r '[.[].featureVersion] | unique | reverse | .[]' <<<"${LIB_LIST}")
  [ ${#LIB_MAJORS[@]} -ne 0 ] || die "${L_NO_VERSION}"

  for i in "${!LIB_MAJORS[@]}"; do
    echo "  $((i + 1))) JDK ${LIB_MAJORS[$i]}$(java_lts_tag "${LIB_MAJORS[$i]}")"
  done
  CHOICE="$(read_choice "version [1-${#LIB_MAJORS[@]}]: " "" "${#LIB_MAJORS[@]}")"
  MAJOR="${LIB_MAJORS[$((CHOICE - 1))]}"

  LIB_PKG="$(curl -fsSL --retry 2 --connect-timeout 15 "${LIB_BASE}&version-feature=${MAJOR}")" \
    || die "${L_NO_VERSION}"
  LIB_ROW="$(jq -c '[
      .[] | select(.filename | endswith(".tar.gz"))
      | . as $r | $r + { sortkey: (.version | [scan("[0-9]+") | tonumber]) }
    ] | sort_by(.sortkey) | last // empty' <<<"${LIB_PKG}")"
  [ -n "$LIB_ROW" ] && [ "$LIB_ROW" != "null" ] || die "${L_NO_VERSION}"
  VERSION="$(jq -r '.version' <<<"${LIB_ROW}")"
  DOWNLOAD_URL="$(jq -r '.downloadUrl' <<<"${LIB_ROW}")"
  CHECKSUM_ALGO="sha1"
  CHECKSUM_EXPECTED="$(jq -r '.sha1 // empty' <<<"${LIB_ROW}")"
elif [ "$DISTRO" = "kona" ]; then
  # GitHub releases/latest per major repo; asset names like
  # TencentKona-21.0.12.b1-jdk_linux-x86_64.tar.gz
  [ "$ARCH_LABEL" = "x64" ] || [ "$ARCH_LABEL" = "aarch64" ] || die "${L_NO_VERSION}"
  K_ARCH="x86_64"
  [ "$ARCH_LABEL" = "aarch64" ] && K_ARCH="aarch64" || true
  echo -e "${BLUE}${L_QUERY_VERSIONS}${NC}"
  K_RE="^TencentKona-.*-jdk_linux-${K_ARCH}\.tar\.gz$"

  KONA_ROWS=()
  for m in 25 21 17 11 8; do
    K_JSON="$(curl -fsSL --retry 1 --connect-timeout 15 \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/Tencent/TencentKona-${m}/releases/latest" 2>/dev/null)" || continue
    K_ASSET="$(jq -r --arg re "$K_RE" \
      '[.assets[] | select(.name | test($re))][0] // empty' <<<"${K_JSON}")"
    [ -n "$K_ASSET" ] || continue
    KONA_ROWS+=("${m}"$'\t'"$(jq -r '.tag_name' <<<"${K_JSON}")"$'\t'"$(jq -r '.browser_download_url' <<<"${K_ASSET}")")
  done
  [ ${#KONA_ROWS[@]} -ne 0 ] || die "${L_NO_VERSION}"

  for i in "${!KONA_ROWS[@]}"; do
    K_ROW="${KONA_ROWS[$i]}"
    echo "  $((i + 1))) JDK $(cut -f1 <<<"$K_ROW")$(java_lts_tag "$(cut -f1 <<<"$K_ROW")")  ($(cut -f2 <<<"$K_ROW"))"
  done
  CHOICE="$(read_choice "version [1-${#KONA_ROWS[@]}]: " "" "${#KONA_ROWS[@]}")"
  K_ROW="${KONA_ROWS[$((CHOICE - 1))]}"
  MAJOR="$(cut -f1 <<<"$K_ROW")"
  VERSION="$(cut -f2 <<<"$K_ROW")"
  DOWNLOAD_URL="$(cut -f3 <<<"$K_ROW")"
  CHECKSUM_ALGO="sha256"
  CHECKSUM_EXPECTED="$(jq -r '.digest // empty' <<<"${K_ASSET}" | sed -E 's/^sha256://')"
else
  # BiSheng: HuaweiCloud mirror has a plain autoindex listing; parse it and
  # take the newest file per major (8u492 -> sort key 8.492 for sort -V)
  [ "$ARCH_LABEL" = "x64" ] || [ "$ARCH_LABEL" = "aarch64" ] || die "${L_NO_VERSION}"
  B_ARCH="x64"
  [ "$ARCH_LABEL" = "aarch64" ] && B_ARCH="aarch64" || true
  echo -e "${BLUE}${L_QUERY_VERSIONS}${NC}"
  B_LISTING="$(curl -fsSL --retry 2 --connect-timeout 15 \
    'https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/')" \
    || die "${L_ERR_FETCH} mirrors.huaweicloud.com"

  mapfile -t BISHENG_MAJORS < <(printf '%s\n' "${B_LISTING}" \
    | grep -oE 'bisheng-jdk-[0-9]+(u[0-9]+)?(\.[0-9]+)*-b[0-9]+' \
    | sed -E 's/^bisheng-jdk-//; s/-b[0-9]+$//; s/u/./' \
    | cut -d. -f1 | sort -nru || true)
  [ ${#BISHENG_MAJORS[@]} -ne 0 ] || die "${L_NO_VERSION}"

  for i in "${!BISHENG_MAJORS[@]}"; do
    echo "  $((i + 1))) JDK ${BISHENG_MAJORS[$i]}$(java_lts_tag "${BISHENG_MAJORS[$i]}")"
  done
  CHOICE="$(read_choice "version [1-${#BISHENG_MAJORS[@]}]: " "" "${#BISHENG_MAJORS[@]}")"
  MAJOR="${BISHENG_MAJORS[$((CHOICE - 1))]}"

  B_FILE="$(printf '%s\n' "${B_LISTING}" \
    | grep -oE "bisheng-jdk-${MAJOR}[0-9u.]*-b[0-9]+-linux-${B_ARCH}\.tar\.gz" \
    | sort -u \
    | awk '{ v = $0
             sub(/^bisheng-jdk-/, "", v)
             sub(/-linux-.*$/, "", v)
             key = v; sub(/u/, ".", key)
             print key "\t" $0 }' \
    | sort -k1,1V | tail -1 | cut -f2 || true)"
  [ -n "$B_FILE" ] || die "${L_NO_VERSION}"
  VERSION="$(printf '%s' "${B_FILE}" | sed -E 's/^bisheng-jdk-//; s/-linux-.*$//')"
  DOWNLOAD_URL="https://mirrors.huaweicloud.com/kunpeng/archive/compiler/bisheng_jdk/${B_FILE}"
  CHECKSUM_ALGO="sha256"
  CHECKSUM_EXPECTED="$(curl -fsSL --retry 2 --connect-timeout 15 \
    "${DOWNLOAD_URL}.sha256" 2>/dev/null | awk '{print $1}' || true)"
fi

ASSET_NAME="${DOWNLOAD_URL##*/}"
echo "  -> ${DISTRO_LABEL} ${VERSION} (${TYPE:-JDK ${MAJOR}})  ${ASSET_NAME}"

# --- [4/8] update check against the install registry --------------------------
echo -e "${BLUE}${L_UPDATE_CHECK}${NC}"
DB_LINE=""
OLD_VERSION=""
OLD_HOME=""
if [ -f "$DB_FILE" ]; then
  DB_LINE="$(awk -F'\t' -v d="$DISTRO" -v m="$MAJOR" '$1 == d && $2 == m {print; exit}' "$DB_FILE" 2>/dev/null || true)"
  if [ -n "$DB_LINE" ]; then
    OLD_VERSION="$(awk -F'\t' '{print $3}' <<<"$DB_LINE")"
    OLD_HOME="$(awk -F'\t' '{print $4}' <<<"$DB_LINE")"
    echo -e "${BLUE}${L_INSTALLED_FOUND} ${DISTRO_LABEL} JDK ${MAJOR} = ${OLD_VERSION} (${OLD_HOME})${NC}"
    if [ "$OLD_VERSION" = "$VERSION" ]; then
      printf "${YELLOW}${L_ALREADY_LATEST}${NC}\n" "$VERSION"
      ask_yes_no "$(echo -e "${RED}${L_ASK_FORCE}${NC}")" "n" || { echo -e "${RED}${L_ABORT_USER}${NC}"; exit 0; }
    else
      printf "${BLUE}$(printf "${L_UPDATING}" "${DISTRO_LABEL} JDK ${MAJOR}" "${OLD_VERSION}" "${VERSION}")${NC}\n"
    fi
  fi
fi

# --- [5/8] download -----------------------------------------------------------
echo -e "${BLUE}${L_DOWNLOAD}${NC}  ${ASSET_NAME}"
ARCHIVE="${WORK_DIR}/jdk.tar.gz"
download_file "${ARCHIVE}" "${DOWNLOAD_URL}" \
  || die "${L_ERR_DOWNLOAD} ${DOWNLOAD_URL}"

# --- integrity check ----------------------------------------------------------
# expected hash comes from the trusted origin (API/sidecar), the archive may
# come from a mirror -- a mismatch here means corruption or tampering
if [ -n "${CHECKSUM_EXPECTED}" ]; then
  echo -e "${BLUE}${L_CHECKSUM_VERIFY}${NC}"
  EXPECTED_NORM="$(printf '%s' "${CHECKSUM_EXPECTED}" | tr -d ' -' | tr '[:upper:]' '[:lower:]')"
  if [[ "${EXPECTED_NORM}" =~ ^[0-9a-f]{32,64}$ ]]; then
    case "${CHECKSUM_ALGO}" in
      sha256) ACTUAL_HASH="$(sha256sum "${ARCHIVE}" | awk '{print $1}')" ;;
      sha1)   ACTUAL_HASH="$(sha1sum "${ARCHIVE}" | awk '{print $1}')" ;;
      md5)    ACTUAL_HASH="$(md5sum "${ARCHIVE}" | awk '{print $1}')" ;;
      *)      ACTUAL_HASH="" ;;
    esac
    if [ "${ACTUAL_HASH}" != "${EXPECTED_NORM}" ]; then
      die "$(printf "${L_ERR_CHECKSUM}" "${CHECKSUM_ALGO}" "${EXPECTED_NORM}" "${ACTUAL_HASH:-none}")"
    fi
  else
    echo -e "${YELLOW}$(printf "${L_WARN_NO_CHECKSUM}" "${DISTRO_LABEL}")${NC}"
  fi
else
  echo -e "${YELLOW}$(printf "${L_WARN_NO_CHECKSUM}" "${DISTRO_LABEL}")${NC}"
fi

# --- [6/8] extract + registry -------------------------------------------------
echo -e "${BLUE}${L_INSTALL} ${INSTALL_DIR}${NC}"
# sed (not `head`) reads the whole listing: avoids SIGPIPE tripping pipefail
TOP_DIR="$(tar -ztf "${ARCHIVE}" | sed -n '1{s,/.*,,;p}')"
[ -n "$TOP_DIR" ] && [ "$TOP_DIR" != "." ] || die "${L_ERR_TOPDIR}"

dir_op mkdir -p "${INSTALL_DIR}"
# replace only the exact target dir; other installed versions are kept
dir_op rm -rf "${INSTALL_DIR}/${TOP_DIR}"
dir_op tar -xzf "${ARCHIVE}" -C "${INSTALL_DIR}"

# Zulu / Corretto / Liberica tarballs extract to dirs ending in e.g.
# -linux_x64 / -linux-x64 / -linux-amd64: offer to drop the platform suffix
if [[ "$TOP_DIR" == *-linux* ]]; then
  NEW_TOP_DIR="${TOP_DIR%%-linux*}"
  if ask_yes_no "$(printf "${L_ASK_RENAME}" "${NEW_TOP_DIR}")" "y"; then
    dir_op rm -rf "${INSTALL_DIR}/${NEW_TOP_DIR}"
    dir_op mv "${INSTALL_DIR}/${TOP_DIR}" "${INSTALL_DIR}/${NEW_TOP_DIR}"
    TOP_DIR="${NEW_TOP_DIR}"
  fi
fi
JAVA_HOME_DIR="${INSTALL_DIR}/${TOP_DIR}"

# stable per-major symlink (e.g. /opt/java/jdk17): when accepted, env config
# points JAVA_HOME at it, so later updates keep the same JAVA_HOME
JAVA_HOME_ENV="$JAVA_HOME_DIR"
LINK_PATH="${INSTALL_DIR}/jdk${MAJOR}"
if ask_yes_no "$(printf "${L_ASK_SYMLINK}" "$LINK_PATH" "$JAVA_HOME_DIR")" "y"; then
  if [ -e "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
    echo -e "${YELLOW}$(printf "${L_SYMLINK_SKIP}" "$LINK_PATH")${NC}"
  else
    dir_op ln -sfn "$JAVA_HOME_DIR" "$LINK_PATH"
    JAVA_HOME_ENV="$LINK_PATH"
  fi
fi

EXTRA="-"
[ "$DISTRO" = "dragonwell" ] && EXTRA="${SRC}/${TYPE}"
DB_TMP="${WORK_DIR}/db.tmp"
{ [ ! -f "$DB_FILE" ] || awk -F'\t' -v k="${DISTRO}|${MAJOR}" '($1 "|" $2) != k' "$DB_FILE"; } > "$DB_TMP"
printf '%s\t%s\t%s\t%s\t%s\n' "$DISTRO" "$MAJOR" "$VERSION" "$JAVA_HOME_DIR" "$EXTRA" >> "$DB_TMP"
dir_op tee "$DB_FILE" < "$DB_TMP" > /dev/null

# offer to drop the superseded directory (guard: only inside INSTALL_DIR)
if [ -n "$OLD_HOME" ] && [ "$OLD_VERSION" != "$VERSION" ] \
  && [ -d "$OLD_HOME" ] && [ "$OLD_HOME" != "$JAVA_HOME_DIR" ] \
  && [[ "$OLD_HOME" == "$INSTALL_DIR"/* ]]; then
  if ask_yes_no "$(echo -e "${YELLOW}${L_ASK_REMOVE_OLD}${NC}")" "n"; then
    dir_op rm -rf "${OLD_HOME}"
    echo -e "${GREEN}${L_OLD_REMOVED} ${OLD_HOME}${NC}"
  else
    echo -e "${BLUE}${L_OLD_KEPT} ${OLD_HOME}${NC}"
  fi
fi

# --- [7/8] environment --------------------------------------------------------
# migrate config lines the 2022 version of this script appended to /etc/profile:
# they sit at the bottom of the file and would shadow profile.d / rc files
migrate_legacy_profile() {
  [ -f "$ETC_PROFILE" ] || return 0
  as_root grep -q '^export JAVA_HOME=/opt/java/' "$ETC_PROFILE" 2>/dev/null || return 0
  BACKUP="${ETC_PROFILE}.bak-java-dragonwell"
  as_root cp "$ETC_PROFILE" "$BACKUP"
  echo -e "${YELLOW}${L_MIGRATE_BACKUP} ${BACKUP}${NC}"
  as_root sed -i \
    -e '/^export JAVA_HOME=\/opt\/java\//d' \
    -e '/^export PATH=\$JAVA_HOME\/bin:\$PATH$/d' \
    "$ETC_PROFILE"
}

ENV_FILE=""
case "$ENV_MODE" in
  1) # skip, but warn if the old script's config would dangle
    [ -f "$ETC_PROFILE" ] \
      && as_root grep -q '^export JAVA_HOME=/opt/java/' "$ETC_PROFILE" 2>/dev/null \
      && echo -e "${YELLOW}$(printf "${L_LEGACY_SKIP}" "$ETC_PROFILE")${NC}" \
      || true
    ;;
  2) # system-wide
    echo -e "${BLUE}${L_ENV_WRITE} ${PROFILE_D}${NC}"
    migrate_legacy_profile
    as_root mkdir -p "$(dirname "$PROFILE_D")"
    printf 'export JAVA_HOME=%s\nexport PATH=$JAVA_HOME/bin:$PATH\n' "${JAVA_HOME_ENV}" \
      | as_root tee "$PROFILE_D" > /dev/null
    ENV_FILE="$PROFILE_D"
    ;;
  3) # current user, marker block so reruns replace instead of duplicate
    echo -e "${BLUE}${L_ENV_WRITE} ${RC_FILE}${NC}"
    migrate_legacy_profile
    sed -i '/^# >>> dragonwell jdk >>>$/,/^# <<< dragonwell jdk <<<$/d' "$RC_FILE" 2>/dev/null || true
    {
      echo '# >>> dragonwell jdk >>>'
      printf 'export JAVA_HOME=%s\n' "${JAVA_HOME_ENV}"
      echo 'export PATH=$JAVA_HOME/bin:$PATH'
      echo '# <<< dragonwell jdk <<<'
    } >> "$RC_FILE"
    ENV_FILE="$RC_FILE"
    ;;
esac

# --- [8/8] verify -------------------------------------------------------------
echo -e "${GREEN}${L_VERIFY}${NC}"
"${JAVA_HOME_ENV}/bin/java" -version

printf "${GREEN}${L_DONE}${NC}\n"
if [ -n "$ENV_FILE" ]; then
  printf "${L_RELOGIN_HINT}\n" "$ENV_FILE"
else
  echo -e "${BLUE}${L_MANUAL_ENV}${NC}"
  echo "export JAVA_HOME=${JAVA_HOME_ENV}"
  echo 'export PATH=$JAVA_HOME/bin:$PATH'
fi
