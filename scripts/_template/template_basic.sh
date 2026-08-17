#!/bin/bash
#
# @title: 基础模板（零依赖）
# @desc: 不依赖任何公共 lib，演示脱离菜单也能独立运行的最简写法
# @order: 999

set -euo pipefail

main() {
  echo "这是一个最简单的示例脚本。"
  echo "当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
  echo "复制此文件作为新脚本的起点："
  echo "  cp scripts/_template/template_basic.sh scripts/<分类>/<新脚本>.sh"
}

main "$@"
