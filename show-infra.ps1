#Requires -Version 5.1
<#
.SYNOPSIS
    Provision, check status of, or tear down the Zabbix monitoring stack on AWS ap-south-1.

.DESCRIPTION
    Default / --create  : Creates VPC, subnets, IGW, NAT Gateway, route tables, IAM SSM
                          role, 5 security groups, and 5 EC2 instances. Writes infra-state.json.
    --status            : Queries AWS and prints live instance state + IPs.
    --teardown          : Destroys every resource listed in infra-state.json in reverse order.
                          Prompts: type DELETE to confirm.

    Instances provisioned:
      zabbix-server      (t3.medium, Ubuntu 24.04, PUBLIC subnet, EIP attached)
      zabbix-proxy       (t3.small,  Ubuntu 24.04, private subnet)
      linux-agent-proxy  (t3.micro,  Ubuntu 24.04, private subnet)  -- reports via proxy
      linux-agent-direct (t3.micro,  Ubuntu 24.04, private subnet)  -- reports direct to server
      windows-agent-01   (t3.medium, Windows Server 2022, private subnet)

    SSM Agent is confirmed on ALL instances via EC2 user data (including Windows).
    No key pairs or bastion host required.

.EXAMPLE
    .\show-infra.ps1               # same as --create
    .\show-infra.ps1 --create
    .\show-infra.ps1 --status
    .\show-infra.ps1 --teardown
#>

[CmdletBinding()]
param(
    [Parameter(Position=0)][string]$Action = "",
    [switch]$Create,
    [switch]$Status,
    [switch]$Teardown
)

# Map GNU-style --flags to switches
if ($Action -eq "--create")   { $Create   = $true; $Action = "" }
if ($Action -eq "--status")   { $Status   = $true; $Action = "" }
if ($Action -eq "--teardown") { $Teardown = $true; $Action = "" }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Configuration ────────────────────────────────────────────────────────────
$AWS_PROFILE  = "sarowar-ostad"
$AWS_REGION   = "ap-south-1"
$AZ           = "ap-south-1a"
$STATE_FILE   = Join-Path $PSScriptRoot "infra-state.json"
$ROLE_NAME    = "ZabbixSSMRole"
$INST_PROF    = "ZabbixSSMProfile"

# ─── AWS CLI Wrappers ────────────────────────────────────────────────────────
# These functions use $args (automatic variable) so they accept any positional args.

