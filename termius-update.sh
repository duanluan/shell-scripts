#!/bin/bash

# ==============================================================================
# Termius Arch Package Auto-Updater (Smart Check Version)
#
# Logic:
# 1. Detect Language.
# 2. Check Dependencies -> Clone AUR -> Parse Deb (Target Version).
# 3. [NEW] Check Installed Version -> Prompt if matches.
# 4. Query Snap -> Update PKGBUILD -> Launch Shell.
# ==============================================================================

set -e

# --- 1. Language & Color Setup ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default to English
L_CHECK_DEPS=">>> [0/6] Checking system dependencies..."
L_DEPS_PASS="Dependencies checked."
L_ERR_MISSING="Error: Missing the following tools:"
L_INSTALL_HINT="Please run the following command to install:"
L_CREATE_TMP=">>> [1/6] Creating temporary workspace..."
L_WORK_DIR="Work Dir:"
L_CLONE_AUR=">>> [2/6] Cloning AUR repository..."
L_ERR_CLONE="Failed to clone AUR repo. Check your internet connection."
L_DL_DEB=">>> [3/6] Downloading official Deb & parsing version..."
L_ERR_CHANGELOG="Error: Could not extract version from Changelog."
L_VER_DETECT="Target version detected:"
L_QUERY_SNAP=">>> [4/6] Querying Snapcraft API for Resource ID..."
L_WARN_MISMATCH="Warning: Deb version (%s) matches Snap version (%s)."
L_WARN_CONTINUE="Snap might not be synced yet. Continue? (Ctrl+C to cancel)"
L_SNAP_URL="Snap Download URL:"
L_MOD_PKGBUILD=">>> [5/6] Modifying PKGBUILD..."
L_CALC_SHA=">>> [6/6] Auto-calculating and updating SHA512 checksums..."
L_SUCCESS_HEAD="=============================================="
L_SUCCESS_BODY="  PKGBUILD Update Complete!"
L_FILE_LOC="  File location:"
L_FINAL_MSG="You are now in the temp directory. You can run 'makepkg -si' immediately."
L_EXIT_MSG="Type 'exit' to leave and clean up temporary files."

# [NEW] Version Check Messages
L_CUR_INSTALLED="Current installed version:"
L_NOT_INSTALLED="Termius is not installed locally."
L_ALREADY_LATEST="You already have the target version (%s) installed."
L_ASK_FORCE="Do you want to force reinstall/rebuild? [y/N]: "
L_ABORT_USER="Aborted by user."

# Overwrite with Chinese if locale contains "zh_"
if [[ "$LANG" == *"zh_"* ]]; then
  L_CHECK_DEPS=">>> [0/6] 检查系统依赖..."
  L_DEPS_PASS="依赖检查通过。"
  L_ERR_MISSING="错误: 缺少以下依赖工具:"
  L_INSTALL_HINT="请运行以下命令进行安装:"
  L_CREATE_TMP=">>> [1/6] 创建临时工作目录..."
  L_WORK_DIR="工作目录:"
  L_CLONE_AUR=">>> [2/6] 克隆 AUR 仓库..."
  L_ERR_CLONE="克隆 AUR 仓库失败，请检查网络连接。"
  L_DL_DEB=">>> [3/6] 下载官方 Deb 包并解析版本号..."
  L_ERR_CHANGELOG="错误: 无法从 Changelog 提取版本号。"
  L_VER_DETECT="检测到目标版本:"
  L_QUERY_SNAP=">>> [4/6] 查询 Snapcraft API 获取资源 ID..."
  L_WARN_MISMATCH="警告: Deb 版本 (%s) 与 Snap 最新版本 (%s) 不一致！"
  L_WARN_CONTINUE="Snap 可能尚未同步最新版。是否继续？(Ctrl+C 取消)"
  L_SNAP_URL="Snap 下载地址:"
  L_MOD_PKGBUILD=">>> [5/6] 修改 PKGBUILD 文件..."
  L_CALC_SHA=">>> [6/6] 自动计算并更新 SHA512 校验和..."
  L_SUCCESS_HEAD="=============================================="
  L_SUCCESS_BODY="  PKGBUILD 更新完成！"
  L_FILE_LOC="  文件位置:"
  L_FINAL_MSG="你现在位于临时目录，可以直接执行 'makepkg -si' 进行安装。"
  L_EXIT_MSG="输入 'exit' 退出并清理临时文件。"

  # [NEW] Chinese
  L_CUR_INSTALLED="当前本地已安装:"
  L_NOT_INSTALLED="本地未安装 Termius。"
  L_ALREADY_LATEST="检测到您已经安装了该版本 (%s)。"
  L_ASK_FORCE="是否强制重装/重新构建? [y/N]: "
  L_ABORT_USER="用户已取消。"
fi

