#!/bin/bash
#
# @title: 检查网络连通性
# @desc: 依次 ping 默认网关、DNS 服务器与公网地址，报告连通性状态
# @order: 10

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

if [[ -f "$LIB_DIR/colors.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/colors.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/log.sh"
else
  log::info()    { echo "[INFO] $*"; }
  log::warn()    { echo "[WARN] $*" >&2; }
  log::error()   { echo "[ERROR] $*" >&2; }
  log::success() { echo "[ OK ] $*"; }
fi

_check() {
  local desc="$1" target="$2"
  if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
    log::success "$desc ($target) 可达"
    return 0
  fi
  log::error "$desc ($target) 不可达"
  return 1
}

main() {
  local gateway rc=0
  gateway="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"

  if [[ -n "$gateway" ]]; then
    _check "默认网关" "$gateway" || rc=1
  else
    log::warn "未能获取默认网关地址，跳过该项检查"
  fi

  _check "DNS 服务器" "8.8.8.8" || rc=1
  _check "公网地址" "www.baidu.com" || rc=1

  exit "$rc"
}

main "$@"
