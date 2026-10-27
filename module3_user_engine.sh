#!/usr/bin/env bash
# ==============================================================================
# MODULE 3: Real-Time User, Expiration, Bandwidth & gRPC Multi-Device Limiter
# Architecture: Enterprise Linux Software Architect & Backend Automation
# Target OS   : Ubuntu 24.04 LTS (Noble Numbat)
# Optimization: gRPC In-Memory Device Revocation & Atomic Database Safety
# Compatibility: Standalone executable OR sourceable module
# ==============================================================================

# Ensure strict execution safety when invoked directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
fi

# ------------------------------------------------------------------------------
# Module Constants & Paths
# ------------------------------------------------------------------------------
MODULE3_NAME="User Lifecycle, Bandwidth & gRPC Multi-Device Limiter"
MODULE3_VERSION="3.0.0-PROD"
MODULE3_AUTHOR="Enterprise Linux Software Architect"

BASE_DIR="/etc/xray-manager"
DB_FILE="${BASE_DIR}/users.json"
CONFIG_ENV="${BASE_DIR}/config.env"
CRON_SYNC_FILE="/etc/cron.hourly/xray-quota-sync"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_ACCESS_LOG="/var/log/xray/access.log"
PORT_XRAY_API=10085

DEVICE_LIMITER_SCRIPT="/usr/local/bin/xray-device-limiter.sh"
DEVICE_LIMITER_SERVICE="/etc/systemd/system/xray-device-limiter.service"
DEVICE_LIMITER_LOG="/var/log/xray-device-limiter.log"

