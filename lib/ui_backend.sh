#!/bin/bash
#
# ui_backend.sh - 菜单/提示框封装
#
# 优先使用 fzf（模糊过滤 + 方向键）；未安装 fzf 时自动降级为纯 bash
# 数字编号菜单（read -rp 循环），保证任何装了 bash 4+ 的机器都能跑起来。

[[ -n "${_CLI_COVE_UI_BACKEND_SH:-}" ]] && return
_CLI_COVE_UI_BACKEND_SH=1

# ui::menu <title> <text> <tag1> <item1> [...]
# 选中: 打印选中的 tag 到 stdout，返回 0
# 取消（ESC/Ctrl-C/q）或无匹配项: 不打印内容，返回非 0
ui::menu() {
  local title="$1" text="$2"
  shift 2

  if command -v fzf >/dev/null 2>&1; then
    ui::_menu_fzf "$title" "$text" "$@"
  else
    ui::_menu_plain "$title" "$text" "$@"
  fi
}

ui::_menu_fzf() {
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

# 未安装 fzf 时的兜底实现：打印编号列表，读取用户输入的编号。
# 菜单文字/提示一律写到 stderr，stdout 只用于返回选中的 tag，
# 这样调用方用 choice="$(ui::menu ...)" 捕获时不会把菜单本身也捕获进去。
ui::_menu_plain() {
  local title="$1" text="$2"
  shift 2

  local -a tags=() items=()
  while [[ $# -gt 0 ]]; do
    tags+=("$1")
    items+=("$2")
    shift 2
  done

  local input i
  while true; do
    {
      printf '\n=== %s ===\n%s\n' "$title" "$text"
      for i in "${!items[@]}"; do
        printf '%2d) %s\n' "$((i + 1))" "${items[$i]}"
      done
    } >&2

    if ! read -rp "请输入编号 (q 取消): " input; then
      return 1
    fi

    case "$input" in
      q|Q) return 1 ;;
      '') continue ;;
    esac

    if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#items[@]} )); then
      printf '%s\n' "${tags[$((input - 1))]}"
      return 0
    fi

    printf '无效输入，请重试。\n' >&2
  done
}

# ui::msgbox <title> <text>
ui::msgbox() {
  local title="$1" text="$2"
  printf '\n=== %s ===\n%s\n\n' "$title" "$text"
  read -rp "按回车键继续..." _
}
