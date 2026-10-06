# file/ - 待发送文件目录

把要定时传输的文件放在本目录下，例如：

```
send-file/file/guangzhui
```

安装器（script/install.sh）会把本目录中的文件自动部署到发送方服务器的 `/root/send-file/file/`，并将其作为默认传输对象。

> 注意：大文件不建议提交进 Git 仓库（GitHub 单文件上限 100 MB），服务器上直接把文件放到 `/root/send-file/file/` 即可，安装时在"本地要发送的文件完整路径"处填写实际路径。
