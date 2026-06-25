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

[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

# ==========================================
# 1. 动态检测包管理器及系统服务适配
# ==========================================
if [[ -x "$(command -v apt-get)" ]]; then
    PM="apt-get"
    PM_INSTALL="apt-get install -y"
    PM_UPDATE="apt-get update -y"
    PM_UNINSTALL="apt-get autoremove -y"
    CRON_PKG="cron"
    CRON_SERVICE="cron"
    IPTABLES_PKG="iptables-persistent netfilter-persistent"
elif [[ -x "$(command -v dnf)" ]]; then
    PM="dnf"
    PM_INSTALL="dnf install -y"
    PM_UPDATE="dnf check-update"
    PM_UNINSTALL="dnf autoremove -y"
    CRON_PKG="cronie"
    CRON_SERVICE="crond"
    IPTABLES_PKG="iptables-services"
elif [[ -x "$(command -v yum)" ]]; then
    PM="yum"
    PM_INSTALL="yum install -y"
    PM_UPDATE="yum check-update"
    PM_UNINSTALL="yum autoremove -y"
    CRON_PKG="cronie"
    CRON_SERVICE="crond"
    IPTABLES_PKG="iptables-services"
elif [[ -x "$(command -v pacman)" ]]; then
    PM="pacman"
    PM_INSTALL="pacman -S --noconfirm"
    PM_UPDATE="pacman -Sy"
    PM_UNINSTALL="pacman -Rsn --noconfirm"
    CRON_PKG="cronie"
    CRON_SERVICE="cronie"
    IPTABLES_PKG="iptables"
elif [[ -x "$(command -v zypper)" ]]; then
    PM="zypper"
    PM_INSTALL="zypper install -y"
    PM_UPDATE="zypper refresh"
    PM_UNINSTALL="zypper remove -y"
    CRON_PKG="cron"
    CRON_SERVICE="cron"
    IPTABLES_PKG="iptables"
else
    red "未检测到支持的包管理器 (apt/dnf/yum/pacman/zypper)，暂不支持当前操作系统！"
    exit 1
fi

# 统一防火墙规则保存函数
save_iptables() {
    if [[ $PM == "apt-get" ]]; then
        netfilter-persistent save >/dev/null 2>&1
    elif [[ $PM == "yum" || $PM == "dnf" ]]; then
        service iptables save >/dev/null 2>&1
    elif [[ $PM == "pacman" || $PM == "zypper" ]]; then
        iptables-save > /etc/iptables/iptables.rules 2>/dev/null
        ip6tables-save > /etc/iptables/ip6tables.rules 2>/dev/null
    fi
}

if [[ -z $(type -P curl) ]]; then
    ${PM_UPDATE}
    ${PM_INSTALL} curl
fi

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

        chmod a+x /root # 让 Hysteria 主程序访问到 /root 目录

        if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "检测到原有域名：$domain 的证书，正在应用"
            hy_domain=$domain
        else
            WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
                wg-quick down wgcf >/dev/null 2>&1
                systemctl stop warp-go >/dev/null 2>&1
                realip
                wg-quick up wgcf >/dev/null 2>&1
                systemctl start warp-go >/dev/null 2>&1
            else
                realip
            fi
            
            read -p "请输入需要申请证书的域名：" domain
            [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
            green "已输入的域名：$domain" && sleep 1
            domainIP=$(curl -sm8 ipget.net/?ip="${domain}")
            if [[ $domainIP == $ip ]]; then
                ${PM_INSTALL} curl wget sudo socat openssl $CRON_PKG
                systemctl start $CRON_SERVICE
                systemctl enable $CRON_SERVICE
                
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
                if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]]; then
                    echo $domain > /root/ca.log
                    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
                    echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                    green "证书申请成功! 脚本申请到的证书 (cert.crt) 和私钥 (private.key) 文件已保存到 /root 文件夹下"
                    hy_domain=$domain
                fi
            else
                red "当前域名解析的IP与当前VPS使用的真实IP不匹配"
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

    read -p "设置 Hysteria 2 端口 [1-65535]（回车则随机分配端口）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
            read -p "端口被占用，请重新设置 [1-65535]：" port
            [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
        fi
    done

    yellow "使用端口：$port"
    inst_jump
}

inst_jump(){
    green "Hysteria 2 端口使用模式如下："
    echo -e " ${GREEN}1.${PLAIN} 单端口 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 端口跳跃"
    read -rp "请输入选项 [1-2]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        read -p "设置范围端口的起始端口：" firstport
        read -p "设置范围端口的末尾端口：" endport
        iptables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        ip6tables -t nat -A PREROUTING -p udp --dport $firstport:$endport  -j DNAT --to-destination :$port
        save_iptables
    else
        red "将继续使用单端口模式"
    fi
}

inst_pwd(){
    read -p "设置 Hysteria 2 密码（回车跳过为随机字符）：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-8)
    yellow "使用密码：$auth_pwd"
}

inst_site(){
    read -rp "请输入 Hysteria 2 的伪装网站地址 （去除https://） [默认首尔大学]：" proxysite
    [[ -z $proxysite ]] && proxysite="en.snu.ac.kr"
    yellow "使用伪装网站：$proxysite"
}

