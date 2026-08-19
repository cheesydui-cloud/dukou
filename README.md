# Dukou Sing-box 一键部署

跨发行版的 Sing-box 安装脚本：可选协议、自动生成配置与客户端链接，并自带 `sb` 管理命令。

## 一键安装

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cheesydui-cloud/dukou/main/install-singbox-yyds.sh)"
```

需要 root。不要用 `curl | bash`，交互输入会读到脚本本身。

## 支持协议

| 编号 | 协议 | 说明 |
|------|------|------|
| 1 | Shadowsocks | `2022-blake3-aes-128-gcm` 或 `aes-128-gcm` |
| 2 | Hysteria2 | 自签 ECDSA 证书，`insecure=1` |
| 3 | TUIC | UUID + 密码，BBR |
| 4 | VLESS Reality | 默认监听 443；按出口位置探测附近高校/机构 SNI |
| 5 | AnyTLS Reality | 单独部署时默认 443；与 VLESS 共用 Reality 密钥和 SNI |

可多选，例如 `1 2 4`。

## 自己的域名怎么填

安装时会问「节点对外地址」：

1. 默认用出口 IP
2. 填已绑定到这台机器的域名，例如 `jp.example.com`

这个域名只出现在客户端链接的 host 里。**不要把它当成 Reality SNI**——Reality dest 仍会探测附近高校/机构。

如果同时选了 Hysteria2 / TUIC，可以再选证书：

1. 自签（默认，`insecure=1`）
2. 用该域名申请 Let's Encrypt（本机 80 要从外网进来）
3. 使用已有证书文件

只有 Reality 时不必申请证书。

## 会自动做的事

- 安装最新 sing-box，并配置 systemd / OpenRC 开机自启
- **以 `sing-box` 系统用户运行**，443 通过 `CAP_NET_BIND_SERVICE` 绑定
- **开启 BBR**（`fq` + `tcp_congestion_control=bbr`）
- HY2 / TUIC 额外调大 UDP 缓冲
- Reality dest 探测：TLS1.3 + HTTP/2 + 证书 SAN 覆盖 SNI，排除 Cloudflare / Fastly / Cloudfront 等 CDN
- 配置用 `jq` 生成，密码里的 `+` `/` 不会写坏 JSON
- 缓存按 key=value 读取，不会 `source` 执行
- 已有安装会询问：保留配置只更新 / 全量重装（全量重装先备份到 `/etc/sing-box/backups/`）
- 可选填自己的域名作为节点地址，并做 DNS 是否指向本机的提示
- HY2 / TUIC 可选 Let's Encrypt 或已有证书
- 依赖已齐全时跳过 apt/apk，避免 `needrestart` 重启 sshd 踢掉当前会话
- 全量重装前先停旧进程，再分配端口；22 / 当前 SSH 端口不会被 inbound 占用
- 装完把链接写到 `/root/singbox-uris.txt`
- 端口校验、去重、占用检测
- 配置和密钥文件权限收紧
- IPv6 节点链接自动加 `[]`
- 装完提示需要放行的防火墙/安全组端口

## 管理

安装完成后执行：

```bash
sb
```

可以查看状态、链接、改端口、改节点域名、重探 Reality SNI、更换 VLESS UUID / Reality 密钥、更新、卸载，以及生成以本机 SS 为出口的线路机脚本。改配置前会先 `sing-box check`。

## 系统

Alpine、Debian、Ubuntu、CentOS / RHEL / Rocky / Alma / Fedora。
