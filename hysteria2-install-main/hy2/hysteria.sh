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
    if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" start; else systemctl start "$1"; fi
}
svc_stop() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-service "$1" stop || true; else systemctl stop "$1" || true; fi
}
svc_enable() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-update add "$1" default; else systemctl enable "$1"; fi
}
svc_disable() {
    if [[ $SYSTEM == "Alpine" ]]; then rc-update del "$1" default || true; else systemctl disable "$1" || true; fi
}

save_iptables() {
    if [[ $SYSTEM == "Alpine" ]]; then
        rc-service iptables save || true
        rc-service ip6tables save || true
    elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" ]]; then
        service iptables save || true
        service ip6tables save || true
    else
        netfilter-persistent save || true
    fi
}

# ================= 系统环境与前置检查 =================
check_env() {
    clear
    yellow "================= 🖥️  系统环境检查 ================="
    green " 当前操作系统: $SYSTEM"
    echo ""
    yellow " 正在检查 Hysteria 2 及附加服务所需的前置依赖包..."
    
    local cmds=("curl" "wget" "sudo" "ss" "iptables" "python3" "openssl" "socat")
    local missing=0

    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            red " ❌ [缺失] $cmd"
            missing=1
        else
            green " ✅ [正常] $cmd 已安装"
        fi
    done

    if ! command -v crontab &> /dev/null; then
        red " ❌ [缺失] crontab (用于证书自动续期)"
        missing=1
    else
        green " ✅ [正常] crontab 已安装"
    fi

    if [[ $SYSTEM == "Debian" || $SYSTEM == "Ubuntu" ]]; then
        if ! command -v netfilter-persistent &> /dev/null; then
            red " ❌ [缺失] netfilter-persistent (用于防火墙规则保存)"
            missing=1
        else
            green " ✅ [正常] netfilter-persistent 已安装"
        fi
    fi

    if [[ $missing -eq 1 ]]; then
        echo ""
        yellow "--------------------------------------------------"
        yellow " ⏳ 发现缺失前置组件，正在为您自动拉取安装，请稍候..."
        
        if [[ ! $SYSTEM == "CentOS" ]]; then
            ${PACKAGE_UPDATE[int]}
        fi
        
        if [[ $SYSTEM == "Alpine" ]]; then
            ${PACKAGE_INSTALL[int]} curl wget sudo procps iptables ip6tables iproute2 python3 openssl socat cronie
            svc_start crond
            svc_enable crond
        elif [[ $SYSTEM == "CentOS" || $SYSTEM == "Fedora" ]]; then
            ${PACKAGE_INSTALL[int]} curl wget sudo procps iptables iptables-services iproute python3 openssl socat cronie
            svc_start crond
            svc_enable crond
        else
            export DEBIAN_FRONTEND=noninteractive
            ${PACKAGE_INSTALL[int]} curl wget sudo procps iptables-persistent netfilter-persistent iproute2 python3 openssl socat cron
            svc_start cron
            svc_enable cron
        fi
        
        green " ✨ 所有前置依赖补全完成！"
    else
        echo ""
        green "--------------------------------------------------"
        green " 🎉 所有前置依赖检查通过，环境非常完美，无需额外安装！"
    fi
    yellow "=================================================="
    echo ""
    sleep 2
}

realip(){
    # 强化获取 IP 的稳定性，防止抓取到报错的 HTML 代码，并加上 head -n 1 防止多行污染
    ip=$(curl -s4m8 ip.sb -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1 || curl -s4m8 ifconfig.me -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6m8 ip.sb -k || curl -s6m8 ifconfig.me -k)
    fi
}

