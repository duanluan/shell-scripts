#!/bin/bash

set -euo pipefail

# 允许两种显式指定输出口的方式：
# 1. 第一个命令行参数，例如：./reset_screen.sh HDMI-0
# 2. 环境变量，例如：RESET_SCREEN_OUTPUT=HDMI-A-0 ./reset_screen.sh
# 如果都没有传入，则后续根据当前桌面环境自动探测一个已连接输出口。
OUTPUT="${1:-${RESET_SCREEN_OUTPUT:-}}"

# 默认不关闭输出口，避免已打开的软件收到显示器断开事件。
# 可选值：
# - mode：临时切换到另一个分辨率再切回来；
# - dpms：只执行显示电源关闭/打开；
# - apply：只重新应用当前配置；
# - disconnect：关闭输出口再打开，最后兜底使用。
RESET_METHOD="${RESET_SCREEN_METHOD:-mode}"
if [[ "${RESET_SCREEN_HARD:-}" == "1" ]]; then
    RESET_METHOD="disconnect"
elif [[ "${RESET_SCREEN_HARD:-}" == "0" && -z "${RESET_SCREEN_METHOD:-}" ]]; then
    RESET_METHOD="apply"
fi

# 可选：显式指定 X11 DPI，例如 RESET_SCREEN_DPI=144 ./reset_screen.sh。
# 默认动态读取当前桌面配置；读不到时不传 --dpi。
DPI_OVERRIDE="${RESET_SCREEN_DPI:-}"

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
    # 输出行在不同版本里可能是 "Output: 1 HDMI-A-0 ... connected"，
    # 也可能带有 name=HDMI-A-0，这里同时兼容两种格式。
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
            if (name == "" && NF >= 3) {
                name = $3
            }
            if (connected && name != "") {
                print name
                exit
            }
        }
    '
}

get_xrandr_state() {
    local output="$1"

    # 保存当前输出口的分辨率、位置和主屏状态，避免 --auto 重新选择配置。
    xrandr --query | awk -v output="$output" '
        $1 == output && $2 == "connected" {
            primary = ($0 ~ / primary /) ? "1" : "0"
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
                    split($i, geometry, /[+]/)
                    print geometry[1], geometry[2], geometry[3], primary
                    exit
                }
            }
        }
    '
}

get_xrandr_fallback_mode() {
    local output="$1"
    local current_mode="$2"

    # 选择同一输出口上一个接近当前模式的较低分辨率，避免关闭输出口。
    xrandr --query | awk -v output="$output" -v current_mode="$current_mode" '
        $1 == output && $2 == "connected" {
            active = 1
            split(current_mode, current_size, "x")
            current_area = current_size[1] * current_size[2]
            next
        }
        active && /^[^[:space:]]/ {
            exit
        }
        active && /^[[:space:]]+[0-9]+x[0-9]+/ {
            mode = $1
            split(mode, size, "x")
            area = size[1] * size[2]
            if (mode != current_mode && area < current_area && area > best_area) {
                best = mode
                best_area = area
            }
        }
        END {
            if (best != "") {
                print best
            }
        }
    '
}

apply_xrandr_state() {
    local state="$1"
    local dpi="${2:-}"
    local mode xpos ypos primary
    local args

    if [[ -n "$state" ]]; then
        read -r mode xpos ypos primary <<<"$state"
        args=(--output "$OUTPUT" --mode "$mode" --pos "${xpos}x${ypos}")
        if [[ "$primary" == "1" ]]; then
            args+=(--primary)
        fi
        if [[ -n "$dpi" ]]; then
            args+=(--dpi "$dpi")
        fi
        xrandr "${args[@]}"
    else
        args=(--output "$OUTPUT" --auto --primary)
        if [[ -n "$dpi" ]]; then
            args+=(--dpi "$dpi")
        fi
        xrandr "${args[@]}"
    fi
}

reset_xrandr_with_mode_switch() {
    local state="$1"
    local dpi="$2"
    local mode xpos ypos primary fallback_mode

    [[ -n "$state" ]] || return 1
    read -r mode xpos ypos primary <<<"$state"
    fallback_mode="$(get_xrandr_fallback_mode "$OUTPUT" "$mode")"
    [[ -n "$fallback_mode" ]] || return 1

    xrandr --output "$OUTPUT" --mode "$fallback_mode" --pos "${xpos}x${ypos}" ${dpi:+--dpi "$dpi"}
    sleep 1
    apply_xrandr_state "$state" "$dpi"
}

get_kscreen_state() {
    local output="$1"

    # 保存 KDE/Wayland 当前输出口的位置和缩放。mode 若未精确读取到，由 KScreen 保持原配置。
    kscreen-doctor -o | awk -v output="$output" '
        /^Output: / {
            active = 0
            name = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^name=/) {
                    name = $i
                    sub(/^name=/, "", name)
                }
            }
            if (name == "" && NF >= 3) {
                name = $3
            }
            if (name == output) {
                active = 1
            }
            next
        }
        active && /^[[:space:]]*Geometry:/ {
            split($2, pos, ",")
            if (pos[1] != "" && pos[2] != "") {
                print "position." pos[1] "," pos[2]
            }
            next
        }
        active && /^[[:space:]]*Scale:/ {
            if ($2 != "") {
                print "scale." $2
            }
            next
        }
    '
}

apply_kscreen_state() {
    local state="$1"
    local args setting

    args=("output.${OUTPUT}.enable")
    while IFS= read -r setting; do
        [[ -n "$setting" ]] || continue
        args+=("output.${OUTPUT}.${setting}")
    done <<<"$state"

    kscreen-doctor "${args[@]}"
}

