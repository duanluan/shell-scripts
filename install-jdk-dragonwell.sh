#!/bin/bash

# ==============================================================================
# Alibaba Dragonwell JDK Installer
#
# Source of truth: https://dragonwell-jdk.io/releases.json
# Structure (changed since 2022, the reason the old script broke):
#   { "oss":    { "extended": {...}, "standard": {...} },
#     "github": { "extended": {...}, "standard": {...} } }
# Per release line (e.g. 21): version21, xurl21 (x64 glibc),
# aurl21 (aarch64), apurl21 (x64 Alpine musl), rurl21 (riscv64), wurl21 (win).
#
# Flow: check deps (auto-install via detected package manager) -> configure
# (install dir + env-var scope) -> pick download source / type / version ->
# auto-pick asset for the detected arch (musl builds preferred on Alpine) ->
# download & extract -> configure JAVA_HOME (system-wide / current user /
# skip; also cleans up lines the 2022 version of this script appended to
# /etc/profile, with a backup first).
#
# Overridable for testing: INSTALL_DIR (prompt default), PROFILE_D, RC_FILE,
# ETC_PROFILE, SUDO ("" disables privilege escalation entirely).
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
L_ENV_OPT1="  1) System-wide (all users): %s"
L_ENV_OPT2="  2) Current user only: %s"
L_ENV_OPT3="  3) Skip (configure it myself later)"
L_ERR_NO_ROOT="Error: root privileges required for this step. Run as root or install sudo:"
L_FETCH_JSON=">>> [2/8] Fetching Dragonwell release index..."
L_ERR_FETCH="Error: failed to fetch the release index:"
L_SELECT_SOURCE=">>> [3/8] Select download source"
L_SELECT_TYPE=">>> [4/8] Select distribution type"
L_SELECT_VERSION=">>> [5/8] Select version"
L_ARCH_DETECT="Detected architecture:"
L_MUSL_NOTICE="musl (Alpine) detected: musl build preferred when available."
L_NO_VERSION="Error: no release for this source/type/arch."
L_INVALID_INPUT="Invalid choice, try again."
L_DOWNLOAD=">>> [6/8] Downloading..."
L_ERR_DOWNLOAD="Error: download failed:"
L_INSTALL=">>> [7/8] Extracting to"
L_ERR_TOPDIR="Error: unexpected archive layout (no top-level directory)."
L_ENV_WRITE=">>> [8/8] Writing environment:"
L_MIGRATE_BACKUP="Legacy JAVA_HOME lines found in profile, backing up to"
L_LEGACY_SKIP="Legacy JAVA_HOME lines (from the old script) left in %s: they may point to a removed directory."
L_VERIFY="Installed. Verify:"
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
  L_ENV_OPT1="  1) 全局（所有用户）：%s"
  L_ENV_OPT2="  2) 仅当前用户：%s"
  L_ENV_OPT3="  3) 跳过（之后自行配置）"
  L_ERR_NO_ROOT="错误：此步骤需要 root 权限，请以 root 运行或安装 sudo："
  L_FETCH_JSON=">>> [2/8] 获取 Dragonwell 版本索引..."
  L_ERR_FETCH="错误：获取版本索引失败："
  L_SELECT_SOURCE=">>> [3/8] 选择下载源"
  L_SELECT_TYPE=">>> [4/8] 选择发行类型"
  L_SELECT_VERSION=">>> [5/8] 选择版本"
  L_ARCH_DETECT="检测到架构："
  L_MUSL_NOTICE="检测到 musl（Alpine）：优先使用 musl 构建。"
  L_NO_VERSION="错误：该下载源/类型/架构下没有可用版本。"
  L_INVALID_INPUT="输入无效，请重试。"
  L_DOWNLOAD=">>> [6/8] 下载中..."
  L_ERR_DOWNLOAD="错误：下载失败："
  L_INSTALL=">>> [7/8] 解压到"
  L_ERR_TOPDIR="错误：压缩包结构异常（未找到顶层目录）。"
  L_ENV_WRITE=">>> [8/8] 写入环境变量："
  L_MIGRATE_BACKUP="检测到旧版脚本写入 /etc/profile 的 JAVA_HOME 配置，已备份到"
  L_LEGACY_SKIP="%s 中仍留有旧版脚本写入的 JAVA_HOME 配置，可能指向已删除的目录。"
  L_VERIFY="安装完成，验证："
  L_DONE="完成。"
  L_RELOGIN_HINT="执行 'source %s' 或重新登录后，'java -version' 即为新 JDK。"
  L_MANUAL_ENV="如需手动配置环境变量，可在 shell 配置文件中加入以下两行："