# Terminal Color Palette
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'; C_MAGENTA='\033[0;35m'; C_CYAN='\033[0;36m'
    C_B_RED='\033[1;31m'; C_B_GREEN='\033[1;32m'; C_B_YELLOW='\033[1;33m'; C_B_CYAN='\033[1;36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_MAGENTA='' C_CYAN='' C_B_RED='' C_B_GREEN='' C_B_YELLOW='' C_B_CYAN=''
fi

m3_log_info()    { echo -e "${C_CYAN}[M3-INFO]${C_RESET} $*"; }
m3_log_success() { echo -e "${C_GREEN}[M3-SUCCESS]${C_RESET} $*"; }
m3_log_warn()    { echo -e "${C_YELLOW}[M3-WARN]${C_RESET} $*"; }
m3_log_error()   { echo -e "${C_RED}[M3-ERROR]${C_RESET} $*" >&2; }
m3_log_fatal()   { echo -e "${C_B_RED}[M3-FATAL]${C_RESET} $*" >&2; exit 1; }

m3_error_trap() {
    local exit_code="$1" line_no="$2" command="$3"
    m3_log_error "Command failed with exit code ${exit_code} at line ${line_no}: '${command}'"
}

# ------------------------------------------------------------------------------
# 1. Environment & Database Initialization
# ------------------------------------------------------------------------------
m3_init_environment() {
    mkdir -p "${BASE_DIR}" "/var/log/xray"
    chmod 700 "${BASE_DIR}"

    if [[ ! -f "$DB_FILE" || ! -s "$DB_FILE" ]]; then
        echo "[]" > "${DB_FILE}.tmp"
        chmod 600 "${DB_FILE}.tmp"
        mv -f "${DB_FILE}.tmp" "$DB_FILE"
        m3_log_info "Initialized empty user database at ${DB_FILE}."
    fi

    if [[ -f "$CONFIG_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_ENV"
    fi

    if [[ -z "${SERVER_DOMAIN:-}" ]]; then
        SERVER_DOMAIN="$(curl -s4 --max-time 2 https://api.ipify.org 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')"
        SERVER_DOMAIN="${SERVER_DOMAIN:-127.0.0.1}.nip.io"
    fi

    for tool in jq qrencode openssl awk; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y && apt-get install -y "$tool" >/dev/null 2>&1 || m3_log_fatal "Failed to install ${tool}."
        fi
    done
}

# ------------------------------------------------------------------------------
# 2. Atomic Database Operations (Lock-Free Write Safety)
# ------------------------------------------------------------------------------
m3_atomic_write_db() {
    local json_payload="$1"
    if ! echo "$json_payload" | jq . >/dev/null 2>&1; then
        m3_log_error "Corrupted JSON payload passed to m3_atomic_write_db. Write aborted."
        return 1
    fi

    local tmp_file="${DB_FILE}.tmp.$$"
    echo "$json_payload" | jq . > "$tmp_file"
    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$DB_FILE"
}

m3_generate_credential() {
    local proto="$1"
    if [[ "$proto" == "vmess" || "$proto" == "vless" ]]; then
        if command -v xray >/dev/null 2>&1; then
            xray uuid
        elif command -v uuidgen >/dev/null 2>&1; then
            uuidgen
        else
            openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
        fi
    else
        openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16
    fi
}

# ------------------------------------------------------------------------------
# 3. Synchronize Database with Xray Active Inbound Configuration
# ------------------------------------------------------------------------------
m3_sync_xray_core_clients() {
    m3_log_info "Synchronizing active database credentials into Xray configuration..."

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        m3_log_warn "Xray configuration (${XRAY_CONFIG}) not found. Skipping config sync."
        return 0
    fi

    local vmess_active vless_active trojan_active ss_active
    vmess_active="$(jq '[.[] | select(.protocol=="vmess" and .status=="active") | {"id": .uuid, "alterId": 0, "email": .username}]' "$DB_FILE")"
    vless_active="$(jq '[.[] | select(.protocol=="vless" and .status=="active") | {"id": .uuid, "flow": "", "email": .username}]' "$DB_FILE")"
    trojan_active="$(jq '[.[] | select(.protocol=="trojan" and .status=="active") | {"password": .uuid, "email": .username}]' "$DB_FILE")"
    ss_active="$(jq '[.[] | select(.protocol=="shadowsocks" and .status=="active") | {"password": .uuid, "email": .username}]' "$DB_FILE")"

    local updated_conf
    updated_conf="$(jq \
        --argjson vmess "$vmess_active" \
        --argjson vless "$vless_active" \
        --argjson trojan "$trojan_active" \
        --argjson ss "$ss_active" \
        '
        (.inbounds[] | select(.tag=="vmess-ws-in").settings.clients) = $vmess |
        (.inbounds[] | select(.tag=="vless-ws-in").settings.clients) = $vless |
        (.inbounds[] | select(.tag=="trojan-ws-in").settings.clients) = $trojan |
        (.inbounds[] | select(.tag=="trojan-direct-in").settings.clients) = $trojan |
        (.inbounds[] | select(.tag=="ss-in").settings.clients) = $ss
        ' "$XRAY_CONFIG")"

    local tmp_conf="${XRAY_CONFIG}.tmp.$$"
    echo "$updated_conf" > "$tmp_conf"

    if "${XRAY_BIN}" run -test -config "$tmp_conf" >/dev/null 2>&1; then
        mv -f "$tmp_conf" "$XRAY_CONFIG"
        systemctl reload xray.service 2>/dev/null || systemctl restart xray.service 2>/dev/null || true
        m3_log_success "Xray inbounds updated and service reloaded."
    else
        rm -f "$tmp_conf"
        m3_log_error "Generated config failed Xray schema test. Reverting changes."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 4. User Lifecycle Management (CRUD)
# ------------------------------------------------------------------------------
m3_add_user() {
    m3_init_environment

    local username="${1:-}"
    local protocol="${2:-}"
    local days="${3:-}"
    local quota_gb="${4:-}"
    local max_devices="${5:-}"
    local credential="${6:-}"

    if [[ -z "$protocol" ]]; then
        clear
        echo -e "${C_B_CYAN}====================================================${C_RESET}"
        echo -e "${C_BOLD}             ADD USER - PROTOCOL SELECTION          ${C_RESET}"
        echo -e "${C_B_CYAN}====================================================${C_RESET}"
        echo -e " [1] VMess (WebSocket + TLS & Plain HTTP CDN)"
        echo -e " [2] VLESS (WebSocket + TLS & Plain HTTP CDN)"
        echo -e " [3] Trojan (WebSocket + TLS & Direct Port 442)"
        echo -e " [4] Shadowsocks (AEAD aes-256-gcm Port 8388)"
        echo -e " [0] Cancel"
        echo -e "${C_B_CYAN}----------------------------------------------------${C_RESET}"
        read -rp "Select Protocol [1-4]: " p_choice
        case "$p_choice" in
            1) protocol="vmess" ;;
            2) protocol="vless" ;;
            3) protocol="trojan" ;;
            4) protocol="shadowsocks" ;;
            *) m3_log_warn "Operation cancelled."; return ;;
        esac
    fi

    while [[ -z "$username" ]]; do
        read -rp "Enter Username (alphanumeric, no spaces): " username
        if [[ ! "$username" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            m3_log_error "Username must only contain letters, numbers, dashes, and underscores."
            username=""
        elif jq -e --arg u "$username" '.[] | select(.username == $u)' "$DB_FILE" >/dev/null 2>&1; then
            m3_log_error "User '${username}' already exists in the database."
            username=""
        fi
    done

    while [[ -z "$days" || ! "$days" =~ ^[0-9]+$ || "$days" -le 0 ]]; do
        read -rp "Enter Validity in Days (e.g. 30): " days
    done

    if [[ -z "$quota_gb" || ! "$quota_gb" =~ ^[0-9]+$ ]]; then
        read -rp "Enter Bandwidth Quota in GB [0 = Unlimited]: " quota_gb
        [[ ! "$quota_gb" =~ ^[0-9]+$ ]] && quota_gb=0
    fi

    if [[ -z "$max_devices" || ! "$max_devices" =~ ^[0-9]+$ || "$max_devices" -le 0 ]]; then
        read -rp "Max Allowed Concurrent IP Devices [Default: 2]: " max_devices
        [[ ! "$max_devices" =~ ^[0-9]+$ || "$max_devices" -le 0 ]] && max_devices=2
    fi

    if [[ -z "$credential" ]]; then
        credential="$(m3_generate_credential "$protocol")"
    fi

    local created_at expire_date
    created_at="$(date +%Y-%m-%d)"
    expire_date="$(date -d "+${days} days" +%Y-%m-%d)"

    local updated_json
    updated_json="$(jq \
        --arg u "$username" \
        --arg p "$protocol" \
        --arg c "$credential" \
        --arg ca "$created_at" \
        --arg ed "$expire_date" \
        --arg q "$quota_gb" \
        --arg md "$max_devices" \
        '. += [{
            "username": $u,
            "uuid": $c,
            "protocol": $p,
            "created_at": $ca,
            "expire_date": $ed,
            "quota_gb": ($q | tonumber),
            "max_devices": ($md | tonumber),
            "used_bytes": 0,
            "status": "active"
        }]' "$DB_FILE")"

    m3_atomic_write_db "$updated_json"
    m3_sync_xray_core_clients

    m3_log_success "Account [${username}] (${protocol^^}) successfully provisioned until ${expire_date} (Max Devices: ${max_devices})."
    m3_show_uris_and_qr "$username"
}

