#!/bin/bash
#
# die.sh - 统一的错误退出函数
#
# 注意：本文件及其余 lib/*.sh 均不 set -e/-u，避免 source 进业务脚本后
# 悄悄改变调用方原本的错误处理行为。是否启用严格模式由业务脚本自行决定。

[[ -n "${_CLI_COVE_DIE_SH:-}" ]] && return
_CLI_COVE_DIE_SH=1

# die <message> [exit_code=1]
die() {
  local msg="$1" code="${2:-1}"
  if declare -F log::error >/dev/null 2>&1; then
    log::error "$msg"
  else
    printf 'ERROR: %s\n' "$msg" >&2
  fi
  exit "$code"
}
