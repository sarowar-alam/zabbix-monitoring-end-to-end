# Zabbix 7.0 LTS — Linux Agent (via Proxy)

**Instance:** `linux-agent-proxy` · t3.micro · Ubuntu 24.04 · Private subnet  
**Monitored by:** `ZabbixProxy01` — proxy polls this agent on TCP 10050 (passive mode)  
**Reports to:** Proxy → Server (data flows: agent → proxy → server)

---

## Automated Install

```bash
aws ssm start-session --target <linux-agent-proxy-instance-id> \
    --profile sarowar-ostad --region ap-south-1

sudo -s
git clone https://github.com/sarowar-alam/zabbix-monitoring-end-to-end.git
cd zabbix-monitoring-end-to-end
bash 03-agent-linux-proxy/install-agent-linux-proxy.sh '10.0.2.x'   # proxy private IP
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

Replace `10.0.2.x` with the actual Zabbix proxy private IP.

```bash
cat > /etc/zabbix/zabbix_agentd.conf <<'EOF'
# Zabbix Agent — linux-agent-proxy
# Passive mode: proxy polls this agent on TCP 10050

PidFile=/run/zabbix/zabbix_agentd.pid
LogFile=/var/log/zabbix/zabbix_agentd.log
LogFileSize=0

# Proxy is allowed to poll this agent (passive checks)
Server=10.0.2.x
# ServerActive disabled — passive mode only

Hostname=linux-agent-proxy

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
# Test a local item
zabbix_agentd -t system.uptime
zabbix_agentd -t system.hostname

# Check log
tail -10 /var/log/zabbix/zabbix_agentd.log
```

---

## Add Host in Zabbix UI

**Configuration → Hosts → Create host**

| Tab | Field | Value |
|-----|-------|-------|
| Host | Host name | `linux-agent-proxy` |
| Host | Monitored by proxy | `ZabbixProxy01` |
| Host | Groups | `Linux servers` |
| Interfaces | Type | Agent |
| Interfaces | IP address | `<linux-agent-proxy private IP>` |
| Interfaces | Port | `10050` |
| Interfaces | Connect to | IP |
| Templates | | `Linux by Zabbix agent` |

Click **Add**. The proxy will poll the agent within 60 seconds and the host goes green.

> **Visual confirmation:** In the Hosts list, the **Proxy** column shows `ZabbixProxy01` for this host.  
> Compare with `linux-agent-direct` which shows nothing in that column.

---

## Sender Config (for Scheduled Task Alerting)

After installing, write the sender config used by `task-linux.sh`:

```bash
cat > /etc/zabbix/sender.conf <<'EOF'
# Zabbix Sender config — linux-agent-proxy
# Sends task status values to the proxy (trapper port 10051)
ZABBIX_TARGET_IP=10.0.2.x
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=linux-agent-proxy
EOF
```

Copy the task wrapper:
```bash
mkdir -p /opt/zabbix
cp 06-zabbix-sender/task-linux.sh /opt/zabbix/task-linux.sh
chmod +x /opt/zabbix/task-linux.sh
```

See [06-zabbix-sender/README.md](../06-zabbix-sender/README.md) for how to create trapper items and triggers.

---

## Troubleshooting

```bash
# Agent not responding to proxy polls
journalctl -u zabbix-agent -n 30

# Test if proxy can reach agent
# Run from proxy instance:
# zabbix_get -s <linux-agent-proxy-ip> -p 10050 -k system.uptime

# Check listening port
ss -tlnp | grep 10050

# Verify Server= line matches proxy IP
grep '^Server=' /etc/zabbix/zabbix_agentd.conf
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `install-agent-linux-proxy.sh` | Automated install script |
| `zabbix_agentd.conf.template` | Config template with placeholders |
