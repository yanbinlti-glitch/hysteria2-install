#!/usr/bin/env bash
set -Eeuo pipefail

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red() {
    echo -e "\033[31m\033[01m$1\033[0m"
}

green() {
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow() {
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("alpine" "debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon linux" "fedora")
RELEASE=("Alpine" "Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apk update" "apt-get update -y" "apt-get update -y" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apk add" "apt-get install -y" "apt-get install -y" "yum -y install" "yum -y install" "yum -y install")

[[ ${EUID} -ne 0 ]] && red "注意: 请在 root 用户下运行脚本" && exit 1

SYSTEM=""
CURRENT_PKG_INDEX=0

CMD=(
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d '"' -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d '"' -f2)"
    "$(cat /etc/redhat-release 2>/dev/null || true)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
)

for i in "${CMD[@]}"; do
    SYS="${i:-}"
    [[ -n "${SYS// }" ]] && break
done

for ((idx = 0; idx < ${#REGEX[@]}; idx++)); do
    if [[ "$(echo "${SYS:-}" | tr '[:upper:]' '[:lower:]')" =~ ${REGEX[idx]} ]]; then
        SYSTEM="${RELEASE[idx]}"
        CURRENT_PKG_INDEX="${idx}"
        break
    fi
done

[[ -z "${SYSTEM}" ]] && red "目前暂不支持你的 VPS 操作系统！" && exit 1

pkg_update() {
    eval "${PACKAGE_UPDATE[CURRENT_PKG_INDEX]}"
}

pkg_install() {
    eval "${PACKAGE_INSTALL[CURRENT_PKG_INDEX]} $*"
}

if ! command -v curl >/dev/null 2>&1; then
    [[ "${SYSTEM}" != "CentOS" ]] && pkg_update
    pkg_install curl
fi

svc_start() {
    if [[ "${SYSTEM}" == "Alpine" ]]; then
        rc-service "$1" start
    else
        systemctl start "$1"
    fi
}

svc_stop() {
    if [[ "${SYSTEM}" == "Alpine" ]]; then
        rc-service "$1" stop || true
    else
        systemctl stop "$1" || true
    fi
}

svc_restart() {
    if [[ "${SYSTEM}" == "Alpine" ]]; then
        rc-service "$1" restart || {
            rc-service "$1" stop || true
            rc-service "$1" start
        }
    else
        systemctl restart "$1" || {
            systemctl stop "$1" || true
            systemctl start "$1"
        }
    fi
}

svc_enable() {
    if [[ "${SYSTEM}" == "Alpine" ]]; then
        rc-update add "$1" default || true
    else
        systemctl enable "$1" >/dev/null 2>&1 || true
    fi
}

svc_disable() {
    if [[ "${SYSTEM}" == "Alpine" ]]; then
        rc-update del "$1" default || true
    else
        systemctl disable "$1" >/dev/null 2>&1 || true
    fi
}

save_iptables() {
    if [[ "${SYSTEM}" == "Alpine" ]]; then
        rc-service iptables save || true
        rc-service ip6tables save || true
    elif [[ "${SYSTEM}" == "CentOS" || "${SYSTEM}" == "Fedora" ]]; then
        service iptables save || true
        service ip6tables save || true
    else
        command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
    fi
}

ensure_rule() {
    local table="$1"
    local chain="$2"
    shift 2
    if ! iptables ${table:+-t "$table"} -C "$chain" "$@" 2>/dev/null; then
        iptables ${table:+-t "$table"} -I "$chain" "$@"
    fi
}

ensure_rule6() {
    local table="$1"
    local chain="$2"
    shift 2
    if command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables ${table:+-t "$table"} -C "$chain" "$@" 2>/dev/null; then
            ip6tables ${table:+-t "$table"} -I "$chain" "$@"
        fi
    fi
}

delete_rule() {
    local table="$1"
    local chain="$2"
    shift 2
    while iptables ${table:+-t "$table"} -C "$chain" "$@" 2>/dev/null; do
        iptables ${table:+-t "$table"} -D "$chain" "$@" || break
    done
}

delete_rule6() {
    local table="$1"
    local chain="$2"
    shift 2
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables ${table:+-t "$table"} -C "$chain" "$@" 2>/dev/null; do
            ip6tables ${table:+-t "$table"} -D "$chain" "$@" || break
        done
    fi
}

random_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        date +%s%N | md5sum | awk '{print $1}'
    fi
}

random_token() {
    local len="${1:-8}"
    random_uuid | tr -d '-' | cut -c1-"${len}"
}

is_ipv6() {
    [[ "$1" == *:* ]]
}

realip() {
    ip=""
    ip="$(curl -fsS4m8 ip.sb 2>/dev/null || curl -fsS4m8 ifconfig.me 2>/dev/null || curl -fsS4m8 icanhazip.com 2>/dev/null || true)"
    if [[ -z "${ip}" ]]; then
        ip="$(curl -fsS6m8 ip.sb 2>/dev/null || curl -fsS6m8 ifconfig.me 2>/dev/null || curl -fsS6m8 icanhazip.com 2>/dev/null || true)"
    fi
    [[ -z "${ip}" ]] && red "无法获取本机公网 IP，请检查服务器网络。" && exit 1
}

is_port_in_use_udp() {
    local port="$1"
    ss -lunH 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)\[?[^]]*\]?:${port}$|:${port}$"
}

is_port_in_use_tcp() {
    local port="$1"
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)\[?[^]]*\]?:${port}$|:${port}$"
}

