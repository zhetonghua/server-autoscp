# Linux 服务器定时文件传输部署教程

> 基于 systemd timer + scp + SSH 密钥免密的定时传输方案
> 实战环境：ser4baewkrh9dqe（发送方）→ racknerd-d83d254 / 192.129.134.230（接收方）
> 传输文件：`/root/send-file/file/guangzhui`（约 2.8 GB），每 30 分钟一次，每次生成独立日志

---

## 方案架构

```
┌──────────────────────────────┐      每 30 分钟       ┌──────────────────────┐
│  发送方服务器                  │  ── scp (密钥免密) ──►  │  接收方服务器          │
│  ser4baewkrh9dqe              │     /root/sendfile/    │  racknerd-d83d254    │
│                               │                       │  192.129.134.230     │
│  /root/send-file/  (主目录)   │                       │                      │
│  ├─ script/  脚本与unit       │                       │  /root/sendfile/     │
│  └─ file/    待发送文件        │                       │    └─ guangzhui      │
│       └─ guangzhui            │                       │                      │
│  systemd timer 每30分钟触发    │                       │                      │
│  日志自动记录发送方/接收方 IP   │                       │                      │
└──────────────────────────────┘                       └──────────────────────┘
        │
        ▼
  /var/log/send-file/upload_YYYYMMDD_HHMMSS.log  （每次上传独立日志）
```

**目录结构约定（主文件夹 `send-file/`）：**

```
send-file/
├── script/              # 脚本目录
│   ├── send-file.sh     # 传输脚本（安装到 /usr/local/bin/）
│   ├── send-file.service
│   ├── send-file.timer
│   └── install.sh       # 一键安装器
└── file/                # 待发送文件目录
    └── guangzhui        # 要传输的文件
```

三个核心组件：

| 组件 | 文件 | 作用 |
|------|------|------|
| 传输脚本 | `/usr/local/bin/send-file.sh` | 执行 scp 传输 + 写详细日志 |
| 服务单元 | `/etc/systemd/system/send-file.service` | 告诉 systemd "执行什么" |
| 定时单元 | `/etc/systemd/system/send-file.timer` | 告诉 systemd "什么时候执行" |

**为什么选 systemd timer 而不是 crontab？** 日志进 journalctl 统一管理、支持错过后补跑（服务器关机错过的时间点开机立即补传）、`systemctl list-timers` 直接查看调度状态，比 crontab 更现代可控。

---

## 第一步：配置 SSH 密钥免密

定时任务运行时没有人在场输密码，所以必须先配好免密登录。

> ⚠️ **方向最容易搞错：谁发送，谁生成密钥。** 密钥对必须在**发送方**生成，再把公钥装到**接收方**。反着配等于白配。

### 1.1 在发送方生成密钥对

```bash
ssh-keygen -t ed25519
```

- `ssh-keygen`：密钥生成工具
- `-t ed25519`：指定算法。ed25519 是目前最推荐的算法——密钥短、验证快、安全性高

执行后会依次出现三个提问：

```
Enter file in which to save the key (/root/.ssh/id_ed25519):
```
**直接回车**。这是让你指定密钥的**保存路径**（不是密码！），回车表示用默认位置 `/root/.ssh/id_ed25519`。
> 🚨 实战踩坑：在这里输入了其他字符（比如当成密码输了），密钥就会被存到当前目录的乱名字文件里，后续 `ssh-copy-id` 会报 `No identities found`。

```
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
```
**两次都直接回车**（留空）。passphrase 是给私钥再加一层口令，但定时任务必须无人工干预，**必须留空**。

### 1.2 把公钥安装到接收方

```bash
ssh-copy-id root@192.129.134.230
```

- 作用：把发送方的公钥（`~/.ssh/id_ed25519.pub`）追加写入接收方的 `~/.ssh/authorized_keys` 文件
- 之后发送方每次 ssh/scp 连接收方，用私钥证明身份，无需密码
- 执行时需要**输一次接收方的 root 密码**（这是最后一次需要密码）。注意：
  - 输密码时屏幕**完全不显示**（连星号都没有），正常输完回车即可
  - 看到 `Number of key(s) added: 1` 才算成功
- 首次连接会问 `Are you sure you want to continue connecting (yes/no)?`，这是记录接收方的"指纹"，输 `yes` 回车

### 1.3 验证免密生效

```bash
ssh root@192.129.134.230 "hostname"
```

- 不问密码、直接输出 `racknerd-d83d254`，说明免密配置成功
- 如果仍要密码，说明密钥方向或配置有问题，回到 1.1 检查

---

## 第二步：准备目录环境

