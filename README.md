# Linux 服务器定时文件传输部署教程

仓库地址：https://github.com/zhetonghua/server-autoscp.git

> 基于 systemd timer + scp + SSH 密钥免密的定时传输方案
> 实战环境：HK VPS（发送方）→ US VPS 接收方）
> 传输文件：每 30 分钟一次，每次生成独立日志

---

## 方案架构

```
┌─────────────────────┐         每 30 分钟           ┌──────────────────────┐
│       Send          │  ──── scp (密钥免密) ────►  │        Receive         │
│      HK VPS         │      /root/sendfile/        │      US VPS          │
│                     │                             │                      │
│  systemd timer      │                             │                      │
│   └─ send-file.sh   │                             │  /root/sendfile/     │
│      每30分钟触发     │                             │    └─ guangzhui      │
└─────────────────────┘                             └──────────────────────┘
        │
        ▼
  /var/log/send-file/upload_YYYYMMDD_HHMMSS.log  （每次上传独立日志）
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
ssh root@IP "hostname"
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


### 2.2 发送方：确认待传文件存在

```bash
ls -l /root/sendfile/yourfile
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
scp /send-file/send-file.sh root@IP:/root/send-file/
```

**逐条解释：**

- 第一条：通过 ssh 远程执行 `mkdir -p`，在发送方服务器上创建暂存目录。**scp 不会自动创建远程目录**，目录不存在时会报错
- `scp 本地文件 用户@服务器:目标路径`：scp 的基本语法——把本地文件经 SSH 加密通道复制到远程主机的指定路径
- 目标路径 `/root/send-file/` 是发送方服务器上的**暂存目录**，先把文件放这里，确认无误后再"安装"到正式位置（`/usr/local/bin/`），避免直接覆盖系统目录
- 如果要一次性传整个目录（含脚本和两个 unit 文件），加 `-r` 参数递归传输：

```bash
scp -r /send-file root@IP:/root/send-file/
```

- `-r`：recursive，递归复制整个目录及其内容
- 上传的三个文件：`send-file.sh`（脚本）、`send-file.service`（服务单元）、`send-file.timer`（定时单元）

> 💡 发送方服务器没配免密，执行时会提示输发送方服务器的 root 密码。也可以按第一步同样的方法在 Mac 上 `ssh-keygen` + `ssh-copy-id root@ser4baewkrh9dqe` 配好免密（同样的原理：谁发送，谁生成密钥）。

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


## 第四步：部署 systemd 服务与定时单元


### 4.1 加载并启用

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
md5sum /root/sendfile/youfile-name
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



## 附录：完整文件清单

| 文件 | 位置 | 用途 |
|------|------|------|
| send-file.sh | `/usr/local/bin/send-file.sh` | 传输 + 日志脚本 |
| send-file.service | `/etc/systemd/system/send-file.service` | 服务单元 |
| send-file.timer | `/etc/systemd/system/send-file.timer` | 定时单元 |
| 上传日志 | `/var/log/send-file/upload_*.log` | 每次传输的详细记录（保留 30 天） |
| 私钥 | 发送方 `~/.ssh/id_ed25519` | 免密认证凭据，勿外泄 |
| 公钥 | 接收方 `~/.ssh/authorized_keys` | 发送方公钥登记处 |