m3_delete_user() {
    m3_init_environment
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        clear
        echo -e "${C_B_RED}====================================================${C_RESET}"
        echo -e "${C_BOLD}                 PURGE USER ACCOUNT                 ${C_RESET}"
        echo -e "${C_B_RED}====================================================${C_RESET}"
        local count
        count="$(jq '. | length' "$DB_FILE")"
        if [[ "$count" -eq 0 ]]; then
            m3_log_warn "No accounts registered in database."
            return
        fi

        jq -r 'to_entries[] | " [\(.key + 1)] \(.value.username) (\(.value.protocol)) - Status: \(.value.status)"' "$DB_FILE"
        echo -e "${C_B_RED}----------------------------------------------------${C_RESET}"
        read -rp "Enter Username or Index to remove: " target
    fi

    local target_user=""
    local count
    count="$(jq '. | length' "$DB_FILE")"
    if [[ "$target" =~ ^[0-9]+$ ]] && [[ "$target" -ge 1 && "$target" -le "$count" ]]; then
        local idx=$((target - 1))
        target_user="$(jq -r ".[$idx].username" "$DB_FILE")"
    else
        target_user="$target"
    fi

    if ! jq -e --arg u "$target_user" '.[] | select(.username == $u)' "$DB_FILE" >/dev/null 2>&1; then
        m3_log_error "User '${target_user}' does not exist in database."
        return 1
    fi

    local updated_json
    updated_json="$(jq --arg u "$target_user" 'del(.[] | select(.username == $u))' "$DB_FILE")"
    m3_atomic_write_db "$updated_json"
    m3_sync_xray_core_clients

    m3_log_success "User [${target_user}] has been permanently purged."
}

