#!/bin/bash
#
# ui_backend.sh - 基于 fzf 的菜单/提示框封装
#
# 依赖: fzf 命令（由 deps::check_ui_backend 探测）

[[ -n "${_CLI_COVE_UI_BACKEND_SH:-}" ]] && return
_CLI_COVE_UI_BACKEND_SH=1

# ui::menu <title> <text> <tag1> <item1> [...]
# 选中: 打印选中的 tag 到 stdout，返回 0
# 取消（ESC/Ctrl-C）或无匹配项: 不打印内容，返回非 0
ui::menu() {
  local title="$1" text="$2"
  shift 2

  local -a lines=()
  while [[ $# -gt 0 ]]; do
    lines+=("$1"$'\t'"$2")
    shift 2
  done

  local selected
  selected="$(printf '%s\n' "${lines[@]}" | fzf \
    --prompt="${title} > " \
    --header="$text" \
    --delimiter=$'\t' \
    --with-nth=2.. \
    --height=90% \
    --reverse \
    --border)"
  local rc=$?

  if [[ $rc -eq 0 && -n "$selected" ]]; then
    printf '%s\n' "${selected%%$'\t'*}"
    return 0
  fi
  return 1
}

# ui::msgbox <title> <text>
ui::msgbox() {
  local title="$1" text="$2"
  printf '\n=== %s ===\n%s\n\n' "$title" "$text"
  read -rp "按回车键继续..." _
}
