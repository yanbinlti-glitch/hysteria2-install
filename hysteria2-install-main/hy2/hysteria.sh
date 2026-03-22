#!/bin/bash

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

# =================================================================
#  1. 现代化极简 UI 色彩库
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

# 安全提取脚本路径
SCRIPT_PATH=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
if [[ -f "$SCRIPT_PATH" && "$(head -n 1 "$SCRIPT_PATH" 2>/dev/null)" == "#!/bin/bash" ]]; then
    if [[ "$SCRIPT_PATH" != "/usr/local/bin/hy2" ]]; then
        cp -f "$SCRIPT_PATH" /usr/local/bin/hy2
        chmod +x /usr/local/bin/hy2
    fi
fi

REGEX=("alpine" "debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon linux" "fedora")
RELEASE=("Alpine" "Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apk update" "apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apk add" "apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install")

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
[[ -z $SYSTEM ]] && red " [错误] 目前暂不支持您的 VPS 操作系统！" && exit 1

if [[ -z $(type -P curl) ]]; then
    [[ ! $SYSTEM == "CentOS" ]] && { $PKG_UPDATE || { echo ""; red " [错误] 系统软件源更新失败！"; exit 1; }; }
    $PKG_INSTALL curl || { echo ""; red " [错误] curl 安装失败！请检查网络或系统源。"; exit 1; }
fi

realip() {
    ip=$(curl -s4m3 api.ipify.org -k || curl -s4m3 ifconfig.me -k || curl -s4m3 ip.sb -k)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6m3 api64.ipify.org -k || curl -s6m3 ifconfig.me -k || curl -s6m3 ip.sb -k)
    fi
    ip=$(echo "$ip" | grep -m 1 -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}|([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:)*:[0-9a-fA-F]{1,4}")
    if [[ -z "$ip" ]]; then
        echo ""
        red " [错误] 无法获取本机的公网 IP，请检查 VPS 的网络连接或 DNS 设置！"
        exit 1
    fi
}

gen_random_str() {
    local len=$1
    local str=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
    if [[ -z "$str" ]]; then
        str=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n')
    fi
    echo "${str:0:$len}"
}

