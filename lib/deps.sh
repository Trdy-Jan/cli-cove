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
# 探测可用的菜单后端（whiptail 优先，其次 dialog）。
# 可用 CLI_COVE_UI_BACKEND 环境变量强制指定其中之一。
# 成功: 打印后端命令名到 stdout，返回 0
# 失败: 返回 1，不打印内容
deps::check_ui_backend() {
  if [[ -n "${CLI_COVE_UI_BACKEND:-}" ]]; then
    if deps::has_cmd "$CLI_COVE_UI_BACKEND"; then
      printf '%s\n' "$CLI_COVE_UI_BACKEND"
      return 0
    fi
    return 1
  fi

  if deps::has_cmd whiptail; then
    printf 'whiptail\n'
    return 0
  fi

  if deps::has_cmd dialog; then
    printf 'dialog\n'
    return 0
  fi

  return 1
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
      printf '请运行: sudo apt update && sudo apt install -y whiptail\n'
      ;;
    *rhel*|*fedora*|*centos*)
      printf '请运行: sudo dnf install -y newt   # whiptail 包含在 newt 包中\n'
      ;;
    *arch*)
      printf '请运行: sudo pacman -S dialog\n'
      ;;
    *alpine*)
      printf '请运行: sudo apk add dialog\n'
      ;;
    *)
      printf '未能识别当前发行版，请安装 whiptail 或 dialog 中的任意一个，例如：\n'
      printf '  Debian/Ubuntu: sudo apt install -y whiptail\n'
      printf '  RHEL/Fedora:   sudo dnf install -y newt\n'
      printf '  Arch:          sudo pacman -S dialog\n'
      printf '  Alpine:        sudo apk add dialog\n'
      ;;
  esac
}
