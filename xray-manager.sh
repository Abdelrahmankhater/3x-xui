#!/usr/bin/env bash
# ==============================================================================
# Enterprise Xray, SSH & Multi-Protocol VPN/Proxy Management Suite
# Target OS: Ubuntu 24.04 LTS (Noble Numbat)
# Author: Principal Linux Systems Engineer & Network Security Architect
# ==============================================================================

# Strict error traps where safe
set -o pipefail

# ------------------------------------------------------------------------------
# Global Constants & Paths
# ------------------------------------------------------------------------------
APP_NAME="Xray & SSH Multi-Protocol Suite"
APP_VERSION="3.5.0-LTS"
SCRIPT_PATH="$(readlink -f "$0")"

BASE_DIR="/etc/xray-manager"
DB_FILE="${BASE_DIR}/users.json"
CONFIG_ENV="${BASE_DIR}/config.env"
SSL_DIR="${BASE_DIR}/ssl"
BACKUP_DIR="${BASE_DIR}/backups"

XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONF_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"

NGINX_CONF_AVAILABLE="/etc/nginx/sites-available/xray-manager.conf"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/xray-manager.conf"
WEB_ROOT="/var/www/html"

BADVPN_BIN="/usr/local/bin/badvpn-udpgw"
BADVPN_SERVICE="/etc/systemd/system/badvpn-udpgw.service"

CRON_JOB="/etc/cron.hourly/xray-user-checker"

# Default Internal Proxy Ports
PORT_VMESS_WS=10001
PORT_VLESS_WS=10002
PORT_TROJAN_WS=10003
PORT_SSH_WS=10004
PORT_XRAY_API=10085

# External Ports
PORT_TROJAN_DIRECT=442
PORT_SHADOWSOCKS=8388
PORT_BADVPN_UDP=7300

# ------------------------------------------------------------------------------
# Terminal Styling & Colors
# ------------------------------------------------------------------------------
setup_colors() {
    if [[ -t 1 ]]; then
        C_RESET='\033[0m'
        C_BOLD='\033[1m'
        C_DIM='\033[2m'
        C_RED='\033[0;31m'
        C_GREEN='\033[0;32m'
        C_YELLOW='\033[0;33m'
        C_BLUE='\033[0;34m'
        C_MAGENTA='\033[0;35m'
        C_CYAN='\033[0;36m'
        C_WHITE='\033[0;37m'
        C_B_GREEN='\033[1;32m'
        C_B_CYAN='\033[1;36m'
        C_B_YELLOW='\033[1;33m'
        C_B_RED='\033[1;31m'
    else
        C_RESET=''
        C_BOLD=''
        C_DIM=''
        C_RED=''
        C_GREEN=''
        C_YELLOW=''
        C_BLUE=''
        C_MAGENTA=''
        C_CYAN=''
        C_WHITE=''
        C_B_GREEN=''
        C_B_CYAN=''
        C_B_YELLOW=''
        C_B_RED=''
    fi
}
setup_colors

log_info()    { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $*"; }
log_warning() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $*"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_fatal()   { echo -e "${C_B_RED}[FATAL]${C_RESET} $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Pre-flight Environment Checks
# ------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This management script must be executed as root (sudo)."
    fi
}

check_system_compatibility() {
    if [[ ! -f /etc/os-release ]]; then
        log_fatal "Unsupported operating system: /etc/os-release was not found."
    fi

    # Source OS information
    . /etc/os-release

    if [[ "$ID" != "ubuntu" && "$ID_LIKE" != *"ubuntu"* && "$ID_LIKE" != *"debian"* ]]; then
        log_warning "This script is tailored specifically for Ubuntu 24.04 LTS (Noble Numbat)."
        log_warning "Current OS: ${PRETTY_NAME:-$ID}. Some system packages or systemd paths may differ."
        read -rp "Do you wish to proceed anyway? [y/N]: " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || exit 1
    fi

    # Detect Architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)   XRAY_ARCH="64" ;;
        aarch64|arm64)  XRAY_ARCH="arm64-v8a" ;;
        armv7l|armhf)   XRAY_ARCH="arm32-v7a" ;;
        *)              log_fatal "Unsupported CPU architecture: $ARCH" ;;
    esac
}

get_public_ip() {
    local ip
    ip=$(curl -s4 --max-time 3 https://api.ipify.org || \
         curl -s4 --max-time 3 https://icanhazip.com || \
         curl -s4 --max-time 3 https://ifconfig.me || \
         ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    echo "${ip:-127.0.0.1}"
}

# ------------------------------------------------------------------------------
# Environment & Configuration Storage
# ------------------------------------------------------------------------------
init_directories() {
    mkdir -p "${BASE_DIR}" "${SSL_DIR}" "${BACKUP_DIR}" "${WEB_ROOT}" \
             "${XRAY_CONF_DIR}" "/var/log/xray" "/etc/nginx/sites-available" "/etc/nginx/sites-enabled"
    chmod 700 "${BASE_DIR}"
    chmod 750 "${SSL_DIR}"
    chmod -R 755 "${WEB_ROOT}"

    # Initialize users database if not present
    if [[ ! -f "$DB_FILE" ]]; then
        echo "[]" > "$DB_FILE"
        chmod 600 "$DB_FILE"
    fi

    # Initialize environment configuration if not present
    if [[ ! -f "$CONFIG_ENV" ]]; then
        local detected_ip
        detected_ip=$(get_public_ip)
        cat <<EOF > "$CONFIG_ENV"
SERVER_IP="${detected_ip}"
SERVER_DOMAIN="${detected_ip}.nip.io"
SSL_MODE="self-signed"
SSH_PORT="22"
BADVPN_PORT="${PORT_BADVPN_UDP}"
VMESS_PORT="10001"
VLESS_PORT="10002"
TROJAN_PORT="10003"
SSH_WS_PORT="10004"
TROJAN_DIRECT_PORT="${PORT_TROJAN_DIRECT}"
SHADOWSOCKS_PORT="${PORT_SHADOWSOCKS}"
EOF
        chmod 600 "$CONFIG_ENV"
    fi

    # Load configuration
    # shellcheck disable=SC1090
    source "$CONFIG_ENV"
}

save_config_env() {
    cat <<EOF > "$CONFIG_ENV"
SERVER_IP="${SERVER_IP}"
SERVER_DOMAIN="${SERVER_DOMAIN}"
SSL_MODE="${SSL_MODE}"
SSH_PORT="${SSH_PORT:-22}"
BADVPN_PORT="${PORT_BADVPN_UDP}"
VMESS_PORT="${PORT_VMESS_WS}"
VLESS_PORT="${PORT_VLESS_WS}"
TROJAN_PORT="${PORT_TROJAN_WS}"
SSH_WS_PORT="${PORT_SSH_WS}"
TROJAN_DIRECT_PORT="${PORT_TROJAN_DIRECT}"
SHADOWSOCKS_PORT="${PORT_SHADOWSOCKS}"
EOF
    chmod 600 "$CONFIG_ENV"
}

# ------------------------------------------------------------------------------
# System Dependencies & Package Management
# ------------------------------------------------------------------------------
install_dependencies() {
    log_info "Updating APT repositories and installing critical system dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || log_fatal "Failed to update apt packages."
    
    local pkgs=(
        curl wget jq qrencode openssl git cmake build-essential
        ufw cron certbot nginx lsof net-tools iproute2 tar
        uuid-runtime bc libssl-dev zlib1g-dev ca-certificates
        socat iptables iptables-persistent
    )

    apt-get install -y "${pkgs[@]}" || log_fatal "Failed to install required system packages."
    log_success "Base dependencies successfully installed."
}

# ------------------------------------------------------------------------------
# Kernel Tuning: BBR Congestion Control & High-Concurrency Limits
# ------------------------------------------------------------------------------
optimize_kernel_bbr() {
    log_info "Applying Linux kernel optimizations and enabling BBR Congestion Control..."

    # Enable BBR module persistently
    if ! grep -q "^tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi
    modprobe tcp_bbr 2>/dev/null || true

    # Write sysctl tuning configuration
    cat <<EOF > /etc/sysctl.d/99-vps-tuning.conf
# File Descriptor & Queue Limits
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# IP Forwarding for Tunneling / VPN
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# TCP Memory & Buffer Tuning
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-vps-tuning.conf >/dev/null 2>&1

    # Apply limits for high concurrency
    cat <<EOF > /etc/security/limits.d/99-vps-limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 524288
* hard nproc 524288
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 524288
root hard nproc 524288
EOF

    # Configure systemd limits
    if ! grep -q "^DefaultLimitNOFILE=1048576" /etc/systemd/system.conf 2>/dev/null; then
        echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
        echo "DefaultLimitNPROC=524288" >> /etc/systemd/system.conf
    fi

    log_success "BBR congestion control and high-concurrency limits activated."
}

# ------------------------------------------------------------------------------
# BadVPN UDP Gateway (Port 7300 for SSH Gaming / VoIP)
# ------------------------------------------------------------------------------
install_badvpn() {
    log_info "Setting up BadVPN UDP Gateway on Port ${PORT_BADVPN_UDP}..."

    if [[ ! -x "$BADVPN_BIN" ]]; then
        log_info "Compiling BadVPN UDP Gateway from source for Ubuntu 24.04..."
        rm -rf /tmp/badvpn-build
        mkdir -p /tmp/badvpn-build
        if git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn-build/badvpn; then
            mkdir -p /tmp/badvpn-build/badvpn/build
            cd /tmp/badvpn-build/badvpn/build || log_fatal "Failed to access badvpn build directory"
            cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1
            make install -j"$(nproc)" >/dev/null 2>&1
            cd /
            rm -rf /tmp/badvpn-build
        fi

        # Binary fallback if build environment is minimal
        if [[ ! -x "$BADVPN_BIN" ]]; then
            log_warning "CMake compilation was skipped or unavailable."
        fi
    fi

    if [[ ! -x "$BADVPN_BIN" ]]; then
        log_error "BadVPN binary could not be prepared. Skipping badvpn service setup."
        return 1
    fi

    cat <<EOF > "$BADVPN_SERVICE"
[Unit]
Description=BadVPN UDP Gateway Daemon for SSH Gaming Port ${PORT_BADVPN_UDP}
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BADVPN_BIN} --listen-addr 0.0.0.0:${PORT_BADVPN_UDP} --max-clients 1024 --max-connections-for-client 512
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable badvpn-udpgw.service >/dev/null 2>&1
    systemctl restart badvpn-udpgw.service >/dev/null 2>&1
    log_success "BadVPN UDP Gateway running on 0.0.0.0:${PORT_BADVPN_UDP}."
}

