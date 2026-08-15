param(
    [switch]$Force,
    [switch]$CheckOnly,
    [string]$RdpwarpsRoot = ''
)

$ErrorActionPreference = 'Stop'
$script:BuildRoot = $PSScriptRoot
$script:BuildScript = Join-Path $script:BuildRoot 'build.ps1'

if (-not $RdpwarpsRoot) {
    $candidates = @(
        (Join-Path $script:BuildRoot '..\..\RDPWarpper'),
        (Join-Path $PWD 'RDPWarpper'),
        (Join-Path $script:BuildRoot '..\RDPWarpper')
    ) | ForEach-Object { [System.IO.Path]::GetFullPath($_) } | Select-Object -Unique
    $RdpwarpsRoot = $candidates | Where-Object { Test-Path (Join-Path $_ 'rdpwarps.ps1') } | Select-Object -First 1
}
if (-not $RdpwarpsRoot -or -not (Test-Path (Join-Path $RdpwarpsRoot 'rdpwarps.ps1'))) {
    Write-Error "找不到 rdpwarps.ps1，请用 -RdpwarpsRoot 指定（如: .\update-rdpwarp.ps1 -RdpwarpsRoot D:\path\RDPWarpper）"
    exit 2
}

Write-Host '=== TermWrap / OffsetFinder 更新助手（双上游自动追踪）==='
Write-Host "rdpwarps 目录: $RdpwarpsRoot"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vswhere) { & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } else { '' }
if (-not $vs -and -not $CheckOnly) {
    Write-Host '  [!] 未检测到 VS Build Tools（含 VC 工具链）——构建必需，安装: https://aka.ms/buildtools'
}

$repos = @(
    @{ Key = 'offsetfinder-master.zip'; Repo = 'llccd/RDPWrapOffsetFinder'; Label = 'OffsetFinder'; Label2 = 'RDPWrapOffsetFinder' },
    @{ Key = 'termwrap-master.zip';    Repo = 'llccd/TermWrap';             Label = 'TermWrap';      Label2 = 'TermWrap' }
)

$bp = Get-Content $script:BuildScript -Raw
$changed = $false
foreach ($repo in $repos) {
    $line = ($bp -split "`r?`n") | Where-Object { $_ -match "Name = '$($repo.Key)'" } | Select-Object -First 1
    if (-not $line) { throw "pin line not found: $($repo.Key)" }
    $cur = [regex]::Match($line, 'zip/([0-9a-f]{40})').Groups[1].Value
    $curHash = [regex]::Match($line, "Sha256 = '([0-9A-F]{64})'").Groups[1].Value
    Write-Host "$($repo.Label) current pin: $cur"

    try {
        $commit = (Invoke-RestMethod -Uri "https://api.github.com/repos/$($repo.Repo)/commits/master" -Headers @{ 'User-Agent' = 'ps' } -TimeoutSec 30).sha
        Write-Host "$($repo.Label) master     : $commit"
    } catch {
        Write-Host "  [!] $($repo.Label) master 检测失败：$($_.Exception.Message)（保留当前 pin）"
        continue
    }

    if ($commit -ne $cur -or $Force) {
        if ($CheckOnly) { Write-Host "  [*] $($repo.Label) 有更新待拉取（$($cur.Substring(0,10)) -> $($commit.Substring(0,10))）；-CheckOnly 模式跳过构建"; continue }
        $zip = Join-Path $env:TEMP "$($repo.Key)-$commit.zip"
        Invoke-WebRequest -Uri "https://codeload.github.com/$($repo.Repo)/zip/$commit" -OutFile $zip -UseBasicParsing -TimeoutSec 300
        $h = (Get-FileHash $zip -Algorithm SHA256).Hash
        $bp = $bp.Replace("zip/$cur", "zip/$commit").Replace("Sha256 = '$curHash'", "Sha256 = '$h'")
        $changed = $true
        Write-Host "  pin updated: $($cur.Substring(0,10)) -> $($commit.Substring(0,10))  SHA256=$h"
    } else {
        Write-Host "  $($repo.Label) 已是最新 master"
    }
}
if ($changed -and -not $CheckOnly) {
    $bp | Out-File $script:BuildScript -Encoding UTF8
}
if ($CheckOnly) { Write-Host '=== 检查完成（-CheckOnly，未构建）==='; exit 0 }

Write-Host '=== building ==='
& $script:BuildScript
if ($LASTEXITCODE -ne 0) { throw 'build failed' }

Write-Host '=== deploying OffsetFinder to rdpwarps ==='
foreach ($arch in @('x64','x86')) {
    $src = Join-Path $script:BuildRoot "..\src\bin\offsetfinder\$arch\RDPWrapOffsetFinder.dll"
    $dst = Join-Path $RdpwarpsRoot "bin\RDPWrapOffsetFinder_$arch.dll"
    if (-not (Test-Path $src)) { throw "missing: $src" }
    Copy-Item $src $dst -Force
    Write-Host "  deployed: $dst"
}
$rp = Get-Content (Join-Path $RdpwarpsRoot 'rdpwarps.ps1') -Raw -Encoding UTF8
$h64 = (Get-FileHash (Join-Path $RdpwarpsRoot 'bin\RDPWrapOffsetFinder_x64.dll') -Algorithm SHA256).Hash
$h86 = (Get-FileHash (Join-Path $RdpwarpsRoot 'bin\RDPWrapOffsetFinder_x86.dll') -Algorithm SHA256).Hash
$rp = [regex]::Replace($rp, "'RDPWrapOffsetFinder_x64\.dll'='[0-9A-F]{64}'", "'RDPWrapOffsetFinder_x64.dll'='$h64'")
$rp = [regex]::Replace($rp, "'RDPWrapOffsetFinder_x86\.dll'='[0-9A-F]{64}'", "'RDPWrapOffsetFinder_x86.dll'='$h86'")
$rp | Out-File (Join-Path $RdpwarpsRoot 'rdpwarps.ps1') -Encoding UTF8
Write-Host "  pins updated in rdpwarps.ps1: x64=$($h64.Substring(0,16))... x86=$($h86.Substring(0,16))..."
Write-Host ''
Write-Host '=== DONE ==='
