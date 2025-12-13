#! /bin/bash
#===============================================================
# title:         github-mirror-axel.sh
# description:   一个 axel 包装脚本，用于通过镜像加速 GitHub 下载
# author:        duanluan<duanluan@outlook.com>
# date:          2025-12-13
# version:       v2.2
# usage:         github-mirror-axel.sh <output_file> <url>
#
# description_zh:
#   此脚本旨在替换或包装下载工具（如 axel）。
#   它会检查传入的 URL ($2)。如果 URL 是 github.com 域名，
#   它会从一个预定义的列表中随机选择一个镜像（支持 'prefix' 和 'replace' 模式）
#   来加速下载。其他 URL 则保持不变。
#
# changelog:
#   v2.2 (2025-12-13):
#     - 新增: 低速自动切换功能 (若5秒内均速 < 100KB/s 则重试)
#     - 新增: 智能重试机制 (最大2次，且自动避开刚刚失败的镜像)
#     - 优化: 恢复 axel 原生进度条显示 (监控逻辑静默运行)
#   v2.1 (2025-12-13):
#     - 给变量添加引号，解决文件名或 URL 包含空格/特殊字符时的报错
#     - 移除 axel 硬编码路径 (/usr/bin/axel -> axel)，提高系统兼容性
#     - 增加代理列表判空检查，防止列表为空时脚本崩溃
#   v2.0 (2025-11-09):
#     - 引入多镜像随机选择
#     - 支持 "prefix" (前缀) 和 "replace" (替换) 两种镜像模式
#   v1.0 (2025-10-21):
#     - 初始版本，硬编码 gh-proxy.com
#===============================================================

# $1: 本地输出文件名
# $2: 原始下载 URL

OUTPUT_FILE="$1"
ORIGINAL_URL="$2"
MAX_RETRIES=2          # 最大重试次数 (切换两次)
MIN_SPEED_KB=100       # 最低速度阈值 KB/s (后台监控用)
CHECK_INTERVAL=5       # 检查间隔 (秒)

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
    # "replace:https://bgithub.xyz/"
    # 在这里添加更多...
)

# 检查基本参数
if [ -z "$OUTPUT_FILE" ] || [ -z "$ORIGINAL_URL" ]; then
    echo "用法: $0 <output_file> <url>"
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

    # 仅针对 github.com 启用代理逻辑
    domin=$(echo "$ORIGINAL_URL" | cut -f3 -d'/')

    if [[ "$domin" == *"github.com"* ]] && [ "$num_proxies" -gt 0 ]; then
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
    # 为了不干扰 axel 的进度条，我们在开始前把信息打印清楚
    if [ $attempt -eq 0 ]; then
        echo "🚀 开始下载 [$proxy_info]"
    else
        echo "--------------------------------------------------------"
        echo "🔄 第 $attempt 次重试 (切换 -> $proxy_info)"
    fi
    # 仅在调试时取消注释下面这行
    # echo "⬇️  URL: $url"

    # -----------------------------------------------
    # 4. 启动下载与监控
    # -----------------------------------------------

    # 后台启动 axel
    # -n 2: 使用 2 个连接数
    # -a: 简洁进度条 (保留原生视觉效果)
    # -o $1: 指定输出文件路径
    # 注意: 不使用 -q，让 axel 输出到前台
    axel -n 2 -a -o "$OUTPUT_FILE" "$url" &
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

        # [静默] 不输出当前速度，以免打断 axel 进度条

        # 启动缓冲期 (前 5 秒不杀，防止连接建立初期的波动)
        if [ $start_delay -lt 1 ]; then
            ((start_delay++))
            prev_size=$curr_size
            continue
        fi

        # 速度检查
        # 5秒内的最低字节增量
        min_bytes=$((MIN_SPEED_KB * 1024 * CHECK_INTERVAL))

        if [ $diff -lt $min_bytes ]; then
            # 只有出错时才输出，先 echo 空行把进度条顶上去
            echo ""
            echo "⚠️  检测到速度过低 (后台均速 < ${MIN_SPEED_KB}KB/s)，正在切换..."
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
        rm -f "$OUTPUT_FILE" "$OUTPUT_FILE.st"
        ((attempt++))
    elif [ $exit_code -eq 0 ]; then
        # 成功时不需要额外 echo，axel 进度条走到 100% 就是最好的提示
        success=true
        break
    else
        echo ""
        echo "❌ axel 异常退出 (代码: $exit_code)。"
        rm -f "$OUTPUT_FILE" "$OUTPUT_FILE.st"
        ((attempt++))
    fi

done

if [ "$success" = false ]; then
    echo "❌ 已达到最大重试次数 ($MAX_RETRIES)，下载失败。"
    exit 1
fi