function Invoke-Aws {
    # Returns parsed JSON object. Throws on non-zero exit.
    $cmdArgs = $args
    $out = & { $ErrorActionPreference = 'Continue'; aws @cmdArgs --profile $AWS_PROFILE --region $AWS_REGION --output json --no-cli-pager 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI error: $($out -join ' ')" }
    $stdout = $out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    if ($stdout) { return ($stdout -join "`n") | ConvertFrom-Json }
    return $null
}

function Invoke-AwsText {
    # Returns trimmed text output.
    $cmdArgs = $args
    $out = & { $ErrorActionPreference = 'Continue'; aws @cmdArgs --profile $AWS_PROFILE --region $AWS_REGION --output text --no-cli-pager 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "AWS CLI error: $($out -join ' ')" }
    $stdout = $out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    return ($stdout | Out-String).Trim()
}

function Invoke-AwsWait {
    # Runs an 'aws ec2 wait' command (no output). Accepts a [string[]] argument.
    param([string[]]$Cmd)
    $out = & { $ErrorActionPreference = 'Continue'; aws @Cmd --profile $AWS_PROFILE --region $AWS_REGION --no-cli-pager 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "AWS wait command failed: $($out -join ' ')" }
}

function Invoke-IamAws {
    # IAM is global — no --region needed.
    param([string[]]$Cmd)
    $out = & { $ErrorActionPreference = 'Continue'; aws @Cmd --profile $AWS_PROFILE --output json --no-cli-pager 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "AWS IAM error: $($out -join ' ')" }
    $stdout = $out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    if ($stdout) { return ($stdout -join "`n") | ConvertFrom-Json }
    return $null
}

# ─── Display Helpers ─────────────────────────────────────────────────────────
function Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function OK   { param([string]$m) Write-Host "    [+] $m" -ForegroundColor Green }
function Info { param([string]$m) Write-Host "    ... $m" -ForegroundColor DarkGray }
function Warn { param([string]$m) Write-Host "    [!] $m" -ForegroundColor Yellow }
function Sep  { Write-Host ("─" * 72) -ForegroundColor DarkGray }

# ─── State Helpers ────────────────────────────────────────────────────────────
function Save-State {
    param($s)
    $noBom = New-Object System.Text.UTF8Encoding $false
    $json  = $s | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($STATE_FILE, $json, $noBom)
    OK "State saved to infra-state.json"
}

function Read-State {
    if (-not (Test-Path $STATE_FILE)) {
        throw "infra-state.json not found. Run: .\show-infra.ps1 --create"
    }
    return Get-Content -Path $STATE_FILE -Raw | ConvertFrom-Json
}

# ─── SG Rule Helpers ──────────────────────────────────────────────────────────
function Allow-CidrIngress {
    param([string]$GroupId, [int]$Port, [string]$Cidr)
    $out = & { $ErrorActionPreference = 'Continue'
        aws ec2 authorize-security-group-ingress `
            --group-id $GroupId --protocol tcp --port $Port.ToString() --cidr $Cidr `
            --profile $AWS_PROFILE --region $AWS_REGION --output json --no-cli-pager 2>&1
    }
    if ($LASTEXITCODE -ne 0 -and ("$out" -notmatch 'InvalidPermission.Duplicate')) {
        throw "Allow-CidrIngress failed: $($out -join ' ')"
    }
}

function Allow-SgIngress {
    # Authorize ingress from another security group using ip-permissions JSON
    param([string]$GroupId, [int]$Port, [string]$SourceSgId)
    $json   = "[{`"IpProtocol`":`"tcp`",`"FromPort`":$Port,`"ToPort`":$Port,`"UserIdGroupPairs`":[{`"GroupId`":`"$SourceSgId`"}]}]"
    $tmp    = ([IO.Path]::GetTempFileName() + ".json")
    $tmpUri = $tmp.Replace('\', '/')
    $noBom  = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($tmp, $json, $noBom)
    try {
        $out = & { $ErrorActionPreference = 'Continue'
            aws ec2 authorize-security-group-ingress `
                --group-id $GroupId --ip-permissions "file://$tmpUri" `
                --profile $AWS_PROFILE --region $AWS_REGION --output json --no-cli-pager 2>&1
        }
        if ($LASTEXITCODE -ne 0 -and ("$out" -notmatch 'InvalidPermission.Duplicate')) {
            throw "Allow-SgIngress failed for $GroupId port $Port from $SourceSgId : $($out -join ' ')"
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Set-Tag {
    param([string]$ResourceId, [string]$Name)
    $null = Invoke-Aws ec2 create-tags --resources $ResourceId `
        --tags "Key=Name,Value=$Name" "Key=Project,Value=zabbix-monitoring"
}

# ─── CREATE ───────────────────────────────────────────────────────────────────
function New-ZabbixInfra {
    # Load existing state (resume mode) or start fresh
    if (Test-Path $STATE_FILE) {
        Warn "infra-state.json found — resuming from existing state (skipping completed steps)."
        $raw = Get-Content -Path $STATE_FILE -Raw | ConvertFrom-Json
        $s = [ordered]@{}
        foreach ($p in $raw.PSObject.Properties) { $s[$p.Name] = $p.Value }
        if (-not $s.Contains('instances') -or $null -eq $s.instances) {
            $s.instances = [ordered]@{}
        } else {
            $instHash = [ordered]@{}
            foreach ($ip in $s.instances.PSObject.Properties) {
                $instHash[$ip.Name] = [ordered]@{}
                foreach ($pp in $ip.Value.PSObject.Properties) { $instHash[$ip.Name][$pp.Name] = $pp.Value }
            }
            $s.instances = $instHash
        }
    } else {
        $s = [ordered]@{}
    }

    # ── 1. VPC ────────────────────────────────────────────────────────────────
    if ($s.Contains('vpc_id') -and $s.vpc_id) {
        Info "VPC already exists: $($s.vpc_id) (skipping)"
        $vpcId = $s.vpc_id
    } else {
        Step "Creating VPC (10.0.0.0/16)"
        $vpc   = Invoke-Aws ec2 create-vpc --cidr-block 10.0.0.0/16
        $vpcId = $vpc.Vpc.VpcId
        $null  = Invoke-Aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-hostnames
        $null  = Invoke-Aws ec2 modify-vpc-attribute --vpc-id $vpcId --enable-dns-support
        Set-Tag $vpcId "zbx-vpc"
        $s.vpc_id = $vpcId
        Save-State $s
        OK "VPC: $vpcId"
    }

    # ── 2. Subnets ────────────────────────────────────────────────────────────
    if ($s.Contains('public_subnet_id') -and $s.public_subnet_id) {
        Info "Subnets already exist (skipping)"
        $pubSubId = $s.public_subnet_id
        $pvtSubId = $s.private_subnet_id
    } else {
        Step "Creating subnets"
        $pubSub   = Invoke-Aws ec2 create-subnet --vpc-id $vpcId --cidr-block 10.0.1.0/24 --availability-zone $AZ
        $pubSubId = $pubSub.Subnet.SubnetId
        $null     = Invoke-Aws ec2 modify-subnet-attribute --subnet-id $pubSubId --map-public-ip-on-launch
        Set-Tag $pubSubId "zbx-public-subnet"
        $s.public_subnet_id = $pubSubId
        OK "Public  subnet: $pubSubId (10.0.1.0/24, $AZ)"

        $pvtSub   = Invoke-Aws ec2 create-subnet --vpc-id $vpcId --cidr-block 10.0.2.0/24 --availability-zone $AZ
        $pvtSubId = $pvtSub.Subnet.SubnetId
        Set-Tag $pvtSubId "zbx-private-subnet"
        $s.private_subnet_id = $pvtSubId
        Save-State $s
        OK "Private subnet: $pvtSubId (10.0.2.0/24, $AZ)"
    }

    # ── 3. Internet Gateway ───────────────────────────────────────────────────
    if ($s.Contains('igw_id') -and $s.igw_id) {
        Info "IGW already exists: $($s.igw_id) (skipping)"
        $igwId = $s.igw_id
    } else {
        Step "Creating & attaching Internet Gateway"
        $igw   = Invoke-Aws ec2 create-internet-gateway
        $igwId = $igw.InternetGateway.InternetGatewayId
        $null  = Invoke-Aws ec2 attach-internet-gateway --internet-gateway-id $igwId --vpc-id $vpcId
        Set-Tag $igwId "zbx-igw"
        $s.igw_id = $igwId
        Save-State $s
        OK "IGW: $igwId"
    }

    # ── 4. Elastic IPs ────────────────────────────────────────────────────────
    if ($s.Contains('nat_eip_alloc_id') -and $s.nat_eip_alloc_id) {
        Info "EIPs already allocated (skipping)"
    } else {
        Step "Allocating Elastic IPs (NAT Gateway + Zabbix Server)"
        $natEip = Invoke-Aws ec2 allocate-address --domain vpc
        $s.nat_eip_alloc_id = $natEip.AllocationId
        OK "NAT EIP allocation: $($natEip.AllocationId)"

        $srvEip = Invoke-Aws ec2 allocate-address --domain vpc
        $s.server_eip_alloc_id  = $srvEip.AllocationId
        $s.server_eip_public_ip = $srvEip.PublicIp
        Save-State $s
        OK "Server EIP: $($srvEip.PublicIp)  (alloc: $($srvEip.AllocationId))"
    }

    # ── 5. NAT Gateway ────────────────────────────────────────────────────────
    if ($s.Contains('nat_gw_id') -and $s.nat_gw_id) {
        Info "NAT Gateway already exists: $($s.nat_gw_id) (skipping)"
        $natGwId = $s.nat_gw_id
    } else {
        Step "Creating NAT Gateway in public subnet (takes ~90 s)"
        $natGw   = Invoke-Aws ec2 create-nat-gateway --subnet-id $pubSubId --allocation-id $s.nat_eip_alloc_id
        $natGwId = $natGw.NatGateway.NatGatewayId
        Set-Tag $natGwId "zbx-nat-gw"
        $s.nat_gw_id = $natGwId
        Save-State $s
        Info "NAT GW: $natGwId — waiting for 'available'..."
        do {
            Start-Sleep 15
            $natState = Invoke-AwsText ec2 describe-nat-gateways `
                --nat-gateway-ids $natGwId --query "NatGateways[0].State"
            Info "  state: $natState"
        } while ($natState -ne "available")
        OK "NAT Gateway available"
    }

    # ── 6. Route Tables ───────────────────────────────────────────────────────
    if ($s.Contains('public_rt_id') -and $s.public_rt_id) {
        Info "Route tables already exist (skipping)"
        $pubRtId = $s.public_rt_id
        $pvtRtId = $s.private_rt_id
    } else {
        Step "Creating route tables"
        $pubRt   = Invoke-Aws ec2 create-route-table --vpc-id $vpcId
        $pubRtId = $pubRt.RouteTable.RouteTableId
        $null    = Invoke-Aws ec2 create-route --route-table-id $pubRtId --destination-cidr-block 0.0.0.0/0 --gateway-id $igwId
        $null    = Invoke-Aws ec2 associate-route-table --route-table-id $pubRtId --subnet-id $pubSubId
        Set-Tag $pubRtId "zbx-public-rt"
        $s.public_rt_id = $pubRtId
        OK "Public  RT: $pubRtId  → IGW"

        $pvtRt   = Invoke-Aws ec2 create-route-table --vpc-id $vpcId
        $pvtRtId = $pvtRt.RouteTable.RouteTableId
        $null    = Invoke-Aws ec2 create-route --route-table-id $pvtRtId --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $natGwId
        $null    = Invoke-Aws ec2 associate-route-table --route-table-id $pvtRtId --subnet-id $pvtSubId
        Set-Tag $pvtRtId "zbx-private-rt"
        $s.private_rt_id = $pvtRtId
        Save-State $s
        OK "Private RT: $pvtRtId  → NAT GW"
    }

    # ── 7. IAM Role for SSM ───────────────────────────────────────────────────
    if ($s.Contains('iam_role_arn') -and $s.iam_role_arn -ne "") {
        Info "IAM role already exists: $ROLE_NAME (skipping)"
    } else {
        Step "Creating IAM role '$ROLE_NAME' (AmazonSSMManagedInstanceCore)"

        # Pre-check: role may already exist in AWS from a previous failed run
        $existingRole = $null
        try { $existingRole = Invoke-IamAws @("iam","get-role","--role-name",$ROLE_NAME) } catch {}

        if ($existingRole) {
            Warn "IAM role already exists in AWS — reusing"
            $s.iam_role_arn = $existingRole.Role.Arn
        } else {
            $trust = '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
            $tmpTrust    = [IO.Path]::GetTempFileName() + ".json"
            $tmpTrustUri = $tmpTrust.Replace('\', '/')
            [IO.File]::WriteAllText($tmpTrust, $trust, [Text.Encoding]::ASCII)
            try {
                $role = Invoke-IamAws @("iam","create-role","--role-name",$ROLE_NAME,
                    "--assume-role-policy-document","file://$tmpTrustUri")
                $s.iam_role_arn = $role.Role.Arn
            } finally { Remove-Item $tmpTrust -Force -ErrorAction SilentlyContinue }
        }

        # Attach policy (attach-role-policy is idempotent — safe to run even if already attached)
        try {
            $null = Invoke-IamAws @("iam","attach-role-policy","--role-name",$ROLE_NAME,
                "--policy-arn","arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore")
        } catch {}

        # Pre-check instance profile
        $existingProf = $null
        try { $existingProf = Invoke-IamAws @("iam","get-instance-profile","--instance-profile-name",$INST_PROF) } catch {}

        if ($existingProf) {
            Warn "Instance profile already exists — reusing"
            $s.instance_profile_arn = $existingProf.InstanceProfile.Arn
        } else {
            $prof = Invoke-IamAws @("iam","create-instance-profile","--instance-profile-name",$INST_PROF)
            $s.instance_profile_arn = $prof.InstanceProfile.Arn
        }

        # Add role to profile only if not already attached
        $profDetail = Invoke-IamAws @("iam","get-instance-profile","--instance-profile-name",$INST_PROF)
        $alreadyAttached = $profDetail.InstanceProfile.Roles | Where-Object { $_.RoleName -eq $ROLE_NAME }
        if (-not $alreadyAttached) {
            $null = Invoke-IamAws @("iam","add-role-to-instance-profile",
                "--instance-profile-name",$INST_PROF,"--role-name",$ROLE_NAME)
        }

        Save-State $s
        OK "IAM role=$ROLE_NAME  profile=$INST_PROF"
        Info "Waiting 15 s for IAM propagation..."
        Start-Sleep 15
    }

    # ── 8. Security Groups ────────────────────────────────────────────────────
    if ($s.Contains('sg_server') -and $s.sg_server -ne "") {
        Info "Security Groups already exist (skipping)"
        $sgSrv = $s.sg_server
        $sgPrx = $s.sg_proxy
        $sgLap = $s.sg_linux_agent_proxy
        $sgLad = $s.sg_linux_agent_direct
        $sgWin = $s.sg_windows_agent
    } else {
        Step "Creating 5 Security Groups"
        $sgSrv = (Invoke-Aws ec2 create-security-group --group-name "zbx-server" `
            --description "Zabbix Server SG" --vpc-id $vpcId).GroupId
        $sgPrx = (Invoke-Aws ec2 create-security-group --group-name "zbx-proxy" `
            --description "Zabbix Proxy SG" --vpc-id $vpcId).GroupId
        $sgLap = (Invoke-Aws ec2 create-security-group --group-name "zbx-linux-agent-proxy" `
            --description "Linux Agent via Proxy SG" --vpc-id $vpcId).GroupId
        $sgLad = (Invoke-Aws ec2 create-security-group --group-name "zbx-linux-agent-direct" `
            --description "Linux Agent Direct SG" --vpc-id $vpcId).GroupId
        $sgWin = (Invoke-Aws ec2 create-security-group --group-name "zbx-windows-agent" `
            --description "Windows Agent SG" --vpc-id $vpcId).GroupId

        Set-Tag $sgSrv "zbx-sg-server"
        Set-Tag $sgPrx "zbx-sg-proxy"
        Set-Tag $sgLap "zbx-sg-linux-proxy"
        Set-Tag $sgLad "zbx-sg-linux-direct"
        Set-Tag $sgWin "zbx-sg-windows"

        $s.sg_server             = $sgSrv
        $s.sg_proxy              = $sgPrx
        $s.sg_linux_agent_proxy  = $sgLap
        $s.sg_linux_agent_direct = $sgLad
        $s.sg_windows_agent      = $sgWin
        Save-State $s
        OK "5 SGs created"
    }

    # ── 9. SG Ingress Rules ─────────────────────────────────────────────────────────
    if ($s.Contains('sg_rules_applied') -and $s.sg_rules_applied) {
        Info "SG ingress rules already applied (skipping)"
    } else {
        Step "Configuring Security Group ingress rules"
        Allow-CidrIngress $sgSrv 8080  "0.0.0.0/0"   # Zabbix web UI
        Allow-SgIngress   $sgSrv 10051 $sgPrx          # active proxy → server
        Allow-SgIngress   $sgSrv 10051 $sgLad          # linux-agent-direct → server
        Allow-SgIngress   $sgPrx 10051 $sgLap          # linux-agent-proxy → proxy
        Allow-SgIngress   $sgPrx 10051 $sgWin          # windows-agent → proxy
        $s.sg_rules_applied = $true
        Save-State $s
        OK "SG rules applied"
    }

    # ── 10. Fetch AMI IDs ─────────────────────────────────────────────────────
    if ($s.Contains('ubuntu_ami') -and $s.ubuntu_ami -ne "") {
        Info "AMIs already fetched (skipping)"
        $uAmi = $s.ubuntu_ami
        $wAmi = $s.windows_ami
    } else {
        Step "Fetching latest AMI IDs"
        $uAmi = Invoke-AwsText ec2 describe-images `
            --owners 099720109477 `
            --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" `
                      "Name=state,Values=available" `
                      "Name=architecture,Values=x86_64" `
            --query "sort_by(Images, &CreationDate)[-1].ImageId"
        if (-not $uAmi -or $uAmi -eq 'None') {
            throw "Ubuntu 24.04 AMI not found in $AWS_REGION — check region or filter"
        }
        OK "Ubuntu 24.04 AMI: $uAmi"

        $wAmi = Invoke-AwsText ec2 describe-images `
            --owners amazon `
            --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" `
                      "Name=state,Values=available" `
                      "Name=architecture,Values=x86_64" `
            --query "sort_by(Images, &CreationDate)[-1].ImageId"
        if (-not $wAmi -or $wAmi -eq 'None') {
            throw "Windows Server 2022 AMI not found in $AWS_REGION — check region or filter"
        }
        OK "Windows Server 2022 AMI: $wAmi"

        $s.ubuntu_ami  = $uAmi
        $s.windows_ami = $wAmi
        Save-State $s
    }

    # ── 11. Launch EC2 Instances (skip any already launched) ─────────────────
    if (-not $s.Contains('instances') -or $null -eq $s.instances) { $s.instances = [ordered]@{} }

    $linuxUD = @'
#!/bin/bash
set -e
if ! snap list amazon-ssm-agent &>/dev/null 2>&1; then
    snap install amazon-ssm-agent --classic
fi
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent.service || true
'@

    $winUD = @'
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
'@

    $tmpL    = [IO.Path]::GetTempFileName() + ".sh"
    $tmpW    = [IO.Path]::GetTempFileName() + ".txt"
    $tmpLUri = $tmpL.Replace('\', '/')
    $tmpWUri = $tmpW.Replace('\', '/')
    $noBom   = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($tmpL, $linuxUD.TrimStart(), $noBom)
    [IO.File]::WriteAllText($tmpW, $winUD.TrimStart(),   $noBom)

    try {
        $launches = @(
            [ordered]@{ name="zabbix-server";      type="t3.medium"; subnet=$pubSubId; sg=$sgSrv; ami=$uAmi; ud=$tmpLUri; vol=20 }
            [ordered]@{ name="zabbix-proxy";       type="t3.small";  subnet=$pvtSubId; sg=$sgPrx; ami=$uAmi; ud=$tmpLUri; vol=15 }
            [ordered]@{ name="linux-agent-proxy";  type="t3.micro";  subnet=$pvtSubId; sg=$sgLap; ami=$uAmi; ud=$tmpLUri; vol=10 }
            [ordered]@{ name="linux-agent-direct"; type="t3.micro";  subnet=$pvtSubId; sg=$sgLad; ami=$uAmi; ud=$tmpLUri; vol=10 }
            [ordered]@{ name="windows-agent-01";   type="t3.medium"; subnet=$pvtSubId; sg=$sgWin; ami=$wAmi; ud=$tmpWUri; vol=50 }
        )

        $needWait = @()
        Step "Launching EC2 instances"
        foreach ($l in $launches) {
            if ($s.instances.Contains($l.name) -and $s.instances[$l.name].Contains('instance_id') -and $s.instances[$l.name].instance_id) {
                Info "$($l.name) already launched: $($s.instances[$l.name].instance_id) (skipping)"
                continue
            }
            Info "Launching $($l.name) ($($l.type))..."
            $bdt  = "DeviceName=/dev/sda1,Ebs={VolumeSize=$($l.vol),VolumeType=gp3,DeleteOnTermination=true}"
            $inst = Invoke-Aws ec2 run-instances `
                --image-id $l.ami `
                --instance-type $l.type `
                --subnet-id $l.subnet `
                --security-group-ids $l.sg `
                --iam-instance-profile "Name=$INST_PROF" `
                --user-data "file://$($l.ud)" `
                --block-device-mappings $bdt `
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$($l.name)},{Key=Project,Value=zabbix-monitoring}]" `
                --query "Instances[0]"
            $s.instances[$l.name] = [ordered]@{ instance_id = $inst.InstanceId }
            $needWait += $inst.InstanceId
            Save-State $s
            OK "$($l.name): $($inst.InstanceId)"
        }

        # ── 12. Wait for newly launched instances ─────────────────────────────
        if ($needWait.Count -gt 0) {
            Step "Waiting for $($needWait.Count) instance(s) to reach 'running' state..."
            Invoke-AwsWait (@("ec2","wait","instance-running","--instance-ids") + $needWait)
            OK "Instances running"
        }

        # ── 13. Collect Private IPs ───────────────────────────────────────────
        Step "Collecting private IPs"
        foreach ($name in $s.instances.Keys) {
            if ($s.instances[$name].Contains('private_ip') -and $s.instances[$name].private_ip) { Info "$name  →  $($s.instances[$name].private_ip) (cached)"; continue }
            $id  = $s.instances[$name].instance_id
            $pip = Invoke-AwsText ec2 describe-instances --instance-ids $id `
                       --query "Reservations[0].Instances[0].PrivateIpAddress"
            $s.instances[$name].private_ip = $pip
            Info "$name  →  $pip"
        }
        Save-State $s

        # ── 14. Associate Server EIP ─────────────────────────────────────────
        if (-not ($s.instances["zabbix-server"].Contains('public_ip') -and $s.instances["zabbix-server"].public_ip)) {
            $null = Invoke-Aws ec2 associate-address `
                --instance-id $s.instances["zabbix-server"].instance_id `
                --allocation-id $s.server_eip_alloc_id
            $s.instances["zabbix-server"].public_ip = $s.server_eip_public_ip
            Save-State $s
            OK "EIP $($s.server_eip_public_ip) associated with zabbix-server"
        } else {
            Info "Server EIP already associated: $($s.instances['zabbix-server'].public_ip) (skipping)"
        }

    } finally {
        Remove-Item $tmpL -Force -ErrorAction SilentlyContinue
        Remove-Item $tmpW -Force -ErrorAction SilentlyContinue
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Sep
    Write-Host "  INFRASTRUCTURE READY  —  ap-south-1 (Mumbai)" -ForegroundColor Green
    Sep
    Write-Host ("  " + "Instance".PadRight(24) + "Private IP".PadRight(18) + "Public IP / Notes") -ForegroundColor White
    Write-Host ("  " + ("─" * 66))
    foreach ($n in $s.instances.Keys) {
        $i   = $s.instances[$n]
        $pip = if ($i.Contains('private_ip') -and $i.private_ip) { $i.private_ip } else { "" }
        $pub = if ($i.Contains('public_ip')  -and $i.public_ip)  { $i.public_ip  } else { "(private only — SSM access)" }
        Write-Host ("  " + $n.PadRight(24) + $pip.PadRight(18) + $pub)
    }
    Write-Host ""
    Write-Host "  Zabbix Web UI : http://$($s.server_eip_public_ip):8080" -ForegroundColor Cyan
    Write-Host "  SSM session   : aws ssm start-session --target <id> --profile $AWS_PROFILE --region $AWS_REGION" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Next step: follow INSTALL.md to configure each component." -ForegroundColor White
    Sep
}

# ─── STATUS ──────────────────────────────────────────────────────────────────
function Get-ZabbixStatus {
    $state = Read-State
    Write-Host ""
    Sep
    Write-Host "  ZABBIX INFRASTRUCTURE STATUS  —  ap-south-1" -ForegroundColor Cyan
    Sep
    Write-Host ("  " + "Instance".PadRight(24) + "Instance ID".PadRight(22) + "State".PadRight(14) + "Private IP".PadRight(18) + "Public IP") -ForegroundColor White
    Write-Host ("  " + ("─" * 86))
    foreach ($n in $state.instances.PSObject.Properties.Name) {
        $inst = $state.instances.$n
        $id   = $inst.instance_id
        $info = Invoke-Aws ec2 describe-instances --instance-ids $id `
                    --query "Reservations[0].Instances[0]"
        $iState = $info.State.Name
        $pip    = if ($info.PrivateIpAddress)  { $info.PrivateIpAddress } else { "" }
        $eip    = if ($info.PublicIpAddress)   { $info.PublicIpAddress  } else { "" }
        $col    = switch ($iState) { "running" { "Green" } "stopped" { "Yellow" } default { "Red" } }
        Write-Host ("  " + $n.PadRight(24) + $id.PadRight(22) + $iState.PadRight(14) + $pip.PadRight(18) + $eip) -ForegroundColor $col
    }
    Write-Host ""
    Write-Host "  Zabbix Web UI : http://$($state.server_eip_public_ip):8080" -ForegroundColor Cyan
    Sep
}

# ─── TEARDOWN ────────────────────────────────────────────────────────────────
function Remove-ZabbixInfra {
    $state = Read-State

    Write-Host ""
    Warn "This will PERMANENTLY DELETE all Zabbix infrastructure in ap-south-1:"
    Warn "  5 EC2 instances, VPC, 2 EIPs, NAT Gateway, IGW, subnets, SGs, IAM role."
    Write-Host ""
    $confirm = Read-Host "Type DELETE to confirm teardown"
    if ($confirm -ne "DELETE") {
        Write-Host "Teardown cancelled." -ForegroundColor Yellow
        return
    }

    # ── 1. Terminate instances ────────────────────────────────────────────────
    Step "Terminating EC2 instances"
    $ids = @($state.instances.PSObject.Properties | ForEach-Object { $_.Value.instance_id })
    if ($ids.Count -gt 0) {
        $null = Invoke-Aws (@("ec2","terminate-instances","--instance-ids") + $ids)
        Info "Waiting for termination (2-4 min)..."
        Invoke-AwsWait (@("ec2","wait","instance-terminated","--instance-ids") + $ids)
        OK "All instances terminated"
    }

    # ── 2. Revoke cross-SG rules and delete SGs ───────────────────────────────
    Step "Deleting Security Groups"
    $sgIds = @(
        $state.sg_server, $state.sg_proxy,
        $state.sg_linux_agent_proxy, $state.sg_linux_agent_direct, $state.sg_windows_agent
    ) | Where-Object { $_ }

    # Revoke ingress rules first (breaks cross-SG dependencies)
    foreach ($sgId in $sgIds) {
        try {
            $sg = Invoke-Aws ec2 describe-security-groups --group-ids $sgId
            $perms = $sg.SecurityGroups[0].IpPermissions
            if ($perms -and $perms.Count -gt 0) {
                $permJson = $perms | ConvertTo-Json -Depth 8 -Compress
                # Ensure it's an array
                if (-not $permJson.StartsWith("[")) { $permJson = "[$permJson]" }
                $tmpRevoke    = [IO.Path]::GetTempFileName() + ".json"
                $tmpRevokeUri = $tmpRevoke.Replace('\', '/')
                $noBom        = New-Object System.Text.UTF8Encoding $false
                [IO.File]::WriteAllText($tmpRevoke, $permJson, $noBom)
                try {
                    aws ec2 revoke-security-group-ingress --group-id $sgId `
                        --ip-permissions "file://$tmpRevokeUri" `
                        --profile $AWS_PROFILE --region $AWS_REGION --output json --no-cli-pager | Out-Null
                } finally { Remove-Item $tmpRevoke -Force -ErrorAction SilentlyContinue }
            }
        } catch { Warn "Could not revoke rules for $sgId (proceeding)" }
    }

    foreach ($sgId in $sgIds) {
        try { $null = Invoke-Aws ec2 delete-security-group --group-id $sgId; OK "Deleted SG $sgId" }
        catch { Warn "Could not delete SG $sgId : $($_.Exception.Message)" }
    }

    # ── 3. Delete NAT Gateway ─────────────────────────────────────────────────
    Step "Deleting NAT Gateway"
    if ($state.nat_gw_id) {
        try {
            $null = Invoke-Aws ec2 delete-nat-gateway --nat-gateway-id $state.nat_gw_id
            Info "Waiting for NAT GW deletion (~60 s)..."
            do {
                Start-Sleep 15
                $ns = Invoke-AwsText ec2 describe-nat-gateways `
                    --nat-gateway-ids $state.nat_gw_id --query "NatGateways[0].State"
                Info "  state: $ns"
            } while ($ns -notin @('deleted','failed',''))
            OK "NAT Gateway deleted"
        } catch { Warn "NAT GW deletion issue: $($_.Exception.Message)" }
    }

    # ── 4. Release Elastic IPs ────────────────────────────────────────────────
    Step "Releasing Elastic IPs"
    foreach ($allocId in @($state.nat_eip_alloc_id, $state.server_eip_alloc_id) | Where-Object { $_ }) {
        try { $null = Invoke-Aws ec2 release-address --allocation-id $allocId; OK "Released EIP $allocId" }
        catch { Warn "Could not release EIP $allocId" }
    }

    # ── 5. Detach & delete Internet Gateway ──────────────────────────────────
    Step "Detaching and deleting Internet Gateway"
    if ($state.igw_id -and $state.vpc_id) {
        try {
            $null = Invoke-Aws ec2 detach-internet-gateway --internet-gateway-id $state.igw_id --vpc-id $state.vpc_id
            $null = Invoke-Aws ec2 delete-internet-gateway --internet-gateway-id $state.igw_id
            OK "IGW $($state.igw_id) deleted"
        } catch { Warn "IGW issue: $($_.Exception.Message)" }
    }

    # ── 6. Delete Route Tables ────────────────────────────────────────────────
    Step "Deleting route tables"
    foreach ($rtId in @($state.public_rt_id, $state.private_rt_id) | Where-Object { $_ }) {
        try {
            $rt = Invoke-Aws ec2 describe-route-tables --route-table-ids $rtId
            foreach ($assoc in $rt.RouteTables[0].Associations) {
                if (-not $assoc.Main) {
                    $null = Invoke-Aws ec2 disassociate-route-table --association-id $assoc.RouteTableAssociationId
                }
            }
            $null = Invoke-Aws ec2 delete-route-table --route-table-id $rtId
            OK "Deleted route table $rtId"
        } catch { Warn "RT deletion issue ($rtId): $($_.Exception.Message)" }
    }

    # ── 7. Delete Subnets ─────────────────────────────────────────────────────
    Step "Deleting subnets"
    foreach ($subId in @($state.public_subnet_id, $state.private_subnet_id) | Where-Object { $_ }) {
        try { $null = Invoke-Aws ec2 delete-subnet --subnet-id $subId; OK "Deleted subnet $subId" }
        catch { Warn "Could not delete subnet $subId" }
    }

    # ── 8. Delete VPC ────────────────────────────────────────────────────────
    Step "Deleting VPC"
    if ($state.vpc_id) {
        try { $null = Invoke-Aws ec2 delete-vpc --vpc-id $state.vpc_id; OK "VPC $($state.vpc_id) deleted" }
        catch { Warn "VPC deletion issue: $($_.Exception.Message)" }
    }

    # ── 9. IAM Cleanup ────────────────────────────────────────────────────────
    Step "Cleaning up IAM role and instance profile"
    try { $null = Invoke-IamAws @("iam","remove-role-from-instance-profile","--instance-profile-name",$INST_PROF,"--role-name",$ROLE_NAME) } catch {}
    try { $null = Invoke-IamAws @("iam","delete-instance-profile","--instance-profile-name",$INST_PROF); OK "Instance profile deleted" } catch { Warn "Could not delete instance profile" }
    try { $null = Invoke-IamAws @("iam","detach-role-policy","--role-name",$ROLE_NAME,"--policy-arn","arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore") } catch {}
    try { $null = Invoke-IamAws @("iam","delete-role","--role-name",$ROLE_NAME); OK "IAM role $ROLE_NAME deleted" } catch { Warn "Could not delete IAM role" }

    # ── 10. Remove state file ─────────────────────────────────────────────────
    Remove-Item $STATE_FILE -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "  TEARDOWN COMPLETE — all Zabbix infrastructure removed." -ForegroundColor Green
    Sep
}

# ─── Entry Point ─────────────────────────────────────────────────────────────
if     ($Teardown) { Remove-ZabbixInfra }
elseif ($Status)   { Get-ZabbixStatus   }
else               { New-ZabbixInfra    }   # --create or no flag