inst_cert(){
    green "Hysteria 2 协议证书申请方式如下："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 必应自签证书 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} Acme 脚本申请 ${YELLOW}(Cloudflare DNS API 验证)${PLAIN}"
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
            green "已输入的域名：$domain"
            
            domainIP=$(python3 -c "import socket; print(socket.gethostbyname('${domain}'))" 2>/dev/null)
            
            if [[ "$domainIP" != "$ip" ]]; then
                yellow "警告: 当前域名解析的 IP ($domainIP) 与当前 VPS 的真实 IP ($ip) 不匹配或无法解析！"
                yellow "虽然 DNS 验证可以成功申请证书，但 Hysteria 2 节点必须使用真实 IP 直连。"
                yellow "请确保你的 Cloudflare 已关闭小云朵 (DNS Only)，否则客户端无法连接。"
                read -p "是否确认并继续申请证书？(y/n) [默认: y]: " force_cert
                [[ -z $force_cert ]] && force_cert="y"
                if [[ $force_cert != "y" && $force_cert != "Y" ]]; then
                    exit 1
                fi
            fi

            green "=========================================================="
            yellow "准备使用 Cloudflare DNS API 申请证书"
            yellow "请在 Cloudflare 控制台 -> 我的个人资料 -> API 令牌 中获取"
            green "=========================================================="
            read -p "请输入 Cloudflare 账号邮箱 (CF_Email): " cf_email
            read -p "请输入 Cloudflare Global API Key: " cf_key
            
            if [[ -z $cf_email || -z $cf_key ]]; then
                red "邮箱或 API Key 不能为空，无法继续申请证书！"
                exit 1
            fi

            export CF_Email="$cf_email"
            export CF_Key="$cf_key"
            
            curl https://get.acme.sh | sh -s email=$cf_email
            bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            
            green "正在通过 Cloudflare DNS API 验证域名所有权，这可能需要 1-3 分钟，请耐心等待..."
            bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${domain} -k ec-256
            
            # 根据不同系统定义续签后的重载命令
            if [[ $SYSTEM == "Alpine" ]]; then
                reload_cmd="rc-service hysteria-server restart"
            else
                reload_cmd="systemctl restart hysteria-server"
            fi
            
            # 增加 --reloadcmd 确保续签后自动重启服务加载新证书
            bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc --reloadcmd "$reload_cmd"
            
            if [[ -f /root/cert.crt && -f /root/private.key ]]; then
                echo $domain > /root/ca.log
                # acme.sh 安装时已自动配置用户级 cron，无需重复画蛇添足
                chmod 644 /root/cert.crt
                chmod 600 /root/private.key
                
                green "证书申请成功！已保存至 /root/ 目录下。"
                hy_domain=$domain
            else
                red "证书申请失败！请检查你的 Cloudflare 邮箱和 API Key 是否正确，或者查看终端报错信息。"
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
        
        chmod 644 /etc/hysteria/cert.crt
        chmod 600 /etc/hysteria/private.key
        
        hy_domain="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_port(){
    read -p "设置 Hysteria 2 节点端口 [1-65535]（回车随机）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    
    # 强制校验是否为纯数字
    while [[ ! "$port" =~ ^[0-9]+$ ]]; do
        red "⚠️ 端口必须是纯数字！"
        read -p "请重新设置 Hysteria 2 节点端口 [1-65535]（回车随机）：" port
        [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    done

    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
            echo -e "${RED} $port ${PLAIN} 端口已经被占用，请更换端口重试！"
            read -p "设置 Hysteria 2 节点端口 [1-65535]（回车随机）：" port
            [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
            while [[ ! "$port" =~ ^[0-9]+$ ]]; do
                red "⚠️ 端口必须是纯数字！"
                read -p "请重新设置 Hysteria 2 节点端口 [1-65535]（回车随机）：" port
                [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
            done
        fi
    done
    yellow "将在 Hysteria 2 节点使用的端口是：$port"
    
    iptables -I INPUT -p udp --dport $port -j ACCEPT
    ip6tables -I INPUT -p udp --dport $port -j ACCEPT
    
    save_iptables

    inst_jump
}

inst_jump(){
    green "Hysteria 2 端口使用模式如下："
    echo -e " ${GREEN}1.${PLAIN} 单端口 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 端口跳跃"
    read -rp "请输入选项 [1-2]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        read -p "起始端口 (建议10000-65535)：" firstport
        while [[ ! "$firstport" =~ ^[0-9]+$ ]]; do
            red "⚠️ 端口必须是纯数字！"
            read -p "起始端口 (建议10000-65535)：" firstport
        done

        read -p "末尾端口 (一定要比起始大)：" endport
        while [[ ! "$endport" =~ ^[0-9]+$ || "$endport" -le "$firstport" ]]; do
            red "⚠️ 端口必须是纯数字，且必须大于起始端口！"
            read -p "末尾端口 (一定要比起始大)：" endport
        done

        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        
        save_iptables
    fi
}

inst_sub_port(){
    read -p "设置 HTTP 订阅服务端口 [1024-65535]（回车则随机分配）：" sub_port_input
    [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    
    # 强制校验是否为纯数字
    while [[ ! "$sub_port_input" =~ ^[0-9]+$ ]]; do
        red "⚠️ 端口必须是纯数字！"
        read -p "请重新设置 HTTP 订阅服务端口 [1024-65535]：" sub_port_input
        [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
    done
    
    if [[ "$sub_port_input" -lt 1024 ]]; then
        red "⚠️ 警告：订阅服务为了安全已降级为 nobody 运行，Linux 严禁非 root 用户绑定 1024 以下特权端口！"
        yellow "系统已自动为您切换为安全的随机高位端口。"
        sub_port_input=$(shuf -i 10000-30000 -n 1)
    fi
    
    until [[ -z $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$sub_port_input") ]]; do
        if [[ -n $(ss -tunlp | grep -w tcp | awk '{print $5}' | sed 's/.*://g' | grep -w "$sub_port_input") ]]; then
            echo -e "${RED} $sub_port_input ${PLAIN} 端口已经被占用，请更换端口重试！"
            read -p "设置 HTTP 订阅服务端口 [1024-65535]（回车则随机分配）：" sub_port_input
            [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
            
            while [[ ! "$sub_port_input" =~ ^[0-9]+$ ]]; do
                red "⚠️ 端口必须是纯数字！"
                read -p "请重新设置 HTTP 订阅服务端口 [1024-65535]：" sub_port_input
                [[ -z $sub_port_input ]] && sub_port_input=$(shuf -i 10000-30000 -n 1)
            done

            if [[ "$sub_port_input" -lt 1024 ]]; then
                sub_port_input=$(shuf -i 10000-30000 -n 1)
            fi
        fi
    done
    yellow "HTTP 订阅服务将使用的端口是：$sub_port_input"
}

inst_pwd(){
    read -p "设置 Hysteria 2 密码（回车随机）：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c 1-8 || date +%s%N | md5sum | cut -c 1-8)
    yellow "密码为：$auth_pwd"
}

inst_site(){
    read -rp "请输入伪装网站地址 （去除https://） [默认www.bing.com]：" proxysite
    [[ -z $proxysite ]] && proxysite="www.bing.com"
}

inst_node_name(){
    read -rp "请输入你的节点名称 (⚠️ 请勿包含空格或特殊字符) [默认: Hysteria2_Node]：" custom_node_name
    [[ -z $custom_node_name ]] && custom_node_name="Hysteria2_Node"
}

inst_bandwidth(){
    echo ""
    green "================ 🚀 节点带宽控制配置 (降低延迟关键) ================"
    yellow "Hysteria 2 推荐配置服务端最大可用带宽，以配合 Brutal 拥塞控制算法防止缓冲膨胀。"
    
    read -p "请输入 VPS 的最大上行带宽 (单位 Mbps，仅填数字，回车默认 1000)：" bw_up_input
    [[ -z $bw_up_input ]] && bw_up_input="1000"
    # 强制校验是否为纯数字
    while [[ ! "$bw_up_input" =~ ^[0-9]+$ ]]; do
        red "⚠️ 输入无效，请仅输入纯数字！"
        read -p "请输入 VPS 的最大上行带宽 (单位 Mbps)：" bw_up_input
    done
    bw_up="${bw_up_input} mbps"
    
    read -p "请输入 VPS 的最大下行带宽 (单位 Mbps，仅填数字，回车默认 1000)：" bw_down_input
    [[ -z $bw_down_input ]] && bw_down_input="1000"
    # 强制校验是否为纯数字
    while [[ ! "$bw_down_input" =~ ^[0-9]+$ ]]; do
        red "⚠️ 输入无效，请仅输入纯数字！"
        read -p "请输入 VPS 的最大下行带宽 (单位 Mbps)：" bw_down_input
    done
    bw_down="${bw_down_input} mbps"
}

inst_obfs(){
    echo ""
    green "================ 🛡️ 防阻断混淆(Obfuscation)配置 ================"
    yellow "开启 Salamander 混淆可有效防止运营商针对未知大流量 UDP 的 QoS 限速和封锁。"
    read -p "是否开启 Salamander 混淆？(y/n) [默认: y]: " enable_obfs
    [[ -z $enable_obfs ]] && enable_obfs="y"
    if [[ "$enable_obfs" == "y" || "$enable_obfs" == "Y" ]]; then
        obfs_pwd=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c 1-12 || date +%s%N | md5sum | cut -c 1-12)
        yellow "已开启混淆，自动生成的混淆密码为：$obfs_pwd"
    else
        obfs_pwd=""
        yellow "已选择不开启混淆。"
    fi
}

# ================= 客户端配置与 HTTP 守护进程 =================
generate_client_configs() {
    realip
    
    local s_pwd=$(grep 'password:' /etc/hysteria/config.yaml | head -n 1 | awk '{print $2}')
    local c_domain=$(grep 'sni:' /etc/hysteria/hy-client.yaml | awk '{print $2}')
    [[ -z "$c_domain" ]] && c_domain="www.bing.com"
    
    local c_server=$(grep '^server:' /etc/hysteria/hy-client.yaml | awk '{print $2}')
    local c_ports="${c_server##*:}"
    local primary_port=$(echo "$c_ports" | cut -d',' -f1)
    local hop_ports=$(echo "$c_ports" | awk -F ',' '{print $2}')
    
    # 提取服务端混淆密码和证书验证状态
    local s_obfs_pwd=$(awk '/obfs:/{flag=1} flag && /password:/{print $2; flag=0}' /etc/hysteria/config.yaml | tr -d '"' | tr -d "'")
    local is_insecure_url=$(cat /etc/hysteria/insecure_state.txt 2>/dev/null || echo "1")
    
    local clash_cert_verify="true"
    if [[ "$is_insecure_url" == "0" ]]; then
        clash_cert_verify="false"
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
    mkdir -p $web_dir
    echo "<h1 style='text-align:center;margin-top:20%;'>403 Forbidden</h1>" > $web_dir/index.html

    local sub_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N | md5sum | head -c 16)
    mkdir -p $web_dir/$sub_uuid
    echo "<h1 style='text-align:center;margin-top:20%;'>403 Forbidden</h1>" > $web_dir/$sub_uuid/index.html
    echo "$sub_uuid" > /etc/hysteria/sub_path.txt

    # 包含动态证书验证和混淆参数的 URL 链接
    local url="hysteria2://$s_pwd@$uri_ip:$primary_port/?insecure=${is_insecure_url}&sni=$c_domain${mport_param}${obfs_param}#${custom_node_name}"
    echo "$url" > $web_dir/$sub_uuid/url.txt
    
    echo -n "$url" | base64 | tr -d '\r\n' > $web_dir/$sub_uuid/sub_b64.txt

    # Clash Meta 订阅文件生成 (动态判断是否需要 skip-cert-verify)
    cat << EOF > $web_dir/$sub_uuid/clash-meta-sub.yaml
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
  - name: "🚀 节点选择"
    type: select
    proxies:
      - '${custom_node_name}'
      - DIRECT

rules:
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF

    local sub_port=$sub_port_input
    echo "$sub_port" > /etc/hysteria/sub_port.txt
    
    chown -R nobody $web_dir || true
    
    iptables -I INPUT -p tcp --dport $sub_port -j ACCEPT
    save_iptables
    
    local py_path=$(command -v python3)
    if [[ $SYSTEM == "Alpine" ]]; then
        cat << EOF > /etc/init.d/hysteria-sub
#!/sbin/openrc-run
description="Hysteria HTTP Subscription Server"
command="${py_path}"
command_args="-m http.server ${sub_port}"
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
Description=Hysteria HTTP Subscription Server
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=${web_dir}
ExecStart=${py_path} -m http.server ${sub_port}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria-sub
    fi
    
    svc_stop hysteria-sub || true
    svc_start hysteria-sub
    
    green "HTTP 订阅服务已通过系统守护进程启动 (以非特权用户运行)，并已开启防遍历保护..."
}

showconf(){
    local ip=$(curl -s4m8 ip.sb -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1 || curl -s4m8 ifconfig.me -k | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -n 1)
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6m8 ip.sb -k || curl -s6m8 ifconfig.me -k)
    fi
    local sub_port=$(cat /etc/hysteria/sub_port.txt 2>/dev/null)
    local sub_path=$(cat /etc/hysteria/sub_path.txt 2>/dev/null)
    local web_dir="/var/www/hysteria"
    
    yellow "================ Hysteria 2 全平台订阅链接 ================"
    green "🎯 1. Clash Meta 专属配置订阅链接 (推荐 Clash Verge 一键导入):"
    red "http://$ip:$sub_port/$sub_path/clash-meta-sub.yaml"
    echo ""
    green "🔗 2. 通用 Base64 订阅链接 (适用 v2rayN/Shadowrocket 等):"
    red "http://$ip:$sub_port/$sub_path/sub_b64.txt"
    echo ""
    green "📄 3. 原始 Hysteria 2 协议链接单节点:"
    red "$(cat $web_dir/$sub_path/url.txt 2>/dev/null)"
    echo ""
    yellow "==========================================================="
    yellow "提示 1: 您的订阅链接已被随机 UUID 及防遍历策略双重保护，安全可靠。"
    yellow "提示 2: 导入 Clash 后，请根据您本地的实际宽带，修改 up/down 数值获得最佳体验。"
    echo ""
    read -p "按回车键返回主菜单..."
    menu
}

edit_config() {
    clear
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "未检测到 Hysteria 2 配置文件，请先安装！"
        sleep 2
        menu
        return
    fi
    
    green "================ ⚙️ 当前 Hysteria 2 节点配置 ================"
    cat /etc/hysteria/config.yaml
    green "================================================================"
    echo ""
    read -p "是否需要修改配置文件？(y/n) [默认: n]: " edit_choice
    if [[ "$edit_choice" == "y" || "$edit_choice" == "Y" ]]; then
        if command -v nano >/dev/null; then
            nano /etc/hysteria/config.yaml
        elif command -v vi >/dev/null; then
            vi /etc/hysteria/config.yaml
        else
            red "未找到 nano 或 vi 编辑器，请手动修改 /etc/hysteria/config.yaml"
        fi
        
        green "配置修改完成，正在重启 Hysteria 2 服务以使配置生效..."
        svc_stop hysteria-server
        svc_start hysteria-server
        green "重启成功！新的配置已生效。"
    fi
    echo ""
    read -p "按回车键返回主菜单..."
    menu
}

check_traffic() {
    if [[ ! -f /etc/hysteria/config.yaml ]]; then
        red "未检测到 Hysteria 2 配置文件，请先安装！"
        sleep 2
        menu
        return
    fi
    
    if ! grep -q "trafficStats:" /etc/hysteria/config.yaml; then
        green "正在为 Hysteria 2 自动开启流量统计 API 以获取数据..."
        cat << EOF >> /etc/hysteria/config.yaml

trafficStats:
  listen: 127.0.0.1:9999
EOF
        svc_stop hysteria-server
        svc_start hysteria-server
        sleep 2
    fi

    local traffic_data=$(curl -s http://127.0.0.1:9999/traffic)
    
    if [[ -z "$traffic_data" || "$traffic_data" =~ "404" ]]; then
        red "获取数据失败。请检查 Hysteria 2 服务是否运行正常 ( systemctl status hysteria-server )。"
    elif [[ ! "$traffic_data" =~ '"tx"' ]]; then
        echo ""
        green "================ 🚀 客户端连接与流量统计 =================="
        yellow "当前节点没有任何流量消耗记录或客户端连接。"
        green "========================================================"
    else
        echo ""
        green "================ 🚀 客户端连接与流量统计 =================="
        
        local client_count=$(echo "$traffic_data" | grep -o '"[^"]*":{[^}]*}' | grep -c '"tx"')
        yellow "活跃客户端 (产生流量记录) 总数: $client_count"
        echo "--------------------------------------------------------"
        
        echo "$traffic_data" | grep -o '"[^"]*":{[^}]*}' | grep '"tx"' | while read -r line; do
            user=$(echo "$line" | cut -d '"' -f2)
            tx=$(echo "$line" | grep -o '"tx":[0-9]*' | cut -d: -f2)
            rx=$(echo "$line" | grep -o '"rx":[0-9]*' | cut -d: -f2)
            
            [[ -z $tx ]] && tx=0
            [[ -z $rx ]] && rx=0
            
            tx_mb=$(awk "BEGIN {printf \"%.2f\", $tx/1048576}")
            rx_mb=$(awk "BEGIN {printf \"%.2f\", $rx/1048576}")
            
            echo -e "  👥 客户端账号: ${GREEN}${user}${PLAIN} \t| ⬆️ 节点发送: ${YELLOW}${tx_mb} MB${PLAIN} \t| ⬇️ 节点接收: ${YELLOW}${rx_mb} MB${PLAIN}"
        done
        green "========================================================"
    fi
    
    echo ""
    read -p "按回车键返回主菜单..."
    menu
}

insthysteria(){
    check_env

    mkdir -p /etc/hysteria
    
    green "正在从 Apernet 官方仓库下载 Hysteria 2 二进制核心..."
    arch=$(uname -m)
    case $arch in
        x86_64) hy_arch="amd64" ;;
        aarch64) hy_arch="arm64" ;;
        s390x) hy_arch="s390x" ;;
        *) red "不支持的架构: $arch" && exit 1 ;;
    esac
    
    hy_ver=$(curl -sI "https://github.com/apernet/hysteria/releases/latest" | grep -i "^location:" | sed 's/.*\/tag\///g' | tr -d '\r\n')
    # 修复 URL 编码导致的 404 问题：将 %2F 替换回 /
    hy_ver=${hy_ver//%2F//}
    [[ -z $hy_ver ]] && hy_ver="app/v2.4.0"
    
    wget -N -O /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/${hy_ver}/hysteria-linux-${hy_arch}"
    if [[ $? -ne 0 ]]; then
        red "Hysteria 2 核心下载失败，请检查你的 VPS 网络能否访问 Github！"
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

    # 动态判断是否需要跳过证书验证
    if [[ "$hy_domain" == "www.bing.com" ]]; then
        cert_insecure_yaml="true"
        cert_insecure_url="1"
    else
        cert_insecure_yaml="false"
        cert_insecure_url="0"
    fi
    
    # 存入状态供后续生成客户端配置使用
    echo "$cert_insecure_url" > /etc/hysteria/insecure_state.txt

    # 写入优化版服务端配置 (移除 quic 窗口硬编码，加入混淆与带宽控制)
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
  listen: 127.0.0.1:9999
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
    
    red "======================================================================"
    green "Hysteria 2 代理及 HTTP 订阅服务安装完成"
    echo ""
    green "请在主菜单选择 [4] 查看您的订阅链接。"
    sleep 3
    menu
}

unsthysteria(){
    local main_port=$(grep '^listen:' /etc/hysteria/config.yaml 2>/dev/null | awk -F ':' '{print $NF}' | tr -d ' ')
    local sub_port=$(cat /etc/hysteria/sub_port.txt 2>/dev/null)

    # 强化安全判断，避免 $main_port 为空或含有非数字字符时导致 iptables 报错
    if [[ -n "$main_port" && "$main_port" =~ ^[0-9]+$ ]]; then
        iptables -D INPUT -p udp --dport $main_port -j ACCEPT || true
        ip6tables -D INPUT -p udp --dport $main_port -j ACCEPT || true
        yellow "提示：如果你使用了端口跳跃，建议手动使用 iptables -t nat -F PREROUTING 清理 NAT 规则。"
    fi
    if [[ -n "$sub_port" && "$sub_port" =~ ^[0-9]+$ ]]; then
        iptables -D INPUT -p tcp --dport $sub_port -j ACCEPT || true
    fi

    svc_stop hysteria-server || true
    svc_disable hysteria-server || true
    svc_stop hysteria-sub || true
    svc_disable hysteria-sub || true

    if [[ $SYSTEM == "Alpine" ]]; then
        rm -f /etc/init.d/hysteria-server /etc/init.d/hysteria-sub
    else
        rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-sub.service
        systemctl daemon-reload || true
    fi
    save_iptables

    rm -rf /usr/local/bin/hysteria /etc/hysteria /var/www/hysteria /root/hysteria.sh

    green "Hysteria 2 服务及相关文件、端口规则已彻底卸载清理完成！"
    sleep 2
    exit 0
}

starthysteria(){
    svc_start hysteria-server
    svc_start hysteria-sub
    green "Hysteria 2 及订阅服务已安全启动！"
    sleep 2; menu
}

stophysteria_only(){
    svc_stop hysteria-server
    svc_stop hysteria-sub
    green "Hysteria 2 及订阅服务已关闭！"
}

hysteriaswitch(){
    clear
    green "================ ⚙️ 服务状态控制 ================"
    echo -e " ${GREEN}1.${PLAIN} 启动 Hysteria 2 及订阅服务"
    echo -e " ${RED}2.${PLAIN} 停止 Hysteria 2 及订阅服务"
    echo -e " ${YELLOW}3.${PLAIN} 重启 Hysteria 2 及订阅服务"
    echo " ------------------------------------------------"
    echo -e " 0. 返回主菜单"
    echo ""
    read -rp "请输入选项 [0-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria_only; sleep 2; menu ;;
        3 ) stophysteria_only; starthysteria ;;
        0 ) menu ;;
        * ) red "输入无效，返回主菜单"; sleep 1; menu ;;
    esac
}

