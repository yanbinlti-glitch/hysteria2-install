cat << 'EOF' > /usr/local/bin/hy2
#!/bin/bash

export LANG=en_US.UTF-8

# ==========================================
# UI 颜色变量
# ==========================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
PURPLE="\033[35m"
PLAIN="\033[0m"

red(){ echo -e "${RED}\033[01m$1${PLAIN}"; }
green(){ echo -e "${GREEN}\033[01m$1${PLAIN}"; }
yellow(){ echo -e "${YELLOW}\033[01m$1${PLAIN}"; }
cyan(){ echo -e "${CYAN}\033[01m$1${PLAIN}"; }
purple(){ echo -e "${PURPLE}\033[01m$1${PLAIN}"; }

[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

# ==========================================
# 1. 动态检测包管理器及系统服务适配
# ==========================================
if [[ -x "$(command -v apk)" ]]; then
    PM="apk"
    PM_INSTALL="apk add --no-cache"
    PM_UPDATE="apk update"
    PM_UNINSTALL="apk del"
    CRON_PKG="cronie"
    CRON_SERVICE="crond"
    IPTABLES_PKG="iptables ip6tables"
    INIT_SYS="openrc"
elif [[ -x "$(command -v apt-get)" ]]; then
    PM="apt-get"
    PM_INSTALL="apt-get install -y"
    PM_UPDATE="apt-get update -y"
    PM_UNINSTALL="apt-get autoremove -y"
    CRON_PKG="cron"
    CRON_SERVICE="cron"
    IPTABLES_PKG="iptables-persistent netfilter-persistent"
    INIT_SYS="systemd"
elif [[ -x "$(command -v dnf)" ]]; then
    PM="dnf"
    PM_INSTALL="dnf install -y"
    PM_UPDATE="dnf check-update"
    PM_UNINSTALL="dnf autoremove -y"
    CRON_PKG="cronie"
    CRON_SERVICE="crond"
    IPTABLES_PKG="iptables-services"
    INIT_SYS="systemd"
elif [[ -x "$(command -v yum)" ]]; then
    PM="yum"
    PM_INSTALL="yum install -y"
    PM_UPDATE="yum check-update"
    PM_UNINSTALL="yum autoremove -y"
    CRON_PKG="cronie"
    CRON_SERVICE="crond"
    IPTABLES_PKG="iptables-services"
    INIT_SYS="systemd"
else
    red "未检测到支持的包管理器！"
    exit 1
fi

# ==========================================
# 2. 跨平台守护进程封装
# ==========================================
start_service() { if [[ $INIT_SYS == "openrc" ]]; then rc-service "$1" start >/dev/null 2>&1; else systemctl start "$1" >/dev/null 2>&1; fi; }
stop_service() { if [[ $INIT_SYS == "openrc" ]]; then rc-service "$1" stop >/dev/null 2>&1; else systemctl stop "$1" >/dev/null 2>&1; fi; }
enable_service() { if [[ $INIT_SYS == "openrc" ]]; then rc-update add "$1" default >/dev/null 2>&1; else systemctl enable "$1" >/dev/null 2>&1; fi; }
disable_service() { if [[ $INIT_SYS == "openrc" ]]; then rc-update del "$1" default >/dev/null 2>&1; else systemctl disable "$1" >/dev/null 2>&1; fi; }
check_service() {
    if [[ $INIT_SYS == "openrc" ]]; then rc-service "$1" status 2>/dev/null | grep -i "started"; else systemctl status "$1" 2>/dev/null | grep -w "active"; fi
}
reload_daemon() { if [[ $INIT_SYS == "systemd" ]]; then systemctl daemon-reload >/dev/null 2>&1; fi; }

if [[ -z $(type -P curl) ]]; then
    ${PM_UPDATE}
    ${PM_INSTALL} curl
fi

realip(){
    ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
}

# ==========================================
# BBR 加速智能模块
# ==========================================
enable_bbr() {
    virt=$(systemd-detect-virt 2>/dev/null || hostnamectl 2>/dev/null | grep Virtualization | awk '{print $2}')
    if grep -q "lxc" /proc/1/environ 2>/dev/null || [[ "$virt" == "lxc" || "$virt" == "openvz" ]]; then
        yellow "检测到 LXC/OpenVZ NAT 环境，宿主机内核受限，已自动跳过 BBR 配置。"
    else
        if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
            green "BBR 加速已处于开启状态。"
        else
            cyan "正在为 KVM/独服 开启 BBR 加速..."
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            green "BBR 加速开启完成！"
        fi
    fi
}

inst_cert(){
    green "将使用 Bing 自签证书 (针对 NAT 小鸡最省资源)"
    mkdir -p /etc/hysteria
    cert_path="/etc/hysteria/cert.crt"
    key_path="/etc/hysteria/private.key"
    openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
    openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com"
    chmod 777 /etc/hysteria/cert.crt /etc/hysteria/private.key
    hy_domain="www.bing.com"
}

inst_port(){
    read -p "设置 Hysteria 2 监听端口 [1-65535]（回车则随机）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    yellow "机器本地监听端口：$port"

    read -p "NAT 机器的公网映射端口是多少？(若是全端口/独服请填同样的 $port)：" public_port
    [[ -z $public_port ]] && public_port=$port
    yellow "外网连接端口：$public_port"
}

inst_pwd(){
    auth_pwd=$(cat /proc/sys/kernel/random/uuid | tr -d '-' | head -c 12)
    yellow "自动生成安全密码：$auth_pwd"
}

inst_sub_config(){
    read -p "设置 HTTP 订阅服务的内网端口 [1-65535]（用于分发订阅）：" sub_port
    [[ -z $sub_port ]] && sub_port=$(shuf -i 10000-60000 -n 1)
    read -p "设置 HTTP 订阅服务的公网映射端口（若是全端口请填同样的 $sub_port）：" sub_pub_port
    [[ -z $sub_pub_port ]] && sub_pub_port=$sub_port
    
    sub_uuid=$(cat /proc/sys/kernel/random/uuid)
    yellow "订阅生成路径: /$sub_uuid"
}

insthysteria(){
    ${PM_UPDATE}
    ${PM_INSTALL} curl wget sudo qrencode iptables $IPTABLES_PKG openssl busybox
    
    # 为 Alpine 补充底层依赖以支持官方核心
    if [[ $PM == "apk" ]]; then
        ${PM_INSTALL} libc6-compat iproute2 bash coreutils grep
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64 | x64 | amd64 ) HY2_ARCH="amd64" ;;
        i386 | i686 )          HY2_ARCH="386" ;;
        armv8 | aarch64 )      HY2_ARCH="arm64" ;;
        * ) red "不支持的架构: $ARCH" && exit 1 ;;
    esac

    cyan "正在拉取 Hysteria 2 核心 ($HY2_ARCH) ..."
    if wget -N "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY2_ARCH}" -O /usr/local/bin/hysteria; then
        chmod +x /usr/local/bin/hysteria
        green "核心下载成功！"
    else
        red "核心下载失败！请检查网络。" && exit 1
    fi

    inst_cert
    inst_port
    inst_pwd
    inst_sub_config

    cat << EOF2 > /etc/hysteria/config.yaml