# =================================================================
#  3. 服务管理与防火墙控制封装
# =================================================================
svc_start()   { if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" start; else systemctl start "$1"; fi; }
svc_stop()    { if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" stop; else systemctl stop "$1"; fi; }
svc_enable()  { if [[ $SYSTEM == "Alpine" ]]; then rc-update add "$1" default; else systemctl enable "$1"; fi; }
svc_disable() { if [[ $SYSTEM == "Alpine" ]]; then rc-update del "$1" default; else systemctl disable "$1"; fi; }

save_iptables() {
    if [[ $SYSTEM == "Alpine" ]]; then
        rc-service iptables save 2>/dev/null
        rc-service ip6tables save 2>/dev/null
    elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
        service iptables save 2>/dev/null
        service ip6tables save 2>/dev/null
    else
        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save 2>/dev/null
        fi
    fi
}

open_port() {
    local port=$1
    local proto=$2
    iptables -I INPUT -p $proto --dport $port -j ACCEPT 2>/dev/null
    ip6tables -I INPUT -p $proto --dport $port -j ACCEPT 2>/dev/null
    if command -v ufw >/dev/null; then ufw allow $port/$proto 2>/dev/null; fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --add-port=$port/$proto --permanent 2>/dev/null
        firewall-cmd --reload 2>/dev/null
    fi
    save_iptables
}

close_port() {
    local port=$1
    local proto=$2
    iptables -D INPUT -p $proto --dport $port -j ACCEPT 2>/dev/null
    ip6tables -D INPUT -p $proto --dport $port -j ACCEPT 2>/dev/null
    if command -v ufw >/dev/null; then ufw delete allow $port/$proto 2>/dev/null; fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --zone=public --remove-port=$port/$proto --permanent 2>/dev/null
        firewall-cmd --reload 2>/dev/null
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
    
    local cmds=("curl" "wget" "sudo" "ss" "iptables" "python3" "openssl" "socat" "qrencode" "jq")
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
            $PKG_INSTALL curl wget sudo procps iptables ip6tables iproute2 python3 openssl socat cronie libqrencode-tools jq || { echo ""; red " [错误] 前置依赖安装失败！请检查系统源或网络后重试。"; exit 1; }
            rc-update add crond default 2>/dev/null; rc-service crond start 2>/dev/null
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            $PKG_INSTALL epel-release || { echo ""; red " [错误] epel-release 扩展源安装失败！"; exit 1; }
            $PKG_INSTALL curl wget sudo procps iptables iptables-services iproute python3 openssl socat cronie qrencode jq || { echo ""; red " [错误] 前置依赖安装失败！请检查系统源或网络后重试。"; exit 1; }
            systemctl enable --now crond 2>/dev/null || systemctl enable --now cron 2>/dev/null
        else
            yellow "  正在尝试修复并清理系统损坏的依赖项..."
            apt-get --fix-broken install -y || { echo ""; red " [错误] 尝试修复系统损坏的依赖项失败！"; exit 1; }
            apt-get autoremove -y
            apt-get clean
            $PKG_INSTALL curl wget sudo procps iptables-persistent netfilter-persistent iproute2 python3 openssl socat cron qrencode jq || { echo ""; red " [错误] 前置依赖安装失败！请检查 APT 源或网络后重试。"; exit 1; }
            systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null
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
        if [[ -f /root/cert.crt && -f /root/private.key && -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log | tr -d '\r')
            echo ""
            green " 检测到原有域名：$domain 的证书，正在直接应用..."
            hy_domain="$domain"
            cert_path="/var/www/hysteria/certs/cert.crt"
            key_path="/var/www/hysteria/certs/private.key"
            mkdir -p /var/www/hysteria/certs
            cp -f /root/cert.crt "$cert_path"
            cp -f /root/private.key "$key_path"
            chown -R nobody /var/www/hysteria/certs
        else
            realip
            echo ""
            echo -en " ${LIGHT_YELLOW} ▶ 请输入需要申请证书的域名: ${PLAIN}"
            read domain
            [[ -z "$domain" ]] && red " 未输入域名，无法执行操作！" && exit 1
            domain=$(echo "$domain" | tr -d '\r' | tr -d ' ')
            green " 已记录域名：$domain"
            
            # 【优化】支持双栈环境多 IP 聚合匹配，减少误报
            domainIPs=$(DOMAIN="$domain" python3 -c "import socket, os; try: addrs=socket.getaddrinfo(os.environ.get('DOMAIN'), None); print(' '.join(list(set([a[4][0] for a in addrs])))) except: print('')" 2>/dev/null || echo "")
            
            if [[ -z "$domainIPs" ]]; then
                echo ""
                yellow " [警告] 无法解析域名 ${domain} 的 IP 地址！请确认域名已正确解析。"
                echo -en " ${LIGHT_YELLOW} ▶ 是否强制继续？(y/n) [默认: y]: ${PLAIN}"
                read force_cert
                [[ -z "$force_cert" ]] && force_cert="y"
                [[ "$force_cert" != "y" && "$force_cert" != "Y" ]] && exit 1
            elif ! echo "$domainIPs" | grep -q "$ip"; then
                echo ""
                yellow " [警告] 域名解析的 IP 列表 ($domainIPs) 中未完全匹配当前真实 IP ($ip)！"
                yellow " [提示] 如果您的服务器是纯 IPv6 环境，这可能是由于 IPv6 缩写格式不一致导致的误报。"
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
                local reload_cmd="cp -f /root/cert.crt /var/www/hysteria/certs/cert.crt && cp -f /root/private.key /var/www/hysteria/certs/private.key && chown -R nobody /var/www/hysteria/certs && (rc-service hysteria-server restart || true) && (rc-service hysteria-sub restart || true)"
            else
                local reload_cmd="cp -f /root/cert.crt /var/www/hysteria/certs/cert.crt && cp -f /root/private.key /var/www/hysteria/certs/private.key && chown -R nobody /var/www/hysteria/certs && (systemctl try-restart hysteria-server || true) && (systemctl try-restart hysteria-sub || true)"
            fi
            
            bash /root/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc --reloadcmd "$reload_cmd"
            
            if [[ -f /root/cert.crt && -f /root/private.key ]]; then
                echo "$domain" > /root/ca.log
                chmod 644 /root/cert.crt; chmod 600 /root/private.key
                green " 证书申请成功！已保存至 /root/ 目录下。"
                hy_domain="$domain"
                
                cert_path="/var/www/hysteria/certs/cert.crt"
                key_path="/var/www/hysteria/certs/private.key"
                cp -f /root/cert.crt "$cert_path"
                cp -f /root/private.key "$key_path"
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
    firstport=""
    endport=""

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

        modprobe ip6table_nat 2>/dev/null || true
        iptables -I INPUT -p udp --dport $firstport:$endport -m comment --comment "hy2-port-hop-input" -j ACCEPT 2>/dev/null
        ip6tables -I INPUT -p udp --dport $firstport:$endport -m comment --comment "hy2-port-hop-input" -j ACCEPT 2>/dev/null || true
        
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j REDIRECT --to-ports $port -m comment --comment "hy2-port-hop" 2>/dev/null
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport -j REDIRECT --to-ports $port -m comment --comment "hy2-port-hop" 2>/dev/null || true
        
        if [[ $? -ne 0 ]]; then
            yellow "  [提示] 当前系统/内核可能不支持 IPv6 NAT，IPv6 端口跳跃已静默跳过。"
        fi

        if command -v ufw >/dev/null; then ufw allow $firstport:$endport/udp 2>/dev/null; fi
        if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --zone=public --add-port=$firstport-$endport/udp --permanent 2>/dev/null
            firewall-cmd --reload 2>/dev/null
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
    
    while [[ ! "$sub_port_input" =~ ^[0-9]+$ ]] || [[ "$sub_port_input" -lt 1024 ]] || [[ "$sub_port_input" -gt 65535 ]] || [[ "$sub_port_input" == "$port" ]] || { [[ -n "$firstport" && -n "$endport" ]] && [[ "$sub_port_input" -ge "$firstport" && "$sub_port_input" -le "$endport" ]]; }; do
        if [[ "$sub_port_input" == "$port" ]]; then
            red " [警告] 订阅端口不能与 Hysteria 主端口 ($port) 冲突！"
        elif [[ -n "$firstport" && -n "$endport" && "$sub_port_input" -ge "$firstport" && "$sub_port_input" -le "$endport" ]]; then
            red " [警告] 订阅端口不能与跳跃端口范围 ($firstport-$endport) 重叠冲突！"
        else
            red " [警告] 端口必须在 1024-65535 之间！"
        fi
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
    echo -en " ${LIGHT_YELLOW} ▶ 节点显示名称 [回车默认 Hysteria2_Node]: ${PLAIN}"
    read custom_node_name
    [[ -z $custom_node_name ]] && custom_node_name="Hysteria2_Node"
    
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 是否在客户端配置中强制开启 '跳过证书验证' (防 SNI 阻断/高墙推荐)？(y/n) [默认: y]: ${PLAIN}"
    read force_skip_cert
    [[ -z $force_skip_cert ]] && force_skip_cert="y"
    if [[ "$force_skip_cert" == "y" || "$force_skip_cert" == "Y" ]]; then
        echo "1" > /etc/hysteria/force_skip_cert.txt
    else
        echo "0" > /etc/hysteria/force_skip_cert.txt
    fi

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
    
    local main_port=$(grep -E "^[[:space:]]*listen:" /etc/hysteria/config.yaml 2>/dev/null | awk -F ':' '{print $NF}' | tr -d ' ' | tr -d '\r' | tr -d '"')
    local sub_port=$(cat /etc/hysteria/sub_port.txt 2>/dev/null | tr -d '\r')

    [[ -n "$main_port" && "$main_port" =~ ^[0-9]+$ ]] && close_port "$main_port" "udp"
    [[ -n "$sub_port" && "$sub_port" =~ ^[0-9]+$ ]] && close_port "$sub_port" "tcp"

    # 【修复】采用精准匹配删除，摒弃可能破坏 Docker 与其他容器环境的 iptables-restore 大法
    if [[ -f /etc/hysteria/port_hop.txt ]]; then
        local hop_range=$(cat /etc/hysteria/port_hop.txt | tr -d '\r')
        local f_port=$(echo "$hop_range" | cut -d':' -f1)
        local e_port=$(echo "$hop_range" | cut -d':' -f2)
        if [[ -n "$f_port" && -n "$e_port" ]]; then
            iptables -D INPUT -p udp --dport $f_port:$e_port -m comment --comment "hy2-port-hop-input" -j ACCEPT 2>/dev/null
            ip6tables -D INPUT -p udp --dport $f_port:$e_port -m comment --comment "hy2-port-hop-input" -j ACCEPT 2>/dev/null
            iptables -t nat -D PREROUTING -p udp --dport $f_port:$e_port -j REDIRECT --to-ports $main_port -m comment --comment "hy2-port-hop" 2>/dev/null
            ip6tables -t nat -D PREROUTING -p udp --dport $f_port:$e_port -j REDIRECT --to-ports $main_port -m comment --comment "hy2-port-hop" 2>/dev/null

            if command -v ufw >/dev/null; then ufw delete allow "$f_port:$e_port/udp" 2>/dev/null; fi
            if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
                firewall-cmd --zone=public --remove-port="$f_port-$e_port/udp" --permanent 2>/dev/null
                firewall-cmd --reload 2>/dev/null
            fi
        fi
    fi

    svc_stop hysteria-server 2>/dev/null; svc_disable hysteria-server 2>/dev/null
    svc_stop hysteria-sub 2>/dev/null; svc_disable hysteria-sub 2>/dev/null
    
    pkill -f "/var/www/hysteria/server.py" 2>/dev/null || true

    if [[ $SYSTEM == "Alpine" ]]; then
        rm -f /etc/init.d/hysteria-server /etc/init.d/hysteria-sub
    else
        rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-sub.service
        systemctl daemon-reload 2>/dev/null
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
    
    local raw_pwd=$(awk '/^auth:/,0' /etc/hysteria/config.yaml | grep -E '^[[:space:]]*password:' | head -n 1 | sed 's/.*password:[[:space:]]*//; s/["'\''\r]//g')
    
    local s_pwd=$(PWD="$raw_pwd" python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ.get('PWD', '')))")
    local safe_node_name=$(NAME="$custom_node_name" python3 -c "import urllib.parse, os; print(urllib.parse.quote(os.environ.get('NAME', '')))")
    
    local c_domain=$(grep 'sni:' /etc/hysteria/hy-client.yaml | awk '{print $2}')
    [[ -z "$c_domain" ]] && c_domain="www.bing.com"
    
    local c_server=$(grep '^server:' /etc/hysteria/hy-client.yaml | awk '{print $2}')
    local c_ports="${c_server##*:}"
    local primary_port=$(echo "$c_ports" | cut -d',' -f1)
    local hop_ports=$(echo "$c_ports" | awk -F ',' '{print $2}')
    
    local s_obfs_pwd=$(awk '/obfs:/{flag=1} flag && /password:/{print $2; flag=0}' /etc/hysteria/config.yaml | tr -d '"' | tr -d "'")
    local is_insecure_url=$(cat /etc/hysteria/insecure_state.txt || echo "1")
    local force_skip=$(cat /etc/hysteria/force_skip_cert.txt 2>/dev/null || echo "1")
    
    local clash_cert_verify="false"
    
    if [[ "$is_insecure_url" == "0" && "$force_skip" == "0" ]]; then
        clash_cert_verify="false"
        echo "$c_domain" > /etc/hysteria/sub_host.txt
    else
        clash_cert_verify="true"
        echo "$ip" > /etc/hysteria/sub_host.txt
    fi

    local obfs_param=""
    if [[ -n "$s_obfs_pwd" ]]; then
        obfs_param="&obfs=salamander&obfs-password=${s_obfs_pwd}"
    fi

    local c_up=$(cat /etc/hysteria/c_up.txt || echo "0")
    local c_down=$(cat /etc/hysteria/c_down.txt || echo "0")

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

    local sub_uuid=$(cat /etc/hysteria/sub_path.txt 2>/dev/null)
    [[ -z "$sub_uuid" ]] && sub_uuid=$(gen_random_str 16)
    mkdir -p "$web_dir/$sub_uuid"
    echo "$sub_uuid" > /etc/hysteria/sub_path.txt

    local url="hy2://$s_pwd@$uri_ip:$primary_port/?insecure=${is_insecure_url}&sni=$c_domain${mport_param}${obfs_param}#${safe_node_name}"
    echo "$url" > "$web_dir/$sub_uuid/url.txt"
    
    printf "%s" "$url" | base64 -w 0 2>/dev/null > "$web_dir/$sub_uuid/sub_b64.txt" || printf "%s" "$url" | base64 | tr -d '\r\n' > "$web_dir/$sub_uuid/sub_b64.txt"

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
    password: "$raw_pwd"
    sni: "$c_domain"
    skip-cert-verify: $clash_cert_verify
    alpn:
      - h3
$([[ -n "$s_obfs_pwd" ]] && echo "    obfs: salamander
    obfs-password: \"$s_obfs_pwd\"")
$([[ "$c_up" != "0" ]] && echo "    up: '${c_up} mbps'
    down: '${c_down} mbps'")

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
    
    # 【优化】Python 订阅服务器支持热重载，每次请求动态读取文件，免去重启进程烦恼
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
WEB_DIR = "$web_dir"

class SecureSubHandler(http.server.BaseHTTPRequestHandler):
    server_version = "nginx/1.24.0"
    sys_version = ""

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        req_path = parsed.path.strip('/')
        
        if req_path == SUB_UUID:
            try:
                with open(f"{WEB_DIR}/{SUB_UUID}/clash-meta-sub.yaml", 'rb') as f:
                    clash_data = f.read()
                with open(f"{WEB_DIR}/{SUB_UUID}/sub_b64.txt", 'rb') as f:
                    b64_data = f.read()
            except FileNotFoundError:
                clash_data = b""
                b64_data = b""

            self.send_response(200)
            self.send_header('Content-type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
            self.send_header('profile-update-interval', '24')
            self.end_headers()
            
            ua = self.headers.get('User-Agent', '').lower()
            if any(x in ua for x in ['clash', 'meta', 'verge', 'stash', 'mihomo']):
                self.wfile.write(clash_data)
            else:
                self.wfile.write(b64_data + b"\n")
        else:
            self.send_response(403)
            self.send_header('Content-type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(b"<html><head><title>403 Forbidden</title></head><body><center><h1>403 Forbidden</h1></center><hr><center>nginx</center></body></html>")

class DualStackServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True
    address_family = getattr(socket, 'AF_INET6', socket.AF_INET)

    def server_bind(self):
        if hasattr(socket, 'AF_INET6') and self.address_family == socket.AF_INET6:
            try:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            except (AttributeError, OSError):
                pass
        super().server_bind()

try:
    httpd = DualStackServer(("", PORT), SecureSubHandler)
except OSError:
    DualStackServer.address_family = socket.AF_INET
    httpd = DualStackServer(("0.0.0.0", PORT), SecureSubHandler)

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
StandardOutput=journal
StandardError=journal
LogRateLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria-sub
    fi
    
    svc_stop hysteria-sub 2>/dev/null
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
    
    # 【优化】增加 GitHub 镜像站 Fallback 防失联下载机制
    wget --timeout=10 --tries=3 -N -v -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${hy_arch}" || \
    wget --timeout=10 --tries=3 -N -v -O /usr/local/bin/hysteria "https://mirror.ghproxy.com/https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${hy_arch}"
    
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
StandardOutput=journal
StandardError=journal
LogRateLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    inst_cert
    inst_port
    inst_sub_port
    inst_other_configs

    local user_force_skip=$(cat /etc/hysteria/force_skip_cert.txt 2>/dev/null || echo "0")
    if [[ "$hy_domain" == "www.bing.com" || "$user_force_skip" == "1" ]]; then
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
    - reject(169.254.0.0/16)
    - reject(::1/128)
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
    
    sleep 2
    if ! ss -unl | grep -E -q ":$port( |$)"; then
        echo ""
        red " [致命错误] 服务端未能成功启动，端口 $port 未被监听！"
        yellow " 请使用命令: journalctl -u hysteria-server -e 检查报错日志 (可能是证书路径错误或端口冲突)。"
        exit 1
    fi
    
    echo ""
    print_line
    green "  Hysteria 2 服务端及智能订阅安装部署完成！"
    purple "  请在主菜单选择 [6] 获取节点与二维码。"
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

    local traffic_data=$(curl --max-time 3 "http://127.0.0.1:$api_port/traffic" 2>/dev/null)
    
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
    pkill -f "/var/www/hysteria/server.py" 2>/dev/null || true
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

enable_bbr() {
    echo ""
    print_line
    local kernel_v=$(uname -r | cut -d. -f1)
    if [[ "$kernel_v" -lt 4 ]]; then
        red "  当前内核版本过低 ($(uname -r))，不支持开启 BBR！"
        sleep 3; return
    fi

    if ! modprobe tcp_bbr 2>/dev/null; then
        if ! grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            red "  [错误] 当前系统/内核 (可能是 LXC 容器) 彻底不支持 BBR 模块！"
            sleep 3; return
        fi
    fi
    
    local total_mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    
    # 【修复】防止容器环境读取不到内存而引发除零崩溃
    [[ -z "$total_mem_kb" ]] && total_mem_kb=1048576 
    
    local page_size=$(getconf PAGESIZE 2>/dev/null)
    if ! [[ "$page_size" =~ ^[0-9]+$ ]] || [[ "$page_size" -le 0 ]]; then
        page_size=4096
    fi
    
    local mem_pages=$(( total_mem_kb / (page_size / 1024) ))
    
    local udp_max=$(( mem_pages / 4 ))
    [[ $udp_max -lt 65536 ]] && udp_max=65536
    
    local udp_mid=$(( udp_max * 3 / 4 ))
    local udp_min=$(( udp_max / 2 ))

    mkdir -p /etc/sysctl.d
    cat << EOF > /etc/sysctl.d/99-hysteria-bbr.conf
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_max=26214400
net.core.wmem_default=26214400
net.core.netdev_max_backlog=100000
net.core.somaxconn=65535
net.ipv4.udp_mem=$udp_min $udp_mid $udp_max
EOF
    
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-hysteria-bbr.conf >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1
    
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

    local cert_path=$(grep -w 'cert:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d '"' | tr -d "'")
    local key_path=$(grep -w 'key:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d '"' | tr -d "'")

    local has_error=0

    if [[ -z "$cert_path" || -z "$key_path" ]]; then
        red "  [✘] 配置文件中的证书路径为空！"
        yellow "  ▶ 报错原因: config.yaml 配置被破坏，或安装时参数未能正确写入。"
        has_error=1
    else
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

            if command -v python3 >/dev/null; then
                local days_left=$(python3 -c "import datetime; t_str = ' '.join('$cert_end'.split()); t=datetime.datetime.strptime(t_str, '%b %d %H:%M:%S %Y %Z'); print((t - datetime.datetime.now()).days)" 2>/dev/null)
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

            local is_mismatch=0
            local cert_type="ECC"
            
            if openssl x509 -noout -modulus -in "$cert_path" 2>/dev/null | grep -q "Modulus"; then
                cert_type="RSA"
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
                local cert_pub=$(openssl x509 -in "$cert_path" -pubkey -noout 2>/dev/null | sed '/^-----/d' | tr -d '\r\n ')
                local key_pub=$(openssl pkey -in "$key_path" -pubout 2>/dev/null | sed '/^-----/d' | tr -d '\r\n ')
                
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

config_outbound() {
    clear
    echo ""
    print_line
    green "                 Hysteria 2 落地代理与分流 (IP 中转) 设置               "
    print_line
    echo ""

    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "  未检测到 Hysteria 2 配置文件，请先安装！"
        sleep 2; return
    fi

    if ! command -v jq >/dev/null; then
        yellow "  检测到系统缺失 jq 组件，正在自动安装..."
        if [[ $SYSTEM == "Ubuntu" || $SYSTEM == "Debian" ]]; then
            apt-get update -y && apt-get install -y jq
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" || $SYSTEM == "Alma" || $SYSTEM == "Rocky" ]]; then
            yum install -y epel-release && yum install -y jq
        elif [[ $SYSTEM == "Alpine" ]]; then
            apk update && apk add jq
        fi
    fi

    # 检查当前是否开启了 outbound 及路由模式
    if grep -q "^outbound:" /etc/hysteria/config.yaml; then
        local current_type=$(awk '/^outbound:/{getline; print $2}' /etc/hysteria/config.yaml | tr -d '\r')
        local route_mode_str="未知/自定义"
        if grep -q "proxy(all)" /etc/hysteria/config.yaml; then
            route_mode_str="全局代理"
        elif grep -q "proxy(suffix:netflix.com)" /etc/hysteria/config.yaml; then
            route_mode_str="智能分流 (AI+流媒体)"
        fi
        
        yellow "  当前状态: [已开启] 落地代理模式 (类型: $current_type |路由: $route_mode_str)"
        
        local current_addr=""
        if [[ "$current_type" == "socks5" ]]; then
            current_addr=$(awk '/socks5:/{getline; print $2}' /etc/hysteria/config.yaml | awk '/addr:/{print $2}' | tr -d '\r')
        elif [[ "$current_type" == "http" ]]; then
            current_addr=$(awk '/http:/{getline; print $2}' /etc/hysteria/config.yaml | awk '/url:/{print $2}' | tr -d '\r')
        fi
        [[ -n "$current_addr" ]] && green "  当前代理地址: $current_addr"
    else
        green "  当前状态: [未开启] 本机 IP 直连输出"
    fi
    echo ""
    
    echo -e "    ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}配置 / 修改 落地代理与分流 (支持一键粘贴完整 URI 格式)${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_RED}退回 服务器本机直连 (关闭当前落地代理)${PLAIN}"
    echo -e "    ${LIGHT_GREEN}[3]${PLAIN} ${LIGHT_YELLOW}检查 落地状态 (验证出口连通性、IP 归属地与核心状态)${PLAIN}"
    echo ""
    echo -e "    ${LIGHT_GREEN}[0]${PLAIN} ${LIGHT_PURPLE}返回主菜单${PLAIN}"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [0-3]: ${PLAIN}"
    read out_choice

    case $out_choice in
        1)
            echo ""
            yellow "  ▶ 请输入完整的代理 URI"
            yellow "  (支持格式: socks5://user:pass@ip:port 或 http://user:pass@ip:port)"
            echo -en " ${LIGHT_YELLOW} ▶ 代理 URI: ${PLAIN}"
            read proxy_uri
            [[ -z "$proxy_uri" ]] && { red " 地址不能为空！"; sleep 2; return; }

            proxy_uri=$(echo "$proxy_uri" | tr -d '\r' | tr -d ' ')

            local out_type=""
            local out_user=""
            local out_pass=""
            local out_addr=""

            if [[ "$proxy_uri" =~ ^(socks5|http):// ]]; then
                out_type="${BASH_REMATCH[1]}"
                local remain="${proxy_uri#*://}"
                if [[ "$remain" == *"@"* ]]; then
                    local userpass="${remain%@*}"
                    out_addr="${remain#*@}"
                    out_user="${userpass%:*}"
                    out_pass="${userpass#*:}"
                else
                    out_addr="$remain"
                fi
            else
                red "  [错误] 格式不正确！必须以 socks5:// 或 http:// 开头。"
                sleep 2; return
            fi

            echo ""
            yellow "  正在测试代理连通性并获取归属地信息 (限时 7 秒)..."
            
            local curl_proxy="$proxy_uri"
            local geo_info=$(curl -x "$curl_proxy" -s -m 7 "http://ip-api.com/json/?lang=zh-CN")
            local api_status=$(echo "$geo_info" | jq -r '.status' 2>/dev/null)
            
            if [[ "$api_status" == "success" ]]; then
                local out_ip=$(echo "$geo_info" | jq -r '.query')
                local out_country=$(echo "$geo_info" | jq -r '.country')
                local out_city=$(echo "$geo_info" | jq -r '.city')
                local out_isp=$(echo "$geo_info" | jq -r '.isp')
                
                green "  [✔] 代理连通测试成功！"
                print_line
                green "  ▶ 落地 IP  : $out_ip"
                green "  ▶ 归属地区 : $out_country - $out_city"
                green "  ▶ 运营商   : $out_isp"
                print_line
            else
                red "  [✘] 代理测试失败！无法通过该代理连接外网，或连接超时。"
                yellow "  ▶ 调试信息: ${geo_info:-"获取不到数据，代理死链、限流或格式错误"}"
                echo -en " ${LIGHT_YELLOW} ▶ 代理可能无效，是否强制保存并继续？(y/n) [默认: n]: ${PLAIN}"
                read force_save
                [[ "$force_save" != "y" && "$force_save" != "Y" ]] && { yellow "  已取消中转配置。"; sleep 2; return; }
            fi

            echo ""
            yellow "  ▶ 请选择路由分流模式："
            echo -e "    ${LIGHT_GREEN}[1]${PLAIN} ${LIGHT_GREEN}智能分流 (仅解锁流媒体 Netflix/Disney 等与 AI 平台，兼顾网速) - 推荐${PLAIN}"
            echo -e "    ${LIGHT_GREEN}[2]${PLAIN} ${LIGHT_PURPLE}全局代理 (所有流量 100% 通过落地 IP 转发)${PLAIN}"
            echo ""
            echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [1-2] (默认1): ${PLAIN}"
            read route_mode
            [[ -z "$route_mode" ]] && route_mode=1

            local acl_block="acl:\n  inline:\n    - reject(169.254.0.0/16)\n    - reject(::1/128)\n    - reject(127.0.0.0/8)\n    - reject(10.0.0.0/8)\n    - reject(172.16.0.0/12)\n    - reject(192.168.0.0/16)\n    - reject(fc00::/7)\n    - reject(fe80::/10)\n"
            
            if [[ "$route_mode" == 1 ]]; then
                acl_block+="    - proxy(suffix:openai.com)\n    - proxy(suffix:chatgpt.com)\n    - proxy(suffix:anthropic.com)\n    - proxy(suffix:claude.ai)\n    - proxy(suffix:ai.ndai.top)\n    - proxy(suffix:netflix.com)\n    - proxy(suffix:nflxvideo.net)\n    - proxy(suffix:nflxext.com)\n    - proxy(suffix:nflxso.net)\n    - proxy(suffix:disneyplus.com)\n    - proxy(suffix:dssott.com)\n    - proxy(suffix:bamgrid.com)\n    - proxy(suffix:hulu.com)\n    - proxy(suffix:primevideo.com)\n    - proxy(suffix:amazon.video)\n    - proxy(suffix:spotify.com)\n    - direct(all)"
            else
                acl_block+="    - proxy(all)"
            fi

            local out_block="outbound:\n"
            if [[ "$out_type" == "socks5" ]]; then
                # 【优化】单引号转移防 YAML 注入，确保中转代理特殊密码不出错
                local safe_user=$(echo "$out_user" | sed "s/'/''/g")
                local safe_pass=$(echo "$out_pass" | sed "s/'/''/g")
                
                out_block+="  type: socks5\n  socks5:\n    addr: $out_addr\n"
                [[ -n "$out_user" ]] && out_block+="    username: '${safe_user}'\n    password: '${safe_pass}'\n"
            else
                out_block+="  type: http\n  http:\n    url: $proxy_uri\n"
            fi

            cp -f /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak

            cat << 'EOF' > /tmp/hy2_yaml_editor.py
import sys

with open('/etc/hysteria/config.yaml', 'r') as f:
    lines = f.read().split('\n')

new_lines = []
skip = False
for line in lines:
    if line.startswith('acl:') or line.startswith('outbound:'):
        skip = True
        continue
    if skip and line and not line.startswith(' ') and not line.startswith('#'):
        skip = False
    if not skip:
        new_lines.append(line)

new_content = '\n'.join(new_lines).strip()
new_content += '\n\n' + sys.argv[1].replace('\\n', '\n')
if len(sys.argv) > 2 and sys.argv[2]:
    new_content += '\n\n' + sys.argv[2].replace('\\n', '\n')

with open('/etc/hysteria/config.yaml', 'w') as f:
    f.write(new_content + '\n')
EOF
            python3 /tmp/hy2_yaml_editor.py "$acl_block" "$out_block"
            rm -f /tmp/hy2_yaml_editor.py

            green "  新落地代理与路由配置写入完毕！"
            
            echo ""
            yellow "  正在重启 Hysteria 2 核心应用配置..."
            svc_stop hysteria-server 2>/dev/null
            svc_start hysteria-server

            sleep 2

            local is_active=0
            if [[ $SYSTEM == "Alpine" ]]; then
                rc-service hysteria-server status 2>/dev/null | grep -q 'started' && is_active=1
            else
                systemctl is-active --quiet hysteria-server 2>/dev/null && is_active=1
            fi

            if [[ $is_active -eq 1 ]]; then
                green "  [✔] 重启成功！静态住宅 IP 落地规则已全面生效。"
            else
                red "  [✘] 致命错误：核心服务启动失败！可能配置文件语法存在冲突。"
                purple "  正在为您自动回滚到修改前的稳定配置..."
                mv -f /etc/hysteria/config.yaml.bak /etc/hysteria/config.yaml
                svc_start hysteria-server
                green "  [✔] 回滚完成，已恢复原状。"
            fi
            ;;
        2)
            cp -f /etc/hysteria/config.yaml /etc/hysteria/config.yaml.bak
            
            local default_acl="acl:\n  inline:\n    - reject(169.254.0.0/16)\n    - reject(::1/128)\n    - reject(127.0.0.0/8)\n    - reject(10.0.0.0/8)\n    - reject(172.16.0.0/12)\n    - reject(192.168.0.0/16)\n    - reject(fc00::/7)\n    - reject(fe80::/10)\n    - direct(all)"
            
            cat << 'EOF' > /tmp/hy2_yaml_editor.py
import sys
with open('/etc/hysteria/config.yaml', 'r') as f:
    lines = f.read().split('\n')
new_lines = []
skip = False
for line in lines:
    if line.startswith('acl:') or line.startswith('outbound:'):
        skip = True
        continue
    if skip and line and not line.startswith(' ') and not line.startswith('#'):
        skip = False
    if not skip:
        new_lines.append(line)
new_content = '\n'.join(new_lines).strip()
new_content += '\n\n' + sys.argv[1].replace('\\n', '\n')
with open('/etc/hysteria/config.yaml', 'w') as f:
    f.write(new_content + '\n')
EOF
            python3 /tmp/hy2_yaml_editor.py "$default_acl"
            rm -f /tmp/hy2_yaml_editor.py

            green "  已清除落地代理与分流配置参数。"
            
            yellow "  正在重启 Hysteria 2 核心..."
            svc_stop hysteria-server 2>/dev/null
            svc_start hysteria-server
            sleep 2
            green "  [✔] 重启成功！已安全退回服务器本机 IP 直连输出模式。"
            ;;
        3)
            echo ""
            print_line
            yellow "  ▶ 正在检查落地代理运行与健康状态..."
            if ! grep -q "^outbound:" /etc/hysteria/config.yaml; then
                red "  当前未开启落地代理，正在使用本机原生直连。"
            else
                local current_type=$(awk '/^outbound:/{getline; print $2}' /etc/hysteria/config.yaml | tr -d '\r')
                local curl_proxy=""
                
                if [[ "$current_type" == "socks5" ]]; then
                    local s_addr=$(awk '/socks5:/{getline; print $2}' /etc/hysteria/config.yaml | awk '/addr:/{print $2}' | tr -d '\r')
                    local s_user=$(awk '/socks5:/{getline; getline; print $0}' /etc/hysteria/config.yaml | awk '/username:/{print $2}' | tr -d '\r' | tr -d "'")
                    local s_pass=$(awk '/socks5:/{getline; getline; getline; print $0}' /etc/hysteria/config.yaml | awk '/password:/{print $2}' | tr -d '\r' | tr -d "'")
                    if [[ -n "$s_user" ]]; then
                        curl_proxy="socks5h://${s_user}:${s_pass}@${s_addr}"
                    else
                        curl_proxy="socks5h://${s_addr}"
                    fi
                elif [[ "$current_type" == "http" ]]; then
                    curl_proxy=$(awk '/http:/{getline; print $2}' /etc/hysteria/config.yaml | awk '/url:/{print $2}' | tr -d '\r')
                fi

                echo ""
                yellow "  [1/2] 测试外网 TCP 连通性与真实出口 IP 伪装度..."
                local geo_info=$(curl -x "$curl_proxy" -s -m 7 "http://ip-api.com/json/?lang=zh-CN")
                local api_status=$(echo "$geo_info" | jq -r '.status' 2>/dev/null)
                
                if [[ "$api_status" == "success" ]]; then
                    local test_ip=$(echo "$geo_info" | jq -r '.query')
                    local test_country=$(echo "$geo_info" | jq -r '.country')
                    local test_city=$(echo "$geo_info" | jq -r '.city')
                    local test_isp=$(echo "$geo_info" | jq -r '.isp')
                    
                    green "  [✔] 落地状态正常！您的最终出口已被伪装："
                    yellow "  ▶ 出口 IP : $test_ip"
                    yellow "  ▶ 归属地  : $test_country - $test_city"
                    yellow "  ▶ 运营商  : $test_isp"
                else
                    red "  [✘] 测试失败！您的静态住宅代理可能已过期、被封禁或格式错误导致无法连通网络。"
                fi

                echo ""
                yellow "  [2/2] 检查 Hysteria 2 守护进程运转情况..."
                local is_active=0
                if [[ $SYSTEM == "Alpine" ]]; then
                    rc-service hysteria-server status 2>/dev/null | grep -q 'started' && is_active=1
                else
                    systemctl is-active --quiet hysteria-server 2>/dev/null && is_active=1
                fi
                
                if [[ $is_active -eq 1 ]]; then
                    green "  [✔] 核心进程状态: 活跃 (Active & Running)"
                else
                    red "  [✘] 核心进程状态: 停止/崩溃 (Inactive)"
                fi
            fi
            ;;
        0)
            return
            ;;
        *)
            red "  输入无效"; sleep 1; return
            ;;
    esac

    echo ""
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
    echo -e "  ${LIGHT_GREEN}[5]${PLAIN} ${LIGHT_GREEN}配置 出口落地代理与分流 (IP 检测 & 流媒体解锁)${PLAIN}"
    echo "----------------------------------------------------------------------------------"
    echo -e "  ${LIGHT_GREEN}[6]${PLAIN} ${LIGHT_GREEN}获取 节点配置 与 订阅链接${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[7]${PLAIN} ${LIGHT_YELLOW}查看 客户端连接 与 流量统计${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[8]${PLAIN} ${LIGHT_PURPLE}开启 BBR 及 UDP 极限并发加速 (强烈推荐)${PLAIN}"
    echo -e "  ${LIGHT_GREEN}[9]${PLAIN} ${LIGHT_GREEN}检查 证书安装状态与详细信息${PLAIN}"
    echo "----------------------------------------------------------------------------------"
    echo -e "  ${LIGHT_GREEN}[0]${PLAIN} ${LIGHT_RED}退出脚本${PLAIN}"
    red "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo ""
    echo -en " ${LIGHT_YELLOW} ▶ 请输入选项 [0-9]: ${PLAIN}"
    read menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) edit_config ;;
        5 ) config_outbound ;;
        6 ) showconf ;;
        7 ) check_traffic ;;
        8 ) enable_bbr ;;
        9 ) check_cert ;;
        0 ) exit 0 ;;
        * ) red "  输入无效"; sleep 1 ;;
    esac
}

while true; do
    menu
done
