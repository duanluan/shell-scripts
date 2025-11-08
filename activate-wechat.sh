#!/bin/bash
#===============================================================
# title:         activate-wechat.sh
# description:   激活托盘区和任务栏的微信主窗口
# author:        duanluan<duanluan@outlook.com>
# date:          2025-11-07
# version:       v1.2
# changelog:
#   v1.2:
#     - 解决非终端环境无法弹出 sudo 密码框的问题
#     - 自动检测 TTY：终端内使用 sudo，GUI 环境使用 pkexec
#   v1.1:
#     - 增加 wmctrl 依赖
#     - 修复任务栏窗口无法激活到前台的问题 (先关闭再激活)
#     - 增加包管理器自动检测 (apt, pacman, dnf, yum)
#     - 修正不同发行版的依赖包名称 (e.g. qt5-qdbus-bin vs qt5-tools)
#===============================================================

# 微信可执行文件路径
WECHAT_PATH="/usr/bin/wechat"

# [ -t 1 ] 检查标准输出是否连接到终端
if [ -t 1 ]; then
  # 在终端中运行，使用 sudo
  SUDO_CMD="sudo"
else
  # 非终端环境 (例如：GUI 点击)，尝试使用 pkexec
  if command -v pkexec >/dev/null 2>&1; then
    SUDO_CMD="pkexec"
    echo "ℹ️ 非终端环境，使用 pkexec 获取权限。"
  else
    # 警告：未找到 pkexec，可能无法弹出密码框
    echo "⚠️ 警告：非终端环境，且未找到 'pkexec'。"
    echo "⚠️ 自动安装依赖可能失败，因为它无法弹出密码框。"
    echo "⚠️ 请尝试先在终端中手动运行此脚本一次。"

    # 仍然退回到 sudo，万一用户配置了 NOPASSWD
    SUDO_CMD="sudo"

    # 尝试使用 zenity/kdialog 发出图形化警告
    # (放到子 shell & 后台运行，避免阻塞主流程)
    local_warn_msg="未找到 'pkexec'。\n\n自动安装依赖可能无法弹出密码框。\n\n请尝试先在**终端**中手动运行此脚本一次。"
    if command -v zenity >/dev/null 2>&1; then
        (zenity --warning --text="$local_warn_msg" --title="微信激活脚本依赖警告" &)
    elif command -v kdialog >/dev/null 2>&1; then
        (kdialog --warningcontinuecancel "$local_warn_msg" --title="微信激活脚本依赖警告" &)
    fi
  fi
fi

# 探测包管理器
PKG_MANAGER=""
INSTALL_CMD=""
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

# 定义检查和安装函数
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
            # $SUDO_CMD $PKG_MANAGER install -y epel-release >/dev/null 2>&1
            # 使用 $INSTALL_CMD 保持一致性
            $SUDO_CMD $PKG_MANAGER install -y epel-release
          fi
          ;;
      esac

      # 执行安装
      if [ -n "$package_to_install" ]; then
        # $INSTALL_CMD 已经包含了 $SUDO_CMD
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

# 执行所有依赖检查
# 命令 | Debian/Ubuntu 包 | Arch 包 | Fedora/RHEL 包
check_and_install "dbus-send" "dbus" "dbus" "dbus-tools"
check_and_install "qdbus" "qt5-qdbus-bin" "qt5-tools" "qt5-qttools"
check_and_install "wmctrl" "wmctrl" "wmctrl" "wmctrl"

# 是否安装 Linux 版微信
if [ ! -x "$WECHAT_PATH" ]; then
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
  #   $WECHAT_PATH &
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
