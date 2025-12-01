#! /bin/bash
#===============================================================
# title:         github-mirror-axel.sh
# description:   一个 axel 包装脚本，用于通过镜像加速 GitHub 下载
# author:        duanluan<duanluan@outlook.com>
# date:          2025-11-09
# version:       v2.0
# usage:         github-mirror-axel.sh <output_file> <url>
#
# description_zh:
#   此脚本旨在替换或包装下载工具（如 axel）。
#   它会检查传入的 URL ($2)。如果 URL 是 github.com 域名，
#   它会从一个预定义的列表中随机选择一个镜像（支持 'prefix' 和 'replace' 模式）
#   来加速下载。其他 URL 则保持不变。
#
# changelog:
#   v2.0 (2025-11-09):
#     - 引入多镜像随机选择
#     - 支持 "prefix" (前缀) 和 "replace" (替换) 两种镜像模式
#   v1.0 (2025-10-21):
#     - 初始版本，硬编码 gh-proxy.com
#===============================================================

# $1: 本地输出文件名
# $2: 原始下载 URL

# ===================================================
# GitHub 镜像代理列表
# 格式: "类型:URL"
# 类型:
#   - prefix:  前缀模式 (例如: https://gh-proxy.com/https://github.com/...)
#   - replace: 替换模式 (例如: https://bgithub.xyz/user/repo...)
#
# 你可以按需添加或修改这个列表
# ===================================================
declare -a proxies=(
    "prefix:https://gh-proxy.com/"
    "prefix:https://ghproxy.net/"
    # "replace:https://bgithub.xyz/"
    # 在这里添加更多...
)
# --- 随机选择一个代理条目 ---
num_proxies=${#proxies[@]}
random_index=$(($RANDOM % $num_proxies))
selected_entry=${proxies[$random_index]}
# --- 随机选择结束 ---

# --- 解析代理类型和 URL ---
# 使用 cut -d':' -f1 获取类型 (prefix / replace)
proxy_type=$(echo $selected_entry | cut -d':' -f1)
# 使用 cut -d':' -f2- 获取 URL (处理 URL 中可能包含的冒号)
proxy_url=$(echo $selected_entry | cut -d':' -f2-)

# --- 解析原始 URL ($2) ---
# $2 示例: https://github.com/user/repo/file.zip
# domin 将会是: github.com
domin=`echo $2 | cut -f3 -d'/'`

case "$domin" in
    *github.com*)
        # 匹配到 GitHub，应用代理逻辑
        if [ "$proxy_type" = "prefix" ]; then
            # 类型1: 前缀 (代理 URL + 完整原始 URL)
            url="${proxy_url}$2"
            echo "🔄 github-mirror-axel.sh 生效 (类型: Prefix, 镜像: ${proxy_url})"

        elif [ "$proxy_type" = "replace" ]; then
            # 类型2: 替换 (代理 URL + 路径)
            # 提取路径 (例如: user/repo/file.zip)
            others=`echo $2 | cut -f4- -d'/'`
            url="${proxy_url}${others}"
            echo "🔄 github-mirror-axel.sh 生效 (类型: Replace, 镜像: ${proxy_url})"
        fi
        ;;
    *)
        # 其他 URL，不使用代理，直接下载
        url=$2
        echo "ℹ️ github-mirror-axel.sh 生效 (直连)"
        ;;
esac

# 调用 axel 执行下载
# -n 2: 使用 2 个连接数
# -a: 尽可能快 (Alternative: --alternate-output for simple progress bar)
# -o $1: 指定输出文件路径
# $url: (可能) 替换后的 URL
/usr/bin/axel -n 2 -a -o $1 $url
