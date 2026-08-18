#!/bin/bash
#
# self_install.sh - 首次运行自动把 cli-cove 装进 PATH
#
# 效果: ~/.local/bin/cli-cove -> main.bash 的 symlink，之后可直接输入
# `cli-cove` 启动菜单。幂等且自愈：仓库路径变了、symlink 被删了，下次
# 运行都会自动修正；已经正确就什么也不做、不打印任何东西。
# 设 CLI_COVE_SKIP_SELF_INSTALL=1 可整体跳过（自动化/CI 场景用）。

[[ -n "${_CLI_COVE_SELF_INSTALL_SH:-}" ]] && return
_CLI_COVE_SELF_INSTALL_SH=1

# self_install::_is_in_path <dir>
# <dir> 是否已出现在当前 $PATH 中（按 : 切分逐段精确匹配）
self_install::_is_in_path() {
  local dir="$1" entry
  local IFS=':'
  for entry in $PATH; do
    [[ "$entry" == "$dir" ]] && return 0
  done
  return 1
}

# self_install::_rc_file_for_shell
# 根据 $SHELL 选一个合适的 rc 文件路径（不保证文件已存在）
self_install::_rc_file_for_shell() {
  local home="${CLI_COVE_HOME_OVERRIDE:-$HOME}"
  case "$(basename -- "${SHELL:-}")" in
    zsh)  printf '%s/.zshrc\n' "$home" ;;
    bash) printf '%s/.bashrc\n' "$home" ;;
    *)    printf '%s/.profile\n' "$home" ;;
  esac
}

# self_install::ensure <main_bash_path>
self_install::ensure() {
  [[ "${CLI_COVE_SKIP_SELF_INSTALL:-0}" == "1" ]] && return 0

  local main_bash="$1"
  local home="${CLI_COVE_HOME_OVERRIDE:-$HOME}"
  local bin_dir="${CLI_COVE_BIN_DIR:-$home/.local/bin}"
  local target="$bin_dir/cli-cove"

  if [[ -L "$target" ]] && [[ "$(readlink "$target")" == "$main_bash" ]]; then
    return 0
  fi

  if ! mkdir -p "$bin_dir" 2>/dev/null || ! ln -sf "$main_bash" "$target" 2>/dev/null; then
    log::warn "自动安装 cli-cove 命令失败（$target），可忽略，不影响当前使用。"
    return 1
  fi
  log::success "已将 cli-cove 命令安装到 $target"

  if self_install::_is_in_path "$bin_dir"; then
    return 0
  fi

  local rc_file
  rc_file="$(self_install::_rc_file_for_shell)"
  local export_line="export PATH=\"$bin_dir:\$PATH\""
  if [[ ! -f "$rc_file" ]] || ! grep -qF "$export_line" "$rc_file" 2>/dev/null; then
    printf '\n# added by cli-cove self_install\n%s\n' "$export_line" >> "$rc_file"
  fi
  log::warn "$bin_dir 不在 PATH 中，已追加到 $rc_file，请执行 'source $rc_file' 或重开终端后即可直接使用 cli-cove 命令。"
}
