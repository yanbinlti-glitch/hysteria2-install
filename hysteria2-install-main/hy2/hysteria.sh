#!/bin/bash

export LANG=en_US.UTF-8

# ================= 定义现代化极简 UI 色彩库 =================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
PURPLE="\033[35m"
CYAN="\033[36m"

LIGHT_RED="\033[1;31m"
LIGHT_GREEN="\033[1;32m"
LIGHT_YELLOW="\033[1;33m"
LIGHT_BLUE="\033[1;34m"
LIGHT_PURPLE="\033[1;35m"
LIGHT_CYAN="\033[1;36m"

PLAIN="\033[0m"

red(){ echo -e "${LIGHT_RED}$1${PLAIN}"; }
green(){ echo -e "${LIGHT_GREEN}$1${PLAIN}"; }
yellow(){ echo -e "${LIGHT_YELLOW}$1${PLAIN}"; }
cyan(){ echo -e "${LIGHT_CYAN}$1${PLAIN}"; }
blue(){ echo -e "${LIGHT_BLUE}$1${PLAIN}"; }
purple(){ echo -e "${LIGHT_PURPLE}$1${PLAIN}"; }

# 判断系统及定义系统安装依赖方式
REGEX=("alpine" "debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Alpine" "Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apk update" "apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apk add" "apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

[[ $EUID -ne 0 ]] && red "[错误] 请在 root 用户下运行此脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        PKG_UPDATE="${PACKAGE_UPDATE[int]}"
        PKG_INSTALL="${PACKAGE_INSTALL[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "[错误] 目前暂不支持你的 VPS 操作系统！" && exit 1

if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        $PKG_UPDATE >/dev/null 2>&1
    fi
    $PKG_INSTALL curl >/dev/null 2>&1
fi

# ================= 兼容 OpenRC 和 Systemd 的服务控制 =================
svc_start() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" start >/dev/null 2>&1; else systemctl start "$1" >/dev/null 2>&1; fi
}
svc_stop() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" stop >/dev/null 2>&1 || true; else systemctl stop "$1" >/dev/null 2>&1 || true; fi
}
svc_enable() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-update add "$1" default >/dev/null 2>&1; else systemctl enable "$1" >/dev/null 2>&1; fi
}
svc_disable() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-update del "$1" default >/dev/null 2>&1 || true; else systemctl disable "$1" >/dev/null 2>&1 || true; fi
}

save_iptables() {
    if [[ $SYSTEM == "Alpine" ]]; then
        rc-service iptables save >/dev/null 2>&1 || true
        rc-service ip6tables save >/dev/null 2>&1 || true
    elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" ]]; then
        service iptables save >/dev/null 2>&1 || true
        service ip6tables save >/dev/null 2>&1 || true
    else
        netfilter-persistent save >/dev/null 2>&1 || true
    fi
}

# ================= 系统环境与前置检查 =================
check_env() {
    clear
    cyan " ┌──────────────────────────────────────────────────────┐"
    cyan " │                 系统依赖与环境检查                   │"
    cyan " └──────────────────────────────────────────────────────┘"
    echo ""
    green " 当前操作系统: $SYSTEM"
    echo ""
    yellow " 正在检查 Hysteria 2 及附加服务所需的前置依赖包..."
    echo ""
    
    local cmds=("curl" "wget" "sudo" "ss" "iptables" "python3" "openssl" "socat" "qrencode")
    local missing=0

    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            red "   [缺失] $cmd"
            missing=1
        else
            green "   [正常] $cmd 已安装"
        fi
    done

    if ! command -v crontab &> /dev/null; then
        red "   [缺失] crontab (用于证书自动续期)"
        missing=1
    else
        green "   [正常] crontab 已安装"
    fi

    if [[ $SYSTEM == "Debian" || $SYSTEM == "Ubuntu" ]]; then
        if ! command -v netfilter-persistent &> /dev/null; then
            red "   [缺失] netfilter-persistent (用于防火墙规则保存)"
            missing=1
        else
            green "   [正常] netfilter-persistent 已安装"
        fi
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        cyan " ────────────────────────────────────────────────────────"
        yellow " 发现缺失前置组件，正在为您自动拉取安装，请稍候..."
        
        if [[ ! $SYSTEM == "CentOS" ]]; then
            $PKG_UPDATE >/dev/null 2>&1
        fi
        
        if [[ $SYSTEM == "Alpine" ]]; then
            $PKG_INSTALL curl wget sudo procps iptables ip6tables iproute2 python3 openssl socat cronie libqrencode-tools >/dev/null 2>&1
            svc_start crond || true
            svc_enable crond || true
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            $PKG_INSTALL epel-release >/dev/null 2>&1 || true
            $PKG_INSTALL curl wget sudo procps iptables iptables-services iproute python3 openssl socat cronie qrencode >/dev/null 2>&1
            svc_start crond || true
            svc_enable crond || true
        else
            export DEBIAN_FRONTEND=noninteractive
            $PKG_INSTALL curl wget sudo procps iptables-persistent netfilter-persistent iproute2 python3 openssl socat cron qrencode >/dev/null 2>&1
            svc_start cron || true
            svc_enable cron || true
        fi
        
        echo ""
        green " 所有前置依赖补全完成！"
    else
        echo ""
        cyan " ────────────────────────────────────────────────────────"
        green " 所有前置依赖检查通过，环境非常完美，无需额外安装！"
    fi
    echo ""
    sleep 2
}

