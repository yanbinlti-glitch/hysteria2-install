# Hysteria 2 一键安装与管理脚本

这是一个基于 Linux Shell 编写的 Hysteria 2 服务端一键部署脚本。旨在简化安装流程，支持自动申请证书、配置端口跳跃、开启 BBR 网络加速，并自动生成适配多种客户端的配置信息。

## ✨ 核心功能

* **多系统兼容**：支持 Debian, Ubuntu, CentOS, Fedora, AlmaLinux, Rocky Linux 等主流发行版。
* **灵活的证书管理**：
    * 🔐 **必应自签证书**（默认）：无需域名，快速部署，适合新手或临时使用。
    * 📝 **ACME 自动续签**：集成 acme.sh，支持通过 Let's Encrypt 自动申请和续签证书（需要域名）。
    * 📂 **自定义证书**：支持使用已有的证书文件路径。
* **高级端口功能**：
    * 支持自定义端口或随机端口。
    * **端口跳跃 (Port Hopping)**：支持配置端口范围（如 10000-20000），提高抗封锁能力。
* **网络优化**：
    * 内置 **BBR 加速** 一键开启功能，自动优化系统内核参数。
* **伪装配置**：支持自定义伪装网站（默认模拟首尔大学或 Bing）。
* **配置导出**：
    * 自动生成标准的 YAML 和 JSON 客户端配置文件。
    * 自动生成 `hysteria2://` 分享链接。

## 🚀 快速安装

请在服务器的 Root 用户下执行以下命令：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/yanbinlti-glitch/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
