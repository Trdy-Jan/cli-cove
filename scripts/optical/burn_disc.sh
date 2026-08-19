#!/bin/bash
#===============================================================================
# 光盘刻录脚本 (DVD/BD Burning Script)
# 功能: 交互式刻录光盘，支持新建和追加模式
#===============================================================================
#
# @title: 刻录光盘 (DVD/BD)
# @desc: 交互式刻录光盘
# @order: 10

set -e  # 遇到错误立即退出

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

# ---------- 日志函数 ----------
# 终端输出走共享 log:: 函数（带颜色）；同时把纯文本行追加到持久化日志文件，
# 方便刻录失败后事后排查（刻录耗时长且是破坏性操作）。
LOG_FILE="/var/log/disc_burn_$(date +%Y%m%d_%H%M%S).log"

log_info()  { log::info  "$1"; printf '[INFO]  %s\n' "$1" >> "$LOG_FILE"; }
log_warn()  { log::warn  "$1"; printf '[WARN]  %s\n' "$1" >> "$LOG_FILE"; }
log_error() { log::error "$1"; printf '[ERROR] %s\n' "$1" >> "$LOG_FILE"; }
log_step()  { log::info  "==> $1"; printf '\n==> %s\n' "$1" >> "$LOG_FILE"; }

# ---------- 1. 权限检查 ----------
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 权限运行此脚本 (sudo $0)"
    exit 1
fi

# ---------- 2. 依赖检查与安装 ----------
log_step "检查依赖软件包"
REQUIRED_PKGS=("dvd+rw-tools" "genisoimage")
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    log_warn "缺少软件包: ${MISSING_PKGS[*]}"
    read -rp "是否自动安装? [Y/n]: " INSTALL_CONFIRM
    INSTALL_CONFIRM=${INSTALL_CONFIRM:-Y}
    if [[ "$INSTALL_CONFIRM" =~ ^[Yy]$ ]]; then
        apt update && apt install -y "${MISSING_PKGS[@]}"
    else
        log_error "依赖未安装，退出"
        exit 1
    fi
else
    log_info "所有依赖已安装"
fi

# ---------- 3. 检测光驱设备 ----------
log_step "检测光驱设备"

# 列出所有光驱设备
mapfile -t CDROM_DEVICES < <(lsblk -dno NAME,TYPE | awk '$2=="rom"{print "/dev/"$1}')