read_kde_config() {
    local group="$1"
    local key="$2"

    if has_command kreadconfig6; then
        kreadconfig6 --file kdeglobals --group "$group" --key "$key" 2>/dev/null && return 0
    fi

    if has_command kreadconfig5; then
        kreadconfig5 --file kdeglobals --group "$group" --key "$key" 2>/dev/null && return 0
    fi

    return 1
}

get_kde_scale_factor() {
    local scale_factors scale

    if [[ -n "$OUTPUT" ]]; then
        scale_factors="$(read_kde_config KScreen ScreenScaleFactors || true)"
        scale="$(
            awk -v output="$OUTPUT" '
                BEGIN {
                    RS = ";"
                    FS = "="
                }
                $1 == output && $2 ~ /^[0-9]+([.][0-9]+)?$/ {
                    print $2
                    exit
                }
            ' <<<"$scale_factors"
        )"

        if [[ -n "$scale" ]]; then
            printf '%s\n' "$scale"
            return 0
        fi
    fi

    read_kde_config KScreen ScaleFactor | awk '
        /^[0-9]+([.][0-9]+)?$/ {
            print
            exit
        }
    '
}

get_xft_dpi() {
    xrdb -query 2>/dev/null | awk -F: '
        $1 == "Xft.dpi" {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            if ($2 ~ /^[0-9]+([.][0-9]+)?$/) {
                print $2
                exit
            }
        }
    '
}

normalize_dpi() {
    awk -v dpi="$1" '
        BEGIN {
            if (dpi ~ /^[0-9]+([.][0-9]+)?$/ && dpi > 0) {
                printf "%.0f\n", dpi
            }
        }
    '
}

detect_x11_dpi() {
    local scale dpi

    if [[ -n "$DPI_OVERRIDE" ]]; then
        normalize_dpi "$DPI_OVERRIDE"
        return
    fi

    scale="$(get_kde_scale_factor || true)"
    if [[ -n "$scale" ]]; then
        awk -v scale="$scale" 'BEGIN { printf "%.0f\n", scale * 96 }'
        return 0
    fi

    dpi="$(get_xft_dpi || true)"
    if [[ -n "$dpi" ]]; then
        awk -v dpi="$dpi" 'BEGIN { printf "%.0f\n", dpi }'
    fi
}

reload_xsettingsd() {
    if pgrep -u "$(id -u)" -x xsettingsd >/dev/null 2>&1; then
        pkill -HUP -u "$(id -u)" -x xsettingsd >/dev/null 2>&1 || true
    fi
}

reconfigure_kde() {
    if has_command qdbus6; then
        qdbus6 org.kde.kded6 /kded org.kde.kded6.reconfigure >/dev/null 2>&1 || true
        qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
        return
    fi

    if has_command qdbus; then
        qdbus org.kde.kded6 /kded org.kde.kded6.reconfigure >/dev/null 2>&1 || true
        qdbus org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 || true
    fi
}

refresh_x11_scaling() {
    local dpi

    [[ -n "${DISPLAY:-}" ]] || return

    dpi="$(detect_x11_dpi || true)"
    if [[ -n "$dpi" ]]; then
        xrandr --dpi "$dpi" >/dev/null 2>&1 || true
        printf 'Xft.dpi:\t%s\n' "$dpi" | xrdb -merge >/dev/null 2>&1 || true
    fi

    reload_xsettingsd
    reconfigure_kde
}

reset_with_xrandr() {
    # 主流程再次补齐 Xorg 环境，保证直接调用此函数时也能工作。
    maybe_use_xorg_session

    if [[ -z "$OUTPUT" ]]; then
        OUTPUT="$(detect_xrandr_output)"
    fi

    local state dpi
    state="$(get_xrandr_state "$OUTPUT")"
    dpi="$(detect_x11_dpi || true)"

    # 先尝试唤醒 DPMS，再按当前配置重新应用。
    # xset 在部分环境不可用，不应影响真正的 xrandr 重置动作。
    xset dpms force on >/dev/null 2>&1 || true

    case "$RESET_METHOD" in
        mode)
            reset_xrandr_with_mode_switch "$state" "$dpi" || apply_xrandr_state "$state" "$dpi"
            ;;
        dpms)
            xset dpms force off >/dev/null 2>&1 || true
            sleep 1
            xset dpms force on >/dev/null 2>&1 || true
            apply_xrandr_state "$state" "$dpi"
            ;;
        apply)
            apply_xrandr_state "$state" "$dpi"
            ;;
        disconnect)
            xrandr --output "$OUTPUT" --off
            sleep 1
            apply_xrandr_state "$state" "$dpi"
            ;;
        *)
            echo "RESET_SCREEN_METHOD 只能是 mode、dpms、apply 或 disconnect" >&2
            exit 1
            ;;
    esac

    refresh_x11_scaling
    xset dpms force on >/dev/null 2>&1 || true
}

reset_with_kscreen_doctor() {
    if [[ -z "$OUTPUT" ]]; then
        OUTPUT="$(detect_kscreen_output)"
    fi

    local state
    state="$(get_kscreen_state "$OUTPUT")"

    # KDE/Wayland 下默认只重新应用当前配置，避免已打开的软件收到显示器断开事件。
    if [[ "$RESET_METHOD" == "disconnect" ]]; then
        kscreen-doctor "output.${OUTPUT}.disable"
        sleep 1
    elif [[ "$RESET_METHOD" == "dpms" ]]; then
        sleep 1
    elif [[ "$RESET_METHOD" != "mode" && "$RESET_METHOD" != "apply" ]]; then
        echo "RESET_SCREEN_METHOD 只能是 mode、dpms、apply 或 disconnect" >&2
        exit 1
    fi

    apply_kscreen_state "$state"
    refresh_x11_scaling
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
