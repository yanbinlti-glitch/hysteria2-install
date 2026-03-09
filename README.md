# Hysteria 2 一键安装与管理脚本 (多系统兼容版)

这是一个用于快速部署、配置和管理 [Hysteria 2](https://v2.hysteria.network/) 代理服务的 Bash 脚本。

在原版一键脚本的基础上，**本版本特别增加了对 Alpine Linux 的全面深度适配**（包括底层的 OpenRC 服务管理、apk 包管理器调用以及二进制核心直装），同时完美向下兼容 Debian、Ubuntu、CentOS 和 Fedora 等主流 Linux 发行版。

## ⚠️ 重要前提提示：必须放行 UDP 协议！

Hysteria 2 核心基于定制的 QUIC 协议，**完全依赖 UDP 进行数据传输**。
* **VPS 提供商防火墙**：如果您使用的是阿里云、腾讯云、AWS、GCP、Oracle 等拥有外部“安全组”或“云防火墙”的服务器，**请务必前往对应的云控制台，手动放行您在脚本中设置的端口（协议选择 `UDP`，如果是跳跃端口则放行对应的端口段）**。
* **本地网络限制**：部分校园网、公司内网或特定运营商可能会针对 UDP 进行 QoS 限速甚至完全封锁 UDP 流量。如果配置正确但无法连接，请优先排查本地网络是否支持 UDP。

## ✨ 核心特性

* **多系统全覆盖**：完美支持 Debian, Ubuntu, CentOS, Fedora 以及 **Alpine Linux**。
* **灵活的证书管理**：
  * 必应 (Bing) 自签证书（开箱即用，默认推荐）
  * Acme.sh 一键自动申请域名证书
  * 指定本地自定义证书路径
* **强大的网络特性**：
  * 支持单端口模式
  * 支持端口跳跃 (Port Hopping)，有效防止端口被封锁
  * 一键开启 BBR 加速及 fq 队列规则优化网络吞吐
* **便捷的日常管理**：
  * 一键启动、停止、重启服务
  * 随时修改端口、密码、证书类型和伪装网站

## ⚙️ 系统要求

* **操作系统**：Alpine Linux / Debian / Ubuntu / CentOS / Fedora
* **权限**：需要 `root` 权限执行
* **环境依赖**：必须使用 `bash` 运行（Alpine 系统默认 shell 为 `ash`，若未安装 `bash`，请先执行 `apk update && apk add bash`）

## 🚀 快速开始

### 1. 下载脚本

将脚本下载到您的服务器上（假设文件名为 `hysteria.sh`）：

```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/yanbinlti-glitch/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
# 如果没有 wget，可以使用 curl
# curl -N --no-check-certificate https://raw.githubusercontent.com/yanbinlti-glitch/hysteria2-install/main/hysteria2-install-main/hy2/hysteria.sh && bash hysteria.sh
