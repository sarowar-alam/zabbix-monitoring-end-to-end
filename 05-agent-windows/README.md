# Zabbix 7.0 LTS — Windows Agent (via Proxy)

**Instance:** `windows-agent-01` · t3.medium · Windows Server 2022 · Private subnet  
**Monitored by:** `ZabbixProxy01` — proxy polls this agent on TCP 10050 (passive mode)  
**Access:** AWS Systems Manager Session Manager (no RDP required for install)

---

## Automated Install

```powershell
# SSM session to the Windows instance
aws ssm start-session --target <windows-agent-instance-id> `
    --profile sarowar-ostad --region ap-south-1

# Inside the PowerShell session, run as SYSTEM (already elevated via SSM)
.\05-agent-windows\install-agent-windows.ps1 -ProxyIp '10.0.2.x'
```

---

## Manual Install

### Step 1 — Download Zabbix Agent MSI

Run in elevated PowerShell on the Windows instance:

```powershell
$version  = '7.0.9'
$proxyIp  = '10.0.2.x'   # replace with proxy private IP
$msi      = 'C:\Windows\Temp\zabbix_agent.msi'

Invoke-WebRequest `
    "https://cdn.zabbix.com/zabbix/binaries/stable/7.0/$version/windows/amd64/zabbix_agent-$version-windows-amd64-openssl.msi" `
    -OutFile $msi -UseBasicParsing
```

### Step 2 — Silent Install (Passive Mode)

```powershell
# Passive mode — no SERVERACTIVE. Proxy polls agent on :10050.
msiexec /i $msi /quiet /l*v 'C:\Windows\Temp\zabbix_install.log' `
    "SERVER=$proxyIp" `
    'HOSTNAME=windows-agent-01'

Start-Sleep 10
```

### Step 3 — Write `zabbix_agentd.conf`

The MSI install creates a default config. Overwrite it for clean passive-mode settings:

```powershell
$proxyIp = '10.0.2.x'   # replace with proxy private IP
$confDir = 'C:\Program Files\Zabbix Agent'

@"
# Zabbix Agent — windows-agent-01
# Passive mode: proxy polls this agent on TCP 10050

LogFile=C:\Program Files\Zabbix Agent\zabbix_agentd.log
LogFileSize=0

# Proxy is allowed to poll this agent (passive checks)
Server=$proxyIp
# ServerActive disabled — passive mode only

Hostname=windows-agent-01

Timeout=3
"@ | Set-Content "$confDir\zabbix_agentd.conf" -Encoding UTF8
```

### Step 4 — Start and Enable Service

```powershell
Set-Service  'Zabbix Agent' -StartupType Automatic
Restart-Service 'Zabbix Agent'

# Verify running
Get-Service 'Zabbix Agent'
```

### Step 5 — Write Sender Config

```powershell
New-Item 'C:\ProgramData\Zabbix' -ItemType Directory -Force | Out-Null

@"
# Zabbix Sender config — windows-agent-01
ZABBIX_TARGET_IP=$proxyIp
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=windows-agent-01
"@ | Set-Content 'C:\ProgramData\Zabbix\sender.conf' -Encoding UTF8
```

### Step 6 — Copy Task Wrapper

```powershell
New-Item 'C:\ZabbixTasks' -ItemType Directory -Force | Out-Null
Copy-Item '.\06-zabbix-sender\task-windows.ps1' 'C:\ZabbixTasks\task-windows.ps1'
```

### Step 7 — Verify

```powershell
# Check service status
Get-Service 'Zabbix Agent'

# Check log
Get-Content 'C:\Program Files\Zabbix Agent\zabbix_agentd.log' -Tail 20

# Test local item
& 'C:\Program Files\Zabbix Agent\zabbix_agentd.exe' -t system.uptime
```

---

## Add Host in Zabbix UI

**Configuration → Hosts → Create host**

| Tab | Field | Value |
|-----|-------|-------|
| Host | Host name | `windows-agent-01` |
| Host | Monitored by proxy | `ZabbixProxy01` |
| Host | Groups | `Windows servers` |
| Interfaces | Type | Agent |
| Interfaces | IP address | `<windows-agent-01 private IP>` |
| Interfaces | Port | `10050` |
| Interfaces | Connect to | IP |
| Templates | | `Windows by Zabbix agent` |

Click **Add**.

---

## Troubleshooting

```powershell
# Service not starting
Get-EventLog -LogName Application -Source 'Zabbix*' -Newest 20
Get-Content 'C:\Program Files\Zabbix Agent\zabbix_agentd.log' -Tail 30

# Test connectivity to proxy from this instance
Test-NetConnection -ComputerName 10.0.2.x -Port 10050
Test-NetConnection -ComputerName 10.0.2.x -Port 10051

# Verify config
Get-Content 'C:\Program Files\Zabbix Agent\zabbix_agentd.conf'

# Reinstall cleanly (stops service, removes files)
msiexec /x $msi /quiet
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `install-agent-windows.ps1` | Automated install script |
| `zabbix_agentd.win.conf.template` | Windows agent config template |
