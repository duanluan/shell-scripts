#!/bin/bash
#===============================================================
# title:         synology_ignore_monitor.sh
# description:   监控并自动为 SynologyDrive 注入全局忽略目录规则
# author:        duanluan<duanluan@outlook.com>
# date:          2026-03-09
# version:       v1.0
#===============================================================

# 定义 SynologyDrive 的 session 基础目录
SESSION_DIR="$HOME/.SynologyDrive/data/session"

# 定义需要注入的忽略规则
IGNORE_RULE='black_name = ".git", "node_modules", "venv", ".venv", "vendor", "Pods", "target", "build", "dist", "generator", "bin", "obj", ".idea", ".vscode", "__pycache__", ".pytest_cache", ".cache", ".mvn", ".bundle", ".local", ".mvn", ".gradle", ".fleet", ".kotlin", "checkpoints", "temp", "tmp"'

# 自动检测包管理器并安装 inotify-tools 依赖包
install_inotify_tools() {
  echo "Missing inotify-tools. Attempting automatic installation..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y inotify-tools
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y inotify-tools
  elif command -v yum >/dev/null 2>&1; then
    # CentOS 7 等老系统可能需要先安装 epel-release
    sudo yum install -y epel-release && sudo yum install -y inotify-tools
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm inotify-tools
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y inotify-tools
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add inotify-tools
  else
    echo "Error: Cannot detect a supported package manager. Please install inotify-tools manually."
    exit 1
  fi
}

# 检查 inotifywait 命令是否存在，如果不存在则触发自动安装
if ! command -v inotifywait &> /dev/null; then
  install_inotify_tools
  # 安装完成后再次进行校验，确保安装成功
  if ! command -v inotifywait &> /dev/null; then
    echo "Error: Installation failed. Please check your network or sudo permissions."
    exit 1
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

echo "Start monitoring directories: ${CONF_DIRS[*]}"

# 开始持续监控数组中所有的目录
inotifywait -m -e close_write,moved_to "${CONF_DIRS[@]}" |
  while read -r directory events filename; do
    # 仅当变动的文件是 blacklist.filter 时才执行更新逻辑
    if [ "$filename" = "blacklist.filter" ]; then
      # inotifywait 输出的 directory 结尾带有斜杠，使用 %/ 去除以便统一格式
      update_filter "${directory%/}"
    fi
  done