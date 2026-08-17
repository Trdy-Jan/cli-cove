#!/bin/bash
#
# menu_scan.sh - 扫描 scripts/ 目录并解析脚本头部元数据
#
# 约定:
#   - scripts/<category>/*.sh 每个一级子目录是一个分类
#   - 目录名以 "_" 开头的分类会被排除在菜单之外（用于存放模板等）
#   - 不含任何 *.sh 文件的分类目录会被排除
#   - 脚本头部（前 30 行内）用 "# @key: value" 注释声明元数据

[[ -n "${_CLI_COVE_MENU_SCAN_SH:-}" ]] && return
_CLI_COVE_MENU_SCAN_SH=1

_MENU_SCAN_HEAD_LINES=30

menu_scan::_category_has_scripts() {
  local dir="$1" f
  for f in "$dir"/*.sh; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# menu_scan::list_categories <scripts_dir>
# 输出: 每行一个分类目录名（已排除 "_" 前缀与空分类）
menu_scan::list_categories() {
  local scripts_dir="$1" dir base
  for dir in "$scripts_dir"/*/; do
    [[ -d "$dir" ]] || continue
    base="$(basename "$dir")"
    [[ "$base" == _* ]] && continue
    menu_scan::_category_has_scripts "$dir" || continue
    printf '%s\n' "$base"
  done
}

# menu_scan::category_title <category_name>
# 输出: 目录名转为展示用标题（下划线转空格，首字母大写）
menu_scan::category_title() {
  local name="$1" title
  title="${name//_/ }"
  title="$(tr '[:lower:]' '[:upper:]' <<< "${title:0:1}")${title:1}"
  printf '%s\n' "$title"
}

# menu_scan::parse_metadata <script_path>
# 解析脚本头部元数据，结果写入全局变量: META_TITLE META_DESC META_ORDER
# @title 缺失时用文件名 fallback；@desc 缺失时为空；@order 缺失/非数字时为 999
menu_scan::parse_metadata() {
  local script_path="$1"
  META_TITLE=""
  META_DESC=""
  META_ORDER="999"

  local line key value n=0
  while IFS= read -r line && (( n < _MENU_SCAN_HEAD_LINES )); do
    ((n++))
    if [[ "$line" =~ ^#[[:space:]]*@([A-Za-z_]+):[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      case "$key" in
        title) META_TITLE="$value" ;;
        desc)  META_DESC="$value" ;;
        order) [[ "$value" =~ ^[0-9]+$ ]] && META_ORDER="$value" ;;
      esac
    fi
  done < "$script_path"

  if [[ -z "$META_TITLE" ]]; then
    local base
    base="$(basename "$script_path" .sh)"
    base="${base//_/ }"
    base="${base//-/ }"
    META_TITLE="$(tr '[:lower:]' '[:upper:]' <<< "${base:0:1}")${base:1}"
  fi
}

# menu_scan::list_scripts_in_category <scripts_dir> <category>
# 输出: 该分类下 *.sh 的绝对路径，每行一个，按 @order 升序、文件名次序排序
menu_scan::list_scripts_in_category() {
  local scripts_dir="$1" category="$2" dir f
  dir="$scripts_dir/$category"
  [[ -d "$dir" ]] || return 0

  local -a entries=()
  for f in "$dir"/*.sh; do
    [[ -e "$f" ]] || continue
    menu_scan::parse_metadata "$f"
    entries+=("$(printf '%05d' "$META_ORDER")|$(basename "$f")|$f")
  done

  [[ ${#entries[@]} -eq 0 ]] && return 0
  printf '%s\n' "${entries[@]}" | sort | cut -d'|' -f3-
}
