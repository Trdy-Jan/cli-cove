#!/bin/bash
# disc_split.sh —— 将一个文件夹内的文件/子文件夹按指定容量拆分到多个子文件夹中
#
# 特性：
#   - 支持 G/M/K 容量输入（例：23G、700M、4.7G）
#   - FFD 贪心分配（按大小降序装箱，尽量塞满每张盘）
#   - 子文件夹作为整体移动
#   - 单项超过容量时使用 tar + split 分卷打包
#   - 分卷打包成功后删除原文件（节省空间）
#
# 还原方法（通用）：
#   把某一项的所有 .partXXXX 文件收集到同一目录后执行：
#       cat <name>.part* | tar -xf -
#
# @title: 拆分文件夹用于刻录多张光盘
# @desc: 按容量将文件夹内容 FFD 装箱拆分为多个子文件夹
# @order: 5

set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LIB_DIR="$SCRIPT_DIR/../../lib"

if [[ -f "$LIB_DIR/colors.sh" ]]; then
  # shellcheck source=/dev/null
  source "$LIB_DIR/colors.sh"
  # shellcheck source=/dev/null
  source "$LIB_DIR/log.sh"
else
  # 找不到公共 lib 时的最小降级，保证脚本仍可独立运行
  log::info()    { echo "[INFO] $*"; }
  log::warn()    { echo "[WARN] $*" >&2; }
  log::error()   { echo "[ERROR] $*" >&2; }
  log::success() { echo "[ OK ] $*"; }
fi

# ========== 1. 源文件夹 ==========
read -rp "请输入源文件夹路径: " SRC_DIR
SRC_DIR="${SRC_DIR%/}"

if [[ ! -e "$SRC_DIR" ]]; then
    log::error "路径不存在 -> $SRC_DIR"; exit 1
fi
if [[ ! -d "$SRC_DIR" ]]; then
    log::error "该路径不是文件夹 -> $SRC_DIR"; exit 1
fi
if [[ -z "$(ls -A "$SRC_DIR")" ]]; then
    log::error "文件夹为空 -> $SRC_DIR"; exit 1
fi

# ========== 2. 容量 ==========
read -rp "请输入每个分卷的容量上限 (支持 G/M/K，例如 23G、700M、4.7G): " CAP_INPUT

parse_size() {
    local s
    s=$(echo "$1" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
    local num unit
    if [[ "$s" =~ ^([0-9]+(\.[0-9]+)?)([KMGT]?)B?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
    else
        echo "ERR"; return
    fi
    case "$unit" in
        ""|"B") awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        "K")    awk -v n="$num" 'BEGIN{printf "%d", n*1024}' ;;
        "M")    awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024}' ;;
        "G")    awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024*1024}' ;;
        "T")    awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024*1024*1024}' ;;
    esac
}

CAP_BYTES=$(parse_size "$CAP_INPUT")
if [[ "$CAP_BYTES" == "ERR" || -z "$CAP_BYTES" || "$CAP_BYTES" -le 0 ]]; then
    log::error "容量格式不正确"; exit 1
fi

human_size() {
    awk -v b="$1" 'BEGIN{
        split("B KB MB GB TB",u," "); i=1;
        while(b>=1024 && i<5){b/=1024; i++}
        printf "%.2f%s", b, u[i]
    }'
}

echo
echo "源文件夹  : $SRC_DIR"
echo "每卷容量  : $(human_size "$CAP_BYTES")"
echo

# ========== 3. 扫描顶层条目 ==========
declare -a NAMES SIZES
TOTAL_BYTES=0

while IFS= read -r -d '' item; do
    name=$(basename "$item")
    size=$(du -sb "$item" 2>/dev/null | awk '{print $1}')
    [[ -z "$size" ]] && { log::warn "无法获取大小，跳过 -> $item"; continue; }
    NAMES+=("$name")
    SIZES+=("$size")
    TOTAL_BYTES=$((TOTAL_BYTES + size))