fi

RELEASES_URL="https://dragonwell-jdk.io/releases.json"
INSTALL_DIR_DEFAULT="${INSTALL_DIR:-/opt/java}"
PROFILE_D="${PROFILE_D:-/etc/profile.d/java.sh}"
ETC_PROFILE="${ETC_PROFILE:-/etc/profile}"
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

# --- [0/8] dependencies -------------------------------------------------------
echo -e "${BLUE}${L_CHECK_DEPS}${NC}"

MISSING=()
command -v curl > /dev/null 2>&1 || MISSING+=("curl")
command -v jq > /dev/null 2>&1 || MISSING+=("jq")

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
    echo "  Debian/Ubuntu:  sudo apt-get install curl jq"
    echo "  Fedora/RHEL:    sudo dnf install curl jq"
    echo "  openSUSE:       sudo zypper install curl jq"
    echo "  Arch:           sudo pacman -S curl jq"
    echo "  Alpine:         sudo apk add curl jq"
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

# default env scope: user-level when installing into the home directory
DEFAULT_ENV=1
[[ "$INSTALL_DIR" == "$HOME"/* ]] && DEFAULT_ENV=2 || true

echo -e "${BLUE}${L_ASK_ENV}${NC}"
printf "${L_ENV_OPT1}\n" "$PROFILE_D"
printf "${L_ENV_OPT2}\n" "$RC_FILE"
echo "${L_ENV_OPT3}"
ENV_MODE="$(read_choice "env [1-3], default ${DEFAULT_ENV}: " "$DEFAULT_ENV" 3)"

# --- architecture / libc ------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH_KEY="x";  ARCH_LABEL="x64" ;;
  aarch64|arm64) ARCH_KEY="a"; ARCH_LABEL="aarch64" ;;
  riscv64)       ARCH_KEY="r"; ARCH_LABEL="riscv64" ;;
  *) die "Unsupported architecture: ${ARCH}" ;;
esac

# musl systems (Alpine) get the dedicated musl build when one exists
PREF_KEY="${ARCH_KEY}url"
FALLBACK_KEY="${ARCH_KEY}url"
if [ "$ARCH_KEY" = "x" ] && ldd --version 2>&1 | head -1 | grep -qi musl; then
  PREF_KEY="apurl"
  echo -e "${BLUE}${L_MUSL_NOTICE}${NC}"
fi

# --- [2/8] fetch release index ------------------------------------------------
echo -e "${BLUE}${L_FETCH_JSON}${NC}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
JSON_FILE="${WORK_DIR}/releases.json"

curl -fsSL --retry 3 --connect-timeout 15 -o "${JSON_FILE}" "${RELEASES_URL}" \
  || die "${L_ERR_FETCH} ${RELEASES_URL}"

# --- [3/8] download source ----------------------------------------------------
echo -e "${BLUE}${L_SELECT_SOURCE}${NC}"
echo "  1) Aliyun OSS (fast in China)   2) GitHub Releases"
CHOICE="$(read_choice 'source [1-2], default 1: ' 1 2)"
case "$CHOICE" in
  1) SRC="oss" ;;
  2) SRC="github" ;;
esac

# --- [4/8] distribution type --------------------------------------------------
echo -e "${BLUE}${L_SELECT_TYPE}${NC}"
echo "  1) extended (more features)   2) standard (LTS upstream)"
CHOICE="$(read_choice 'type [1-2], default 1: ' 1 2)"
case "$CHOICE" in
  1) TYPE="extended" ;;
  2) TYPE="standard" ;;
esac

echo -e "${BLUE}${L_ARCH_DETECT} ${ARCH_LABEL} (${ARCH})${NC}"

SECTION_JSON="$(jq -c --arg s "$SRC" --arg t "$TYPE" '.[$s][$t] // {}' "${JSON_FILE}")"

# --- [5/8] version ------------------------------------------------------------
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

echo -e "${BLUE}${L_SELECT_VERSION}${NC}"
for i in "${!VERSION_ROWS[@]}"; do
  major="$(cut -f1 <<<"${VERSION_ROWS[$i]}")"
  ver="$(cut -f2 <<<"${VERSION_ROWS[$i]}")"
  echo "  $((i + 1))) JDK ${major}  (Dragonwell ${ver})"
done

CHOICE="$(read_choice "version [1-${#VERSION_ROWS[@]}]: " "" "${#VERSION_ROWS[@]}")"
ROW="${VERSION_ROWS[$((CHOICE - 1))]}"
MAJOR="$(cut -f1 <<<"${ROW}")"
VERSION="$(cut -f2 <<<"${ROW}")"

DOWNLOAD_URL="$(jq -r --arg p "${PREF_KEY}${MAJOR}" --arg f "${FALLBACK_KEY}${MAJOR}" \
  'if (.[$p] // "") != "" then .[$p] else .[$f] end' <<<"${SECTION_JSON}")"
ASSET_NAME="${DOWNLOAD_URL##*/}"
echo "  -> Dragonwell ${VERSION} (${TYPE}, ${SRC})  ${ASSET_NAME}"

# --- [6/8] download -----------------------------------------------------------
echo -e "${BLUE}${L_DOWNLOAD}${NC}  ${ASSET_NAME}"
ARCHIVE="${WORK_DIR}/dragonwell.tar.gz"
curl -fL --progress-bar --retry 3 --connect-timeout 15 -o "${ARCHIVE}" "${DOWNLOAD_URL}" \
  || die "${L_ERR_DOWNLOAD} ${DOWNLOAD_URL}"

# --- [7/8] extract ------------------------------------------------------------
echo -e "${BLUE}${L_INSTALL} ${INSTALL_DIR}${NC}"
# sed (not `head`) reads the whole listing: avoids SIGPIPE tripping pipefail
TOP_DIR="$(tar -ztf "${ARCHIVE}" | sed -n '1{s,/.*,,;p}')"
[ -n "$TOP_DIR" ] && [ "$TOP_DIR" != "." ] || die "${L_ERR_TOPDIR}"

dir_op mkdir -p "${INSTALL_DIR}"
# replace only the exact target dir; other installed versions are kept
dir_op rm -rf "${INSTALL_DIR}/${TOP_DIR}"
dir_op tar -xzf "${ARCHIVE}" -C "${INSTALL_DIR}"
JAVA_HOME_DIR="${INSTALL_DIR}/${TOP_DIR}"

# --- [8/8] environment --------------------------------------------------------
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
  1) # system-wide
    echo -e "${BLUE}${L_ENV_WRITE} ${PROFILE_D}${NC}"
    migrate_legacy_profile
    as_root mkdir -p "$(dirname "$PROFILE_D")"
    printf 'export JAVA_HOME=%s\nexport PATH=$JAVA_HOME/bin:$PATH\n' "${JAVA_HOME_DIR}" \
      | as_root tee "$PROFILE_D" > /dev/null
    ENV_FILE="$PROFILE_D"
    ;;
  2) # current user, marker block so reruns replace instead of duplicate
    echo -e "${BLUE}${L_ENV_WRITE} ${RC_FILE}${NC}"
    migrate_legacy_profile
    sed -i '/^# >>> dragonwell jdk >>>$/,/^# <<< dragonwell jdk <<<$/d' "$RC_FILE" 2>/dev/null || true
    {
      echo '# >>> dragonwell jdk >>>'
      printf 'export JAVA_HOME=%s\n' "${JAVA_HOME_DIR}"
      echo 'export PATH=$JAVA_HOME/bin:$PATH'
      echo '# <<< dragonwell jdk <<<'
    } >> "$RC_FILE"
    ENV_FILE="$RC_FILE"
    ;;
  3) # skip, but warn if the old script's config would dangle
    [ -f "$ETC_PROFILE" ] \
      && as_root grep -q '^export JAVA_HOME=/opt/java/' "$ETC_PROFILE" 2>/dev/null \
      && echo -e "${YELLOW}$(printf "${L_LEGACY_SKIP}" "$ETC_PROFILE")${NC}" \
      || true
    ;;
esac

echo -e "${GREEN}${L_VERIFY}${NC}"
"${JAVA_HOME_DIR}/bin/java" -version

printf "${GREEN}${L_DONE}${NC}\n"
if [ -n "$ENV_FILE" ]; then
  printf "${L_RELOGIN_HINT}\n" "$ENV_FILE"
else
  echo -e "${BLUE}${L_MANUAL_ENV}${NC}"
  echo "export JAVA_HOME=${JAVA_HOME_DIR}"
  echo 'export PATH=$JAVA_HOME/bin:$PATH'
fi
