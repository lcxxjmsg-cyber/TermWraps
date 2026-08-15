# Core.Deploy.ps1 - TermWrap 部署/卸载/升级/回滚
# 依据 docs/termwrap-deployment-notes.md：只改写 ServiceDll 指针 + 复制 DLL 集

$script:RDPWRAP_DIR = "$env:ProgramFiles\RDP Wrapper"
$script:RDPWRAP_TERMSRV = "$env:ProgramFiles\RDP Wrapper\TermWrap.dll"
$script:RDPWRAP_UMWRAP = "$env:ProgramFiles\RDP Wrapper\UmWrap.dll"
$script:RDPWRAP_ENDPWRAP = "$env:ProgramFiles\RDP Wrapper\EndpWrap.dll"
$script:TERMWRAP_STATE = "$env:ProgramData\rdpwarp\termwrap-state.json"

$script:REG_UMRDP_PARAMS = 'HKLM:\SYSTEM\CurrentControlSet\Services\UmRdpService\Parameters'
$script:REG_AUDIO_ENUM = "$REG_RDP_WS\AudioEnumeratorDll"

function Get-TermWrapBinRoot {
    $mod = Join-Path $PSScriptRoot '..\bin\termwrap'
    return [System.IO.Path]::GetFullPath($mod)
}

function Test-TermWrapBinaries {
    param([string]$Arch)
    $root = Get-TermWrapBinRoot
    $dir = Join-Path $root $Arch
    if (-not (Test-Path $dir)) { return $false }
    $manifest = Join-Path $root 'SHA256.txt'
    if (-not (Test-Path $manifest)) { return $false }
    foreach ($line in (Get-Content $manifest)) {
        if ($line -match "^$([regex]::Escape($Arch))\\([^ ]+)\s+([0-9A-F]{64})$") {
            $f = Join-Path $dir $Matches[1]
            if (-not (Test-Path $f)) { return $false }
            $h = (Get-FileHash $f -Algorithm SHA256).Hash
            if ($h -ne $Matches[2]) { return $false }
        }
    }
    return $true
}

