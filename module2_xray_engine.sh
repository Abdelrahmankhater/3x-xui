#!/usr/bin/env bash
# ==============================================================================
# MODULE 2: Xray-Core gRPC API & High-Performance Multi-Protocol Engine
# Architecture: Master Network Protocol Architect & Xray-Core Expert
# Target OS   : Ubuntu 24.04 LTS (Noble Numbat)
# Compatibility: Standalone executable OR sourceable module
# ==============================================================================

# Ensure strict execution safety when invoked directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
fi

# ------------------------------------------------------------------------------
# Module Metadata & Paths
# ------------------------------------------------------------------------------
MODULE2_NAME="Xray-Core gRPC API & Multi-Protocol Engine"
MODULE2_VERSION="2.4.0-LTS"
MODULE2_AUTHOR="Master Network Protocol Architect"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONF_DIR}/config.json"
XRAY_ASSET_DIR="/usr/local/share/xray"
XRAY_LOG_DIR="/var/log/xray"
XRAY_SERVICE="/etc/systemd/system/xray.service"

BASE_MGR_DIR="/etc/xray-manager"
DB_FILE="${BASE_MGR_DIR}/users.json"
SSL_DIR="${BASE_MGR_DIR}/ssl"

# Port Architecture
PORT_XRAY_API=10085
PORT_VMESS_WS=10001
PORT_VLESS_WS=10002
PORT_TROJAN_WS=10003
PORT_SSH_WS=10004
PORT_TROJAN_DIRECT=442
PORT_SHADOWSOCKS=8388

# Color Setup
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'; C_CYAN='\033[0;36m'; C_B_RED='\033[1;31m'; C_B_GREEN='\033[1;32m'
else
    C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN='' C_B_RED='' C_B_GREEN=''
fi

m2_log_info()    { echo -e "${C_CYAN}[M2-INFO]${C_RESET} $*"; }
m2_log_success() { echo -e "${C_GREEN}[M2-SUCCESS]${C_RESET} $*"; }
m2_log_warn()    { echo -e "${C_YELLOW}[M2-WARN]${C_RESET} $*"; }
m2_log_error()   { echo -e "${C_RED}[M2-ERROR]${C_RESET} $*" >&2; }
m2_log_fatal()   { echo -e "${C_B_RED}[M2-FATAL]${C_RESET} $*" >&2; exit 1; }

m2_error_trap() {
    local exit_code="$1" line_no="$2" command="$3"
    m2_log_error "Command failed with exit code ${exit_code} at line ${line_no}: '${command}'"
}

# ------------------------------------------------------------------------------
# 1. Environment & Architecture Detection
# ------------------------------------------------------------------------------
m2_check_prerequisites() {
    m2_log_info "Verifying prerequisites for Xray-Core engine deployment..."

    if [[ $EUID -ne 0 ]]; then
        m2_log_fatal "Module 2 requires root privileges (sudo)."
    fi

    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)   XRAY_ARCH="64" ;;
        aarch64|arm64)  XRAY_ARCH="arm64-v8a" ;;
        armv7l|armhf)   XRAY_ARCH="arm32-v7a" ;;
        *)              m2_log_fatal "Unsupported CPU architecture: ${arch}" ;;
    esac

    m2_log_info "Detected Architecture: ${arch} (Package: Xray-linux-${XRAY_ARCH}.zip)"

    # Ensure base dependencies are available
    local missing_pkgs=()
    for pkg in curl wget jq unzip tar openssl lsof; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        m2_log_info "Installing required utility packages: ${missing_pkgs[*]}..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y && apt-get install -y "${missing_pkgs[@]}" || m2_log_fatal "Failed to install missing packages."
    fi

    mkdir -p "${XRAY_CONF_DIR}" "${XRAY_ASSET_DIR}" "${XRAY_LOG_DIR}" "${BASE_MGR_DIR}" "${SSL_DIR}"
    chmod 750 "${XRAY_CONF_DIR}" "${XRAY_LOG_DIR}"
}

