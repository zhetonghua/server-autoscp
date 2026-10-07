# Linux 服务器定时文件传输部署教程

> 基于 systemd timer + scp + SSH 密钥免密的定时传输方案  
> 示例环境：sender-server / 192.0.2.10（发送方）→ receiver-server / 203.0.113.20（接收方）  
> 默认传输文件：`send-file/sendfile/sendfile`（用户可自定义），每 30 分钟一次，每次生成独立日志  
> 部署方式：**一键安装 install.sh**——所有脚本和发送文件均从 GitHub 仓库拉取，无需 git、无需 clone、无需手动部署

---

## 方案架构

```
┌──────────────────────────────────┐      每 30 分钟      ┌──────────────────────┐
│  发送方服务器                      │  ── scp (密钥免密) ──► │  接收方服务器          │
│  sender-server / 192.0.2.10 │                       │  receiver-server    │
│                                   │                       │  203.0.113.20     │
│  /root/send-file/  (主目录)       │                       │  /root/send-file/    │
│  ├─ script/      脚本与unit       │                       │  └─ receivefile/     │
│  ├─ sendfile/    发送端文件区      │                       │      └─ sendfile     │
│  │   └─ sendfile (默认发送文件)   │                       │   (与发送端同名落地)   │
│  └─ receivefile/ 接收端文件区      │                       │                      │
│  systemd timer 每30分钟触发        │                       │                      │
│  日志自动记录发送方/接收方 IP      │                       │                      │
└──────────────────────────────────┘                       └──────────────────────┘
        │
        ▼
  /var/log/send-file/upload_YYYYMMDD_HHMMSS.log  （每次上传独立日志）
```

**目录结构约定（主文件夹 `send-file/`，收发两端框架一致）：**

```
send-file/
├── script/              # 脚本目录
│   ├── send-file.sh     # 传输脚本（安装到 /usr/local/bin/）
│   ├── send-file.service
│   ├── send-file.timer
│   └── install.sh       # 一键安装器
├── sendfile/            # 发送端文件区
│   └── sendfile         # 默认要传输的文件
└── receivefile/         # 接收端文件区（文件落地位置）
    └── sendfile         # 传输后落地于此（与发送端同名）
```

传输映射：发送端 `/root/send-file/sendfile/sendfile` → 接收端 `/root/send-file/receivefile/sendfile`

三个核心组件：

| 组件   | 文件                                      | 作用                  |
| ---- | --------------------------------------- | ------------------- |
| 传输脚本 | `/usr/local/bin/send-file.sh`           | 执行 scp 传输 + 写详细日志   |
| 服务单元 | `/etc/systemd/system/send-file.service` | 告诉 systemd "执行什么"   |
| 定时单元 | `/etc/systemd/system/send-file.timer`   | 告诉 systemd "什么时候执行" |

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
ssh-copy-id root@203.0.113.20
```

- 作用：把发送方的公钥（`~/.ssh/id_ed25519.pub`）追加写入接收方的 `~/.ssh/authorized_keys` 文件
- 之后发送方每次 ssh/scp 连接收方，用私钥证明身份，无需密码
- 执行时需要**输一次接收方的 root 密码**（这是最后一次需要密码）。注意：
  - 输密码时屏幕**完全不显示**（连星号都没有），正常输完回车即可
  - 看到 `Number of key(s) added: 1` 才算成功
- 首次连接会问 `Are you sure you want to continue connecting (yes/no)?`，这是记录接收方的"指纹"，输 `yes` 回车

### 1.3 验证免密生效

```bash
ssh root@203.0.113.20 "hostname"
```

- 不问密码、直接输出 `receiver-server`，说明免密配置成功
- 如果仍要密码，说明密钥方向或配置有问题，回到 1.1 检查

---

## 第二步：准备目录环境

### 2.1 接收方：确保目标目录存在

```bash
ssh root@203.0.113.20 "mkdir -p /root/send-file/receivefile"
```

- `mkdir -p`：创建目录；`-p` 表示已存在时不报错、父目录不存在时一并创建
- scp 不会自动创建目标目录，目录不存在会直接报错
- 使用 install.sh 一键安装时此步自动完成，无需手动执行

### 2.2 发送方：确认待传文件存在

```bash
ls -l /root/send-file/sendfile/sendfile
```

- `ls -l`：列出文件详细信息（大小、修改时间、权限）
- 脚本里有文件存在性检查，但提前确认能少走弯路

### 2.3 发送方：创建日志目录

```bash
mkdir -p /var/log/send-file
```

- 每次上传的日志文件都存放在这里（脚本里也带了自动创建逻辑，提前建好更稳妥）

---

## 第三步：一键安装部署

### 一键安装 install.sh（唯一方式）

仓库自带一键安装器，自动完成本教程第一~五步的全部工作（配密钥、建目录、装文件、启用定时器、首次验证），**所有脚本和发送文件均从 GitHub 仓库拉取**：

```bash
# 交互式安装（无需 git、无需 clone）
curl -fsSL https://raw.githubusercontent.com/zhetonghua/server-autoscp/main/send-file/script/install.sh | sudo bash

