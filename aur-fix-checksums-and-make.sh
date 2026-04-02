#!/bin/bash
#===============================================================
# title:         aur-fix-checksums-and-make.sh
# description:   自动修复 AUR source 校验值并继续执行 makepkg
# author:        duanluan<duanluan@outlook.com>
# date:          2026-04-02
# version:       v1.0
# usage:         aur-fix-checksums-and-make [pkgname|pkgbuild_dir] [makepkg_args...]
#
# changelog:
#   v1.0 (2026-04-02)：支持自动修复校验值、自更新、paru/yay 缓存目录解析、重复目录交互选择，以及无需修改时的构建确认
#===============================================================

set -euo pipefail

UPDATE_SOURCE_URL="https://raw.githubusercontent.com/duanluan/shell-scripts/refs/heads/main/aur-fix-checksums-and-make.sh"
LAST_CHECK_FILE="$HOME/.cache/aur-fix-checksums-and-make.last_check"
CHECK_COOLDOWN=86400

declare -a proxies=(
  "prefix:https://gh-proxy.com/"
  "prefix:https://ghproxy.net/"
  "prefix:https://ghfast.top/"
  "prefix:https://fastgit.cc/"
)

if [[ "${LANG:-}" == *"zh_"* ]]; then
  L_ERR_NO_PKG="错误：当前目录没有 PKGBUILD，也没有传入可用目录。"
  L_HINT_PARU="提示：也可以直接传包名，例如：aur-fix-checksums-and-make visual-studio-code-bin"
  L_ERR_DEP="错误：缺少依赖工具：%s"
  L_MULTI_FOUND="检测到多个缓存目录，请选择："
  L_MULTI_PROMPT="请输入序号 [1-%d]："
  L_MULTI_INVALID="错误：无效选择：%s"
  L_MULTI_NO_TTY="错误：检测到多个缓存目录，但当前不是交互终端，无法选择。"
  L_UPDATE_CHECK="🔍 正在检查更新..."
  L_UPDATE_FETCH="☁ 正在从远端获取版本信息 (代理: %s)..."
  L_UPDATE_SKIP="⏭ 更新检查冷却中，跳过。"
  L_UPDATE_DL_FAIL="❌ 检查更新失败：无法下载脚本文件。"
  L_UPDATE_VER_FAIL="❌ 检查更新失败：解析远端版本号错误。"
  L_UPDATE_FOUND="🎉 发现新版本: %s (当前: %s)"
  L_UPDATE_DO="📦 正在更新..."
  L_UPDATE_OK="✅ 更新成功！请重新运行脚本。"
  L_UPDATE_LATEST="✅ 当前已是最新版本 (%s)。"
  L_UPDATE_NO_CURL="❌ 检查更新失败：缺少依赖工具：curl"
  L_VERIFY=">>> [1/4] 检查 source 文件..."
  L_NO_FAIL="未发现校验失败，无需修改 PKGBUILD。"
  L_ASK_BUILD="是否继续执行 makepkg -si？[y/N]："
  L_ABORT_USER="用户已取消。"
  L_FAIL_FOUND="发现 %d 个校验失败的文件，开始更新 PKGBUILD 校验值。"
  L_FAIL_LIST="失败文件："
  L_BACKUP="已备份 PKGBUILD：%s"
  L_UPDATE_SUMS=">>> [2/4] 执行 updpkgsums..."
  L_REVERIFY=">>> [3/4] 再次检查 source 文件..."
  L_STILL_FAIL="错误：更新校验值后仍然有文件未通过检查。"
  L_BUILD=">>> [4/4] 执行 makepkg -si ..."
else
  L_ERR_NO_PKG="Error: no PKGBUILD found in the current directory and no valid directory was provided."
  L_HINT_PARU="Hint: you can also pass the package name directly, for example: aur-fix-checksums-and-make visual-studio-code-bin"
  L_ERR_DEP="Error: missing dependency: %s"
  L_MULTI_FOUND="Multiple cache directories were found. Choose one:"
  L_MULTI_PROMPT="Enter a number [1-%d]: "
  L_MULTI_INVALID="Error: invalid selection: %s"
  L_MULTI_NO_TTY="Error: multiple cache directories were found, but no interactive terminal is available."
  L_UPDATE_CHECK="Checking for updates..."
  L_UPDATE_FETCH="Fetching remote version info (proxy: %s)..."
  L_UPDATE_SKIP="Update check cooldown active. Skipping."
  L_UPDATE_DL_FAIL="Update check failed: could not download script."
  L_UPDATE_VER_FAIL="Update check failed: could not parse remote version."
  L_UPDATE_FOUND="New version found: %s (current: %s)"
  L_UPDATE_DO="Updating..."
  L_UPDATE_OK="Update complete. Please run the script again."
  L_UPDATE_LATEST="Already up to date (%s)."
  L_UPDATE_NO_CURL="Update check failed: missing dependency: curl"
  L_VERIFY=">>> [1/4] Verifying source files..."
  L_NO_FAIL="No checksum mismatch detected. No PKGBUILD change is needed."
  L_ASK_BUILD="Continue with makepkg -si? [y/N]: "
  L_ABORT_USER="Aborted by user."
  L_FAIL_FOUND="Detected %d source file checksum mismatches. Updating PKGBUILD checksums."
  L_FAIL_LIST="Failed files:"
  L_BACKUP="Backed up PKGBUILD to: %s"
  L_UPDATE_SUMS=">>> [2/4] Running updpkgsums..."
  L_REVERIFY=">>> [3/4] Re-verifying source files..."
  L_STILL_FAIL="Error: source verification still fails after updating checksums."
  L_BUILD=">>> [4/4] Running makepkg -si ..."