# ------------------------------------------------------------------------------
# OpenSSH Hardening & WebSocket Forwarding Support
# ------------------------------------------------------------------------------
configure_openssh() {
    log_info "Configuring OpenSSH parameters for tunneling..."

    mkdir -p /etc/ssh/sshd_config.d
    cat <<EOF > /etc/ssh/sshd_config.d/50-xray-manager.conf
# Managed by Xray Manager
PasswordAuthentication yes
PermitRootLogin yes
ClientAliveInterval 60
ClientAliveCountMax 3
TCPKeepAlive yes
AllowTcpForwarding yes
GatewayPorts yes
EOF

    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true
    log_success "OpenSSH configured and reloaded."
}

# ------------------------------------------------------------------------------
# Xray-Core Installation & Systemd Service
# ------------------------------------------------------------------------------
install_xray_core() {
    log_info "Installing / Updating Xray-Core..."
    
    # Official XTLS script execution with non-interactive flag
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1; then
        log_success "Xray-core successfully installed via official installer."
    else
        log_warning "Official installer failed. Downloading Xray binary directly from GitHub releases..."
        local tmp_dir="/tmp/xray-install"
        mkdir -p "$tmp_dir"
        local latest_tag
        latest_tag=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r .tag_name)
        [[ -z "$latest_tag" || "$latest_tag" == "null" ]] && latest_tag="v1.8.24"
        
        local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${XRAY_ARCH}.zip"
        wget -qO "${tmp_dir}/xray.zip" "$download_url" || log_fatal "Failed to download Xray release."
        unzip -qo "${tmp_dir}/xray.zip" -d "$tmp_dir"
        install -m 755 "${tmp_dir}/xray" /usr/local/bin/xray
        mkdir -p /usr/local/share/xray
        cp -f "${tmp_dir}/geoip.dat" "${tmp_dir}/geosite.dat" /usr/local/share/xray/ 2>/dev/null || true
        rm -rf "$tmp_dir"
    fi

    # Ensure systemd service exists and is configured
    cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Multi-Protocol Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    # Symlink config directory to /etc/xray for admin convenience
    mkdir -p /usr/local/etc/xray
    ln -sfn /usr/local/etc/xray /etc/xray

    systemctl daemon-reload
    log_success "Xray-Core installed: $(/usr/local/bin/xray version 2>/dev/null | head -n1)"
}

# ------------------------------------------------------------------------------
# SSL Certificate Management (Let's Encrypt / ZeroSSL with Self-Signed Fallback)
# ------------------------------------------------------------------------------
generate_self_signed_cert() {
    local domain="${1:-$SERVER_DOMAIN}"
    log_info "Generating 2048-bit RSA / ECC self-signed TLS certificate for ${domain}..."
    mkdir -p "${SSL_DIR}"
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${SSL_DIR}/privkey.pem" \
        -out "${SSL_DIR}/fullchain.pem" \
        -days 3650 \
        -subj "/CN=${domain}/O=Enterprise Gateway/C=US" >/dev/null 2>&1
    chmod 600 "${SSL_DIR}/privkey.pem"
    chmod 644 "${SSL_DIR}/fullchain.pem"
    log_success "Self-signed certificate generated at ${SSL_DIR}."
}