if [ ${#CDROM_DEVICES[@]} -eq 0 ]; then
    log_error "未检测到光驱设备，请检查硬件连接"
    lsblk
    exit 1
elif [ ${#CDROM_DEVICES[@]} -eq 1 ]; then
    DEVICE="${CDROM_DEVICES[0]}"
    log_info "检测到光驱: $DEVICE"
else
    log_info "检测到多个光驱:"
    for i in "${!CDROM_DEVICES[@]}"; do
        echo "  [$i] ${CDROM_DEVICES[$i]}"
    done
    read -rp "请选择光驱编号 [0]: " DEV_IDX
    DEV_IDX=${DEV_IDX:-0}
    DEVICE="${CDROM_DEVICES[$DEV_IDX]}"
fi

# 显示光盘信息
log_info "光盘信息:"
if ! dvd+rw-mediainfo "$DEVICE" 2>/dev/null | grep -E "Mounted Media|Media ID|Free Blocks|Disc status" | tee -a "$LOG_FILE"; then
    log_warn "无法读取光盘信息，请确认已放入可刻录光盘"
    read -rp "是否继续? [y/N]: " CONTINUE
    [[ ! "$CONTINUE" =~ ^[Yy]$ ]] && exit 1
fi

# ---------- 4. 选择刻录模式 ----------
log_step "选择刻录模式"
echo "  [1] 新建刻录 (-Z)  — 覆盖光盘，适用于空盘或重写盘"
echo "  [2] 追加刻录 (-M)  — 在已有内容后追加，适用于多段刻录"
read -rp "请选择模式 [1]: " BURN_MODE
BURN_MODE=${BURN_MODE:-1}

# ---------- 5. 输入源目录 ----------
log_step "指定源目录"
while true; do
    read -rp "请输入要刻录的目录路径: " SOURCE_DIR
    # 去除首尾空格和引号
    SOURCE_DIR=$(echo "$SOURCE_DIR" | sed -e 's/^["'\'' ]*//' -e 's/["'\'' ]*$//')

    if [ -z "$SOURCE_DIR" ]; then
        log_warn "路径不能为空"
        continue
    fi

    if [ ! -d "$SOURCE_DIR" ]; then
        log_error "目录不存在: $SOURCE_DIR"
        continue
    fi

    # 计算目录大小
    DIR_SIZE=$(du -sb "$SOURCE_DIR" | awk '{print $1}')
    DIR_SIZE_HUMAN=$(du -sh "$SOURCE_DIR" | awk '{print $1}')
    FILE_COUNT=$(find "$SOURCE_DIR" -type f | wc -l)

    log_info "目录: $SOURCE_DIR"
    log_info "大小: $DIR_SIZE_HUMAN ($FILE_COUNT 个文件)"

    # 容量警告(DVD 约 4.37 GB = 4694304000 bytes, DVD DL 约 8.5 GB)
    if [ "$DIR_SIZE" -gt 8547991552 ]; then
        log_error "目录大小超过 DVD±R DL 容量 (8.5 GB)，需要蓝光盘"
        read -rp "是否继续? [y/N]: " CONTINUE
        [[ ! "$CONTINUE" =~ ^[Yy]$ ]] && continue
    elif [ "$DIR_SIZE" -gt 4694304000 ]; then
        log_warn "目录大小超过普通 DVD 容量 (4.37 GB)，需要双层或蓝光盘"
        read -rp "是否继续? [y/N]: " CONTINUE
        [[ ! "$CONTINUE" =~ ^[Yy]$ ]] && continue
    fi
    break
done

# ---------- 6. Volume ID (仅新建模式需要) ----------
if [ "$BURN_MODE" = "1" ]; then
    log_step "设置 Volume ID (光盘卷标)"
    DEFAULT_VOL=$(printf '%s' "$(basename "$SOURCE_DIR")" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_' | cut -c1-32)
    read -rp "请输入 Volume ID [默认: $DEFAULT_VOL]: " VOLUME_ID
    VOLUME_ID=${VOLUME_ID:-$DEFAULT_VOL}

    # 校验: ISO 9660 卷标最长 32 字符，只允许 A-Z 0-9 _
    if [ ${#VOLUME_ID} -gt 32 ]; then
        log_warn "Volume ID 超过 32 字符，已截断"
        VOLUME_ID=${VOLUME_ID:0:32}
    fi
    log_info "Volume ID: $VOLUME_ID"
fi

# ---------- 7. 选择刻录速度 ----------
log_step "选择刻录速度"
echo "  建议速度参考:"
echo "    - DVD±R      : 4x (推荐) / 8x / 16x"
echo "    - DVD±R DL   : 2x / 4x (推荐)"
echo "    - BD-R       : 2x / 4x / 6x"
echo "    - 归档长期保存 : 建议 4x，成功率最高"
read -rp "请输入刻录速度 [默认 4]: " SPEED
SPEED=${SPEED:-4}

# 校验速度为正整数
if ! [[ "$SPEED" =~ ^[0-9]+$ ]] || [ "$SPEED" -lt 1 ]; then
    log_error "刻录速度必须为正整数"
    exit 1
fi

# ---------- 8. 刻录后选项 ----------
log_step "刻录后选项"
read -rp "刻录完成后是否校验数据? [y/N]: " VERIFY_CONFIRM
read -rp "刻录完成后是否弹出光盘? [Y/n]: " EJECT_CONFIRM
EJECT_CONFIRM=${EJECT_CONFIRM:-Y}

# ---------- 9. 确认信息 ----------
log_step "请确认刻录信息"
echo "  设备         : $DEVICE"
echo "  模式         : $([ "$BURN_MODE" = "1" ] && echo "新建 (-Z)" || echo "追加 (-M)")"
echo "  源目录       : $SOURCE_DIR"
echo "  数据大小     : $DIR_SIZE_HUMAN"
[ "$BURN_MODE" = "1" ] && echo "  Volume ID    : $VOLUME_ID"
echo "  刻录速度     : ${SPEED}x"
echo "  校验数据     : $([ "$VERIFY_CONFIRM" = "y" ] || [ "$VERIFY_CONFIRM" = "Y" ] && echo "是" || echo "否")"
echo "  刻录后弹出   : $([ "$EJECT_CONFIRM" = "Y" ] || [ "$EJECT_CONFIRM" = "y" ] && echo "是" || echo "否")"
echo ""
read -rp "确认开始刻录? [y/N]: " FINAL_CONFIRM
if [[ ! "$FINAL_CONFIRM" =~ ^[Yy]$ ]]; then
    log_warn "已取消刻录"
    exit 0
fi

# ---------- 10. 执行刻录 ----------
log_step "开始刻录 (开始时间: $(date '+%Y-%m-%d %H:%M:%S'))"
START_TIME=$(date +%s)

if [ "$BURN_MODE" = "1" ]; then
    # 新建刻录
    growisofs -speed="$SPEED" \
        -Z "$DEVICE" \
        -udf -R -J \
        -allow-limited-size \
        -V "$VOLUME_ID" \
        "$SOURCE_DIR" 2>&1 | tee -a "$LOG_FILE"
else
    # 追加刻录
    growisofs -speed="$SPEED" \
        -M "$DEVICE" \
        -udf -R -J \
        -allow-limited-size \
        "$SOURCE_DIR" 2>&1 | tee -a "$LOG_FILE"
fi

BURN_STATUS=${PIPESTATUS[0]}
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

if [ "$BURN_STATUS" -ne 0 ]; then
    log_error "刻录失败! 耗时: $((ELAPSED/60))分$((ELAPSED%60))秒"
    exit 1
fi

log_info "刻录成功! 耗时: $((ELAPSED/60))分$((ELAPSED%60))秒"

# ---------- 11. 数据校验 (可选) ----------
if [[ "$VERIFY_CONFIRM" =~ ^[Yy]$ ]]; then
    log_step "校验光盘数据"
    MOUNT_POINT="/mnt/disc_verify_$$"
    mkdir -p "$MOUNT_POINT"

    # 等待光盘就绪
    sleep 3

    if mount -o ro "$DEVICE" "$MOUNT_POINT" 2>/dev/null; then
        log_info "光盘已挂载到 $MOUNT_POINT"

        # 对比文件数量
        DISC_FILES=$(find "$MOUNT_POINT" -type f | wc -l)
        log_info "源目录文件数: $FILE_COUNT  光盘文件数: $DISC_FILES"

        if [ "$FILE_COUNT" -eq "$DISC_FILES" ]; then
            log_info "文件数量一致 ✓"
        else
            log_warn "文件数量不一致，请手动检查"
        fi

        umount "$MOUNT_POINT"
        rmdir "$MOUNT_POINT"
    else
        log_warn "无法挂载光盘进行校验"
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
fi

# ---------- 12. 弹出光盘 ----------
if [[ "$EJECT_CONFIRM" =~ ^[Yy]$ ]]; then
    log_step "弹出光盘"
    eject "$DEVICE" && log_info "光盘已弹出"
fi

log_info "全部操作完成! 日志已保存至: $LOG_FILE"
exit 0
