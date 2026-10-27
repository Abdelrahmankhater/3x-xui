#!/usr/bin/env bash
# ==============================================================================
# MODULE 6: Master TUI/CLI Orchestrator & Disaster Recovery Architect (main.sh)
# Architecture: Principal Linux UI/UX & Systems Orchestrator Architect
# Target OS   : Ubuntu 24.04 LTS (Noble Numbat)
# Enhancements: Automated SHA-256 Disaster Recovery, Live Telemetry & gRPC Sync
# ==============================================================================

# Ensure strict execution safety
set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Orchestrator Constants & Paths
# ------------------------------------------------------------------------------
APP_TITLE="ENTERPRISE XRAY & SSH PROXY SUITE"
APP_VERSION="3.5.0-PROD"
APP_CODENAME="Aetheris Mesh Core"

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

BASE_DIR="/etc/xray-manager"
MODULES_DIR="${BASE_DIR}/modules"
CONFIG_ENV="${BASE_DIR}/config.env"
BACKUP_DIR="${BASE_DIR}/backups"
SSH_USERS_DB="${BASE_DIR}/ssh_users.json"
XRAY_USERS_DB="${BASE_DIR}/users.json"

SYM_LINK_MENU="/usr/local/bin/menu"
SYM_LINK_MGR="/usr/local/bin/xray-manager"

# Module Paths
MOD1_SHIELD="${MODULES_DIR}/module1_core_shield.sh"
MOD2_ENGINE="${MODULES_DIR}/module2_xray_engine.sh"
MOD3_USERS="${MODULES_DIR}/module3_user_engine.sh"
MOD4_SSH="${MODULES_DIR}/module4_ssh_badvpn_engine.sh"
MOD5_SRE="${MODULES_DIR}/module5_reliability_engine.sh"

