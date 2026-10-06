#!/usr/bin/env bash
#
# send-file.sh - 定时通过 scp（SSH 密钥免密）向远程服务器传输固定文件
# 由 systemd timer (send-file.timer) 每 30 分钟调用一次
#
# 每次上传生成一个独立日志文件（含时间戳文件名），
# 记录文件大小、MD5、传输耗时、结果等详细信息。
#
LOG_DIR="/var/log/send-file"       # 日志目录，需提前创建
LOG_KEEP_DAYS=30                   # 日志保留天数，超过自动清理；设为 0 关闭清理
# ========================================

# ======== 传输配置 ========
REMOTE_USER="root"                     # 目标服务器用户名
REMOTE_HOST="IP"          # 目标服务器 IP
REMOTE_PORT="22"                       # SSH 端口，非 22 端口务必修改
LOCAL_FILE="/root/send-file/send-file-name"  # 本地要发送的文件（固定路径）
REMOTE_PATH="/root/send-file/"          # 目标服务器存放路径
# 密钥路径: 默认 ~/.ssh/id_ed25519 或 id_rsa，非默认位置请取消下行注释并修改
# SSH_KEY="/root/.ssh/id_backup_key"
# ========================================

LOG_TAG="send-file"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new)
[[ -n "${SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$SSH_KEY")

# ---- 初始化本次日志文件 ----
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"   # 无权限时降级到 /tmp
fi
LOG_FILE="$LOG_DIR/upload_$(date '+%Y%m%d_%H%M%S').log"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

log "========== 上传任务开始 =========="
log "目标: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}${REMOTE_PATH}"
log "本地文件: $LOCAL_FILE"

# ---- 文件检查 ----
if [[ ! -f "$LOCAL_FILE" ]]; then
    log "ERROR: 本地文件不存在"
    exit 1
fi

FILE_SIZE=$(stat -c '%s' "$LOCAL_FILE" 2>/dev/null || stat -f '%z' "$LOCAL_FILE")
FILE_MTIME=$(date -r "$LOCAL_FILE" '+%F %T')
FILE_MD5=$(md5sum "$LOCAL_FILE" 2>/dev/null | awk '{print $1}' || md5 -q "$LOCAL_FILE" 2>/dev/null || echo "N/A")

FILE_SIZE_MB=$(awk "BEGIN{printf \"%.2f\", ${FILE_SIZE}/1048576}")
log "文件大小: ${FILE_SIZE} bytes (${FILE_SIZE_MB} MB)"
log "文件修改时间: $FILE_MTIME"
log "本地 MD5: $FILE_MD5"

# ---- 传输 ----
log "开始 scp 传输..."
START_TS=$(date +%s)

if scp -P "$REMOTE_PORT" -p "${SSH_OPTS[@]}" \
    "$LOCAL_FILE" "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}" >>"$LOG_FILE" 2>&1; then
    END_TS=$(date +%s)
    DURATION=$((END_TS - START_TS))
    RATE="N/A"
    if (( DURATION > 0 )); then
        RATE=$(awk "BEGIN{printf \"%.2f\", ${FILE_SIZE}/${DURATION}/1048576}")
    fi
    log "传输成功"
    log "耗时: ${DURATION} 秒 (平均速率 ${RATE} MB/s)"
    log "结果: SUCCESS"
    RC=0
else
    RC=$?
    END_TS=$(date +%s)
    log "ERROR: 传输失败, exit code=$RC (1=连接/认证失败, 2=传输中断)"
    log "结果: FAILED"
    log "耗时: $((END_TS - START_TS)) 秒"
fi

# ---- 清理过期日志 ----
if (( LOG_KEEP_DAYS > 0 )); then
    find "$LOG_DIR" -name 'upload_*.log' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
fi

log "========== 上传任务结束 (exit=$RC) =========="
exit $RC