m3_renew_user() {
    m3_init_environment
    local target="${1:-}"
    local add_days="${2:-}"

    if [[ -z "$target" ]]; then
        clear
        echo -e "${C_B_GREEN}====================================================${C_RESET}"
        echo -e "${C_BOLD}             RENEW / EXTEND ACCOUNT VALIDITY        ${C_RESET}"
        echo -e "${C_B_GREEN}====================================================${C_RESET}"
        jq -r 'to_entries[] | " [\(.key + 1)] \(.value.username) (\(.value.protocol)) - Expires: \(.value.expire_date) [\(.value.status)]"' "$DB_FILE"
        echo -e "${C_B_GREEN}----------------------------------------------------${C_RESET}"
        read -rp "Enter Username or Index: " target
    fi

    local target_user=""
    local count
    count="$(jq '. | length' "$DB_FILE")"
    if [[ "$target" =~ ^[0-9]+$ ]] && [[ "$target" -ge 1 && "$target" -le "$count" ]]; then
        local idx=$((target - 1))
        target_user="$(jq -r ".[$idx].username" "$DB_FILE")"
    else
        target_user="$target"
    fi

    if ! jq -e --arg u "$target_user" '.[] | select(.username == $u)' "$DB_FILE" >/dev/null 2>&1; then
        m3_log_error "User '${target_user}' not found."
        return 1
    fi

    while [[ -z "$add_days" || ! "$add_days" =~ ^[0-9]+$ || "$add_days" -le 0 ]]; do
        read -rp "Enter additional days to add: " add_days
    done

    local current_expire today base_date new_expire
    current_expire="$(jq -r --arg u "$target_user" '.[] | select(.username == $u) | .expire_date' "$DB_FILE")"
    today="$(date +%Y-%m-%d)"

    if [[ "$current_expire" < "$today" ]]; then
        base_date="$today"
    else
        base_date="$current_expire"
    fi
    new_expire="$(date -d "${base_date} + ${add_days} days" +%Y-%m-%d)"

    local updated_json
    updated_json="$(jq --arg u "$target_user" --arg ed "$new_expire" \
        'map(if .username == $u then .expire_date = $ed | .status = "active" else . end)' "$DB_FILE")"

    m3_atomic_write_db "$updated_json"
    m3_sync_xray_core_clients

    m3_log_success "Account [${target_user}] extended until ${new_expire}."
}

m3_list_users() {
    m3_init_environment
    clear
    echo -e "${C_B_CYAN}================================================================================================${C_RESET}"
    echo -e "${C_BOLD}                            REGISTERED CLIENT ACCOUNTS & USAGE                                  ${C_RESET}"
    echo -e "${C_B_CYAN}================================================================================================${C_RESET}"
    printf "%-4s | %-16s | %-11s | %-11s | %-9s | %-9s | %-9s | %-10s | %-8s\n" \
        "ID" "Username" "Protocol" "Expires" "Days Left" "Max Dev" "Quota" "Used" "Status"
    echo -e "${C_CYAN}------------------------------------------------------------------------------------------------${C_RESET}"

    local count
    count="$(jq '. | length' "$DB_FILE")"
    if [[ "$count" -eq 0 ]]; then
        echo " No accounts registered in database."
    else
        local today_sec
        today_sec="$(date +%s)"
        for ((i=0; i<count; i++)); do
            local u proto exp q used status md
            u="$(jq -r ".[$i].username" "$DB_FILE")"
            proto="$(jq -r ".[$i].protocol" "$DB_FILE")"
            exp="$(jq -r ".[$i].expire_date" "$DB_FILE")"
            q="$(jq -r ".[$i].quota_gb" "$DB_FILE")"
            md="$(jq -r ".[$i].max_devices // 2" "$DB_FILE")"
            used="$(jq -r ".[$i].used_bytes" "$DB_FILE")"
            status="$(jq -r ".[$i].status" "$DB_FILE")"

            local used_str
            if (( used >= 1073741824 )); then
                used_str="$(awk -v u="$used" 'BEGIN { printf "%.2f GB", u / 1073741824 }')"
            else
                used_str="$(awk -v u="$used" 'BEGIN { printf "%.1f MB", u / 1048576 }')"
            fi

            local exp_sec diff_days
            exp_sec="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
            diff_days=$(( (exp_sec - today_sec) / 86400 ))
            [[ $diff_days -lt 0 ]] && diff_days=0

            local status_color="$C_GREEN"
            if [[ "$status" == "expired" ]]; then
                status_color="$C_RED"
            elif [[ "$status" == "quota_exceeded" || "$status" == "device_limited" ]]; then
                status_color="$C_YELLOW"
            fi

            local quota_str="${q} GB"
            [[ "$q" -eq 0 ]] && quota_str="Unlimited"

            printf "%-4s | %-16s | %-11s | %-11s | %-9s | %-9s | %-9s | %-10s | ${status_color}%-8s${C_RESET}\n" \
                "$((i+1))" "$u" "$proto" "$exp" "${diff_days}d" "${md} IP" "$quota_str" "$used_str" "$status"
        done
    fi
    echo -e "${C_B_CYAN}================================================================================================${C_RESET}"
}

