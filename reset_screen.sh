#!/bin/bash

set -euo pipefail

# 允许两种显式指定输出口的方式：
# 1. 第一个命令行参数，例如：./reset_screen.sh HDMI-0
# 2. 环境变量，例如：RESET_SCREEN_OUTPUT=HDMI-A-0 ./reset_screen.sh
# 如果都没有传入，则后续根据当前桌面环境自动探测一个已连接输出口。
OUTPUT="${1:-${RESET_SCREEN_OUTPUT:-}}"

has_command() {
    command -v "$1" >/dev/null 2>&1
}

maybe_use_xorg_session() {
    # 已经有可用 DISPLAY 时直接复用当前会话，避免误改环境变量。
    if [[ -n "${DISPLAY:-}" ]] && xrandr --query >/dev/null 2>&1; then
        return
    fi

    local current_uid xorg_args auth_file

    # 某些从 SSH、TTY 或快捷键服务启动的脚本没有 DISPLAY/XAUTHORITY。
    # 这里只查找当前用户自己的 Xorg 进程，避免多用户环境里拿到别人的认证文件。
    current_uid="$(id -u)"
    xorg_args="$(pgrep -u "$current_uid" -a Xorg | head -n 1 || true)"

    # Xorg 启动参数中通常包含 "-auth /path/to/Xauthority"。
    # awk 从完整命令行中提取 -auth 后面的文件路径。
    auth_file="$(awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "-auth" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' <<<"$xorg_args")"

    # 只有认证文件存在且当前用户可读时才补齐环境变量。
    # DISPLAY 默认用 :0，适配单桌面会话的常见场景。
    if [[ -n "$auth_file" && -r "$auth_file" ]]; then
        export DISPLAY="${DISPLAY:-:0}"
        export XAUTHORITY="$auth_file"
    fi
}

xrandr_is_usable() {
    # 不能只判断 xrandr 命令是否存在；Wayland/KDE 下它可能存在但无法控制输出。
    # 先尝试补齐 Xorg 环境，再用 xrandr --query 作为可用性判断。
    maybe_use_xorg_session
    xrandr --query >/dev/null 2>&1
}

detect_xrandr_output() {
    # 在 xrandr 输出中选择一个已连接输出口。
    # 评分策略：
    # - primary 优先，尽量保持用户当前主屏；
    # - 已启用并带坐标的输出其次，避免选中连接但未启用的口；
    # - HDMI 再优先于 DP，兼容本脚本原本主要处理 HDMI 的使用场景。
    xrandr --query | awk '
        /^[^[:space:]]+ connected/ {
            score = 0
            if ($0 ~ / primary /) {
                score += 100
            }
            if ($0 ~ /[0-9]+x[0-9]+\+[0-9]+\+[0-9]+/) {
                score += 50
            }
            if ($1 ~ /^HDMI/) {
                score += 20
            }
            if ($1 ~ /^DP/ || $1 ~ /^DisplayPort/) {
                score += 10
            }
            if (best == "" || score > best_score) {
                best = $1
                best_score = score
            }
        }
        END {
            if (best != "") {
                print best
            } else {
                exit 1
            }
        }
    '
}

detect_kscreen_output() {
    # kscreen-doctor 是 KDE/Wayland 场景更可靠的显示配置工具。
    # 输出行中形如 "Output: ... connected ... name=HDMI-A-0"，
    # 这里取第一个 connected 且带 name 的输出口。
    kscreen-doctor -o | awk '
        /^Output: / {
            connected = 0
            name = ""
            for (i = 1; i <= NF; i++) {
                if ($i == "connected") {
                    connected = 1
                }
                if ($i ~ /^name=/) {
                    name = $i
                    sub(/^name=/, "", name)
                }
            }
            if (connected && name != "") {
                print name
                exit
            }
        }
    '
}

reset_with_xrandr() {
    # 主流程再次补齐 Xorg 环境，保证直接调用此函数时也能工作。
    maybe_use_xorg_session

    if [[ -z "$OUTPUT" ]]; then
        OUTPUT="$(detect_xrandr_output)"
    fi

    # 先尝试唤醒 DPMS，再执行 off -> auto -> primary。
    # xset 在部分环境不可用，不应影响真正的 xrandr 重置动作。
    xset dpms force on >/dev/null 2>&1 || true
    xrandr --output "$OUTPUT" --off
    sleep 1
    xrandr --output "$OUTPUT" --auto --primary
    xset dpms force on >/dev/null 2>&1 || true
}

reset_with_kscreen_doctor() {
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT="$(detect_kscreen_output)"
    fi

    # KDE/Wayland 下用 disable/enable 完成一次显示输出重置。
    kscreen-doctor "output.${OUTPUT}.disable"
    sleep 1
    kscreen-doctor "output.${OUTPUT}.enable"
}

# 优先使用真正可用的 xrandr；如果 xrandr 存在但当前会话不可用，
# 则回退到 kscreen-doctor，避免 Wayland 环境直接失败。
if has_command xrandr && xrandr_is_usable; then
    reset_with_xrandr
elif has_command kscreen-doctor; then
    reset_with_kscreen_doctor
else
    echo "需要安装可用的 xrandr 或 kscreen-doctor" >&2
    exit 1
fi