realip(){
    ip=$(curl -s4m3 ip.sb -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1 || curl -s4m3 ifconfig.me -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6m3 ip.sb -k || curl -s6m3 ifconfig.me -k)
    fi
}

inst_cert(){
    clear
    cyan " ┌──────────────────────────────────────────────────────┐"
    cyan " │                  Hysteria 2 证书配置                 │"
    cyan " └──────────────────────────────────────────────────────┘"
    echo ""
    green "   [1] 必应自签证书 (推荐小白，默认)"
    cyan "   [2] Acme 脚本申请 (需 Cloudflare 域名托管)"
    yellow "   [3] 自定义证书路径"
    echo ""
    read -rp " 请输入选项 [1-3] (默认1): " certInput
    [[ -z $certInput ]] && certInput=1
    
    if [[ $certInput == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        chmod a+x /root 
        if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green " 检测到原有域名：$domain 的证书，正在应用..."
            hy_domain=$domain
        else
            realip
            echo ""
            read -p " 请输入需要申请证书的域名：" domain
            [[ -z $domain ]] && red " 未输入域名，无法执行操作！" && exit 1
            green " 已输入的域名：$domain"
            
            domainIP=$(python3 -c "import socket; print(socket.gethostbyname('${domain}'))" 2>/dev/null)
            
            if [[ "$domainIP" != "$ip" ]]; then
                echo ""
                yellow " [警告] 域名解析的 IP ($domainIP) 与当前 VPS 真实 IP ($ip) 不匹配！"
                yellow " [警告] Hysteria 2 必须使用真实 IP 直连，请确保 Cloudflare 已关闭小云朵 (DNS Only)。"
                read -p " 是否确认并继续申请证书？(y/n) [默认: y]: " force_cert
                [[ -z $force_cert ]] && force_cert="y"
                if [[ $force_cert != "y" && $force_cert != "Y" ]]; then
                    exit 1
                fi
            fi

            echo ""
            cyan " ────────────────────────────────────────────────────────"
            yellow " 准备使用 Cloudflare DNS API 申请证书"
            cyan " 推荐在 CF控制台 -> 我的个人资料 -> API 令牌 中获取 Token"
            cyan " ────────────────────────────────────────────────────────"
            echo ""
            read -p " 请选择认证方式 [1. API Token (推荐) | 2. Global API Key]: " cf_auth_choice
            [[ -z $cf_auth_choice ]] && cf_auth_choice=1

            if [[ $cf_auth_choice == 1 ]]; then
                read -p " 请输入 Cloudflare API Token: " cf_token
                if [[ -z $cf_token ]]; then
                    red " API Token 不能为空！"
                    exit 1
                fi
                export CF_Token="$cf_token"
                curl https://get.acme.sh | sh -s email="admin@${domain}"
            else
                read -p " 请输入 Cloudflare 账号邮箱 (CF_Email): " cf_email
                read -p " 请输入 Cloudflare Global API Key: " cf_key
                if [[ -z $cf_email || -z $cf_key ]]; then
                    red " 邮箱或 API Key 不能为空！"
                    exit 1
                fi
                export CF_Email="$cf_email"
                export CF_Key="$cf_key"
                curl https://get.acme.sh | sh -s email="$cf_email"
            fi
            
            bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            
            echo ""
            yellow " 正在通过 Cloudflare DNS API 验证所有权 (可能需要1-3分钟)..."
            bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${domain} -k ec-256
            
            if [[ $SYSTEM == "Alpine" ]]; then
                reload_cmd="rc-service hysteria-server restart"
            else
                reload_cmd="systemctl restart hysteria-server"
            fi
            
            bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc --reloadcmd "$reload_cmd"
            
            if [[ -f /root/cert.crt && -f /root/private.key ]]; then
                echo $domain > /root/ca.log
                chmod 644 /root/cert.crt
                chmod 600 /root/private.key
                
                green " 证书申请成功！已保存至 /root/ 目录下。"
                hy_domain=$domain
            else
                red " 证书申请失败！请检查认证信息或查看报错。"
                exit 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        echo ""
        read -p " 请输入公钥文件 crt 的绝对路径：" cert_path
        read -p " 请输入密钥文件 key 的绝对路径：" key_path
        read -p " 请输入该证书对应的域名：" domain
        hy_domain=$domain
    else
        echo ""
        green " 已选择 必应(Bing)自签伪装证书"
        mkdir -p /etc/hysteria
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key >/dev/null 2>&1
        openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com" >/dev/null 2>&1
        
        chmod 644 /etc/hysteria/cert.crt
        chmod 600 /etc/hysteria/private.key
        
        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port(){
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    read -p " 设置 Hysteria 2 节点端口 [1-65535] (回车随机)：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    
    while [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; do
        red " [警告] 端口必须是 1-65535 之间的纯数字！"
        read -p " 请重新设置 Hysteria 2 节点端口：" port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    done

    while ss -unl | grep -q ":$port\b"; do
        red " [警告] 端口 $port 已经被占用，请更换端口重试！"
        read -p " 请重新设置 Hysteria 2 节点端口：" port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    done
    green " 节点主端口已设置为：$port"
    
    iptables -I INPUT -p udp --dport $port -j ACCEPT
    ip6tables -I INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1; then ufw allow $port/udp >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --zone=public --add-port=$port/udp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    save_iptables

    inst_jump
}

inst_jump(){
    echo ""
    yellow " 端口模式选择："
    green "   [1] 单端口直连 (默认)"
    cyan "   [2] 端口跳跃模式 (防封锁黑科技)"
    read -rp " 请输入选项 [1-2] (默认1): " jumpInput
    if [[ $jumpInput == 2 ]]; then
        echo ""
        read -p " 请输入起始端口 (建议10000-65535)：" firstport
        while [[ ! "$firstport" =~ ^[0-9]+$ ]] || [[ "$firstport" -lt 1 ]] || [[ "$firstport" -gt 65535 ]]; do
            red " [警告] 起始端口必须是纯数字！"
            read -p " 请输入起始端口：" firstport
        done

        read -p " 请输入末尾端口 (必须大于起始端口)：" endport
        while [[ ! "$endport" =~ ^[0-9]+$ ]] || [[ "$endport" -le "$firstport" ]] || [[ "$endport" -gt 65535 ]]; do
            red " [警告] 末尾端口无效！"
            read -p " 请重新输入末尾端口：" endport
        done
        green " 已开启端口跳跃范围：$firstport - $endport"

        modprobe ip6table_nat 2>/dev/null || true
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port 2>/dev/null || true
        if command -v ufw >/dev/null 2>&1; then ufw allow $firstport:$endport/udp >/dev/null 2>&1; fi
        if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --zone=public --add-port=$firstport-$endport/udp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
        
        save_iptables
    fi
}

inst_sub_port(){
    echo ""
    read -p " 设置智能订阅服务端口 [1024-65535] (回车随机)：" sub_port_input
    [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    
    while [[ ! "$sub_port_input" =~ ^[0-9]+$ ]] || [[ "$sub_port_input" -lt 1024 ]] || [[ "$sub_port_input" -gt 65535 ]]; do
        red " [警告] 端口必须在 1024-65535 之间！"
        read -p " 重新设置订阅端口：" sub_port_input
        [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    done
    
    while ss -tnl | grep -q ":$sub_port_input\b"; do
        red " [警告] 端口 $sub_port_input 已被占用！"
        read -p " 重新设置订阅端口：" sub_port_input
        [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    done
    green " 订阅端口已设置为：$sub_port_input"
}

inst_pwd(){
    echo ""
    read -p " 设置节点连接密码 (回车自动生成)：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c 1-8 || date +%s%N | md5sum | cut -c 1-8)
    green " 连接密码为：$auth_pwd"
}

inst_site(){
    echo ""
    read -rp " 伪装网站地址 (不带 https://) [回车默认 www.bing.com]：" proxysite
    [[ -z $proxysite ]] && proxysite="www.bing.com"
}

inst_node_name(){
    echo ""
    read -rp " 节点显示名称 (勿含空格特殊字符) [回车默认 Hysteria2_Node]：" custom_node_name
    [[ -z $custom_node_name ]] && custom_node_name="Hysteria2_Node"
}

inst_bandwidth(){
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    yellow " 拥塞控制配置 (降低延迟的核心)"
    cyan " Hysteria 2 的 Brutal 算法需知晓服务器最大带宽。"
    
    read -p " 请输入 VPS 最大 上行带宽 (Mbps, 回车默认 1000)：" bw_up_input
    [[ -z $bw_up_input ]] && bw_up_input="1000"
    while [[ ! "$bw_up_input" =~ ^[0-9]+$ ]]; do
        red " [警告] 仅限纯数字！"
        read -p " 请输入 VPS 最大 上行带宽 (Mbps)：" bw_up_input
    done
    bw_up="${bw_up_input} mbps"
    
    read -p " 请输入 VPS 最大 下行带宽 (Mbps, 回车默认 1000)：" bw_down_input
    [[ -z $bw_down_input ]] && bw_down_input="1000"
    while [[ ! "$bw_down_input" =~ ^[0-9]+$ ]]; do
        red " [警告] 仅限纯数字！"
        read -p " 请输入 VPS 最大 下行带宽 (Mbps)：" bw_down_input
    done
    bw_down="${bw_down_input} mbps"
}

inst_obfs(){
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    yellow " 防阻断混淆(Obfuscation)配置"
    cyan " 开启 Salamander 混淆可防运营商 QoS 限速与封锁。"
    read -p " 是否开启混淆？(y/n) [默认: y]: " enable_obfs
    [[ -z $enable_obfs ]] && enable_obfs="y"
    if [[ "$enable_obfs" == "y" || "$enable_obfs" == "Y" ]]; then
        obfs_pwd=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c 1-12 || date +%s%N | md5sum | cut -c 1-12)
        green " 已开启混淆，系统生成的密钥为：$obfs_pwd"
    else
        obfs_pwd=""
        yellow " 已跳过混淆配置。"
    fi
}

generate_client_configs() {
    realip
    
    local s_pwd=$(grep 'password:' /etc/hysteria/config.yaml | head -n 1 | awk '{print $2}')
    local c_domain=$(grep 'sni:' /etc/hysteria/hy-client.yaml | awk '{print $2}')
    [[ -z "$c_domain" ]] && c_domain="www.bing.com"
    
    local c_server=$(grep '^server:' /etc/hysteria/hy-client.yaml | awk '{print $2}')
    local c_ports="${c_server##*:}"
    local primary_port=$(echo "$c_ports" | cut -d',' -f1)
    local hop_ports=$(echo "$c_ports" | awk -F ',' '{print $2}')
    
    local s_obfs_pwd=$(awk '/obfs:/{flag=1} flag && /password:/{print $2; flag=0}' /etc/hysteria/config.yaml | tr -d '"' | tr -d "'")
    local is_insecure_url=$(cat /etc/hysteria/insecure_state.txt 2>/dev/null || echo "1")
    
    local clash_cert_verify="true"
    if [[ "$is_insecure_url" == "0" ]]; then
        clash_cert_verify="false"
        echo "$c_domain" > /etc/hysteria/sub_host.txt
    else
        echo "$ip" > /etc/hysteria/sub_host.txt
    fi

    local obfs_param=""
    local clash_obfs_block=""
    if [[ -n "$s_obfs_pwd" ]]; then
        obfs_param="&obfs=salamander&obfs-password=${s_obfs_pwd}"
        clash_obfs_block="    obfs: salamander
    obfs-password: \"$s_obfs_pwd\""
    fi

    local yaml_json_ip="$ip"
    local uri_ip="$ip"
    if [[ -n $(echo "$ip" | grep ":") ]]; then
        uri_ip="[$ip]"
    fi

    local mport_param=""
    if [[ -n "$hop_ports" ]]; then
        mport_param="&mport=$hop_ports"
    fi

    local web_dir="/var/www/hysteria"
    mkdir -p "$web_dir"

    local sub_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N | md5sum | head -c 16)
    mkdir -p "$web_dir/$sub_uuid"
    echo "$sub_uuid" > /etc/hysteria/sub_path.txt

    local url="hysteria2://$s_pwd@$uri_ip:$primary_port/?insecure=${is_insecure_url}&sni=$c_domain${mport_param}${obfs_param}#${custom_node_name}"
    echo "$url" > "$web_dir/$sub_uuid/url.txt"
    
    echo -n "$url" | base64 | tr -d '\r\n' > "$web_dir/$sub_uuid/sub_b64.txt"

    cat << EOF > "$web_dir/$sub_uuid/clash-meta-sub.yaml"
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: true

proxies:
  - name: '${custom_node_name}'
    type: hysteria2
    server: "$yaml_json_ip"
    port: $primary_port
$([[ -n "$hop_ports" ]] && echo "    ports: '$hop_ports'")
    password: "$s_pwd"
    sni: "$c_domain"
    skip-cert-verify: $clash_cert_verify
    alpn:
      - h3
$clash_obfs_block
    up: '50 mbps'
    down: '500 mbps'

proxy-groups:
  - name: "节点选择"
    type: select
    proxies:
      - '${custom_node_name}'
      - DIRECT

rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF

    local sub_port=$sub_port_input
    echo "$sub_port" > /etc/hysteria/sub_port.txt

    local sub_cert_dir="$web_dir/certs"
    mkdir -p "$sub_cert_dir"
    cp "$cert_path" "$sub_cert_dir/cert.crt" 2>/dev/null || cp /etc/hysteria/cert.crt "$sub_cert_dir/cert.crt" 2>/dev/null
    cp "$key_path" "$sub_cert_dir/private.key" 2>/dev/null || cp /etc/hysteria/private.key "$sub_cert_dir/private.key" 2>/dev/null
    chown -R nobody "$sub_cert_dir" 2>/dev/null
    chmod 400 "$sub_cert_dir/private.key" 2>/dev/null
    
    cat << EOF > "$web_dir/server.py"
import http.server
import socketserver
import ssl
import os
import urllib.parse

PORT = $sub_port
SUB_UUID = "$sub_uuid"
CERT_FILE = "$sub_cert_dir/cert.crt"
KEY_FILE = "$sub_cert_dir/private.key"

try:
    with open("$web_dir/$sub_uuid/clash-meta-sub.yaml", 'rb') as f:
        CLASH_DATA = f.read()
    with open("$web_dir/$sub_uuid/sub_b64.txt", 'rb') as f:
        B64_DATA = f.read()
except FileNotFoundError:
    CLASH_DATA = b""
    B64_DATA = b""

class SecureSubHandler(http.server.BaseHTTPRequestHandler):
    server_version = "nginx/1.24.0"
    sys_version = ""

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        req_path = parsed.path.strip('/')
        
        if req_path == SUB_UUID:
            self.send_response(200)
            self.send_header('Content-type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
            self.end_headers()
            
            ua = self.headers.get('User-Agent', '').lower()
            if any(x in ua for x in ['clash', 'meta', 'verge', 'stash', 'mihomo']):
                self.wfile.write(CLASH_DATA)
            else:
                self.wfile.write(B64_DATA)
        else:
            self.send_response(403)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(b"<html><head><title>403 Forbidden</title></head><body><center><h1>403 Forbidden</h1></center><hr><center>nginx</center></body></html>")

with socketserver.TCPServer(("", PORT), SecureSubHandler) as httpd:
    if "${is_insecure_url}" == "0" and os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()
EOF

    chown -R nobody "$web_dir" || true
    
    iptables -I INPUT -p tcp --dport $sub_port -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT -p tcp --dport $sub_port -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1; then ufw allow $sub_port/tcp >/dev/null 2>&1; fi
    if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --zone=public --add-port=$sub_port/tcp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1; fi
    save_iptables
    
    local py_path=$(command -v python3)
    if [[ $SYSTEM == "Alpine" ]]; then
        cat << EOF > /etc/init.d/hysteria-sub
#!/sbin/openrc-run
description="Hysteria Subscription Server"
command="${py_path}"
command_args="${web_dir}/server.py"
command_background=true
command_user="nobody"
directory="${web_dir}"
pidfile="/run/hysteria-sub.pid"
EOF
        chmod +x /etc/init.d/hysteria-sub
        rc-update add hysteria-sub default >/dev/null 2>&1
    else
        cat << EOF > /etc/systemd/system/hysteria-sub.service
[Unit]
Description=Hysteria Subscription Server
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=${web_dir}
ExecStart=${py_path} ${web_dir}/server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria-sub >/dev/null 2>&1
    fi
    
    svc_stop hysteria-sub
    svc_start hysteria-sub
}

showconf(){
    local ip=$(curl -s4m3 ip.sb -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1 || curl -s4m3 ifconfig.me -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6m3 ip.sb -k || curl -s6m3 ifconfig.me -k)
    fi
    local sub_port=$(cat /etc/hysteria/sub_port.txt 2>/dev/null)
    local sub_path=$(cat /etc/hysteria/sub_path.txt 2>/dev/null)
    local sub_host=$(cat /etc/hysteria/sub_host.txt 2>/dev/null)
    local is_insecure=$(cat /etc/hysteria/insecure_state.txt 2>/dev/null)
    [[ -z "$sub_host" ]] && sub_host=$ip
    
    local protocol="https"
    [[ "$is_insecure" == "1" ]] && protocol="http"
    
    local sub_url=""
    if [[ -n $(echo "$sub_host" | grep ":") ]]; then
        sub_url="${protocol}://[${sub_host}]:${sub_port}/${sub_path}"
    else
        sub_url="${protocol}://${sub_host}:${sub_port}/${sub_path}"
    fi

    local web_dir="/var/www/hysteria"
    local raw_url=$(cat "$web_dir/$sub_path/url.txt" 2>/dev/null)
    
    clear
    cyan " ┌──────────────────────────────────────────────────────┐"
    cyan " │                Hysteria 2 全平台智能订阅             │"
    cyan " └──────────────────────────────────────────────────────┘"
    echo ""
    green " [智能订阅链接] (推荐)"
    cyan " 适用客户端: Clash Verge / v2rayN / Shadowrocket"
    yellow " 订阅地址: ${sub_url}"
    echo ""
    green " [单节点直连链接]"
    cyan " 适用客户端: NekoBox / v2rayNG (直接导入)"
    yellow " 节点地址: ${raw_url}"
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    echo ""
    
    if ! command -v qrencode &> /dev/null; then
        yellow " 正在加载二维码模块..."
        if [[ $SYSTEM == "Ubuntu" || $SYSTEM == "Debian" ]]; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y qrencode >/dev/null 2>&1
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            yum install -y epel-release >/dev/null 2>&1
            yum install -y qrencode >/dev/null 2>&1
        elif [[ $SYSTEM == "Alpine" ]]; then
            apk update >/dev/null 2>&1
            apk add libqrencode-tools >/dev/null 2>&1
        fi
    fi

    if command -v qrencode >/dev/null; then
        cyan " 提示：若二维码断层，请将终端字体缩小，或设置行间距为1.0"
        echo ""
        qrencode -t ANSIUTF8 "$raw_url"
    else
        yellow " 正通过安全在线 API 绘制二维码..."
        curl -s -d "$raw_url" https://qrenco.de
    fi
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    yellow " 使用说明："
    cyan " 1. 打开 Shadowrocket 或 v2rayNG 扫一扫功能直接扫码。"
    cyan " 2. 智能订阅会自动识别客户端！Clash 获取 YAML，v2rayN 获取 Base64。"
    echo ""
    read -p " 按回车键返回主菜单..."
    menu
}

edit_config() {
    clear
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red " 未检测到 Hysteria 2 配置文件，请先安装！"
        sleep 2
        menu
        return
    fi
    
    cyan " ┌──────────────────────────────────────────────────────┐"
    cyan " │                当前 Hysteria 2 节点配置              │"
    cyan " └──────────────────────────────────────────────────────┘"
    echo ""
    cat /etc/hysteria/config.yaml
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    read -p " 是否需要修改配置文件？(y/n) [默认: n]: " edit_choice
    if [[ "$edit_choice" == "y" || "$edit_choice" == "Y" ]]; then
        if command -v nano >/dev/null; then
            nano /etc/hysteria/config.yaml
        elif command -v vi >/dev/null; then
            vi /etc/hysteria/config.yaml
        else
            red " 未找到 nano 或 vi 编辑器，请手动修改 /etc/hysteria/config.yaml"
        fi
        
        echo ""
        green " 配置修改完成，正在重启 Hysteria 2 服务..."
        svc_stop hysteria-server
        svc_start hysteria-server
        green " 重启成功！新配置已生效。"
    fi
    echo ""
    read -p " 按回车键返回主菜单..."
    menu
}

check_traffic() {
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red " 未检测到 Hysteria 2 配置文件，请先安装！"
        sleep 2
        menu
        return
    fi
    
    if ! grep -q "^trafficStats:" /etc/hysteria/config.yaml; then
        local api_port=$(shuf -i 30000-60000 -n 1)
        while ss -tnl | grep -q ":$api_port\b"; do
            api_port=$(shuf -i 30000-60000 -n 1)
        done
        echo "$api_port" > /etc/hysteria/api_port.txt
        
        green " 正在自动开启流量统计 API..."
        cat << EOF >> /etc/hysteria/config.yaml

trafficStats:
  listen: 127.0.0.1:$api_port
EOF
        svc_stop hysteria-server
        svc_start hysteria-server
        sleep 2
    else
        local api_port=$(grep 'listen: 127.0.0.1:' /etc/hysteria/config.yaml | grep -oE '[0-9]+$')
        [[ -z "$api_port" ]] && api_port=$(cat /etc/hysteria/api_port.txt 2>/dev/null)
    fi

    local traffic_data=$(curl -s "http://127.0.0.1:$api_port/traffic")
    
    clear
    cyan " ┌──────────────────────────────────────────────────────┐"
    cyan " │                客户端连接与流量统计                  │"
    cyan " └──────────────────────────────────────────────────────┘"
    echo ""
    
    if [[ -z "$traffic_data" || "$traffic_data" =~ "404" ]]; then
        red " 获取数据失败，Hysteria 服务可能未正常运行。"
    elif [[ ! "$traffic_data" =~ '"tx"' ]]; then
        yellow " 暂无任何流量消耗记录或客户端连接。"
    else
        local client_count=$(echo "$traffic_data" | grep -o '"[^"]*":{[^}]*}' | grep -c '"tx"')
        green " 当前活跃客户端总数: $client_count"
        echo ""
        cyan " ────────────────────────────────────────────────────────"
        
        echo "$traffic_data" | grep -o '"[^"]*":{[^}]*}' | grep '"tx"' | while read -r line; do
            user=$(echo "$line" | cut -d '"' -f2)
            tx=$(echo "$line" | grep -o '"tx":[0-9]*' | cut -d: -f2)
            rx=$(echo "$line" | grep -o '"rx":[0-9]*' | cut -d: -f2)
            
            [[ -z $tx ]] && tx=0
            [[ -z $rx ]] && rx=0
            
            tx_mb=$(awk "BEGIN {printf \"%.2f\", $tx/1048576}")
            rx_mb=$(awk "BEGIN {printf \"%.2f\", $rx/1048576}")
            
            yellow " 账号: $user | 发送: $tx_mb MB | 接收: $rx_mb MB"
        done
    fi
    
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    read -p " 按回车键返回主菜单..."
    menu
}

insthysteria(){
    check_env

    mkdir -p /etc/hysteria
    
    api_port=$(shuf -i 30000-60000 -n 1)
    while ss -tnl | grep -q ":$api_port\b"; do
        api_port=$(shuf -i 30000-60000 -n 1)
    done
    echo "$api_port" > /etc/hysteria/api_port.txt
    
    green " 正在下载 Hysteria 2 二进制核心..."
    arch=$(uname -m)
    case $arch in
        x86_64) hy_arch="amd64" ;;
        aarch64) hy_arch="arm64" ;;
        s390x) hy_arch="s390x" ;;
        *) red " 不支持的架构: $arch" && exit 1 ;;
    esac
    
    hy_ver=$(curl -sI "https://github.com/apernet/hysteria/releases/latest" | grep -i "^location:" | sed 's/.*\/tag\///g' | tr -d '\r\n')
    hy_ver=${hy_ver//%2F//}
    [[ -z $hy_ver ]] && hy_ver="app/v2.4.0"
    
    wget -N -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/${hy_ver}/hysteria-linux-${hy_arch}"
    if [[ $? -ne 0 ]]; then
        red " Hysteria 2 核心下载失败，请检查网络！"
        exit 1
    fi
    chmod +x /usr/local/bin/hysteria
    
    if [[ $SYSTEM == "Alpine" ]]; then
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
        cat << EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    inst_cert
    inst_port
    inst_sub_port
    inst_pwd
    inst_site
    inst_node_name
    inst_bandwidth
    inst_obfs

    if [[ "$hy_domain" == "www.bing.com" ]]; then
        cert_insecure_yaml="true"
        cert_insecure_url="1"
    else
        cert_insecure_yaml="false"
        cert_insecure_url="0"
    fi
    
    echo "$cert_insecure_url" > /etc/hysteria/insecure_state.txt

    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $cert_path
  key: $key_path

auth:
  type: password
  password: $auth_pwd

bandwidth:
  up: $bw_up
  down: $bw_down

$(if [[ -n "$obfs_pwd" ]]; then
echo "obfs:
  type: salamander
  salamander:
    password: \"$obfs_pwd\""
fi)

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true

trafficStats:
  listen: 127.0.0.1:$api_port
EOF

    if [[ -n $firstport ]]; then
        last_port="$port,$firstport-$endport"
    else
        last_port=$port
    fi

    if [[ -n $(echo "$ip" | grep ":") ]]; then
        last_ip="[$ip]"
    else
        last_ip=$ip
    fi

    cat << EOF > /etc/hysteria/hy-client.yaml
server: $last_ip:$last_port
auth: $auth_pwd
tls:
  sni: $hy_domain
  insecure: $cert_insecure_yaml
EOF

    svc_enable hysteria-server
    svc_start hysteria-server
    
    generate_client_configs
    
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    green " Hysteria 2 服务端及智能订阅安装部署完成！"
    cyan " 请在主菜单选择 [ 5 ] 获取节点与二维码。"
    echo ""
    sleep 3
    menu
}

unsthysteria(){
    local main_port=$(grep '^listen:' /etc/hysteria/config.yaml 2>/dev/null | awk -F ':' '{print $NF}' | tr -d ' ')
    local sub_port=$(cat /etc/hysteria/sub_port.txt 2>/dev/null)

    echo ""
    yellow " 正在安全地清理系统网络与防火墙规则..."
    if [[ -n "$main_port" && "$main_port" =~ ^[0-9]+$ ]]; then
        iptables -D INPUT -p udp --dport $main_port -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport $main_port -j ACCEPT 2>/dev/null || true
        
        iptables-save -t nat | grep "DNAT --to-destination :$main_port" | sed 's/^-A /-D /' | while read -r rule; do
            iptables -t nat $rule 2>/dev/null || true
        done
        ip6tables-save -t nat | grep "DNAT --to-destination :$main_port" | sed 's/^-A /-D /' | while read -r rule; do
            ip6tables -t nat $rule 2>/dev/null || true
        done

        if command -v ufw >/dev/null 2>&1; then ufw delete allow $main_port/udp >/dev/null 2>&1 || true; fi
        if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --zone=public --remove-port=$main_port/udp --permanent >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
    fi
    
    if [[ -n "$sub_port" && "$sub_port" =~ ^[0-9]+$ ]]; then
        iptables -D INPUT -p tcp --dport $sub_port -j ACCEPT 2>/dev/null || true
        if command -v ufw >/dev/null 2>&1; then ufw delete allow $sub_port/tcp >/dev/null 2>&1 || true; fi
        if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --zone=public --remove-port=$sub_port/tcp --permanent >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi
    fi

    svc_stop hysteria-server >/dev/null 2>&1 || true
    svc_disable hysteria-server >/dev/null 2>&1 || true
    svc_stop hysteria-sub >/dev/null 2>&1 || true
    svc_disable hysteria-sub >/dev/null 2>&1 || true

    if [[ $SYSTEM == "Alpine" ]]; then
        rm -f /etc/init.d/hysteria-server /etc/init.d/hysteria-sub
    else
        rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-sub.service
        systemctl daemon-reload || true
    fi
    save_iptables

    rm -rf /usr/local/bin/hysteria /etc/hysteria /var/www/hysteria

    echo ""
    green " Hysteria 2 服务及相关文件、端口规则已彻底清理！"
    sleep 2
    exit 0
}

starthysteria(){
    svc_start hysteria-server
    svc_start hysteria-sub
    green " Hysteria 2 及订阅服务已启动！"
    sleep 2; menu
}

stophysteria_only(){
    svc_stop hysteria-server
    svc_stop hysteria-sub
    yellow " Hysteria 2 及订阅服务已停止！"
}

hysteriaswitch(){
    clear
    cyan " ┌──────────────────────────────────────────────────────┐"
    cyan " │                  服务运行状态控制                    │"
    cyan " └──────────────────────────────────────────────────────┘"
    echo ""
    green "   [1] 启动 Hysteria 2 及订阅服务"
    red "   [2] 停止 Hysteria 2 及订阅服务"
    yellow "   [3] 重启 Hysteria 2 及订阅服务"
    echo ""
    cyan " ────────────────────────────────────────────────────────"
    blue "   [0] 返回主菜单"
    echo ""
    read -rp " 请输入选项 [0-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria_only; sleep 2; menu ;;
        3 ) stophysteria_only; starthysteria ;;
        0 ) menu ;;
        * ) red " 输入无效，返回主菜单"; sleep 1; menu ;;
    esac
}

