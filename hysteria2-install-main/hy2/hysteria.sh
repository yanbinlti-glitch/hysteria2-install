#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

# 判断系统及定义系统安装依赖方式
REGEX=("alpine" "debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Alpine" "Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apk update" "apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apk add" "apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "目前暂不支持你的VPS的操作系统！" && exit 1

if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi

# ================= 兼容 OpenRC 和 Systemd 的服务控制 =================
svc_start() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" start >/dev/null 2>&1; else systemctl start "$1" >/dev/null 2>&1; fi
}
svc_stop() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" stop >/dev/null 2>&1; else systemctl stop "$1" >/dev/null 2>&1; fi
}
svc_enable() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-update add "$1" default >/dev/null 2>&1; else systemctl enable "$1" >/dev/null 2>&1; fi
}
svc_disable() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-update del "$1" default >/dev/null 2>&1; else systemctl disable "$1" >/dev/null 2>&1; fi
}
# =====================================================================

realip(){
    ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
}

inst_cert(){
    green "Hysteria 2 协议证书申请方式如下："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 必应自签证书 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} Acme 脚本自动申请"
    echo -e " ${GREEN}3.${PLAIN} 自定义证书路径"
    echo ""
    read -rp "请输入选项 [1-3]: " certInput
    if [[ $certInput == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        chmod a+x /root 
        if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "检测到原有域名：$domain 的证书，正在应用"
            hy_domain=$domain
        else
            realip
            read -p "请输入需要申请证书的域名：" domain
            [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
            green "已输入的域名：$domain" && sleep 1
            domainIP=$(curl -sm8 ipget.net/?ip="${domain}")
            if [[ $domainIP == $ip ]]; then
                ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl
                if [[ $SYSTEM == "CentOS" || $SYSTEM == "Alpine" ]]; then
                    ${PACKAGE_INSTALL[int]} cronie
                    svc_start crond && svc_enable crond
                else
                    ${PACKAGE_INSTALL[int]} cron
                    svc_start cron && svc_enable cron
                fi
                curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
                source ~/.bashrc
                bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                if [[ -n $(echo $ip | grep ":") ]]; then
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
                else
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
                fi
                bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
                if [[ -f /root/cert.crt && -f /root/private.key ]]; then
                    echo $domain > /root/ca.log
                    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
                    echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                    green "证书申请成功!"
                    hy_domain=$domain
                fi
            else
                red "域名解析IP与当前VPS的IP不匹配！"
                exit 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -p "请输入公钥文件 crt 的路径：" cert_path
        read -p "请输入密钥文件 key 的路径：" key_path
        read -p "请输入证书的域名：" domain
        hy_domain=$domain
    else
        green "将使用必应自签证书作为 Hysteria 2 的节点证书"
        mkdir -p /etc/hysteria
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
        openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com"
        chmod 777 /etc/hysteria/cert.crt /etc/hysteria/private.key
        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port(){
    iptables -t nat -F PREROUTING >/dev/null 2>&1
    read -p "设置 Hysteria 2 端口 [1-65535]（回车随机）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    yellow "将在 Hysteria 2 节点使用的端口是：$port"
    inst_jump
}

inst_jump(){
    green "Hysteria 2 端口使用模式如下："
    echo -e " ${GREEN}1.${PLAIN} 单端口 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 端口跳跃"
    read -rp "请输入选项 [1-2]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        read -p "起始端口 (建议10000-65535)：" firstport
        read -p "末尾端口 (一定要比起始大)：" endport
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        if [[ $SYSTEM == "Alpine" ]]; then
            rc-service iptables save >/dev/null 2>&1 || true
            rc-service ip6tables save >/dev/null 2>&1 || true
        else
            netfilter-persistent save >/dev/null 2>&1
        fi
    fi
}

inst_pwd(){
    read -p "设置 Hysteria 2 密码（回车随机）：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-8)
    yellow "密码为：$auth_pwd"
}

inst_site(){
    read -rp "请输入伪装网站地址 （去除https://） [默认en.snu.ac.kr]：" proxysite
    [[ -z $proxysite ]] && proxysite="en.snu.ac.kr"
}

# ================= 客户端配置与 HTTP 订阅服务 =================
generate_client_configs() {
    realip
    
    local s_pwd=$(grep 'password:' /etc/hysteria/config.yaml | awk '{print $2}')
    local c_domain=$(grep 'sni:' /root/hy/hy-client.yaml | awk '{print $2}')
    [[ -z "$c_domain" ]] && c_domain="www.bing.com"
    
    local c_server=$(grep '^server:' /root/hy/hy-client.yaml | awk '{print $2}')
    local c_ports="${c_server##*:}"
    local primary_port=$(echo "$c_ports" | cut -d',' -f1)
    local hop_ports=$(echo "$c_ports" | awk -F ',' '{print $2}')
    
    local yaml_json_ip="$ip"
    local uri_ip="$ip"
    if [[ -n $(echo "$ip" | grep ":") ]]; then
        uri_ip="[$ip]"
    fi

    local mport_param=""
    if [[ -n "$hop_ports" ]]; then
        mport_param="&mport=$hop_ports"
    fi

    # 1. 基础链接
    local url="hysteria2://$s_pwd@$uri_ip:$primary_port/?insecure=1&sni=$c_domain${mport_param}#Hysteria2-Node"
    echo "$url" > /root/hy/url.txt
    echo -n "$url" | base64 -w 0 > /root/hy/sub_b64.txt

    # 2. 生成完整版 Clash Meta 订阅文件
    cat << EOF > /root/hy/clash-meta-sub.yaml
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: true

proxies:
  - name: "Hysteria2-Node"
    type: hysteria2
    server: "$yaml_json_ip"
    port: $primary_port
$([[ -n "$hop_ports" ]] && echo "    ports: '$hop_ports'")
    password: "$s_pwd"
    sni: "$c_domain"
    skip-cert-verify: true
    alpn:
      - h3

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies:
      - "Hysteria2-Node"
      - DIRECT

rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF

    # 3. 开启 Python HTTP 订阅服务
    if ! command -v python3 &> /dev/null; then
        if [[ $SYSTEM == "Alpine" ]]; then ${PACKAGE_INSTALL[int]} python3; else ${PACKAGE_INSTALL[int]} python3; fi
    fi

    # 杀死旧的 HTTP 服务
    if [[ -f /root/hy/sub_port.txt ]]; then
        local old_port=$(cat /root/hy/sub_port.txt)
        pkill -f "python3 -m http.server $old_port" >/dev/null 2>&1
    fi

    local sub_port=$(shuf -i 30000-50000 -n 1)
    echo "$sub_port" > /root/hy/sub_port.txt
    
    # 允许 HTTP 端口通过防火墙 (如果开启了iptables)
    iptables -I INPUT -p tcp --dport $sub_port -j ACCEPT >/dev/null 2>&1
    
    cd /root/hy
    nohup python3 -m http.server $sub_port >/dev/null 2>&1 &
    cd /root
}

showconf(){
    local ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
    local sub_port=$(cat /root/hy/sub_port.txt 2>/dev/null)
    
    yellow "================ Hysteria 2 全平台订阅链接 ================"
    
    green "🎯 1. Clash Meta 专属配置订阅链接 (推荐 Clash Verge 一键导入):"
    red "http://$ip:$sub_port/clash-meta-sub.yaml"
    echo ""
    
    green "🔗 2. 通用 Base64 订阅链接 (适用 v2rayN/Shadowrocket 等):"
    red "http://$ip:$sub_port/sub_b64.txt"
    echo ""
    
    green "📄 3. 原始 Hysteria 2 协议链接单节点:"
    red "$(cat /root/hy/url.txt)"
    echo ""
    yellow "==========================================================="
    yellow "提示: 以上订阅链接直接由您的 VPS 提供，安全且私密。"
}
# =============================================================

insthysteria(){
    if [[ ! ${SYSTEM} == "CentOS" ]]; then
        ${PACKAGE_UPDATE}
    fi
    
    if [[ $SYSTEM == "Alpine" ]]; then
        ${PACKAGE_INSTALL} curl wget sudo qrencode procps iptables ip6tables iproute2
    else
        ${PACKAGE_INSTALL} curl wget sudo qrencode procps iptables-persistent netfilter-persistent
    fi

    mkdir -p /etc/hysteria
    if [[ $SYSTEM == "Alpine" ]]; then
        green "正在为 Alpine 下载 Hysteria 2 二进制核心..."
        arch=$(uname -m)
        case $arch in
            x86_64) hy_arch="amd64" ;;
            aarch64) hy_arch="arm64" ;;
            s390x) hy_arch="s390x" ;;
            *) red "不支持的架构" && exit 1 ;;
        esac
        
        hy_ver=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -z $hy_ver ]] && hy_ver="app/v2.4.0"
        wget -N -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/${hy_ver}/hysteria-linux-${hy_arch}"
        chmod +x /usr/local/bin/hysteria
        
        cat << 'EOF' > /etc/init.d/hysteria-server