issue_letsencrypt_cert() {
    local domain="$1"
    local email="$2"

    log_info "Requesting genuine Let's Encrypt SSL certificate for: ${domain}..."

    # Ensure Nginx is temporarily running or webroot is available
    mkdir -p "${WEB_ROOT}/.well-known/acme-challenge"
    chmod -R 755 "${WEB_ROOT}"

    # Verify domain resolves to this server
    local resolved_ip
    resolved_ip=$(dig +short "$domain" @1.1.1.1 2>/dev/null | tail -n1)
    if [[ -z "$resolved_ip" ]]; then
        resolved_ip=$(ping -c 1 "$domain" 2>/dev/null | awk -F '[()]' '/PING/{print $2}')
    fi

    if [[ "$resolved_ip" != "$SERVER_IP" ]]; then
        log_warning "Domain DNS record ($resolved_ip) does not match Public IP ($SERVER_IP)."
        log_warning "Let's Encrypt validation may fail. Ensure Cloudflare proxy (orange cloud) is set to DNS-Only during issuance."
        read -rp "Attempt issuance anyway? [y/N]: " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || return 1
    fi

    # Issue using certbot webroot
    certbot certonly --webroot -w "${WEB_ROOT}" \
        -d "${domain}" \
        --email "${email}" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --keep-until-expiring

    local le_path="/etc/letsencrypt/live/${domain}"
    if [[ -f "${le_path}/fullchain.pem" && -f "${le_path}/privkey.pem" ]]; then
        cp -f "${le_path}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
        cp -f "${le_path}/privkey.pem" "${SSL_DIR}/privkey.pem"
        chmod 644 "${SSL_DIR}/fullchain.pem"
        chmod 600 "${SSL_DIR}/privkey.pem"
        
        SERVER_DOMAIN="$domain"
        SSL_MODE="letsencrypt"
        save_config_env

        # Setup automated renewal hook
        cat <<EOF > /etc/letsencrypt/renewal-hooks/deploy/xray-reload.sh
#!/bin/sh
cp -f /etc/letsencrypt/live/${domain}/fullchain.pem ${SSL_DIR}/fullchain.pem
cp -f /etc/letsencrypt/live/${domain}/privkey.pem ${SSL_DIR}/privkey.pem
systemctl reload nginx
systemctl restart xray
EOF
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/xray-reload.sh

        log_success "Let's Encrypt SSL issued and linked successfully!"
        return 0
    else
        log_error "Certbot issuance failed. Falling back to self-signed certificate."
        generate_self_signed_cert "$domain"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Decoy Webpage Installation (Anti-Censorship Cloaking)
# ------------------------------------------------------------------------------
deploy_decoy_website() {
    log_info "Deploying anti-probing decoy website template to ${WEB_ROOT}..."
    cat <<'EOF' > "${WEB_ROOT}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CloudCore Networks - Global Edge Infrastructure</title>
    <style>
        :root { --primary: #0284c7; --bg: #0f172a; --card: #1e293b; --text: #f8fafc; --muted: #94a3b8; }
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        body { background: var(--bg); color: var(--text); line-height: 1.6; padding: 2rem 1rem; }
        .container { max-width: 1000px; margin: 0 auto; }
        header { text-align: center; padding: 3rem 0; border-bottom: 1px solid #334155; }
        h1 { font-size: 2.5rem; color: #38bdf8; margin-bottom: 0.5rem; }
        p.subtitle { font-size: 1.2rem; color: var(--muted); }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1.5rem; margin-top: 3rem; }
        .card { background: var(--card); border: 1px solid #334155; border-radius: 12px; padding: 1.5rem; transition: transform 0.2s; }
        .card:hover { transform: translateY(-4px); }
        .card h3 { color: #7dd3fc; margin-bottom: 0.5rem; }
        .card p { color: var(--muted); font-size: 0.95rem; }
        footer { text-align: center; margin-top: 4rem; color: #64748b; font-size: 0.85rem; border-top: 1px solid #334155; padding-top: 1.5rem; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>CloudCore Edge Node</h1>
            <p class="subtitle">High-throughput content delivery and distributed API endpoint cluster.</p>
        </header>
        <div class="grid">
            <div class="card">
                <h3>Global Anycast Network</h3>
                <p>Sub-millisecond packet steering with adaptive edge caching and route optimization.</p>
            </div>
            <div class="card">
                <h3>TLS 1.3 & HTTP/2 Ingress</h3>
                <p>Zero-latency cryptographic handshake acceleration powered by hardware-assisted engines.</p>
            </div>
            <div class="card">
                <h3>Autonomous Telemetry</h3>
                <p>Continuous synthetic health checks and DDoS layer-7 automated traffic filtering.</p>
            </div>
        </div>
        <footer>
            &copy; 2026 CloudCore Global Infrastructure Systems. All rights reserved. System operational.
        </footer>
    </div>
</body>
</html>
EOF
    chmod 644 "${WEB_ROOT}/index.html"
}

# ------------------------------------------------------------------------------
# Nginx Configuration (Cloudflare HTTP/HTTPS Ports & WebSocket Routing)
# ------------------------------------------------------------------------------
configure_nginx() {
    log_info "Configuring Nginx Reverse Proxy for multi-port ingress & WebSocket routing..."

    # Ensure default conflicting site is removed
    rm -f /etc/nginx/sites-enabled/default

    cat <<EOF > "$NGINX_CONF_AVAILABLE"
# Managed by Xray Manager
# Ingress on all standard & Cloudflare HTTP ports
server {
    listen 80;
    listen [::]:80;
    listen 8080;
    listen 8880;
    listen 2082;
    listen 2086;
    server_name ${SERVER_DOMAIN};

    root ${WEB_ROOT};
    index index.html;

    # ACME Challenge for Automated SSL
    location /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        try_files \$uri =404;
    }

    # VMess Plain WebSocket
    location /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_VMESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # VLESS Plain WebSocket
    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_VLESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # SSH over WebSocket (Plain HTTP CDN Port 80/8080)
    location /ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_SSH_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}

# Ingress for TLS / HTTPS Port 443
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${SERVER_DOMAIN};

    ssl_certificate ${SSL_DIR}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    root ${WEB_ROOT};
    index index.html;

    # VMess TLS WebSocket
    location /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_VMESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # VLESS TLS WebSocket
    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_VLESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Trojan TLS WebSocket
    location /trojan {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_TROJAN_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # SSH over WebSocket (TLS CDN Port 443)
    location /ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_SSH_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    ln -sfn "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED"
    nginx -t >/dev/null 2>&1 || log_fatal "Nginx configuration syntax validation failed."
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    log_success "Nginx proxy configured and active."
}

# ------------------------------------------------------------------------------
# Xray Base Configuration (Multi-Protocol Inbounds & Dokodemo SSH)
# ------------------------------------------------------------------------------
generate_xray_config() {
    log_info "Generating Master Xray Configuration (${XRAY_CONFIG})..."

    # Preserve existing clients from database if available
    local vmess_clients="[]"
    local vless_clients="[]"
    local trojan_clients="[]"
    local ss_clients="[]"

    if [[ -f "$DB_FILE" && -s "$DB_FILE" ]]; then
        vmess_clients=$(jq '[.[] | select(.protocol=="vmess" and .status=="active") | {"id": .uuid, "alterId": 0, "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")
        vless_clients=$(jq '[.[] | select(.protocol=="vless" and .status=="active") | {"id": .uuid, "flow": "", "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")
        trojan_clients=$(jq '[.[] | select(.protocol=="trojan" and .status=="active") | {"password": .uuid, "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")
        ss_clients=$(jq '[.[] | select(.protocol=="shadowsocks" and .status=="active") | {"password": .uuid, "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")
    fi

    cat <<EOF > "$XRAY_CONFIG"
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${PORT_XRAY_API},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    },
    {
      "listen": "127.0.0.1",
      "port": ${PORT_VMESS_WS},
      "protocol": "vmess",
      "settings": {
        "clients": ${vmess_clients}
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess"
        }
      },
      "tag": "vmess-in"
    },
    {
      "listen": "127.0.0.1",
      "port": ${PORT_VLESS_WS},
      "protocol": "vless",
      "settings": {
        "clients": ${vless_clients},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless"
        }
      },
      "tag": "vless-in"
    },
    {
      "listen": "127.0.0.1",
      "port": ${PORT_TROJAN_WS},
      "protocol": "trojan",
      "settings": {
        "clients": ${trojan_clients}
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/trojan"
        }
      },
      "tag": "trojan-ws-in"
    },
    {
      "listen": "127.0.0.1",
      "port": ${PORT_SSH_WS},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1",
        "port": 22,
        "network": "tcp"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/ssh"
        }
      },
      "tag": "ssh-ws-in"
    },
    {
      "listen": "0.0.0.0",
      "port": ${PORT_TROJAN_DIRECT},
      "protocol": "trojan",
      "settings": {
        "clients": ${trojan_clients}
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${SSL_DIR}/fullchain.pem",
              "keyFile": "${SSL_DIR}/privkey.pem"
            }
          ]
        }
      },
      "tag": "trojan-direct-in"
    },
    {
      "listen": "0.0.0.0",
      "port": ${PORT_SHADOWSOCKS},
      "protocol": "shadowsocks",
      "settings": {
        "method": "aes-256-gcm",
        "clients": ${ss_clients},
        "network": "tcp,udp"
      },
      "tag": "ss-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

    # Validate JSON syntax
    jq . "$XRAY_CONFIG" >/dev/null 2>&1 || log_fatal "Generated Xray JSON is malformed."
    systemctl restart xray
    log_success "Xray master configuration generated and service restarted."
}

# ------------------------------------------------------------------------------
# Firewall Configuration (UFW & iptables)
# ------------------------------------------------------------------------------
configure_firewall() {
    log_info "Configuring network ports & firewall rules..."

    local tcp_ports=(22 80 443 "${PORT_TROJAN_DIRECT}" 8080 8880 2082 2086 "${PORT_SHADOWSOCKS}")
    local udp_ports=("${PORT_BADVPN_UDP}" "${PORT_SHADOWSOCKS}")

    # UFW Configuration if installed
    if command -v ufw >/dev/null 2>&1; then
        for p in "${tcp_ports[@]}"; do
            ufw allow "${p}/tcp" >/dev/null 2>&1 || true
        done
        for p in "${udp_ports[@]}"; do
            ufw allow "${p}/udp" >/dev/null 2>&1 || true
        done
    fi

    # Raw iptables fallback rules
    for p in "${tcp_ports[@]}"; do
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
    done
    for p in "${udp_ports[@]}"; do
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
    done

    # Save iptables rules
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    fi

    log_success "All proxy ingress and BadVPN ports (80, 443, 442, 8080, 8880, 2082, 2086, 8388, 7300) are open."
}

# ------------------------------------------------------------------------------
# Automated Hourly Expiry & Bandwidth Quota Daemon
# ------------------------------------------------------------------------------
setup_cron_job() {
    cat <<EOF > "$CRON_JOB"
#!/usr/bin/env bash
/usr/local/bin/xray-manager --check-expiry >/dev/null 2>&1
EOF
    chmod +x "$CRON_JOB"
}

check_expired_accounts() {
    [[ ! -f "$DB_FILE" ]] && return 0
    local today
    today=$(date +%Y-%m-%d)
    local modified=0

    local users_count
    users_count=$(jq '. | length' "$DB_FILE")

    for ((i=0; i<users_count; i++)); do
        local user proto exp status
        user=$(jq -r ".[$i].username" "$DB_FILE")
        proto=$(jq -r ".[$i].protocol" "$DB_FILE")
        exp=$(jq -r ".[$i].expiry" "$DB_FILE")
        status=$(jq -r ".[$i].status" "$DB_FILE")

        if [[ "$status" == "active" && "$exp" < "$today" ]]; then
            log_warning "Account [${user}] (${proto}) has expired on ${exp}. Deactivating..."
            
            # Update status in DB
            local tmp_db
            tmp_db=$(mktemp)
            jq "(.[$i].status) = \"expired\"" "$DB_FILE" > "$tmp_db" && mv "$tmp_db" "$DB_FILE"
            chmod 600 "$DB_FILE"

            # If SSH, lock user
            if [[ "$proto" == "ssh" ]]; then
                usermod -L "$user" 2>/dev/null || true
            fi
            modified=1
        fi
    done

    if [[ $modified -eq 1 ]]; then
        generate_xray_config
    fi
}

# ------------------------------------------------------------------------------
# User Account Management (Add, Delete, Renew, List)
# ------------------------------------------------------------------------------
generate_uuid() {
    if command -v xray >/dev/null 2>&1; then
        xray uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
    fi
}

add_user() {
    clear
    echo -e "${C_B_CYAN}====================================================${C_RESET}"
    echo -e "${C_B_WHITE}             CREATE NEW PROXY / SSH ACCOUNT         ${C_RESET}"
    echo -e "${C_B_CYAN}====================================================${C_RESET}"
    echo -e "Select Target Protocol:"
    echo -e " [1] SSH (Direct Port 22 + BadVPN UDP 7300 + WebSocket CDN)"
    echo -e " [2] VMess (WebSocket TLS 443 & Plain HTTP 80/8080/CDN)"
    echo -e " [3] VLESS (WebSocket TLS 443 & Plain HTTP 80/8080/CDN)"
    echo -e " [4] Trojan (WebSocket TLS 443 & Direct TLS 442)"
    echo -e " [5] Shadowsocks (AEAD 2022 / Port 8388)"
    echo -e " [0] Return to Main Menu"
    echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
    read -rp "Enter choice [1-5]: " proto_choice

    local protocol=""
    case "$proto_choice" in
        1) protocol="ssh" ;;
        2) protocol="vmess" ;;
        3) protocol="vless" ;;
        4) protocol="trojan" ;;
        5) protocol="shadowsocks" ;;
        0) return ;;
        *) log_error "Invalid selection."; sleep 1.5; return ;;
    esac

    # Prompt Username
    local username=""
    while true; do
        read -rp "Enter Username (alphanumeric, e.g. client01): " username
        if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_error "Username must be alphanumeric without spaces."
            continue
        fi

        # Check for duplication in database
        if jq -e --arg u "$username" '.[] | select(.username == $u)' "$DB_FILE" >/dev/null 2>&1; then
            log_error "User '$username' already exists in the system database."
            continue
        fi

        # If SSH, check Linux system accounts
        if [[ "$protocol" == "ssh" ]] && id "$username" >/dev/null 2>&1; then
            log_error "Linux user '$username' already exists on this server."
            continue
        fi
        break
    done

    # Prompt Password / UUID
    local credential=""
    if [[ "$protocol" == "ssh" || "$protocol" == "trojan" || "$protocol" == "shadowsocks" ]]; then
        read -rp "Enter Password (Press ENTER to auto-generate): " credential
        if [[ -z "$credential" ]]; then
            credential=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 12)
        fi
    else
        read -rp "Enter UUID (Press ENTER to auto-generate): " credential
        if [[ -z "$credential" ]]; then
            credential=$(generate_uuid)
        fi
    fi

    # Prompt Validity Duration
    local days=""
    while true; do
        read -rp "Account Validity in Days (e.g. 30): " days
        if [[ "$days" =~ ^[0-9]+$ ]] && [[ "$days" -gt 0 ]]; then
            break
        fi
        log_error "Please enter a valid positive integer."
    done

    # Prompt Bandwidth Quota (GB)
    local quota=""
    read -rp "Bandwidth Quota in GB [0 = Unlimited]: " quota
    [[ ! "$quota" =~ ^[0-9]+$ ]] && quota=0

    # Calculate Expiry Date
    local expiry_date
    expiry_date=$(date -d "+${days} days" +%Y-%m-%d)
    local created_date
    created_date=$(date +%Y-%m-%d)

    # 1. System user creation for SSH
    if [[ "$protocol" == "ssh" ]]; then
        useradd -M -s /bin/false "$username" 2>/dev/null || useradd -M -s /usr/sbin/nologin "$username"
        echo "${username}:${credential}" | chpasswd
        usermod -e "$expiry_date" "$username"
    fi

    # 2. Append user to users.json
    local tmp_db
    tmp_db=$(mktemp)
    jq --arg u "$username" \
       --arg p "$protocol" \
       --arg c "$credential" \
       --arg exp "$expiry_date" \
       --arg q "$quota" \
       --arg cd "$created_date" \
       '. += [{
           "username": $u,
           "protocol": $p,
           "uuid": $c,
           "expiry": $exp,
           "quota_gb": ($q | tonumber),
           "created_at": $cd,
           "status": "active"
       }]' "$DB_FILE" > "$tmp_db" && mv "$tmp_db" "$DB_FILE"
    chmod 600 "$DB_FILE"

    # 3. Reload Xray Config
    generate_xray_config

    log_success "Account [${username}] created successfully!"
    display_user_credentials "$username"
}