set_sysctl_tuning() {
    touch /etc/sysctl.conf

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.rmem_default/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_default/d' /etc/sysctl.conf
    sed -i '/net.ipv4.udp_mem/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_fastopen/d' /etc/sysctl.conf
    sed -i '/net.core.somaxconn/d' /etc/sysctl.conf
    sed -i '/net.ipv4.udp_rmem_min/d' /etc/sysctl.conf
    sed -i '/net.ipv4.udp_wmem_min/d' /etc/sysctl.conf

    {
        echo "net.core.default_qdisc=fq"
        echo "net.ipv4.tcp_congestion_control=bbr"
        echo "net.core.rmem_max=26214400"
        echo "net.core.rmem_default=4194304"
        echo "net.core.wmem_max=26214400"
        echo "net.core.wmem_default=4194304"
        echo "net.ipv4.udp_mem=262144 524288 1048576"
        echo "net.ipv4.udp_rmem_min=8192"
        echo "net.ipv4.udp_wmem_min=8192"
        echo "net.ipv4.tcp_fastopen=3"
        echo "net.core.somaxconn=4096"
    } >> /etc/sysctl.conf

    sysctl -p >/dev/null 2>&1 || true
}

check_env() {
    clear
    yellow "================= 🖥️  系统环境检查 ================="
    green " 当前操作系统: ${SYSTEM}"
    echo ""
    yellow " 正在检查 Hysteria 2 所需前置依赖..."

    local cmds=("curl" "wget" "sudo" "ss" "iptables" "python3" "openssl" "socat")
    local missing=0

    for cmd in "${cmds[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            red " ❌ [缺失] ${cmd}"
            missing=1
        else
            green " ✅ [正常] ${cmd} 已安装"
        fi
    done

    if ! command -v crontab >/dev/null 2>&1; then
        red " ❌ [缺失] crontab"
        missing=1
    else
        green " ✅ [正常] crontab 已安装"
    fi

    if [[ "${SYSTEM}" == "Debian" || "${SYSTEM}" == "Ubuntu" ]]; then
        if ! command -v netfilter-persistent >/dev/null 2>&1; then
            red " ❌ [缺失] netfilter-persistent"
            missing=1
        else
            green " ✅ [正常] netfilter-persistent 已安装"
        fi
    fi

    if [[ "${missing}" -eq 1 ]]; then
        echo ""
        yellow "--------------------------------------------------"
        yellow " ⏳ 正在自动安装缺失依赖..."

        [[ "${SYSTEM}" != "CentOS" ]] && pkg_update

        if [[ "${SYSTEM}" == "Alpine" ]]; then
            pkg_install curl wget sudo procps iptables ip6tables iproute2 python3 openssl socat cronie
            svc_start crond
            svc_enable crond
        elif [[ "${SYSTEM}" == "CentOS" || "${SYSTEM}" == "Fedora" ]]; then
            pkg_install curl wget sudo procps-ng iptables iptables-services iproute python3 openssl socat cronie
            svc_start crond
            svc_enable crond
        else
            export DEBIAN_FRONTEND=noninteractive
            pkg_install curl wget sudo procps iptables-persistent netfilter-persistent iproute2 python3 openssl socat cron
            svc_start cron
            svc_enable cron
        fi

        green " ✨ 所有依赖安装完成！"
    else
        echo ""
        green "--------------------------------------------------"
        green " 🎉 所有依赖检查通过！"
    fi

    set_sysctl_tuning

    yellow "=================================================="
    echo ""
    sleep 2
}

