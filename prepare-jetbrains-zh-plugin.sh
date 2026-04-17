#!/bin/bash

set -euo pipefail

PLUGIN_XML_ID="com.intellij.zh"
KEEP_TEMP=0
LIST_ONLY=0
INSTALL_PLUGIN=1
SOURCE_PACKAGE=""
OUTPUT_FILE=""
TEMP_ROOT=""
JB_PATH=""
AS_PATH=""

IDE_DIRS=()
IDE_NAMES=()
IDE_CODES=()
IDE_BUILD_NUMBERS=()
IDE_COMPAT_BUILDS=()
IDE_BRANCHES=()
IDE_RAW_BUILDS=()
IDE_PLUGIN_PATHS=()
IDE_DATA_DIR_NAMES=()
IDE_VENDORS=()
IDE_SELECTORS=()

LOADED_IDE_NAME=""
LOADED_IDE_CODE=""
LOADED_IDE_BUILD_NUMBER=""
LOADED_IDE_COMPAT_BUILD=""
LOADED_IDE_BRANCH=""
LOADED_IDE_RAW_BUILD=""
LOADED_IDE_PLUGIN_PATH=""
LOADED_IDE_DATA_DIR_NAME=""
LOADED_IDE_VENDOR=""
LOADED_IDE_SELECTOR=""

cleanup() {
  if [ -n "${TEMP_ROOT}" ] && [ -d "${TEMP_ROOT}" ] && [ "${KEEP_TEMP}" -eq 0 ]; then
    rm -rf "${TEMP_ROOT}"
  fi
}

trap cleanup EXIT

