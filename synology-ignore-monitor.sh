#!/bin/bash
#===============================================================
# title:         synology_ignore_monitor.sh
# description:   监控并自动为 SynologyDrive 注入全局忽略目录规则
# author:        duanluan<duanluan@outlook.com>
# date:          2026-03-12
# version:       v1.1
#===============================================================

# 定义 SynologyDrive 的 session 基础目录
SESSION_DIR="$HOME/.SynologyDrive/data/session"
# 轮询降级模式间隔（秒）
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# 定义需要注入的忽略规则
IGNORE_RULE='black_name = ".git", "node_modules", "venv", ".venv", "vendor", "Pods", "target", "build", "dist", "generator", "bin", "obj", ".idea", ".vscode", "__pycache__", ".pytest_cache", ".cache", ".mvn", ".bundle", ".local", ".mvn", ".gradle", ".fleet", ".kotlin", "checkpoints", "temp", "tmp"'

# 检查是否处于可交互终端
is_interactive_shell() {
  [ -t 0 ] || [ -t 1 ] || [ -t 2 ]
}

# 在可行条件下执行提权命令
run_with_privilege() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
    return $?
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Warning: sudo is not available; skip automatic installation."
    return 127
  fi

  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
    return $?
  fi

  if is_interactive_shell; then
    sudo "$@"
    return $?
  fi

  echo "Warning: Non-interactive environment and sudo requires a password; skip automatic installation."
  return 126
}

# 检查 pacman mirrorlist 是否至少包含一个 Server 条目
pacman_mirrorlist_has_server() {
  local mirrorlist="/etc/pacman.d/mirrorlist"
  [ -f "$mirrorlist" ] && grep -Eq '^[[:space:]]*Server[[:space:]]*=' "$mirrorlist"
}

# 在 mirrorlist 缺失服务器时尝试自动修复
repair_pacman_mirrorlist() {
  if ! command -v pacman-mirrors >/dev/null 2>&1; then
    echo "Warning: pacman-mirrors not found; cannot auto-repair mirrorlist."
    return 1
  fi

  echo "Warning: pacman mirrorlist has no Server entries. Attempting auto-repair..."
  if run_with_privilege pacman-mirrors -f 5; then
    return 0
  fi

  echo "Warning: pacman-mirrors -f 5 failed. Trying full mirror reset..."
  run_with_privilege pacman-mirrors -c all
}

# 使用 pacman 安装 inotify-tools（含 mirrorlist 自修复）
install_with_pacman() {
  if ! pacman_mirrorlist_has_server; then
    repair_pacman_mirrorlist || return 1
  fi

  run_with_privilege pacman -Syy --noconfirm &&
    run_with_privilege pacman -S --noconfirm --needed inotify-tools
}

# 自动检测包管理器并安装 inotify-tools 依赖包（仅在可行时）
install_inotify_tools() {
  echo "Missing inotify-tools. Attempting automatic installation..."
  if command -v apt-get >/dev/null 2>&1; then
    run_with_privilege apt-get update && run_with_privilege apt-get install -y inotify-tools
  elif command -v dnf >/dev/null 2>&1; then
    run_with_privilege dnf install -y inotify-tools
  elif command -v yum >/dev/null 2>&1; then
    # CentOS 7 等老系统可能需要先安装 epel-release
    run_with_privilege yum install -y epel-release && run_with_privilege yum install -y inotify-tools
  elif command -v pacman >/dev/null 2>&1; then
    install_with_pacman
  elif command -v zypper >/dev/null 2>&1; then
    run_with_privilege zypper install -y inotify-tools
  elif command -v apk >/dev/null 2>&1; then
    run_with_privilege apk add inotify-tools
  else
    echo "Error: Cannot detect a supported package manager. Please install inotify-tools manually."
    exit 1
  fi
}

# 检查轮询间隔是否有效
if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Warning: Invalid POLL_INTERVAL='$POLL_INTERVAL', fallback to 5 seconds."
  POLL_INTERVAL=5
fi

# 检查 inotifywait 命令是否存在；缺失时尝试安装，失败则降级为轮询模式
HAS_INOTIFY=true
if ! command -v inotifywait >/dev/null 2>&1; then
  if install_inotify_tools && command -v inotifywait >/dev/null 2>&1; then
    echo "inotify-tools installed successfully."
  else
    HAS_INOTIFY=false
    echo "Warning: inotifywait is unavailable; switch to polling mode (${POLL_INTERVAL}s interval)."
    if command -v pacman >/dev/null 2>&1 && ! pacman_mirrorlist_has_server; then
      echo "Hint: pacman mirrorlist is empty. Try: sudo pacman-mirrors -c all && sudo pacman -Syy && sudo pacman -S inotify-tools"
    else
      echo "Hint: Install inotify-tools manually for event-driven monitoring."
    fi
  fi
fi

# 查找所有包含 blacklist.filter 的目录，并存入数组
mapfile -t CONF_DIRS < <(find "$SESSION_DIR" -name "blacklist.filter" -exec dirname {} \;)

# 如果找不到任何目录则退出脚本
if [ ${#CONF_DIRS[@]} -eq 0 ]; then
  echo "Error: Cannot find any blacklist.filter in $SESSION_DIR"
  exit 1
fi

# 定义更新配置文件的函数，接收目录路径作为参数
update_filter() {
  local target_dir="$1"
  local target_file="$target_dir/blacklist.filter"

  # 检查文件中是否已经包含我们自定义的规则，防止无限循环触发
  if ! grep -Fq "$IGNORE_RULE" "$target_file"; then
    echo "Changes detected or missing rules in $target_file. Injecting custom blacklist rules..."
    # 使用 sed 命令在 [Directory] 这一行的下一行追加我们的忽略规则
    sed -i "/^\[Directory\]/a $IGNORE_RULE" "$target_file"
    echo "Rules injected successfully for $target_dir."
  fi
}

echo "Found ${#CONF_DIRS[@]} session directories."

# 脚本启动时，先主动遍历所有找到的目录执行一次检查和更新
for dir in "${CONF_DIRS[@]}"; do
  update_filter "$dir"
done

monitor_with_inotify() {
  echo "Start monitoring with inotify: ${CONF_DIRS[*]}"
  inotifywait -m -e close_write,moved_to "${CONF_DIRS[@]}" |
    while read -r directory _events filename; do
      # 仅当变动的文件是 blacklist.filter 时才执行更新逻辑
      if [ "$filename" = "blacklist.filter" ]; then
        # inotifywait 输出的 directory 结尾带有斜杠，使用 %/ 去除以便统一格式
        update_filter "${directory%/}"
      fi
    done
}

monitor_with_polling() {
  echo "Start monitoring with polling (${POLL_INTERVAL}s): ${CONF_DIRS[*]}"
  while true; do
    for dir in "${CONF_DIRS[@]}"; do
      update_filter "$dir"
    done
    sleep "$POLL_INTERVAL"
  done
}

if [ "$HAS_INOTIFY" = true ]; then
  monitor_with_inotify
else
  monitor_with_polling
fi
