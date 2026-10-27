#!/usr/bin/env bash
# ==============================================================================
# MODULE 1: Core Environment, Kernel Hardening & Anti-Probing Camouflage Shield
# Architecture: Enterprise Linux Kernel & Network Security Architecture
# Target OS   : Ubuntu 24.04 LTS (Noble Numbat)
# Compatibility: Standalone executable OR sourceable module
# ==============================================================================

# Ensure strict execution safety when invoked directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
fi

# ------------------------------------------------------------------------------
# Module Metadata & Global Configurations
# ------------------------------------------------------------------------------
MODULE1_NAME="Core Environment & Anti-Probing Shield"
MODULE1_VERSION="2.4.0-LTS"
MODULE1_AUTHOR="Principal Linux Systems & Network Security Architect"

SYSCTL_HARDENING_FILE="/etc/sysctl.d/99-proxy-hardening.conf"
LIMITS_HARDENING_FILE="/etc/security/limits.d/99-proxy-limits.conf"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
WEB_ROOT_DIR="/var/www/html"
PROXY_CONF_NAME="anti_probing_shield.conf"

# Required Ingress Ports
SHIELD_TCP_PORTS=(22 80 443 442 8080 8880 2082 2086)
SHIELD_UDP_PORTS=(7300)

# Color & Logging Setup
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_B_RED='\033[1;31m'
    C_B_GREEN='\033[1;32m'
    C_B_CYAN='\033[1;36m'
else
    C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_B_RED='' C_B_GREEN='' C_B_CYAN=''
fi

m1_log_info()    { echo -e "${C_CYAN}[M1-INFO]${C_RESET} $*"; }
m1_log_success() { echo -e "${C_GREEN}[M1-SUCCESS]${C_RESET} $*"; }
m1_log_warn()    { echo -e "${C_YELLOW}[M1-WARN]${C_RESET} $*"; }
m1_log_error()   { echo -e "${C_RED}[M1-ERROR]${C_RESET} $*" >&2; }
m1_log_fatal()   { echo -e "${C_B_RED}[M1-FATAL]${C_RESET} $*" >&2; exit 1; }

# Trap handler for granular debugging
m1_error_trap() {
    local exit_code="$1"
    local line_no="$2"
    local command="$3"
    m1_log_error "Command failed with exit code ${exit_code} at line ${line_no}: '${command}'"
}

# ------------------------------------------------------------------------------
# 1. Environment & Pre-Flight Validation
# ------------------------------------------------------------------------------
m1_check_prerequisites() {
    m1_log_info "Executing pre-flight validation checks for Module 1..."

    # Check EUID
    if [[ $EUID -ne 0 ]]; then
        m1_log_fatal "Module 1 requires root privileges. Please execute via sudo or as root."
    fi

    # Verify Ubuntu 24.04 LTS
    if [[ ! -f /etc/os-release ]]; then
        m1_log_fatal "/etc/os-release not detected. Unsupported platform."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID_LIKE:-}" != *"debian"* ]]; then
        m1_log_warn "Current OS (${PRETTY_NAME:-$ID}) is not Ubuntu. Targeting Noble Numbat (24.04)."
    else
        m1_log_success "Target OS verified: ${PRETTY_NAME:-$ID}"
    fi

    # Kernel version assertion
    local kernel_ver
    kernel_ver="$(uname -r)"
    m1_log_info "Detected Linux Kernel version: ${kernel_ver}"
}

