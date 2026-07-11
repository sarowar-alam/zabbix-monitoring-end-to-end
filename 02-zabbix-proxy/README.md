# Zabbix 7.0 LTS — Proxy

**Instance:** `zabbix-proxy` · t3.small · Ubuntu 24.04 · Private subnet  
**Database:** SQLite3 (local buffer — no separate DB server needed)  
**Mode:** Active (ProxyMode=0) — proxy dials OUT to server on TCP 10051  
**Encryption:** PSK (pre-shared key) between proxy and server  
**Also monitored as:** A host in Zabbix UI (server polls proxy agent on TCP 10050)

---

## Automated Install

```bash
# SSM into the proxy
aws ssm start-session --target <zabbix-proxy-instance-id> \
    --profile sarowar-ostad --region ap-south-1

sudo -s
git clone https://github.com/sarowar-alam/zabbix-monitoring-end-to-end.git
cd zabbix-monitoring-end-to-end
bash 02-zabbix-proxy/install-proxy.sh '10.0.1.x'   # replace with server private IP
```

---

## Manual Install

### Step 1 — System Update and Zabbix Repository

```bash
sudo -s
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb \
     -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb
apt-get update -y
```

### Step 2 — Install Packages

```bash
apt-get install -y zabbix-proxy-sqlite3 zabbix-agent zabbix-sender
```

> `zabbix-agent` is installed so the server can monitor this proxy instance.

### Step 3 — Create SQLite3 Database Directory

```bash
mkdir -p /var/lib/zabbix
chown zabbix:zabbix /var/lib/zabbix
chmod 750 /var/lib/zabbix
```

### Step 4 — Generate PSK Encryption Key

```bash
openssl rand -hex 32 > /etc/zabbix/zabbix_proxy.psk
chown zabbix:zabbix /etc/zabbix/zabbix_proxy.psk
chmod 640 /etc/zabbix/zabbix_proxy.psk

# Save this value — you need it when registering the proxy in Zabbix UI
cat /etc/zabbix/zabbix_proxy.psk
```

### Step 5 — Write `/etc/zabbix/zabbix_proxy.conf`

Replace `10.0.1.x` with the actual Zabbix server private IP.

```bash
cat > /etc/zabbix/zabbix_proxy.conf <<'EOF'
# Zabbix Proxy 7.0 — /etc/zabbix/zabbix_proxy.conf

# ── Core ──────────────────────────────────────────────────────────────────────
ProxyMode=0
Server=10.0.1.x
Hostname=ZabbixProxy01

# ── Database (SQLite3) ────────────────────────────────────────────────────────
DBName=/var/lib/zabbix/zabbix_proxy.db

# ── Network ───────────────────────────────────────────────────────────────────
ListenPort=10051
ConfigFrequency=60
DataSenderFrequency=1

# ── Buffer ────────────────────────────────────────────────────────────────────
ProxyBufferMode=hybrid
ProxyMemoryBufferSize=16M

# ── Logging ───────────────────────────────────────────────────────────────────
LogFile=/var/log/zabbix/zabbix_proxy.log
LogFileSize=0
PidFile=/run/zabbix/zabbix_proxy.pid
SocketDir=/run/zabbix

# ── Timeouts & Paths ──────────────────────────────────────────────────────────
Timeout=4
FpingLocation=/usr/bin/fping
Fping6Location=/usr/bin/fping6
LogSlowQueries=3000
SNMPTrapperFile=/var/log/snmptrap/snmptrap.log
StatsAllowedIP=127.0.0.1

# ── PSK Encryption ────────────────────────────────────────────────────────────
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=ZabbixProxy01
TLSPSKFile=/etc/zabbix/zabbix_proxy.psk

# ── Include ───────────────────────────────────────────────────────────────────
Include=/etc/zabbix/zabbix_proxy.d/*.conf
EOF
```

### Step 6 — Write `/etc/zabbix/zabbix_agentd.conf`

The agent on this instance is polled by the **server** directly (not through the proxy itself).  
Replace `10.0.1.x` with the actual server private IP.

```bash
cat > /etc/zabbix/zabbix_agentd.conf <<'EOF'
# Zabbix Agent on zabbix-proxy — polled directly by server (passive mode)

PidFile=/run/zabbix/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
LogFileSize=0

# Server polls this agent on :10050 (passive mode — no ServerActive)
Server=10.0.1.x
# ServerActive disabled — passive mode only
Hostname=zabbix-proxy

Include=/etc/zabbix/zabbix_agentd.d/*.conf
EOF
```

### Step 7 — Enable and Start Services

```bash
systemctl enable  zabbix-proxy zabbix-agent
systemctl restart zabbix-proxy zabbix-agent
systemctl status  zabbix-proxy zabbix-agent --no-pager | head -10
```

### Step 8 — Verify

```bash
# Proxy log — should show "proxy started" and "sending data"
tail -20 /var/log/zabbix/zabbix_proxy.log

# Agent log
tail -10 /var/log/zabbix/zabbix_agentd.log
```

---

## Register Proxy in Zabbix UI (with PSK)

1. **Administration → Proxies → Create proxy**

| Field | Value |
|-------|-------|
| Proxy name | `ZabbixProxy01` (must match `Hostname=` exactly) |
| Proxy mode | Active |

2. **Encryption tab:**

| Field | Value |
|-------|-------|
| Connections from proxy | PSK |
| PSK identity | `ZabbixProxy01` |
| PSK | *(paste the 64-character hex value from `/etc/zabbix/zabbix_proxy.psk`)* |

3. Click **Add**

**Verify:** In the proxy list, **Last seen** updates within 60 seconds.

---

## Add Proxy as a Monitored Host

The proxy instance itself should be monitored by the Zabbix server.

**Configuration → Hosts → Create host**

| Tab | Field | Value |
|-----|-------|-------|
| Host | Host name | `zabbix-proxy` |
| Host | Monitored by proxy | *(leave empty — server polls it directly)* |
| Host | Groups | `Linux servers` |
| Interfaces | Type | Agent |
| Interfaces | IP address | `<zabbix-proxy private IP>` |
| Interfaces | Port | `10050` |
| Templates | | `Linux by Zabbix agent` |

Click **Add**. The host will go green once the server polls it on TCP 10050.

> **Security group note:** The server SG must be allowed to reach the proxy SG on TCP 10050.  
> If using `show-infra.ps1 --create`, this rule is applied automatically.

---

## Troubleshooting

```bash
# Proxy not connecting to server
journalctl -u zabbix-proxy -n 30

# PSK mismatch
grep -i "psk\|tls\|encrypt" /var/log/zabbix/zabbix_proxy.log

# Agent not responding
zabbix_agentd -t system.uptime
journalctl -u zabbix-agent -n 20

# Check open ports
ss -tlnp | grep -E '10050|10051'
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `install-proxy.sh` | Automated install script (idempotent) |
| `zabbix_proxy.conf.template` | Config template with placeholders |
