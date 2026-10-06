# file/ - 待发送文件目录

**默认发送文件：`sendfile`**

安装器（script/install.sh）会：

- **clone 安装**：把本目录内容复制到服务器 `/root/send-file/file/`
- **curl 一行命令安装**：直接从 GitHub 拉取 `sendfile` 到服务器 `/root/send-file/file/sendfile`

发送优先级：`/etc/send-file.conf` 指定的 `LOCAL_FILE` > 目录下的 `sendfile` > 目录下第一个非目录文件（排除 README）。

> 注意：大文件不建议提交进 Git 仓库（GitHub 单文件上限 100 MB）。超过限制时，服务器上直接把文件放到 `/root/send-file/file/` 即可，安装时在"本地要发送的文件完整路径"处填写实际路径。
