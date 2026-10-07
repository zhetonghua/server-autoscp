# sendfile/ - 发送端文件区

**默认发送文件：`sendfile/sendfile`（本目录下的 sendfile 文件）**

收发两端目录框架一致：

```
发送端: /root/send-file/sendfile/      ← 待发送文件放这里
接收端: /root/send-file/receivefile/   ← 文件落地到这里
```

安装器（script/install.sh）统一从 GitHub 仓库拉取本目录的 `sendfile` 到服务器 `/root/send-file/sendfile/sendfile`——无需 clone、无需手动放置。

发送优先级：`/etc/send-file.conf` 指定的 `LOCAL_FILE` > 目录下的 `sendfile` > 目录下第一个非目录文件（排除 README）。

> 注意：大文件不建议提交进 Git 仓库（GitHub 单文件上限 100 MB）。超过限制时，服务器上直接把文件放到 `/root/send-file/sendfile/` 即可，安装时在"本地要发送的文件完整路径"处填写实际路径。