delete_user() {
    clear
    echo -e "${C_B_RED}====================================================${C_RESET}"
    echo -e "${C_B_WHITE}                 DELETE USER ACCOUNT                ${C_RESET}"
    echo -e "${C_B_RED}====================================================${C_RESET}"
    
    local count
    count=$(jq '. | length' "$DB_FILE")
    if [[ "$count" -eq 0 ]]; then
        log_warning "No users found in database."
        read -rp "Press ENTER to return..."; return
    fi

    echo -e "Existing accounts:"
    jq -r 'to_entries[] | " [\(.key + 1)] \(.value.username) (\(.value.protocol)) - Expires: \(.value.expiry) [\(.value.status)]"' "$DB_FILE"
    echo -e "${C_B_RED}----------------------------------------------------${C_RESET}"
    read -rp "Enter Username or Index to delete: " target

    local target_user=""
    if [[ "$target" =~ ^[0-9]+$ ]] && [[ "$target" -ge 1 && "$target" -le "$count" ]]; then
        local idx=$((target - 1))
        target_user=$(jq -r ".[$idx].username" "$DB_FILE")
    else
        target_user="$target"
    fi

    if ! jq -e --arg u "$target_user" '.[] | select(.username == $u)' "$DB_FILE" >/dev/null 2>&1; then
        log_error "User '$target_user' not found."
        read -rp "Press ENTER to return..."; return
    fi

    local proto
    proto=$(jq -r --arg u "$target_user" '.[] | select(.username == $u) | .protocol' "$DB_FILE")

    read -rp "Are you sure you want to permanently delete '${target_user}'? [y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        # If SSH, remove system user
        if [[ "$proto" == "ssh" ]]; then
            userdel -r "$target_user" 2>/dev/null || userdel "$target_user" 2>/dev/null || true
        fi

        # Remove from users.json
        local tmp_db
        tmp_db=$(mktemp)
        jq --arg u "$target_user" 'del(.[] | select(.username == $u))' "$DB_FILE" > "$tmp_db" && mv "$tmp_db" "$DB_FILE"
        chmod 600 "$DB_FILE"

        generate_xray_config
        log_success "Account [${target_user}] successfully purged."
    else
        log_info "Deletion cancelled."
    fi
    read -rp "Press ENTER to return..."
}