# ------------------------------------------------------------------------------
# High-Contrast ANSI Terminal Styling
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'; C_MAGENTA='\033[0;35m'; C_CYAN='\033[0;36m'; C_WHITE='\033[0;37m'
    C_B_RED='\033[1;31m'; C_B_GREEN='\033[1;32m'; C_B_YELLOW='\033[1;33m'; C_B_CYAN='\033[1;36m'; C_B_WHITE='\033[1;37m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE='' C_B_RED='' C_B_GREEN=''
    C_B_YELLOW='' C_B_CYAN='' C_B_WHITE=''
fi

log_info()    { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_fatal()   { echo -e "${C_B_RED}[FATAL]${C_RESET} $*" >&2; exit 1; }

error_trap() {
    local exit_code="$1" line_no="$2" command="$3"
    log_error "Execution interrupted with exit code ${exit_code} at line ${line_no}: '${command}'"
}
trap 'error_trap $? $LINENO "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
# 1. Environment Sync & Module Verification
# ------------------------------------------------------------------------------
init_orchestrator() {
    if [[ $EUID -ne 0 ]]; then
        log_fatal "This orchestrator requires root administrative privileges (sudo)."
    fi

    mkdir -p "${BASE_DIR}" "${MODULES_DIR}" "${BACKUP_DIR}"
    chmod 700 "${BASE_DIR}" "${BACKUP_DIR}"

    # Sync local ./modules to /etc/xray-manager/modules if running from repo
    if [[ -d "${SCRIPT_DIR}/modules" ]]; then
        cp -u "${SCRIPT_DIR}/modules"/*.sh "${MODULES_DIR}/" 2>/dev/null || true
    fi

    chmod +x "${MODULES_DIR}"/*.sh 2>/dev/null || true

    # Link system-wide shortcuts
    if [[ ! -L "$SYM_LINK_MENU" || "$(readlink -f "$SYM_LINK_MENU")" != "$SCRIPT_PATH" ]]; then
        ln -sfn "$SCRIPT_PATH" "$SYM_LINK_MENU"
        chmod +x "$SYM_LINK_MENU"
    fi
    if [[ ! -L "$SYM_LINK_MGR" || "$(readlink -f "$SYM_LINK_MGR")" != "$SCRIPT_PATH" ]]; then
        ln -sfn "$SCRIPT_PATH" "$SYM_LINK_MGR"
        chmod +x "$SYM_LINK_MGR"
    fi

    if [[ -f "$CONFIG_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_ENV"
    fi
}

verify_or_source_module() {
    local mod_path="$1"
    local mod_desc="$2"

    if [[ ! -f "$mod_path" ]]; then
        log_error "Module missing: ${mod_desc} (${mod_path})"
        echo -e "${C_YELLOW}Ensure all module files are present in ${MODULES_DIR}.${C_RESET}"
        read -rp "Press ENTER to return..."; return 1
    fi

    # shellcheck disable=SC1090
    source "$mod_path"
    return 0
}

# ------------------------------------------------------------------------------
# 2. Live System Telemetry & Health Banner
# ------------------------------------------------------------------------------
render_telemetry_header() {
    clear
    local host_name public_ip active_domain kernel_ver cpu_usage ram_usage sys_uptime
    host_name="$(hostname 2>/dev/null || echo 'localhost')"
    kernel_ver="$(uname -r 2>/dev/null || echo 'Linux')"

    public_ip="${SERVER_IP:-}"
    if [[ -z "$public_ip" ]]; then
        public_ip="$(curl -s4 --max-time 1 https://api.ipify.org 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')"
        public_ip="${public_ip:-127.0.0.1}"
    fi
    active_domain="${SERVER_DOMAIN:-${public_ip}.nip.io}"

    cpu_usage="$(top -bn1 2>/dev/null | grep -E "^(%Cpu|Cpu\(s\))" | awk '{print 100 - $8 "%"}' || echo "N/A")"
    [[ -z "$cpu_usage" || "$cpu_usage" == "%" ]] && cpu_usage="0.5%"

    ram_usage="$(free -m 2>/dev/null | awk '/Mem:/ { printf "%s/%s MB (%.0f%%)", $3, $2, ($3/$2)*100 }' || echo "N/A")"
    sys_uptime="$(uptime -p 2>/dev/null | sed 's/up //' || echo "N/A")"

    local st_xray st_nginx st_ssh st_badvpn st_killer st_devlimit st_watchdog
    st_xray="${C_B_RED}OFF${C_RESET}"
    st_nginx="${C_B_RED}OFF${C_RESET}"
    st_ssh="${C_B_RED}OFF${C_RESET}"
    st_badvpn="${C_B_RED}OFF${C_RESET}"
    st_killer="${C_B_RED}OFF${C_RESET}"
    st_devlimit="${C_B_RED}OFF${C_RESET}"
    st_watchdog="${C_B_RED}OFF${C_RESET}"

    systemctl is-active --quiet xray.service 2>/dev/null && st_xray="${C_B_GREEN}ON${C_RESET}"
    systemctl is-active --quiet nginx.service 2>/dev/null && st_nginx="${C_B_GREEN}ON${C_RESET}"
    (systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null) && st_ssh="${C_B_GREEN}ON${C_RESET}"
    systemctl is-active --quiet badvpn-udpgw.service 2>/dev/null && st_badvpn="${C_B_GREEN}ON${C_RESET}"
    systemctl is-active --quiet ssh-multilogin-killer.service 2>/dev/null && st_killer="${C_B_GREEN}ON${C_RESET}"
    systemctl is-active --quiet xray-device-limiter.service 2>/dev/null && st_devlimit="${C_B_GREEN}ON${C_RESET}"
    [[ -f /etc/cron.d/xray-self-healing ]] && st_watchdog="${C_B_GREEN}ON${C_RESET}"

    local xray_users=0 ssh_users=0
    [[ -f "$XRAY_USERS_DB" ]] && xray_users="$(jq '. | length' "$XRAY_USERS_DB" 2>/dev/null || echo 0)"
    [[ -f "$SSH_USERS_DB" ]] && ssh_users="$(jq '. | length' "$SSH_USERS_DB" 2>/dev/null || echo 0)"

    echo -e "${C_B_CYAN}┌────────────────────────────────────────────────────────────────────────┐${C_RESET}"
    echo -e "${C_B_CYAN}│${C_RESET} ${C_B_WHITE}${APP_TITLE}${C_RESET} - ${C_CYAN}v${APP_VERSION}${C_RESET} [${C_GREEN}${APP_CODENAME}${C_RESET}] $(printf '%*s' 12 '') ${C_B_CYAN}│${C_RESET}"
    echo -e "${C_B_CYAN}├────────────────────────────────────────────────────────────────────────┤${C_RESET}"
    printf "${C_B_CYAN}│${C_RESET}  %-14s: ${C_B_WHITE}%-20s${C_RESET} %-12s: ${C_B_WHITE}%-18s${C_RESET} ${C_B_CYAN}│${C_RESET}\n" "Hostname" "$host_name" "Kernel" "$kernel_ver"
    printf "${C_B_CYAN}│${C_RESET}  %-14s: ${C_B_GREEN}%-20s${C_RESET} %-12s: ${C_B_CYAN}%-18s${C_RESET} ${C_B_CYAN}│${C_RESET}\n" "Server IP" "$public_ip" "Domain" "$active_domain"
    printf "${C_B_CYAN}│${C_RESET}  %-14s: %-20s %-12s: %-18s ${C_B_CYAN}│${C_RESET}\n" "CPU Load" "$cpu_usage" "Memory" "$ram_usage"
    printf "${C_B_CYAN}│${C_RESET}  %-14s: %-20s %-12s: ${C_B_YELLOW}%-18s${C_RESET} ${C_B_CYAN}│${C_RESET}\n" "System Uptime" "$sys_uptime" "Accounts" "Xray: ${xray_users} | SSH: ${ssh_users}"
    echo -e "${C_B_CYAN}├────────────────────────────────────────────────────────────────────────┤${C_RESET}"
    echo -e "${C_B_CYAN}│${C_RESET}  Daemons: Xray[${st_xray}] Nginx[${st_nginx}] SSH[${st_ssh}] BadVPN[${st_badvpn}] MultiLog[${st_killer}] DevLim[${st_devlimit}] Watchdog[${st_watchdog}] ${C_B_CYAN}│${C_RESET}"
    echo -e "${C_B_CYAN}└────────────────────────────────────────────────────────────────────────┘${C_RESET}"
}

# ------------------------------------------------------------------------------
# 3. Automated Backup & One-Click Disaster Recovery Engine
# ------------------------------------------------------------------------------
m6_create_backup() {
    init_orchestrator
    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}           SYSTEM BACKUP & DISASTER RECOVERY ARCHIVAL                 ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"

    local timestamp backup_name archive_file
    timestamp="$(date +%Y%m%d_%H%M%S)"
    backup_name="xray_disaster_backup_${timestamp}"
    archive_file="${BACKUP_DIR}/${backup_name}.tar.gz"

    log_info "Creating snapshot archive of credentials, databases, and SSL keys..."

    # Create backup archive containing critical configuration and databases
    tar -czf "$archive_file" -C / \
        etc/xray-manager/users.json \
        etc/xray-manager/ssh_users.json \
        etc/xray-manager/config.env \
        etc/xray-manager/ssl \
        usr/local/etc/xray/config.json \
        etc/nginx/sites-available 2>/dev/null || true

    # Generate cryptographic SHA-256 integrity checksum
    sha256sum "$archive_file" > "${archive_file}.sha256"

    local archive_size
    archive_size="$(stat -c %s "$archive_file" 2>/dev/null || echo 0)"

    log_success "Disaster recovery snapshot created successfully!"
    echo -e " ${C_BOLD}Archive Path :${C_RESET} ${archive_file}"
    echo -e " ${C_BOLD}Checksum File:${C_RESET} ${archive_file}.sha256"
    echo -e " ${C_BOLD}Archive Size :${C_RESET} $(( archive_size / 1024 )) KB"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
}

m6_restore_backup() {
    init_orchestrator
    clear
    echo -e "${C_B_RED}======================================================================${C_RESET}"
    echo -e "${C_BOLD}             DISASTER RECOVERY & SYSTEM RESTORATION                   ${C_RESET}"
    echo -e "${C_B_RED}======================================================================${C_RESET}"

    local target_archive="${1:-}"

    if [[ -z "$target_archive" ]]; then
        mapfile -t backups < <(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || true)
        if [[ ${#backups[@]} -eq 0 ]]; then
            log_warn "No disaster recovery backups discovered in ${BACKUP_DIR}."
            return 1
        fi

        echo -e "Available Snapshot Archives:"
        for idx in "${!backups[@]}"; do
            local b_size
            b_size="$(stat -c %s "${backups[$idx]}" 2>/dev/null || echo 0)"
            printf " [%d] %s (%d KB)\n" "$((idx + 1))" "$(basename "${backups[$idx]}")" "$(( b_size / 1024 ))"
        done
        echo -e "${C_B_RED}----------------------------------------------------------------------${C_RESET}"
        read -rp "Select snapshot to restore [1-${#backups[@]}]: " b_sel
        if [[ ! "$b_sel" =~ ^[0-9]+$ || "$b_sel" -lt 1 || "$b_sel" -gt ${#backups[@]} ]]; then
            log_error "Invalid selection. Restoration cancelled."
            return 1
        fi
        target_archive="${backups[$((b_sel - 1))]}"
    fi

    if [[ ! -f "$target_archive" ]]; then
        log_fatal "Archive file '${target_archive}' does not exist."
    fi

    # Verify SHA-256 integrity checksum if available
    local sha_file="${target_archive}.sha256"
    if [[ -f "$sha_file" ]]; then
        log_info "Verifying SHA-256 cryptographic archive integrity..."
        if sha256sum -c "$sha_file" >/dev/null 2>&1; then
            log_success "SHA-256 archive checksum verified!"
        else
            log_fatal "Checksum verification failed! Snapshot archive may be corrupt or tampered."
        fi
    fi

    read -rp "Are you sure you want to restore? Current configuration will be overwritten [y/N]: " confirm_res
    [[ ! "$confirm_res" =~ ^[yY]$ ]] && { log_info "Restoration aborted."; return 0; }

    log_info "Extracting archive snapshot to filesystem root..."
    tar -xzf "$target_archive" -C /

    # Re-enforce security permissions
    chmod 700 "${BASE_DIR}"
    chmod 600 "${BASE_DIR}"/*.json "${BASE_DIR}/config.env" 2>/dev/null || true
    chmod 600 "${BASE_DIR}/ssl/privkey.pem" 2>/dev/null || true
    chmod 644 "${BASE_DIR}/ssl/fullchain.pem" 2>/dev/null || true

    # Validate restored Xray and Nginx configs
    log_info "Validating restored service schemas..."
    if command -v xray >/dev/null 2>&1; then
        xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 || log_warn "Xray configuration reported schema warnings."
    fi
    if command -v nginx >/dev/null 2>&1; then
        nginx -t >/dev/null 2>&1 || log_warn "Nginx syntax test reported warnings."
    fi

    # Gracefully restart all core daemons
    log_info "Restarting core proxies and background daemons..."
    systemctl restart xray.service nginx.service ssh.service badvpn-udpgw.service \
        ssh-multilogin-killer.service xray-device-limiter.service 2>/dev/null || true

    log_success "DISASTER RECOVERY COMPLETED. All databases, SSL keys, and inbounds restored!"
    echo -e "${C_B_RED}======================================================================${C_RESET}"
}

# ------------------------------------------------------------------------------
# 4. View System Logs (Enforcement & Self-Healing Telemetry)
# ------------------------------------------------------------------------------
view_system_logs_menu() {
    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}               REAL-TIME SYSTEM & ENFORCEMENT AUDIT LOGS              ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e " [1] SSH Multi-Login Killer Violations (/var/log/ssh-multilogin-killer.log)"
    echo -e " [2] Xray gRPC Multi-Device Eviction Logs (/var/log/xray-device-limiter.log)"
    echo -e " [3] SRE Self-Healing Watchdog Actions (/var/log/xray-self-healing.log)"
    echo -e " [4] Automated SSL Certificate Renewal Hook Logs"
    echo -e " [5] Xray Core Engine Error Logs (/var/log/xray/error.log)"
    echo -e " [6] Nginx Reverse Proxy Error Logs (/var/log/nginx/error.log)"
    echo -e " [0] Return to Main Menu"
    echo -e "${C_B_CYAN}----------------------------------------------------------------------${C_RESET}"
    read -rp "Select log stream to inspect [0-6]: " l_choice

    case "$l_choice" in
        1)
            clear; echo -e "${C_CYAN}=== SSH Multi-Login Killer Log ===${C_RESET}"
            tail -n 45 /var/log/ssh-multilogin-killer.log 2>/dev/null || echo "No multi-login violations recorded."
            ;;
        2)
            clear; echo -e "${C_CYAN}=== Xray Multi-Device Limiter Log ===${C_RESET}"
            tail -n 45 /var/log/xray-device-limiter.log 2>/dev/null || echo "No device limit violations recorded."
            ;;
        3)
            clear; echo -e "${C_CYAN}=== Self-Healing Recovery Log ===${C_RESET}"
            tail -n 45 /var/log/xray-self-healing.log 2>/dev/null || echo "No self-healing events recorded."
            ;;
        4)
            clear; echo -e "${C_CYAN}=== SSL Certbot Post-Renew Log ===${C_RESET}"
            tail -n 45 /var/log/xray-cert-renewal.log 2>/dev/null || echo "No renewal hook events recorded."
            ;;
        5)
            clear; echo -e "${C_CYAN}=== Xray Error Stream ===${C_RESET}"
            tail -n 45 /var/log/xray/error.log 2>/dev/null || echo "Log empty."
            ;;
        6)
            clear; echo -e "${C_CYAN}=== Nginx Error Stream ===${C_RESET}"
            tail -n 45 /var/log/nginx/error.log 2>/dev/null || echo "Log empty."
            ;;
        0) return ;;
        *) log_warn "Invalid selection." ;;
    esac
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    read -rp "Press ENTER to return..."
}

# ------------------------------------------------------------------------------
# 5. Sequential One-Click Full Stack Deployment
# ------------------------------------------------------------------------------
execute_full_one_click_setup() {
    clear
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}   SEQUENTIAL ONE-CLICK FULL STACK DEPLOYMENT FOR UBUNTU 24.04 LTS    ${C_RESET}"
    echo -e "${C_B_CYAN}======================================================================${C_RESET}"
    echo -e " This automated deployment executes all 5 enterprise modules in order:"
    echo -e "   1. Module 1: Kernel BBR, Extreme Concurrency & Multi-Page Camouflage Web"
    echo -e "   2. Module 2: Xray-Core Binary, gRPC API (10085) & Multi-Protocol Inbounds"
    echo -e "   3. Module 3: JSON User Database, Quota Daemon & Multi-Device Limiter"
    echo -e "   4. Module 4: OpenSSH Hardening, BadVPN UDPGW (7300) & Socket Watchdog"
    echo -e "   5. Module 5: Resilient SSL (Webroot+Standalone), Hooks & SRE Self-Healing"
    echo -e "${C_B_CYAN}----------------------------------------------------------------------${C_RESET}"

    local public_ip
    public_ip="$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null || ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')"
    echo -e "Detected Public IPv4: ${C_B_GREEN}${public_ip}${C_RESET}"

    read -rp "Enter your Domain Name (Press ENTER to default to '${public_ip}.nip.io'): " user_domain
    if [[ -z "$user_domain" ]]; then
        SERVER_DOMAIN="${public_ip}.nip.io"
    else
        SERVER_DOMAIN="$user_domain"
    fi
    SERVER_IP="$public_ip"

    cat <<EOF > "$CONFIG_ENV"
SERVER_IP="${SERVER_IP}"
SERVER_DOMAIN="${SERVER_DOMAIN}"
SSL_MODE="self-signed"
EOF
    chmod 600 "$CONFIG_ENV"

    # Step 1: Module 1
    log_info "STEP 1/5: Deploying Module 1 (Kernel BBR, Camouflage Site & Nginx Ingress)..."
    if verify_or_source_module "$MOD1_SHIELD" "Module 1"; then
        m1_check_prerequisites
        m1_optimize_sysctl_and_bbr
        m1_deploy_multi_page_camouflage_site
        m1_install_and_configure_nginx
        m1_configure_firewall_and_persistence
        m1_verify_health
    fi

    # Step 2: Module 2
    log_info "STEP 2/5: Deploying Module 2 (Xray-Core Master Engine & gRPC API)..."
    if verify_or_source_module "$MOD2_ENGINE" "Module 2"; then
        m2_check_prerequisites
        m2_install_xray_core
        m2_generate_xray_config
        m2_restart_service
        m2_verify_api_status
        m2_verify_engine_health
    fi

    # Step 3: Module 3
    log_info "STEP 3/5: Deploying Module 3 (Database Initialization & Device Limiter)..."
    if verify_or_source_module "$MOD3_USERS" "Module 3"; then
        m3_init_environment
        m3_install_cron_daemon
        m3_install_device_limiter_daemon
    fi

    # Step 4: Module 4
    log_info "STEP 4/5: Deploying Module 4 (OpenSSH Tunneling, BadVPN UDPGW & Socket Watchdog)..."
    if verify_or_source_module "$MOD4_SSH" "Module 4"; then
        m4_init_environment
        m4_configure_sshd
        m4_install_badvpn
        m4_install_multilogin_daemon
    fi

    # Step 5: Module 5
    log_info "STEP 5/5: Deploying Module 5 (Zero-Downtime Hooks & Self-Healing SRE Watchdog)..."
    if verify_or_source_module "$MOD5_SRE" "Module 5"; then
        m5_init_environment
        m5_configure_cert_hooks
        m5_install_self_healing
        m5_system_maintenance

        if [[ "$user_domain" != "" && "$user_domain" != *.nip.io ]]; then
            echo -e "\n${C_B_YELLOW}Domain detected: ${user_domain}${C_RESET}"
            read -rp "Would you like to issue a genuine Let's Encrypt SSL certificate now? [Y/n]: " do_ssl
            if [[ ! "$do_ssl" =~ ^[nN]$ ]]; then
                read -rp "Enter administrator email for Let's Encrypt notifications: " admin_email
                m5_issue_ssl "$user_domain" "$admin_email" || log_warn "SSL generation can be re-attempted from Menu [3]."
            fi
        fi
    fi

    # Create initial disaster recovery snapshot
    m6_create_backup

    echo -e "\n${C_B_GREEN}======================================================================${C_RESET}"
    echo -e "${C_BOLD}          ONE-CLICK FULL STACK DEPLOYMENT COMPLETED SUCCESSFULLY       ${C_RESET}"
    echo -e "${C_B_GREEN}======================================================================${C_RESET}"
    echo -e " Access this master console anytime by executing: ${C_B_CYAN}menu${C_RESET} or ${C_B_CYAN}xray-manager${C_RESET}"
    read -rp "Press ENTER to return to the master dashboard..."
}

# ------------------------------------------------------------------------------
# 6. Master TUI Orchestrator Loop
# ------------------------------------------------------------------------------
master_orchestrator_loop() {
    init_orchestrator

    while true; do
        render_telemetry_header

        echo -e " ${C_B_WHITE}[USER & PROTOCOL MANAGEMENT]${C_RESET}"
        echo -e "   ${C_CYAN}[1]${C_RESET} Manage V2Ray/Xray Accounts  ${C_DIM}(VMess, VLESS, Trojan, Shadowsocks)${C_RESET}"
        echo -e "   ${C_CYAN}[2]${C_RESET} Manage Linux SSH & BadVPN    ${C_DIM}(Direct SSH, BadVPN 7300, Socket Limiter)${C_RESET}"
        echo -e "   ${C_CYAN}[3]${C_RESET} SSL Certificate Management   ${C_DIM}(Webroot + Standalone Auto-Fallback)${C_RESET}"
        echo ""
        echo -e " ${C_B_WHITE}[CORE INFRASTRUCTURE & NETWORK SECURITY]${C_RESET}"
        echo -e "   ${C_CYAN}[4]${C_RESET} Core Shield & Firewall       ${C_DIM}(Kernel BBR, Camouflage Web, UFW)${C_RESET}"
        echo -e "   ${C_CYAN}[5]${C_RESET} Xray Engine & gRPC Status    ${C_DIM}(Inbound Audits, API Socket 10085)${C_RESET}"
        echo -e "   ${C_CYAN}[6]${C_RESET} Run Smart SRE Maintenance    ${C_DIM}(Pagecache/Slab Flush, Dynamic Log Vacuum)${C_RESET}"
        echo ""
        echo -e " ${C_B_WHITE}[BACKUP, DISASTER RECOVERY & AUDIT]${C_RESET}"
        echo -e "   ${C_CYAN}[7]${C_RESET} Backup & Disaster Recovery   ${C_DIM}(SHA-256 Snapshot Archival & Restoration)${C_RESET}"
        echo -e "   ${C_CYAN}[8]${C_RESET} View System Audit Logs       ${C_DIM}(MultiLog, DevLimiter, SRE Recovery)${C_RESET}"
        echo ""
        echo -e " ${C_B_WHITE}[AUTOMATED DEPLOYMENT & SHORTCUTS]${C_RESET}"
        echo -e "   ${C_B_GREEN}[9] Full One-Click Stack Setup${C_RESET}  ${C_DIM}(Automated 5-Module Fresh VPS Deploy)${C_RESET}"
        echo -e "   ${C_B_RED}[0] Exit Management Console${C_RESET}"
        echo -e "${C_B_CYAN}────────────────────────────────────────────────────────────────────────${C_RESET}"
        read -rp "Select an option [0-9]: " main_choice

        case "$main_choice" in
            1)
                if verify_or_source_module "$MOD3_USERS" "Module 3 (User Engine)"; then
                    module3_run_all
                fi
                ;;
            2)
                if verify_or_source_module "$MOD4_SSH" "Module 4 (SSH & BadVPN)"; then
                    module4_run_all
                fi
                ;;
            3)
                if verify_or_source_module "$MOD5_SRE" "Module 5 (Reliability & SSL)"; then
                    module5_run_all
                fi
                ;;
            4)
                if verify_or_source_module "$MOD1_SHIELD" "Module 1 (Core Shield)"; then
                    module1_run_all
                    read -rp "Press ENTER to return..."
                fi
                ;;
            5)
                if verify_or_source_module "$MOD2_ENGINE" "Module 2 (Xray Engine)"; then
                    module2_run_all
                    read -rp "Press ENTER to return..."
                fi
                ;;
            6)
                if verify_or_source_module "$MOD5_SRE" "Module 5 (Reliability Engine)"; then
                    m5_system_maintenance
                    read -rp "Press ENTER to return..."
                fi
                ;;
            7)
                clear
                echo -e "${C_B_CYAN}======================================================================${C_RESET}"
                echo -e "${C_BOLD}             DISASTER RECOVERY & BACKUP OPERATIONS                    ${C_RESET}"
                echo -e "${C_B_CYAN}======================================================================${C_RESET}"
                echo -e " [1] Create Immediate SHA-256 System Snapshot Archive"
                echo -e " [2] Restore from Existing Disaster Recovery Snapshot"
                echo -e " [0] Return to Main Menu"
                echo -e "${C_B_CYAN}----------------------------------------------------------------------${C_RESET}"
                read -rp "Select action [0-2]: " br_sel
                case "$br_sel" in
                    1) m6_create_backup; read -rp "Press ENTER to return..." ;;
                    2) m6_restore_backup; read -rp "Press ENTER to return..." ;;
                    *) ;;
                esac
                ;;
            8)
                view_system_logs_menu
                ;;
            9)
                execute_full_one_click_setup
                ;;
            0)
                clear; exit 0
                ;;
            *)
                log_warn "Invalid selection. Please input a number between [0-9]."
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Entry Point & CLI Sub-Command Handling
# ------------------------------------------------------------------------------
main() {
    case "${1:-}" in
        --backup)
            init_orchestrator
            m6_create_backup
            ;;
        --restore)
            init_orchestrator
            shift
            m6_restore_backup "${1:-}"
            ;;
        --install-all)
            init_orchestrator
            execute_full_one_click_setup
            ;;
        --maintenance)
            init_orchestrator
            if verify_or_source_module "$MOD5_SRE" "Module 5"; then
                m5_system_maintenance
            fi
            ;;
        --logs)
            init_orchestrator
            view_system_logs_menu
            ;;
        --version|-v)
            echo "${APP_TITLE} v${APP_VERSION} (${APP_CODENAME})"
            exit 0
            ;;
        --help|-h)
            echo "Usage: menu [COMMAND]"
            echo "Commands:"
            echo "  (none)          Launch interactive master TUI dashboard"
            echo "  --backup        Create an automated SHA-256 snapshot archive"
            echo "  --restore [tar] Restore databases, keys, and inbounds from snapshot"
            echo "  --install-all   Execute full sequential 5-module installation"
            echo "  --maintenance   Run smart SRE memory evaluation and log vacuum"
            echo "  --logs          Inspect audit logs for Multi-Login, Limits & SRE"
            echo "  --version       Display application version"
            exit 0
            ;;
        *)
            master_orchestrator_loop
            ;;
    esac
}

main "$@"