inst_profile() {
    echo ""
    green "================ 安装策略选择 ================"
    echo -e " ${GREEN}1.${PLAIN} 低延迟优先 ${YELLOW}(推荐)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 抗封锁优先"
    echo ""
    read -rp "请输入选项 [1-2，默认 1]: " install_profile
    install_profile="${install_profile:-1}"

    case "${install_profile}" in
        2)
            profile_name="抗封锁优先"
            default_enable_obfs="y"
            default_enable_masq="y"
            ;;
        *)
            profile_name="低延迟优先"
            default_enable_obfs="n"
            default_enable_masq="n"
            ;;
    esac

    green "已选择：${profile_name}"
}

inst_cert() {
    green "Hysteria 2 协议证书申请方式如下："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 自签证书 ${YELLOW}（默认）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} Acme 脚本申请 ${YELLOW}(Cloudflare DNS API 验证)${PLAIN}"
    echo -e " ${GREEN}3.${PLAIN} 自定义证书路径"
    echo ""

    read -rp "请输入选项 [1-3]: " certInput
    certInput="${certInput:-1}"

    if [[ "${certInput}" == "2" ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        chmod a+x /root

        if [[ -s "/root/cert.crt" && -s "/root/private.key" && -s "/root/ca.log" ]]; then
            domain="$(< /root/ca.log)"
            green "检测到原有域名：${domain} 的证书，正在应用"
            hy_domain="${domain}"
            echo "${hy_domain}" > /etc/hysteria/server_name.txt
        else
            realip
            read -rp "请输入需要申请证书的域名: " domain
            [[ -z "${domain}" ]] && red "未输入域名，无法继续！" && exit 1
            green "已输入的域名：${domain}"

            domainIP="$(python3 -c "import socket; print(socket.gethostbyname('${domain}'))" 2>/dev/null || true)"

            if [[ -z "${domainIP}" || "${domainIP}" != "${ip}" ]]; then
                yellow "警告: 当前域名解析 IP (${domainIP:-解析失败}) 与当前 VPS 真实 IP (${ip}) 不匹配。"
                yellow "DNS 验证可成功签发证书，但实际连接仍应指向真实服务器 IP。"
                read -rp "是否继续申请证书？(y/n) [默认 y]: " force_cert
                force_cert="${force_cert:-y}"
                [[ "${force_cert}" != "y" && "${force_cert}" != "Y" ]] && exit 1
            fi

            green "=========================================================="
            yellow "准备使用 Cloudflare DNS API 申请证书"
            green "=========================================================="

            read -rp "请输入 Cloudflare 账号邮箱 (CF_Email): " cf_email
            read -rp "请输入 Cloudflare Global API Key: " cf_key
            [[ -z "${cf_email}" || -z "${cf_key}" ]] && red "邮箱或 API Key 不能为空！" && exit 1

            export CF_Email="${cf_email}"
            export CF_Key="${cf_key}"

            curl -fsSL https://get.acme.sh | sh -s email="${cf_email}"
            bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

            green "正在通过 Cloudflare DNS API 验证域名所有权..."
            bash ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" -k ec-256
            bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /root/private.key --fullchain-file /root/cert.crt --ecc

            if [[ -s "/root/cert.crt" && -s "/root/private.key" ]]; then
                echo "${domain}" > /root/ca.log

                if [[ -f /etc/crontab ]]; then
                    sed -i '/acme\.sh --cron/d' /etc/crontab
                    echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                fi

                chmod 644 /root/cert.crt
                chmod 600 /root/private.key

                green "证书申请成功！"
                hy_domain="${domain}"
                echo "${hy_domain}" > /etc/hysteria/server_name.txt
            else
                red "证书申请失败！请检查 Cloudflare 邮箱/API Key 或查看终端报错。"
                exit 1
            fi
        fi

    elif [[ "${certInput}" == "3" ]]; then
        read -rp "请输入公钥文件 crt 的路径: " cert_path
        read -rp "请输入密钥文件 key 的路径: " key_path
        read -rp "请输入证书域名/SNI: " domain

        [[ ! -s "${cert_path}" ]] && red "公钥文件不存在或为空：${cert_path}" && exit 1
        [[ ! -s "${key_path}" ]] && red "私钥文件不存在或为空：${key_path}" && exit 1
        [[ -z "${domain}" ]] && red "证书域名/SNI 不能为空。" && exit 1

        hy_domain="${domain}"
        echo "${hy_domain}" > /etc/hysteria/server_name.txt

    else
        green "将使用自签证书作为 Hysteria 2 节点证书"
        mkdir -p /etc/hysteria
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"

        read -rp "请输入自签证书使用的域名/SNI [默认 www.bing.com]: " self_domain
        self_domain="${self_domain:-www.bing.com}"

        openssl ecparam -genkey -name prime256v1 -out "${key_path}"
        openssl req -new -x509 -days 3650 -key "${key_path}" -out "${cert_path}" -subj "/CN=${self_domain}"

        chmod 644 "${cert_path}"
        chmod 600 "${key_path}"

        hy_domain="${self_domain}"
        domain="${self_domain}"
        echo "${hy_domain}" > /etc/hysteria/server_name.txt
    fi
}

inst_port() {
    while true; do
        read -rp "设置 Hysteria 2 节点端口 [1-65535]（回车默认 443）: " port
        [[ -z "${port}" ]] && port="443"

        if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            red "端口无效，请输入 1-65535。"
            continue
        fi

        if is_port_in_use_udp "${port}"; then
            red "UDP 端口 ${port} 已被占用，请更换。"
            continue
        fi

        break
    done

    yellow "Hysteria 2 节点端口：${port}"

    ensure_rule "" INPUT -p udp --dport "${port}" -j ACCEPT
    ensure_rule6 "" INPUT -p udp --dport "${port}" -j ACCEPT
    save_iptables

    inst_jump
}

inst_jump() {
    green "Hysteria 2 端口模式："
    echo -e " ${GREEN}1.${PLAIN} 单端口 ${YELLOW}(默认，低延迟推荐)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 端口跳跃 ${YELLOW}(仅在封锁严重时使用)${PLAIN}"
    read -rp "请输入选项 [1-2，默认 1]: " jumpInput
    jumpInput="${jumpInput:-1}"

    unset firstport endport

    if [[ "${jumpInput}" == "2" ]]; then
        while true; do
            read -rp "起始端口 (建议 10000-65535): " firstport
            read -rp "末尾端口 (必须大于起始端口): " endport

            if ! [[ "${firstport}" =~ ^[0-9]+$ && "${endport}" =~ ^[0-9]+$ ]]; then
                red "端口必须为数字。"
                continue
            fi

            if (( firstport < 1 || endport > 65535 || firstport >= endport )); then
                red "端口范围不合法。"
                continue
            fi

            break
        done

        ensure_rule "nat" PREROUTING -p udp --dport "${firstport}:${endport}" -j DNAT --to-destination ":${port}"
        ensure_rule6 "nat" PREROUTING -p udp --dport "${firstport}:${endport}" -j DNAT --to-destination ":${port}"
        save_iptables
    fi
}

inst_sub_port() {
    while true; do
        read -rp "设置 HTTP 订阅服务端口 [1024-65535]（回车随机）: " sub_port_input
        [[ -z "${sub_port_input}" ]] && sub_port_input="$(shuf -i 10000-30000 -n 1)"

        if ! [[ "${sub_port_input}" =~ ^[0-9]+$ ]]; then
            red "端口必须为数字。"
            continue
        fi

        if (( sub_port_input < 1024 || sub_port_input > 65535 )); then
            yellow "订阅服务仅允许使用 1024-65535，已自动改为高位随机端口。"
            sub_port_input="$(shuf -i 10000-30000 -n 1)"
        fi

        if is_port_in_use_tcp "${sub_port_input}"; then
            red "TCP 端口 ${sub_port_input} 已被占用，请更换。"
            continue
        fi

        break
    done

    yellow "HTTP 订阅服务端口：${sub_port_input}"
}

inst_pwd() {
    read -rp "设置 Hysteria 2 密码（回车随机）: " auth_pwd
    [[ -z "${auth_pwd}" ]] && auth_pwd="$(random_token 8)"
    yellow "密码为：${auth_pwd}"
}

inst_node_name() {
    read -rp "请输入节点名称（请勿包含空格）[默认 Hysteria2_Node]: " custom_node_name
    [[ -z "${custom_node_name}" ]] && custom_node_name="Hysteria2_Node"
    custom_node_name="${custom_node_name// /_}"
}

inst_bandwidth_mode() {
    echo ""
    green "================ 带宽 / 拥塞模式 ================"
    echo -e " ${GREEN}1.${PLAIN} 低延迟优先 ${YELLOW}(默认，不写服务端 bandwidth)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 手动设置服务端带宽 ${YELLOW}(仅在你非常了解线路时使用)${PLAIN}"
    echo ""
    read -rp "请输入选项 [1-2，默认 1]: " bw_mode
    bw_mode="${bw_mode:-1}"

    if [[ "${bw_mode}" == "2" ]]; then
        read -rp "请输入 VPS 最大上行带宽 (如 100 mbps, 1 gbps): " bw_up
        read -rp "请输入 VPS 最大下行带宽 (如 100 mbps, 1 gbps): " bw_down
        [[ -z "${bw_up}" || -z "${bw_down}" ]] && red "带宽不能为空。" && exit 1
    else
        bw_up=""
        bw_down=""
    fi
}

inst_obfs() {
    echo ""
    green "================ Salamander 混淆配置 ================"
    if [[ "${default_enable_obfs}" == "y" ]]; then
        read -rp "是否开启 Salamander 混淆？(y/n) [默认 y]: " enable_obfs
        enable_obfs="${enable_obfs:-y}"
    else
        read -rp "是否开启 Salamander 混淆？(y/n) [默认 n]: " enable_obfs
        enable_obfs="${enable_obfs:-n}"
    fi

    if [[ "${enable_obfs}" == "y" || "${enable_obfs}" == "Y" ]]; then
        obfs_pwd="$(random_token 12)"
        yellow "已开启混淆，密码为：${obfs_pwd}"
    else
        obfs_pwd=""
        yellow "已关闭混淆。"
    fi
}

inst_masquerade() {
    echo ""
    green "================ HTTP/3 伪装配置 ================"
    if [[ "${default_enable_masq}" == "y" ]]; then
        read -rp "是否开启 masquerade 伪装？(y/n) [默认 y]: " enable_masq
        enable_masq="${enable_masq:-y}"
    else
        read -rp "是否开启 masquerade 伪装？(y/n) [默认 n]: " enable_masq
        enable_masq="${enable_masq:-n}"
    fi

    if [[ "${enable_masq}" == "y" || "${enable_masq}" == "Y" ]]; then
        read -rp "请输入伪装网站地址（去除 https://）[默认 www.bing.com]: " proxysite
        [[ -z "${proxysite}" ]] && proxysite="www.bing.com"
        yellow "已开启 masquerade 伪装：${proxysite}"
    else
        proxysite=""
        yellow "已关闭 masquerade 伪装。"
    fi
}

write_server_config() {
    cat > /etc/hysteria/config.yaml <<EOF
listen: :${port}

tls:
  cert: ${cert_path}
  key: ${key_path}

auth:
  type: password
  password: ${auth_pwd}
EOF

    if [[ -n "${bw_up:-}" && -n "${bw_down:-}" ]]; then
        cat >> /etc/hysteria/config.yaml <<EOF

bandwidth:
  up: ${bw_up}
  down: ${bw_down}
EOF
    fi

    if [[ -n "${obfs_pwd:-}" ]]; then
        cat >> /etc/hysteria/config.yaml <<EOF

obfs:
  type: salamander
  salamander:
    password: "${obfs_pwd}"
EOF
    fi

    if [[ -n "${proxysite:-}" ]]; then
        cat >> /etc/hysteria/config.yaml <<EOF

masquerade:
  type: proxy
  proxy:
    url: https://${proxysite}
    rewriteHost: true
EOF
    fi

    cat >> /etc/hysteria/config.yaml <<EOF

trafficStats:
  listen: 127.0.0.1:9999
EOF
}

write_client_hint() {
    if [[ -n "${firstport:-}" ]]; then
        last_port="${port},${firstport}-${endport}"
    else
        last_port="${port}"
    fi

    realip
    if is_ipv6 "${ip}"; then
        last_ip="[${ip}]"
    else
        last_ip="${ip}"
    fi

    cat > /etc/hysteria/hy-client.yaml <<EOF
server: ${last_ip}:${last_port}
auth: ${auth_pwd}
tls:
  sni: ${hy_domain}
  insecure: true
EOF
}

generate_client_configs() {
    realip

    local s_pwd
    s_pwd="$(awk '/password:/{print $2; exit}' /etc/hysteria/config.yaml 2>/dev/null || true)"

    local c_domain
    c_domain="$(awk '/sni:/{print $2; exit}' /etc/hysteria/hy-client.yaml 2>/dev/null || true)"
    if [[ -z "${c_domain}" && -s /etc/hysteria/server_name.txt ]]; then
        c_domain="$(< /etc/hysteria/server_name.txt)"
    fi
    [[ -z "${c_domain}" ]] && c_domain="www.bing.com"

    local c_server
    c_server="$(awk '/^server:/{print $2; exit}' /etc/hysteria/hy-client.yaml 2>/dev/null || true)"
    local c_ports="${c_server##*:}"
    local primary_port
    primary_port="$(echo "${c_ports}" | cut -d',' -f1)"
    local hop_ports=""
    [[ "${c_ports}" == *,* ]] && hop_ports="$(echo "${c_ports}" | cut -d',' -f2-)"

    local s_obfs_pwd
    s_obfs_pwd="$(awk '/obfs:/{flag=1} flag && /password:/{print $2; flag=0}' /etc/hysteria/config.yaml 2>/dev/null | tr -d '"' | tr -d "'" || true)"

    local obfs_param=""
    local clash_obfs_block=""
    if [[ -n "${s_obfs_pwd}" ]]; then
        obfs_param="&obfs=salamander&obfs-password=${s_obfs_pwd}"
        clash_obfs_block=$'    obfs: salamander\n    obfs-password: "'"${s_obfs_pwd}"'"'
    fi

    local yaml_json_ip="${ip}"
    local uri_ip="${ip}"
    if is_ipv6 "${ip}"; then
        uri_ip="[${ip}]"
    fi

    local mport_param=""
    [[ -n "${hop_ports}" ]] && mport_param="&mport=${hop_ports}"

    local web_dir="/var/www/hysteria"
    mkdir -p "${web_dir}"
    echo "<h1 style='text-align:center;margin-top:20%;'>403 Forbidden</h1>" > "${web_dir}/index.html"

    local sub_uuid
    sub_uuid="$(random_uuid)"
    mkdir -p "${web_dir}/${sub_uuid}"
    echo "<h1 style='text-align:center;margin-top:20%;'>403 Forbidden</h1>" > "${web_dir}/${sub_uuid}/index.html"
    echo "${sub_uuid}" > /etc/hysteria/sub_path.txt

    local url="hysteria2://${s_pwd}@${uri_ip}:${primary_port}/?insecure=1&sni=${c_domain}${mport_param}${obfs_param}#${custom_node_name}"
    echo "${url}" > "${web_dir}/${sub_uuid}/url.txt"
    printf '%s' "${url}" | base64 | tr -d '\r\n' > "${web_dir}/${sub_uuid}/sub_b64.txt"

    cat > "${web_dir}/${sub_uuid}/clash-meta-sub.yaml" <<EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: true

proxies:
  - name: '${custom_node_name}'
    type: hysteria2
    server: "${yaml_json_ip}"
    port: ${primary_port}
$( [[ -n "${hop_ports}" ]] && echo "    ports: '${hop_ports}'" )
    password: "${s_pwd}"
    sni: "${c_domain}"
    skip-cert-verify: true
    alpn:
      - h3
${clash_obfs_block}

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

    local sub_port="${sub_port_input}"
    echo "${sub_port}" > /etc/hysteria/sub_port.txt

    chown -R nobody:nobody "${web_dir}" 2>/dev/null || chown -R nobody "${web_dir}" || true

    ensure_rule "" INPUT -p tcp --dport "${sub_port}" -j ACCEPT
    save_iptables

    local py_path
    py_path="$(command -v python3)"

    if [[ "${SYSTEM}" == "Alpine" ]]; then
        cat > /etc/init.d/hysteria-sub <<EOF
#!/sbin/openrc-run
description="Hysteria HTTP Subscription Server"
command="${py_path}"
command_args="-m http.server ${sub_port} --directory ${web_dir}"
command_background=true
command_user="nobody"
directory="${web_dir}"
pidfile="/run/hysteria-sub.pid"
EOF
        chmod +x /etc/init.d/hysteria-sub
        rc-update add hysteria-sub default || true
    else
        cat > /etc/systemd/system/hysteria-sub.service <<EOF
[Unit]
Description=Hysteria HTTP Subscription Server
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=${web_dir}
ExecStart=${py_path} -m http.server ${sub_port} --directory ${web_dir}
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable hysteria-sub >/dev/null 2>&1 || true
    fi

    svc_stop hysteria-sub
    svc_start hysteria-sub

    green "HTTP 订阅服务已启动。"
}

showconf() {
    realip

    local sub_port=""
    local sub_path=""
    sub_port="$(< /etc/hysteria/sub_port.txt 2>/dev/null || true)"
    sub_path="$(< /etc/hysteria/sub_path.txt 2>/dev/null || true)"
    local web_dir="/var/www/hysteria"

    yellow "================ Hysteria 2 全平台订阅链接 ================"
    green "🎯 1. Clash Meta 专属配置订阅链接："
    red "http://${ip}:${sub_port}/${sub_path}/clash-meta-sub.yaml"
    echo ""
    green "🔗 2. 通用 Base64 订阅链接："
    red "http://${ip}:${sub_port}/${sub_path}/sub_b64.txt"
    echo ""
    green "📄 3. 原始 Hysteria 2 协议单节点："
    red "$(cat "${web_dir}/${sub_path}/url.txt" 2>/dev/null || true)"
    echo ""
    yellow "==========================================================="
    yellow "提示 1: 为降低误配导致的延迟，Clash 默认未写 up/down。"
    yellow "提示 2: 若你非常了解真实链路带宽，再手动填写 up/down。"
    echo ""
    read -rp "按回车键返回主菜单..."
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

    read -rp "是否需要修改配置文件？(y/n) [默认 n]: " edit_choice
    edit_choice="${edit_choice:-n}"

    if [[ "${edit_choice}" == "y" || "${edit_choice}" == "Y" ]]; then
        if command -v nano >/dev/null 2>&1; then
            nano /etc/hysteria/config.yaml
        elif command -v vi >/dev/null 2>&1; then
            vi /etc/hysteria/config.yaml
        else
            red "未找到 nano 或 vi，请手动修改 /etc/hysteria/config.yaml"
        fi

        green "配置修改完成，正在重启 Hysteria 2 服务..."
        svc_restart hysteria-server
        green "重启成功！"
    fi

    echo ""
    read -rp "按回车键返回主菜单..."
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
        green "正在自动开启流量统计 API..."
        cat >> /etc/hysteria/config.yaml <<EOF

trafficStats:
  listen: 127.0.0.1:9999
EOF
        svc_restart hysteria-server
        sleep 2
    fi

    local traffic_data=""
    traffic_data="$(curl -fsS http://127.0.0.1:9999/traffic 2>/dev/null || true)"

    if [[ -z "${traffic_data}" ]]; then
        red "获取流量数据失败，请检查 Hysteria 服务状态。"
    elif [[ "${traffic_data}" != *'"tx"'* ]]; then
        echo ""
        green "================ 🚀 客户端连接与流量统计 =================="
        yellow "当前节点没有流量记录。"
        green "========================================================"
    else
        echo ""
        green "================ 🚀 客户端连接与流量统计 =================="

        local client_count
        client_count="$(echo "${traffic_data}" | grep -o '"[^"]*":[[:space:]]*{[^}]*}' | grep -c '"tx"' || true)"
        yellow "活跃客户端总数: ${client_count}"
        echo "--------------------------------------------------------"

        echo "${traffic_data}" | grep -o '"[^"]*":[[:space:]]*{[^}]*}' | grep '"tx"' | while read -r line; do
            local user tx rx tx_mb rx_mb
            user="$(echo "${line}" | cut -d '"' -f2)"
            tx="$(echo "${line}" | grep -o '"tx":[0-9]*' | cut -d: -f2 || true)"
            rx="$(echo "${line}" | grep -o '"rx":[0-9]*' | cut -d: -f2 || true)"

            [[ -z "${tx}" ]] && tx=0
            [[ -z "${rx}" ]] && rx=0

            tx_mb="$(awk "BEGIN {printf \"%.2f\", ${tx}/1048576}")"
            rx_mb="$(awk "BEGIN {printf \"%.2f\", ${rx}/1048576}")"

            echo -e "  👥 客户端账号: ${GREEN}${user}${PLAIN} \t| ⬆️ 发送: ${YELLOW}${tx_mb} MB${PLAIN} \t| ⬇️ 接收: ${YELLOW}${rx_mb} MB${PLAIN}"
        done

        green "========================================================"
    fi

    echo ""
    read -rp "按回车键返回主菜单..."
    menu
}

install_hysteria_core() {
    green "正在从 Apernet 官方仓库下载 Hysteria 2 核心..."
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64) hy_arch="amd64" ;;
        aarch64|arm64) hy_arch="arm64" ;;
        s390x) hy_arch="s390x" ;;
        *)
            red "不支持的架构: ${arch}"
            exit 1
            ;;
    esac

    hy_ver="$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | cut -d '"' -f4 || true)"
    [[ -z "${hy_ver}" ]] && hy_ver="app/v2.4.0"

    wget -qO /usr/local/bin/hysteria "https://github.com/apernet/hysteria/releases/download/${hy_ver}/hysteria-linux-${hy_arch}"
    chmod +x /usr/local/bin/hysteria
}

