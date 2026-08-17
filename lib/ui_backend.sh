#!/bin/bash
#
# ui_backend.sh - 封装 whiptail 与 dialog 的差异，对外只暴露统一接口
#
# 依赖: 全局变量 CLI_COVE_UI_BACKEND（由 deps::check_ui_backend 探测得出，
# 在 main.bash 中 export，值为 "whiptail" 或 "dialog"）

[[ -n "${_CLI_COVE_UI_BACKEND_SH:-}" ]] && return
_CLI_COVE_UI_BACKEND_SH=1

# ui::menu <title> <text> <height> <width> <menu_height> <tag1> <item1> [...]
# 选中: 打印选中的 tag 到 stdout，返回 0
# 取消/ESC: 不打印内容，返回非 0（whiptail/dialog 对 Cancel 用 1、对 ESC 用 255，
# 这里统一按“非 0 即取消”处理，调用方不需要关心具体数值）
ui::menu() {
  local title="$1" text="$2" height="$3" width="$4" menu_height="$5"
  shift 5
  local backend="${CLI_COVE_UI_BACKEND:?CLI_COVE_UI_BACKEND 未设置}"
  local choice
  choice="$("$backend" --title "$title" --menu "$text" "$height" "$width" "$menu_height" "$@" 3>&1 1>&2 2>&3)"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    printf '%s\n' "$choice"
  fi
  return $rc
}

# ui::msgbox <title> <text> [height=10] [width=60]
ui::msgbox() {
  local title="$1" text="$2" height="${3:-10}" width="${4:-60}"
  local backend="${CLI_COVE_UI_BACKEND:?CLI_COVE_UI_BACKEND 未设置}"
  "$backend" --title "$title" --msgbox "$text" "$height" "$width" 3>&1 1>&2 2>&3
}