enable_bbr(){
    local kernel_v=$(uname -r | cut -d. -f1)
    if [[ "$kernel_v" -lt 4 ]]; then
        red " 当前内核版本过低 ($(uname -r))，不支持开启 BBR！"
        sleep 3
        menu
        return
    fi

    modprobe tcp_bbr || true
    
    sed -i '/^net\.core\.default_qdisc/d' /etc/sysctl.conf
    sed -i '/^net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/^net\.core\.rmem_max/d' /etc/sysctl.conf
    sed -i '/^net\.core\.rmem_default/d' /etc/sysctl.conf
    sed -i '/^net\.core\.wmem_max/d' /etc/sysctl.conf
    sed -i '/^net\.core\.wmem_default/d' /etc/sysctl.conf
    sed -i '/^net\.ipv4\.udp_mem/d' /etc/sysctl.conf

    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.core.rmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.rmem_default=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_default=26214400" >> /etc/sysctl.conf
    echo "net.ipv4.udp_mem=262144 524288 1048576" >> /etc/sysctl.conf
    
    sysctl -p >/dev/null 2>&1
    
    echo ""
    green " BBR 及 UDP 缓冲区底层优化开启成功！可显著降低丢包率。"
    echo ""
    read -p " 按回车键返回主菜单..."
    menu
}

menu() {
    clear
    cyan " ┌────────────────────────────────────────────────────────┐"
    cyan " │                                                        │"
    cyan " │       Hysteria 2 一键部署与管理脚本 (极致优化版)       │"
    cyan " │                                                        │"
    cyan " └────────────────────────────────────────────────────────┘"
    echo ""
    green "  [核心功能]"
    green "   1. 安装部署 Hysteria 2"
    red "   2. 彻底卸载 Hysteria 2"
    echo ""
    yellow "  [服务管理]"
    yellow "   3. 启动 / 停止 / 重启服务"
    yellow "   4. 查看 / 修改 配置文件"
    echo ""
    blue "  [实用工具]"
    blue "   5. 获取 节点配置 与 订阅链接"
    blue "   6. 查看 客户端连接 与 流量统计"
    blue "   7. 开启 BBR 及 UDP 缓冲区加速 (推荐)"
    cyan " ──────────────────────────────────────────────────────────"
    purple "   0. 退出脚本"
    echo ""
    read -rp " 请输入选项 [0-7]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) edit_config ;;
        5 ) showconf ;;
        6 ) check_traffic ;;
        7 ) enable_bbr ;;
        0 ) exit 0 ;;
        * ) exit 1 ;;
    esac
}

menu
