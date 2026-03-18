#!/bin/bash

export LANG=en_US.UTF-8

# =================================================================
#  1. 现代化极简 UI 色彩库 (严格遵循: 绿/红/黄/紫)
# =================================================================
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PURPLE="\033[35m"

LIGHT_RED="\033[1;31m"
LIGHT_GREEN="\033[1;32m"
LIGHT_YELLOW="\033[1;33m"
LIGHT_PURPLE="\033[1;35m"
PLAIN="\033[0m"

red()    { echo -e "${LIGHT_RED}$1${PLAIN}"; }
green()  { echo -e "${LIGHT_GREEN}$1${PLAIN}"; }
yellow() { echo -e "${LIGHT_YELLOW}$1${PLAIN}"; }
purple() { echo -e "${LIGHT_PURPLE}$1${PLAIN}"; }

print_line() {
    green " ──────────────────────────────────────────────────────────"
}

# =================================================================
#  2. 基础系统判定与核心工具函数
# =================================================================
[[ $EUID -ne 0 ]] && red " [错误] 请在 root 用户下运行此脚本！" && exit 1

SCRIPT_PATH=$(realpath "$0" || readlink -f "$0" || echo "$0")
if [[ "$SCRIPT_PATH" != "/usr/local/bin/hy2" ]]; then
    cp -f "$0" /usr/local/bin/hy2
    chmod +x /usr/local/bin/hy2
fi

REGEX=("alpine" "debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora")
RELEASE=("Alpine" "Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apk update" "apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apk add" "apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

CMD=("$(grep -i pretty_name /etc/os-release | cut -d \" -f2)" "$(hostnamectl | grep -i system | cut -d : -f2)" "$(lsb_release -sd)" "$(grep -i description /etc/lsb-release | cut -d \" -f2)" "$(grep . /etc/redhat-release)" "$(grep . /etc/issue | cut -d \\ -f1 | sed '/^[ ]*$/d')")

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
[[ -z $SYSTEM ]] && red " [错误] 目前暂不支持您的 VPS 操作系统！" && exit 1

if [[ -z $(type -P curl) ]]; then
    [[ ! $SYSTEM == "CentOS" ]] && { $PKG_UPDATE || { echo ""; red " [错误] 系统软件源更新失败！"; exit 1; }; }
    $PKG_INSTALL curl || { echo ""; red " [错误] curl 安装失败！请检查网络或系统源。"; exit 1; }
fi

realip() {
    ip=$(curl -s4m3 ip.sb -k | grep -m 1 -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" || curl -s4m3 ifconfig.me -k | grep -m 1 -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" || curl -s4m3 api.ipify.org -k | grep -m 1 -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}")
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6m3 ip.sb -k || curl -s6m3 ifconfig.me -k || curl -s6m3 api64.ipify.org -k)
    fi
    
    if [[ -z "$ip" ]]; then
        echo ""
        red " [错误] 无法获取本机的公网 IP，请检查 VPS 的网络连接或 DNS 设置！"
        exit 1
    fi
}

gen_random_str() {
    local len=$1
    cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c 1-$len || head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n' | cut -c 1-$len
}

