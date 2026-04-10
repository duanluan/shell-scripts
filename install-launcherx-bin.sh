#!/bin/bash

# ==============================================================================
# LauncherX AUR Package Auto-Updater (Dynamic Build URL)
#
# Logic:
# 1. Detect Language.
# 2. Check Dependencies -> Clone AUR -> Query Corona Studio API (latest stable).
# 3. Pick latest linux-x64 -> Update PKGBUILD (pkgver + source URL).
# 4. updpkgsums -> makepkg -si
# ==============================================================================

set -e

# --- 1. Language & Color Setup ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

L_CHECK_DEPS=">>> [0/6] Checking system dependencies..."
L_DEPS_PASS="Dependencies checked."
L_ERR_MISSING="Error: Missing the following tools:"
L_INSTALL_HINT="Please run the following command to install:"
L_CREATE_TMP=">>> [1/6] Creating temporary workspace..."
L_WORK_DIR="Work Dir:"
L_CLONE_AUR=">>> [2/6] Cloning AUR repository..."
L_ERR_CLONE="Failed to clone AUR repo. Check your internet connection."
L_QUERY_API=">>> [3/6] Querying Corona Studio API for latest stable linux build..."
L_ERR_NO_MATCH="Error: No matching linux-x64 build found in API response."
L_BUILD_PICK="Selected build:"
L_MOD_PKGBUILD=">>> [4/6] Modifying PKGBUILD..."
L_CALC_SUMS=">>> [5/6] Auto-updating checksums (updpkgsums)..."
L_BUILD_INSTALL=">>> [6/6] Building & installing (makepkg -si)..."
L_DONE="Done."

L_CUR_INSTALLED="Current installed version:"
L_NOT_INSTALLED="LauncherX is not installed locally."
L_ALREADY_LATEST="You already have the target version (%s) installed."
L_ASK_FORCE="Do you want to force reinstall/rebuild? [y/N]: "
L_ABORT_USER="Aborted by user."

if [[ "$LANG" == *"zh_"* ]]; then
  L_CHECK_DEPS=">>> [0/6] 检查系统依赖..."
  L_DEPS_PASS="依赖检查通过。"
  L_ERR_MISSING="错误：缺少以下依赖工具："
  L_INSTALL_HINT="请运行以下命令进行安装："
  L_CREATE_TMP=">>> [1/6] 创建临时工作目录..."
  L_WORK_DIR="工作目录："
  L_CLONE_AUR=">>> [2/6] 克隆 AUR 仓库..."
  L_ERR_CLONE="克隆 AUR 仓库失败，请检查网络连接。"
  L_QUERY_API=">>> [3/6] 调用 Corona Studio API 获取最新 stable 的 linux 构建..."
  L_ERR_NO_MATCH="错误：API 返回中未找到匹配的 linux-x64 构建。"
  L_BUILD_PICK="已选择构建："
  L_MOD_PKGBUILD=">>> [4/6] 修改 PKGBUILD..."
  L_CALC_SUMS=">>> [5/6] 自动更新校验和（updpkgsums）..."
  L_BUILD_INSTALL=">>> [6/6] 构建并安装（makepkg -si）..."
  L_DONE="完成。"

  L_CUR_INSTALLED="当前本地已安装版本："
  L_NOT_INSTALLED="本地未安装 LauncherX。"
  L_ALREADY_LATEST="检测到您已经安装了该版本（%s）。"
  L_ASK_FORCE="是否强制重装/重新构建？[y/N]："
  L_ABORT_USER="用户已取消。"
fi