renew_user() {
    clear
    echo -e "${C_B_GREEN}====================================================${C_RESET}"
    echo -e "${C_B_WHITE}             RENEW / EXTEND USER ACCOUNT            ${C_RESET}"
    echo -e "${C_B_GREEN}====================================================${C_RESET}"
    
    local count
    count=$(jq '. | length' "$DB_FILE")
    if [[ "$count" -eq 0 ]]; then
        log_warning "No users found in database."
        read -rp "Press ENTER to return..."; return
    fi

    jq -r 'to_entries[] | " [\(.key + 1)] \(.value.username) (\(.value.protocol)) - Expires: \(.value.expiry) [\(.value.status)]"' "$DB_FILE"
    echo -e "${C_B_GREEN}----------------------------------------------------${C_RESET}"
    read -rp "Enter Username or Index to renew: " target

    local target_user=""
    if [[ "$target" =~ ^[0-9]+$ ]] && [[ "$target" -ge 1 && "$target" -le "$count" ]]; then
        local idx=$((target - 1))
        target_user=$(jq -r ".[$idx].username" "$DB_FILE")
    else
        target_user="$target"
    fi

    if ! jq -e --arg u "$target_user" '.[] | select(.username == $u)' "$DB_FILE" >/dev/null 2>&1; then
        log_error "User '$target_user' not found."
        read -rp "Press ENTER to return..."; return
    fi

    local current_expiry
    current_expiry=$(jq -r --arg u "$target_user" '.[] | select(.username == $u) | .expiry' "$DB_FILE")
    local proto
    proto=$(jq -r --arg u "$target_user" '.[] | select(.username == $u) | .protocol' "$DB_FILE")

    read -rp "Enter additional days to extend (e.g. 30): " add_days
    [[ ! "$add_days" =~ ^[0-9]+$ ]] && { log_error "Invalid day input."; return; }

    local today
    today=$(date +%Y-%m-%d)
    local base_date="$current_expiry"
    # If already expired, extend from today
    if [[ "$current_expiry" < "$today" ]]; then
        base_date="$today"
    fi

    local new_expiry
    new_expiry=$(date -d "${base_date} + ${add_days} days" +%Y-%m-%d)

    # Update DB
    local tmp_db
    tmp_db=$(mktemp)
    jq --arg u "$target_user" --arg exp "$new_expiry" \
       'map(if .username == $u then .expiry = $exp | .status = "active" else . end)' \
       "$DB_FILE" > "$tmp_db" && mv "$tmp_db" "$DB_FILE"
    chmod 600 "$DB_FILE"

    # If SSH, update system expiration and unlock if locked
    if [[ "$proto" == "ssh" ]]; then
        usermod -e "$new_expiry" "$target_user" 2>/dev/null || true
        usermod -U "$target_user" 2>/dev/null || true
    fi

    generate_xray_config
    log_success "Account [${target_user}] extended until ${new_expiry}."
    read -rp "Press ENTER to return..."
}

list_users() {
    clear
    echo -e "${C_B_CYAN}================================================================================${C_RESET}"
    echo -e "${C_B_WHITE}                              ACTIVE USER ACCOUNTS                              ${C_RESET}"
    echo -e "${C_B_CYAN}================================================================================${C_RESET}"
    printf "%-4s | %-16s | %-11s | %-11s | %-8s | %-9s | %-8s\n" "ID" "Username" "Protocol" "Expires" "Days Left" "Quota(GB)" "Status"
    echo -e "${C_CYAN}--------------------------------------------------------------------------------${C_RESET}"

    local count
    count=$(jq '. | length' "$DB_FILE")
    if [[ "$count" -eq 0 ]]; then
        echo -e " No accounts registered."
    else
        local today_sec
        today_sec=$(date +%s)
        for ((i=0; i<count; i++)); do
            local u proto exp q status
            u=$(jq -r ".[$i].username" "$DB_FILE")
            proto=$(jq -r ".[$i].protocol" "$DB_FILE")
            exp=$(jq -r ".[$i].expiry" "$DB_FILE")
            q=$(jq -r ".[$i].quota_gb" "$DB_FILE")
            status=$(jq -r ".[$i].status" "$DB_FILE")

            local exp_sec
            exp_sec=$(date -d "$exp" +%s 2>/dev/null || echo 0)
            local diff_days=$(( (exp_sec - today_sec) / 86400 ))
            [[ $diff_days -lt 0 ]] && diff_days=0

            local status_color="$C_GREEN"
            [[ "$status" != "active" ]] && status_color="$C_RED"

            printf "%-4s | %-16s | %-11s | %-11s | %-9s | %-9s | ${status_color}%-8s${C_RESET}\n" \
                "$((i+1))" "$u" "$proto" "$exp" "${diff_days}d" "${q}GB" "$status"
        done
    fi
    echo -e "${C_B_CYAN}================================================================================${C_RESET}"
    read -rp "Press ENTER to return..."
}

