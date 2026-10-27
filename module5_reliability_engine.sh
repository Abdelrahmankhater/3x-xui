#!/usr/bin/env bash
# ==============================================================================
# MODULE 5: Resilient SSL (Webroot + Standalone Fallback), Smart SRE & Watchdog
# Architecture: Principal Reliability Engineer (SRE) & Linux Security Architect
# Target OS   : Ubuntu 24.04 LTS (Noble Numbat)
# Optimization: Smart Kernel Cache Evaluation (Slab/Pagecache) & Auto-Fallback SSL
# Compatibility: Standalone executable OR sourceable module
# ==============================================================================

# Ensure strict execution safety when invoked directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
fi

# ------------------------------------------------------------------------------
# Module Metadata & Constants
# ------------------------------------------------------------------------------
MODULE5_NAME="Resilient SSL, Smart SRE & Self-Healing Watchdog"
MODULE5_VERSION="3.0.0-PROD"
MODULE5_AUTHOR="Principal Reliability Engineer (SRE)"

BASE_DIR="/etc/xray-manager"
CONFIG_ENV="${BASE_DIR}/config.env"
SSL_DIR="${BASE_DIR}/ssl"
WEB_ROOT="/var/www/html"

WATCHDOG_SCRIPT="/usr/local/bin/xray-self-healing.sh"
WATCHDOG_CRON="/etc/cron.d/xray-self-healing"
WATCHDOG_LOG="/var/log/xray-self-healing.log"

CERTBOT_HOOK_DIR="/etc/letsencrypt/renewal-hooks/post"
CERTBOT_HOOK_SCRIPT="${CERTBOT_HOOK_DIR}/99-xray-zero-downtime-reload.sh"

SUPERVISED_SERVICES=(
    "xray.service"
    "nginx.service"
    "ssh.service"
    "badvpn-udpgw.service"
    "ssh-multilogin-killer.service"
    "xray-device-limiter.service"
)

# Terminal Color Palette
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_MAGENTA='\033[0;35m'
    C_B_RED='\033[1;31m'; C_B_GREEN='\033[1;32m'; C_B_YELLOW='\033[1;33m'; C_B_CYAN='\033[1;36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_CYAN='' C_MAGENTA='' C_B_RED='' C_B_GREEN='' C_B_YELLOW='' C_B_CYAN=''
fi

m5_log_info()    { echo -e "${C_CYAN}[M5-INFO]${C_RESET} $*"; }
m5_log_success() { echo -e "${C_GREEN}[M5-SUCCESS]${C_RESET} $*"; }
m5_log_warn()    { echo -e "${C_YELLOW}[M5-WARN]${C_RESET} $*"; }
m5_log_error()   { echo -e "${C_RED}[M5-ERROR]${C_RESET} $*" >&2; }
m5_log_fatal()   { echo -e "${C_B_RED}[M5-FATAL]${C_RESET} $*" >&2; exit 1; }

m5_error_trap() {
    local exit_code="$1" line_no="$2" command="$3"
    m5_log_error "Command failed with exit code ${exit_code} at line ${line_no}: '${command}'"
}