# --- 2. Dependency Check Function ---
check_dependencies() {
  local missing_deps=()

  if ! command -v jq &> /dev/null; then missing_deps+=("jq"); fi
  if ! command -v updpkgsums &> /dev/null; then missing_deps+=("pacman-contrib (updpkgsums)"); fi
  if ! command -v ar &> /dev/null; then missing_deps+=("binutils (ar)"); fi
  if ! command -v git &> /dev/null; then missing_deps+=("git"); fi

  if [ ${#missing_deps[@]} -ne 0 ]; then
    echo -e "${RED}${L_ERR_MISSING}${NC}"
    for dep in "${missing_deps[@]}"; do
      echo -e "  - ${dep}"
    done
    echo -e "${BLUE}${L_INSTALL_HINT}${NC}"
    echo -e "sudo pacman -S --needed jq pacman-contrib binutils git"
    exit 1
  fi
}

# --- Main Logic ---

echo -e "${BLUE}${L_CHECK_DEPS}${NC}"
check_dependencies
echo -e "${GREEN}${L_DEPS_PASS}${NC}"

echo -e "${BLUE}${L_CREATE_TMP}${NC}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
echo "${L_WORK_DIR} ${WORK_DIR}"
cd "${WORK_DIR}"

echo -e "${BLUE}${L_CLONE_AUR}${NC}"
if ! git clone https://aur.archlinux.org/termius.git > /dev/null 2>&1; then
  echo -e "${RED}${L_ERR_CLONE}${NC}"
  exit 1
fi
cd termius

echo -e "${BLUE}${L_DL_DEB}${NC}"
DEB_URL="https://autoupdate.termius.com/linux/Termius.deb"
wget -q --show-progress "${DEB_URL}" -O Termius.deb

ar x Termius.deb data.tar.xz
tar -xf data.tar.xz ./usr/share/doc/termius-app/changelog.gz
RAW_LINE=$(zcat ./usr/share/doc/termius-app/changelog.gz | head -n 1)
NEW_VERSION=$(echo "$RAW_LINE" | grep -oP '(?<=\().+?(?=\))')

if [ -z "$NEW_VERSION" ]; then
  echo -e "${RED}${L_ERR_CHANGELOG}${NC}"
  exit 1
fi
echo -e "${GREEN}${L_VER_DETECT} ${NEW_VERSION}${NC}"

# ==============================================================================
# [NEW] Check Installed Version Logic
# ==============================================================================
if command -v pacman &> /dev/null; then
  # Use pacman -Q to query installed version. Suppress stderr if not found.
  if INSTALLED_RAW=$(pacman -Q termius 2>/dev/null); then
    # output format: "termius 9.34.8-1"
    # 1. Extract the second column (9.34.8-1)
    INSTALLED_VER_FULL=$(echo "$INSTALLED_RAW" | awk '{print $2}')
    # 2. Remove the pkgrel (remove anything after the last dash)
    INSTALLED_VER_CLEAN=${INSTALLED_VER_FULL%-*}

    echo -e "${BLUE}${L_CUR_INSTALLED} ${INSTALLED_VER_CLEAN}${NC}"

    if [ "$INSTALLED_VER_CLEAN" == "$NEW_VERSION" ]; then
      printf "${YELLOW}${L_ALREADY_LATEST}${NC}\n" "$NEW_VERSION"
      read -p "$(echo -e ${RED}${L_ASK_FORCE}${NC})" -n 1 -r REPLY
      echo "" # New line
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}${L_ABORT_USER}${NC}"
        exit 0
      fi
    fi
  else
    echo -e "${BLUE}${L_NOT_INSTALLED}${NC}"
  fi
fi
# ==============================================================================

echo -e "${BLUE}${L_QUERY_SNAP}${NC}"
SNAP_API_URL="https://api.snapcraft.io/api/v1/snaps/details/termius-app"
SNAP_HEADER="X-Ubuntu-Series: 16"
SNAP_JSON=$(curl -s -H "${SNAP_HEADER}" "${SNAP_API_URL}")
SNAP_VERSION=$(echo "${SNAP_JSON}" | jq -r '.version')
SNAP_DOWNLOAD_URL=$(echo "${SNAP_JSON}" | jq -r '.download_url')

if [ "$NEW_VERSION" != "$SNAP_VERSION" ]; then
  printf "${RED}${L_WARN_MISMATCH}${NC}\n" "$NEW_VERSION" "$SNAP_VERSION"
  echo -e "${RED}${L_WARN_CONTINUE}${NC}"
  sleep 5
fi
echo -e "${L_SNAP_URL} ${SNAP_DOWNLOAD_URL}"

echo -e "${BLUE}${L_MOD_PKGBUILD}${NC}"
sed -i "s/^pkgver=.*/pkgver=${NEW_VERSION}/" PKGBUILD
sed -i "s|::https://api.snapcraft.io.*snap|::${SNAP_DOWNLOAD_URL}|" PKGBUILD

echo -e "${BLUE}${L_CALC_SHA}${NC}"
updpkgsums

echo -e "${GREEN}${L_SUCCESS_HEAD}${NC}"
echo -e "${GREEN}${L_SUCCESS_BODY}${NC}"
echo -e "${GREEN}${L_FILE_LOC} ${WORK_DIR}/termius/PKGBUILD${NC}"
echo -e "${GREEN}${L_SUCCESS_HEAD}${NC}"

echo -e "${BLUE}${L_FINAL_MSG}${NC}"
echo -e "${BLUE}${L_EXIT_MSG}${NC}"

# Start subshell
bash