#!/bin/bash

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

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
PACKAGE_INSTALL=("apk add" "apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install")

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

# 获取公网真实IP (优化双栈并发与超时体验)
realip() {
    ip=$(curl -s --max-time 3 ip.sb -k | grep -m 1 -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}|([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:)*:[0-9a-fA-F]{1,4}")
    
    if [[ -z "$ip" ]]; then
        ip=$(curl -s4m3 api.ipify.org -k || curl -s6m3 api64.ipify.org -k || curl -s4m3 ifconfig.me -k || curl -s6m3 ifconfig.me -k)
        ip=$(echo "$ip" | grep -m 1 -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}|([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:)*:[0-9a-fA-F]{1,4}")
    fi
    
    if [[ -z "$ip" ]]; then
        echo ""
        red " [错误] 无法获取本机的公网 IP，请检查 VPS 的网络连接或 DNS 设置！"
        exit 1
    fi
}

# 随机高强度字符生成
gen_random_str() {
    local len=$1
    cat /proc/sys/kernel/random/uuid | tr -d '-' | cut -c 1-$len || head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n' | cut -c 1-$len
}

# =================================================================
#  3. 服务管理与防火墙控制封装 (开放原生报错输出并修复 Firewalld)
# =================================================================
svc_start()   { if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" start; else systemctl start "$1"; fi; }
svc_stop()    { if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" stop; else systemctl stop "$1"; fi; }
svc_enable()  { if [[ $SYSTEM == "Alpine" ]]; then rc-update add "$1" default; else systemctl enable "$1"; fi; }
svc_disable() { if [[ $SYSTEM == "Alpine" ]]; then rc-update del "$1" default; else systemctl disable "$1"; fi; }

save_iptables() {
    if [[ $SYSTEM == "Alpine" ]]; then
        rc-service iptables save
        rc-service ip6tables save
    elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
        service iptables save
        service ip6tables save
    else
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save
        fi
    fi
}

open_port() {
    local port=$1
    local proto=$2
    iptables -I INPUT -p $proto --dport $port -j ACCEPT
    ip6tables -I INPUT -p $proto --dport $port -j ACCEPT
    if command -v ufw >/dev/null; then ufw allow $port/$proto; fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --zone=public --add-port=$port/$proto --permanent
        firewall-cmd --reload
    fi
    save_iptables
}

close_port() {
    local port=$1
    local proto=$2
    iptables -D INPUT -p $proto --dport $port -j ACCEPT
    ip6tables -D INPUT -p $proto --dport $port -j ACCEPT
    if command -v ufw >/dev/null; then ufw delete allow $port/$proto; fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
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
        if ! command -v "$cmd" > /dev/null; then
            red "   [✘] 缺失:  $cmd"
            missing=1
        else
            green "   [✔] 正常:  $cmd"
        fi
    done

    if ! command -v crontab > /dev/null; then
        red "   [✘] 缺失:  crontab (用于证书自动续期)"
        missing=1
    else
        green "   [✔] 正常:  crontab"
    fi

    if [[ $SYSTEM == "Debian" || $SYSTEM == "Ubuntu" ]]; then
        if ! command -v netfilter-persistent > /dev/null; then
            red "   [✘] 缺失:  netfilter-persistent (用于防火墙保存)"
            missing=1
        else
            green "   [✔] 正常:  netfilter-persistent"
        fi
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        print_line
        yellow "  发现缺失前置组件，正在为您自动拉取安装，执行日志如下..."
        echo ""
        
        [[ ! $SYSTEM == "CentOS" ]] && { $PKG_UPDATE || { echo ""; red " [错误] 系统软件源更新失败！请检查网络连接或更换软件源后重试。"; exit 1; }; }
        
        if [[ $SYSTEM == "Alpine" ]]; then
            $PKG_INSTALL curl wget sudo procps iptables ip6tables iproute2 python3 openssl socat cronie libqrencode-tools || { echo ""; red " [错误] 前置依赖安装失败！请检查系统源或网络后重试。"; exit 1; }
            svc_start crond; svc_enable crond
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            $PKG_INSTALL epel-release || { echo ""; red " [错误] epel-release 扩展源安装失败！"; exit 1; }
            $PKG_INSTALL curl wget sudo procps iptables iptables-services iproute python3 openssl socat cronie qrencode || { echo ""; red " [错误] 前置依赖安装失败！请检查系统源或网络后重试。"; exit 1; }
            svc_start crond; svc_enable crond
        else
            yellow "  正在尝试修复并清理系统损坏的依赖项..."
            apt-get --fix-broken install -y || { echo ""; red " [错误] 尝试修复系统损坏的依赖项失败！"; exit 1; }
            apt-get autoremove -y
            apt-get clean
            $PKG_INSTALL curl wget sudo procps iptables-persistent netfilter-persistent iproute2 python3 openssl socat cron qrencode || { echo ""; red " [错误] 前置依赖安装失败！请检查 APT 源或网络后重试。"; exit 1; }
            svc_start cron; svc_enable cron
        fi
        
        echo ""
        green "  所有前置依赖补全完成！"
    else
        echo ""
        print_line
        green "  所有前置依赖检查通过，环境完美，无需额外安装！"
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
                yellow " [警告] 无法解析域名 ${domain} 的 IP 地址！请确认域名已正确解析。"
                echo -en " ${LIGHT_YELLOW} ▶ 是否强制继续？(y/n) [默认: y]: ${PLAIN}"
                read force_cert
                [[ -z "$force_cert" ]] && force_cert="y"
                [[ "$force_cert" != "y" && "$force_cert" != "Y" ]] && exit 1
            elif [[ "$domainIP" != "$ip" ]]; then
                echo ""
                yellow " [警告] 域名解析的 IP ($domainIP) 与当前真实 IP ($ip) 不匹配！"
                yellow " [警告] Hysteria 2 必须使用真实 IP 直连，请确保 Cloudflare 已关闭小云朵 (DNS Only)。"
                echo -en " ${LIGHT_YELLOW} ▶ 是否确认并继续？(y/n) [默认: y]: ${PLAIN}"
                read force_cert
                [[ -z "$force_cert" ]] && force_cert="y"
                [[ "$force_cert" != "y" && "$force_cert" != "Y" ]] && exit 1
            fi

            echo ""
            print_line
            yellow "  准备使用 Cloudflare DNS API 申请证书"
            print_line
            echo ""
            echo -en " ${LIGHT_YELLOW} ▶ 选择认证方式 [1. API Token(推荐) | 2. Global API Key]: ${PLAIN}"
            read cf_auth_choice
            [[ -z "$cf_auth_choice" ]] && cf_auth_choice=1

            install_acme() {
                local acme_email="$1"
                if [[ ! -f "/root/.acme.sh/acme.sh" ]]; then
                    yellow "  正在安全拉取 Acme.sh 安装脚本..."
                    curl -sL --max-time 20 -o /tmp/acme_install.sh https://get.acme.sh || curl -sL --max-time 20 -o /tmp/acme_install.sh https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh
                    if [[ ! -s /tmp/acme_install.sh ]]; then
                        red "  [错误] Acme.sh 下载失败！请检查网络连接或更换 DNS。"
                        rm -f /tmp/acme_install.sh
                        exit 1
                    fi
                    sh /tmp/acme_install.sh email="$acme_email" || { red "  [错误] Acme.sh 安装过程报错！"; rm -f /tmp/acme_install.sh; exit 1; }
                    rm -f /tmp/acme_install.sh
                fi
            }

            if [[ "$cf_auth_choice" == 1 ]]; then
                echo -en " ${LIGHT_YELLOW} ▶ 请输入 Cloudflare API Token: ${PLAIN}"
                read cf_token
                [[ -z "$cf_token" ]] && red " Token 不能为空！" && exit 1
                export CF_Token="$(echo "$cf_token" | tr -d '\r' | tr -d ' ')"
                install_acme "admin@${domain}"
            else
                echo -en " ${LIGHT_YELLOW} ▶ 请输入 Cloudflare 账号邮箱: ${PLAIN}"
                read cf_email
                echo -en " ${LIGHT_YELLOW} ▶ 请输入 Cloudflare Global API Key: ${PLAIN}"
                read cf_key
                [[ -z "$cf_email" || -z "$cf_key" ]] && red " 邮箱或 Key 不能为空！" && exit 1
                export CF_Email="$(echo "$cf_email" | tr -d '\r' | tr -d ' ')"
                export CF_Key="$(echo "$cf_key" | tr -d '\r' | tr -d ' ')"
                install_acme "$CF_Email"
            fi
            
            bash /root/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            rm -f /root/cert.crt /root/private.key /root/ca.log

            yellow " 正在通过 DNS API 验证所有权，请留意下方执行日志 (约1-3分钟)..."
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
                green " 证书申请成功！已保存至 /root/ 目录下。"
                hy_domain="$domain"
            else
                red " [错误] 证书申请失败！请向上翻阅执行日志检查具体报错信息。"
                exit 1
            fi
        fi
    elif [[ "$certInput" == 3 ]]; then
        echo ""
        while true; do
            echo -en " ${LIGHT_YELLOW} ▶ 请输入公钥(crt)的绝对路径: ${PLAIN}"
            read cert_path
            cert_path=$(echo "$cert_path" | tr -d '\r' | tr -d ' ')
            if [[ -f "$cert_path" ]]; then break; else red " [错误] 文件不存在，请重新输入！"; fi
        done
        while true; do
            echo -en " ${LIGHT_YELLOW} ▶ 请输入密钥(key)的绝对路径: ${PLAIN}"
            read key_path
            key_path=$(echo "$key_path" | tr -d '\r' | tr -d ' ')
            if [[ -f "$key_path" ]]; then break; else red " [错误] 文件不存在，请重新输入！"; fi
        done
        while true; do
            echo -en " ${LIGHT_YELLOW} ▶ 请输入对应的域名: ${PLAIN}"
            read domain
            domain=$(echo "$domain" | tr -d '\r' | tr -d ' ')
            if [[ -n "$domain" ]]; then break; else red " [错误] 域名不能为空！"; fi
        done
        hy_domain="$domain"
    else
        echo ""
        green " 已选择 必应(Bing)自签伪装证书，开始生成密钥与证书..."
        mkdir -p /etc/hysteria
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
        openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com"
        chmod 644 /etc/hysteria/cert.crt; chmod 600 /etc/hysteria/private.key

        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port() {
    echo ""
    print_line
    echo -en " ${LIGHT_YELLOW} ▶ 设置 Hysteria 2 主端口 [10000-65535] (回车随机): ${PLAIN}"
    read port
    [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    
    while [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; do
        red " [警告] 端口必须是 1-65535 之间的纯数字！"
        echo -en " ${LIGHT_YELLOW} ▶ 重新设置主端口: ${PLAIN}"
        read port
        [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    done

    while ss -unl | grep -E -q ":$port( |$)"; do
        red " [警告] 端口 $port 已被占用！"
        echo -en " ${LIGHT_YELLOW} ▶ 重新设置主端口: ${PLAIN}"
        read port
        [[ -z $port ]] && port=$(shuf -i 10000-65535 -n 1)
    done
    green " 节点主端口已设置为: $port"
    open_port $port "udp"

    echo ""
    yellow "  端口模式选择："
    echo -e "    ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}单端口直连 (默认)${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_PURPLE}端口跳跃模式 (防封锁黑科技)${PLAIN}"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [1-2] (默认1): ${PLAIN}"
    read jumpInput
    if [[ $jumpInput == 2 ]]; then
        echo ""
        echo -en " ${LIGHT_YELLOW} ▶ 请输入起始端口 (建议10000-65535): ${PLAIN}"
        read firstport
        while [[ ! "$firstport" =~ ^[0-9]+$ ]] || [[ "$firstport" -lt 1 ]] || [[ "$firstport" -gt 65535 ]]; do
            red " [警告] 起始端口必须是数字！"
            echo -en " ${LIGHT_YELLOW} ▶ 重新输入起始端口: ${PLAIN}"
            read firstport
        done

        echo -en " ${LIGHT_YELLOW} ▶ 请输入末尾端口 (必须大于起始端口): ${PLAIN}"
        read endport
        while [[ ! "$endport" =~ ^[0-9]+$ ]] || [[ "$endport" -le "$firstport" ]] || [[ "$endport" -gt 65535 ]]; do
            red " [警告] 末尾端口无效！"
            echo -en " ${LIGHT_YELLOW} ▶ 重新输入末尾端口: ${PLAIN}"
            read endport
        done
        green " 已开启端口跳跃范围: $firstport - $endport"

        echo "$firstport:$endport" > /etc/hysteria/port_hop.txt

        modprobe ip6table_nat || true
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j REDIRECT --to-ports $port -m comment --comment "hy2-port-hop"
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j REDIRECT --to-ports $port -m comment --comment "hy2-port-hop"
        if command -v ufw >/dev/null; then ufw allow $firstport:$endport/udp; fi
        if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --zone=public --add-port=$firstport-$endport/udp --permanent
            firewall-cmd --reload
        fi
        save_iptables
    fi
}

inst_sub_port(){
    echo ""
    print_line
    echo -en " ${LIGHT_YELLOW} ▶ 设置智能订阅服务端口 [1024-65535] (回车随机): ${PLAIN}"
    read sub_port_input
    [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    
    while [[ ! "$sub_port_input" =~ ^[0-9]+$ ]] || [[ "$sub_port_input" -lt 1024 ]] || [[ "$sub_port_input" -gt 65535 ]]; do
        red " [警告] 端口必须在 1024-65535 之间！"
        echo -en " ${LIGHT_YELLOW} ▶ 重新设置订阅端口: ${PLAIN}"
        read sub_port_input
        [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    done
    
    while ss -tnl | grep -E -q ":$sub_port_input( |$)"; do
        red " [警告] 端口 $sub_port_input 已被占用！"
        echo -en " ${LIGHT_YELLOW} ▶ 重新设置订阅端口: ${PLAIN}"
        read sub_port_input
        [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    done
    green " 订阅端口已设置为: $sub_port_input"
    open_port $sub_port_input "tcp"
    
    mkdir -p /etc/hysteria
    echo "$sub_port_input" > /etc/hysteria/sub_port.txt
}

inst_other_configs() {
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 设置节点连接密码 (回车自动生成): ${PLAIN}"
    read auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(gen_random_str 8)
    green " 连接密码为: $auth_pwd"

    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 伪装网站地址 (不带 https://) [回车默认 www.bing.com]: ${PLAIN}"
    read proxysite
    [[ -z $proxysite ]] && proxysite="www.bing.com"

    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 节点显示名称 (勿含空格特殊字符) [回车默认 Hysteria2_Node]: ${PLAIN}"
    read custom_node_name
    [[ -z $custom_node_name ]] && custom_node_name="Hysteria2_Node"

    echo ""
    print_line
    yellow "  拥塞控制配置 (降低延迟的核心)"
    purple "  输入 0 将关闭 Brutal 算法并开启 BBR 回退自适应模式 (适合弱网或未知环境)"
    purple "  【优化提示】服务端已配置防滥用机制，将强制接管带宽上限！"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 请输入 VPS 最大上行带宽 (Mbps, 输入 0 开启 BBR 自适应模式): ${PLAIN}"
    read bw_up_input
    [[ -z $bw_up_input ]] && bw_up_input="0"
    while [[ ! "$bw_up_input" =~ ^[0-9]+$ ]]; do
        red " [警告] 仅限纯数字！"
        echo -en " ${LIGHT_YELLOW} ▶ 重新输入上行带宽 (Mbps): ${PLAIN}"
        read bw_up_input
    done
    
    if [[ "$bw_up_input" != "0" ]]; then
        bw_up="${bw_up_input} mbps"
        echo -en " ${LIGHT_YELLOW} ▶ 请输入 VPS 最大下行带宽 (Mbps, 回车默认 1000): ${PLAIN}"
        read bw_down_input
        [[ -z $bw_down_input ]] && bw_down_input="1000"
        while [[ ! "$bw_down_input" =~ ^[0-9]+$ ]]; do
            red " [警告] 仅限纯数字！"
            echo -en " ${LIGHT_YELLOW} ▶ 重新输入下行带宽 (Mbps): ${PLAIN}"
            read bw_down_input
        done
        bw_down="${bw_down_input} mbps"
        
        echo ""
        purple "  为生成最佳的客户端配置，请填写您本地网络（家庭/公司）的实际宽带速度："
        echo -en " ${LIGHT_YELLOW} ▶ 本地真实下载速度 (Mbps, 回车默认 500): ${PLAIN}"
        read c_down
        [[ -z $c_down ]] && c_down="500"
        echo -en " ${LIGHT_YELLOW} ▶ 本地真实上传速度 (Mbps, 回车默认 50): ${PLAIN}"
        read c_up
        [[ -z $c_up ]] && c_up="50"
        echo "$c_down" > /etc/hysteria/c_down.txt
        echo "$c_up" > /etc/hysteria/c_up.txt
    else
        green " 已开启 BBR 自适应回退模式！"
        echo "0" > /etc/hysteria/c_down.txt
        echo "0" > /etc/hysteria/c_up.txt
    fi

    echo ""
    print_line
    yellow "  防阻断混淆(Obfuscation)配置"
    purple "  开启 Salamander 混淆可防运营商 QoS 限速与封锁。"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 是否开启混淆？(y/n) [默认: y]: ${PLAIN}"
    read enable_obfs
    [[ -z $enable_obfs ]] && enable_obfs="y"
    if [[ "$enable_obfs" == "y" || "$enable_obfs" == "Y" ]]; then
        obfs_pwd=$(gen_random_str 12)
        green " 已开启混淆，系统生成的密钥为: $obfs_pwd"
    else
        obfs_pwd=""
        yellow " 已跳过混淆配置。"
    fi
}

# =================================================================
#  6. 核心业务处理与部署逻辑
# =================================================================
clean_env() {
    local mode="$1"
    
    local main_port=$(grep -E "^[[:space:]]*listen:" /etc/hysteria/config.yaml 2>/dev/null | awk -F ':' '{print $NF}' | tr -d ' ' | tr -d '\r')
    local sub_port=$(cat /etc/hysteria/sub_port.txt 2>/dev/null | tr -d '\r')

    [[ -n "$main_port" && "$main_port" =~ ^[0-9]+$ ]] && close_port "$main_port" "udp"
    [[ -n "$sub_port" && "$sub_port" =~ ^[0-9]+$ ]] && close_port "$sub_port" "tcp"

    if command -v iptables >/dev/null; then
        iptables -t nat -nL PREROUTING --line-numbers 2>/dev/null | grep "hy2-port-hop" | awk '{print $1}' | sort -nr | while read -r num; do
            iptables -t nat -D PREROUTING "$num"
        done
    fi
    if command -v ip6tables >/dev/null; then
        ip6tables -t nat -nL PREROUTING --line-numbers 2>/dev/null | grep "hy2-port-hop" | awk '{print $1}' | sort -nr | while read -r num; do
            ip6tables -t nat -D PREROUTING "$num"
        done
    fi

    if [[ -f /etc/hysteria/port_hop.txt ]]; then
        local hop_range=$(cat /etc/hysteria/port_hop.txt | tr -d '\r')
        local f_port=$(echo "$hop_range" | cut -d':' -f1)
        local e_port=$(echo "$hop_range" | cut -d':' -f2)
        if [[ -n "$f_port" && -n "$e_port" ]]; then
            if command -v ufw >/dev/null; then ufw delete allow "$f_port:$e_port/udp"; fi
            if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
                firewall-cmd --zone=public --remove-port="$f_port-$e_port/udp" --permanent
                firewall-cmd --reload
            fi
        fi
    fi

    svc_stop hysteria-server 2>/dev/null; svc_disable hysteria-server 2>/dev/null
    svc_stop hysteria-sub 2>/dev/null; svc_disable hysteria-sub 2>/dev/null

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
        rm -rf /root/.acme.sh
        echo ""
        green "  [提示] 证书及 Acme.sh 环境已彻底清除。"
    elif [[ "$mode" == "keep" ]]; then
        echo ""
        yellow "  [提示] Acme.sh 环境及已申请的证书被保留，未执行全局卸载。"
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
    
    if [[ "$ip" == *":"* ]]; then
        uri_ip="[$ip]"
    fi

    local mport_param=""
    if [[ -n "$hop_ports" ]]; then
        mport_param="&mport=$hop_ports"
    fi

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
    sys_version = ""

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        req_path = parsed.path.strip('/')
        
        if req_path == SUB_UUID:
            self.send_response(200)
            self.send_header('Content-type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
            self.send_header('profile-update-interval', '24')
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
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        except AttributeError:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS)
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
    
    svc_stop hysteria-sub
    svc_start hysteria-sub
}

insthysteria() {
    if [[ -f "/etc/hysteria/config.yaml" || -f "/usr/local/bin/hysteria" ]]; then
        echo ""
        yellow "  检测到旧版本配置，正在清理旧规则与文件，为您重新生成..."
        clean_env "keep_certs"
        green "  旧文件清理完成，准备重新部署！"
    fi
    
    check_env
    mkdir -p /etc/hysteria
    
    api_port=$(shuf -i 30000-60000 -n 1)
    while ss -tnl | grep -E -q ":$api_port( |$)"; do api_port=$(shuf -i 30000-60000 -n 1); done
    echo "$api_port" > /etc/hysteria/api_port.txt
    
    echo ""
    print_line
    yellow "  正在下载 Hysteria 2 二进制核心..."
    arch=$(uname -m)
    case $arch in
        x86_64) hy_arch="amd64" ;;
        aarch64) hy_arch="arm64" ;;
        s390x) hy_arch="s390x" ;;
        *) red " [错误] 不支持的架构: $arch" && exit 1 ;;
    esac
    
    wget --timeout=10 --tries=3 -N -v -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${hy_arch}"
    
    if [[ ! -s /usr/local/bin/hysteria ]]; then
        red " [错误] Hysteria 2 核心下载失败或文件损坏，请根据上方输出排查网络！"
        rm -f /usr/local/bin/hysteria
        exit 1
    fi
    
    chmod +x /usr/local/bin/hysteria
    green "  核心下载完成！"
    
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

    # ===============================
    # 核心配置文件注入逻辑 (融合所有进阶优化)
    # ===============================
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

    svc_enable hysteria-server
    svc_start hysteria-server
    
    generate_client_configs
    
    echo ""
    print_line
    green "  Hysteria 2 服务端及智能订阅安装部署完成！"
    purple "  请在主菜单选择 [5] 获取节点与二维码。"
    echo ""
    sleep 3
}

unsthysteria() {
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 是否彻底删除已申请的域名证书及 Acme.sh 环境？(y/n) [默认: y]: ${PLAIN}"
    read rm_cert
    [[ -z "$rm_cert" ]] && rm_cert="y"

    yellow "  正在安全地清理系统网络、防火墙规则，并卸载相关文件..."
    
    if [[ "$rm_cert" == "y" || "$rm_cert" == "Y" ]]; then
        clean_env "all"
    else
        clean_env "keep"
    fi
    
    rm -f /usr/local/bin/hy2

    echo ""
    green "  Hysteria 2 服务及相关文件、端口规则已被彻底清理！"
    sleep 2
    exit 0
}

# =================================================================
#  7. 二级菜单功能与辅助工具
# =================================================================
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
    echo ""
    print_line
    green "                 Hysteria 2 全平台智能订阅                 "
    print_line
    echo ""
    yellow "  ▶ [智能订阅链接] (推荐)"
    purple "    适用客户端: Clash Verge / v2rayN / Shadowrocket"
    green  "    订阅地址: ${sub_url}"
    echo ""
    yellow "  ▶ [单节点直连链接]"
    purple "    适用客户端: NekoBox / v2rayNG (直接导入)"
    green  "    节点地址: ${raw_url}"
    echo ""
    
    if ! command -v qrencode > /dev/null; then
        yellow "  正在加载二维码模块..."
        if [[ $SYSTEM == "Ubuntu" || $SYSTEM == "Debian" ]]; then
            apt-get update -y
            apt-get install -y qrencode
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            yum install -y epel-release
            yum install -y qrencode
        elif [[ $SYSTEM == "Alpine" ]]; then
            apk update
            apk add libqrencode-tools
        fi
    fi

    if command -v qrencode > /dev/null; then
        echo ""
        purple "  提示：若二维码断层，请将终端字体缩小，或设置行间距为1.0"
        echo ""
        qrencode -t ANSIUTF8 "$raw_url"
    else
        echo ""
        yellow "  正通过在线 API 绘制二维码..."
        curl -s -d "$raw_url" https://qrenco.de
    fi
    
    echo ""
    print_line
    yellow "  ▶ 特别提醒（重要）："
    echo -e "    ${LIGHT_GREEN}若您使用的是 阿里云/腾讯云/AWS 等自带控制台防火墙的云服务器，${PLAIN}"
    echo -e "    ${LIGHT_GREEN}请务必在网页控制台的【安全组】中开放以下端口：${PLAIN}"
    echo -e "    ${LIGHT_GREEN}主节点端口: ${main_port} (UDP)${PLAIN}"
    if [[ -n "$hop_ports" ]]; then
        echo -e "    ${LIGHT_RED}跳跃端口组: ${hop_ports} (UDP) - 必须放行整个范围！${PLAIN}"
    fi
    echo -e "    ${LIGHT_GREEN}云订阅端口: ${sub_port} (TCP)${PLAIN}"
    echo -e "    ${LIGHT_PURPLE}若不开放上述云端防火墙，所有的订阅都将提示无效或超时！${PLAIN}"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回主菜单... ${PLAIN}"
    read temp
}

edit_config() {
    clear
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "  未检测到 Hysteria 2 配置文件，请先安装！"
        sleep 2; return
    fi
    
    echo ""
    print_line
    green "                  当前 Hysteria 2 节点配置                 "
    print_line
    echo ""
    cat /etc/hysteria/config.yaml
    echo ""
    print_line
    yellow "  [警告] 如果您在此处修改了 listen (主端口) 或通过系统修改了订阅端口，"
    yellow "         脚本将无法自动更新系统的防火墙规则！修改后请务必自行放行新端口。"
    print_line
    echo -en " ${LIGHT_YELLOW} ▶ 是否需要修改配置文件？(y/n) [默认: n]: ${PLAIN}"
    read edit_choice
    if [[ "$edit_choice" == "y" || "$edit_choice" == "Y" ]]; then
        if command -v nano >/dev/null; then
            nano /etc/hysteria/config.yaml
        elif command -v vi >/dev/null; then
            vi /etc/hysteria/config.yaml
        else
            red "  未找到 nano 或 vi 编辑器，请手动修改 /etc/hysteria/config.yaml"
        fi
        
        green "  正在重启 Hysteria 2 服务验证配置..."
        svc_stop hysteria-server
        svc_start hysteria-server
        sleep 1
        
        if [[ $SYSTEM == "Alpine" ]]; then
            if rc-service hysteria-server status | grep -q 'started'; then
                green "  重启成功！新配置已生效。"
                green "  正在同步更新客户端订阅配置..."
                generate_client_configs
            else
                red "  [错误] 服务重启失败！请重新检查 yaml 文件的缩进和格式是否正确。"
            fi
        else
            if systemctl is-active --quiet hysteria-server; then
                green "  重启成功！新配置已生效。"
                green "  正在同步更新客户端订阅配置..."
                generate_client_configs
            else
                red "  [错误] 服务启动失败！请重新检查 yaml 文件的缩进和格式是否正确。"
            fi
        fi
    fi
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回主菜单... ${PLAIN}"
    read temp
}

check_traffic() {
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "  未检测到 Hysteria 2 配置文件，请先安装！"
        sleep 2; return
    fi
    
    if ! grep -q -E "^[[:space:]]*trafficStats:" /etc/hysteria/config.yaml; then
        local api_port=$(shuf -i 30000-60000 -n 1)
        while ss -tnl | grep -E -q ":$api_port( |$)"; do api_port=$(shuf -i 30000-60000 -n 1); done
        echo "$api_port" > /etc/hysteria/api_port.txt
        
        green "  正在自动开启流量统计 API..."
        cat << EOF >> /etc/hysteria/config.yaml

trafficStats:
  listen: 127.0.0.1:$api_port
EOF
        svc_stop hysteria-server
        svc_start hysteria-server
        sleep 2
        yellow "  流量统计功能已激活！"
        yellow "  (注意：由于服务刚刚重启，所有历史流量已清空，请稍后重新连接并产生流量后再来查看)"
        echo ""
        echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回主菜单... ${PLAIN}"
        read temp
        return
    else
        local api_port=$(awk '/^[[:space:]]*trafficStats:/{flag=1} flag && /listen:/{print $NF; exit}' /etc/hysteria/config.yaml | awk -F ':' '{print $NF}' | tr -d '\r' | tr -d ' ')
        [[ -z "$api_port" ]] && api_port=$(cat /etc/hysteria/api_port.txt | tr -d '\r')
    fi

    local traffic_data=$(curl --max-time 3 "http://127.0.0.1:$api_port/traffic")
    
    clear
    echo ""
    print_line
    green "                    客户端连接与流量统计                   "
    print_line
    echo ""
    
    if [[ -z "$traffic_data" || "$traffic_data" =~ "404" ]]; then
        red "  获取数据失败，Hysteria 服务可能未正常运行，或 API 端口超时。"
    else
        export TRAFFIC_JSON_DATA="${traffic_data}"
        python3 -c "
import os, json
try:
    data_str = os.environ.get('TRAFFIC_JSON_DATA', '').strip()
    if not data_str:
        print('\033[33m  暂无任何流量消耗记录或客户端连接。\033[0m')
    else:
        data = json.loads(data_str)
        if not data:
            print('\033[33m  暂无任何流量消耗记录或客户端连接。\033[0m')
        else:
            print('\033[32m  当前活跃客户端总数: ' + str(len(data)) + '\033[0m\n')
            print('\033[32m ──────────────────────────────────────────────────────────\033[0m')
            for user, stats in data.items():
                tx_mb = stats.get('tx', 0) / 1048576
                rx_mb = stats.get('rx', 0) / 1048576
                print('\033[33m  账号: {} | 发送: {:.2f} MB | 接收: {:.2f} MB\033[0m'.format(user, tx_mb, rx_mb))
except ValueError:
    print('\033[31m  [致命错误] API 端口返回的不是 JSON！服务可能冲突。\033[0m')
    print('\033[33m  [调试日志] 以下是我们在端口抓取到的阻断信息：\033[0m')
    print('  ' + data_str.replace('\n', '\n  '))
except Exception as e:
    print('\033[31m  获取流量数据异常: ' + str(e) + '\033[0m')
"
    fi
    
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回主菜单... ${PLAIN}"
    read temp
}

starthysteria() {
    svc_start hysteria-server
    svc_start hysteria-sub
    echo ""
    green "  Hysteria 2 及订阅服务已启动！"
    sleep 2
}

stophysteria_only() {
    svc_stop hysteria-server
    svc_stop hysteria-sub
    echo ""
    yellow "  Hysteria 2 及订阅服务已停止！"
}

hysteriaswitch() {
    clear
    echo ""
    print_line
    green "                      服务运行状态控制                     "
    print_line
    echo ""
    echo -e "    ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}启动 Hysteria 2 及订阅服务${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_RED}停止 Hysteria 2 及订阅服务${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[3]${PLAIN} ${LIGHT_YELLOW}重启 Hysteria 2 及订阅服务${PLAIN}"
    echo ""
    echo -e "    ${LIGHT_GREEN}[0]${PLAIN} ${LIGHT_PURPLE}返回主菜单${PLAIN}"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [0-3]: ${PLAIN}"
    read switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria_only; sleep 2 ;;
        3 ) stophysteria_only; starthysteria ;;
        0 ) return ;;
        * ) red "  输入无效"; sleep 1 ;;
    esac
}

# ===============================
# 内核参数极限调优模块更新
# ===============================
enable_bbr() {
    echo ""
    print_line
    local kernel_v=$(uname -r | cut -d. -f1)
    if [[ "$kernel_v" -lt 4 ]]; then
        red "  当前内核版本过低 ($(uname -r))，不支持开启 BBR！"
        sleep 3; return
    fi

    if ! modprobe tcp_bbr; then
        if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control; then
            red "  [错误] 当前系统/内核 (可能是 LXC 容器) 彻底不支持 BBR 模块！"
            sleep 3; return
        fi
    fi
    
    # 清理旧的系统参数避免重复叠加
    sed -i '/^[[:space:]]*net\.core\.default_qdisc/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.rmem_max/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.rmem_default/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.wmem_max/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.wmem_default/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.ipv4\.udp_mem/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.netdev_max_backlog/d' /etc/sysctl.conf
    sed -i '/^[[:space:]]*net\.core\.somaxconn/d' /etc/sysctl.conf

    # 动态计算 UDP 缓冲区，防止小内存 VPS(如 512M) 发生 OOM 崩溃
    local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local mem_pages=$(( total_mem_kb / 4 ))
    
    # 限制 UDP 最大占用物理内存的 25%
    local udp_max=$(( mem_pages / 4 ))
    # 设定安全底线，防止由于内存太小导致算出来的值不满足最低要求
    [[ $udp_max -lt 65536 ]] && udp_max=65536
    
    local udp_mid=$(( udp_max * 3 / 4 ))
    local udp_min=$(( udp_max / 2 ))

    # 注入极限高并发 UDP 队列调优参数
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.core.rmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.rmem_default=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_default=26214400" >> /etc/sysctl.conf
    echo "net.core.netdev_max_backlog=100000" >> /etc/sysctl.conf
    echo "net.core.somaxconn=65535" >> /etc/sysctl.conf
    echo "net.ipv4.udp_mem=$udp_min $udp_mid $udp_max" >> /etc/sysctl.conf
    
    sysctl -p
    
    echo ""
    green "  BBR 及极致的 UDP 缓冲区底层调优开启成功！"
    yellow "  已显著拉升最大并发连接数和收发包深度，可有效抵抗大流量时的丢包状况。"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回主菜单... ${PLAIN}"
    read temp
}

check_cert() {
    clear
    echo ""
    print_line
    green "                 证书安装诊断与健康状态检查                "
    print_line
    echo ""

    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "  [✘] 未检测到 Hysteria 2 配置文件，请先安装服务！"
        echo ""
        echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回主菜单... ${PLAIN}"
        read temp
        return
    fi

    # 提取 Cert 和 Key 路径
    local cert_path=$(grep -w 'cert:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d '"' | tr -d "'")
    local key_path=$(grep -w 'key:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d '"' | tr -d "'")

    local has_error=0

    # ==========================================
    # 1. 深度诊断：检查文件是否存在、大小及内容合法性
    # ==========================================
    if [[ -z "$cert_path" || -z "$key_path" ]]; then
        red "  [✘] 配置文件中的证书路径为空！"
        yellow "  ▶ 报错原因: config.yaml 配置被破坏，或安装时参数未能正确写入。"
        has_error=1
    else
        # 诊断公钥 (Cert)
        if [[ ! -f "$cert_path" ]]; then
            red "  [✘] 找不到证书公钥 (Cert): $cert_path"
            yellow "  ▶ 报错原因排查:"
            yellow "     1. [API 错误] Cloudflare Token/Key 填错，或权限不足。"
            yellow "     2. [DNS 未生效] 刚买的域名解析还没生效，导致 Acme.sh 无法验证。"
            yellow "     3. [频率限制] 短时间内频繁重装，触发了 Let's Encrypt 的风控机制。"
            yellow "     4. [路径拼写] 如果您选了自定义路径，可能是手误打错了绝对路径。"
            has_error=1
        elif [[ ! -s "$cert_path" ]]; then
            red "  [✘] 证书公钥 (Cert) 大小为 0 字节！"
            yellow "  ▶ 报错原因: Acme.sh 申请过程中被强制杀掉进程，或您的 VPS 磁盘空间已爆满。"
            has_error=1
        elif ! grep -q "BEGIN" "$cert_path"; then
            red "  [✘] 证书公钥 (Cert) 格式异常！"
            yellow "  ▶ 报错原因: 文件内容损坏，不是标准的 PEM 格式。可能被其他程序覆写。"
            has_error=1
        else
            green "  [✔] 公钥 (Cert) 基础状态正常: $cert_path"
        fi

        # 诊断私钥 (Key)
        if [[ ! -f "$key_path" ]]; then
            red "  [✘] 找不到证书私钥 (Key): $key_path"
            yellow "  ▶ 报错原因: 私钥生成失败，同上请检查 API 和 DNS 状态。"
            has_error=1
        elif [[ ! -s "$key_path" ]]; then
            red "  [✘] 证书私钥 (Key) 大小为 0 字节！"
            yellow "  ▶ 报错原因: 系统在生成私钥时出错，可能是 VPS 熵池不足或磁盘已满。"
            has_error=1
        elif ! grep -q "PRIVATE KEY" "$key_path"; then
            red "  [✘] 证书私钥 (Key) 格式异常！"
            yellow "  ▶ 报错原因: 文件不是合法的私钥文件，请检查是否混入了其他文本。"
            has_error=1
        else
            green "  [✔] 私钥 (Key) 基础状态正常: $key_path"
        fi
    fi

    echo ""

    # ==========================================
    # 2. 如果文件正常，进行密码学级别的匹配与过期诊断
    # ==========================================
    if [[ $has_error -eq 0 ]]; then
        if command -v openssl >/dev/null; then
            local cert_subject=$(openssl x509 -in "$cert_path" -noout -subject | awk -F'CN = |CN=' '{print $2}' | awk -F',' '{print $1}')
            local cert_issuer=$(openssl x509 -in "$cert_path" -noout -issuer | awk -F'CN = |CN=|O = |O=' '{print $2}' | awk -F',' '{print $1}')
            local cert_start=$(openssl x509 -in "$cert_path" -noout -startdate | cut -d= -f2)
            local cert_end=$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)
            local cert_algo=$(openssl x509 -in "$cert_path" -noout -text | grep "Public Key Algorithm" | awk -F':' '{print $2}' | tr -d ' ')

            yellow "  ▶ 绑定的域名 (CN) : ${cert_subject:-未知}"
            yellow "  ▶ 证书颁发机构    : ${cert_issuer:-未知}"
            yellow "  ▶ 密钥加密算法    : ${cert_algo:-未知}"
            yellow "  ▶ 证书生效日期    : $cert_start"

            # 跨平台高精度时间计算
            if command -v python3 >/dev/null; then
                local days_left=$(python3 -c "import datetime; t=datetime.datetime.strptime('$cert_end', '%b %d %H:%M:%S %Y %Z'); print((t - datetime.datetime.now()).days)" 2>/dev/null)
            else
                local end_epoch=$(date -d "$cert_end" +%s 2>/dev/null)
                local now_epoch=$(date +%s 2>/dev/null)
                if [[ -n "$end_epoch" && -n "$now_epoch" && "$end_epoch" =~ ^[0-9]+$ ]]; then
                    local days_left=$(( (end_epoch - now_epoch) / 86400 ))
                fi
            fi

            if [[ -n "$days_left" && "$days_left" =~ ^-?[0-9]+$ ]]; then
                if [[ $days_left -lt 0 ]]; then
                    red "  ▶ 证书过期日期    : $cert_end (⚠ 已经过期！)"
                    yellow "  ▶ 报错原因        : 证书已过期，Acme.sh 自动续期任务可能已失效。"
                elif [[ $days_left -lt 15 ]]; then
                    red "  ▶ 证书过期日期    : $cert_end (⚠ 仅剩 $days_left 天，即将过期！)"
                else
                    green "  ▶ 证书过期日期    : $cert_end (正常，剩余 $days_left 天)"
                fi
            else
                yellow "  ▶ 证书过期日期    : $cert_end"
            fi

            # 密码学验证：检查 Cert 和 Key 是否成对
            local is_mismatch=0
            local cert_type="ECC"
            
            if openssl x509 -noout -modulus -in "$cert_path" 2>/dev/null | grep -q "Modulus"; then
                cert_type="RSA"
                # RSA 算法验证
                local cert_mod=$(openssl x509 -noout -modulus -in "$cert_path" 2>/dev/null | tr -d '\r\n ')
                local key_mod=$(openssl rsa -noout -modulus -in "$key_path" 2>/dev/null | tr -d '\r\n ')
                if [[ "$cert_mod" == "$key_mod" && -n "$cert_mod" ]]; then
                    green "  ▶ 证书与私钥匹配  : [✔] 完美配对 (RSA)"
                else
                    red "  ▶ 证书与私钥匹配  : [✘] 不匹配！"
                    yellow "  ▶ 报错原因        : 现在的私钥解不开当前的公钥！可能是手动替换文件时只换了其中一个，或者生成时发生了错乱。"
                    is_mismatch=1
                fi
            else
                cert_type="ECC"
                # ECC 算法验证 (彻底修复 Alpine Busybox 环境下文本截断导致的误报)
                local cert_pub=$(openssl x509 -in "$cert_path" -pubkey -noout 2>/dev/null | sed '/^-----/d' | tr -d '\r\n ')
                local key_pub=$(openssl pkey -in "$key_path" -pubout 2>/dev/null | sed '/^-----/d' | tr -d '\r\n ')
                
                # 兼容部分老系统不支持 pkey 命令，使用 ec 备用提取
                if [[ -z "$key_pub" ]]; then
                    key_pub=$(openssl ec -in "$key_path" -pubout 2>/dev/null | sed '/^-----/d' | tr -d '\r\n ')
                fi

                if [[ "$cert_pub" == "$key_pub" && -n "$cert_pub" ]]; then
                    green "  ▶ 证书与私钥匹配  : [✔] 完美配对 (ECC)"
                else
                    red "  ▶ 证书与私钥匹配  : [✘] 不匹配！"
                    yellow "  ▶ 报错原因        : ECC 公钥指纹与私钥不对应。必须保证 crt 和 key 是同一批次生成的。"
                    is_mismatch=1
                fi
            fi

            # ====== 新增：智能一键修复逻辑 ======
            if [[ $is_mismatch -eq 1 && -f "/root/.acme.sh/acme.sh" ]]; then
                echo ""
                print_line
                yellow "  检测到证书不匹配！是否尝试使用 Acme.sh 本地缓存自动修复？"
                echo -en " ${LIGHT_YELLOW} ▶ 请输入 (y/n) [默认: y]: ${PLAIN}"
                read try_repair
                [[ -z "$try_repair" ]] && try_repair="y"
                
                if [[ "$try_repair" == "y" || "$try_repair" == "Y" ]]; then
                    echo ""
                    green "  正在执行自动修复并重新提取证书..."
                    local acme_ecc_param=""
                    [[ "$cert_type" == "ECC" ]] && acme_ecc_param="--ecc"
                    
                    bash /root/.acme.sh/acme.sh --install-cert -d "$cert_subject" $acme_ecc_param \
                        --key-file /root/private.key \
                        --fullchain-file /root/cert.crt
                    
                    if [[ $? -eq 0 ]]; then
                        chmod 644 /root/cert.crt
                        chmod 600 /root/private.key
                        mkdir -p /var/www/hysteria/certs
                        cp -f /root/cert.crt /var/www/hysteria/certs/cert.crt
                        cp -f /root/private.key /var/www/hysteria/certs/private.key
                        chown -R nobody /var/www/hysteria/certs
                        
                        if [[ $SYSTEM == "Alpine" ]]; then
                            rc-service hysteria-server restart 2>/dev/null
                            rc-service hysteria-sub restart 2>/dev/null
                        else
                            systemctl restart hysteria-server 2>/dev/null
                            systemctl restart hysteria-sub 2>/dev/null
                        fi
                        echo ""
                        green "  [✔] 修复完成！核心服务与订阅服务已自动同步并重启。"
                    else
                        echo ""
                        red "  [✘] 修复失败！Acme.sh 目录中可能没有该域名 ($cert_subject) 的有效缓存。"
                    fi
                fi
            fi
            # ====================================

            # 模式提示与 Acme 自检
            if [[ "$cert_subject" == "www.bing.com" || "$cert_issuer" =~ "bing.com" ]]; then
                echo ""
                yellow "  ℹ 提示: 当前使用的是系统自动生成的【必应自签伪装证书】。"
            elif [[ "$cert_issuer" =~ "Let's Encrypt" || "$cert_issuer" =~ "ZeroSSL" || "$cert_issuer" =~ "Google" || "$cert_issuer" =~ "Cloudflare" ]]; then
                echo ""
                green "  ℹ 提示: 当前使用的是受信任的【真实 CA 域名证书】。"
                
                if [[ -f "/root/.acme.sh/acme.sh" || -f "/root/ca.log" ]]; then
                    echo ""
                    purple "  [Acme.sh 守护进程自检]"
                    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                        green "  ▶ Cron 定时任务   : [✔] 正常运行中"
                    else
                        red "  ▶ Cron 定时任务   : [✘] 缺失！"
                        yellow "  ▶ 报错原因        : 系统的 crontab 被清空或卸载了 cronie 组件，证书到期后将无法自动续期。"
                    fi
                fi
            fi
        else
            red "  [警告] 系统未安装 openssl 组件，跳过了深度密码学检测。"
        fi
    fi
    
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 按回车键返回主菜单... ${PLAIN}"
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
    green " 项目名称 ：Hysteria 2 一键部署与管理脚本 (单人旗舰加固版)"
    purple " 项目地址 ：哆啦的Github库 https://github.com/yanbinlti-glitch"
    green "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    yellow " 脚本快捷方式：hy2 (已自动配置，下次可在终端直接输入 hy2 启动)"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "  ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}安装部署 Hysteria 2${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_RED}彻底卸载 Hysteria 2${PLAIN}"
    echo "----------------------------------------------------------------------------------"
    echo -e "  ${LIGHT_GREEN}[3]${PLAIN} ${LIGHT_YELLOW}启动 / 停止 / 重启服务${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[4]${PLAIN} ${LIGHT_PURPLE}查看 / 修改 配置文件${PLAIN}"
    echo "----------------------------------------------------------------------------------"
    echo -e "  ${LIGHT_GREEN}[5]${PLAIN} ${LIGHT_GREEN}获取 节点配置 与 订阅链接${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[6]${PLAIN} ${LIGHT_YELLOW}查看 客户端连接 与 流量统计${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[7]${PLAIN} ${LIGHT_PURPLE}开启 BBR 及 UDP 极限并发加速 (强烈推荐)${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[8]${PLAIN} ${LIGHT_GREEN}检查 证书安装状态与详细信息${PLAIN}"
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
