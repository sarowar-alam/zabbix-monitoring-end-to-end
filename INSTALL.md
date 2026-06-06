# Zabbix Monitoring End-to-End — Complete Installation Guide

**Stack:** Zabbix 7.0 LTS · Ubuntu 24.04 · AWS ap-south-1 · SSM Session Manager

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Architecture Overview](#2-architecture-overview)
3. [Phase 0 — AWS Infrastructure](#3-phase-0--aws-infrastructure)
4. [Phase 1 — Zabbix Server](#4-phase-1--zabbix-server)
5. [Phase 2 — Zabbix Proxy](#5-phase-2--zabbix-proxy)
6. [Phase 3 — Linux Agent via Proxy](#6-phase-3--linux-agent-via-proxy)
7. [Phase 4 — Linux Agent Direct to Server](#7-phase-4--linux-agent-direct-to-server)
8. [Phase 5 — Windows Agent via Proxy](#8-phase-5--windows-agent-via-proxy)
9. [Phase 6 — Scheduled Task Alerting (Zabbix Sender)](#9-phase-6--scheduled-task-alerting-zabbix-sender)
10. [Verification Checklist](#10-verification-checklist)
11. [Dashboard Guide — What to Expect](#11-dashboard-guide--what-to-expect)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Prerequisites

### On your Windows 11 laptop

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI v2 | 2.x | `winget install Amazon.AWSCLI` |
| AWS Session Manager Plugin | latest | [Download MSI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) |
| PowerShell | 5.1+ | Built-in on Windows 11 |

Verify AWS profile is configured:
```powershell
aws sts get-caller-identity --profile sarowar-ostad
```
Expected: returns your Account ID and ARN.

### Execution Policy
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## 2. Architecture Overview

```
Your Laptop (Windows 11)
       │  aws --profile sarowar-ostad --region ap-south-1
       │  show-infra.ps1 --create
       ▼
┌──────────────────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16   AWS ap-south-1 (Mumbai)                      │
│                                                                  │
│  PUBLIC subnet 10.0.1.0/24                                       │
│  ┌─────────────────────────────────┐                             │
│  │  zabbix-server  (t3.medium)     │◄─── http://<EIP>:8080       │
│  │  Ubuntu 24.04                   │     (web UI from internet)  │
│  │  PostgreSQL 16 + Nginx + UI     │                             │
│  └─────────────────────────────────┘                             │
│    ▲ :10051  (proxy active check-in)                             │
│    ▲ :10051  (linux-agent-direct active send)                    │
│  NAT GW  ←── private subnet internet egress                      │
│                                                                  │
│  PRIVATE subnet 10.0.2.0/24                                      │
│  ┌───────────────┐  ┌──────────────────┐  ┌───────────────────┐  │
│  │ zabbix-proxy  │◄─│linux-agent-proxy │  │linux-agent-direct │  │
│  │ t3.small      │  │t3.micro          │  │t3.micro           │  │
│  │ Ubuntu 24.04  │  │Ubuntu 24.04      │  │Ubuntu 24.04       │  │
│  │ SQLite3       │  │active → proxy    │  │active → server    │  │
│  └───────┬───────┘  └──────────────────┘  └───────────────────┘  │
│          │ active :10051                                         │
│  ┌───────▼───────┐                                               │
│  │windows-agent-01│                                              │
│  │t3.medium       │                                              │
│  │WinSrv 2022     │                                              │
│  │active → proxy  │                                              │
│  └────────────────┘                                              │
│  All 5 instances: IAM SSM role + user data SSM confirmation      │
└──────────────────────────────────────────────────────────────────┘
```

**Key networking rules:**
- All agents run in **active mode** — they dial OUT. No inbound Zabbix ports on agent SGs.
- `linux-agent-proxy` and `windows-agent-01` → connect to **proxy** on port 10051
- `linux-agent-direct` → connects directly to **server** on port 10051 (no proxy)
- Proxy → server: **private IP** (same VPC, no NAT needed)
- Access method: **SSM Session Manager only** (no SSH keys, no bastion)

---

## 3. Phase 0 — AWS Infrastructure

### 3.1 Automated (recommended)

```powershell
cd "c:\...\zabbix-monitoring-end-to-end"

# Create everything (takes ~5-7 minutes)
.\show-infra.ps1 --create

# Check status at any time
.\show-infra.ps1 --status

# Tear everything down when done
.\show-infra.ps1 --teardown
```

After `--create`, the output shows all IPs. Also written to `infra-state.json`:
```json
{
  "server_eip_public_ip": "X.X.X.X",
  "instances": {
    "zabbix-server":      { "instance_id": "i-...", "private_ip": "10.0.1.x", "public_ip": "X.X.X.X" },
    "zabbix-proxy":       { "instance_id": "i-...", "private_ip": "10.0.2.x" },
    "linux-agent-proxy":  { "instance_id": "i-...", "private_ip": "10.0.2.y" },
    "linux-agent-direct": { "instance_id": "i-...", "private_ip": "10.0.2.z" },
    "windows-agent-01":   { "instance_id": "i-...", "private_ip": "10.0.2.w" }
  }
}
```

### 3.2 Manual — AWS Console / CLI steps

If you prefer manual creation, perform these steps in order:

1. **VPC**: Create VPC `10.0.0.0/16`, enable DNS hostnames + DNS resolution.
2. **Subnets**: Public `10.0.1.0/24` (ap-south-1a, auto-assign public IP on) + Private `10.0.2.0/24`.
3. **Internet Gateway**: Create, attach to VPC.
4. **EIPs**: Allocate two — one for NAT GW, one for zabbix-server.
5. **NAT Gateway**: In the public subnet, use the NAT EIP. Wait for "available".
6. **Route tables**:
   - Public RT: route `0.0.0.0/0 → IGW`, associate with public subnet.
   - Private RT: route `0.0.0.0/0 → NAT GW`, associate with private subnet.
7. **IAM role**: Create role `ZabbixSSMRole` with trust for `ec2.amazonaws.com`, attach `AmazonSSMManagedInstanceCore`. Create instance profile `ZabbixSSMProfile` and add the role.
8. **Security Groups** (5 total):

   | SG | Inbound | Outbound |
   |----|---------|----------|
   | `sg-zbx-server` | TCP 8080 from `0.0.0.0/0`; TCP 10051 from `sg-zbx-proxy`; TCP 10051 from `sg-zbx-linux-agent-direct` | All |
   | `sg-zbx-proxy` | TCP 10051 from `sg-zbx-linux-agent-proxy`; TCP 10051 from `sg-zbx-windows-agent` | All |
   | `sg-zbx-linux-agent-proxy` | (none) | All |
   | `sg-zbx-linux-agent-direct` | (none) | All |
   | `sg-zbx-windows-agent` | (none) | All |

9. **EC2 Instances** (with `ZabbixSSMProfile` instance profile attached):

   | Name | AMI | Type | Subnet | User Data |
   |------|-----|------|--------|-----------|
   | `zabbix-server` | Ubuntu 24.04 | t3.medium | public | Linux SSM script below |
   | `zabbix-proxy` | Ubuntu 24.04 | t3.small | private | Linux SSM script below |
   | `linux-agent-proxy` | Ubuntu 24.04 | t3.micro | private | Linux SSM script below |
   | `linux-agent-direct` | Ubuntu 24.04 | t3.micro | private | Linux SSM script below |
   | `windows-agent-01` | Windows Server 2022 | t3.medium | private | Windows SSM script below |

   **Linux user data** (paste in EC2 Launch → Advanced → User data):
   ```bash
   #!/bin/bash
   set -e
   if ! snap list amazon-ssm-agent &>/dev/null 2>&1; then
       snap install amazon-ssm-agent --classic
   fi
   systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
   systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service || true
   ```

   **Windows user data** (paste as PowerShell):
   ```powershell
   <powershell>
   $ssm = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
   if (-not $ssm) {
       $url = 'https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe'
       Invoke-WebRequest -Uri $url -OutFile 'C:\AmazonSSMAgentSetup.exe' -UseBasicParsing
       Start-Process 'C:\AmazonSSMAgentSetup.exe' -ArgumentList '/S' -Wait
   }
   Set-Service  -Name 'AmazonSSMAgent' -StartupType Automatic
   Start-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
   </powershell>
   ```

10. **Associate Server EIP** to `zabbix-server` instance.

### 3.3 Verify SSM access

```powershell
# From your laptop, after instances are running
aws ssm start-session `
    --target <zabbix-server-instance-id> `
    --profile sarowar-ostad `
    --region ap-south-1
```
You should get a shell prompt. Type `exit` to close.

---

## 4. Phase 1 — Zabbix Server

### 4.1 Access the server

```powershell
# Get the instance ID from infra-state.json or --status
aws ssm start-session `
    --target i-XXXXXXXXXXXXXXXXX `
    --profile sarowar-ostad `
    --region ap-south-1
```

### 4.2 Automated install

From the SSM shell on `zabbix-server`:
```bash
# Clone the repo (or upload the scripts via S3)
git clone https://github.com/sarowar-alam/zabbix-monitoring-end-to-end.git
cd zabbix-monitoring-end-to-end

sudo bash 01-zabbix-server/install-server.sh "YourSecurePassword@2025"
```

### 4.3 Manual install (step by step)

```bash
sudo -s
export DEBIAN_FRONTEND=noninteractive

# 1. System update
apt-get update -y && apt-get upgrade -y

# 2. Install PostgreSQL
apt-get install -y postgresql postgresql-contrib
systemctl enable postgresql && systemctl start postgresql

# 3. Create Zabbix DB user and database
sudo -u postgres psql -c "CREATE USER zabbix WITH PASSWORD 'YourSecurePassword@2025';"
sudo -u postgres createdb -O zabbix zabbix

# 4. Add Zabbix 7.0 repository
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb
apt-get update -y

# 5. Install Zabbix packages
apt-get install -y \
    zabbix-server-pgsql \
    zabbix-frontend-php \
    php8.3-pgsql \
    zabbix-nginx-conf \
    zabbix-sql-scripts \
    zabbix-agent \
    zabbix-sender

# 6. Import schema
zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | sudo -u zabbix psql zabbix

# 7. Set DB password in server config
sed -i -E "s|^[# ]*DBPassword=.*|DBPassword=YourSecurePassword@2025|" /etc/zabbix/zabbix_server.conf

# 8. Configure Nginx — uncomment listen and server_name
PRIVATE_IP=$(hostname -I | awk '{print $1}')
sed -i -E 's|^[[:space:]]*#[[:space:]]*(listen[[:space:]]+8080;)|\t\1|' /etc/zabbix/nginx.conf
sed -i -E "s|^[[:space:]]*#[[:space:]]*(server_name[[:space:]]+).*;|\tserver_name ${PRIVATE_IP};|" /etc/zabbix/nginx.conf
rm -f /etc/nginx/sites-enabled/default

# 9. Enable and start services
systemctl enable  zabbix-server zabbix-agent nginx php8.3-fpm
systemctl restart zabbix-server zabbix-agent nginx php8.3-fpm

# 10. Verify
systemctl status zabbix-server --no-pager
```

### 4.4 Web Setup Wizard

Open in your browser: `http://<server-EIP>:8080`

Step through the 7-step wizard:
1. **Welcome** — click Next
2. **Check prerequisites** — all should be OK (green)
3. **Configure DB connection**:
   - Database type: PostgreSQL
   - Database host: `localhost`
   - Database port: `0` (default 5432)
   - Database name: `zabbix`
   - User: `zabbix`
   - Password: `YourSecurePassword@2025`
4. **Zabbix server details**:
   - Host: `localhost`
   - Port: `10051`
   - Name: `Zabbix Server`
5. **GUI settings**: timezone = `Asia/Kolkata` (IST), theme = default
6. **Pre-installation summary** — review and click Next
7. **Install** — click Finish

**Login**: `Admin` / `zabbix` — **Change the password immediately** (User settings → top right → Change password)

---

## 5. Phase 2 — Zabbix Proxy

### 5.1 Access the proxy

```powershell
aws ssm start-session --target i-PROXY_INSTANCE_ID --profile sarowar-ostad --region ap-south-1
```

### 5.2 Automated install

```bash
cd zabbix-monitoring-end-to-end
sudo bash 02-zabbix-proxy/install-proxy.sh "10.0.1.x"   # replace with server private IP
```

### 5.3 Manual install

```bash
sudo -s
export DEBIAN_FRONTEND=noninteractive

# 1. Update and add Zabbix repo (same as server)
apt-get update -y
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb
apt-get update -y

# 2. Install proxy with SQLite3
apt-get install -y zabbix-proxy-sqlite3 zabbix-sender

# 3. Create DB directory
mkdir -p /var/lib/zabbix && chown zabbix:zabbix /var/lib/zabbix

# 4. Configure proxy
SERVER_PRIVATE_IP="10.0.1.x"   # <-- replace with your server private IP

cat >> /etc/zabbix/zabbix_proxy.conf <<EOF
ProxyMode=0
Server=${SERVER_PRIVATE_IP}
Hostname=ZabbixProxy01
DBName=/var/lib/zabbix/zabbix_proxy.db
EOF

# 5. Enable and start
systemctl enable zabbix-proxy && systemctl restart zabbix-proxy
```

### 5.4 Register Proxy in Zabbix UI

1. In the web UI: **Administration → Proxies → Create proxy**
2. Fill in:
   - **Proxy name**: `ZabbixProxy01` (must match exactly)
   - **Proxy mode**: Active
3. Click **Add**

**Verify:** In the proxy list, the "Last seen" column should update within 60 seconds.

---

## 6. Phase 3 — Linux Agent via Proxy

### 6.1 Access the instance

```powershell
aws ssm start-session --target i-LINUX_PROXY_AGENT_ID --profile sarowar-ostad --region ap-south-1
```

### 6.2 Automated install

```bash
cd zabbix-monitoring-end-to-end
sudo bash 03-agent-linux-proxy/install-agent-linux-proxy.sh "10.0.2.x"   # proxy private IP
```

### 6.3 Manual install

```bash
sudo -s
export DEBIAN_FRONTEND=noninteractive

PROXY_IP="10.0.2.x"   # <-- replace with proxy private IP

apt-get update -y
wget https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb
dpkg -i zabbix-release_latest_7.0+ubuntu24.04_all.deb && apt-get update -y

apt-get install -y zabbix-agent zabbix-sender

# Configure agent
sed -i -E "s|^[# ]*Server=.*|Server=${PROXY_IP}|"       /etc/zabbix/zabbix_agentd.conf
sed -i -E "s|^[# ]*ServerActive=.*|ServerActive=${PROXY_IP}|" /etc/zabbix/zabbix_agentd.conf
sed -i -E "s|^[# ]*Hostname=.*|Hostname=linux-agent-proxy|"   /etc/zabbix/zabbix_agentd.conf
echo "Include=/etc/zabbix/zabbix_agentd.d/*.conf" >> /etc/zabbix/zabbix_agentd.conf

mkdir -p /etc/zabbix/zabbix_agentd.d

# Write sender config
cat > /etc/zabbix/sender.conf <<EOF
ZABBIX_TARGET_IP=${PROXY_IP}
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=linux-agent-proxy
EOF

systemctl enable zabbix-agent && systemctl restart zabbix-agent

# Install task wrapper
mkdir -p /opt/zabbix
cp 06-zabbix-sender/task-linux.sh /opt/zabbix/task-linux.sh
chmod +x /opt/zabbix/task-linux.sh
```

### 6.4 Add Host in Zabbix UI

1. **Configuration → Hosts → Create host**
2. **Host** tab:
   - Host name: `linux-agent-proxy`
   - Monitored by proxy: `ZabbixProxy01`
   - Groups: `Linux servers`
3. **Interfaces** tab:
   - Type: Agent
   - IP address: `<linux-agent-proxy private IP>`
   - Port: `10050`
   - Connect to: IP *(passive check interface, even in active mode)*
4. **Templates** tab: click **Select**, search for `Linux by Zabbix agent`, add it
5. Click **Add**

---

## 7. Phase 4 — Linux Agent Direct to Server

### 7.1 Access the instance

```powershell
aws ssm start-session --target i-LINUX_DIRECT_AGENT_ID --profile sarowar-ostad --region ap-south-1
```

### 7.2 Automated install

```bash
cd zabbix-monitoring-end-to-end
sudo bash 04-agent-linux-direct/install-agent-linux-direct.sh "10.0.1.x"   # server private IP
```

### 7.3 Manual install

Same steps as Phase 3 but replace the proxy IP with the **server private IP** and hostname with `linux-agent-direct`:
```bash
SERVER_PRIVATE_IP="10.0.1.x"
sed -i -E "s|^[# ]*Server=.*|Server=${SERVER_PRIVATE_IP}|"          /etc/zabbix/zabbix_agentd.conf
sed -i -E "s|^[# ]*ServerActive=.*|ServerActive=${SERVER_PRIVATE_IP}|" /etc/zabbix/zabbix_agentd.conf
sed -i -E "s|^[# ]*Hostname=.*|Hostname=linux-agent-direct|"            /etc/zabbix/zabbix_agentd.conf
```

Sender config also points to server:
```bash
cat > /etc/zabbix/sender.conf <<EOF
ZABBIX_TARGET_IP=${SERVER_PRIVATE_IP}
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=linux-agent-direct
EOF
```

### 7.4 Add Host in Zabbix UI

Same as Phase 3 but:
- Host name: `linux-agent-direct`
- **Monitored by proxy: (leave EMPTY)** — this host connects directly to the server
- Interface IP: `<linux-agent-direct private IP>`
- Template: `Linux by Zabbix agent`

> **Note the visual difference in the Hosts list:** `linux-agent-proxy` shows `ZabbixProxy01` in the Proxy column. `linux-agent-direct` shows nothing in the Proxy column — confirming direct server connection.

---

## 8. Phase 5 — Windows Agent via Proxy

### 8.1 Access the Windows instance via SSM

**Option A — Run Command (recommended for scripts):**
```powershell
aws ssm send-command `
    --instance-ids i-WINDOWS_AGENT_ID `
    --document-name "AWS-RunPowerShellScript" `
    --parameters "commands=['Get-Date']" `
    --profile sarowar-ostad `
    --region ap-south-1
```

**Option B — Interactive session (Fleet Manager):**
In the AWS Console → Systems Manager → Fleet Manager → select the Windows instance → Start RDP session

**Option C — SSM Session Manager (PowerShell):**
```powershell
aws ssm start-session --target i-WINDOWS_AGENT_ID --profile sarowar-ostad --region ap-south-1
```

### 8.2 Automated install

Upload the scripts to the instance (via Run Command, S3, or git clone), then:
```powershell
# Run as Administrator inside the Windows instance
.\05-agent-windows\install-agent-windows.ps1 -ProxyIp "10.0.2.x"
```

### 8.3 Manual install (step by step)

Run these commands in an **elevated PowerShell** on `windows-agent-01`:

```powershell
# 1. Download Zabbix Agent MSI
$version = "7.0.9"
$url = "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/$version/windows/amd64/zabbix_agent-$version-windows-amd64-openssl.msi"
$msi = "C:\Windows\Temp\zabbix_agent.msi"
Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing

# 2. Silent install
$proxyIp = "10.0.2.x"   # <-- replace with proxy private IP
msiexec /i $msi /quiet /l*v "C:\Windows\Temp\zabbix_install.log" `
    "SERVER=$proxyIp" `
    "SERVERACTIVE=$proxyIp" `
    "HOSTNAME=windows-agent-01"

# 3. Verify service created
Get-Service "Zabbix Agent"

# 4. Set auto-start and start service
Set-Service  "Zabbix Agent" -StartupType Automatic
Start-Service "Zabbix Agent"

# 5. Confirm running
Get-Service "Zabbix Agent"   # Status should be Running

# 6. Write sender config (for task-windows.ps1)
New-Item "C:\ProgramData\Zabbix" -ItemType Directory -Force | Out-Null
@"
ZABBIX_TARGET_IP=$proxyIp
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=windows-agent-01
"@ | Set-Content "C:\ProgramData\Zabbix\sender.conf"

# 7. Copy task wrapper
New-Item "C:\ZabbixTasks" -ItemType Directory -Force | Out-Null
# (copy task-windows.ps1 to C:\ZabbixTasks\task-windows.ps1)
```

### 8.4 Add Host in Zabbix UI

1. **Configuration → Hosts → Create host**
2. Host name: `windows-agent-01`
3. Monitored by proxy: `ZabbixProxy01`
4. Groups: `Windows servers`
5. Interface: Agent, IP = `<windows-agent-01 private IP>`, Port `10050`
6. Templates: `Windows by Zabbix agent`
7. Click **Add**

---

## 9. Phase 6 — Scheduled Task Alerting (Zabbix Sender)

### 9.1 How it works

Each scheduled task script wraps a real command and sends its status to Zabbix using `zabbix_sender`. Zabbix receives the value via a **Trapper item** and fires triggers based on the value:

| Value | Meaning | Trigger fired |
|-------|---------|---------------|
| `0` | OK / idle | No alert — resolves existing alerts |
| `1` | Task is running | **Warning**: "Task `<name>` is running" |
| `2` | Task FAILED | **High**: "Task `<name>` FAILED with error" |

### 9.2 Create Trapper Items in Zabbix UI

For **each host** that runs a scheduled task, create an item:

1. **Configuration → Hosts → `<hostname>` → Items → Create item**
2. Fill in:
   - **Name**: `Scheduled task status: nightly-backup`
   - **Type**: `Zabbix trapper`
   - **Key**: `scheduled.task.status[nightly-backup]`
   - **Type of information**: `Numeric (unsigned)`
   - **Units**: *(leave empty)*
3. **Value mapping tab**: click Add, create a new value map named `Task Status`:
   - `0` → `OK`
   - `1` → `Running`
   - `2` → `Failed`
4. Click **Add**

> Repeat for each task name on each host. The key parameter (e.g. `nightly-backup`) is what you pass as `TASK_NAME` in the script.

### 9.3 Create Triggers

For each trapper item, create **two triggers**:

**Trigger 1 — Warning (task running):**
1. **Configuration → Hosts → `<hostname>` → Triggers → Create trigger**
2. Name: `Task nightly-backup is running on {HOST.NAME}`
3. Severity: **Warning**
4. Expression:
   ```
   last(/linux-agent-proxy/scheduled.task.status[nightly-backup])=1
   ```
5. Recovery expression (auto-resolve when not running):
   ```
   last(/linux-agent-proxy/scheduled.task.status[nightly-backup])<>1
   ```
6. Click **Add**

**Trigger 2 — High (task failed):**
1. Name: `Task nightly-backup FAILED on {HOST.NAME}`
2. Severity: **High**
3. Expression:
   ```
   last(/linux-agent-proxy/scheduled.task.status[nightly-backup])=2
   ```
4. Recovery expression (only resolves when explicitly OK):
   ```
   last(/linux-agent-proxy/scheduled.task.status[nightly-backup])=0
   ```
5. Click **Add**

### 9.4 Test on Linux

On `linux-agent-proxy` (via SSM):

```bash
# Test 1: Simulate a RUNNING then SUCCESSFUL task
/opt/zabbix/task-linux.sh "nightly-backup" "sleep 30" &
# → Watch Zabbix UI Problems: Warning fires immediately
# Wait 30 seconds → Warning auto-resolves (status 0 sent)

# Test 2: Simulate a FAILED task
/opt/zabbix/task-linux.sh "nightly-backup" "exit 1"
# → Watch Zabbix UI Problems: High alert fires
# High stays until you run a successful task:
/opt/zabbix/task-linux.sh "nightly-backup" "echo success"
# → High resolves

# Test 3: Schedule via cron (edit with: crontab -e)
# 0 2 * * * /opt/zabbix/task-linux.sh "nightly-backup" "/usr/local/bin/backup.sh"
```

### 9.5 Test on Windows

On `windows-agent-01` (PowerShell as Administrator):

```powershell
# Set up task directory
New-Item "C:\ZabbixTasks" -ItemType Directory -Force | Out-Null
Copy-Item ".\06-zabbix-sender\task-windows.ps1" "C:\ZabbixTasks\task-windows.ps1"

# Test 1: Successful task
& "C:\ZabbixTasks\task-windows.ps1" -TaskName "win-daily-task" -ScriptBlock {
    Start-Sleep 30   # simulates work
    Write-Host "Task done"
}
# → Warning fires, then resolves after 30s

# Test 2: Failed task
& "C:\ZabbixTasks\task-windows.ps1" -TaskName "win-daily-task" -ScriptBlock {
    throw "Simulated failure"
}
# → High alert fires, stays until a success run

# Test 3: Register as a Windows Scheduled Task
& "C:\ZabbixTasks\task-windows.ps1" -TaskName "win-daily-task" -Register `
    -ScheduleTime "02:00" `
    -ScriptPath "C:\ZabbixTasks\my-actual-task.ps1"
# → Shows in Task Scheduler as "ZabbixTask-win-daily-task"
```

> **Create the same trapper item + triggers in the UI for `windows-agent-01`** with key `scheduled.task.status[win-daily-task]`.

---

## 10. Verification Checklist

| # | What | How to verify | Expected result |
|---|------|---------------|-----------------|
| 1 | All 5 instances running | `.\show-infra.ps1 --status` | All show state = **running** |
| 2 | SSM reachable on all instances | `aws ssm start-session ...` for each | Shell opens without error |
| 3 | Zabbix web UI accessible | `http://<server-EIP>:8080` | Login page appears |
| 4 | Wizard complete + login works | Login with `Admin` / `zabbix` | Dashboard loads |
| 5 | Proxy connected | Administration → Proxies | `ZabbixProxy01` Last seen < 60s |
| 6 | linux-agent-proxy data | Monitoring → Latest data → filter `linux-agent-proxy` | CPU, memory, disk values updating |
| 7 | linux-agent-direct data | Monitoring → Latest data → filter `linux-agent-direct` | Values updating; Proxy column = **empty** |
| 8 | Windows agent data | Monitoring → Latest data → filter `windows-agent-01` | CPU, memory, services count present |
| 9 | Proxy column difference | Configuration → Hosts (all hosts view) | `linux-agent-proxy` shows `ZabbixProxy01`; `linux-agent-direct` shows nothing |
| 10 | Task Warning fires | Run `task-linux.sh "test" "sleep 60"` | Warning appears in Monitoring → Problems |
| 11 | Task Warning auto-resolves | Wait for sleep to finish | Problem cleared, status = OK |
| 12 | Task High fires | Run `task-linux.sh "test" "exit 1"` | High appears in Monitoring → Problems |
| 13 | Task High resolves on success | Run `task-linux.sh "test" "echo ok"` | High clears |
| 14 | Windows task High fires | Run `task-windows.ps1` with `throw` | High appears in Problems |
| 15 | Teardown cleans everything | `.\show-infra.ps1 --teardown` | No orphaned resources in AWS console |

---

## 11. Dashboard Guide — What to Expect

### Hosts view (Configuration → Hosts)

| Host name | Proxy | Status | Items |
|-----------|-------|--------|-------|
| `zabbix-server` | (none — self-monitored) | Enabled | ~60 items |
| `linux-agent-proxy` | `ZabbixProxy01` | Enabled | ~60 items |
| `linux-agent-direct` | *(empty)* | Enabled | ~60 items |
| `windows-agent-01` | `ZabbixProxy01` | Enabled | ~80 items |

### Latest Data (Monitoring → Latest Data)

Filter by each host to see:

**Linux hosts:**
- `system.cpu.load[all,avg1]` — 1-minute load average
- `vm.memory.size[available]` — available RAM bytes
- `vfs.fs.size[/,pfree]` — root disk free %
- `system.uptime` — seconds since boot
- `proc.num[]` — number of processes

**Windows host:**
- `system.cpu.util` — CPU utilization %
- `vm.memory.size[available]` — available memory
- `service.discovery` — discovered Windows services
- `system.uptime` — uptime in seconds

### Problems view (Monitoring → Problems)

What you will see after testing Phase 6:

| Time | Host | Severity | Problem |
|------|------|----------|---------|
| HH:MM | linux-agent-proxy | **Warning** | Task nightly-backup is running on linux-agent-proxy |
| HH:MM | linux-agent-proxy | **High** | Task nightly-backup FAILED on linux-agent-proxy |

The Warning auto-resolves (disappears) when the task finishes successfully.
The High stays until the next successful run sends value `0`.

### Recommended Dashboard Widgets

Create a new dashboard (**Monitoring → Dashboard → Create dashboard**):

1. **Problems widget** — shows all active alerts across all hosts by severity
2. **Graph widget** for each host:
   - Item: `system.cpu.load[all,avg1]` — CPU load history
   - Item: `vm.memory.size[available]` — memory trend
3. **Graph widget** for task status:
   - Item: `scheduled.task.status[nightly-backup]` on `linux-agent-proxy`
   - Set graph type to "Staircase" — clearly shows 0→1→0 or 0→1→2 transitions
4. **Gauge widget** — current task status (0/1/2) with color thresholds:
   - 0 = green, 1 = yellow, 2 = red
5. **Host availability widget** — summary of all hosts (green/red)

---

## 12. Troubleshooting

### zabbix-server not starting
```bash
journalctl -u zabbix-server -n 50
# Common causes:
# - Wrong DBPassword in zabbix_server.conf
# - PostgreSQL not running: systemctl start postgresql
# - Schema not imported: check pg_database
```

### Agent not sending data (after 5+ minutes)
```bash
# Check agent log on the Linux agent
journalctl -u zabbix-agent -n 30
tail -50 /var/log/zabbix/zabbix_agentd.log

# Check if ServerActive connection is working
grep "active check" /var/log/zabbix/zabbix_agentd.log

# Common causes:
# - ServerActive IP wrong (verify private IP in infra-state.json)
# - Security group not allowing outbound 10051 (check SG egress rules)
# - Hostname mismatch between conf and Zabbix UI
```

### Proxy shows "never" in Last seen
```bash
# On proxy instance
journalctl -u zabbix-proxy -n 30

# Common causes:
# - Wrong Server= IP in zabbix_proxy.conf
# - Proxy not registered in UI, or name mismatch
# - SG not allowing port 10051 from proxy SG to server SG
```

### Windows agent not sending
```powershell
# Check service
Get-Service "Zabbix Agent"
Get-EventLog -LogName Application -Source "Zabbix*" -Newest 20

# Check log file
Get-Content "C:\ProgramData\Zabbix\zabbix_agentd.log" -Tail 30

# Test connectivity to proxy
Test-NetConnection -ComputerName 10.0.2.x -Port 10051
```

### Zabbix Sender returns "Failed to send"
```bash
# Test sender manually
zabbix_sender -z 10.0.2.x -p 10051 -s linux-agent-proxy -k scheduled.task.status[test] -o 0 -vv

# Common causes:
# - Target IP/port wrong in sender.conf
# - Trapper item doesn't exist yet in Zabbix UI (create it first)
# - Hostname in sender doesn't match UI host name exactly
```

### SSM session won't connect
```powershell
# Verify instance is running and SSM agent is active
aws ssm describe-instance-information `
    --profile sarowar-ostad `
    --region ap-south-1 `
    --query "InstanceInformationList[?InstanceId=='i-XXXXX']"

# If not in list: SSM agent not running
# For Linux: sudo systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
# For Windows: Start-Service AmazonSSMAgent
# Also verify IAM instance profile is attached (ZabbixSSMProfile)
```

---

## Project Lead

**MD Sarowar Alam**
Lead DevOps Engineer, WPP Production
📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)
🔗 LinkedIn: https://www.linkedin.com/in/sarowar/

---
