#!/bin/bash
#
# @title: 导入 NPM 镜像（Verdaccio）
# @desc: 校验并导入离线数据包到本地 Verdaccio storage 目录（顺序检查、重复导入保护）
# @order: 20

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

BACKEND="npm"

main() {
  [[ "${1:-}" == "--reconfigure" ]] && {
    mirror_sync::config_set NPM_STORAGE_DIR ""
    mirror_sync::config_set NPM_DEPLOY_TYPE ""
    mirror_sync::config_set NPM_SERVICE_NAME ""
    mirror_sync::config_set NPM_COMPOSE_DIR ""
  }

  local storage_dir deploy_type service_name compose_dir
  storage_dir="$(mirror_sync::require_config NPM_STORAGE_DIR "Verdaccio storage 目录路径" "/opt/verdaccio/storage")"
  if [[ ! -d "$storage_dir" ]]; then
    log::error "目录不存在: $storage_dir"
    exit 1
  fi
  deploy_type="$(mirror_sync::require_config NPM_DEPLOY_TYPE "Verdaccio 部署方式：systemd 或 docker-compose" "systemd")"
  service_name="$(mirror_sync::require_config NPM_SERVICE_NAME "Verdaccio 服务名（systemd 单元名，或 docker-compose 里的 service 名）" "verdaccio")"
  compose_dir=""
  [[ "$deploy_type" == "docker-compose" ]] && \
    compose_dir="$(mirror_sync::require_config NPM_COMPOSE_DIR "Verdaccio 的 docker-compose.yml 所在目录" "")"

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
  case "$order_result" in
    init|ok) ;;
    new_chain)
      log::warn "检测到这是一条与本地记录不同的全新导出链（可能是导出端状态被重置后的全量导出）"
      local confirm
      read -rp "确认要以此全量包重新初始化本地导入状态吗？[y/N]: " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log::warn "已取消导入"
        exit 1
      fi
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

  local file_count
  file_count="$(find "$extract_dir/files" -type f | wc -l | tr -d ' ')"
  log::info "开始写入 $file_count 个文件到 $storage_dir"

  local f relpath dest
  find "$extract_dir/files" -type f | while IFS= read -r f; do
    relpath="${f#"$extract_dir"/files/}"
    dest="$storage_dir/$relpath"
    mkdir -p "$(dirname -- "$dest")"
    cp -p -- "$f" "$dest"
  done

  mirror_sync::record_import "$package_id" "$chain_id" "$sequence" "$import_state" "$applied_ids"

  log::success "导入完成（序号 $sequence，链 ${chain_id:0:8}...）"
  log::warn "请手动重启服务以确保立即生效: $(mirror_sync::restart_hint "$deploy_type" "$service_name" "$compose_dir")"
}

main "$@"