# ------------------------------------------------------------------------------
# 1. Environment & Pre-Flight Validation
# ------------------------------------------------------------------------------
m5_init_environment() {
    if [[ $EUID -ne 0 ]]; then
        m5_log_fatal "Module 5 requires root privileges (sudo)."
    fi

    mkdir -p "${BASE_DIR}" "${SSL_DIR}" "${WEB_ROOT}/.well-known/acme-challenge"
    chmod 700 "${BASE_DIR}"
    chmod 750 "${SSL_DIR}"
    chmod -R 755 "${WEB_ROOT}"

    if [[ -f "$CONFIG_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_ENV"
    fi

    if [[ -z "${SERVER_DOMAIN:-}" ]]; then
        SERVER_DOMAIN="$(curl -s4 --max-time 2 https://api.ipify.org 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')"
        SERVER_DOMAIN="${SERVER_DOMAIN:-127.0.0.1}.nip.io"
    fi

    for tool in certbot nginx openssl cron awk systemctl bc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y && apt-get install -y "$tool" >/dev/null 2>&1 || m5_log_fatal "Failed to install ${tool}."
        fi
    done
}

# ------------------------------------------------------------------------------
# 2. Resilient SSL/TLS Engine (Webroot HTTP-01 with Automatic Standalone Fallback)
# ------------------------------------------------------------------------------
m5_issue_ssl() {
    m5_init_environment

    local domain="${1:-}"
    local email="${2:-}"

    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}     RESILIENT LET'S ENCRYPT SSL ENGINE (WEBROOT + STANDALONE)        ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"

    while [[ -z "$domain" ]]; do
        read -rp "Enter Domain Name pointing to this VPS (e.g. vpn.example.com): " domain
        if [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            m5_log_error "Invalid domain name syntax."
            domain=""
        fi
    done

    while [[ -z "$email" ]]; do
        read -rp "Enter Administrative Email for Let's Encrypt: " email
        if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            m5_log_error "Invalid email address format."
            email=""
        fi
    done

    m5_log_info "Initiating DNS pre-flight verification for: ${domain}..."

    local public_ip resolved_ip
    public_ip="$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')"
    resolved_ip="$(dig +short "$domain" @1.1.1.1 2>/dev/null | tail -n1 || true)"

    if [[ -z "$resolved_ip" ]]; then
        resolved_ip="$(ping -c 1 "$domain" 2>/dev/null | awk -F '[()]' '/PING/{print $2}' || true)"
    fi

    if [[ "$resolved_ip" != "$public_ip" ]]; then
        m5_log_warn "DNS mismatch detected!"
        m5_log_warn "Domain [${domain}] resolves to: '${resolved_ip:-UNRESOLVED}'"
        m5_log_warn "Server Public IP is: '${public_ip}'"
        m5_log_warn "Ensure Cloudflare proxy (orange cloud) is paused or set to DNS-Only during issuance."
        read -rp "Attempt issuance anyway? [y/N]: " confirm_issue
        [[ ! "$confirm_issue" =~ ^[yY]$ ]] && { m5_log_info "Issuance aborted."; return 1; }
    else
        m5_log_success "DNS pre-flight verification passed: ${domain} -> ${public_ip}"
    fi

    local le_live_dir="/etc/letsencrypt/live/${domain}"
    local issuance_success=0

    # ATTEMPT 1: Primary Zero-Downtime Webroot Mode
    m5_log_info "[ATTEMPT 1/2] Issuing via Nginx Webroot HTTP-01 challenge..."
    if ! systemctl is-active --quiet nginx; then
        systemctl restart nginx.service || true
    fi

    if certbot certonly --webroot -w "${WEB_ROOT}" \
        -d "${domain}" \
        --email "${email}" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --keep-until-expiring >/dev/null 2>&1; then
        issuance_success=1
        m5_log_success "Webroot HTTP-01 challenge succeeded!"
    else
        m5_log_warn "Webroot HTTP-01 validation failed or was intercepted by upstream proxy."
        m5_log_info "[ATTEMPT 2/2] Engaging Automatic Standalone Mode Fallback..."

        # Temporarily stop Nginx to free port 80 for Standalone ACME listener
        systemctl stop nginx.service || true
        sleep 1

        if certbot certonly --standalone \
            -d "${domain}" \
            --email "${email}" \
            --agree-tos \
            --no-eff-email \
            --non-interactive \
            --keep-until-expiring >/dev/null 2>&1; then
            issuance_success=1
            m5_log_success "Standalone HTTP-01 challenge succeeded!"
        else
            m5_log_error "Both Webroot and Standalone challenges failed. Check firewall and DNS propagation."
        fi

        # Immediately restore Nginx daemon
        systemctl start nginx.service || true
    fi

    if [[ $issuance_success -eq 1 && -f "${le_live_dir}/fullchain.pem" && -f "${le_live_dir}/privkey.pem" ]]; then
        cp -f "${le_live_dir}/fullchain.pem" "${SSL_DIR}/fullchain.pem"
        cp -f "${le_live_dir}/privkey.pem" "${SSL_DIR}/privkey.pem"
        chmod 644 "${SSL_DIR}/fullchain.pem"
        chmod 600 "${SSL_DIR}/privkey.pem"

        SERVER_DOMAIN="$domain"
        SSL_MODE="letsencrypt"

        cat <<EOF > "$CONFIG_ENV"
SERVER_IP="${public_ip}"
SERVER_DOMAIN="${SERVER_DOMAIN}"
SSL_MODE="letsencrypt"
EOF
        chmod 600 "$CONFIG_ENV"

        m5_configure_cert_hooks
        m5_reload_proxy_daemons

        m5_log_success "SSL certificates deployed to ${SSL_DIR}."
        m5_log_success "Automated renewal hook registered."
        return 0
    else
        m5_log_error "Certificate acquisition failed. Retaining current cryptographic keys."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# 3. Zero-Downtime Post-Renewal Hooks
# ------------------------------------------------------------------------------
m5_configure_cert_hooks() {
    m5_log_info "Deploying zero-downtime post-renewal hook to ${CERTBOT_HOOK_DIR}..."

    mkdir -p "${CERTBOT_HOOK_DIR}"

    cat <<'EOF' > "${CERTBOT_HOOK_SCRIPT}"
#!/usr/bin/env bash
# ==============================================================================
# Automated Zero-Downtime Certificate Deployment Hook
# Triggered automatically by Certbot upon successful certificate renewal
# ==============================================================================
set -Eeuo pipefail

SSL_DEST_DIR="/etc/xray-manager/ssl"
LOG_FILE="/var/log/xray-cert-renewal.log"

mkdir -p "$SSL_DEST_DIR" /var/log

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Automated certificate renewal hook triggered." >> "$LOG_FILE"

deployed=0
for live_dir in /etc/letsencrypt/live/*; do
    [ -d "$live_dir" ] || continue
    if [[ -f "${live_dir}/fullchain.pem" && -f "${live_dir}/privkey.pem" ]]; then
        cp -f "${live_dir}/fullchain.pem" "${SSL_DEST_DIR}/fullchain.pem"
        cp -f "${live_dir}/privkey.pem" "${SSL_DEST_DIR}/privkey.pem"
        chmod 644 "${SSL_DEST_DIR}/fullchain.pem"
        chmod 600 "${SSL_DEST_DIR}/privkey.pem"
        deployed=1
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Synced certificate from ${live_dir} to ${SSL_DEST_DIR}" >> "$LOG_FILE"
    fi
done

if [[ $deployed -eq 1 ]]; then
    systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service 2>/dev/null || true
    systemctl reload xray.service 2>/dev/null || systemctl restart xray.service 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Graceful daemon reload completed for Nginx and Xray." >> "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No valid certificates discovered for sync." >> "$LOG_FILE"
fi
EOF

    chmod +x "${CERTBOT_HOOK_SCRIPT}"
    m5_log_success "Zero-downtime Certbot post-renewal hook installed."
}

m5_reload_proxy_daemons() {
    m5_log_info "Gracefully reloading Nginx and Xray cryptographic contexts..."
    systemctl reload nginx.service 2>/dev/null || systemctl restart nginx.service 2>/dev/null || true
    systemctl reload xray.service 2>/dev/null || systemctl restart xray.service 2>/dev/null || true
}

m5_check_cert_expiry() {
    m5_init_environment
    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}                   SSL/TLS CERTIFICATE HEALTH AUDIT                   ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"

    local cert_file="${SSL_DIR}/fullchain.pem"
    if [[ ! -f "$cert_file" ]]; then
        m5_log_error "No certificate file discovered at ${cert_file}."
        return 1
    fi

    local issuer subject end_date days_left
    issuer="$(openssl x509 -in "$cert_file" -noout -issuer | sed 's/issuer=//')"
    subject="$(openssl x509 -in "$cert_file" -noout -subject | sed 's/subject=//')"
    end_date="$(openssl x509 -in "$cert_file" -noout -enddate | sed 's/notAfter=//')"

    local expire_epoch today_epoch
    expire_epoch="$(date -d "$end_date" +%s 2>/dev/null || echo 0)"
    today_epoch="$(date +%s)"
    days_left=$(( (expire_epoch - today_epoch) / 86400 ))

    echo -e " ${C_BOLD}Domain / Subject   :${C_RESET} ${subject}"
    echo -e " ${C_BOLD}Certificate Issuer :${C_RESET} ${issuer}"
    echo -e " ${C_BOLD}Expiration Date    :${C_RESET} ${end_date}"

    if (( days_left <= 0 )); then
        echo -e " ${C_BOLD}Status             :${C_RESET} ${C_B_RED}EXPIRED (${days_left} days left)${C_RESET}"
    elif (( days_left <= 15 )); then
        echo -e " ${C_BOLD}Status             :${C_RESET} ${C_B_YELLOW}RENEWAL RECOMMENDED (${days_left} days left)${C_RESET}"
    else
        echo -e " ${C_BOLD}Status             :${C_RESET} ${C_B_GREEN}HEALTHY (${days_left} days remaining)${C_RESET}"
    fi
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
}

# ------------------------------------------------------------------------------
# 4. Self-Healing Daemon & Automated Watchdog System
# ------------------------------------------------------------------------------
m5_install_self_healing() {
    m5_log_info "Installing self-healing watchdog daemon and health monitor..."

    cat <<'EOF' > "${WATCHDOG_SCRIPT}"
#!/usr/bin/env bash
# ==============================================================================
# Xray & VPN Core Self-Healing Watchdog
# Automatically inspects, revives failed daemons, and sanitizes kernel caches
# ==============================================================================
set -Eeuo pipefail

LOG_FILE="/var/log/xray-self-healing.log"
mkdir -p /var/log

SERVICES=(
    "xray.service"
    "nginx.service"
    "ssh.service"
    "badvpn-udpgw.service"
    "ssh-multilogin-killer.service"
    "xray-device-limiter.service"
)

# 1. Daemon Health Check & Automatic Resurrection
for svc in "${SERVICES[@]}"; do
    if ! systemctl list-unit-files "$svc" >/dev/null 2>&1; then
        continue
    fi

    if ! systemctl is-active --quiet "$svc"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FAILURE DETECTED] ${svc} was inactive or failed. Triggering recovery..." >> "$LOG_FILE"
        systemctl restart "$svc" 2>/dev/null || true
        sleep 1

        if systemctl is-active --quiet "$svc"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [RECOVERED] ${svc} successfully restarted and stabilized." >> "$LOG_FILE"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRITICAL] ${svc} failed to restart. Check journalctl -u ${svc}." >> "$LOG_FILE"
        fi
    fi
done

# 2. Smart Kernel Memory & Slab/Pagecache Assessment
mem_total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
cached="$(awk '/^Cached:/ {print $2}' /proc/meminfo)"
sreclaim="$(awk '/^SReclaimable:/ {print $2}' /proc/meminfo)"

used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))

if (( used_pct >= 85 )); then
    reclaimable_kb=$(( cached + sreclaim ))
    reclaimable_pct=$(( reclaimable_kb * 100 / mem_total ))

    if (( reclaimable_pct >= 25 )); then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [MEMORY THRESHOLD] RAM at ${used_pct}%. Reclaimable cache: ${reclaimable_pct}%. Flushing pagecache..." >> "$LOG_FILE"
        sync
        # If reclaimable slab is disproportionately high, flush dentries/inodes (3), else flush pagecache only (1)
        if (( sreclaim * 2 > cached )); then
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        else
            echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
        fi
        new_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
        new_used_pct=$(( (mem_total - new_avail) * 100 / mem_total ))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [MEMORY STABILIZED] RAM usage reduced from ${used_pct}% to ${new_used_pct}%." >> "$LOG_FILE"
    fi
fi
EOF

    chmod +x "${WATCHDOG_SCRIPT}"

    cat <<EOF > "${WATCHDOG_CRON}"
# /etc/cron.d/xray-self-healing: Executed every 5 minutes
*/5 * * * * root ${WATCHDOG_SCRIPT} >/dev/null 2>&1
EOF
    chmod 644 "${WATCHDOG_CRON}"

    m5_log_success "Self-healing watchdog cron installed: ${WATCHDOG_CRON} (Interval: 5m)."
}

# ------------------------------------------------------------------------------
# 5. Smart System Resource & Maintenance Sanitizer
# ------------------------------------------------------------------------------
m5_system_maintenance() {
    m5_init_environment
    m5_log_info "Initiating deep system maintenance and resource reclamation..."

    # 1. Dynamic Log Truncation to Prevent Disk Exhaustion (> 30MB)
    local target_log_dirs=("/var/log/xray" "/var/log/nginx" "/var/log")
    for d in "${target_log_dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for logfile in "${d}"/*.log; do
            [[ -f "$logfile" ]] || continue
            local logsize
            logsize="$(stat -c %s "$logfile" 2>/dev/null || echo 0)"
            # 31457280 bytes = 30MB
            if (( logsize > 31457280 )); then
                m5_log_info "Truncating oversized log: ${logfile} (${logsize} bytes)..."
                tail -n 15000 "$logfile" > "${logfile}.tmp.$$" && mv -f "${logfile}.tmp.$$" "$logfile"
            fi
        done
    done

    # 2. Vacuum systemd journal logs to retain max 3 days / 100MB
    if command -v journalctl >/dev/null 2>&1; then
        m5_log_info "Vacuuming systemd journal logs (retaining last 3 days / 100MB)..."
        journalctl --vacuum-time=3d --vacuum-size=100M >/dev/null 2>&1 || true
    fi

    # 3. Purge stale temporary artifacts in /tmp (> 3 days old)
    m5_log_info "Purging stale files in /tmp older than 3 days..."
    find /tmp -mindepth 1 -maxdepth 2 -mtime +3 -delete 2>/dev/null || true

    # 4. Clean APT package cache
    m5_log_info "Reclaiming APT cache disk space..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get clean >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true

    # 5. Smart Kernel Memory & Slab/Pagecache Evaluation
    local mem_total mem_avail cached sreclaim used_pct
    mem_total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    mem_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
    cached="$(awk '/^Cached:/ {print $2}' /proc/meminfo)"
    sreclaim="$(awk '/^SReclaimable:/ {print $2}' /proc/meminfo)"

    used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    m5_log_info "Current Physical Memory Utilization: ${used_pct}%"

    if (( used_pct >= 85 )); then
        local reclaimable_kb reclaimable_pct
        reclaimable_kb=$(( cached + sreclaim ))
        reclaimable_pct=$(( reclaimable_kb * 100 / mem_total ))

        m5_log_warn "Memory threshold exceeds 85% (Reclaimable Cache: ${reclaimable_pct}%)."
        sync

        if (( sreclaim * 2 > cached )); then
            m5_log_info "Flushing Pagecache and Dentries/Inodes (echo 3)..."
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        else
            m5_log_info "Flushing Pagecache only (echo 1) to preserve directory metadata..."
            echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
        fi

        local new_avail new_used_pct
        new_avail="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
        new_used_pct=$(( (mem_total - new_avail) * 100 / mem_total ))
        m5_log_success "Kernel caches sanitized. New utilization: ${new_used_pct}%"
    fi

    m5_log_success "System maintenance completed. Disk and memory resources reclaimed."
}

# ------------------------------------------------------------------------------
# 6. Watchdog Event Telemetry Inspector
# ------------------------------------------------------------------------------
m5_view_healing_logs() {
    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}               SELF-HEALING WATCHDOG RECOVERY LOGS                    ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    if [[ -f "$WATCHDOG_LOG" ]]; then
        tail -n 45 "$WATCHDOG_LOG"
    else
        echo "No recovery actions recorded yet in ${WATCHDOG_LOG}."
    fi
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
}

# ------------------------------------------------------------------------------
# 7. Unified Module Execution Routine
# ------------------------------------------------------------------------------
module5_run_all() {
    m5_init_environment
    while true; do
        clear
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        echo -e "${C_BOLD}   MODULE 5: RESILIENT SSL, SMART SRE & SELF-HEALING ENGINE           ${C_RESET}"
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        echo -e " [1] Issue Let's Encrypt Certificate (Webroot + Standalone Fallback)"
        echo -e " [2] Inspect SSL/TLS Certificate Validity & Expiration"
        echo -e " [3] Install / Verify Zero-Downtime Post-Renewal Hooks"
        echo -e " [4] Install / Verify Self-Healing Watchdog System (5m Cron)"
        echo -e " [5] Trigger Smart Memory & Log Maintenance Sanitizer"
        echo -e " [6] View Self-Healing Watchdog Event Logs"
        echo -e " [0] Exit Module"
        echo -e "${C_B_CYAN}======================================================================${C_RESET}"
        read -rp "Please select an option [0-6]: " m5_choice

        case "$m5_choice" in
            1) m5_issue_ssl; read -rp "Press ENTER to continue..." ;;
            2) m5_check_cert_expiry; read -rp "Press ENTER to continue..." ;;
            3) m5_configure_cert_hooks; read -rp "Press ENTER to continue..." ;;
            4) m5_install_self_healing; read -rp "Press ENTER to continue..." ;;
            5) m5_system_maintenance; read -rp "Press ENTER to continue..." ;;
            6) m5_view_healing_logs; read -rp "Press ENTER to continue..." ;;
            0) clear; break ;;
            *) m5_log_warn "Invalid selection."; sleep 1 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap 'm5_error_trap $? $LINENO "$BASH_COMMAND"' ERR

    case "${1:-}" in
        --issue-ssl)
            shift
            m5_issue_ssl "$@"
            ;;
        --check-cert)
            m5_check_cert_expiry
            ;;
        --install-watchdog)
            m5_install_self_healing
            ;;
        --maintenance)
            m5_system_maintenance
            ;;
        --logs)
            m5_view_healing_logs
            ;;
        *)
            module5_run_all
            ;;
    esac
fi