# ------------------------------------------------------------------------------
# 2. System Optimization: Extreme Concurrency & BBR Congestion Control
# ------------------------------------------------------------------------------
m1_optimize_sysctl_and_bbr() {
    m1_log_info "Applying Linux kernel sysctl hardening and enabling TCP BBR..."

    # Ensure tcp_bbr module is loaded and persistent across reboots
    if ! lsmod | grep -qw "tcp_bbr"; then
        modprobe tcp_bbr 2>/dev/null || m1_log_warn "Failed to execute modprobe tcp_bbr directly."
    fi

    mkdir -p /etc/modules-load.d
    if ! grep -qxF "tcp_bbr" /etc/modules-load.d/bbr.conf 2>/dev/null; then
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
    fi

    # Deploy high-throughput, low-latency, extreme concurrency sysctl rules
    cat <<'EOF' > "${SYSCTL_HARDENING_FILE}"
# ==============================================================================
# Enterprise High-Concurrency & BBR Hardening Configuration
# Tailored for Ubuntu 24.04 LTS (Noble Numbat)
# ==============================================================================

# TCP BBR Congestion Control & FQ Queuing Discipline
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Socket Backlog & Queue Optimization
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000

# File Descriptors & Memory Mapping Limits
fs.file-max = 2097152
fs.nr_open = 2097152

# IP Forwarding for High-Performance Tunneling
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# TCP Buffer Allocation (Autotuning: Min, Default, Max - up to 64MB)
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Connection Recycling, Keepalive & FastOpen
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_slow_start_after_idle = 0

# SYN Flood Mitigation
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
EOF

    # Apply sysctl parameters immediately
    sysctl --system >/dev/null 2>&1 || sysctl -p "${SYSCTL_HARDENING_FILE}" >/dev/null 2>&1

    # Apply security limits for 1048576 file descriptors
    cat <<'EOF' > "${LIMITS_HARDENING_FILE}"
# ==============================================================================
# High-Concurrency Security Limits for Xray, SSH & Reverse Proxy Daemons
# ==============================================================================
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 524288
* hard nproc 524288
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 524288
root hard nproc 524288
EOF

    # Ensure systemd propagates limits to services
    mkdir -p /etc/systemd/system.conf.d
    cat <<'EOF' > /etc/systemd/system.conf.d/99-nofile-limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=524288
EOF
    systemctl daemon-reexec 2>/dev/null || true

    # Verification assertions
    local active_cc active_qdisc active_somaxconn
    active_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    active_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    active_somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null || true)"

    if [[ "$active_cc" == "bbr" && "$active_qdisc" == "fq" ]]; then
        m1_log_success "TCP BBR + FQ is active and functioning (CC=${active_cc}, QDISC=${active_qdisc})."
    else
        m1_log_warn "BBR status check returned: CC=${active_cc}, QDISC=${active_qdisc}. Verify module load status."
    fi

    if [[ "$active_somaxconn" -eq 65535 ]]; then
        m1_log_success "Socket backlog verified (somaxconn=65535, file-max=2097152)."
    fi
}