# ------------------------------------------------------------------------------
# 5. URI & Terminal QR Code Generation
# ------------------------------------------------------------------------------
m3_show_uris_and_qr() {
    m3_init_environment
    local username="${1:-}"

    if [[ -z "$username" ]]; then
        read -rp "Enter username to generate connection links: " username
    fi

    local user_record
    user_record="$(jq -r --arg u "$username" '.[] | select(.username == $u)' "$DB_FILE")"
    if [[ -z "$user_record" ]]; then
        m3_log_error "User '${username}' not found."
        return 1
    fi

    local proto credential expiry quota max_dev
    proto="$(echo "$user_record" | jq -r .protocol)"
    credential="$(echo "$user_record" | jq -r .uuid)"
    expiry="$(echo "$user_record" | jq -r .expire_date)"
    quota="$(echo "$user_record" | jq -r .quota_gb)"
    max_dev="$(echo "$user_record" | jq -r '.max_devices // 2')"

    clear
    echo -e "${C_B_YELLOW}======================================================================${C_RESET}"
    echo -e "${C_BOLD}                     CLIENT CONNECTION PROFILE                        ${C_RESET}"
    echo -e "${C_B_YELLOW}======================================================================${C_RESET}"
    echo -e " ${C_BOLD}Username   :${C_RESET} ${username}"
    echo -e " ${C_BOLD}Protocol   :${C_RESET} ${proto^^}"
    echo -e " ${C_BOLD}Domain/Host:${C_RESET} ${SERVER_DOMAIN}"
    echo -e " ${C_BOLD}Expires On :${C_RESET} ${expiry}"
    echo -e " ${C_BOLD}Quota Limit:${C_RESET} ${quota} GB"
    echo -e " ${C_BOLD}Max Devices:${C_RESET} ${max_dev} distinct client IP(s)"
    echo -e "${C_B_YELLOW}----------------------------------------------------------------------${C_RESET}"

    case "$proto" in
        vmess)
            local vmess_tls_json vmess_tls_uri vmess_http_json vmess_http_uri
            vmess_tls_json="$(jq -c -n \
                --arg ps "${username}-TLS" \
                --arg add "${SERVER_DOMAIN}" \
                --arg port "443" \
                --arg id "${credential}" \
                --arg host "${SERVER_DOMAIN}" \
                --arg sni "${SERVER_DOMAIN}" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:"ws", type:"none", host:$host, path:"/vmess", tls:"tls", sni:$sni}')"
            vmess_tls_uri="vmess://$(echo -n "$vmess_tls_json" | base64 | tr -d '\n')"

            vmess_http_json="$(jq -c -n \
                --arg ps "${username}-HTTP" \
                --arg add "${SERVER_DOMAIN}" \
                --arg port "80" \
                --arg id "${credential}" \
                --arg host "${SERVER_DOMAIN}" \
                '{v:"2", ps:$ps, add:$add, port:$port, id:$id, aid:"0", scy:"auto", net:"ws", type:"none", host:$host, path:"/vmess", tls:"none"}')"
            vmess_http_uri="vmess://$(echo -n "$vmess_http_json" | base64 | tr -d '\n')"

            echo -e "${C_CYAN}[1] VMess WebSocket + TLS (Port 443):${C_RESET}"
            echo -e "${C_DIM}${vmess_tls_uri}${C_RESET}\n"
            echo -e "${C_CYAN}[2] VMess WebSocket + Plain HTTP (Port 80, 8080 CDN):${C_RESET}"
            echo -e "${C_DIM}${vmess_http_uri}${C_RESET}\n"

            echo -e "${C_BOLD}Terminal QR Code (VMess TLS):${C_RESET}"
            qrencode -t ANSIUTF8 "${vmess_tls_uri}"
            ;;

        vless)
            local vless_tls_uri vless_http_uri
            vless_tls_uri="vless://${credential}@${SERVER_DOMAIN}:443?path=%2Fvless&security=tls&encryption=none&type=ws&host=${SERVER_DOMAIN}&sni=${SERVER_DOMAIN}#${username}-TLS"
            vless_http_uri="vless://${credential}@${SERVER_DOMAIN}:80?path=%2Fvless&security=none&encryption=none&type=ws&host=${SERVER_DOMAIN}#${username}-HTTP"

            echo -e "${C_CYAN}[1] VLESS WebSocket + TLS (Port 443):${C_RESET}"
            echo -e "${C_DIM}${vless_tls_uri}${C_RESET}\n"
            echo -e "${C_CYAN}[2] VLESS WebSocket + Plain HTTP (Port 80, 8080 CDN):${C_RESET}"
            echo -e "${C_DIM}${vless_http_uri}${C_RESET}\n"

            echo -e "${C_BOLD}Terminal QR Code (VLESS TLS):${C_RESET}"
            qrencode -t ANSIUTF8 "${vless_tls_uri}"
            ;;

        trojan)
            local trojan_ws_uri trojan_direct_uri
            trojan_ws_uri="trojan://${credential}@${SERVER_DOMAIN}:443?path=%2Ftrojan&security=tls&type=ws&host=${SERVER_DOMAIN}&sni=${SERVER_DOMAIN}#${username}-WS"
            trojan_direct_uri="trojan://${credential}@${SERVER_DOMAIN}:442?security=tls&headerType=none&type=tcp&sni=${SERVER_DOMAIN}#${username}-Direct"

            echo -e "${C_CYAN}[1] Trojan WebSocket + TLS (Port 443):${C_RESET}"
            echo -e "${C_DIM}${trojan_ws_uri}${C_RESET}\n"
            echo -e "${C_CYAN}[2] Trojan Direct TLS (Port 442):${C_RESET}"
            echo -e "${C_DIM}${trojan_direct_uri}${C_RESET}\n"

            echo -e "${C_BOLD}Terminal QR Code (Trojan WS):${C_RESET}"
            qrencode -t ANSIUTF8 "${trojan_ws_uri}"
            ;;

        shadowsocks)
            local ss_plain ss_base64 ss_uri
            ss_plain="aes-256-gcm:${credential}"
            ss_base64="$(echo -n "$ss_plain" | base64 | tr -d '\n')"
            ss_uri="ss://${ss_base64}@${SERVER_DOMAIN}:8388#${username}"

            echo -e "${C_CYAN}Shadowsocks AEAD (aes-256-gcm, Port 8388):${C_RESET}"
            echo -e "${C_DIM}${ss_uri}${C_RESET}\n"

            echo -e "${C_BOLD}Terminal QR Code (Shadowsocks):${C_RESET}"
            qrencode -t ANSIUTF8 "${ss_uri}"
            ;;
    esac
    echo -e "${C_B_YELLOW}======================================================================${C_RESET}"
}

