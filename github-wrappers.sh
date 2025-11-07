#!/bin/bash
#===============================================================
# title:       github-wrappers.sh
# description: Shell 包装器 (wrappers), 用于拦截 curl 和 wget 并自动将 GitHub URL 替换为镜像 URL
# author:      duanluan<duanluan@outlook.com>
# date:        2025-11-07
# version:     v1.0
#===============================================================

# ================================================================
# == ♻️ GitHub 镜像加速包装器 (wget) ♻️ ==
# ================================================================
#
# 此函数会拦截 wget 命令, 检查参数中是否有 GitHub URL，如果有, 则自动替换为 gh-proxy.com 镜像地址。
wget() {
  # 用于存放最终参数的数组
  local args=()
  # 标记是否找到了 GitHub URL
  local original_url=""
  local mirrored_url=""

  # 你的镜像前缀
  # (注意: 这里的格式是 https://gh-proxy.com/https:// )
  local mirror_prefix="https://gh-proxy.com/https://"

  # 遍历所有传入的参数
  for arg in "$@"; do
    # 检查参数是否是 GitHub URL (同时匹配 http 和 https)
    if [[ "$arg" == *github.com/* ]]; then
      # 提取 github.com/ 之后的部分
      # 使用 sed 提取 (s|...|...|p):
      # 1. 匹配 'http://github.com/' 或 'https://github.com/'
      # 2. 捕获 (.*) 之后的所有内容
      # 3. 替换为捕获的内容并打印
      local others=$(echo "$arg" | sed -n -E 's|https?://github.com/(.*)|\1|p')

      if [[ -n "$others" ]]; then
        # 构筑镜像 URL
        mirrored_url="${mirror_prefix}github.com/${others}"
        # 将替换后的 URL 添加到参数数组
        args+=("$mirrored_url")
        original_url="$arg"
      else
        # 匹配失败或 URL 不完整 (例如只输入了 github.com), 保留原样
        args+=("$arg")
      fi
    else
      # 其他参数（如 -O, -c, -q 等）原样保留
      args+=("$arg")
    fi
  done

  # 如果替换了 URL, 打印提示信息到 stderr
  if [[ -n "$mirrored_url" ]]; then
    echo "♻️  wget 包装器生效: $original_url -> $mirrored_url" >&2
  fi

  # 使用 'command' 关键字来调用原始的 /usr/bin/wget 程序
  # 并传入修改后的参数数组 ("${args[@]}")
  command wget "${args[@]}"
}

# ================================================================
# == ♻️ GitHub 镜像加速包装器 (curl) ♻️ ==
# ================================================================
#
# 此函数会拦截 'curl' 命令, 逻辑与 wget 包装器相同。
curl() {
  local args=()
  local original_url=""
  local mirrored_url=""
  local mirror_prefix="https://gh-proxy.com/https://"

  for arg in "$@"; do
    if [[ "$arg" == *github.com/* ]]; then
      local others=$(echo "$arg" | sed -n -E 's|https?://github.com/(.*)|\1|p')

      if [[ -n "$others" ]]; then
        mirrored_url="${mirror_prefix}github.com/${others}"
        args+=("$mirrored_url")
        original_url="$arg"
      else
        args+=("$arg")
      fi
    else
      # 其他参数 (-L, -o, -s, -f, 等) 原样保留
      args+=("$arg")
    fi
  done

  if [[ -n "$mirrored_url" ]]; then
    echo "♻️  curl 包装器生效: $original_url -> $mirrored_url" >&2
  fi

  # 调用原始的 /usr/bin/curl 程序
  command curl "${args[@]}"
}