write_service() {
    if [[ "${SYSTEM}" == "Alpine" ]]; then
        cat > /etc/init.d/hysteria-server <<'EOF'
#!/sbin/openrc-run
description="Hysteria 2 Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria-server.pid"
EOF
        chmod +x /etc/init.d/hysteria-server
    else
        cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

insthysteria() {
    check_env
    mkdir -p /etc/hysteria

    inst_profile
    install_hysteria_core
    write_service

    inst_cert
    inst_port
    inst_sub_port
    inst_pwd
    inst_node_name
    inst_bandwidth_mode
    inst_obfs
    inst_masquerade

    write_server_config
    write_client_hint

    svc_enable hysteria-server
    svc_start hysteria-server

    generate_client_configs

    red "======================================================================"
    green "Hysteria 2 代理及 HTTP 订阅服务安装完成"
    yellow "当前策略：${profile_name}"
    yellow "低延迟建议：默认不要开 obfs，不要开 masquerade，不要乱填 up/down。"
    green "请在主菜单选择 [4] 查看订阅链接。"
    sleep 3
    menu
}

unsthysteria() {
    local main_port=""
    local sub_port=""
    main_port="$(awk -F ':' '/^listen:/{gsub(/ /,"",$NF); print $NF}' /etc/hysteria/config.yaml 2>/dev/null || true)"
    sub_port="$(cat /etc/hysteria/sub_port.txt 2>/dev/null || true)"

    if [[ -n "${main_port}" ]]; then
        delete_rule "" INPUT -p udp --dport "${main_port}" -j ACCEPT
        delete_rule6 "" INPUT -p udp --dport "${main_port}" -j ACCEPT
    fi

    if [[ -n "${sub_port}" ]]; then
        delete_rule "" INPUT -p tcp --dport "${sub_port}" -j ACCEPT
    fi

    if [[ -f /etc/hysteria/config.yaml ]]; then
        if grep -q 'DNAT --to-destination' <(iptables -t nat -S PREROUTING 2>/dev/null || true); then
            yellow "提示：如启用了端口跳跃，可手动检查并清理 PREROUTING NAT 规则。"
        fi
    fi

    svc_stop hysteria-server
    svc_disable hysteria-server
    svc_stop hysteria-sub
    svc_disable hysteria-sub

    if [[ "${SYSTEM}" == "Alpine" ]]; then
        rm -f /etc/init.d/hysteria-server /etc/init.d/hysteria-sub
    else
        rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-sub.service
        systemctl daemon-reload || true
    fi

    save_iptables

    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -rf /var/www/hysteria

    green "Hysteria 2 服务及相关文件已卸载完成！"
    sleep 2
    exit 0
}

starthysteria() {
    svc_start hysteria-server
    svc_start hysteria-sub
    green "Hysteria 2 及订阅服务已启动！"
    sleep 2
    menu
}

stophysteria_only() {
    svc_stop hysteria-server
    svc_stop hysteria-sub
    green "Hysteria 2 及订阅服务已关闭！"
    sleep 2
    menu
}

restarthysteria() {
    svc_restart hysteria-server
    svc_restart hysteria-sub
    green "Hysteria 2 及订阅服务已重启！"
    sleep 2
    menu
}

hysteriaswitch() {
    clear
    echo "================ 服务管理 ================"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "0. 返回主菜单"
    echo ""
    read -rp "请输入选项 [0-3]: " switchInput
    case "${switchInput}" in
        1) starthysteria ;;
        2) stophysteria_only ;;
        3) restarthysteria ;;
        0) menu ;;
        *) menu ;;
    esac
}

enable_bbr() {
    modprobe tcp_bbr || true
    set_sysctl_tuning
    green "BBR 及 UDP 缓冲优化已开启！"
    read -rp "按回车键返回主菜单..."
    menu
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#     ${GREEN}Hysteria 2 一键安装脚本（低延迟稳定增强版）${PLAIN}       #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ${GREEN}安装 Hysteria 2${PLAIN}"
    echo -e " ${RED}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 3. 关闭、开启、重启服务"
    echo -e " 4. 显示 Hysteria 2 订阅链接"
    echo -e " ${YELLOW}5.${PLAIN} 开启 BBR 及 UDP 缓冲优化"
    echo -e " ${GREEN}6.${PLAIN} 查看客户端连接及流量统计"
    echo -e " ${YELLOW}7.${PLAIN} 查看并修改 Hysteria 2 配置"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-7]: " menuInput
    case "${menuInput}" in
        1) insthysteria ;;
        2) unsthysteria ;;
        3) hysteriaswitch ;;
        4) showconf ;;
        5) enable_bbr ;;
        6) check_traffic ;;
        7) edit_config ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

menu