# ------------------------------------------------------------------------------
# 6. Real-Time gRPC Stats Ingestion & Automated Locking Engine
# ------------------------------------------------------------------------------
m3_sync_usage_and_lock() {
    m3_init_environment
    m3_log_info "Executing gRPC stats ingestion & account enforcement cycle..."

    local users_count
    users_count="$(jq '. | length' "$DB_FILE")"
    [[ "$users_count" -eq 0 ]] && return 0

    local api_dump
    api_dump="$("${XRAY_BIN}" api statsquery --server="127.0.0.1:${PORT_XRAY_API}" 2>/dev/null || echo '{}')"

    local today state_changed=0
    today="$(date +%Y-%m-%d)"

    for ((i=0; i<users_count; i++)); do
        local user proto exp quota_gb current_used current_status
        user="$(jq -r ".[$i].username" "$DB_FILE")"
        proto="$(jq -r ".[$i].protocol" "$DB_FILE")"
        exp="$(jq -r ".[$i].expire_date" "$DB_FILE")"
        quota_gb="$(jq -r ".[$i].quota_gb" "$DB_FILE")"
        current_used="$(jq -r ".[$i].used_bytes" "$DB_FILE")"
        current_status="$(jq -r ".[$i].status" "$DB_FILE")"

        local uplink downlink new_traffic total_used
        uplink="$(echo "$api_dump" | jq -r --arg u "$user" '.stat[]? | select(.name == ("user>>>" + $u + ">>>traffic>>>uplink")) | .value // 0' | head -n1)"
        downlink="$(echo "$api_dump" | jq -r --arg u "$user" '.stat[]? | select(.name == ("user>>>" + $u + ">>>traffic>>>downlink")) | .value // 0' | head -n1)"
        
        [[ -z "$uplink" || "$uplink" == "null" ]] && uplink=0
        [[ -z "$downlink" || "$downlink" == "null" ]] && downlink=0
        new_traffic=$(( uplink + downlink ))
        total_used=$(( current_used + new_traffic ))

        local new_status="$current_status"

        if [[ "$exp" < "$today" ]]; then
            new_status="expired"
        elif (( quota_gb > 0 )); then
            local max_bytes
            max_bytes="$(awk -v q="$quota_gb" 'BEGIN { printf "%.0f", q * 1073741824 }')"
            if (( total_used >= max_bytes )); then
                new_status="quota_exceeded"
            fi
        fi

        if [[ "$new_status" != "$current_status" ]]; then
            m3_log_warn "Account [${user}] state change: [${current_status}] -> [${new_status}]."
            state_changed=1
        fi

        local step_json
        step_json="$(jq --arg u "$user" --arg tu "$total_used" --arg ns "$new_status" \
            'map(if .username == $u then .used_bytes = ($tu | tonumber) | .status = $ns else . end)' "$DB_FILE")"
        m3_atomic_write_db "$step_json"
    done

    "${XRAY_BIN}" api statsquery --server="127.0.0.1:${PORT_XRAY_API}" -reset=true >/dev/null 2>&1 || true

    if [[ $state_changed -eq 1 ]]; then
        m3_sync_xray_core_clients
    fi

    m3_log_success "Usage ingestion completed. Database synchronized."
}