usage() {
  cat <<'EOF'
用法:
  bash ./prepare-jetbrains-zh-plugin.sh [--list] [--jb <目录或启动命令路径>] [--as <目录或启动命令路径>] [--source <jar|zip>] [--output <jar>] [--keep-temp]

示例:
  bash ./prepare-jetbrains-zh-plugin.sh --list
  bash ./prepare-jetbrains-zh-plugin.sh --as /opt/jetbrains/android-studio
  bash ./prepare-jetbrains-zh-plugin.sh --jb /opt/jetbrains/intellij-idea-ultimate --as /opt/jetbrains/android-studio
  bash ./prepare-jetbrains-zh-plugin.sh --source ~/Downloads/localization-zh.jar --as /opt/jetbrains/android-studio
  bash ./prepare-jetbrains-zh-plugin.sh --jb /opt/jetbrains/intellij-idea-ultimate --as /opt/jetbrains/android-studio --output ~/Downloads/localization-zh.jar
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

abs_path() {
  local input_path="$1"
  local dir_path
  local base_name

  dir_path=$(dirname "$input_path")
  base_name=$(basename "$input_path")

  if [ -d "$input_path" ]; then
    (
      cd "$input_path"
      pwd
    )
    return 0
  fi

  (
    mkdir -p "$dir_path"
    cd "$dir_path"
    printf '%s/%s\n' "$(pwd)" "$base_name"
  )
}

make_compat_build() {
  local build_number="$1"

  printf '%s\n' "$build_number" | awk -F. '
    NF >= 3 { print $1 "." $2 "." $3; next }
    { print $0 }
  '
}

extract_json_string() {
  local file_path="$1"
  local key_name="$2"

  sed -n "s/^[[:space:]]*\"${key_name}\":[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file_path" | head -n 1
}

extract_selector_from_product_info() {
  local file_path="$1"

  perl -0ne '
    if (/"additionalJvmArguments"\s*:\s*\[(.*?)\]/s) {
      my $block = $1;
      if ($block =~ /-Didea\.paths\.selector=([^"]+)/) {
        print "$1\n";
        exit 0;
      }
    }
  ' "$file_path"
}

extract_selector_from_vmoptions() {
  local file_path="$1"

  sed -n 's/^-Didea\.paths\.selector=\(.*\)$/\1/p' "$file_path" | head -n 1
}

load_ide_metadata() {
  local ide_dir="$1"
  local product_info_path="${ide_dir}/product-info.json"
  local build_txt_path="${ide_dir}/build.txt"

  LOADED_IDE_NAME=""
  LOADED_IDE_CODE=""
  LOADED_IDE_BUILD_NUMBER=""
  LOADED_IDE_COMPAT_BUILD=""
  LOADED_IDE_BRANCH=""
  LOADED_IDE_RAW_BUILD=""
  LOADED_IDE_PLUGIN_PATH=""
  LOADED_IDE_DATA_DIR_NAME=""
  LOADED_IDE_VENDOR=""
  LOADED_IDE_SELECTOR=""

  if [ -f "$product_info_path" ]; then
    LOADED_IDE_NAME=$(extract_json_string "$product_info_path" "name")
    LOADED_IDE_CODE=$(extract_json_string "$product_info_path" "productCode")
    LOADED_IDE_BUILD_NUMBER=$(extract_json_string "$product_info_path" "buildNumber")
    LOADED_IDE_DATA_DIR_NAME=$(extract_json_string "$product_info_path" "dataDirectoryName")
    LOADED_IDE_VENDOR=$(extract_json_string "$product_info_path" "productVendor")
    LOADED_IDE_SELECTOR=$(extract_selector_from_product_info "$product_info_path" || true)

    if [ -z "$LOADED_IDE_SELECTOR" ]; then
      local vmoptions_relative_path=""
      local vmoptions_path=""

      vmoptions_relative_path=$(extract_json_string "$product_info_path" "vmOptionsFilePath")
      if [ -n "$vmoptions_relative_path" ]; then
        vmoptions_path="${ide_dir}/${vmoptions_relative_path}"
        if [ -f "$vmoptions_path" ]; then
          LOADED_IDE_SELECTOR=$(extract_selector_from_vmoptions "$vmoptions_path" || true)
        fi
      fi
    fi
  fi

  if [ -f "$build_txt_path" ]; then
    LOADED_IDE_RAW_BUILD=$(tr -d '[:space:]' < "$build_txt_path")
    LOADED_IDE_RAW_BUILD=${LOADED_IDE_RAW_BUILD%%%}
  fi

  if [ -z "$LOADED_IDE_BUILD_NUMBER" ] && [ -n "$LOADED_IDE_RAW_BUILD" ]; then
    case "$LOADED_IDE_RAW_BUILD" in
      *-*)
        LOADED_IDE_CODE=${LOADED_IDE_RAW_BUILD%%-*}
        LOADED_IDE_BUILD_NUMBER=${LOADED_IDE_RAW_BUILD#*-}
        ;;
      *)
        LOADED_IDE_BUILD_NUMBER=$LOADED_IDE_RAW_BUILD
        ;;
    esac
  fi

  if [ -z "$LOADED_IDE_BUILD_NUMBER" ]; then
    return 1
  fi

  LOADED_IDE_COMPAT_BUILD=$(make_compat_build "$LOADED_IDE_BUILD_NUMBER")
  LOADED_IDE_BRANCH=${LOADED_IDE_COMPAT_BUILD%%.*}

  if [ -z "$LOADED_IDE_RAW_BUILD" ]; then
    if [ -n "$LOADED_IDE_CODE" ]; then
      LOADED_IDE_RAW_BUILD="${LOADED_IDE_CODE}-${LOADED_IDE_COMPAT_BUILD}"
    else
      LOADED_IDE_RAW_BUILD="$LOADED_IDE_COMPAT_BUILD"
    fi
  fi

  if [ -z "$LOADED_IDE_NAME" ]; then
    LOADED_IDE_NAME=$(basename "$ide_dir")
  fi

  if [ -z "$LOADED_IDE_SELECTOR" ]; then
    LOADED_IDE_SELECTOR="$LOADED_IDE_DATA_DIR_NAME"
  fi

  if [ -f "${ide_dir}/plugins/localization-zh/lib/localization-zh.jar" ]; then
    LOADED_IDE_PLUGIN_PATH="${ide_dir}/plugins/localization-zh/lib/localization-zh.jar"
  fi

  return 0
}

has_ide_dir() {
  local target_dir="$1"
  local ide_dir

  for ide_dir in "${IDE_DIRS[@]:-}"; do
    if [ "$ide_dir" = "$target_dir" ]; then
      return 0
    fi
  done

  return 1
}

register_ide_dir() {
  local ide_dir="$1"

  if has_ide_dir "$ide_dir"; then
    return 0
  fi

  if ! load_ide_metadata "$ide_dir"; then
    return 1
  fi

  IDE_DIRS+=("$ide_dir")
  IDE_NAMES+=("$LOADED_IDE_NAME")
  IDE_CODES+=("$LOADED_IDE_CODE")
  IDE_BUILD_NUMBERS+=("$LOADED_IDE_BUILD_NUMBER")
  IDE_COMPAT_BUILDS+=("$LOADED_IDE_COMPAT_BUILD")
  IDE_BRANCHES+=("$LOADED_IDE_BRANCH")
  IDE_RAW_BUILDS+=("$LOADED_IDE_RAW_BUILD")
  IDE_PLUGIN_PATHS+=("$LOADED_IDE_PLUGIN_PATH")
  IDE_DATA_DIR_NAMES+=("$LOADED_IDE_DATA_DIR_NAME")
  IDE_VENDORS+=("$LOADED_IDE_VENDOR")
  IDE_SELECTORS+=("$LOADED_IDE_SELECTOR")
}

resolve_ide_dir_from_path() {
  local input_path="$1"
  local resolved_path=""
  local current_dir=""
  local parent_dir=""

  if [ ! -e "$input_path" ]; then
    return 1
  fi

  resolved_path=$(readlink -f "$input_path" 2>/dev/null || printf '%s\n' "$input_path")

  if [ -d "$resolved_path" ]; then
    current_dir="$resolved_path"
  else
    current_dir=$(dirname "$resolved_path")
  fi

  while [ -n "$current_dir" ] && [ "$current_dir" != "/" ]; do
    if [ -f "${current_dir}/product-info.json" ] || [ -f "${current_dir}/build.txt" ]; then
      printf '%s\n' "$current_dir"
      return 0
    fi
    parent_dir=$(dirname "$current_dir")
    if [ "$parent_dir" = "$current_dir" ]; then
      break
    fi
    current_dir="$parent_dir"
  done

  return 1
}

discover_ides_in_root() {
  local search_root="$1"
  local metadata_path

  if [ ! -d "$search_root" ]; then
    return 0
  fi

  while IFS= read -r metadata_path; do
    register_ide_dir "$(dirname "$metadata_path")"
  done < <(rg --files "$search_root" 2>/dev/null | rg '/product-info\.json$' || true)

  while IFS= read -r metadata_path; do
    register_ide_dir "$(dirname "$metadata_path")"
  done < <(rg --files "$search_root" 2>/dev/null | rg '/build\.txt$' | rg -v '/plugins/' || true)
}

discover_ides_from_launchers() {
  local launcher_name
  local launcher_path
  local ide_dir

  for launcher_name in \
    idea idea-ultimate idea-community \
    studio android-studio \
    pycharm webstorm datagrip rustrover rider clion goland phpstorm dataspell aqua gateway; do
    if launcher_path=$(command -v "$launcher_name" 2>/dev/null); then
      ide_dir=$(resolve_ide_dir_from_path "$launcher_path" || true)
      if [ -n "$ide_dir" ]; then
        register_ide_dir "$ide_dir"
      fi
    fi
  done
}

discover_ides() {
  local search_root
  local ide_dir=""

  for search_root in "/opt/jetbrains" "${HOME}/.local/share/JetBrains/Toolbox/apps"; do
    discover_ides_in_root "$search_root"
  done

  discover_ides_from_launchers

  for ide_dir in "$JB_PATH" "$AS_PATH"; do
    if [ -z "$ide_dir" ]; then
      continue
    fi
    ide_dir=$(resolve_ide_dir_from_path "$ide_dir" || true)
    if [ -n "$ide_dir" ]; then
      register_ide_dir "$ide_dir" || true
    fi
  done
}

print_ide_list() {
  local i
  local has_plugin

  if [ "${#IDE_DIRS[@]}" -eq 0 ]; then
    printf '未找到 JetBrains IDE 安装目录。\n'
    return 0
  fi

  for i in "${!IDE_DIRS[@]}"; do
    has_plugin="no"
    if [ -n "${IDE_PLUGIN_PATHS[$i]}" ]; then
      has_plugin="yes"
    fi
    printf '%d\t%s\t%s\t%s\t%s\t%s\n' \
      "$((i + 1))" \
      "${IDE_NAMES[$i]}" \
      "${IDE_CODES[$i]:--}" \
      "${IDE_COMPAT_BUILDS[$i]}" \
      "$has_plugin" \
      "${IDE_DIRS[$i]}"
  done
}

find_index_by_dir() {
  local target_dir="$1"
  local i

  for i in "${!IDE_DIRS[@]}"; do
    if [ "${IDE_DIRS[$i]}" = "$target_dir" ]; then
      printf '%s\n' "$i"
      return 0
    fi
  done

  return 1
}

is_android_studio_index() {
  local target_index="$1"
  local normalized_name=""
  local normalized_base=""

  if [ "${IDE_CODES[$target_index]}" = "AI" ]; then
    return 0
  fi

  normalized_name=$(printf '%s\n' "${IDE_NAMES[$target_index]}" | tr '[:upper:]' '[:lower:]')
  normalized_base=$(basename "${IDE_DIRS[$target_index]}" | tr '[:upper:]' '[:lower:]')

  case "$normalized_name $normalized_base" in
    *"android studio"*|*"android-studio"*)
      return 0
      ;;
  esac

  return 1
}

resolve_as_target_index() {
  local resolved_dir=""
  local target_index=""
  local i
  local matches=()

  if [ -n "$AS_PATH" ]; then
    resolved_dir=$(resolve_ide_dir_from_path "$AS_PATH" || true)
    [ -n "$resolved_dir" ] || die "无法识别 Android Studio 目录: $AS_PATH"
    target_index=$(find_index_by_dir "$resolved_dir" || true)
    [ -n "$target_index" ] || die "未注册 Android Studio 目录: $resolved_dir"
    printf '%s\n' "$target_index"
    return 0
  fi

  for i in "${!IDE_DIRS[@]}"; do
    if is_android_studio_index "$i"; then
      matches+=("$i")
    fi
  done

  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [ "${#matches[@]}" -eq 0 ]; then
    die "未找到 Android Studio，请使用 --as 指定。"
  fi

  die "检测到多个 Android Studio，请使用 --as 指定。"
}

resolve_jb_source_package() {
  local resolved_dir=""
  local source_index=""

  if [ -z "$JB_PATH" ]; then
    return 1
  fi

  resolved_dir=$(resolve_ide_dir_from_path "$JB_PATH" || true)
  [ -n "$resolved_dir" ] || return 1

  source_index=$(find_index_by_dir "$resolved_dir" || true)
  [ -n "$source_index" ] || return 1

  if [ -n "${IDE_PLUGIN_PATHS[$source_index]}" ]; then
    printf '%s\n' "${IDE_PLUGIN_PATHS[$source_index]}"
    return 0
  fi

  return 1
}

download_with_fallback() {
  local url="$1"
  local output_path="$2"

  if command -v wget >/dev/null 2>&1; then
    if wget -qO "$output_path" "$url"; then
      return 0
    fi
  fi

  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "$url" -o "$output_path" 2>/dev/null; then
      return 0
    fi
  fi

  return 1
}

download_marketplace_package() {
  local target_index="$1"
  local output_path="$2"
  local attempts=()
  local build_value="${IDE_COMPAT_BUILDS[$target_index]}"
  local product_code="${IDE_CODES[$target_index]}"
  local attempt
  local download_url

  if [ -n "$product_code" ]; then
    attempts+=("${product_code}-${build_value}")
  fi
  attempts+=("$build_value")

  for attempt in "${attempts[@]}"; do
    download_url="https://plugins.jetbrains.com/pluginManager?action=download&id=${PLUGIN_XML_ID}&build=${attempt}"
    if download_with_fallback "$download_url" "$output_path"; then
      return 0
    fi
    rm -f "$output_path"
  done

  return 1
}

source_priority() {
  local source_path="$1"

  case "$source_path" in
    */intellij-idea-ultimate/*)
      printf '0\n'
      ;;
    */intellij-idea-community/*)
      printf '1\n'
      ;;
    */pycharm/*)
      printf '2\n'
      ;;
    */webstorm/*)
      printf '3\n'
      ;;
    */datagrip/*)
      printf '4\n'
      ;;
    *)
      printf '9\n'
      ;;
  esac
}

choose_local_source_package() {
  local target_index="$1"
  local i
  local best_index="-1"
  local best_diff="999999"
  local best_priority="999999"
  local current_diff
  local current_priority
  local target_branch="${IDE_BRANCHES[$target_index]}"
  local candidate_branch

  for i in "${!IDE_PLUGIN_PATHS[@]}"; do
    if [ -z "${IDE_PLUGIN_PATHS[$i]}" ]; then
      continue
    fi

    candidate_branch="${IDE_BRANCHES[$i]}"
    current_diff=$((target_branch - candidate_branch))
    if [ "$current_diff" -lt 0 ]; then
      current_diff=$((0 - current_diff))
    fi

    if [ "$i" -eq "$target_index" ]; then
      current_priority="-1"
    else
      current_priority=$(source_priority "${IDE_PLUGIN_PATHS[$i]}")
    fi

    if [ "$current_diff" -lt "$best_diff" ] || {
      [ "$current_diff" -eq "$best_diff" ] && [ "$current_priority" -lt "$best_priority" ]
    }; then
      best_index="$i"
      best_diff="$current_diff"
      best_priority="$current_priority"
    fi
  done

  if [ "$best_index" -ge 0 ]; then
    printf '%s\n' "${IDE_PLUGIN_PATHS[$best_index]}"
    return 0
  fi

  return 1
}

extract_source_package() {
  local source_path="$1"
  local work_dir="$2"
  local extract_dir="${work_dir}/extract"
  local plugin_dir="${work_dir}/plugin"
  local plugin_xml_path
  local plugin_root

  rm -rf "$extract_dir" "$plugin_dir"
  mkdir -p "$extract_dir" "$plugin_dir"

  unzip -q "$source_path" -d "$extract_dir"

  plugin_xml_path=$(rg --files "$extract_dir" | rg '/META-INF/plugin\.xml$' | head -n 1 || true)
  if [ -z "$plugin_xml_path" ]; then
    die "源文件中未找到 META-INF/plugin.xml: $source_path"
  fi

  plugin_root=$(dirname "$(dirname "$plugin_xml_path")")
  cp -a "${plugin_root}/." "$plugin_dir/"

  if [ ! -f "${plugin_dir}/META-INF/plugin.xml" ]; then
    die "提取后的插件目录缺少 META-INF/plugin.xml: $source_path"
  fi
}

patch_plugin_xml() {
  local plugin_xml_path="$1"
  local plugin_version="$2"
  local since_build="$3"
  local until_build="$4"

  TARGET_PLUGIN_VERSION="$plugin_version" \
  TARGET_SINCE_BUILD="$since_build" \
  TARGET_UNTIL_BUILD="$until_build" \
    perl -0pi -e '
      s#<version>.*?</version>#<version>$ENV{TARGET_PLUGIN_VERSION}</version>#s;
      s#<idea-version\b[^>]*/>#<idea-version since-build="$ENV{TARGET_SINCE_BUILD}" until-build="$ENV{TARGET_UNTIL_BUILD}" />#s;
      s#<description\b[^>]*>.*?</description>#<description></description>#s;
    ' "$plugin_xml_path"
}

pack_plugin_dir() {
  local plugin_dir="$1"
  local output_path="$2"
  local output_dir
  local temp_path

  output_dir=$(dirname "$output_path")
  temp_path="${output_path}.tmp.$$"

  mkdir -p "$output_dir"

  (
    cd "$plugin_dir"
    rm -f "$temp_path"
    zip -qr "$temp_path" .
  )

  mv -f "$temp_path" "$output_path"
}

get_install_path() {
  local target_index="$1"
  local selector_name="${IDE_SELECTORS[$target_index]}"
  local vendor_name="${IDE_VENDORS[$target_index]}"
  local base_dir=""

  if [ -z "$selector_name" ]; then
    return 1
  fi

  case "$vendor_name" in
    Google)
      base_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/Google"
      ;;
    JetBrains)
      base_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/JetBrains"
      ;;
    *)
      case "${IDE_DIRS[$target_index]}" in
        */android-studio*)
          base_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/Google"
          ;;
        *)
          base_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/JetBrains"
          ;;
      esac
      ;;
  esac

  printf '%s/%s/localization-zh.jar\n' "$base_dir" "$selector_name"
}

