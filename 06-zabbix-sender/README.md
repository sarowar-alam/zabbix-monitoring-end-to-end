# Zabbix 7.0 LTS — Scheduled Task Alerting (Zabbix Sender)

**Pattern:** Dead man's switch — each task reports START → SUCCESS or FAILURE  
**Transport:** `zabbix_sender` → Zabbix Trapper item → Trigger → Alert  
**Works on:** All Linux instances + Windows Agent

---

## How It Works

```
Task starts    → sends value 1 → Zabbix raises WARNING  "Task is running"
Task succeeds  → sends value 0 → WARNING auto-resolves
Task fails     → sends value 2 → Zabbix raises HIGH     "Task FAILED"
                                  HIGH stays until next successful run
```

**Trapper item key:** `scheduled.task.status[<task-name>]`  
**Values:** `0` = OK/idle · `1` = Running · `2` = Failed

---

## Sender Config

Location:
- Linux: `/etc/zabbix/sender.conf`
- Windows: `C:\ProgramData\Zabbix\sender.conf`

### Linux (via proxy)

```
ZABBIX_TARGET_IP=10.0.2.x        # proxy private IP
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=linux-agent-proxy
```

### Linux (direct to server)

```
ZABBIX_TARGET_IP=10.0.1.x        # server private IP
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=linux-agent-direct
```

### Windows

```
ZABBIX_TARGET_IP=10.0.2.x        # proxy private IP
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=windows-agent-01
```

---

## Step 1 — Create Trapper Item in Zabbix UI

For **each host** that will run scheduled tasks:

**Configuration → Hosts → `<hostname>` → Items → Create item**

| Field | Value |
|-------|-------|
| Name | `Scheduled task status: nightly-backup` |
| Type | `Zabbix trapper` |
| Key | `scheduled.task.status[nightly-backup]` |
| Type of information | `Numeric (unsigned)` |
| History | `7d` |
| Trends | `365d` |

**Value mapping** (shows OK/Running/Failed instead of 0/1/2):  
Value mapping tab → Add → create mapping named `Task Status`:

| Value | Mapped to |
|-------|-----------|
| `0` | `OK` |
| `1` | `Running` |
| `2` | `Failed` |

Click **Add**.

> Repeat for each task name. The value map can be reused across all items.

---

## Step 2 — Create Triggers

### Warning trigger (task running)

**Configuration → Hosts → `<hostname>` → Triggers → Create trigger**

| Field | Value |
|-------|-------|
| Name | `Task nightly-backup is running on {HOST.NAME}` |
| Severity | Warning |
| Expression | `last(/linux-agent-proxy/scheduled.task.status[nightly-backup])=1` |
| Recovery expression | `last(/linux-agent-proxy/scheduled.task.status[nightly-backup])<>1` |

### High trigger (task failed)

| Field | Value |
|-------|-------|
| Name | `Task nightly-backup FAILED on {HOST.NAME}` |
| Severity | High |
| Expression | `last(/linux-agent-proxy/scheduled.task.status[nightly-backup])=2` |
| Recovery expression | `last(/linux-agent-proxy/scheduled.task.status[nightly-backup])=0` |

---

## Step 3 — Usage on Linux

Install the task wrapper:

```bash
mkdir -p /opt/zabbix
cp /path/to/task-linux.sh /opt/zabbix/task-linux.sh
chmod +x /opt/zabbix/task-linux.sh
```

Run a task:

```bash
# Correct usage — command and args are separate tokens
/opt/zabbix/task-linux.sh "task-name" command [args...]

# Examples
/opt/zabbix/task-linux.sh "nightly-backup"  /usr/local/bin/backup.sh
/opt/zabbix/task-linux.sh "db-maintenance"  mysqldump -u root mydb

# Test cases
/opt/zabbix/task-linux.sh "test-task" sleep 30 &   # WARNING fires, then resolves
/opt/zabbix/task-linux.sh "test-task" bash -c 'exit 1'  # HIGH fires
/opt/zabbix/task-linux.sh "test-task" echo ok          # HIGH resolves
```

Schedule with cron (`crontab -e`):

```
# Run nightly backup at 2am, report to Zabbix
0 2 * * * /opt/zabbix/task-linux.sh "nightly-backup" /usr/local/bin/backup.sh

# Run DB maintenance every Sunday at 3am
0 3 * * 0 /opt/zabbix/task-linux.sh "db-maintenance" /usr/local/bin/db-maint.sh
```

---

## Step 4 — Usage on Windows

Copy the wrapper:

```powershell
New-Item 'C:\ZabbixTasks' -ItemType Directory -Force | Out-Null
Copy-Item '.\task-windows.ps1' 'C:\ZabbixTasks\task-windows.ps1'
```

Run a task:

```powershell
# Test — success
& 'C:\ZabbixTasks\task-windows.ps1' -TaskName 'win-daily-task' -ScriptBlock {
    Start-Sleep 10
    Write-Host "Done"
}

# Test — failure
& 'C:\ZabbixTasks\task-windows.ps1' -TaskName 'win-daily-task' -ScriptBlock {
    throw "Simulated failure"
}

# Register as Windows Scheduled Task (runs at 02:00 daily)
& 'C:\ZabbixTasks\task-windows.ps1' -TaskName 'win-daily-task' -Register `
    -ScheduleTime '02:00' `
    -ScriptPath 'C:\ZabbixTasks\my-actual-task.ps1'
```

---

## Manual Sender Test

Test that the sender can reach the target before creating items:

```bash
# Linux — verbose test
zabbix_sender \
    -z 10.0.2.x \
    -p 10051 \
    -s linux-agent-proxy \
    -k scheduled.task.status[test] \
    -o 0 \
    -vv
# Expected: "processed: 1; failed: 0; total: 1"
```

```powershell
# Windows
& 'C:\Program Files\Zabbix Agent\zabbix_sender.exe' `
    -z 10.0.2.x -p 10051 `
    -s windows-agent-01 `
    -k 'scheduled.task.status[test]' `
    -o 0 -vv
```

> If `failed: 1` — the Trapper item doesn't exist in Zabbix UI yet. Create it first (Step 1).

---

## Troubleshooting

```bash
# Sender fails with "connection refused"
Test-NetConnection -ComputerName 10.0.2.x -Port 10051   # Windows
nc -zv 10.0.2.x 10051                                   # Linux

# Item key mismatch — check exact key name in UI
# Key in sender MUST match key in UI exactly, including brackets

# Hostname mismatch — check sender.conf ZABBIX_HOSTNAME matches UI host name exactly
grep ZABBIX_HOSTNAME /etc/zabbix/sender.conf
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `task-linux.sh` | Bash task wrapper — wraps any command, sends lifecycle status |
| `task-windows.ps1` | PowerShell task wrapper — same pattern for Windows |
| `sender.conf.template` | Sender config template with placeholders |