# ------------------------------------------------------------------------------
# 7. Xray gRPC Multi-Device Connection Limiter Watchdog
# ------------------------------------------------------------------------------
m3_install_device_limiter_daemon() {
    m3_log_info "Deploying active gRPC multi-device connection limiter watchdog..."

    cat <<'EOF' > "$DEVICE_LIMITER_SCRIPT"
#!/usr/bin/env bash
# ==============================================================================
# Xray Multi-Device Active Connection Limiter & gRPC In-Memory Revocation
# Inspects active client IP concurrency and enforces device limits dynamically
# ==============================================================================
set -Eeuo pipefail

DB_FILE="/etc/xray-manager/users.json"
ACCESS_LOG="/var/log/xray/access.log"
LIMIT_LOG="/var/log/xray-device-limiter.log"
XRAY_BIN="/usr/local/bin/xray"
API_PORT=10085
POLL_INTERVAL=10

mkdir -p /var/log /etc/xray-manager

while true; do
    if [[ -f "$DB_FILE" && -f "$ACCESS_LOG" ]]; then
        # Sample recent connections in the last 60 seconds (tail last 500 lines)
        declare -A ip_counts=()
        declare -A revoked_state=()

        # Extract: Client IP and Email from Xray access log format:
        # e.g.: 2026/10/26 02:40:00 203.0.113.19:54321 accepted tcp:1.1.1.1:443 [vmess-ws-in -> direct] email: client01
        while read -r ip user; do
            [[ -z "$ip" || -z "$user" ]] && continue
            ip_counts["${user}###${ip}"]=1
        done < <(tail -n 500 "$ACCESS_LOG" 2>/dev/null | awk '/email:/ { for(i=1;i<=NF;i++) if($i=="email:") user=$(i+1); split($3,a,":"); if(user!="" && a[1]!="") print a[1], user }' || true)

        # Count unique IPs per user
        declare -A user_unique_ips=()
        for key in "${!ip_counts[@]}"; do
            u="${key%%###*}"
            user_unique_ips["$u"]=$(( ${user_unique_ips["$u"]:-0} + 1 ))
        done

        # Enforce limits against database
        users_count="$(jq '. | length' "$DB_FILE" 2>/dev/null || echo 0)"
        for ((i=0; i<users_count; i++)); do
            username="$(jq -r ".[$i].username" "$DB_FILE" 2>/dev/null || true)"
            max_dev="$(jq -r ".[$i].max_devices // 2" "$DB_FILE" 2>/dev/null || echo 2)"
            proto="$(jq -r ".[$i].protocol" "$DB_FILE" 2>/dev/null || echo "")"
            status="$(jq -r ".[$i].status" "$DB_FILE" 2>/dev/null || echo "active")"

            [[ -z "$username" || "$status" != "active" ]] && continue

            active_ips="${user_unique_ips["$username"]:-0}"

            if (( active_ips > max_dev )); then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] MULTI-DEVICE VIOLATION: ${username} has ${active_ips} active IPs (Allowed: ${max_dev}). Revoking via gRPC API..." >> "$LIMIT_LOG"

                # In-memory revocation via gRPC API without dropping other connections
                case "$proto" in
                    vmess)
                        "${XRAY_BIN}" api removeuser --server="127.0.0.1:${API_PORT}" -inboundTag="vmess-ws-in" -email="$username" >/dev/null 2>&1 || true
                        ;;
                    vless)
                        "${XRAY_BIN}" api removeuser --server="127.0.0.1:${API_PORT}" -inboundTag="vless-ws-in" -email="$username" >/dev/null 2>&1 || true
                        ;;
                    trojan)
                        "${XRAY_BIN}" api removeuser --server="127.0.0.1:${API_PORT}" -inboundTag="trojan-ws-in" -email="$username" >/dev/null 2>&1 || true
                        "${XRAY_BIN}" api removeuser --server="127.0.0.1:${API_PORT}" -inboundTag="trojan-direct-in" -email="$username" >/dev/null 2>&1 || true
                        ;;
                esac
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] User ${username} evicted from gRPC inbound session pool." >> "$LIMIT_LOG"
            fi
        done
    fi
    sleep "$POLL_INTERVAL"