#!/sbin/openrc-run
description="Hysteria 2 Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria-server.pid"
EOF
        chmod +x /etc/init.d/hysteria-server
    else
        wget -N https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy2/install_server.sh
        bash install_server.sh
        rm -f install_server.sh
    fi

    inst_cert
    inst_port
    inst_pwd
    inst_site

    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

auth:
  type: password
  password: $auth_pwd

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true
EOF

    if [[ -n $firstport ]]; then
        last_port="$port,$firstport-$endport"
    else
        last_port=$port
    fi

    if [[ -n $(echo $ip | grep ":") ]]; then
        last_ip="[$ip]"
    else
        last_ip=$ip
    fi

    mkdir -p /root/hy
    cat << EOF > /root/hy/hy-client.yaml
server: $last_ip:$last_port
auth: $auth_pwd
tls:
  sni: $hy_domain
  insecure: true
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

    [[ $SYSTEM != "Alpine" ]] && systemctl daemon-reload
    svc_enable hysteria-server
    svc_start hysteria-server
    
    # 生成各端配置并启动 HTTP 订阅服务
    generate_client_configs
    
    red "======================================================================"
    green "Hysteria 2 代理及 HTTP 订阅服务安装完成"
    showconf
}

unsthysteria(){
    svc_stop hysteria-server
    svc_disable hysteria-server
    
    # 杀掉 Python HTTP 服务
    if [[ -f /root/hy/sub_port.txt ]]; then
        local old_port=$(cat /root/hy/sub_port.txt)
        pkill -f "python3 -m http.server $old_port" >/dev/null 2>&1
    fi

    if [[ $SYSTEM == "Alpine" ]]; then
        rm -f /etc/init.d/hysteria-server
    else
        rm -f /lib/systemd/system/hysteria-server.service
        netfilter-persistent save >/dev/null 2>&1
    fi
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy /root/hysteria.sh
    iptables -t nat -F PREROUTING >/dev/null 2>&1

    green "Hysteria 2 已彻底卸载完成！"
}