### 2.1 接收方：确保目标目录存在

```bash
ssh root@192.129.134.230 "mkdir -p /root/sendfile"
```

- `mkdir -p`：创建目录；`-p` 表示已存在时不报错、父目录不存在时一并创建
- scp 不会自动创建目标目录，目录不存在会直接报错

### 2.2 发送方：确认待传文件存在

```bash
ls -l /root/send-file/file/guangzhui
```

- `ls -l`：列出文件详细信息（大小、修改时间、权限）
- 脚本里有文件存在性检查，但提前确认能少走弯路

### 2.3 发送方：创建日志目录

```bash
mkdir -p /var/log/send-file
```

- 每次上传的日志文件都存放在这里（脚本里也带了自动创建逻辑，提前建好更稳妥）

---

## 第三步：部署传输脚本

脚本文件先存在于本地 Mac（或其他管理机）上，需要先传到发送方服务器，再安装到系统位置。两种方式二选一。

### 方式 A：从本地 Mac 上传（推荐，文件已有现成副本时）

#### 3.1 在本地 Mac 上执行：上传到发送方服务器的暂存目录

```bash
# 先在发送方服务器上创建暂存目录（scp 不会自动创建远程目录）
ssh root@ser4baewkrh9dqe "mkdir -p /root/send-file"

# 再把文件传上去
scp ~/WorkBuddy/send-file/script/send-file.sh root@ser4baewkrh9dqe:/root/send-file/script/
```

**逐条解释：**

- 第一条：通过 ssh 远程执行 `mkdir -p`，在发送方服务器上创建暂存目录。**scp 不会自动创建远程目录**，目录不存在时会报错
- `scp 本地文件 用户@服务器:目标路径`：scp 的基本语法——把本地文件经 SSH 加密通道复制到远程主机的指定路径
- 目标路径 `/root/send-file/` 是发送方服务器上的**暂存目录**，先把文件放这里，确认无误后再"安装"到正式位置（`/usr/local/bin/`），避免直接覆盖系统目录
- 如果要一次性传整个目录（含脚本和两个 unit 文件），加 `-r` 参数递归传输：

```bash
scp -r ~/WorkBuddy/send-file root@ser4baewkrh9dqe:/root/
```

- `-r`：recursive，递归复制整个目录及其内容
- 上传的三个文件：`send-file.sh`（脚本）、`send-file.service`（服务单元）、`send-file.timer`（定时单元）

> 💡 如果 Mac 到发送方服务器没配免密，执行时会提示输发送方服务器的 root 密码。也可以按第一步同样的方法在 Mac 上 `ssh-keygen` + `ssh-copy-id root@ser4baewkrh9dqe` 配好免密（同样的原理：谁发送，谁生成密钥）。

#### 3.2 在发送方服务器上执行：从暂存目录安装到正式位置

```bash
cp /root/send-file/send-file.sh /usr/local/bin/
cp /root/send-file/send-file.service /root/send-file/send-file.timer /etc/systemd/system/
chmod +x /usr/local/bin/send-file.sh
```

**逐条解释：**

- `cp 源 目标`：复制文件
- 第一条：脚本复制到 `/usr/local/bin/`——Linux 存放自装程序的标准目录，放这里任何路径下直接敲文件名即可执行
- 第二条：两个 systemd 配置文件复制到 `/etc/systemd/system/`——**systemd 只从规定目录加载单元文件**，放别处它看不见
- `chmod +x`：给脚本加**可执行**权限。Linux 里没有 x 权限的脚本无法运行，systemd 调用时会报 `Permission denied`（这是新手部署失败的最高频原因）

### 方式 B：在服务器上直接写入（手头没有现成文件时）

在发送方执行以下整块命令，一次性写入脚本文件：

```bash
cat > /usr/local/bin/send-file.sh << 'EOF'
#!/usr/bin/env bash
#
# send-file.sh - 定时通过 scp（SSH 密钥免密）向远程服务器传输固定文件
# 由 systemd timer (send-file.timer) 每 30 分钟调用一次
# 每次上传生成一个独立日志文件，记录文件大小、MD5、耗时、结果等
#
LOG_DIR="/var/log/send-file"       # 日志目录
LOG_KEEP_DAYS=30                   # 日志保留天数，超过自动清理；设为 0 关闭清理

# ---- 用户自定义配置 (优先级最高) ----
# /etc/send-file.conf 由 install.sh 生成, 也可随时手动编辑, 保存后下次触发即生效
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
# SSH_KEY="/root/.ssh/id_backup_key"   # 密钥非默认位置时取消注释并修改
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
FILE_MD5=$(md5sum "$LOCAL_FILE" 2>/dev/null | awk '{print $1}' || echo "N/A")

FILE_SIZE_MB=$(awk "BEGIN{printf \"%.2f\", ${FILE_SIZE}/1048576}")
log "文件大小: ${FILE_SIZE} bytes (${FILE_SIZE_MB} MB)"
log "文件修改时间: $FILE_MTIME"
log "本地 MD5: $FILE_MD5"

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

if (( LOG_KEEP_DAYS > 0 )); then
    find "$LOG_DIR" -name 'upload_*.log' -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
fi

log "========== 上传任务结束 (exit=$RC) =========="
exit $RC
EOF

chmod +x /usr/local/bin/send-file.sh
```