listen: :$port
tls:
  cert: $cert_path
  key: $key_path
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 16777216
  maxConnReceiveWindow: 16777216
auth:
  type: password
  password: $auth_pwd
masquerade:
  type: proxy
  proxy:
    url: https://en.snu.ac.kr
    rewriteHost: true
EOF2

    realip
    if [[ -n $(echo $ip | grep ":") ]]; then last_ip="[$ip]"; else last_ip=$ip; fi
    url="hy2://$auth_pwd@$last_ip:$public_port/?insecure=1&sni=$hy_domain#NAT-Hysteria2"

    # 生成订阅文件并 Base64 编码 (兼容各类主流客户端)
    mkdir -p /etc/hysteria/www
    echo -n "$url" | base64 -w 0 > /etc/hysteria/www/$sub_uuid

    # 生成 Hysteria 2 主程序服务 (注入极低内存限制参数 GOGC & GOMEMLIMIT)
    if [[ $INIT_SYS == "openrc" ]]; then
        cat << 'SVC' > /etc/init.d/hysteria-server
#!/sbin/openrc-run
name="hysteria-server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria-server.pid"
export GOGC=20
export GOMEMLIMIT=40MiB
depend() { need net; }
SVC
        chmod +x /etc/init.d/hysteria-server
        
        # OpenRC 下的 Busybox 订阅服务器
        cat << SVC3 > /etc/init.d/hy2-sub
