#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

L_CHECK_DEPS=">>> [0/6] Checking dependencies..."
L_DEPS_PASS="Dependencies checked."
L_ERR_MISSING="Error: Missing the following tools:"
L_INSTALL_HINT="Please install them and try again:"
L_QUERY_RELEASE=">>> [1/6] Querying latest HMCL release..."
L_ERR_RELEASE="Error: Failed to find a downloadable HMCL jar in the latest release."
L_PICKED_RELEASE="Selected release:"
L_CREATE_DIRS=">>> [2/6] Preparing local install directories..."
L_DOWNLOAD_JAR=">>> [3/6] Downloading HMCL jar..."
L_DOWNLOAD_ICON=">>> [4/6] Downloading HMCL icon..."
L_WRITE_DESKTOP=">>> [5/6] Writing desktop entry..."
L_REFRESH_DESKTOP=">>> [6/6] Refreshing desktop database..."
L_DONE="Done."
L_DESKTOP_SKIPPED="update-desktop-database not found. You may need to refresh your application menu manually."
L_CUR_INSTALLED="Current installed version:"
L_NOT_INSTALLED="HMCL is not installed locally."
L_ALREADY_LATEST="You already have the target version (%s) installed."
L_ASK_FORCE="Do you want to force reinstall? [y/N]: "
L_ABORT_USER="Aborted by user."
L_JAVA_HINT="Java is required. Example install command:"
L_LAUNCH_HINT="You can now launch HMCL from the app menu or run:"

if [[ "${LANG:-}" == *"zh_"* ]]; then
  L_CHECK_DEPS=">>> [0/6] 检查依赖..."
  L_DEPS_PASS="依赖检查通过。"
  L_ERR_MISSING="错误：缺少以下依赖工具："
  L_INSTALL_HINT="请先安装后重试："
  L_QUERY_RELEASE=">>> [1/6] 获取最新 HMCL 发布版本..."
  L_ERR_RELEASE="错误：未能在最新发布中找到可下载的 HMCL jar 文件。"
  L_PICKED_RELEASE="已选择版本："
  L_CREATE_DIRS=">>> [2/6] 准备本地安装目录..."
  L_DOWNLOAD_JAR=">>> [3/6] 下载 HMCL jar..."
  L_DOWNLOAD_ICON=">>> [4/6] 下载 HMCL 图标..."
  L_WRITE_DESKTOP=">>> [5/6] 写入桌面启动器..."
  L_REFRESH_DESKTOP=">>> [6/6] 刷新桌面应用缓存..."
  L_DONE="完成。"
  L_DESKTOP_SKIPPED="未找到 update-desktop-database，可能需要手动刷新应用菜单。"
  L_CUR_INSTALLED="当前本地已安装版本："
  L_NOT_INSTALLED="本地未安装 HMCL。"
  L_ALREADY_LATEST="检测到您已经安装了该版本（%s）。"
  L_ASK_FORCE="是否强制重新安装？[y/N]："
  L_ABORT_USER="用户已取消。"
  L_JAVA_HINT="运行 HMCL 需要 Java。可参考安装命令："
  L_LAUNCH_HINT="现在可以从应用菜单启动 HMCL，或直接运行："
fi

API_URL="https://api.github.com/repos/HMCL-dev/HMCL/releases/latest"
ICON_URL="https://docs.hmcl.net/assets/img/hmcl.png"
INSTALL_DIR="${HOME}/.local/share/hmcl"
APPS_DIR="${HOME}/.local/share/applications"
HMCL_JAR="${INSTALL_DIR}/HMCL.jar"
HMCL_ICON="${INSTALL_DIR}/hmcl.png"
VERSION_FILE="${INSTALL_DIR}/VERSION"
DESKTOP_FILE="${APPS_DIR}/hmcl.desktop"
UI_SCALE="${HMCL_UI_SCALE:-1.5}"

print_java_hint() {
  echo -e "${BLUE}${L_JAVA_HINT}${NC}"
  if command -v pacman > /dev/null 2>&1; then
    echo "sudo pacman -S --needed jre-openjdk"
  elif command -v apt-get > /dev/null 2>&1; then
    echo "sudo apt-get install default-jre"
  elif command -v dnf > /dev/null 2>&1; then
    echo "sudo dnf install java-21-openjdk"
  elif command -v yum > /dev/null 2>&1; then
    echo "sudo yum install java-21-openjdk"
  else
    echo "Install a Java runtime from your package manager."
  fi
}

