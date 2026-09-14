#!/bin/bash

# ==============================================================================
# Multi-distribution JDK Installer (Azul Zulu / Alibaba Dragonwell)
#
# Logic:
# 1. Check deps -> auto-install via detected package manager
#    (apt-get / dnf / yum / zypper / pacman / apk).
# 2. Configure install dir + JAVA_HOME scope (system / current user / skip).
#    User-writable dirs install without root.
# 3. Select distribution & version. Arch is auto-detected (x64 / aarch64 /
#    riscv64, musl builds preferred on Alpine). Version menus are newest
#    major first and driven by live data:
#      - Zulu: Azul metadata API (api.azul.com). Majors come from one broad
#        "latest" query plus legacy probes (7/8/11), then the newest CA GA
#        JDK tarball is picked by name pattern (CRaC / fx / JRE excluded).
#      - Dragonwell: https://dragonwell-jdk.io/releases.json
#        ({ oss|github -> extended|standard -> versionNN / xurl / aurl / ... });
#        lines with version "0" are unpublished and skipped.
# 4. Update check against ${INSTALL_DIR}/.install-jdk.db: already latest ->
#    ask to skip/reinstall; older install found -> update, optionally remove
#    the old directory afterwards.
# 5. Download -> extract into INSTALL_DIR (only the exact target dir is
#    replaced; other versions coexist; Zulu dirs are offered a rename that
#    drops the '-linux_*' suffix, default yes) -> optional stable symlink
#    jdk<major> that keeps JAVA_HOME valid across updates -> configure env.
#    Also cleans up the lines the 2022 version of this script appended to
#    /etc/profile, with a backup first.
#
# Overridable for testing: INSTALL_DIR (prompt default), PROFILE_D, RC_FILE,
# ETC_PROFILE, DB_FILE, SUDO ("" disables privilege escalation entirely).
# ==============================================================================

set -euo pipefail

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
L_DISTRO_OPT2="  2) Alibaba Dragonwell (Alibaba OpenJDK, Aliyun OSS mirror)"
L_ARCH_DETECT="Detected architecture:"
L_MUSL_NOTICE="musl (Alpine) detected: musl build preferred when available."
L_SELECT_VERSION=">>> [3/8] Select version"
L_SELECT_SOURCE="Select download source"
L_SELECT_TYPE="Select distribution type"
L_ZULU_QUERY="Querying Azul Zulu releases (takes a few seconds)..."
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
  L_DISTRO_OPT2="  2) Alibaba Dragonwell（阿里 OpenJDK，阿里云 OSS 源）"
  L_ARCH_DETECT="检测到架构："
  L_MUSL_NOTICE="检测到 musl（Alpine）：优先使用 musl 构建。"
  L_SELECT_VERSION=">>> [3/8] 选择版本"
  L_SELECT_SOURCE="选择下载源"
  L_SELECT_TYPE="选择发行类型"
  L_ZULU_QUERY="查询 Azul Zulu 可用版本（需几秒钟）..."
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
CHOICE="$(read_choice 'distribution [1-2], default 1: ' 1 2)"
case "$CHOICE" in
  1) DISTRO="zulu";       DISTRO_LABEL="Zulu" ;;
  2) DISTRO="dragonwell"; DISTRO_LABEL="Dragonwell" ;;
esac

# --- [3/8] version ------------------------------------------------------------
echo -e "${BLUE}${L_SELECT_VERSION}${NC}"
MAJOR=""
VERSION=""
DOWNLOAD_URL=""

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
else
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

  echo -e "${BLUE}${L_ZULU_QUERY}${NC}"
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
curl -fL --progress-bar --retry 3 --connect-timeout 15 -o "${ARCHIVE}" "${DOWNLOAD_URL}" \
  || die "${L_ERR_DOWNLOAD} ${DOWNLOAD_URL}"

# --- [6/8] extract + registry -------------------------------------------------
echo -e "${BLUE}${L_INSTALL} ${INSTALL_DIR}${NC}"
# sed (not `head`) reads the whole listing: avoids SIGPIPE tripping pipefail
TOP_DIR="$(tar -ztf "${ARCHIVE}" | sed -n '1{s,/.*,,;p}')"
[ -n "$TOP_DIR" ] && [ "$TOP_DIR" != "." ] || die "${L_ERR_TOPDIR}"

dir_op mkdir -p "${INSTALL_DIR}"
# replace only the exact target dir; other installed versions are kept
dir_op rm -rf "${INSTALL_DIR}/${TOP_DIR}"
dir_op tar -xzf "${ARCHIVE}" -C "${INSTALL_DIR}"

# Zulu tarballs extract to e.g. zulu21.52.203-ca-jdk21.0.12.1-linux_x64:
# offer to drop the platform suffix for a cleaner JAVA_HOME
if [ "$DISTRO" = "zulu" ] && [[ "$TOP_DIR" == *-linux* ]]; then
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
