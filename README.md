# Zabbix Monitoring End-to-End

> **Zabbix 7.0 LTS** — Production-ready infrastructure monitoring stack on **AWS ap-south-1**.
> Covers server, proxy, Linux agents (two topologies), Windows agent, and scheduled task
> lifecycle alerting via Zabbix Sender. Fully automated from zero to running with a single
> PowerShell script.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Architecture Overview](#2-architecture-overview)
3. [Tech Stack](#3-tech-stack)
4. [Repository Structure](#4-repository-structure)
5. [AWS Infrastructure Layout](#5-aws-infrastructure-layout)
6. [Component Workflow](#6-component-workflow)
7. [Monitoring Topology Explained](#7-monitoring-topology-explained)
8. [Scheduled Task Alerting — Zabbix Sender](#8-scheduled-task-alerting--zabbix-sender)
9. [Prerequisites](#9-prerequisites)
10. [Quick Start — Automated Path](#10-quick-start--automated-path)
11. [Manual Installation Summary](#11-manual-installation-summary)
12. [Configuration Variables Reference](#12-configuration-variables-reference)
13. [Ports and Network Rules](#13-ports-and-network-rules)
14. [Zabbix UI Setup Steps](#14-zabbix-ui-setup-steps)
15. [Verification Checklist](#15-verification-checklist)
16. [Monitoring and Dashboard Guide](#16-monitoring-and-dashboard-guide)
17. [Security Practices Applied](#17-security-practices-applied)
18. [Troubleshooting](#18-troubleshooting)
19. [Teardown](#19-teardown)
20. [Future Improvements](#20-future-improvements)
21. [Contributing](#21-contributing)
22. [License](#22-license)

---

## 1. Project Overview

This repository provisions and configures a complete end-to-end Zabbix monitoring stack
on AWS EC2 entirely from a Windows laptop using PowerShell and the AWS CLI. No Terraform,
no Ansible, no bastion host, and no SSH key pairs are required.

**What it delivers:**

- A Zabbix 7.0 LTS server accessible via browser on port `8080`
- A Zabbix Proxy that buffers and forwards metrics from private-subnet agents
- Two Linux monitoring topologies side-by-side: **via proxy** and **direct to server**
- A Windows Server 2022 agent monitored through the proxy
- A reusable **scheduled task alerting pattern** using `zabbix_sender` that raises and
  resolves Zabbix alerts based on a task's own lifecycle (start / success / failure)
- Full infrastructure lifecycle management: one script to create, inspect, and destroy
  all AWS resources

---

## 2. Architecture Overview

```
Your Windows 11 Laptop
  └── show-infra.ps1 (PowerShell + AWS CLI, profile: sarowar-ostad)
        │
        ▼  AWS ap-south-1 (Mumbai)
┌─────────────────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16                                               │
│                                                                 │
│  PUBLIC subnet  10.0.1.0/24  (AZ: ap-south-1a)                  │
│  ┌──────────────────────────────────────────┐                   │
│  │  zabbix-server  t3.medium  Ubuntu 24.04  │◄── :8080 (UI)     │
│  │  PostgreSQL 16 + Nginx + Zabbix Frontend │                   │
│  │  Elastic IP attached                     │                   │
│  └──────────────────────────────────────────┘                   │
│    ▲ :10051  active check-in from proxy                         │
│    ▲ :10051  active send from linux-agent-direct                │
│                                                                 │
│  NAT Gateway  (private subnet → internet egress)                │
│                                                                 │
│  PRIVATE subnet  10.0.2.0/24  (AZ: ap-south-1a)                 │
│  ┌────────────────┐  ┌──────────────────┐  ┌─────────────────┐  │
│  │ zabbix-proxy   │◄─│linux-agent-proxy │  │linux-agent-dirct│  │
│  │ t3.small       │  │t3.micro          │  │t3.micro         │  │
│  │ Ubuntu 24.04   │  │Ubuntu 24.04      │  │Ubuntu 24.04     │  │
│  │ SQLite3 buffer │  │active → proxy    │  │active → server  │  │
│  └───────┬────────┘  └──────────────────┘  └─────────────────┘  │
│          │ :10051 active                                        │
│  ┌───────▼────────┐                                             │
│  │windows-agent-01│                                             │
│  │ t3.medium      │                                             │
│  │ WinSrv 2022    │                                             │
│  │ active → proxy │                                             │
│  └────────────────┘                                             │
│                                                                 │
│  All 5 instances: IAM SSM role + user-data SSM confirmation     │
└─────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**

- All agents run in **active mode** — they dial out to port `10051`. No inbound Zabbix
  ports are needed on agent security groups.
- `linux-agent-proxy` and `windows-agent-01` route through `ZabbixProxy01`.
- `linux-agent-direct` bypasses the proxy and connects straight to the server's private IP
  — demonstrating both topologies in a single environment.
- The proxy uses the server's **private IP** (same VPC), so no NAT or public IP traversal
  is needed for the proxy-to-server path.
- **No SSH key pairs** are created. All shell access is via AWS SSM Session Manager.

---

## 3. Tech Stack

| Layer | Technology | Version / Detail |
|-------|-----------|-----------------|
| Monitoring platform | Zabbix Server | 7.0 LTS |
| Monitoring proxy | Zabbix Proxy | 7.0 LTS, active mode |
| Monitoring agents | Zabbix Agent | 7.0 LTS (Linux); 7.0.9 MSI (Windows) |
| Metric push | Zabbix Sender | Bundled with `zabbix-sender` package |
| Server OS | Ubuntu 24.04 LTS | All Linux EC2 instances |
| Agent OS (Windows) | Windows Server 2022 | `windows-agent-01` |
| Server database | PostgreSQL 16 | Installed via `apt` on Zabbix server |
| Proxy database | SQLite3 | Local file at `/var/lib/zabbix/zabbix_proxy.db` |
| Web server | Nginx | Port 8080, ships with `zabbix-nginx-conf` |
| PHP runtime | PHP 8.3-FPM | Required by Zabbix frontend |
| Cloud provider | AWS | Region: `ap-south-1` (Mumbai) |
| Compute | AWS EC2 | 5 instances, types: t3.medium / t3.small / t3.micro |
| Networking | AWS VPC | VPC, 2 subnets, IGW, NAT GW, 5 SGs |
| Access management | AWS IAM | Role: `ZabbixSSMRole`, Policy: `AmazonSSMManagedInstanceCore` |
| Shell access | AWS SSM Session Manager | No key pairs, no bastion |
| IaC / provisioning | PowerShell 5.1+ + AWS CLI v2 | `show-infra.ps1` |

---

## 4. Repository Structure

```
zabbix-monitoring-end-to-end/
│
├── show-infra.ps1                         # Infrastructure lifecycle script
│                                          # Flags: --create (default) | --status | --teardown
├── infra-state.json                       # Written by --create, gitignored
├── INSTALL.md                             # Full manual + automated guide for all phases
├── README.md                              # This file
├── .gitignore
│
├── 01-zabbix-server/
│   ├── install-server.sh                  # Idempotent: PostgreSQL + Zabbix + Nginx
│   ├── zabbix_server.conf.template        # Server config reference
│   └── nginx.conf.template                # Nginx vhost on port 8080
│
├── 02-zabbix-proxy/
│   ├── install-proxy.sh                   # Proxy with SQLite3, active mode
│   └── zabbix_proxy.conf.template         # Proxy config reference
│
├── 03-agent-linux-proxy/
│   ├── install-agent-linux-proxy.sh       # Agent pointing to ZabbixProxy01
│   └── zabbix_agentd.conf.template        # Agent config reference
│
├── 04-agent-linux-direct/
│   ├── install-agent-linux-direct.sh      # Agent pointing directly to server
│   └── zabbix_agentd.conf.template        # Agent config reference
│
├── 05-agent-windows/
│   ├── install-agent-windows.ps1          # Downloads MSI, silent install, sender.conf
│   └── zabbix_agentd.win.conf.template    # Windows agent config reference
│
└── 06-zabbix-sender/
    ├── task-linux.sh                      # Cron-ready task wrapper (sends 1 / 0 / 2)
    ├── task-windows.ps1                   # Task Scheduler wrapper with -Register mode
    └── sender.conf.template               # Target IP, port, hostname config
```

---

## 5. AWS Infrastructure Layout

All resources are created and tagged with `Project=zabbix-monitoring`.

### EC2 Instances

| Name tag | Instance type | OS | Subnet | Public IP |
|----------|-------------|-----|--------|-----------|
| `zabbix-server` | t3.medium | Ubuntu 24.04 | Public (`10.0.1.0/24`) | Elastic IP |
| `zabbix-proxy` | t3.small | Ubuntu 24.04 | Private (`10.0.2.0/24`) | None (SSM via NAT) |
| `linux-agent-proxy` | t3.micro | Ubuntu 24.04 | Private (`10.0.2.0/24`) | None |
| `linux-agent-direct` | t3.micro | Ubuntu 24.04 | Private (`10.0.2.0/24`) | None |
| `windows-agent-01` | t3.medium | Windows Server 2022 | Private (`10.0.2.0/24`) | None |

### Security Groups

| SG name | Inbound allowed | Purpose |
|---------|----------------|---------|
| `sg-zbx-server` | TCP 8080 from `0.0.0.0/0`; TCP 10051 from `sg-zbx-proxy` and `sg-zbx-linux-agent-direct` | Web UI + trapper |
| `sg-zbx-proxy` | TCP 10051 from `sg-zbx-linux-agent-proxy` and `sg-zbx-windows-agent` | Receive agent data |
| `sg-zbx-linux-agent-proxy` | None (active mode) | Agents dial out only |
| `sg-zbx-linux-agent-direct` | None (active mode) | Agents dial out only |
| `sg-zbx-windows-agent` | None (active mode) | Agents dial out only |

### IAM

| Resource | Name | Policy attached |
|----------|------|----------------|
| IAM Role | `ZabbixSSMRole` | `AmazonSSMManagedInstanceCore` |
| Instance Profile | `ZabbixSSMProfile` | Attached to all 5 EC2 instances |

---

## 6. Component Workflow

```
Provisioning flow (run once from your laptop):

  show-infra.ps1 --create
    ├── Creates VPC, subnets, IGW, EIPs, NAT Gateway, route tables
    ├── Creates IAM role ZabbixSSMRole + instance profile ZabbixSSMProfile
    ├── Creates 5 security groups with scoped ingress rules
    ├── Fetches latest Ubuntu 24.04 + Windows Server 2022 AMI IDs from SSM Parameter Store
    ├── Launches 5 EC2 instances with SSM user data (confirmed on all, including Windows)
    ├── Waits for all instances to pass status checks
    ├── Associates Elastic IP with zabbix-server
    └── Writes infra-state.json with all IDs and private IPs

Installation flow (once per instance via SSM):

  zabbix-server     : install-server.sh <DB_PASSWORD>
  zabbix-proxy      : install-proxy.sh  <SERVER_PRIVATE_IP>
  linux-agent-proxy : install-agent-linux-proxy.sh <PROXY_PRIVATE_IP>
  linux-agent-direct: install-agent-linux-direct.sh <SERVER_PRIVATE_IP>
  windows-agent-01  : install-agent-windows.ps1 -ProxyIp <PROXY_PRIVATE_IP>

Data flow at runtime:

  linux-agent-proxy  --active:10051--> zabbix-proxy --active:10051--> zabbix-server
  linux-agent-direct --active:10051------------------------------------------> zabbix-server
  windows-agent-01   --active:10051--> zabbix-proxy --active:10051--> zabbix-server
```

---

## 7. Monitoring Topology Explained

This project deliberately runs **two agent topologies in parallel** to demonstrate the
difference between proxied and direct monitoring:

| | `linux-agent-proxy` | `linux-agent-direct` |
|-|--------------------|--------------------|
| `ServerActive` points to | `zabbix-proxy` private IP | `zabbix-server` private IP |
| Proxy column in Zabbix UI | `ZabbixProxy01` | *(empty — direct)* |
| Config buffering | Yes (proxy SQLite3 buffer) | No |
| Latency | Slightly higher (proxy hop) | Lower |
| Resilience | Proxy buffers data during server downtime | Data lost if server unreachable |
| Security group egress | To proxy SG port 10051 | To server SG port 10051 |

Both hosts use the same Zabbix template (`Linux by Zabbix agent`) and collect identical
metrics — only the routing path differs.

---

## 8. Scheduled Task Alerting — Zabbix Sender

`task-linux.sh` and `task-windows.ps1` implement a **dead man's switch** pattern.
Any shell command or PowerShell ScriptBlock is wrapped so that Zabbix reflects the
task's real-time lifecycle as an alert.

### Alert lifecycle

```
Task STARTS    --> zabbix_sender sends 1 --> [WARNING]  "Task <name> is running"
Task SUCCEEDS  --> zabbix_sender sends 0 --> [OK]        Warning auto-resolves
Task FAILS     --> zabbix_sender sends 2 --> [HIGH]      "Task <name> FAILED with error"
                                             Stays HIGH until next successful run sends 0
```

### Trapper item key

```
scheduled.task.status[<task-name>]
```

Values: `0` = OK/idle | `1` = Running | `2` = Failed

### Trigger expressions (create in Zabbix UI)

| Severity | Expression | Recovery |
|----------|-----------|---------|
| Warning | `last(...)=1` | `last(...)<>1` |
| High | `last(...)=2` | `last(...)=0` |

### Linux usage

```bash
# Wrap any command — installed at /opt/zabbix/task-linux.sh
/opt/zabbix/task-linux.sh "nightly-backup" "/usr/local/bin/backup.sh"

# Cron entry (daily at 02:00)
0 2 * * * /opt/zabbix/task-linux.sh "nightly-backup" "/usr/local/bin/backup.sh"
```

### Windows usage

```powershell
# Run task and report lifecycle
.\task-windows.ps1 -TaskName "db-export" -ScriptBlock {
    Compress-Archive -Path "C:\Data\*" -DestinationPath "C:\Backup\db.zip" -Force
}

# Register as a daily Windows Scheduled Task
.\task-windows.ps1 -TaskName "db-export" -Register -ScheduleTime "02:00" `
    -ScriptPath "C:\ZabbixTasks\db-export.ps1"
```

Configuration is read from:
- **Linux**: `/etc/zabbix/sender.conf`
- **Windows**: `C:\ProgramData\Zabbix\sender.conf`

Both files are created automatically by the install scripts.

---

## 9. Prerequisites

### On your Windows 11 laptop (control machine)

| Tool | Install command | Notes |
|------|----------------|-------|
| AWS CLI v2 | `winget install Amazon.AWSCLI` | Must be v2.x |
| AWS Session Manager Plugin | [Download MSI](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) | Required for `ssm start-session` |
| PowerShell | Built-in (Windows 11) | Version 5.1+ |

### AWS profile

Configure the `sarowar-ostad` named profile before running any scripts:

```powershell
aws configure --profile sarowar-ostad
# Enter: Access Key ID, Secret Access Key, default region: ap-south-1, output: json
```

Verify:
```powershell
aws sts get-caller-identity --profile sarowar-ostad
```

### PowerShell execution policy

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### AWS account permissions required

The IAM user/role behind `sarowar-ostad` needs permissions to manage:
`ec2`, `iam`, `ssm` (Parameter Store read + Session Manager), `sts`

---

## 10. Quick Start — Automated Path

**Total time: ~20 minutes** (7 min provisioning + 8 min installs + 5 min UI config)

### Step 1 — Provision all AWS resources

```powershell
cd path\to\zabbix-monitoring-end-to-end
.\show-infra.ps1
```

When complete, `infra-state.json` is written. Read it to get instance IDs and private IPs:

```powershell
.\show-infra.ps1 --status
```

### Step 2 — Open SSM session to each instance

```powershell
aws ssm start-session `
    --target <instance-id> `
    --profile sarowar-ostad `
    --region ap-south-1
```

### Step 3 — Clone repo and run install scripts

Inside each SSM shell (Linux):
```bash
git clone https://github.com/sarowar-alam/zabbix-monitoring-end-to-end.git
cd zabbix-monitoring-end-to-end
```

| Instance | Command |
|----------|---------|
| `zabbix-server` | `sudo bash 01-zabbix-server/install-server.sh "YourPass@2025"` |
| `zabbix-proxy` | `sudo bash 02-zabbix-proxy/install-proxy.sh "10.0.1.x"` |
| `linux-agent-proxy` | `sudo bash 03-agent-linux-proxy/install-agent-linux-proxy.sh "10.0.2.x"` |
| `linux-agent-direct` | `sudo bash 04-agent-linux-direct/install-agent-linux-direct.sh "10.0.1.x"` |
| `windows-agent-01` | `.\05-agent-windows\install-agent-windows.ps1 -ProxyIp "10.0.2.x"` |

Replace `10.0.1.x` / `10.0.2.x` with the actual private IPs from `infra-state.json`.

### Step 4 — Open Zabbix web UI

```
http://<server-Elastic-IP>:8080
```

Complete the 7-step setup wizard, then log in with `Admin` / `zabbix`.
**Change the default password immediately.**

---

## 11. Manual Installation Summary

Every phase has a full manual walkthrough in [INSTALL.md](INSTALL.md).
High-level manual sequence:

1. **AWS Console**: VPC → subnets → IGW → 2 EIPs → NAT Gateway → route tables →
   IAM role (`AmazonSSMManagedInstanceCore`) → 5 security groups → 5 EC2 instances
   (paste Linux/Windows user-data from `INSTALL.md` section 3.2)
2. **Server** (SSM shell): `apt install postgresql`, create DB user/db, add Zabbix repo,
   install packages, import schema, edit config files, start services
3. **Register proxy in UI first**, then SSH into proxy instance and install
4. **Linux agents**: `apt install zabbix-agent`, set `Server=`, `ServerActive=`,
   `Hostname=` in `zabbix_agentd.conf`, restart
5. **Windows agent**: `Invoke-WebRequest` MSI, `msiexec /i ... /quiet`, set service auto-start
6. **Sender/triggers**: create Zabbix trapper items + two triggers per host in the UI

---

## 12. Configuration Variables Reference

No `.env` files are used. Configuration is passed as script arguments and written
to config files on each instance by the install scripts.

### install-server.sh

| Parameter | Description | Example |
|-----------|-------------|---------|
| `$1` (required) | PostgreSQL password for the `zabbix` DB user | `"YourPass@2025"` |

**Files written on server:**

| File | Key setting |
|------|-------------|
| `/etc/zabbix/zabbix_server.conf` | `DBPassword=<password>` |
| `/etc/zabbix/nginx.conf` | `listen 8080;` + `server_name <private-ip>;` |

### install-proxy.sh

| Parameter | Description | Example |
|-----------|-------------|---------|
| `$1` (required) | Zabbix server private IP | `"10.0.1.44"` |

**Files written on proxy:**

| File | Key settings |
|------|-------------|
| `/etc/zabbix/zabbix_proxy.conf` | `ProxyMode=0`, `Server=<server-ip>`, `Hostname=ZabbixProxy01`, `DBName=/var/lib/zabbix/zabbix_proxy.db` |

### install-agent-linux-proxy.sh / install-agent-linux-direct.sh

| Parameter | Description |
|-----------|-------------|
| `$1` (required) | Proxy private IP (proxy script) or Server private IP (direct script) |

**Files written on agent:**

| File | Key settings |
|------|-------------|
| `/etc/zabbix/zabbix_agentd.conf` | `Server=`, `ServerActive=`, `Hostname=` |
| `/etc/zabbix/sender.conf` | `ZABBIX_TARGET_IP`, `ZABBIX_TARGET_PORT=10051`, `ZABBIX_HOSTNAME` |

### install-agent-windows.ps1

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ProxyIp` | string | Required | Proxy private IP |
| `-Hostname` | string | `windows-agent-01` | Must match Zabbix UI host name |
| `-ZabbixVersion` | string | `7.0.9` | MSI version to download |

**Files written on Windows agent:**

| File | Key settings |
|------|-------------|
| `C:\Program Files\Zabbix Agent\zabbix_agentd.conf` | `Server=`, `ServerActive=`, `Hostname=` |
| `C:\ProgramData\Zabbix\sender.conf` | `ZABBIX_TARGET_IP`, `ZABBIX_TARGET_PORT`, `ZABBIX_HOSTNAME` |

---

## 13. Ports and Network Rules

| Port | Protocol | Direction | From | To | Purpose |
|------|----------|-----------|------|----|---------|
| `8080` | TCP | Inbound | `0.0.0.0/0` | `zabbix-server` | Zabbix web UI |
| `10051` | TCP | Inbound | `sg-zbx-proxy` | `zabbix-server` | Active proxy check-in |
| `10051` | TCP | Inbound | `sg-zbx-linux-agent-direct` | `zabbix-server` | Direct agent send |
| `10051` | TCP | Inbound | `sg-zbx-linux-agent-proxy` | `zabbix-proxy` | Agent active send |
| `10051` | TCP | Inbound | `sg-zbx-windows-agent` | `zabbix-proxy` | Windows agent send |
| `443` | TCP | Outbound | All private instances | Internet (via NAT) | SSM, apt, package downloads |

Agents have **no inbound Zabbix ports** — they initiate all connections outbound.

---

## 14. Zabbix UI Setup Steps

After all install scripts succeed, perform these steps in the web UI once:

### Register the proxy

1. **Administration → Proxies → Create proxy**
2. Proxy name: `ZabbixProxy01` | Mode: **Active**
3. Click **Add** — within 60 seconds, "Last seen" will update

### Add each host

Repeat for all 4 monitored hosts:

1. **Configuration → Hosts → Create host**
2. Fill in:

   | Host | Host name | Monitored by proxy | Template |
   |------|-----------|-------------------|----------|
   | Linux via proxy | `linux-agent-proxy` | `ZabbixProxy01` | `Linux by Zabbix agent` |
   | Linux direct | `linux-agent-direct` | *(leave empty)* | `Linux by Zabbix agent` |
   | Windows | `windows-agent-01` | `ZabbixProxy01` | `Windows by Zabbix agent` |

3. Interface → Type: Agent | IP: `<private IP from infra-state.json>` | Port: `10050`
4. Click **Add**

### Create task alerting items and triggers

For each host running scheduled tasks, create a **Zabbix trapper** item:
- Type: `Zabbix trapper`
- Key: `scheduled.task.status[nightly-backup]`
- Type of information: `Numeric (unsigned)`

Then create two triggers per item (see section 8 for expressions).

---

## 15. Verification Checklist

| # | What to verify | How |
|---|---------------|-----|
| 1 | All 5 instances running | `.\show-infra.ps1 --status` — all state = running |
| 2 | SSM reachable on all instances | `aws ssm start-session --target <id> ...` opens a shell |
| 3 | Zabbix web UI accessible | `http://<EIP>:8080` loads the login page |
| 4 | Setup wizard complete, login works | Login with `Admin` and your changed password |
| 5 | Proxy connected | UI: Administration → Proxies → Last seen < 60 s |
| 6 | `linux-agent-proxy` data flowing | Latest data → values present, Proxy column = `ZabbixProxy01` |
| 7 | `linux-agent-direct` data flowing | Latest data → values present, Proxy column = **empty** |
| 8 | `windows-agent-01` data flowing | Latest data → CPU / memory / services present |
| 9 | Proxy column difference visible | Hosts list shows clear distinction between proxied and direct |
| 10 | Task Warning fires | `task-linux.sh "test" "sleep 60"` → Warning in Problems |
| 11 | Task Warning auto-resolves | Script finishes → Problem clears automatically |
| 12 | Task High fires | `task-linux.sh "test" "exit 1"` → High in Problems |
| 13 | Task High resolves only on 0 | Re-run successfully → High clears |
| 14 | Windows task lifecycle works | `task-windows.ps1 -TaskName "test" -ScriptBlock { throw }` → High |
| 15 | Teardown clean | `.\show-infra.ps1 --teardown` → no orphaned resources in AWS console |

---

## 16. Monitoring and Dashboard Guide

### What appears in Latest Data

**Linux hosts** (`Linux by Zabbix agent` template):

| Item key | Description |
|----------|-------------|
| `system.cpu.load[all,avg1]` | 1-minute CPU load average |
| `vm.memory.size[available]` | Available RAM in bytes |
| `vfs.fs.size[/,pfree]` | Root filesystem free % |
| `system.uptime` | Seconds since boot |
| `proc.num[]` | Number of running processes |
| `net.if.in[eth0]` | Network bytes received |

**Windows host** (`Windows by Zabbix agent` template):

| Item key | Description |
|----------|-------------|
| `system.cpu.util` | CPU utilization % |
| `vm.memory.size[available]` | Available memory |
| `service.discovery` | Discovered Windows services |
| `system.uptime` | Uptime in seconds |
| `perf_counter[\System\Processor Queue Length]` | CPU queue |

**Scheduled task items** (custom, Zabbix trapper):

| Item key | Values |
|----------|--------|
| `scheduled.task.status[nightly-backup]` | `0`=OK, `1`=Running, `2`=Failed |
| `scheduled.task.status[win-daily-task]` | `0`=OK, `1`=Running, `2`=Failed |

### Recommended dashboard widgets

1. **Problems** widget — live alert severity view across all hosts
2. **Graph** widget — `system.cpu.load[all,avg1]` per Linux host
3. **Graph** widget — `vm.memory.size[available]` per host (trend)
4. **Graph** (staircase type) — `scheduled.task.status[*]` — shows 0→1→0 or 0→1→2
5. **Gauge** widget — current task status with colour thresholds (0=green, 1=amber, 2=red)
6. **Host availability** widget — green/red summary of all 4 monitored hosts

---

## 17. Security Practices Applied

| Practice | Implementation |
|----------|---------------|
| No SSH key pairs | All access via AWS SSM Session Manager — no port 22 |
| No bastion host | SSM eliminates the need for a jump server |
| Least-privilege security groups | Agent SGs have zero inbound Zabbix ports (active mode only) |
| Server-to-proxy communication | Uses private IP only — never traverses public internet |
| EIP on server only | 4 of 5 instances have no public IP |
| IAM scoped to SSM only | `ZabbixSSMRole` carries only `AmazonSSMManagedInstanceCore` |
| SSM user data confirmation | All instances — including Windows — bootstrap the SSM agent via user data |
| State file gitignored | `infra-state.json` (contains IPs and IDs) is excluded from version control |
| DB password not hardcoded | Passed as a CLI argument to `install-server.sh`, never stored in repo |
| `set -euo pipefail` on all bash scripts | Prevents silent failures in install scripts |
| Teardown confirmation | `--teardown` requires typing `DELETE` to prevent accidental destruction |

---

## 18. Troubleshooting

### `zabbix-server` service fails to start

```bash
journalctl -u zabbix-server -n 50
```

Common causes:
- Wrong `DBPassword` in `/etc/zabbix/zabbix_server.conf`
- PostgreSQL not running: `systemctl start postgresql`
- Schema not imported: check with `sudo -u zabbix psql zabbix -c "\dt hosts"`

### Agent not sending data after 5+ minutes

```bash
# Check agent log
tail -50 /var/log/zabbix/zabbix_agentd.log
grep "active check" /var/log/zabbix/zabbix_agentd.log
```

Common causes:
- `ServerActive=` IP is wrong — verify against `infra-state.json`
- Security group egress rule missing (port 10051 to target SG)
- `Hostname=` in `zabbix_agentd.conf` does not match the host name in the Zabbix UI exactly

### Proxy shows "never" in Last seen

```bash
journalctl -u zabbix-proxy -n 30
```

Common causes:
- `Server=` in `zabbix_proxy.conf` has wrong IP
- Proxy not registered in UI, or name mismatch with `Hostname=`
- Port 10051 not allowed from `sg-zbx-proxy` to `sg-zbx-server`

### Windows agent not running

```powershell
Get-Service "Zabbix Agent"
Get-Content "C:\ProgramData\Zabbix\zabbix_agentd.log" -Tail 30
Test-NetConnection -ComputerName <proxy-ip> -Port 10051
```

### `zabbix_sender` returns "failed to send"

```bash
zabbix_sender -z <target-ip> -p 10051 -s <hostname> -k scheduled.task.status[test] -o 0 -vv
```

Common causes:
- Trapper item not yet created in the Zabbix UI (must exist before sender will be accepted)
- `ZABBIX_HOSTNAME` in `sender.conf` does not match the UI host name
- Target IP wrong in `sender.conf`

### SSM session won't connect

```powershell
aws ssm describe-instance-information `
    --profile sarowar-ostad --region ap-south-1 `
    --query "InstanceInformationList[?InstanceId=='i-XXXXX']"
```

If the instance is not listed, the SSM agent is not running or the IAM profile is not attached. For Linux: `sudo systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service`. For Windows: `Start-Service AmazonSSMAgent`.

---

## 19. Teardown

```powershell
.\show-infra.ps1 --teardown
```

Destroys in reverse-dependency order:
1. Terminate all 5 EC2 instances (waits for completion)
2. Revoke cross-SG ingress rules, then delete all 5 security groups
3. Delete NAT Gateway (waits for `deleted` state)
4. Release both Elastic IPs
5. Detach and delete Internet Gateway
6. Disassociate and delete both route tables
7. Delete both subnets
8. Delete VPC
9. Remove IAM role from instance profile, delete instance profile, detach policy, delete role
10. Delete `infra-state.json`

Prompts: `Type DELETE to confirm teardown` before any destructive action.

---

## 20. Future Improvements

- [ ] Add TLS/PSK encryption between all Zabbix components (server, proxy, agents)
- [ ] Zabbix Agent 2 support for Go-plugin-based monitoring (Docker, MySQL, Redis)
- [ ] Email / Slack / PagerDuty alert media type configuration
- [ ] Auto-discovery rules to automatically onboard new EC2 instances
- [ ] Zabbix templates exported as XML for version-controlled host/trigger definitions
- [ ] Terraform rewrite of `show-infra.ps1` for state file + drift detection
- [ ] Multi-AZ deployment for high availability (server in public, proxy per AZ)
- [ ] AWS Auto Scaling Group integration with Zabbix auto-registration
- [ ] Centralised log shipping (CloudWatch Logs agent on all instances)
- [ ] Zabbix API automation for host/item/trigger creation (replace manual UI steps)

---

## 21. Contributing

1. Fork the repository and create a feature branch:
   ```bash
   git checkout -b feature/your-change
   ```
2. All bash scripts must pass `shellcheck` before submission.
3. All PowerShell scripts must pass `PSScriptAnalyzer`.
4. Do not commit `infra-state.json` — it is gitignored and contains live infrastructure IDs.
5. Keep install scripts idempotent — they must be safe to run more than once.
6. Update `INSTALL.md` if any configuration step changes.
7. Open a pull request with a clear description of what changed and why.

---

## Project Lead

**MD Sarowar Alam**

Lead DevOps Engineer, WPP Production

📧 Email: [sarowar@hotmail.com](mailto:sarowar@hotmail.com)

🔗 LinkedIn: [https://www.linkedin.com/in/sarowar/](https://www.linkedin.com/in/sarowar/)

---