# ------------------------------------------------------------------------------
# 2. Automated Binary & Asset Installation
# ------------------------------------------------------------------------------
m2_install_xray_core() {
    m2_log_info "Fetching and installing the latest official Xray-Core binary..."

    local tmp_dir="/tmp/xray-fetch-$$-$(date +%s)"
    mkdir -p "$tmp_dir"

    # Query latest stable release tag
    local release_tag
    release_tag="$(curl -s4L --connect-timeout 5 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name // empty')"
    if [[ -z "$release_tag" || "$release_tag" == "null" ]]; then
        m2_log_warn "GitHub API rate limit hit or offline. Fallback to official script installer."
        if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1; then
            m2_log_success "Xray-Core installed via official installer script."
            m2_configure_systemd_service
            return 0
        else
            m2_log_fatal "Both GitHub direct release and official script failed to download Xray-core."
        fi
    fi

    m2_log_info "Latest stable release detected: ${release_tag}"
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${release_tag}/Xray-linux-${XRAY_ARCH}.zip"

    m2_log_info "Downloading package from: ${download_url}"
    wget -q --show-progress --timeout=15 -O "${tmp_dir}/xray.zip" "$download_url" || m2_log_fatal "Failed to download Xray-core archive."

    unzip -qo "${tmp_dir}/xray.zip" -d "$tmp_dir"

    # Install binary
    install -m 755 "${tmp_dir}/xray" "${XRAY_BIN}"

    # Install GeoIP and GeoSite routing assets
    if [[ -f "${tmp_dir}/geoip.dat" ]]; then
        install -m 644 "${tmp_dir}/geoip.dat" "${XRAY_ASSET_DIR}/geoip.dat"
    fi
    if [[ -f "${tmp_dir}/geosite.dat" ]]; then
        install -m 644 "${tmp_dir}/geosite.dat" "${XRAY_ASSET_DIR}/geosite.dat"
    fi

    rm -rf "$tmp_dir"

    # Verify executable binary
    local installed_version
    installed_version="$(${XRAY_BIN} version 2>/dev/null | head -n1 || echo 'unknown')"
    m2_log_success "Binary installed: ${installed_version}"

    m2_configure_systemd_service
}

m2_configure_systemd_service() {
    m2_log_info "Configuring hardened systemd service unit for Xray-Core..."

    cat <<EOF > "${XRAY_SERVICE}"
[Unit]
Description=Xray Multi-Protocol Routing Core Engine
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=always
RestartSec=3s
RestartPreventExitStatus=23
LimitNPROC=524288
LimitNOFILE=1048576

# Memory & Process Sandboxing
MemoryAccounting=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray.service >/dev/null 2>&1
    m2_log_success "Systemd service configured: ${XRAY_SERVICE}"
}

