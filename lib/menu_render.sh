#!/bin/bash
#
# menu_render.sh - 分类菜单 / 脚本菜单的两级导航与脚本执行
#
# 依赖: ui_backend.sh, menu_scan.sh, log.sh（均由 main.bash 预先 source）

[[ -n "${_CLI_COVE_MENU_RENDER_SH:-}" ]] && return
_CLI_COVE_MENU_RENDER_SH=1

menu_render::_run_script() {
  local script_path="$1" title="$2"

  clear
  printf '=== %s ===\n\n' "$title"
  bash "$script_path"
  local rc=$?
  echo
  if [[ $rc -ne 0 ]]; then
    log::warn "脚本执行失败，退出码: $rc"
  else
    log::success "脚本执行完成。"
  fi
  read -rp "按回车键返回菜单..." _
}

# menu_render::_script_menu <scripts_dir> <category>
# 返回 0: 用户执行了一个脚本（调用方应继续显示脚本菜单）
# 返回 1: 用户取消/ESC，或该分类为空（调用方应返回分类菜单）
menu_render::_script_menu() {
  local scripts_dir="$1" category="$2"

  local -a paths=()
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] && paths+=("$p")
  done < <(menu_scan::list_scripts_in_category "$scripts_dir" "$category")

  if [[ ${#paths[@]} -eq 0 ]]; then
    ui::msgbox "提示" "该分类下暂无脚本。"
    return 1
  fi

  local -a menu_args=()
  local i=1 title desc
  for p in "${paths[@]}"; do
    menu_scan::parse_metadata "$p"
    title="$META_TITLE"
    desc="$META_DESC"
    if [[ -n "$desc" ]]; then
      menu_args+=("$i" "$title - $desc")
    else
      menu_args+=("$i" "$title")
    fi
    ((i++))
  done

  local choice
  choice="$(ui::menu "$(menu_scan::category_title "$category")" \
    "输入过滤，方向键选择，回车确认，ESC 返回上一级" \
    "${menu_args[@]}")"
  local rc=$?
  if [[ $rc -ne 0 || -z "$choice" ]]; then
    return 1
  fi

  local idx=$((choice - 1))
  local selected="${paths[$idx]}"
  menu_scan::parse_metadata "$selected"
  menu_render::_run_script "$selected" "$META_TITLE"
  return 0
}

# menu_render::main_loop <scripts_dir>
menu_render::main_loop() {
  local scripts_dir="$1"
  local -a categories=()
  local cat

  while true; do
    categories=()
    while IFS= read -r cat; do
      [[ -n "$cat" ]] && categories+=("$cat")
    done < <(menu_scan::list_categories "$scripts_dir")

    if [[ ${#categories[@]} -eq 0 ]]; then
      ui::msgbox "提示" "scripts/ 目录下暂无任何分类/脚本。"
      return
    fi

    local -a menu_args=()
    local i=1
    for cat in "${categories[@]}"; do
      menu_args+=("$i" "$(menu_scan::category_title "$cat")")
      ((i++))
    done

    local choice
    choice="$(ui::menu "cli-cove" \
      "输入过滤，方向键选择，回车确认，ESC 退出" \
      "${menu_args[@]}")"
    local rc=$?
    if [[ $rc -ne 0 || -z "$choice" ]]; then
      return
    fi

    local idx=$((choice - 1))
    local selected_category="${categories[$idx]}"

    while menu_render::_script_menu "$scripts_dir" "$selected_category"; do
      :
    done
  done
}
