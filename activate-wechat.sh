#!/bin/bash
#===============================================================
# title:         activate-wechat.sh
# description:   激活托盘区和任务栏的微信主窗口
# author:        duanluan<duanluan@outlook.com>
# date:          2025-11-07
# version:       v1.1
# changelog:
#   v1.1:
#     - 增加 wmctrl 依赖
#     - 修复任务栏窗口无法激活到前台的问题 (先关闭再激活)
#     - 增加包管理器自动检测 (apt, pacman, dnf, yum)
#     - 修正不同发行版的依赖包名称 (e.g. qt5-qdbus-bin vs qt5-tools)
#===============================================================

# 🚀 自动依赖处理
# ---------------------------------------------------------------
# 1. 探测包管理器
PKG_MANAGER=""
INSTALL_CMD=""
SUDO_CMD="sudo" # 假设 sudo 存在

if command -v apt >/dev/null 2>&1; then
  PKG_MANAGER="apt"
  INSTALL_CMD="$SUDO_CMD apt install -y"
  echo "ℹ️ 检测到包管理器: apt"
elif command -v pacman >/dev/null 2>&1; then
  PKG_MANAGER="pacman"
  INSTALL_CMD="$SUDO_CMD pacman -S --noconfirm"
  echo "ℹ️ 检测到包管理器: pacman"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MANAGER="dnf"
  INSTALL_CMD="$SUDO_CMD dnf install -y"
  echo "ℹ️ 检测到包管理器: dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MANAGER="yum"
  INSTALL_CMD="$SUDO_CMD yum install -y"
  echo "ℹ️ 检测到包管理器: yum"
else
  echo "⚠️ 无法自动识别包管理器。请手动安装以下依赖："
  echo "   - dbus-send (包: dbus, dbus-tools, ...)"
  echo "   - qdbus (包: qt5-qdbus-bin, qt5-tools, ...)"
  echo "   - wmctrl (包: wmctrl)"
  # 不退出，也许依赖已经存在
fi

# 2. 定义检查和安装函数
check_and_install() {
  local cmd_to_check=$1
  local deb_pkg=$2
  local arch_pkg=$3
  local fedora_pkg=$4 # (dnf/yum)

  # 检查命令是否存在
  if ! command -v "$cmd_to_check" >/dev/null 2>&1; then
    echo "🤔 未找到 $cmd_to_check ..."

    if [ -n "$PKG_MANAGER" ]; then
      echo "📥 正在尝试使用 $PKG_MANAGER 安装..."
      local package_to_install=""

      case "$PKG_MANAGER" in
        "apt")
          package_to_install="$deb_pkg"
          ;;
        "pacman")
          package_to_install="$arch_pkg"
          ;;
        "dnf" | "yum")
          package_to_install="$fedora_pkg"

          # 特殊处理：RHEL/CentOS 上的 wmctrl 需要 EPEL
          if [ "$cmd_to_check" == "wmctrl" ] && [ -f /etc/redhat-release ] && ! command -v wmctrl >/dev/null 2>&1; then
             echo "ℹ️ 在 RHEL/CentOS 上, wmctrl 需要 EPEL 仓库。"
             echo "ℹ️ 正在尝试安装 epel-release..."
             $SUDO_CMD $PKG_MANAGER install -y epel-release >/dev/null 2>&1
          fi
          ;;
      esac

      # 执行安装
      if [ -n "$package_to_install" ]; then
        $INSTALL_CMD "$package_to_install"
      else
        echo "❌ 未知包管理器，无法确定包名。"
      fi

    else
      echo "❌ 自动安装失败。请手动安装 $cmd_to_check"
      exit 1
    fi

    # 再次检查
    if ! command -v "$cmd_to_check" >/dev/null 2>&1; then
       echo "❌ 安装后仍未找到 $cmd_to_check。请检查路径或安装是否成功。"
       exit 1
    else
       echo "✅ $cmd_to_check 安装成功。"
    fi
  fi
}

# 3. 执行所有依赖检查
# 命令 | Debian/Ubuntu 包 | Arch 包 | Fedora/RHEL 包
check_and_install "dbus-send" "dbus" "dbus" "dbus-tools"
check_and_install "qdbus" "qt5-qdbus-bin" "qt5-tools" "qt5-qttools"
check_and_install "wmctrl" "wmctrl" "wmctrl" "wmctrl"
# ---------------------------------------------------------------
# 依赖检查结束


wechat_path="/usr/bin/wechat"

# 是否安装 Linux 版微信
if [ ! -x "$wechat_path" ]; then
  echo "未安装微信 Linux 版：https://linux.weixin.qq.com/"
  exit 1
fi

# 查找微信 PID
wechat_pid=$(pgrep -x "wechat")
if [ -z "$wechat_pid" ]; then
  echo "未找到微信进程"
  # 是否启动微信
  # read -p "是否启动微信？(y/n): " is_start
  # if [ "$is_start" == "y" ]; then
  #   $wechat_path &
  # fi
  exit 1
fi

# 🚀 检查微信窗口是否已在任务栏 (核心修改)
# 1. 使用 wmctrl -l -p 列出所有窗口，-p 包含 PID
# 2. awk 筛选出 PID ($3) 匹配 $wechat_pid 的行
# 3. 提取窗口 ID ($1)
# 4. head -n1 只取第一个匹配的窗口
window_id=$(wmctrl -l -p | awk -v pid="$wechat_pid" '$3 == pid {print $1}' | head -n1)

if [ -n "$window_id" ]; then
  echo "ℹ️ 发现微信窗口 ($window_id) 存在于任务栏，正在尝试关闭以最小化到托盘..."
  # -i 通过窗口 ID 操作, -c 关闭窗口 (微信会最小化到托盘)
  wmctrl -i -c "$window_id"
  # 给予 0.2 秒让窗口完成关闭/最小化到托盘的动作
  sleep 0.2
else
  echo "ℹ️ 微信窗口未在任务栏找到，将直接从托盘激活。"
fi


# 获取所有注册的 StatusNotifierItem
items=$(qdbus org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher.RegisteredStatusNotifierItems)

found=0
# 遍历所有注册的项目
for item in $items; do
  # 是否包含微信 PID
  if [[ $item =~ $wechat_pid ]]; then
    found=1
    # 获取项目名称
    item_name=$(echo "$item" | cut -d'/' -f1)
    echo "OK! 正在激活: $item_name"
    # 激活微信主窗口
    dbus-send --session --type=method_call --dest="$item_name" /StatusNotifierItem org.kde.StatusNotifierItem.Activate int32:0 int32:0
    break
  fi
done

if [ $found -eq 0 ]; then
  echo "❌ 未在 D-Bus 中找到微信的 StatusNotifierItem。"
fi