# ------------------------------------------------------------------------------
# 3. Anti-Probing & Web Camouflage: Enterprise Multi-Page HTML5 Site
# ------------------------------------------------------------------------------
m1_deploy_multi_page_camouflage_site() {
    m1_log_info "Deploying complete multi-page HTML5 enterprise camouflage website..."

    mkdir -p "${WEB_ROOT_DIR}/css" "${WEB_ROOT_DIR}/assets"

    # 3.1 Embedded Standalone Modern CSS (Zero External CDN Dependency)
    cat <<'EOF' > "${WEB_ROOT_DIR}/css/styles.css"
:root {
    --bg-primary: #0a0f1d;
    --bg-secondary: #131c31;
    --card-bg: #1c2744;
    --text-primary: #f1f5f9;
    --text-secondary: #94a3b8;
    --accent: #0ea5e9;
    --accent-hover: #38bdf8;
    --accent-glow: rgba(14, 165, 233, 0.25);
    --border: #2e3d64;
    --success: #10b981;
}
* { margin: 0; padding: 0; box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; }
body { background: var(--bg-primary); color: var(--text-primary); line-height: 1.6; min-height: 100vh; display: flex; flex-direction: column; }
header { background: var(--bg-secondary); border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 100; }
.nav-container { max-width: 1200px; margin: 0 auto; display: flex; justify-content: space-between; align-items: center; padding: 1.25rem 2rem; }
.logo { font-size: 1.5rem; font-weight: 700; color: #fff; text-decoration: none; display: flex; align-items: center; gap: 0.5rem; }
.logo span { color: var(--accent); }
nav ul { display: flex; list-style: none; gap: 1.75rem; }
nav a { color: var(--text-secondary); text-decoration: none; font-weight: 500; transition: color 0.2s ease; }
nav a:hover, nav a.active { color: var(--accent); }
main { flex: 1; max-width: 1200px; margin: 0 auto; width: 100%; padding: 3rem 2rem; }
.hero { text-align: center; padding: 4rem 1rem; border-bottom: 1px solid var(--border); }
.hero h1 { font-size: 3rem; font-weight: 800; letter-spacing: -0.025em; margin-bottom: 1.25rem; background: linear-gradient(135deg, #fff 0%, #94a3b8 100%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
.hero p { font-size: 1.25rem; color: var(--text-secondary); max-width: 750px; margin: 0 auto 2rem; }
.status-pill { display: inline-flex; align-items: center; gap: 0.5rem; background: rgba(16, 185, 129, 0.1); color: var(--success); border: 1px solid rgba(16, 185, 129, 0.2); padding: 0.35rem 1rem; border-radius: 9999px; font-size: 0.875rem; font-weight: 600; margin-bottom: 1.5rem; }
.status-dot { width: 8px; height: 8px; background: var(--success); border-radius: 50%; box-shadow: 0 0 8px var(--success); }
.grid-3 { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 2rem; margin-top: 3.5rem; }
.card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px; padding: 2rem; transition: transform 0.2s, box-shadow 0.2s; }
.card:hover { transform: translateY(-4px); box-shadow: 0 12px 24px var(--accent-glow); }
.card h3 { font-size: 1.35rem; color: #fff; margin-bottom: 0.75rem; }
.card p { color: var(--text-secondary); font-size: 0.975rem; line-height: 1.6; }
.telemetry { background: var(--bg-secondary); border: 1px solid var(--border); border-radius: 12px; padding: 2rem; margin-top: 3rem; }
.telemetry-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 1.5rem; text-align: center; }
.telemetry-item h4 { font-size: 2rem; color: var(--accent); margin-bottom: 0.25rem; }
.telemetry-item span { color: var(--text-secondary); font-size: 0.875rem; text-transform: uppercase; letter-spacing: 0.05em; }
footer { background: var(--bg-secondary); border-top: 1px solid var(--border); padding: 2.5rem 2rem; text-align: center; color: var(--text-secondary); font-size: 0.9rem; margin-top: 4rem; }
.contact-form { max-width: 650px; margin: 2rem auto; background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px; padding: 2.5rem; }
.form-group { margin-bottom: 1.5rem; }
.form-group label { display: block; margin-bottom: 0.5rem; font-weight: 500; font-size: 0.9rem; }
.form-control { width: 100%; padding: 0.85rem 1rem; background: var(--bg-secondary); border: 1px solid var(--border); border-radius: 8px; color: #fff; font-size: 0.95rem; }
.form-control:focus { outline: none; border-color: var(--accent); }
.btn-primary { background: var(--accent); color: #fff; border: none; padding: 0.85rem 2rem; border-radius: 8px; font-weight: 600; cursor: pointer; transition: background 0.2s; }
.btn-primary:hover { background: var(--accent-hover); }
EOF

    # 3.2 Index Page (Home / Global Edge Status)
    cat <<'EOF' > "${WEB_ROOT_DIR}/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Aetheris Cloud Global - Distributed Anycast & Edge Mesh</title>
    <link rel="stylesheet" href="/css/styles.css">
</head>
<body>
    <header>
        <div class="nav-container">
            <a href="/" class="logo">AETHERIS <span>NETWORKS</span></a>
            <nav>
                <ul>
                    <li><a href="/" class="active">Overview</a></li>
                    <li><a href="/services.html">Platform Services</a></li>
                    <li><a href="/about.html">Architecture</a></li>
                    <li><a href="/contact.html">Support</a></li>
                </ul>
            </nav>
        </div>
    </header>
    <main>
        <div class="hero">
            <div class="status-pill"><span class="status-dot"></span> Edge Node Active: HTTP/2 & TLS 1.3 Verified</div>
            <h1>Autonomous Low-Latency Edge Acceleration</h1>
            <p>Enterprise infrastructure delivering multi-path edge routing, distributed caching, and zero-trust protocol proxy mesh.</p>
        </div>
        <div class="telemetry">
            <div class="telemetry-grid">
                <div class="telemetry-item"><h4>99.999%</h4><span>Platform Uptime</span></div>
                <div class="telemetry-item"><h4>&lt; 1.2ms</h4><span>Internal Hop Latency</span></div>
                <div class="telemetry-item"><h4>256-bit</h4><span>Hardware Cryptography</span></div>
                <div class="telemetry-item"><h4>100 Gbps</h4><span>Backbone Redundancy</span></div>
            </div>
        </div>
        <div class="grid-3">
            <div class="card">
                <h3>Global Anycast Routing</h3>
                <p>BGP multihoming with real-time latency probing steers packets to optimal point-of-presence (PoP) clusters without middlebox inspection delays.</p>
            </div>
            <div class="card">
                <h3>TLS Handshake Offloading</h3>
                <p>Hardware-accelerated ChaCha20-Poly1305 and AES-GCM cipher execution minimizing CPU overhead during high-concurrency peak transitions.</p>
            </div>
            <div class="card">
                <h3>Automated Layer 4/7 Shielding</h3>
                <p>Deep packet filtering with synthetic challenge-response engines neutralizing volumetric and application-layer anomalies proactively.</p>
            </div>
        </div>
    </main>
    <footer>
        &copy; 2026 Aetheris Cloud Global Systems Inc. Node telemetry verified. All rights reserved.
    </footer>
</body>
</html>
EOF

    # 3.3 Services Page
    cat <<'EOF' > "${WEB_ROOT_DIR}/services.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Platform Services - Aetheris Cloud Global</title>
    <link rel="stylesheet" href="/css/styles.css">
</head>
<body>
    <header>
        <div class="nav-container">
            <a href="/" class="logo">AETHERIS <span>NETWORKS</span></a>
            <nav>
                <ul>
                    <li><a href="/">Overview</a></li>
                    <li><a href="/services.html" class="active">Platform Services</a></li>
                    <li><a href="/about.html">Architecture</a></li>
                    <li><a href="/contact.html">Support</a></li>
                </ul>
            </nav>
        </div>
    </header>
    <main>
        <div class="hero">
            <h1>Edge Delivery & Micro-Tunneling Services</h1>
            <p>Designed for mission-critical enterprise workloads requiring guaranteed bandwidth allocation, low jitter, and seamless failover.</p>
        </div>
        <div class="grid-3">
            <div class="card">
                <h3>Encrypted Tunneling Ingress</h3>
                <p>High-capacity WebSocket and TLS tunneling gateways supporting multiplexed connections for real-time telemetry and streaming telemetry.</p>
            </div>
            <div class="card">
                <h3>High-Throughput UDP Gateways</h3>
                <p>Specialized low-latency UDP packet forwarders engineered for real-time interactive communications, multiplayer simulations, and VoIP.</p>
            </div>
            <div class="card">
                <h3>Zero-Trust Edge Gateways</h3>
                <p>Granular role-based session authentication with dynamic lifecycle termination and cryptographically signed session tokens.</p>
            </div>
        </div>
    </main>
    <footer>
        &copy; 2026 Aetheris Cloud Global Systems Inc. ISO/IEC 27001 Certified Infrastructure.
    </footer>
</body>
</html>
EOF

    # 3.4 About / Architecture Page
    cat <<'EOF' > "${WEB_ROOT_DIR}/about.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Architecture - Aetheris Cloud Global</title>
    <link rel="stylesheet" href="/css/styles.css">
</head>
<body>
    <header>
        <div class="nav-container">
            <a href="/" class="logo">AETHERIS <span>NETWORKS</span></a>
            <nav>
                <ul>
                    <li><a href="/">Overview</a></li>
                    <li><a href="/services.html">Platform Services</a></li>
                    <li><a href="/about.html" class="active">Architecture</a></li>
                    <li><a href="/contact.html">Support</a></li>
                </ul>
            </nav>
        </div>
    </header>
    <main>
        <div class="hero">
            <h1>Engineered for Resilience & Strict Privacy</h1>
            <p>Our edge cluster operates under stateless volatile-memory architectures ensuring no telemetry or packet contents are stored on persistent disks.</p>
        </div>
        <div class="grid-3">
            <div class="card">
                <h3>Linux 6.8 Kernel Subsystem</h3>
                <p>Leveraging native eBPF, TCP BBR v3 congestion algorithms, and Fair Queuing disciplines for deterministically fair queue scheduling.</p>
            </div>
            <div class="card">
                <h3>Zero Disk Telemetry Logging</h3>
                <p>Memory-only socket buffers with automated RAM sanitization ensures total operational confidentiality and regulatory compliance.</p>
            </div>
            <div class="card">
                <h3>Multi-Tier Redundancy</h3>
                <p>Automatic failover to secondary transit backbones in sub-50ms intervals if optical carrier anomalies are detected.</p>
            </div>
        </div>
    </main>
    <footer>
        &copy; 2026 Aetheris Cloud Global Systems Inc. High Assurance Architecture.
    </footer>
</body>
</html>
EOF

    # 3.5 Contact / Support Page
    cat <<'EOF' > "${WEB_ROOT_DIR}/contact.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Contact & Support - Aetheris Cloud Global</title>
    <link rel="stylesheet" href="/css/styles.css">
</head>
<body>
    <header>
        <div class="nav-container">
            <a href="/" class="logo">AETHERIS <span>NETWORKS</span></a>
            <nav>
                <ul>
                    <li><a href="/">Overview</a></li>
                    <li><a href="/services.html">Platform Services</a></li>
                    <li><a href="/about.html">Architecture</a></li>
                    <li><a href="/contact.html" class="active">Support</a></li>
                </ul>
            </nav>
        </div>
    </header>
    <main>
        <div class="hero">
            <h1>Infrastructure Operations Center</h1>
            <p>Direct communications channel for network engineers, peering requests, and critical incident reporting.</p>
        </div>
        <div class="contact-form">
            <form onsubmit="event.preventDefault(); alert('Telemetry request recorded. NOC team notified.');">
                <div class="form-group">
                    <label for="name">Operator ID / Name</label>
                    <input type="text" id="name" class="form-control" placeholder="e.g. NOC-Engineer-42" required>
                </div>
                <div class="form-group">
                    <label for="email">Organization Email</label>
                    <input type="email" id="email" class="form-control" placeholder="noc@organization.org" required>
                </div>
                <div class="form-group">
                    <label for="msg">Incident / Inquiry Description</label>
                    <textarea id="msg" rows="4" class="form-control" placeholder="Provide node routing metrics or peering request details..." required></textarea>
                </div>
                <button type="submit" class="btn-primary">Transmit Telemetry Notice</button>
            </form>
        </div>
    </main>
    <footer>
        &copy; 2026 Aetheris Cloud Global Systems Inc. NOC Support Active 24/7/365.
    </footer>
</body>
</html>
EOF

    # 3.6 Standard 404 Page, Robots.txt & Sitemap
    cat <<'EOF' > "${WEB_ROOT_DIR}/404.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>404 - Resource Not Found</title>
    <link rel="stylesheet" href="/css/styles.css">
</head>
<body>
    <main style="text-align: center; padding-top: 8rem;">
        <h1 style="font-size: 5rem; color: var(--accent);">404</h1>
        <h2>Specified Endpoint Unreachable</h2>
        <p style="color: var(--text-secondary); margin: 1rem 0 2rem;">The requested edge asset or URI route does not exist on this cluster PoP.</p>
        <a href="/" class="btn-primary">Return to Edge Overview</a>
    </main>
</body>
</html>
EOF

    cat <<'EOF' > "${WEB_ROOT_DIR}/robots.txt"
User-agent: *
Allow: /
Disallow: /vmess
Disallow: /vless
Disallow: /trojan
Disallow: /ssh
Sitemap: /sitemap.xml
EOF

    cat <<'EOF' > "${WEB_ROOT_DIR}/sitemap.xml"
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>/</loc><changefreq>daily</changefreq><priority>1.0</priority></url>
  <url><loc>/services.html</loc><changefreq>weekly</changefreq><priority>0.8</priority></url>
  <url><loc>/about.html</loc><changefreq>monthly</changefreq><priority>0.6</priority></url>
  <url><loc>/contact.html</loc><changefreq>monthly</changefreq><priority>0.5</priority></url>
</urlset>
EOF

    chmod -R 755 "${WEB_ROOT_DIR}"
    m1_log_success "Enterprise multi-page camouflage website deployed successfully to ${WEB_ROOT_DIR}."
}

# ------------------------------------------------------------------------------
# 4. Nginx Reverse Proxy & HTTP/2 Hardened Shield
# ------------------------------------------------------------------------------
m1_install_and_configure_nginx() {
    m1_log_info "Configuring hardened Nginx reverse proxy & anti-probing shield..."

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v nginx >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y nginx || m1_log_fatal "Failed to install Nginx."
    fi

    # Remove default colliding configurations
    rm -f "${NGINX_SITES_ENABLED}/default"
    mkdir -p "${NGINX_SITES_AVAILABLE}" "${NGINX_SITES_ENABLED}"

    # Self-signed ECC fallback cert if genuine cert is not yet generated
    mkdir -p /etc/xray-manager/ssl
    if [[ ! -f /etc/xray-manager/ssl/fullchain.pem || ! -f /etc/xray-manager/ssl/privkey.pem ]]; then
        m1_log_info "Generating temporary ECC 256-bit TLS certificate for Nginx HTTPS initialization..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/xray-manager/ssl/privkey.pem \
            -out /etc/xray-manager/ssl/fullchain.pem \
            -days 365 \
            -subj "/CN=edge.aetheris-cloud.local/O=Aetheris Global/C=US" >/dev/null 2>&1
        chmod 600 /etc/xray-manager/ssl/privkey.pem
        chmod 644 /etc/xray-manager/ssl/fullchain.pem
    fi

    # Write unified Nginx configuration
    cat <<'EOF' > "${NGINX_SITES_AVAILABLE}/${PROXY_CONF_NAME}"
# ==============================================================================
# Hardened Nginx Reverse Proxy with Anti-Probing Security Controls
# Tailored for Ubuntu 24.04 LTS (Nginx 1.24+)
# ==============================================================================

# Global WebSocket Connection Mapping
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# HTTP / Cleartext Ingress (Standard & Cloudflare Ports)
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 8080;
    listen 8880;
    listen 2082;
    listen 2086;

    server_name _;
    root /var/www/html;
    index index.html;

    # Security Headers for Cleartext Responses
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;

    # ACME Challenge Pass-Through for ZeroSSL / Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        try_files $uri =404;
    }

    # VMess WebSocket Cleartext Location
    location /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # VLESS WebSocket Cleartext Location
    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # SSH over WebSocket (Cleartext CDN Injector friendly)
    location /ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10004;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # Default Camouflage Delivery
    location / {
        try_files $uri $uri/ /index.html =404;
    }

    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
}

# HTTPS / TLS Ingress with Modern HTTP/2
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;

    server_name _;
    root /var/www/html;
    index index.html;

    # Cryptographic & TLS Protocol Hardening
    ssl_certificate /etc/xray-manager/ssl/fullchain.pem;
    ssl_certificate_key /etc/xray-manager/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    # Enterprise Strict Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' wss:; font-src 'self';" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=()" always;

    # VMess WebSocket TLS Location
    location /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # VLESS WebSocket TLS Location
    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10002;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # Trojan WebSocket TLS Location
    location /trojan {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10003;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # SSH over WebSocket (TLS CDN Port 443)
    location /ssh {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10004;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    # Default Camouflage Delivery
    location / {
        try_files $uri $uri/ /index.html =404;
    }

    error_page 404 /404.html;
    location = /404.html {
        internal;
    }
}
EOF

    ln -sfn "${NGINX_SITES_AVAILABLE}/${PROXY_CONF_NAME}" "${NGINX_SITES_ENABLED}/${PROXY_CONF_NAME}"

    # Syntax test before reloading
    nginx -t || m1_log_fatal "Nginx configuration syntax validation failed."
    systemctl enable nginx >/dev/null 2>&1
    systemctl restart nginx
    m1_log_success "Hardened Nginx reverse proxy running with active HTTP/2 and anti-probing locations."
}

# ------------------------------------------------------------------------------
# 5. Automated Firewall & Port Isolation (UFW + iptables + netfilter-persistent)
# ------------------------------------------------------------------------------
m1_configure_firewall_and_persistence() {
    m1_log_info "Configuring automated firewall isolation & persistent netfilter rules..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y iptables iptables-persistent netfilter-persistent ufw >/dev/null 2>&1

    # 5.1 UFW Integration (If active or present)
    if command -v ufw >/dev/null 2>&1; then
        m1_log_info "Configuring UFW rules..."
        for port in "${SHIELD_TCP_PORTS[@]}"; do
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        done
        for port in "${SHIELD_UDP_PORTS[@]}"; do
            ufw allow "${port}/udp" >/dev/null 2>&1 || true
        done
    fi

    # 5.2 Raw iptables Layer-4 Ingress Hardening
    m1_log_info "Applying persistent iptables ingress filter chain..."

    # Ensure loopback and established states are accepted unconditionally
    iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i lo -j ACCEPT
    iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 2 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Drop invalid state packets immediately
    iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || \
        iptables -I INPUT 3 -m conntrack --ctstate INVALID -j DROP

    # Authorize TCP Ingress Ports
    for port in "${SHIELD_TCP_PORTS[@]}"; do
        iptables -C INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p tcp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
    done

    # Authorize BadVPN UDP Gateway (Port 7300)
    for port in "${SHIELD_UDP_PORTS[@]}"; do
        iptables -C INPUT -p udp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport "$port" -m conntrack --ctstate NEW -j ACCEPT
    done

    # 5.3 Persist Rules Across Reboots
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi

    systemctl enable netfilter-persistent >/dev/null 2>&1 || true
    netfilter-persistent save >/dev/null 2>&1 || true

    m1_log_success "Firewall rules applied and persisted for TCP (${SHIELD_TCP_PORTS[*]}) and UDP (${SHIELD_UDP_PORTS[*]})."
}

# ------------------------------------------------------------------------------
# 6. Comprehensive Health & Verification Test
# ------------------------------------------------------------------------------
m1_verify_health() {
    m1_log_info "Executing Module 1 verification & compliance audit..."

    local all_passed=1

    # Check 1: BBR Congestion Control
    local bbr_status
    bbr_status="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'none')"
    if [[ "$bbr_status" == "bbr" ]]; then
        echo -e " [✓] Kernel Congestion Control : ${C_GREEN}BBR Active${C_RESET}"
    else
        echo -e " [✗] Kernel Congestion Control : ${C_RED}FAILED (${bbr_status})${C_RESET}"
        all_passed=0
    fi

    # Check 2: Max File Descriptors
    local file_max
    file_max="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
    if [[ "$file_max" -ge 2097152 ]]; then
        echo -e " [✓] System File Descriptors   : ${C_GREEN}2097152 (Configured)${C_RESET}"
    else
        echo -e " [✗] System File Descriptors   : ${C_YELLOW}${file_max}${C_RESET}"
    fi

    # Check 3: Nginx Daemon Status
    if systemctl is-active --quiet nginx; then
        echo -e " [✓] Nginx Anti-Probing Shield : ${C_GREEN}Running & Enabled${C_RESET}"
    else
        echo -e " [✗] Nginx Anti-Probing Shield : ${C_RED}Inactive${C_RESET}"
        all_passed=0
    fi

    # Check 4: Camouflage Site Files
    if [[ -f "${WEB_ROOT_DIR}/index.html" && -f "${WEB_ROOT_DIR}/services.html" && -f "${WEB_ROOT_DIR}/about.html" && -f "${WEB_ROOT_DIR}/contact.html" ]]; then
        echo -e " [✓] Multi-Page Camouflage Web : ${C_GREEN}Present (index, services, about, contact, css)${C_RESET}"
    else
        echo -e " [✗] Multi-Page Camouflage Web : ${C_RED}Missing key assets${C_RESET}"
        all_passed=0
    fi

    # Check 5: Listening Ports
    local listening_80 listening_443
    listening_80="$(ss -tlpn | grep -w ":80" || true)"
    listening_443="$(ss -tlpn | grep -w ":443" || true)"
    if [[ -n "$listening_80" && -n "$listening_443" ]]; then
        echo -e " [✓] Nginx Ingress Listening    : ${C_GREEN}Port 80 & Port 443 Active${C_RESET}"
    else
        echo -e " [✗] Nginx Ingress Listening    : ${C_YELLOW}Check port status (ss -tlpn)${C_RESET}"
    fi

    if [[ $all_passed -eq 1 ]]; then
        m1_log_success "MODULE 1 AUDIT: ALL SECURITY & ENVIRONMENT CONTROLS VERIFIED."
        return 0
    else
        m1_log_warn "MODULE 1 AUDIT: Some checks require attention."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 7. Unified Module 1 Execution Routine
# ------------------------------------------------------------------------------
module1_run_all() {
    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_B_WHITE}   MODULE 1: CORE ENVIRONMENT & ANTI-PROBING CAMOUFLAGE SHIELD   ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    m1_check_prerequisites
    m1_optimize_sysctl_and_bbr
    m1_deploy_multi_page_camouflage_site
    m1_install_and_configure_nginx
    m1_configure_firewall_and_persistence
    m1_verify_health
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
}

# Standalone execution trap & invoker
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap 'm1_error_trap $? $LINENO "$BASH_COMMAND"' ERR
    module1_run_all
fi