starthysteria(){
    svc_start hysteria-server
    svc_enable hysteria-server
    
    # 重启 HTTP 服务
    if [[ -f /root/hy/sub_port.txt ]]; then
        local sub_port=$(cat /root/hy/sub_port.txt)
        cd /root/hy
        nohup python3 -m http.server $sub_port >/dev/null 2>&1 &
        cd /root
    fi
    green "Hysteria 2 及订阅服务已启动！"
}

stophysteria(){
    svc_stop hysteria-server
    svc_disable hysteria-server
    
    # 停止 HTTP 服务
    if [[ -f /root/hy/sub_port.txt ]]; then
        local old_port=$(cat /root/hy/sub_port.txt)
        pkill -f "python3 -m http.server $old_port" >/dev/null 2>&1
    fi
    green "Hysteria 2 及订阅服务已关闭！"
}

hysteriaswitch(){
    yellow "请选择操作："
    echo -e " ${GREEN}1.${PLAIN} 启动 Hysteria 2"
    echo -e " ${GREEN}2.${PLAIN} 关闭 Hysteria 2"
    echo -e " ${GREEN}3.${PLAIN} 重启 Hysteria 2"
    read -rp "请输入选项 [1-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) stophysteria && starthysteria ;;
        * ) exit 1 ;;
    esac
}

changeconf(){
    green "由于配置修改涉及端口和密码，为了确保数据一致性，建议直接卸载重装体验最佳。"
    yellow "如果你确定要手动修改配置，请编辑 /etc/hysteria/config.yaml 然后重启服务。"
    echo ""
    read -p "按回车键返回主菜单..."
    menu
}

enable_bbr(){
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if [[ $(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep bbr) ]]; then
        green "检测到 BBR 加速已经开启，无需重复配置！"
        sleep 2; menu; return
    fi
    
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    
    green "BBR 加速开启成功！"
    read -p "按回车键返回主菜单..."
    menu
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#     ${GREEN}Hysteria 2 一键安装脚本 (带自建 HTTP 订阅服务)${PLAIN}      #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ${GREEN}安装 Hysteria 2${PLAIN}"
    echo -e " ${RED}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 3. 关闭、开启、重启服务"
    echo -e " 4. 显示 Hysteria 2 订阅链接"
    echo -e " ${YELLOW}5. 开启 BBR 网络加速 (推荐)${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-5]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) showconf ;;
        5 ) enable_bbr ;;
        0 ) exit 0 ;;
        * ) exit 1 ;;
    esac
}

menu
