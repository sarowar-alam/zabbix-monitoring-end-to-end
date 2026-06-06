#Requires -Version 5.1
<#
.SYNOPSIS
    Install and configure Zabbix Agent 7.0 on Windows Server 2022.

.DESCRIPTION
    Downloads Zabbix Agent 7.0 MSI, installs silently, writes the agent
    configuration, installs the Windows service, and creates a sender.conf
    for use with task-windows.ps1.

    The agent runs in ACTIVE mode — it connects OUT to the Zabbix Proxy
    on port 10051. No inbound ports are required on the Windows SG.

.PARAMETER ProxyIp
    Private IP of the Zabbix Proxy (e.g. "10.0.2.x")

.PARAMETER Hostname
    Zabbix host name — must match EXACTLY what you create in the Zabbix UI.
    Default: "windows-agent-01"

.PARAMETER ZabbixVersion
    Zabbix agent version to download. Default: "7.0.9"

.EXAMPLE
    # Run as Administrator via SSM Run Command or Fleet Manager
    .\install-agent-windows.ps1 -ProxyIp "10.0.2.50"
    .\install-agent-windows.ps1 -ProxyIp "10.0.2.50" -Hostname "windows-agent-01"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
    [string]$ProxyIp,

    [string]$Hostname      = "windows-agent-01",
    [string]$ZabbixVersion = "7.0.9"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Constants ─────────────────────────────────────────────────────────────────
$INSTALL_DIR = "C:\Program Files\Zabbix Agent"
$LOG_DIR     = "C:\ProgramData\Zabbix"
$CONF_FILE   = "$INSTALL_DIR\zabbix_agentd.conf"
$SENDER_CONF = "C:\ProgramData\Zabbix\sender.conf"
$SERVICE_NAME= "Zabbix Agent"

# Build MSI download URL (official Zabbix CDN)
$MajorMinor  = ($ZabbixVersion -split "\." | Select-Object -First 2) -join "."
$MSI_URL     = "https://cdn.zabbix.com/zabbix/binaries/stable/$MajorMinor/$ZabbixVersion/windows/amd64/zabbix_agent-$ZabbixVersion-windows-amd64-openssl.msi"
$MSI_PATH    = "C:\Windows\Temp\zabbix_agent.msi"
$LOG_PATH    = "C:\Windows\Temp\zabbix_agent_install.log"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [+] $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "    ... $m" -ForegroundColor DarkGray }
function Write-Warn { param([string]$m) Write-Host "    [!] $m" -ForegroundColor Yellow }

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Zabbix $ZabbixVersion Agent Installation — Windows Server 2022"
Write-Host "  Proxy IP  : $ProxyIp"
Write-Host "  Hostname  : $Hostname"
Write-Host "============================================================" -ForegroundColor Cyan

# ── 1. Check Administrator ────────────────────────────────────────────────────
Write-Step "Checking privileges"
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run as Administrator."
}
Write-OK "Running as Administrator"

# ── 2. Stop existing agent if installed ───────────────────────────────────────
Write-Step "Checking for existing Zabbix Agent installation"
$existingSvc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Info "Existing service found (state: $($existingSvc.Status)) — stopping..."
    Stop-Service -Name $SERVICE_NAME -Force -ErrorAction SilentlyContinue
    Start-Sleep 3
    Write-Info "Uninstalling old agent via MSI..."
    $oldMsi = Get-WmiObject -Class Win32_Product -Filter "Name LIKE 'Zabbix Agent%'" -ErrorAction SilentlyContinue
    if ($oldMsi) {
        $oldMsi.Uninstall() | Out-Null
        Write-OK "Old agent uninstalled"
    }
} else {
    Write-Info "No existing Zabbix Agent service found"
}

# ── 3. Download MSI ───────────────────────────────────────────────────────────
Write-Step "Downloading Zabbix Agent $ZabbixVersion MSI"
Write-Info "URL: $MSI_URL"

# Disable progress bar for faster downloads
$ProgressPreference = "SilentlyContinue"
try {
    Invoke-WebRequest -Uri $MSI_URL -OutFile $MSI_PATH -UseBasicParsing
    Write-OK "Downloaded to $MSI_PATH"
} catch {
    # Try alternative URL format
    Write-Warn "First URL failed, trying alternative..."
    $MSI_URL_ALT = "https://cdn.zabbix.com/zabbix/binaries/stable/$MajorMinor/$ZabbixVersion/windows/amd64/zabbix_agent-$ZabbixVersion-windows-amd64.msi"
    Invoke-WebRequest -Uri $MSI_URL_ALT -OutFile $MSI_PATH -UseBasicParsing
    Write-OK "Downloaded to $MSI_PATH (alternative URL)"
}
$ProgressPreference = "Continue"

# Verify download
if (-not (Test-Path $MSI_PATH) -or (Get-Item $MSI_PATH).Length -lt 1MB) {
    throw "MSI download appears corrupt or incomplete. Check URL and connectivity."
}

# ── 4. Install MSI ────────────────────────────────────────────────────────────
Write-Step "Installing Zabbix Agent (silent MSI install)"

