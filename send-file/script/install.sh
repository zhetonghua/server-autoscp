#!/usr/bin/env bash
#
# install.sh - server-autoscp 一键安装脚本
#
# 唯一部署方式: 所有脚本和发送文件均从 GitHub 仓库拉取, 无需 clone、无需本地文件
#
# 交互式安装:
#   curl -fsSL https://raw.githubusercontent.com/zhetonghua/server-autoscp/main/send-file/script/install.sh | sudo bash
#
# 非交互模式 (脚本化批量部署, 注意 -s -- 传参方式):
#   curl -fsSL https://raw.githubusercontent.com/zhetonghua/server-autoscp/main/send-file/script/install.sh | \
#       sudo bash -s -- --host 1.2.3.4 --user root --port 22 \
#       --file /root/send-file/sendfile/sendfile --path /root/send-file/receivefile/ --yes
#
set -euo pipefail

REPO_BASE="https://raw.githubusercontent.com/zhetonghua/server-autoscp/main"
RAW_SCRIPT="$REPO_BASE/send-file/script"     # 脚本文件 raw 路径
RAW_FILE="$REPO_BASE/send-file/sendfile"     # 默认发送文件 raw 路径

# ---------- 输出工具 ----------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗] ERROR: $*${NC}" >&2; exit 1; }
step()  { echo -e "\n${CYAN}========== $* ==========${NC}"; }

# ---------- 参数解析 (非交互模式) ----------
CFG_HOST="" CFG_USER="root" CFG_PORT="22" CFG_FILE="" CFG_PATH="" CFG_SENDER="" ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) CFG_HOST="$2"; shift 2 ;;
        --user) CFG_USER="$2"; shift 2 ;;
        --port) CFG_PORT="$2"; shift 2 ;;
        --file) CFG_FILE="$2"; shift 2 ;;
        --path) CFG_PATH="$2"; shift 2 ;;
        --sender) CFG_SENDER="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=true; shift ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        *) die "未知参数: $1 (看 --help)" ;;
    esac
done

