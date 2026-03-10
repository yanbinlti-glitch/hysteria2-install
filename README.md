# 🚀 Hysteria 2 一键安装与管理脚本 (带防遍历 HTTP 订阅服务)

这是一个功能强大、极致安全的 **Hysteria 2** 代理协议一键安装与管理脚本。不仅包含了基础的核心搭建，还内置了防遍历的 HTTP 订阅分发系统、端口跳跃、自动化证书管理以及实时流量统计。

## ✨ 核心特性 (Features)

* **🛡️ 极致安全的订阅分发**：内置基于 Python3 的 HTTP 订阅服务。采用 `nobody` 降权运行，拒绝 Root 风险；配合随机 UUID 目录防遍历机制，确保您的节点信息不被恶意爬取。
* **🔗 全平台订阅兼容**：自动生成 **Clash Meta / Verge** 专属 YAML 订阅文件，以及通用 Base64 订阅链接（适用于 v2rayN, Shadowrocket 等）。
* **🔀 端口跳跃与防封锁**：支持配置单端口或大规模端口跳跃 (Port Hopping)，有效应对 ISP 封锁和 QoS 限制。
* **🔐 智能证书管理**：
    * 支持 Bing 自签证书（开箱即用，免配域名）。
    * 支持通过 ACME.sh 调用 Cloudflare DNS API 自动申请并续期真实 TLS 证书。
    * 支持自定义已有的证书路径。
* **📊 实时流量监控**：内置 Hysteria 2 流量统计 API，一键查看当前各个客户端（密码）的上传/下载消耗。
* **🚀 网络底层优化**：一键开启 BBR 拥塞控制与 FQ 队列，榨干 VPS 最后一滴带宽。
* **🧹 绿色无残留卸载**：智能清理服务进程、相关文件以及 iptables/ip6tables 端口放行与 NAT 转发规则。

## 💻 支持的操作系统 (Supported OS)

脚本底层针对各大主流 Linux 发行版的包管理器和服务管理器（Systemd & OpenRC）进行了深度适配：

* **Debian** (推荐)
* **Ubuntu** (推荐)
* **Alpine Linux** (极简环境完美兼容)
* **CentOS / AlmaLinux / Rocky Linux / Fedora**
* **Oracle Linux / Amazon Linux**

## 🛠️ 安装与使用 (Usage)

1. 将脚本下载或上传至您的 VPS（以 `root` 用户登录）。
2. 赋予脚本执行权限：
   ```bash
   wget -N --no-check-certificate https://raw.githubusercontent.com/yanbinlti-glitch/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