function Save-TermWrapState {
    param([bool]$UmWrap)
    $ts = (Get-ItemProperty -Path $REG_TS -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
    $um = (Get-ItemProperty -Path $script:REG_UMRDP_PARAMS -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
    $state = [PSCustomObject]@{
        Schema=1; SavedAt=(Get-Date).ToString('o')
        TermServiceDll=$ts; UmRdpServiceDll=$um
        UmWrap=$UmWrap; EndpWrap=$false
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path $script:TERMWRAP_STATE) -Force -ErrorAction Stop | Out-Null
        $state | ConvertTo-Json -Depth 4 | Out-File $script:TERMWRAP_STATE -Encoding UTF8 -Force
        return $true
    } catch { Write-E "状态保存失败: $_"; return $false }
}

function Set-TermServiceDll {
    param([string]$Path,[string]$Value)
    try {
        if ($null -eq (Get-ItemProperty -Path $Path -Name ServiceDll -ErrorAction SilentlyContinue)) {
            New-ItemProperty -Path $Path -Name ServiceDll -Value $Value -PropertyType ExpandString -Force -ErrorAction Stop | Out-Null
        } else {
            Set-ItemProperty -Path $Path -Name ServiceDll -Value $Value -ErrorAction Stop
        }
        return $true
    } catch { Write-E "ServiceDll 写入失败 ($Path): $_"; return $false }
}

function Stop-RdpService {
    Write-I "停止 RDP 服务..."
    Stop-Service -Name UmRdpService -Force -ErrorAction SilentlyContinue
    Stop-Service -Name TermService -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

function Start-RdpService {
    Write-I "启动 TermService..."
    Start-Service -Name TermService -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
    if ($svc.Status -eq 'Running') { Write-S "TermService 运行中" } else { Write-E "TermService: $($svc.Status)" }
    Start-Service -Name UmRdpService -ErrorAction SilentlyContinue
}

function Restart-RdpService {
    Stop-RdpService
    Start-RdpService
    Start-Sleep -Seconds 1
    Start-Service -Name UmRdpService -ErrorAction SilentlyContinue
}

function Deploy-TermWrapBinaries {
    param([switch]$UmWrap,[switch]$EndpWrap,[switch]$SkipRestart)
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    if (-not (Test-Admin)) { Write-E "需要管理员权限"; return $false }
    if (-not (Test-TermWrapBinaries $arch)) { Write-E "TermWrap 二进制缺失或哈希不符 ($arch)"; return $false }

    $origTs = (Get-ItemProperty -Path $REG_TS -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
    $origUm = (Get-ItemProperty -Path $script:REG_UMRDP_PARAMS -Name ServiceDll -ErrorAction SilentlyContinue).ServiceDll
    if (-not $origTs) { $origTs = '%SystemRoot%\System32\termsrv.dll' }
    if (-not $origUm) { $origUm = '%SystemRoot%\System32\umrdp.dll' }

    $rollback = {
        param($files)
        Write-W "自动回滚：恢复 ServiceDll 并删除已部署文件..."
        Set-TermServiceDll -Path $REG_TS -Value $origTs | Out-Null
        Set-TermServiceDll -Path $script:REG_UMRDP_PARAMS -Value $origUm | Out-Null
        foreach ($f in $files) {
            $p = Join-Path $script:RDPWRAP_DIR $f
            if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
        }
        Stop-RdpService
        Start-RdpService
    }

    $deployedFiles = @()
    try {
        New-Item -ItemType Directory -Path $script:RDPWRAP_DIR -Force | Out-Null
        $root = Get-TermWrapBinRoot
        $src = Join-Path $root $arch
        $files = @('TermWrap.dll')
        if ($UmWrap -and $arch -eq 'x64') { $files += 'UmWrap.dll' }
        if ($EndpWrap -and $arch -eq 'x64') { $files += 'EndpWrap.dll' }
        if ($UmWrap -and $arch -ne 'x64') { Write-W "UmWrap 仅支持 x64，已跳过" }
        if ($EndpWrap -and $arch -ne 'x64') { Write-W "EndpWrap 仅支持 x64，已跳过" }

        foreach ($f in $files) {
            Copy-Item (Join-Path $src $f) $script:RDPWRAP_DIR -Force -ErrorAction Stop
            $deployedFiles += $f
            Write-I "部署: $f"
        }

        if (-not (Save-TermWrapState -UmWrap ($UmWrap -and $arch -eq 'x64'))) { throw '状态文件保存失败' }

        $target = '%ProgramFiles%\RDP Wrapper\TermWrap.dll'
        if (-not (Set-TermServiceDll -Path $REG_TS -Value $target)) { throw "TermService ServiceDll 写入失败" }
        if ($UmWrap -and $arch -eq 'x64') {
            if (-not (Set-TermServiceDll -Path $script:REG_UMRDP_PARAMS -Value '%ProgramFiles%\RDP Wrapper\UmWrap.dll')) { throw 'UmRdpService ServiceDll 写入失败' }
            Write-S "UmWrap 已启用（UmRdpService.ServiceDll -> UmWrap.dll）"
        }
        Add-RdpwrapDefenderExclusions

        if ($SkipRestart) { Write-W "已跳过服务重启"; return $true }

        Stop-RdpService
        Start-RdpService
        Start-Sleep -Seconds 2
        $st = Get-TermWrapStatus
        if ($st.HealthState -eq 'Healthy') {
            Write-S "TermWrap 运行验证通过（$($st.HealthMessage)）"
            Set-TermsrvChangeState -Version $st.TermsrvVersion
            return $true
        }
        Write-E "热启动后未达 Healthy（$($st.HealthMessage)）"
        Write-W "可能需要重启系统才能生效（ServiceDll 变更的兜底路径）"
        Write-I "执行: shutdown /r /t 0"
        return $false
    } catch {
        & $rollback $deployedFiles
        Write-E "部署异常: $_（已自动回滚到原配置）"
        return $false
    }
}

function Uninstall-TermWrapBinaries {
    if (-not (Test-Admin)) { Write-E "需要管理员权限"; return $false }
    $stockTs = '%SystemRoot%\System32\termsrv.dll'
    $stockUm = '%SystemRoot%\System32\umrdp.dll'
    $restored = $false
    if (Test-Path $script:TERMWRAP_STATE) {
        try {
            $state = Get-Content $script:TERMWRAP_STATE -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.TermServiceDll) { $stockTs = $state.TermServiceDll }
            if ($state.UmRdpServiceDll) { $stockUm = $state.UmRdpServiceDll }
            $restored = $true
        } catch { Write-W "状态文件解析失败，使用默认还原值" }
    }
    Stop-RdpService
    if (-not (Set-TermServiceDll -Path $REG_TS -Value $stockTs)) { return $false }
    if (-not (Set-TermServiceDll -Path $script:REG_UMRDP_PARAMS -Value $stockUm)) { return $false }
    Start-RdpService
    foreach ($f in @('TermWrap.dll','UmWrap.dll','EndpWrap.dll')) {
        $p = Join-Path $script:RDPWRAP_DIR $f
        if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Write-I "已删除: $f" }
    }
    if (Test-Path $script:TERMWRAP_STATE) { Remove-Item $script:TERMWRAP_STATE -Force -ErrorAction SilentlyContinue }
    Write-S "TermWrap 已卸载（ServiceDll 已还原）"
    return $true
}

function Enable-TermWrapAudioRecording {
    if (-not (Test-Admin)) { Write-E "需要管理员权限"; return $false }
    if (-not (Test-Path $script:RDPWRAP_ENDPWRAP)) { Write-E "EndpWrap.dll 未部署（需 x64 + -EndpWrap）"; return $false }
    $sys32 = "$env:SystemRoot\System32"
    Copy-Item $script:RDPWRAP_ENDPWRAP $sys32 -Force
    try {
        Set-ItemProperty -Path $script:REG_AUDIO_ENUM -Name '(default)' -Value 'EndpWrap.dll' -ErrorAction Stop
        Write-S "音频录制重定向已启用（AudioEnumeratorDll -> EndpWrap.dll）"
        return $true
    } catch { Write-E "AudioEnumeratorDll 写入失败: $_"; return $false }
}

