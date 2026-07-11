# Zabbix 7.0 LTS — Linux Agent (Direct to Server)

**Instance:** `linux-agent-direct` · t3.micro · Ubuntu 24.04 · Private subnet  
**Monitored by:** Zabbix Server directly — server polls this agent on TCP 10050 (passive mode)  
**No proxy** — data flows: agent → server (bypasses the proxy entirely)

> **Visual difference in Zabbix UI:** In the Hosts list, the **Proxy** column is **empty** for this host,  
> while `linux-agent-proxy` shows `ZabbixProxy01`. This confirms the direct connection.

---

## Automated Install

```bash
aws ssm start-session --target <linux-agent-direct-instance-id> \
    --profile sarowar-ostad --region ap-south-1

sudo -s
git clone https://github.com/sarowar-alam/zabbix-monitoring-end-to-end.git
cd zabbix-monitoring-end-to-end
bash 04-agent-linux-direct/install-agent-linux-direct.sh '10.0.1.x'   # server private IP
```

---

## Manual Install

### Step 1 — Add Zabbix Repository and Install Agent

```bash
sudo -s
export DEBIAN_FRONTEND=noninteractive
apt-get update -y

wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb \
     -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb
apt-get update -y

apt-get install -y zabbix-agent zabbix-sender
```

### Step 2 — Write `/etc/zabbix/zabbix_agentd.conf`

Replace `10.0.1.x` with the actual Zabbix **server** private IP.

```bash
cat > /etc/zabbix/zabbix_agentd.conf <<'EOF'
# Zabbix Agent — linux-agent-direct
# Passive mode: server polls this agent directly on TCP 10050 (no proxy)

PidFile=/run/zabbix/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
LogFileSize=0

# Server is allowed to poll this agent (passive checks)
Server=10.0.1.x
# ServerActive disabled — passive mode only

Hostname=linux-agent-direct

# Performance
StartAgents=3
Timeout=3
MaxLinesPerSecond=20
RefreshActiveChecks=120
BufferSend=5
BufferSize=100

Include=/etc/zabbix/zabbix_agentd.d/*.conf
EOF

mkdir -p /etc/zabbix/zabbix_agentd.d
```

### Step 3 — Enable and Start

```bash
systemctl enable zabbix-agent
systemctl restart zabbix-agent
systemctl status  zabbix-agent --no-pager | head -5
```

### Step 4 — Verify

```bash
zabbix_agentd -t system.uptime
tail -10 /var/log/zabbix/zabbix_agentd.log
```

---

## Add Host in Zabbix UI

**Configuration → Hosts → Create host**

| Tab | Field | Value |
|-----|-------|-------|
| Host | Host name | `linux-agent-direct` |
| Host | Monitored by proxy | *(leave empty — direct to server)* |
| Host | Groups | `Linux servers` |
| Interfaces | Type | Agent |
| Interfaces | IP address | `<linux-agent-direct private IP>` |
| Interfaces | Port | `10050` |
| Interfaces | Connect to | IP |
| Templates | | `Linux by Zabbix agent` |

Click **Add**. The server will poll the agent on TCP 10050 within 60 seconds.

---

## Sender Config (for Scheduled Task Alerting)

Sender config points to the **server** (not proxy), since this agent bypasses the proxy:

```bash
cat > /etc/zabbix/sender.conf <<'EOF'
# Zabbix Sender config — linux-agent-direct
# Sends task status values directly to the server (trapper port 10051)
ZABBIX_TARGET_IP=10.0.1.x
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=linux-agent-direct
EOF

mkdir -p /opt/zabbix
cp 06-zabbix-sender/task-linux.sh /opt/zabbix/task-linux.sh
chmod +x /opt/zabbix/task-linux.sh
```

See [06-zabbix-sender/README.md](../06-zabbix-sender/README.md) for trapper items and triggers.

---

## Troubleshooting

```bash
# Agent not responding
journalctl -u zabbix-agent -n 30
ss -tlnp | grep 10050

# Test from server instance:
# zabbix_get -s <linux-agent-direct-ip> -p 10050 -k system.uptime

# Verify Server= points to server (not proxy)
grep '^Server=' /etc/zabbix/zabbix_agentd.conf
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `install-agent-linux-direct.sh` | Automated install script |
| `zabbix_agentd.conf.template` | Config template with placeholders |
