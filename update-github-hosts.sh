#!/bin/bash
#===============================================================
# title:        update-github-hosts.sh
# description:  自动更新 GitHub IP hosts 并设置定时任务
# author:       duanluan<duanluan@outlook.com>
# date:         2025-11-07
# version:      v1.0
#===============================================================

# --- 1. 权限检查 ---
# 脚本必须以 root 权限运行, 因为要修改 /etc/hosts 和 /etc/cron.d/
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 错误：此脚本需要 root 权限才能运行。"
  echo "请尝试使用: sudo $0"
  exit 1
fi
echo "✅ 权限检查通过 (root 权限)"

# --- 2. 定义变量 ---
HOSTS_FILE="/etc/hosts"
GITHUB_HOSTS_URL="https://ghfast.top/https://raw.githubusercontent.com/ittuann/GitHub-IP-hosts/refs/heads/main/hosts_single"
TEMP_FILE=$(mktemp) # 创建临时文件

# 确保脚本退出时删除临时文件
# trap command EXIT/ERR/INT
trap 'rm -f "$TEMP_FILE"' EXIT

# --- 3. 下载 Hosts ---
echo "⏳ 正在下载最新的 GitHub hosts... (URL: $GITHUB_HOSTS_URL)"
# -L 跟随重定向, --fail 在 HTTP 错误时(如404)快速失败
if ! curl -sL --fail "$GITHUB_HOSTS_URL" -o "$TEMP_FILE"; then
   echo "❌ 下载 hosts 失败。请检查 URL 或网络连接。"
   exit 1
fi
echo "✅ 下载成功。"

# --- 4. 更新 /etc/hosts ---
echo "⏳ 正在更新 $HOSTS_FILE..."

# (这个逻辑同时兼容 "已存在" 和 "不存在" 的情况, 非常好!)
# 步骤 1: 删除 hosts 文件中已有的 GitHub IP hosts 内容块 (如果存在)
sed -i '/# GitHub IP hosts Start/,/# GitHub IP hosts End/d' "$HOSTS_FILE"

# 步骤 2: 将新下载的内容追加到 hosts 文件末尾
cat "$TEMP_FILE" >> "$HOSTS_FILE"

echo "✅ $HOSTS_FILE 更新完毕。"


# --- 5. 设置/更新定时任务 (跨发行版) ---
# 使用 /etc/cron.d/ 是最健壮和标准化的方式

# 获取此脚本的绝对路径
# readlink -f 会解析 $0 (即使是相对路径) 为绝对路径
SCRIPT_PATH=$(readlink -f "$0")

CRON_FILE_PATH="/etc/cron.d/update-github-hosts"
# 注意: cron.d 下的文件必须指定运行的用户名, 这里我们用 root
CRON_JOB_CONTENT="0 1 * * * root /bin/bash $SCRIPT_PATH"

echo "⏳ 正在检查/更新定时任务 (/etc/cron.d/)..."

# 将任务内容写入 cron.d 文件 (覆盖)
# 使用 printf 来确保文件末尾有且只有一个换行符
printf "%s\n" "$CRON_JOB_CONTENT" > "$CRON_FILE_PATH"

# cron.d/ 目录下的文件通常需要 644 权限
chmod 0644 "$CRON_FILE_PATH"

echo "✅ 定时任务已创建/更新：每天凌晨 1 点执行。"
echo "  (cron file: $CRON_FILE_PATH)"

# --- 脚本结束 ---
echo "🎉 全部操作完成。"