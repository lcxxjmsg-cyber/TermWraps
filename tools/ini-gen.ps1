param(
    [string]$TermsrvPath = "$env:SystemRoot\System32\termsrv.dll",
    [string]$OutIni = '',
    [string]$TemplateIni = '',
    [string]$DllPath = '',
    [switch]$NoRestart,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$script:BinRoot = Join-Path $PSScriptRoot '..\src\bin\offsetfinder'
$script:Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and -not $env:PROCESSOR_ARCHITEW6432) { 'x86' } else { 'x64' }
if (-not $DllPath) { $DllPath = Join-Path $script:BinRoot "$script:Arch\RDPWrapOffsetFinder.dll" }

if (-not $OutIni) { $OutIni = "$env:ProgramFiles\rdpwarp\rdpwrap.ini" }

$script:DefaultTemplate = @'
[Main]
Updated=2024-01-01
LogFile=\rdpwrap.txt
SLPolicyHookNT60=1
SLPolicyHookNT61=1

[PatchCodes]
nop=90
Zero=00
jmpshort=EB
nopjmp=90E9
CDefPolicy_Query_edx_ecx=BA000100008991200300005E90
CDefPolicy_Query_eax_rcx_jmp=B80001000089813806000090EB
CDefPolicy_Query_eax_esi=B80001000089862003000090
CDefPolicy_Query_eax_rdi=B80001000089873806000090
CDefPolicy_Query_eax_ecx=B80001000089812403000090
CDefPolicy_Query_eax_ecx_jmp=B800010000898120030000EB0E
CDefPolicy_Query_eax_rcx=B80001000089813806000090
CDefPolicy_Query_edi_rcx=BF0001000089B938060000909090
nop_3=909090
nop_7=90909090909090
mov_eax_1_nop_1=B80100000090
mov_eax_1_nop_2=B8010000009090
nop_4=90909090
pop_eax_add_esp_12_nop_2=5883C40C9090
CDefPolicy_Query_eax_rdi_jmp=B80001000089873806000090EB
CDefPolicy_Query_r9d_rdi_jmp=C7873806000000010000EB

[SLInit]
bServerSku=1
bRemoteConnAllowed=1
bFUSEnabled=1
bAppServerAllowed=1
bMultimonAllowed=1
lMaxUserSessions=0
ulMaxDebugSessions=0
bInitialized=1

[SLPolicy]
TerminalServices-RemoteConnectionManager-AllowRemoteConnections=1
TerminalServices-RemoteConnectionManager-AllowMultipleSessions=1
TerminalServices-RemoteConnectionManager-AllowAppServerMode=1
TerminalServices-RemoteConnectionManager-AllowMultimon=1
TerminalServices-RemoteConnectionManager-MaxUserSessions=0
TerminalServices-RemoteConnectionManager-ce0ad219-4670-4988-98fb-89b14c2f072b-MaxSessions=0
TerminalServices-RemoteConnectionManager-45344fe7-00e6-4ac6-9f01-d01fd4ffadfb-MaxSessions=2
TerminalServices-RDP-7-Advanced-Compression-Allowed=1
TerminalServices-RemoteConnectionManager-45344fe7-00e6-4ac6-9f01-d01fd4ffadfb-LocalOnly=0
TerminalServices-RemoteConnectionManager-8dc86f1d-9969-4379-91c1-06fe1dc60575-MaxSessions=1000
TerminalServices-DeviceRedirection-Licenses-TSEasyPrintAllowed=1
TerminalServices-DeviceRedirection-Licenses-PnpRedirectionAllowed=1
TerminalServices-DeviceRedirection-Licenses-TSMFPluginAllowed=1
TerminalServices-RemoteConnectionManager-UiEffects-DWMRemotingAllowed=1
TerminalServices-RemoteApplications-ClientSku-RAILAllowed=1
'@

function Get-TermsrvVersion {
    param([string]$Path)
    try { $fi = (Get-Item $Path).VersionInfo; return "$($fi.FileMajorPart).$($fi.FileMinorPart).$($fi.FileBuildPart).$($fi.FilePrivatePart)" } catch { return $null }
}

