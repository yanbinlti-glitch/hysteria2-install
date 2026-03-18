# Hysteria 2 一键部署与管理脚本 (单人旗舰加固版)

![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Bash](https://img.shields.io/badge/Language-Bash-green.svg)
![Hysteria2](https://img.shields.io/badge/Core-Hysteria_2-purple.svg)

本项目是一个功能全面、极致优化的 Hysteria 2 服务端一键部署与管理脚本。专为追求低延迟、高并发和防封锁的单人/小团体用户打造。包含智能订阅分发、端口跳跃、极限 UDP 调优以及全自动证书健康诊断等旗舰级功能。

## ✨ 核心特性

* **全系统兼容**：深度兼容 Alpine (OpenRC)、Debian, Ubuntu, CentOS, Fedora, Alma, Rocky, Amazon Linux 等主流 Linux 发行版。
* **三种证书模式**：
    * 🎯 **必应自签伪装** (默认)：免域名，直接利用 IP 与必应自签证书启动，适合纯小白。
    * 🛡️ **Acme.sh 自动申请**：对接 Cloudflare DNS API（支持 Token 与 Global Key），全自动申请并续签真实域名证书。
    * 📁 **自定义证书**：支持手动指定服务器上的现有证书路径。
* **防阻断黑科技**：
    * **端口跳跃 (Port Hopping)**：一键配置 iptables/ip6tables 端口跳跃转发，有效防止单端口被运营商 QoS 或封锁。
    * **Salamander 混淆**：内置开启抗特征审查混淆，保护流量隐私。
* **极致网络调优**：
    * **Brutal 拥塞控制**：自定义上下行带宽，跑满宽带。
    * **BBR 自适应回退**：支持输入 0 开启 BBR 模式，适合弱网或带宽未知环境。
    * **极限 UDP 并发加速**：一键写入内核级缓冲区调优参数，防止高并发导致 OOM 或丢包。
* **全平台智能订阅服务器**：
    * 内置 Python 双栈 (IPv4/IPv6) 智能 Web 订阅分发。
    * 自适应客户端 User-Agent（自动下发 Clash Meta 格式配置或标准 Base64 节点链接）。
* **可视化数据与诊断**：
    * 实时监控当前在线客户端数与出入站流量消耗。
    * **密码学级证书诊断**：自动检测证书是否过期、RSA/ECC 密钥是否配对，并提供本地缓存一键修复功能。

## 💻 支持的操作系统

| OS Family | Supported Versions | Init System |
| :--- | :--- | :--- |
| **Alpine Linux** | Latest | OpenRC |
| **Debian** | 10, 11, 12+ | Systemd |
| **Ubuntu** | 18.04, 20.04, 22.04+ | Systemd |
| **CentOS/RHEL** | 7, 8, 9 (Alma/Rocky) | Systemd |
| **Amazon Linux** | 2, 2023 | Systemd |
| **Fedora** | 36+ | Systemd |

## 🚀 安装与使用

连接到您的 VPS，在 root 权限下执行以下命令下载并运行脚本：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/yanbinlti-glitch/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
