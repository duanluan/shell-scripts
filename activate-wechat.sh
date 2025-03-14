#!/bin/bash
#===============================================================
# title:        activate-wechat.sh
# description:  激活托盘区和任务栏的微信主窗口
# author:       duanluan<duanluan@outlook.com>
# date:         2025-03-14
# version:      v1.0
#===============================================================

echo "激活微信主窗口"
# 是否安装 dbus
if [ ! -x /usr/bin/dbus-send ]; then
  echo "安装 dbus"
  sudo apt install dbus -y
fi

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

# 获取所有注册的 StatusNotifierItem
items=$(qdbus org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher.RegisteredStatusNotifierItems)

# 遍历所有注册的项目
for item in $items; do
  # 是否包含微信 PID
  if [[ $item =~ $wechat_pid ]]; then
    echo $item
    # 获取项目名称
    item_name=$(echo "$item" | cut -d'/' -f1)
    # 激活微信主窗口
    dbus-send --session --type=method_call --dest="$item_name" /StatusNotifierItem org.kde.StatusNotifierItem.Activate int32:0 int32:0
    break
  fi
done