# =================================================================
#  3. 服务管理与防火墙控制封装 (开放日志输出)
# =================================================================
svc_start()   { if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" start; else systemctl start "$1"; fi; }
svc_stop()    { if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" stop; else systemctl stop "$1"; fi; }
svc_enable()  { if [[ $SYSTEM == "Alpine" ]]; then rc-update add "$1" default; else systemctl enable "$1"; fi; }
svc_disable() { if [[ $SYSTEM == "Alpine" ]]; then rc-update del "$1" default; else systemctl disable "$1"; fi; }

save_iptables() {
    echo "  [调试] 正在保存防火墙规则..."
    if [[ $SYSTEM == "Alpine" ]]; then
        rc-service iptables save
        rc-service ip6tables save
    elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
        service iptables save
        service ip6tables save
    else
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        fi
    fi
}

open_port() {
    local port=$1
    local proto=$2
    echo "  [调试] 正在开放端口: $port/$proto"
    iptables -I INPUT -p $proto --dport $port -j ACCEPT
    ip6tables -I INPUT -p $proto --dport $port -j ACCEPT
    if command -v ufw &>/dev/null; then ufw allow $port/$proto; fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --add-port=$port/$proto --permanent
        firewall-cmd --reload
    fi
    save_iptables
}

close_port() {
    local port=$1
    local proto=$2
    echo "  [调试] 正在关闭端口: $port/$proto"
    iptables -D INPUT -p $proto --dport $port -j ACCEPT
    ip6tables -D INPUT -p $proto --dport $port -j ACCEPT
    if command -v ufw &>/dev/null; then ufw delete allow $port/$proto; fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --remove-port=$port/$proto --permanent
        firewall-cmd --reload
    fi
    save_iptables
}

# =================================================================
#  4. 环境检查与预处理
# =================================================================
check_env() {
    clear
    echo ""
    print_line
    green "                   系统依赖与环境检查                      "
    print_line
    echo ""
    green "  当前操作系统: $SYSTEM"
    yellow "  正在检查 Hysteria 2 核心及前置依赖包..."
    echo ""
    
    local cmds=("curl" "wget" "sudo" "ss" "iptables" "python3" "openssl" "socat" "qrencode")
    local missing=0

    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            red "   [✘] 缺失:  $cmd"
            missing=1
        else
            green "   [✔] 正常:  $cmd"
        fi
    done

    if ! command -v crontab &> /dev/null; then
        red "   [✘] 缺失:  crontab"
        missing=1
    else
        green "   [✔] 正常:  crontab"
    fi

    if [[ $SYSTEM == "Debian" || $SYSTEM == "Ubuntu" ]]; then
        if ! command -v netfilter-persistent &> /dev/null; then
            red "   [✘] 缺失:  netfilter-persistent"
            missing=1
        else
            green "   [✔] 正常:  netfilter-persistent"
        fi
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        print_line
        yellow "  发现缺失前置组件，正在为您自动拉取安装，请查看下方日志..."
        echo ""
        
        [[ ! $SYSTEM == "CentOS" ]] && { $PKG_UPDATE || { echo ""; red " [错误] 系统软件源更新失败！"; exit 1; }; }
        
        if [[ $SYSTEM == "Alpine" ]]; then
            $PKG_INSTALL curl wget sudo procps iptables ip6tables iproute2 python3 openssl socat cronie libqrencode-tools || exit 1
            svc_start crond; svc_enable crond
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            $PKG_INSTALL epel-release || exit 1
            $PKG_INSTALL curl wget sudo procps iptables iptables-services iproute python3 openssl socat cronie qrencode || exit 1
            svc_start crond; svc_enable crond
        else
            export DEBIAN_FRONTEND=noninteractive
            apt-get --fix-broken install -y || exit 1
            apt-get autoremove -y
            apt-get clean
            $PKG_INSTALL curl wget sudo procps iptables-persistent netfilter-persistent iproute2 python3 openssl socat cron qrencode || exit 1
            svc_start cron; svc_enable cron
        fi
        
        echo ""
        green "  所有前置依赖补全完成！"
    else
        echo ""
        print_line
        green "  所有前置依赖检查通过！"
    fi
    sleep 2
}

# =================================================================
#  5. 安装交互核心流程
# =================================================================
inst_cert() {
    clear
    echo ""
    print_line
    green "                    Hysteria 2 证书配置                    "
    print_line
    echo ""
    echo -e "    ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}必应自签伪装证书 (单人独享/免域名，默认)${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_PURPLE}Acme 脚本申请 (需 Cloudflare 域名托管)${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[3]${PLAIN} ${LIGHT_YELLOW}自定义证书路径${PLAIN}"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [1-3] (默认1): ${PLAIN}"
    read certInput
    [[ -z "$certInput" ]] && certInput=1

    if [[ "$certInput" == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        if [[ -f /root/cert.crt && -f /root/private.key && -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log | tr -d '\r')
            echo ""
            green " 检测到原有域名：$domain 的证书，正在直接应用..."
            hy_domain="$domain"
        else
            realip
            echo ""
            echo -en " ${LIGHT_YELLOW} ▶ 请输入需要申请证书的域名: ${PLAIN}"
            read domain
            [[ -z "$domain" ]] && red " 未输入域名，无法执行操作！" && exit 1
            domain=$(echo "$domain" | tr -d '\r' | tr -d ' ')
            green " 已记录域名：$domain"
            
            domainIP=$(python3 -c "import socket; print(socket.getaddrinfo('${domain}', None)[0][4][0])" || echo "")
            
            if [[ -z "$domainIP" ]]; then
                echo ""
                yellow " [警告] 无法解析域名 ${domain} 的 IP 地址！"
                echo -en " ${LIGHT_YELLOW} ▶ 是否强制继续？(y/n) [默认: y]: ${PLAIN}"
                read force_cert
                [[ -z "$force_cert" ]] && force_cert="y"
                [[ "$force_cert" != "y" && "$force_cert" != "Y" ]] && exit 1
            elif [[ "$domainIP" != "$ip" ]]; then
                echo ""
                yellow " [警告] 域名解析的 IP ($domainIP) 与当前真实 IP ($ip) 不匹配！"
                echo -en " ${LIGHT_YELLOW} ▶ 是否确认并继续？(y/n) [默认: y]: ${PLAIN}"
                read force_cert
                [[ -z "$force_cert" ]] && force_cert="y"
                [[ "$force_cert" != "y" && "$force_cert" != "Y" ]] && exit 1
            fi

            echo ""
            yellow "  准备使用 Cloudflare DNS API 申请证书"
            echo -en " ${LIGHT_YELLOW} ▶ 选择认证方式 [1. API Token(推荐) | 2. Global API Key]: ${PLAIN}"
            read cf_auth_choice
            [[ -z "$cf_auth_choice" ]] && cf_auth_choice=1

            install_acme() {
                local acme_email="$1"
                if [[ ! -f "/root/.acme.sh/acme.sh" ]]; then
                    yellow "  正在安全拉取 Acme.sh 安装脚本..."
                    curl -L --max-time 30 -o /tmp/acme_install.sh https://get.acme.sh
                    if [[ $? -ne 0 || ! -s /tmp/acme_install.sh ]]; then
                        red "  [错误] Acme.sh 下载失败！"
                        rm -f /tmp/acme_install.sh
                        exit 1
                    fi
                    sh /tmp/acme_install.sh email="$acme_email" || { red "  [错误] Acme.sh 安装报错！"; exit 1; }
                    rm -f /tmp/acme_install.sh
                fi
            }

            if [[ "$cf_auth_choice" == 1 ]]; then
                echo -en " ${LIGHT_YELLOW} ▶ 请输入 Cloudflare API Token: ${PLAIN}"
                read cf_token
                export CF_Token="$(echo "$cf_token" | tr -d '\r' | tr -d ' ')"
                install_acme "admin@${domain}"
            else
                echo -en " ${LIGHT_YELLOW} ▶ 请输入 Cloudflare 账号邮箱: ${PLAIN}"
                read cf_email
                echo -en " ${LIGHT_YELLOW} ▶ 请输入 Cloudflare Global API Key: ${PLAIN}"
                read cf_key
                export CF_Email="$(echo "$cf_email" | tr -d '\r' | tr -d ' ')"
                export CF_Key="$(echo "$cf_key" | tr -d '\r' | tr -d ' ')"
                install_acme "$CF_Email"
            fi
            
            bash /root/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            rm -f /root/cert.crt /root/private.key /root/ca.log

            yellow " 正在通过 DNS API 验证所有权，请留意下方执行日志..."
            bash /root/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256
            mkdir -p /var/www/hysteria/certs

            if [[ $SYSTEM == "Alpine" ]]; then
                local reload_cmd="cp -f /root/cert.crt /var/www/hysteria/certs/cert.crt && cp -f /root/private.key /var/www/hysteria/certs/private.key && chown -R nobody /var/www/hysteria/certs && if rc-service hysteria-server status | grep -q 'started'; then rc-service hysteria-server restart; fi && if rc-service hysteria-sub status | grep -q 'started'; then rc-service hysteria-sub restart; fi"
            else
                local reload_cmd="cp -f /root/cert.crt /var/www/hysteria/certs/cert.crt && cp -f /root/private.key /var/www/hysteria/certs/private.key && chown -R nobody /var/www/hysteria/certs && if systemctl is-active --quiet hysteria-server; then systemctl restart hysteria-server; fi && if systemctl is-active --quiet hysteria-sub; then systemctl restart hysteria-sub; fi"
            fi
            
            bash /root/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc --reloadcmd "$reload_cmd"
            
            if [[ -f /root/cert.crt && -f /root/private.key ]]; then
                echo "$domain" > /root/ca.log
                chmod 644 /root/cert.crt; chmod 600 /root/private.key
                green " 证书申请成功！"
                hy_domain="$domain"
            else
                red " [错误] 证书申请失败！请检查上方报错。"
                exit 1
            fi
        fi
    elif [[ "$certInput" == 3 ]]; then
        echo ""
        while true; do
            echo -en " ${LIGHT_YELLOW} ▶ 请输入公钥(crt)的绝对路径: ${PLAIN}"
            read cert_path
            cert_path=$(echo "$cert_path" | tr -d '\r' | tr -d ' ')
            if [[ -f "$cert_path" ]]; then break; else red " [错误] 文件不存在！"; fi
        done
        while true; do
            echo -en " ${LIGHT_YELLOW} ▶ 请输入密钥(key)的绝对路径: ${PLAIN}"
            read key_path
            key_path=$(echo "$key_path" | tr -d '\r' | tr -d ' ')
            if [[ -f "$key_path" ]]; then break; else red " [错误] 文件不存在！"; fi
        done
        while true; do
            echo -en " ${LIGHT_YELLOW} ▶ 请输入对应的域名: ${PLAIN}"
            read domain
            domain=$(echo "$domain" | tr -d '\r' | tr -d ' ')
            if [[ -n "$domain" ]]; then break; else red " [错误] 不能为空！"; fi
        done
        hy_domain="$domain"
    else
        echo ""
        green " 已选择 必应自签伪装证书，开始生成..."
        mkdir -p /etc/hysteria
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        
        echo "  [调试] 执行 openssl 生成证书..."
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
        openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com"
        chmod 644 /etc/hysteria/cert.crt; chmod 600 /etc/hysteria/private.key

        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port() {
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 设置 Hysteria 2 主端口 [10000-65535] (回车随机): ${PLAIN}"
    read port
    [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    
    while [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; do
        echo -en " ${LIGHT_YELLOW} ▶ 重新设置主端口: ${PLAIN}"
        read port
    done

    open_port $port "udp"

    echo ""
    echo -e "    ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}单端口直连 (默认)${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_PURPLE}端口跳跃模式${PLAIN}"
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [1-2] (默认1): ${PLAIN}"
    read jumpInput
    if [[ $jumpInput == 2 ]]; then
        echo -en " ${LIGHT_YELLOW} ▶ 请输入起始端口: ${PLAIN}"
        read firstport
        echo -en " ${LIGHT_YELLOW} ▶ 请输入末尾端口: ${PLAIN}"
        read endport
        
        echo "$firstport:$endport" > /etc/hysteria/port_hop.txt

        echo "  [调试] 配置端口跳跃 iptables 规则..."
        modprobe ip6table_nat || true
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j REDIRECT --to-ports $port -m comment --comment "hy2-port-hop"
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j REDIRECT --to-ports $port -m comment --comment "hy2-port-hop"
        if command -v ufw &>/dev/null; then ufw allow $firstport:$endport/udp; fi
        if command -v firewall-cmd &>/dev/null; then
            firewall-cmd --zone=public --add-port=$firstport-$endport/udp --permanent
            firewall-cmd --reload
        fi
        save_iptables
    fi
}

inst_sub_port(){
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 设置订阅服务端口 [1024-65535] (回车随机): ${PLAIN}"
    read sub_port_input
    [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    open_port $sub_port_input "tcp"
    
    mkdir -p /etc/hysteria
    echo "$sub_port_input" > /etc/hysteria/sub_port.txt
}

inst_other_configs() {
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 设置节点连接密码 (回车自动生成): ${PLAIN}"
    read auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(gen_random_str 8)

    echo -en " ${LIGHT_YELLOW} ▶ 伪装网站地址 [回车默认 www.bing.com]: ${PLAIN}"
    read proxysite
    [[ -z $proxysite ]] && proxysite="www.bing.com"

    echo -en " ${LIGHT_YELLOW} ▶ 节点显示名称 [回车默认 Hysteria2_Node]: ${PLAIN}"
    read custom_node_name
    [[ -z $custom_node_name ]] && custom_node_name="Hysteria2_Node"

    echo -en " ${LIGHT_YELLOW} ▶ 请输入 VPS 最大上行带宽 (Mbps, 输入 0 开启 BBR 自适应模式): ${PLAIN}"
    read bw_up_input
    [[ -z $bw_up_input ]] && bw_up_input="0"
    
    if [[ "$bw_up_input" != "0" ]]; then
        bw_up="${bw_up_input} mbps"
        echo -en " ${LIGHT_YELLOW} ▶ 请输入 VPS 最大下行带宽 (Mbps, 回车默认 1000): ${PLAIN}"
        read bw_down_input
        [[ -z $bw_down_input ]] && bw_down_input="1000"
        bw_down="${bw_down_input} mbps"
        
        echo -en " ${LIGHT_YELLOW} ▶ 本地真实下载速度 (Mbps, 回车默认 500): ${PLAIN}"
        read c_down
        [[ -z $c_down ]] && c_down="500"
        echo -en " ${LIGHT_YELLOW} ▶ 本地真实上传速度 (Mbps, 回车默认 50): ${PLAIN}"
        read c_up
        [[ -z $c_up ]] && c_up="50"
        echo "$c_down" > /etc/hysteria/c_down.txt
        echo "$c_up" > /etc/hysteria/c_up.txt
    else
        echo "0" > /etc/hysteria/c_down.txt
        echo "0" > /etc/hysteria/c_up.txt
    fi

    echo -en " ${LIGHT_YELLOW} ▶ 是否开启混淆？(y/n) [默认: y]: ${PLAIN}"
    read enable_obfs
    [[ -z $enable_obfs ]] && enable_obfs="y"
    if [[ "$enable_obfs" == "y" || "$enable_obfs" == "Y" ]]; then
        obfs_pwd=$(gen_random_str 12)
    else
        obfs_pwd=""
    fi
}

# =================================================================
#  6. 核心业务处理与部署逻辑
# =================================================================
clean_env() {
    local mode="$1"
    
    local main_port=$(grep -E "^[[:space:]]*listen:" /etc/hysteria/config.yaml | awk -F ':' '{print $NF}' | tr -d ' ' | tr -d '\r')
    local sub_port=$(cat /etc/hysteria/sub_port.txt | tr -d '\r')

    [[ -n "$main_port" && "$main_port" =~ ^[0-9]+$ ]] && close_port "$main_port" "udp"
    [[ -n "$sub_port" && "$sub_port" =~ ^[0-9]+$ ]] && close_port "$sub_port" "tcp"

    echo "  [调试] 清理 NAT 端口跳跃规则..."
    if command -v iptables &>/dev/null; then
        iptables -t nat -nL PREROUTING --line-numbers | grep "hy2-port-hop" | awk '{print $1}' | sort -nr | while read -r num; do
            iptables -t nat -D PREROUTING "$num"
        done
    fi
    if command -v ip6tables &>/dev/null; then
        ip6tables -t nat -nL PREROUTING --line-numbers | grep "hy2-port-hop" | awk '{print $1}' | sort -nr | while read -r num; do
            ip6tables -t nat -D PREROUTING "$num"
        done
    fi

    if [[ -f /etc/hysteria/port_hop.txt ]]; then
        local hop_range=$(cat /etc/hysteria/port_hop.txt | tr -d '\r')
        local f_port=$(echo "$hop_range" | cut -d':' -f1)
        local e_port=$(echo "$hop_range" | cut -d':' -f2)
        if [[ -n "$f_port" && -n "$e_port" ]]; then
            if command -v ufw &>/dev/null; then ufw delete allow "$f_port:$e_port/udp"; fi
            if command -v firewall-cmd &>/dev/null; then
                firewall-cmd --zone=public --remove-port="$f_port-$e_port/udp" --permanent
                firewall-cmd --reload
            fi
        fi
    fi

    echo "  [调试] 停止并禁用系统服务..."
    svc_stop hysteria-server; svc_disable hysteria-server
    svc_stop hysteria-sub; svc_disable hysteria-sub

    if [[ $SYSTEM == "Alpine" ]]; then
        rm -f /etc/init.d/hysteria-server /etc/init.d/hysteria-sub
    else
        rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-sub.service
        systemctl daemon-reload
    fi
    save_iptables

    rm -rf /usr/local/bin/hysteria /etc/hysteria /var/www/hysteria
    
    if [[ "$mode" == "all" ]]; then
        rm -f /root/cert.crt /root/private.key /root/ca.log
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
    local is_insecure_url=$(cat /etc/hysteria/insecure_state.txt || echo "1")
    
    local clash_cert_verify="false"
    if [[ "$is_insecure_url" == "0" ]]; then
        clash_cert_verify="false"
        echo "$c_domain" > /etc/hysteria/sub_host.txt
    else
        clash_cert_verify="true"
        echo "$ip" > /etc/hysteria/sub_host.txt
    fi

    local obfs_param=""
    local clash_obfs_block=""
    if [[ -n "$s_obfs_pwd" ]]; then
        obfs_param="&obfs=salamander&obfs-password=${s_obfs_pwd}"
        clash_obfs_block="    obfs: salamander\n    obfs-password: \"$s_obfs_pwd\""
    fi

    local c_up=$(cat /etc/hysteria/c_up.txt || echo "0")
    local c_down=$(cat /etc/hysteria/c_down.txt || echo "0")
    local clash_bw_block=""
    if [[ "$c_up" != "0" ]]; then
        clash_bw_block="    up: '${c_up} mbps'\n    down: '${c_down} mbps'"
    fi

    local yaml_json_ip="$ip"
    local uri_ip="$ip"
    [[ "$ip" == *":"* ]] && uri_ip="[$ip]"

    local mport_param=""
    [[ -n "$hop_ports" ]] && mport_param="&mport=$hop_ports"

    local web_dir="/var/www/hysteria"
    mkdir -p "$web_dir"

    local sub_uuid=$(gen_random_str 16)
    mkdir -p "$web_dir/$sub_uuid"
    echo "$sub_uuid" > /etc/hysteria/sub_path.txt

    local url="hy2://$s_pwd@$uri_ip:$primary_port/?insecure=${is_insecure_url}&sni=$c_domain${mport_param}${obfs_param}#${custom_node_name}"
    echo "$url" > "$web_dir/$sub_uuid/url.txt"
    printf "%s" "$url" | base64 | tr -d '\r\n' > "$web_dir/$sub_uuid/sub_b64.txt"

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
$(echo -e "$clash_obfs_block")
$(echo -e "$clash_bw_block")

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

    local sub_port=$(cat /etc/hysteria/sub_port.txt)
    local sub_cert_dir="$web_dir/certs"
    mkdir -p "$sub_cert_dir"
    
    echo "  [调试] 拷贝证书供订阅系统使用..."
    cp -L "$cert_path" "$sub_cert_dir/cert.crt" || cp -L /etc/hysteria/cert.crt "$sub_cert_dir/cert.crt"
    cp -L "$key_path" "$sub_cert_dir/private.key" || cp -L /etc/hysteria/private.key "$sub_cert_dir/private.key"
    
    chown -R nobody "$sub_cert_dir"
    chmod 400 "$sub_cert_dir/private.key"
    
    cat << EOF > "$web_dir/server.py"
import http.server
import socketserver
import ssl
import os
import urllib.parse
import socket

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
                self.wfile.write(B64_DATA + b"\n")
        else:
            self.send_response(403)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(b"<html><head><title>403 Forbidden</title></head><body><center><h1>403 Forbidden</h1></center><hr><center>nginx</center></body></html>")

class DualStackServer(socketserver.TCPServer):
    allow_reuse_address = True
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        s.close()
        address_family = socket.AF_INET6
    except Exception:
        pass

with DualStackServer(("", PORT), SecureSubHandler) as httpd:
    if "${is_insecure_url}" == "0" and os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
    httpd.serve_forever()
EOF

    chown -R nobody "$web_dir"
    
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
        rc-update add hysteria-sub default
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
        systemctl enable hysteria-sub
    fi
    
    echo "  [调试] 重启订阅服务..."
    svc_stop hysteria-sub
    svc_start hysteria-sub
}

insthysteria() {
    if [[ -f "/etc/hysteria/config.yaml" || -f "/usr/local/bin/hysteria" ]]; then
        echo ""
        yellow "  检测到旧版本配置，正在清理旧规则与文件..."
        clean_env "keep_certs"
    fi
    
    check_env
    mkdir -p /etc/hysteria
    
    api_port=$(shuf -i 30000-60000 -n 1)
    while ss -tnl | grep -E -q ":$api_port( |$)"; do api_port=$(shuf -i 30000-60000 -n 1); done
    echo "$api_port" > /etc/hysteria/api_port.txt
    
    arch=$(uname -m)
    case $arch in
        x86_64) hy_arch="amd64" ;;
        aarch64) hy_arch="arm64" ;;
        s390x) hy_arch="s390x" ;;
        *) red " [错误] 不支持的架构: $arch" && exit 1 ;;
    esac
    
    echo "  [调试] 开始下载 Hysteria2 核心文件..."
    wget -N -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${hy_arch}"
    
    if [[ $? -ne 0 ]] || [[ ! -s /usr/local/bin/hysteria ]]; then
        red " [错误] Hysteria 2 核心下载失败或文件损坏！"
        rm -f /usr/local/bin/hysteria
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
rc_ulimit="-n 1048576"
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
LimitNOFILE=1048576
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
    inst_other_configs

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

quic:
  mtu: 1400

tls:
  cert: $cert_path
  key: $key_path

auth:
  type: password
  password: $auth_pwd

$(if [[ "$bw_up_input" != "0" ]]; then
echo "bandwidth:
  up: $bw_up
  down: $bw_down
ignoreClientBandwidth: true"
fi)

$(if [[ -n "$obfs_pwd" ]]; then
echo "obfs:
  type: salamander
  salamander:
    password: \"$obfs_pwd\""
fi)

resolver:
  type: udp
  udp:
    addr: 8.8.8.8:53
    timeout: 4s

acl:
  inline:
    - reject(127.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(fc00::/7)
    - reject(fe80::/10)
    - direct(all)

masquerade:
  type: proxy
  proxy:
    url: https://$proxysite
    rewriteHost: true

trafficStats:
  listen: 127.0.0.1:$api_port
EOF
    
    chmod 600 /etc/hysteria/config.yaml

    local last_port=$port
    [[ -n $firstport ]] && last_port="$port,$firstport-$endport"
    local last_ip=$ip
    [[ "$ip" == *":"* ]] && last_ip="[$ip]"

    cat << EOF > /etc/hysteria/hy-client.yaml
server: $last_ip:$last_port
auth: $auth_pwd
tls:
  sni: $hy_domain
  insecure: $cert_insecure_yaml
EOF

    echo "  [调试] 启动 Hysteria 主服务..."
    svc_enable hysteria-server
    svc_start hysteria-server
    
    generate_client_configs
    
    echo ""
    green "  Hysteria 2 服务端部署完成！请在主菜单选择 [5] 获取节点。"
    sleep 3
}

unsthysteria() {
    echo ""
    yellow "  正在清理系统文件和防火墙规则..."
    clean_env "all"
    rm -f /usr/local/bin/hy2
    green "  Hysteria 2 已彻底清理！"
    sleep 2
    exit 0
}

showconf() {
    realip
    
    local sub_port=$(cat /etc/hysteria/sub_port.txt)
    local sub_path=$(cat /etc/hysteria/sub_path.txt)
    local sub_host=$(cat /etc/hysteria/sub_host.txt)
    local is_insecure=$(cat /etc/hysteria/insecure_state.txt)
    local main_port=$(grep -E "^[[:space:]]*listen:" /etc/hysteria/config.yaml | awk -F ':' '{print $NF}' | tr -d ' ' | tr -d '\r')
    local hop_ports=$(grep '^server:' /etc/hysteria/hy-client.yaml | awk -F ',' '{print $2}')
    
    [[ -z "$sub_host" || "$sub_host" == "" ]] && sub_host=$ip
    local protocol="https"
    [[ "$is_insecure" == "1" ]] && protocol="http"
    
    local sub_url=""
    if [[ "$sub_host" == *":"* ]]; then
        sub_url="${protocol}://[${sub_host}]:${sub_port}/${sub_path}"
    else
        sub_url="${protocol}://${sub_host}:${sub_port}/${sub_path}"
    fi

    local web_dir="/var/www/hysteria"
    local raw_url=$(cat "$web_dir/$sub_path/url.txt")
    
    clear
    green "  ▶ [智能订阅链接] (推荐)"
    green "    ${sub_url}"
    echo ""
    yellow "  ▶ [单节点直连链接]"
    green "    ${raw_url}"
    echo ""
    
    if ! command -v qrencode &> /dev/null; then
        echo "  [调试] 正在安装 qrencode 二维码组件..."
        if [[ $SYSTEM == "Ubuntu" || $SYSTEM == "Debian" ]]; then
            apt-get update -y; apt-get install -y qrencode
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            yum install -y epel-release; yum install -y qrencode
        elif [[ $SYSTEM == "Alpine" ]]; then
            apk update; apk add libqrencode-tools
        fi
    fi

    if command -v qrencode &> /dev/null; then
        qrencode -t ANSIUTF8 "$raw_url"
    else
        curl -d "$raw_url" https://qrenco.de
    fi
    
    echo ""
    echo -e "    ${LIGHT_GREEN}主节点端口: ${main_port} (UDP)${PLAIN}"
    if [[ -n "$hop_ports" ]]; then echo -e "    ${LIGHT_RED}跳跃组: ${hop_ports} (UDP)${PLAIN}"; fi
    echo -e "    ${LIGHT_GREEN}订阅端口: ${sub_port} (TCP)${PLAIN}"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回... ${PLAIN}"
    read temp
}

edit_config() {
    clear
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "  未检测到配置文件！"; sleep 2; return
    fi
    
    cat /etc/hysteria/config.yaml
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 是否需要修改配置文件？(y/n) [默认: n]: ${PLAIN}"
    read edit_choice
    if [[ "$edit_choice" == "y" || "$edit_choice" == "Y" ]]; then
        if command -v nano &>/dev/null; then nano /etc/hysteria/config.yaml
        elif command -v vi &>/dev/null; then vi /etc/hysteria/config.yaml
        fi
        
        echo "  [调试] 重启服务使新配置生效..."
        svc_stop hysteria-server; svc_start hysteria-server
        sleep 1
        
        if [[ $SYSTEM == "Alpine" ]]; then
            if rc-service hysteria-server status | grep -q 'started'; then
                green "  重启成功！更新订阅配置..."; generate_client_configs
            else red "  [错误] 服务启动失败！"
            fi
        else
            if systemctl is-active --quiet hysteria-server; then
                green "  重启成功！更新订阅配置..."; generate_client_configs
            else red "  [错误] 服务启动失败！查看 systemctl status hysteria-server 了解详情。"
            fi
        fi
    fi
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回... ${PLAIN}"
    read temp
}

# =================================================================
#  重点整合：全新流量统计与故障自动抓取模块
# =================================================================
check_traffic() {
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "  未检测到 Hysteria 2 配置文件！"; sleep 2; return
    fi
    
    if ! grep -q -E "^[[:space:]]*trafficStats:" /etc/hysteria/config.yaml; then
        local api_port=$(shuf -i 30000-60000 -n 1)
        while ss -tnl | grep -E -q ":$api_port( |$)"; do api_port=$(shuf -i 30000-60000 -n 1); done
        echo "$api_port" > /etc/hysteria/api_port.txt
        
        echo -e "\ntrafficStats:\n  listen: 127.0.0.1:$api_port" >> /etc/hysteria/config.yaml
        
        echo "  [调试] 注入 trafficStats 配置并重启服务..."
        svc_stop hysteria-server; svc_start hysteria-server
        sleep 2
        yellow "  流量 API 已激活！请连接并产生流量后再来查看。"
        echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回... ${PLAIN}"
        read temp; return
    else
        local api_port=$(awk '/^[[:space:]]*trafficStats:/{flag=1} flag && /listen:/{print $NF; exit}' /etc/hysteria/config.yaml | awk -F ':' '{print $NF}' | tr -d '\r' | tr -d ' ')
        [[ -z "$api_port" ]] && api_port=$(cat /etc/hysteria/api_port.txt | tr -d '\r')
    fi

    echo "  [调试] 正在向 127.0.0.1:$api_port 发起流量数据请求..."
    # 移除 -s 标志并强制抓取所有 HTTP 返回码与内容
    local traffic_data=$(curl --max-time 3 "http://127.0.0.1:$api_port/traffic")
    
    clear
    print_line
    green "                    客户端连接与流量统计                   "
    print_line
    
    if [[ -z "$traffic_data" || "$traffic_data" =~ "404" ]]; then
        red "  获取数据失败，Hysteria 服务未运行，或 API 端口超时。"
    else
        export TRAFFIC_JSON_DATA="${traffic_data}"
        python3 -c "
import os, json
try:
    data_str = os.environ.get('TRAFFIC_JSON_DATA', '').strip()
    if not data_str:
        print('\033[33m  暂无记录。\033[0m')
    else:
        data = json.loads(data_str)
        if not data:
            print('\033[33m  暂无记录。\033[0m')
        else:
            print('\033[32m  活跃客户端总数: ' + str(len(data)) + '\033[0m\n')
            for user, stats in data.items():
                tx_mb = stats.get('tx', 0) / 1048576
                rx_mb = stats.get('rx', 0) / 1048576
                print('\033[33m  账号: {} | 发送: {:.2f} MB | 接收: {:.2f} MB\033[0m'.format(user, tx_mb, rx_mb))
except ValueError:
    print('\033[31m  [致命错误] API 端口返回的不是 JSON！可能是端口冲突导致。\033[0m')
    print('\033[33m  [核心调试日志] 以下是我们在端口抓取到的阻断信息：\033[0m')
    print('----------------------------------------------------')
    print(data_str)
    print('----------------------------------------------------')
except Exception as e:
    print('\033[31m  Python 执行异常: ' + str(e) + '\033[0m')
"
    fi
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回... ${PLAIN}"
    read temp
}

starthysteria() {
    echo "  [调试] 正在启动服务进程..."
    svc_start hysteria-server; svc_start hysteria-sub
    sleep 2
}

stophysteria_only() {
    echo "  [调试] 正在停止服务进程..."
    svc_stop hysteria-server; svc_stop hysteria-sub
}

hysteriaswitch() {
    clear
    echo -e "    ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}启动 服务${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_RED}停止 服务${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[3]${PLAIN} ${LIGHT_YELLOW}重启 服务${PLAIN}"
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项: ${PLAIN}"
    read switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria_only; sleep 2 ;;
        3 ) stophysteria_only; starthysteria ;;
        * ) return ;;
    esac
}

enable_bbr() {
    local kernel_v=$(uname -r | cut -d. -f1)
    if [[ "$kernel_v" -lt 4 ]]; then red " 内核不支持！"; sleep 3; return; fi

    echo "  [调试] 加载 bbr 内核模块..."
    modprobe tcp_bbr
    
    sed -i '/^[[:space:]]*net\.core\.default_qdisc/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.rmem_max/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.rmem_default/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.wmem_max/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.wmem_default/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.ipv4\.udp_mem/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.netdev_max_backlog/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.somaxconn/d' /etc/sysctl.conf

    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.core.rmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.rmem_default=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_default=26214400" >> /etc/sysctl.conf
    echo "net.core.netdev_max_backlog=100000" >> /etc/sysctl.conf
    echo "net.core.somaxconn=65535" >> /etc/sysctl.conf
    echo "net.ipv4.udp_mem=65536 131072 262144" >> /etc/sysctl.conf
    
    echo "  [调试] 应用系统级 TCP/UDP 优化参数..."
    sysctl -p
    
    green "  BBR 开启成功！"
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回... ${PLAIN}"
    read temp
}

check_cert() {
    clear
    if [[ ! -f /etc/hysteria/config.yaml ]]; then red "  未检测到配置！"; return; fi

    local cert_path=$(grep -w 'cert:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d '"' | tr -d "'")

    if [[ -z "$cert_path" || ! -f "$cert_path" ]]; then
        red "  [✘] 未找到证书文件！"
    else
        green "  [✔] 证书已就绪！路径: $cert_path"
        if command -v openssl &>/dev/null; then
            echo "  [调试] 读取证书内部信息..."
            local cert_subject=$(openssl x509 -in "$cert_path" -noout -subject | awk -F'CN = |CN=' '{print $2}' | awk -F',' '{print $1}')
            local cert_issuer=$(openssl x509 -in "$cert_path" -noout -issuer | awk -F'CN = |CN=|O = |O=' '{print $2}' | awk -F',' '{print $1}')
            local cert_end=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
            
            yellow "  ▶ 域名: ${cert_subject}"
            yellow "  ▶ 机构: ${cert_issuer}"
            yellow "  ▶ 过期: $cert_end"
        fi
    fi
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回... ${PLAIN}"
    read temp
}

# =================================================================
#  8. 主菜单控制
# =================================================================
menu() {
    clear
    green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "${LIGHT_GREEN}  ██████╗  ██╗   ██╗ ██████╗  ██╗       █████╗ ${PLAIN}"
    echo -e "${LIGHT_GREEN}  ██╔══██╗ ██║   ██║ ██╔═══██╗██║      ██╔══██╗${PLAIN}"
    echo -e "${LIGHT_GREEN}  ██║  ██║ ██║   ██║ ██║   ██║██║      ███████║${PLAIN}"
    echo -e "${LIGHT_GREEN}  ██║  ██║ ██║   ██║ ██║   ██║██║      ██╔══██║${PLAIN}"
    echo -e "${LIGHT_GREEN}  ██████╔╝ ╚██████╔╝ ╚██████╔╝███████╗ ██║  ██║${PLAIN}"
    echo -e "${LIGHT_GREEN}  ╚═════╝   ╚══════╝  ╚═════╝ ╚══════╝ ╚═╝  ╚═╝${PLAIN}"
    green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "  ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}安装部署 Hysteria 2${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_RED}彻底卸载 Hysteria 2${PLAIN}"
    echo "----------------------------------------------------------------------------------"
    echo -e "  ${LIGHT_GREEN}[3]${PLAIN} ${LIGHT_YELLOW}启动 / 停止 / 重启服务${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[4]${PLAIN} ${LIGHT_PURPLE}查看 / 修改 配置文件${PLAIN}"
    echo "----------------------------------------------------------------------------------"
    echo -e "  ${LIGHT_GREEN}[5]${PLAIN} ${LIGHT_GREEN}获取 节点配置 与 订阅链接${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[6]${PLAIN} ${LIGHT_YELLOW}查看 客户端连接 与 流量统计${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[7]${PLAIN} ${LIGHT_PURPLE}开启 BBR 及 UDP 极限并发加速${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[8]${PLAIN} ${LIGHT_GREEN}检查 证书详细信息${PLAIN}"
    echo "----------------------------------------------------------------------------------"
    echo -e "  ${LIGHT_GREEN}[0]${PLAIN} ${LIGHT_RED}退出脚本${PLAIN}"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [0-8]: ${PLAIN}"
    read menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) edit_config ;;
        5 ) showconf ;;
        6 ) check_traffic ;;
        7 ) enable_bbr ;;
        8 ) check_cert ;;
        0 ) exit 0 ;;
        * ) red "  输入无效"; sleep 1 ;;
    esac
}

while true; do
    menu
done
