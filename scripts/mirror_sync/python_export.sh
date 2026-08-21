#!/bin/bash
#
# @title: 导出 Python 镜像（Devpi）
# @desc: 全量/增量导出 Devpi server-dir 为离线数据包（含版本与完整性校验信息）
# @order: 30

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
EXCLUDES=()

# Devpi 的落盘状态由内部数据库支撑，不能安全地按任意文件粒度做增量拷贝。
# 这里先用 devpi-server 自带的 --export 生成一份自洽的文件系统快照，
# 再把快照目录当作"存储目录"交给通用流水线处理（详见设计文档"后端适配说明"）。
_dump_snapshot() {
  local deploy_type="$1" service_name="$2" compose_dir="$3" server_dir="$4" snapshot_dir="$5"

  if [[ "$deploy_type" == "docker-compose" ]]; then
    if ! deps::has_cmd docker; then
      log::error "找不到 docker 命令，无法通过 docker compose 生成导出快照"
      exit 1
    fi
  elif ! deps::has_cmd devpi-server; then
    log::error "找不到 devpi-server 命令，无法生成导出快照"
    exit 1
  fi

  log::warn "导出前请确保 devpi-server 服务已停止（docker-compose 部署可执行: docker compose stop $service_name），否则可能得到不一致的快照"
  local confirm
  read -rp "devpi-server 是否已停止？[y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log::warn "已取消导出"
    exit 1
  fi

  if [[ "$deploy_type" == "docker-compose" ]]; then
    log::warn "docker-compose 模式会以 --entrypoint devpi-server 覆盖镜像原始入口，若镜像 entrypoint 脚本包含权限初始化等逻辑将被跳过，需按实际镜像验证"
  fi
  log::info "执行 devpi-server --export（具体参数需按实际 Devpi 版本核对）..."
  mirror_sync::devpi_export "$deploy_type" "$service_name" "$compose_dir" "$server_dir" "$snapshot_dir"
}

main() {
  [[ "${1:-}" == "--reconfigure" ]] && {
    mirror_sync::config_set PYTHON_SERVER_DIR ""
    mirror_sync::config_set PYTHON_DEPLOY_TYPE ""
    mirror_sync::config_set PYTHON_SERVICE_NAME ""
    mirror_sync::config_set PYTHON_COMPOSE_DIR ""
    mirror_sync::config_set EXPORT_OUTPUT_DIR ""
  }

  local server_dir deploy_type service_name compose_dir output_dir
  server_dir="$(mirror_sync::require_config PYTHON_SERVER_DIR "Devpi server-dir 路径" "/opt/devpi/server")"
  if [[ ! -d "$server_dir" ]]; then
    log::error "目录不存在: $server_dir"
    exit 1
  fi
  deploy_type="$(mirror_sync::require_config PYTHON_DEPLOY_TYPE "Devpi 部署方式：systemd 或 docker-compose" "systemd")"
  service_name="$(mirror_sync::require_config PYTHON_SERVICE_NAME "Devpi 服务名（systemd 单元名，或 docker-compose 里的 service 名）" "devpi-server")"
  compose_dir=""
  if [[ "$deploy_type" == "docker-compose" ]]; then
    compose_dir="$(mirror_sync::require_config PYTHON_COMPOSE_DIR "Devpi 的 docker-compose.yml 所在目录" "")"
    if [[ ! -d "$compose_dir" ]]; then
      log::error "目录不存在: $compose_dir"
      exit 1
    fi
  fi
  output_dir="$(mirror_sync::require_config EXPORT_OUTPUT_DIR "导出数据包存放目录" "$HOME/mirror-exports")"
  mkdir -p "$output_dir/$BACKEND"

  local state_dir state_file last_manifest
  state_dir="$(mirror_sync::state_root)/$BACKEND"
  mkdir -p "$state_dir"
  state_file="$state_dir/state.env"
  last_manifest="$state_dir/last_checksums.sha256"

  local chain_id sequence base_sequence force_full
  { read -r chain_id; read -r sequence; read -r base_sequence; read -r force_full; } \
    < <(mirror_sync::resolve_export_plan "$state_file")

  # 不用 local：EXIT trap 在 main 返回之后才触发，此时函数局部变量已被销毁，
  # 若 work_dir 是 local，set -u 下会报 unbound variable。
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT

  local snapshot_dir="$work_dir/devpi_snapshot"
  _dump_snapshot "$deploy_type" "$service_name" "$compose_dir" "$server_dir" "$snapshot_dir"

  log::info "扫描导出快照..."
  local current_manifest="$work_dir/current.sha256"
  mirror_sync::build_manifest "$snapshot_dir" "${EXCLUDES[@]}" > "$current_manifest"

  local included="$work_dir/included.txt"
  if [[ "$force_full" -eq 1 ]]; then
    mirror_sync::diff_manifest "$current_manifest" "$work_dir/does_not_exist.sha256" > "$included"
  else
    mirror_sync::diff_manifest "$current_manifest" "$last_manifest" > "$included"
  fi

  if [[ ! -s "$included" ]]; then
    log::warn "没有新增或变化的文件，无需导出"
    exit 0
  fi

  local pkg_dir="$work_dir/package" relpath
  mkdir -p "$pkg_dir/files"
  while IFS= read -r relpath; do
    mkdir -p "$pkg_dir/files/$(dirname -- "$relpath")"
    cp -p -- "$snapshot_dir/$relpath" "$pkg_dir/files/$relpath"
  done < "$included"

  local package_id file_count total_bytes created_at source_host
  package_id="$(mirror_sync::package_id "$BACKEND" "$chain_id" "$sequence")"
  file_count="$(wc -l < "$included" | tr -d ' ')"
  total_bytes="$(du -sb "$pkg_dir/files" 2>/dev/null | awk '{print $1}')"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  source_host="$(hostname)"

  cat > "$pkg_dir/meta.env" <<EOF
BACKEND=$BACKEND
CHAIN_ID=$chain_id
SEQUENCE=$sequence
BASE_SEQUENCE=$base_sequence
PACKAGE_ID=$package_id
CREATED_AT=$created_at
SOURCE_HOST=$source_host
FILE_COUNT=$file_count
TOTAL_BYTES=$total_bytes
EOF

  log::info "生成完整性校验清单..."
  (
    cd "$pkg_dir"
    : > CHECKSUMS.sha256
    { printf '%s\n' meta.env; find files -type f | sort; } | while IFS= read -r f; do
      sha256sum "$f" >> CHECKSUMS.sha256
    done
  )

  local ts chain_short out_file
  ts="$(date +%Y%m%d_%H%M%S)"
  chain_short="${chain_id:0:8}"
  out_file="$output_dir/$BACKEND/${BACKEND}-${chain_short}-seq$(printf '%02d' "$sequence")-${ts}.tar"
  tar -C "$pkg_dir" -cf "$out_file" .

  cp -- "$current_manifest" "$last_manifest"
  mirror_sync::kv_set "$state_file" CHAIN_ID "$chain_id"
  mirror_sync::kv_set "$state_file" SEQUENCE "$sequence"

  log::success "导出完成: $out_file"
  log::info "文件数: $file_count，序号: $sequence，链: ${chain_id:0:8}..."
}

main "$@"