**逐条解释：**

- `cat > 文件 << 'EOF' ... EOF`：Here-document 写入。把 `EOF` 之间的所有内容原样写进文件；`'EOF'` 加引号表示**不做变量替换**（`$` 等符号原样保留），这一点对脚本写入至关重要
- 直接写入 `/usr/local/bin/` 和 `chmod +x` 的原因同方式 A 的 3.2 节，不再赘述
- 方式 B 只写入了脚本本身，service 和 timer 两个 unit 文件仍需按第四步的命令单独创建（或从 Mac 一并上传）

**脚本关键设计解读：**

| 代码 | 作用 |
|------|------|
| `set -euo pipefail` | 严格模式：任何命令失败立即退出，不带着错误继续跑 |
| `source /etc/send-file.conf` | 用户自定义配置文件优先级最高——改发送文件/目标地址只需编辑此文件，无需动脚本，下次触发即生效 |
| `LOCAL_FILE` 自动取值 | 优先级：配置文件指定 > 目录下的默认文件 `sendfile` > 目录下第一个非目录文件（排除 README）——curl 安装时 sendfile 会自动从 GitHub 拉取 |
| `BatchMode=yes` | 禁止一切交互提示。密钥失效时立即报错退出，而不是卡住等输密码——定时任务卡死最难排查 |
| `StrictHostKeyChecking=accept-new` | 首次连接自动记录对方指纹；之后指纹若变化则拒绝连接（防中间人攻击） |
| `scp -P 端口 -p 文件 目标` | `-P` 指定端口（注意是大写 P，小写 p 是保留文件时间戳） |
| `md5sum` | 计算文件 MD5 校验值，传完后可在接收方对比，验证文件完整性 |
| `tee -a "$LOG_FILE"` | 一份输出同时写日志文件和标准输出（后者进 journalctl），两边都能查 |
| `find ... -mtime +30 -delete` | 自动删除 30 天前的旧日志，防止日志撑爆磁盘 |

---

## 第四步：部署 systemd 服务与定时单元

### 4.1 创建 service（定义"做什么"）

```bash
cat > /etc/systemd/system/send-file.service << 'EOF'
[Unit]
Description=Send file to remote server via scp

[Service]
Type=oneshot
ExecStart=/usr/local/bin/send-file.sh
StandardOutput=journal
StandardError=journal
Restart=no
EOF
```

- `Type=oneshot`：一次性任务，跑完即退出（区别于常驻服务）
- `ExecStart`：要执行的命令
- `StandardOutput/Error=journal`：输出重定向到 journalctl
- `Restart=no`：失败不自动重启，等下次 timer 触发自然重试（避免失败后疯狂重试打爆带宽）

### 4.2 创建 timer（定义"何时做"）

```bash
cat > /etc/systemd/system/send-file.timer << 'EOF'
[Unit]
Description=Run send-file.service every 30 minutes

[Timer]
OnCalendar=*:0/30
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
```

- `OnCalendar=*:0/30`：日历式触发——每小时的第 0 分钟和第 30 分钟（即 00:00、00:30、01:00……）
- `Persistent=true`：**错过补跑**。服务器若在触发点关机，开机后立即补执行一次（crontab 做不到这点）
- `RandomizedDelaySec=30`：随机延迟 0~30 秒，避免与其他整点任务精确撞车

### 4.3 加载并启用

```bash
systemctl daemon-reload
systemctl enable --now send-file.timer
```

- `daemon-reload`：**每次修改 unit 文件后必须执行**，让 systemd 重新读取配置，否则改动不生效（最常见的"改了没反应"原因）
- `enable --now`：设为开机自启（enable）并立即启动（--now），一次到位

---

## 第五步：验证与日常运维

### 5.1 手动触发一次测试

```bash
systemctl start send-file.service
tail -n 20 /var/log/send-file/upload_*.log
```

