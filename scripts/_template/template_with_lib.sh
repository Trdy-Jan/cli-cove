#!/bin/bash
#
# @title: 带公共库模板
# @desc: 演示健壮地 source 公共 lib、使用统一日志函数、以及简单的用户确认交互
# @order: 999

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

if [[ -f "$LIB_DIR/colors.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/colors.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/log.sh"
else
  # 找不到公共 lib 时的最小降级，保证脚本仍可独立运行
  log::info()    { echo "[INFO] $*"; }
  log::warn()    { echo "[WARN] $*" >&2; }
  log::error()   { echo "[ERROR] $*" >&2; }
  log::success() { echo "[ OK ] $*"; }
fi

main() {
  log::info "开始执行示例任务..."

  read -rp "是否继续？[y/N] " reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    log::warn "用户取消，退出。"
    exit 1
  fi

  log::success "任务执行完成。"
}

main "$@"
