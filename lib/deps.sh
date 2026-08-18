#!/bin/bash
#
# deps.sh - 外部命令依赖探测

[[ -n "${_CLI_COVE_DEPS_SH:-}" ]] && return
_CLI_COVE_DEPS_SH=1

# deps::has_cmd <command>
deps::has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# deps::check_ui_backend
# 探测菜单所需的 fzf 是否可用。
# 成功: 返回 0；失败: 返回 1
deps::check_ui_backend() {
  deps::has_cmd fzf
}

# deps::print_install_hint
# 根据 /etc/os-release 识别发行版，打印针对性的安装命令
deps::print_install_hint() {
  local os_id="" os_id_like=""
  if [[ -r /etc/os-release ]]; then
    local ID="" ID_LIKE=""
    # shellcheck source=/dev/null
    source /etc/os-release
    os_id="${ID:-}"
    os_id_like="${ID_LIKE:-}"
  fi

  case "$os_id $os_id_like" in
    *debian*|*ubuntu*)
      printf '请运行: sudo apt update && sudo apt install -y fzf\n'
      ;;
    *rhel*|*fedora*|*centos*)
      printf '请运行: sudo dnf install -y fzf\n'
      ;;
    *arch*)
      printf '请运行: sudo pacman -S fzf\n'
      ;;
    *alpine*)
      printf '请运行: sudo apk add fzf\n'
      ;;
    *)
      printf '未能识别当前发行版，请安装 fzf，例如：\n'
      printf '  Debian/Ubuntu: sudo apt install -y fzf\n'
      printf '  RHEL/Fedora:   sudo dnf install -y fzf\n'
      printf '  Arch:          sudo pacman -S fzf\n'
      printf '  Alpine:        sudo apk add fzf\n'
      ;;
  esac
}
