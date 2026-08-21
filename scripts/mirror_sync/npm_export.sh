#!/bin/bash
#
# @title: 导出 NPM 镜像（Verdaccio）
# @desc: 全量/增量导出 Verdaccio storage 目录为离线数据包（含版本与完整性校验信息）
# @order: 10

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
EXCLUDES=(".verdaccio-db.json" ".sinopia-db.json" "*.lock")

main() {
  [[ "${1:-}" == "--reconfigure" ]] && {
    mirror_sync::config_set NPM_STORAGE_DIR ""
    mirror_sync::config_set EXPORT_OUTPUT_DIR ""
  }

  local storage_dir output_dir
  storage_dir="$(mirror_sync::require_config NPM_STORAGE_DIR "Verdaccio storage 目录路径" "/opt/verdaccio/storage")"
  if [[ ! -d "$storage_dir" ]]; then
    log::error "目录不存在: $storage_dir"
    exit 1
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

  log::info "扫描 storage 目录: $storage_dir"
  local current_manifest="$work_dir/current.sha256"
  mirror_sync::build_manifest "$storage_dir" "${EXCLUDES[@]}" > "$current_manifest"

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
    cp -p -- "$storage_dir/$relpath" "$pkg_dir/files/$relpath"
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

  # 只有打包成功后才推进导出状态，避免失败的导出污染下一次增量的基准
  cp -- "$current_manifest" "$last_manifest"
  mirror_sync::kv_set "$state_file" CHAIN_ID "$chain_id"
  mirror_sync::kv_set "$state_file" SEQUENCE "$sequence"

  log::success "导出完成: $out_file"
  log::info "文件数: $file_count，序号: $sequence，链: ${chain_id:0:8}..."
}

main "$@"
