#!/bin/bash
#
# log.sh - 统一格式的日志输出函数
# 依赖 colors.sh（未加载时自动降级为无色输出，不报错）

[[ -n "${_CLI_COVE_LOG_SH:-}" ]] && return
_CLI_COVE_LOG_SH=1

_log::emit() {
  local color="$1" tag="$2"
  shift 2
  local ts=""
  if [[ "${CLI_COVE_LOG_TIMESTAMP:-1}" != "0" ]]; then
    ts="[$(date '+%H:%M:%S')] "
  fi
  if declare -F color::supported >/dev/null 2>&1 && color::supported; then
    printf '%b%s[%s] %s%b\n' "$color" "$ts" "$tag" "$*" "${C_RESET:-}"
  else
    printf '%s[%s] %s\n' "$ts" "$tag" "$*"
  fi
}

log::info()    { _log::emit "${C_BLUE:-}"  "INFO"  "$*"; }
log::warn()    { _log::emit "${C_YELLOW:-}" "WARN"  "$*" >&2; }
log::error()   { _log::emit "${C_RED:-}"   "ERROR" "$*" >&2; }
log::success() { _log::emit "${C_GREEN:-}" " OK "  "$*"; }
log::debug()   {
  [[ "${CLI_COVE_DEBUG:-0}" == "1" ]] || return 0
  _log::emit "${C_GRAY:-}" "DEBUG" "$*" >&2
}