# ------------------------------------------------------------------------------
# Config URI & QR Code Generation
# ------------------------------------------------------------------------------
display_user_credentials() {
    local username="$1"
    local user_record
    user_record=$(jq -r --arg u "$username" '.[] | select(.username == $u)' "$DB_FILE")

    if [[ -z "$user_record" ]]; then
        log_error "User '$username' not found."
        read -rp "Press ENTER to return..."; return
    fi

    local proto credential expiry quota
    proto=$(echo "$user_record" | jq -r .protocol)
    credential=$(echo "$user_record" | jq -r .uuid)
    expiry=$(echo "$user_record" | jq -r .expiry)
    quota=$(echo "$user_record" | jq -r .quota_gb)

    clear
    echo -e "${C_B_YELLOW}====================================================================${C_RESET}"
    echo -e "${C_B_WHITE}                     CLIENT CONNECTION DETAILS                     ${C_RESET}"
    echo -e "${C_B_YELLOW}====================================================================${C_RESET}"
    echo -e " ${C_BOLD}Username   :${C_RESET} ${username}"
    echo -e " ${C_BOLD}Protocol   :${C_RESET} ${proto^^}"
    echo -e " ${C_BOLD}Domain/Host:${C_RESET} ${SERVER_DOMAIN}"
    echo -e " ${C_BOLD}Server IP  :${C_RESET} ${SERVER_IP}"
    echo -e " ${C_BOLD}Expires On :${C_RESET} ${expiry}"
    echo -e " ${C_BOLD}Data Quota :${C_RESET} ${quota} GB"
    echo -e "${C_B_YELLOW}--------------------------------------------------------------------${C_RESET}"

    case "$proto" in
        ssh)
            echo -e " ${C_BOLD}Direct SSH Port      :${C_RESET} 22"
            echo -e " ${C_BOLD}BadVPN UDPGW Port    :${C_RESET} ${PORT_BADVPN_UDP} (For UDP Games & VoIP)"
            echo -e " ${C_BOLD}WebSocket Plain Port :${C_RESET} 80, 8080, 8880, 2082, 2086 (Path: /ssh)"
            echo -e " ${C_BOLD}WebSocket TLS Port   :${C_RESET} 443 (Path: /ssh)"
            echo -e " ${C_BOLD}Password             :${C_RESET} ${credential}"
            echo -e " ${C_BOLD}Payload Header Format:${C_RESET} GET /ssh HTTP/1.1[crlf]Host: ${SERVER_DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]"
            ;;

        vmess)
            # VMess TLS JSON Base64
            local vmess_tls_json
            vmess_tls_json=$(jq -c -n \
                --arg ps "${username}-TLS" \
                --arg add "${SERVER_DOMAIN}" \
                --arg port "443" \
                --arg id "${credential}" \
                --arg host "${SERVER_DOMAIN}" \
                --arg sni "${SERVER_DOMAIN}" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:"ws", type:"none", host:$host, path:"/vmess", tls:"tls", sni:$sni}')
            local vmess_tls_uri="vmess://$(echo -n "$vmess_tls_json" | base64 -w 0)"

            # VMess Plain HTTP JSON Base64
            local vmess_http_json
            vmess_http_json=$(jq -c -n \
                --arg ps "${username}-HTTP" \
                --arg add "${SERVER_DOMAIN}" \
                --arg port "80" \
                --arg id "${credential}" \
                --arg host "${SERVER_DOMAIN}" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:"ws", type:"none", host:$host, path:"/vmess", tls:"none"}')
            local vmess_http_uri="vmess://$(echo -n "$vmess_http_json" | base64 -w 0)"

            echo -e "${C_CYAN}[1] VMess WebSocket + TLS (Port 443):${C_RESET}"
            echo -e "${C_DIM}${vmess_tls_uri}${C_RESET}\n"

            echo -e "${C_CYAN}[2] VMess WebSocket + Plain HTTP (Port 80, 8080 CDN):${C_RESET}"
            echo -e "${C_DIM}${vmess_http_uri}${C_RESET}\n"

            echo -e "${C_B_WHITE}Terminal QR Code (VMess TLS):${C_RESET}"
            qrencode -t ANSIUTF8 "${vmess_tls_uri}"
            ;;

        vless)
            local vless_tls_uri="vless://${credential}@${SERVER_DOMAIN}:443?path=%2Fvless&security=tls&encryption=none&type=ws&host=${SERVER_DOMAIN}&sni=${SERVER_DOMAIN}#${username}-TLS"
            local vless_http_uri="vless://${credential}@${SERVER_DOMAIN}:80?path=%2Fvless&security=none&encryption=none&type=ws&host=${SERVER_DOMAIN}#${username}-HTTP"

            echo -e "${C_CYAN}[1] VLESS WebSocket + TLS (Port 443):${C_RESET}"
            echo -e "${C_DIM}${vless_tls_uri}${C_RESET}\n"

            echo -e "${C_CYAN}[2] VLESS WebSocket + Plain HTTP (Port 80, 8080 CDN):${C_RESET}"
            echo -e "${C_DIM}${vless_http_uri}${C_RESET}\n"

            echo -e "${C_B_WHITE}Terminal QR Code (VLESS TLS):${C_RESET}"
            qrencode -t ANSIUTF8 "${vless_tls_uri}"
            ;;

        trojan)
            local trojan_ws_uri="trojan://${credential}@${SERVER_DOMAIN}:443?path=%2Ftrojan&security=tls&type=ws&host=${SERVER_DOMAIN}&sni=${SERVER_DOMAIN}#${username}-WS"
            local trojan_direct_uri="trojan://${credential}@${SERVER_DOMAIN}:${PORT_TROJAN_DIRECT}?security=tls&headerType=none&type=tcp&sni=${SERVER_DOMAIN}#${username}-Direct"

            echo -e "${C_CYAN}[1] Trojan WebSocket + TLS (Port 443):${C_RESET}"
            echo -e "${C_DIM}${trojan_ws_uri}${C_RESET}\n"

            echo -e "${C_CYAN}[2] Trojan Direct TLS (Port ${PORT_TROJAN_DIRECT}):${C_RESET}"
            echo -e "${C_DIM}${trojan_direct_uri}${C_RESET}\n"

            echo -e "${C_B_WHITE}Terminal QR Code (Trojan WS):${C_RESET}"
            qrencode -t ANSIUTF8 "${trojan_ws_uri}"
            ;;

        shadowsocks)
            local ss_plain="aes-256-gcm:${credential}"
            local ss_base64
            ss_base64=$(echo -n "$ss_plain" | base64 -w 0)
            local ss_uri="ss://${ss_base64}@${SERVER_DOMAIN}:${PORT_SHADOWSOCKS}#${username}"

            echo -e "${C_CYAN}Shadowsocks AEAD (Port ${PORT_SHADOWSOCKS}):${C_RESET}"
            echo -e "${C_DIM}${ss_uri}${C_RESET}\n"

            echo -e "${C_B_WHITE}Terminal QR Code (Shadowsocks):${C_RESET}"
            qrencode -t ANSIUTF8 "${ss_uri}"
            ;;
    esac

    echo -e "${C_B_YELLOW}====================================================================${C_RESET}"
    read -rp "Press ENTER to return..."
}

show_config_menu() {
    clear
    local count
    count=$(jq '. | length' "$DB_FILE")
    if [[ "$count" -eq 0 ]]; then
        log_warning "No users found in database."
        read -rp "Press ENTER to return..."; return
    fi

    echo -e "${C_B_CYAN}Select User Account to Display Configuration / QR Code:${C_RESET}"
    jq -r 'to_entries[] | " [\(.key + 1)] \(.value.username) (\(.value.protocol))"' "$DB_FILE"
    echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
    read -rp "Enter choice: " target

    local target_user=""
    if [[ "$target" =~ ^[0-9]+$ ]] && [[ "$target" -ge 1 && "$target" -le "$count" ]]; then
        local idx=$((target - 1))
        target_user=$(jq -r ".[$idx].username" "$DB_FILE")
    else
        target_user="$target"
    fi

    display_user_credentials "$target_user"
}

