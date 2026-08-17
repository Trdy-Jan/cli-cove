#!/bin/bash
#
# @title: 磁盘使用情况报告
# @desc: 展示各挂载点的磁盘使用率，超过阈值的挂载点会高亮提示
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

WARN_THRESHOLD=80

main() {
  log::info "磁盘使用情况（阈值: ${WARN_THRESHOLD}%）："
  echo

  local mount pcent usage
  while read -r mount pcent; do
    usage="${pcent%\%}"
    if [[ "$usage" =~ ^[0-9]+$ ]] && (( usage >= WARN_THRESHOLD )); then
      log::warn "$mount: $pcent"
    else
      echo "  $mount: $pcent"
    fi
  done < <(df -h --output=target,pcent 2>/dev/null | tail -n +2)
}

main "$@"
