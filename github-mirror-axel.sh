#! /bin/bash
#===============================================================
# title:         github-mirror-axel.sh
# description:   一个 axel 包装脚本，用于通过镜像加速 GitHub 下载
# author:        duanluan<duanluan@outlook.com>
# date:          2025-12-30
# version:       v3.2
# usage:         github-mirror-axel.sh <output_file> <url>
#
# description_zh:
#   此脚本旨在替换或包装下载工具（如 axel）。
#   它会检查传入的 URL ($2)。如果 URL 是 github.com 或 raw.githubusercontent.com 域名，
#   它会从一个预定义的列表中随机选择一个镜像（支持 'prefix' 和 'replace' 模式）
#   来加速下载。其他 URL 则保持不变。
#
# changelog:
#   v3.2 (2026-01-04)：直连且出现 403/404 错误，直接终止，不再尝试镜像
#   v3.0 (2025-12-30)：自我更新功能，运行 --self-update 即可通过镜像检测并更新脚本自身
#   v2.5 (2025-12-30)：
#     - 修复: 启动时若存在同名文件但无进度文件(.st)，会导致 axel 报错退出的问题 (改为自动备份旧文件)
#     - 修复: 非镜像（直连）模式下不再触发低速自动切换，避免非 GitHub 链接因网速慢被误杀
#   v2.4 (2025-12-22)：支持 raw.githubusercontent.com 域名的代理加速
#   v2.3 (2025-12-14)：
#     - 修复: 增加“兜底机制”，最后一次重试时即使速度慢也不中断，防止下载失败
#     - 优化: 延长速度检测窗口 (5s -> 15s) 以减少网络波动导致的误判
#     - 调整: 降低最低速度阈值 (100KB/s -> 50KB/s)，增加默认重试次数
#   v2.2 (2025-12-13)：
#     - 新增: 低速自动切换功能 (若5秒内均速 < 100KB/s 则重试)
#     - 新增: 智能重试机制 (最大2次，且自动避开刚刚失败的镜像)
#     - 优化: 恢复 axel 原生进度条显示 (监控逻辑静默运行)
#   v2.1 (2025-12-13)：
#     - 给变量添加引号，解决文件名或 URL 包含空格/特殊字符时的报错
#     - 移除 axel 硬编码路径 (/usr/bin/axel -> axel)，提高系统兼容性
#     - 增加代理列表判空检查，防止列表为空时脚本崩溃
#   v2.0 (2025-11-09)：引入多镜像随机选择，支持 "prefix" (前缀) 和 "replace" (替换) 两种镜像模式
#   v1.0 (2025-10-21)：初始版本，硬编码 gh-proxy.com
#===============================================================

# $1: 本地输出文件名
# $2: 原始下载 URL

OUTPUT_FILE="$1"
ORIGINAL_URL="$2"
MAX_RETRIES=3          # 最大重试次数
MIN_SPEED_KB=50        # 最低速度阈值 KB/s
CHECK_INTERVAL=15      # 检查间隔 (秒)

# 更新相关配置
UPDATE_SOURCE_URL="https://raw.githubusercontent.com/duanluan/shell-scripts/refs/heads/main/github-mirror-axel.sh"
LAST_CHECK_FILE="$HOME/.cache/github-mirror-axel.last_check"
CHECK_COOLDOWN=86400  # 冷却时间：24小时 (秒)

# ===================================================
# 辅助函数: 获取文件大小 (兼容 Linux 和 macOS)
# ===================================================
get_file_size() {
    if [ ! -f "$1" ]; then echo 0; return; fi
    # macOS (BSD) 使用 -f %z, Linux 使用 -c %s
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f %z "$1"
    else
        stat -c %s "$1"
    fi
}

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
    "prefix:https://ghfast.top/"
    "prefix:https://fastgit.cc/"
    # "replace:https://bgithub.xyz/"
    # 在这里添加更多...
)