done
EOF

    chmod +x "$DEVICE_LIMITER_SCRIPT"

    cat <<EOF > "$DEVICE_LIMITER_SERVICE"
[Unit]
Description=Xray Multi-Device Connection Limiter & gRPC Eviction Watchdog
Documentation=https://github.com/xtls/xray-core
After=network.target xray.service

[Service]
Type=simple
User=root
ExecStart=${DEVICE_LIMITER_SCRIPT}
Restart=always
RestartSec=5s
LimitNOFILE=65535
MemoryAccounting=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-device-limiter.service >/dev/null 2>&1
    systemctl restart xray-device-limiter.service
    m3_log_success "Xray Multi-Device Limiter daemon active: ${DEVICE_LIMITER_SERVICE}"
}

# ------------------------------------------------------------------------------
# 8. Background Hourly Daemon Installation
# ------------------------------------------------------------------------------
m3_install_cron_daemon() {
    m3_log_info "Installing automated hourly quota and expiration enforcement cron daemon..."

    cat <<EOF > "$CRON_SYNC_FILE"
#!/usr/bin/env bash
# Managed by Xray Manager Module 3
/usr/local/bin/xray-user-engine --sync >/dev/null 2>&1
EOF
    chmod +x "$CRON_SYNC_FILE"
    m3_log_success "Cron daemon active: ${CRON_SYNC_FILE}"
}

# ------------------------------------------------------------------------------
# 9. Unified Module Execution Routine
# ------------------------------------------------------------------------------
module3_run_all() {
    m3_init_environment
    while true; do
        clear
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        echo -e "${C_BOLD}       MODULE 3: USER LIFECYCLE & BANDWIDTH TELEMETRY ENGINE          ${C_RESET}"
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        echo -e " [1] Add New Proxy Account (VMess, VLESS, Trojan, Shadowsocks)"
        echo -e " [2] Delete Existing Proxy Account"
        echo -e " [3] Renew / Extend Account Duration"
        echo -e " [4] List All Accounts, Usage & Expiration Matrix"
        echo -e " [5] Display Connection URIs & Terminal QR Codes"
        echo -e " [6] Force Real-Time gRPC Stats Ingestion & Enforcement Cycle"
        echo -e " [7] Install / Verify Multi-Device Connection Limiter Watchdog"
        echo -e " [8] Install / Verify Hourly Background Cron Daemon"
        echo -e " [0] Exit Module"
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        read -rp "Please select an option [0-8]: " m3_choice

        case "$m3_choice" in
            1) m3_add_user; read -rp "Press ENTER to continue..." ;;
            2) m3_delete_user; read -rp "Press ENTER to continue..." ;;
            3) m3_renew_user; read -rp "Press ENTER to continue..." ;;
            4) m3_list_users; read -rp "Press ENTER to continue..." ;;
            5) m3_show_uris_and_qr ""; read -rp "Press ENTER to continue..." ;;
            6) m3_sync_usage_and_lock; read -rp "Press ENTER to continue..." ;;
            7) m3_install_device_limiter_daemon; read -rp "Press ENTER to continue..." ;;
            8) m3_install_cron_daemon; read -rp "Press ENTER to continue..." ;;
            0) clear; break ;;
            *) m3_log_warn "Invalid selection."; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap 'm3_error_trap $? $LINENO "$BASH_COMMAND"' ERR

    case "${1:-}" in
        --sync)
            m3_sync_usage_and_lock
            ;;
        --list)
            m3_list_users
            ;;
        --add)
            shift
            m3_add_user "$@"
            ;;
        --install-limiter)
            m3_install_device_limiter_daemon
            ;;
        *)
            module3_run_all
            ;;
    esac
fi
