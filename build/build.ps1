param(
    [switch]$Clean,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$script:BuildRoot = $PSScriptRoot
$script:SrcRoot = Join-Path $script:BuildRoot 'src'
$script:CacheDir = Join-Path $script:BuildRoot 'cache'
$script:OutRoot = Join-Path $script:BuildRoot 'out'
$script:BinRoot = Join-Path (Split-Path $script:BuildRoot -Parent) 'src\bin\offsetfinder'

$script:Pins = @(
    @{ Name = 'offsetfinder-master.zip'; Url = 'https://codeload.github.com/llccd/RDPWrapOffsetFinder/zip/60fbe8de72662f9748e283398d8eb364afa6712b'; Sha256 = '88DAF1A7394513DC9865E46CBAAE15EC3BADD5570331C6D906C660A3E8C072B7'; Extract = @{ Into = "$script:SrcRoot\offsetfinder"; Flat = 'RDPWrapOffsetFinder' } }
    @{ Name = 'termwrap-master.zip'; Url = 'https://codeload.github.com/llccd/TermWrap/zip/5d425e6e1584a82e4811c2ecc8529fd4a51e93df'; Sha256 = '8BA0D89EE6B71F6A0030CA3EADBFEF19767254FE2983CDEEDDAE94699E0DF251'; Extract = @{ Into = "$script:SrcRoot\termwrap"; Flat = 'TermWrap' } }
    @{ Name = 'zydis.zip'; Url = 'https://codeload.github.com/zyantific/zydis/zip/938b5158fd7db5043f88285b23470c8b3b02108a'; Sha256 = 'F35DC9F4F9D35BF31357491D1B0B2E4A3C6E024C6AD7692A5F0F20B3B708AE9D'; Extract = @{ Into = "$script:SrcRoot"; Flat = 'zydis' } }
    @{ Name = 'zycore.zip'; Url = 'https://codeload.github.com/zyantific/zycore-c/zip/75a36c45ae1ad382b0f4e0ede0af84c11ee69928'; Sha256 = 'E3176BB41839AAD88D7385EA3C7A5674201A1B2F18FAEB2E9345E5771E5964E6'; Extract = @{ Into = "$script:SrcRoot\zydis\dependencies"; Flat = 'zycore' } }
)

function Invoke-MsBuild {
    param([string]$Project, [string]$Platform, [string]$Toolset, [string]$Configuration = 'Release', [string]$ExtraProps = '')
    $msbuild = Join-Path $script:VsInstall 'MSBuild\Current\Bin\MSBuild.exe'
    $args = @($Project, "/p:Configuration=$Configuration", "/p:Platform=$Platform", "/p:PlatformToolset=$Toolset", '/v:m', '/nologo')
    if ($ExtraProps) { $args += $ExtraProps }
    Write-Host "  msbuild $Project ($Platform / $Toolset)"
    & $msbuild @args
    if ($LASTEXITCODE -ne 0) { throw "MSBuild failed: $Project ($Platform)" }
}

Write-Host '=== TermWrapWrapper: RDPWrapOffsetFinder self-build ==='

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw 'vswhere not found' }
$script:VsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $script:VsInstall) { throw 'VS Build Tools with VC tools not found' }
Write-Host "VS install: $script:VsInstall"

$toolsetDirs = @(Get-ChildItem "$script:VsInstall\MSBuild\Microsoft\VC\*\Platforms\*\PlatformToolsets\*" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Where-Object { $_ -match '^v\d+$' } | Sort-Object -Unique)
$toolset = if ($toolsetDirs -contains 'v143') { 'v143' } elseif ($toolsetDirs.Count -gt 0) { $toolsetDirs[0] } else { throw 'no VC toolset found' }
Write-Host "toolset: $toolset"

New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null

foreach ($pin in $script:Pins) {
    $zip = Join-Path $script:CacheDir $pin.Name
    if ($Clean -or -not (Test-Path $zip)) {
        Write-Host "  downloading $($pin.Name)..."
        Invoke-WebRequest -Uri $pin.Url -OutFile $zip -UseBasicParsing -TimeoutSec 300
    }
    if (-not $SkipVerify) {
        $h = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($h -ne $pin.Sha256) { throw "$($pin.Name) SHA256 mismatch: $h" }
    }
    $target = $pin.Extract.Into
    $flat = Join-Path $target $pin.Extract.Flat
    if (-not (Test-Path $flat)) {
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Expand-Archive -Path $zip -DestinationPath $target -Force
        $innerDir = Get-ChildItem $target -Directory | Where-Object { $_.Name -ne $pin.Extract.Flat } | Select-Object -First 1
        if ($innerDir) {
            Get-ChildItem $innerDir.FullName -Force | Move-Item -Destination $target -Force
            Remove-Item $innerDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "  verified+extracted: $($pin.Name)"
}

Write-Host '=== staging fork files ==='
Copy-Item (Join-Path $script:BuildRoot 'fork\RDPWrapOffsetFinderDll.vcxproj') (Join-Path $script:SrcRoot 'offsetfinder\RDPWrapOffsetFinderDll.vcxproj') -Force

Write-Host '=== patching sources (fork layer) ==='
& (Join-Path $script:BuildRoot 'patch-src.ps1') -SrcRoot $script:SrcRoot

Write-Host '=== building zydis/zycore (static, no /GS) ==='
Get-Process mspdbsrv, cl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $script:SrcRoot 'zydis\msvc\bin') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $script:SrcRoot 'zydis\msvc\obj') -Recurse -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$zycoreProj = Join-Path $script:SrcRoot 'zydis\msvc\dependencies\zycore\Zycore.vcxproj'
$zydisProj = Join-Path $script:SrcRoot 'zydis\msvc\zydis\Zydis.vcxproj'
for ($attempt = 1; $attempt -le 3; $attempt++) {
    $failed = $false
    try {
        foreach ($plat in @('x64','Win32')) {
            Invoke-MsBuild -Project $zycoreProj -Platform $plat -Toolset $toolset -Configuration 'Release MD' -ExtraProps '/p:BufferSecurityCheck=false'
            Invoke-MsBuild -Project $zydisProj -Platform $plat -Toolset $toolset -Configuration 'Release MD' -ExtraProps '/p:BufferSecurityCheck=false'
        }
    } catch {
        $failed = $true
        Write-Host "  zydis build attempt $attempt failed; retrying..."
        Get-Process mspdbsrv, cl -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:SrcRoot 'zydis\msvc\bin') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:SrcRoot 'zydis\msvc\obj') -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    if (-not $failed) { break }
    if ($attempt -eq 3) { throw 'zydis build failed after 3 attempts' }
}