# ------------------------------------------------------------------------------
# Real-Time Monitoring: Connections & Xray API Bandwidth
# ------------------------------------------------------------------------------
monitor_connections_and_stats() {
    clear
    echo -e "${C_B_CYAN}====================================================================${C_RESET}"
    echo -e "${C_B_WHITE}               REAL-TIME CONNECTIONS & TRAFFIC TELEMETRY             ${C_RESET}"
    echo -e "${C_B_CYAN}====================================================================${C_RESET}"

    echo -e "${C_B_WHITE}[1] Active OpenSSH Sessions:${C_RESET}"
    who 2>/dev/null || echo "No active interactive sessions."
    echo ""

    echo -e "${C_B_WHITE}[2] Active Ingress Socket Connections:${C_RESET}"
    ss -nt state established '( sport = :443 or sport = :80 or sport = :442 or sport = :8388 or sport = :7300 )' | head -n 20
    echo ""

    echo -e "${C_B_WHITE}[3] Xray API Traffic Metrics (Per User):${C_RESET}"
    if command -v xray >/dev/null 2>&1; then
        local stats_output
        stats_output=$(xray api statsquery --server="127.0.0.1:${PORT_XRAY_API}" 2>/dev/null || true)
        if [[ -n "$stats_output" ]]; then
            echo "$stats_output" | jq -r '.stat[]? | "\(.name): \((.value | tonumber) / 1048576 | round) MB"' 2>/dev/null || echo "Traffic counters initial."
        else
            echo "API stats service ready. Awaiting inbound client data."
        fi
    else
        echo "Xray binary unavailable."
    fi

    echo -e "${C_B_CYAN}====================================================================${C_RESET}"
    read -rp "Press ENTER to return..."
}

# ------------------------------------------------------------------------------
# SSL Certificate Management Menu
# ------------------------------------------------------------------------------
manage_ssl_menu() {
    clear
    echo -e "${C_B_CYAN}====================================================${C_RESET}"
    echo -e "${C_B_WHITE}             SSL / TLS CERTIFICATE MANAGER          ${C_RESET}"
    echo -e "${C_B_CYAN}====================================================${C_RESET}"
    echo -e " Current Domain : ${C_B_GREEN}${SERVER_DOMAIN}${C_RESET}"
    echo -e " Current Mode   : ${C_B_YELLOW}${SSL_MODE}${C_RESET}"
    echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
    echo -e " [1] Issue Genuine Let's Encrypt Certificate (Webroot)"
    echo -e " [2] Generate ECC 256-bit Self-Signed Certificate"
    echo -e " [3] Check SSL Certificate Expiry & Validity"
    echo -e " [4] Force Certbot Certificate Renewal"
    echo -e " [0] Return to Main Menu"
    echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
    read -rp "Enter choice [0-4]: " ssl_choice

    case "$ssl_choice" in
        1)
            read -rp "Enter your Domain (e.g. vpn.example.com): " domain
            read -rp "Enter your Email address: " email
            if [[ -n "$domain" && -n "$email" ]]; then
                SERVER_DOMAIN="$domain"
                configure_nginx
                issue_letsencrypt_cert "$domain" "$email"
                configure_nginx
                generate_xray_config
            else
                log_error "Domain and email cannot be empty."
            fi
            ;;
        2)
            generate_self_signed_cert "$SERVER_DOMAIN"
            configure_nginx
            generate_xray_config
            ;;
        3)
            if [[ -f "${SSL_DIR}/fullchain.pem" ]]; then
                openssl x509 -in "${SSL_DIR}/fullchain.pem" -noout -issuer -subject -dates
            else
                log_error "Certificate not found at ${SSL_DIR}/fullchain.pem"
            fi
            ;;
        4)
            certbot renew --force-renewal
            systemctl reload nginx
            systemctl restart xray
            ;;
        0) return ;;
        *) log_error "Invalid selection." ;;
    esac
    read -rp "Press ENTER to return..."
}

# ------------------------------------------------------------------------------
# Service Management & System Diagnostics
# ------------------------------------------------------------------------------
manage_services() {
    clear
    echo -e "${C_B_CYAN}====================================================${C_RESET}"
    echo -e "${C_B_WHITE}             SERVICE STATUS & DIAGNOSTICS           ${C_RESET}"
    echo -e "${C_B_CYAN}====================================================${C_RESET}"

    local services=("xray" "nginx" "badvpn-udpgw" "ssh")
    for s in "${services[@]}"; do
        if systemctl is-active --quiet "$s"; then
            echo -e " ${s} : ${C_B_GREEN}[RUNNING]${C_RESET}"
        else
            echo -e " ${s} : ${C_B_RED}[FAILED / INACTIVE]${C_RESET}"
        fi
    done

    echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
    echo -e " [1] Restart All Services (Xray, Nginx, BadVPN, SSH)"
    echo -e " [2] View Xray Access Logs"
    echo -e " [3] View Xray Error Logs"
    echo -e " [4] View Nginx Error Logs"
    echo -e " [0] Return to Main Menu"
    echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
    read -rp "Enter choice [0-4]: " svc_choice

    case "$svc_choice" in
        1)
            systemctl restart xray nginx badvpn-udpgw ssh 2>/dev/null || true
            log_success "All services restarted."
            ;;
        2) tail -n 50 /var/log/xray/access.log 2>/dev/null || echo "Log empty." ;;
        3) tail -n 50 /var/log/xray/error.log 2>/dev/null || echo "Log empty." ;;
        4) tail -n 50 /var/log/nginx/error.log 2>/dev/null || echo "Log empty." ;;
        0) return ;;
        *) log_error "Invalid selection." ;;
    esac
    read -rp "Press ENTER to return..."
}

# ------------------------------------------------------------------------------
# Backup and Restore Configuration & Users
# ------------------------------------------------------------------------------
backup_and_restore() {
    clear
    echo -e "${C_B_CYAN}====================================================${C_RESET}"
    echo -e "${C_B_WHITE}             BACKUP & RESTORE UTILITY               ${C_RESET}"
    echo -e "${C_B_CYAN}====================================================${C_RESET}"
    echo -e " [1] Create Complete Server Backup Archive"
    echo -e " [2] Restore from Existing Backup Archive"
    echo -e " [0] Return to Main Menu"
    echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
    read -rp "Enter choice [0-2]: " br_choice

    case "$br_choice" in
        1)
            local timestamp
            timestamp=$(date +%Y%m%d_%H%M%S)
            local backup_file="${BACKUP_DIR}/xray_backup_${timestamp}.tar.gz"
            tar -czf "$backup_file" -C / \
                etc/xray-manager \
                usr/local/etc/xray/config.json \
                etc/nginx/sites-available/xray-manager.conf 2>/dev/null || true
            log_success "Backup archived: ${backup_file}"
            ;;
        2)
            echo "Available Backups:"
            ls -l "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || { log_warning "No backups found."; return; }
            read -rp "Enter full path of backup file to restore: " rest_file
            if [[ -f "$rest_file" ]]; then
                tar -xzf "$rest_file" -C /
                systemctl restart nginx xray badvpn-udpgw 2>/dev/null || true
                log_success "Configuration restored successfully."
            else
                log_error "File does not exist."
            fi
            ;;
        0) return ;;
        *) log_error "Invalid selection." ;;
    esac
    read -rp "Press ENTER to return..."
}