$msiArgs = @(
    "/i", $MSI_PATH,
    "/quiet",
    "/l*v", $LOG_PATH,
    "SERVER=$ProxyIp",
    "SERVERACTIVE=$ProxyIp",
    "HOSTNAME=$Hostname",
    "LISTENPORT=10050",
    "LOGFILE=$LOG_DIR\zabbix_agentd.log",
    "ENABLEPATH=1"
)

$proc = Start-Process "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Warn "MSI exit code: $($proc.ExitCode). Check log at $LOG_PATH"
    Write-Warn "Common fix: ensure .NET is available and re-run."
    throw "MSI installation failed (exit code $($proc.ExitCode))"
}
Write-OK "MSI installed (exit 0)"

# ── 5. Write Configuration File ───────────────────────────────────────────────
Write-Step "Writing Zabbix Agent configuration"

# Create directories
New-Item -ItemType Directory -Path $LOG_DIR      -Force | Out-Null
New-Item -ItemType Directory -Path $INSTALL_DIR  -Force | Out-Null

$agentConf = @"
# Zabbix Agent Configuration — windows-agent-01
# Generated by install-agent-windows.ps1

LogFile=$LOG_DIR\zabbix_agentd.log
LogFileSize=10
DebugLevel=3

# Server: allow-list for passive checks
Server=$ProxyIp

# ServerActive: agent dials OUT to proxy for active checks
ServerActive=$ProxyIp

# Hostname must match EXACTLY what is set in the Zabbix UI
Hostname=$Hostname

# Include custom UserParameters (for task wrapper)
Include=$INSTALL_DIR\zabbix_agentd.d\*.conf
"@

$agentConf | Set-Content -Path $CONF_FILE -Encoding UTF8
Write-OK "Config written to $CONF_FILE"

# Create include directory
New-Item -ItemType Directory -Path "$INSTALL_DIR\zabbix_agentd.d" -Force | Out-Null

# ── 6. Write Sender Config ────────────────────────────────────────────────────
Write-Step "Writing sender configuration"
$senderConf = @"
# Zabbix Sender configuration
# Used by task-windows.ps1
ZABBIX_TARGET_IP=$ProxyIp
ZABBIX_TARGET_PORT=10051
ZABBIX_HOSTNAME=$Hostname
"@
$senderConf | Set-Content -Path $SENDER_CONF -Encoding UTF8
Write-OK "Sender config written to $SENDER_CONF"

# ── 7. Configure and Start Service ────────────────────────────────────────────
Write-Step "Configuring and starting Zabbix Agent service"

# Re-read service after MSI install
$svc = Get-Service -Name $SERVICE_NAME -ErrorAction SilentlyContinue
if (-not $svc) {
    # MSI should have created it; try manual install
    Write-Warn "Service not found after MSI — attempting manual service creation..."
    $agentExe = "$INSTALL_DIR\zabbix_agentd.exe"
    if (Test-Path $agentExe) {
        & $agentExe --config $CONF_FILE --install
        Start-Sleep 2
    } else {
        throw "zabbix_agentd.exe not found at $agentExe. MSI may have failed."
    }
}

Set-Service  -Name $SERVICE_NAME -StartupType Automatic
Start-Service -Name $SERVICE_NAME

Start-Sleep 3
$svcState = (Get-Service -Name $SERVICE_NAME).Status
if ($svcState -eq "Running") {
    Write-OK "Zabbix Agent service is Running"
} else {
    Write-Warn "Service state: $svcState (expected Running)"
}

# ── 8. Windows Firewall ───────────────────────────────────────────────────────
Write-Step "Configuring Windows Firewall (outbound to proxy)"
# Allow outbound to proxy on 10051 (active mode only — no inbound needed)
$fwRule = Get-NetFirewallRule -DisplayName "Zabbix Agent Outbound" -ErrorAction SilentlyContinue
if (-not $fwRule) {
    New-NetFirewallRule -DisplayName "Zabbix Agent Outbound" `
        -Direction Outbound `
        -Protocol TCP `
        -RemotePort 10051 `
        -RemoteAddress $ProxyIp `
        -Action Allow | Out-Null
    Write-OK "Outbound firewall rule created (port 10051 to $ProxyIp)"
} else {
    Write-Info "Firewall rule already exists"
}

# Clean up MSI
Remove-Item $MSI_PATH -Force -ErrorAction SilentlyContinue

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Installation Complete!"
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Proxy IP  : $ProxyIp`:10051"
Write-Host "  Hostname  : $Hostname"
Write-Host "  Config    : $CONF_FILE"
Write-Host "  Log       : $LOG_DIR\zabbix_agentd.log"
Write-Host ""
Write-Host "  IMPORTANT — Add this host in the Zabbix UI (see INSTALL.md Phase 5):"
Write-Host "    Configuration → Hosts → Create host"
Write-Host "    Host name          : $Hostname"
Write-Host "    Monitored by proxy : ZabbixProxy01"
Write-Host "    Template           : Windows by Zabbix agent"
Write-Host ""
Write-Host "  Copy task-windows.ps1 to C:\ZabbixTasks\ for scheduled task alerting."
Write-Host "============================================================" -ForegroundColor Green
