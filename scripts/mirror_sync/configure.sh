#!/bin/bash
#
# @title: 配置镜像同步路径
# @desc: 查看/修改 mirror-sync 的存储目录、服务名、导出目录等配置
# @order: 1

set -euo pipefail

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

if [[ ! -f "$LIB_DIR/mirror_sync.sh" ]]; then
  log::error "缺少 $LIB_DIR/mirror_sync.sh，无法运行"
  exit 1
fi
# shellcheck source=/dev/null
source "$LIB_DIR/mirror_sync.sh"

# key|提示文案|默认值
_CONFIG_ITEMS=(
  "NPM_STORAGE_DIR|Verdaccio storage 目录路径|/opt/verdaccio/storage"
  "NPM_SERVICE_NAME|Verdaccio 的 systemd 服务名（用于导入完成后的重启提示）|verdaccio"
  "PYTHON_SERVER_DIR|Devpi server-dir 路径|/opt/devpi/server"
  "PYTHON_SERVICE_NAME|Devpi 的 systemd 服务名（用于导入完成后的重启提示）|devpi-server"
  "EXPORT_OUTPUT_DIR|导出数据包存放目录|$HOME/mirror-exports"
)

main() {
  log::info "配置文件: $(mirror_sync::config_path)"
  echo

  local item key prompt fallback current input
  for item in "${_CONFIG_ITEMS[@]}"; do
    IFS='|' read -r key prompt fallback <<< "$item"
    current="$(mirror_sync::config_get "$key" "$fallback")"
    read -rp "$prompt [$current]: " input
    input="${input:-$current}"
    mirror_sync::config_set "$key" "$input"
  done

  echo
  log::success "配置已保存"
}

main "$@"
