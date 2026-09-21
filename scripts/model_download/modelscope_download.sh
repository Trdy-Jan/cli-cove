#!/bin/bash
#
# @title: 下载 ModelScope 模型
# @desc: 输入 model_id 与保存路径，自动开始下载
# @order: 10

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

if [[ -f "$LIB_DIR/colors.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/colors.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/log.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/deps.sh"
else
  log::info()    { echo "[INFO] $*"; }
  log::warn()    { echo "[WARN] $*" >&2; }
  log::error()   { echo "[ERROR] $*" >&2; }
  log::success() { echo "[ OK ] $*"; }
  deps::has_cmd() { command -v "$1" >/dev/null 2>&1; }
fi

DEFAULT_BASE_DIR="$HOME/modelscope-models"

main() {
  if ! deps::has_cmd modelscope; then
    log::error "找不到 modelscope 命令，请先安装: pip install modelscope"
    exit 1
  fi

  local model_id
  while [[ -z "${model_id:-}" ]]; do
    read -rp "请输入 model_id（如 ATH-MaaS/OvisOCR2）: " model_id
    [[ -z "$model_id" ]] && log::warn "model_id 不能为空"
  done

  local default_dir save_dir
  default_dir="$DEFAULT_BASE_DIR/$model_id"
  read -rp "请输入保存位置 [$default_dir]: " save_dir
  save_dir="${save_dir:-$default_dir}"

  mkdir -p -- "$save_dir"

  log::info "开始下载 $model_id 到 $save_dir ..."
  if modelscope download --model "$model_id" --local_dir "$save_dir"; then
    log::success "下载完成: $save_dir"
  else
    log::error "下载失败（modelscope 退出码非 0）"
    exit 1
  fi
}

main "$@"
