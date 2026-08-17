#!/bin/bash
#
# colors.sh - 颜色常量与终端支持检测

[[ -n "${_CLI_COVE_COLORS_SH:-}" ]] && return
_CLI_COVE_COLORS_SH=1

readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_BLUE='\033[0;34m'
readonly C_GRAY='\033[0;90m'

# color::supported
# 输出终端是否支持颜色（stdout 为 tty 且 TERM 不是 dumb）
color::supported() {
  [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]
}
