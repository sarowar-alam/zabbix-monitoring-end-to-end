#!/bin/bash
# =============================================================================
# Zabbix 7.0 LTS Agent Installation — Linux Direct to Server
# =============================================================================
# Run as root on the linux-agent-direct EC2 instance (private subnet).
#
# Usage:
#   sudo bash install-agent-linux-direct.sh <SERVER_PRIVATE_IP>
#
# Example:
#   sudo bash install-agent-linux-direct.sh "10.0.1.x"
#
# This agent:
#   - Runs in ACTIVE mode  (agent dials OUT to SERVER directly on port 10051)
#   - Bypasses the Zabbix Proxy entirely
#   - Demonstrates the direct agent ↔ server topology (no proxy hop)
#   - No inbound port 10050 is needed on this instance's security group
# =============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Must be run as root or with sudo." >&2
  exit 1
fi

SERVER_IP="${1:?ERROR: Server private IP required. Usage: sudo bash $0 <SERVER_PRIVATE_IP>}"
THIS_HOSTNAME="linux-agent-direct"
ZABBIX_VERSION="7.0"
ZABBIX_REPO_DEB="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_${ZABBIX_VERSION}+ubuntu24.04_all.deb"

echo "============================================================"
echo "  Zabbix ${ZABBIX_VERSION} Agent Installation (Direct to Server)"
echo "  Server IP : ${SERVER_IP}"
echo "  Hostname  : ${THIS_HOSTNAME}"
echo "============================================================"

export DEBIAN_FRONTEND=noninteractive

# ── 1. System Update ──────────────────────────────────────────────────────────
echo "--> [1/4] Updating system packages..."
apt-get update -y -q
apt-get upgrade -y -q

# ── 2. Add Zabbix Repository ──────────────────────────────────────────────────
echo "--> [2/4] Adding Zabbix ${ZABBIX_VERSION} repository..."
if ! dpkg -l zabbix-release &>/dev/null; then
  wget -q "${ZABBIX_REPO_DEB}" -O /tmp/zabbix-release.deb
  dpkg -i /tmp/zabbix-release.deb
  apt-get update -y -q
  rm -f /tmp/zabbix-release.deb
fi

# ── 3. Install Zabbix Agent + Sender ─────────────────────────────────────────
echo "--> [3/4] Installing zabbix-agent and zabbix-sender..."
apt-get install -y -q zabbix-agent zabbix-sender

# ── 4. Configure zabbix_agentd.conf ──────────────────────────────────────────
echo "--> [4/4] Configuring /etc/zabbix/zabbix_agentd.conf..."

AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"

apply_conf() {
  local key="$1" value="$2" file="$3"
  if grep -qE "^[# ]*${key}=" "${file}"; then
    sed -i -E "s|^[# ]*${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

# Server = server private IP (no proxy in the path)
apply_conf "Server"              "${SERVER_IP}"      "${AGENT_CONF}"
# ServerActive = server private IP (agent dials OUT directly to the server)
apply_conf "ServerActive"        "${SERVER_IP}"      "${AGENT_CONF}"
apply_conf "Hostname"            "${THIS_HOSTNAME}"   "${AGENT_CONF}"
apply_conf "LogFile"             "/var/log/zabbix/zabbix_agentd.log" "${AGENT_CONF}"
apply_conf "PidFile"             "/run/zabbix/zabbix_agentd.pid"     "${AGENT_CONF}"
apply_conf "Include"             "/etc/zabbix/zabbix_agentd.d/*.conf" "${AGENT_CONF}"

mkdir -p /etc/zabbix/zabbix_agentd.d

# ── Write sender config for task wrapper ─────────────────────────────────────
SENDER_CONF="/etc/zabbix/sender.conf"
cat > "${SENDER_CONF}" <<EOF
# Zabbix Sender configuration
# Used by /opt/zabbix/task-linux.sh
# For this host: sender sends directly to the Zabbix SERVER (no proxy hop)
ZABBIX_TARGET_IP=${SERVER_IP}
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=${THIS_HOSTNAME}
EOF
chmod 644 "${SENDER_CONF}"
echo "    Sender config written to ${SENDER_CONF}"

# ── Enable and Start Agent ────────────────────────────────────────────────────
systemctl enable  zabbix-agent
systemctl restart zabbix-agent

# ── Install task wrapper ──────────────────────────────────────────────────────
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SENDER_SCRIPT="${SCRIPT_DIR}/../06-zabbix-sender/task-linux.sh"
if [[ -f "${SENDER_SCRIPT}" ]]; then
  mkdir -p /opt/zabbix
  cp "${SENDER_SCRIPT}" /opt/zabbix/task-linux.sh
  chmod +x /opt/zabbix/task-linux.sh
  echo "    task-linux.sh installed to /opt/zabbix/"
else
  echo "    NOTE: Copy 06-zabbix-sender/task-linux.sh to /opt/zabbix/task-linux.sh manually."
fi

# ── Status Report ─────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Installation Complete!"
echo "============================================================"
if systemctl is-active --quiet zabbix-agent; then
  echo "  [OK] zabbix-agent — running"
else
  echo "  [!!] zabbix-agent — NOT running"
  echo "       Check: journalctl -u zabbix-agent -n 30"
fi
echo ""
echo "  Server IP : ${SERVER_IP}:10051  (direct active connection)"
echo "  Hostname  : ${THIS_HOSTNAME}"
echo ""
echo "  IMPORTANT — Add this host in the Zabbix UI (see INSTALL.md Phase 4):"
echo "    Configuration → Hosts → Create host"
echo "    Host name : ${THIS_HOSTNAME}"
echo "    Monitored by proxy : (leave EMPTY — direct to server)"
echo "    Template  : Linux by Zabbix agent"
echo "============================================================"