done < <(find "$SRC_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)

ITEM_COUNT=${#NAMES[@]}
echo "顶层条目数: $ITEM_COUNT"
echo "总大小    : $(human_size "$TOTAL_BYTES")"
echo

# ========== 4. 识别超大项 ==========
declare -a OVERSIZE_IDX
for i in "${!NAMES[@]}"; do
    if (( ${SIZES[$i]} > CAP_BYTES )); then
        OVERSIZE_IDX+=("$i")
    fi
done

if (( ${#OVERSIZE_IDX[@]} > 0 )); then
    log::warn "以下条目超过单卷容量，将使用 tar+split 分卷打包"
    for i in "${OVERSIZE_IDX[@]}"; do
        printf "   - %s  (%s)\n" "${NAMES[$i]}" "$(human_size "${SIZES[$i]}")"
    done
    echo
fi

# ========== 5. FFD 贪心分配（排除超大项） ==========
mapfile -t ORDER < <(
    for i in "${!SIZES[@]}"; do
        skip=0
        for o in "${OVERSIZE_IDX[@]}"; do
            [[ "$o" == "$i" ]] && { skip=1; break; }
        done
        (( skip == 0 )) && echo "$i ${SIZES[$i]}"
    done | sort -k2 -n -r | awk '{print $1}'
)

declare -a BIN_USED BIN_ITEMS

place_item() {
    local idx=$1 sz=${SIZES[$1]} b
    for b in "${!BIN_USED[@]}"; do
        if (( ${BIN_USED[$b]} + sz <= CAP_BYTES )); then
            BIN_USED[$b]=$(( ${BIN_USED[$b]} + sz ))
            BIN_ITEMS[$b]="${BIN_ITEMS[$b]} $idx"
            return
        fi
    done
    local new_b=${#BIN_USED[@]}
    BIN_USED[$new_b]=$sz
    BIN_ITEMS[$new_b]="$idx"
}

for idx in "${ORDER[@]}"; do
    place_item "$idx"
done

# ========== 6. 展示方案 ==========
BASE_NAME=$(basename "$SRC_DIR")
PARENT_DIR=$(dirname "$SRC_DIR")

oversize_vol_count() {
    awk -v s="$1" -v c="$CAP_BYTES" 'BEGIN{
        n = s / c;
        if (n == int(n)) print int(n); else print int(n)+1;
    }'
}

NORMAL_BINS=${#BIN_USED[@]}
EST_EXTRA=0
for i in "${OVERSIZE_IDX[@]}"; do
    EST_EXTRA=$(( EST_EXTRA + $(oversize_vol_count "${SIZES[$i]}") ))
done

log::info "分配方案"
vol_num=0
for b in "${!BIN_ITEMS[@]}"; do
    vol_num=$((vol_num + 1))
    echo
    echo "[${BASE_NAME}_${vol_num}]  已用 $(human_size "${BIN_USED[$b]}") / $(human_size "$CAP_BYTES")"
    for idx in ${BIN_ITEMS[$b]}; do
        printf "   - %s  (%s)\n" "${NAMES[$idx]}" "$(human_size "${SIZES[$idx]}")"
    done
done

for i in "${OVERSIZE_IDX[@]}"; do
    n=$(oversize_vol_count "${SIZES[$i]}")
    echo
    echo "[分卷打包 ~${n}卷 估算]  ${NAMES[$i]}  (tar+split, 实际卷数以打包结果为准)"
done

EST_TOTAL=$((NORMAL_BINS + EST_EXTRA))
echo
echo "预计共 ${EST_TOTAL} 个分卷（含超大项估算），位于 $PARENT_DIR"
log::warn "分卷打包成功后，原文件将被删除以节省空间"
echo

read -rp "确认执行吗？(y/N): " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { log::warn "已取消。"; exit 0; }

# ========== 7. 执行 ==========
VOL_COUNTER=0

# 7a. 普通分卷
for b in "${!BIN_ITEMS[@]}"; do
    VOL_COUNTER=$((VOL_COUNTER + 1))
    vol_dir="${PARENT_DIR}/${BASE_NAME}_${VOL_COUNTER}"
    mkdir -p "$vol_dir"
    for idx in ${BIN_ITEMS[$b]}; do
        log::info "移动: ${NAMES[$idx]}  ->  ${vol_dir}/"
        mv -- "${SRC_DIR}/${NAMES[$idx]}" "$vol_dir/"
    done
done

# 7b. 超大项：统一用 tar + split
# 单片取容量的 99%，留余量防止文件系统开销把分卷撑爆
SPLIT_SIZE=$(awk -v c="$CAP_BYTES" 'BEGIN{printf "%d", c*0.99}')

# tar+split 或后续移动失败时，清理残留在 PARENT_DIR 下的分卷临时文件
trap 'rm -f -- "${PARENT_DIR}"/.disc_split_tmp_*_part_* 2>/dev/null' EXIT

for i in "${OVERSIZE_IDX[@]}"; do
    name="${NAMES[$i]}"
    src="${SRC_DIR}/${name}"

    echo
    log::info "分卷打包: $name"
    log::info "  tar + split 中..."

    tmp_prefix="${PARENT_DIR}/.disc_split_tmp_${name}_part_"

    # set -e 下用 pipefail 捕获 tar 失败
    ( set -o pipefail; cd "$SRC_DIR" && tar -cf - -- "$name" | \
        split -b "$SPLIT_SIZE" -d -a 4 - "$tmp_prefix" )

    restore_hint="# 还原方法：把所有 ${name}.part* 复制到同一目录后执行：
#   cat ${name}.part* | tar -xf -"

    k=0
    for part in "$tmp_prefix"*; do
        VOL_COUNTER=$((VOL_COUNTER + 1))
        vol_dir="${PARENT_DIR}/${BASE_NAME}_${VOL_COUNTER}"
        mkdir -p "$vol_dir"
        part_name="${name}.part$(printf '%04d' $k)"
        log::info "  -> ${vol_dir}/${part_name}"
        mv -- "$part" "${vol_dir}/${part_name}"
        printf "%s\n" "$restore_hint" > "${vol_dir}/README_restore_${name}.txt"
        k=$((k + 1))
    done

    log::info "  分卷完成，删除原始: $src"
    rm -rf -- "$src"
done

echo
log::success "全部完成。"
echo "生成的分卷: ${BASE_NAME}_1 .. ${BASE_NAME}_${VOL_COUNTER}  (位于 ${PARENT_DIR})"
if [[ -z "$(ls -A "$SRC_DIR" 2>/dev/null)" ]]; then
    log::info "源文件夹已清空，可手动删除: $SRC_DIR"
fi