install_plugin_file() {
  local source_path="$1"
  local install_path="$2"
  local install_dir
  local temp_path

  install_dir=$(dirname "$install_path")
  temp_path="${install_path}.tmp.$$"

  mkdir -p "$install_dir"
  rm -f "$temp_path"
  cp "$source_path" "$temp_path"
  mv -f "$temp_path" "$install_path"
}

check_dependencies() {
  local missing=()
  local command_name

  for command_name in awk basename cp dirname head mktemp perl readlink rg sed tr unzip zip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing+=("$command_name")
    fi
  done

  if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
    missing+=("wget/curl")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    die "缺少依赖: ${missing[*]}"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --list)
        LIST_ONLY=1
        shift
        ;;
      --source)
        [ "$#" -ge 2 ] || die "--source 需要参数"
        SOURCE_PACKAGE="$2"
        shift 2
        ;;
      --output)
        [ "$#" -ge 2 ] || die "--output 需要参数"
        OUTPUT_FILE="$2"
        shift 2
        ;;
      --keep-temp)
        KEEP_TEMP=1
        shift
        ;;
      --jb)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        JB_PATH="$2"
        shift 2
        ;;
      --as)
        [ "$#" -ge 2 ] || die "$1 需要参数"
        AS_PATH="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1"
        ;;
    esac
  done
}

