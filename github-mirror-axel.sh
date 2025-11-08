#! /bin/bash
#===============================================================
# title:         github-mirror-axel.sh
# description:   一个 axel 包装脚本，用于通过镜像加速 GitHub 下载，使用在 https://github.com/duanluan/linux-notes/blob/main/docs/notes/system-configuration.md
# author:        duanluan<duanluan@outlook.com>
# date:          2025-10-21
# version:       v1.0
# usage:         github-mirror-axel.sh <output_file> <url>
#
# description_zh:
#   此脚本旨在替换或包装下载工具（如 axel）。
#   它会检查传入的 URL ($2)。如果 URL 是 github.com 域名，
#   它会自动将 URL 替换为使用 gh-proxy.com 镜像的地址，
#   以加速下载。其他 URL 则保持不变。
#===============================================================

# $1: 本地输出文件名
# $2: 原始下载 URL

echo "ℹ️ github-mirror-axel.sh 生效"

# 提取域名 (例如: https://github.com/user/repo -> github.com)
domin=`echo $2 | cut -f3 -d'/'`
# 提取域名后的路径 (例如: https://github.com/user/repo -> user/repo)
others=`echo $2 | cut -f4- -d'/'`

# 检查域名是否包含 github.com
case "$domin" in
    *github.com*)
        # 匹配到 GitHub 链接，使用 gh-proxy.com 镜像
        echo "-> 检测到 GitHub 链接，应用镜像: $domin"
        url="https://gh-proxy.com/https://github.com/"$others
        ;;
    *)
        # 非 GitHub 链接，使用原始 URL
        url=$2
        ;;
esac

# 调用 axel 执行下载
# -n 2: 使用 2 个连接数
# -a: 尽可能快 (Alternative: --alternate-output for simple progress bar)
# -o $1: 指定输出文件路径
# $url: (可能) 替换后的 URL
/usr/bin/axel -n 2 -a -o $1 $url