fi

get_script_path() {
  local source="${BASH_SOURCE[0]}"
  while [[ -L "$source" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  local base_dir
  base_dir="$(cd -P "$(dirname "$source")" && pwd)"
  printf '%s/%s\n' "$base_dir" "$(basename "$source")"
}

SCRIPT_PATH="$(get_script_path)"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s\n' "$(printf "$L_ERR_DEP" "$1")" >&2
    exit 1
  fi
}

confirm_build_if_needed() {
  if [[ ! -t 0 ]]; then
    return 0
  fi

  local reply
  read -r -p "$L_ASK_BUILD" reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    printf '%s\n' "$L_ABORT_USER"
    exit 0
  fi
}

check_self_update() {
  local force_check="$1"
  local current_time
  current_time="$(date +%s)"

  if [[ "$force_check" != "true" && -f "$LAST_CHECK_FILE" ]]; then
    local last_check elapsed
    last_check="$(cat "$LAST_CHECK_FILE")"
    elapsed=$((current_time - last_check))
    if [[ $elapsed -lt $CHECK_COOLDOWN ]]; then
      printf '%s\n' "$L_UPDATE_SKIP"
      return
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    if [[ "$force_check" == "true" ]]; then
      printf '%s\n' "$L_UPDATE_NO_CURL" >&2
      exit 1
    fi
    return
  fi

  printf '%s\n' "$L_UPDATE_CHECK"

  local current_ver
  current_ver="$(grep -m1 "# version:" "$SCRIPT_PATH" | awk '{print $3}')"

  local num_proxies selected_entry random_index target_url proxy_label proxy_type proxy_url tmp_script remote_ver
  num_proxies=${#proxies[@]}
  selected_entry=""
  if [[ "$num_proxies" -gt 0 ]]; then
    random_index=$(($RANDOM % $num_proxies))
    selected_entry="${proxies[$random_index]}"
  fi

  target_url="$UPDATE_SOURCE_URL"
  proxy_label="直连"
  if [[ -n "$selected_entry" ]]; then
    proxy_type="$(echo "$selected_entry" | cut -d':' -f1)"
    proxy_url="$(echo "$selected_entry" | cut -d':' -f2-)"
    proxy_label="$proxy_url"
    if [[ "$proxy_type" == "prefix" ]]; then
      target_url="${proxy_url}${UPDATE_SOURCE_URL}"
    elif [[ "$proxy_type" == "replace" ]]; then
      target_url="${proxy_url}$(echo "$UPDATE_SOURCE_URL" | cut -f4- -d'/')"
    fi
  fi

  printf "$L_UPDATE_FETCH\n" "$proxy_label"
  mkdir -p "$(dirname "$LAST_CHECK_FILE")"

  tmp_script="/tmp/aur-fix-checksums-and-make.sh.tmp"
  if ! curl -sL --connect-timeout 10 --max-time 20 -o "$tmp_script" "$target_url"; then
    printf '%s\n' "$L_UPDATE_DL_FAIL"
    rm -f "$tmp_script"
    printf '%s\n' "$current_time" > "$LAST_CHECK_FILE"
    if [[ "$force_check" == "true" ]]; then
      exit 1
    fi
    return 0
  fi

  if [[ ! -s "$tmp_script" ]]; then
    printf '%s\n' "$L_UPDATE_DL_FAIL"
    rm -f "$tmp_script"
    printf '%s\n' "$current_time" > "$LAST_CHECK_FILE"
    if [[ "$force_check" == "true" ]]; then
      exit 1
    fi
    return 0
  fi

  printf '%s\n' "$current_time" > "$LAST_CHECK_FILE"
  remote_ver="$(grep -m1 "# version:" "$tmp_script" | awk '{print $3}')"

  if [[ -z "$remote_ver" ]]; then
    printf '%s\n' "$L_UPDATE_VER_FAIL"
    rm -f "$tmp_script"
    if [[ "$force_check" == "true" ]]; then
      exit 1
    fi
    return 0
  fi

  local ver_local ver_remote need_update
  ver_local="${current_ver#v}"
  ver_remote="${remote_ver#v}"
  need_update="$(awk -v l="$ver_local" -v r="$ver_remote" 'BEGIN {print (r > l) ? 1 : 0}')"

  if [[ "$need_update" -eq 1 ]]; then
    printf "$L_UPDATE_FOUND\n" "$remote_ver" "$current_ver"
    printf '%s\n' "$L_UPDATE_DO"
    mv "$tmp_script" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    printf '%s\n' "$L_UPDATE_OK"
    exit 0
  fi

  printf "$L_UPDATE_LATEST\n" "$current_ver"
  rm -f "$tmp_script"
  if [[ "$force_check" == "true" ]]; then
    exit 0
  fi
  return 0
}

if [[ "${1:-}" == "--self-update" ]]; then
  check_self_update "true"
fi

check_self_update "false"

resolve_pkgbuild_dir() {
  local input="$1"

  if [[ -d "$input" && -f "$input/PKGBUILD" ]]; then
    printf '%s\n' "$input"
    return 0
  fi

  if [[ "$input" != */* ]]; then
    local cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
    local labels=()
    local paths=()
    local choice
    local idx

    if [[ -d "$cache_root/paru/clone/$input" && -f "$cache_root/paru/clone/$input/PKGBUILD" ]]; then
      labels+=("paru")
      paths+=("$cache_root/paru/clone/$input")
    fi

    if [[ -d "$cache_root/yay/$input" && -f "$cache_root/yay/$input/PKGBUILD" ]]; then
      labels+=("yay")
      paths+=("$cache_root/yay/$input")
    fi

    if [[ ${#paths[@]} -eq 1 ]]; then
      printf '%s\n' "${paths[0]}"
      return 0
    fi

    if [[ ${#paths[@]} -gt 1 ]]; then
      if [[ ! -t 0 ]]; then
        printf '%s\n' "$L_MULTI_NO_TTY" >&2
        return 1
      fi

      printf '%s\n' "$L_MULTI_FOUND" >&2
      for idx in "${!paths[@]}"; do
        printf '%d) %s  %s\n' "$((idx + 1))" "${labels[idx]}" "${paths[idx]}" >&2
      done

      while true; do
        printf "$L_MULTI_PROMPT" "${#paths[@]}" >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#paths[@]} )); then
          printf '%s\n' "${paths[$((choice - 1))]}"
          return 0
        fi
        printf "$L_MULTI_INVALID\n" "$choice" >&2
      done
    fi
  fi

  return 1
}

if [[ $# -gt 0 ]]; then
  if pkg_dir="$(resolve_pkgbuild_dir "$1")"; then
    cd "$pkg_dir"
    shift
  fi
fi

if [[ ! -f PKGBUILD ]]; then
  printf '%s\n' "$L_ERR_NO_PKG" >&2
  printf '%s\n' "$L_HINT_PARU" >&2
  exit 1
fi

require_command makepkg
require_command updpkgsums

verify_log="$(mktemp)"
reverify_log="$(mktemp)"
trap 'rm -f "$verify_log" "$reverify_log"' EXIT

printf '%s\n' "$L_VERIFY"
if LANG=C makepkg --verifysource 2>&1 | tee "$verify_log"; then
  failed_count=0
else
  failed_count="$(awk '/\.\.\. FAILED$/ {count++} END {print count+0}' "$verify_log")"
fi

if [[ "${failed_count:-0}" -eq 0 ]]; then
  printf '%s\n' "$L_NO_FAIL"
  confirm_build_if_needed
  printf '%s\n' "$L_BUILD"
  exec makepkg -si "$@"
fi

printf "$L_FAIL_FOUND\n" "$failed_count"
printf '%s\n' "$L_FAIL_LIST"
awk '/\.\.\. FAILED$/ {sub(/[[:space:]]+\.\.\. FAILED$/, "", $0); sub(/^[[:space:]]+/, "", $0); print "  - " $0}' "$verify_log"

backup_file="PKGBUILD.bak.$(date +%Y%m%d%H%M%S)"
cp PKGBUILD "$backup_file"
printf "$L_BACKUP\n" "$backup_file"

printf '%s\n' "$L_UPDATE_SUMS"
updpkgsums

printf '%s\n' "$L_REVERIFY"
if LANG=C makepkg --verifysource 2>&1 | tee "$reverify_log"; then
  :
else
  if awk '/\.\.\. FAILED$/ {found=1} END {exit found ? 0 : 1}' "$reverify_log"; then
    printf '%s\n' "$L_STILL_FAIL" >&2
    exit 1
  fi
fi

printf '%s\n' "$L_BUILD"
exec makepkg -si "$@"