- `systemctl start`：手动触发 service 跑一次（不影响 timer 的调度）
- 日志末尾出现 `结果: SUCCESS` 即成功
- > 🚨 实战踩坑：某些精简系统（BusyBox 环境）的 tail 不认 `-20` 简写，必须写全 `tail -n 20`，否则报 `option used in invalid context`

### 5.2 文件完整性核对（推荐做一次）

```bash
# 接收方执行
md5sum /root/sendfile/guangzhui
```

输出值与日志里的 `本地 MD5` 一致 → 文件在传输中零损坏。

### 5.3 日常运维命令速查

```bash
systemctl list-timers send-file.timer          # 查看下次触发时间、上次执行时间
tail -n 20 /var/log/send-file/upload_*.log     # 查看最近一次上传详情
journalctl -u send-file.service -n 30 --no-pager  # 从 systemd 侧查执行记录
grep -L "SUCCESS" /var/log/send-file/upload_*.log # 快速揪出所有失败的批次（-L 列出不含关键词的文件）
```

---

## 第六步：故障排查手册（实战踩坑实录）

### 症状 1：`No identities found`

**原因**：`ssh-keygen` 时把"保存路径"提示当成了密码输入，密钥存到了当前目录的乱名文件里，`~/.ssh/` 下没有默认名字的密钥。

**修复**：把密钥挪到标准位置，或删掉重新生成：

```bash
# 方案 A：挪过去
mkdir -p ~/.ssh && chmod 700 ~/.ssh
mv ~/乱名文件 ~/.ssh/id_ed25519
mv ~/乱名文件.pub ~/.ssh/id_ed25519.pub
chmod 600 ~/.ssh/id_ed25519

# 方案 B：重新生成，路径提示处直接回车
rm ~/乱名文件*
ssh-keygen -t ed25519
```

### 症状 2：`Permission denied, please try again`（ssh-copy-id 时）

**原因**：① 密码输错（终端粘贴易丢字符，建议手输）；② 接收方禁止 root 密码登录。

**排查**（在接收方本机执行）：

```bash
grep -E "^(PermitRootLogin|PasswordAuthentication)" /etc/ssh/sshd_config
```

若为 `prohibit-password` 或 `PasswordAuthentication no`，改配置允许密钥登录即可：

```bash
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart sshd
```

`prohibit-password` = 禁止密码、允许密钥，正是定时任务需要的安全姿态。

### 症状 3：service 启动失败，日志显示 `exit code=255`

**原因**：255 是 ssh/scp 的"连接或认证失败"专属退出码——密钥方向配反了（在接收方生成了密钥）或公钥没装到接收方。

**修复**：回到第一步，确认在**发送方**生成密钥并 `ssh-copy-id` 到接收方。

> 📌 scp 退出码速查：`0` 成功｜`1` 连接/认证失败｜`2` 传输中断｜`255` ssh 层错误

### 症状 4：`tail: option used in invalid context`

**原因**：BusyBox 精简环境不认 `-20` 这种数字简写。

**修复**：统一用完整写法 `tail -n 20`。

---

## 附：可选优化方向

当前方案 scp 为**全量重传**——每次都发完整文件（本例 2.8 GB × 每天 48 次 ≈ 135 GB/天流量）。若文件更新不频繁或带宽有限：

1. **跳过无变化传输**：脚本记录上次成功的 MD5，本次一致则记 `SKIPPED` 直接退出，省 99% 流量
2. **换 rsync**：`rsync -avz -e "ssh -p 22" 文件 目标` 只传输变化的数据块，大文件增量更新效率远高于 scp
3. **调整频率**：若 30 分钟太密，改 timer 里 `OnCalendar=*:0/30` 为 `OnCalendar=hourly`（每小时）或 `OnUnitActiveSec=30min`

---

## 附录：完整文件清单

| 文件 | 位置 | 用途 |
|------|------|------|
| send-file.sh | `/usr/local/bin/send-file.sh` | 传输 + 日志脚本 |
| send-file.service | `/etc/systemd/system/send-file.service` | 服务单元 |
| send-file.timer | `/etc/systemd/system/send-file.timer` | 定时单元 |
| **用户配置** | `/etc/send-file.conf` | **自定义发送文件/目标地址（优先级最高，编辑即生效）** |
| 待发送文件 | `/root/send-file/file/` | 未配置 LOCAL_FILE 时自动取目录下第一个文件 |
| 上传日志 | `/var/log/send-file/upload_*.log` | 每次传输的详细记录（保留 30 天） |
| 私钥 | 发送方 `~/.ssh/id_ed25519` | 免密认证凭据，勿外泄 |
| 公钥 | 接收方 `~/.ssh/authorized_keys` | 发送方公钥登记处 |