# 非交互模式（脚本化批量部署，注意 -s -- 传参方式）
curl -fsSL https://raw.githubusercontent.com/zhetonghua/server-autoscp/main/send-file/script/install.sh | \
    sudo bash -s -- --host 203.0.113.20 --user root --port 22 \
    --file /root/send-file/sendfile/sendfile --path /root/send-file/receivefile/ --yes
```

**install.sh 自动完成的 8 个步骤：**

| 步骤           | 动作                                                                                              |
| ------------ | ----------------------------------------------------------------------------------------------- |
| 1. 前置检查      | root 权限 / 终端可用性 / scp·ssh·systemctl 命令是否存在                                                      |
| 2. 准备目录结构    | 创建 `/root/send-file/{script,sendfile,receivefile}`；从 GitHub 拉取 `sendfile` 与全部脚本文件 |
| 3. 收集传输配置    | 交互询问：发送端 IP（自动识别，回车采纳）、接收端 IP（必填）、文件路径、用户名、端口、目标路径                                              |
| 4. 配置 SSH 免密 | 无密钥自动生成（passphrase 留空）→ 测试 → 不通则 ssh-copy-id（仅此一次输密码）                                           |
| 5. 创建接收目录    | 在接收端 `mkdir -p` 目标路径                                                                            |
| 6. 安装文件      | 脚本→`/usr/local/bin/`，unit→`/etc/systemd/system/`，生成 `/etc/send-file.conf`                       |
| 7. 启用定时任务    | daemon-reload + enable --now timer                                                              |
| 8. 首次运行验证    | 手动触发一次传输并打印日志，确认 SUCCESS                                                                        |

**关键设计（curl|bash 兼容性）：** 全部逻辑包在 `main()` 函数中、最后一行才调用——管道模式下 bash 边读边执行，执行到 main 调用时脚本已读完，此时切换 stdin 到 `/dev/tty` 做交互才安全（详见第六步症状 5）。

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

> 📌 说明：第四步与第五步由 install.sh **自动完成**，本节为原理参考（理解 install.sh 在做什么、或需要手动调整时阅读）。

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
md5sum /root/send-file/receivefile/sendfile
```

输出值与日志里的 `本地 MD5` 一致 → 文件在传输中零损坏。

### 5.3 日常运维命令速查

```bash
systemctl list-timers send-file.timer          # 查看下次触发时间、上次执行时间
tail -n 20 /var/log/send-file/upload_*.log     # 查看最近一次上传详情
journalctl -u send-file.service -n 30 --no-pager  # 从 systemd 侧查执行记录
grep -L "SUCCESS" /var/log/send-file/upload_*.log # 快速揪出所有失败的批次（-L 列出不含关键词的文件）
rm -f /var/log/send-file/upload_*.log          # 清空全部上传日志（脚本仍会自动保留最近 30 天）
find /var/log/send-file -name 'upload_*.log' -mtime +7 -delete  # 只删 7 天前的旧日志
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

### 症状 5：curl|bash 一行命令安装时卡死（install.sh 无响应）

**原因**（本项目修复过的真实 bug）：脚本中途执行 `exec 0</dev/tty` 把 bash 的输入源从管道切到了终端——bash 连脚本自身的剩余内容都读不到，表现为卡死。

**原理与修复模式**：`curl | bash` 下 bash 边读边执行。正确做法是把全部逻辑包进 `main()` 函数、最后一行才 `main "$@"` 调用——执行到该行时脚本已从管道读完，此时切 stdin 才安全；且 main 之后必须显式 `exit $?`，否则 stdin 已是 tty，bash 执行完不退出。这是 rustup 等官方安装器的标准模式。

### 症状 6：`BASH_SOURCE[0]: unbound variable`（install.sh 启动即报错）

**原因**：`set -u` 严格模式下引用了 `BASH_SOURCE[0]`，但 curl|bash 管道执行时脚本没有文件路径，该变量不存在。

**修复**：`${BASH_SOURCE[0]:-$0}`——正常执行取脚本路径，管道模式回退到 `$0` 再兜底当前目录。

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
| install.sh | 仓库 `send-file/script/install.sh` | 一键安装器（自动完成全部部署步骤） |
| send-file.sh | `/usr/local/bin/send-file.sh` | 传输 + 日志脚本 |
| send-file.service | `/etc/systemd/system/send-file.service` | 服务单元 |
| send-file.timer | `/etc/systemd/system/send-file.timer` | 定时单元 |
| **用户配置** | `/etc/send-file.conf` | **自定义发送文件/目标地址（优先级最高，编辑即生效）** |
| 待发送文件 | `/root/send-file/sendfile/` | 未配置 LOCAL_FILE 时优先取 sendfile/sendfile，否则目录下第一个文件 |
| 接收落地 | `/root/send-file/receivefile/` | 接收端文件存放位置（与发送端框架一致） |
| 上传日志 | `/var/log/send-file/upload_*.log` | 每次传输的详细记录（保留 30 天） |
| 私钥 | 发送方 `~/.ssh/id_ed25519` | 免密认证凭据，勿外泄 |
| 公钥 | 接收方 `~/.ssh/authorized_keys` | 发送方公钥登记处 |