enable_bbr(){
    modprobe tcp_bbr || true
    
    # 清理旧的参数并写入全新的网络和 UDP 优化参数
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_default/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_default/d' /etc/sysctl.conf
    sed -i '/net.ipv4.udp_mem/d' /etc/sysctl.conf

    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    # 扩大 UDP 缓冲区至 ~25MB
    echo "net.core.rmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.rmem_default=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_max=26214400" >> /etc/sysctl.conf
    echo "net.core.wmem_default=26214400" >> /etc/sysctl.conf
    echo "net.ipv4.udp_mem=262144 524288 1048576" >> /etc/sysctl.conf
    
    sysctl -p
    
    green "BBR 及 UDP 缓冲区底层优化开启成功！这能显著降低 Hysteria 2 的丢包率。"
    read -p "按回车键返回主菜单..."
    menu
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#     ${GREEN}Hysteria 2 一键安装脚本 (极致优化版)${PLAIN}              #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ${GREEN}安装 Hysteria 2${PLAIN}"
    echo -e " ${RED}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 3. 关闭、开启、重启服务"
    echo -e " 4. 显示 Hysteria 2 订阅链接"
    echo -e " ${YELLOW}5. 开启 BBR 及 UDP 缓冲区网络加速 (推荐)${PLAIN}"
    echo -e " ${GREEN}6. 查看客户端连接及流量统计${PLAIN}"
    echo -e " ${YELLOW}7. 查看并修改 Hysteria 2 配置${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-7]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) showconf ;;
        5 ) enable_bbr ;;
        6 ) check_traffic ;;
        7 ) edit_config ;;
        0 ) exit 0 ;;
        * ) exit 1 ;;
    esac
}

menu
