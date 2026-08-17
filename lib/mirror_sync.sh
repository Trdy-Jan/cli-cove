#!/bin/bash
#
# mirror_sync.sh - 软件包镜像离线导出/导入的通用逻辑
# 详见 docs/superpowers/specs/2026-08-17-mirror-sync-design.md

[[ -n "${_CLI_COVE_MIRROR_SYNC_SH:-}" ]] && return
_CLI_COVE_MIRROR_SYNC_SH=1

# mirror_sync::state_root
# 输出: mirror-sync 状态/配置根目录（可用 CLI_COVE_STATE_DIR 覆盖，便于测试）
mirror_sync::state_root() {
  printf '%s/mirror-sync\n' "${CLI_COVE_STATE_DIR:-$HOME/.cli-cove}"
}

# mirror_sync::config_path
mirror_sync::config_path() {
  printf '%s/config.env\n' "$(mirror_sync::state_root)"
}

# mirror_sync::kv_get <file> <key> [default]
# 从纯文本 KEY=value 文件中读取 key 的值；文件或 key 不存在时输出 default（可省略）
mirror_sync::kv_get() {
  local file="$1" key="$2" default="${3:-}"
  [[ -f "$file" ]] || { printf '%s\n' "$default"; return 0; }
  local line
  line="$(grep "^${key}=" "$file" | tail -n1)"
  if [[ -z "$line" ]]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "${line#*=}"
  fi
}

# mirror_sync::kv_set <file> <key> <value>
# 更新/新增 KEY=value 文件中的一个 key（原子写：临时文件 + mv）
mirror_sync::kv_set() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname -- "$file")"
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  if [[ -f "$file" ]]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$file"
}

# mirror_sync::config_get <key> [default]
mirror_sync::config_get() {
  mirror_sync::kv_get "$(mirror_sync::config_path)" "$1" "${2:-}"
}

# mirror_sync::config_set <key> <value>
mirror_sync::config_set() {
  mirror_sync::kv_set "$(mirror_sync::config_path)" "$1" "$2"
}

# mirror_sync::require_config <key> <提示文案> <默认值>
# 若 key 已配置则直接返回其值；否则交互式提示（bring-your-own default）并写入配置
mirror_sync::require_config() {
  local key="$1" prompt="$2" fallback="$3"
  local current
  current="$(mirror_sync::config_get "$key")"
  if [[ -n "$current" ]]; then
    printf '%s\n' "$current"
    return 0
  fi
  local input
  read -rp "$prompt [$fallback]: " input >&2
  input="${input:-$fallback}"
  mirror_sync::config_set "$key" "$input"
  printf '%s\n' "$input"
}

# mirror_sync::build_manifest <src_dir> [exclude_glob ...]
# 输出: src_dir 下所有普通文件的 sha256sum 兼容清单（<sha256>  <相对路径>），按相对路径排序
# exclude_glob 可匹配完整相对路径或文件名（用于跳过运行时索引/锁文件）
mirror_sync::build_manifest() {
  local src_dir="$1"
  shift
  local -a excludes=("$@")
  local f relpath base excluded pattern

  find "$src_dir" -type f | sort | while IFS= read -r f; do
    relpath="${f#"$src_dir"/}"
    base="$(basename -- "$relpath")"
    excluded=0
    for pattern in "${excludes[@]}"; do
      [[ -z "$pattern" ]] && continue
      if [[ "$relpath" == $pattern || "$base" == $pattern ]]; then
        excluded=1
        break
      fi
    done
    [[ "$excluded" -eq 1 ]] && continue
    printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$relpath"
  done
}

# mirror_sync::diff_manifest <new_manifest_file> <old_manifest_file>
# 输出: new_manifest_file 中相对 old_manifest_file 而言"新增或 hash 变化"的相对路径
# old_manifest_file 不存在时等价于输出 new_manifest_file 的全部路径
mirror_sync::diff_manifest() {
  local new_file="$1" old_file="$2"
  local -A old_hash=()
  local line hash path

  if [[ -f "$old_file" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      hash="${line:0:64}"
      path="${line:66}"
      old_hash["$path"]="$hash"
    done < "$old_file"
  fi

  [[ -f "$new_file" ]] || return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    hash="${line:0:64}"
    path="${line:66}"
    if [[ "${old_hash[$path]+set}" != "set" || "${old_hash[$path]}" != "$hash" ]]; then
      printf '%s\n' "$path"
    fi
  done < "$new_file"
}

# mirror_sync::gen_chain_id
# 输出一个新的、大概率唯一的链标识
mirror_sync::gen_chain_id() {
  printf '%s-%s-%s\n' "$(date +%s%N)" "$$" "$RANDOM"
}

# mirror_sync::package_id <backend> <chain_id> <sequence>
mirror_sync::package_id() {
  printf '%s-%s-seq%s\n' "$1" "$2" "$3"
}

# mirror_sync::verify_package <package_dir>
# 在 package_dir 内执行 sha256sum -c CHECKSUMS.sha256；成功返回 0，任何一行不匹配返回非 0
mirror_sync::verify_package() {
  local package_dir="$1"
  ( cd "$package_dir" && sha256sum -c CHECKSUMS.sha256 )
}

# mirror_sync::check_import_order <meta_env_file> <import_state_file>
# 输出以下之一: init / new_chain / ok / reject:chain_mismatch / reject:order_mismatch
mirror_sync::check_import_order() {
  local meta_file="$1" state_file="$2"
  local chain_id sequence base_sequence last_chain_id last_seq

  chain_id="$(mirror_sync::kv_get "$meta_file" CHAIN_ID)"
  sequence="$(mirror_sync::kv_get "$meta_file" SEQUENCE)"
  base_sequence="$(mirror_sync::kv_get "$meta_file" BASE_SEQUENCE)"
  last_chain_id="$(mirror_sync::kv_get "$state_file" LAST_CHAIN_ID)"
  last_seq="$(mirror_sync::kv_get "$state_file" LAST_APPLIED_SEQUENCE)"

  if [[ -z "$base_sequence" ]]; then
    # 全量包
    if [[ -z "$last_chain_id" ]]; then
      printf 'init\n'
    elif [[ "$last_chain_id" != "$chain_id" ]]; then
      printf 'new_chain\n'
    else
      printf 'init\n'
    fi
    return 0
  fi

  # 增量包
  if [[ "$chain_id" != "$last_chain_id" ]]; then
    printf 'reject:chain_mismatch\n'
  elif [[ "$base_sequence" != "$last_seq" ]]; then
    printf 'reject:order_mismatch\n'
  else
    printf 'ok\n'
  fi
}

# mirror_sync::is_duplicate_import <package_id> <applied_ids_file>
# 返回 0 表示该 package_id 已经导入过，1 表示还没有
mirror_sync::is_duplicate_import() {
  local package_id="$1" applied_ids_file="$2"
  [[ -f "$applied_ids_file" ]] || return 1
  grep -qxF "$package_id" "$applied_ids_file"
}

# mirror_sync::record_import <package_id> <chain_id> <sequence> <import_state_file> <applied_ids_file>
# 更新导入状态并把 package_id 追加进已导入列表
mirror_sync::record_import() {
  local package_id="$1" chain_id="$2" sequence="$3" state_file="$4" applied_ids_file="$5"
  mirror_sync::kv_set "$state_file" LAST_CHAIN_ID "$chain_id"
  mirror_sync::kv_set "$state_file" LAST_APPLIED_SEQUENCE "$sequence"
  mkdir -p "$(dirname -- "$applied_ids_file")"
  printf '%s\n' "$package_id" >> "$applied_ids_file"
}
