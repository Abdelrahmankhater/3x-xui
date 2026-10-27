# Enterprise Xray, SSH & Multi-Protocol VPN/Proxy Management Suite

A production-grade, highly optimized, and modular automation suite engineered specifically for **Ubuntu 24.04 LTS (Noble Numbat)** to deploy and manage high-throughput proxy accounts (VMess, VLESS, Trojan, Shadowsocks) and high-concurrency SSH tunneling with BadVPN UDP Gateway for low-latency gaming and anti-censorship bypassing.

---

## 🏗️ Architecture & Module Structure

```
vps-proxy-manager/
├── main.sh                          # Master TUI/CLI Orchestrator & Shortcut Linker (Module 6)
├── xray-manager.sh                  # Monolithic all-in-one fallback script
├── README.md                        # Documentation & quick deployment guide
└── modules/
    ├── module1_core_shield.sh       # Kernel BBR, Extreme Concurrency, Camouflage Site & Nginx
    ├── module2_xray_engine.sh       # Xray-Core Binary, gRPC Stats API (10085) & Inbounds
    ├── module3_user_engine.sh       # JSON User Lifecycle, Quota Ingestion & URI/QR Generator
    ├── module4_ssh_badvpn_engine.sh # OpenSSH Tunneling, BadVPN UDPGW (7300) & Multi-Login Killer
    └── module5_reliability_engine.sh# Certbot SSL HTTP-01, Renewal Hooks & Self-Healing Watchdog
```

---

## ⚡ Quick Start & Deployment Guide

### Prerequisites
* A fresh VPS running **Ubuntu 24.04 LTS (Noble Numbat)**.
* Root privileges (`sudo -i`).
* (Optional) A registered domain pointed to your VPS IP (e.g. `vpn.example.com`). If not set, the suite defaults to `<public-ip>.nip.io` with an automated ECC self-signed fallback.

### 1. Download & Prepare the Suite on VPS
```bash
# Update APT index and install Git/curl
apt-get update -y && apt-get install -y git curl

# Clone or copy the repository to /etc/xray-manager
git clone https://github.com/your-repo/vps-proxy-manager.git /etc/xray-manager

# Grant execution permissions
chmod +x /etc/xray-manager/main.sh /etc/xray-manager/modules/*.sh

# Run the master orchestrator
/etc/xray-manager/main.sh
```

### 2. Accessing the Dashboard Anytime
Once launched, the orchestrator automatically links global shortcuts:
```bash
menu
# or
xray-manager
```

---

## 📊 Live Dashboard & Menu Preview

```text
┌────────────────────────────────────────────────────────────────────────┐
│ ENTERPRISE XRAY & SSH PROXY SUITE - v3.5.0-LTS [Aetheris Mesh Core]    │
├────────────────────────────────────────────────────────────────────────┤
│  Hostname      : vps-node-01          Kernel      : 6.8.0-31-generic   │
│  Server IP     : 198.51.100.25        Domain      : vpn.example.com    │
│  CPU Load      : 1.2%                 Memory      : 512/2048 MB (25%)  │
│  System Uptime : 14 days, 3 hours     Accounts    : Xray: 12 | SSH: 6  │
├────────────────────────────────────────────────────────────────────────┤
│  Services: Xray[ON] Nginx[ON] SSH[ON] BadVPN[ON] MultiLog[ON] Watchdog[ON] │
└────────────────────────────────────────────────────────────────────────┘
 [USER & PROTOCOL MANAGEMENT]
   [1] Manage V2Ray/Xray Accounts  (VMess, VLESS, Trojan, Shadowsocks)
   [2] Manage Linux SSH & BadVPN    (Direct SSH, BadVPN 7300, MultiLog)
   [3] SSL Certificate Management   (Certbot HTTP-01, Renewal Hooks)

 [CORE INFRASTRUCTURE & NETWORK SECURITY]
   [4] Core Shield & Firewall       (Kernel BBR, Camouflage Web, UFW)
   [5] Xray Engine & gRPC Status    (Inbound Audits, API Socket 10085)
   [6] Run System Maintenance       (Memory Flush, Journal & Log Vacuum)
   [7] View System Audit Logs       (Watchdog Telemetry, Multi-Login)

 [AUTOMATED DEPLOYMENT & SHORTCUTS]
   [8] Full One-Click Stack Setup  (Automated 5-Module Fresh VPS Deploy)
   [0] Exit Management Console
```

---

## 🔒 Master Port Matrix

| Service / Tag | External Port | Internal Proxy Port | Stream Settings | Target Destination |
| :--- | :--- | :--- | :--- | :--- |
| **OpenSSH Direct** | `22` | Direct | TCP | Standard SSH Access |
| **BadVPN UDPGW** | `7300` | Direct | UDP | Mobile Gaming & VoIP UDP Forwarding |
| **VMess WS (TLS)** | `443` | `127.0.0.1:10001` | WS (`/vmess`) | Cloudflare CDN & Direct TLS |
| **VMess WS (Plain)** | `80, 8080, 8880, 2082, 2086` | `127.0.0.1:10001` | WS (`/vmess`) | Cloudflare CDN Plain HTTP |
| **VLESS WS (TLS)** | `443` | `127.0.0.1:10002` | WS (`/vless`) | Cloudflare CDN & Direct TLS |
| **VLESS WS (Plain)** | `80, 8080, 8880, 2082, 2086` | `127.0.0.1:10002` | WS (`/vless`) | Cloudflare CDN Plain HTTP |
| **Trojan WS (TLS)** | `443` | `127.0.0.1:10003` | WS (`/trojan`) | Cloudflare CDN & Direct TLS |
| **Trojan Direct TLS** | `442` | Direct Xray | TCP + TLS | Direct IP / SNI Bypass |
| **SSH Dokodemo WS** | `80, 443, 8080, 8880` | `127.0.0.1:10004` | WS (`/ssh`) | Pipes TCP to OpenSSH `127.0.0.1:22` |
| **Shadowsocks AEAD** | `8388` | Direct Xray | TCP + UDP | Native AES-256-GCM |
| **gRPC Stats API** | `127.0.0.1:10085` | Internal Loopback | gRPC / Dokodemo | Telemetry & Quota Enforcement |

---

## 🛠️ Individual Module Command-Line Triggers

Each module can also be invoked independently from the command line:

```bash
# Module 1: Kernel BBR & Camouflage Site
/etc/xray-manager/modules/module1_core_shield.sh

# Module 2: Xray Binary & Engine Health
/etc/xray-manager/modules/module2_xray_engine.sh

# Module 3: List users or force usage sync
/etc/xray-manager/modules/module3_user_engine.sh --list
/etc/xray-manager/modules/module3_user_engine.sh --sync

# Module 4: List SSH accounts or inspect Multi-Login logs
/etc/xray-manager/modules/module4_ssh_badvpn_engine.sh --list
/etc/xray-manager/modules/module4_ssh_badvpn_engine.sh --logs

# Module 5: Issue SSL certificate or run system maintenance
/etc/xray-manager/modules/module5_reliability_engine.sh --issue-ssl vpn.example.com admin@example.com
/etc/xray-manager/modules/module5_reliability_engine.sh --maintenance
```

---

## 📄 License
Licensed under the MIT License. Designed for production edge privacy, high concurrency, and autonomous SRE reliability.
