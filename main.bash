#!/bin/bash
#
# cli-cove 入口程序
# 流程: 依赖检查 -> 扫描 scripts/ -> 两级菜单导航循环
set -uo pipefail

_resolve_self_dir() {
  local source="${BASH_SOURCE[0]}"
  while [[ -h "$source" ]]; do
    local dir
    dir="$(cd -P "$(dirname -- "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname -- "$source")" >/dev/null 2>&1 && pwd
}

ROOT_DIR="$(_resolve_self_dir)"
LIB_DIR="$ROOT_DIR/lib"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# shellcheck source=lib/colors.sh
source "$LIB_DIR/colors.sh"
# shellcheck source=lib/log.sh
source "$LIB_DIR/log.sh"
# shellcheck source=lib/die.sh
source "$LIB_DIR/die.sh"
# shellcheck source=lib/deps.sh
source "$LIB_DIR/deps.sh"
# shellcheck source=lib/ui_backend.sh
source "$LIB_DIR/ui_backend.sh"
# shellcheck source=lib/menu_scan.sh
source "$LIB_DIR/menu_scan.sh"
# shellcheck source=lib/menu_render.sh
source "$LIB_DIR/menu_render.sh"

main() {
  if ! deps::check_ui_backend; then
    log::warn "未检测到 fzf，将使用纯文本数字菜单（体验有限，建议安装 fzf）。"
    deps::print_install_hint
  fi

  if [[ ! -d "$SCRIPTS_DIR" ]]; then
    die "scripts 目录不存在: $SCRIPTS_DIR"
  fi

  menu_render::main_loop "$SCRIPTS_DIR"

  clear
  log::info "已退出 cli-cove。"
}

main "$@"
