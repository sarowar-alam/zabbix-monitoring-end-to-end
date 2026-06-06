# Zabbix Monitoring End-to-End

Complete Zabbix 7.0 LTS monitoring stack on AWS `ap-south-1` — from zero to a
fully operational monitoring setup with server, proxy, Linux agents, Windows
agent, and scheduled task alerting via Zabbix Sender.

## What's covered

| Phase | Component | Description |
|-------|-----------|-------------|
| 0 | AWS Infrastructure | VPC, subnets, NAT GW, IAM SSM role, 5 EC2 instances |
| 1 | Zabbix Server | Ubuntu 24.04, PostgreSQL 16, Nginx, web frontend |
| 2 | Zabbix Proxy | Ubuntu 24.04, SQLite3, active mode |
| 3 | Linux Agent (via proxy) | Reports metrics through ZabbixProxy01 |
| 4 | Linux Agent (direct) | Reports metrics directly to server — no proxy |
| 5 | Windows Agent | Windows Server 2022, reports through proxy |
| 6 | Zabbix Sender | Scheduled task lifecycle alerting (Warning/High triggers) |

## Quick Start

### Prerequisites
- AWS CLI v2 + profile `sarowar-ostad` configured
- AWS Session Manager Plugin installed
- PowerShell 5.1+

### 1 — Provision infrastructure

```powershell
.\show-infra.ps1              # creates all AWS resources, writes infra-state.json
.\show-infra.ps1 --status     # check live instance state
.\show-infra.ps1 --teardown   # destroy everything (prompts for DELETE confirmation)
```

### 2 — Install each component

Access every instance via SSM:
```powershell
aws ssm start-session --target <instance-id> --profile sarowar-ostad --region ap-south-1
```

Run the install script matching the instance:

| Instance | Script |
|----------|--------|
| `zabbix-server` | `sudo bash 01-zabbix-server/install-server.sh <DB_PASSWORD>` |
| `zabbix-proxy` | `sudo bash 02-zabbix-proxy/install-proxy.sh <SERVER_PRIVATE_IP>` |
| `linux-agent-proxy` | `sudo bash 03-agent-linux-proxy/install-agent-linux-proxy.sh <PROXY_PRIVATE_IP>` |
| `linux-agent-direct` | `sudo bash 04-agent-linux-direct/install-agent-linux-direct.sh <SERVER_PRIVATE_IP>` |
| `windows-agent-01` | `.\05-agent-windows\install-agent-windows.ps1 -ProxyIp <PROXY_PRIVATE_IP>` |

### 3 — Open Zabbix UI

`http://<server-EIP>:8080` — complete the 7-step wizard, login `Admin / zabbix`

### 4 — Register components in UI

After each install, register in the Zabbix web UI:
- Proxy: Administration → Proxies → Create proxy (`ZabbixProxy01`, Active)
- Hosts: Configuration → Hosts → Create host (see INSTALL.md for full details)

### 5 — Test scheduled task alerting

```bash
# On linux-agent-proxy (simulate a failing task)
/opt/zabbix/task-linux.sh "nightly-backup" "exit 1"
# → High alert fires in Monitoring → Problems
```

```powershell
# On windows-agent-01 (simulate a failing task)
.\task-windows.ps1 -TaskName "win-daily-task" -ScriptBlock { throw "fail" }
# → High alert fires
```

## Repository Structure

```
zabbix-monitoring-end-to-end/
├── show-infra.ps1                        # --create | --status | --teardown
├── infra-state.json                      # written by --create (gitignored)
├── INSTALL.md                            # full step-by-step guide (read this!)
│
├── 01-zabbix-server/
│   ├── install-server.sh                 # automated server install
│   ├── zabbix_server.conf.template
│   └── nginx.conf.template
│
├── 02-zabbix-proxy/
│   ├── install-proxy.sh                  # automated proxy install
│   └── zabbix_proxy.conf.template
│
├── 03-agent-linux-proxy/
│   ├── install-agent-linux-proxy.sh      # agent → proxy topology
│   └── zabbix_agentd.conf.template
│
├── 04-agent-linux-direct/
│   ├── install-agent-linux-direct.sh     # agent → server directly
│   └── zabbix_agentd.conf.template
│
├── 05-agent-windows/
│   ├── install-agent-windows.ps1         # Windows Server 2022 agent
│   └── zabbix_agentd.win.conf.template
│
└── 06-zabbix-sender/
    ├── task-linux.sh                     # cron task wrapper (dead man's switch)
    ├── task-windows.ps1                  # Task Scheduler wrapper
    └── sender.conf.template              # target IP + hostname config
```

## Architecture

```
Public subnet 10.0.1.0/24
  └── zabbix-server (t3.medium, Ubuntu 24.04, EIP)
        ← port 10051 from proxy (active)
        ← port 10051 from linux-agent-direct (active)
        ← port 8080  from your browser (web UI)

Private subnet 10.0.2.0/24
  ├── zabbix-proxy       (t3.small,  Ubuntu 24.04)  → server:10051
  ├── linux-agent-proxy  (t3.micro,  Ubuntu 24.04)  → proxy:10051
  ├── linux-agent-direct (t3.micro,  Ubuntu 24.04)  → server:10051 (no proxy)
  └── windows-agent-01   (t3.medium, WinSrv 2022)   → proxy:10051
```

All instances accessed via **AWS SSM Session Manager** — no SSH keys, no bastion host.

## Full Documentation

See [INSTALL.md](INSTALL.md) for:
- Complete manual installation steps for every phase
- Zabbix UI configuration (hosts, proxies, trapper items, triggers)
- Verification checklist (15 checks)
- Dashboard widget guide
- Troubleshooting reference