# ============ main ============
# 所有逻辑包在 main 中, 最后一行才调用。
# 原因: curl|bash 管道模式下 bash 边读边执行, 当执行到末尾的 main 调用时
# 整个脚本已从管道读完, 此时再把 stdin 切到 /dev/tty 才安全——
# 若在脚本中部就切换 stdin, bash 连脚本本身的剩余内容都读不到, 表现为卡死。
main() {

# ---------- 前置检查 ----------
step "前置检查"

[[ $EUID -eq 0 ]] || die "请用 root 运行: sudo bash install.sh"

# curl|bash 管道模式下 stdin 不是终端, 切到 tty 以便交互 (此时脚本已全部读完, 安全)
if [[ ! -t 0 && -r /dev/tty ]]; then
    exec 0</dev/tty
fi

for cmd in scp ssh systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: $cmd"
done

info "环境检查通过"

# ---------- 准备目录结构 ----------
step "准备目录结构 (收发两端框架一致: sendfile + receivefile + script)"

mkdir -p /root/send-file/script /root/send-file/sendfile /root/send-file/receivefile

# 从 GitHub 拉取默认发送文件 sendfile (统一只走仓库拉取)
DEFAULT_FILE=""
if curl -fsSL --max-time 120 "$RAW_FILE/sendfile" -o /root/send-file/sendfile/sendfile 2>/dev/null \
    || curl -fsSL --max-time 120 "${RAW_FILE/main/master}/sendfile" -o /root/send-file/sendfile/sendfile 2>/dev/null; then
    info "已从 GitHub 拉取默认发送文件 sendfile"
else
    warn "未获取到默认发送文件 (可稍后手动放入 /root/send-file/sendfile/)"
fi

# 默认传输对象: 优先 sendfile/sendfile, 否则发送端文件区第一个非目录文件 (排除 README)
if [[ -f /root/send-file/sendfile/sendfile ]]; then
    DEFAULT_FILE="/root/send-file/sendfile/sendfile"
    info "默认发送文件: $DEFAULT_FILE ($(du -h "$DEFAULT_FILE" 2>/dev/null | cut -f1))"
else
    DEFAULT_FILE="$(ls -p /root/send-file/sendfile/ 2>/dev/null | grep -v '/$' | grep -v '^README' | head -1)"
    [[ -n "$DEFAULT_FILE" ]] && DEFAULT_FILE="/root/send-file/sendfile/$DEFAULT_FILE"
fi

info "目录就绪: 发送端 /root/send-file/sendfile/ | 接收端 /root/send-file/receivefile/"

# ---------- 交互式收集配置 ----------
step "收集传输配置"

ask() {  # ask "提示语" "默认值" -> 结果存 REPLY
    local prompt="$1" default="$2" input
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " input
        REPLY="${input:-$default}"
    else
        read -r -p "$prompt: " input
        REPLY="$input"
    fi
}

# 自动识别发送端 IP (用户可在交互中覆盖或用 --sender 指定)
DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$DETECTED_IP" ]] && DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[[ -z "$DETECTED_IP" ]] && DETECTED_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
[[ -z "$DETECTED_IP" ]] && DETECTED_IP="unknown"

if [[ -z "$CFG_SENDER" ]]; then
    if [[ "$DETECTED_IP" != "unknown" ]]; then
        ask "发送端 IP (回车=自动识别: $DETECTED_IP)" "$DETECTED_IP"
    else
        ask "发送端 IP (未能自动识别, 请手动输入)" ""
    fi
    CFG_SENDER="$REPLY"
fi
info "发送端 IP: $CFG_SENDER"

if [[ -z "$CFG_HOST" ]]; then
    while true; do
        ask "目标服务器 IP 或域名" ""
        [[ -n "$REPLY" ]] && { CFG_HOST="$REPLY"; break; }
        warn "目标服务器不能为空"
    done
fi

if [[ -z "$CFG_FILE" ]]; then
    while true; do
        ask "本地要发送的文件完整路径" "$DEFAULT_FILE"
        [[ -n "$REPLY" ]] && { CFG_FILE="$REPLY"; break; }
        warn "文件路径不能为空"
    done
fi

[[ -n "$CFG_USER" ]] || { ask "目标服务器用户名" "root"; CFG_USER="$REPLY"; }
[[ -n "$CFG_PORT" ]] || { ask "SSH 端口" "22"; CFG_PORT="$REPLY"; }
[[ -n "$CFG_PATH" ]] || { ask "目标服务器存放路径" "/root/send-file/receivefile/"; CFG_PATH="$REPLY"; }
[[ "$CFG_PATH" == */ ]] || CFG_PATH="$CFG_PATH/"   # 统一以 / 结尾表示目录

[[ -f "$CFG_FILE" ]] || die "本地文件不存在: $CFG_FILE (请先确认路径)"

echo "----------------------------------------"
echo "  发送端   : $CFG_SENDER ($(hostname))"
echo "  接收端   : $CFG_HOST"
echo "  发送文件 : $CFG_FILE ($(du -h "$CFG_FILE" | cut -f1))"
echo "  目标路径 : ${CFG_USER}@${CFG_HOST}:${CFG_PORT}${CFG_PATH}"
echo "  定时     : 每 30 分钟一次 (systemd timer)"
echo "----------------------------------------"
if [[ "$ASSUME_YES" != true ]]; then
    ask "确认以上配置并开始安装?" "y"
    [[ "$REPLY" =~ ^[Yy] ]] || die "已取消"
fi

# ---------- SSH 密钥免密配置 ----------
step "配置 SSH 密钥免密"

SSH_KEY_FILE="$HOME/.ssh/id_ed25519"

if [[ ! -f "$SSH_KEY_FILE" && ! -f "$HOME/.ssh/id_rsa" ]]; then
    info "未发现 SSH 密钥，生成 ed25519 密钥对 (passphrase 留空, 定时任务必需)..."
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY_FILE" -q
    info "密钥已生成: $SSH_KEY_FILE"
else
    [[ -f "$SSH_KEY_FILE" ]] && info "已存在密钥: $SSH_KEY_FILE" || info "已存在密钥: $HOME/.ssh/id_rsa"
fi

ssh_test() {
    ssh -p "$CFG_PORT" -o BatchMode=yes -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        "${CFG_USER}@${CFG_HOST}" true 2>/dev/null
}

if ssh_test; then
    info "免密登录已生效"
else
    warn "免密未配置，现在安装公钥到目标服务器 (需输入对方密码, 仅此一次)"
    if command -v ssh-copy-id >/dev/null 2>&1; then
        ssh-copy-id -p "$CFG_PORT" -o StrictHostKeyChecking=accept-new "${CFG_USER}@${CFG_HOST}"
    else
        # 无 ssh-copy-id 的系统手动追加公钥
        cat "${SSH_KEY_FILE}.pub" | ssh -p "$CFG_PORT" -o StrictHostKeyChecking=accept-new \
            "${CFG_USER}@${CFG_HOST}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    fi
    ssh_test || die "免密配置失败，请检查密码/网络后重试"
    info "免密登录配置成功"
fi

# 确保接收目录存在
ssh -p "$CFG_PORT" -o BatchMode=yes "${CFG_USER}@${CFG_HOST}" "mkdir -p '$CFG_PATH'"
info "接收方目录已就绪: $CFG_PATH"

# ---------- 获取并安装文件 ----------
step "安装文件"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fetch() {  # 从 GitHub 拉取脚本文件到 $TMP_DIR
    local f="$1"
    curl -fsSL "$RAW_SCRIPT/$f" -o "$TMP_DIR/$f" \
        || curl -fsSL "${RAW_SCRIPT/main/master}/$f" -o "$TMP_DIR/$f" \
        || die "下载失败: $f (请检查网络或仓库地址)"
}

fetch send-file.sh
fetch send-file.service
fetch send-file.timer
fetch install.sh   # install.sh 自身也落一份到服务器, 便于以后重跑/升级

# 生成用户配置文件 (发送文件等参数由用户自定义, 改配置无需动脚本)
cat > /etc/send-file.conf << EOF
# send-file 用户配置 - 由 install.sh 生成, 可随时手动编辑, 下次触发即生效
SENDER_IP="${CFG_SENDER}"     # 发送端 IP (留空则每次自动识别)
REMOTE_HOST="${CFG_HOST}"     # 接收端 IP (必填)
REMOTE_USER="${CFG_USER}"
REMOTE_PORT="${CFG_PORT}"
LOCAL_FILE="${CFG_FILE}"      # 待发送文件 (留空则自动取 /root/send-file/sendfile/ 下第一个文件)
REMOTE_PATH="${CFG_PATH}"
EOF
chmod 644 /etc/send-file.conf

install -m 755 "$TMP_DIR/send-file.sh" /usr/local/bin/send-file.sh
install -m 644 "$TMP_DIR/send-file.service" /etc/systemd/system/send-file.service
install -m 644 "$TMP_DIR/send-file.timer" /etc/systemd/system/send-file.timer
install -m 755 "$TMP_DIR/install.sh" /root/send-file/script/install.sh
mkdir -p /var/log/send-file

info "传输脚本 -> /usr/local/bin/send-file.sh"
info "服务单元 -> /etc/systemd/system/send-file.service"
info "定时单元 -> /etc/systemd/system/send-file.timer"
info "安装器   -> /root/send-file/script/install.sh (便于以后重跑)"
info "日志目录 -> /var/log/send-file/"
info "用户配置 -> /etc/send-file.conf (改发送文件/目标地址: 编辑此文件即可)"

# ---------- 启用定时任务 ----------
step "启用定时任务"

systemctl daemon-reload
systemctl enable --now send-file.timer
info "send-file.timer 已启用 (每 30 分钟触发)"

# ---------- 首次运行验证 ----------
step "首次运行验证"

if systemctl start send-file.service; then
    sleep 1
    LOG_FILE="$(ls -t /var/log/send-file/upload_*.log 2>/dev/null | head -1)"
    echo -e "---- 本次上传日志 ----"
    tail -n 12 "$LOG_FILE" 2>/dev/null || journalctl -u send-file.service -n 12 --no-pager
    if grep -q "SUCCESS" "$LOG_FILE" 2>/dev/null; then
        info "首次传输成功！部署完成 🎉"
    else
        warn "首次运行未确认成功，请查看上方日志"
    fi
else
    warn "首次运行失败，排查命令:"
    echo "  journalctl -u send-file.service -n 30 --no-pager"
    echo "  tail -n 20 /var/log/send-file/upload_*.log"
fi

echo ""
step "部署摘要"
systemctl list-timers send-file.timer --no-pager | head -3
echo ""
echo "  查看日志   : tail -n 20 /var/log/send-file/upload_*.log"
echo "  清空日志   : rm -f /var/log/send-file/upload_*.log"
echo "  下次触发   : systemctl list-timers send-file.timer"
echo "  手动传输   : systemctl start send-file.service"
echo "  停用任务   : systemctl disable --now send-file.timer"
echo "  卸载       : systemctl disable --now send-file.timer &&"
echo "                rm -f /usr/local/bin/send-file.sh /etc/systemd/system/send-file.{service,timer} &&"
echo "                systemctl daemon-reload"

}

main "$@"
# main 内部可能把 stdin 切到 /dev/tty, 必须显式 exit,
# 否则 bash 会继续从 tty 等待输入 (表现为执行完不退出)
exit $?