# ------------------------------------------------------------------------------
# 3. Production JSON Configuration Generation
# ------------------------------------------------------------------------------
m2_generate_xray_config() {
    m2_log_info "Generating production Xray JSON configuration with gRPC Stats API..."

    # Ensure certificate files exist for Direct Trojan TLS (Port 442)
    if [[ ! -f "${SSL_DIR}/fullchain.pem" || ! -f "${SSL_DIR}/privkey.pem" ]]; then
        m2_log_info "Generating self-signed ECC certificate for Port 442 TLS Inbound..."
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout "${SSL_DIR}/privkey.pem" \
            -out "${SSL_DIR}/fullchain.pem" \
            -days 365 \
            -subj "/CN=edge.aetheris-cloud.local/O=Aetheris Core/C=US" >/dev/null 2>&1
        chmod 600 "${SSL_DIR}/privkey.pem"
        chmod 644 "${SSL_DIR}/fullchain.pem"
    fi

    # Read active clients from database if available, otherwise initialize empty
    local vmess_clients="[]"
    local vless_clients="[]"
    local trojan_clients="[]"
    local ss_clients="[]"

    if [[ -f "$DB_FILE" && -s "$DB_FILE" ]]; then
        vmess_clients="$(jq '[.[] | select(.protocol=="vmess" and .status=="active") | {"id": .uuid, "alterId": 0, "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")"
        vless_clients="$(jq '[.[] | select(.protocol=="vless" and .status=="active") | {"id": .uuid, "flow": "", "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")"
        trojan_clients="$(jq '[.[] | select(.protocol=="trojan" and .status=="active") | {"password": .uuid, "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")"
        ss_clients="$(jq '[.[] | select(.protocol=="shadowsocks" and .status=="active") | {"password": .uuid, "email": .username}]' "$DB_FILE" 2>/dev/null || echo "[]")"
    fi

    # Build master configuration file
    cat <<EOF > "${XRAY_CONFIG}"
{
  "log": {
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log",
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
        "statsUserDownlink": true,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
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
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "vmess-ws-in"
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
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "tag": "vless-ws-in"
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
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
      "tag": "ssh-ws-bridge-in"
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
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
      "settings": {
        "domainStrategy": "UseIP"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      },
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "inboundTag": ["ssh-ws-bridge-in"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

    # Validate JSON syntax and structure
    m2_verify_config_syntax
}

# ------------------------------------------------------------------------------
# 4. Strict Configuration Verification & Syntax Assertion
# ------------------------------------------------------------------------------
m2_verify_config_syntax() {
    m2_log_info "Testing Xray configuration validity via 'xray run -test'..."

    if ! jq . "${XRAY_CONFIG}" >/dev/null 2>&1; then
        m2_log_fatal "JSON syntax error in ${XRAY_CONFIG}. Check formatting."
    fi

    if "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" >/dev/null 2>&1; then
        m2_log_success "Xray configuration syntax and schema verified successfully."
    else
        local err_msg
        err_msg="$("${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" 2>&1 || true)"
        m2_log_fatal "Xray engine rejected configuration: ${err_msg}"
    fi
}

# ------------------------------------------------------------------------------
# 5. Service Reload & gRPC API Status Verification
# ------------------------------------------------------------------------------
m2_restart_service() {
    m2_log_info "Restarting Xray service and validating runtime state..."
    systemctl restart xray.service
    sleep 1

    if systemctl is-active --quiet xray.service; then
        m2_log_success "Xray systemd daemon is active and running."
    else
        local journal_log
        journal_log="$(journalctl -u xray.service -n 20 --no-pager 2>/dev/null || true)"
        m2_log_fatal "Xray daemon failed to start. Logs:\n${journal_log}"
    fi
}

m2_verify_api_status() {
    m2_log_info "Probing Xray gRPC Stats API endpoint on 127.0.0.1:${PORT_XRAY_API}..."

    # Check listening socket
    if ! ss -tlpn | grep -q "127.0.0.1:${PORT_XRAY_API}"; then
        m2_log_error "API port 127.0.0.1:${PORT_XRAY_API} is not actively listening."
        return 1
    fi

    # Query Stats API using native xray api CLI
    local api_response
    api_response="$("${XRAY_BIN}" api statsquery --server="127.0.0.1:${PORT_XRAY_API}" 2>&1 || true)"

    if echo "$api_response" | grep -q -E '(stat|value|"stat":)'; then
        m2_log_success "Xray gRPC Stats API responded with valid telemetry payload."
        return 0
    elif echo "$api_response" | grep -q "failed to call"; then
        m2_log_error "API call failed: ${api_response}"
        return 1
    else
        # Empty stats response is acceptable on a fresh instance with zero connected traffic
        m2_log_success "Xray gRPC Stats API is operational and awaiting client connections."
        return 0
    fi
}

# ------------------------------------------------------------------------------
# 6. Real-Time User Telemetry Query Helper
# ------------------------------------------------------------------------------
m2_query_user_stats() {
    local target_email="${1:-}"
    if [[ -z "$target_email" ]]; then
        "${XRAY_BIN}" api statsquery --server="127.0.0.1:${PORT_XRAY_API}" 2>/dev/null || echo "{}"
    else
        local pattern="user>>>${target_email}>>>traffic"
        "${XRAY_BIN}" api statsquery --server="127.0.0.1:${PORT_XRAY_API}" -pattern "$pattern" 2>/dev/null || echo "{}"
    fi
}

# ------------------------------------------------------------------------------
# 7. Comprehensive Health & Socket Audit
# ------------------------------------------------------------------------------
m2_verify_engine_health() {
    m2_log_info "Auditing Xray-Core listening sockets and operational compliance..."

    local expected_ports=(
        "${PORT_XRAY_API}:API(Dokodemo)"
        "${PORT_VMESS_WS}:VMess(WS)"
        "${PORT_VLESS_WS}:VLESS(WS)"
        "${PORT_TROJAN_WS}:Trojan(WS)"
        "${PORT_SSH_WS}:SSH(Dokodemo)"
        "${PORT_TROJAN_DIRECT}:Trojan(DirectTLS)"
        "${PORT_SHADOWSOCKS}:Shadowsocks(AEAD)"
    )

    local audit_passed=1
    for item in "${expected_ports[@]}"; do
        local port="${item%%:*}"
        local desc="${item##*:}"
        if ss -tulpn | grep -qw ":${port}"; then
            echo -e " [✓] Port ${port} (${desc}) : ${C_GREEN}LISTENING${C_RESET}"
        else
            echo -e " [✗] Port ${port} (${desc}) : ${C_RED}NOT DETECTED${C_RESET}"
            audit_passed=0
        fi
    done

    if [[ $audit_passed -eq 1 ]]; then
        m2_log_success "MODULE 2 AUDIT: ALL INBOUNDS & gRPC TELEMETRY FULLY OPERATIONAL."
        return 0
    else
        m2_log_warn "MODULE 2 AUDIT: Some inbounds require operational verification."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 8. Unified Module Execution Routine
# ------------------------------------------------------------------------------
module2_run_all() {
    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}   MODULE 2: XRAY-CORE gRPC API & MULTI-PROTOCOL ENGINE DEPLOYMENT    ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    m2_check_prerequisites
    m2_install_xray_core
    m2_generate_xray_config
    m2_restart_service
    m2_verify_api_status
    m2_verify_engine_health
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
}

# Standalone execution trap & invoker
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap 'm2_error_trap $? $LINENO "$BASH_COMMAND"' ERR
    module2_run_all
fi