# ------------------------------------------------------------------------------
# Full Stack Initial Setup Wizard
# ------------------------------------------------------------------------------
run_full_installer() {
    clear
    echo -e "${C_B_CYAN}===================================================================${C_RESET}"
    echo -e "${C_B_WHITE}   ENTERPRISE MULTI-PROTOCOL VPN/PROXY SETUP FOR UBUNTU 24.04 LTS  ${C_RESET}"
    echo -e "${C_B_CYAN}===================================================================${C_RESET}"
    echo -e " This wizard will configure:"
    echo -e "   - Xray-Core (VMess, VLESS, Trojan, Shadowsocks, SSH-WS Inbounds)"
    echo -e "   - BadVPN UDP Gateway (Port 7300 for SSH Gaming)"
    echo -e "   - Nginx HTTP & TLS Reverse Proxy (Ports 80, 443, 8080, 8880, 2082, 2086)"
    echo -e "   - Automated SSL (Let's Encrypt / ECC Self-Signed Fallback)"
    echo -e "   - Kernel BBR Congestion Control & Concurrency Hardening"
    echo -e "   - Anti-Censorship Camouflage Decoy Webpage"
    echo -e "${C_B_CYAN}-------------------------------------------------------------------${C_RESET}"

    local public_ip
    public_ip=$(get_public_ip)
    echo -e "Detected Public IP: ${C_B_GREEN}${public_ip}${C_RESET}"

    read -rp "Enter your Domain name (Leave blank to use '${public_ip}.nip.io'): " input_domain
    if [[ -z "$input_domain" ]]; then
        SERVER_DOMAIN="${public_ip}.nip.io"
    else
        SERVER_DOMAIN="$input_domain"
    fi
    SERVER_IP="$public_ip"
    save_config_env

    log_info "Initiating Full Automated Stack Deployment..."

    install_dependencies
    optimize_kernel_bbr
    deploy_decoy_website
    generate_self_signed_cert "$SERVER_DOMAIN"
    configure_nginx
    install_xray_core
    install_badvpn
    configure_openssh
    generate_xray_config
    configure_firewall
    setup_cron_job

    # Attempt genuine Let's Encrypt if user provided custom domain
    if [[ "$input_domain" != "" && "$input_domain" != *.nip.io ]]; then
        read -rp "Do you wish to issue a Let's Encrypt SSL certificate now? [Y/n]: " do_ssl
        if [[ ! "$do_ssl" =~ ^[nN]$ ]]; then
            read -rp "Enter administrative email for SSL notifications: " admin_email
            issue_letsencrypt_cert "$SERVER_DOMAIN" "$admin_email"
            configure_nginx
            generate_xray_config
        fi
    fi

    # Create global executable symlink
    ln -sfn "$SCRIPT_PATH" /usr/local/bin/xray-manager
    ln -sfn "$SCRIPT_PATH" /usr/local/bin/menu
    chmod +x /usr/local/bin/xray-manager /usr/local/bin/menu

    echo -e "\n${C_B_GREEN}===================================================================${C_RESET}"
    echo -e "${C_B_WHITE}             FULL STACK INSTALLATION COMPLETED SUCCESSFULLY        ${C_RESET}"
    echo -e "${C_B_GREEN}===================================================================${C_RESET}"
    echo -e "You can launch this management console at any time by running: ${C_B_CYAN}menu${C_RESET} or ${C_B_CYAN}xray-manager${C_RESET}"
    read -rp "Press ENTER to access the management dashboard..."
}

# ------------------------------------------------------------------------------
# Main Interactive CLI Dashboard
# ------------------------------------------------------------------------------
main_menu() {
    while true; do
        clear
        # Gather live telemetry
        local xray_status="${C_B_RED}OFF${C_RESET}"
        local nginx_status="${C_B_RED}OFF${C_RESET}"
        local badvpn_status="${C_B_RED}OFF${C_RESET}"
        local bbr_status="${C_B_RED}OFF${C_RESET}"

        systemctl is-active --quiet xray && xray_status="${C_B_GREEN}ON${C_RESET}"
        systemctl is-active --quiet nginx && nginx_status="${C_B_GREEN}ON${C_RESET}"
        systemctl is-active --quiet badvpn-udpgw && badvpn_status="${C_B_GREEN}ON${C_RESET}"
        [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] && bbr_status="${C_B_GREEN}ON${C_RESET}"

        local total_users=0
        if [[ -f "$DB_FILE" ]]; then
            total_users=$(jq '. | length' "$DB_FILE" 2>/dev/null || echo 0)
        fi

        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        echo -e "${C_B_WHITE}    UBUNTU 24.04 LTS ENTERPRISE XRAY & SSH PROXY SUITE v${APP_VERSION}    ${C_RESET}"
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        echo -e " Server IP : ${C_GREEN}${SERVER_IP:-127.0.0.1}${C_RESET} | Domain : ${C_GREEN}${SERVER_DOMAIN:-N/A}${C_RESET}"
        echo -e " Services  : Xray [${xray_status}] Nginx [${nginx_status}] BadVPN [${badvpn_status}] BBR [${bbr_status}]"
        echo -e " Database  : ${C_B_YELLOW}${total_users}${C_RESET} Active Client Accounts Registered"
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        echo -e " ${C_B_WHITE}[USER MANAGEMENT]${C_RESET}"
        echo -e "   ${C_CYAN}[1]${C_RESET} Create Account (SSH / VMess / VLESS / Trojan / Shadowsocks)"
        echo -e "   ${C_CYAN}[2]${C_RESET} Delete User Account"
        echo -e "   ${C_CYAN}[3]${C_RESET} Renew / Extend Account Duration"
        echo -e "   ${C_CYAN}[4]${C_RESET} List All Registered Accounts & Expiry Status"
        echo -e "   ${C_CYAN}[5]${C_RESET} Show Connection Details, URIs & Terminal QR Codes"
        echo -e "   ${C_CYAN}[6]${C_RESET} Real-Time Connections & Bandwidth Telemetry"
        echo ""
        echo -e " ${C_B_WHITE}[SERVER & PROTOCOL MANAGEMENT]${C_RESET}"
        echo -e "   ${C_CYAN}[7]${C_RESET} Run Full Stack Setup / Reconfigure Core Services"
        echo -e "   ${C_CYAN}[8]${C_RESET} SSL Certificate Management (Let's Encrypt / Self-Signed)"
        echo -e "   ${C_CYAN}[9]${C_RESET} Service Status, Logs & Process Diagnostics"
        echo -e "  ${C_CYAN}[10]${C_RESET} Kernel BBR Congestion Control & Concurrency Tuning"
        echo -e "  ${C_CYAN}[11]${C_RESET} Backup & Restore Configuration Database"
        echo ""
        echo -e "   ${C_RED}[0]${C_RESET} Exit Management Suite"
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        read -rp "Please select an option [0-11]: " choice

        case "$choice" in
            1) add_user ;;
            2) delete_user ;;
            3) renew_user ;;
            4) list_users ;;
            5) show_config_menu ;;
            6) monitor_connections_and_stats ;;
            7) run_full_installer ;;
            8) manage_ssl_menu ;;
            9) manage_services ;;
            10) optimize_kernel_bbr; read -rp "Press ENTER to return..." ;;
            11) backup_and_restore ;;
            0) clear; exit 0 ;;
            *) log_error "Invalid selection."; sleep 1 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entry Point & CLI Argument Parsing
# ------------------------------------------------------------------------------
main() {
    check_root
    check_system_compatibility
    init_directories

    case "${1:-}" in
        --install)
            run_full_installer
            ;;
        --check-expiry)
            check_expired_accounts
            ;;
        --list)
            list_users
            ;;
        --help|-h)
            echo "Usage: $0 [OPTION]"
            echo "Options:"
            echo "  --install       Execute unattended / guided full stack deployment"
            echo "  --check-expiry  Execute cron account expiration check"
            echo "  --list          Display registered users list"
            echo "  --help          Show this documentation"
            exit 0
            ;;
        *)
            # If config is uninitialized or Xray is not installed, prompt to run installer
            if [[ ! -f "$XRAY_BIN" || ! -f "$XRAY_CONFIG" ]]; then
                echo -e "${C_YELLOW}Xray or core stack has not been initialized yet.${C_RESET}"
                read -rp "Would you like to run the Full Stack Installer now? [Y/n]: " start_inst
                if [[ ! "$start_inst" =~ ^[nN]$ ]]; then
                    run_full_installer
                fi
            fi
            main_menu
            ;;
    esac
}

main "$@"
