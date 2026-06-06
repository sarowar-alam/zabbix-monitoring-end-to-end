#Requires -Version 5.1
<#
.SYNOPSIS
    Zabbix Sender — Scheduled Task Lifecycle Wrapper (Windows)

.DESCRIPTION
    Wraps any PowerShell ScriptBlock and reports its lifecycle to Zabbix via sender.

    Alert lifecycle (dead man's switch pattern):
      Task STARTS    → sends 1 → Zabbix raises WARNING  "Task is running"
      Task SUCCEEDS  → sends 0 → WARNING auto-resolves  (OK)
      Task FAILS     → sends 2 → Zabbix raises HIGH     "Task FAILED"
                                  stays HIGH until next successful run

    Trapper item key: scheduled.task.status[<task-name>]
    Values: 0=OK/idle  1=running  2=failed

.PARAMETER TaskName
    Logical name of the task — used as the Zabbix item key parameter.
    Example: "nightly-backup", "db-maintenance"

.PARAMETER ScriptBlock
    The PowerShell code to execute. Any thrown exception = failure (status 2).

.PARAMETER SenderConfPath
    Path to sender.conf containing target IP, port, and hostname.
    Default: C:\ProgramData\Zabbix\sender.conf

.EXAMPLE
    # Simple usage
    .\task-windows.ps1 -TaskName "nightly-backup" -ScriptBlock {
        Compress-Archive -Path "C:\Data\*" -DestinationPath "C:\Backup\backup.zip" -Force
    }

    # Register as a Windows Scheduled Task (runs daily at 02:00)
    .\task-windows.ps1 -TaskName "db-export" -Register -ScheduleTime "02:00"

.NOTES
    Run as Administrator or as the account that has write access to the log directory.
    The ScriptBlock runs in the same PowerShell session — use full paths in scripts.
#>

[CmdletBinding(DefaultParameterSetName = "Run")]
param(
    [Parameter(Mandatory, ParameterSetName = "Run")]
    [Parameter(Mandatory, ParameterSetName = "Register")]
    [string]$TaskName,

    [Parameter(Mandatory, ParameterSetName = "Run")]
    [scriptblock]$ScriptBlock,

    [Parameter(ParameterSetName = "Register")]
    [switch]$Register,

    [Parameter(ParameterSetName = "Register")]
    [string]$ScheduleTime = "02:00",

    [Parameter(ParameterSetName = "Register")]
    [string]$ScriptPath,   # full path to the .ps1 that wraps the real work

    [string]$SenderConfPath = "C:\ProgramData\Zabbix\sender.conf"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Load Configuration ───────────────────────────────────────────────────────
$cfg = @{
    ZABBIX_TARGET_IP   = ""
    ZABBIX_TARGET_PORT = "10051"
    ZABBIX_HOSTNAME    = "windows-agent-01"
}

if (Test-Path $SenderConfPath) {
    Get-Content $SenderConfPath | Where-Object { $_ -match "^\s*[^#].*=" } | ForEach-Object {
        $parts = $_ -split "=", 2
        if ($parts.Count -eq 2) {
            $cfg[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
} else {
    Write-Warning "sender.conf not found at $SenderConfPath — using defaults."
    Write-Warning "Run install-agent-windows.ps1 first, or create sender.conf manually."
}

# Allow environment variable overrides
if ($env:ZABBIX_TARGET_IP)   { $cfg.ZABBIX_TARGET_IP   = $env:ZABBIX_TARGET_IP   }
if ($env:ZABBIX_TARGET_PORT) { $cfg.ZABBIX_TARGET_PORT = $env:ZABBIX_TARGET_PORT }
if ($env:ZABBIX_HOSTNAME)    { $cfg.ZABBIX_HOSTNAME    = $env:ZABBIX_HOSTNAME    }

$ITEM_KEY    = "scheduled.task.status[$TaskName]"
$SENDER_EXE  = "C:\Program Files\Zabbix Agent\zabbix_sender.exe"
$LOG_PREFIX  = "[zabbix-task][$TaskName]"

# ─── Sender Function ──────────────────────────────────────────────────────────
function Send-ZabbixStatus {
    param([int]$Value)
    $label = switch ($Value) { 0 { "OK" } 1 { "RUNNING" } 2 { "FAILED" } default { "UNKNOWN" } }
    Write-Host "$LOG_PREFIX Sending status=$Value ($label) → $($cfg.ZABBIX_TARGET_IP):$($cfg.ZABBIX_TARGET_PORT)"

    if (-not (Test-Path $SENDER_EXE)) {
        Write-Warning "$LOG_PREFIX zabbix_sender.exe not found at $SENDER_EXE — status NOT sent."
        return
    }

    try {
        $result = & $SENDER_EXE `
            -z $cfg.ZABBIX_TARGET_IP `
            -p $cfg.ZABBIX_TARGET_PORT `
            -s $cfg.ZABBIX_HOSTNAME `
            -k $ITEM_KEY `
            -o $Value.ToString() 2>&1
        Write-Host "    $result"
    } catch {
        Write-Warning "$LOG_PREFIX Sender failed: $_"
    }
}

# ─── Register Mode ────────────────────────────────────────────────────────────
if ($Register) {
    if (-not $ScriptPath -or -not (Test-Path $ScriptPath)) {
        throw "-ScriptPath is required and must point to an existing .ps1 file when using -Register."
    }

    $taskAction  = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    $taskTrigger = New-ScheduledTaskTrigger -Daily -At $ScheduleTime

    $taskSettings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -RestartCount 0 `
        -StartWhenAvailable

    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName "ZabbixTask-$TaskName" `
        -Action   $taskAction `
        -Trigger  $taskTrigger `
        -Settings $taskSettings `
        -Principal $taskPrincipal `
        -Force | Out-Null

    Write-Host ""
    Write-Host "[+] Scheduled Task 'ZabbixTask-$TaskName' registered." -ForegroundColor Green
    Write-Host "    Schedule : Daily at $ScheduleTime"
    Write-Host "    Script   : $ScriptPath"
    Write-Host "    User     : SYSTEM"
    Write-Host ""
    Write-Host "    Verify in Task Scheduler → Task Scheduler Library → ZabbixTask-$TaskName"
    return
}

# ─── Run Mode ─────────────────────────────────────────────────────────────────
Write-Host "$LOG_PREFIX Starting task execution"

# Signal: task is running
Send-ZabbixStatus 1

$exitCode = 0
try {
    & $ScriptBlock
    Write-Host "$LOG_PREFIX Task completed successfully"
    Send-ZabbixStatus 0
} catch {
    $exitCode = 1
    Write-Error "$LOG_PREFIX Task FAILED: $_"
    Send-ZabbixStatus 2
    exit $exitCode
}

exit $exitCode
