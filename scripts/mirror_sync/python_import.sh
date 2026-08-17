#!/bin/bash
#
# @title: 导入 Python 镜像（Devpi）
# @desc: 校验并导入离线数据包到本地 Devpi server-dir（顺序检查、重复导入保护）
# @order: 40

set -euo pipefail

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

if [[ ! -f "$LIB_DIR/mirror_sync.sh" ]]; then
  log::error "缺少 $LIB_DIR/mirror_sync.sh，无法运行"
  exit 1
fi
# shellcheck source=/dev/null
source "$LIB_DIR/mirror_sync.sh"

BACKEND="python"

main() {
  [[ "${1:-}" == "--reconfigure" ]] && {
    mirror_sync::config_set PYTHON_SERVER_DIR ""
    mirror_sync::config_set PYTHON_SERVICE_NAME ""
  }

  local server_dir service_name
  server_dir="$(mirror_sync::require_config PYTHON_SERVER_DIR "Devpi server-dir 路径" "/opt/devpi/server")"
  service_name="$(mirror_sync::require_config PYTHON_SERVICE_NAME "Devpi 的 systemd 服务名" "devpi-server")"

  if ! deps::has_cmd devpi-server; then
    log::error "找不到 devpi-server 命令，无法完成导入"
    exit 1
  fi

  local state_dir
  state_dir="$(mirror_sync::state_root)/$BACKEND"
  mkdir -p "$state_dir"

  local log_file
  log_file="$state_dir/import_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee -a "$log_file") 2>&1
  log::info "本次导入日志: $log_file"

  local pkg_path
  read -rp "请输入待导入的离线数据包路径 (.tar): " pkg_path
  if [[ ! -f "$pkg_path" ]]; then
    log::error "文件不存在: $pkg_path"
    exit 1
  fi

  # 不用 local：EXIT trap 在 main 返回之后才触发，此时函数局部变量已被销毁，
  # 若 work_dir 是 local，set -u 下会报 unbound variable。
  local extract_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  extract_dir="$work_dir/extracted"
  mkdir -p "$extract_dir"
  tar -C "$extract_dir" -xf "$pkg_path"

  if [[ ! -f "$extract_dir/meta.env" || ! -f "$extract_dir/CHECKSUMS.sha256" ]]; then
    log::error "数据包格式不正确：缺少 meta.env 或 CHECKSUMS.sha256"
    exit 1
  fi

  log::info "校验数据包完整性..."
  if ! mirror_sync::verify_package "$extract_dir" > "$work_dir/verify.log" 2>&1; then
    log::error "完整性校验失败，拒绝导入。详情:"
    cat "$work_dir/verify.log" >&2
    exit 1
  fi
  log::success "完整性校验通过"

  local pkg_backend
  pkg_backend="$(mirror_sync::kv_get "$extract_dir/meta.env" BACKEND)"
  if [[ "$pkg_backend" != "$BACKEND" ]]; then
    log::error "数据包 backend 不匹配（期望 $BACKEND，实际 $pkg_backend）"
    exit 1
  fi

  local chain_id sequence package_id import_state applied_ids
  chain_id="$(mirror_sync::kv_get "$extract_dir/meta.env" CHAIN_ID)"
  sequence="$(mirror_sync::kv_get "$extract_dir/meta.env" SEQUENCE)"
  package_id="$(mirror_sync::kv_get "$extract_dir/meta.env" PACKAGE_ID)"
  import_state="$state_dir/import_state.env"
  applied_ids="$state_dir/applied_ids.list"

  if mirror_sync::is_duplicate_import "$package_id" "$applied_ids"; then
    log::warn "该数据包（$package_id）已经导入过，跳过"
    exit 0
  fi

  local order_result
  order_result="$(mirror_sync::check_import_order "$extract_dir/meta.env" "$import_state")"
  local reset_snapshot=0
  case "$order_result" in
    init) ;;
    ok) ;;
    new_chain)
      log::warn "检测到这是一条与本地记录不同的全新导出链（可能是导出端状态被重置后的全量导出）"
      local confirm
      read -rp "确认要以此全量包重新初始化本地导入状态吗？[y/N]: " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log::warn "已取消导入"
        exit 1
      fi
      reset_snapshot=1
      ;;
    reject:chain_mismatch)
      log::error "导入顺序错误：该增量包属于另一条导出链，请先导入正确链上的全量/增量包"
      exit 1
      ;;
    reject:order_mismatch)
      log::error "导入顺序错误：该增量包的前置序号与本地已导入的序号不衔接"
      exit 1
      ;;
    *)
      log::error "无法判断导入顺序（未知结果: $order_result）"
      exit 1
      ;;
  esac

  # Devpi 不支持直接把零散文件合并进已有 server-dir 的数据库；这里在本地维护一份
  # "当前合并快照"（累积应用过的全量+增量文件），每次导入都在这份快照上做覆盖式
  # 叠加，再整体喂给 devpi-server --import 落库。
  local snapshot_dir="$state_dir/current_snapshot"
  if [[ "$reset_snapshot" -eq 1 || "$order_result" == "init" ]]; then
    rm -rf "$snapshot_dir"
  fi
  mkdir -p "$snapshot_dir"

  local file_count f relpath dest
  file_count="$(find "$extract_dir/files" -type f | wc -l | tr -d ' ')"
  log::info "合并 $file_count 个文件到本地快照 $snapshot_dir"
  find "$extract_dir/files" -type f | while IFS= read -r f; do
    relpath="${f#"$extract_dir"/files/}"
    dest="$snapshot_dir/$relpath"
    mkdir -p "$(dirname -- "$dest")"
    cp -p -- "$f" "$dest"
  done

  log::warn "即将执行 devpi-server --import 落库，请确保 devpi-server 服务已停止"
  local confirm
  read -rp "devpi-server 是否已停止？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log::warn "已取消导入（本地合并快照已更新，可稍后重新运行完成落库）"
    exit 1
  fi

  log::info "执行 devpi-server --import（具体参数需按实际 Devpi 版本核对）..."
  devpi-server --serverdir="$server_dir" --import="$snapshot_dir"

  mirror_sync::record_import "$package_id" "$chain_id" "$sequence" "$import_state" "$applied_ids"

  log::success "导入完成（序号 $sequence，链 ${chain_id:0:8}...）"
  log::warn "请手动重启服务以确保立即生效: sudo systemctl restart $service_name"
}

main "$@"