function Get-IniSections {
    param([string]$Content)
    $secs = @{}
    $cur = $null
    foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') { $cur = $Matches[1]; if (-not $secs.ContainsKey($cur)) { $secs[$cur] = @{} } }
        elseif ($cur -and $line -match '^\s*([^=;]+?)\s*=\s*(.*)$') { $secs[$cur][$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $secs
}

function Remove-IniSection {
    param([string]$Content, [string]$Section)
    if (-not $Content) { return $Content }
    $pattern = '(?ms)^\s*\[' + [regex]::Escape($Section) + '\]\s*\r?\n.*?(?=^\s*\[|\z)'
    return [regex]::Replace($Content, $pattern, '')
}

function Test-GeneratedCandidate {
    param([string]$Generated, [string]$Version, [string]$BaseContent)
    $a = $script:Arch
    $secs = Get-IniSections $Generated
    $main = $secs[$Version]
    $sl = $secs["$Version-SLInit"]
    $missing = @()
    if (-not $main) { $missing += 'main section' }
    else {
        foreach ($key in @("LocalOnlyOffset.$a", "SingleUserOffset.$a", "DefPolicyOffset.$a")) {
            if (-not $main.ContainsKey($key) -or $main[$key] -notmatch '^[0-9A-Fa-f]+$') { $missing += $key }
        }
        $baseSecs = Get-IniSections $BaseContent
        $codes = $baseSecs['PatchCodes']
        foreach ($key in @("LocalOnlyCode.$a", "SingleUserCode.$a", "DefPolicyCode.$a")) {
            if ($main.ContainsKey($key) -and $main[$key] -and -not $codes.ContainsKey($main[$key])) { $missing += "PatchCodes/$($main[$key])" }
        }
    }
    if (-not $sl) { $missing += 'SLInit section' }
    else {
        foreach ($name in @('bInitialized', 'bServerSku', 'lMaxUserSessions', 'bAppServerAllowed', 'bRemoteConnAllowed', 'bMultimonAllowed', 'ulMaxDebugSessions', 'bFUSEnabled')) {
            $key = "$name.$a"
            if (-not $sl.ContainsKey($key) -or $sl[$key] -notmatch '^[0-9A-Fa-f]+$') { $missing += "SLInit/$key" }
        }
    }
    return @{ Valid = ($missing.Count -eq 0); Missing = @($missing) }
}

if (-not (Test-Path $TermsrvPath)) { Write-Error "termsrv.dll not found: $TermsrvPath"; exit 2 }
$ver = Get-TermsrvVersion $TermsrvPath
if (-not $ver) { Write-Error "cannot read version of $TermsrvPath"; exit 2 }
if (-not (Test-Path $DllPath)) { Write-Error "OffsetFinder DLL not found: $DllPath"; exit 2 }

$baseContent = ''
if (Test-Path $OutIni) { $baseContent = Get-Content $OutIni -Raw }
elseif ($TemplateIni -and (Test-Path $TemplateIni)) { $baseContent = Get-Content $TemplateIni -Raw }
else { $baseContent = $script:DefaultTemplate }
if (-not (Get-IniSections $baseContent).ContainsKey('PatchCodes')) { Write-Error "base ini has no [PatchCodes] section: $OutIni"; exit 2 }

$dllEscaped = $DllPath -replace '\\', '\\'
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class RDPOffsetFinderNative {
    [DllImport("$dllEscaped", CharSet=CharSet.Unicode)]
    public static extern int FindRDPOffsetsNoSym(string path, StringBuilder output, int bufSize, int flags);
}
"@ -ErrorAction Stop
$sb = New-Object System.Text.StringBuilder 131072
$hr = [RDPOffsetFinderNative]::FindRDPOffsetsNoSym($TermsrvPath, $sb, $sb.Capacity, 0)
$generated = $sb.ToString()
if ($hr -ne 0 -or -not $generated -or $generated.Contains('ERROR:')) {
    Write-Error "OffsetFinder 生成失败 (hr=$hr)。新模式破坏时请参考 docs/self-patch-workflow.md"
    exit 3
}

$check = Test-GeneratedCandidate -Generated $generated -Version $ver -BaseContent $baseContent
if (-not $check.Valid) { Write-Error "generated candidate rejected: $($check.Missing -join ', ')"; exit 4 }

$merged = Remove-IniSection -Content $baseContent -Section $ver
$merged = Remove-IniSection -Content $merged -Section "$ver-SLInit"
$merged = "$($merged.TrimEnd())`r`n`r`n$($generated.Trim())`r`n"
if (Test-Path $OutIni) { Copy-Item $OutIni "$OutIni.bak" -Force }
New-Item -ItemType Directory -Path (Split-Path $OutIni) -Force | Out-Null
$merged | Out-File $OutIni -Encoding ASCII

$restarted = $false
if (-not $NoRestart) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Stop-Service TermService -Force -ErrorAction SilentlyContinue
        Stop-Service UmRdpService -Force -ErrorAction SilentlyContinue
        Start-Service TermService -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Service UmRdpService -ErrorAction SilentlyContinue
        $restarted = $true
    } else { Write-Warning 'Not elevated; skipping service restart (use -NoRestart or run elevated)' }
}

$report = @{
    Version   = $ver
    Arch      = $script:Arch
    DllPath   = $DllPath
    OutIni    = $OutIni
    Backup    = "$OutIni.bak"
    Restarted = $restarted
    Validated = $true
}
if ($Json) { ConvertTo-Json -InputObject $report -Depth 3 -Compress } else {
    Write-Host "  [+] $ver 生成成功 (NoSym/离线)"
    Write-Host "  [+] merged into $OutIni"
    if ($restarted) { Write-Host "  [+] TermService restarted" }
    else { Write-Host "  [!] service not restarted" }
}
exit 0