#!/sbin/openrc-run
name="hy2-sub"
command="/bin/busybox"
command_args="httpd -f -p $sub_port -h /etc/hysteria/www"
command_background=true
pidfile="/run/hy2-sub.pid"
depend() { need net; }
SVC3
        chmod +x /etc/init.d/hy2-sub
    else
        cat << EOF3 > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target
[Service]
Type=simple
Environment="GOGC=20"
Environment="GOMEMLIMIT=40MiB"
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=on-failure
RestartSec=3
User=root
[Install]
WantedBy=multi-user.target
EOF3
        # Systemd 下的 Busybox 订阅服务器
        cat << EOF4 > /etc/systemd/system/hy2-sub.service
[Unit]
Description=Hysteria 2 Http Subscription Server
After=network.target
[Service]
Type=simple
ExecStart=/bin/busybox httpd -f -p $sub_port -h /etc/hysteria/www
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF4
    fi

    # 保存配置信息留待后续查看
    sub_url="http://$last_ip:$sub_pub_port/$sub_uuid"
    echo "$sub_url" > /etc/hysteria/sub_url.txt
    echo "$url" > /etc/hysteria/hy2_url.txt

    enable_bbr

    reload_daemon
    enable_service hysteria-server
    enable_service hy2-sub
    start_service hysteria-server
    start_service hy2-sub

    if [[ -n $(check_service hysteria-server) ]]; then
        green "Hysteria 2 与订阅服务启动成功！"
    else
        red "启动失败，请检查端口是否被占用。" && exit 1
    fi
    showconf
}

unsthysteria(){
    stop_service hysteria-server
    disable_service hysteria-server
    stop_service hy2-sub
    disable_service hy2-sub
    if [[ $INIT_SYS == "openrc" ]]; then
        rm -f /etc/init.d/hysteria-server /etc/init.d/hy2-sub
    else
        rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hy2-sub.service
    fi
    reload_daemon
    rm -rf /usr/local/bin/hysteria /etc/hysteria
    green "Hysteria 2 及订阅服务已彻底卸载！"
}

starthysteria(){ start_service hysteria-server; start_service hy2-sub; green "服务已启动"; }
stophysteria(){ stop_service hysteria-server; stop_service hy2-sub; green "服务已关闭"; }

hysteriaswitch(){
    echo -e " ${GREEN}1.${PLAIN} 启动\n ${GREEN}2.${PLAIN} 关闭\n ${GREEN}3.${PLAIN} 重启"
    read -rp "请输入选项 [1-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) stophysteria && starthysteria ;;
        * ) exit 1 ;;
    esac
}

showconf(){
    clear
    echo "========================================================"
    purple "Hysteria 2 NAT 轻量版部署信息"
    echo "========================================================"
    cyan "【通用订阅链接 (推荐)】:"
    yellow "$(cat /etc/hysteria/sub_url.txt)"
    echo "使用说明：复制上方链接，导入至 v2rayN / Nekobox / Clash 等支持订阅的客户端即可。"
    echo "--------------------------------------------------------"
    cyan "【单节点直连 URI】:"
    green "$(cat /etc/hysteria/hy2_url.txt)"
    echo "========================================================"
    qrencode -t ANSIUTF8 "$(cat /etc/hysteria/hy2_url.txt)" 2>/dev/null
    echo "提示：日常管理可直接在命令行输入 hy2"
}

menu() {
    clear
    echo "#############################################################"
    cyan "         Hysteria 2 极限轻量版 - 专为 NAT 小鸡优化"
    echo "#############################################################"
    echo -e " ${GREEN}1.${PLAIN} 安装 Hysteria 2 (带 HTTP 订阅)"
    echo -e " ${RED}2.${PLAIN} 完全卸载 Hysteria 2"
    echo " ------------------------------------------------------------"
    echo -e " ${CYAN}3.${PLAIN} 管理服务状态 (启动/关闭/重启)"
    echo -e " ${CYAN}4.${PLAIN} 查看订阅链接与节点配置"
    echo -e " ${CYAN}5.${PLAIN} 手动执行 BBR 内核加速"
    echo " ------------------------------------------------------------"
    echo -e " ${YELLOW}0.${PLAIN} 退出脚本"
    read -rp "请输入选项 [0-5]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) showconf ;;
        5 ) enable_bbr ;;
        * ) exit 0 ;;
    esac
}

menu
EOF

chmod +x /usr/local/bin/hy2
hy2