insthysteria(){
    ${PM_UPDATE}
    ${PM_INSTALL} curl wget sudo qrencode procps iptables $IPTABLES_PKG openssl

    # ==========================================
    # 2. 动态检测系统架构，原生下载官方主程序
    # ==========================================
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64 | x64 | amd64 ) HY2_ARCH="amd64" ;;
        i386 | i686 )          HY2_ARCH="386" ;;
        armv8 | armv8l | aarch64 | arm64 ) HY2_ARCH="arm64" ;;
        armv7l )               HY2_ARCH="arm" ;;
        s390x )                HY2_ARCH="s390x" ;;
        * ) red "不支持的架构: $ARCH" && exit 1 ;;
    esac

    green "正在拉取 Hysteria 2 官方主程序 ($HY2_ARCH) ..."
    wget -N "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${HY2_ARCH}" -O /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria

    if [[ -f "/usr/local/bin/hysteria" ]]; then
        green "Hysteria 2 主程序部署成功！"
    else
        red "Hysteria 2 主程序下载失败！" && exit 1
    fi

    # ==========================================
    # 3. 注册跨平台 Systemd 守护进程
    # ==========================================
    mkdir -p /etc/hysteria
    cat << EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

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

    realip
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
fastOpen: true
socks5:
  listen: 127.0.0.1:5678
transport:
  udp:
    hopInterval: 30s 
EOF

    cat << EOF > /root/hy/hy-client.json
{
  "server": "$last_ip:$last_port",
  "auth": "$auth_pwd",
  "tls": {
    "sni": "$hy_domain",
    "insecure": true
  },
  "quic": {
    "initStreamReceiveWindow": 16777216,
    "maxStreamReceiveWindow": 16777216,
    "initConnReceiveWindow": 33554432,
    "maxConnReceiveWindow": 33554432
  },
  "socks5": {
    "listen": "127.0.0.1:5678"
  },
  "transport": {
    "udp": {
      "hopInterval": "30s"
    }
  }
}
EOF

    url="hysteria2://$auth_pwd@$last_ip:$last_port/?insecure=1&sni=$hy_domain#Hysteria2-Node"
    echo $url > /root/hy/url.txt

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server

    if [[ -n $(systemctl status hysteria-server 2>/dev/null | grep -w active) ]]; then
        green "Hysteria 2 服务启动成功"
    else
        red "Hysteria 2 服务启动失败，请运行 systemctl status hysteria-server 查看服务状态" && exit 1
    fi
    showconf
}

unsthysteria(){
    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /etc/systemd/system/hysteria-server.service
    systemctl daemon-reload
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy
    iptables -t nat -F PREROUTING >/dev/null 2>&1
    save_iptables
    green "Hysteria 2 已彻底卸载完成！"
}

starthysteria(){
    systemctl start hysteria-server
    systemctl enable hysteria-server >/dev/null 2>&1
}

stophysteria(){
    systemctl stop hysteria-server
    systemctl disable hysteria-server >/dev/null 2>&1
}

hysteriaswitch(){
    echo -e " ${GREEN}1.${PLAIN} 启动 Hysteria 2\n ${GREEN}2.${PLAIN} 关闭 Hysteria 2\n ${GREEN}3.${PLAIN} 重启 Hysteria 2"
    read -rp "请输入选项 [1-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) stophysteria && starthysteria ;;
        * ) exit 1 ;;
    esac
}

changeport(){
    oldport=$(cat /etc/hysteria/config.yaml | grep listen | awk -F ":" '{print $3}')
    read -p "设置新端口[1-65535]：" port
    sed -i "s/$oldport/$port/g" /etc/hysteria/config.yaml
    sed -i "s/$oldport/$port/g" /root/hy/hy-client.yaml
    sed -i "s/$oldport/$port/g" /root/hy/hy-client.json
    stophysteria && starthysteria
    green "端口已修改为：$port"
}

changepasswd(){
    oldpasswd=$(cat /etc/hysteria/config.yaml | grep password | awk '{print $2}')
    read -p "设置新密码：" passwd
    sed -i "s/$oldpasswd/$passwd/g" /etc/hysteria/config.yaml
    sed -i "s/$oldpasswd/$passwd/g" /root/hy/hy-client.yaml
    sed -i "s/$oldpasswd/$passwd/g" /root/hy/hy-client.json
    stophysteria && starthysteria
    green "密码已修改为：$passwd"
}

changeproxysite(){
    oldproxysite=$(cat /etc/hysteria/config.yaml | grep url | awk -F "https://" '{print $2}')
    inst_site
    sed -i "s/$oldproxysite/$proxysite/g" /etc/hysteria/config.yaml
    stophysteria && starthysteria
    green "伪装网站已修改为：$proxysite"
}

changeconf(){
    echo -e " ${GREEN}1.${PLAIN} 修改端口\n ${GREEN}2.${PLAIN} 修改密码\n ${GREEN}3.${PLAIN} 修改伪装网站"
    read -p " 选择操作 [1-3]：" confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changepasswd ;;
        3 ) changeproxysite ;;
        * ) exit 1 ;;
    esac
}

showconf(){
    yellow "客户端 YAML 配置 (/root/hy/hy-client.yaml):"
    red "$(cat /root/hy/hy-client.yaml)"
    yellow "\n节点分享链接 (/root/hy/url.txt):"
    red "$(cat /root/hy/url.txt)"
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                  ${GREEN}Hysteria 2 跨平台全适配安装脚本${PLAIN}            #"
    echo "#############################################################"
    echo -e " ${GREEN}1.${PLAIN} ${GREEN}安装 Hysteria 2${PLAIN}"
    echo -e " ${RED}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 3. 管理服务状态 (开启/关闭/重启)"
    echo -e " 4. 修改核心配置 (端口/密码/伪装)"
    echo -e " 5. 查看配置与链接"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    read -rp "请输入选项 [0-5]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        * ) exit 0 ;;
    esac
}

menu