Write-Host '=== building RDPWrapOffsetFinder DLL ==='
$dllProj = Join-Path $script:SrcRoot 'offsetfinder\RDPWrapOffsetFinderDll.vcxproj'
foreach ($plat in @('x64','Win32')) {
    Invoke-MsBuild -Project $dllProj -Platform $plat -Toolset $toolset
}

Write-Host '=== building RDPWrapOffsetFinder EXE (sym research tool) ==='
$exeProj = Join-Path $script:SrcRoot 'offsetfinder\RDPWrapOffsetFinder\RDPWrapOffsetFinder.vcxproj'
foreach ($plat in @('x64','Win32')) {
    Invoke-MsBuild -Project $exeProj -Platform $plat -Toolset $toolset
}
$symTools = Join-Path $script:BuildRoot 'sym-tools'
New-Item -ItemType Directory -Path $symTools -Force | Out-Null
Copy-Item (Join-Path $script:OutRoot 'sym-x64\RDPWrapOffsetFinder.exe') $symTools -Force
Copy-Item (Join-Path $script:OutRoot 'sym-x86\RDPWrapOffsetFinder.exe') (Join-Path $symTools 'RDPWrapOffsetFinder_x86.exe') -Force
$v10 = Join-Path (Split-Path $script:BuildRoot -Parent) 'src\bin\v1.0\x64'
foreach ($sf in @('dbghelp.dll','symsrv.dll','symsrv.yes','Zydis.dll')) {
    if (Test-Path (Join-Path $v10 $sf)) { Copy-Item (Join-Path $v10 $sf) $symTools -Force }
}
Write-Host "  sym tools: $symTools"

Write-Host '=== building TermWrap (master @ 28000.2307 fix) ==='
$twRoot = Join-Path $script:SrcRoot 'termwrap'
foreach ($item in @(
    @{ Proj = 'TermWrap'; Plats = @('x64','Win32') },
    @{ Proj = 'UmWrap';  Plats = @('x64') },
    @{ Proj = 'EndpWrap'; Plats = @('x64') }
)) {
    foreach ($plat in $item.Plats) {
        Invoke-MsBuild -Project (Join-Path $twRoot "$($item.Proj)\$($item.Proj).vcxproj") -Platform $plat -Toolset $toolset
    }
}

Write-Host '=== deploying TermWrap to src\bin\termwrap ==='
$twBin = Join-Path (Split-Path $script:BuildRoot -Parent) 'src\bin\termwrap'
$twManifest = @()
foreach ($item in @(
    @{ Arch = 'x64'; Files = @('TermWrap.dll','UmWrap.dll','EndpWrap.dll') },
    @{ Arch = 'x86'; Files = @('TermWrap.dll') }
)) {
    New-Item -ItemType Directory -Path (Join-Path $twBin $item.Arch) -Force | Out-Null
    foreach ($fn in $item.Files) {
        $platDir = if ($item.Arch -eq 'x64') { 'x64' } else { '' }
        $srcOut = Join-Path $twRoot "$($fn.Replace('.dll',''))\$platDir\Release\$fn"
        if (-not (Test-Path $srcOut)) { throw "TermWrap output missing: $srcOut" }
        Copy-Item $srcOut (Join-Path $twBin "$($item.Arch)\$fn") -Force
    }
}
Get-ChildItem $twBin -Recurse -Filter *.dll | ForEach-Object {
    $rel = $_.FullName.Replace($twBin + '\', '')
    $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    $twManifest += "$rel  $h"
}
$twManifest | Set-Content (Join-Path $twBin 'SHA256.txt') -Encoding UTF8
$twManifest | ForEach-Object { Write-Host "  $_" }

Write-Host '=== deploying to src\bin\offsetfinder ==='
$manifest = @()
foreach ($plat in @('x64','x86')) {
    $dll = Join-Path $script:OutRoot "$plat\RDPWrapOffsetFinder.dll"
    if (-not (Test-Path $dll)) { throw "expected output missing: $dll" }
    New-Item -ItemType Directory -Path (Join-Path $script:BinRoot $plat) -Force | Out-Null
    Copy-Item $dll (Join-Path $script:BinRoot "$plat\RDPWrapOffsetFinder.dll") -Force
    $h = (Get-FileHash (Join-Path $script:BinRoot "$plat\RDPWrapOffsetFinder.dll") -Algorithm SHA256).Hash
    $manifest += "$plat RDPWrapOffsetFinder.dll  $h"
}
$manifest | Set-Content (Join-Path $script:BinRoot 'SHA256.txt') -Encoding UTF8
$manifest | ForEach-Object { Write-Host "  $_" }
Write-Host '=== DONE ==='


