param(
    [string]$TermsrvPath = "$env:SystemRoot\System32\termsrv.dll",
    [string]$IniDir = (Join-Path $env:TEMP 'rdp-compat-cache'),
    [string]$DllPath = '',
    [switch]$Json,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$script:BinRoot = Join-Path $PSScriptRoot '..\src\bin\offsetfinder'
$script:Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'x86' -and -not $env:PROCESSOR_ARCHITEW6432) { 'x86' } else { 'x64' }
if (-not $DllPath) { $DllPath = Join-Path $script:BinRoot "$script:Arch\RDPWrapOffsetFinder.dll" }

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

function Get-SectionFingerprint {
    param($Section)
    if (-not $Section -or $Section.Count -eq 0) { return '' }
    return ((($Section.GetEnumerator() | Sort-Object Name) | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';')
}

function Get-CommunitySections {
    param([string]$Ver)
    $hits = @()
    if (Test-Path $IniDir) {
        Get-ChildItem $IniDir -Filter *.ini -ErrorAction SilentlyContinue | ForEach-Object {
            $secs = Get-IniSections (Get-Content $_.FullName -Raw)
            if ($secs.ContainsKey($Ver)) {
                $hits += @{ Source = $_.BaseName; Keys = $secs[$Ver]; SlKeys = $secs["$ver-SLInit"] }
            }
        }
    }
    return $hits
}

if (-not (Test-Path $TermsrvPath)) { Write-Error "termsrv.dll not found: $TermsrvPath"; exit 2 }
$ver = Get-TermsrvVersion $TermsrvPath
if (-not $ver) { Write-Error "cannot read version of $TermsrvPath"; exit 2 }
if (-not (Test-Path $DllPath)) { Write-Error "OffsetFinder DLL not found: $DllPath"; exit 2 }

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
$text = $sb.ToString()
$secs = Get-IniSections $text
$mainSec = $secs[$ver]
$slSec = $secs["$ver-SLInit"]
$clean = ($hr -eq 0 -and $text -notmatch 'ERROR:')
$mainFp = $(if ($mainSec) { Get-SectionFingerprint $mainSec } else { '' })
$slFp = $(if ($slSec) { Get-SectionFingerprint $slSec } else { '' })

$community = Get-CommunitySections $ver
$bestSource = ''
$perSource = @()
foreach ($hit in $community) {
    $mainOk = ($mainFp -and $mainFp -eq (Get-SectionFingerprint $hit.Keys))
    $slOk = $true
    if ($hit.SlKeys) { $slOk = ($slFp -eq (Get-SectionFingerprint $hit.SlKeys)) }
    $perSource += @{ Source = $hit.Source; Main = $(if ($mainOk) { 'MATCH' } else { 'DIFF' }); SlInit = $(if ($hit.SlKeys) { $(if ($slOk) { 'MATCH' } else { 'DIFF' }) } else { 'N/A' }) }
    if ($mainOk -and -not $bestSource) { $bestSource = $hit.Source }
}
$verdict = if ($clean -and $mainFp) { if ($bestSource) { 'PASS' } else { 'WARN' } } else { 'FAIL' }

$report = @{
    Version    = $ver
    Arch       = $script:Arch
    DllPath    = $DllPath
    HResult    = $hr
    Clean      = $clean
    Length     = $text.Length
    Verdict    = $verdict
    BestSource = $bestSource
    PerSource  = @($perSource)
}

if ($Json) {
    $jsonText = ConvertTo-Json -InputObject $report -Depth 4 -Compress
    if ($OutFile) { $jsonText | Out-File $OutFile -Encoding UTF8 } else { $jsonText }
    exit ($(if ($verdict -in @('PASS','WARN')) { 0 } else { 1 }))
}

Write-Host ""
Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
Write-Host "|  OffsetFinder 测试台 (自建 DLL / NoSym 离线)" -ForegroundColor Cyan
Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
Write-Host "  termsrv.dll : $TermsrvPath"
Write-Host "  版本        : $ver"
Write-Host "  DLL         : $DllPath"
Write-Host "  HRESULT     : $hr  输出=$($text.Length)B  含ERROR=$(-not $clean)"
foreach ($ps in $perSource) {
    $c = if ($ps.Main -eq 'MATCH') { 'Green' } else { 'Yellow' }
    Write-Host "  社区[$($ps.Source)]: 主段=$($ps.Main) SLInit=$($ps.SlInit)" -ForegroundColor $c
}
if (-not $community) { Write-Host "  社区: 无同版本段 (NO-INI)" -ForegroundColor Yellow }
Write-Host "  最佳匹配源: $bestSource" -ForegroundColor $(if ($bestSource) { 'Green' } else { 'Yellow' })
Write-Host "  判定: $verdict" -ForegroundColor $(if ($verdict -eq 'PASS') { 'Green' } elseif ($verdict -eq 'WARN') { 'Yellow' } else { 'Red' })
Write-Host "+----------------------------------------------------+" -ForegroundColor Cyan
if (-not $clean) { ($text -split "`r?`n" | Where-Object { $_ -match 'ERROR' } | Select-Object -First 3) | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
exit ($(if ($verdict -in @('PASS','WARN')) { 0 } else { 1 }))