main() {
  local target_index
  local target_dir
  local target_name
  local target_code
  local target_build
  local target_branch
  local target_since_build
  local target_plugin_version
  local source_path=""
  local source_kind=""
  local stage_dir
  local output_path
  local install_path=""

  parse_args "$@"
  check_dependencies
  discover_ides

  if [ "$LIST_ONLY" -eq 1 ]; then
    print_ide_list
    exit 0
  fi

  target_index=$(resolve_as_target_index)
  target_dir="${IDE_DIRS[$target_index]}"
  target_name="${IDE_NAMES[$target_index]}"
  target_code="${IDE_CODES[$target_index]}"
  target_build="${IDE_COMPAT_BUILDS[$target_index]}"
  target_branch="${IDE_BRANCHES[$target_index]}"

  TEMP_ROOT=$(mktemp -d)
  stage_dir="${TEMP_ROOT}/stage"
  mkdir -p "$stage_dir"

  if [ -n "$SOURCE_PACKAGE" ]; then
    if [ ! -f "$SOURCE_PACKAGE" ]; then
      die "源文件不存在: $SOURCE_PACKAGE"
    fi
    source_path=$(abs_path "$SOURCE_PACKAGE")
    source_kind="manual"
  else
    source_path=$(resolve_jb_source_package || true)
    if [ -n "$source_path" ]; then
      source_kind="jb"
    elif download_marketplace_package "$target_index" "${TEMP_ROOT}/marketplace-package.zip"; then
      source_path="${TEMP_ROOT}/marketplace-package.zip"
      source_kind="marketplace"
    else
      source_path=$(choose_local_source_package "$target_index" || true)
      if [ -z "$source_path" ]; then
        die "未找到可用中文插件。请先安装一个自带 localization-zh.jar 的 JetBrains IDE，或用 --jb / --source 指定。"
      fi
      source_kind="local"
    fi
  fi

  extract_source_package "$source_path" "$stage_dir"

  if [ "$target_code" = "AI" ]; then
    target_since_build="${target_code}-${target_build}"
  else
    target_since_build="$target_build"
  fi

  if [ -n "$target_code" ]; then
    target_plugin_version="${target_code}-${target_build}"
  else
    target_plugin_version="$target_build"
  fi

  patch_plugin_xml \
    "${stage_dir}/plugin/META-INF/plugin.xml" \
    "$target_plugin_version" \
    "$target_since_build" \
    "${target_branch}.*"

  install_path=$(get_install_path "$target_index" || true)
  if [ -z "$install_path" ]; then
    die "无法推断 Android Studio 插件目录。"
  fi

  if [ -n "$OUTPUT_FILE" ]; then
    output_path=$(abs_path "$OUTPUT_FILE")
  else
    output_path="$install_path"
  fi

  pack_plugin_dir "${stage_dir}/plugin" "$output_path"

  if [ "$INSTALL_PLUGIN" -eq 1 ] && [ "$output_path" != "$install_path" ]; then
    install_plugin_file "$output_path" "$install_path"
  fi

  printf 'target=%s\n' "$target_name"
  printf 'target_dir=%s\n' "$target_dir"
  printf 'target_build=%s\n' "$target_since_build"
  printf 'source=%s\n' "$source_path"
  printf 'source_kind=%s\n' "$source_kind"
  printf 'output=%s\n' "$output_path"
  printf 'installed=%s\n' "$install_path"
  if [ "$KEEP_TEMP" -eq 1 ]; then
    printf 'temp=%s\n' "$TEMP_ROOT"
  fi
}

main "$@"
