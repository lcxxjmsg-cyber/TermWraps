# Core.Common.ps1 - 共享原语（1:1 移植自 rdpwarps.ps1）

# 注册表常量 (rdpwarps.ps1 L1163-L1169)
$REG_TS = "HKLM:\SYSTEM\CurrentControlSet\Services\TermService\Parameters"
$REG_RDP = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
$REG_RDP_WS = "$REG_RDP\WinStations\RDP-Tcp"
$REG_RDP_LIC = "$REG_RDP\Licensing Core"
$REG_WINLOGON = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$REG_POLICY = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
$REG_POLICY_LOCAL = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

# 输出助手 (L1171-L1174)
function Write-I { param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Message,[switch]$NoNewline) Write-Host "  $($Message -join ' ')" -ForegroundColor Gray -NoNewline:$NoNewline }

function Write-S { param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Message,[switch]$NoNewline) Write-Host "  [+] $($Message -join ' ')" -ForegroundColor Green -NoNewline:$NoNewline }

function Write-W { param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Message,[switch]$NoNewline) Write-Host "  [!] $($Message -join ' ')" -ForegroundColor Yellow -NoNewline:$NoNewline }

function Write-E { param([Parameter(Position=0,ValueFromRemainingArguments=$true)][object[]]$Message,[switch]$NoNewline) Write-Host "  [-] $($Message -join ' ')" -ForegroundColor Red -NoNewline:$NoNewline }

# 管理员检测 (L1247)
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# termsrv 版本 (L1253)
function Get-TermsrvVersion {
    $path = "$env:SystemRoot\System32\termsrv.dll"
    if (-not (Test-Path $path)) { return $null }
    $vi = (Get-Item $path).VersionInfo
    return "$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
}

# 注册表读写 (L1805)
function Get-RegDword { param($Path,$Name) $v = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue; if ($v) { $v.$Name } else { $null } }

function Set-RegDword {
    param($Path,$Name,$Value,$Type='DWord')
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $existing = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -ErrorAction Stop
        } else {
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        }
        return $true
    } catch { Write-W "Registry write failed: $Path\$Name ($($_.Exception.Message))"; return $false }
}