check_dependencies() {
  local missing_deps=()

  if ! command -v curl > /dev/null 2>&1; then missing_deps+=("curl"); fi
  if ! command -v jq > /dev/null 2>&1; then missing_deps+=("jq"); fi
  if ! command -v java > /dev/null 2>&1; then missing_deps+=("java"); fi

  if [ ${#missing_deps[@]} -ne 0 ]; then
    echo -e "${RED}${L_ERR_MISSING}${NC}"
    for dep in "${missing_deps[@]}"; do
      echo "  - ${dep}"
    done
    echo -e "${BLUE}${L_INSTALL_HINT}${NC}"
    print_java_hint
    exit 1
  fi
}

echo -e "${BLUE}${L_CHECK_DEPS}${NC}"
check_dependencies
echo -e "${GREEN}${L_DEPS_PASS}${NC}"

echo -e "${BLUE}${L_QUERY_RELEASE}${NC}"
RELEASE_JSON=$(curl -fsSL \
  -H 'Accept: application/vnd.github+json' \
  -H 'User-Agent: install-hmcl.sh' \
  "${API_URL}")

ASSET_JSON=$(echo "${RELEASE_JSON}" | jq -c '
  [.assets[] | select(.name | test("^HMCL-.*\\.jar$"))]
  | first
')

if [ -z "${ASSET_JSON}" ] || [ "${ASSET_JSON}" = "null" ]; then
  echo -e "${RED}${L_ERR_RELEASE}${NC}"
  exit 1
fi

RELEASE_TAG=$(echo "${RELEASE_JSON}" | jq -r '.tag_name')
ASSET_NAME=$(echo "${ASSET_JSON}" | jq -r '.name')
DOWNLOAD_URL=$(echo "${ASSET_JSON}" | jq -r '.browser_download_url')
TARGET_VERSION="${RELEASE_TAG#v}"

echo -e "${GREEN}${L_PICKED_RELEASE}${NC}"
echo "  tag=${RELEASE_TAG}"
echo "  version=${TARGET_VERSION}"
echo "  asset=${ASSET_NAME}"
echo "  url=${DOWNLOAD_URL}"

if [ -f "${VERSION_FILE}" ]; then
  INSTALLED_VERSION=$(cat "${VERSION_FILE}")
  echo -e "${BLUE}${L_CUR_INSTALLED} ${INSTALLED_VERSION}${NC}"
  if [ "${INSTALLED_VERSION}" = "${TARGET_VERSION}" ]; then
    printf "${YELLOW}${L_ALREADY_LATEST}${NC}\n" "${TARGET_VERSION}"
    if [ -t 0 ]; then
      read -r -p "$(echo -e "${RED}${L_ASK_FORCE}${NC}")" REPLY
      if [[ ! "${REPLY}" =~ ^[Yy]$ ]]; then
        echo -e "${RED}${L_ABORT_USER}${NC}"
        exit 0
      fi
    else
      exit 0
    fi
  fi
else
  echo -e "${BLUE}${L_NOT_INSTALLED}${NC}"
fi

echo -e "${BLUE}${L_CREATE_DIRS}${NC}"
mkdir -p "${INSTALL_DIR}" "${APPS_DIR}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

echo -e "${BLUE}${L_DOWNLOAD_JAR}${NC}"
curl -fL --progress-bar -o "${WORK_DIR}/HMCL.jar" "${DOWNLOAD_URL}"

echo -e "${BLUE}${L_DOWNLOAD_ICON}${NC}"
curl -fL --progress-bar -o "${WORK_DIR}/hmcl.png" "${ICON_URL}"

mv "${WORK_DIR}/HMCL.jar" "${HMCL_JAR}"
mv "${WORK_DIR}/hmcl.png" "${HMCL_ICON}"
printf '%s\n' "${TARGET_VERSION}" > "${VERSION_FILE}"

JAVA_BIN=$(command -v java)

echo -e "${BLUE}${L_WRITE_DESKTOP}${NC}"
cat > "${DESKTOP_FILE}" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=HMCL
Comment=Hello Minecraft! Launcher, a powerful Minecraft launcher.
Exec=${JAVA_BIN} -Dglass.gtk.uiScale=${UI_SCALE} -jar ${HMCL_JAR}
Icon=${HMCL_ICON}
Terminal=false
StartupNotify=false
Categories=Game;
StartupWMClass=org.jackhuang.hmcl.Launcher
EOF

if command -v update-desktop-database > /dev/null 2>&1; then
  echo -e "${BLUE}${L_REFRESH_DESKTOP}${NC}"
  update-desktop-database "${APPS_DIR}" > /dev/null 2>&1 || true
else
  echo -e "${YELLOW}${L_DESKTOP_SKIPPED}${NC}"
fi

echo -e "${GREEN}${L_DONE}${NC}"
echo "${L_LAUNCH_HINT}"
echo "  ${JAVA_BIN} -Dglass.gtk.uiScale=${UI_SCALE} -jar ${HMCL_JAR}"
