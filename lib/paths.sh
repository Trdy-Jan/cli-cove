#!/bin/bash
#
# paths.sh - 健壮地解析文件所在的真实目录（兼容软链接、路径含空格）
#
# 业务脚本用法示例:
#   SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# 若还需要兼容“脚本本身是软链接”的场景，可改用本文件提供的函数:
#   source lib/paths.sh
#   SCRIPT_DIR="$(paths::resolve_dir "${BASH_SOURCE[0]}")"

[[ -n "${_CLI_COVE_PATHS_SH:-}" ]] && return
_CLI_COVE_PATHS_SH=1

# paths::resolve_dir <file_path>
# 输出: file_path 所在的真实目录（已解析软链接）
paths::resolve_dir() {
  local source="$1"
  while [[ -h "$source" ]]; do
    local dir
    dir="$(cd -P "$(dirname -- "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname -- "$source")" >/dev/null 2>&1 && pwd
}
