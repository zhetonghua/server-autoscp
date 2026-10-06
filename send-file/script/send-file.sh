#!/usr/bin/env bash
#
# send-file.sh - 定时通过 scp（SSH 密钥免密）向远程服务器传输固定文件
# 由 systemd timer (send-file.timer) 每 30 分钟调用一次
#
# 每次上传生成一个独立日志文件（含时间戳文件名），
# 记录发送方/接收方 IP、文件大小、MD5、传输耗时、结果等详细信息。
#
# 目录约定: 主文件夹 send-file/
#           send-file/script/  脚本与 unit 文件
#           send-file/file/    待发送文件
#
LOG_DIR="/var/log/send-file"       # 日志目录，需提前创建
LOG_KEEP_DAYS=30                   # 日志保留天数，超过自动清理；设为 0 关闭清理
# ========================================

# ---- 用户自定义配置 (优先级最高) ----
# /etc/send-file.conf 由 install.sh 生成, 也可随时手动编辑, 保存后下次触发即生效:
#   REMOTE_HOST(接收端,必填) / REMOTE_USER / REMOTE_PORT
#   LOCAL_FILE(待发送文件) / REMOTE_PATH / SENDER_IP(留空=自动识别发送端IP)
CONFIG_FILE="/etc/send-file.conf"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# ======== 传输配置 (内置默认值, 均可被 /etc/send-file.conf 覆盖) ========
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_PATH="${REMOTE_PATH:-/root/sendfile/}"
# REMOTE_HOST(接收端 IP)不设默认值, 必须由 /etc/send-file.conf 提供
# 待发送文件: 优先用配置文件指定的 LOCAL_FILE;
# 未指定时: 优先取默认文件 sendfile, 否则取目录下第一个非目录文件(排除 README)
if [[ -z "${LOCAL_FILE:-}" ]]; then
    if [[ -f /root/send-file/file/sendfile ]]; then
        LOCAL_FILE="/root/send-file/file/sendfile"
    else
        _F="$(ls -p /root/send-file/file/ 2>/dev/null | grep -v '/$' | grep -v '^README' | head -1)"
        [[ -n "$_F" ]] && LOCAL_FILE="/root/send-file/file/$_F"
    fi
fi
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

# ---- 识别发送端 / 接收端 IP ----
# 发送端 IP: 优先用配置指定的 SENDER_IP; 未指定时自动探测
# (依次尝试 hostname -I / ip route / 公网探测, 全失败则记 unknown)
if [[ -n "${SENDER_IP:-}" ]]; then
    LOCAL_IP="$SENDER_IP"
else
    LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
    [[ -z "$LOCAL_IP" ]] && LOCAL_IP="unknown"
fi

if [[ -z "${REMOTE_HOST:-}" ]]; then
    log "ERROR: 未配置接收端 IP (在 /etc/send-file.conf 设置 REMOTE_HOST)"
    exit 1
fi

log "========== 上传任务开始 =========="
log "发送方: ${LOCAL_IP} ($(hostname))"
log "接收方: ${REMOTE_HOST}"
log "目标路径: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}${REMOTE_PATH}"
log "本地文件: $LOCAL_FILE"

# ---- 文件检查 ----
if [[ -z "${LOCAL_FILE:-}" ]]; then
    log "ERROR: 未指定待发送文件 (在 /etc/send-file.conf 配置 LOCAL_FILE, 或将文件放入 /root/send-file/file/)"
    exit 1
fi
if [[ ! -f "$LOCAL_FILE" ]]; then
    log "ERROR: 本地文件不存在: $LOCAL_FILE"
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
