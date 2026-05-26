#!/bin/bash

set -euo pipefail

OUTPUT="${1:-${RESET_SCREEN_OUTPUT:-HDMI-0}}"

has_command() {
    command -v "$1" >/dev/null 2>&1
}

reset_with_xrandr() {
    xrandr --output "$OUTPUT" --off
    sleep 1
    xrandr --output "$OUTPUT" --auto --primary
}

reset_with_kscreen_doctor() {
    kscreen-doctor "output.${OUTPUT}.disable"
    sleep 1
    kscreen-doctor "output.${OUTPUT}.enable"
}

if has_command xrandr; then
    reset_with_xrandr
elif has_command kscreen-doctor; then
    reset_with_kscreen_doctor
else
    echo "需要安装 xrandr 或 kscreen-doctor" >&2
    exit 1
fi
