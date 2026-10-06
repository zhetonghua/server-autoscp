# receivefile/ - 接收端文件区

接收端服务器上文件落地的目标目录：`/root/send-file/receivefile/`

发送端把 `send-file/sendfile/` 里的文件通过 scp 传过来后，就存放在本目录对应位置，两端目录框架保持一致：

```
发送端: /root/send-file/sendfile/sendfile
                │
                │  scp (每 30 分钟, systemd timer)
                ▼
接收端: /root/send-file/receivefile/sendfile
```

> 本目录在仓库中作为结构占位；实际文件在接收端服务器上生成，无需提交。