# --- 2. Dependency Check Function ---
check_dependencies() {
  local missing_deps=()

  if ! command -v jq &> /dev/null; then missing_deps+=("jq"); fi
  if ! command -v curl &> /dev/null; then missing_deps+=("curl"); fi
  if ! command -v git &> /dev/null; then missing_deps+=("git"); fi
  if ! command -v updpkgsums &> /dev/null; then missing_deps+=("pacman-contrib (updpkgsums)"); fi
  if ! command -v makepkg &> /dev/null; then missing_deps+=("base-devel (makepkg)"); fi
  if ! command -v sed &> /dev/null; then missing_deps+=("sed"); fi

  if [ ${#missing_deps[@]} -ne 0 ]; then
    echo -e "${RED}${L_ERR_MISSING}${NC}"
    for dep in "${missing_deps[@]}"; do
      echo -e "  - ${dep}"
    done
    echo -e "${BLUE}${L_INSTALL_HINT}${NC}"
    echo -e "sudo pacman -S --needed jq curl git pacman-contrib base-devel"
    exit 1
  fi
}

echo -e "${BLUE}${L_CHECK_DEPS}${NC}"
check_dependencies
echo -e "${GREEN}${L_DEPS_PASS}${NC}"

echo -e "${BLUE}${L_CREATE_TMP}${NC}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
echo -e "${L_WORK_DIR} ${WORK_DIR}"
cd "${WORK_DIR}"

echo -e "${BLUE}${L_CLONE_AUR}${NC}"
if ! git clone https://aur.archlinux.org/launcherx-bin.git > /dev/null 2>&1; then
  echo -e "${RED}${L_ERR_CLONE}${NC}"
  exit 1
fi
cd launcherx-bin

echo -e "${BLUE}${L_QUERY_API}${NC}"
API_URL="https://api.corona.studio/Build/get/latest/all/stable"
API_JSON=$(curl -fsSL "${API_URL}")

# 选取最新 stable 的 linux-x64（优先 net10.0-linux，其次 net9.0-linux 等；按 releaseDate 排序取最新）
PICKED_JSON=$(echo "${API_JSON}" | jq -c '
  map(select(.branch=="Stable" and .runtime=="linux-x64" and (.framework|test("^net[0-9]+\\.[0-9]+-linux$"))))
  | sort_by(.releaseDate)
  | last
')

if [ -z "${PICKED_JSON}" ] || [ "${PICKED_JSON}" == "null" ]; then
  echo -e "${RED}${L_ERR_NO_MATCH}${NC}"
  exit 1
fi

BUILD_ID=$(echo "${PICKED_JSON}" | jq -r '.id')
FRAMEWORK=$(echo "${PICKED_JSON}" | jq -r '.framework')
RUNTIME=$(echo "${PICKED_JSON}" | jq -r '.runtime')
RELEASE_DATE=$(echo "${PICKED_JSON}" | jq -r '.releaseDate')
FILE_HASH=$(echo "${PICKED_JSON}" | jq -r '.fileHash')

# pkgver 用 releaseDate 生成：YYYYMMDD.HHMMSS
PKGVER=$(date -u -d "${RELEASE_DATE}" +%Y%m%d.%H%M%S)

ZIP_NAME="${FRAMEWORK}.${RUNTIME}.zip"
DOWNLOAD_URL="https://api.corona.studio/Build/get/${BUILD_ID}/${ZIP_NAME}"

echo -e "${GREEN}${L_BUILD_PICK}${NC}"
echo "  id=${BUILD_ID}"
echo "  releaseDate=${RELEASE_DATE}"
echo "  pkgver=${PKGVER}"
echo "  url=${DOWNLOAD_URL}"
echo "  fileHash(sha256)=${FILE_HASH}"

# ==============================================================================
# Installed Version Check
# ==============================================================================
if command -v pacman &> /dev/null; then
  if INSTALLED_RAW=$(pacman -Q launcherx-bin 2>/dev/null); then
    INSTALLED_VER_FULL=$(echo "$INSTALLED_RAW" | awk '{print $2}')
    INSTALLED_VER_CLEAN=${INSTALLED_VER_FULL%-*}

    echo -e "${BLUE}${L_CUR_INSTALLED} ${INSTALLED_VER_CLEAN}${NC}"

    if [ "${INSTALLED_VER_CLEAN}" == "${PKGVER}" ]; then
      printf "${YELLOW}${L_ALREADY_LATEST}${NC}\n" "${PKGVER}"
      read -p "$(echo -e ${RED}${L_ASK_FORCE}${NC})" -n 1 -r REPLY
      echo ""
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

echo -e "${BLUE}${L_MOD_PKGBUILD}${NC}"

# 更新 pkgver
sed -i "s/^pkgver=.*/pkgver='${PKGVER}'/" PKGBUILD

# 更新 source 中的下载链接（只替换第一条 zip source）
# 目标行形如：
#   "${pkgname}-${pkgver}.zip::https://api.corona.studio/Build/get/<id>/<framework>.<runtime>.zip"
SOURCE_REPLACEMENT="    \"\${pkgname}-\${pkgver}.zip::${DOWNLOAD_URL}\""
sed -i "s|^[[:space:]]*\"\\\${pkgname}-\\\${pkgver}\.zip::https://api\.corona\.studio/Build/get/[^/]\\+/[^\\\"]\\+\"|${SOURCE_REPLACEMENT}|" PKGBUILD

# 修补 package() 中写死的可执行文件名，兼容旧包的 LauncherX.Avalonia 和新包的 LauncherX
PACKAGE_INSTALL_LINE='    install -Dm755 "${srcdir}/LauncherX.Avalonia" "${pkgdir}/usr/bin/launcherx"'
PACKAGE_INSTALL_REPLACEMENT='    local launcher_bin=""\
    for candidate in LauncherX LauncherX.Avalonia; do\
        if [ -f "${srcdir}/${candidate}" ]; then\
            launcher_bin="${srcdir}/${candidate}"\
            break\
        fi\
    done\
    if [ -z "${launcher_bin}" ]; then\
        echo "LauncherX binary not found in ${srcdir}" >\&2\
        return 1\
    fi\
    install -Dm755 "${launcher_bin}" "${pkgdir}/usr/bin/launcherx"'
sed -i "s|^${PACKAGE_INSTALL_LINE}$|${PACKAGE_INSTALL_REPLACEMENT}|" PKGBUILD

echo -e "${BLUE}${L_CALC_SUMS}${NC}"
updpkgsums

echo -e "${BLUE}${L_BUILD_INSTALL}${NC}"
makepkg -si

echo -e "${GREEN}${L_DONE}${NC}"