# ===================================================
# 自我更新检查逻辑
# ===================================================
check_self_update() {
    local force_check=$1
    local current_time=$(date +%s)

    # ---------------------------------------------------
    # 冷却检查逻辑
    # ---------------------------------------------------
    if [ "$force_check" != "true" ]; then
        if [ -f "$LAST_CHECK_FILE" ]; then
            last_check=$(cat "$LAST_CHECK_FILE")
            elapsed=$((current_time - last_check))
            if [ $elapsed -lt $CHECK_COOLDOWN ]; then
                # 仍在冷却时间内，跳过自动检查
                return
            fi
        fi
    fi

    echo "🔍 正在检查更新..."

    # 获取当前版本
    current_ver=$(grep -m1 "# version:" "$0" | awk '{print $3}')

    # 随机选择一个代理来加速更新检测
    num_proxies=${#proxies[@]}
    selected_entry=""
    if [ "$num_proxies" -gt 0 ]; then
        random_index=$(($RANDOM % $num_proxies))
        selected_entry="${proxies[$random_index]}"
    fi

    # 构建代理 URL
    target_url="$UPDATE_SOURCE_URL"
    p_url="直连"
    if [ -n "$selected_entry" ]; then
        p_type=$(echo "$selected_entry" | cut -d':' -f1)
        p_url=$(echo "$selected_entry" | cut -d':' -f2-)
        if [ "$p_type" = "prefix" ]; then
            target_url="${p_url}${UPDATE_SOURCE_URL}"
        elif [ "$p_type" = "replace" ]; then
            target_url="${p_url}$(echo "$UPDATE_SOURCE_URL" | cut -f4- -d'/')"
        fi
    fi

    echo "☁️ 正在从远端获取版本信息 (代理: ${p_url})..."

    # 准备缓存目录
    mkdir -p "$(dirname "$LAST_CHECK_FILE")"

    # 下载到临时文件
    tmp_script="/tmp/github-mirror-axel.sh.tmp"
    curl -sL --connect-timeout 10 -o "$tmp_script" "$target_url"

    if [ ! -s "$tmp_script" ]; then
        echo "❌ 检查更新失败：无法下载脚本文件。"
        rm -f "$tmp_script"
        # 即使失败也记录时间，避免频繁报错
        echo "$current_time" > "$LAST_CHECK_FILE"
        [ "$force_check" = "true" ] && exit 1 || return
    fi

    # 记录最后检查时间
    echo "$current_time" > "$LAST_CHECK_FILE"

    # 提取远程版本
    remote_ver=$(grep -m1 "# version:" "$tmp_script" | awk '{print $3}')

    if [ -z "$remote_ver" ]; then
        echo "❌ 检查更新失败：解析远程版本号错误。"
        rm -f "$tmp_script"
        [ "$force_check" = "true" ] && exit 1 || return
    fi

    # 比较版本号
    ver_local=${current_ver#v}
    ver_remote=${remote_ver#v}
    need_update=$(awk -v l="$ver_local" -v r="$ver_remote" 'BEGIN {print (r > l) ? 1 : 0}')

    if [ "$need_update" -eq 1 ]; then
        echo "🎉 发现新版本: $remote_ver (当前: $current_ver)"
        echo "📦 正在更新..."
        mv "$tmp_script" "$0"
        chmod +x "$0"
        echo "✅ 更新成功！请重新运行脚本。"
        exit 0
    else
        echo "✅ 当前已是最新版本 ($current_ver)。"
        rm -f "$tmp_script"
        if [ "$force_check" = "true" ]; then exit 0; fi
    fi
}

# ---------------------------------------------------
# 参数处理
# ---------------------------------------------------
if [ "$1" == "--self-update" ]; then
    check_self_update "true"
fi

# 默认执行自动更新检查 (受冷却机制保护)
check_self_update "false"

# 检查基本参数
if [ -z "$OUTPUT_FILE" ] || [ -z "$ORIGINAL_URL" ]; then
    echo "💡 用法: $0 <output_file> <url>"
    echo "💡 提示: 运行 $0 --self-update 可强制更新本脚本"
    exit 1
fi

# ===================================================
# 主逻辑循环 (重试机制)
# ===================================================
attempt=0
success=false
last_index=-1  # 用于记录上一次使用的代理索引，防止重试时重复

while [ $attempt -le $MAX_RETRIES ]; do

    # -----------------------------------------------
    # 1. 代理选择逻辑 (含去重)
    # -----------------------------------------------
    num_proxies=${#proxies[@]}
    selected_entry=""

    # 解析域名
    domin=$(echo "$ORIGINAL_URL" | cut -f3 -d'/')

    # 仅针对 github.com 和 raw.githubusercontent.com 启用代理逻辑
    if ([[ "$domin" == *"github.com"* ]] || [[ "$domin" == "raw.githubusercontent.com" ]]) && [ "$num_proxies" -gt 0 ]; then
        # 生成随机索引
        random_index=$(($RANDOM % $num_proxies))

        # [逻辑优化] 如果代理多于1个，且随机到了上次失败的同一个，就强制重选
        if [ "$num_proxies" -gt 1 ]; then
            while [ "$random_index" -eq "$last_index" ]; do
                random_index=$(($RANDOM % $num_proxies))
            done
        fi

        last_index=$random_index
        selected_entry="${proxies[$random_index]}"
    fi

    # -----------------------------------------------
    # 2. 解析代理并构建 URL
    # -----------------------------------------------
    proxy_type=""
    proxy_url=""

    if [ -n "$selected_entry" ]; then
        proxy_type=$(echo "$selected_entry" | cut -d':' -f1)
        proxy_url=$(echo "$selected_entry" | cut -d':' -f2-)
    fi

    url="$ORIGINAL_URL"
    proxy_info="直连"

    if [ -n "$proxy_type" ]; then
        if [ "$proxy_type" = "prefix" ]; then
            url="${proxy_url}${ORIGINAL_URL}"
            proxy_info="镜像: ${proxy_url}"
        elif [ "$proxy_type" = "replace" ]; then
            others=$(echo "$ORIGINAL_URL" | cut -f4- -d'/')
            url="${proxy_url}${others}"
            proxy_info="镜像: ${proxy_url}"
        fi
    fi

    # -----------------------------------------------
    # 3. 输出状态信息
    # -----------------------------------------------
    # 判定是否为最后一次尝试
    is_last_attempt=false
    if [ $attempt -eq $MAX_RETRIES ]; then
        is_last_attempt=true
    fi

    if [ $attempt -eq 0 ]; then
        echo "🚀 开始下载 [$proxy_info]"
    else
        echo "--------------------------------------------------------"
        echo "🔄 第 $attempt 次重试 (切换 -> $proxy_info)"
        if [ "$is_last_attempt" = true ]; then
            echo "🛡️  这是最后一次尝试，已禁用低速检测！"
        fi
    fi

    # -----------------------------------------------
    # 4. 启动下载与监控
    # -----------------------------------------------

    # 检查“僵尸”文件
    # 如果文件存在但 .st 不存在，axel 会因为无法断点续传而直接报错退出。
    # 这种情况通常是上次下载失败残留的，我们将其备份以便重新下载。
    if [ $attempt -eq 0 ] && [ -f "$OUTPUT_FILE" ] && [ ! -f "$OUTPUT_FILE.st" ]; then
        echo "⚠️  检测到残留文件但无进度信息，正在备份并重新开始..."
        mv "$OUTPUT_FILE" "${OUTPUT_FILE}.bak.$(date +%s)"
    fi

    # 后台启动 axel
    # -n 4: 增加连接数到 4 (有时能提高稳定性)
    # -a: 简洁进度条
    # -o $1: 指定输出文件路径
    # -k: 允许连接中断时不删除文件 (为可能的断点续传做准备，虽然换镜像通常不建议混用，但作为保险)
    axel -n 4 -a -k -o "$OUTPUT_FILE" "$url" &
    AXEL_PID=$!

    # 初始化监控变量
    start_delay=0
    prev_size=$(get_file_size "$OUTPUT_FILE")
    download_failed=false

    # 监控循环 (静默运行)
    while kill -0 $AXEL_PID 2>/dev/null; do
        sleep $CHECK_INTERVAL

        # 再次检查进程是否还活着
        if ! kill -0 $AXEL_PID 2>/dev/null; then break; fi

        curr_size=$(get_file_size "$OUTPUT_FILE")
        diff=$((curr_size - prev_size))

        # 启动缓冲期 (前 5 秒不杀，防止连接建立初期的波动)
        if [ $start_delay -lt 1 ]; then
            ((start_delay++))
            prev_size=$curr_size
            continue
        fi

        # 兜底逻辑：如果是最后一次尝试，跳过速度检测
        if [ "$is_last_attempt" = true ]; then
            prev_size=$curr_size
            continue
        fi

        # 速度检查
        # 计算当前间隔内的最低预期字节增量
        min_bytes=$((MIN_SPEED_KB * 1024 * CHECK_INTERVAL))

        # 只有在使用镜像代理时才检测低速切换，直连时不中断
        if [ -n "$proxy_type" ] && [ $diff -lt $min_bytes ]; then
            # 只有出错时才输出，先 echo 空行把进度条顶上去
            echo ""
            echo "⚠️  检测到速度过低 (15s内均速 < ${MIN_SPEED_KB}KB/s)，准备切换..."
            kill $AXEL_PID 2>/dev/null
            wait $AXEL_PID 2>/dev/null
            download_failed=true
            break
        fi

        prev_size=$curr_size
    done

    # -----------------------------------------------
    # 5. 结果判定
    # -----------------------------------------------

    wait $AXEL_PID 2>/dev/null
    exit_code=$?

    if [ "$download_failed" = true ]; then
        # 速度慢主动停止，清理文件，准备重试
        # 注意：这里我们删除了文件，因为换镜像后 offset 可能不同，重新开始比 resume 坏文件更安全
        rm -f "$OUTPUT_FILE" "$OUTPUT_FILE.st"
        ((attempt++))
    elif [ $exit_code -eq 0 ]; then
        success=true
        break
    else
        # 非主动停止的异常退出 (如 404，连接被服务器重置等)
        echo ""
        echo "❌ axel 异常退出 (代码: $exit_code)。"

        # 如果是直连且出现 403/404 错误，直接终止，不再尝试镜像
        # 避免因权限问题或文件不存在导致的无效循环重试
        if [ -z "$proxy_type" ]; then
            err_http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "$url")
            if [ "$err_http_code" == "403" ] || [ "$err_http_code" == "404" ]; then
                echo "⛔ 直连检测到致命错误 (HTTP $err_http_code)，停止下载。"
                rm -f "$OUTPUT_FILE" "$OUTPUT_FILE.st"
                exit 1
            fi
        fi

        # 如果不是最后一次，就清理重试
        if [ "$is_last_attempt" = false ]; then
            rm -f "$OUTPUT_FILE" "$OUTPUT_FILE.st"
        fi
        ((attempt++))
    fi

done

if [ "$success" = false ]; then
    echo "❌ 已达到最大重试次数 ($MAX_RETRIES)，下载失败。"
    exit 1
fi