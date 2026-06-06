#!/bin/bash
# =============================================================================
# Zabbix 7.0 LTS Proxy Installation — Ubuntu 24.04
# =============================================================================
# Run as root on the zabbix-proxy EC2 instance (private subnet).
#
# Usage:
#   sudo bash install-proxy.sh <ZABBIX_SERVER_PRIVATE_IP>
#
# Example:
#   sudo bash install-proxy.sh "10.0.1.x"
#
# Notes:
#   - Uses SQLite3 as the local buffer database (no separate DB server needed)
#   - ProxyMode=0 (active) — proxy connects OUT to the server on port 10051
#   - Server must be running and the proxy must be registered in the Zabbix UI
#     BEFORE starting this service (or immediately after — proxy will retry)
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must be run as root or with sudo." >&2
  exit 1
fi

SERVER_IP="${1:?ERROR: Zabbix server private IP required. Usage: sudo bash $0 <SERVER_PRIVATE_IP>}"
PROXY_HOSTNAME="ZabbixProxy01"
ZABBIX_VERSION="7.0"
ZABBIX_REPO_DEB="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+ubuntu24.04_all.deb"

echo "============================================================"
echo "  Zabbix ${ZABBIX_VERSION} Proxy Installation"
echo "  Server IP : ${SERVER_IP}"
echo "  Hostname  : ${PROXY_HOSTNAME}"
echo "============================================================"

# ── 1. System Update ──────────────────────────────────────────────────────────
echo "--> [1/5] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get upgrade -y -q

# ── 2. Add Zabbix Repository ──────────────────────────────────────────────────
echo "--> [2/5] Adding Zabbix ${ZABBIX_VERSION} repository..."
if ! dpkg -l zabbix-release &>/dev/null; then
  wget -q "${ZABBIX_REPO_DEB}" -O /tmp/zabbix-release.deb
  dpkg -i /tmp/zabbix-release.deb
  apt-get update -y -q
  rm -f /tmp/zabbix-release.deb
  echo "    Repository added."
else
  echo "    Repository already installed — skipping."
fi

# ── 3. Install Zabbix Proxy (SQLite3) ─────────────────────────────────────────
echo "--> [3/5] Installing zabbix-proxy-sqlite3..."
apt-get install -y -q zabbix-proxy-sqlite3 zabbix-sender

# ── 4. Configure zabbix_proxy.conf ────────────────────────────────────────────
echo "--> [4/5] Configuring /etc/zabbix/zabbix_proxy.conf..."

PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
DB_DIR="/var/lib/zabbix"
DB_FILE="${DB_DIR}/zabbix_proxy.db"

# Create DB directory
mkdir -p "${DB_DIR}"
chown -R zabbix:zabbix "${DB_DIR}"

# Apply settings (handles both commented and active lines)
apply_conf() {
  local key="$1" value="$2" file="$3"
  if grep -qE "^[# ]*${key}=" "${file}"; then
    sed -i -E "s|^[# ]*${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

apply_conf "ProxyMode"  "0"                 "${PROXY_CONF}"   # 0=active (proxy → server)
apply_conf "Server"     "${SERVER_IP}"      "${PROXY_CONF}"
apply_conf "Hostname"   "${PROXY_HOSTNAME}" "${PROXY_CONF}"
apply_conf "DBName"     "${DB_FILE}"        "${PROXY_CONF}"
apply_conf "LogFile"    "/var/log/zabbix/zabbix_proxy.log" "${PROXY_CONF}"
apply_conf "PidFile"    "/run/zabbix/zabbix_proxy.pid"     "${PROXY_CONF}"
apply_conf "SocketDir"  "/run/zabbix"       "${PROXY_CONF}"

echo "    Configuration applied."

# ── 5. Enable and Start Proxy ─────────────────────────────────────────────────
echo "--> [5/5] Enabling and starting zabbix-proxy..."
systemctl enable  zabbix-proxy
systemctl restart zabbix-proxy

# ── Status Report ─────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Installation Complete!"
echo "============================================================"
if systemctl is-active --quiet zabbix-proxy; then
  echo "  [OK] zabbix-proxy — running"
else
  echo "  [!!] zabbix-proxy — NOT running"
  echo "       Check: journalctl -u zabbix-proxy -n 30"
fi
echo ""
echo "  Server  : ${SERVER_IP}:10051"
echo "  Hostname: ${PROXY_HOSTNAME}"
echo "  DB file : ${DB_FILE}"
echo ""
echo "  IMPORTANT — Register proxy in Zabbix UI:"
echo "    Administration → Proxies → Create proxy"
echo "    Name: ${PROXY_HOSTNAME}   Mode: Active"
echo ""
echo "  After registration, check 'Last seen' updates within 60 seconds."
echo "============================================================"
