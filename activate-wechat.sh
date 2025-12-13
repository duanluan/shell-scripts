#!/bin/bash
#===============================================================
# title:         activate-wechat.sh
# description:   激活托盘区和任务栏的微信主窗口 (支持 X11 & Wayland)
# author:        duanluan<duanluan@outlook.com>
# date:          2025-12-13
# version:       v1.4
# changelog:
#   v1.4:
#     - 新增文件锁 (flock) 机制，防止快捷键连按导致并发运行冲突
#     - 修复非终端环境下无 pkexec 且 sudo 需要密码时的死锁问题
#     - 优化窗口关闭等待逻辑：轮询检测 (Smart Wait)
#   v1.3:
#     - 新增显示服务类型检测 (X11 vs Wayland)
#     - 完善 Wayland 下的逻辑：利用 XWayland 兼容性通过 wmctrl 操作窗口
#     - 优化日志输出，明确当前运行环境
#   v1.2:
#     - 解决非终端环境无法弹出 sudo 密码框的问题
#     - 自动检测 TTY：终端内使用 sudo，GUI 环境使用 pkexec
#   v1.1:
#     - 增加 wmctrl 依赖
#     - 修复任务栏窗口无法激活到前台的问题 (先关闭再激活)
#     - 增加包管理器自动检测 (apt, pacman, dnf, yum)
#     - 修正不同发行版的依赖包名称 (e.g. qt5-qdbus-bin vs qt5-tools)
#===============================================================

# ===============================================================
# 🔒 防连按/并发锁 (Singleton Lock)
# 防止用户因为反应慢而狂按快捷键，导致多个脚本实例同时运行产生冲突
# ===============================================================
LOCK_FILE="/tmp/activate-wechat-${USER}.lock"
# 打开文件描述符 200 到锁文件
exec 200>"$LOCK_FILE"
# 尝试获取排他锁 (-x)，非阻塞模式 (-n)
# 如果获取失败（即已有实例在运行），则直接退出
flock -x -n 200 || {
    # 这里不需要弹出提示，直接静默退出即可，避免弹出一堆窗口骚扰用户
    exit 0
}

# ===============================================================
# 🟢 脚本主逻辑开始
# ===============================================================

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
    # ⚠️ 关键修改 (v1.4)：防止死锁
    # 如果没有 pkexec，先检查 sudo 是否配置了 NOPASSWD (免密)
    # sudo -n (non-interactive) 如果需要密码会返回非零状态
    if sudo -n true 2>/dev/null; then
        SUDO_CMD="sudo"
        echo "⚠️ 警告：非终端环境且未找到 pkexec，但检测到 sudo 免密权限，继续执行。"
    else
        # 既无 pkexec 也无免密 sudo，无法弹出密码框，必须退出
        # 否则脚本会卡在后台等待输入密码 (死锁)
        echo "❌ 错误：非终端环境，未找到 'pkexec' 且 sudo 需要密码。"
        echo "❌ 脚本无法弹出密码框，即将退出以避免死锁。"

        local_err_msg="未找到 'pkexec' 且 sudo 需要密码。\n\n无法自动安装依赖，请先在**终端**中手动运行此脚本一次。"

        # 尝试弹出错误框 (不再后台运行，而是阻塞显示后退出)
        if command -v zenity >/dev/null 2>&1; then
            zenity --error --text="$local_err_msg" --title="微信激活脚本错误"
        elif command -v kdialog >/dev/null 2>&1; then
            kdialog --error "$local_err_msg" --title="微信激活脚本错误"
        fi

        exit 1
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
  # (dnf/yum)
  local fedora_pkg=$4

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
  exit 1
fi

# 🖥️ 检测显示服务类型 (X11 or Wayland)
# 默认设为 x11 以防变量为空
SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"
echo "ℹ️ 检测到会话类型: $SESSION_TYPE"

# 🚀 检查微信窗口是否已在任务栏 (核心修改)
# 逻辑：
# 1. 无论是 X11 还是 Wayland，微信通常通过 XWayland 运行。
# 2. wmctrl 通常可以列出 XWayland 的窗口。
# 3. 如果找到窗口，执行“关闭”操作以强制其最小化到托盘。
# 4. 这样随后的 Activate 信号才能确保窗口弹出到最前。

# 使用 wmctrl -l -p 列出所有窗口，-p 包含 PID
# awk 筛选出 PID ($3) 匹配 $wechat_pid 的行
# head -n1 只取第一个匹配的窗口
window_id=$(wmctrl -l -p | awk -v pid="$wechat_pid" '$3 == pid {print $1}' | head -n1)

if [ -n "$window_id" ]; then
  echo "ℹ️ 发现微信窗口 ($window_id) 存在于任务栏/桌面，正在尝试先关闭..."

  # 针对 Wayland 的额外日志
  if [[ "$SESSION_TYPE" == "wayland" ]]; then
    echo "   (Wayland 模式下，依赖 XWayland 支持来操作窗口)"
  fi

  # -i 通过窗口 ID 操作, -c 关闭窗口 (微信会最小化到托盘)
  wmctrl -i -c "$window_id"

  # 🚀 智能等待窗口关闭 (v1.4 修改)
  # 之前版本使用硬编码 sleep 0.2，可能导致慢机器激活失败或快机器浪费时间。
  # 现在使用轮询检测：只要窗口 ID 还在，就继续等，直到超时 (2秒)。
  echo "⏳ 等待窗口最小化..."
  wait_count=0
  timeout=20 # 20 * 0.1s = 2s

  while wmctrl -l -p | grep -q "$window_id"; do
    if [ "$wait_count" -ge "$timeout" ]; then
      echo "⚠️ 等待窗口关闭超时，将尝试强制激活..."
      break
    fi
    sleep 0.1
    wait_count=$((wait_count + 1))
  done

# 如果循环提前结束，说明窗口已关闭，可以立即进行下一步
else
  echo "ℹ️ 微信窗口未在任务栏找到 (或已最小化/Wayland限制)，将直接从托盘激活。"
fi


# 获取所有注册的 StatusNotifierItem
# 这一步是跨平台标准的 (FreeDesktop StatusNotifierItem)，在 KDE/GNOME(需插件) 的 X11 和 Wayland 下通用
items=$(qdbus org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher.RegisteredStatusNotifierItems)

found=0
# 遍历所有注册的项目
for item in $items; do
  # 是否包含微信 PID
  if [[ $item =~ $wechat_pid ]]; then
    found=1
    # 获取项目名称 (去掉路径前缀)
    item_name=$(echo "$item" | cut -d'/' -f1)
    echo "🚀 OK! 正在发送 D-Bus Activate 信号: $item_name"

    # 激活微信主窗口
    # method_call Activate int32:x int32:y
    # 参数 0 0 代表点击坐标，通常传 0 即可
    dbus-send --session --type=method_call --dest="$item_name" /StatusNotifierItem org.kde.StatusNotifierItem.Activate int32:0 int32:0
    break
  fi
done

if [ $found -eq 0 ]; then
  echo "❌ 未在 D-Bus 中找到微信的 StatusNotifierItem。"
  echo "   可能原因：微信托盘图标未加载，或 GNOME 缺少 AppIndicator 扩展。"
fi
